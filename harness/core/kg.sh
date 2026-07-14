# core/kg.sh — Code Knowledge Graph builder + queries.
#
# Populates kg_nodes (kind, name, file, line) and kg_edges (src→dst, kind) from a
# scan of the project's source. Symbol/import extraction is done by two awk
# programs (kg_symbols.awk, kg_imports.awk) — one process for the whole tree,
# dispatched by file extension, covering the declaration forms current as of
# each language's latest spec. There is no ctags/grep fallback: Bash 5.3 + the
# bundled awk programs are the single, owned path.
#
#   node kinds : file | function | class | module
#   edge kinds : contains (file→symbol) | imports (file→module)

# Directory holding the awk programs — resolved when this file is sourced, so it
# is correct regardless of the caller's cwd or $YCA_DIR.
_KG_DIR="${BASH_SOURCE[0]%/*}"

# _kg_ignore -> a find prune expression for noise directories.
_kg_ignore='( -name .git -o -name node_modules -o -name vendor -o -name target -o -name dist -o -name build -o -name .venv -o -name __pycache__ -o -name .harness )'

# _kg_files DIR -> NUL-separated candidate source files, noise dirs pruned.
# One tree walk; consumed by a single awk pass via `xargs -0`. The harness's own
# .harness.db* SQLite files live at the project root — exclude them so awk never
# reads them (they are also handled by LC_ALL=C below, but skipping is cheaper).
_kg_files() { find "$1" $_kg_ignore -prune -o -type f ! -name '.harness.db*' -print0 2>/dev/null; }

# awk under LC_ALL=C: treat input as bytes, so a binary or non-UTF-8 file
# anywhere in the tree can never abort the scan with a multibyte-conversion
# error (which would lose every other file's symbols too). Source identifiers
# are ASCII, so byte-wise matching is equivalent for our patterns.
kg_scan_symbols() {
    local dir="${1%/}"
    _kg_files "$dir" | LC_ALL=C xargs -0 awk -v dir="$dir" -f "$_KG_DIR/kg_symbols.awk" 2>/dev/null
}

# kg_scan_imports DIR -> TSV rows: relfile<TAB>module
kg_scan_imports() {
    local dir="${1%/}"
    _kg_files "$dir" | LC_ALL=C xargs -0 awk -v dir="$dir" -f "$_KG_DIR/kg_imports.awk" 2>/dev/null
}

