#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/zig-out/bin/fable-monitor"
TMP="$(mktemp -d -t fable-live-canary)"
trap 'rm -rf "$TMP"' EXIT

[ -x "$BIN" ] || { echo "FAIL: canary binary is missing" >&2; exit 1; }
mkdir -p "$TMP/home"

# Keep fetched content and diagnostics in an ephemeral directory. The workflow
# emits only this fixed result, so source text, URLs, and inherited secrets never
# enter the Actions log.
if ! env -i PATH="$PATH" HOME="$TMP/home" TZ=UTC \
    FABLE_MONITOR_ONLY=anthropic_model_list \
    FABLE_MONITOR_STATE="$TMP/state.jsonl.zst" \
    FABLE_MONITOR_LOG="$TMP/events.jsonl.zst" \
    "$BIN" poll >"$TMP/stdout" 2>"$TMP/stderr"; then
    echo "FAIL: sanitized live-source canary failed" >&2
    exit 1
fi

echo "PASS: sanitized public live-source canary"
