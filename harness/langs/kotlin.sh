# langs/kotlin.sh — Kotlin tools and workflows
# Rich introspection: detect build system, compiler, linters, static analysis,
# coroutines, Android, multiplatform, and report install status with hints.

# ── Detection ──────────────────────────────────────────────────────────────
lang_kotlin_detect() {
    local dir="${1:-$YCA_PROJECT_DIR}"
    [[ -f "$dir/build.gradle.kts" || -f "$dir/build.gradle" || -f "$dir/settings.gradle.kts" || -f "$dir/settings.gradle" || -f "$dir/pom.xml" ]]
}

lang_kotlin_profile() {
    local dir="${1:-$YCA_PROJECT_DIR}" ver="" gradle="" jvm_target="" coroutines="false" android="false" multiplatform="false"
    ver=$(kotlin -version 2>&1 | head -1 || echo 'missing')
    if [[ -x "$dir/gradlew" ]]; then gradle="./gradlew";
    elif command -v gradle &>/dev/null; then gradle="gradle"; fi
    if [[ -f "$dir/build.gradle.kts" ]]; then
        jvm_target=$(grep -oP '(?<=jvmTarget\s*=\s*")[^"]+' "$dir/build.gradle.kts" 2>/dev/null || echo '')
        grep -q 'kotlinx.coroutines' "$dir/build.gradle.kts" 2>/dev/null && coroutines="true"
        grep -q 'id("com.android.application")' "$dir/build.gradle.kts" 2>/dev/null || grep -q 'id "com.android.application"' "$dir/build.gradle.kts" 2>/dev/null && android="true"
        grep -q 'kotlin("multiplatform")' "$dir/build.gradle.kts" 2>/dev/null || grep -q 'id("org.jetbrains.kotlin.multiplatform")' "$dir/build.gradle.kts" 2>/dev/null && multiplatform="true"
    fi
    jq -n --arg ver "$ver" --arg gradle "$gradle" --arg jvm "$jvm_target" --argjson coroutines "$coroutines" --argjson android "$android" --argjson multiplatform "$multiplatform" \
        '{build:"gradle build", test:"gradle test", lint:"ktlint", format:"ktlint -F", run:"gradle run", kotlin_version:$ver, gradle:$gradle, jvm_target:$jvm, coroutines:$coroutines, android:$android, multiplatform:$multiplatform}'
}

# ── Helpers ────────────────────────────────────────────────────────────────
_kotlin_run() { (cd "$YCA_PROJECT_DIR" && "$@" 2>&1); }
_kotlin_missing() { printf 'tool missing: %s\ninstall: %s' "$1" "$2"; }
_kotlin_gradle() {
    local dir="$YCA_PROJECT_DIR"
    if [[ -x "$dir/gradlew" ]]; then _kotlin_run ./gradlew "$@"
    elif command -v gradle &>/dev/null; then _kotlin_run gradle "$@"
    else _kotlin_missing "gradle/gradlew" "brew install gradle or use wrapper via gradle init"; return 1; fi
}

# ── Build ──────────────────────────────────────────────────────────────────
tool_kotlin_gradle_build() { _kotlin_gradle build; }
tool_kotlin_gradle_test()  { _kotlin_gradle test; }
tool_kotlin_gradle_clean() { _kotlin_gradle clean; }
tool_kotlin_gradle_run()   { _kotlin_gradle run; }

tool_kotlin_kotlinc() {
    local file="$1"
    [[ -n "$file" ]] || { printf 'kotlin source file required'; return 1; }
    command -v kotlinc &>/dev/null || { _kotlin_missing "kotlinc" "brew install kotlin"; return 1; }
    _kotlin_run kotlinc "$file" -include-runtime -d "${file%.kt}.jar" 2>&1 && printf 'compiled: %s.jar' "${file%.kt}"
}

# ── Lint / format ──────────────────────────────────────────────────────────
tool_kotlin_ktlint() {
    command -v ktlint &>/dev/null || { _kotlin_missing "ktlint" "brew install ktlint"; return 1; }
    _kotlin_run ktlint 2>&1
}

tool_kotlin_ktlint_fix() {
    command -v ktlint &>/dev/null || { _kotlin_missing "ktlint" "brew install ktlint"; return 1; }
    _kotlin_run ktlint -F 2>&1
}

# ── Static analysis ────────────────────────────────────────────────────────
tool_kotlin_detekt() {
    command -v detekt &>/dev/null || { _kotlin_missing "detekt" "brew install detekt"; return 1; }
    local config="$YCA_PROJECT_DIR/detekt.yml"
    if [[ -f "$config" ]]; then _kotlin_run detekt --config "$config"
    else _kotlin_run detekt; fi
}

