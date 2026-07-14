# Yantra Coding Agent — Architecture

Yantra is a **pure MCP server**: a single Bash process that speaks JSON-RPC 2.0
over stdio, exposing ~614 tools and ~113 workflows to any Model Context Protocol
host. The host owns the conversation and the reasoning loop; Yantra owns the
tools, their schemas, validation, consent gating, discovery, plans, budgets, and
the single-shot `*_llm_*` diagnostic calls.

## Overview

```
   MCP host  ◄───── JSON-RPC 2.0 over stdio ─────►  yantra-mcp-server.sh
 (Claude Desktop,        tools/call, tools/list,        (one process per host)
  Ollama-driving CLI,    resources/*, prompts/*,                │
  …owns the loop)        elicitation, sampling                  ▼
                                            ┌───────────────────────────────┐
                                            │   commands/mcp.sh  (the loop)  │
                                            └───────────────┬───────────────┘
                                      routes each request to:
                        ┌───────────────────────┼───────────────────────┐
                        ▼                        ▼                       ▼
              ┌───────────────────┐   ┌────────────────────┐  ┌───────────────────┐
              │  TOOL LAYER       │   │  WORKFLOW LAYER    │  │  RESOURCES/PROMPTS│
              │  614 tools,       │◄──│  113 workflows,    │  │  plan://current,  │
              │  category-gated,  │   │  chained tools,    │  │  spill://, doc://,│
              │  consent-gated    │   │  as wf__<id> tools │  │  grounding prompt │
              └─────────┬─────────┘   └─────────┬──────────┘  └───────────────────┘
                        └──── read/write ───────┴──── SQLite (.harness.db, WAL) ───┘
```

A tool call is a `tools/call`; a workflow is a tool named `wf__<id>`; both flow
through the same registry, validation, and consent gate. The 26 `*_llm_*` tools
additionally reach out to a configured provider (or request MCP *sampling* from
the host). Everything else is deterministic and needs no model.

## File structure

```
yantra-mcp-server.sh              # Entry point (sets YCA_DIR, parses launch flags, sources main.sh)
harness/
  main.sh                           # Orchestrator (sources all modules, defines main() → mcp_loop)
  register.sh                       # Sources tools/, langs/, workflows/ (registration)
  lib/                              # Pure utility functions (no deps on other harness code)
    constants.sh                    # Version, globals, config defaults, category definitions
    bash53.sh                       # Bash 5.3 requirement guard
    sanitize.sh                     # Untrusted-input sanitizers: sanitize_url/sql_safe_fragment/int_guard/...
    strings.sh arrays.sh hashmaps.sh numbers.sh   # str_*/arr_*/map_*/math_* pure-bash helpers
    paths.sh json.sh sql.sh io.sh files.sh        # path guard, jq wrappers, _sqlite/db_exec, io, file ops
    process.sh os.sh datetime.sh http.sh data.sh retry.sh   # procs, os detect, dates, curl, data, retry
    version.sh colors.sh logging.sh validate.sh   # semver, ANSI, logmsg, val_required/...
    (files are sourced alphabetically; constants.sh is sourced first explicitly)
  core/                             # Infrastructure (depends on lib/)
    db.sh                           # SQLite schema/init (events/skills/tasks/…); cat_init_defaults
    projectconfig.sh                # yantra.config.json load/merge (global+project), apply to runtime
    config.sh                       # Session-only config store (get/set); NOT persisted
    complexity.sh                   # Complexity taxonomy (high|mid|low) → tier (think|build|tool)
    providers.sh                    # Multi-provider LLM routing: sticky, fall-down, mark-dead, env override
    profiles.sh                     # T9 capability profiles: provider probing (metered-guarded) + host record
    budget.sh                       # T10 result budgets: spill-to-file, resource links, truncation detector
    kg.sh kg_symbols.awk kg_imports.awk   # Code knowledge graph builder + bundled 12-lang parser
    doctor.sh                       # Dependency manifest (~60 deps), check_one/all/report
    emit.sh                         # Frame emission (single point), emit_ok/fail/progress/error
    ui.sh                           # confirm_action/confirm_denied_msg (machine consent)
    tools.sh                        # Tool registry (+complexity), build_tools_json, tool_dispatch, _tool_exec
    workflows.sh                    # Workflow registry (+complexity), input hydration, run_workflow, wf_call
    scanner.sh                      # Startup project scan → recommends tool categories
    llm.sh                          # Provider-routed llm_analyze + the grounding prompt text
    startup.sh                      # llm_unavailable_flow (graceful "no provider" result)
    toolchain.sh                    # Detect language by marker files, build profile JSON
    skills.sh                       # Seed agent skills into DB (heredoc-embedded)
    update.sh heartbeat.sh cleanup.sh   # auto-update, background heartbeat, trap handler
  tools/                            # Tool implementations + registration (~30 categories)
    core.sh                         # 6 default: read, write, edit, bash, browse, batch
    discovery.sh                    # T11 meta-tools: search_tools, describe_tool, enable_category + intent facet
    plan.sh                         # T12 plan store: plan_create/status/step_done + result decoration
    fs.sh ssh.sh docker.sh kubernetes.sh helm.sh   # filesystem, remote, containers, clusters, charts
    pg.sh mysql.sh redis.sh perf.sh net.sh         # databases, profiling, network
    security.sh security_dns.sh quality.sh monitor.sh s3.sh kg.sh brew.sh
    ci.sh doc.sh data.sh media.sh opencv.sh ollama.sh localdb.sh text.sh
  langs/                            # Per-language tool calls + profile detection
    nodejs.sh python.sh rust.sh golang.sh ccpp.sh java.sh kotlin.sh scala.sh ruby.sh php.sh
  workflows/                        # Workflows (deterministic; exposed as wf__<id> tools)
    git.sh test.sh build.sh deps.sh fmt.sh lint.sh refactor.sh pipeline.sh
    scaffold.sh docs.sh project.sh harness.sh devops.sh secops.sh disk.sh tools.sh
  commands/
    mcp.sh                          # THE surface: JSON-RPC over stdio (initialize/tools/resources/prompts)
  docs/
    cli/                            # Per-category tool/workflow reference (generated; served as doc://cli/*)
    gen_cli_md.sh                   # Generator: rebuilds docs/cli/*.md from the live registries
```

