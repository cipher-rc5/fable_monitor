#!/usr/bin/env bash
# Convention gate: every Zig source under src/ must open with a `//!` module
# doc-comment header. Verified true across the current tree (all src/**.zig
# files start with `//!`); this catches FUTURE files that forget the header.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

missing=0
while IFS= read -r file; do
    first_line="$(head -n 1 "$file")"
    case "$first_line" in
        "//!"*) ;;
        *)
            printf 'Missing //! module doc-comment header: %s\n' "$file" >&2
            missing=1
            ;;
    esac
done < <(find src -name '*.zig' | sort)

if [ "$missing" -ne 0 ]; then
    printf 'FAIL: one or more src/*.zig files lack a //! module header\n' >&2
    exit 1
fi

printf 'PASS: all src/*.zig files start with a //! module doc-comment header\n'
