#!/usr/bin/env bash
# Generates the tool/workflow reference as ONE FILE PER CATEGORY under docs/cli/
# (plus an index docs/cli/README.md), so a reader/agent loads only the relevant
# category instead of one giant file. Regenerate with:  bash docs/gen_cli_md.sh
#
# Yantra is a pure MCP server, so every page is written for a host or an LLM
# driving it over JSON-RPC: each row gives the EXACT `name` to put in a
# `tools/call`, its required/optional arguments (with types and enum values),
# whether it needs consent, and whether it costs an LLM call. Every page ends
# with copy-paste `tools/call` JSON. Also served live over MCP as
# `doc://cli/<category>`.
set -uo pipefail
export YCA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$YCA_DIR/harness/main.sh" >/dev/null 2>&1

OUT_DIR="$YCA_DIR/docs/cli"
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

# ── Topic intros (the "why would I open this page" line) ─────────────────────
_topic_intro() {
    case "$1" in
        core)       printf 'The always-on basics: read/write/edit files, run shell commands, fetch a web page, and fan out many tool calls in one `batch`.' ;;
        git)        printf 'Read-only git introspection: history, diffs, show, "who introduced this string?" (pickaxe), per-file history, ahead/behind. Mutations (commit/push/branch) live in the `git.*` workflows below, behind consent. (Plain status/branches/contributors are one `bash` call — use that.)' ;;
        net)        printf 'Network triage from the shell: DNS, traceroute, port checks, TLS cert expiry, HTTP headers, and `net_fetch` (SSRF-vetted, fenced download of any URL to a file) — or run the `net.diagnose` workflow for the full DNS→TCP→TLS→HTTP sweep, or `net.watch` to be told when a page changes.' ;;
        fs)         printf 'Filesystem power tools: recursive grep/replace, TODO census, tree, duplicate finder, disk usage, archives (tar), encrypt/decrypt, plus batch move/copy/rename/organize/dedupe.' ;;
        docker)     printf 'Container operations: ps/logs/inspect/diff/health, build/run/exec/cp/push/restart/prune (gated) — plus LLM triage ("why is my container crashing?"). The `container.overview` workflow is a one-call ps+stats+health+reclaimable snapshot.' ;;
        kubernetes) printf 'Cluster operations: describe, logs, events, plus the curated diagnostics (pending pods, restart counts, node pressure, resource requests/limits, images) and gated write verbs (scale/rollout/apply/delete/exec). LLM pod diagnosis + manifest review. The `k8s.overview` workflow triages cluster health in one call.' ;;
        helm)       printf 'Helm chart operations: release status and values (secret-redacted), lint and template charts, gated upgrade/rollback/uninstall, LLM chart review.' ;;
        ci)         printf 'CI/CD introspection (GitHub Actions via gh): the failing-run log, workflow inventory and secret-reference audit, per-step durations, local workflow lint — plus LLM diagnosis of a red run.' ;;
        pg)         printf 'PostgreSQL client tools (connection from PG_CONN/env): tables, describe, indexes, sizes, slow queries, EXPLAIN, activity/locks, vacuum, backup.' ;;
        mysql)      printf 'MySQL/MariaDB client tools (connection from env): databases, tables, describe, indexes, processlist, slow log, EXPLAIN, status, backup.' ;;
        redis)      printf 'Redis inspection (connection from $REDIS_URL): info, non-blocking scan, type-aware get, ttl/type, clients, slowlog, credential-safe config, and a gated flushdb. (Single-key set/del/expire are one `bash` redis-cli call — use that.)' ;;
        sec)        printf 'Security scanning: secrets, dependency CVEs (OSV), SAST (semgrep), IaC checks, SBOM, container scans, kube-bench, SSH/permissions audits. The `sec.pipeline` workflow runs the lot.' ;;
        quality)    printf 'Code-quality analysis with no LLM: complexity, dead code, duplication, churn hotspots, LOC, long functions, TODO census, shell/YAML/JSON/Dockerfile linting.' ;;
        perf)       printf 'System and process profiling: CPU/memory/IO/network load, top processes, open files, strace/dtrace, benchmarks, binary size.' ;;
        doc)        printf 'Document handling: extract/convert PDFs and DOCX, OCR (incl. searchable-PDF), split/merge, compress, images↔PDF — plus LLM summarize/README/docstring and the `doc.save_article` / `doc.scan-to-pdf` workflows.' ;;
        data)       printf 'SQL over data files with DuckDB — CSV/Parquet/Arrow, no import step: query, schema, head, profile, join, convert — plus LLM insights.' ;;
        media)      printf 'Audio/video/image toolbox (ffmpeg-based): probe codecs first, then trim/convert/resize/concat/watermark/transcribe/strip-metadata.' ;;
        opencv)     printf 'Computer vision (OpenCV 4.13, via python3+cv2): QC (edges/compare/count/template_match), logistics & retail (read_qr/dominant_colors), security (detect_faces/motion/blur_faces), doc intake (document_scan/threshold), imaging (denoise), and capture (extract_frames/stitch). Run `opencv_doctor` first.' ;;
        cua)        printf 'Computer-use driver, two halves. PIXEL half: SEE the screen (screenshot/ocr, screen_size, cursor_position, list/active windows, find_text) and DRIVE it by coordinate (move/click/type/press_key/scroll/drag). ACCESSIBILITY half (the robust, pi-computer-use "act_ui" model): `cua_ui_snapshot` builds a structured element tree, `cua_act` acts on an element by its semantic identity (role+name) not pixels, and `cua_ui_diff` / `cua_ui_find` compute the minimal change-set / query the tree (pure JSON, cross-platform). Backends are per-OS — macOS screencapture+cliclick+System Events (AX), X11 xdotool+scrot/maim, Wayland grim+wtype/ydotool. Run `cua_doctor` first (it reports the macOS Accessibility/Screen-Recording and Wayland uinput requirements, and the a11y backend). Capture and input are consent-gated; a real loop runs the server with `-y`.' ;;
        ytdl)       printf 'YouTube (and 1000+ sites) media downloader via yt-dlp: read metadata (info/search) then download (download/audio/subtitles/transcript). URLs are http(s)-only and SSRF-checked, output is confined to `downloads/`, playlists are capped, and every download is consent-gated. Run `ytdl_doctor` first (needs yt-dlp; ffmpeg for audio/merges).' ;;
        ollama)     printf 'Drive local LLMs via Ollama: one-shot run, model-file/notebook inspection, embeddings + RAG (DuckDB vector store), chat/generate with option merging, structured extract, serve status/disk/logs. (Plain list/pull/ps/rm are one `bash` call — use that.)' ;;
        monitor)    printf "Inspect the harness's own runtime: events, tool calls, heartbeats, tasks, messages, timeline — filterable with a safe SQL WHERE fragment." ;;
        s3)         printf 'S3-compatible object storage (SigV4 via env creds): upload/download/list/delete/head.' ;;
        ssh)        printf 'Injection-safe remote operations: exec over stdin, scp both ways, tunnels, sshfs mounts, remote logs/ps/disk.' ;;
        brew)       printf 'Homebrew lifecycle with consent gates: ensure (bootstrap Homebrew itself), install/uninstall/upgrade/cleanup, and a status aggregate. (Plain list/search/info/outdated are one `bash` call — use that.)' ;;
        kg)         printf 'The code knowledge graph: build it once (`kg_build`), then query symbols, references, neighbors, and per-file structure. Substring search is trigram-indexed.' ;;
        localdb)    printf 'A scratch SQLite database (.yantra-scratch.db) for your own quick tables — separate from harness internals: create/insert/query/import/export.' ;;
        nodejs)     printf 'Node.js/TypeScript toolchain (npm/pnpm/yarn/bun auto-detected): install/audit/outdated, tsc, eslint/prettier AND the Rust-based tools (oxlint, biome, swc), vitest/jest, playwright.' ;;
        python)     printf 'Python toolchain: pytest, ruff/black/isort, mypy/pyright, pip-audit/bandit, cProfile/py-spy/tracemalloc, venv info.' ;;
        rust)       printf 'Rust toolchain: cargo build/test/clippy/fmt, nextest, miri, flamegraph, audit/outdated/udeps/bloat/expand, MSRV, publish dry-run.' ;;
        golang)     printf 'Go toolchain: build/test (race/fuzz/bench/cover), vet, staticcheck, golangci-lint, govulncheck, pprof cpu/mem, module graph.' ;;
        ccpp)       printf 'C/C++ toolchain: cmake/make/ninja/meson/bazel, ctest/googletest, clang-tidy/format, cppcheck, valgrind, ASan/MSan/TSan/UBSan, perf record.' ;;
        java)       printf 'Java toolchain: maven + gradle build/test/deps, checkstyle/pmd/spotbugs/errorprone, jacoco, JFR/jstack/jmap/jcmd profiling.' ;;
        kotlin)     printf 'Kotlin toolchain: gradle build/test/run, ktlint, detekt, coroutine debugging.' ;;
        scala)      printf 'Scala toolchain: sbt/mill compile/test/run, scalafmt, scalafix, wartremover, scoverage.' ;;
        ruby)       printf 'Ruby toolchain: bundler, rspec/minitest, rubocop/standardrb, brakeman, bundle-audit, reek.' ;;
        php)        printf 'PHP toolchain: composer install/audit/outdated, phpunit/pest, phpstan/psalm (incl. taint), phpcs/php-cs-fixer.' ;;
        build)      printf 'Generic project build workflows — the build command is auto-detected from the toolchain profile.' ;;
        container)  printf 'One-word container workflows (list/logs/stats/health) that work even when the docker tool category is toggled off.' ;;
        k8s)        printf 'One-word Kubernetes workflows (pods/logs/events/describe) that work even when the kubernetes tool category is toggled off.' ;;
        debug)      printf 'Failure triage: collects the recent evidence (git state, failing tests, logs) into one report.' ;;
        deps)       printf 'Dependency lifecycle: install, update, audit, license check, tree — and `deps.risk`: outdated + CVEs + loose version specs with a senior upgrade order.' ;;
        devops)     printf 'Cross-cutting ops checks: cron/systemd timers, Kubernetes manifest validation.' ;;
        disk)       printf 'Reclaim disk space: scan for caches/artifacts (incl. browser caches), then clean with heavy safeguards.' ;;
        doctor)     printf 'Dependency doctor: check every optional tool, report versions vs recommended minimums, and install what is missing via Homebrew.' ;;
        fmt)        printf 'Formatting workflows — formatter auto-detected per language (incl. biome/prettier for JS/TS): all files or only git-changed ones.' ;;
        harness)    printf "The harness's self-management: effective config, version history, cost accounting, DB backup, update check." ;;
        hygiene)    printf 'Repo housekeeping the way a senior keeps house: branch graveyard audit, tracked junk/.gitignore gaps, TODO debt ledger.' ;;
        lint)       printf 'Lint workflows — linter auto-detected per language (biome/oxlint/eslint for JS/TS, ruff, clippy, …): check or auto-fix.' ;;
        mentor)     printf 'Zero-LLM senior advice: checklists and explain-error playbooks for common failure classes.' ;;
        pipeline)   printf 'Composite quality gates: `pipeline.ci` = format + lint + build + test in one shot; preflight and fix variants.' ;;
        pr)         printf 'Pull-request preparation: branch state, diff summary, checklist — everything before you open the PR.' ;;
        project)    printf 'Project understanding: overview, full onboarding ("I just inherited this repo"), churn hotspots, changelog, init.' ;;
        refactor)   printf 'Mechanical refactors, e.g. renaming a function signature across the project.' ;;
        release)    printf 'Release engineering: preflight checks, notes generation, tag + push.' ;;
        rescue)     printf 'Lost-work first aid (also available as the `git.rescue` workflow).' ;;
        review)     printf 'Pre-commit review: self-review of the pending diff, risk assessment, precommit gate.' ;;
        scaffold)   printf 'Scaffold a new project skeleton for a chosen language.' ;;
        test)       printf 'Test workflows — runner auto-detected: run all, rerun failures, coverage, and `test.flaky` (run N times to expose flakiness).' ;;
        tools)      printf 'Toggle tool categories for the session (session-only; persist in yantra.config.json): list, status, enable, disable.' ;;
        *)          return 1 ;;
    esac
}

