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
| **brew** | Homebrew (macOS/Linux) | 6 | 0 | [brew.md](brew.md) |
| **build** | build | 0 | 2 | [build.md](build.md) |
| **ccpp** | C/C++ | 22 | 0 | [ccpp.md](ccpp.md) |
| **ci** | CI/CD | 8 | 0 | [ci.md](ci.md) |
| **container** | container | 0 | 3 | [container.md](container.md) |
| **core** | Core (read/write/edit/bash/browse/batch) | 12 | 0 | [core.md](core.md) |
| **cua** | Computer Use (screen/mouse/keyboard driver) | 19 | 0 | [cua.md](cua.md) |
| **data** | Data (duckdb) | 9 | 6 | [data.md](data.md) |
| **debug** | debug | 0 | 1 | [debug.md](debug.md) |
| **deps** | deps | 0 | 7 | [deps.md](deps.md) |
| **devops** | devops | 0 | 2 | [devops.md](devops.md) |
| **disk** | disk | 0 | 2 | [disk.md](disk.md) |
| **doc** | Documents | 15 | 3 | [doc.md](doc.md) |
| **docker** | Docker | 20 | 0 | [docker.md](docker.md) |
| **doctor** | doctor | 0 | 2 | [doctor.md](doctor.md) |
| **fmt** | fmt | 0 | 2 | [fmt.md](fmt.md) |
| **fs** | Filesystem & Search | 23 | 0 | [fs.md](fs.md) |
| **git** | Git (read-only introspection) | 6 | 16 | [git.md](git.md) |
| **golang** | Go | 31 | 0 | [golang.md](golang.md) |
| **harness** | harness | 0 | 6 | [harness.md](harness.md) |
| **helm** | Helm | 9 | 1 | [helm.md](helm.md) |
| **hygiene** | hygiene | 0 | 3 | [hygiene.md](hygiene.md) |
| **java** | Java | 27 | 0 | [java.md](java.md) |
| **k8s** | k8s | 0 | 3 | [k8s.md](k8s.md) |
| **kg** | Code Knowledge Graph | 8 | 2 | [kg.md](kg.md) |
| **kotlin** | Kotlin | 12 | 0 | [kotlin.md](kotlin.md) |
| **kubernetes** | Kubernetes | 23 | 0 | [kubernetes.md](kubernetes.md) |
| **lint** | lint | 0 | 2 | [lint.md](lint.md) |
| **localdb** | Local SQLite scratch DB | 13 | 0 | [localdb.md](localdb.md) |
| **media** | Media | 22 | 6 | [media.md](media.md) |
| **mentor** | mentor | 0 | 3 | [mentor.md](mentor.md) |
| **monitor** | Agent Monitor | 12 | 0 | [monitor.md](monitor.md) |
| **mysql** | MySQL/MariaDB | 14 | 0 | [mysql.md](mysql.md) |
| **net** | Network | 9 | 2 | [net.md](net.md) |
| **nodejs** | Node.js/TypeScript | 32 | 0 | [nodejs.md](nodejs.md) |
| **ollama** | Ollama / Local LLM | 16 | 0 | [ollama.md](ollama.md) |
| **opencv** | Computer Vision (OpenCV 4.13) | 19 | 0 | [opencv.md](opencv.md) |
| **perf** | Performance | 16 | 2 | [perf.md](perf.md) |
| **pg** | PostgreSQL | 15 | 0 | [pg.md](pg.md) |
| **php** | PHP | 20 | 0 | [php.md](php.md) |
| **pipeline** | pipeline | 0 | 3 | [pipeline.md](pipeline.md) |
| **playwright** | Playwright end-to-end testing | 6 | 0 | [playwright.md](playwright.md) |
| **pr** | pr | 0 | 3 | [pr.md](pr.md) |
| **project** | project | 0 | 5 | [project.md](project.md) |
| **pubapi** | Public APIs (weather/stocks/flights/FX, Bitly, Apify, Fingerprint) | 11 | 0 | [pubapi.md](pubapi.md) |
| **python** | Python | 27 | 0 | [python.md](python.md) |
| **quality** | Code Quality | 16 | 0 | [quality.md](quality.md) |
| **redis** | Redis | 12 | 0 | [redis.md](redis.md) |
| **refactor** | refactor | 0 | 3 | [refactor.md](refactor.md) |
| **release** | release | 0 | 2 | [release.md](release.md) |
| **review** | review | 0 | 3 | [review.md](review.md) |
| **ruby** | Ruby | 18 | 0 | [ruby.md](ruby.md) |
| **rust** | Rust | 27 | 0 | [rust.md](rust.md) |
| **s3** | S3 Storage | 7 | 0 | [s3.md](s3.md) |
| **scaffold** | scaffold | 0 | 2 | [scaffold.md](scaffold.md) |
| **scala** | Scala | 13 | 0 | [scala.md](scala.md) |
| **sec** | Security | 19 | 8 | [sec.md](sec.md) |
| **ssh** | SSH/Remote | 13 | 0 | [ssh.md](ssh.md) |
| **test** | test | 0 | 4 | [test.md](test.md) |
| **tools** | tools | 0 | 4 | [tools.md](tools.md) |
| **ytdl** | YouTube & media downloader (yt-dlp) | 8 | 0 | [ytdl.md](ytdl.md) |

_Generated by docs/gen_cli_md.sh from the live registries. Regenerate after adding tools/workflows._
