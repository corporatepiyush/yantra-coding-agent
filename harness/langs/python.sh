# langs/python.sh — Python tools and workflows
# Rich introspection: detect package manager, test runner, linter, type checker,
# formatter, and report which are installed vs missing with install hints.

# ── Detection ──────────────────────────────────────────────────────────────
lang_python_detect() {
    local dir="${1:-$YCA_PROJECT_DIR}"
    [[ -f "$dir/pyproject.toml" || -f "$dir/requirements.txt" || -f "$dir/setup.py" || -f "$dir/setup.cfg" || -f "$dir/Pipfile" || -f "$dir/requirements-dev.txt" ]]
}

lang_python_profile() {
    local dir="${1:-$YCA_PROJECT_DIR}"
    # Package manager
    local pm="pip"
    [[ -f "$dir/poetry.lock" ]] && pm="poetry"
    [[ -f "$dir/uv.lock" ]] && pm="uv"
    [[ -f "$dir/Pipfile.lock" ]] && pm="pipenv"
    # Virtualenv
    local venv="false" venv_path=""
    if [[ -d "$dir/.venv" ]]; then venv="true"; venv_path="$dir/.venv";
    elif [[ -d "$dir/venv" ]]; then venv="true"; venv_path="$dir/venv"; fi
    # Test runner
    local test="pytest"
    if [[ -f "$dir/manage.py" ]]; then test="python manage.py test";
    elif ! command -v pytest &>/dev/null && grep -rq 'unittest' "$dir" --include='*.py' 2>/dev/null; then test="python -m unittest"; fi
    # Linter / formatter / type checker (detect config files)
    local lint="ruff check ." format="ruff format ." typecheck=""
    if [[ -f "$dir/.flake8" || -f "$dir/setup.cfg" ]] && command -v flake8 &>/dev/null; then lint="flake8 ."; fi
    if [[ -f "$dir/.pylintrc" || -f "$dir/pylintrc" ]] && command -v pylint &>/dev/null; then lint="pylint ."; fi
    if [[ -f "$dir/.mypy.ini" || -f "$dir/mypy.ini" || -f "$dir/pyproject.toml" ]] && command -v mypy &>/dev/null; then typecheck="mypy ."; fi
    if command -v pyright &>/dev/null; then typecheck="pyright"; fi
    local pyver=""
    pyver=$(python3 --version 2>&1 || python --version 2>&1)
    jq -n --arg pm "$pm" --argjson venv "$venv" --arg vp "$venv_path" \
          --arg test "$test" --arg lint "$lint" --arg format "$format" --arg tc "$typecheck" --arg pyver "$pyver" \
        '{build:"python -m build", test:$test, lint:$lint, format:$format, typecheck:$tc, run:"python -m $(basename $PWD)", package_manager:$pm, venv:$venv, venv_path:$vp, python_version:$pyver}'
}

# ── Helpers ────────────────────────────────────────────────────────────────
_py_run() { (cd "$YCA_PROJECT_DIR" && "$@" 2>&1); }
_py_in_venv() {
    # Run command inside the project venv if present
    local dir="$YCA_PROJECT_DIR"
    if [[ -d "$dir/.venv" && -x "$dir/.venv/bin/python" ]]; then
        (cd "$dir" && "$dir/.venv/bin/python" -m "$@" 2>&1)
    elif [[ -d "$dir/venv" && -x "$dir/venv/bin/python" ]]; then
        (cd "$dir" && "$dir/venv/bin/python" -m "$@" 2>&1)
    else
        (cd "$dir" && python3 -m "$@" 2>&1)
    fi
}
_py_pip() {
    local dir="$YCA_PROJECT_DIR"
    if [[ -f "$dir/uv.lock" ]]; then (cd "$dir" && uv "$@" 2>&1)
    elif [[ -f "$dir/poetry.lock" ]]; then (cd "$dir" && poetry run "$@" 2>&1)
    elif [[ -f "$dir/Pipfile.lock" ]]; then (cd "$dir" && pipenv run "$@" 2>&1)
    else (cd "$dir" && python3 -m pip "$@" 2>&1); fi
}
_py_missing() { printf 'tool missing: %s\ninstall: %s' "$1" "$2"; }
_py_bin() {
    # Print the interpreter path (project venv first) for direct `python -c` use.
    local dir="$YCA_PROJECT_DIR"
    if [[ -x "$dir/.venv/bin/python" ]]; then printf '%s' "$dir/.venv/bin/python"
    elif [[ -x "$dir/venv/bin/python" ]]; then printf '%s' "$dir/venv/bin/python"
    else command -v python3 || command -v python; fi
}

