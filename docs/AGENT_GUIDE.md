# Yantra for LLMs — Agent Operating Guide

You are an LLM (small or large, purpose-built or multimodal) driving the **Yantra
Coding Agent**. Read this once and you have the whole picture: what Yantra is, how
to call it, how to find any capability, and the rules to follow. When you need the
exact arguments for a specific call, open the per-category pages under
**[docs/cli/](./cli/)** — one file per category, load only the one you need.

---

## 1. What Yantra is

A single command that wraps **hundreds of tools and workflows** across ~55
categories (files, git, docker, kubernetes, every major language toolchain,
databases, security, docs, media, ollama, …). It is **deterministic-first**: most
work is done by real tools (build, test, lint, grep, query) at **zero token cost**;
you only reason when a tool cannot. Two kinds of calls:

- **tool** — one atomic action (`read`, `pg slow`, `rust cargo_test`).
- **workflow** — a scripted multi-step routine (`pipeline.ci`, `git.quicksave`).

Each call has a **complexity tier**: `low` (pure tool, no LLM), `mid` (LLM-backed,
e.g. `*_llm_*` summarize/diagnose), `high` (the open reasoning loop). When a call is
LLM-backed, **you** may be the model it calls.

## 2. How to drive Yantra — it IS an MCP server

Yantra is a pure Model Context Protocol server over stdio (the CLI subcommand,
NDJSON, and REPL surfaces were removed — owner amendment in PLAN.md T8; the map
of every removed call to its replacement is docs/MIGRATION_MCP_ONLY.md).

```
yantra-mcp-server.sh              # MCP server on stdio (this is the default)
yantra-mcp-server.sh -y           # …with writes pre-consented for the session
yantra-mcp-server.sh --enable git # …with a tool category enabled at boot
```
Point an MCP host (Claude Desktop, an Ollama-driving CLI host) at that command. It
speaks JSON-RPC 2.0 over stdio:
| Method | Behavior |
|--------|----------|
| `initialize` | handshake (spec `2025-11-25`); records the host's `sampling`/`elicitation`/`roots` capabilities |
| `ping` | liveness — replies `{}` |
| `tools/list` | the default wire set (~6 core tools + the discovery meta-tools) with danger levels as advisory annotations (`readOnlyHint`/`destructiveHint`); enable the rest on demand |
| `tools/call` | runs a tool through the same validation + consent gate as the CLI; workflows are callable as `wf__<id>` (dots mangled, e.g. `wf__test_run` → `test.run`); a large result comes back as a short preview + a `resource_link`; tool stderr arrives as `notifications/message`, never inside the result |
| `resources/list` | enumerates `plan://current` and the `doc://cli/<page>` reference pages |
| `resources/read` | `plan://current` (the live plan), `spill://<id>` (a spilled large result), `doc://cli/<page>` (CLI reference) |
| `prompts/list` / `prompts/get` | the `grounding` prompt — anti-drift rules to append at the TAIL of context each turn (takes an optional `goal` argument) |

**Reaching the other 685 tools without flooding context:**
- `search_tools {query|intent}` → the best-matching tools *with their schemas*.
- `describe_tool {name}` → one tool's full schema.
- `enable_category {name}` → expose a category for the session (consent-gated; emits `tools/list_changed`).

**Consent on MCP:** a writes-class call triggers one `elicitation/create` question when
the host advertised the capability — decline, timeout, or a garbage answer all deny.
A host without elicitation gets the same instructive deny message as unconsented
NDJSON (fail-closed parity), unless the server was launched with consent. Never
assume a write went through.

**Staying on-plan:** call `plan_create {steps:[…]}`; while a plan is active every result
is tagged `PLAN: step N of M — …`, so you keep the plan even across a long session.

## 3. Finding the right call — start at [docs/cli/](./cli/)

The **[docs/cli/](./cli/)** folder is the full reference: an index
([docs/cli/README.md](./cli/README.md)) with every category, plus one page per
category listing each call, its required/optional fields, whether it writes, and
copy-paste examples. **Load only the category page you need** — do not read all of
them (each page is also served over MCP as `doc://cli/<page>`). You can also
enumerate at runtime with `search_tools` / `describe_tool`.

