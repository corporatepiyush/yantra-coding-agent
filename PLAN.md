# YANTRA EXECUTION PLAN — Small-Models-First, MCP-Native Tool Server

**STATUS: MANDATORY.** This is the sole authoritative plan; it supersedes all prior drafts. Task numbering is the execution order. Deviations, reorderings, or scope changes require a written amendment to this document approved by the owner. Decisions D1–D12 (PART III) bind every task; a task that conflicts with a decision must be flagged, not improvised around.

**Author:** Claude (Anthropic) · July 13, 2026 · **Subject:** the `yantra-coding-agent` repository (261 files, ~23.7K lines of Bash).

## How to read this document

This document is written so that any LLM — including a small one (7B–14B parameters) — can understand and execute it without outside context. It has four parts:

- **PART I — REVIEW.** Facts about the codebase: what was tested, what works, what is broken. This part is evidence. It is NOT a to-do list. Do not "fix" things from Part I directly; every fix already has a task in Part II.
- **PART II — PLAN.** The task list. It is one flat list in priority order with a cut line. Tasks above the cut line are committed work. Items below the cut line are backlog: scoped but NOT committed. Do the tasks in the stated execution order.
- **PART III — DECISIONS.** The standing rules (D1–D9) that every task must obey, plus version history. If a task and a decision seem to conflict, the decision wins; flag the conflict instead of guessing.
- **PART IV — DESIGN NOTES.** Reference material: the MCP protocol mapping (used by task T8), the host-requirements checklist IV-B.1 (used by T5 and by anyone choosing an MCP host), and the inference-engine failure catalog F1–F13 (used by T5, T10, T9, and host selection).

**Artifact notation — no ambiguity about what exists.** Every file, tool, command, flag, or config key marked **(NEW)** does not exist yet: this plan creates it. Every unmarked artifact name was verified present in the repository during the review. If an implementer finds an unmarked name that does not exist, that is a plan bug — flag it, do not guess.

Claims are tagged. **[verified]** = confirmed by reading source code or running the software during this review. **[unmeasured]** = plausible and supported by notes or general knowledge, but not measured; task T5 exists to measure these. Treat [unmeasured] claims as hypotheses, not facts.

## Glossary (read this first if any term is unfamiliar)

- **Tool** — one atomic action Yantra can run, e.g. `read` (read a file) or `k8s_pods` (list Kubernetes pods). Each tool has a name, a function, a JSON **schema** describing its arguments, and a **danger level**.
- **Workflow** — a scripted multi-step routine chaining tools, e.g. `pipeline.ci` runs format → lint → build → test.
- **Tool call** — the JSON message an LLM emits to run a tool, e.g. `{"name":"read","arguments":{"path":"README.md"}}`.
- **Schema** — a JSON Schema object listing a tool's argument names, types, which are required, and (after task T6) a description and, where possible, an **enum** (a fixed list of allowed values) for each argument.
- **Registry** — the in-memory table of all registered tools (`YCA_TOOL_REGISTRY` in `harness/core/tools.sh`) and workflows (`YCA_WF_REGISTRY` in `harness/core/workflows.sh`).
- **Category** — a group of tools (e.g. `docker`, `python`). Categories are gated: only enabled categories are sent to the LLM. The 6 `core` tools (read, write, edit, bash, browse, batch) are always enabled.
- **Danger level** — per tool: `safe` (read-only), `writes`, `destructive`, or `dangerous`. Anything except `safe` needs user consent before running.
- **Consent gate** — the mechanism that blocks non-safe actions until the user approves (`-y` on the CLI, `auto_confirm:true` per frame in machine mode).
- **Machine mode / NDJSON** — Yantra's programmatic interface: one JSON object per line over stdin/stdout (`harness/commands/stdio.sh`). NDJSON means "newline-delimited JSON".
- **Agent loop** — the function `agent_run_llm_loop` in `harness/core/llm.sh`: it sends messages + tool schemas to an LLM, executes the returned tool calls, and repeats. **Removed by task T8 under Decision D11:** the reasoning loop belongs to the MCP host; Yantra remains the tool server.
- **MCP host** — the client application that owns the conversation and the reasoning loop and connects to MCP servers like Yantra: Claude Desktop for large models; Ollama-driving CLI hosts for small local models.
- **Elicitation** — MCP feature: the server asks the user a structured question mid-call (Yantra uses it for consent, Decision D5).
- **Sampling** — MCP feature: the server asks the *host's* model to run a completion (Yantra uses it for the `*_llm_*` tools).
- **Resource link** — MCP feature: a tool result can return a link to bulk content instead of the bytes; the host fetches it only if needed (Yantra uses it for large tool outputs, task T10).
- **Provider / tier** — a configured LLM endpoint (URL + model + token). Providers are grouped into three tiers by task complexity: `tool` (low), `build` (mid), `think` (high). See `harness/core/providers.sh` and `harness/core/complexity.sh`.
- **Context window** — the maximum number of **tokens** (word pieces, roughly 4 characters each) a model can see at once. Small local models commonly have 4K–32K.
- **Truncation** — cutting text to fit a limit. **Silent truncation** = the server cuts the prompt without telling you (see failure F1).
- **Chat template** — the per-model recipe (usually Jinja) that an inference engine uses to turn the message list into the model's raw input text, and to parse the model's raw output back into messages and tool calls.
- **Inference engine** — the server program running the model: Ollama, llama.cpp (`llama-server`), vLLM, LM Studio, etc. The same model can behave differently on different engines.
- **GGUF** — the quantized model file format used by llama.cpp/Ollama/LM Studio. GGUF files embed a chat template, which is sometimes wrong or broken.
- **Constrained decoding / grammar** — making the engine *force* the model's output to match a schema or grammar, so malformed JSON becomes impossible. Names per engine: Ollama `format`, OpenAI-style `response_format`/strict tools, llama.cpp GBNF grammars.
- **Salvage** — recovering a tool call that the engine failed to parse, by finding it inside plain-text content. Host scope: requirement H2 in checklist IV-B.1.
- **MCP** — Model Context Protocol: the open standard by which LLM client apps (like Claude Desktop) connect to tool servers. See PART IV-A.
- **LSP** — Language Server Protocol: the standard IDE-backend protocol spoken by `gopls`, `rust-analyzer`, `pyright`, etc. It provides "find callers", "rename symbol" and similar operations (backlog item B1/B3).
- **KG (knowledge graph)** — Yantra's code map: symbols and import edges extracted with awk (`harness/core/kg.sh`).
- **Exemplar** — an existing file in the user's own repository that is similar to what they want to create next (backlog item B4).
- **Cut line** — the marker in Part II separating committed tasks from backlog (B-items).
- **Canary probe** — a tiny test request sent to a provider to detect a capability, e.g. "define one trivial tool; does the model call it?" (task T9).
- **Capability profile** — the recorded answers of all canary probes for one provider (task T9).
- **Effort scale** — S = under one day including its regression test; M = 1–3 days; L = 1–2 weeks. The ORDER is binding; effort figures are planning estimates the implementer must re-scope and record at task start.

## The guiding principle (Decision D1 — everything follows from this)

Small LLMs are the priority. Large models benefit from Yantra only opportunistically — they can read dependencies and compose shell commands themselves. Small models cannot, so Yantra's real product is converting small-model *failure* into *success*. Every task is judged by one question: **does it raise a ≤14B model's task success rate?**

The known small-model failure modes this plan targets, each mapped to its tasks:

1. Emitting malformed tool-call JSON → T6, T7 server-side; call *generation* quality is the MCP host's job (checklist IV-B.1).
2. Constructing exact-match strings for text edits → B1, B3 (semantic operations).
3. Composing multi-flag shell commands → already solved by Yantra's tool wrappers; protected by Decision D6.
4. Choosing correctly from a long tool list → T11 (discovery, exposed over MCP).
5. Losing the plan over many turns → T12 (plan store, exposed as tools + an MCP resource + result decoration).
6. Drowning in oversized tool output through a small context window → T10.
7. Being sabotaged by the inference engine itself (broken templates, silent truncation, dropped tool calls) → T9 for Yantra's own mid-tier calls; for the host's loop, the catalog PART IV-B and checklist IV-B.1 govern host selection (T5 records host + version for exactly this reason).

---

# PART I — REVIEW (frozen evidence — not a to-do list)

## I.1 What was examined

**Read line-by-line:** `harness/main.sh`, `core/tools.sh`, `core/workflows.sh`, `core/llm.sh`, `core/complexity.sh`, `core/dispatch.sh` (~first 100 lines), `commands/stdio.sh`, `tools/core.sh`, `workflows/pipeline.sh`, `workflows/test.sh` registrations, `core/skills.sh` (preamble + one role), `lib/bash53.sh`, `lib/sanitize.sh`, `lib/io.sh` (grep paths), `lib/json.sh` (head), the `eval` call sites in `workflows/debug.sh`, `tools/docker.sh`, `tools/kubernetes.sh`, `docs/AGENT_GUIDE.md`, README (~first 120 lines), `docs/cli/git.md` (head), the test runner, and two test files.

**Only sampled (not audited):** the remaining ~30 tool category files, the 10 `langs/*.sh` files, most workflow bodies, most of `lib/`, `scanner.sh`, `kg.sh` (grepped only), `doctor.sh`. Any repo-wide quality judgment generalizes from roughly 15% of the code read closely. Weigh it accordingly.

## I.2 What was executed (environment: Ubuntu 24.04 container, bash 5.2, jq + sqlite3 installed; the two Bash-5.3 version checks were patched down in a copy — nothing else changed)

