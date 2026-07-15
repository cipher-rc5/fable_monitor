#!/usr/bin/env bash
#
# Unload and remove the fable-monitor launchd agent installed by dist/install.sh.
# Leaves the built binary, state, and logs in place.
#
set -euo pipefail
umask 077

LABEL="io.zerocreativity.fable-monitor"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

LC_ALL=C
[[ "$HOME" != *[[:cntrl:]]* ]] || { echo "error: HOME must not contain control characters" >&2; exit 1; }

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null ||
    launchctl unload "$PLIST" 2>/dev/null || true
rm -f "$PLIST"
echo "Unloaded and removed $LABEL."
