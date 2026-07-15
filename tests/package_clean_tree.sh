#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d -t fable-clean-package)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# Copy only inputs available to a fresh checkout, deliberately excluding local
# caches and zig-out so packaging cannot accidentally consume stale products.
CLONE="$TMP/clone"
mkdir -p "$CLONE"
for file in build.zig build.zig.zon README.md LICENSE; do
    cp "$ROOT/$file" "$CLONE/$file"
done
for dir in src scripts tests dist; do
    cp -R "$ROOT/$dir" "$CLONE/$dir"
done

case "$(uname -s):$(uname -m)" in
    Darwin:arm64) target=aarch64-macos; platform=macos-aarch64 ;;
    Darwin:x86_64) target=x86_64-macos; platform=macos-x86_64 ;;
    Linux:aarch64) target=aarch64-linux-musl; platform=linux-aarch64 ;;
    Linux:x86_64) target=x86_64-linux-musl; platform=linux-x86_64 ;;
    *) fail "unsupported native packaging host: $(uname -s) $(uname -m)" ;;
esac

mkdir -p "$TMP/cache" "$TMP/global-cache"
(
    cd "$CLONE"
    ZIG_LOCAL_CACHE_DIR="$TMP/cache" ZIG_GLOBAL_CACHE_DIR="$TMP/global-cache" \
        bash scripts/package-release.sh "$target" "$platform" "$TMP/release"
)

shopt -s nullglob
archives=("$TMP"/release/*.tar.gz)
[ "${#archives[@]}" -eq 1 ] || fail "expected exactly one release archive"
bash "$CLONE/tests/release_artifact.sh" "${archives[0]}" true

echo "PASS: clean-tree package and native release artifact"
