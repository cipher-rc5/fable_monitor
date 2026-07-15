#!/usr/bin/env bash
#
# Remove the fable-monitor Linux job installed by dist/install-linux.sh (systemd
# timer or cron entry). Leaves the staged binary, durable state, and logs under
# FABLE_HOME in place.
set -uo pipefail
umask 077

LABEL="fable-monitor"
FABLE_HOME="${FABLE_HOME:-$HOME/.local/share/fable-monitor}"
BIN="$FABLE_HOME/fable-monitor"

LC_ALL=C
for value in "$HOME" "$FABLE_HOME"; do
    [[ "$value" != *[[:cntrl:]]* ]] || { echo "error: paths must not contain control characters" >&2; exit 1; }
done

# systemd user timer, if present.
if command -v systemctl >/dev/null 2>&1; then
    systemctl --user disable --now "$LABEL.timer" 2>/dev/null || true
    rm -f "$HOME/.config/systemd/user/$LABEL.service" "$HOME/.config/systemd/user/$LABEL.timer"
    systemctl --user daemon-reload 2>/dev/null || true
fi

# crontab entry, if present.
if command -v crontab >/dev/null 2>&1; then
    if current="$(crontab -l 2>/dev/null)"; then
        printf '%s\n' "$current" | grep -F -v -- "$BIN poll" | crontab - 2>/dev/null || true
    fi
fi

echo "Removed fable-monitor systemd timer and/or crontab entry."
echo "Durable data left under: $FABLE_HOME"
