#!/usr/bin/env bash
#
# Prove the installer's osascript notify fallback passes the alert text as
# DATA, not code. A hostile message — double quotes plus an AppleScript
# `do shell script "…"` payload — must arrive at osascript as a single,
# byte-identical argv item after `--`, never spliced into the AppleScript
# source handed to -e.
#
# Standalone: stubs osascript on PATH (recording its argv), extracts the real
# NOTIFY construction from dist/install.sh, and invokes it exactly the way the
# binary does at runtime: `sh -c <cmd> fable-monitor <message>`.
#
#   bash tests/notify_quoting.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL="$ROOT/dist/install.sh"

TMP="$(mktemp -d -t fable-notify-quoting)"
trap 'rm -rf "$TMP"' EXIT
ARGS_LOG="$TMP/osascript.args"
PWNED="$TMP/pwned"

fail() { echo "FAIL: $*" >&2; exit 1; }

# 1. Stub osascript: record argc and each argv item NUL-separated (payloads may
#    contain anything but NUL), and touch nothing else. If the payload were
#    evaluated as code, the `do shell script` below would create $PWNED — the
#    stub never does, so its presence would mean a real interpreter ran it.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/osascript" <<EOF
#!/usr/bin/env bash
printf '%s\0' "\$#" "\$@" > "$ARGS_LOG"
EOF
chmod +x "$TMP/bin/osascript"

# 2. Extract the NOTIFY construction from the installer and evaluate it with a
#    PATH lacking terminal-notifier (a third-party tool, never in /usr/bin or
#    /bin on a stock system), forcing the osascript fallback branch.
NOTIFY_BLOCK="$(sed -n '/^if command -v terminal-notifier/,/^fi$/p' "$INSTALL")"
[ -n "$NOTIFY_BLOCK" ] || fail "could not extract the NOTIFY if/else block from $INSTALL"
NOTIFY="$(PATH="$TMP/bin:/usr/bin:/bin" bash -c "$NOTIFY_BLOCK"'
printf "%s" "$NOTIFY"')"
case "$NOTIFY" in
    osascript*) ;;
    *) fail "expected the osascript fallback, got: $NOTIFY" ;;
esac

# 3. Fire the hook the way poll.zig does — sh -c <cmd> fable-monitor <message> —
#    with a hostile title: a double quote and an AppleScript command injection.
TITLE='RESTORATION: he said "hi" — '"'"'do shell script "touch '"$PWNED"'"'"'"
if PATH="$TMP/bin:/usr/bin:/bin" sh -c "$NOTIFY" fable-monitor "$TITLE"; then
    notify_status=0
else
    notify_status=$?
fi
[ "$notify_status" -eq 0 ] || fail "notify command exited $notify_status (expected 0)"

# 4. Assertions.
[ -s "$ARGS_LOG" ] || fail "stub osascript was never invoked"
[ ! -e "$PWNED" ] && [ ! -e /tmp/pwned ] || fail "payload was EXECUTED (pwned file exists)"

# Parse the NUL-separated record: argc, then each argv item.
ARGS=()
while IFS= read -r -d '' item; do ARGS+=("$item"); done < "$ARGS_LOG"
ARGC="${ARGS[0]}"
LAST="${ARGS[$((${#ARGS[@]} - 1))]}"

# The message must be the single argv item after `--`, byte-identical.
[ "$LAST" = "$TITLE" ] || fail "payload did not arrive as one intact argv item: <$LAST>"

# `--` must separate the -e script lines from the data.
SEP="${ARGS[$((${#ARGS[@]} - 2))]}"
[ "$SEP" = "--" ] || fail "expected '--' before the payload, got: <$SEP>"

# No OTHER argv item (i.e. no -e AppleScript source line) may contain any part
# of the payload — that would mean interpolation into code.
i=1
while [ "$i" -lt $((${#ARGS[@]} - 1)) ]; do
    case "${ARGS[$i]}" in
        *'do shell script'*|*'he said'*) fail "payload leaked into AppleScript source: <${ARGS[$i]}>" ;;
    esac
    i=$((i + 1))
done

# Sanity: the recorded argc matches what the stub saw.
[ "$ARGC" = "$((${#ARGS[@]} - 1))" ] || fail "argc mismatch: $ARGC vs $((${#ARGS[@]} - 1))"

echo "PASS: notify payload arrives as data (1 argv item, unevaluated); argc=$ARGC"
