# kg_symbols.awk — extract top-level symbol declarations from source files.
# Invoked as:  awk -v dir="$PROJECT_DIR" -f kg_symbols.awk FILE...
# Emits TSV rows:  kind<TAB>name<TAB>relpath<TAB>line
#   kind : function | class | module   (small, stable vocabulary)
#
# Path+line come from FILENAME/FNR, so paths containing ':' are safe and no
# shell escaping is needed. Precision-first: when unsure we drop a line rather
# than emit a garbage symbol. Covers the declaration forms current as of each
# language's latest spec (Python 3.12 `type`/`async def`; TS `interface|enum|
# type|function*`; Rust 2024 `async|const|unsafe|union|mod|macro_rules!`; Java
# 16+ `record|sealed`; PHP 8.1 `enum`; Scala 3 `enum`; Kotlin `data|object|
# typealias`; C#/Go generics; ...).
#
# NOTE on awk: a regex *constant* passed to a function is evaluated against $0
# (yielding "0"/"1"), so every prefix pattern here is a STRING passed to match()
# via after(). match() is leftmost, which also guards against a keyword that
# reappears later in a trailing comment. In an awk string literal, "\t" is a
# real tab, so "[ \t]" is a valid "space-or-tab" bracket expression.

function fext(p,   n, a) { n = split(p, a, "."); return (n > 1) ? tolower(a[n]) : "" }

# ident(s) -> leading identifier of s, after trimming leading non-word chars.
function ident(s) { sub(/^[^A-Za-z_$]+/, "", s); sub(/[^A-Za-z0-9_$].*$/, "", s); return s }

# after(line, re) -> identifier that follows the first match of prefix regex re.
function after(line, re) { return match(line, re) ? ident(substr(line, RSTART + RLENGTH)) : "" }

function emit(kind, name) { if (name != "") print kind "\t" name "\t" rel "\t" FNR }

# Reset per-file state at the first line of each file.
#   inblock : inside a /* … */ block comment
#   gotype  : inside a Go grouped `type ( … )` declaration
#   gdepth  : brace nesting within that Go block (so struct fields aren't types)
FNR == 1 { inblock = 0; gotype = 0; gdepth = 0 }

