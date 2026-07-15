#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/zig-out/bin/fable-monitor"
FIXTURES="$ROOT/tests/fixtures/preflight-default"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

[ -x "$BIN" ] || fail "real binary not built"

# Empty values from retained templates are equivalent to unset. Exercise the
# two scheduler environment shapes against every default source using fixtures.
for platform in linux macos; do
    mkdir -p "$TMP/$platform"
    common=(
        PATH="$PATH" HOME="$TMP/$platform" FABLE_MONITOR_FIXTURES="$FIXTURES"
        FABLE_MONITOR_STATE="$TMP/$platform/state.zst" FABLE_MONITOR_LOG="$TMP/$platform/events.zst"
        FABLE_MONITOR_SOURCES= FABLE_MONITOR_ONLY= FABLE_MONITOR_DISABLE=
        FABLE_MONITOR_WEBHOOK= FABLE_MONITOR_HEARTBEAT_URL= FABLE_MONITOR_EVENT_SINK=
        FABLE_MONITOR_NOTIFY= ANTHROPIC_API_KEY= FABLE_MONITOR_REQUIRED_SOURCES=
        FABLE_MONITOR_LOOP= FABLE_MONITOR_FORCE= FABLE_MONITOR_METRICS= FABLE_MONITOR_STATS=
        FABLE_MONITOR_FAST_INTERVAL= FABLE_MONITOR_ESCALATE_AFTER= FABLE_MONITOR_MAX_EVENTS=
        FABLE_MONITOR_MIN_DECISIVE_SOURCES= FABLE_MONITOR_PORT= FABLE_MONITOR_READER=
    )
    if [ "$platform" = linux ]; then common+=(FABLE_MONITOR_FAST_INTERVAL=45); fi
    env -i "${common[@]}" "$BIN" preflight >/dev/null 2>"$TMP/$platform/preflight.log" \
        || fail "$platform default install preflight failed"
done

if FABLE_MONITOR_FAST_INTERVAL=oops "$BIN" banner >/dev/null 2>&1; then
    fail "malformed numeric environment value was accepted"
fi
if FABLE_MONITOR_FORCE=true "$BIN" banner >/dev/null 2>&1; then
    fail "malformed boolean environment value was accepted"
fi
if FABLE_MONITOR_READER=yes "$BIN" banner >/dev/null 2>&1; then
    fail "malformed reader boolean was accepted"
fi
FABLE_MONITOR_FORCE=0 FABLE_MONITOR_STATS=0 "$BIN" banner >/dev/null

linux_out="$(HOME="$TMP/linux-preview" SCHEDULER=cron ANTHROPIC_API_KEY=do-not-write \
    bash "$ROOT/dist/install-linux.sh" --dry-run)"
for name in FABLE_MONITOR_SOURCES FABLE_MONITOR_WEBHOOK FABLE_MONITOR_HEARTBEAT_URL \
    FABLE_MONITOR_EVENT_SINK FABLE_MONITOR_NOTIFY ANTHROPIC_API_KEY; do
    [[ "$linux_out" != *"$name="* ]] || fail "Linux installer emitted unset $name"
done
[[ "$linux_out" != *FABLE_SLOW_INTERVAL* ]] || fail "Linux installer still exposes FABLE_SLOW_INTERVAL"

echo "PASS: empty env defaults, strict parsing, and real-binary installer preflights"
