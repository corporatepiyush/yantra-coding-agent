<div align="center">

# यन्त्र · Yantra Coding Agent

### The coding agent that does the mechanical 90% for **zero tokens** — and saves the LLM for what actually needs a brain.

**615 built-in tools · 113 deterministic workflows · 10 languages · any LLM (or none)**
Pure Bash. Four tiny deps. Clone and run — on macOS, Linux, FreeBSD, or Windows (WSL).

[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)
![Bash 5.3+](https://img.shields.io/badge/bash-5.3%2B-4EAA25?logo=gnubash&logoColor=white)
![Tests](https://img.shields.io/badge/tests-61%20suites%20passing-brightgreen)
![Runtime deps](https://img.shields.io/badge/runtime%20deps-4-orange)
![No telemetry](https://img.shields.io/badge/telemetry-none-success)

*No daemon. No cloud account. No install step. It's a script — and it outships platforms.*

</div>

---

## The insight

Most AI coding agents bill you tokens to run `git commit`. To run `npm test`.
To grep a file. To list your Kubernetes pods. Every mechanical action becomes a
round-trip to a language model — slow, non-deterministic, and metered.

**Yantra flips that.** The boring, mechanical, *deterministic* work — building,
testing, linting, formatting, git, dependency audits, secret scans, SQL queries,
container diagnostics, log analysis — is done **natively, in Bash, for zero
tokens**. The LLM is reserved for the one thing it's uniquely good at: reasoning.

```
you ──► Yantra ──► deterministic workflow / tool  (free, instant, repeatable)
                 ╰─► LLM  (tokens)  ── only when the task genuinely needs to think
```

The result: a coding agent that is **cheaper, faster, more predictable, and
dramatically more capable out of the box** — because 589 deterministic tools (out of 615)
never touch a model at all; only 26 are LLM-backed diagnostic tools.

---

## Why teams choose Yantra

| When you ask for… | A typical AI agent | Yantra |
|---|---|---|
| "run the tests" | plans a shell call through the LLM — tokens, latency | `wf:test run` — deterministic, **0 tokens**, auto-detects the framework |
| "commit & push" | LLM round-trip | `wf:git quicksave` — **0 tokens** |
| DevOps / DB / security ops | shell improvisation or bolt-on plugins | **615 first-class tools** built in |
| "why is this pod crashing?" | dumps raw logs at you | gathers evidence, redacts secrets, returns **root cause + fix** |
| which model? | usually one vendor, one endpoint | **any** OpenAI-compatible endpoint · local models · tiered routing · HA failover · **or no LLM at all** |
| runtime footprint | Node/Python stack, a daemon, a cloud account | **pure Bash + curl + sqlite3 + jq** — clone and run |
| default blast radius | broad tool access | **5 tools on**; everything else opt-in, path-guarded, confirmed |

No lock-in. No daemon. No telemetry. No cloud account. It's a script.

---

## What you get

<div align="center">

| 🧰 **615** | ⚡ **113** | 🗣️ **10** | 🧠 **26** | 🔒 **61** |
|:---:|:---:|:---:|:---:|:---:|
| built-in tools | zero-token workflows | languages, deeply | LLM diagnostic tools | test suites |

</div>

- **589 deterministic tools** across 39 categories — DevOps, databases,
  security, data, cloud, docs, media, computer vision (OpenCV), computer use
  (screen/mouse/keyboard), media download (yt-dlp), performance, git,
  text/encoding — that run with **no LLM**.
- **26 LLM-backed diagnostic tools** — "senior engineer on tap": diagnose a
  CrashLoopBackOff, review a Dockerfile, explain a failing CI run, find the
  insight in a dataset.
- **113 workflows** that chain tools into one-word actions: `git.quicksave`,
  `pipeline.ci`, `sec.pipeline`, `project.onboard`, `net.diagnose`,
  `test.flaky`, `git.rescue`.
- **229 language-specific tools** — not just `build`/`test`, but `clippy`,
  `miri`, `flamegraph`, `pprof`, `govulncheck`, `bandit`, `py-spy`, ASan/TSan,
  `oxlint`, `biome`, `swc`, and more, per language.
- **A code knowledge graph**, a content-aware project scanner, and a dependency
  doctor — all in ~13K lines of Bash, behind one MCP stdio surface.

---

## Highlights

- **A pure MCP server** — Yantra IS a Model Context Protocol server over stdio (the only surface): `tools/list` with advisory danger annotations, `tools/call` (argument validation + consent via elicitation, deny-with-explanation fallback), workflows as `wf__<id>` tools, `resources/*`, the `grounding` prompt, logging notifications. Point Claude Desktop or an Ollama-driving MCP host at `yantra-mcp-server.sh` and every tool is available behind fail-closed safety gates.
- **Tool discovery for small models** — hundreds of tools won't fit a small context, so the default wire set stays ~6 core tools + meta-tools. `search_tools {query}` finds tools by intent and returns their schemas; `describe_tool {name}` gives one tool's full schema; `enable_category {name}` exposes a category on demand (and emits `tools/list_changed` over MCP).
- **Plan store, server-side** — `plan_create` / `plan_status` / `plan_step_done` keep a plan in SQLite; while a plan is active, every tool result is decorated with the current step (`PLAN: step N of M — …`) so the plan survives long sessions on any host. Exposed as the `plan://current` MCP resource.
- **Result budgets + resource links** — oversized tool output spills to a file and returns a short preview plus an MCP `resource_link` (fetch the bulk only if needed) instead of flooding a small context window. A silent-context-truncation detector warns when an engine quietly drops your prompt (the classic Ollama `num_ctx` trap).
- **Capability profiles** — Yantra probes each LLM endpoint for context size and `response_format` support (a `probe:false` provider is *never* contacted — no surprise bills) and records what the connected MCP host supports (sampling / elicitation); `doctor` prints both.
- **Git as first-class tools** — `git_log`, pickaxe search, file history, ahead/behind — token-bounded views instead of raw shell.
- **Rust-based JS toolchain** — `oxlint`, `biome`, and `swc` are detected from your project (Rust-first: biome > oxlint > eslint) and wired into `lint.check`/`fmt.all` automatically. No `npx` auto-downloading unpinned registry code — ever.
- **`net.diagnose`** — DNS → TCP → TLS → HTTP in one call. *"Is it down or is it me?"* answered in two seconds.
- **`test.flaky`** — runs your suite N times and tells you `stable-pass`, `stable-fail`, or `FLAKY`. Before CI tells you the hard way.
- **Parallel project scanner** — detection probes run concurrently at boot; engine-specific database detection (no more "enable pg *and* mysql *and* redis" for one migrations dir).
- **Hardened by default** — credentials never touch `curl` argv (enforced by a regression test), protocol-pinned redirects, SSRF guards, stall detection on transfers, path guards on worktrees. **Benchmarked: 50 parallel agents, zero lock errors** (pre-MCP-only CLI benchmark; re-run pending).

---

## 60-second quick start

```bash
git clone https://github.com/corporatepiyush/yantra-coding-agent.git
cd yantra-coding-agent

# Interactive — no install, no config, no API key required
bash yantra-mcp-server.sh

# Or fire a single workflow and exit
bash yantra-mcp-server.sh --workflow project.onboard --auto-confirm
```

On first launch Yantra scans your repo and tells you **exactly which
capabilities are worth turning on for this project** — with a copy-paste command
for each. No LLM key? It runs anyway: every deterministic tool and workflow
works without one.

---

## How you talk to it — one prefix, four destinations

Every line you type is routed by a prefix. This is the whole mental model:

| You type… | Goes to… | Cost |
|---|---|---|
| `wf:<name>` | a deterministic workflow | **free** |
| `tl:<name> [json]` | one tool, run directly | **free** (LLM tools are `mid`/`high`) |
| `cmd:<name>` | a built-in (help, list, tools, scan, config) | free |
| *(no prefix)* | **the LLM** — chat, reasoning, agentic edits | tokens |

Names are forgiving — `tl:k8s events` ≡ `tl:k8s_events`, `wf:git
quicksave` ≡ `wf:git.quicksave`. You always know whether an action costs
tokens, because *you* chose the lane.

```bash
yantra> wf:pipeline ci                       # build + test + lint + format — free
yantra> tl:pg slow                               # top slow queries — free
yantra> tl:sec sbom {"path":"."}                 # software bill of materials — free
yantra> why is the auth middleware rejecting valid tokens?   # ← the LLM earns its keep
```

---

## Usage (MCP over stdio — the only surface)

Yantra is a pure MCP server. The CLI subcommands, interactive REPL, and NDJSON
machine mode were removed (owner amendment); every removed call maps
to an MCP replacement.

    bash yantra-mcp-server.sh              # MCP server on stdio (default)
    bash yantra-mcp-server.sh -y           # writes pre-consented for the session
    bash yantra-mcp-server.sh --enable git # a category enabled at boot
    bash yantra-mcp-server.sh --help       # options + removed-surface map

Claude Desktop config:

    { "mcpServers": { "yantra": {
        "command": "bash",
        "args": ["/path/to/yantra-mcp-server.sh", "--project", "/path/to/repo"] } } }

- Tools run via `tools/call`; workflows are tools named `wf__<id>` (`wf__git_quicksave` → `git.quicksave`).
- Consent: writes-class calls raise an `elicitation/create` question; hosts without elicitation get an instructive deny unless the server was launched with `-y`.
- Discovery: `search_tools {query}` → schemas of the best matches; `enable_category {name}` exposes more (emits `tools/list_changed`).

See **[docs/cli/](docs/cli/)** (one page per category) for every call and its exact arguments.

### New categories
- **`git`** — read-only git introspection as first-class tools: `git_log`/`git_diff`/`git_show`, pickaxe `git_search_history` (*"who introduced this string?"*), `git_file_history`, `git_remotes` with ahead/behind.
- **`ollama`** — drive and maintain local LLMs where the tool earns its place: one-shot `ollama_run`, `ollama_model_info`/`ollama_notebook` inspection, `ollama_embed` + RAG (`ollama_rag_index`/`ollama_rag_query`), `ollama_extract` (structured output), `ollama_chat`/`ollama_api_generate` with option merging, and `serve_status`/`version`/`disk_usage`/`logs`. (Plain `list`/`pull`/`ps` are one `bash` call.)
- **`localdb`** — a scratch SQLite database (`.yantra-scratch.db`, kept separate from harness internals) for quick heuristic work: `tables`/`schema`/`create`/`drop`/`insert`/`query`/`update`/`delete`/`import`/`export`/`exec`/`vacuum`/`reset`.
- **`cua`** — a computer-use driver that SEEs the screen (`screenshot`/`ocr`, `screen_size`, `cursor_position`, `list_windows`/`active_window`) and DRIVEs it (`move`/`click`/`type`/`press_key`/`scroll`/`drag`, plus `cua_find_text` to locate and click on-screen text by OCR). Backends are chosen per OS — macOS `screencapture`+`cliclick`, X11 `xdotool`+`scrot`/`maim`, Wayland `grim`+`wtype`/`ydotool` — and `cua_doctor` reports what's present plus the macOS Accessibility/Screen-Recording and Wayland uinput requirements. Capture and input are consent-gated.
- **`ytdl`** — a YouTube (and 1000+ sites) media downloader via `yt-dlp`: read `info`/`search`, then `download`/`audio`/`subtitles`/`transcript`. URLs are http(s)-only and SSRF-checked, output is confined to `downloads/`, playlists are capped, and every fetch is consent-gated.

---

## The toolbox — an entire ops platform, built in

Only `core` (read/write/edit/bash/browse/batch) is on by default. Enable any
domain in one line — `cmd:tools enable <category>` — or persist it in
`yantra.config.json`.

**🚢 Ship & operate**
`docker` · `kubernetes` · `helm` · `ci` — logs/inspect/build/exec + a one-call
`container.overview`, describe/logs/events + scale/rollout/apply and a
`k8s.overview` triage, chart lint/template, CI failing logs. Plus LLM triage:
*"why is my container crashing?"*

**🗄️ Databases** — `pg` · `mysql` · `redis`
Query, describe, indexes, sizes, slow-query analysis, EXPLAIN, activity/locks,
backups — ~12 focused tools per engine, connection from env, nothing to install
in your app.

**🔐 Security & supply chain** — `sec` · `quality`
Secret scanning, IaC checks, SAST (semgrep), **SBOM generation**, **OSV /
dependency CVE audits**, container image scans, CIS kube-bench, dead-code and
complexity analysis, shell/YAML/JSON/Dockerfile linting.

**📊 Data & documents** — `data` · `doc` · `media`
Run SQL on CSV/Parquet/Arrow with DuckDB (no import step), or `data.diff` two
exports. Extract/convert/OCR PDFs, `doc.save_article`, `doc.scan-to-pdf`. Probe,
trim, transcode, transcribe, watermark, strip-metadata media — plus task-level
`media.podcast` / `media.clip` / `media.hardsub` / `media.audiobook` pipelines
for the photographers, editors, and podcasters too.

**☁️ Remote & cloud** — `ssh` · `s3` · `net` · `perf` · `monitor`
Injection-safe remote exec, sshfs mounts, S3 upload/download/list, DNS/trace/
port tools, CPU/mem/IO/strace profiling, agent metrics with a safe SQL `WHERE`.

**🕸️ Code intelligence** — `kg`
A real knowledge graph of your codebase — symbols, files, references, neighbors
— built from source by a bundled multi-language parser (no ctags/tree-sitter
dependency): `wf:kg build` for the whole project, or `tl:kg parse` to
get one file's symbols/imports as JSON for your own store. Queryable by you or
the LLM (substring symbol search is a trigram-indexed lookup).

**🔤 Git introspection** — `git`
Read-only git as first-class tools (log/diff/show, pickaxe *"who introduced this
string?"*, per-file history, remotes with ahead/behind). Mutating git stays in
the `git.*` workflows behind confirmation gates. (Plain status/branches are one
`bash` call — that's what the always-on `bash` tool is for.)

**🧑‍💻 Ollama / Local LLM & packaging** — `ollama` · `brew` · `fs`
Drive local Ollama models, inspect model files/notebooks, embeddings + RAG,
structured extract; bootstrap and install via Homebrew (gated);
tree/dedup/archive/encrypt/search/replace across the filesystem.

> Every tool **returns text and never emits protocol noise**, so they compose:
> `batch` fans out many calls in one turn, workflows invoke tools, and workflows
> call other workflows — all behind the same safety gates.

---

## A senior engineer, on tap

Two dozen tools go one step past "run a command" — they gather the evidence, redact
your secrets, and hand the LLM exactly what it needs to give a **root-cause
answer**, not a wall of logs:

| Ask… | Tool | What comes back |
|---|---|---|
| *"Why is pod api-7c9 stuck pending?"* | `k8s_llm_diagnose_pod` | the actual reason + the fix |
| *"Why does this container keep restarting?"* | `docker_llm_diagnose` | logs + inspect → root cause |
| *"Why did CI fail?"* | `ci_llm_diagnose` | failing step, exact line, fix, flaky-or-not |
| *"Review this Dockerfile / manifest / Helm chart"* | `*_llm_*_review` | best-practice findings |
| *"What's in this dataset?"* | `data_llm_insights` | quality issues + the SQL to run next |
| *"Summarize this spec / draft a README"* | `doc_llm_*` | key points, action items, a real README |

A junior engineer gets senior-level triage. A senior engineer gets their time
back.

---

## Deep language mastery — not a thin wrapper

Auto-detected per project. **229 language-specific tools** that reach for the
*right* professional tool, not just the generic one:

| Language | Tools | Highlights beyond build/test |
|---|:---:|---|
| Node.js/TS | 31 | tsc, **the Rust toolchain: `oxlint`, `biome`, `swc`**, eslint/prettier, vitest/jest, playwright, npm/pnpm/yarn/bun |
| Go | 30 | `pprof` cpu/mem, trace, `govulncheck`, fuzz, race, staticcheck, gofumpt, outdated, entry points |
| Rust | 26 | `clippy`, `miri`, `flamegraph`, `nextest`, cargo-audit/udeps/bloat/expand, ASan/TSan, MSRV, publish dry-run |
| Java | 26 | maven + gradle, spotbugs, JFR/jstack profiling, jps, dependency updates |
| Python | 26 | ruff, mypy/pyright, `py-spy`, cProfile, tracemalloc, bandit, hypothesis |
| C/C++ | 21 | cmake/make, clang-tidy/format, valgrind, ASan/UBSan/TSan |
| PHP · Ruby · Scala · Kotlin | 11–19 each | phpstan/psalm, brakeman, scalafix, detekt |

---

## Bring your own brain — or no brain at all

Point Yantra at **any OpenAI-compatible endpoint**, and route by cost:

- **Tiered by complexity** — send deep reasoning to a big model, the many small
  LLM-backed tool calls to a cheap or **local** one. `think` / `build` / `tool`
  tiers, all configurable.
- **High availability** — list redundant URLs per tier; Yantra sticks to one for
  prompt-cache warmth and **fails over only on network unreachability**, never on
  an HTTP error.
- **Local-first friendly** — Ollama, vLLM, LM Studio, anything speaking the
  standard API.
- **Zero-LLM mode** — configure nothing and every deterministic tool and workflow
  still works. Yantra tells you what's unavailable and how to turn it on.

```json
{ "providers": {
  "think": [{ "url": "https://api.openai.com/v1", "model": "gpt-5.1", "token_env": "OPENAI_API_KEY" }],
  "build": [{ "url": "http://localhost:11434/v1", "model": "qwen3-coder" }],
  "tool":  [{ "url": "http://localhost:11434/v1", "model": "qwen3-coder" }]
} }
```

Full reference: **[docs/CONFIGURATION.md](docs/CONFIGURATION.md)**.

---

## Safe by default — built for real repos

- **5 tools on out of the box.** Everything else is opt-in, so the LLM's context
  stays small (fewer tokens) and its reach stays bounded.
- **Path guards** confine file ops to the project directory.
- **Confirmations** on every write/destructive action (auto-confirm is explicit).
- **Secret redaction** — API tokens are stripped from logs, events, and every
  payload sent to a model.
- **Injection-safe SSH** — remote commands travel over stdin, never interpolated
  into a shell string.
- **Input sanitization at every boundary** — protocol input, config values, and
  tool arguments are cleaned before they reach a shell, SQL, or a URL.
- **Hardened HTTP** — every web-facing `curl` pins protocols on request *and*
  redirect (no `file://` downgrades), bounds redirects and response sizes,
  detects stalled transfers, and never carries a credential on argv (tokens
  travel via header files, invisible to `ps` — enforced by a regression test).
- **SSRF-guarded `browse`** — loopback, link-local, private ranges, and cloud
  metadata endpoints are refused outright.

---

## Runs anywhere. Embeds in anything.

- **Tiny footprint** — `bash 5.3 + curl + sqlite3 + jq`. No Node, no Python
  runtime, no daemon. Missing optional tools auto-install via Homebrew on request
  and degrade gracefully otherwise.
- **One protocol** — JSON-RPC 2.0 over stdio (MCP), for hosts, CI, scripts, and
  other programs alike:

```bash
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"ci","version":"1"}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"wf__pipeline_ci","arguments":{}}}' \
  '{"jsonrpc":"2.0","method":"notifications/exit"}' \
  | bash yantra-mcp-server.sh -y
```

Works over SSH, inside containers, in air-gapped environments, and in your CI —
because it's just a script that reads stdin and writes stdout.

---

## Real-world, in a few lines

```bash
# Inherit an unfamiliar repo and know it in seconds
wf:project onboard        # structure · how to build · TODO roadmap · what to enable

# Pre-push gauntlet, zero tokens
wf:pipeline ci            # build + test + lint + format

# Production incident triage
cmd:tools enable kubernetes
Why is the checkout-service pod restarting?     # ← evidence-gathered root cause

# Security & supply-chain audit
wf:sec pipeline           # secrets + IaC + SAST
tl:sec sbom {"path":"."}      # SBOM
tl:sec osv {"path":"."}       # CVE cross-check

# Understand a data drop without loading it into anything
cmd:tools enable data
tl:data query {"file":"events.parquet","query":"SELECT status, COUNT(*) FROM this GROUP BY status"}
```

More: **[docs/EXAMPLES.md](docs/EXAMPLES.md)** — 12 end-to-end playbooks.

---

## Supported languages

| Language | Build | Test | Lint | Format | Profiling | Security |
|----------|-------|------|------|--------|-----------|----------|
| Node.js/TS | `npm run build`/`swc` | `npm test` | `oxlint`/`biome`/`eslint` | `biome`/`prettier` | — | `npm audit` |
| Python | `python -m build` | `pytest` | `ruff` | `ruff format` | `cProfile`/`py-spy` | `bandit`/`pip-audit` |
| Rust | `cargo build` | `cargo test` | `clippy` | `cargo fmt` | `flamegraph`/`miri` | `cargo audit` |
| Go | `go build` | `go test` | `go vet` | `gofmt` | `pprof`/`trace` | `govulncheck` |
| C/C++ | `make`/`cmake` | `ctest` | `clang-tidy` | `clang-format` | `perf`/`valgrind` | ASan/UBSan/TSan |
| Java | `mvn`/`gradle` | `mvn test`/`gradle test` | `checkstyle` | `spotless` | `JFR`/`jstack` | `spotbugs` |
| Kotlin | `gradle build` | `gradle test` | `ktlint`/`detekt` | `ktlint -F` | — | — |
| Scala | `sbt compile` | `sbt test` | `scalafix` | `scalafmt` | — | `scoverage` |
| Ruby | `rake` | `rspec` | `rubocop` | `rubocop -a` | — | `brakeman`/`bundle-audit` |
| PHP | `composer` | `phpunit`/`pest` | `phpcs` | `php-cs-fixer` | — | `phpstan`/`psalm` |

---

## Install & prerequisites

Four small core deps; everything else is optional and auto-detected.

| Dep | Floor | Install |
|-----|-------|---------|
| bash | 5.3 | `brew install bash` (macOS) / build from source |
| curl | 8.0 | `brew install curl` / `apt install curl` |
| sqlite3 | 3.40 | `brew install sqlite` / `apt install sqlite3` |
| jq | 1.7 | `brew install jq` / `apt install jq` |

Type `cmd:install-deps` (or run `doctor.install`) and Yantra installs the
rest for you via Homebrew — installing Homebrew itself first if needed.
**Windows:** run inside [WSL](https://learn.microsoft.com/windows/wsl/install).
Full list with latest recommended versions: **[docs/DEPENDENCIES.md](docs/DEPENDENCIES.md)**.

---

## Under the hood

```
yantra-mcp-server.sh          # Entry point (Bash 5.3 gate, sources the harness)
harness/
  main.sh · register.sh         # Orchestrator + module registration
  lib/     (22 modules)         # Pure-Bash utilities: strings, arrays, json, sql, paths…
  core/    (20 modules)         # dispatch, config, providers, doctor, scanner, kg, llm, db…
  tools/                        # 6 core + 30+ categories (26 LLM-backed)
  langs/   (10 modules)         # 229 language-specific tools
  workflows/  (31 modules)      # 113 deterministic workflows (one file per namespace)
  commands/                     # the MCP server (JSON-RPC over stdio)
tests/                          # 61 test suites
docs/                           # GUIDE · EXAMPLES · CONFIGURATION · DEPENDENCIES · ARCHITECTURE
```

Pure Bash 5.3 — no Python, no Node. No-fork hot paths, WAL SQLite for runtime
state, `yantra.config.json` as the single source of truth. See
**[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)**.

---

## Documentation

- **[docs/AGENT_GUIDE.md](docs/AGENT_GUIDE.md)** — Single-page operating guide for an LLM driving Yantra over MCP (links [docs/cli/](docs/cli/)); hand this to any model
- **[docs/cli/](docs/cli/)** — Full call reference: one page per category, every call + arguments (served over MCP as `doc://cli/<page>`)
- **[docs/GUIDE.md](docs/GUIDE.md)** — Novice → advanced, 16 sections + cheat sheet
- **[docs/EXAMPLES.md](docs/EXAMPLES.md)** — 12 end-to-end playbooks (incident, release, media, security)
- **[docs/CONFIGURATION.md](docs/CONFIGURATION.md)** — `yantra.config.json` + LLM endpoints
- **[docs/DEPENDENCIES.md](docs/DEPENDENCIES.md)** — Core + optional deps, latest versions
- **[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)** — How it all fits together

---

## License

Licensed under the [Apache License, Version 2.0](LICENSE).

<div align="center">

**Yantra** (यन्त्र) — Sanskrit for *machine*, *instrument*, *that which
harnesses*. A device that channels raw force into precise, repeatable work.
Named on purpose.

</div>
</content>
