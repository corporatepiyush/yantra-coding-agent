# core/scanner.sh — Smart project inspection: recommends tool_call categories.
# Called at startup. Scans the project for signals beyond build files.
# Each category has its own scan criteria. Outputs info messages only — never
# auto-enables anything. The user decides.
#
# Performance design (one walk, then memory):
#   1. ONE pruned `find` builds a capped file index (_SCAN_INDEX). Every
#      filename/extension count is then a grep over that in-memory list —
#      the old scanner re-walked the tree with a fresh `find` per category
#      (~10 walks per boot on top of ~15 content greps).
#   2. Content greps are BOOLEAN (_scan_has): rg -q / grep -q stop at the
#      first match instead of listing every matching file in the tree.
#   3. The index is capped (20k entries) and rg skips files >1MB, so a
#      monorepo or a vendored blob can't blow up scan time or memory.

# ── File index (built once per scan) ─────────────────────────────────────────
_SCAN_INDEX=""
_SCAN_INDEX_COUNT=0
_SCAN_INDEX_CAP=20000
_SCAN_INDEX_CAPPED=0

_scan_build_index() {
    local dir="$1"
    _SCAN_INDEX=$(find "$dir" -maxdepth 4 \
        \( -name .git -o -name node_modules -o -name .venv -o -name venv \
           -o -name target -o -name dist -o -name build -o -name __pycache__ \
           -o -name .next -o -name vendor \) -prune \
        -o -type f -print 2>/dev/null | head -n "$_SCAN_INDEX_CAP")
    _SCAN_INDEX_COUNT=$(grep -c . <<< "$_SCAN_INDEX" || true)
    [[ -z "$_SCAN_INDEX" ]] && _SCAN_INDEX_COUNT=0
    _SCAN_INDEX_CAPPED=0
    (( _SCAN_INDEX_COUNT >= _SCAN_INDEX_CAP )) && _SCAN_INDEX_CAPPED=1
}

# _scan_count ERE -> how many indexed paths match (bounded by the index cap).
_scan_count() {
    [[ -z "$_SCAN_INDEX" ]] && { printf '0'; return 0; }
    printf '%s\n' "$_SCAN_INDEX" | grep -cE -- "$1" || true
}

# _scan_index_has ERE -> 0 if any indexed path matches.
_scan_index_has() {
    [[ -z "$_SCAN_INDEX" ]] && return 1
    printf '%s\n' "$_SCAN_INDEX" | grep -qE -- "$1"
}

