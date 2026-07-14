# Yantra Coding Agent — Configuration & LLM Endpoints

`yantra.config.json` is the **single source of truth** for configuration. This
document is the complete reference: where the file lives, its schema, and — most
importantly — **how to configure one or more LLM endpoints**.

Yantra is a pure MCP server, so "using" a setting means it takes effect when a
host launches the server. LLM endpoints here power only Yantra's own
single-shot `*_llm_*` diagnostic tools (summarize, diagnose, review) — the
host owns the main conversation and can supply completions via MCP *sampling*
instead, in which case no provider config is needed at all.

---

## 1. Where config lives

Two files, merged. The project file wins on every key.

| Scope   | Path                                                              | Purpose                          |
|---------|-------------------------------------------------------------------|----------------------------------|
| Global  | `$XDG_CONFIG_HOME/yantra/yantra.config.json` (or `~/.config/…`)   | Your defaults across all projects |
| Project | `<project>/yantra.config.json`                                    | Per-project overrides            |

**Precedence (highest wins):**

```
launch flag  >  env var  >  project file  >  global file  >  built-in default
```

- On first run in a project, a `yantra.config.json` is **created for you**, seeded
  with defaults. Edit it — the harness never rewrites it.
- **Runtime changes are session-only.** The `enable_category` tool or a
  `--enable <cat>` launch flag change live in memory and are *never* written
  back. To persist something, edit the file.
- A malformed file is ignored (with a warning), never fatal.

Override the file locations for testing/CI:

```bash
HARNESS_CONFIG=/path/to/project.json  HARNESS_CONFIG_GLOBAL=/path/to/global.json  bash yantra-mcp-server.sh
```

---

## 2. Full schema

```jsonc
{
  "version": "1",

  // ── LLM providers, grouped into three tiers (see §3) ──
  "providers": {
    "think": [ /* provider objects; highest complexity */ ],
    "build": [ /* provider objects; medium complexity  */ ],
    "tool":  [ /* provider objects; low complexity      */ ]
  },

  "routing": {
    "sticky": true,        // reuse one URL per tier for remote prompt-cache affinity
    "fallback": "down"     // if a tier has no live URL, fall to lower tiers
  },

  "tools": {
    "enabled": ["core", "docker", "pg", "fs"],  // categories on at startup
    "complexity_overrides": {                    // pin a tool/workflow's complexity
      "k8s_llm_troubleshoot": "high",
      "git.quicksave": "low"
    }
  },

  "safety": { "confirm_destructive": true },
  "update": { "enabled": true, "branch": "main" },
  "log":    { "level": "info" }
}
```

A **provider object**:

```jsonc
{
  "url":       "http://localhost:11434/v1",  // required; OpenAI-compatible base URL
  "model":     "qwen3-coder",                 // optional; falls back to the global default
  "token":     "sk-...",                      // optional; inline bearer token
  "token_env": "OPENAI_API_KEY",              // optional; read the token from this env var
  "priority":  10                             // optional; higher = preferred within the tier
}
```

Token resolution order: `token` → value of `token_env` → global `HARNESS_API_TOKEN`.

---

## 3. LLM endpoints — the important part

### 3.1 The three tiers

Every tool and workflow has a **complexity**, which selects a provider tier:

| Complexity | Tier    | Used by                                             |
|------------|---------|-----------------------------------------------------|
| `high`     | `think` | The heaviest `*_llm_*` diagnostics (deep review/analysis) |
| `mid`      | `build` | The everyday LLM-backed tools & workflows (`*_llm_*`) |
| `low`      | `tool`  | Static tools & workflows — **never call an LLM**     |

(The open-ended reasoning loop that once used the `think` tier now lives in the
MCP host, per the MCP-only design — see [AGENT_GUIDE.md](AGENT_GUIDE.md).)

So you can point deep reasoning at a big (expensive) model and route the many
smaller LLM-backed tool calls at a cheaper/local model — without touching code.

### 3.2 The simplest setup — one endpoint via env

No file editing needed. `HARNESS_LLM_URL` becomes the sole provider in **all**
tiers (and wins over the file):

```bash
export HARNESS_LLM_URL="http://localhost:11434/v1"   # e.g. ollama
export HARNESS_API_TOKEN="ollama"                     # any non-empty string for local
export HARNESS_LLM_MODEL="qwen3-coder"
bash yantra-mcp-server.sh
```

### 3.3 One endpoint via the config file

```json
{
  "providers": {
    "think": [{ "url": "http://localhost:11434/v1", "model": "qwen3-coder" }],
    "build": [{ "url": "http://localhost:11434/v1", "model": "qwen3-coder" }],
    "tool":  [{ "url": "http://localhost:11434/v1", "model": "qwen3-coder" }]
  }
}
```

### 3.4 Tiered — big model for reasoning, local for the rest

Offload the many cheap `build`/`tool` calls (summarize, classify, extract, diagnose,
format) to a **free local model** and keep the paid model only for `think`-tier
reasoning. Recommended local model: **`lfm2.5:8b-a1b-q8_0`** (LiquidAI LFM2.5, 8.5B
MoE — fast, reliable tool-calling). Pull once with `ollama pull lfm2.5:8b-a1b-q8_0` (or via the `bash` tool).

