#!/usr/bin/env bash
#
# End-to-end replay test for the full detection pipeline, driven entirely by
# captured fixtures (no network). Proves the brief's "definition of done" #4:
# the pipeline fires on a simulated restoration, end to end, including the
# notification hook; and the Workstream 7 acceptance: zero false negatives on
# the restoration fixture, and the decoys do not trip.
#
# Stages:
#   1. baseline   -> no trip (models absent, statement suspended)
#   2. restored   -> tier-1 trip: model-list absent->present on two independent
#                    probes (coalesced), statement restoration language, plus a
#                    tier-2 FR advisory; the notify hook fires
#   3. restored#2 -> idempotent: zero new structured events
#   4. decoy      -> no trip (layout churn + an unrelated "fable" FR document)
#   5. latency    -> in-process fixture poll completes under a bound
#
# Usage: bash tests/e2e.sh   (run from the repo root; needs a built binary)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/zig-out/bin/fable-monitor"
FIX="$ROOT/tests/fixtures"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

[ -x "$BIN" ] || { echo "FAIL: binary not built ($BIN). Run: zig build" >&2; exit 1; }

# The restoration scenario the brief specifies: model list flips, statement
# changes, an FR public-inspection document appears.
export FABLE_MONITOR_ONLY="anthropic_model_list,anthropic_pricing,anthropic_statement,fr_pi_bis"
export FABLE_MONITOR_STATE="$TMP/state.jsonl.zst"
export FABLE_MONITOR_LOG="$TMP/log.jsonl.zst"
NOTIFY_FILE="$TMP/notify.txt"
export FABLE_MONITOR_NOTIFY="echo \">>> \$1\" >> $NOTIFY_FILE"

fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { echo "ok: $1"; }

# Run a poll against a fixture set, writing the structured events to $1.
poll() { # poll <fixture_dir> <sink_file>
    FABLE_MONITOR_EVENT_SINK="$2" FABLE_MONITOR_FIXTURES="$FIX/$1" "$BIN" poll >"$TMP/out.log" 2>&1
}
events() { [ -f "$1" ] && grep -c '^{' "$1" 2>/dev/null || echo 0; }

# --- 1. baseline: no trip --------------------------------------------------
poll baseline "$TMP/ev1.ndjson"
[ "$(events "$TMP/ev1.ndjson")" -eq 0 ] || fail "baseline emitted structured events"
pass "baseline: no trip"

# --- 2. restored: tier-1 trip + notify -------------------------------------
poll restored "$TMP/ev2.ndjson"
n=$(events "$TMP/ev2.ndjson")
[ "$n" -ge 3 ] || fail "restored emitted $n events, expected >=3 (two model + statement)"
grep -q '"event_id":"model_present:claude-fable-5".*"confidence":"high"' "$TMP/ev2.ndjson" \
    || fail "no high-confidence model_present:claude-fable-5 event"
grep -q '"event_id":"statement_restored".*"confidence":"high"' "$TMP/ev2.ndjson" \
    || fail "no high-confidence statement_restored event"
# The two model probes must coalesce into one event with both corroborating.
grep -q '"corroborating_sources":\["anthropic_model_list","anthropic_pricing"\]' "$TMP/ev2.ndjson" \
    || fail "model probes did not coalesce into one corroborated event"
[ -f "$NOTIFY_FILE" ] && grep -q 'RESTORATION' "$NOTIFY_FILE" || fail "notify hook did not fire on restoration"
pass "restored: $n tier-1/2 events, coalesced, notify fired"

# --- 3. idempotency: re-running restored emits nothing new -----------------
poll restored "$TMP/ev3.ndjson"
[ "$(events "$TMP/ev3.ndjson")" -eq 0 ] || fail "re-run of restored re-fired alerts (not idempotent)"
pass "restored re-run: idempotent (0 new events)"

# --- 4. decoy: layout churn + unrelated 'fable' doc must not trip ----------
export FABLE_MONITOR_STATE="$TMP/state2.jsonl.zst"
export FABLE_MONITOR_LOG="$TMP/log2.jsonl.zst"
poll baseline "$TMP/ev4a.ndjson"   # fresh baseline
poll decoy    "$TMP/ev4b.ndjson"
[ "$(events "$TMP/ev4b.ndjson")" -eq 0 ] || fail "decoy tripped an alert"
pass "decoy: no trip"

# --- 5. latency bound on the in-process fixture pipeline -------------------
export FABLE_MONITOR_STATE="$TMP/state3.jsonl.zst"
export FABLE_MONITOR_LOG="$TMP/log3.jsonl.zst"
poll baseline /dev/null
poll restored /dev/null
wall=$(grep -oE 'wall [0-9]+ms' "$TMP/out.log" | grep -oE '[0-9]+' | tail -1)
[ -n "$wall" ] || fail "no wall-clock metric in poll output"
[ "$wall" -lt 5000 ] || fail "fixture poll wall-clock ${wall}ms exceeded 5000ms bound"
pass "latency: fixture poll wall-clock ${wall}ms (< 5000ms)"

echo "ALL E2E CHECKS PASSED"
