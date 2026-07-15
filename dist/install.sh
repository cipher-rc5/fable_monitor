#!/usr/bin/env bash
#
# Install fable-monitor as a macOS launchd agent: build a release binary, stage
# it (and its state/log/output) under ~/Library/Application Support, generate a
# LaunchAgent, and load it. Re-running re-installs cleanly. Remove with
# dist/uninstall.sh.
#
#   bash dist/install.sh            # install + load (polls every 60 s)
#   bash dist/install.sh --dry-run  # just print the plist it would write
#   FABLE_INTERVAL=1800 bash dist/install.sh  # poll every 30 minutes instead
#
# Why stage under Application Support? On modern macOS, ~/Desktop, ~/Documents,
# and ~/Downloads are TCC-protected. A background launchd agent can't answer the
# consent prompt, so executing a binary from there hangs in the loader. App
# Support is not protected, so the agent runs unattended.
#
set -euo pipefail
umask 077

LABEL="io.zerocreativity.fable-monitor"
# Default cadence: 60 s, approximating the config's tier-1 fast loop
# (fast_interval_s=45) the same way the Linux cron path does. Conditional GETs
# (ETag/304) keep an unchanged source nearly free, and the in-binary due-cadence
# still holds tier-2/3 sources to slow_interval_s regardless of how often the
# binary runs. Raise it only if 30-minute tier-1 latency is acceptable.
INTERVAL="${FABLE_INTERVAL:-60}" # seconds between polls (default 60 s)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_BIN="$ROOT/zig-out/bin/fable-monitor"
ARTIFACT="${FABLE_MONITOR_ARTIFACT:-}"
ARTIFACT_SHA256="${FABLE_MONITOR_ARTIFACT_SHA256:-}"
ARTIFACT_VERIFIER="${FABLE_MONITOR_ARTIFACT_VERIFIER:-}"
APP_DIR="$HOME/Library/Application Support/fable-monitor"
BIN="$APP_DIR/fable-monitor"
AGENTS="$HOME/Library/LaunchAgents"
PLIST="$AGENTS/$LABEL.plist"
DRYRUN="${1:-}"

[ -z "$DRYRUN" ] || [ "$DRYRUN" = "--dry-run" ] || { echo "usage: $0 [--dry-run]" >&2; exit 2; }
[[ "$INTERVAL" =~ ^[0-9]+$ ]] && [ "$INTERVAL" -gt 0 ] || { echo "error: FABLE_INTERVAL must be a positive integer" >&2; exit 1; }

fail() { echo "error: $*" >&2; exit 1; }
reject_controls() {
    local name="$1" value="$2"
    LC_ALL=C
    [[ "$value" != *[[:cntrl:]]* ]] || fail "$name must not contain control characters"
}
for name in HOME FABLE_INTERVAL FABLE_MONITOR_SOURCES FABLE_MONITOR_ONLY FABLE_MONITOR_DISABLE \
    FABLE_MONITOR_FIXTURES FABLE_MONITOR_WEBHOOK FABLE_MONITOR_HEARTBEAT_URL \
    FABLE_MONITOR_EVENT_SINK FABLE_MONITOR_NOTIFY FABLE_MONITOR_ARTIFACT \
    FABLE_MONITOR_ARTIFACT_SHA256 FABLE_MONITOR_ARTIFACT_VERIFIER; do
    reject_controls "$name" "${!name:-}"
done

