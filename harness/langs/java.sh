# langs/java.sh — Java tools and workflows
# Rich introspection: detect build tool (Maven/Gradle), wrapper presence,
# Java version, and report which tools are installed vs missing with install hints.

# ── Detection ──────────────────────────────────────────────────────────────
lang_java_detect() {
    local dir="${1:-$YCA_PROJECT_DIR}"
    [[ -f "$dir/pom.xml" || -f "$dir/build.gradle" || -f "$dir/build.gradle.kts" ]]
}

_java_is_maven() { [[ -f "${1:-$YCA_PROJECT_DIR}/pom.xml" ]]; }
_java_is_gradle() { [[ -f "${1:-$YCA_PROJECT_DIR}/build.gradle" || -f "${1:-$YCA_PROJECT_DIR}/build.gradle.kts" ]]; }

lang_java_profile() {
    local dir="${1:-$YCA_PROJECT_DIR}"
    local build="mvn package -DskipTests" test="mvn test" lint="mvn checkstyle:check" format="mvn spotless:apply" run="mvn exec:java"
    local build_tool="maven" wrapper=""
    if _java_is_gradle "$dir"; then
        build_tool="gradle"
        if [[ -x "$dir/gradlew" ]]; then
            wrapper="gradlew"
            build="./gradlew build"
            test="./gradlew test"
            lint="./gradlew checkstyleMain"
            format="./gradlew spotlessApply"
            run="./gradlew run"
        else
            build="gradle build"
            test="gradle test"
            lint="gradle checkstyleMain"
            format="gradle spotlessApply"
            run="gradle run"
        fi
    fi
    local javaver=""
    javaver=$(java -version 2>&1 | head -1)
    jq -n --arg b "$build" --arg t "$test" --arg l "$lint" --arg f "$format" --arg r "$run" \
          --arg jv "$javaver" --arg bt "$build_tool" --arg wr "$wrapper" \
        '{build:$b, test:$t, lint:$l, format:$f, run:$r, build_tool:$bt, wrapper:$wr, java_version:$jv}'
}

# ── Helpers ────────────────────────────────────────────────────────────────
_java_run() { (cd "$YCA_PROJECT_DIR" && "$@" 2>&1); }
_java_missing() { printf 'tool missing: %s\ninstall: %s' "$1" "$2"; }

# Build-tool-aware: resolve the build command (respecting wrapper)
_java_build_cmd() {
    local dir="$YCA_PROJECT_DIR"
    if _java_is_gradle "$dir"; then
        [[ -x "$dir/gradlew" ]] && echo "./gradlew" || echo "gradle"
    else
        echo "mvn"
    fi
}

_java_mvn_or_gradle() {
    local mvn_cmd="$1" gradle_cmd="$2"
    local dir="$YCA_PROJECT_DIR"
    if _java_is_gradle "$dir"; then
        local cmd="$(_java_build_cmd)"
        _java_run "$cmd" $gradle_cmd
    else
        _java_run mvn $mvn_cmd
    fi
}

# ── Build ──────────────────────────────────────────────────────────────────
tool_java_mvn_build() {
    command -v mvn &>/dev/null || { _java_missing "mvn" "brew install maven  # or: apt install maven"; return 1; }
    _java_run mvn package -DskipTests
}

tool_java_mvn_test() {
    command -v mvn &>/dev/null || { _java_missing "mvn" "brew install maven"; return 1; }
    _java_run mvn test
}

tool_java_mvn_clean() {
    command -v mvn &>/dev/null || { _java_missing "mvn" "brew install maven"; return 1; }
    _java_run mvn clean
}

tool_java_mvn_dependency_tree() {
    command -v mvn &>/dev/null || { _java_missing "mvn" "brew install maven"; return 1; }
    _java_run mvn dependency:tree
}

tool_java_mvn_dependency_analyze() {
    command -v mvn &>/dev/null || { _java_missing "mvn" "brew install maven"; return 1; }
    _java_run mvn dependency:analyze
}

tool_java_gradle_build() {
    local cmd="$(_java_build_cmd)"
    command -v "$cmd" &>/dev/null || { _java_missing "$cmd" "brew install gradle"; return 1; }
    _java_run "$cmd" build
}

tool_java_gradle_test() {
    local cmd="$(_java_build_cmd)"
    command -v "$cmd" &>/dev/null || { _java_missing "$cmd" "brew install gradle"; return 1; }
    _java_run "$cmd" test
}

tool_java_gradle_clean() {
    local cmd="$(_java_build_cmd)"
    command -v "$cmd" &>/dev/null || { _java_missing "$cmd" "brew install gradle"; return 1; }
    _java_run "$cmd" clean
}

