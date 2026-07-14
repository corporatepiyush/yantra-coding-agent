# langs/ccpp.sh — C/C++ tools and workflows
# Rich introspection: detect build system, compiler, compile_commands.json,
# C/C++ standard, and report which tools are installed vs missing with install hints.

# ── Detection ──────────────────────────────────────────────────────────────
lang_ccpp_detect() {
    local dir="${1:-$YCA_PROJECT_DIR}"
    [[ -f "$dir/CMakeLists.txt" || -f "$dir/Makefile" || -f "$dir/meson.build" || -f "$dir/BUILD" || -f "$dir/configure" || -f "$dir/configure.ac" ]]
}

lang_ccpp_profile() {
    local dir="${1:-$YCA_PROJECT_DIR}"
    # Build system
    local build_system="make"
    [[ -f "$dir/CMakeLists.txt" ]] && build_system="cmake"
    [[ -f "$dir/meson.build" ]] && build_system="meson"
    [[ -f "$dir/BUILD" || -f "$dir/BUILD.bazel" ]] && build_system="bazel"
    [[ -f "$dir/Makefile" && -f "$dir/meson.build" ]] && build_system="meson"
    [[ -f "$dir/configure" || -f "$dir/configure.ac" ]] && build_system="autotools"
    # Compiler
    local compiler="gcc"
    command -v clang &>/dev/null && compiler="clang"
    # compile_commands.json
    local has_cc="false"
    [[ -f "$dir/compile_commands.json" || -f "$dir/build/compile_commands.json" ]] && has_cc="true"
    # C/C++ standard detection (best-effort from CMakeLists.txt)
    local c_std="" cpp_std=""
    if [[ -f "$dir/CMakeLists.txt" ]]; then
        c_std=$(grep -oP 'CMAKE_C_STANDARD\s+\K[0-9]+' "$dir/CMakeLists.txt" 2>/dev/null || true)
        cpp_std=$(grep -oP 'CMAKE_CXX_STANDARD\s+\K[0-9]+' "$dir/CMakeLists.txt" 2>/dev/null || true)
    fi
    # Build command
    local build="make"
    case "$build_system" in
        cmake) build="cmake --build build" ;;
        meson) build="ninja -C build" ;;
        bazel) build="bazel build //..." ;;
        autotools) build="./configure && make" ;;
    esac
    jq -n --arg bs "$build_system" --arg cc "$compiler" --argjson hcc "$has_cc" \
          --arg cstd "$c_std" --arg cppstd "$cpp_std" --arg build "$build" \
        '{build_system:$bs,compiler:$cc,has_compile_commands:$hcc,c_standard:$cstd,cpp_standard:$cppstd,build:$build,test:"ctest",lint:"clang-tidy",format:"clang-format -i",run:"./a.out"}'
}

# ── Helpers ────────────────────────────────────────────────────────────────
_ccpp_run() { (cd "$YCA_PROJECT_DIR" && "$@" 2>&1); }
_ccpp_missing() { printf 'tool missing: %s\ninstall: %s' "$1" "$2"; }

# ── Build systems ───────────────────────────────────────────────────────────
tool_ccpp_make() {
    command -v make &>/dev/null || { _ccpp_missing "make" "apt install build-essential / xcode-select --install"; return 1; }
    _ccpp_run make
}

tool_ccpp_cmake() {
    command -v cmake &>/dev/null || { _ccpp_missing "cmake" "apt install cmake / brew install cmake"; return 1; }
    _ccpp_run cmake -B build . && _ccpp_run cmake --build build
}

tool_ccpp_cmake_clean() {
    command -v cmake &>/dev/null || { _ccpp_missing "cmake" "apt install cmake / brew install cmake"; return 1; }
    _ccpp_run rm -rf build && _ccpp_run cmake -B build . && _ccpp_run cmake --build build
}

tool_ccpp_ninja() {
    command -v ninja &>/dev/null || { _ccpp_missing "ninja" "apt install ninja-build / brew install ninja"; return 1; }
    _ccpp_run ninja -C build
}