| Evidence | Result |
|---|---|
| `{"type":"list","what":"tools"}` in machine mode | Clean NDJSON; **659 tools cataloged** |
| `core read hello.py` and `core read /etc/passwd` | First works; second correctly refused by the path guard |
| `core write` without `-y`, then with `-y` | Denied without consent; file written with consent |
| `test run` on a bare Python file | Correct answer: "no test command detected" |
| `git status`, `fs grep` | Both work; `fs grep` returned matches from `.git/hooks/` (noise — see defect d) |
| `{"type":"run","workflow":"git.quicksave"}` without consent | Correctly auto-denied with an instructive message |
| Test suite: **10 of 58 suites** (keyword-filtered) | 9 pass; 1 fails only because the `column` binary is missing (defect c), not because of bash 5.2 |
| Size of the tools JSON sent to the LLM | Core only: 6 tools, 1,642 bytes. All categories enabled: **659 tools, 79,983 bytes ≈ ~20,000 tokens** |
| `eval` security triage | All 24 sites listed; 4 contexts read closely — see I.5 |
| `lib/io.sh` lines 76 and 86 | ripgrep (`rg`) is already preferred; plain `grep` is only the fallback |
| `lib/json.sh` header | Says: "All JSON is built with jq. Never hand-build JSON" — and the code follows it |
| `core/kg.sh` | Contains no hash or mtime cache — the knowledge graph re-parses every file on every build |
| `tools/ollama.sh` line 301+ | `ai_rag_index` / `ai_rag_query` exist (semantic search over a DuckDB vector store) |
| `main.sh`, the `architect` role | Its body is `while true; do sleep 1; done` — scaffolding presented as a feature |
| `lib/constants.sh:69`, `core/llm.sh:266,280` | Tool-output cap = 1 MiB; conversation cap = 4 MiB — sized for frontier models, absurd for 8K-context local models |
| `tools/docker.sh:29` | `docker_ps`'s `target` argument accepts exactly `all`, `running`, `stopped` — a closed set, suitable for an enum |

**Not done (be honest about the limits of this evidence):** the agent loop was never run against a live model; docker/k8s/database tools were never run against live services; the repo's "50 parallel agents" benchmark was not reproduced; 48 of 58 test suites were not run. The "works on bash 5.2" claim covers only the code paths that the 10 suites and the manual calls exercised.

## I.3 Assessment: how much does Yantra actually help an LLM?

**Where the help is real.** Deterministic workflows replace generation: `pipeline.ci` runs format → lint → build → test with per-project framework detection, so the model does not spend turns discovering the test runner and composing commands. Output shaping (bounded `git log` views, `tail -30` on step output, truncation, eliding of old tool messages) reduces *input* tokens — the side most harnesses ignore. The source contains real context engineering **[verified]**: core tools are placed first in the tools array because small models pick from the head of the list (the code comment cites a llama3.2 fuzz result); the tool-list bytes are kept stable so the provider's prefix cache stays warm; parameterless tools omit the `parameters` field to save tokens; the anti-drift reminder is appended as a `user`-role message because a trailing `system` message silently breaks tool calling on llama-family chat templates.

**For a large model:** savings are modest and mostly on the input side; the real gains are determinism and shaped output. Magnitude **[unmeasured]** — no percentage may appear in any README until task T5 produces one. **For a small model:** the value is capability conversion — tasks change from "fails" to "succeeds" — not merely a token discount **[unmeasured]**.

**The central tension.** All 659 tools ≈ 20K tokens of schemas. No small model can be handed that. Category gating (default: 6 tools) is the current answer, but it is static — a session cannot *discover* a needed tool mid-task. `wf_suggest` (fuzzy matching over workflow names) exists internally but is not exposed to the model. Task T11 fixes this.

## I.4 Verified defects (each has a task; do not fix from here)

a. The machine-mode `ready` frame advertises `"stream"` and `"cancel"` capabilities, but no handler for either exists anywhere in `commands/` or `core/` (`stdio.sh:5`). → T1
b. The Bash 5.3 hard requirement appears unnecessary: the gate's comment cites a `${| …; }` construct "in harness/lib/bash53.sh" that exists only inside comments, and everything exercised ran on bash 5.2. Ubuntu 24.04 LTS ships 5.2; macOS ships 3.2 — so "clone and run" currently means "first build bash from source". → T3
c. `workflows/harness.sh:19` pipes to the `column` binary, which is absent on minimal images and not probed by `doctor` — a shipped workflow crashes. → T2
d. `io_grep_recursive`'s grep fallback searches `.git/` (ripgrep, when installed, skips it natively). → T2
e. README counts drift from the source: README says 606 tools / 99 workflows; the source registers **659** tools and **~105** workflows. → T1
f. The positional argument mapper in `_tool_exec` maps ~4 priority slots (`.path // .command // .url // …`) and its own comment admits collisions (e.g. a tool needing both `file` and `sql`). → mitigated by T7 (exact-field validation); long-term migration to `tool_arg` reads.
g. `_tool_exec` merges stderr into the tool output the model sees (`2>&1`), polluting results with diagnostics. → B5
h. `_k8s_run` in `tools/kubernetes.sh` is defined and never called — dead code. → T1
i. The `architect` role is a sleep loop presented in docs as a feature. → T8 (removal half) + M5 (docs sweep)
j. Output caps (1 MiB per tool result ≈ ~250K tokens; 4 MiB conversation) are sized for frontier contexts, not the 8–32K windows of the small models this project prioritizes. → T10
k. Tool schemas carry only `type` per argument — no descriptions, no enums (verified on `read` and `docker_ps`). → T6

## I.5 Security triage of the 24 `eval` sites (performed; conclusion first)

**Conclusion: no unconsented LLM-controlled input reaches `eval` in anything traced.** Details:

| Class | ~Sites | Finding |
|---|---|---|
| Workflow steps eval'ing commands from `toolchain_profile_json` (pipeline/test/lint/build/fmt/deps/perf/release) | ~19 | The command strings derive from the **project's own files** (package.json, Cargo.toml, …), not from LLM arguments. This is not an injection vector. It IS "running the project's build executes the project" — a trust model to write down (B20), not a vulnerability to patch. |
| `workflows/debug.sh:44` — `eval "$INPUT_cmd"` | 1 | User/LLM-controlled **by design** (it is a "run this repro command" feature) and consent-gated via `confirm_action`; machine mode auto-denies without `auto_confirm`. Same exposure as the `bash` tool. OK. |
| `tools/docker.sh` — `_docker_run` | 1 | Reachable only through the explicit `docker_run` tool, which is registered `writes` and therefore consent-gated. Read verbs call docker directly with quoted arguments; write verbs additionally sanitize names via `shell_arg_safe` (rejects metacharacters, whitespace, leading `-`). OK. |
| `tools/kubernetes.sh` — `_k8s_run` | 1 | Dead code (defect h). Verbs call kubectl directly; write verbs use `_k8s_nsflag_safe` against flag injection. |
| `lib/os.sh` (brew shellenv), `lib/files.sh:132` (fswatch callback) | 2 | brew: trusts the local brew binary — standard practice. **`files.sh:132`'s `cmd` origin was NOT traced — the one residual unknown**, assigned to B20. |

## I.6 Non-goals (things this plan deliberately does NOT do)

- **Native Windows.** WSL remains the Windows story. A PowerShell port is a rewrite, not a task. State this in the README.
- **Replacing Bash.** Where Bash hurts most (streaming tool-call reassembly, long-lived LSP processes), tasks are scoped down rather than fought.
- **Growing the default catalog.** Rule: the token count of the default tool list sent to the model may not increase. New capabilities land as opt-in extras reachable through discovery (T11). See Decision D6.
- **Model routing/gateway features** beyond the providers kept for the `*_llm_*` tools.
- **Owning the reasoning loop** *(Decision D11)*. Yantra is a tool server; the conversation and the tool-calling loop belong to the MCP host. Yantra keeps only single-shot LLM calls (`llm_analyze`) for its 22 `*_llm_*` diagnostic tools.

---

# PART II — PLAN

**Above the cut line: tasks T1–T12 — committed work, totaling 2 S + 9 M + 1 L ≈ 6–8 focused weeks for one maintainer. Numbering IS the execution order: execute T1 → T12.** Below the cut line: backlog B1–B21 — scoped and priority-ordered, not committed. No below-line item may start while an above-line task is incomplete, except by owner-approved amendment.

**T1 → T2 → T3 → T4 → T5 → T6 → T7 → T8 → T9 → T10 → T11 → T12.**

## II.0 How to write a test in this repository (read before writing any test)

These are the repo's real conventions **[verified by reading `tests/run_all.sh`, `tests/test_danger_gate.sh`, `tests/test_scripts/danger_gate_body.sh`, `tests/test_helpers.sh`]**. Follow them exactly.

**File layout and discovery.** A test suite is one file `tests/test_<name>.sh`. The runner (`tests/run_all.sh`) discovers suites automatically by globbing `tests/test_*.sh` — there is no registration step. Complex suites put their logic in a body script under `tests/test_scripts/<name>_body.sh`; the suite wrapper runs the body and greps its output for the marker `<name>_body OK`.

**The contract.** Every suite receives two arguments: `$1` = the ABSOLUTE path to `yantra-mcp-server.sh`, `$2` = a private temporary directory created just for this suite. Start with `set -Euo pipefail`. Do all work inside `$2`. On any failure, print `FAIL: <specific reason, including the actual value received>` and `exit 1`. On success, print `<name> OK` and `exit 0`.

**Two test styles — pick per level.** (a) *End-to-end:* pipe NDJSON frames into the entry script — `printf '{"type":"run",...}\n{"type":"bye"}\n' | HARNESS_UPDATE_ENABLED=false bash "$HARNESS" --ui json` — then parse the output frames **with jq**, never with substring-grep on raw JSON (a value can appear in more than one field). (b) *Unit:* export `YCA_DIR`, `source "$YCA_DIR/harness/main.sh"` (sourcing does NOT run `main()`), then set `YCA_PROJECT_DIR="$2"`, `YCA_SAFETY_PATHS="$2"`, `YCA_UI_MODE=json`, enable the categories you need (e.g. `YCA_CAT_ENABLED[core]=1`), and call functions directly.

**Isolation rules.** No network. No live services — mock HTTP providers with a local stub inside `$TMP`; use fixture git repositories with a local bare remote (`git clone --bare`, the existing `test_helpers.sh` pattern). No fixed ports, no global git config (set `user.email`/`user.name` inside the fixture repo), delete `.harness.db` first when database state matters. Suites run in parallel; nothing may depend on another suite.

**The spy pattern (how to prove something did NOT run).** Register a fixture tool whose function touches a marker file: `_fake() { touch "$MARKER"; }; tool_register "fake_x" _fake '<schema>' destructive all core`. Then assert on the marker's existence or absence. This is the repo's own idiom for proving fail-closed behavior.

