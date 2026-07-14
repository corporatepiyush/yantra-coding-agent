# lib/sanitize.sh — Untrusted-input sanitizers.
# Anything we read from a prompt, a config file, or an LLM tool argument passes
# through here before it reaches a shell, SQL, or a URL. Functions PRINT the
# cleaned value (and return 0) or return non-zero when the input is rejected.
# (Complements lib/validate.sh, whose val_* helpers log + return without echoing.)

# sanitize_line INPUT -> strip NUL, control chars (except tab), and ANSI/OSC escape
# sequences from a line of interactive input, so a pasted escape sequence can't
# move the cursor, spoof output, or smuggle bytes into a command.
sanitize_line() {
    local s="$1"
    # Drop ESC-introduced sequences (CSI/OSC) first, then remaining control bytes.
    s=$(printf '%s' "$s" | LC_ALL=C sed -E $'s/\x1b\\[[0-9;?]*[ -\/]*[@-~]//g; s/\x1b\\][^\x07]*(\x07|\x1b\\\\)?//g')
    s=$(printf '%s' "$s" | LC_ALL=C tr -d '\000-\010\013-\037\177')
    printf '%s' "$s"
}

# sanitize_url INPUT -> print a safe http(s) URL or return 1.
# Rejects anything that could break out of the curl argument: whitespace, shell
# metacharacters, quotes, a leading '-' (which curl would read as an option), and
# non-http(s) schemes.
sanitize_url() {
    local u="$1"
    # trim surrounding whitespace
    u="${u#"${u%%[![:space:]]*}"}"; u="${u%"${u##*[![:space:]]}"}"
    [[ -z "$u" ]] && return 1
    # Regex kept in a var so its ';' isn't parsed by [[ ]] as a command separator.
    local re='^https?://[A-Za-z0-9._~:/?#@!$&*+,;=%-]+$'
    [[ "$u" =~ $re ]] || return 1
    # No shell metacharacters, quotes, backslashes, or a leading dash.
    case "$u" in
        -*) return 1 ;;
        *[\`\$\;\|\<\>\(\)\'\"\\]*|*' '*) return 1 ;;
    esac
    printf '%s' "$u"
}

# sql_safe_fragment INPUT -> print a single-statement SQL boolean/expression
# fragment (for a monitor WHERE), or return 1. Blocks statement terminators,
# comment markers, and schema/attachment verbs so a fragment can only ever filter
# a single readonly SELECT — never stack or escape it.
sql_safe_fragment() {
    local f="$1"
    [[ -z "$f" ]] && return 1
    # No terminators / comment sequences / stacked-query tricks.
    case "$f" in
        *';'*|*'--'*|*'/*'*|*'*/'*|*$'\n'*|*$'\r'*|*'\'*) return 1 ;;
    esac
    # No dangerous verbs (word-boundary, case-insensitive).
    # Block DML/DDL/attach AND the sqlite CLI fileio/extension functions. Verified
    # at runtime: `sqlite3 -readonly` does NOT stop writefile()/readfile()/
    # load_extension() — they run at shell level, so a "read-only" monitor WHERE
    # like  1=1 OR writefile('/tmp/x','…')>=0  was an arbitrary host file read/write
    # primitive. A bare SELECT is blocked too so a subquery can't exfil another
    # table through the filter.
    if printf '%s' "$f" | grep -qiE '\b(attach|detach|pragma|insert|update|delete|drop|create|alter|replace|vacuum|reindex|select|readfile|writefile|load_extension|fts3_tokenizer|zipfile)\b'; then
        return 1
    fi
    printf '%s' "$f"
}

# int_guard INPUT [DEFAULT] -> print INPUT if it is a non-negative integer, else
# DEFAULT (default 0). Never lets a non-numeric value reach a SQL LIMIT/OFFSET.
int_guard() {
    local v="$1" default="${2:-0}"
    [[ "$v" =~ ^[0-9]+$ ]] && { printf '%s' "$v"; return 0; }
    printf '%s' "$default"
}

# sql_single_stmt SQL -> 0 if SQL has no statement-chaining ';' (one optional
# trailing ';' is allowed). The read-only DB query/explain tools use this so a
# "query" can't smuggle a second, mutating statement past a read-only guard —
# e.g. `SELECT 1; DROP TABLE x` or `SET ...read_only=off; DELETE`.
sql_single_stmt() {
    local core="${1%;}"
    case "$core" in *';'*) return 1 ;; *) return 0 ;; esac
}

# shell_arg_safe INPUT -> print INPUT if it has no shell metacharacters/whitespace
# (safe as a single unquoted token, e.g. a hostname), else return 1.
shell_arg_safe() {
    local s="$1"
    [[ -z "$s" ]] && return 1
    case "$s" in
        *[\`\$\;\|\&\<\>\(\)\'\"\\]*|*' '*|*$'\n'*|*$'\t'*) return 1 ;;
        -*) return 1 ;;
    esac
    printf '%s' "$s"
}

# redact_secrets TEXT -> TEXT with likely secret VALUES masked. Catches both
# `KEY=value` (env/CLI) and `key: value` (YAML/JSON) for common sensitive key
# names, redacting to end-of-line, so a tool that dumps config (helm get values,
# a k8s manifest, an env listing) can't spill passwords/tokens/keys into the
# transcript or an LLM prompt. Case-insensitive via bracket classes (portable —
# no GNU-only `I` flag). Best-effort, not a guarantee.
redact_secrets() {
    printf '%s' "$1" | sed -E \
        -e 's/(([Pp][Aa][Ss][Ss][Ww]?[A-Za-z_]*|[Ss][Ee][Cc][Rr][Ee][Tt][A-Za-z_]*|[Tt][Oo][Kk][Ee][Nn][A-Za-z_]*|[Aa][Pp][Ii][_-]?[Kk][Ee][Yy]|[Cc][Rr][Ee][Dd][A-Za-z_]*|[Pp][Rr][Ii][Vv][Aa][Tt][Ee][_-]?[Kk][Ee][Yy]|[Aa][Cc][Cc][Ee][Ss][Ss][_-]?[Kk][Ee][Yy]|[Rr][Ee][Qq][Uu][Ii][Rr][Ee][Pp][Aa][Ss][Ss]|[Mm][Aa][Ss][Tt][Ee][Rr][Aa][Uu][Tt][Hh]|[Aa][Uu][Tt][Hh][Oo][Rr][Ii][Zz][Aa][Tt][Ii][Oo][Nn]|[Cc][Ll][Ii][Ee][Nn][Tt][_-]?[Ss][Ee][Cc][Rr][Ee][Tt]|[Rr][Ee][Ff][Rr][Ee][Ss][Hh][_-]?[Tt][Oo][Kk][Ee][Nn]|[Aa][Cc][Cc][Ee][Ss][Ss][_-]?[Tt][Oo][Kk][Ee][Nn]|[Ss][Ee][Ss][Ss][Ii][Oo][Nn][_-]?[Kk][Ee][Yy]|[Cc][Oo][Nn][Nn][Ee][Cc][Tt][Ii][Oo][Nn][_-]?[Ss][Tt][Rr][Ii][Nn][Gg])[[:space:]]*[:=][[:space:]]*)[^[:space:]].*/\1[REDACTED]/g' \
        -e 's/([Bb][Ee][Aa][Rr][Ee][Rr][[:space:]]+)[A-Za-z0-9._~+\/-]+=*/\1[REDACTED]/g'
}
