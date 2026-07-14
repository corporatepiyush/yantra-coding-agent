# Yantra Coding Agent — Real-World Playbooks

These are **end-to-end scenarios**, not a command reference. For the basics —
tools, workflows, discovery, consent — see **[GUIDE.md](GUIDE.md)** and the full
per-category reference in [cli/](cli/). What follows is how the pieces come
together on a real day: an incident, a release, a security questionnaire, a
podcast to ship.

**How to read these.** Yantra is an MCP server, so every step is a `tools/call`
the host sends. Reasoning steps belong to the **host**, not Yantra — they're
marked `⟶ host turn`. Two ideas run through every playbook:

- **`batch` — the multiplier, on by default.** Alongside read/write/edit/bash/
  browse, `batch` runs up to **100 tool calls in one request**, each through the
  same category and consent gates. It gathers ten pieces of evidence in one
  round-trip instead of ten. Shape:
  `{"name":"batch","arguments":{"calls":[{"tool":"NAME","args":{…}}, …]}}`. A
  failing sub-call is annotated (`[i] tool (rc=…)`) and never aborts the rest.
- **The split that saves money.** Gather deterministically (free), then let the
  host's model decide **only** at the judgment point. In every playbook a `batch`
  or workflow does the legwork for zero tokens; the model is spent exactly once,
  where judgment is required.

For brevity the `{"jsonrpc":"2.0","id":N}` envelope is elided — each JSON line is
the `params` of a `tools/call`. Enable a category once per session with
`enable_category` (or launch with `--enable <cat>`).

---

## 1. 2 a.m. — a service is flapping in production

`checkout-service` is restarting in a loop. Gather the whole picture in **one**
call, then let the host name the cause.

```json
{"name":"enable_category","arguments":{"category":"kubernetes"}}

// one batch = not-running pods + recent events + last logs + resource requests — zero tokens
{"name":"batch","arguments":{"calls":[
  {"tool":"k8s_pending_pods",  "args":{}},
  {"tool":"k8s_events",        "args":{"target":"prod"}},
  {"tool":"k8s_logs",          "args":{"pod":"checkout-service","lines":"200"}},
  {"tool":"k8s_pod_resources", "args":{"target":"prod"}}
]}}
```

⟶ **host turn:** with the four results in context, the model correlates the
OOMKill in events with the memory spike in `top` and the stack trace in logs, and
names which limit to raise — or call `k8s_llm_diagnose_pod` to have Yantra do
that correlation in one shot. Four kubectl calls, one round-trip, one paste of
context — instead of re-running kubectl (and re-billing) per hunch.

---

## 2. Podcast day — a 94-minute raw recording into a shippable episode

You recorded to `raw/ep42.wav` and need a normalized master, a distributable MP3,
a waveform, and show notes — none of which should cost tokens until the last step.

```json
{"name":"enable_category","arguments":{"category":"media"}}

// inspect first — codecs, sample rate, true duration (free)
{"name":"media_probe","arguments":{"file":"raw/ep42.wav"}}

// produce every deliverable in one batch (each is deterministic ffmpeg)
{"name":"batch","arguments":{"calls":[
  {"tool":"media_trim",         "args":{"file":"raw/ep42.wav","start":"0:37","duration":"93:20"}},
  {"tool":"media_normalize",    "args":{"file":"raw/ep42.wav"}},
  {"tool":"media_extract_audio","args":{"file":"raw/ep42.wav","format":"mp3"}},
  {"tool":"media_waveform",     "args":{"file":"raw/ep42.wav"}},
  {"tool":"media_transcribe",   "args":{"file":"raw/ep42.wav"}}
]}}
```

⟶ **host turn:** draft chapter markers and show notes from the transcript Yantra
just produced. The heavy lifting (loudness normalization, transcription,
waveform) was free and repeatable; the model only writes prose over extracted text.

---

## 3. Cutting a launch clip and scrubbing it before it goes public

From `demo-recording.mov` you want a 6-second GIF, a watermarked MP4, and —
critically — **no location or device metadata** leaking.