tool_ccpp_meson() {
    command -v meson &>/dev/null || { _ccpp_missing "meson" "pip install meson / apt install meson"; return 1; }
    if [[ ! -d "$YCA_PROJECT_DIR/build" ]]; then
        _ccpp_run meson setup build && _ccpp_run meson compile -C build
    else
        _ccpp_run meson compile -C build
    fi
}

tool_ccpp_bazel() {
    command -v bazel &>/dev/null || { _ccpp_missing "bazel" "https://bazel.build/install"; return 1; }
    _ccpp_run bazel build //...
}

# ── Test ────────────────────────────────────────────────────────────────────
tool_ccpp_ctest() {
    command -v ctest &>/dev/null || { _ccpp_missing "ctest" "apt install cmake / brew install cmake"; return 1; }
    if [[ -d "$YCA_PROJECT_DIR/build" ]]; then
        _ccpp_run ctest --test-dir build
    else
        printf 'no build directory found; run cmake first'
        return 1
    fi
}

tool_ccpp_googletest() {
    local dir="$YCA_PROJECT_DIR"
    # Try to find a prebuilt test binary
    local test_bin=""
    if [[ -f "$dir/build/test" ]]; then test_bin="$dir/build/test"
    elif [[ -f "$dir/build/tests" ]]; then test_bin="$dir/build/tests"
    elif [[ -f "$dir/build/test/test" ]]; then test_bin="$dir/build/test/test"
    elif [[ -f "$dir/build/test/runTests" ]]; then test_bin="$dir/build/test/runTests"
    elif [[ -f "$dir/build/tests/test" ]]; then test_bin="$dir/build/tests/test"
    elif [[ -f "$dir/build/tests/runTests" ]]; then test_bin="$dir/build/tests/runTests"
    fi
    if [[ -n "$test_bin" && -x "$test_bin" ]]; then
        _ccpp_run "$test_bin"
    elif grep -q 'gtest\|GTest\|googletest' "$dir/CMakeLists.txt" 2>/dev/null || grep -q 'gtest\|GTest\|googletest' "$dir/Makefile" 2>/dev/null; then
        printf 'GoogleTest detected in project files but no prebuilt test binary found.\nBuild first (cmake/make) then retry.'
        return 1
    else
        printf 'no GoogleTest test binary found and no gtest reference in project files'
        return 1
    fi
}

# ── Format ──────────────────────────────────────────────────────────────────
tool_ccpp_clang_format() {
    command -v clang-format &>/dev/null || { _ccpp_missing "clang-format" "apt install clang-format / brew install clang-format"; return 1; }
    _ccpp_run find . -name '*.c' -o -name '*.cpp' -o -name '*.cxx' -o -name '*.cc' -o -name '*.h' -o -name '*.hpp' -o -name '*.hxx' | xargs clang-format -i
}

tool_ccpp_clang_format_check() {
    command -v clang-format &>/dev/null || { _ccpp_missing "clang-format" "apt install clang-format / brew install clang-format"; return 1; }
    _ccpp_run find . -name '*.c' -o -name '*.cpp' -o -name '*.cxx' -o -name '*.cc' -o -name '*.h' -o -name '*.hpp' -o -name '*.hxx' | xargs clang-format --dry-run -Werror
}

tool_ccpp_clang_tidy() {
    command -v clang-tidy &>/dev/null || { _ccpp_missing "clang-tidy" "apt install clang-tidy / brew install llvm"; return 1; }
    local dir="$YCA_PROJECT_DIR"
    local cc_json=""
    if [[ -f "$dir/compile_commands.json" ]]; then cc_json="$dir/compile_commands.json"
    elif [[ -f "$dir/build/compile_commands.json" ]]; then cc_json="$dir/build/compile_commands.json"
    fi
    if [[ -z "$cc_json" ]]; then
        printf 'compile_commands.json not found — clang-tidy needs it for accurate analysis.\nGenerate with: cmake -DCMAKE_EXPORT_COMPILE_COMMANDS=ON -B build .\nRunning clang-tidy without it (may produce limited results)...\n'
    fi
    _ccpp_run find . -name '*.c' -o -name '*.cpp' -o -name '*.cxx' -o -name '*.cc' | xargs clang-tidy
}

