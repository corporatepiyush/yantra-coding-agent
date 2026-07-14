# kg_imports.awk — extract module/dependency references from source files.
# Invoked as:  awk -v dir="$PROJECT_DIR" -f kg_imports.awk FILE...
# Emits TSV rows:  relpath<TAB>module
# \047=' \042=" so the file needs no shell quoting tricks.

function fext(p,   n, a) { n = split(p, a, "."); return (n > 1) ? tolower(a[n]) : "" }

FNR == 1 { inblock = 0 }

{
  rel = substr(FILENAME, length(dir) + 2)
  ext = fext(FILENAME)
  L = $0

  # Skip comments so commented-out imports are not counted (see kg_symbols.awk).
  if (ext == "py" || ext == "rb") {
    if (L ~ /^[ \t]*#/) next
  } else {
    if (inblock) { if (match(L, /\*\//)) { L = substr(L, RSTART + RLENGTH); inblock = 0 } else next }
    while ((p = index(L, "/*")) > 0) {
      rest = substr(L, p + 2)
      if (match(rest, /\*\//)) L = substr(L, 1, p - 1) " " substr(rest, RSTART + RLENGTH)
      else { L = substr(L, 1, p - 1); inblock = 1; break }
    }
    p = index(L, "//"); if (p > 0) L = substr(L, 1, p - 1)
    if (ext == "php" && (p = index(L, "#")) > 0 && substr(L, p + 1, 1) != "[") L = substr(L, 1, p - 1)
  }
  if (L ~ /^[ \t]*$/) next

  if (ext == "py") {
    if (match(L, /^[ \t]*(import|from)[ \t]+[A-Za-z_][A-Za-z0-9_.]*/)) {
      m = substr(L, RSTART, RLENGTH); sub(/^[ \t]*(import|from)[ \t]+/, "", m); print rel "\t" m
    }
  } else if (ext=="js"||ext=="mjs"||ext=="cjs"||ext=="jsx"||ext=="ts"||ext=="tsx"||ext=="mts"||ext=="cts") {
    s = L
    while (match(s, /(from[ \t]+|require\(|import\()[\047\042][^\047\042]+/)) {
      t = substr(s, RSTART, RLENGTH); sub(/.*[\047\042]/, "", t); if (t != "") print rel "\t" t
      s = substr(s, RSTART + RLENGTH)
    }
  } else if (ext == "go") {
    s = L
    while (match(s, /\042[a-zA-Z0-9_.\/-]+\042/)) {
      t = substr(s, RSTART, RLENGTH); gsub(/\042/, "", t); if (t ~ /\//) print rel "\t" t
      s = substr(s, RSTART + RLENGTH)
    }
  } else if (ext == "rs") {
    if (match(L, /^[ \t]*(pub[ \t]+)?use[ \t]+[A-Za-z_][A-Za-z0-9_:]*/)) {
      m = substr(L, RSTART, RLENGTH); sub(/^[ \t]*(pub[ \t]+)?use[ \t]+/, "", m); print rel "\t" m
    }
  } else if (ext=="java"||ext=="kt"||ext=="kts"||ext=="scala"||ext=="sc") {
    if (match(L, /^[ \t]*import[ \t]+(static[ \t]+)?[A-Za-z_][A-Za-z0-9_.]*/)) {
      m = substr(L, RSTART, RLENGTH); sub(/^[ \t]*import[ \t]+(static[ \t]+)?/, "", m); print rel "\t" m
    }
  } else if (ext == "rb") {
    s = L
    while (match(s, /require(_relative)?[ \t]+[\047\042][^\047\042]+/)) {
      t = substr(s, RSTART, RLENGTH); sub(/.*[\047\042]/, "", t); if (t != "") print rel "\t" t
      s = substr(s, RSTART + RLENGTH)
    }
  } else if (ext == "php") {
    if (match(L, /^[ \t]*use[ \t]+[A-Za-z_\\][A-Za-z0-9_\\]*/)) {
      m = substr(L, RSTART, RLENGTH); sub(/^[ \t]*use[ \t]+/, "", m); print rel "\t" m
    }
  }
}
