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
#                    probes (coalesced), statement restoration terms flipping
#                    absent->present, plus a tier-2 FR advisory; the notify
#                    hook fires
#   3. restored#2 -> idempotent: zero new structured events
#   4. decoy      -> no trip (layout churn + an unrelated "fable" FR document)
#   5. negation   -> no trip: suspension copy that *names* the controlled ids
#                    ("claude-fable-5 remains restricted") and uses the
#                    ambiguous restoration stems in negation contexts ("not
#                    available", "will return when authorized") must not read
#                    as restoration
#   6. restored#3 -> the real restoration still trips high after the negation
#                    decoy (the decoy neither poisoned the term baseline nor
#                    recorded false model presence)
#   7. latency    -> in-process fixture poll completes under a bound
#
# Usage: bash tests/e2e.sh   (run from the repo root; needs a built binary)
set -euo pipefail

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
    local status
    if FABLE_MONITOR_EVENT_SINK="$2" FABLE_MONITOR_FIXTURES="$FIX/$1" "$BIN" poll >"$TMP/out.log" 2>&1; then
        status=0
    else
        status=$?
    fi
    [ "$status" -eq 0 ] || fail "poll with fixture '$1' exited $status (expected 0); output: $TMP/out.log"
}
events() {
    if [ -f "$1" ]; then
        grep -c '^{' "$1" 2>/dev/null || true
    else
        echo 0
    fi
}

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
if [ ! -f "$NOTIFY_FILE" ] || ! grep -q 'RESTORATION' "$NOTIFY_FILE"; then
    fail "notify hook did not fire on restoration"
fi
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

# --- 5. negation decoy: suspension copy naming the ids/terms must not trip -
export FABLE_MONITOR_STATE="$TMP/state4.jsonl.zst"
export FABLE_MONITOR_LOG="$TMP/log4.jsonl.zst"
NOTIFY2_FILE="$TMP/notify2.txt"
export FABLE_MONITOR_NOTIFY="echo \">>> \$1\" >> $NOTIFY2_FILE"
poll baseline       "$TMP/ev5a.ndjson"   # fresh baseline
poll decoy_negation "$TMP/ev5b.ndjson"
# The reworded suspension copy may raise a context-shift advisory, but no
# restoration trip, no model presence, and nothing high-confidence.
! grep -q '"event_id":"statement_restored"' "$TMP/ev5b.ndjson" 2>/dev/null \
    || fail "negation decoy tripped statement_restored"
! grep -q 'model_present' "$TMP/ev5b.ndjson" 2>/dev/null \
    || fail "negation decoy recorded a model_present event"
! grep -q '"confidence":"high"' "$TMP/ev5b.ndjson" 2>/dev/null \
    || fail "negation decoy emitted a high-confidence event"
[ ! -f "$NOTIFY2_FILE" ] || ! grep -q 'RESTORATION' "$NOTIFY2_FILE" \
    || fail "negation decoy fired the notify hook"
pass "negation decoy: no trip (ids/terms only in suspension context)"

# --- 6. the real restoration still trips after the negation decoy ----------
poll restored "$TMP/ev6.ndjson"
grep -q '"event_id":"statement_restored".*"confidence":"high"' "$TMP/ev6.ndjson" \
    || fail "post-decoy restoration did not trip statement_restored high"
grep -q '"event_id":"model_present:claude-fable-5".*"confidence":"high"' "$TMP/ev6.ndjson" \
    || fail "post-decoy restoration did not trip model_present:claude-fable-5 high"
grep -q 'RESTORATION' "$NOTIFY2_FILE" || fail "notify hook did not fire on post-decoy restoration"
pass "post-decoy restoration: trips high, notify fired"

# --- 7. latency bound on the in-process fixture pipeline -------------------
export FABLE_MONITOR_STATE="$TMP/state3.jsonl.zst"
export FABLE_MONITOR_LOG="$TMP/log3.jsonl.zst"
poll baseline "$TMP/ev7a.ndjson"
poll restored "$TMP/ev7b.ndjson"
wall=$(grep -oE 'wall [0-9]+ms' "$TMP/out.log" | grep -oE '[0-9]+' | tail -1)
[ -n "$wall" ] || fail "no wall-clock metric in poll output"
[ "$wall" -lt 5000 ] || fail "fixture poll wall-clock ${wall}ms exceeded 5000ms bound"
pass "latency: fixture poll wall-clock ${wall}ms (< 5000ms)"