# scan_project -> prints recommendations as info messages.
scan_project() {
    local dir="${1:-$YCA_PROJECT_DIR}"
    local recs=()
    local cat

    # Run scan functions with errexit disabled — individual ls/grep/find calls
    # return non-zero on no-match. Save and RESTORE the caller's errexit state:
    # a bare `set -e` here used to switch errexit ON for the whole process (the
    # harness runs with it OFF), so the first workflow whose tool returned
    # non-zero — e.g. a missing optional binary — silently killed the session
    # with exit 1 and no result frame.
    local _errexit_was_on=0
    [[ $- == *e* ]] && _errexit_was_on=1
    set +e
    _scan_build_index "$dir"
    # Categories run CONCURRENTLY (each is an independent read-only probe), so
    # wall time is the slowest category instead of the sum of ~23 of them.
    # Each subshell writes to its own index-named file; results are collected
    # in list order afterward, so the output stays deterministic.
    local -a cats=(git docker kubernetes helm pg mysql redis fs perf net sec quality ci doc data media opencv ollama monitor s3 ssh brew localdb kg)
    local tmpd i
    tmpd=$(path_temp_dir yca-scan)
    for i in "${!cats[@]}"; do
        ( _scan_category "${cats[$i]}" "$dir" > "$tmpd/$i" 2>/dev/null ) &
    done
    wait
    for i in "${!cats[@]}"; do
        local reason=""
        [[ -s "$tmpd/$i" ]] && reason=$(<"$tmpd/$i")
        [[ -n "$reason" ]] && recs+=("${cats[$i]}|$reason")
    done
    rm -rf "$tmpd"
    # Free the index — scan results are printed; keeping 20k paths resident in
    # a long-lived REPL session would be a slow leak for zero benefit.
    _SCAN_INDEX=""; _SCAN_INDEX_COUNT=0
    (( _errexit_was_on )) && set -e

    if [[ ${#recs[@]} -eq 0 ]]; then
        logmsg "$(c_dim 'No optional tool categories recommended for this project.')"
        return 0
    fi

    logmsg "$(c_info '💡 Based on your project, you may enable these tool categories to be more productive:')"
    logmsg ""
    local rec
    for rec in "${recs[@]}"; do
        local c="${rec%%|*}" r="${rec#*|}"
        local label="${YCA_CAT_LABEL[$c]:-$c}"
        local enabled="${YCA_CAT_ENABLED[$c]:-0}"
        local status=""
        [[ "$enabled" == "1" ]] && status=" $(c_dim '(already enabled)')"
        logmsg "  $(c_ok '→') $label$status"
        logmsg "    $(c_dim "$r")"
        local hint; hint=$(_scan_next_step "$c")
        [[ -n "$hint" ]] && logmsg "    $(c_dim "try: $hint")"
    done
    logmsg ""
    logmsg "$(c_dim '  Enable a category with: cmd:tools enable <category>   (re-run anytime with: cmd:scan)')"
}

# _scan_next_step CATEGORY -> a concrete first command a junior can copy/paste
# once the category is enabled. Bridges "what's available" to "what do I do".
_scan_next_step() {
    case "$1" in
        git)        printf 'cmd:tools enable git → tl:git status / tl:git log / "who introduced this string?" (git search)' ;;
        docker)     printf 'cmd:tools enable docker  → then ask: "why is my container crashing?" (docker_llm_diagnose)' ;;
        kubernetes) printf 'cmd:tools enable kubernetes → then ask: "why is pod X pending?" (k8s_llm_diagnose_pod)' ;;
        helm)       printf 'cmd:tools enable helm  → helm.list  or ask for a chart review (helm_llm_review)' ;;
        pg)         printf 'cmd:tools enable pg  → set PG_CONN, then tl:pg tables / tl:pg slow' ;;
        mysql)      printf 'cmd:tools enable mysql → tl:mysql tables / tl:mysql processlist' ;;
        redis)      printf 'cmd:tools enable redis → tl:redis info / tl:redis keys' ;;
        ci)         printf 'cmd:tools enable ci  → ask: "why did CI fail?" (ci_llm_diagnose)' ;;
        doc)        printf 'cmd:tools enable doc → ask: "summarize spec.pdf" (doc_llm_summarize) or generate a README' ;;
        data)       printf 'cmd:tools enable data → data.query {"file":"x.csv","query":"SELECT ..."} or get insights (data_llm_insights)' ;;
        media)      printf 'cmd:tools enable media → media_probe to inspect codecs before touching anything' ;;
        opencv)     printf 'cmd:tools enable opencv → opencv doctor, then opencv info/detect_faces/read_qr/compare/count_objects (needs python3 + pip install "opencv-python>=4.13")' ;;
        ollama)     printf 'cmd:tools enable ollama → tl:ollama models / tl:ollama ps / tl:ollama run (run a local LLM); tl:ollama doctor' ;;
        sec)        printf 'sec.pipeline  (secrets + IaC + semgrep, no LLM needed)' ;;
        quality)    printf 'sec.complexity / sec.deadcode  (no LLM needed)' ;;
        perf)       printf 'cmd:tools enable perf → profile a hot path with the right tool for your language' ;;
        net)        printf 'cmd:tools enable net → dns/trace/scan/free-port, or net.diagnose <url> for one-shot triage' ;;
        s3)         printf 'cmd:tools enable s3  → list/inspect buckets' ;;
        ssh)        printf 'cmd:tools enable ssh → run remote diagnostics safely (stdin, no injection)' ;;
        monitor)    printf 'cmd:tools enable monitor → inspect metrics/observability config' ;;
        fs)         printf 'cmd:tools enable fs → tl:fs todos (inherited-project roadmap), tl:fs tree, grep/replace, dedup, disk usage' ;;
        brew)       printf 'cmd:tools enable brew → brew_ensure to install missing deps' ;;
        localdb)    printf 'cmd:tools enable localdb → tl:localdb tables / tl:localdb query (scratch SQLite, kept out of git)' ;;
        kg)         printf 'wf:kg build  → then tl:kg symbol <name> / tl:kg refs <name> (code knowledge graph)' ;;
        *)          return 1 ;;
    esac
}