# kg_build [DIR] -> rebuild the graph for the project. Returns a summary line.
#
# The scan emits two TSV streams to temp files; SQLite `.import`s them into TEMP
# staging tables (streamed row-by-row in C — bounded memory, no giant SQL string
# held in the shell), then the real tables are populated with set-based
# `INSERT … SELECT` inside one transaction. This replaces the previous approach
# of emitting one `INSERT … VALUES` statement per symbol (tens of thousands of
# repeated statements built up in a shell loop), which was the dominant cost and
# grew unbounded with project size.
kg_build() {
    local dir="${1:-$YCA_PROJECT_DIR}"; dir="${dir%/}"
    local symf impf; symf=$(path_temp_file yca-kg .sym); impf=$(path_temp_file yca-kg .imp)
    kg_scan_symbols "$dir" > "$symf"
    kg_scan_imports "$dir" > "$impf"

    # Dot-commands (.import) and SQL are mixed in one sqlite3 session. Staging is
    # TEMP (separate temp DB — its writes never touch the main WAL). The single
    # BEGIN…COMMIT is the only main-DB transaction and is fully set-based.
    sqlite3 -cmd ".timeout ${YCA_SQLITE_BUSY_TIMEOUT:-10000}" "$YCA_DB_PATH" 2>/dev/null <<SQL
PRAGMA foreign_keys=OFF;
-- Leave temp_store at the default (disk-backed): the staging tables spill to a
-- temp file rather than RAM, so peak memory stays bounded no matter how large
-- the project is — .import streams rows in, it never materialises the whole set
-- in memory. Speed cost is negligible; bounded memory is the point.
CREATE TEMP TABLE stg_sym(kind TEXT, name TEXT, file TEXT, line INTEGER);
CREATE TEMP TABLE stg_imp(file TEXT, module TEXT);
.mode tabs
.import '$symf' stg_sym
.import '$impf' stg_imp
BEGIN;
DELETE FROM kg_edges;
DELETE FROM kg_nodes;

-- File nodes: every distinct path that produced a symbol or an import.
INSERT OR IGNORE INTO kg_nodes(kind, name, file, line)
    SELECT 'file', file, file, 0
    FROM (SELECT file FROM stg_sym WHERE file <> ''
          UNION
          SELECT file FROM stg_imp WHERE file <> '');

-- Symbol nodes. OR IGNORE + UNIQUE(name,file,line) dedups repeats.
INSERT OR IGNORE INTO kg_nodes(kind, name, file, line)
    SELECT kind, name, file, line
    FROM stg_sym
    WHERE name <> '' AND kind IN ('function', 'class', 'module');

-- Module nodes (name=module, file=importing file — the edge join keys on this).
INSERT OR IGNORE INTO kg_nodes(kind, name, file, line)
    SELECT 'module', module, file, 0
    FROM stg_imp
    WHERE module <> '';

-- contains: file → its functions/classes.
INSERT INTO kg_edges(src_id, dst_id, kind)
    SELECT f.id, s.id, 'contains'
    FROM kg_nodes f JOIN kg_nodes s ON s.file = f.name
    WHERE f.kind = 'file' AND s.kind IN ('function', 'class');

-- imports: file → module it references.
INSERT INTO kg_edges(src_id, dst_id, kind)
    SELECT f.id, m.id, 'imports'
    FROM kg_nodes f JOIN kg_nodes m ON m.file = f.name
    WHERE f.kind = 'file' AND m.kind = 'module';
COMMIT;
PRAGMA optimize;
SQL
    local rc=$?
    rm -f "$symf" "$impf"
    local n e
    n=$(db_exec "SELECT COUNT(*) FROM kg_nodes;" 2>/dev/null)
    e=$(db_exec "SELECT COUNT(*) FROM kg_edges;" 2>/dev/null)
    printf 'knowledge graph built: %s nodes, %s edges' "${n:-0}" "${e:-0}"
    return $rc
}

# kg_parse_file FILE -> JSON of the symbols and imports extracted from one file:
#   { "file": "...", "symbols": [{kind,name,line}, ...], "imports": ["mod", ...] }
# The parser output with no persistence — for callers that keep/query the graph
# in their own store instead of the built-in SQLite tables.
kg_parse_file() {
    local file="$1"
    [[ -f "$file" ]] || { printf '{"error":"no such file","file":%s}' "$(printf '%s' "$file" | jq -R .)"; return 1; }
    # dir = the file's own directory, so the awk programs' relative path is just
    # the basename (the caller already knows the path they passed in).
    local dir; dir=$(cd "$(dirname "$file")" 2>/dev/null && pwd) || dir="."
    local syms imps
    syms=$(LC_ALL=C awk -v dir="$dir" -f "$_KG_DIR/kg_symbols.awk" "$file" 2>/dev/null)
    imps=$(LC_ALL=C awk -v dir="$dir" -f "$_KG_DIR/kg_imports.awk" "$file" 2>/dev/null)
    jq -n --arg file "$file" --arg syms "$syms" --arg imps "$imps" '{
        file: $file,
        symbols: ($syms | split("\n") | map(select(length > 0) | split("\t")
                  | {kind: .[0], name: .[1], line: (.[3] | tonumber? // 0)})),
        imports: ($imps | split("\n") | map(select(length > 0) | split("\t") | .[1]) | unique)
    }'
}

# kg_query SQL -> JSON rows (read-only).
kg_query() { _sqlite -json -readonly "$YCA_DB_PATH" "$1" 2>/dev/null || printf '[]'; }