```json
{"name":"enable_category","arguments":{"category":"media"}}

{"name":"batch","arguments":{"calls":[
  {"tool":"media_make_gif",           "args":{"file":"demo-recording.mov","start":"0:12","duration":"6","fps":15}},
  {"tool":"media_trim",          "args":{"file":"demo-recording.mov","start":"0:10","duration":"45"}},
  {"tool":"media_watermark",     "args":{"file":"demo-recording.mov","text":"© Acme 2026"}},
  {"tool":"media_strip_metadata","args":{"file":"demo-recording.mov"}}
]}}

// sanity-check the cleaned file (codecs/streams; run `bash exiftool` for EXIF/GPS)
{"name":"media_probe","arguments":{"file":"demo-recording.mov"}}
```

If ffmpeg complains, don't guess — `media_llm_explain {"file":"…"}` reads the
probe + error and tells you the exact fix (wrong pixel format, missing codec, …).

---

## 4. Reviewing a 2,000-line PR you didn't write

Before you approve, you want the risk surface, not a vibe. Gather every red flag
at once, then ask for a verdict.

```json
{"name":"enable_category","arguments":{"category":"sec"}}
{"name":"enable_category","arguments":{"category":"quality"}}

{"name":"batch","arguments":{"calls":[
  {"tool":"fs_search",            "args":{"pattern":"(TODO|FIXME|console\\.log|binding.pry|debugger)","path":"src"}},
  {"tool":"sec_scan_secrets",        "args":{}},
  {"tool":"sec_semgrep",        "args":{}},
  {"tool":"quality_complexity", "args":{"path":"src"}},
  {"tool":"quality_deadcode",   "args":{"path":"src"}}
]}}

// deterministic gate before the model is even involved
{"name":"wf__test_run","arguments":{}}
```

⟶ **host turn:** given these findings, what are the top 3 risks and what should
the author change? The model reasons over real scanner output, not guesses.

---

## 5. A query got slow after last night's deploy

Point `PG_CONN` at the replica, pull the DBA evidence set in one call before
touching an index.

```json
{"name":"enable_category","arguments":{"category":"pg"}}   // export PG_CONN=postgresql://readonly@replica/app

{"name":"batch","arguments":{"calls":[
  {"tool":"pg_slow_queries",     "args":{}},
  {"tool":"pg_active_queries", "args":{}},
  {"tool":"pg_lock_waits",    "args":{}},
  {"tool":"pg_indexes",  "args":{"table":"orders"}},
  {"tool":"pg_explain",  "args":{"sql":"select * from orders where customer_id=$1 and status='open'"}}
]}}
```

⟶ **host turn:** the orders query does a seq scan — what index should I add, and
will it hurt writes? The model reasons over a real EXPLAIN and the real index
list; nobody guessed at your schema.

---

## 6. Security sent a vendor questionnaire due Friday

They want an SBOM, a CVE report, and evidence the image is clean. All
deterministic — the model only triages at the end.

```json
{"name":"enable_category","arguments":{"category":"sec"}}

{"name":"batch","arguments":{"calls":[
  {"tool":"sec_sbom",           "args":{"path":"."}},
  {"tool":"sec_dep_audit",      "args":{"path":"."}},
  {"tool":"sec_osv",            "args":{"path":"."}},
  {"tool":"sec_container_scan", "args":{"target":"registry.acme.io/app:1.8.0"}},
  {"tool":"sec_kube_bench",     "args":{}}
]}}
```

⟶ **host turn:** of these CVEs, which are actually reachable in our code path,
and what's the minimal set of upgrades to close the criticals?

---

## 7. "Explain how auth works" — onboarding onto a legacy monorepo

You inherited a 400k-line service. Build the code graph once, trace the symbol
deterministically, then let the host narrate — grounded in the graph, not
hallucinated.

```json
{"name":"wf__project_onboard","arguments":{}}            // structure, build, TODOs, what to enable
{"name":"enable_category","arguments":{"category":"kg"}}
{"name":"kg_build","arguments":{}}                       // index symbols/files/refs (one transaction)

{"name":"batch","arguments":{"calls":[
  {"tool":"kg_find_symbol",    "args":{"name":"authenticate"}},
  {"tool":"kg_references",      "args":{"name":"authenticate"}},
  {"tool":"kg_neighbors", "args":{"name":"SessionManager"}}
]}}
```

