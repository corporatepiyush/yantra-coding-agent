# core/db.sh — SQLite database schema and initialization

readonly YCA_SCHEMA_VERSION="5"

db_init() {
    YCA_DB_PATH="${HARNESS_DB:-$YCA_PROJECT_DIR/.harness.db}"
    path_ensure_dir "$(dirname "$YCA_DB_PATH")"

    # Keep harness internals out of git
    local gi="$YCA_PROJECT_DIR/.gitignore"
    if [[ -d "$YCA_PROJECT_DIR/.git" ]] && ! grep -qxF '.harness.db*' "$gi" 2>/dev/null; then
        printf '# yantra-coding-agent internals\n.harness.db*\n.harness/\n.yantra-scratch.db*\n' >> "$gi" 2>/dev/null || true
    fi

    # Schema version check + migration
    _db_check_schema_version

    sqlite3 "$YCA_DB_PATH" >/dev/null 2>&1 <<'SQL'
PRAGMA journal_mode=WAL;
PRAGMA busy_timeout=5000;
PRAGMA foreign_keys=ON;
PRAGMA wal_autocheckpoint=1000;
PRAGMA auto_vacuum=INCREMENTAL;

CREATE TABLE IF NOT EXISTS config (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS skills (agent TEXT, version TEXT, text TEXT NOT NULL, updated TEXT DEFAULT (datetime('now')), PRIMARY KEY (agent, version));
CREATE TABLE IF NOT EXISTS events (id INTEGER PRIMARY KEY AUTOINCREMENT, agent TEXT, ts TEXT DEFAULT (datetime('now')), level TEXT, kind TEXT, message TEXT, data_json TEXT);
CREATE TABLE IF NOT EXISTS heartbeats (agent TEXT, pid INTEGER, ts TEXT DEFAULT (datetime('now')), status TEXT DEFAULT 'alive', cpu REAL, mem REAL, PRIMARY KEY (agent, pid, ts));
CREATE TABLE IF NOT EXISTS tasks (id INTEGER PRIMARY KEY AUTOINCREMENT, parent_id INTEGER, agent TEXT, status TEXT DEFAULT 'pending', input_json TEXT, output_json TEXT, created_ts TEXT DEFAULT (datetime('now')), updated_ts TEXT DEFAULT (datetime('now')));
CREATE TABLE IF NOT EXISTS messages (id INTEGER PRIMARY KEY AUTOINCREMENT, from_agent TEXT, to_agent TEXT, ts TEXT DEFAULT (datetime('now')), payload_json TEXT, consumed INTEGER DEFAULT 0);
CREATE TABLE IF NOT EXISTS changes (id INTEGER PRIMARY KEY AUTOINCREMENT, task_id INTEGER, file_path TEXT, change_type TEXT, summary TEXT, ts TEXT DEFAULT (datetime('now')));
CREATE TABLE IF NOT EXISTS versions (id INTEGER PRIMARY KEY AUTOINCREMENT, harness_version TEXT, commit_sha TEXT, applied_ts TEXT DEFAULT (datetime('now')));
-- Knowledge graph. STRICT for type safety; plain INTEGER PRIMARY KEY (rowid
-- alias — no AUTOINCREMENT, which only adds a monotonic-id guarantee we don't
-- need and a sqlite_sequence write per insert). kg_edges carries no FK: it is a
-- fully-derived cache rebuilt wholesale by kg_build, so integrity is guaranteed
-- by the rebuild, and skipping the FK check speeds the bulk INSERT…SELECT.
CREATE TABLE IF NOT EXISTS kg_nodes (
    id    INTEGER PRIMARY KEY,
    kind  TEXT    NOT NULL,
    name  TEXT    NOT NULL,
    file  TEXT    NOT NULL DEFAULT '',
    line  INTEGER NOT NULL DEFAULT 0,
    attrs_json TEXT,
    UNIQUE(name, file, line)
) STRICT;
CREATE TABLE IF NOT EXISTS kg_edges (
    id     INTEGER PRIMARY KEY,
    src_id INTEGER NOT NULL,
    dst_id INTEGER NOT NULL,
    kind   TEXT    NOT NULL,
    attrs_json TEXT
) STRICT;

-- Indexes on the columns the monitor tools filter/sort by (agent/kind/level/ts,
-- change_type, status, heartbeat liveness). Keeps WHERE/ORDER queries fast as
-- the event log grows.
CREATE INDEX IF NOT EXISTS idx_events_ts        ON events(ts);
CREATE INDEX IF NOT EXISTS idx_events_agent     ON events(agent);
CREATE INDEX IF NOT EXISTS idx_events_kind      ON events(kind);
CREATE INDEX IF NOT EXISTS idx_events_level     ON events(level);
CREATE INDEX IF NOT EXISTS idx_events_kind_ts   ON events(kind, ts);
CREATE INDEX IF NOT EXISTS idx_changes_ts       ON changes(ts);
CREATE INDEX IF NOT EXISTS idx_changes_type     ON changes(change_type);
CREATE INDEX IF NOT EXISTS idx_tasks_status     ON tasks(status);
CREATE INDEX IF NOT EXISTS idx_tasks_created    ON tasks(created_ts);
-- Hot plan lookup: WHERE agent='plan' AND status='active' (every plan step).
-- The standalone status index can't serve the two-column predicate directly.
CREATE INDEX IF NOT EXISTS idx_tasks_agent_status ON tasks(agent, status);
CREATE INDEX IF NOT EXISTS idx_heartbeats_agent ON heartbeats(agent, ts);
-- ts-only prune runs on EVERY heartbeat tick (DELETE ... WHERE ts < ?); the
-- (agent, ts) PK/index can't serve a leading-ts predicate, so without this the
-- prune (and the monitor 'WHERE ts > ?' liveness query) full-scans heartbeats.
CREATE INDEX IF NOT EXISTS idx_heartbeats_ts      ON heartbeats(ts);
CREATE INDEX IF NOT EXISTS idx_messages_ts      ON messages(ts);
-- name: exact-name joins (refs/neighbors WHERE name=?); file_kind: symbols-in-
-- file + the edge-build join (s.file=f.name); name_ci: case-insensitive lookup.
-- Edge indexes are covering + composite so contains/imports traversals in both
-- directions are index-only (src→dst and dst→src) instead of a per-column probe.
CREATE INDEX IF NOT EXISTS idx_kg_nodes_name      ON kg_nodes(name);
CREATE INDEX IF NOT EXISTS idx_kg_nodes_file_kind ON kg_nodes(file, kind);
CREATE INDEX IF NOT EXISTS idx_kg_nodes_name_ci   ON kg_nodes(name COLLATE NOCASE);
CREATE INDEX IF NOT EXISTS idx_kg_edges_out       ON kg_edges(src_id, kind, dst_id);
CREATE INDEX IF NOT EXISTS idx_kg_edges_in        ON kg_edges(dst_id, kind, src_id);

-- Substring symbol search without a table scan. The trigram tokenizer (SQLite
-- 3.34+) makes `name MATCH 'foo'` an indexed lookup that matches 'foo' anywhere
-- in an identifier — the indexed replacement for `name LIKE '%foo%'`. External
-- content (content=kg_nodes) stores no duplicate copy of the names; the triggers
-- keep the index in sync across the wholesale delete+insert of a rebuild.
CREATE VIRTUAL TABLE IF NOT EXISTS kg_nodes_fts USING fts5(
    name, content='kg_nodes', content_rowid='id', tokenize='trigram'
);
CREATE TRIGGER IF NOT EXISTS kg_nodes_ai AFTER INSERT ON kg_nodes BEGIN
    INSERT INTO kg_nodes_fts(rowid, name) VALUES (new.id, new.name);
END;
CREATE TRIGGER IF NOT EXISTS kg_nodes_ad AFTER DELETE ON kg_nodes BEGIN
    INSERT INTO kg_nodes_fts(kg_nodes_fts, rowid, name) VALUES ('delete', old.id, old.name);
END;
CREATE TRIGGER IF NOT EXISTS kg_nodes_au AFTER UPDATE ON kg_nodes BEGIN
    INSERT INTO kg_nodes_fts(kg_nodes_fts, rowid, name) VALUES ('delete', old.id, old.name);
    INSERT INTO kg_nodes_fts(rowid, name) VALUES (new.id, new.name);
END;

CREATE VIRTUAL TABLE IF NOT EXISTS search_fts USING fts5(events_content, content=events, content_rowid=id);
CREATE TRIGGER IF NOT EXISTS events_ai AFTER INSERT ON events BEGIN
    INSERT INTO search_fts(rowid, events_content) VALUES (new.id, new.message);
END;
CREATE TRIGGER IF NOT EXISTS events_ad AFTER DELETE ON events BEGIN
    INSERT INTO search_fts(search_fts, rowid, events_content) VALUES ('delete', old.id, old.message);
END;
CREATE TRIGGER IF NOT EXISTS events_au AFTER UPDATE ON events BEGIN
    INSERT INTO search_fts(search_fts, rowid, events_content) VALUES ('delete', old.id, old.message);
    INSERT INTO search_fts(rowid, events_content) VALUES (new.id, new.message);
END;
SQL
    db_exec "INSERT OR IGNORE INTO versions(harness_version) VALUES ($(sql_quote "$YCA_VERSION"));" 2>/dev/null || true
    db_exec "INSERT OR REPLACE INTO config(key, value) VALUES ('schema_version', '$YCA_SCHEMA_VERSION');" 2>/dev/null || true
    seed_skills
    cat_init_defaults
}

_db_check_schema_version() {
    [[ -f "$YCA_DB_PATH" ]] || return 0
    local current
    current=$(_sqlite -readonly "$YCA_DB_PATH" "SELECT value FROM config WHERE key='schema_version';" 2>/dev/null || printf '')
    if [[ -n "$current" && "$current" != "$YCA_SCHEMA_VERSION" ]]; then
        local backup="${YCA_DB_PATH}.v${current}_backup_$(now_stamp)"
        logmsg "$(c_warn "⚠ Schema version mismatch (DB: v$current, harness: v$YCA_SCHEMA_VERSION)")"
        logmsg "$(c_warn "  Backing up old DB → $backup")"
        logmsg "$(c_warn "  Creating fresh DB for new schema.")"
        cp "$YCA_DB_PATH" "$backup"
        rm -f "$YCA_DB_PATH" "${YCA_DB_PATH}-wal" "${YCA_DB_PATH}-shm"
    fi
}

# cat_init_defaults — seed the in-memory category gates from the built-in
# defaults. Config-file categories and detected-language categories are layered
# on afterward by main(). Category toggles are session-only (never persisted),
# because yantra.config.json is the single source of truth.
cat_init_defaults() {
    local cat
    for cat in "${!YCA_CAT_DEFAULT[@]}"; do
        [[ -z "${YCA_CAT_ENABLED[$cat]:-}" ]] && YCA_CAT_ENABLED[$cat]="${YCA_CAT_DEFAULT[$cat]}"
    done
}
