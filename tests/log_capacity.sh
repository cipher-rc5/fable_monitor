#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/zig-out/bin/fable-monitor"
TMP="$(mktemp -d -t fable-log-capacity)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

[ -x "$BIN" ] || fail "build the binary before running this test"
BUDGET="$(perl -ne 'print $1 if /compaction \(default `([0-9]+)`/' "$ROOT/README.md")"
[ "$BUDGET" = 100000 ] || fail "could not resolve the documented default event budget"
INPUT_ROWS=$((BUDGET * 2))
LOG="$TMP/events.jsonl.zst"
STATE="$TMP/state.jsonl.zst"

# A legacy log at twice the documented capacity exercises migration and the
# expensive compaction path. Minimal valid rows keep the fixture reasonably small.
python3 - "$INPUT_ROWS" <<'PY' | zstd -q -c > "$LOG"
import sys
sys.stdout.write("{}\n" * int(sys.argv[1]))
PY

append_once() {
    FABLE_MONITOR_FIXTURES="$ROOT/tests/fixtures/baseline" \
    FABLE_MONITOR_ONLY=anthropic_model_list \
    FABLE_MONITOR_METRICS=1 \
    FABLE_MONITOR_MAX_EVENTS="$BUDGET" \
    FABLE_MONITOR_STATE="$STATE" FABLE_MONITOR_LOG="$LOG" \
        "$BIN" poll >"$TMP/poll.out" 2>"$TMP/poll.err"
}

assert_bounded() {
    local base rows files
    base="$(python3 - "$LOG.manifest" "$BUDGET" <<'PY'
import json, sys
manifest = json.load(open(sys.argv[1], encoding="utf-8"))
assert manifest["count"] == int(sys.argv[2]), manifest
assert manifest["base"], manifest
print(manifest["base"])
PY
)"
    rows="$(zstd -q -dc "$LOG.segments/$base" | wc -l | tr -d ' ')"
    [ "$rows" -eq "$BUDGET" ] || fail "retained $rows rows, expected $BUDGET"
    files="$(find "$LOG.segments" -type f | wc -l | tr -d ' ')"
    [ "$files" -le 2 ] || fail "append storage grew beyond a base plus one frame"
    [ ! -e "$LOG" ] || fail "legacy log was not retired after compaction"
}

append_once
assert_bounded
append_once
assert_bounded

echo "PASS: append remains bounded after 2x documented log capacity"