**Assertions that must never be missed — the universal checklist:**
1. **Assert the negative case, not just the positive.** The feature working is half a test; the gate still denying, the exclusion still excluding, the field still absent is the other half.
2. **Assert exit code AND output content.** Either alone passes wrong implementations.
3. **Assert absence explicitly** — a removed capability is `jq '.capabilities | index("stream") == null'`, not "the test didn't mention it".
4. **When a task claims "unchanged" or "identical", assert byte-identical** (`cmp`, `git diff --exit-code`, golden files) — never "looks similar".
5. **Assert error messages by content.** Corrective errors are a feature of this plan (T7); a test that only checks non-zero exit would pass a useless message.
6. **Guard against false positives.** Every detector/warning test needs a companion case asserting NO warning fires when things are fine (T10).
7. **Assert idempotence for every transformer**: `f(f(x)) == f(x)`.
8. **Assert pairing integrity** wherever two things must match (a tool result's `tool_call_id` must equal its call's id after any rewriting — strict servers reject mismatches).
9. **Never assert on timing, durations, or the ordering of parallel output.**
10. **One behavior per assertion**, each with a `FAIL:` message that names what broke and prints the actual value — the debugger reading it may be a small model.

## II.0.1 Edge-case taxonomy (walk this list for every task; skip a class only with a written reason)

- **Empty/zero:** empty arguments `{}`, empty tools list, zero-length file, empty plan, empty category, empty string vs missing field vs `null` (three different things — test all three).
- **Boundary/off-by-one:** results at exactly the size cap, cap−1, cap+1; page size 1; the last item of a list.
- **Oversize shape:** one huge line vs many small lines; deeply nested JSON at the depth limit.
- **Unicode:** emoji/CJK in paths, arguments, and tool output; **truncation must never cut mid-UTF-8-codepoint** (truncate at a character boundary, assert the result is still valid UTF-8); invalid UTF-8 bytes and NUL bytes in tool output must be escaped or spilled to a file — raw control bytes inside a JSON-RPC line corrupt the stream.
- **Filesystem:** paths containing spaces and newlines; **symlinks inside the project pointing outside it** (the guard portion read during review shows no symlink resolution — this is a must-test, potential path-guard bypass); read-only project directory; disk full while spilling a result file (T10 must fail with a message, not a broken link).
- **Concurrency:** parallel JSON-RPC requests with distinct ids on one stdio connection — serial Bash must queue and answer **by id**, and a test must send request B before A's answer and assert both answers carry the right ids; notifications arriving mid-call.
- **Crash/lifecycle:** client closes stdin → clean shutdown; **client dies mid-write → SIGPIPE** (verified during review: the cleanup trap covers `EXIT INT TERM` only — SIGPIPE must be trapped or the server dies without cleanup); server killed mid-elicitation.
- **Hostile/malformed:** invalid JSON, valid JSON that is not JSON-RPC, unknown method, wrong protocol version, elicitation answered with garbage, sampling answered with an error or empty completion (fallback must engage exactly once, never loop).
- **Nesting:** the `batch` tool containing a writes-class call → elicitation fired from inside a batch; a plan-decorated result that is itself spilled to a resource link.
- **Environment:** `LANG=C` / non-UTF-8 locale; missing optional binaries (every optional-tool path needs its absent-binary case).

## II.0.2 Test-suite architecture for the MCP-native harness

Five layers, each with its own directory and failure meaning:
- **L1 — Unit** (`tests/test_*`, existing style): source `main.sh`, call functions. Fast, no processes.
- **L2 — Protocol** (`tests/mcp_*`, NEW naming): the T4 client against the real server; golden frame logs; every II.0.1 crash/concurrency/malformed case lives here.
- **L3 — Parity** (`tests/parity_*`, NEW naming): the SAME fixture scenario executed via CLI, NDJSON, and MCP, asserting identical outcomes and identical fail-closed behavior — consent parity (T8 test 2) generalized into a standing suite. Any behavior that exists on all three surfaces gets a parity test, or it will drift.
- **L4 — Conformance:** the official MCP conformance suite in CI once consumable (IV-A row 16).
- **L5 — Evals** (T5): success-rate and token measurements with real models and hosts.
Standing rules: (a) **fuzz the reader** — random bytes and truncated frames into the JSON-RPC reader must never crash it, always yielding an error response or a clean skip (extend the existing `fuzz_dispatch` pattern); (b) **every migration bug becomes a fixture** — a bug found during this migration is not fixed until its reproduction is a committed test; (c) goldens are regenerated only by an explicit, reviewed command, never silently.

## II.M Migration playbook for the loop-removal (mandatory procedure for the loop removal)

The pivot is a *migration*, not just a feature. T8 executes inside this playbook; Decision D12 makes it binding.

- **M1 — Characterize first.** Before ANY refactor: capture golden tests for every surface that must not change — CLI subcommand output, NDJSON `run`/`dispatch`/`list` frames, tool result text for a fixture set. The refactor is then provable: goldens green = surfaces preserved. Deleting code without a prior characterization test of its neighbors is forbidden.
- **M2 — Strangler sequencing with an evidence gate.** T8 splits into phases: **T8-a (build)** — the MCP server ships alongside the still-working loop, behind `--ui mcp`; **gate** — the destructive half may start only when T5 shows the MCP-hosted path matches or beats the loop path on task success for the small-model matrix (deleting the loop before the evals run destroys the experiment's control group); **T8-b (deprecate)** — `message` frames and `--role` warn for one release (B11 policy); **T8-c (remove)** — deletion, only after a tagged release exists as the rollback point.
- **M3 — Test-migration inventory with assertion preservation.** Enumerated during review **[verified by grep]**: `test_llm_loop.sh` and `test_turn_reminder.sh` are certain casualties; `test_startup_ux.sh`, `test_helpers.sh`, `test_git_workflows.sh`, `test_scripts/ai_actions_body.sh`, `test_scripts/fuzz_dispatch.sh`, `test_scripts/vcs_actions_body.sh` need per-suite triage (the grep over-matches — "message" also hits git commit messages, so read each suite). Rule: **no test is deleted until each of its assertions is mapped** to (a) a new home in L2/L3, (b) the host checklist IV-B.1 with a note, or (c) a written "assertion obsolete because X". The map is committed with the deletion.
- **M4 — Config compatibility.** Old config/flags must warn, never silently no-op: think-tier provider entries, `YCA_TURN_REMINDER_ENABLED`, `--role`, `--workflow` with a role. Each prints a one-line deprecation naming its replacement. Test: a config exercising every removed key produces every warning and still boots.
- **M5 — Docs sweep.** `AGENT_GUIDE.md` is written for a model driving Yantra's own loop; after T8-b it must be rewritten as "Yantra over MCP" (host setup for Claude Desktop and for an Ollama-driving host, the meta-tools, the consent flow). README regenerated (T1's count generation helps); the turn reminder's grounding rules — genuinely good content — are preserved as an MCP prompt rather than deleted.
- **M6 — Release mechanics.** The removal ships as a major version with a migration guide; the pre-removal tag is the documented rollback; the CHANGELOG maps every removed surface to its replacement.


Every task below states: **What** (the change), **Why** (the reason), **Files** (where to work), **Done when** (the summary of success), **Tests & assertions** (the test cases to write and the assertions that must not be missed — see II.0 for the conventions), and **Depends** (prerequisite tasks). Numbered steps are included where the order of operations matters. Per Decision D10, a task is not done until every listed assertion exists as an executable test.

### T1 — Protocol & docs honesty · Effort S · Depends: none
**What:** Three small truth fixes. (1) Remove `"stream"` and `"cancel"` from the capabilities list in the `ready` frame. (2) Make CI generate the README's tool/workflow counts from the registry. (3) Delete the unused function `_k8s_run`.
**Why:** The `ready` frame currently promises capabilities that do not exist (defect a); machine clients plan against that promise and fail. The README numbers have already drifted (defect e). Dead code misleads readers (defect h).
**Files:** `harness/commands/stdio.sh` (line 5), README generation in CI config, `harness/tools/kubernetes.sh`.
**Steps:** 1. Edit the capabilities array. 2. Add a test that iterates the advertised capabilities and asserts each has a handler. 3. Add a CI step: count `tool_register`/`wf_register` calls, compare to README, fail on mismatch. 4. Delete `_k8s_run`; run the suite.
**Done when:** the capability-walk test passes; CI fails on count drift; `grep -rn _k8s_run harness` returns nothing.
**Tests & assertions:** (1) E2E: capture the `ready` frame, assert with jq that `.capabilities | index("stream")` and `index("cancel")` are both null (checklist #3 — assert absence). (2) Capability walk both directions: every advertised capability maps to an existing handler (`declare -F` or a case-arm check in `stdio_loop`), AND every handled command type is advertised — drift in either direction fails. (3) The counts test must compute truth by sourcing the harness and counting `${#YCA_TOOL_REGISTRY[@]}` / `${#YCA_WF_REGISTRY[@]}` — never by grepping source text — and on mismatch print BOTH numbers. (4) After deleting `_k8s_run`, run the full suite, not just the k8s suite (deletion regressions hide elsewhere).

### T2 — Shipped-behavior fixes · Effort M · Depends: none
**What:** (1) Replace the `column` dependency in `workflows/harness.sh:19` with awk-based alignment, or add `column` to the doctor's probe list with a graceful fallback; then sweep every workflow for other binaries the doctor does not probe. (2) In the plain-`grep` fallback of `io_grep_recursive`, exclude `.git`, `node_modules`, `target`, `dist`, `build`, `__pycache__`, `.venv` by default; add an `include_ignored:true` argument to opt back in.
**Why:** A shipped workflow crashes on minimal Linux images (defect c). Grep noise from `.git/` wastes the model's context window (defect d) — and note ripgrep already skips `.git`; only the fallback is broken **[verified]**.
**Files:** `harness/workflows/harness.sh`, `harness/core/doctor.sh`, `harness/lib/io.sh`, `harness/tools/fs.sh`.
**Done when:** `test_e2e_workflows` passes on a minimal image containing only the 4 declared dependencies (bash, curl, jq, sqlite3); a grep for a common word in a git repo returns zero `.git/` matches both with and without ripgrep installed.
**Tests & assertions:** (1) Dependency proof: build `$TMP/bin` containing symlinks to ONLY the four declared dependencies plus coreutils, run the affected workflow with `PATH=$TMP/bin`, assert exit 0 — this proves no hidden binary, not just that `column` was replaced. (2) The grep test MUST run twice: once with `rg` on PATH and once with a PATH that hides `rg` — the fallback is the buggy path, so testing only with ripgrep present proves nothing (checklist #1). (3) Fixture: a repo with the pattern present in `.git/hooks/`, `node_modules/`, AND a normal source file; assert zero excluded-dir matches by default, assert the normal match IS still found (no over-exclusion), assert `include_ignored:true` returns the excluded matches. (4) **Symlink escape:** create a symlink inside the project pointing at a file outside it; assert `read` and `fs_grep` through that link are refused by the path guard — the guard code read during review shows prefix matching without visible symlink resolution, so this is either a passing test or a real vulnerability fix; either outcome belongs in this task.

### T3 — Drop the Bash 5.3 gate · Effort S · Depends: none
> **AMENDMENT (owner, 2026-07-13): T3 REVERSED.** Lowering the gate to 5.2 was a
> bad decision; Bash **5.3** is required again. The entry-point gate, `_yca_require_bash`
> in `harness/lib/bash53.sh`, the README badge, and `tests/test_bash_version.sh` all
> re-enforce 5.3; `tests/test_bash_modernization.sh` (which guards the 5.3 message)
> passes. The original T3 text below is retained for history only — do NOT execute it.

**What:** Lower the required Bash version to 5.2 (or 5.1 if verification allows) in both gates: the entry-point check in `yantra-mcp-server.sh` and `_yca_require_bash` in `harness/lib/bash53.sh`. Delete or correct the stale comment about the `${| …; }` construct. Add bash 5.1/5.2/5.3 to the CI matrix.
**Why:** The requirement blocks the exact audience being prioritized — people running local models on stock Linux, where Ubuntu LTS ships bash 5.2 (defect b). The entire harness plus 9/10 sampled test suites already ran on 5.2 during this review **[verified for the exercised paths]**.
**Done when:** all 58 suites are green on bash 5.2 in CI; the gate value equals the lowest green version.
**Tests & assertions:** (1) Extend the runner's existing `bash -n` syntax gate to run under EACH bash version in the matrix — a parse check under the oldest supported bash catches 5.3-only syntax even in code paths no suite executes; it is the cheapest full-coverage assertion available. (2) The CI matrix must run all 58 suites, not a `-k`-filtered subset (this review's own 10-suite sample is explicitly insufficient evidence — see I.2). (3) Assert the gate's error message states the same version as the constant it checks (message/constant drift guard).

### T4 — Minimal MCP test client (in-repo) · Effort M · Depends: none ·
**What:** A small MCP client for CI, living in `tests/mcp_client/` (NEW directory; its captured fixtures live in `tests/fixtures/`, also NEW) (bash, or python3 which the harness already uses as a soft dependency). It can: perform the handshake with configurable capability flags (sampling on/off, elicitation on/off, roots); send `tools/list`, `tools/call`, `resources/read`; answer elicitation requests from a scripted approve/deny fixture; answer sampling requests from canned completions; record every frame it sends and receives to a log the tests assert on. It is a test instrument, not a product.
**Why:** T8's tests and T5's deterministic CI runs need an MCP counterpart that behaves exactly as scripted. Depending on a third-party host in CI would make every test flaky and every failure ambiguous.
**Fixture rule (mandatory):** protocol fixtures are verbatim captures, never hand-typed — hand-typed fixtures encode the author's assumptions and test nothing.
**Done when:** the client drives a scripted handshake + list + call + elicitation + sampling exchange against a stub server and its frame log matches goldens.
**Tests & assertions:** (1) Golden framing: every request the client emits is byte-stable given the same script. (2) The client tolerates interleaved notifications without desync. (3) It asserts the server's echoed protocol version and fails loudly on mismatch. (4) Capability flags actually change the handshake (assert both presence and absence per checklist #3). (5) The client doubles as the fuzz driver for L2: it can replay a corpus of malformed/truncated/random-byte frames and assert the server never crashes and always answers with an error or a clean skip (extends the repo's existing `fuzz_dispatch` pattern).