tool_java_gradle_dependencies() {
    local cmd="$(_java_build_cmd)"
    command -v "$cmd" &>/dev/null || { _java_missing "$cmd" "brew install gradle"; return 1; }
    _java_run "$cmd" dependencies --configuration compileClasspath
}

# ── Add dependency ──────────────────────────────────────────────────────────
# Neither Maven nor Gradle ships a safe single-command "add dependency" that
# edits the build file. Be honest: validate the coordinate, detect the build
# system, and print the exact edit — never fake it. The coordinate is validated
# (no leading '-', no shell metacharacters).
tool_java_dep_add() {
    local pkg safe dir="$YCA_PROJECT_DIR"
    pkg=$(tool_arg package "${1:-}")
    safe=$(shell_arg_safe "$pkg") || { printf 'invalid package name (rejected: leading dash or shell metacharacter): %s' "$pkg"; return 1; }
    if _java_is_gradle "$dir"; then
        if [[ -f "$dir/gradle/libs.versions.toml" ]]; then
            printf 'Gradle version catalog detected (gradle/libs.versions.toml).\n'
            printf 'Add under [libraries] (coordinate group:artifact:version):\n'
            printf '  <alias> = "%s"\n' "$safe"
            printf 'then reference implementation(libs.<alias>) in build.gradle[.kts], and build with %s.\n' "$(_java_build_cmd)"
        else
            printf 'Gradle project — add to dependencies { } in build.gradle[.kts]:\n'
            printf '  implementation("%s")\n' "$safe"
            printf 'then run: %s build  (Gradle has no safe CLI to edit the build file).\n' "$(_java_build_cmd)"
        fi
    else
        printf 'Maven project — add to <dependencies> in pom.xml (split group:artifact:version):\n'
        printf '  <dependency><groupId>…</groupId><artifactId>…</artifactId><version>…</version></dependency>\n'
        printf 'coordinate given: %s\nthen run: mvn install  (Maven has no safe CLI to edit pom.xml).\n' "$safe"
    fi
}

# ── Static analysis ────────────────────────────────────────────────────────
tool_java_checkstyle() {
    if _java_is_gradle "$YCA_PROJECT_DIR"; then
        local cmd="$(_java_build_cmd)"
        _java_run "$cmd" checkstyleMain
    else
        command -v mvn &>/dev/null || { _java_missing "mvn" "brew install maven"; return 1; }
        _java_run mvn checkstyle:check
    fi
}

tool_java_pmd() {
    if _java_is_gradle "$YCA_PROJECT_DIR"; then
        local cmd="$(_java_build_cmd)"
        _java_run "$cmd" pmdMain
    else
        command -v mvn &>/dev/null || { _java_missing "mvn" "brew install maven"; return 1; }
        _java_run mvn pmd:check
    fi
}

tool_java_spotbugs() {
    if _java_is_gradle "$YCA_PROJECT_DIR"; then
        local cmd="$(_java_build_cmd)"
        _java_run "$cmd" spotbugsCheck
    else
        command -v mvn &>/dev/null || { _java_missing "mvn" "brew install maven"; return 1; }
        _java_run mvn spotbugs:check
    fi
}

tool_java_errorprone() {
    # Error Prone is typically a compiler flag; detect if javac -J-XX is used or
    # if the project has net.ltgt.errorprone plugin.  We attempt a gradle build
    # with -Perrorprone or just run javac with -Xplugin:ErrorProne as a check.
    if _java_is_gradle "$YCA_PROJECT_DIR"; then
        local cmd="$(_java_build_cmd)"
        command -v "$cmd" &>/dev/null || { _java_missing "$cmd" "brew install gradle"; return 1; }
        _java_run "$cmd" compileJava -Perrorprone
    else
        command -v mvn &>/dev/null || { _java_missing "mvn" "brew install maven"; return 1; }
        _java_run mvn compile -Perrorprone
    fi
}

# ── Format ──────────────────────────────────────────────────────────────────
tool_java_format() {
    if _java_is_gradle "$YCA_PROJECT_DIR"; then
        local cmd="$(_java_build_cmd)"
        command -v "$cmd" &>/dev/null || { _java_missing "$cmd" "brew install gradle"; return 1; }
        _java_run "$cmd" spotlessApply
    else
        command -v mvn &>/dev/null || { _java_missing "mvn" "brew install maven"; return 1; }
        _java_run mvn spotless:apply
    fi
}

tool_java_format_check() {
    if _java_is_gradle "$YCA_PROJECT_DIR"; then
        local cmd="$(_java_build_cmd)"
        command -v "$cmd" &>/dev/null || { _java_missing "$cmd" "brew install gradle"; return 1; }
        _java_run "$cmd" spotlessCheck
    else
        command -v mvn &>/dev/null || { _java_missing "mvn" "brew install maven"; return 1; }
        _java_run mvn spotless:check
    fi
}

