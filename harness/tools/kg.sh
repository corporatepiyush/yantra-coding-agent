# tools/kg.sh — Code Knowledge Graph tools (category: kg).
# Backed by core/kg.sh; queries kg_nodes/kg_edges (populated by kg_build).
# Run kg_build first (or wf:kg build) to index the project.

# Confine indexing to the project fence, like every other read tool — without
# this, kg_build/kg_parse would read and index the symbol/import structure of any
# file or directory on the host (e.g. ~/.aws, /etc), escaping YCA_SAFETY_PATHS.
tool_kg_build() {
    local path; path=$(tool_arg path "${1:-$YCA_PROJECT_DIR}")
    path_check_allowed "$path" || { printf 'path not allowed: %s' "$path"; return 1; }
    kg_build "$path"
}

# parse — extract symbols + imports from ONE file as JSON, without persisting.
# For callers who want to feed the parser output into their own KG store/query
# engine instead of the built-in SQLite tables.
tool_kg_parse() {
    local file; file=$(tool_arg file "$1"); [[ -n "$file" ]] || { printf 'file required (.file)'; return 1; }
    path_check_allowed "$file" || { printf 'path not allowed: %s' "$file"; return 1; }
    kg_parse_file "$file"
}

tool_kg_stats() {
    db_table_exists kg_nodes || { printf 'graph empty — run kg_build first'; return 0; }
    printf 'nodes by kind:\n'
    kg_query "SELECT kind, COUNT(*) AS n FROM kg_nodes GROUP BY kind ORDER BY n DESC;"
    printf '\nedges by kind:\n'
    kg_query "SELECT kind, COUNT(*) AS n FROM kg_edges GROUP BY kind ORDER BY n DESC;"
}

# symbol — find where a function/class is defined. Substring match via the
# trigram FTS index (indexed, no table scan) for queries ≥3 chars; shorter
# queries fall back to a prefix match on the case-insensitive name index.
tool_kg_find_symbol() {
    local name; name=$(tool_arg name "$1"); [[ -n "$name" ]] || { printf 'name required (.name)'; return 1; }
    if (( ${#name} >= 3 )); then
        # Wrap as an FTS5 phrase ("…") so '.', '-', etc. in the query are treated
        # as literal text, not query operators; strip any embedded double quotes.
        local q="\"${name//\"/}\""
        kg_query "SELECT n.kind, n.name, n.file, n.line FROM kg_nodes_fts f JOIN kg_nodes n ON n.id=f.rowid WHERE kg_nodes_fts MATCH $(sql_quote "$q") AND n.kind IN ('function','class') ORDER BY n.name LIMIT 100;"
    else
        kg_query "SELECT kind, name, file, line FROM kg_nodes WHERE name LIKE $(sql_quote "$name")||'%' AND kind IN ('function','class') ORDER BY name LIMIT 100;"
    fi
}

# file — list the symbols defined in a file.
tool_kg_file_symbols() {
    local file; file=$(tool_arg file "$1"); [[ -n "$file" ]] || { printf 'file required (.file)'; return 1; }
    kg_query "SELECT kind, name, line FROM kg_nodes WHERE file=$(sql_quote "$file") AND kind IN ('function','class') ORDER BY line;"
}

# refs — which files reference/import a symbol or module.
tool_kg_references() {
    local name; name=$(tool_arg name "$1"); [[ -n "$name" ]] || { printf 'name required (.name)'; return 1; }
    kg_query "SELECT DISTINCT s.name AS from_file, e.kind AS via FROM kg_edges e JOIN kg_nodes s ON e.src_id=s.id JOIN kg_nodes d ON e.dst_id=d.id WHERE d.name=$(sql_quote "$name") ORDER BY from_file LIMIT 100;"
}

# neighbors — edges touching nodes named NAME (both directions).
tool_kg_neighbors() {
    local name; name=$(tool_arg name "$1"); [[ -n "$name" ]] || { printf 'name required (.name)'; return 1; }
    kg_query "SELECT s.name AS src, e.kind AS edge, d.name AS dst, d.file AS dst_file FROM kg_edges e JOIN kg_nodes s ON e.src_id=s.id JOIN kg_nodes d ON e.dst_id=d.id WHERE s.name=$(sql_quote "$name") OR d.name=$(sql_quote "$name") LIMIT 100;"
}

# llm_explain — build (if needed) then have the LLM narrate the module structure.
tool_kg_llm_explain() {
    db_table_exists kg_nodes || kg_build "$YCA_PROJECT_DIR" >/dev/null
    local stats top
    stats=$(kg_query "SELECT kind, COUNT(*) n FROM kg_nodes GROUP BY kind;")
    top=$(kg_query "SELECT f.name file, COUNT(*) symbols FROM kg_edges e JOIN kg_nodes f ON e.src_id=f.id WHERE e.kind='contains' GROUP BY f.name ORDER BY symbols DESC LIMIT 20;")
    local system_prompt='You are a codebase guide. Given a knowledge-graph summary (node/edge counts and the files with the most symbols), describe the project structure: likely entry points, the biggest/most central modules, and where a newcomer should start reading. Be concrete and concise; only use the data given.'
    llm_analyze "$system_prompt" "$(printf 'NODE/EDGE COUNTS:\n%s\n\nTOP FILES BY SYMBOL COUNT:\n%s' "$stats" "$top")"
}

# kg_build reads project files and writes only the harness's own KG tables —
# an internal index rebuild, not a user-visible mutation, so `safe` (the
# machine-mode consent gate in tool_dispatch denies `writes` tools).
tool_register "kg_build"       tool_kg_build       '{"type":"object","properties":{"path":{"type":"string","description":"file or directory path relative to the project root"}}}' safe all kg
tool_register "kg_parse"       tool_kg_parse       '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"}},"required":["file"]}' safe all kg
tool_register "kg_stats"       tool_kg_stats       '{"type":"object","properties":{}}' safe all kg
tool_register "kg_find_symbol"      tool_kg_find_symbol      '{"type":"object","properties":{"name":{"type":"string","description":"the resource name"}},"required":["name"]}' safe all kg
tool_register "kg_file_symbols"        tool_kg_file_symbols        '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"}},"required":["file"]}' safe all kg
tool_register "kg_references"        tool_kg_references        '{"type":"object","properties":{"name":{"type":"string","description":"the resource name"}},"required":["name"]}' safe all kg
tool_register "kg_neighbors"   tool_kg_neighbors   '{"type":"object","properties":{"name":{"type":"string","description":"the resource name"}},"required":["name"]}' safe all kg
tool_register "kg_llm_explain" tool_kg_llm_explain '{"type":"object","properties":{}}' safe all kg mid