# ── Static analysis ─────────────────────────────────────────────────────────
tool_ccpp_cppcheck() {
    command -v cppcheck &>/dev/null || { _ccpp_missing "cppcheck" "apt install cppcheck / brew install cppcheck"; return 1; }
    _ccpp_run cppcheck --enable=all --suppress=missingIncludeSystem --error-exitcode=1 .
}

tool_ccpp_iwyu() {
    command -v include-what-you-use &>/dev/null || { _ccpp_missing "include-what-you-use" "apt install iwyu / brew install include-what-you-use"; return 1; }
    local dir="$YCA_PROJECT_DIR"
    local cc_json=""
    if [[ -f "$dir/compile_commands.json" ]]; then cc_json="$dir/compile_commands.json"
    elif [[ -f "$dir/build/compile_commands.json" ]]; then cc_json="$dir/build/compile_commands.json"
    fi
    if [[ -z "$cc_json" ]]; then
        printf 'compile_commands.json not found — iwyu needs it.\nGenerate with: cmake -DCMAKE_EXPORT_COMPILE_COMMANDS=ON -B build .'
        return 1
    fi
    _ccpp_run include-what-you-use -Xiwyu --mapping_file=/usr/share/include-what-you-use/gcc.stl.headers "$(find . -name '*.c' -o -name '*.cpp' | head -1)"
}

# ── Sanitizers ──────────────────────────────────────────────────────────────
_ccpp_sanitizer_build() {
    local san="$1" san_flag="$2" dir="$YCA_PROJECT_DIR"
    local build_dir="$dir/build-sanitizers"
    mkdir -p "$build_dir"
    if [[ -f "$dir/CMakeLists.txt" ]]; then
        command -v cmake &>/dev/null || { _ccpp_missing "cmake" "apt install cmake / brew install cmake"; return 1; }
        _ccpp_run cmake -B "$build_dir" -S "$dir" -DCMAKE_C_FLAGS="$san_flag" -DCMAKE_CXX_FLAGS="$san_flag" -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
        _ccpp_run cmake --build "$build_dir"
    elif [[ -f "$dir/Makefile" ]]; then
        _ccpp_run make -C "$dir" CFLAGS="$san_flag" CXXFLAGS="$san_flag"
    else
        printf 'no CMakeLists.txt or Makefile found to build with %s' "$san"
        return 1
    fi
}

_ccpp_sanitizer_run() {
    local san="$1" san_flag="$2" dir="$YCA_PROJECT_DIR"
    printf '=== %s sanitizer build ===\n' "$san"
    _ccpp_sanitizer_build "$san" "$san_flag" || return 1
    printf '\n=== %s sanitizer run ===\n' "$san"
    local bin
    bin=$(find "$dir/build-sanitizers" -type f -executable 2>/dev/null | head -1)
    if [[ -n "$bin" ]]; then
        _ccpp_run "$bin"
    else
        printf 'no executable found in build-sanitizers'
        return 1
    fi
}

tool_ccpp_asan()  { _ccpp_sanitizer_run "ASan"  "-fsanitize=address -fno-omit-frame-pointer"; }
tool_ccpp_tsan()  { _ccpp_sanitizer_run "TSan"  "-fsanitize=thread -fno-omit-frame-pointer"; }
tool_ccpp_ubsan() { _ccpp_sanitizer_run "UBSan" "-fsanitize=undefined -fno-omit-frame-pointer"; }
tool_ccpp_msan()  {
    if ! command -v clang &>/dev/null; then
        _ccpp_missing "clang" "MSan requires clang; install: apt install clang / brew install llvm"
        return 1
    fi
    _ccpp_sanitizer_run "MSan" "-fsanitize=memory -fno-omit-frame-pointer -fsanitize-memory-track-origins"
}

