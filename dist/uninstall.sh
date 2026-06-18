#!/usr/bin/env bash
#
# Unload and remove the fable-monitor launchd agent installed by dist/install.sh.
# Leaves the built binary, state, and logs in place.
#
set -euo pipefail

LABEL="io.zerocreativity.fable-monitor"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null ||
    launchctl unload "$PLIST" 2>/dev/null || true
rm -f "$PLIST"
echo "Unloaded and removed $LABEL."