# ── Install / deps ─────────────────────────────────────────────────────────
tool_python_pip_install() {
    local dir="$YCA_PROJECT_DIR"
    if [[ -f "$dir/uv.lock" ]]; then _py_run uv sync
    elif [[ -f "$dir/poetry.lock" ]]; then _py_run poetry install
    elif [[ -f "$dir/Pipfile.lock" ]]; then _py_run pipenv install
    elif [[ -f "$dir/requirements.txt" ]]; then _py_in_venv pip install -r requirements.txt
    elif [[ -f "$dir/pyproject.toml" ]]; then _py_in_venv pip install -e .
    else printf 'no Python dependency manifest found (requirements.txt/pyproject.toml/Pipfile)'; return 1; fi
}

# dep_add — manager-aware add (uv add / poetry add / pipenv install / pip
# install). The package name is validated (no leading '-', no shell
# metacharacters) and passed as ARGV, never interpolated. Installing fetches +
# may run build/setup code + mutates the manifest/lockfile → gated.
tool_python_dep_add() {
    local pkg safe dir="$YCA_PROJECT_DIR"
    pkg=$(tool_arg package "${1:-}")
    safe=$(shell_arg_safe "$pkg") || { printf 'invalid package name (rejected: leading dash or shell metacharacter): %s' "$pkg"; return 1; }
    if [[ -f "$dir/uv.lock" ]] && command -v uv &>/dev/null; then
        confirm_action "add dependency $safe to python project (uv)" "uv add $safe" || { confirm_denied_msg; return 1; }
        _py_run uv add "$safe"
    elif [[ -f "$dir/poetry.lock" ]] && command -v poetry &>/dev/null; then
        confirm_action "add dependency $safe to python project (poetry)" "poetry add $safe" || { confirm_denied_msg; return 1; }
        _py_run poetry add "$safe"
    elif [[ -f "$dir/Pipfile.lock" || -f "$dir/Pipfile" ]] && command -v pipenv &>/dev/null; then
        confirm_action "add dependency $safe to python project (pipenv)" "pipenv install $safe" || { confirm_denied_msg; return 1; }
        _py_run pipenv install "$safe"
    else
        confirm_action "add dependency $safe to python project (pip)" "pip install $safe" || { confirm_denied_msg; return 1; }
        _py_in_venv pip install "$safe"
    fi
}

tool_python_pip_audit() {
    if command -v pip-audit &>/dev/null; then _py_in_venv pip-audit
    elif command -v safety &>/dev/null; then _py_run safety check
    else _py_missing "pip-audit" "pip install pip-audit"; return 1; fi
}

tool_python_dep_tree() {
    if command -v pipdeptree &>/dev/null; then _py_in_venv pipdeptree
    elif [[ -f "$YCA_PROJECT_DIR/poetry.lock" ]]; then _py_run poetry show --tree
    elif [[ -f "$YCA_PROJECT_DIR/uv.lock" ]]; then _py_run uv tree
    else _py_missing "pipdeptree" "pip install pipdeptree"; return 1; fi
}

tool_python_outdated() { _py_in_venv pip list --outdated 2>&1 || _py_missing "pip" "ensure pip is installed"; }

# ── Type checking ──────────────────────────────────────────────────────────
tool_python_mypy()   { command -v mypy &>/dev/null && _py_run mypy . || _py_missing "mypy" "pip install mypy"; }
tool_python_pyright(){ command -v pyright &>/dev/null && _py_run pyright || command -v npx &>/dev/null && _py_run npx pyright || _py_missing "pyright" "npm i -g pyright"; }

# ── Lint / format ──────────────────────────────────────────────────────────
tool_python_ruff()    { command -v ruff &>/dev/null && _py_run ruff check --fix . || _py_missing "ruff" "pip install ruff"; }
tool_python_ruff_fmt(){ command -v ruff &>/dev/null && _py_run ruff format . || _py_missing "ruff" "pip install ruff"; }
tool_python_black()   { command -v black &>/dev/null && _py_run black . || _py_missing "black" "pip install black"; }
tool_python_flake8()  { command -v flake8 &>/dev/null && _py_run flake8 . || _py_missing "flake8" "pip install flake8"; }
tool_python_pylint()  { command -v pylint &>/dev/null && _py_run pylint . || _py_missing "pylint" "pip install pylint"; }
tool_python_isort()   { command -v isort &>/dev/null && _py_run isort . || _py_missing "isort" "pip install isort"; }

# ── Test / coverage ────────────────────────────────────────────────────────
tool_python_pytest()   { command -v pytest &>/dev/null && _py_run pytest || _py_in_venv pytest; }
tool_python_pytest_cov(){ command -v pytest &>/dev/null && _py_run pytest --cov=. --cov-report=term-missing || _py_missing "pytest-cov" "pip install pytest pytest-cov"; }
tool_python_unittest() { _py_in_venv unittest discover -s . -p '*test*.py'; }
tool_python_hypothesis(){ command -v hypothesis &>/dev/null && _py_run pytest -p hypothesis --hypothesis-show-statistics || _py_missing "hypothesis" "pip install hypothesis"; }