# _scan_exists PATTERN... -> 0 if any argument is an existing path.
# Safe under nullglob (set globally): an unmatched glob collapses to nothing,
# so `ls "$dir"/*.foo | head` would degrade to `ls` (lists cwd, exits 0) and
# report a false positive. Testing the surviving args with -e avoids that.
_scan_exists() {
    local p
    for p in "$@"; do [[ -e "$p" ]] && return 0; done
    return 1
}

# _scan_category CATEGORY DIR -> prints reason if recommended, empty if not.
_scan_category() {
    local cat="$1" dir="$2"
    case "$cat" in
        git)         _scan_git "$dir" ;;
        docker)      _scan_docker "$dir" ;;
        kubernetes)  _scan_kubernetes "$dir" ;;
        helm)        _scan_helm "$dir" ;;
        pg)          _scan_pg "$dir" ;;
        mysql)       _scan_mysql "$dir" ;;
        redis)       _scan_redis "$dir" ;;
        fs)          _scan_files "$dir" ;;
        perf)        _scan_perf "$dir" ;;
        net)         _scan_net "$dir" ;;
        sec)         _scan_sec "$dir" ;;
        quality)     _scan_quality "$dir" ;;
        ci)          _scan_ci "$dir" ;;
        doc)         _scan_doc "$dir" ;;
        data)        _scan_data "$dir" ;;
        media)       _scan_media "$dir" ;;
        opencv)      _scan_opencv "$dir" ;;
        ollama)      _scan_ollama "$dir" ;;
        monitor)     _scan_monitor "$dir" ;;
        s3)          _scan_s3 "$dir" ;;
        ssh)         _scan_ssh "$dir" ;;
        brew)        _scan_brew "$dir" ;;
        localdb)     _scan_localdb "$dir" ;;
        kg)          _scan_kg "$dir" ;;
        *)           return 1 ;;
    esac
}

# ── Per-category scan functions ──────────────────────────────────────────────

_scan_git() {
    local dir="$1"
    [[ -e "$dir/.git" ]] || return 1
    printf 'Git repository — read-only introspection tools (status/log/diff/show, pickaxe search, file history). '
}

_scan_docker() {
    local dir="$1" hits=""
    [[ -f "$dir/Dockerfile" || -f "$dir/Dockerfile.dev" || -f "$dir/Dockerfile.prod" ]] && hits+="Dockerfile found. "
    _scan_exists "$dir"/docker-compose*.yml "$dir"/docker-compose*.yaml && hits+="docker-compose found. "
    [[ -f "$dir/.dockerignore" ]] && hits+=".dockerignore found. "
    # Content signal: docker run/build/execute in scripts or CI — only worth
    # the grep when no cheap file signal already recommended the category.
    [[ -z "$hits" ]] && _scan_has "$dir" 'docker[[:space:]]+(run|build|compose|exec)' --include='*.sh' --include='*.yml' --include='*.yaml' --include='Makefile' && hits+="docker commands in scripts. "
    # Containerfile (podman/buildah)
    _scan_exists "$dir"/Containerfile* && hits+="Containerfile found. "
    [[ -n "$hits" ]] && printf 'Containerization detected: %s' "${hits% }" || return 1
}

_scan_kubernetes() {
    local dir="$1" hits=""
    # Helm charts imply k8s
    [[ -f "$dir/Chart.yaml" ]] && return 1  # handled by _scan_helm
    # k8s manifest dirs
    local d
    for d in k8s kube deploy deployment manifests helm charts; do
        [[ -d "$dir/$d" ]] && { hits+="'$d/' directory. "; break; }
    done
    # YAML files with k8s apiVersion + kind (skipped when a dir already hit)
    [[ -z "$hits" ]] && _scan_has "$dir" '^apiVersion:[[:space:]]*(apps/|v1|batch/|rbac\.authorization\.k8s\.io/|networking\.k8s\.io/|policy/)' --include='*.yaml' --include='*.yml' && hits+="k8s manifests (apiVersion) found. "
    # kustomization (index lookup — the old `$dir/**/kustomization.yaml` glob
    # silently required globstar, which the harness never sets)
    _scan_index_has '(^|/)kustomization\.ya?ml$' && hits+="kustomization found. "
    # Skaffold / tilt
    [[ -f "$dir/skaffold.yaml" || -f "$dir/Tiltfile" ]] && hits+="dev tool (skaffold/tilt). "
    [[ -n "$hits" ]] && printf 'Kubernetes deployment detected: %s' "${hits% }" || return 1
}