## 4. Safety rules (do not violate)

- `-y` / `auto_confirm` is **only** for calls marked *Writes? = yes*. Never add it to a
  read-only call.
- File operations are confined to the project directory (path guard). Model files are
  additionally readable from model dirs (`~/.ollama`, `~/models`, …).
- Destructive/outward-facing actions (delete, push, deploy) require confirmation —
  surface what will happen before doing it.

## 5. If you are an LLM-backed call (summarize / diagnose / review)

Some calls hand you extracted content with a task-specific header and expect a
faithful result. Follow the header exactly. Universal rules:
- Use **only** the content you were given. Never add outside knowledge or invent
  paths, APIs, numbers, names, or dates. Keep figures exact.
- If the input is truncated, garbled, or mostly boilerplate/paywall, **say so** — do
  not fabricate. Cite `file:line` for code claims and the URL/section for web claims.
- Prefer a deterministic tool over guessing: `test.run`, `lint.fix`, `pipeline.ci`,
  `ci_llm_diagnose`, `pg_explain`, `data_profile`, `doc_extract`, `media_probe`.

## 6. Notes for thinking & multimodal models

- **Thinking models**: your reasoning is separate from the answer. Give a generous
  output budget; a tight `num_predict` can leave the answer empty. Emit the final
  result plainly after thinking.
- **Multimodal models**: use `media_probe`/`media_*` for audio/video/image metadata
  and `doc_extract` before reading PDFs/DOCX. For a web page, prefer
  `doc llm_web_summarize <url>` (it fetches, strips page noise, and summarizes) over
  raw fetching.
- **Local models via Ollama**: `yantra ollama chat <model> --content "..."` accepts
  tunables — `temperature`, `top_k`, `min_p`, `num_ctx`, `num_predict`, `seed`, and
  `format` (a JSON schema) for structurally guaranteed output. Pin `temperature`
  around 0.2 for reliable tool-calling.

## 7. Offload cheap tasks to a local model — save the paid LLM for hard reasoning

A big paid model is expensive per token. Route the many small, well-scoped calls to a
free **local** model and reserve the paid one for open-ended `high`-tier reasoning.

**Recommended local model: `lfm2.5:8b-a1b-q8_0`** (LiquidAI LFM2.5, 8.5B MoE — fast on
consumer hardware, honest, reliable tool-calling). It comfortably handles the `tool`
and `build` tiers: summarization (`doc_llm_summarize`, `doc_llm_web_summarize`),
classification and extraction (use `format` for guaranteed JSON), commit messages,
log/CI diagnosis, routing, and quick math/lookups. Pull it once with
`yantra ollama pull lfm2.5:8b-a1b-q8_0`.

Point Yantra's tiers at it in `yantra.config.json` — paid model on `think`, local
`lfm2.5:8b-a1b-q8_0` on `build`/`tool` (see [docs/CONFIGURATION.md](./CONFIGURATION.md)):

```json
{ "providers": {
    "think": [{ "url": "https://api.openai.com/v1", "model": "gpt-5.1", "token_env": "OPENAI_API_KEY" }],
    "build": [{ "url": "http://localhost:11434/v1", "model": "lfm2.5:8b-a1b-q8_0" }],
    "tool":  [{ "url": "http://localhost:11434/v1", "model": "lfm2.5:8b-a1b-q8_0" }]
} }
```

Rule of thumb: if a task is extract / classify / summarize / format / diagnose from
given input, send it local; if it needs multi-step planning or deep judgment, use the
paid `think` tier. Constrain structured outputs with `format` rather than trusting the
prompt.

## 8. Operating loop (how to work)

1. Restate the task in one line if it is ambiguous; ask only if the choice is
   load-bearing and you cannot verify it.
2. Reach for the deterministic tool that already knows the answer before reasoning.
3. Read before you edit; make the smallest change; run the project's own test/build
   to verify — do not claim success without evidence.
4. Report plainly: what changed, what ran, what passed/failed. Ground every claim.

---

_Full per-category reference: **[docs/cli/](./cli/)**. Human walkthrough:
[docs/GUIDE.md](./GUIDE.md). Config & LLM endpoints: [docs/CONFIGURATION.md](./CONFIGURATION.md)._
