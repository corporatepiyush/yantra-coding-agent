# MCP-only migration — assertion-preservation map (playbook M3)

Owner amendment 2026-07-13 (PLAN.md T8): the CLI subcommand surface, interactive
REPL, NDJSON stdio surface, roles, and the agent loop were removed; Yantra is a
pure MCP server. Rollback point: the commit marked "M6 rollback point" in its
message (parent of the removal commit). Per M3, no test was deleted until every
assertion was mapped to (a) a new home, (b) the host checklist IV-B.1, or (c) a
written "obsolete because X".

## Removed code → replacement

| Removed | Replacement |
|---|---|
| `yantra <category> <call>` CLI | `tools/call` over MCP (`--enable CAT` at launch, or `enable_category`) |
| NDJSON `--ui json` (`run`/`dispatch`/`list`/`message` frames) | MCP JSON-RPC: `tools/call`, `wf__<id>` tools, `tools/list` |
| Interactive REPL (`tl:`/`cmd:`/`wf:` prefixes, `:reload`/`:quit`) | any MCP host |
| `agent_run_llm_loop` + roles (`--role`, `--workflow`) | the MCP host owns the loop (D11); `*_llm_*` single-shot tools kept |
| Turn reminder (`YCA_TURN_REMINDER_ENABLED`) | preserved as the MCP prompt `grounding` (`prompts/get`); env var warns at boot (M4) |
| `commands/{cli,subcommand,catalog,interactive,stdio}.sh`, `core/dispatch.sh` | `commands/mcp.sh`; the catalog was a registry view — tests read the registry |
| startup LLM/deps notices | stderr logging + `wf__harness_doctor` |
| Removed flags/args | fail with exit 64 + one-line pointer to the MCP replacement (M4) |

Kept as internal plumbing (NOT surfaces): `tool_dispatch`, `tool_invoke`,
`run_workflow`, `wf_call`, `emit`/frame internals (captured by the MCP wf__
bridge), `confirm_action`/`confirm_denied_msg`, providers + `llm_analyze`.

## Suite dispositions

**Deleted — surface itself removed; assertions re-homed or obsolete:**

| Suite | Disposition |
|---|---|
| test_stdio | NDJSON framing/ack/bye → obsolete; reader robustness lives in test_mcp_server §11 (fuzz corpus), id handling in §1/§9 |
| test_startup_ux | ready-frame `.llm`, startup notices → obsolete (initialize response is the handshake; test_protocol_honesty walks it) |
| test_interactive | REPL → obsolete |
| test_cli_subcommand | CLI front door → obsolete; removed-flag errors asserted by main.sh M4 messages (manual smoke; `--help` covered in test_secret_hygiene) |
| test_cli_exec | `--workflow` one-shot → obsolete; workflows run as `wf__<id>` (test_e2e_workflows) |
| test_dispatch_prefix (+ test_scripts/fuzz_dispatch.sh) | prefix router → obsolete; hostile-input fuzz replaced by tests/fixtures/mcp/fuzz_corpus.txt via the T4 client |
| test_llm_loop | loop → host scope (IV-B.1); skills-seeding assertion deferred until skills→prompts ships |
| test_turn_reminder | reminder → test_mcp_server §13 (grounding prompt content + goal argument) |
| test_meta_reload | REPL `:reload`/`:quit` → obsolete |
| test_ui | NDJSON renderers/frames → obsolete; stdout purity is test_mcp_server §7 and test_e2e_workflows §1 |

**Ported — same assertions, MCP vehicle (`tests/lib_mcp.sh`: `mcp_session`/`mcp_call`/`mcp_wf`/`registry_dump`):**
test_protocol_honesty (capability↔handler walk now on `initialize`),
test_e2e_workflows, test_git_workflows, test_workflows, test_composition
(frame-suppression asserted at the run_workflow seam), test_helpers,
test_toolchain, test_security, test_tool_toggles, test_projectconfig,
test_kg, test_git_text_tools, test_db, test_lang_detect, test_scanner,
test_llm_unavailable (cmd:config → provider-detection seam),
test_local_llm_features (frame-scoped consent → MCP default-deny; per-call
scope in test_mcp_server §12), test_secret_hygiene, test_categories_split,
test_complexity_routing, test_tool_categories, test_monitor_dns_os,
test_localdb, test_nodejs_rust_tools, test_ollama, test_opencv, test_disk,
test_doctor_deps.

