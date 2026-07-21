#!/usr/bin/env bash
set -euo pipefail

readonly TARGET_LINES=400
readonly MAX_SOURCE_LINES=500
readonly MAX_TEST_LINES=800
readonly EXCEPTION_FILE=architecture-exceptions.tsv

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
failures=0
warnings=0

exception_limit() {
    local path=$1
    [[ -f "$EXCEPTION_FILE" ]] || return 1
    awk -F '\t' -v path="$path" '$1 == "file" && $2 == path { print $3; found = 1; exit } END { if (!found) exit 1 }' "$EXCEPTION_FILE"
}

if [[ -f "$EXCEPTION_FILE" ]]; then
    while IFS=$'\t' read -r kind path limit reason; do
        [[ -z "$kind" || "$kind" == \#* ]] && continue
        if [[ "$kind" != file || -z "$path" || ! "$limit" =~ ^[0-9]+$ || ${#reason} -lt 12 \
              || "$path" == *'*'* || "$path" == */ || ! -f "$path" ]]; then
            printf 'ARCH ERROR: invalid exact-file exception: %s | %s | %s | %s\n' "$kind" "$path" "$limit" "$reason" >&2
            failures=$((failures + 1))
        fi
    done < "$EXCEPTION_FILE"
fi

is_test_file() {
    case "$1" in tests/*|test/*|test_*|*/tests/*|*/test/*|*/test_*|*_test.*) return 0 ;; *) return 1 ;; esac
}

while IFS= read -r -d '' path; do
    path=${path#./}
    lines=$(wc -l < "$path")
    exception=""
    if exception=$(exception_limit "$path"); then limit=$exception
    elif is_test_file "$path"; then limit=$MAX_TEST_LINES
    else limit=$MAX_SOURCE_LINES; fi
    if (( lines > limit )); then
        printf 'ARCH ERROR: %s has %d lines (limit %d)\n' "$path" "$lines" "$limit" >&2
        failures=$((failures + 1))
    elif [[ -n "$exception" ]] && (( lines > TARGET_LINES )); then
        printf 'ARCH NOTE:  %s uses its documented %d-line exception (%d lines)\n' "$path" "$limit" "$lines" >&2
    elif ! is_test_file "$path" && (( lines > TARGET_LINES )); then
        printf 'ARCH WARN:  %s has %d lines (target %d)\n' "$path" "$lines" "$TARGET_LINES" >&2
        warnings=$((warnings + 1))
    fi
done < <(
    find . \
        \( -path './.git' -o -path './target' -o -path '*/target' \
           -o -path './dist' -o -path './vendor' -o -path './third_party' \) -prune -o \
        -type f \( -name '*.rs' -o -name '*.c' -o -name '*.h' \
                     -o -name '*.lua' -o -name '*.sh' \
                     -o \( -path './scripts/*' ! -name '*.*' \) \) \
        ! -name '*.patch' -print0
)

if (( failures > 0 )); then
    printf 'Architecture check failed: %d violation(s).\n' "$failures" >&2
    exit 1
fi
printf 'Architecture check passed; review warnings and documented exceptions above.\n'