# ── Profiling / debugging ───────────────────────────────────────────────────
tool_ccpp_valgrind() {
    command -v valgrind &>/dev/null || { _ccpp_missing "valgrind" "apt install valgrind / brew install valgrind"; return 1; }
    local binary="${1:-}"
    if [[ -z "$binary" ]]; then
        # Fallback search
        if [[ -f "$YCA_PROJECT_DIR/build" && -d "$YCA_PROJECT_DIR/build" ]]; then
            binary=$(find "$YCA_PROJECT_DIR/build" -type f -executable 2>/dev/null | head -1)
        fi
        binary="${binary:-./a.out}"
    fi
    _ccpp_run valgrind --leak-check=full --show-leak-kinds=all --track-origins=yes "$binary"
}

tool_ccpp_perf_record() {
    command -v perf &>/dev/null || { _ccpp_missing "perf" "apt install linux-perf / brew install perf (linux only)"; return 1; }
    local binary="${1:-}"
    if [[ -z "$binary" ]]; then
        if [[ -d "$YCA_PROJECT_DIR/build" ]]; then
            binary=$(find "$YCA_PROJECT_DIR/build" -type f -executable 2>/dev/null | head -1)
        fi
        binary="${binary:-./a.out}"
    fi
    local out="/tmp/perf_${EPOCHSECONDS}.data"
    _ccpp_run perf record -o "$out" "$binary" && _ccpp_run perf report -i "$out"
}

# ── compile_commands.json generation ────────────────────────────────────────
tool_ccpp_compile_commands() {
    local dir="$YCA_PROJECT_DIR"
    if [[ -f "$dir/CMakeLists.txt" ]]; then
        command -v cmake &>/dev/null || { _ccpp_missing "cmake" "apt install cmake / brew install cmake"; return 1; }
        _ccpp_run cmake -B build -S "$dir" -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
    elif [[ -f "$dir/Makefile" ]]; then
        if command -v bear &>/dev/null; then
            _ccpp_run bear -- make
        else
            _ccpp_missing "bear" "apt install bear / brew install bear / pip install bear"
            return 1
        fi
    else
        printf 'no CMakeLists.txt or Makefile found; cannot generate compile_commands.json'
        return 1
    fi
}

# ── Add dependency ──────────────────────────────────────────────────────────
# C/C++ has no universal package manager. Do the real thing when a manifest +
# tool exist (vcpkg manifest mode), otherwise be honest and guide the edit —
# never fake it. The package name is validated (no leading '-', no shell
# metacharacters) and passed as ARGV, never interpolated.
tool_ccpp_dep_add() {
    local pkg safe dir="$YCA_PROJECT_DIR"
    pkg=$(tool_arg package "${1:-}")
    safe=$(shell_arg_safe "$pkg") || { printf 'invalid package name (rejected: leading dash or shell metacharacter): %s' "$pkg"; return 1; }
    if [[ -f "$dir/vcpkg.json" ]] && command -v vcpkg &>/dev/null; then
        confirm_action "add dependency $safe to C/C++ project (vcpkg manifest)" "vcpkg add port $safe" || { confirm_denied_msg; return 1; }
        _ccpp_run vcpkg add port "$safe"
    elif [[ -f "$dir/conanfile.txt" || -f "$dir/conanfile.py" ]]; then
        printf 'Conan project detected. Conan has no CLI to edit the manifest.\n'
        printf 'Add "%s" under [requires] in conanfile.txt (or self.requires("%s") in conanfile.py),\n' "$safe" "$safe"
        printf 'then run: conan install .\n'
    elif command -v vcpkg &>/dev/null; then
        confirm_action "install C/C++ library $safe (vcpkg classic mode)" "vcpkg install $safe" || { confirm_denied_msg; return 1; }
        _ccpp_run vcpkg install "$safe"
    else
        printf 'C/C++ has no universal package manager — not adding "%s" blindly.\n' "$safe"
        printf 'Options: vcpkg (create vcpkg.json, then re-run to `vcpkg add port %s`)\n' "$safe"
        printf '     or: Conan (add %s under [requires] in conanfile.txt, then `conan install .`).\n' "$safe"
        return 1
    fi
}