### T5 — Evals seed · Effort M · Depends: none · **This is the acceptance authority — deliberately near the top.**
**What:** A minimal, CI-runnable evaluation harness. Matrix: 3 scripted tasks (fix a failing test; find a slow query; "add another X like the existing ones") × at least 2 small local models (≤14B parameters) × at least 2 inference engines (Ollama, and llama.cpp started with `--jinja`) × two conditions (with Yantra / without Yantra). in the "with Yantra" condition, the model is driven by an **MCP host**, since Yantra no longer has its own loop. Use (a) the T4 test client with a thin scripted driver for the deterministic CI runs, and (b) at least one real Ollama-driving MCP host for the reported numbers (candidates exist — e.g. mcphost-style CLI hosts; verify current options at implementation time). The host name + version becomes a mandatory matrix column, because PART IV-B shows the host/engine changes outcomes as much as the model does. Record per run: task success (yes/no) and prompt + completion token counts.
**Why:** A third of this plan's claims are tagged [unmeasured]. This task is the instrument that measures them. It sits near the top because later tasks (T11, T12, T8) define "done" in terms of these evals — the measuring instrument cannot be built last.
**Rules:** Report measured A/B deltas on these specific tasks. Never generalize to a universal percentage.
**Done when:** the harness runs in CI; a results table (including the host column) lives in docs; T11/T12/T8 can cite it.
**Tests & assertions (the evals harness itself needs tests):** (1) Fixture determinism: checksum the fixture directory before every run and assert identical — otherwise A/B comparisons are unfair. (2) Success detection must be programmatic (expected file content, suite exit code) — never judged by a model. (3) A run whose provider is unreachable is recorded as `error`, never as `fail` — dead providers must not poison the success statistics. (4) Every result row carries model name, engine name, and engine version. (5) Token counts come from the response `usage` fields and are asserted > 0 before a row is accepted. (6) Every row carries host name + host version; a row missing either is rejected.

### T6 — Schema descriptions + enums · Effort M · Depends: none
> **DONE (2026-07-13).** ~508 properties across 35 files now carry a one-line
> `description` (field-name-driven codemod + humanized fallback); `docker_ps.target`
> and `fs_organize.by` carry enums. `tests/test_schema_descriptions.sh` was
> rewritten to SOURCE the registry (not grep) and enforce, per schema: valid JSON,
> every property described, `required` ⊆ `properties`, no anyOf/oneOf/allOf,
> every enum a non-empty string array, and a wire-size cap. **Recorded price
> (D6):** the default core tool list is **3182 bytes** (cap 6000).

**What:** Sweep all 659 tool schemas. For every argument: add a one-line `description` (e.g. `"path": file path relative to the project root`). For every argument whose valid values are a closed set, add an `enum` (e.g. `docker_ps.target: ["all","running","stopped"]` — that set is closed in the source **[verified]**). Add a registry-walking test that enforces both rules forever. Also adopt the rule: schemas stay flat — no `anyOf`, no `oneOf`, no deep nesting — because several constrained-decoding backends reject those (failure F12); Yantra's schemas are already flat **[verified]**, this rule keeps them so.
**Why:** An enum turns free-text generation into selection from a list, which is the cheapest accuracy improvement available for a small model **[unmeasured; T5 measures]**. Descriptions tell the model what each field means instead of making it guess.
**Files:** every `tool_register` call across `harness/tools/*.sh` and `harness/langs/*.sh`; a new test in `tests/`.
**Done when:** the registry test passes (every property has a non-empty description; every closed value set is an enum; no anyOf/oneOf); the wire-size increase is measured and recorded in docs (descriptions cost tokens — publish the price).
**Tests & assertions (one registry-walking suite, sourcing `main.sh` and iterating `YCA_TOOL_SCHEMAS`):** (1) Every schema parses under `jq -e`. (2) Every property has a non-empty `description`. (3) `required` is a subset of the keys of `properties` — the classic silent drift bug. (4) No `anyOf`/`oneOf`/`allOf`; nesting depth ≤ 3 (compute via jq paths). (5) Every `enum` is a non-empty array of strings. (6) Wire-size snapshot: total `build_tools_json` bytes must stay under a recorded threshold, so catalog growth is a conscious commit, not an accident (Decision D6 enforced by test).

### T7 — Argument validation with corrective errors · Effort M · Depends: T6
**What:** Before `_tool_exec` runs a tool, validate the incoming arguments against the tool's registered schema. On failure, return a message the model can act on: unknown field → `unknown field 'file'; this tool takes {path, pattern}; did you mean 'path'?`; wrong type → name the expected type; where safe, coerce obvious cases (a number sent as a string, an array sent as a JSON string — failure F9) instead of erroring.
**Why:** Small models constantly send wrong field names and wrong types. Today those calls fall through the generic positional mapper (defect f) and fail silently or wrongly. A corrective error message is how a small model recovers on the next turn **[unmeasured; T5 measures]**.
**Files:** `harness/core/tools.sh` (`tool_dispatch` path), new test in `tests/`.
**Done when:** a fuzz test feeding the common mistakes (wrong field name, string-for-integer, arguments-as-string, extra fields) always receives a corrective message or a safe coercion — never a silent positional fallback.

