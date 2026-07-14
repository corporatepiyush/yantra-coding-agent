#!/usr/bin/env bash
# Test: knowledge-graph parser + build + query.
# Covers the owned awk parser (multi-language, incl. modern syntax), the SQLite
# build (STRICT tables + trigram FTS search), the kg_parse single-file tool,
# comment-awareness, and that C# is intentionally not parsed.
set -uo pipefail
HARNESS="$1"; TMP="$2"
cd "$TMP"; rm -f .harness.db; git init -q
export HARNESS_UPDATE_ENABLED=false HARNESS_CONFIG_GLOBAL="$TMP/none.json"
mkdir -p src

# Python: async def, def, class, PEP 695 `type` alias, + a decl inside a comment.
printf 'import os\nfrom sys import path\n\n# class GhostInComment must be ignored\nasync def fetch_it(u):\n    return u\n\ndef hello(name):\n    return name\n\nclass Greeter:\n    pass\ntype Alias = int\n' > src/app.py
# JS: function, class, import.
printf 'export function add(a,b){return a+b}\nimport { z } from "./z"\nclass Widget {}\n' > src/w.js
# Go: grouped `type ( … )` block (Server/ClientID) + func.
printf 'package p\nimport "net/http"\ntype (\n\tServer struct{ addr string }\n\tClientID int\n)\nfunc Serve(){}\n' > src/srv.go
# Java: record + sealed interface.
printf 'public record Point(int x, int y) {}\npublic sealed interface Shape {}\n' > src/P.java
# Kotlin: data class + enum class.
printf 'data class User(val id: Int)\nenum class Role { ADMIN }\n' > src/u.kt
# PHP: enum (8.1) + function + a `#` comment (must be ignored, unlike #[Attr]).
printf '<?php\n# class PhpGhost ignored\nenum Suit: string { case H = "h"; }\nfunction handle(){}\n' > src/x.php
# Scala 3: named given + case class.
printf 'given intOrd: Ordering[Int] = ???\ncase class Vec(x: Int)\n' > src/v.scala
# C#: MUST be ignored entirely (unsupported by design).
printf 'public class ShouldBeIgnored {}\npublic record struct Nope(int X);\n' > src/ignored.cs

cat > yantra.config.json <<'JSON'
{ "version":"1","providers":{"think":[],"build":[],"tool":[]},"tools":{"enabled":["core","kg"]} }
JSON
PROJ_ROOT="$(cd "$(dirname "$HARNESS")" && pwd)"
source "$PROJ_ROOT/tests/lib_mcp.sh"
q()   { sqlite3 .harness.db "$1"; }

# ── build populates the graph ───────────────────────────────────────────────
OUT=$(mcp_call "$HARNESS" kg_build) \
    || { echo "kg build failed"; echo "$OUT"; exit 1; }
echo "$OUT" | grep -qE "nodes, [0-9]+ edges" \
    || { echo "kg build did not report nodes/edges"; echo "$OUT"; exit 1; }
NODES=$(q "SELECT COUNT(*) FROM kg_nodes;")
[[ "${NODES:-0}" -ge 10 ]] || { echo "kg_nodes not populated (got $NODES)"; exit 1; }

# ── modern-syntax coverage across languages ─────────────────────────────────
# async def / PEP695 type / Go grouped-type block / Java record & sealed /
# Kotlin data & enum class / PHP enum / Scala named given.
for sym in fetch_it hello Greeter Alias add Widget Server ClientID Serve \
           Point Shape User Role Suit handle intOrd Vec; do
    c=$(q "SELECT COUNT(*) FROM kg_nodes WHERE name='$sym';")
    [[ "${c:-0}" -ge 1 ]] || { echo "parser missed symbol: $sym"; exit 1; }
done

# ── comment-awareness: declarations inside comments are NOT captured ─────────
for ghost in GhostInComment PhpGhost; do
    c=$(q "SELECT COUNT(*) FROM kg_nodes WHERE name='$ghost';")
    [[ "${c:-0}" -eq 0 ]] || { echo "comment declaration leaked as a symbol: $ghost"; exit 1; }
done

# ── C# is intentionally unsupported (no .cs symbols) ────────────────────────
c=$(q "SELECT COUNT(*) FROM kg_nodes WHERE name IN ('ShouldBeIgnored','Nope');")
[[ "${c:-0}" -eq 0 ]] || { echo "C# was parsed but should be ignored"; exit 1; }

# ── schema is STRICT (rejects a TEXT value in an INTEGER column) ─────────────
if sqlite3 .harness.db "INSERT INTO kg_nodes(kind,name,file,line) VALUES('x','y','z','notint');" 2>/dev/null; then
    echo "kg_nodes is not STRICT (accepted TEXT in INTEGER column)"; exit 1
fi

# ── trigram FTS: substring search (>=3 chars) is indexed, not a table scan ───
OUT=$(mcp_call "$HARNESS" kg_find_symbol '{"name":"reet"}')  # substring of "Greeter"
echo "$OUT" | grep -q "Greeter" \
    || { echo "FTS substring search failed for 'reet'"; echo "$OUT"; exit 1; }

# ── symbol lookup + import refs (regression) ────────────────────────────────
OUT=$(mcp_call "$HARNESS" kg_find_symbol '{"name":"hello"}')
echo "$OUT" | grep -q "src/app.py" \
    || { echo "kg symbol did not locate hello()"; echo "$OUT"; exit 1; }
OUT=$(mcp_call "$HARNESS" kg_references '{"name":"os"}')
echo "$OUT" | grep -q "src/app.py" \
    || { echo "kg refs did not find importer of os"; echo "$OUT"; exit 1; }

# ── kg_parse: single-file JSON, no persistence (bring-your-own KG store) ─────
OUT=$(mcp_call "$HARNESS" kg_parse '{"file":"src/srv.go"}')
echo "$OUT" | jq -e '(.symbols|map(.name)|index("Server"))' >/dev/null \
    || { echo "kg parse did not return Server from srv.go"; echo "$OUT"; exit 1; }
echo "$OUT" | jq -e '(.imports|index("net/http"))' >/dev/null \
    || { echo "kg parse did not return the net/http import"; echo "$OUT"; exit 1; }

# ── monitor still returns real rows ─────────────────────────────────────────
cat > yantra.config.json <<'JSON'
{ "version":"1","providers":{"think":[],"build":[],"tool":[]},"tools":{"enabled":["core","monitor"]} }
JSON
OUT=$(mcp_call "$HARNESS" monitor_kg_nodes '{"limit":"5"}')
echo "$OUT" | grep -q '"kind"' \
    || { echo "monitor_kg_nodes returned no rows"; echo "$OUT"; exit 1; }

rm -f yantra.config.json
echo "kg OK"
exit 0