# ── Security ───────────────────────────────────────────────────────────────
tool_python_bandit(){ command -v bandit &>/dev/null && _py_run bandit -r . || _py_missing "bandit" "pip install bandit"; }

# ── Profiling ──────────────────────────────────────────────────────────────
tool_python_cprofile() {
    local script="$1"
    [[ -n "$script" ]] || { printf 'script path required (use .py file)'; return 1; }
    _py_in_venv cProfile -s cumulative "$script" 2>&1 | head -40
}
tool_python_pyspy() {
    local pid="$1"
    command -v py-spy &>/dev/null || { _py_missing "py-spy" "pip install py-spy"; return 1; }
    [[ -n "$pid" ]] || { printf 'pid required'; return 1; }
    py-spy dump --pid "$pid" 2>&1
}
tool_python_pyspy_record() {
    local pid="$1" duration="${2:-10}"
    command -v py-spy &>/dev/null || { _py_missing "py-spy" "pip install py-spy"; return 1; }
    [[ -n "$pid" ]] || { printf 'pid required'; return 1; }
    local out="/tmp/py_spy_${EPOCHSECONDS}.svg"
    timeout "$duration" py-spy record --pid "$pid" -o "$out" 2>&1 && printf 'flamegraph: %s' "$out"
}
tool_python_tracemalloc() {
    local script="$1"
    [[ -n "$script" ]] || { printf 'script path required'; return 1; }
    _py_in_venv python -X tracemalloc=25 "$script" 2>&1 | tail -40
}

# ── Project introspection ──────────────────────────────────────────────────
tool_python_venv_info() {
    local py; py=$(_py_bin) || { _py_missing "python3" "https://www.python.org/downloads/"; return 1; }
    "$py" -c 'import sys, site
print("executable:", sys.executable)
print("version:", sys.version.split()[0])
print("prefix:", sys.prefix)
print("in_venv:", sys.prefix != sys.base_prefix)
sp = site.getsitepackages()
print("site-packages:", sp[0] if sp else "?")' 2>&1
    printf 'installed packages: %s\n' "$(_py_in_venv pip list 2>/dev/null | awk 'NR>2' | wc -l | tr -d ' ')"
}

tool_python_entry_points() {
    local dir="$YCA_PROJECT_DIR" py; py=$(_py_bin)
    if [[ -f "$dir/pyproject.toml" ]]; then
        "$py" - "$dir/pyproject.toml" <<'PY' 2>&1
import sys
try:
    import tomllib
except ImportError:
    sys.exit("tomllib unavailable (needs Python 3.11+) — read pyproject.toml manually")
with open(sys.argv[1], "rb") as f:
    data = tomllib.load(f)
proj = data.get("project", {})
print("name:", proj.get("name", "?"))
print("scripts:", proj.get("scripts") or "(none)")
print("gui-scripts:", proj.get("gui-scripts") or "(none)")
print("entry-points:", proj.get("entry-points") or "(none)")
poetry = data.get("tool", {}).get("poetry", {})
if poetry.get("scripts"):
    print("poetry scripts:", poetry["scripts"])
PY
    elif [[ -f "$dir/setup.py" || -f "$dir/setup.cfg" ]]; then
        grep -n -A5 'console_scripts' "$dir/setup.py" "$dir/setup.cfg" 2>/dev/null || printf 'no console_scripts found'
    else
        printf 'no pyproject.toml / setup.py in project'
        return 1
    fi
}

tool_python_freeze() { _py_in_venv pip freeze 2>&1 | head -150; }

