#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARCHIVE="${1:?usage: release_artifact.sh <archive> [run-native]}"
RUN_NATIVE="${2:-false}"
TMP="$(mktemp -d -t fable-release-artifact)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -s "$ARCHIVE" ] || fail "archive missing or empty: $ARCHIVE"
tar -tzf "$ARCHIVE" > "$TMP/members"
if grep -Eq '(^/|(^|/)\.\.(/|$))' "$TMP/members"; then
    fail "archive contains an unsafe path"
fi
top="$(while IFS= read -r member; do printf '%s\n' "${member%%/*}"; done < "$TMP/members" | sort -u)"
[ "$(printf '%s\n' "$top" | wc -l | tr -d ' ')" -eq 1 ] || fail "archive has multiple roots"
grep -qx "$top/fable-monitor" "$TMP/members" || fail "archive has no fable-monitor binary"
grep -qx "$top/README.md" "$TMP/members" || fail "archive has no README"
grep -qx "$top/LICENSE" "$TMP/members" || fail "archive has no LICENSE"
tar -xzf "$ARCHIVE" -C "$TMP"
[ -x "$TMP/$top/fable-monitor" ] || fail "packaged binary is not executable"

if [ "$RUN_NATIVE" = true ]; then
    mkdir "$TMP/install"
    install -m 0755 "$TMP/$top/fable-monitor" "$TMP/install/fable-monitor"
    "$TMP/install/fable-monitor" banner OK 3 > "$TMP/banner.out"
    [ -s "$TMP/banner.out" ] || fail "installed binary smoke test produced no output"
    FABLE_MONITOR_BIN="$TMP/install/fable-monitor" bash "$ROOT/tests/state_compat.sh"
fi

echo "PASS: release artifact structure, install, and native smoke checks"