_scan_helm() {
    local dir="$1"
    [[ -f "$dir/Chart.yaml" ]] && { printf 'Helm chart found (Chart.yaml). '; return 0; }
    [[ -d "$dir/charts" && -f "$dir/charts/Chart.yaml" ]] && { printf 'Helm subcharts found. '; return 0; }
    [[ -f "$dir/helmfile.yaml" || -f "$dir/helmfile.yaml.gotmpl" ]] && { printf 'Helmfile found. '; return 0; }
    return 1
}

# _scan_db_generic DIR -> engine-agnostic DB signals (migrations, SQL files,
# ORM configs). Used by _scan_pg as the fallback; mysql/redis require an
# engine-specific signal so one migrations/ dir doesn't recommend three engines.
_scan_db_generic() {
    local dir="$1" hits=""
    local d
    for d in migrations migration alembic flyway db/migrate db/migrations liquibase; do
        [[ -d "$dir/$d" ]] && { hits+="migration dir '$d/'. "; break; }
    done
    local sql_count
    sql_count=$(_scan_count '\.sql$')
    [[ "$sql_count" -gt 0 ]] && hits+="$sql_count SQL files. "
    [[ -f "$dir/prisma/schema.prisma" ]] && hits+="Prisma schema. "
    [[ -f "$dir/knexfile.js" || -f "$dir/knexfile.ts" ]] && hits+="Knex config. "
    _scan_exists "$dir"/typeorm* "$dir"/entities && hits+="TypeORM. "
    [[ -z "$hits" ]] && _scan_has "$dir" 'DATABASE_URL[[:space:]]*=' --include='.env*' --include='*.example' --include='*.template' && hits+="DATABASE_URL in env. "
    [[ -z "$hits" ]] && _scan_has "$dir" 'import.*(sqlalchemy|sequelize|mongoose|prisma|gorm|sqlx|diesel)' --include='*.py' --include='*.js' --include='*.ts' --include='*.go' --include='*.rs' && hits+="ORM imports. "
    printf '%s' "$hits"
}

_scan_pg() {
    local dir="$1" hits=""
    _scan_has "$dir" '(postgres|psycopg|pgx|node-postgres|jdbc:postgresql|POSTGRES_|PG_CONN)' --include='*.py' --include='*.js' --include='*.ts' --include='*.go' --include='*.rs' --include='*.java' --include='.env*' --include='*.yml' --include='*.yaml' -i && hits+="PostgreSQL references. "
    # Generic SQL signals land here (one engine recommendation, not three).
    [[ -z "$hits" ]] && hits=$(_scan_db_generic "$dir")
    [[ -n "$hits" ]] && printf 'Database usage detected: %s' "${hits% }" || return 1
}

_scan_mysql() {
    local dir="$1"
    _scan_has "$dir" '(mysql|mariadb|pymysql|jdbc:mysql|MYSQL_)' --include='*.py' --include='*.js' --include='*.ts' --include='*.go' --include='*.java' --include='.env*' --include='*.yml' --include='*.yaml' -i \
        && { printf 'MySQL/MariaDB references detected. '; return 0; }
    return 1
}

_scan_redis() {
    local dir="$1"
    _scan_has "$dir" '(redis|ioredis|jedis|lettuce|REDIS_URL|REDIS_HOST)' --include='*.py' --include='*.js' --include='*.ts' --include='*.go' --include='*.java' --include='.env*' --include='*.yml' --include='*.yaml' -i \
        && { printf 'Redis references detected. '; return 0; }
    return 1
}