# syntax — fast AST parse of every .py file (no imports run, no .pyc written).
tool_python_check_syntax() {
    local dir="${1:-$YCA_PROJECT_DIR}" py errors=0 count=0 f out
    py=$(_py_bin) || { _py_missing "python3" "https://www.python.org/downloads/"; return 1; }
    while IFS= read -r -d '' f; do
        ((count++))
        out=$("$py" -c 'import ast, sys
ast.parse(open(sys.argv[1]).read(), sys.argv[1])' "$f" 2>&1) || { printf '%s\n' "$out" | tail -3; ((errors++)); }
    done < <(find "$dir" -name '*.py' -type f ! -path '*/.venv/*' ! -path '*/venv/*' ! -path '*/.git/*' ! -path '*/node_modules/*' -print0 2>/dev/null)
    printf 'syntax check: %d files, %d errors\n' "$count" "$errors"
    (( errors == 0 ))
}

# ── Introspection: what's installed ────────────────────────────────────────
tool_python_doctor() {
    local dir="$YCA_PROJECT_DIR" out=""
    out+="Python: $(python3 --version 2>&1 || echo 'missing')\n"
    out+="Interpreter: $(command -v python3 || echo 'missing')\n"
    out+="Package manager: "
    if [[ -f "$dir/uv.lock" ]]; then out+="uv ($(uv --version 2>&1 || echo 'NOT installed'))"
    elif [[ -f "$dir/poetry.lock" ]]; then out+="poetry ($(poetry --version 2>&1 || echo 'NOT installed'))"
    elif [[ -f "$dir/Pipfile.lock" ]]; then out+="pipenv ($(pipenv --version 2>&1 || echo 'NOT installed'))"
    else out+="pip"; fi
    out+="\nVenv: "
    if [[ -d "$dir/.venv" ]]; then out+=".venv present"
    elif [[ -d "$dir/venv" ]]; then out+="venv present"
    else out+="none"; fi
    out+="\n"
    local t
    for t in pytest ruff black flake8 pylint mypy pyright isort bandit pip-audit pipdeptree py-spy; do
        local v
        v=$(command -v "$t" 2>/dev/null && printf ' ok' || printf ' MISSING')
        out+="$t:$v\n"
    done
    printf '%b' "$out"
}

# ── Register ───────────────────────────────────────────────────────────────
tool_register "python_pip_install"  tool_python_pip_install  '{"type":"object","properties":{}}' writes all python
tool_register "python_dep_add"      tool_python_dep_add      '{"description":"Add a Python dependency via the detected manager (uv/poetry/pipenv/pip) — fetches code + mutates the manifest — gated","type":"object","properties":{"package":{"type":"string","description":"distribution name, optionally versioned (e.g. requests or requests==2.31)"}},"required":["package"]}' writes all python
tool_register "python_pip_audit"    tool_python_pip_audit    '{"type":"object","properties":{}}' safe all python
tool_register "python_dep_tree"     tool_python_dep_tree     '{"type":"object","properties":{}}' safe all python
tool_register "python_outdated"     tool_python_outdated     '{"type":"object","properties":{}}' safe all python
tool_register "python_mypy"         tool_python_mypy         '{"type":"object","properties":{}}' safe all python
tool_register "python_pyright"      tool_python_pyright      '{"type":"object","properties":{}}' safe all python
tool_register "python_ruff"         tool_python_ruff         '{"type":"object","properties":{}}' writes all python
tool_register "python_ruff_fmt"     tool_python_ruff_fmt     '{"type":"object","properties":{}}' writes all python
tool_register "python_black"        tool_python_black        '{"type":"object","properties":{}}' writes all python
tool_register "python_flake8"       tool_python_flake8       '{"type":"object","properties":{}}' safe all python
tool_register "python_pylint"       tool_python_pylint       '{"type":"object","properties":{}}' safe all python
tool_register "python_isort"        tool_python_isort        '{"type":"object","properties":{}}' writes all python
tool_register "python_pytest"       tool_python_pytest       '{"type":"object","properties":{}}' safe all python
tool_register "python_pytest_cov"   tool_python_pytest_cov   '{"type":"object","properties":{}}' safe all python
tool_register "python_unittest"     tool_python_unittest     '{"type":"object","properties":{}}' safe all python
tool_register "python_hypothesis"   tool_python_hypothesis   '{"type":"object","properties":{}}' safe all python
tool_register "python_bandit"       tool_python_bandit       '{"type":"object","properties":{}}' safe all python
tool_register "python_cprofile"     tool_python_cprofile     '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"}},"required":["file"]}' safe all python
tool_register "python_pyspy"        tool_python_pyspy        '{"type":"object","properties":{"pid":{"type":"string","description":"the process id"}},"required":["pid"]}' safe all python
tool_register "python_pyspy_record" tool_python_pyspy_record '{"type":"object","properties":{"pid":{"type":"string","description":"the process id"},"duration":{"type":"integer","description":"duration to sample, in seconds"}},"required":["pid"]}' safe all python
tool_register "python_tracemalloc"  tool_python_tracemalloc  '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"}},"required":["file"]}' safe all python
tool_register "python_doctor"       tool_python_doctor       '{"type":"object","properties":{}}' safe all python
tool_register "python_venv_info"    tool_python_venv_info    '{"type":"object","properties":{}}' safe all python
tool_register "python_entry_points" tool_python_entry_points '{"type":"object","properties":{}}' safe all python
tool_register "python_freeze"       tool_python_freeze       '{"type":"object","properties":{}}' safe all python
tool_register "python_check_syntax"       tool_python_check_syntax       '{"type":"object","properties":{"path":{"type":"string","description":"file or directory path relative to the project root"}}}' safe all python