## Sourcing order

```
yantra-mcp-server.sh
  └─ sets YCA_DIR, parses launch flags
  └─ source harness/main.sh
       ├─ source harness/lib/*.sh (constants.sh first, then alphabetical)
       ├─ _yca_bash_init + _yca_require_bash   (hard-reject Bash < 5.3)
       ├─ source harness/core/*.sh
       ├─ source harness/commands/mcp.sh       (defines the loop; never runs at source time)
       ├─ source harness/register.sh
       │    ├─ source harness/tools/*.sh    (registers tools)
       │    ├─ source harness/langs/*.sh    (registers language tools)
       │    └─ source harness/workflows/*.sh (registers workflows)
       ├─ cleanup_register_trap                (EXIT/INT/TERM/PIPE)
       └─ main() defined → runs mcp_loop
```

## Request lifecycle

The loop (`commands/mcp.sh` → `mcp_loop`) is a synchronous, blocking read: one
JSON-RPC line in, fully handled, response out, then the next line. There is no
event loop and no thread pool — concurrency across many agents comes from the
OS running one server process per host in parallel (stdio is 1:1).

```
tools/call {"name":"read", "arguments":{"path":"x"}}
  → mcp_tools_call
      → (writes-class?) _mcp_confirm → elicitation/create, else deny  [D5 consent]
      → tool_dispatch("read", args)
          → category gate → coerce_arguments → validate_args_against_schema  [T7]
          → _tool_exec: run the tool fn (stdin from /dev/null) → text
          → plan_decorate (append "PLAN: step N of M" if a plan is active)   [T12]
          → result_budget (oversized → spill to file)                        [T10]
      → oversized? → resource_link + inline preview; else inline text
  ← {"result":{"content":[{"type":"text","text":"…"}],"isError":false}}

tools/call {"name":"wf__pipeline_ci", "arguments":{}}
  → _mcp_run_workflow (in-process, stdin from /dev/null)
      → run_workflow → hydrate_inputs → wf_function (chains tools via tool_invoke/wf_call)
      → captures the workflow's emit() frames → last result becomes the MCP text
```

