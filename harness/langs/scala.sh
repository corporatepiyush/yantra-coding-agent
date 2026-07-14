# langs/scala.sh — Scala tools and workflows
# Rich introspection: detect Scala 2 vs 3, SBT, Mill, scalafmt, scalafix,
# wartremover, scoverage, bloop, coursier, and report install status with hints.

# ── Detection ──────────────────────────────────────────────────────────────
lang_scala_detect() {
    local dir="${1:-$YCA_PROJECT_DIR}"
    [[ -f "$dir/build.sbt" || -f "$dir/project/build.properties" || -f "$dir/build.sc" || -f "$dir/pom.xml" ]]
}

lang_scala_profile() {
    local dir="${1:-$YCA_PROJECT_DIR}" scala_ver="" sbt_ver="" has_mill="false" has_scala3="false"
    if command -v scala &>/dev/null; then scala_ver=$(scala -version 2>&1 | head -1); fi
    if command -v sbt &>/dev/null; then sbt_ver=$(sbt --version 2>&1 | head -1); fi
    if [[ -f "$dir/build.sc" ]]; then has_mill="true"; fi
    if grep -q 'scalaVersion.*3\.' "$dir/build.sbt" 2>/dev/null || grep -q '"org.scala-lang" % "scala3' "$dir/build.sbt" 2>/dev/null; then has_scala3="true"; fi
    jq -n --arg sv "$scala_ver" --arg sbt "$sbt_ver" --argjson mill "$has_mill" --argjson scala3 "$has_scala3" \
        '{build:"sbt compile", test:"sbt test", lint:"sbt scalafmtCheck", format:"sbt scalafmtAll", run:"sbt run", scala_version:$sv, sbt_version:$sbt, mill:$mill, scala3:$scala3}'
}

# ── Helpers ────────────────────────────────────────────────────────────────
_scala_run() { (cd "$YCA_PROJECT_DIR" && "$@" 2>&1); }
_scala_missing() { printf 'tool missing: %s\ninstall: %s' "$1" "$2"; }
_scala_sbt() {
    command -v sbt &>/dev/null || { _scala_missing "sbt" "brew install sbt"; return 1; }
    _scala_run sbt "$@"
}

# ── Build ──────────────────────────────────────────────────────────────────
tool_scala_sbt_compile() { _scala_sbt compile; }
tool_scala_sbt_test()    { _scala_sbt test; }
tool_scala_sbt_run()     { _scala_sbt run; }
tool_scala_sbt_clean()   { _scala_sbt clean; }

# ── Format / lint ──────────────────────────────────────────────────────────
tool_scala_scalafmt() {
    command -v scalafmt &>/dev/null || { _scala_missing "scalafmt" "brew install scalafmt or add sbt-scalafmt plugin"; return 1; }
    _scala_run scalafmt "$YCA_PROJECT_DIR" 2>&1
}

tool_scala_scalafmt_check() {
    command -v scalafmt &>/dev/null || { _scala_missing "scalafmt" "brew install scalafmt or add sbt-scalafmt plugin"; return 1; }
    _scala_run scalafmt --check "$YCA_PROJECT_DIR" 2>&1
}

tool_scala_scalafix() {
    command -v scalafix &>/dev/null || { _scala_missing "scalafix" "brew install scalafix or add sbt-scalafix plugin"; return 1; }
    _scala_run scalafix 2>&1
}

# ── Static analysis ────────────────────────────────────────────────────────
tool_scala_wartremover() {
    local dir="$YCA_PROJECT_DIR"
    if [[ -f "$dir/build.sbt" ]] && grep -q 'wartremover' "$dir/build.sbt" 2>/dev/null; then
        _scala_sbt wartremover 2>&1
    elif command -v sbt &>/dev/null; then
        printf 'wartremover plugin not detected in build.sbt\n'
        printf 'add to plugins.sbt: addSbtPlugin("org.wartremover" %% "sbt-wartremover" %% "3.3.0")\n'
        return 1
    else
        _scala_missing "sbt" "brew install sbt"; return 1
    fi
}

# ── Coverage ───────────────────────────────────────────────────────────────
tool_scala_scoverage() {
    command -v sbt &>/dev/null || { _scala_missing "sbt" "brew install sbt"; return 1; }
    _scala_run sbt coverage test coverageReport 2>&1
}

# ── Dependencies ───────────────────────────────────────────────────────────
tool_scala_dependencies() {
    command -v sbt &>/dev/null || { _scala_missing "sbt" "brew install sbt"; return 1; }
    # Try dependencyTree first, fall back to dependencyList
    _scala_run sbt dependencyTree 2>&1 || _scala_run sbt dependencyList 2>&1
}

