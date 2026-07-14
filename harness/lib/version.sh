# lib/12-version.sh — Version string comparison utilities

# version_ge A B -> 0 if A >= B (semantic version compare)
version_ge() {
    [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ]
}

# version_lt A B -> 0 if A < B
version_lt() {
    ! version_ge "$1" "$2"
}

# version_eq A B -> 0 if equal
version_eq() {
    [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n1)" == \
       "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" ]]
}

# version_gt A B -> 0 if A > B
version_gt() {
    version_ge "$1" "$2" && ! version_eq "$1" "$2"
}

# version_parse VERSION -> prints "major minor patch" (space separated)
version_parse() {
    local v="$1"
    # Strip leading 'v' or 'V'
    v="${v#v}"; v="${v#V}"
    # Split on dots and dashes
    local major minor patch
    IFS='.-' read -r major minor patch _ <<< "$v"
    printf '%s %s %s' "${major:-0}" "${minor:-0}" "${patch:-0}"
}

# version_major VERSION -> prints major number
version_major() {
    local v="${1#v}"; v="${v#V}"
    printf '%s' "${v%%[.-]*}"
}

# version_minor VERSION
version_minor() {
    local parts
    parts=$(version_parse "$1")
    printf '%s' "$(printf '%s' "$parts" | cut -d' ' -f2)"
}

# version_patch VERSION
version_patch() {
    local parts
    parts=$(version_parse "$1")
    printf '%s' "$(printf '%s' "$parts" | cut -d' ' -f3)"
}

# version_normalize VERSION -> strips prefix, returns "major.minor.patch"
version_normalize() {
    local parts
    parts=$(version_parse "$1")
    printf '%s.%s.%s' $(printf '%s' "$parts")
}

# version_extract_from_output OUTPUT REGEX -> first version match
version_extract() {
    local output="$1" regex="$2"
    printf '%s' "$output" | grep -oE "$regex" | head -1
}

# version_in_range VERSION MIN MAX -> 0 if MIN <= VERSION <= MAX
version_in_range() {
    version_ge "$1" "$2" && version_ge "$3" "$1"
}