⟶ **host turn:** walk me through the request→auth→session flow using these
symbols. The explanation is anchored to real callers/callees.

---

## 8. Flaky CI — it's red again but "works on my machine"

```json
{"name":"enable_category","arguments":{"category":"ci"}}

{"name":"batch","arguments":{"calls":[
  {"tool":"ci_workflows",  "args":{}},
  {"tool":"ci_failed_log", "args":{}}
]}}
```

⟶ **host turn:** why did the last CI run fail — flake or genuine regression? Or
let `ci_llm_diagnose` name the failing step, the exact error line, the fix, and
whether the pattern looks non-deterministic.

---

## 9. Cutting a release and publishing the artifact

Everything up to the upload is deterministic and repeatable; nothing here needs a
model.

```json
{"name":"wf__pipeline_ci","arguments":{}}                        // build + test + lint + format
{"name":"wf__project_changelog","arguments":{}}                  // changelog from commits
{"name":"enable_category","arguments":{"category":"sec"}}
{"name":"sec_sbom","arguments":{"path":"."}}                     // ship an SBOM with the release
{"name":"wf__git_release","arguments":{"version":"1.8.0"}}       // needs consent

{"name":"enable_category","arguments":{"category":"s3"}}
{"name":"s3_upload","arguments":{"file":"dist/app-1.8.0.tar.gz","key":"releases/app-1.8.0.tar.gz"}}   // needs consent
{"name":"s3_object_info","arguments":{"key":"releases/app-1.8.0.tar.gz"}}   // confirm size + etag
```

---

## 10. Remote box is out of disk and SSH is all you've got

```json
{"name":"enable_category","arguments":{"category":"ssh"}}

// injection-safe remote exec (commands travel over stdin, never interpolated)
{"name":"batch","arguments":{"calls":[
  {"tool":"ssh_disk_usage",    "args":{"host":"web01"}},
  {"tool":"ssh_processes",      "args":{"host":"web01"}},
  {"tool":"ssh_journal", "args":{"host":"web01","unit":"nginx"}}
]}}
```

⟶ **host turn:** web01 is at 98% disk — from this, what's consuming it and what's
safe to clear?

---

## 11. Driving Yantra from your own bot (a minimal MCP client)

A PR bot doesn't need a full host — it can spawn Yantra and speak JSON-RPC on the
pipe directly. Dispatch one `batch`, get all the evidence in one result, hand it
to your own model or posting logic.

```python
import subprocess, json

proc = subprocess.Popen(
    ["bash", "yantra-mcp-server.sh", "--enable", "sec", "-y"],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
)

def call(mid, method, params):
    proc.stdin.write(json.dumps({"jsonrpc": "2.0", "id": mid,
                                 "method": method, "params": params}) + "\n")
    proc.stdin.flush()

call(1, "initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
                       "clientInfo": {"name": "pr-bot", "version": "1"}})

# one batch, three scanners, one round-trip
call(2, "tools/call", {"name": "batch", "arguments": {"calls": [
    {"tool": "sec_scan_secrets",   "args": {}},
    {"tool": "sec_semgrep",   "args": {}},
    {"tool": "sec_dep_audit", "args": {"path": "."}},
]}})

for line in proc.stdout:
    ev = json.loads(line)
    if ev.get("id") == 2:
        print(ev["result"]["content"][0]["text"])   # combined scanner output
        break

proc.stdin.write('{"jsonrpc":"2.0","method":"notifications/exit"}\n')
proc.stdin.flush(); proc.wait()
```

Because tools **return text and never emit stray output**, the whole batch comes
back as one clean result — safe to post as a PR comment. (For very large output,
the result is a short preview plus a `resource_link` you fetch with
`resources/read`.)

---

**The pattern, every time:** enable the category, `batch` the evidence for free,
and let the host's model spend tokens on the one thing it's uniquely good at — the
judgment call at the end. That's the difference between an agent that *reasons
over facts* and one that *bills you to go fetch them*.