```json
{
  "providers": {
    "think": [{ "url": "https://api.openai.com/v1", "model": "gpt-5.1", "token_env": "OPENAI_API_KEY" }],
    "build": [{ "url": "http://localhost:11434/v1", "model": "lfm2.5:8b-a1b-q8_0" }],
    "tool":  [{ "url": "http://localhost:11434/v1", "model": "lfm2.5:8b-a1b-q8_0" }]
  }
}
```

### 3.5 Redundant endpoints (high availability)

List several URLs in a tier. The harness uses the **highest-priority one** and
sticks to it (so the remote prompt cache stays warm). It only rotates to the next
URL when the current one is **not network-reachable** (DNS failure, connection
refused, timeout) — never on an HTTP error code.

```json
{
  "providers": {
    "think": [
      { "url": "https://llm-primary.internal/v1",  "model": "big", "priority": 20 },
      { "url": "https://llm-secondary.internal/v1", "model": "big", "priority": 10 }
    ]
  }
}
```

### 3.6 Fallback across tiers

If a call's own tier has **no live URL**, it falls **down** the tiers
(`think → build → tool`) to the first reachable provider. A `high` request can
therefore still complete on the `build` or `tool` endpoint if `think` is down;
a `low` request only ever uses the `tool` tier (and never needs one at all).

---

## 4. Running with **no** LLM endpoint

Perfectly supported, and common — a host that grants MCP *sampling* needs no
provider config at all. With no provider configured **and** no sampling:

- Every **low-complexity** tool and workflow still works (build, test, lint,
  format, git, k8s reads, security scans, data queries, …) — the bulk of Yantra.
- A **mid/high** (`*_llm_*`) tool call returns a graceful "LLM unavailable"
  result explaining how to add a provider — never a crash or a hang.

---

## 5. Complexity overrides

Pin any tool or workflow to a different tier via
`tools.complexity_overrides` (keyed by the bare tool/workflow id):

```json
{ "tools": { "complexity_overrides": {
    "docker_llm_security_audit": "high",   // send this to the big model
    "data_llm_insights": "low"             // ...or force it off the LLM entirely
} } }
```

Overrides win over the registered complexity and are reflected in the
`describe_tool` output.

---

## 6. Tool categories

Only `core` is on by default. Turn categories on at startup with
`tools.enabled`, with a `--enable <cat>` launch flag, or at runtime
(session-only) with the `enable_category` tool.

```json
{ "tools": { "enabled": ["core", "docker", "pg", "fs", "kg"] } }
```

Databases are split into `pg` / `mysql` / `redis`; search + file ops are the `fs`
category; `kg` is the code knowledge graph. Language categories (`python`,
`rust`, `nodejs`, …) are real too, but you rarely list them here — they
auto-enable when Yantra detects that language in the project. Use `search_tools`
to discover what exists, and [cli/README.md](cli/README.md) for the full catalog.

---

## 7. Environment variables for runtime control

These environment variables configure or override behavior at startup (not
persisted in config files):

| Variable | Default | Purpose |
|----------|---------|---------|
| `HARNESS_SCRATCH_DB` | `<project>/.yantra-scratch.db` | Path to the localdb scratch SQLite file, kept separate from harness internals |
| `HARNESS_SQLITE_BUSY_TIMEOUT` | `10000` | Per-connection SQLite busy_timeout in milliseconds; concurrent sub-agents wait instead of erroring |
| `OLLAMA_HOST` | `http://localhost:11434` | Base URL of the local Ollama daemon used by the `ollama` tools |
| `HARNESS_LLM_MAX_CONTEXT_BYTES` | `262144` | Cap on the conversation/context size in bytes. Sized for small local models (8–32K windows); raise it for a large-context host |
| `YCA_RESULT_CAP` | `8192` | A tool result larger than this (bytes) spills to a file and returns a short preview + a link (MCP `resource_link`) / path notice instead of flooding a small context |
| `YCA_RESULT_PREVIEW` | `600` | Characters of inline preview kept with a spilled result (truncated on a UTF-8 boundary) |
| `YCA_SPILL_RETENTION_DAYS` | `7` | Spilled result files under `<project>/.harness_results/` older than this are garbage-collected at boot |
| `YCA_PLAN_DECORATE` | `1` | While a plan is active, append `PLAN: step N of M — …` to each tool result. Set `0` to disable the decoration |

### 7.1 Per-provider capability fields (T9 profiles)

Each provider entry (see §3) may declare capability fields. Declared values are
authoritative and win over anything Yantra would otherwise probe:

| Field | Example | Purpose |
|-------|---------|---------|
| `probe` | `false` | **Metered guard.** A provider with `probe:false` is *never* contacted for capability probing — no surprise per-request bills. |
| `context_window` | `32768` | The model's context size in tokens (feeds the result/context budgets). |
| `response_format` | `"yes"` | Whether the endpoint honors `response_format` for constrained JSON output. |
| `vision` | `true` | Whether the endpoint accepts images (independent of tool support). |

Call the doctor workflow — `tools/call {"name":"wf__harness_doctor","arguments":{}}` —
to see the resolved provider profiles and the connected MCP host's capabilities.