# ── Coverage ────────────────────────────────────────────────────────────────
tool_java_jacoco() {
    if _java_is_gradle "$YCA_PROJECT_DIR"; then
        local cmd="$(_java_build_cmd)"
        command -v "$cmd" &>/dev/null || { _java_missing "$cmd" "brew install gradle"; return 1; }
        _java_run "$cmd" jacocoTestReport
    else
        command -v mvn &>/dev/null || { _java_missing "mvn" "brew install maven"; return 1; }
        _java_run mvn jacoco:report
    fi
}

# ── Benchmarks ──────────────────────────────────────────────────────────────
tool_java_jmh() {
    if _java_is_gradle "$YCA_PROJECT_DIR"; then
        local cmd="$(_java_build_cmd)"
        command -v "$cmd" &>/dev/null || { _java_missing "$cmd" "brew install gradle"; return 1; }
        _java_run "$cmd" jmh
    else
        # Maven JMH plugin: typically me.champeau.jmh or through exec
        command -v mvn &>/dev/null || { _java_missing "mvn" "brew install maven"; return 1; }
        _java_run mvn verify -Pjmh
    fi
}

# ── JVM diagnostics ─────────────────────────────────────────────────────────
_jvm_pid() {
    local pid
    pid=$(jps -q 2>/dev/null | head -1)
    [[ -n "$pid" ]] || { printf 'no running Java process found'; return 1; }
    printf '%s' "$pid"
}

tool_java_jstack() {
    command -v jstack &>/dev/null || { _java_missing "jstack" "install JDK (not just JRE) — part of java-jdk"; return 1; }
    local pid
    pid=$(_jvm_pid) || { _jvm_pid; return 1; }
    _java_run jstack "$pid"
}

tool_java_jmap() {
    command -v jmap &>/dev/null || { _java_missing "jmap" "install JDK — part of java-jdk"; return 1; }
    local pid
    pid=$(_jvm_pid) || { _jvm_pid; return 1; }
    _java_run jmap -histo "$pid"
}

tool_java_jcmd() {
    command -v jcmd &>/dev/null || { _java_missing "jcmd" "install JDK — part of java-jdk"; return 1; }
    local pid
    pid=$(_jvm_pid) || { _jvm_pid; return 1; }
    _java_run jcmd "$pid" VM.info
}

tool_java_jfr_start() {
    local duration="${2:-60}"
    command -v jcmd &>/dev/null || { _java_missing "jcmd" "install JDK"; return 1; }
    local pid
    pid=$(_jvm_pid) || { _jvm_pid; return 1; }
    local out="/tmp/recording_${EPOCHSECONDS}.jfr"
    _java_run jcmd "$pid" JFR.start duration="${duration}s" filename="$out" settings=profile
    printf 'JFR recording: %s' "$out"
}

tool_java_jfr_dump() {
    command -v jcmd &>/dev/null || { _java_missing "jcmd" "install JDK"; return 1; }
    local pid
    pid=$(_jvm_pid) || { _jvm_pid; return 1; }
    _java_run jcmd "$pid" JFR.dump filename="/tmp/jfr_dump_${EPOCHSECONDS}.jfr"
}

# ── Project introspection ───────────────────────────────────────────────────
tool_java_doctor() {
    local dir="$YCA_PROJECT_DIR" out=""
    out+="--- Java Doctor ---\n"
    local t v
    for t in java javac mvn gradle; do
        v=$(command -v "$t" 2>/dev/null && printf ' ok' || printf ' MISSING')
        out+="  $t:$v\n"
    done
    out+="\nWrappers:\n"
    [[ -x "$dir/mvnw" ]] && out+="  mvnw: present\n" || out+="  mvnw: not found\n"
    [[ -x "$dir/gradlew" ]] && out+="  gradlew: present\n" || out+="  gradlew: not found\n"
    out+="\nBuild file:\n"
    [[ -f "$dir/pom.xml" ]] && out+="  pom.xml: present\n"
    [[ -f "$dir/build.gradle" ]] && out+="  build.gradle: present\n"
    [[ -f "$dir/build.gradle.kts" ]] && out+="  build.gradle.kts: present\n"
    local javaver javacver
    javaver=$(java -version 2>&1 | head -1)
    javacver=$(javac -version 2>&1 | head -1)
    out+="\nVersions:\n"
    out+="  java: $javaver\n"
    out+="  javac: $javacver\n"
    out+="\nTooling:\n"
    for t in spotbugs pmd checkstyle errorprone jacoco jmh jstack jmap jcmd; do
        v=$(command -v "$t" 2>/dev/null && printf ' ok' || printf ' MISSING')
        out+="  $t:$v\n"
    done
    out+="\nInstall hints:\n"
    out+="  brew install maven              # Maven\n"
    out+="  brew install gradle             # Gradle\n"
    out+="  brew install --cask adoptopenjdk # JDK with jstack/jmap/jcmd\n"
    printf '%b' "$out"
}