Catalog-view assertions (`{"type":"list"}`) became registry facts
(`registry_dump`) plus wire checks (`tools/list` shows an enabled category's
tools and NOT a disabled one's).

**New assertions added during the migration:** per-call consent scope (one
approval never covers the next call), grounding prompt survival, boot `--enable`
consent + stdout purity, `llm_unavailable_flow` never emits frames into the
JSON-RPC stream, `_mcp_run_workflow` runs in-process so state-mutating
workflows (tools.enable) keep their effect, `describe_tool` reports the
EFFECTIVE complexity (config override wins).

**Known docs debt:** `docs/cli/*.md` (served as `doc://cli/*` resources) still
show `yantra <cat> <call>` invocation examples; the argument tables remain
accurate for `tools/call`. Regenerate via `docs/gen_cli_md.sh` when it is
taught MCP examples.

---

## 2026-07-14 — Alias removal + explicit-action rename + composite workflows

Owner directive: remove tool calls that were 1:1 aliases of a single binary
invocation (the always-on `bash` tool runs those directly, writes still
consent-gated), rename the survivors to explicit `category_action` names, and add
task-level pipelines that chain 2+ dependencies. Net: **690 → 598 tools**, **105 →
112 workflows**.

### Removed alias tools → replacement

The rule: a tool was removed if it reduced to `[missing-check] + <one binary call
with the user's args>` and added no encoded knowledge, safety, aggregation, output
shaping, or LLM reasoning. Replace any removed call with the plain command via the
`bash` core tool, or the workflow noted below.

| Category | Removed | Use instead |
|---|---|---|
| `text` (whole category) | base64, url, jwt_decode, hash, uuid, timestamp, random, count | `bash` (`base64`, `openssl`, `uuidgen`, `date`, `jq`) |
| `brew` | list, search, info, outdated, update, doctor, tap, untap, services_*, deps, uses | `bash brew <verb>` |
| `docker` | stats, top, images, image_history, network_ls/inspect, volume_ls, df, events, info, version, compose_ps/config, contexts, ports | `bash docker <verb>`, or `wf__container_overview` |
| `kubernetes` | pods, pod, deployments, services, nodes, namespaces, configmaps, secrets, top_pods/nodes, explain, api_resources, version, cluster_info, rollout_status/history | `bash kubectl <verb>`, or `wf__k8s_overview` |
| `ollama` | models, pull, show, ps, stop, create, cp, rm, push | `bash ollama <verb>` |
| `git` | status, branches, contributors, stash_list, conflicts | `bash git <verb>` |
| `media` | meta, gps | `bash exiftool <file>` |
| `doc` | toc, wordcount, frontmatter, csv2md | `bash` (`grep`, `wc`, `awk`) |
| `ytdl` | formats, subs_list, thumbnail | `bash yt-dlp -F/--list-subs/--write-thumbnail` |
| `fs` | checksum, dirsize, gzip, gunzip | `bash` (`shasum`, `du`, `gzip`) |
| `redis` | keys, memory, set, del, expire, persist, rename, incr | `bash redis-cli <VERB>` (flushdb kept — destructive gate) |
| `helm` | list, history | `bash helm list/history` (status/values kept — they redact secrets) |
| `net` | ping, public_ip, ifaces | `bash ping/curl ifconfig.me/ip addr` |
| `ci` | runs, view, failures, local_run | `bash gh run …` / `act` (failed_log + diagnosis kept) |
| `ssh` | mounts | `bash mount \| grep fuse` |

`pg`/`mysql` were **kept in full** — every one is a curated expert query over a
shared env-connection helper (encoded knowledge), not a binary alias.

### Renamed for explicit action (hard rename, no aliases)

Opaque names (unix-isms, bare nouns, abbreviations, prefix/category mismatches,
stutters) became explicit `category_action` forms. Language-toolchain names
(`clippy`, `mypy`, `pytest`, …) and already-clear verbs were left as-is.

`docker_ps` → `docker_list_containers` · `docker_cp` → `docker_copy` · `docker_diff` → `docker_container_changes`
`docker_dangling` → `docker_list_dangling` · `docker_stop_rm` → `docker_remove` · `k8s_images` → `k8s_list_images`
`k8s_pending` → `k8s_pending_pods` · `k8s_restarts` → `k8s_pod_restarts` · `k8s_resources` → `k8s_pod_resources`
`fs_grep` → `fs_search` · `fs_stat` → `fs_file_info` · `fs_tar` → `fs_archive`
`fs_untar` → `fs_extract_archive` · `fs_dups` → `fs_find_duplicates` · `fs_todos` → `fs_find_todos`
`fs_disk` → `fs_disk_usage` · `fs_find` → `fs_recent_files` · `fs_largest` → `fs_largest_files`
`fs_empty` → `fs_empty_files` · `fs_ext_census` → `fs_extension_counts` · `net_dns` → `net_dns_lookup`
`net_trace` → `net_traceroute` · `net_scan` → `net_port_scan` · `net_sockets` → `net_listening_ports`
`git_search` → `git_search_history` · `redis_dbsize` → `redis_key_count` · `redis_clients` → `redis_list_clients`
`pg_activity` → `pg_active_queries` · `pg_locks` → `pg_lock_waits` · `pg_slow` → `pg_slow_queries`
`pg_stats` → `pg_table_stats` · `pg_size` → `pg_sizes` · `mysql_slow` → `mysql_slow_queries`
`mysql_size` → `mysql_sizes` · `mysql_status` → `mysql_server_status` · `mysql_variables` → `mysql_server_variables`
`data_head` → `data_preview` · `doc_images` → `doc_extract_images` · `media_gif` → `media_make_gif`
`media_speed` → `media_change_speed` · `opencv_motion` → `opencv_detect_motion` · `opencv_edges` → `opencv_detect_edges`
`perf_cpu` → `perf_cpu_usage` · `perf_mem` → `perf_memory` · `perf_io` → `perf_io_stats`
`perf_net` → `perf_network` · `perf_disk` → `perf_disk_io` · `perf_load` → `perf_load_average`
`perf_top_procs` → `perf_top_processes` · `perf_bench` → `perf_benchmark` · `perf_bin_size` → `perf_binary_size`
`perf_proc_tree` → `perf_process_tree` · `perf_perf_record` → `perf_record` · `s3_head` → `s3_object_info`
`sec_secrets` → `sec_scan_secrets` · `sec_iac` → `sec_scan_iac` · `sec_world_writable` → `sec_find_world_writable`
`sec_suid` → `sec_find_suid` · `remote_disk` → `ssh_disk_usage` · `remote_ps` → `ssh_processes`
`remote_tail` → `ssh_tail_log` · `remote_journal` → `ssh_journal` · `scp_to` → `ssh_upload`
`scp_from` → `ssh_download` · `ssh_hosts` → `ssh_list_hosts` · `ssh_keys` → `ssh_list_keys`
`ai_extract` → `ollama_extract` · `ai_rag_index` → `ollama_rag_index` · `ai_rag_query` → `ollama_rag_query`
`ollama_disk` → `ollama_disk_usage` · `cua_key` → `cua_press_key` · `ci_durations` → `ci_step_durations`
`kg_symbol` → `kg_find_symbol` · `kg_refs` → `kg_references` · `kg_file` → `kg_file_symbols`
`go_mains` → `go_entrypoints` · `nodejs_ls` → `nodejs_list_deps` · `python_syntax` → `python_check_syntax`

### New composite workflows (chain 2+ dependencies into one ask)

`media.podcast` (yt-dlp + ffmpeg loudnorm/tags), `media.clip` (yt-dlp section +
ffmpeg), `media.hardsub` (whisper + ffmpeg/libass), `media.summarize` (transcript
+ LLM), `media.share_photos` (exiftool + imagemagick + opencv + tar),
`media.audiobook` (poppler + say/espeak + ffmpeg), `doc.save_article` (curl +
pandoc), `doc.scan-to-pdf` (opencv + img2pdf + tesseract), `data.diff` (duckdb),
`net.watch` (curl + sqlite3), `container.overview`, `k8s.overview`; plus the
`cua_find_text` tool (screenshot + tesseract + pointer) to locate/click on-screen
text by OCR.