# ── Introspection: what's installed ────────────────────────────────────────
tool_ccpp_doctor() {
    local out=""
    local t v
    for t in gcc g++ clang clang++ cmake make ninja meson bazel clang-tidy clang-format cppcheck valgrind include-what-you-use addr2line perf; do
        v=$(command -v "$t" 2>/dev/null && printf ' ok' || printf ' MISSING')
        out+="$t:$v\n"
    done
    # Compiler versions
    out+="\n"
    for t in gcc g++ clang clang++; do
        local ver
        ver=$("$t" --version 2>&1 | head -1 || printf '')
        out+="$t: $ver\n"
    done
    printf '%b' "$out"
}

# ── Register ───────────────────────────────────────────────────────────────
tool_register "ccpp_make"            tool_ccpp_make            '{"type":"object","properties":{}}' safe all ccpp
tool_register "ccpp_dep_add"         tool_ccpp_dep_add         '{"description":"Add a C/C++ dependency (vcpkg manifest) or emit an honest Conan/vcpkg guide — gated","type":"object","properties":{"package":{"type":"string","description":"port/library name (e.g. fmt or boost)"}},"required":["package"]}' writes all ccpp
tool_register "ccpp_cmake"           tool_ccpp_cmake           '{"type":"object","properties":{}}' writes all ccpp
tool_register "ccpp_cmake_clean"     tool_ccpp_cmake_clean     '{"type":"object","properties":{}}' writes all ccpp
tool_register "ccpp_ninja"           tool_ccpp_ninja           '{"type":"object","properties":{}}' safe all ccpp
tool_register "ccpp_meson"           tool_ccpp_meson           '{"type":"object","properties":{}}' writes all ccpp
tool_register "ccpp_bazel"           tool_ccpp_bazel           '{"type":"object","properties":{}}' safe all ccpp
tool_register "ccpp_ctest"           tool_ccpp_ctest           '{"type":"object","properties":{}}' safe all ccpp
tool_register "ccpp_googletest"      tool_ccpp_googletest      '{"type":"object","properties":{}}' safe all ccpp
tool_register "ccpp_clang_format"    tool_ccpp_clang_format    '{"type":"object","properties":{}}' writes all ccpp
tool_register "ccpp_clang_format_check" tool_ccpp_clang_format_check '{"type":"object","properties":{}}' safe all ccpp
tool_register "ccpp_clang_tidy"      tool_ccpp_clang_tidy      '{"type":"object","properties":{}}' safe all ccpp
tool_register "ccpp_cppcheck"        tool_ccpp_cppcheck        '{"type":"object","properties":{}}' safe all ccpp
tool_register "ccpp_iwyu"            tool_ccpp_iwyu            '{"type":"object","properties":{}}' safe all ccpp
tool_register "ccpp_asan"            tool_ccpp_asan            '{"type":"object","properties":{}}' safe all ccpp
tool_register "ccpp_tsan"            tool_ccpp_tsan            '{"type":"object","properties":{}}' safe all ccpp
tool_register "ccpp_ubsan"           tool_ccpp_ubsan           '{"type":"object","properties":{}}' safe all ccpp
tool_register "ccpp_msan"            tool_ccpp_msan            '{"type":"object","properties":{}}' safe all ccpp
tool_register "ccpp_valgrind"        tool_ccpp_valgrind        '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"}},"required":["file"]}' safe all ccpp
tool_register "ccpp_perf_record"     tool_ccpp_perf_record     '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"}},"required":["file"]}' safe all ccpp
tool_register "ccpp_compile_commands" tool_ccpp_compile_commands '{"type":"object","properties":{}}' writes all ccpp
tool_register "ccpp_doctor"          tool_ccpp_doctor          '{"type":"object","properties":{}}' safe all ccpp