An `*_llm_*` tool additionally calls `llm_analyze` → `provider_resolve(tier)` →
`curl` (sticky URL, rotate on transport error), or — when the host granted it —
requests MCP *sampling*. With neither, it returns a graceful "LLM unavailable".

## Key design decisions

### Pure Bash 5.3 — no Python, no daemon
All utilities (strings, arrays, hashmaps, paths, JSON, SQL) are pure Bash. The
only external commands are `jq`, `sqlite3`, `curl`, `git`, and `rg`/`grep`. The
entry point hard-rejects Bash < 5.3 (a 3.2-safe guard, exit 3) *before* any
module is sourced, so the codebase uses 5.3 features unconditionally: no-fork
`${ …; }` substitution, `printf -v`, `mapfile`, `wait -n`, namerefs, `SRANDOM`,
`EPOCHREALTIME` (no `date` forks → no GNU-vs-BSD divergence). Guarded by
`test_bash_modernization.sh`.

### Category-gated tools (token neutrality)
Only the `core` tools plus the discovery meta-tools are on the wire by default
(~4 KB). Enabling a category (`enable_category`, `--enable`, or `tools.enabled`
in config) adds its schemas to `build_tools_json` (cached, byte-stable so the
host's list cache and any prompt cache stay warm). Small context windows pay the
catalog bill first, so the default wire size may not grow (Decision D6).

### Discovery over a huge catalog (T11)
614 tools cannot be handed to a small model. One ranked search backend
(`discovery_search`, typo-tolerant, over names + T6 descriptions) powers three
meta-tools: `search_tools` (returns matching schemas), `describe_tool` (one
tool's full schema + effective complexity), and `enable_category` (exposes a
category and emits `tools/list_changed`). Every tool/workflow also carries an
`intent` facet (discovery|verify|transform|execute) derived from its danger
level.

### Consent via elicitation, fail-closed (D5)
A writes/destructive/dangerous call raises an `elicitation/create` question when
the host advertised the capability; decline, timeout, garbage, or EOF all deny.
A host without elicitation gets the same instructive deny message as unconsented
machine mode, unless the server was launched with `-y`. Tool *annotations*
(`readOnlyHint`/`destructiveHint`) are advisory metadata; the server-side gate
in `tool_dispatch` is authoritative.

### Result budgets + resource links (T10)
The server can't know the host model's context window, so a tool result over
`YCA_RESULT_CAP` (default 8 KB) is written to a per-session spill file and
returned as an MCP `resource_link` plus a short inline preview — the host fetches
the bulk only if it needs it. Spill files outlive the call (the host may resolve
the link later) and are GC'd by age at boot. UTF-8 truncation never cuts a
codepoint; binary/NUL output is descriptored, never dumped raw into a JSON-RPC
line. For Yantra's own `*_llm_*` calls, a silent-truncation detector compares
sent tokens vs the reported `prompt_tokens` and warns on the classic Ollama
`num_ctx` trap.

### Plan store, server-side (T12)
`plan_create`/`plan_status`/`plan_step_done` keep a plan in SQLite. While a plan
is active, `plan_decorate` appends exactly one `PLAN: step N of M — <text>` line
to every host-facing result — so plan durability works on any host, even one
that never touches the plan tools. The decoration is computed at encode time and
is never persisted. The current plan is also exposed as the `plan://current` MCP
resource.

### Capability profiles (T9)
Two kinds, both facts not assumptions. A **provider profile** records each
`*_llm_*` endpoint's context window, `response_format` support, vision, and a
`metered` flag — a provider with `probe:false` is *never* contacted (no surprise
bills). A **host record** captures what the connected MCP host supports
(sampling / elicitation / roots) from the handshake, and drives every fallback.

### Composition seams (single responsibility)
Tools **return text** and never emit protocol frames, so they embed anywhere.
Three composition mechanisms: the `batch` core tool (fan-out, gated),
`tool_invoke` (workflow→tool, gate-bypassing), and `wf_call` (workflow→workflow
as a step, child frames suppressed via a temporary `YCA_OUT_FD` sink so the
parent emits exactly one result). `tool_dispatch` and `tool_invoke` share the
one `_tool_exec` core — where every tool runs with **stdin redirected from
/dev/null**, so no tool (or a subprocess it spawns, e.g. `git shortlog` with no
range) can drain the JSON-RPC frame stream. `_mcp_run_workflow` applies the same
`</dev/null` guard.

### Input sanitization at every boundary (`lib/sanitize.sh`)
Untrusted text — tool arguments, config values, resource URIs — passes through a
sanitizer before it reaches a shell, SQL, or a URL. `sanitize_url` enforces
http(s) with no shell metacharacters or leading `-`; `sql_safe_fragment` allows
a monitor `WHERE` only as a single read-only filter (no `;`, comments, or
DML/DDL); `int_guard` keeps LIMIT/OFFSET numeric; the path guard uses trailing-
slash prefix matching (`target == dir || target == dir/*`) so `/project-evil`
never matches `/project`. Guarded by `test_sanitize.sh` (with fuzz).

### One SQLite connection choke point (`lib/sql.sh` `_sqlite`)
`journal_mode=WAL` is persisted in the file, but `busy_timeout` is
*per-connection* — an ad-hoc `sqlite3 "$db" …` defaults to 0 ms and fails
instantly the moment a parallel sub-agent holds the write lock. Every connection
(internal `.harness.db` via `db_exec`, the kg build session, monitor/readonly
queries, the plan store, and the scratch db) routes through `_sqlite`, which
sets the timeout via the silent `.timeout` dot-command (not `PRAGMA
busy_timeout=N`, which would echo into query output). Net effect under N
concurrent agents: WAL gives 1 writer + N readers; busy_timeout makes writers
wait instead of erroring — verified at 16-way concurrency (128/128 + 160/160
writes land, zero lock errors). Guarded by `test_sqlite_concurrency.sh`.

### Scratch SQLite datastore, isolated (`tools/localdb.sh`)
A third datastore for ad-hoc user/LLM work (create tables, DML, query), strictly
separate from the config file and the internal DB. It lives in its own file
(`.yantra-scratch.db`, override `HARNESS_SCRATCH_DB`); the
`scratchdb_exec/query/readonly` seam only ever references `_localdb_path`, never
`YCA_DB_PATH` — the isolation `test_localdb.sh` asserts. Category `localdb`, off
by default.

### Real code knowledge graph (`core/kg.sh`)
`kg_build` populates `kg_nodes`/`kg_edges` from a bundled, owned awk parser
(`kg_symbols.awk` + `kg_imports.awk`) — one process for the whole tree,
dispatched by extension, comment-aware, covering 12 languages, under `LC_ALL=C`
so a binary file never aborts the scan. The build is bulk and streaming (TSV →
SQLite `.import` into TEMP staging → `INSERT … SELECT` in one transaction). The
tables are `STRICT` with a trigram FTS5 index so `kg_find_symbol` does an indexed
substring lookup instead of a `LIKE '%…%'` scan. (C# is intentionally
unsupported — its declaration syntax changes almost every release.)

### Two datastores + config, clear split
- **`yantra.config.json`** is the single source of truth for *configuration*
  (providers, enabled categories, complexity overrides, safety/update/log).
  Global + project files, project wins; env/launch flags override for the
  session but are never written back.
- **SQLite (WAL)** holds *runtime state* only: skills, events, heartbeats,
  tasks, messages, changes, versions, the plan store, the knowledge graph.
- The scratch SQLite (above) is a third, opt-in store, isolated from both.

### Sticky, network-only provider rotation
A tier keeps using its highest-priority URL for remote prompt-cache affinity and
rotates to the next only on a curl **transport** failure (DNS/refused/timeout),
never on an HTTP error code. If a whole tier is dead, requests fall down
(think→build→tool) to any reachable provider. Complexity `low` never needs one.

### Safe SSH, incremental VACUUM, honest dispatch
Remote commands go over stdin (`printf '%s' "$cmd" | ssh host 'bash -s'`), never
interpolated into a shell argument. Cleanup uses `PRAGMA incremental_vacuum`
(not full `VACUUM`) to avoid an exclusive lock that would block concurrent
instances. `tool_dispatch` captures combined stdout+stderr and **always** prints
it with the exit code, so a read tool's output is never silently swallowed.
