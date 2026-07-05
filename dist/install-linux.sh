#!/usr/bin/env bash
#
# Install fable-monitor as a recurring job on a Linux instance (the Zo.computer
# deployment target), parameterized by scheduler. Builds a release binary, stages
# it plus durable state under a persistent directory, sources secrets from the
# environment, runs the preflight, and registers the job.
#
#   bash dist/install-linux.sh                 # auto-detect scheduler
#   SCHEDULER=systemd bash dist/install-linux.sh
#   SCHEDULER=cron    bash dist/install-linux.sh
#   bash dist/install-linux.sh --dry-run       # print what it would do
#
# Scheduler selection (override with SCHEDULER=systemd|cron|zo):
#   - zo:      Zo.computer instance detected -> use its scheduler if present,
#              otherwise fall back to cron (always available on the instance).
#   - systemd: a user systemd timer firing every FABLE_FAST_INTERVAL seconds.
#   - cron:    a crontab entry (1-minute granularity; the in-binary due-cadence
#              still gates tier-2/3 work, so a 1-minute cron approximates the
#              fast loop closely enough for tier-1).
#
# Secrets and config come from the environment at install time and are written
# to an env file readable only by you. Nothing here is committed. Required for a
# useful deployment (the preflight warns if missing):
#   FABLE_MONITOR_WEBHOOK         structured-event sink (POST target)
#   FABLE_MONITOR_HEARTBEAT_URL   dead-man's-switch ping target
#   FABLE_MONITOR_NOTIFY          push hook (alert text arrives as $1; pass it
#                                 to your tool as data — its own argv item —
#                                 never spliced into code it evaluates)
set -euo pipefail

LABEL="fable-monitor"
FAST_INTERVAL="${FABLE_FAST_INTERVAL:-45}"
SLOW_INTERVAL="${FABLE_SLOW_INTERVAL:-1800}"
DRYRUN="${1:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_BIN="$ROOT/zig-out/bin/fable-monitor"

# Durable, restart-surviving location. Override with FABLE_HOME. On Zo this
# should point at the instance's persistent volume.
FABLE_HOME="${FABLE_HOME:-$HOME/.local/share/fable-monitor}"
BIN="$FABLE_HOME/fable-monitor"
ENVFILE="$FABLE_HOME/fable-monitor.env"
STATE="$FABLE_HOME/state.jsonl.zst"
LOG="$FABLE_HOME/events.jsonl.zst"

# --- 0. detect scheduler ----------------------------------------------------
is_zo() { [ -n "${ZO_INSTANCE:-}${ZO_COMPUTER:-}" ] || [ -e /etc/zo-release ] || command -v zo >/dev/null 2>&1; }
detect_scheduler() {
    if [ -n "${SCHEDULER:-}" ]; then echo "$SCHEDULER"; return; fi
    if is_zo; then echo "zo"; return; fi
    if command -v systemctl >/dev/null 2>&1 && systemctl --user >/dev/null 2>&1; then echo "systemd"; return; fi
    echo "cron"
}
SCHED="$(detect_scheduler)"
# zo: prefer a native scheduler if present, else cron.
if [ "$SCHED" = "zo" ]; then
    if command -v zo >/dev/null 2>&1; then SCHED_IMPL="zo-native"; else SCHED_IMPL="cron"; fi
else
    SCHED_IMPL="$SCHED"
fi

echo "scheduler: $SCHED (impl: $SCHED_IMPL); interval: fast ${FAST_INTERVAL}s, slow ${SLOW_INTERVAL}s"
echo "durable home: $FABLE_HOME"

# --- render helpers (used by both dry-run and install) ----------------------
render_env() {
    cat <<EOF
FABLE_MONITOR_STATE=$STATE
FABLE_MONITOR_LOG=$LOG
FABLE_MONITOR_FAST_INTERVAL=$FAST_INTERVAL
FABLE_MONITOR_WEBHOOK=${FABLE_MONITOR_WEBHOOK:-}
FABLE_MONITOR_HEARTBEAT_URL=${FABLE_MONITOR_HEARTBEAT_URL:-}
FABLE_MONITOR_EVENT_SINK=${FABLE_MONITOR_EVENT_SINK:-$FABLE_HOME/events-emitted.ndjson}
FABLE_MONITOR_NOTIFY=${FABLE_MONITOR_NOTIFY:-}
FABLE_MONITOR_SOURCES=${FABLE_MONITOR_SOURCES:-}
PATH=/usr/local/bin:/usr/bin:/bin
EOF
}