# ── Placeholder values for examples, derived from field name/type ────────────
_ph() {
    local name="$1" type="$2" enum="$3"
    [[ -n "$enum" ]] && { printf '%s' "${enum%%,*}"; return; }
    case "$name" in
        path|file|src)      printf 'README.md' ;;
        url)                printf 'https://example.com' ;;
        host|domain|target) printf 'example.com' ;;
        port)               printf '443' ;;
        pattern|query)      printf 'TODO' ;;
        sql)                printf 'SELECT 1' ;;
        command)            printf 'echo hi' ;;
        message)            printf 'wip' ;;
        container)          printf 'mycontainer' ;;
        pod)                printf 'mypod' ;;
        name)               printf 'NAME' ;;
        value)              printf 'hello' ;;
        key)                printf 'KEY' ;;
        count|lines)        printf '20' ;;
        days)               printf '7' ;;
        *) case "$type" in
               integer|number) printf '10' ;;
               boolean)        printf 'true' ;;
               *)              printf 'VALUE' ;;
           esac ;;
    esac
}

# _args_cell SCHEMA required|optional -> comma list "`field` (type)" for a table
# cell; the column header already says which set it is.
_args_cell() {
    local schema="$1" which="$2"
    printf '%s' "$schema" | jq -r --arg w "$which" '
        (.required // []) as $req
        | (.properties // {}) | to_entries
        | map(select( if $w=="required" then (.key as $k | $req | index($k) != null)
                      else (.key as $k | ($req | index($k)) == null) end ))
        | map("`" + .key + "` (" + (if .value.enum then (.value.enum|join("\\|")) else (.value.type // "string") end) + ")")
        | join(", ")' 2>/dev/null
}

# _args_json SCHEMA -> a valid arguments object filled from the REQUIRED fields
# (placeholder values), for a copy-paste tools/call example.
_args_json() {
    local schema="$1"
    local obj='{}' prop ptype penum
    while IFS=$'\t' read -r prop ptype penum; do
        [[ -z "$prop" ]] && continue
        local v; v=$(_ph "$prop" "$ptype" "$penum")
        case "$ptype" in
            integer|number|boolean) obj=$(jq -c --arg k "$prop" --argjson v "$v" '. + {($k):$v}' <<<"$obj" 2>/dev/null) ;;
            array)                  obj=$(jq -c --arg k "$prop" '. + {($k):["step one"]}' <<<"$obj" 2>/dev/null) ;;
            *)                      obj=$(jq -c --arg k "$prop" --arg v "$v" '. + {($k):$v}' <<<"$obj" 2>/dev/null) ;;
        esac
    done < <(printf '%s' "$schema" | jq -r '
        (.required // [])[] as $r | .properties[$r]
        | [$r, (.type // "string"), ((.enum // []) | join(","))] | @tsv' 2>/dev/null)
    printf '%s' "${obj:-\{\}}"
}

# ── Tables ───────────────────────────────────────────────────────────────────

# emit_tools_table CATEGORY -> the tools table. The `name` column is the EXACT
# string to put in tools/call.
emit_tools_table() {
    local category="$1" name info schema fn danger agents cat_check complexity
    printf '## Tools\n\n'
    printf 'Call with `tools/call` using the exact `name` below.\n\n'
    printf '| Tool `name` | Required args | Optional args | Consent | LLM |\n'
    printf '|-------------|---------------|---------------|---------|-----|\n'
    for name in $(printf '%s\n' ${TOOLS_BY_CAT[$category]} | sort); do
        info="${YCA_TOOL_REGISTRY[$name]}"
        schema="${YCA_TOOL_SCHEMAS[$name]}"
        IFS='|' read -r fn danger agents cat_check complexity <<< "$info"

        local required optional consent llm_col
        required=$(_args_cell "$schema" required); [[ -z "$required" ]] && required="—"
        optional=$(_args_cell "$schema" optional); [[ -z "$optional" ]] && optional="—"
        consent="no"; [[ "$danger" != "safe" ]] && consent="**yes**"
        llm_col="—"; [[ "$complexity" != "low" ]] && llm_col="$complexity"

        printf '| `%s` | %s | %s | %s | %s |\n' "$name" "$required" "$optional" "$consent" "$llm_col"
    done
    printf '\n'
}

# emit_wf_table NAMESPACE -> the workflows table. MCP name is wf__<id> with dots
# mangled to underscores.
emit_wf_table() {
    local namespace="$1" wf_id info fn tier danger needs desc complexity mangled consent needs_col
    printf '## Workflows\n\n'
    printf 'Workflows chain several tools into one action. Over MCP they are tools named `wf__<id>` (dots become underscores). Pass inputs in `arguments`.\n\n'
    printf '| Workflow `name` | Needs | Consent | What it does |\n'
    printf '|-----------------|-------|---------|-------------|\n'
    for wf_id in $(printf '%s\n' ${WF_BY_NS[$namespace]} | sort); do
        info="${YCA_WF_REGISTRY[$wf_id]}"
        IFS='|' read -r fn tier danger needs desc complexity <<< "$info"
        mangled="wf__${wf_id//./_}"
        consent="no"; [[ "$danger" != "safe" ]] && consent="**yes**"
        needs_col="—"; [[ -n "$needs" && "$needs" != "none" ]] && needs_col="$needs"
        desc="${desc//|/\\|}"
        printf '| `%s` | %s | %s | %s |\n' "$mangled" "$needs_col" "$consent" "$desc"
    done
    printf '\n'
}

# emit_examples TOPIC -> copy-paste tools/call JSON (the exact frames a host sends).
emit_examples() {
    local topic="$1" shown=0 name schema danger
    printf '## Examples\n\n'
    printf 'Each line is the `tools/call` request a host sends over stdio (the `jsonrpc`/`id` envelope is elided):\n\n'
    printf '```json\n'
    if [[ -n "${TOOLS_BY_CAT[$topic]:-}" ]]; then
        # Prefer instructive-but-valid calls: safe calls first, then those with
        # required fields (shows the argument shape) or parameterless tools.
        for name in $(for n in ${TOOLS_BY_CAT[$topic]}; do
                d="${YCA_TOOL_REGISTRY[$n]}"; IFS='|' read -r _ d _ _ _ <<< "$d"
                printf '%s\t%s\n' "$([[ "$d" == safe ]] && printf 0 || printf 1)" "$n"
              done | sort | cut -f2); do
            (( shown >= 5 )) && break
            schema="${YCA_TOOL_SCHEMAS[$name]}"
            local nreq nprops
            nreq=$(printf '%s' "$schema" | jq -r '(.required // [])|length' 2>/dev/null || printf 0)
            nprops=$(printf '%s' "$schema" | jq -r '(.properties // {})|length' 2>/dev/null || printf 0)
            [[ "$nreq" == "0" && "$nprops" != "0" ]] && continue
            danger="${YCA_TOOL_REGISTRY[$name]}"; IFS='|' read -r _ danger _ _ _ <<< "$danger"
            local args; args=$(_args_json "$schema")
            local note=""; [[ "$danger" != "safe" ]] && note='   // needs consent'
            printf '{"method":"tools/call","params":{"name":"%s","arguments":%s}}%s\n' "$name" "$args" "$note"
            ((shown++))
        done
    fi
    if [[ -n "${WF_BY_NS[$topic]:-}" ]]; then
        local wf_id mangled
        wf_id=$(printf '%s\n' ${WF_BY_NS[$topic]} | sort | head -1)
        mangled="wf__${wf_id//./_}"
        printf '{"method":"tools/call","params":{"name":"%s","arguments":{}}}\n' "$mangled"
    fi
    printf '```\n\n'
}

# ── Collect tools by category and workflows by namespace ─────────────────────
declare -A TOOLS_BY_CAT WF_BY_NS
for _name in "${!YCA_TOOL_REGISTRY[@]}"; do
    IFS='|' read -r _fn _danger _agents _category _cx <<< "${YCA_TOOL_REGISTRY[$_name]}"
    TOOLS_BY_CAT[$_category]+="$_name "
done
for _wf in "${!YCA_WF_REGISTRY[@]}"; do
    WF_BY_NS[${_wf%%.*}]+="$_wf "
done

mapfile -t TOPICS < <(printf '%s\n' "${!TOOLS_BY_CAT[@]}" "${!WF_BY_NS[@]}" | sort -u)

# ── One file per topic ───────────────────────────────────────────────────────
for topic in "${TOPICS[@]}"; do
    label="${YCA_CAT_LABEL[$topic]:-$topic}"
    intro=$(_topic_intro "$topic" || printf '')
    has_tools=""; [[ -n "${TOOLS_BY_CAT[$topic]:-}" ]] && has_tools=1
    {
        printf '# %s — %s\n\n' "$topic" "$label"
        [[ -n "$intro" ]] && printf '%s\n\n' "$intro"
        printf 'How to read this page:\n\n'
        printf -- '- **Tool `name`** is the exact string for `tools/call`; **Workflow `name`** is `wf__<id>`.\n'
        if [[ -n "$has_tools" ]]; then
            printf -- '- **Consent = yes** means the call changes state — over MCP it triggers an elicitation (or launch the server with `-y` to pre-approve). Consent = no calls are read-only.\n'
        else
            printf -- '- **Consent = yes** means the workflow changes state — over MCP it triggers an elicitation (or launch the server with `-y`).\n'
        fi
        printf -- '- **LLM = mid/high** means the call sends content to a configured language model; `—` calls are fully local and free.\n'
        printf -- '- If a call errors with "tool category disabled", enable it: `enable_category {"category":"%s"}` (or launch with `--enable %s`).\n\n' "$topic" "$topic"
        [[ -n "$has_tools" ]] && emit_tools_table "$topic"
        [[ -n "${WF_BY_NS[$topic]:-}" ]] && emit_wf_table "$topic"
        emit_examples "$topic"
        printf -- '_Generated by docs/gen_cli_md.sh from the live registries — do not edit by hand. Served over MCP as `doc://cli/%s`._\n' "$topic"
    } > "$OUT_DIR/$topic.md" 2>/dev/null
done

# ── Index ────────────────────────────────────────────────────────────────────
{
    cat <<'EOF'
# Yantra Tool & Workflow Reference

> **Driving Yantra?** It is a pure MCP server (JSON-RPC over stdio). Start with the
> single-page **[Agent Operating Guide](../AGENT_GUIDE.md)** for the whole picture,
> then open the per-category page below for exact `tools/call` arguments.

Every capability is either a **tool** (one atomic action) or a **workflow** (a
scripted chain of tools). Both are invoked the same way over MCP:

```json
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"<tool>","arguments":{ ... }}}
```

- A **tool** `name` is used verbatim (e.g. `read`, `git_log`, `docker_list_containers`).
- A **workflow** is a tool named `wf__<id>` — dots become underscores (`git.quicksave` → `wf__git_quicksave`).
- **Consent:** a state-changing call raises an `elicitation/create` question; a host without elicitation gets an instructive deny unless the server was launched with `-y`.
- **Discovery:** the default wire set is small (core + meta-tools). Reach the rest with `search_tools {"query":"…"}`, inspect one with `describe_tool {"name":"…"}`, or expose a whole category with `enable_category {"category":"…"}`.
- These pages are also served live over MCP as `doc://cli/<category>` (`resources/read`).

Load only the category you need:

| Category | Purpose | Tools | Workflows | Page |
|----------|---------|-------|-----------|------|
EOF
    for topic in "${TOPICS[@]}"; do
        label="${YCA_CAT_LABEL[$topic]:-$topic}"
        ntools=0; [[ -n "${TOOLS_BY_CAT[$topic]:-}" ]] && ntools=$(printf '%s\n' ${TOOLS_BY_CAT[$topic]} | grep -c .)
        nwf=0;    [[ -n "${WF_BY_NS[$topic]:-}" ]] && nwf=$(printf '%s\n' ${WF_BY_NS[$topic]} | grep -c .)
        printf '| **%s** | %s | %s | %s | [%s.md](%s.md) |\n' "$topic" "$label" "$ntools" "$nwf" "$topic" "$topic"
    done
    printf '\n_Generated by docs/gen_cli_md.sh from the live registries. Regenerate after adding tools/workflows._\n'
} > "$OUT_DIR/README.md" 2>/dev/null

printf 'Wrote %s topic files + README.md to %s\n' "${#TOPICS[@]}" "$OUT_DIR" >&2
