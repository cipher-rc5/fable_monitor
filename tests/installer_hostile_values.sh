#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d -t fable-installer-hostile)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

PWNED="$TMP/backtick-ran"
HOSTILE='雪`touch '"$PWNED"'`\路径\`literal`'
API_KEY='fixture-api-key-雪`backtick`\slash'

for scheduler in cron systemd; do
    output="$(HOME="$TMP/home-雪" SCHEDULER="$scheduler" \
        FABLE_MONITOR_WEBHOOK="$HOSTILE" FABLE_MONITOR_NOTIFY="$HOSTILE" \
        ANTHROPIC_API_KEY="$API_KEY" \
        bash "$ROOT/dist/install-linux.sh" --dry-run)"
    [ ! -e "$PWNED" ] || fail "$scheduler dry-run evaluated backticks"
    [[ "$output" != *"$HOSTILE"* ]] || fail "$scheduler exposed a hostile secret"
    [[ "$output" != *"$API_KEY"* ]] || fail "$scheduler exposed ANTHROPIC_API_KEY"
    [[ "$output" == *"<redacted>"* ]] || fail "$scheduler omitted the redaction marker"
done

echo "PASS: installer contains Unicode, backticks, backslashes, and API keys"
