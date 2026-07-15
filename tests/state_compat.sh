#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${FABLE_MONITOR_BIN:-$ROOT/zig-out/bin/fable-monitor}"
FIX="$ROOT/tests/fixtures/baseline"
TMP="$(mktemp -d -t fable-state-compat)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -x "$BIN" ] || fail "binary not executable: $BIN"
command -v zstd >/dev/null 2>&1 || fail "zstd is required"

# A v1 snapshot has no meta record. It must load, re-baseline newer fields
# without a false restoration alert, and be upgraded to the current format.
printf '%s\n' '{"kind":"hash","id":"anthropic_statement","hash":"legacy"}' \
    | zstd -q -o "$TMP/v1.zst"
FABLE_MONITOR_STATE="$TMP/v1.zst" \
FABLE_MONITOR_LOG="$TMP/v1-log.zst" \
FABLE_MONITOR_EVENT_SINK="$TMP/v1-events.ndjson" \
FABLE_MONITOR_ONLY="anthropic_statement" \
FABLE_MONITOR_FIXTURES="$FIX" \
    "$BIN" poll >"$TMP/v1.out" 2>&1 || fail "v1 state poll failed"
zstd -qdc "$TMP/v1.zst" > "$TMP/v1.ndjson"
grep -q '"kind":"meta","version":5' "$TMP/v1.ndjson" || fail "v1 state was not upgraded to v5"
if [ -f "$TMP/v1-events.ndjson" ] && grep -q 'statement_restored' "$TMP/v1-events.ndjson"; then
    fail "v1 upgrade emitted a false restoration"
fi

# A state written by a future binary must fail closed and remain byte-for-byte
# intact, preserving rollback compatibility with that newer binary.
printf '%s\n' '{"kind":"meta","version":999}' | zstd -q -o "$TMP/future.zst"
cp "$TMP/future.zst" "$TMP/future.before"
if FABLE_MONITOR_STATE="$TMP/future.zst" \
    FABLE_MONITOR_LOG="$TMP/future-log.zst" \
    FABLE_MONITOR_ONLY="anthropic_statement" \
    FABLE_MONITOR_FIXTURES="$FIX" \
        "$BIN" poll >"$TMP/future.out" 2>&1; then
    fail "future state version was accepted"
fi
cmp -s "$TMP/future.before" "$TMP/future.zst" || fail "rejected future state was modified"

echo "PASS: v1 state upgrade and future-version rollback compatibility"