version_at_least() {
    local actual="$1" minimum="$2" i a b
    local -a actual_parts minimum_parts
    local IFS=.
    read -r -a actual_parts <<< "${actual%%[-+]*}"
    read -r -a minimum_parts <<< "$minimum"
    for i in 0 1 2; do
        a="${actual_parts[$i]:-0}"; b="${minimum_parts[$i]:-0}"
        [[ "$a" =~ ^[0-9]+$ ]] || return 1
        ((10#$a > 10#$b)) && return 0
        ((10#$a < 10#$b)) && return 1
    done
    return 0
}

# 1. Preconditions: the toolchain and the two runtime binaries must be present.
CURL_BIN="$(type -P curl || true)"
ZSTD_BIN="$(type -P zstd || true)"
reject_controls "curl executable path" "$CURL_BIN"
reject_controls "zstd executable path" "$ZSTD_BIN"
[ -x "$CURL_BIN" ] || fail "curl not found on PATH (needed to fetch)"
[ -x "$ZSTD_BIN" ] || fail "zstd not found on PATH (needed to compress state/log)"
CURL_INFO="$($CURL_BIN --version)" || fail "curl is not runnable"
[[ "$CURL_INFO" =~ ^curl[[:space:]]+([0-9]+\.[0-9]+\.[0-9]+) ]] || fail "could not determine curl version"
version_at_least "${BASH_REMATCH[1]}" 7.71.0 || fail "curl 7.71.0 or newer is required"
[[ "$CURL_INFO" == *"Protocols:"*"https"* ]] || fail "curl lacks HTTPS support"
CURL_HELP="$($CURL_BIN --help all)" || fail "curl cannot report supported options"
[[ "$CURL_HELP" == *--proto-redir* ]] || fail "curl lacks --proto-redir support"
ZSTD_INFO="$($ZSTD_BIN --version)" || fail "zstd is not runnable"
[[ "$ZSTD_INFO" =~ ([0-9]+\.[0-9]+\.[0-9]+) ]] || fail "could not determine zstd version"
version_at_least "${BASH_REMATCH[1]}" 1.4.0 || fail "zstd 1.4.0 or newer is required"
[ "$(printf test | "$ZSTD_BIN" -q -c | "$ZSTD_BIN" -q -d -c)" = test ] || fail "zstd stream round-trip failed"
if [ -z "$ARTIFACT" ]; then
    ZIG_BIN="$(type -P zig || true)"
    [ -x "$ZIG_BIN" ] || fail "zig not found on PATH"
    ZIG_VERSION="$($ZIG_BIN version)" || fail "zig is not runnable"
    version_at_least "$ZIG_VERSION" 0.16.0 || fail "Zig 0.16.0 or newer is required"
fi

# 2. Build a release binary (from the repo; your shell has Desktop access).
ARTIFACT_TMP=""
if [ -n "$ARTIFACT" ]; then
    [ -f "$ARTIFACT" ] || fail "release artifact not found: $ARTIFACT"
    [[ "$ARTIFACT_SHA256" =~ ^[[:xdigit:]]{64}$ ]] || fail "FABLE_MONITOR_ARTIFACT_SHA256 must be a SHA-256 digest"
    if command -v shasum >/dev/null 2>&1; then
        ACTUAL_SHA256="$(shasum -a 256 "$ARTIFACT")"; ACTUAL_SHA256="${ACTUAL_SHA256%% *}"
    elif command -v sha256sum >/dev/null 2>&1; then
        ACTUAL_SHA256="$(sha256sum "$ARTIFACT")"; ACTUAL_SHA256="${ACTUAL_SHA256%% *}"
    else
        fail "shasum or sha256sum is required to verify release artifacts"
    fi
    ACTUAL_SHA256="$(printf '%s' "$ACTUAL_SHA256" | tr '[:upper:]' '[:lower:]')"
    ARTIFACT_SHA256="$(printf '%s' "$ARTIFACT_SHA256" | tr '[:upper:]' '[:lower:]')"
    [ "$ACTUAL_SHA256" = "$ARTIFACT_SHA256" ] || fail "release artifact SHA-256 mismatch"
    if [ -n "$ARTIFACT_VERIFIER" ]; then
        [ -x "$ARTIFACT_VERIFIER" ] || fail "artifact verifier is not executable"
        "$ARTIFACT_VERIFIER" "$ARTIFACT" "$ARTIFACT_SHA256" || fail "artifact verifier rejected the release"
    fi
    ARTIFACT_TMP="$(mktemp -d -t fable-artifact)"
    tar -tzf "$ARTIFACT" > "$ARTIFACT_TMP/members"
    ! grep -Eq '(^/|(^|/)\.\.(/|$)|[[:cntrl:]])' "$ARTIFACT_TMP/members" || fail "release artifact contains an unsafe path"
    ARTIFACT_ROOT="$(while IFS= read -r member; do printf '%s\n' "${member%%/*}"; done < "$ARTIFACT_TMP/members" | sort -u)"
    [[ "$ARTIFACT_ROOT" != *$'\n'* && -n "$ARTIFACT_ROOT" ]] || fail "release artifact must have one root directory"
    grep -qxF "$ARTIFACT_ROOT/fable-monitor" "$ARTIFACT_TMP/members" || fail "release artifact has no fable-monitor binary"
    tar -xzf "$ARTIFACT" -C "$ARTIFACT_TMP"
    SRC_BIN="$ARTIFACT_TMP/$ARTIFACT_ROOT/fable-monitor"
    [ -x "$SRC_BIN" ] || fail "release artifact binary is not executable"
else
    echo "Building fable-monitor (ReleaseSafe, baseline CPU)..."
    (cd "$ROOT" && "$ZIG_BIN" build -Doptimize=ReleaseSafe -Dcpu=baseline)
    [ -x "$SRC_BIN" ] || fail "build did not produce $SRC_BIN"
fi

# 3. The PATH the agent runs with — launchd's is minimal, so include where curl
#    and zstd actually live on this machine.
TOOLPATH="$(dirname "$CURL_BIN"):$(dirname "$ZSTD_BIN"):/usr/bin:/bin:/usr/sbin:/sbin"
reject_controls "runtime PATH" "$TOOLPATH"

xml_escape() {
    local value="$1"
    value="${value//&/\&amp;}"
    value="${value//</\&lt;}"
    value="${value//>/\&gt;}"
    value="${value//\"/\&quot;}"
    value="${value//\'/\&apos;}"
    printf '%s' "$value"
}

# `FABLE_MONITOR_NOTIFY=auto` explicitly opts into the local macOS notifier.
# Keep alert text as argv data; never interpolate it into AppleScript source.
if command -v terminal-notifier >/dev/null 2>&1; then
    NOTIFY='terminal-notifier -title "fable-monitor" -message "$1"'
else
    NOTIFY='osascript -e '\''on run argv'\'' -e '\''display notification (item 1 of argv) with title "fable-monitor"'\'' -e '\''end run'\'' -- "$1"'
fi
if [ "${FABLE_MONITOR_NOTIFY:-}" = auto ]; then FABLE_MONITOR_NOTIFY="$NOTIFY"; fi

# 4. Generate the plist (to a temp file for --dry-run, else to LaunchAgents).
DEST="$(mktemp -t fable-monitor).plist"
X_BIN="$(xml_escape "$BIN")"
X_APP_DIR="$(xml_escape "$APP_DIR")"
X_TOOLPATH="$(xml_escape "$TOOLPATH")"
OPTIONAL_XML=""
append_optional_xml() {
    local name="$1" value="${!1:-}"
    [ -n "$value" ] || return 0
    if [ "$DRYRUN" = "--dry-run" ]; then
        case "$name" in
            FABLE_MONITOR_WEBHOOK|FABLE_MONITOR_HEARTBEAT_URL|FABLE_MONITOR_NOTIFY) value="<redacted>" ;;
        esac
    fi
    OPTIONAL_XML+="        <key>$(xml_escape "$name")</key><string>$(xml_escape "$value")</string>"$'\n'
}
for name in FABLE_MONITOR_SOURCES FABLE_MONITOR_ONLY FABLE_MONITOR_DISABLE \
    FABLE_MONITOR_FIXTURES FABLE_MONITOR_WEBHOOK FABLE_MONITOR_HEARTBEAT_URL \
    FABLE_MONITOR_EVENT_SINK FABLE_MONITOR_NOTIFY; do
    append_optional_xml "$name"
done
cat >"$DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key><array><string>$X_BIN</string><string>poll</string></array>
    <key>WorkingDirectory</key><string>$X_APP_DIR</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>FABLE_MONITOR_STATE</key><string>$X_APP_DIR/state.jsonl.zst</string>
        <key>FABLE_MONITOR_LOG</key><string>$X_APP_DIR/events.jsonl.zst</string>
${OPTIONAL_XML}        <key>PATH</key><string>$X_TOOLPATH</string>
    </dict>
    <key>StartInterval</key><integer>$INTERVAL</integer>
    <key>RunAtLoad</key><true/>
    <key>StandardOutPath</key><string>$X_APP_DIR/out.log</string>
    <key>StandardErrorPath</key><string>$X_APP_DIR/err.log</string>
</dict>
</plist>
EOF

plutil -lint "$DEST" >/dev/null && echo "plist valid."

if [ "$DRYRUN" = "--dry-run" ]; then
    echo "--- (dry run) would write to $PLIST ---"
    cat "$DEST"
    rm -rf "$DEST" "$ARTIFACT_TMP"
    exit 0
fi

# 5. Stage the binary outside TCC-protected locations.
mkdir -p "$APP_DIR" "$AGENTS"
chmod 700 "$APP_DIR"
STAGED="$APP_DIR/.fable-monitor.new.$$"
install -m 0755 "$SRC_BIN" "$STAGED"
echo "Running preflight..."
if ! env -u ANTHROPIC_API_KEY PATH="$TOOLPATH" FABLE_MONITOR_STATE="$APP_DIR/state.jsonl.zst" FABLE_MONITOR_LOG="$APP_DIR/events.jsonl.zst" "$STAGED" preflight; then
    rm -rf "$STAGED" "$DEST" "$ARTIFACT_TMP"
    echo "error: preflight failed; installation aborted" >&2
    exit 1
fi

OLD_BIN="$APP_DIR/.fable-monitor.old.$$"
OLD_PLIST="$AGENTS/.$LABEL.plist.old.$$"
[ ! -e "$BIN" ] || cp -p "$BIN" "$OLD_BIN"
[ ! -e "$PLIST" ] || cp -p "$PLIST" "$OLD_PLIST"
OLD_LOADED=false
launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 && OLD_LOADED=true
rollback() {
    local status=$?
    trap - ERR
    set +e
    launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1
    rm -f "$BIN" "$PLIST"
    [ ! -e "$OLD_BIN" ] || mv "$OLD_BIN" "$BIN"
    [ ! -e "$OLD_PLIST" ] || mv "$OLD_PLIST" "$PLIST"
    rm -rf "$STAGED" "$DEST" "$ARTIFACT_TMP"
    if [ "$OLD_LOADED" = true ] && [ -e "$PLIST" ]; then
        launchctl bootstrap "gui/$(id -u)" "$PLIST" >/dev/null 2>&1 || launchctl load -w "$PLIST" >/dev/null 2>&1
    fi
    exit "$status"
}
trap rollback ERR
mv "$STAGED" "$BIN"
mv "$DEST" "$PLIST"
chmod 600 "$PLIST"

# 6. (Re)load. bootout first so re-installs are clean; fall back to legacy
#    load -w on older macOS where bootstrap is unavailable.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
if ! launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null; then
    launchctl load -w "$PLIST"
fi
trap - ERR
rm -rf "$OLD_BIN" "$OLD_PLIST" "$ARTIFACT_TMP"

echo "Installed $LABEL — polling every ${INTERVAL}s (≈$((INTERVAL / 60)) min), starting now."
echo "  binary:   $BIN"
echo "  data:     $APP_DIR/{state,events}.jsonl.zst"
echo "  logs:     $APP_DIR/out.log (alerts), err.log (diagnostics)"
if [ -n "${FABLE_MONITOR_NOTIFY:-}" ]; then echo "  notifier: configured"; else echo "  notifier: disabled"; fi
echo "  status:   just status   ·   stop: just uninstall"