# --- 8. total outage: every source fails -> nonzero exit, no success heartbeat
# An empty fixtures directory makes every source miss its body and fail. With no
# fresh decisive coverage the run must classify failed, exit nonzero, and the
# dead-man's-switch heartbeat must stay suppressed even though a URL is set (the
# heartbeat host is deliberately unroutable so any contact attempt would show).
EMPTY_FIX="$TMP/empty-fixtures"
mkdir -p "$EMPTY_FIX"
export FABLE_MONITOR_STATE="$TMP/state8.jsonl.zst"
export FABLE_MONITOR_LOG="$TMP/log8.jsonl.zst"
outage_status=0
FABLE_MONITOR_FIXTURES="$EMPTY_FIX" \
FABLE_MONITOR_HEARTBEAT_URL="https://heartbeat.invalid/ping" \
    "$BIN" poll >"$TMP/outage.log" 2>&1 || outage_status=$?
[ "$outage_status" -ne 0 ] || fail "total outage poll exited 0 (expected nonzero); log: $TMP/outage.log"
grep -q 'poll outcome=failed' "$TMP/outage.log" \
    || fail "total outage did not classify outcome=failed; log: $TMP/outage.log"
grep -q 'heartbeat=suppressed' "$TMP/outage.log" \
    || fail "total outage did not suppress the success heartbeat; log: $TMP/outage.log"
! grep -q 'heartbeat=ok' "$TMP/outage.log" \
    || fail "total outage sent a success heartbeat on a failed run"
pass "total outage: nonzero exit ($outage_status), outcome=failed, heartbeat suppressed"

# --- 9. audit-persistence failure: sources succeed but the observation log
# cannot be committed. Pointing the log path into a directory that does not
# exist makes the durable append fail. The run must fail closed: nonzero exit,
# outcome=failed, audit_persisted=no, and no success heartbeat (URL is set to an
# unroutable host so any contact attempt would surface).
export FABLE_MONITOR_STATE="$TMP/state9.jsonl.zst"
export FABLE_MONITOR_LOG="$TMP/no-such-dir/log9.jsonl.zst"
persist_status=0
FABLE_MONITOR_FIXTURES="$FIX/restored" \
FABLE_MONITOR_HEARTBEAT_URL="https://heartbeat.invalid/ping" \
    "$BIN" poll >"$TMP/persist.log" 2>&1 || persist_status=$?
[ "$persist_status" -ne 0 ] || fail "log-write failure poll exited 0 (expected nonzero); log: $TMP/persist.log"
grep -q 'failed to append observation log' "$TMP/persist.log" \
    || fail "log-write failure was not reported; log: $TMP/persist.log"
grep -q 'audit_persisted=no' "$TMP/persist.log" \
    || fail "log-write failure did not mark audit_persisted=no; log: $TMP/persist.log"
grep -q 'heartbeat=suppressed' "$TMP/persist.log" \
    || fail "log-write failure did not suppress the success heartbeat; log: $TMP/persist.log"
! grep -q 'heartbeat=ok' "$TMP/persist.log" \
    || fail "log-write failure sent a success heartbeat"
pass "audit-persistence failure: nonzero exit ($persist_status), audit_persisted=no, heartbeat suppressed"

# --- 10. state-lock failure fails gracefully. Pointing the state path into a
# directory that does not exist makes the <state>.lock create fail. The run must
# report a clean lock diagnostic and exit nonzero into the same failed path
# (heartbeat suppressed) rather than crashing with a raw error return trace that
# a scheduler reading a zero exit as success would miss.
export FABLE_MONITOR_STATE="$TMP/no-such-dir/state10.jsonl.zst"
export FABLE_MONITOR_LOG="$TMP/log10.jsonl.zst"
lock_status=0
FABLE_MONITOR_FIXTURES="$FIX/restored" \
FABLE_MONITOR_HEARTBEAT_URL="https://heartbeat.invalid/ping" \
    "$BIN" poll >"$TMP/lock.log" 2>&1 || lock_status=$?
[ "$lock_status" -ne 0 ] || fail "state-lock failure poll exited 0 (expected nonzero); log: $TMP/lock.log"
grep -q 'could not acquire state lock' "$TMP/lock.log" \
    || fail "state-lock failure did not report a lock diagnostic; log: $TMP/lock.log"
grep -q 'poll failed: PollFailed' "$TMP/lock.log" \
    || fail "state-lock failure did not map to a clean poll failure; log: $TMP/lock.log"
! grep -qE '\.zig:[0-9]+:[0-9]+ ' "$TMP/lock.log" \
    || fail "state-lock failure crashed with a raw error return trace; log: $TMP/lock.log"
! grep -q 'heartbeat=ok' "$TMP/lock.log" \
    || fail "state-lock failure sent a success heartbeat"
pass "state-lock failure: graceful nonzero exit ($lock_status), clean diagnostic, no trace"

echo "ALL E2E CHECKS PASSED"