_scan_files() {
    local dir="$1"
    local count="$_SCAN_INDEX_COUNT" plus=""
    (( _SCAN_INDEX_CAPPED )) && plus="+"
    [[ "$count" -gt 200 ]] && { printf 'Large project (%s%s files) — fs tools (grep/replace/TODO scan, dedup, disk usage) useful. ' "$count" "$plus"; return 0; }
    # Check for large files (only reached on small projects, so the walk is cheap)
    local big
    big=$(find "$dir" -maxdepth 3 -type f -size +10M -not -path '*/.git/*' -not -path '*/node_modules/*' 2>/dev/null | head -1)
    [[ -n "$big" ]] && { printf 'Large files (>10MB) detected. '; return 0; }
    # Even a mid-size project benefits from grep/replace/TODO navigation.
    [[ "$count" -gt 50 ]] && { printf '%s files — grep/replace/TODO-scan tools help you navigate. ' "$count"; return 0; }
    return 1
}

_scan_perf() {
    local dir="$1" hits=""
    # Benchmark dirs
    local d
    for d in bench benchmarks benches criterion benches/perf; do
        [[ -d "$dir/$d" ]] && { hits+="benchmark dir '$d/'. "; break; }
    done
    # Perf-sensitive domains: games, audio, video, graphics, crypto, HFT
    _scan_has "$dir" '(real.?time|game.?loop|audio.?process|video.?encode|render.?pipeline|crypto|mining|latency.?critical)' --include='*.rs' --include='*.cpp' --include='*.c' --include='*.go' --include='*.py' --include='*.ts' -i && hits+="perf-sensitive code. "
    # Load test files
    _scan_exists "$dir"/locustfile.py "$dir"/k6*.js "$dir"/*jmeter* && hits+="load tests. "
    # Profiling configs
    _scan_has "$dir" '#\[bench\]|criterion_group|cProfile|@profile|perf_counter' --include='*.rs' --include='*.py' && hits+="profiling annotations. "
    [[ -n "$hits" ]] && printf 'Performance-sensitive work detected: %s' "${hits% }" || return 1
}

_scan_net() {
    local dir="$1" hits=""
    # HTTP server frameworks
    _scan_has "$dir" '(express|fastify|koa|flask|fastapi|django|gin|echo|fiber|actix.?web|axum|rocket|spring.?boot|net/http)' --include='*.js' --include='*.ts' --include='*.py' --include='*.go' --include='*.rs' --include='*.java' --include='*.kt' && hits+="HTTP server framework. "
    # API client code
    _scan_has "$dir" '(fetch|axios|got|requests|httpx|reqwest|hyper|RestTemplate|WebClient)' --include='*.js' --include='*.ts' --include='*.py' --include='*.go' --include='*.rs' --include='*.java' && hits+="HTTP client code. "
    # WebSocket / socket code
    _scan_has "$dir" '(websocket|socket\.io|ws://|wss://|TCP.?server|UDP.?server)' --include='*.js' --include='*.ts' --include='*.py' --include='*.go' --include='*.rs' && hits+="WebSocket/socket code. "
    # Reverse proxy / nginx configs
    _scan_exists "$dir"/nginx*.conf "$dir"/Caddyfile && hits+="reverse proxy config. "
    # Ports in config
    _scan_has "$dir" '(PORT|listen|bind).*=.*[0-9]{4,5}' --include='*.env*' --include='*.yml' --include='*.yaml' --include='*.conf' --include='*.toml' && hits+="service ports in config. "
    [[ -n "$hits" ]] && printf 'Network/application layer detected: %s' "${hits% }" || return 1
}

_scan_sec() {
    local dir="$1" hits=""
    # Auth code
    _scan_has "$dir" '(jwt|oauth|auth0|passport|cognito|firebase.?auth|session.?secret|bcrypt|argon2)' --include='*.js' --include='*.ts' --include='*.py' --include='*.go' --include='*.rs' --include='*.java' -i && hits+="authentication code. "
    # Crypto usage
    _scan_has "$dir" '(encrypt|decrypt|cipher|aes|rsa|sha256|ssl|tls|certificate|pkcs)' --include='*.js' --include='*.ts' --include='*.py' --include='*.go' --include='*.rs' --include='*.java' -i && hits+="crypto usage. "
    # User input handling (forms, uploads)
    _scan_has "$dir" '(multipart|upload|form.?data|csrf|xss|sanitize|escape)' --include='*.js' --include='*.ts' --include='*.py' --include='*.go' --include='*.java' -i && hits+="user input handling. "
    # Secrets in config templates
    _scan_has "$dir" '(API_KEY|SECRET_KEY|PRIVATE_KEY|ACCESS_TOKEN).*=.*[A-Za-z0-9]{10,}' --include='.env*' --include='*.example' --include='*.template' --include='*.yml' --include='*.yaml' && hits+="secrets in config templates. "
    # API endpoints
    _scan_has "$dir" '(@app\.(route|get|post)|@GetMapping|@PostMapping|@PutMapping|@DeleteMapping|router\.(get|post|put|delete))' --include='*.py' --include='*.java' --include='*.js' --include='*.ts' --include='*.go' && hits+="API endpoints. "
    # Payment code
    _scan_has "$dir" '(stripe|paypal|braintree|square|payment|checkout)' --include='*.js' --include='*.ts' --include='*.py' --include='*.java' -i && hits+="payment processing. "
    [[ -n "$hits" ]] && printf 'Security-relevant code detected: %s' "${hits% }" || return 1
}

_scan_quality() {
    local dir="$1"
    local count
    count=$(_scan_count '\.(py|js|ts|rs|go|java|cpp|c|rb|php|cs|kt|scala)$')
    [[ "$count" -gt 20 ]] && { printf '%s source files — quality tools (complexity, dead code, dup detection) recommended. ' "$count"; return 0; }
    return 1
}

_scan_ci() {
    local dir="$1"
    [[ -d "$dir/.github/workflows" ]] && { printf 'GitHub Actions workflows. '; return 0; }
    [[ -f "$dir/.gitlab-ci.yml" ]] && { printf 'GitLab CI config. '; return 0; }
    [[ -f "$dir/Jenkinsfile" ]] && { printf 'Jenkinsfile. '; return 0; }
    [[ -d "$dir/.circleci" ]] && { printf 'CircleCI config. '; return 0; }
    [[ -f "$dir/azure-pipelines.yml" ]] && { printf 'Azure Pipelines. '; return 0; }
    [[ -f "$dir/.travis.yml" ]] && { printf 'Travis CI. '; return 0; }
    [[ -f "$dir/bitbucket-pipelines.yml" ]] && { printf 'Bitbucket Pipelines. '; return 0; }
    return 1
}

_scan_doc() {
    local dir="$1" hits=""
    [[ -d "$dir/docs" ]] && hits+="docs/ directory. "
    local md_count
    md_count=$(_scan_count '\.md$')
    [[ "$md_count" -gt 3 ]] && hits+="$md_count markdown files. "
    # API doc configs
    _scan_exists "$dir"/swagger*.yml "$dir"/swagger*.json "$dir"/openapi*.yml "$dir"/openapi*.json "$dir"/.redocly.yaml && hits+="OpenAPI/Swagger spec. "
    # Doc generation configs (skipped when docs/ or markdown already hit)
    [[ -z "$hits" ]] && _scan_has "$dir" '(typedoc|jsdoc|sphinx|mksdocs|mkdocs|docusaurus|gitbook)' --include='*.json' --include='*.toml' --include='*.yml' --include='*.yaml' --include='*.cfg' && hits+="doc generator config. "
    [[ -n "$hits" ]] && printf 'Documentation detected: %s' "${hits% }" || return 1
}

_scan_data() {
    local dir="$1" hits=""
    # Data files
    local data_count
    data_count=$(_scan_count '\.(csv|parquet|arrow|feather|orc)$')
    [[ "$data_count" -gt 0 ]] && hits+="$data_count data files (csv/parquet/arrow). "
    # Data processing code (skipped when data files already hit)
    [[ -z "$hits" ]] && _scan_has "$dir" '(pandas|polars|duckdb|dask|pyspark|spark|dbt|airflow|prefect)' --include='*.py' --include='*.sql' --include='*.yml' && hits+="data processing code. "
    # dbt project
    [[ -f "$dir/dbt_project.yml" ]] && hits+="dbt project. "
    # ETL dirs
    local d
    for d in etl pipeline pipelines dag dags; do
        [[ -d "$dir/$d" ]] && { hits+="ETL dir '$d/'. "; break; }
    done
    [[ -n "$hits" ]] && printf 'Data processing detected: %s' "${hits% }" || return 1
}

_scan_media() {
    local dir="$1" hits=""
    local media_count
    media_count=$(_scan_count '\.(png|jpe?g|gif|mp3|wav|mp4|mov|webm)$')
    [[ "$media_count" -gt 5 ]] && hits+="$media_count media files. "
    # Media processing code (skipped when media files already hit)
    [[ -z "$hits" ]] && _scan_has "$dir" '(ffmpeg|avconv|imagemagick|convert|PIL|pillow|opencv|cv2|sharp|jimp|whisper)' --include='*.py' --include='*.js' --include='*.ts' --include='*.rs' --include='*.sh' && hits+="media processing code. "
    [[ -n "$hits" ]] && printf 'Media files/processing detected: %s' "${hits% }" || return 1
}

_scan_opencv() {
    local dir="$1" hits=""
    # Explicit OpenCV usage in code or deps is the strong signal.
    _scan_has "$dir" '(import cv2|from cv2|cv2\.|opencv-python|opencv-contrib)' \
        --include='*.py' --include='*.ipynb' --include='requirements*.txt' \
        --include='pyproject.toml' --include='Pipfile' && hits+="OpenCV/cv2 code. "
    # Otherwise, a repo heavy in still images that isn't just a media/asset dump.
    if [[ -z "$hits" ]]; then
        local img_count
        img_count=$(_scan_count '\.(png|jpe?g|bmp|tiff?|webp)$')
        [[ "$img_count" -gt 20 ]] && hits+="$img_count images (candidate CV dataset). "
    fi
    [[ -n "$hits" ]] && printf 'Computer-vision work detected: %s' "${hits% }" || return 1
}

_scan_ollama() {
    local dir="$1" hits=""
    # ML framework imports
    _scan_has "$dir" '(torch|tensorflow|keras|sklearn|scikit|transformers|huggingface|openai|anthropic|langchain|llama.?cpp|ollama|whisper)' --include='*.py' --include='*.js' --include='*.ts' && hits+="ML/AI framework imports. "
    # Model files
    local model_count
    model_count=$(_scan_count '\.(pt|pth|onnx|gguf|bin|safetensors|tflite)$')
    [[ "$model_count" -gt 0 ]] && hits+="$model_count model files. "
    # Notebooks
    local nb_count
    nb_count=$(_scan_count '\.ipynb$')
    [[ "$nb_count" -gt 0 ]] && hits+="$nb_count Jupyter notebooks. "
    # Training scripts
    _scan_exists "$dir"/train*.py "$dir"/finetune*.py "$dir"/inference*.py && hits+="training/inference scripts. "
    [[ -n "$hits" ]] && printf 'AI/ML work detected: %s' "${hits% }" || return 1
}

_scan_monitor() {
    local dir="$1" hits=""
    # Prometheus config
    [[ -f "$dir/prometheus.yml" || -f "$dir/prometheus.yaml" ]] && hits+="Prometheus config. "
    # Grafana dashboards
    _scan_index_has '/[^/]*grafana[^/]*$|/[^/]*dashboard[^/]*\.json$' && hits+="Grafana dashboards. "
    # Datadog / OpenTelemetry / Sentry configs (skipped when a config already hit)
    [[ -z "$hits" ]] && _scan_has "$dir" '(datadog|ddtrace|opentelemetry|otel|sentry|jaeger|zipkin)' --include='*.py' --include='*.js' --include='*.ts' --include='*.java' --include='*.yml' --include='*.yaml' && hits+="observability library. "
    # Metrics code (skipped when a config/library already hit)
    [[ -z "$hits" ]] && _scan_has "$dir" '(prometheus_client|metrics_counter|histogram|gauge|Counter|Histogram)' --include='*.py' --include='*.js' --include='*.ts' --include='*.java' && hits+="metrics instrumentation. "
    [[ -n "$hits" ]] && printf 'Monitoring/observability detected: %s' "${hits% }" || return 1
}

_scan_s3() {
    local dir="$1" hits=""
    # AWS SDK imports
    _scan_has "$dir" '(boto3|aws-sdk|@aws-sdk|aws-sdk-go|minio|s3\.amazonaws|presigned)' --include='*.py' --include='*.js' --include='*.ts' --include='*.go' --include='*.java' && hits+="S3/cloud storage SDK. "
    # S3 in config
    _scan_has "$dir" '(S3_BUCKET|S3_ENDPOINT|S3_ACCESS_KEY|AWS_REGION|aws_access_key)' --include='.env*' --include='*.yml' --include='*.yaml' --include='*.conf' && hits+="S3 config. "
    [[ -n "$hits" ]] && printf 'S3/cloud storage detected: %s' "${hits% }" || return 1
}

_scan_ssh() {
    local dir="$1" hits=""
    # Deployment scripts
    _scan_exists "$dir"/deploy*.sh "$dir"/scripts/deploy*.sh && hits+="deploy scripts. "
    # Ansible
    _scan_exists "$dir"/ansible.cfg "$dir"/playbook*.yml "$dir"/site.yml && hits+="Ansible playbooks. "
    # SSH in config (skipped when deploy/ansible files already hit)
    [[ -z "$hits" ]] && _scan_has "$dir" '(ssh|scp|rsync).*(deploy|remote|server|prod)' --include='*.sh' --include='*.yml' --include='*.yaml' --include='Makefile' -i && hits+="SSH-based deployment. "
    [[ -n "$hits" ]] && printf 'Remote deployment detected: %s' "${hits% }" || return 1
}

_scan_brew() {
    local dir="$1"
    # Always relevant if we're on macOS/Linux and brew could help install missing deps
    local os; os=$(os_detect 2>/dev/null || printf 'unknown')
    [[ "$os" == "darwin" || "$os" == "linux" ]] || return 1
    # Check if doctor found missing deps that brew could install
    local missing_count=0
    local name
    for name in "${!YCA_DEP_STATUS[@]}"; do
        local status="${YCA_DEP_STATUS[$name]:-}"
        [[ "$status" == MISSING* ]] && ((missing_count++))
    done
    if [[ "$missing_count" -gt 0 ]]; then
        printf '%s missing dependencies detected by doctor — brew tools can install them. ' "$missing_count"
        return 0
    fi
    return 1
}

_scan_localdb() {
    local dir="$1"
    # SQLite files in the tree — but never the harness's own databases.
    local db_count
    db_count=$(printf '%s\n' "$_SCAN_INDEX" | grep -E '\.(sqlite3?|db)$' | grep -cvE '(^|/)(\.harness\.db|\.yantra-scratch\.db)' || true)
    [[ "$db_count" -gt 0 ]] && { printf '%s SQLite database file(s) — localdb tools can inspect/query them. ' "$db_count"; return 0; }
    return 1
}

_scan_kg() {
    local dir="$1"
    local count
    count=$(_scan_count '\.(py|js|ts|rs|go|java|cpp|c|rb|php|cs|kt|scala|sh)$')
    [[ "$count" -gt 30 ]] && { printf '%s source files — a code knowledge graph makes symbols/references queryable. ' "$count"; return 0; }
    return 1
}

# ── Content-grep helper (BOOLEAN, first-match early exit) ────────────────────
# _scan_has DIR PATTERN [--include=GLOB ...] [-i] -> 0 if any file matches.
# rg -q / grep -q stop at the first match — the old helper listed EVERY
# matching file in the tree per pattern and the caller threw the list away.
# Patterns must be portable ERE ([[:space:]] not \s, [0-9] not \d) so the
# grep fallback matches what ripgrep matches.
_scan_has() {
    local dir="$1" pattern="$2"; shift 2
    if command -v rg &>/dev/null; then
        local rgflags=() arg
        for arg in "$@"; do
            case "$arg" in
                --include=*) rgflags+=(-g "${arg#--include=}") ;;
                -i) rgflags+=(-i) ;;
            esac
        done
        rg -q --max-depth 4 --max-filesize 1M "${rgflags[@]}" -e "$pattern" "$dir" 2>/dev/null
    else
        local flags=() arg
        for arg in "$@"; do
            case "$arg" in
                --include=*) flags+=("$arg") ;;
                -i) flags+=(-i) ;;
            esac
        done
        grep -rqE "${flags[@]}" -e "$pattern" "$dir" 2>/dev/null
    fi
}
