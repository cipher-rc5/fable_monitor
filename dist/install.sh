#!/usr/bin/env bash
#
# Install fable-monitor as a macOS launchd agent: build a release binary, stage
# it (and its state/log/output) under ~/Library/Application Support, generate a
# LaunchAgent, and load it. Re-running re-installs cleanly. Remove with
# dist/uninstall.sh.
#
#   bash dist/install.sh            # install + load (polls every 30 min)
#   bash dist/install.sh --dry-run  # just print the plist it would write
#   FABLE_INTERVAL=600 bash dist/install.sh   # poll every 10 minutes instead
#
# Why stage under Application Support? On modern macOS, ~/Desktop, ~/Documents,
# and ~/Downloads are TCC-protected. A background launchd agent can't answer the
# consent prompt, so executing a binary from there hangs in the loader. App
# Support is not protected, so the agent runs unattended.
#
set -euo pipefail

LABEL="io.zerocreativity.fable-monitor"
INTERVAL="${FABLE_INTERVAL:-1800}" # seconds between polls (default 30 min)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_BIN="$ROOT/zig-out/bin/fable-monitor"
APP_DIR="$HOME/Library/Application Support/fable-monitor"
BIN="$APP_DIR/fable-monitor"
AGENTS="$HOME/Library/LaunchAgents"
PLIST="$AGENTS/$LABEL.plist"
DRYRUN="${1:-}"

# 1. Preconditions: the toolchain and the two runtime binaries must be present.
command -v zig >/dev/null || { echo "error: zig not found on PATH" >&2; exit 1; }
command -v curl >/dev/null || { echo "error: curl not found on PATH (needed to fetch)" >&2; exit 1; }
command -v zstd >/dev/null || { echo "error: zstd not found on PATH (needed to compress state/log)" >&2; exit 1; }

# 2. Build a release binary (from the repo; your shell has Desktop access).
echo "Building fable-monitor (ReleaseSafe)…"
(cd "$ROOT" && zig build -Doptimize=ReleaseSafe)
[ -x "$SRC_BIN" ] || { echo "error: build did not produce $SRC_BIN" >&2; exit 1; }

# 3. The PATH the agent runs with — launchd's is minimal, so include where curl
#    and zstd actually live on this machine.
TOOLPATH="/usr/bin:/bin:/usr/sbin:/sbin:$(dirname "$(command -v curl)"):$(dirname "$(command -v zstd)")"

# 4. Notification command. Prefer terminal-notifier (more reliable from a
#    background agent); fall back to built-in osascript. The alert text arrives
#    as "$1" — kept literal here and unescaped by the tool's `sh -c <cmd> … "$1"`.
if command -v terminal-notifier >/dev/null 2>&1; then
    NOTIFY='terminal-notifier -title "fable-monitor" -message "$1"'
else
    NOTIFY='osascript -e "display notification \"$1\" with title \"fable-monitor\""'
fi

# 5. Generate the plist (to a temp file for --dry-run, else to LaunchAgents).
DEST="$PLIST"
[ "$DRYRUN" = "--dry-run" ] && DEST="$(mktemp -t fable-monitor).plist"
cat >"$DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key><array><string>$BIN</string></array>
    <key>WorkingDirectory</key><string>$APP_DIR</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>FABLE_MONITOR_STATE</key><string>$APP_DIR/state.jsonl.zst</string>
        <key>FABLE_MONITOR_LOG</key><string>$APP_DIR/events.jsonl.zst</string>
        <key>FABLE_MONITOR_NOTIFY</key><string>$NOTIFY</string>
        <key>PATH</key><string>$TOOLPATH</string>
    </dict>
    <key>StartInterval</key><integer>$INTERVAL</integer>
    <key>RunAtLoad</key><true/>
    <key>StandardOutPath</key><string>$APP_DIR/out.log</string>
    <key>StandardErrorPath</key><string>$APP_DIR/err.log</string>
</dict>
</plist>
EOF

plutil -lint "$DEST" >/dev/null && echo "plist valid."

if [ "$DRYRUN" = "--dry-run" ]; then
    echo "--- (dry run) would write to $PLIST ---"
    cat "$DEST"
    rm -f "$DEST"
    exit 0
fi

# 6. Stage the binary outside TCC-protected locations.
mkdir -p "$APP_DIR" "$AGENTS"
install -m 0755 "$SRC_BIN" "$BIN"

# 7. (Re)load. bootout first so re-installs are clean; fall back to legacy
#    load -w on older macOS where bootstrap is unavailable.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
if ! launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null; then
    launchctl load -w "$PLIST"
fi

echo "Installed $LABEL — polling every ${INTERVAL}s (≈$((INTERVAL / 60)) min), starting now."
echo "  binary:   $BIN"
echo "  data:     $APP_DIR/{state,events}.jsonl.zst"
echo "  logs:     $APP_DIR/out.log (alerts), err.log (diagnostics)"
echo "  notifier: ${NOTIFY%% *}"
echo "  status:   just status   ·   stop: just uninstall"