systemd_units() {
    cat <<EOF
# --- ~/.config/systemd/user/$LABEL.service ---
[Unit]
Description=fable-monitor poll
After=network-online.target

[Service]
Type=oneshot
EnvironmentFile=$ENVFILE
ExecStart=$BIN poll

# --- ~/.config/systemd/user/$LABEL.timer ---
[Unit]
Description=fable-monitor fast loop

[Timer]
OnBootSec=30
OnUnitActiveSec=${FAST_INTERVAL}
AccuracySec=1s
Unit=$LABEL.service

[Install]
WantedBy=timers.target
EOF
}

cron_line() {
    # cron's finest granularity is 1 minute; the binary's due-cadence handles
    # sub-minute intent for tier-1 when run under FABLE_MONITOR_LOOP, but for a
    # plain cron we run once per minute.
    echo "* * * * * set -a; . $ENVFILE; $BIN poll >> $FABLE_HOME/cron.out 2>&1"
}

if [ "$DRYRUN" = "--dry-run" ]; then
    echo "--- (dry run) env file ---"; render_env
    case "$SCHED_IMPL" in
        systemd) echo "--- (dry run) systemd units ---"; systemd_units ;;
        cron|zo-native) echo "--- (dry run) cron line ---"; cron_line ;;
    esac
    exit 0
fi

# --- 1. preconditions -------------------------------------------------------
command -v zig  >/dev/null || { echo "error: zig not found on PATH" >&2; exit 1; }
command -v curl >/dev/null || { echo "error: curl not found on PATH" >&2; exit 1; }
command -v zstd >/dev/null || { echo "error: zstd not found on PATH" >&2; exit 1; }

# --- 2. build ---------------------------------------------------------------
echo "Building fable-monitor (ReleaseSafe)..."
(cd "$ROOT" && zig build -Doptimize=ReleaseSafe)
[ -x "$SRC_BIN" ] || { echo "error: build did not produce $SRC_BIN" >&2; exit 1; }

# --- 4. stage binary + durable dirs + env ----------------------------------
mkdir -p "$FABLE_HOME"
install -m 0755 "$SRC_BIN" "$BIN"
umask 077; render_env > "$ENVFILE"; chmod 600 "$ENVFILE"
echo "wrote env file (0600): $ENVFILE"

# --- 5. preflight ------------------------------------------------------------
echo "Running preflight..."
set -a; . "$ENVFILE"; set +a
"$BIN" preflight || echo "warning: preflight reported problems (see above); continuing install"

# --- 6. register the job -----------------------------------------------------
case "$SCHED_IMPL" in
    systemd)
        UDIR="$HOME/.config/systemd/user"; mkdir -p "$UDIR"
        systemd_units | awk '
            /# --- .*\.service ---/{f="'"$UDIR"'/'"$LABEL"'.service"; next}
            /# --- .*\.timer ---/{f="'"$UDIR"'/'"$LABEL"'.timer"; next}
            {print > f}'
        systemctl --user daemon-reload
        systemctl --user enable --now "$LABEL.timer"
        echo "Installed systemd user timer '$LABEL.timer' (every ${FAST_INTERVAL}s)."
        echo "  status: systemctl --user status $LABEL.timer"
        echo "  logs:   journalctl --user -u $LABEL.service -f"
        ;;
    cron|zo-native)
        LINE="$(cron_line)"
        ( crontab -l 2>/dev/null | grep -v "$BIN poll" ; echo "$LINE" ) | crontab -
        echo "Installed crontab entry (every minute)."
        if [ "$SCHED_IMPL" = "zo-native" ]; then
            echo "note: 'zo' CLI detected. For sub-minute cadence, register a native"
            echo "      Zo scheduled task running: $BIN poll  (env from $ENVFILE)."
        fi
        echo "  view:   crontab -l"
        echo "  output: $FABLE_HOME/cron.out"
        ;;
esac

echo "Durable state: $STATE"
echo "Done. Remove with: bash dist/uninstall-linux.sh"