### T8 — MCP server as the primary surface + agent-loop removal · Effort L · Depends: T4; T6–T7 precede by order ·
> **AMENDMENT (owner, 2026-07-13): MCP-ONLY, evidence gate waived.** The owner
> ordered the removal half executed immediately and IN FULL: the CLI subcommand
> surface, the interactive REPL, the NDJSON stdio surface, the roles, and the
> agent loop are all removed; Yantra is a pure MCP server (`--ui mcp` is the
> default and only mode). This supersedes D11's "kept escape hatch" (CLI +
> NDJSON frames are gone too) and waives the M2/T5 evidence gate for the loop
> deletion. Executed per the II.M playbook otherwise: rollback point = the
> commit tagged in git history as the parent of this change ("M6 rollback
> point" in its message); the M3 assertion-preservation map lives in
> docs/MIGRATION_MCP_ONLY.md; removed flags fail with a one-line pointer to
> the MCP replacement (M4). Internal seams (tool_dispatch, run_workflow,
> emit frames, tool_invoke) survive as plumbing — only the surfaces died.
**What — build half:** `--ui mcp` (NEW flag), a JSON-RPC-over-stdio MCP server (NEW surface), per the full mapping in PART IV-A. Pin spec revision **2025-11-25** with the handshake isolated in ONE function (the 2026-07-28 revision removes it; final ships July 28, 2026). Concretely: `tools/list` ← `build_tools_json` (core + T11 meta-tools; paginate the full 659 only on request); `tools/call` ← `tool_dispatch` (T7 validation included); workflows exposed as tools named `wf__<id>` with a reverse map (NEW) (MCP names cannot contain dots); danger levels → tool annotations (advisory; server gating stays authoritative); **consent via elicitation** carrying the exact preview `confirm_action` already builds, deny-with-explanation fallback (D5); the 22 `*_llm_*` tools request **sampling** when the host record (T11b) allows, falling back to the provider profile; `docs/cli/*.md`, toolchain profile, doctor report, and `plan://current` exposed as **resources**; `skills.sh` prompts exposed as MCP **prompts**; tool stderr and `log_warn` routed to **logging notifications** (absorbs B5 on this surface); `enable_category` emits `tools/list_changed`; lazy boot (reuse subcommand mode's probe-skipping **[verified pattern]**).
**Execution note:** T8 runs inside the II.M playbook — characterize first (M1), build alongside the loop (T8-a), pass the T5 evidence gate, deprecate (T8-b), then remove (T8-c). The removal half below is T8-b/c, NOT day one.
**What — removal half (Decision D11):** delete `agent_run_llm_loop`; delete the `architect`/`code_gen` roles (this completes defect i / absorbs B21 — only docs cleanup remains); the NDJSON `message` frame returns a deprecation error for one release (per B11's policy) and is then removed; drop `"llm"` from the ready-frame capabilities at the same moment (T1's capability-walk test enforces this automatically). **Kept, deliberately:** `llm_analyze` + `providers.sh` (the `*_llm_*` tools), the full CLI, and NDJSON `run`/`dispatch`/`list` — so any thin external loop can still drive Yantra without speaking MCP.
**Files:** new `harness/commands/mcp.sh`; `harness/core/llm.sh` (loop deletion); `harness/commands/stdio.sh` (message deprecation); `harness/main.sh` (role removal); docs.
**Done when:** the server passes the T4-driven suite below, connects to at least two real MCP clients, and `declare -F agent_run_llm_loop` fails.
**Tests & assertions:** (1) Happy path via T4: handshake → `tools/list` → `tools/call read` → correct result; assert the tools list byte-stable across two connections (prefix-cache property preserved). (2) **Consent parity — the never-miss assertion:** the SAME writes-class fixture tool must be fail-closed identically on all three surfaces: MCP elicitation-deny, NDJSON without `auto_confirm`, CLI without `-y` — one marker-spy tool, three suites, marker absent in all deny cases. (3) Elicitation-approve runs the tool; a host WITHOUT elicitation capability gets deny-with-explanation and the marker stays absent. (4) **stdout purity:** run a deliberately noisy fixture tool (prints to stdout and stderr); assert the server's stdout parses as a pure JSON-RPC line stream and the noise arrived as logging notifications — one stray print corrupts stdio JSON-RPC, so this is the highest-value regression test on this surface. (5) Name mangling: `wf__git_quicksave` round-trips to `git.quicksave`; a registry test asserts no mangled name collides with an existing tool name. (6) Annotations golden per danger level; assert `readOnlyHint` ABSENT on writes tools (checklist #3). (7) Sampling path: with sampling capability on, an `*_llm_*` call produces a sampling request at the T4 client and NO provider request at the stub; capability off → the reverse (assert both directions). (8) `message` frame → deprecation error frame, golden text. (9) Loop removal: `declare -F agent_run_llm_loop` fails; the full suite still passes (deletion regressions hide elsewhere — same rule as T1). (10) **SIGPIPE:** kill the T4 client mid-response; assert the server runs its cleanup (marker in the trap) instead of dying uncleanly — the current trap covers `EXIT INT TERM` only **[verified]**, so SIGPIPE must be added. (11) **Concurrent ids:** T4 sends request B before A's answer; assert both answers arrive with the correct ids and no interleaved corruption. (12) **Cancellation:** a `notifications/cancelled` for an in-flight call is acknowledged without corrupting the stream (best-effort semantics documented until B13 provides real cancellation). (13) **Nested consent:** a `batch` containing one writes-class call fires exactly one elicitation, and a deny leaves the batch's other results intact and the marker absent. (14) **UTF-8 truncation boundary:** a result truncated at the cap remains valid UTF-8 (never cut mid-codepoint); NUL/invalid bytes in tool output arrive escaped or spilled, never raw in the JSON-RPC line. (15) M3's assertion-preservation map exists and is committed alongside any test deletion; M4's deprecation-warning config test passes.
**Tests & assertions:** (1) Table-driven fuzz cases: unknown field, missing required field, string-for-integer, integer-for-string, `arguments` sent as a JSON string, extra fields, null values. (2) Assert each error message contains the offending field name AND the list of valid fields (checklist #5); assert the did-you-mean suggestion appears when a near-miss exists. (3) Coercion cases: use an echo-fixture tool that prints the arguments it actually received; assert the coerced value arrived with the correct type. (4) Spy (checklist #1): the underlying tool function must NOT run on a rejected call — marker file. (5) Assert the generic positional fallback is never reached for invalid input.

### T9 — Capability profiles: mid-tier providers + connected MCP hosts · Effort M · Depends: T8 ·
**What:** Two kinds of profiles. **(a) Provider profile** — for the LLM endpoints that Yantra's 22 `*_llm_*` tools still call directly via `llm_analyze`: probe and record context-window size (feeds T10), `response_format` support (whether the existing constraint can be sent), vision support (F11 — a vision-but-not-tools provider is fine here, because `llm_analyze` never sends tools), metered flag (`probe:false`, NEW config key — skips probing entirely), and cold-load behavior (F13). Probing for tool-call formats, parallel calls, `tool_choice`, and id formats is OUT OF SCOPE — those concern the host's loop and are governed by checklist IV-B.1. **(b) Host capability record** — captured from the MCP handshake: does the connected host support sampling? elicitation? roots? This record drives every fallback: no sampling → `*_llm_*` tools use the provider profile; no elicitation → writes-class tools deny with explanation (D5). Extend `doctor` to print both profiles.
**Why:** Yantra still makes outbound LLM calls (single-shot only) and still needs to know what the connected host can do; both must be known facts, not assumptions.
**Files:** `harness/core/providers.sh`, `harness/core/doctor.sh`, the T8 handshake code.
**Done when:** `doctor` shows both profiles; a host without elicitation gets deny-with-explanation on a writes tool; a metered provider is never probed.
**Tests & assertions:** (1) Mock providers per scenario; assert each provider-profile field. (2) **Metered protection stays the never-miss assertion:** a `probe:false` provider receives ZERO requests — count them at the stub. (3) Host record: T4 client handshakes with capabilities on/off; assert the record and assert the correct fallback path fired in each case (sampling-off → provider request observed at the stub; elicitation-off → deny message AND marker-spy proves the tool did not run). (4) Config override beats probed values. (5) Doctor output golden per scenario.





### T10 — Tool-result budgets + resource links; mid-tier call budgets · Effort M · Depends: T8, T9 ·
**What:** Two halves. **(a) Tool-result budgets for hosts:** the server cannot know the host model's context window, so: a configurable per-result size cap (sane small-model default); any output over the cap is written to a file and returned as an **MCP resource link** plus a short inline summary — the host fetches the bulk only if needed (this promotes IV-A row 11 from a note to the core mechanism). On the NDJSON/CLI surfaces, the same spill-to-file happens and the notice names the path. **(b) Budgets for Yantra's own `llm_analyze` calls:** derive the payload cap from the provider profile's context size (T9); keep the token pre-check (chars ÷ 4), the `jq --rawfile` rule for large embeds, the **silent-truncation detector** (compare estimated sent tokens vs the response's `usage.prompt_tokens` / `prompt_eval_count`; big shortfall → loud warning with the Ollama `num_ctx` fix — F1), and the **cold-load grace** (warm-up ping, longer first-call budget — F13). Fixes defect j: the 1 MiB / 4 MiB constants go away.
**Files:** `harness/lib/constants.sh`, `harness/core/llm.sh`, `harness/core/tools.sh` (result spill), T8's result encoder.
**Spill-file lifecycle (found missing during review):** spilled result files must OUTLIVE the response (the host fetches the link later) yet be garbage-collected eventually. Policy (NEW mechanism): write to a per-session directory under the state dir; never delete in the same session; GC files older than a configurable retention (default 7 days) at boot — the existing time-based cleanup pattern **[verified in `core/cleanup.sh`]** extends naturally. A `resources/read` for a GC'd or deleted file returns a clean not-found error, never a crash. Disk-full during spill fails the call with a message, not a broken link.
**Done when:** an oversized tool result arrives as link + summary over MCP and as path-notice on the CLI; the truncation warning fires on a shortfall and stays silent within tolerance; a cold Ollama model survives its first `*_llm_*` call; the spill lifecycle tests below pass.
**Tests & assertions:** (1) 100 KB fixture output → assert inline part ≤ cap, assert the linked resource resolves via `resources/read` (T4 client) to bytes identical to the original (checklist #4 — the link must not lie). (2) Detector: mocked `usage.prompt_tokens` far below the estimate → warning with fix text; **within-tolerance companion case fires NO warning** (checklist #6). (3) Cold-load: stub times out first request, serves second → assert `provider_mark_dead` never called (marker spy) and the call succeeds. (4) CLI/NDJSON parity: same fixture spills to the same file content on all three surfaces (an L3 parity suite case). (5) Lifecycle: a spilled file survives the end of its call and resolves later in the same session; a fixture file older than retention is GC'd at boot; `resources/read` on a deleted file returns a structured not-found; a simulated disk-full (tiny tmpfs or quota) fails the call with a named error and emits NO link (checklist #6 — a link that cannot resolve is the false positive here).


### T11 — Discovery: one backend, selection mode chosen by evals · Effort M · Depends: T5
> **DONE (2026-07-13).** harness/tools/discovery.sh: an `intent` facet on every
> tool/workflow (discovery|verify|transform|execute, derived from danger + a
> name-based verify refinement); ONE ranked search backend (`discovery_search`,
> name+description, typo-tolerant); meta-tools `search_tools` (search mode, with an
> `intent` filter for menu mode), `describe_tool`, and consent-gated
> `enable_category` — which over MCP is applied in-process (mcp_enable_category)
> and emits `notifications/tools/list_changed`. Default core wire stays ~4.3 KB
> (core + 3 meta-tools, under the 6 KB cap). Which selection mode (search vs menu)
> ships as default is still the T5 eval decision — both surfaces exist over the one
> backend.
**What:** Build ONE search/index backend over the registry (reuse the `wf_suggest`-style matching, extended over tool names + the new descriptions from T6, plus a new `intent` facet on every registry entry: `discovery` | `transform` | `verify` | `execute` — largely derivable from danger levels). On top of that single backend, expose TWO selection surfaces as prompt variants: (a) **search-mode** — a `search_tools {query}` meta-tool (NEW) returning the full schemas of the top ~8 matches (this assumes the model can write a search query — unproven for tiny models); (b) **menu-mode** — the model first picks one of the four intent words, then receives that intent's short tool menu (this only asks the model to choose, never to formulate). Also expose `describe_tool {name}` and `enable_category {name}` (both NEW meta-tools, consent-gated — category *gating* exists in the harness, but no runtime enable tool does). Over MCP, `enable_category` must emit a `tools/list_changed` notification so the host refetches. The default wire set stays ~6 core tools + the meta-tools.
**Why:** This resolves the central tension in I.3: 659 tools cannot be handed to a small model, but a session must be able to reach them. Which selection mode small models navigate better is an empirical question — run both on T5, ship the winner as default, keep the loser as a config option (Decision D2). "Menus dramatically narrow the decision space" is a claim to be measured here, not assumed.
**Files:** `harness/core/tools.sh` (meta-tool registration, intent facet), `harness/core/workflows.sh`, T8's notification path.
**Done when:** a ≤14B model completes at least one T5 task that requires a non-core tool it reached by itself; the higher-scoring selection mode becomes the default.
**Tests & assertions:** (1) Registry walk: every tool and workflow has an `intent` value from the four-value set; the danger→intent derivation table is asserted as a golden mapping. (2) Backend: query → ranked ids as golden tests, including a typo query. (3) Default wire set: assert total bytes of the default tools JSON under a recorded cap (D6). (4) `enable_category` without consent is denied — reuse the marker-spy gate pattern. (5) After `enable_category` (with consent), assert a `tools/list_changed` notification is emitted (T4 client observes it) and a subsequent `tools/list` contains the new category — and the consent-denied case emits NO notification (checklist #6). (6) Both selection modes produce recorded T5 rows (mode is a column).

### T12 — Plan store: tools + resource + result decoration · Effort M · Depends: T8 (rollback deferred to B2) ·
**What:** Three tools backed by the existing SQLite database: `plan_create {steps:[…]}`, `plan_step_done`, `plan_status`. **Durability mechanism (server-side, host-independent):** (a) the current plan is exposed as an MCP **resource** (`plan://current`, NEW) the host can pin into context; (b) **result decoration** (NEW mechanism) — while a plan is active, every tool result gets exactly one appended line: `PLAN: step N of M — <step text>` (configurable off). Decoration is server-side, so plan durability works on ANY host, even one that never touches the plan tools — the same design goal the loop injection served. Plans stay optional; `plan_rollback_step` still ships only with B2.
**Why:** in long sessions the plan decays out of the host's context; small models drift fastest. The server re-surfacing the current step inside every result is the only channel a pure tool server has — and it is enough, because results are the one thing the host must show the model.
**Files:** `harness/core/db.sh`, new `harness/tools/plan.sh`, T8's result encoder + resource handler.
**Done when:** a 30+ turn small-model session on T5 tasks (driven by the reference host) shows one consistent externalized plan being followed rather than re-derived.
**Tests & assertions:** (1) CRUD through `tool_dispatch`. (2) Decoration appears EXACTLY once per result, never twice, and only while a plan is active — and the no-plan case is byte-identical to undecorated output (checklist #4). (3) **Non-accumulation:** the decoration must never be written into any stored state (events, plan rows, spilled result files) — assert the persisted artifacts contain zero `PLAN:` lines; decoration is applied at encode time only. (4) The `plan://current` resource resolves via T4 and equals `plan_status` output. (5) Two plans in two project dirs never cross.

---
---
## ✂ CUT LINE — everything below is backlog: scoped, ordered, NOT committed
---

**Testing rule for backlog items (Decision D10 applies below the line too):** every item's Done-when must land as an executable suite following the II.0 conventions before the item is called done. Assertion hints are included below only where the easy-to-miss assertion is non-obvious.


- **B1 — LSP semantic operations, phase A: read-only queries** (Effort M–L). Wrap the language servers the project already has (`gopls`, `rust-analyzer`, `pyright`, `typescript-language-server`) behind uniform tools: `find_callers`, `find_implementations`, `goto_definition`. Hard parts, named up front: the LSP initialize / didOpen / didChange document-sync lifecycle, and the fact that LSP positions are counted in **UTF-16 code units**, not bytes. The awk knowledge graph remains the zero-dependency floor; without servers, degrade gracefully with an honest note. Done when call-level questions the import-level KG cannot answer are answered on ≥2 languages.
- **B2 — Checkpoint/undo via git** (Effort M). Snapshot the worktree (a temp commit on a shadow ref, or stash-based) before any write-class tool or workflow runs; add `workspace.undo` (NEW tool) to revert to the last checkpoint. Non-git projects degrade to file-copy snapshots of touched paths. The `changes` table already logs writes **[verified: 3 insert sites]** but nothing can revert them. Done when write → undo restores a byte-identical worktree. *Assertion hints:* `git status --porcelain` empty AND `git diff --exit-code` clean AND checksums of untracked files match (tracked-file diffing alone misses untracked damage); also assert a checkpoint exists BEFORE the write ran, not after.
- **B3 — LSP phase B: `rename_symbol`** (Effort L; needs B1, B2). The genuinely hard half: applying multi-file `WorkspaceEdit` responses correctly. Auto-checkpoint (B2) before applying. Small-first rationale: `rename_symbol {old, new}` asks a small model for two words; the equivalent `edit` chain asks it to construct exact-match strings across files — a known failure mode **[unmeasured until run]**. Done when a correct cross-file rename passes on a fixture that a small model verifiably fails via `edit`.
- **B4 — Exemplar finder** (Effort M). `find_similar {kind|symbol}` (NEW tool) returns the closest existing example in the user's own repository (ranked via KG structure, optionally the existing `ai_rag_*` embeddings). Purpose: "here is this repo's most similar handler/widget/migration — adapt it." Adapting a concrete in-repo example is more reliable for a small model than generating from a generic scaffold, and it enforces the skills' prime directive: follow existing project conventions (Decision D4). The existing `scaffold.*` workflows stay for greenfield cases. Done when a small model passes an "add another X like the existing ones" T5 task it otherwise fails.
- **B5 — stderr/stdout split in `_tool_exec`** (Effort M). Opt-in per tool via an `io=split` flag (NEW) on `tool_register` — opt-in because many binaries (cargo, pytest) intentionally write useful signal to stderr. Migrate core tools first. On the MCP surface, captured stderr routes to logging notifications instead (PART IV-A row 7). Fixes defect g incrementally.
- **B6 — `--format json` on the CLI** (Effort S). Subcommand mode gains a `--format json` option (NEW) with a uniform machine envelope: `{ok, tool, data, diagnostics, hint}`. Done when every catalog entry emits parseable JSON on stdout only.
- **B7 — Plugin directories** (Effort M). Source `~/.config/yantra/tools.d/*.sh` and `<project>/.yantra/tools/*.sh` (both NEW plugin paths) at registration time; plugin tools use the existing `tool_register`/`wf_register` and appear in catalogs and discovery like built-ins. A malformed plugin must fail loudly without breaking boot.
- **B8 — Deterministic-only toggle** (Effort S). A `--no-llm` flag (NEW) / config that hides `mid`/`high` complexity tools from catalogs and denies them with a clear message. Today this happens only implicitly when no provider is configured.
- **B9 — NDJSON frame schemas + audit export** (Effort S). Publish a JSON Schema for every machine-mode frame type (`ready`, `ack`, `result`, `progress`, `error`, …); a test round-trips every emitted frame through its schema. Add an `export --format jsonl` verb (NEW) to the existing `monitor` tools (`tools/monitor.sh` **[verified present]**) for the events table.
- **B10 — Honor `Retry-After` on HTTP 429** (Effort S). In `_llm_request`, read the header instead of the fixed `sleep attempt*3`.
- **B11 — Deprecation policy + catalog slimming** (Effort S+M). Write the policy (one release of aliased warnings before any rename/removal); then demote `brew` (20 macOS-only tools) and the host-mutating `sec_dns_hosts_*` tools to an opt-in extras tier, and consolidate the overlap between `disk.*` workflows and `fs_dirsize`/`fs_largest`/`fs_disk` so each question has one canonical answer. Done when the default catalog token count drops.
- **B12 — Incremental knowledge-graph hashing** (Effort M). Map file → sha256 (or mtime+size fast path) in SQLite; `kg_build` re-parses only changed files. Verified absent today: `core/kg.sh` re-parses everything **[verified]**. Optional follow-on: a `--watch` mode via the existing `files_watch` helper.
- **B13 — Background jobs** (Effort L). `job_run`, `job_status`, `job_logs {tail}`, `job_cancel` (all NEW tools); `job_run` returns a job id; implemented with `setsid` + pid/log files + the existing SQLite. Design the job model to match the MCP Tasks extension (PART IV-A row 10) so one implementation serves both surfaces. Only after this lands may the `cancel` capability be re-advertised. *Assertion hints:* after `job_cancel`, assert `kill -0` fails for every PID in the job's process GROUP (a lone parent-kill leaves orphans running); assert the job survives the NDJSON frame that started it ending; assert `job_logs {tail}` on a live job returns partial output.
- **B14 — Parallel `batch`** (Effort M). Run independent *read-only* calls concurrently (`wait -n`, results kept in order, concurrency cap); any writes-class call in a batch stays serial.


- **B15 — Opt-in Linux sandbox** (Effort M). `bwrap` preferred / `unshare` fallback wrapping `tool_bash` and build/test steps, plus the portable subset (`ulimit -v/-t`; `timeout` already exists) everywhere. Never a hard dependency — Yantra targets macOS and FreeBSD, where none of bwrap/overlayfs/cgroups exist; absent sandbox binaries → current behavior plus a doctor note.
- **B16 — Selective test execution via the KG** (Effort L; needs B12). Map changed symbols → dependent test files; run those first as a fast pre-check. **The full suite remains the merge gate** — import-level edges give false negatives, and a missed test is worse than a slow suite. Done when selective runs catch ≥95% of full-suite failures on the eval repos at a fraction of the runtime.
- **B17 — Optional tree-sitter KG backend** (Effort M). If the `tree-sitter` CLI and grammars are present, use S-expression queries for symbol extraction; the awk backend stays the zero-dependency default. Accepted criticism: line-oriented awk misses nested multi-line constructs.

- **B18 — Opt-in comment pruning for LLM payloads** (Effort S). A `prune:true` argument (NEW) on `*_llm_*` tools strips block comments/docstrings before sending source to the model. Default OFF — comments carry intent, and silently stripping them can degrade diagnosis.
- **B19 — Coverage additions as opt-in extras** (Effort M each; needs T11; governed by Decision D6). Ranked: an `http_*` request tool with assertions (reuse `browse`'s SSRF guards); `gh`/`glab` forge tools; sandboxed `json_transform`/`yaml_transform`; `archive_fetch` with checksum verification; read-only Terraform (`tf_plan_summary`); systemd/cron read-only introspection. Each ships extras-tier, path-guarded, doctor-probed, with a docs page.
- **B20 — Write `SECURITY.md` (NEW file) + close the residual unknown** (Effort S). No such file exists in the repository; the name is the standard root-level security-policy convention that GitHub surfaces. In it, document the I.5 trust model ("running a project's build executes the project"); state which surfaces accept arbitrary commands and how each is gated; trace the one untraced `eval` caller (`lib/files.sh:132`).
- **B21 — Evals expansion** (Effort M; needs T5). Grow the T5 seed: more tasks, more models, more engines, plus latency and per-call cost tracing. README claims must link to results.

---

# PART III — DECISIONS (standing rules; a task that conflicts with these is wrong)

- **D1 — Small models first** (owner decision). Large-model gains are welcome side effects, never goals. Consequence: MCP is demoted (D2); call-validity, budgets, and discovery lead the plan.
- **D2 — One discovery backend, two selection modes.** T11 builds a single search/index backend; search-mode and menu-mode are prompt variants over it. Evals (T5) pick the default; the other stays a config option, never a second maintained system. The four-intent taxonomy is a *facet* on the registry; it does NOT replace the 36 domain categories, because domain categories map to gating and to which binaries are actually installed ("transform" says nothing about whether kubectl exists).
- **D3 — Semantic operations are delegation, never construction.** B1/B3 wrap existing LSP servers; Yantra never re-implements rename/references itself. Literal `edit` (exact string replacement) remains the single-file workhorse — it is more reliable than semantic operations when a server's index is stale.
- **D4 — Exemplars over templates.** No library of canned code templates. Generic templates go stale and structurally violate the skills' prime directive (follow existing project conventions). The exemplar finder (B4) serves the same need — adapt a concrete in-repo example — using the repository itself as the template corpus. Greenfield scaffolding partially exists already as the `scaffold.*` workflows.
- **D5 — MCP consent via elicitation.** On the MCP surface, a writes-class tool triggers an elicitation request carrying the same preview `confirm_action` already builds; clients without elicitation support get a deny-with-explanation. Tool annotations (readOnlyHint / destructiveHint) are advisory metadata only; server-side gating stays authoritative.
- **D6 — Catalog-token neutrality.** Tool granularity and catalog size trade off directly, and small context windows pay the bill first. Therefore: the token count of the default wire tool list may not increase; every new capability ships as an opt-in extra reachable through discovery (T11). Corollary: thin, token-bounded, enum-carrying tool wrappers are the product — a small model cannot compose `docker ps --filter status=exited`, but it can call `docker_ps {target:"stopped"}`.
- **D7 — Trust model over eval-paranoia.** Per I.5: running a project's own build IS executing the project. Document this honestly (B20) rather than pretending to sandbox it away; the Linux sandbox (B15) is opt-in defense-in-depth, not the security model.
- **D8 — Engine-compatibility boundary.** Yantra absorbs engine divergence only where Yantra still talks to an engine: the single-shot `*_llm_*` calls (T9 provider profile, T10 budgets/detector). All loop-side divergence — tool-call wire formats, template round-trips, salvage — is the MCP host's responsibility, specified as the checklist IV-B.1 that T5 uses to qualify hosts. The 659 tools stay engine-agnostic either way.
- **D9 — Non-streaming tool turns (host guidance).** Two engines drop or corrupt streamed tool-call deltas (failure F7). This is now requirement H7 in checklist IV-B.1: a qualifying host must not stream tool turns, or must prove its reassembly. Yantra itself no longer runs the turn in question.
- **D10 — Tests are the definition of done.** A task is not done until every assertion listed in its "Tests & assertions" field exists as an executable test following the II.0 conventions. The Done-when line is the summary; the assertions are the contract. This applies to backlog items too. Rationale: this document's audience includes small models, and the II.0 checklist encodes the assertions they most reliably forget (negatives, absences, false-positive guards, idempotence, pairing integrity).
- **D11 — Yantra is a pure MCP tool server; the reasoning loop is removed** (owner decision). The boundary: **Yantra owns** the tools, workflows, schemas, validation, consent gating, discovery, plans, budgets/resource links, and single-shot `*_llm_*` calls with their providers. **The MCP host owns** the conversation, the model, tool-call generation and parsing, history round-trips, and retry policy. Kept escape hatch: the NDJSON `run`/`dispatch`/`list` frames and the CLI remain, so any thin external loop can drive Yantra without MCP. **Stated risk:** small-local-model users depend on third-party host quality for the loop-side layers (tool-call parsing, history round-trips). Mitigations: the IV-B.1 host checklist, T5's mandatory host column, and the kept NDJSON surface. If measured host quality proves unacceptable (T5 evidence, not opinion), reopening a minimal driver requires an owner-approved amendment — never a silent revert.
- **D12 — Migrations are characterization-gated.** Any change that deletes or moves user-visible behavior follows the II.M playbook: golden characterization tests before refactor (M1), coexistence with an evidence gate before deletion (M2), assertion-preservation mapping before test deletion (M3), deprecation warnings instead of silent no-ops (M4). A migration bug is not fixed until its reproduction is a committed fixture (II.0.2 rule b).
- **D13 — De-alias the tool surface; name every tool for its explicit action** (owner amendment, 2026-07-14). A registered tool must earn its place: it stays only if it adds encoded knowledge, safety the raw binary lacks, aggregation of several commands, output shaping, or LLM reasoning. A `command -v` check plus a single passthrough of the user's args does **not** qualify — the always-on `bash` core tool runs that directly (writes stay consent-gated there). This **narrows D1's "breadth"**: breadth means a coherent *capability* per domain, not a wrapper per subcommand. Surviving tools are named `category_action` with an explicit action verb (no unix-isms like `ps`/`grep`/`stat`, no bare nouns like `dbsize`/`dangling`, no prefix/category mismatch like `remote_*` in the `ssh` category); domain-standard tool names (`clippy`, `pytest`, `sbom`, `osv`, `pprof`) are the explicit action in-domain and are kept. Renames are hard (no back-compat aliases; the project is pre-release). Complementary directive: prefer **composite workflows that chain 2+ dependencies** into one task-level action a novice would ask for (`media.podcast`, `data.diff`, `net.watch`, …) over more single-binary tools. Executed 2026-07-14: 690→593 tools, 105→112 workflows; mapping in `docs/MIGRATION_MCP_ONLY.md`.

## III.1 What already exists (do not rebuild these — verified in source during this review)

ripgrep preference with grep fallback (`lib/io.sh`); jq-only JSON construction (`lib/json.sh`); semantic search / embeddings (`ai_rag_index`/`ai_rag_query` on DuckDB, `ollama_embed`); OpenAI-format tool definitions (`build_tools_json`); `git.bisect`; property-based testing (`python_hypothesis`); the auto-generated CLI catalog (`docs/gen_cli_md.sh`); schema-constrained JSON output for single-shot calls (`llm_analyze` `format` parameter); category gating; the review/perf finder suites (`quality_*`, `sec_semgrep`, `go_test_race`, `perf_*`); token-bounded git views; the tail-position turn reminder (which is also the published mitigation for Ollama's front-truncation, failure F1); tolerance for tool-call `arguments` arriving as string or object on the *receiving* side (the sending-side hazard belongs to the host: requirement H5 in IV-B.1).


---

# PART IV — DESIGN NOTES

## IV-A. MCP protocol mapping (reference for task T8 — the primary surface)

Context: MCP's current stable specification revision is **2025-11-25**. The **2026-07-28** revision (final ships July 28, 2026) makes the protocol stateless — it removes the `initialize` handshake, which is *simpler* to implement in Bash — and adds an extensions framework including a Tasks extension. **Caveat:** these mappings come from release notes and spec summaries reviewed on July 13, 2026, not a line-by-line schema read; verify each row against the pinned schema during implementation. Client support for sampling and elicitation varies, so every row needs its stated fallback.

| # | MCP feature | What it does | Yantra already has | Implementation note |
|---|---|---|---|---|
| 1 | **Elicitation** | Server asks the user a structured question mid-call | `confirm_action` builds exactly the needed preview text | The consent answer (D5). Fallback: deny with the instructive message. |
| 2 | **Sampling** | Server asks the *client's* model to run a completion | The 22 `*_llm_*` diagnostic tools | Zero provider config needed for MCP users; Yantra's own tiered providers remain the fallback. |
| 3 | **Resources** | Client fetches reference documents on demand | The 59 `docs/cli/*.md` pages, toolchain profile, scan, doctor report; KG as templates (`kg://symbol/{name}`) | Yantra's load-only-what-you-need docs design IS resources under another name. |
| 4 | **Prompts** | Named reusable prompt templates | `skills.sh` role prompts | Add a "getting started with search_tools" prompt. |
| 5 | **Roots** | Client tells the server which directories are in scope | `YCA_PROJECT_DIR` + the path guard | On `roots/list_changed`: re-scan, re-derive `YCA_SAFETY_PATHS`. |
| 6 | **Progress notifications** | Server streams progress of a long call | `emit_progress` (already label + percent) | `pipeline.ci`'s 0/25/50/75/100 maps directly. |
| 7 | **Logging notifications** | Server sends diagnostics out-of-band | `logmsg` / `log_warn` / tool stderr | Solves B5 on this surface with no per-tool flag: diagnostics → notifications, results stay clean. |
| 8 | **Tool annotations** | Hints like readOnlyHint / destructiveHint | Danger levels | safe→readOnlyHint; destructive/dangerous→destructiveHint; add idempotentHint and openWorldHint (`browse`, `net_*`, `s3_*`). The spec treats annotations as untrusted — advisory only; server-side gating (row 1) stays authoritative. |
| 9 | **tools/list_changed + pagination** | Tell the client the tool list changed | Category gating exists (`YCA_CAT_ENABLED`, config-driven **[verified]**) and `:reload`; a runtime `enable_category` does NOT exist — it is the (NEW) T11 meta-tool | Notify instead of forcing reconnect; paginate the full 659 only on request. |
| 10 | **Tasks extension (2026-07-28)** | A tool call may return a task handle; client polls/cancels | B13 background jobs | Server decides when a call becomes a task (the duration hint on tiers); `tasks/cancel` finally makes the once-phantom `cancel` capability real via a standard. |
| 11 | **Resource links in results** | Return a link to bulk output instead of the bytes | new — the biggest untapped token saver | Full test logs → file + link + short inline summary; the model fetches bulk only if needed. Pairs with T10's truncation notices. |
| 12 | **outputSchema / structuredContent** | Declare the shape of tool results | The `{ok, data}` envelopes | Hosts parse results without spending model tokens. |
| 13 | **Completions** | Autocomplete argument values | Live infrastructure access | Autocomplete container/pod/workflow names — rare among MCP servers; Yantra sits on live systems. |
| 14 | **Lazy boot** | stdio servers are spawned by clients; boot must be fast | Subcommand mode already skips the slow probes | Reuse that fast path; probe on demand. |
| 15 | **List caching** | Clients skip refetching unchanged lists | The per-agent tools-JSON cache with stable byte order | Expose a hash of the list. |
| 16 | **Conformance & registry** | Official test suite; public server index | The repo's test-suite culture | Run the conformance suite in CI when consumable; publish a `server.json` (NEW artifact) to the MCP Registry. |
| 17 | **Transports** | stdio now; streamable HTTP later | — | The stateless core makes load-balanced HTTP plausible, but HTTP serving is where pure Bash hurts most: ship stdio; put HTTP behind a proxy if ever. |

Implementation notes: MCP tool names cannot contain dots — mangle `git.quicksave` → `wf__git_quicksave` and keep a reverse map. Isolate the 2025-11-25 handshake in ONE function so the 2026-07-28 stateless migration is a small diff, not a rewrite.

## IV-B. Inference-engine tool-calling failure catalog (reference for T5, T10, T9, and host selection)

**Scope.** With Yantra's loop removed (D11), failures that occur while *generating and parsing tool calls* or *round-tripping conversation history* (F2–F5, F7, F8, F10) are the **MCP host's** problem. This catalog now serves two purposes: (1) it is the evidence behind the **host-requirements checklist IV-B.1** below, which T5 uses to qualify hosts for small local models; (2) it documents Yantra's **residual server-side exposure** — the single-shot `*_llm_*` calls (F1, F6-partial, F13, handled by T10/T9), argument handling from any host (F9 → T7), and schema constraints (F12 → T6).

### IV-B.1 Host-requirements checklist (mandatory qualification criteria)

A host MUST satisfy all of the following to drive small local models against Yantra. T5 records host + version per eval row so every failure traces unambiguously.

- **H1 — Context honesty.** The host must size prompts to the model's real window or detect silent truncation (compare sent tokens vs `usage.prompt_tokens` / `prompt_eval_count`); it must keep the tool list from being trimmed off the front (F1).
- **H2 — Salvage or reliable parsing**. When the engine delivers a tool call as plain text, the host must either parse the major wire formats — Hermes/Qwen `<tool_call>{JSON}</tool_call>`, Mistral `[TOOL_CALLS][…]`, bare Llama-3 JSON using `"parameters"` — or run a correctly configured engine parser (vLLM: right `--tool-call-parser` + `--enable-auto-tool-choice`; llama.cpp: `--jinja`) (F3/F4).
- **H3 — Reasoning-tag handling + false-positive guard**. Strip/route `<think>…</think>` before parsing; never mistake JSON-shaped prose for a call — a salvager without the false-positive guard is a hallucination engine (F6).
- **H4 — Constrained decoding where available**. Use Ollama `format` / OpenAI strict / llama.cpp-native grammars for call generation, and keep tool schemas flat (F12; Yantra guarantees flatness via T6).
- **H5 — History round-trip discipline**. Canonicalize `arguments` string-vs-object per template; keep call-id ↔ result-id **pairing integrity** (Mistral: exactly 9 characters); respect system-message placement; emulate a missing `tool` role; `null` content → `""`; and the normalization must be **idempotent** (F5).
- **H6 — Bounded parallelism.** Respect the model's parallel-call ability (Llama-3: none; Mistral 7B: unreliable) — one call per turn for models that cannot do more (F10).
- **H7 — No streamed tool turns**. Ollama `/v1` drops streamed tool-call deltas; vLLM has an open hermes-streaming bug. Accumulate-then-parse, or prove the reassembly (F7).
- **H8 — Capability truth.** Detect tool-training and vision independently; never send tools to a non-tool model or conflate the two flags (F2, F11).


Compiled July 13, 2026 from vendor documentation (vLLM tool-calling docs, llama.cpp `docs/function-calling.md`, Ollama API docs and FAQ) and open issue trackers. **Two caveats.** (1) Engine behavior changes fast; re-verify every item against the deployed engine version during implementation. (2) Coverage honesty: Ollama, vLLM, and llama.cpp were researched directly; LM Studio embeds llama.cpp and inherits most of its items; SGLang and TGI were NOT individually researched — assume the same failure classes until the T9 probe says otherwise (probing instead of assuming is exactly why T9 exists).

| # | Failure — plain description | Engine(s) where observed | What the user sees | Which task absorbs it |
|---|---|---|---|---|
| F1 | **Silent context truncation.** When the prompt exceeds the context window, the server cuts it from the FRONT without any error — and the front is where the system prompt and the tool definitions live. Ollama's OpenAI-compat `/v1` endpoint additionally ignores the per-request `num_ctx` option (default is often 4096 tokens). Detection: the response's `usage.prompt_tokens` (native Ollama: `prompt_eval_count`) is much smaller than what you sent. | Ollama (docs/FAQ; issues #7796, #4028) | "The model suddenly stopped calling tools / forgot its instructions mid-session" | Split: hosts must satisfy H1 for the loop; T10(c) keeps the detector for Yantra's own `*_llm_*` calls. |
| F2 | **The model was never trained for tools.** Rare below ~7B parameters. The server either returns an error ("model does not support tools") or the model chats forever and never calls anything. | All engines (a model property, not an engine bug) | The agent never acts | Host scope (H8). Yantra's T9 provider probe covers only its own `*_llm_*` endpoints. |
| F3 | **Server misconfiguration fails silently.** vLLM: using the wrong `--tool-call-parser` for the model family, or omitting `--enable-auto-tool-choice`, produces no tool calls or raw text — with no error. llama.cpp: omitting `--jinja` produces wrong output. A custom system prompt that teaches a different call format breaks the server-side parser. | vLLM, llama.cpp | Tool calls appear as plain text in the reply, or never appear | Host scope (H2); IV-B.1 names the server flags a host's diagnostics should point at. |
| F4 | **Different model families emit different wire formats.** Hermes/Qwen: `<tool_call>{JSON}</tool_call>`. Mistral: `[TOOL_CALLS][{…}]`. Llama-3: bare JSON that says `"parameters"` instead of `"arguments"`. Llama-3.2/4: pythonic calls. Arrays are sometimes serialized as strings. | All (surfaces whenever F3 applies) | Salvageable text; or wrongly-typed arguments | Host scope (H2). Residual Yantra side: T7 coerces argument types arriving from ANY host. |
| F5 | **Re-sending history breaks templates.** Some chat templates crash when `tool_call.arguments` comes back as a JSON string instead of an object (a shipped GGUF template was patched for exactly this). Some templates contain hard `raise_exception` checks on message order and abort the whole request — and runtimes appending their own system message trip those checks. Some templates have no `tool` role or no `system` role at all. | llama.cpp / the GGUF ecosystem, LM Studio, Ollama (they share templates) | An HTTP 500 / Jinja exception on the turn AFTER a successful tool call — the most confusing possible place | Host scope (H5). Yantra's role:user reminder was the in-repo proof this hazard is real **[historical strength, loop removed]**. |
| F6 | **Reasoning tags interfere.** Thinking models emit `<think>…</think>` blocks; tool calls hide inside or after them; multiple think blocks break naive parsing; a small output budget gets fully consumed by thinking, leaving an empty answer. DeepSeek-R1's official template is buggy enough that llama.cpp ships an override file. | llama.cpp, Ollama (R1/QwQ-class models) | Garbled content; missing calls; empty replies | Host scope (H3) for the loop; residual Yantra side: `*_llm_*` calls to thinking models keep the generous-budget rule (T10(b) / T9(a)). |
| F7 | **Streaming drops tool calls.** Ollama's `/v1` streaming drops tool-call delta chunks (Ollama's own provider docs warn against `/v1` for tools); vLLM has an open bug where hermes-parser streaming returns raw text. The model produced the call; the pipeline lost it. | Ollama `/v1`; vLLM (issue #31871) | Tool call generated but never delivered | Host scope (H7; D9). |
| F8 | **`tool_choice` is unreliable.** Ollama: `tool_choice:"required"` plus a large (~1600+ token) system prompt returns empty content and no calls with `finish_reason:"stop"` (open issue, 2026). vLLM supports `required` only from version 0.8.3. | Ollama; older vLLM | Silent no-op turns | Host scope (H2 retry discipline + H8). |
| F9 | **Argument types get corrupted.** Arrays and numbers arrive serialized as strings (documented for Llama-family models on vLLM). | vLLM (model-driven); others | The tool receives wrong types | T7 safe coercion + corrective errors. |
| F10 | **No parallel tool calls.** Llama-3 family: unsupported. Mistral 7B: unreliable. | Per vLLM docs (model property) | The second call in a turn is mangled or missing | Host scope (H6). |
| F11 | **Vision and tools are independent capabilities.** A model can see images but not call tools, or vice versa; clients that conflate the two flags break. Images also consume large chunks of exactly the small contexts these models have. Image transport differs: native Ollama uses an `images` field; the `/v1` endpoint accepts the OpenAI content-array with `image_url` data URIs. | Ollama; all engines | A request combining tools and an image fails, or one of the two is silently dropped | Host scope (H8) for the loop; Yantra's T9(a) provider profile records vision for its own `*_llm_*` providers. |
| F12 | **Constrained-decoding backends reject complex schemas.** Strict/grammar modes fail or silently disable on `anyOf`/`oneOf` and deep nesting. | vLLM strict mode; llama.cpp grammars | Constraint silently off, or a 400 | T6/T7 flat-schema rule (Yantra's schemas are already flat **[verified]**). |
| F13 | **Cold model load looks like a dead provider.** Loading a local model into memory can exceed connect/read timeouts; naive rotation logic then blacklists a healthy provider on its first call. | Ollama; llama.cpp | First request fails; provider abandoned | T10(d): warm-up ping + first-call grace period. |
