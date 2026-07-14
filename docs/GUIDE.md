# Yantra Coding Agent — Developer Guide

**A deterministic-first coding toolbox for multi-language orgs, delivered as one MCP server.**

This guide is for developers who inherited many projects across many languages
and want one tool to manage all of them — from a trivial `read` to a full CI
pipeline — driven by any MCP host (Claude Desktop, an Ollama-driving CLI, your
own client).

> **Driving Yantra from an LLM/agent?** The concise
> **[Agent Operating Guide](AGENT_GUIDE.md)** is the single page to read.
> For exact tool arguments, see the reference at [cli/](cli/).

---

## Table of contents

1. [What Yantra is](#1-what-yantra-is)
2. [Install & connect (5 minutes)](#2-install--connect-5-minutes)
3. [How it works: tools, workflows, consent](#3-how-it-works-tools-workflows-consent)
4. [The default tools & discovery](#4-the-default-tools--discovery)
5. [Tool categories](#5-tool-categories)
6. [Workflows — deterministic, zero-token actions](#6-workflows--deterministic-zero-token-actions)
7. [Language support](#7-language-support)
8. [Safety model](#8-safety-model)
9. [Configuration & LLM endpoints](#9-configuration--llm-endpoints)
10. [Troubleshooting](#10-troubleshooting)
11. [Cheat sheet](#11-cheat-sheet)

---

## 1. What Yantra is

A **single Bash script** (modular under `harness/`) that runs as a **Model
Context Protocol server** over stdio. It gives a host:

- **~609 tools** — atomic actions (read a file, list containers, run a query).
- **~113 workflows** — scripted chains (format → lint → build → test in one call).
- **10 languages** — Node.js, Python, Rust, Go, C/C++, Java, Kotlin, Scala, Ruby, PHP.
- **DevOps** — Docker, Kubernetes, Helm, PostgreSQL/MySQL/Redis, SSH, networking, perf, security.

**Philosophy — deterministic-first.** If a task can be done without a model, it
is: git, test, build, format, lint, search, security scans, and DevOps reads are
all pure and free. Only the 26 `*_llm_*` diagnostic tools call a model, and only
when you invoke them. A small model can call `docker_list_containers {"target":"stopped"}`
where it could never compose `docker ps --filter status=exited` — that
conversion of failure into success is the product.

**What Yantra is *not*.** It doesn't own the conversation or the reasoning loop —
the MCP host does. Yantra is the tool server: schemas, validation, consent,
discovery, plans, budgets, and single-shot LLM diagnostics.

---

## 2. Install & connect (5 minutes)

### Prerequisites

- **Bash 5.3+** (`bash --version`) — macOS: `brew install bash`; Linux: your distro's 5.3+ package.
- **curl, sqlite3, jq** — the only required deps. macOS: `brew install curl sqlite jq`; Debian/Ubuntu: `apt install curl sqlite3 jq`.

Everything else is optional and installed on demand — see [DEPENDENCIES.md](DEPENDENCIES.md).

### Connect it to a host

Point your MCP host at the script. For Claude Desktop (`claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "yantra": {
      "command": "bash",
      "args": ["/path/to/yantra-mcp-server.sh", "--project", "/path/to/your/repo"]
    }
  }
}
```

Launch flags:

| Flag | Effect |
|------|--------|
| *(none)* | Run the MCP server on stdio (the default) |
| `--project DIR` | Serve this project directory (default: cwd) |
| `-y`, `--yes` | Pre-consent writes-class tools for the whole session |
| `--enable CAT` | Enable a tool category at boot (repeatable) |
| `--version`, `--help` | Print version / options |

### Verify it works

Any MCP client can drive it; the raw protocol is just newline-delimited JSON on
stdio:

```bash
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"probe","version":"1"}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"wf__harness_doctor","arguments":{}}}' \
  '{"jsonrpc":"2.0","method":"notifications/exit"}' \
  | bash yantra-mcp-server.sh -y
```

`wf__harness_doctor` checks every known dependency (~65) and, at startup, the
project scan recommends which tool categories are worth enabling for *this* repo.

---

## 3. How it works: tools, workflows, consent

Everything is invoked with **`tools/call`** over MCP:

```json
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"read","arguments":{"path":"README.md"}}}
```

- A **tool** `name` is used verbatim: `read`, `git_log`, `docker_list_containers`, `pg_slow_queries`.
- A **workflow** is a tool named **`wf__<id>`** — dots become underscores:
  `git.quicksave` → `wf__git_quicksave`, `pipeline.ci` → `wf__pipeline_ci`.
- The result comes back as text (`result.content[0].text`); an oversized result
  comes back as a short preview plus a `resource_link` you fetch on demand.

**Consent.** A read-only call just runs. A **writes/destructive** call raises an
MCP `elicitation/create` question the host answers; a host without elicitation
gets an instructive deny message, unless the server was launched with `-y`. This
fail-closed gate is server-side and authoritative — never assume a write went
through without seeing a success result.

---

## 4. The default tools & discovery

To keep a small model's context small, only the **6 core tools** plus **3
discovery meta-tools** are on the wire by default:

| Tool | Does | Consent |
|------|------|---------|
| `read` | Read a file | no |
| `write` | Create/overwrite a file | **yes** |
| `edit` | Replace a string in a file | **yes** |
| `bash` | Run a shell command | **yes** |
| `browse` | Fetch a URL (SSRF-guarded) | no |
| `batch` | Run several tool calls in one request | **yes** |

Reach the other ~685 tools without flooding context:

| Meta-tool | Use |
|-----------|-----|
| `search_tools {"query":"list docker containers"}` | The best-matching tools **with their schemas** |
| `describe_tool {"name":"pg_slow_queries"}` | One tool's full schema + effective complexity |
| `enable_category {"category":"docker"}` | Expose a whole category for the session (emits `tools/list_changed`) |

You can also enable categories at boot with `--enable docker` or persist them in
`yantra.config.json` (`tools.enabled`).

---

## 5. Tool categories

Only `core` is on by default. The full catalog (one page per category, with
exact arguments) is in [cli/](cli/); here's the map:

| Category | What's inside |
|----------|---------------|
| `core` | read, write, edit, bash, browse, batch (always on) |
| `fs` | grep/replace, todos, tree, dirsize, dups, disk, sync, find, checksum, tar/gzip, encrypt/decrypt |
| `ssh` | exec, scp, remote tail/journal/disk/ps, tunnel, sshfs mount (injection-safe) |
| `docker` | ps/logs/stats/inspect/build/run + LLM diagnose/review/audit |
| `kubernetes` | pods/describe/logs/events/nodes/svc + LLM diagnose/manifest-review/audit |
| `helm` | list/status/history/values/lint/template + LLM chart review |
| `pg` / `mysql` / `redis` | per-engine client tools: query/describe/indexes/slow/… |
| `perf` | cpu, mem, io, net, top-procs, load, strace, perf-record |
| `net` | dns, trace, scan, sockets, free-port |
| `sec` | secrets, iac, semgrep, container-scan, sbom, osv, dep-audit, kube-bench |
| `quality` | complexity, deadcode, dup, shell/dockerfile/yaml/json lint, loc, churn |
| `ci` | GitHub Actions runs/logs/failed/lint + LLM failure diagnosis |
| `doc` | pdf/docx extract/convert/ocr/merge/split + LLM summarize/README |
| `data` | DuckDB SQL over CSV/Parquet: schema/query/join/convert + LLM insights |
| `media` | ffmpeg probe/trim/convert/resize/transcribe/strip-metadata |
| `opencv` | computer vision: edges/compare/count/read_qr/detect_faces/document_scan |
| `cua` | computer use: screenshot/ocr + move/click/type/key/scroll/drag (per-OS backends) |
| `ytdl` | YouTube & media download (yt-dlp): info/formats/search + download/audio/subtitles |
| `kg` | code knowledge graph: build/symbol/refs/neighbors/parse |
| `ollama` | drive local models: pull/run/ps/embed/chat |
| `localdb` | scratch SQLite workspace, isolated from harness internals |
| `monitor` | inspect the harness's own runtime (events/tasks/…, WHERE-filterable) |
| `s3` | upload/download/list/delete/head (S3-compatible) |
| `brew` | Homebrew install/upgrade/services (macOS/Linux) |
| `nodejs` `python` `rust` `golang` `ccpp` `java` `kotlin` `scala` `ruby` `php` | per-language toolchains |

Language categories auto-enable when Yantra detects that language in the project.

---

## 6. Workflows — deterministic, zero-token actions

Workflows chain tools into one action. Call them as `wf__<id>`. The 20 most useful:

| Workflow `name` | What it does |
|-----------------|-------------|
| `wf__git_quicksave` | Add + commit + push in one step |
| `wf__git_sync` | Fetch + rebase + push |
| `wf__git_undo` | Undo last commit (soft reset, keeps changes) |
| `wf__git_pr` | Push + create PR via `gh` |
| `wf__test_run` | Run tests (auto-detects the framework) |
| `wf__test_coverage` | Run tests with coverage |
| `wf__build_run` | Build the project |
| `wf__fmt_all` | Format all files |
| `wf__lint_fix` | Auto-fix lint issues |
| `wf__pipeline_ci` | Format + lint + build + test in sequence |
| `wf__deps_install` | Install dependencies |
| `wf__deps_audit` | Security-audit dependencies |
| `wf__refactor_rename-symbol` | AST-aware rename across the codebase (`ast-grep`) |
| `wf__project_onboard` | Inherit a repo: structure + how-to-build + TODOs + scan |
| `wf__project_overview` | Project structure + LOC |
| `wf__sec_pipeline` | Full security scan (secrets + IaC + semgrep) |
| `wf__harness_doctor` | Check all dependencies |
| `wf__tools_status` | Show tool-category status |
| `wf__net_diagnose` | DNS → TCP → TLS → HTTP in one call |
| `wf__test_flaky` | Run the suite N times to expose flakiness |

Workflows detect the project's toolchain automatically — `wf__test_run` finds
jest / pytest / cargo test / go test without being told.

---

## 7. Language support

Yantra detects the language from marker files (`package.json`, `Cargo.toml`,
`go.mod`, `pyproject.toml`, …) and auto-enables that toolchain. Each language
category wraps the ecosystem's real tools behind uniform names — e.g. `rust`
gives `rust_cargo_test`, `rust_clippy`, `rust_fmt`; `nodejs` gives `npm`/`tsc`
plus the Rust-based `oxlint`/`biome`/`swc` (detected Rust-first). The generic
`wf__lint_check` / `wf__fmt_all` / `wf__test_run` / `wf__build_run` workflows
dispatch to whichever toolchain the project uses, so you rarely need the
language-specific tool directly. Full lists: [cli/](cli/) (one page per language).

---

## 8. Safety model

- **Path guard.** File operations are confined to the project directory; a path
  outside it (including `../` escapes and symlinks) is refused. Model files are
  additionally readable from model dirs (`~/.ollama`, `~/models`).
- **Consent gate.** Every writes/destructive/dangerous call is fail-closed:
  elicitation over MCP, or an instructive deny, unless launched with `-y`.
  Server-side and authoritative — tool annotations are only advisory hints.
- **No secrets on the wire.** `HARNESS_API_TOKEN` and provider tokens are
  redacted from logs and events, and travel to `curl` via header files (never on
  argv, invisible to `ps`) — enforced by a regression test.
- **Injection-safe SSH.** Remote commands go over stdin (`ssh host 'bash -s'`),
  never interpolated into a shell string.
- **SSRF-guarded `browse`.** Loopback, link-local, private ranges, and cloud
  metadata endpoints are refused.
- **Trust model.** Running a project's own build *executes the project* — that's
  by design, not a sandbox escape. See `SECURITY.md` for the full model.

---

## 9. Configuration & LLM endpoints

`yantra.config.json` is the single source of truth. The full reference —
schema, the three provider tiers, tiered "big model for reasoning, local for the
rest" setups, high-availability, and every environment variable — is in
**[CONFIGURATION.md](CONFIGURATION.md)**. The essentials:

- LLM endpoints power only Yantra's `*_llm_*` diagnostic tools. A host that
  grants MCP *sampling* needs no provider config at all.
- The simplest setup is one env var: `HARNESS_LLM_URL=http://localhost:11434/v1`.
- Enable categories at boot in `tools.enabled`; runtime `enable_category` changes
  are session-only (edit the file to persist).

---

## 10. Troubleshooting

| Symptom | Fix |
|---------|-----|
| **"Bash 5.3+ required"** | Install bash 5.3+ (`brew install bash`) and launch with it; macOS `/bin/bash` is 3.2. |
| **A tool errors "tool category disabled"** | `enable_category {"category":"<cat>"}`, or launch with `--enable <cat>`, or add it to `tools.enabled`. |
| **`*_llm_*` tool says "LLM unavailable"** | No provider configured and the host granted no sampling — set `HARNESS_LLM_URL` or a `providers` block (see CONFIGURATION.md). |
| **Unknown tool `wf__…`** | Check the mangling: dots become underscores (`git.quicksave` → `wf__git_quicksave`). |
| **A write "didn't happen"** | It was consent-denied. Approve the elicitation, or launch with `-y`. |
| **Session ends unexpectedly** | Update to the latest — a fixed class of bug let a stdin-reading tool drain the frame stream; the guard is now in place. |

---

## 11. Cheat sheet

```jsonc
// initialize (once per session)
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"you","version":"1"}}}

// discover, then act
{"method":"tools/call","params":{"name":"search_tools","arguments":{"query":"slow postgres queries"}}}
{"method":"tools/call","params":{"name":"enable_category","arguments":{"category":"pg"}}}   // needs consent
{"method":"tools/call","params":{"name":"pg_slow_queries","arguments":{}}}

// core file ops
{"method":"tools/call","params":{"name":"read","arguments":{"path":"src/app.py"}}}
{"method":"tools/call","params":{"name":"edit","arguments":{"path":"src/app.py","old_string":"a - b","new_string":"a + b"}}}   // needs consent

// workflows (wf__<id>)
{"method":"tools/call","params":{"name":"wf__pipeline_ci","arguments":{}}}
{"method":"tools/call","params":{"name":"wf__git_quicksave","arguments":{"message":"wip"}}}   // needs consent

// resources & prompts
{"method":"resources/read","params":{"uri":"plan://current"}}
{"method":"resources/read","params":{"uri":"doc://cli/git"}}
{"method":"prompts/get","params":{"name":"grounding","arguments":{"goal":"fix the failing test"}}}
```

---

_See also: [AGENT_GUIDE.md](AGENT_GUIDE.md) (LLM operating guide) ·
[cli/](cli/) (full reference) · [CONFIGURATION.md](CONFIGURATION.md) ·
[ARCHITECTURE.md](ARCHITECTURE.md) · [EXAMPLES.md](EXAMPLES.md)._