# ── Runtime & dependency introspection ──────────────────────────────────────
# jps — running JVMs with main class and flags.
tool_java_jps() {
    command -v jps &>/dev/null || { _java_missing "jps" "ships with the JDK — install a JDK"; return 1; }
    jps -lvm 2>&1
}

# dep_updates — dependencies with newer versions (Maven or Gradle).
tool_java_dep_updates() {
    if _java_is_gradle; then
        # requires the com.github.ben-manes.versions plugin
        _java_mvn_or_gradle "" "dependencyUpdates" 2>&1 | tail -60
    else
        command -v mvn &>/dev/null || { _java_missing "mvn" "brew install maven"; return 1; }
        _java_run mvn -q versions:display-dependency-updates 2>&1 | tail -60
    fi
}

# props — effective JVM system properties (versions, paths, encodings).
tool_java_props() {
    command -v java &>/dev/null || { _java_missing "java" "install a JDK"; return 1; }
    java -XshowSettings:properties -version 2>&1 | head -50
}

# ── Register ───────────────────────────────────────────────────────────────
tool_register "java_mvn_build"            tool_java_mvn_build            '{"type":"object","properties":{}}'            safe  all  java
tool_register "java_dep_add"              tool_java_dep_add              '{"description":"Guide adding a Maven/Gradle dependency (no safe CLI edit exists; prints the exact build-file change) — gated","type":"object","properties":{"package":{"type":"string","description":"coordinate group:artifact:version (e.g. com.google.guava:guava:33.0.0-jre)"}},"required":["package"]}' writes all  java
tool_register "java_mvn_test"             tool_java_mvn_test             '{"type":"object","properties":{}}'            safe  all  java
tool_register "java_mvn_clean"            tool_java_mvn_clean            '{"type":"object","properties":{}}'            writes all  java
tool_register "java_mvn_dependency_tree"  tool_java_mvn_dependency_tree  '{"type":"object","properties":{}}'            safe  all  java
tool_register "java_mvn_dependency_analyze" tool_java_mvn_dependency_analyze '{"type":"object","properties":{}}'      safe  all  java
tool_register "java_gradle_build"         tool_java_gradle_build         '{"type":"object","properties":{}}'            safe  all  java
tool_register "java_gradle_test"          tool_java_gradle_test          '{"type":"object","properties":{}}'            safe  all  java
tool_register "java_gradle_clean"         tool_java_gradle_clean         '{"type":"object","properties":{}}'            writes all  java
tool_register "java_gradle_dependencies"  tool_java_gradle_dependencies  '{"type":"object","properties":{}}'            safe  all  java
tool_register "java_checkstyle"           tool_java_checkstyle           '{"type":"object","properties":{}}'            safe  all  java
tool_register "java_pmd"                  tool_java_pmd                  '{"type":"object","properties":{}}'            safe  all  java
tool_register "java_spotbugs"             tool_java_spotbugs             '{"type":"object","properties":{}}'            safe  all  java
tool_register "java_errorprone"           tool_java_errorprone           '{"type":"object","properties":{}}'            safe  all  java
tool_register "java_format"               tool_java_format               '{"type":"object","properties":{}}'            writes all  java
tool_register "java_format_check"         tool_java_format_check         '{"type":"object","properties":{}}'            safe  all  java
tool_register "java_jacoco"               tool_java_jacoco               '{"type":"object","properties":{}}'            safe  all  java
tool_register "java_jmh"                  tool_java_jmh                  '{"type":"object","properties":{}}'            safe  all  java
tool_register "java_jstack"               tool_java_jstack               '{"type":"object","properties":{}}'            safe  all  java
tool_register "java_jmap"                 tool_java_jmap                 '{"type":"object","properties":{}}'            safe  all  java
tool_register "java_jcmd"                 tool_java_jcmd                 '{"type":"object","properties":{}}'            safe  all  java
tool_register "java_jfr_start"            tool_java_jfr_start            '{"type":"object","properties":{"duration":{"type":"integer","description":"duration to sample, in seconds"}}}' safe all java
tool_register "java_jfr_dump"             tool_java_jfr_dump             '{"type":"object","properties":{}}'            safe  all  java
tool_register "java_doctor"               tool_java_doctor               '{"type":"object","properties":{}}'            safe  all  java
tool_register "java_jps"                  tool_java_jps                  '{"type":"object","properties":{}}'            safe  all  java
tool_register "java_dep_updates"          tool_java_dep_updates          '{"type":"object","properties":{}}'            safe  all  java
tool_register "java_props"                tool_java_props                '{"type":"object","properties":{}}'            safe  all  java