{
  rel = substr(FILENAME, length(dir) + 2)
  ext = fext(FILENAME)
  L = $0

  # ── Comment stripping (precision) ─────────────────────────────────────────
  # Real code carries prose that names keywords ("… calls this function for …",
  # "/** a class type parameter */"). Strip comments so declarations are only
  # matched in actual code. C-family/JS/TS/Go/Rust/Java/Kotlin/Scala/C#/PHP use
  # /* */ (stateful, multi-line) and // ; Python/Ruby use leading #.
  if (ext == "py" || ext == "rb") {
    if (L ~ /^[ \t]*#/) next
  } else {
    if (inblock) {
      if (match(L, /\*\//)) { L = substr(L, RSTART + RLENGTH); inblock = 0 }
      else next
    }
    while ((p = index(L, "/*")) > 0) {
      rest = substr(L, p + 2)
      if (match(rest, /\*\//)) L = substr(L, 1, p - 1) " " substr(rest, RSTART + RLENGTH)
      else { L = substr(L, 1, p - 1); inblock = 1; break }
    }
    p = index(L, "//"); if (p > 0) L = substr(L, 1, p - 1)
    # PHP: # starts a line comment, but #[ starts an attribute (PHP 8) — keep it.
    if (ext == "php" && (p = index(L, "#")) > 0 && substr(L, p + 1, 1) != "[") L = substr(L, 1, p - 1)
  }
  if (L ~ /^[ \t]*$/) next

  # ── Python ────────────────────────────────────────────────────────────────
  if (ext == "py") {
    if (L ~ /^[ \t]*(async[ \t]+)?def[ \t]+[A-Za-z_]/)     emit("function", after(L, "def[ \t]+"))
    else if (L ~ /^[ \t]*class[ \t]+[A-Za-z_]/)            emit("class",    after(L, "class[ \t]+"))
    else if (L ~ /^[ \t]*type[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]*(\[|=)/) emit("class", after(L, "type[ \t]+"))

  # ── JavaScript / TypeScript ───────────────────────────────────────────────
  } else if (ext=="js"||ext=="mjs"||ext=="cjs"||ext=="jsx"||ext=="ts"||ext=="tsx"||ext=="mts"||ext=="cts") {
    if (L ~ /(^|[ \t;])(async[ \t]+)?function[ \t*]+[A-Za-z_$]/) emit("function", after(L, "function[ \t*]+"))
    else if (L ~ /(^|[ \t])(abstract[ \t]+)?class[ \t]+[A-Za-z_$]/) emit("class",  after(L, "class[ \t]+"))
    else if (L ~ /(^|[ \t])interface[ \t]+[A-Za-z_$]/)             emit("class",  after(L, "interface[ \t]+"))
    else if (L ~ /(^|[ \t])enum[ \t]+[A-Za-z_$]/)                  emit("class",  after(L, "enum[ \t]+"))
    else if (L ~ /(^|[ \t])namespace[ \t]+[A-Za-z_$]/)             emit("module", after(L, "namespace[ \t]+"))
    else if (L ~ /(^|[ \t])type[ \t]+[A-Za-z_$][A-Za-z0-9_$]*[ \t]*[=<]/) emit("class", after(L, "type[ \t]+"))
    else if (L ~ /^[ \t]*(export[ \t]+)?(default[ \t]+)?(const|let|var)[ \t]+[A-Za-z_$][A-Za-z0-9_$]*[ \t]*=[ \t]*(async[ \t]*)?(\(|[A-Za-z_$][A-Za-z0-9_$, ]*=>|<)/)
      emit("function", after(L, "(const|let|var)[ \t]+"))

  # ── Go ────────────────────────────────────────────────────────────────────
  } else if (ext == "go") {
    # Inside a grouped `type ( … )`: each entry at brace-depth 0 is a type; the
    # brace counter keeps struct/interface *fields* (depth > 0) from counting.
    if (gotype) {
      if (gdepth == 0 && L ~ /^[ \t]*\)/) gotype = 0
      else {
        if (gdepth == 0 && L ~ /^[ \t]*[A-Za-z_]/) emit("class", after(L, "^[ \t]*"))
        gdepth += gsub(/[{]/, "{", L) - gsub(/[}]/, "}", L); if (gdepth < 0) gdepth = 0
      }
    }
    else if (L ~ /^type[ \t]*\([ \t]*$/) { gotype = 1; gdepth = 0 }
    # func with optional receiver: strip "func " and any "(recv) " before name.
    else if (L ~ /^func[ \t]/)          emit("function", after(L, "^func[ \t]+(\\([^)]*\\)[ \t]*)?"))
    else if (L ~ /^type[ \t]+[A-Za-z_]/) emit("class", after(L, "type[ \t]+"))

  # ── Rust (modifiers precede the keyword, so match on the keyword itself) ───
  } else if (ext == "rs") {
    if (L ~ /(^|[ \t])fn[ \t]+[A-Za-z_]/)                          emit("function", after(L, "(^|[ \t])fn[ \t]+"))
    else if (L ~ /(^|[ \t])(struct|enum|trait|union)[ \t]+[A-Za-z_]/) {
      if (L ~ /(^|[ \t])struct[ \t]/)     emit("class", after(L, "struct[ \t]+"))
      else if (L ~ /(^|[ \t])enum[ \t]/)  emit("class", after(L, "enum[ \t]+"))
      else if (L ~ /(^|[ \t])trait[ \t]/) emit("class", after(L, "trait[ \t]+"))
      else                                emit("class", after(L, "union[ \t]+"))
    }
    else if (L ~ /(^|[ \t])mod[ \t]+[A-Za-z_]/)          emit("module",   after(L, "mod[ \t]+"))
    else if (L ~ /^[ \t]*macro_rules![ \t]+[A-Za-z_]/)   emit("function", after(L, "macro_rules![ \t]+"))
    else if (L ~ /^[ \t]*type[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]*[=<]/) emit("class", after(L, "type[ \t]+"))

  # ── Java / Kotlin / Scala ─────────────────────────────────────────────────
  # (C# intentionally unsupported — its declaration syntax churns every release.)
  # Order matters: `class`/`struct` are checked first so compound forms resolve
  # to the real name — "enum class C"/"data class D"/"sealed class S" → after
  # `class`; bare `enum`/`record`/`interface`/`trait`/`object` fall through.
  } else if (ext=="java"||ext=="kt"||ext=="kts"||ext=="scala"||ext=="sc") {
    if (L ~ /(^|[ \t])class[ \t]+[A-Za-z_]/)       emit("class", after(L, "class[ \t]+"))
    else if (L ~ /(^|[ \t])struct[ \t]+[A-Za-z_]/) emit("class", after(L, "struct[ \t]+"))
    else if (L ~ /(^|[ \t])@?interface[ \t]+[A-Za-z_]/) emit("class", after(L, "interface[ \t]+"))
    else if (L ~ /(^|[ \t])enum[ \t]+[A-Za-z_]/)   emit("class", after(L, "enum[ \t]+"))
    else if (L ~ /(^|[ \t])record[ \t]+[A-Za-z_]/) emit("class", after(L, "record[ \t]+"))
    else if (L ~ /(^|[ \t])trait[ \t]+[A-Za-z_]/)  emit("class", after(L, "trait[ \t]+"))
    else if (L ~ /(^|[ \t])object[ \t]+[A-Za-z_]/) emit("class", after(L, "object[ \t]+"))
    else if ((ext=="kt"||ext=="kts") && L ~ /(^|[ \t])fun[ \t]+([<][^>]*>[ \t]*)?[A-Za-z_]/) emit("function", after(L, "fun[ \t]+([<][^>]*>[ \t]*)?"))
    else if ((ext=="kt"||ext=="kts") && L ~ /(^|[ \t])typealias[ \t]+[A-Za-z_]/) emit("class", after(L, "typealias[ \t]+"))
    else if ((ext=="scala"||ext=="sc") && L ~ /(^|[ \t])def[ \t]+[A-Za-z_]/)     emit("function", after(L, "def[ \t]+"))
    else if ((ext=="scala"||ext=="sc") && L ~ /(^|[ \t])type[ \t]+[A-Za-z_]/)    emit("class", after(L, "type[ \t]+"))
    # Scala 3 named context instance: `given intOrd: Ord[Int] = …` (the `:`
    # distinguishes a named given from an anonymous `given Ord[Int] = …`).
    else if ((ext=="scala"||ext=="sc") && L ~ /(^|[ \t])given[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]*:/) emit("class", after(L, "given[ \t]+"))

  # ── Ruby (method names may end in ? or !) ─────────────────────────────────
  } else if (ext == "rb") {
    if (L ~ /^[ \t]*def[ \t]+/) {
      s = L; sub(/^[ \t]*def[ \t]+(self\.)?/, "", s); sub(/[^A-Za-z0-9_?!].*$/, "", s); emit("function", s)
    }
    else if (L ~ /^[ \t]*class[ \t]+[A-Z]/)  emit("class",  after(L, "class[ \t]+"))
    else if (L ~ /^[ \t]*module[ \t]+[A-Z]/) emit("module", after(L, "module[ \t]+"))

  # ── PHP ───────────────────────────────────────────────────────────────────
  } else if (ext == "php") {
    if (L ~ /(^|[ \t])class[ \t]+[A-Za-z_]/)          emit("class",    after(L, "class[ \t]+"))
    else if (L ~ /(^|[ \t])interface[ \t]+[A-Za-z_]/) emit("class",    after(L, "interface[ \t]+"))
    else if (L ~ /(^|[ \t])trait[ \t]+[A-Za-z_]/)     emit("class",    after(L, "trait[ \t]+"))
    else if (L ~ /(^|[ \t])enum[ \t]+[A-Za-z_]/)      emit("class",    after(L, "enum[ \t]+"))
    else if (L ~ /(^|[ \t])function[ \t]+&?[A-Za-z_]/) emit("function", after(L, "function[ \t]+"))

  # ── C / C++ (heuristic; precision-first — favours declared types) ─────────
  } else if (ext=="c"||ext=="h"||ext=="cc"||ext=="cpp"||ext=="cxx"||ext=="hpp"||ext=="hh"||ext=="hxx") {
    if (L ~ /^[ \t]*namespace[ \t]+[A-Za-z_]/) emit("module", after(L, "namespace[ \t]+"))
    else if (L ~ /^[ \t]*(template[ \t]*<[^>]*>[ \t]*)?(class|struct|union|enum([ \t]+class)?)[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]*[:{;]/) {
      if (L ~ /(^|[ \t])struct[ \t]/)     emit("class", after(L, "struct[ \t]+"))
      else if (L ~ /(^|[ \t])union[ \t]/) emit("class", after(L, "union[ \t]+"))
      else if (L ~ /(^|[ \t])enum[ \t]/)  emit("class", after(L, "enum([ \t]+class)?[ \t]+"))
      else                                emit("class", after(L, "class[ \t]+"))
    }
    # function definition:  TYPE name(args)  opening a body (line ends with { or )).
    else if (L ~ /^[A-Za-z_][A-Za-z0-9_ \t\*&:<>,]*[ \t\*&]+[A-Za-z_][A-Za-z0-9_]*[ \t]*\([^;{]*\)[ \t]*\{?[ \t]*$/ && L !~ /^[ \t]*(if|for|while|switch|return|else|do|sizeof)[ \t(]/) {
      s = L; sub(/[ \t]*\(.*$/, "", s); sub(/^.*[ \t\*&]/, "", s); emit("function", ident(s))
    }
  }
}
