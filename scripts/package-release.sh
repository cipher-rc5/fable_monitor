#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${1:?usage: package-release.sh <zig-target> <platform-name> [output-dir]}"
PLATFORM="${2:?usage: package-release.sh <zig-target> <platform-name> [output-dir]}"
OUT="${3:-$ROOT/release}"
VERSION="$(perl -ne 'print $1 if /\.version\s*=\s*"([^"]+)"/' "$ROOT/build.zig.zon")"

[ -n "$VERSION" ] || { echo "FAIL: could not read version from build.zig.zon" >&2; exit 1; }
command -v zig >/dev/null 2>&1 || { echo "FAIL: zig is required" >&2; exit 1; }

TMP="$(mktemp -d -t fable-release)"
trap 'rm -rf "$TMP"' EXIT
NAME="fable-monitor-${VERSION}-${PLATFORM}"

mkdir -p "$OUT" "$TMP/$NAME"
zig build -Doptimize=ReleaseSafe -Dtarget="$TARGET" -Dcpu=baseline --prefix "$TMP/install"
cp "$TMP/install/bin/fable-monitor" "$TMP/$NAME/fable-monitor"
cp "$ROOT/README.md" "$ROOT/LICENSE" "$TMP/$NAME/"
tar -C "$TMP" -czf "$OUT/$NAME.tar.gz" "$NAME"

echo "PASS: packaged $OUT/$NAME.tar.gz (target=$TARGET, cpu=baseline)"
