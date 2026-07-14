# Dependencies & Versions

Yantra needs only a tiny **core** to run. Everything else is optional and only
used by specific actions — the tool tells you (and offers to install) what a
given action needs, when it needs it.

Run the doctor over MCP —
`tools/call {"name":"wf__doctor_versions","arguments":{}}` — to see what you
have installed versus the versions below.

> The version numbers below are current-stable recommendations. Version numbers
> move fast; always prefer whatever
> your package manager currently ships. The doctor floors
> (`harness/core/doctor.sh` → `YCA_DEP_MINVER`) track these same versions at
> major.minor granularity — being behind flags an advisory OUTDATED (with a
> one-shot `brew upgrade` offer) and never blocks anything.

## How installation works

- On **macOS and Linux**, Yantra uses [Homebrew](https://brew.sh). If Homebrew
  isn't installed, Yantra offers to install it for you (non-interactively) the
  first time a tool is needed.
- Missing tools are offered for one-command install: run the `doctor.install`
  workflow — `tools/call {"name":"wf__doctor_install","arguments":{}}`.
- Install everything at once with, e.g.:
  `brew install git ripgrep duckdb pandoc poppler gh shellcheck hadolint gitleaks trivy osv-scanner yq ffmpeg docker kubectl helm cmake`

## Core (required)

| Tool     | Latest stable | Purpose                       |
|----------|-------------------------|-------------------------------|
| bash     | 5.3.15                  | the harness itself (hard req) |
| jq       | 1.8.2                   | JSON parsing / protocol       |
| sqlite3  | 3.53.3                  | local datastore¹              |
| curl     | 8.21.0                  | HTTP, LLM calls, updates      |

> ¹ 3.53.3 is Homebrew's build. macOS's bundled `/usr/bin/sqlite3` is older
> (older than Homebrew's) — the harness uses whichever is first on PATH, and
> the doctor workflow reports the resolved binary, its version, and its features.

## Optional (feature tools)

The latest stable release of each. They are recommendations,
not requirements: `doctor.versions` only flags an install that is meaningfully
behind its floor, and it never blocks you.

| Tool        | Latest | Installs with            | Used by                     |
|-------------|------------------|--------------------------|-----------------------------|
| git         | 2.55.0           | brew install git         | all git.* workflows         |
| ripgrep (rg)| 15.1.0           | brew install ripgrep     | fast search / grep          |
| sd          | 1.1.0            | brew install sd          | fast find-and-replace       |
| ast-grep    | 0.44.1           | brew install ast-grep    | structural refactors        |
| duckdb      | 1.5.4            | brew install duckdb      | data.* tools & workflows    |
| pandoc      | 3.10             | brew install pandoc      | doc conversion              |
| poppler     | 26.07.0          | brew install poppler     | pdftotext (doc extract)     |
| gh          | 2.96.0           | brew install gh          | git.pr (GitHub PRs)         |
| shellcheck  | 0.11.0           | brew install shellcheck  | shell linting               |
| hadolint    | 2.14.0           | brew install hadolint    | Dockerfile linting          |
| gitleaks    | 8.30.1           | brew install gitleaks    | secret scanning             |
| semgrep     | 1.168.0          | brew install semgrep     | SAST security scan          |
| trivy       | 0.72.0           | brew install trivy       | container/image + SBOM scan |
| osv-scanner | 2.4.0            | brew install osv-scanner | supply-chain (OSV) audit    |
| yq          | 4.53.3           | brew install yq          | YAML processing             |
| ffmpeg      | 8.1.2            | brew install ffmpeg      | media probe/convert         |
| docker      | 29.6.1           | brew install docker      | container.* / docker tools  |
| kubectl     | 1.36.2           | brew install kubectl     | k8s.* workflows             |
| helm        | 4.2.2            | brew install helm        | helm.* workflows            |
| cmake       | 4.3.4            | brew install cmake       | C/C++ builds                |
| yt-dlp      | latest           | brew install yt-dlp      | ytdl.* media downloads      |

## Computer-use (`cua`) backends — OS-specific

The `cua` category picks its screen-capture and input-injection backend from the
display server (`cua_doctor` reports which is present). Install only the row for
your platform:

| Platform | Screenshot | Mouse/keyboard | OCR | Notes |
|----------|------------|----------------|-----|-------|
| macOS (quartz) | `screencapture` (built in) | `brew install cliclick` (or AppleScript) | `brew install tesseract` | Grant **Screen Recording** + **Accessibility** in System Settings ▸ Privacy & Security |
| Linux X11 | `apt install maim` / `scrot` / `imagemagick` | `apt install xdotool` | `apt install tesseract-ocr` | No extra permissions |
| Linux Wayland | `apt install grim` (wlroots) / `gnome-screenshot` / `spectacle` | `apt install wtype` (wlroots) or `ydotool` (+ running `ydotoold`, `/dev/uinput`) | `apt install tesseract-ocr` | `xdotool` does **not** drive native Wayland windows |

## Language toolchains (only if you work in that language)

Node.js and Java pin to the latest **LTS** release; the others have no formal LTS
track, so their latest **stable** is shown.

| Language | Tool    | Latest LTS / stable | Installs with            |
|----------|---------|-------------------------------|--------------------------|
| Node.js  | node    | 24.18.0 (LTS)                 | brew install node@24     |
| Node.js  | npm     | 11.x (ships with node@24)     | ships with node          |
| Python   | python3 | 3.14.6 (latest stable)        | brew install python      |
| Go       | go      | 1.26.4 (latest stable)        | brew install go          |
| Rust     | cargo   | 1.96.1 (latest stable)        | brew install rust        |
| Ruby     | ruby    | 4.0.5 (latest stable)         | brew install ruby        |
| PHP      | php     | 8.5.8 (latest stable)         | brew install php         |
| Java     | java    | 25.0.3 (LTS)                  | brew install openjdk@25  |

> The **advisory floors** live in `harness/core/doctor.sh` (`YCA_DEP_MINVER`)
> and track this table at major.minor granularity. `doctor.versions` compares
> your installed version against the
> floor: behind means an OUTDATED flag and an offered `brew upgrade`, never a
> block.