# dep_add — sbt/Mill offer no safe single-command "add dependency" that edits
# the build file. Be honest: validate the coordinate and print the exact edit —
# never fake it. The coordinate is validated (no leading '-', no shell metachars).
tool_scala_dep_add() {
    local pkg safe dir="$YCA_PROJECT_DIR"
    pkg=$(tool_arg package "${1:-}")
    safe=$(shell_arg_safe "$pkg") || { printf 'invalid package name (rejected: leading dash or shell metacharacter): %s' "$pkg"; return 1; }
    if [[ -f "$dir/build.sc" ]]; then
        printf 'Mill project (build.sc) — add to def ivyDeps:\n'
        printf '  ivy"%s"   (format: org::name:version)\n' "$safe"
        printf 'then run: mill __.compile\n'
    else
        printf 'Scala/sbt — add to libraryDependencies in build.sbt:\n'
        printf '  libraryDependencies += "org" %%%% "name" %% "version"\n'
        printf 'coordinate given: %s\nthen run: sbt update  (sbt has no safe CLI to edit build.sbt).\n' "$safe"
    fi
}

# ── Mill support ───────────────────────────────────────────────────────────
tool_scala_mill() {
    local cmd="${1:-compile}"
    if [[ -f "$YCA_PROJECT_DIR/build.sc" ]]; then
        if command -v mill &>/dev/null; then
            _scala_run mill "$cmd" 2>&1
        else
            _scala_missing "mill" "brew install mill"; return 1
        fi
    else
        printf 'no build.sc found — not a Mill project'; return 1
    fi
}

# ── Introspection: what's installed ────────────────────────────────────────
tool_scala_doctor() {
    local out="" t v
    out+="scala: "
    v=$(command -v scala 2>/dev/null && scala -version 2>&1 | head -1 || printf 'MISSING')
    out+="$v\n"
    out+="scalac: "
    v=$(command -v scalac 2>/dev/null && scalac -version 2>&1 | head -1 || printf 'MISSING')
    out+="$v\n"
    out+="sbt: "
    v=$(command -v sbt 2>/dev/null && sbt --version 2>&1 | head -1 || printf 'MISSING')
    out+="$v\n"
    for t in mill scalafmt scalafix bloop coursier; do
        v=$(command -v "$t" 2>/dev/null && printf ' ok' || printf ' MISSING')
        out+="$t:$v\n"
    done
    printf '%b' "$out"
}

# ── Register ───────────────────────────────────────────────────────────────
tool_register "scala_sbt_compile"    tool_scala_sbt_compile    '{"type":"object","properties":{}}' safe all scala
tool_register "scala_dep_add"        tool_scala_dep_add        '{"description":"Guide adding a Scala sbt/Mill dependency (no safe CLI edit exists; prints the exact build change) — gated","type":"object","properties":{"package":{"type":"string","description":"coordinate org:name:version (e.g. org.typelevel:cats-core:2.10.0)"}},"required":["package"]}' writes all scala
tool_register "scala_sbt_test"       tool_scala_sbt_test       '{"type":"object","properties":{}}' safe all scala
tool_register "scala_sbt_run"        tool_scala_sbt_run        '{"type":"object","properties":{}}' safe all scala
tool_register "scala_sbt_clean"      tool_scala_sbt_clean      '{"type":"object","properties":{}}' safe all scala
tool_register "scala_scalafmt"       tool_scala_scalafmt       '{"type":"object","properties":{}}' writes all scala
tool_register "scala_scalafmt_check" tool_scala_scalafmt_check '{"type":"object","properties":{}}' safe all scala
tool_register "scala_scalafix"       tool_scala_scalafix       '{"type":"object","properties":{}}' writes all scala
tool_register "scala_wartremover"    tool_scala_wartremover    '{"type":"object","properties":{}}' safe all scala
tool_register "scala_scoverage"      tool_scala_scoverage      '{"type":"object","properties":{}}' safe all scala
tool_register "scala_dependencies"   tool_scala_dependencies   '{"type":"object","properties":{}}' safe all scala
tool_register "scala_mill"           tool_scala_mill           '{"type":"object","properties":{"cmd":{"type":"string","description":"the cmd"}},"required":["cmd"]}' safe all scala
tool_register "scala_doctor"         tool_scala_doctor         '{"type":"object","properties":{}}' safe all scala