tool_kotlin_coroutines_debug() {
    printf 'To debug Kotlin coroutines, run with: -Dkotlinx.coroutines.debug=on\n\n'
    printf 'Coroutines present in project: '
    grep -q 'kotlinx.coroutines' "$YCA_PROJECT_DIR/build.gradle.kts" 2>/dev/null && printf 'yes\n' || printf 'no (build.gradle.kts not found or no coroutines dependency)\n'
    printf '\nExample: JAVA_OPTS="-Dkotlinx.coroutines.debug=on" gradle run\n'
}

# ── Dependencies ───────────────────────────────────────────────────────────
tool_kotlin_dependencies() { _kotlin_gradle dependencies; }

# dep_add — Gradle offers no safe single-command "add dependency" that edits the
# build file. Be honest: validate the coordinate and print the exact edit —
# never fake it. The coordinate is validated (no leading '-', no shell metachars).
tool_kotlin_dep_add() {
    local pkg safe dir="$YCA_PROJECT_DIR"
    pkg=$(tool_arg package "${1:-}")
    safe=$(shell_arg_safe "$pkg") || { printf 'invalid package name (rejected: leading dash or shell metacharacter): %s' "$pkg"; return 1; }
    if [[ -f "$dir/gradle/libs.versions.toml" ]]; then
        printf 'Gradle version catalog detected (gradle/libs.versions.toml).\n'
        printf 'Add under [libraries] (coordinate group:artifact:version):\n'
        printf '  <alias> = "%s"\n' "$safe"
        printf 'then reference implementation(libs.<alias>) in build.gradle.kts.\n'
    else
        printf 'Kotlin/Gradle — add to dependencies { } in build.gradle.kts:\n'
        printf '  implementation("%s")\n' "$safe"
        printf 'then run: ./gradlew build  (Gradle has no safe CLI to edit the build file).\n'
    fi
}

# ── Introspection: what's installed ────────────────────────────────────────
tool_kotlin_doctor() {
    local out="" t v
    out+="kotlinc: "
    v=$(command -v kotlinc 2>/dev/null && kotlin -version 2>&1 | head -1 || printf 'MISSING')
    out+="$v\n"
    out+="gradle: "
    v=$(command -v gradle 2>/dev/null && gradle --version 2>&1 | head -1 || printf 'MISSING')
    out+="$v\n"
    out+="gradlew: "
    if [[ -x "$YCA_PROJECT_DIR/gradlew" ]]; then out+="present\n"; else out+="none\n"; fi
    out+="java: "
    v=$(command -v java 2>/dev/null && java -version 2>&1 | head -1 || printf 'MISSING')
    out+="$v\n"
    for t in ktlint detekt; do
        v=$(command -v "$t" 2>/dev/null && printf ' ok' || printf ' MISSING')
        out+="$t:$v\n"
    done
    printf '%b' "$out"
}

# ── Register ───────────────────────────────────────────────────────────────
tool_register "kotlin_gradle_build"   tool_kotlin_gradle_build   '{"type":"object","properties":{}}' safe all kotlin
tool_register "kotlin_gradle_test"    tool_kotlin_gradle_test    '{"type":"object","properties":{}}' safe all kotlin
tool_register "kotlin_gradle_clean"   tool_kotlin_gradle_clean   '{"type":"object","properties":{}}' safe all kotlin
tool_register "kotlin_gradle_run"     tool_kotlin_gradle_run     '{"type":"object","properties":{}}' safe all kotlin
tool_register "kotlin_kotlinc"        tool_kotlin_kotlinc        '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"}},"required":["file"]}' writes all kotlin
tool_register "kotlin_ktlint"         tool_kotlin_ktlint         '{"type":"object","properties":{}}' safe all kotlin
tool_register "kotlin_ktlint_fix"     tool_kotlin_ktlint_fix     '{"type":"object","properties":{}}' writes all kotlin
tool_register "kotlin_detekt"         tool_kotlin_detekt         '{"type":"object","properties":{}}' safe all kotlin
tool_register "kotlin_coroutines_debug" tool_kotlin_coroutines_debug '{"type":"object","properties":{}}' safe all kotlin
tool_register "kotlin_dependencies"   tool_kotlin_dependencies   '{"type":"object","properties":{}}' safe all kotlin
tool_register "kotlin_dep_add"        tool_kotlin_dep_add        '{"description":"Guide adding a Kotlin/Gradle dependency (no safe CLI edit exists; prints the exact build.gradle.kts change) — gated","type":"object","properties":{"package":{"type":"string","description":"coordinate group:artifact:version (e.g. io.ktor:ktor-client-core:2.3.0)"}},"required":["package"]}' writes all kotlin
tool_register "kotlin_doctor"         tool_kotlin_doctor         '{"type":"object","properties":{}}' safe all kotlin