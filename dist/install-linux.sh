#!/usr/bin/env bash
# Install fable-monitor as a systemd user timer or cron job on Linux.
set -euo pipefail
umask 077

LABEL="fable-monitor"
FAST_INTERVAL="${FABLE_FAST_INTERVAL:-45}"
DRYRUN="${1:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_BIN="$ROOT/zig-out/bin/fable-monitor"
ARTIFACT="${FABLE_MONITOR_ARTIFACT:-}"
ARTIFACT_SHA256="${FABLE_MONITOR_ARTIFACT_SHA256:-}"
ARTIFACT_VERIFIER="${FABLE_MONITOR_ARTIFACT_VERIFIER:-}"
FABLE_HOME="${FABLE_HOME:-$HOME/.local/share/fable-monitor}"
BIN="$FABLE_HOME/fable-monitor"
ENVFILE="$FABLE_HOME/fable-monitor.env"
SYSTEMD_ENVFILE="$FABLE_HOME/fable-monitor.systemd.env"
STATE="$FABLE_HOME/state.jsonl.zst"
LOG="$FABLE_HOME/events.jsonl.zst"

fail() { echo "error: $*" >&2; exit 1; }
[ -z "$DRYRUN" ] || [ "$DRYRUN" = "--dry-run" ] || { echo "usage: $0 [--dry-run]" >&2; exit 2; }
[[ "$FAST_INTERVAL" =~ ^[0-9]+$ ]] && [ "$FAST_INTERVAL" -gt 0 ] \
    || fail "FABLE_FAST_INTERVAL must be a positive integer"

reject_controls() {
    local name="$1" value="$2"
    LC_ALL=C
    [[ "$value" != *[[:cntrl:]]* ]] || fail "$name must not contain control characters"
}
for name in HOME SCHEDULER FABLE_HOME FABLE_FAST_INTERVAL \
    FABLE_MONITOR_WEBHOOK FABLE_MONITOR_HEARTBEAT_URL FABLE_MONITOR_EVENT_SINK \
    FABLE_MONITOR_NOTIFY FABLE_MONITOR_SOURCES FABLE_MONITOR_ONLY FABLE_MONITOR_DISABLE \
    FABLE_MONITOR_FIXTURES FABLE_MONITOR_ARTIFACT \
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

runtime_path() {
    local result="" dir candidate
    for candidate in "$CURL_BIN" "$ZSTD_BIN" /usr/bin/x /bin/x; do
        [ -n "$candidate" ] || continue
        dir="$(dirname "$candidate")"
        case ":$result:" in *":$dir:"*) ;; *) result="${result:+$result:}$dir" ;; esac
    done
    printf '%s' "$result"
}

is_zo() { [ -n "${ZO_INSTANCE:-}${ZO_COMPUTER:-}" ] || [ -e /etc/zo-release ] || command -v zo >/dev/null 2>&1; }
detect_scheduler() {
    if [ -n "${SCHEDULER:-}" ]; then printf '%s' "$SCHEDULER"; return; fi
    if is_zo; then printf 'zo'; return; fi
    if command -v systemctl >/dev/null 2>&1 && systemctl --user >/dev/null 2>&1; then printf 'systemd'; return; fi
    printf 'cron'
}
SCHED="$(detect_scheduler)"
case "$SCHED" in systemd|cron) SCHED_IMPL="$SCHED" ;; zo) SCHED_IMPL="cron" ;; *) fail "SCHEDULER must be systemd, cron, or zo" ;; esac

shell_quote() {
    local value="$1"
    printf "'%s'" "${value//\'/\'\\\'\'}"
}
systemd_quote() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '"%s"' "$value"
}
env_value() {
    local name="$1" redact="$2" value=""
    [[ -v "$name" ]] && value="${!name}"
    if [ "$redact" = true ] && [ -n "$value" ]; then printf '<redacted>'; else printf '%s' "$value"; fi
}
emit_values() {
    local redact="$1"
    local format="$2"
    "$format" FABLE_MONITOR_STATE "$STATE"
    "$format" FABLE_MONITOR_LOG "$LOG"
    "$format" FABLE_MONITOR_FAST_INTERVAL "$FAST_INTERVAL"
    emit_optional "$format" FABLE_MONITOR_WEBHOOK "$(env_value FABLE_MONITOR_WEBHOOK "$redact")"
    emit_optional "$format" FABLE_MONITOR_HEARTBEAT_URL "$(env_value FABLE_MONITOR_HEARTBEAT_URL "$redact")"
    emit_optional "$format" FABLE_MONITOR_EVENT_SINK "${FABLE_MONITOR_EVENT_SINK:-}"
    emit_optional "$format" FABLE_MONITOR_NOTIFY "$(env_value FABLE_MONITOR_NOTIFY "$redact")"
    emit_optional "$format" FABLE_MONITOR_SOURCES "${FABLE_MONITOR_SOURCES:-}"
    emit_optional "$format" FABLE_MONITOR_ONLY "${FABLE_MONITOR_ONLY:-}"
    emit_optional "$format" FABLE_MONITOR_DISABLE "${FABLE_MONITOR_DISABLE:-}"
    emit_optional "$format" FABLE_MONITOR_FIXTURES "${FABLE_MONITOR_FIXTURES:-}"
    "$format" PATH "$RUNTIME_PATH"
}
emit_optional() {
    local format="$1" name="$2" value="$3"
    [ -z "$value" ] || "$format" "$name" "$value"
}
shell_env_line() {
    printf '%s=%s\n' "$1" "$(shell_quote "$2")"
}
systemd_env_line() {
    printf '%s=%s\n' "$1" "$(systemd_quote "$2")"
}
render_shell_env() {
    emit_values "${1:-false}" shell_env_line
}
render_systemd_env() {
    emit_values "${1:-false}" systemd_env_line
}
service_unit() {
    printf '%s\n' '[Unit]' 'Description=fable-monitor poll' 'After=network-online.target' '' '[Service]' 'Type=oneshot'
    printf 'EnvironmentFile=%s\nExecStart=%s poll\n' "$(systemd_quote "$SYSTEMD_ENVFILE")" "$(systemd_quote "$BIN")"
    printf '%s\n' 'UMask=0077' 'NoNewPrivileges=true' 'PrivateTmp=true' 'PrivateDevices=true' \
        'ProtectSystem=strict' 'ProtectHome=read-only' "ReadWritePaths=$(systemd_quote "$FABLE_HOME")" \
        'ProtectControlGroups=true' 'ProtectKernelModules=true' 'ProtectKernelTunables=true' \
        'RestrictSUIDSGID=true' 'LockPersonality=true' 'MemoryDenyWriteExecute=true'
}
timer_unit() {
    printf '%s\n' '[Unit]' 'Description=fable-monitor fast loop' '' '[Timer]' 'OnBootSec=30' \
        "OnUnitActiveSec=${FAST_INTERVAL}" 'AccuracySec=1s' "Unit=$LABEL.service" '' '[Install]' 'WantedBy=timers.target'
}
cron_line() {
    printf '* * * * * set -a; . %s; %s poll >> %s 2>&1\n' \
        "$(shell_quote "$ENVFILE")" "$(shell_quote "$BIN")" "$(shell_quote "$FABLE_HOME/cron.out")"
}

echo "scheduler: $SCHED (impl: $SCHED_IMPL); interval: ${FAST_INTERVAL}s"
echo "durable home: $FABLE_HOME"
CURL_BIN="$(type -P curl || true)"
ZSTD_BIN="$(type -P zstd || true)"
RUNTIME_PATH="$(runtime_path)"
reject_controls "curl executable path" "$CURL_BIN"
reject_controls "zstd executable path" "$ZSTD_BIN"
reject_controls "runtime PATH" "$RUNTIME_PATH"
if [ "$DRYRUN" = "--dry-run" ]; then
    echo "--- (dry run) environment (secrets redacted) ---"
    if [ "$SCHED_IMPL" = systemd ]; then render_systemd_env true; service_unit; timer_unit; else render_shell_env true; cron_line; fi
    exit 0
fi

[ -x "$CURL_BIN" ] || fail "curl not found on PATH"
[ -x "$ZSTD_BIN" ] || fail "zstd not found on PATH"
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
case "$SCHED_IMPL" in
    systemd) command -v systemctl >/dev/null || fail "systemctl not found" ;;
    cron) command -v crontab >/dev/null || fail "crontab not found" ;;
esac

mkdir -p "$FABLE_HOME"
chmod 700 "$FABLE_HOME"
ARTIFACT_TMP=""
if [ -n "$ARTIFACT" ]; then
    [ -f "$ARTIFACT" ] || fail "release artifact not found: $ARTIFACT"
    [[ "$ARTIFACT_SHA256" =~ ^[[:xdigit:]]{64}$ ]] || fail "FABLE_MONITOR_ARTIFACT_SHA256 must be a SHA-256 digest"
    if command -v sha256sum >/dev/null 2>&1; then
        ACTUAL_SHA256="$(sha256sum "$ARTIFACT")"; ACTUAL_SHA256="${ACTUAL_SHA256%% *}"
    elif command -v shasum >/dev/null 2>&1; then
        ACTUAL_SHA256="$(shasum -a 256 "$ARTIFACT")"; ACTUAL_SHA256="${ACTUAL_SHA256%% *}"
    else
        fail "sha256sum or shasum is required to verify release artifacts"
    fi
    ACTUAL_SHA256="$(printf '%s' "$ACTUAL_SHA256" | tr '[:upper:]' '[:lower:]')"
    ARTIFACT_SHA256="$(printf '%s' "$ARTIFACT_SHA256" | tr '[:upper:]' '[:lower:]')"
    [ "$ACTUAL_SHA256" = "$ARTIFACT_SHA256" ] || fail "release artifact SHA-256 mismatch"
    if [ -n "$ARTIFACT_VERIFIER" ]; then
        [ -x "$ARTIFACT_VERIFIER" ] || fail "artifact verifier is not executable"
        "$ARTIFACT_VERIFIER" "$ARTIFACT" "$ARTIFACT_SHA256" || fail "artifact verifier rejected the release"
    fi
    ARTIFACT_TMP="$(mktemp -d "$FABLE_HOME/.artifact.XXXXXX")"
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
STAGED_BIN="$FABLE_HOME/.fable-monitor.new.$$"
STAGED_ENV="$FABLE_HOME/.fable-monitor.env.new.$$"
STAGED_SYSTEMD_ENV="$FABLE_HOME/.fable-monitor.systemd.env.new.$$"
install -m 0755 "$SRC_BIN" "$STAGED_BIN"
render_shell_env > "$STAGED_ENV"
render_systemd_env > "$STAGED_SYSTEMD_ENV"
chmod 600 "$STAGED_ENV" "$STAGED_SYSTEMD_ENV"

echo "Running preflight..."
set -a; . "$STAGED_ENV"; set +a
if ! env -u ANTHROPIC_API_KEY "$STAGED_BIN" preflight; then
    rm -f "$STAGED_BIN" "$STAGED_ENV" "$STAGED_SYSTEMD_ENV"
    fail "preflight failed; installation aborted"
fi

BACKUP="$FABLE_HOME/.install-backup.$$"
mkdir "$BACKUP"
for file in "$BIN" "$ENVFILE" "$SYSTEMD_ENVFILE"; do [ ! -e "$file" ] || cp -p "$file" "$BACKUP/$(basename "$file")"; done
if [ "$SCHED_IMPL" = systemd ]; then
    UDIR="$HOME/.config/systemd/user"
    [ ! -e "$UDIR/$LABEL.service" ] || cp -p "$UDIR/$LABEL.service" "$BACKUP/$LABEL.service"
    [ ! -e "$UDIR/$LABEL.timer" ] || cp -p "$UDIR/$LABEL.timer" "$BACKUP/$LABEL.timer"
    systemctl --user is-enabled --quiet "$LABEL.timer" 2>/dev/null && touch "$BACKUP/timer-enabled" || true
    systemctl --user is-active --quiet "$LABEL.timer" 2>/dev/null && touch "$BACKUP/timer-active" || true
else
    if crontab -l > "$BACKUP/crontab" 2>/dev/null; then touch "$BACKUP/had-crontab"; fi
fi
rollback() {
    local status=$?
    trap - ERR
    set +e
    rm -f "$BIN" "$ENVFILE" "$SYSTEMD_ENVFILE"
    for name in fable-monitor fable-monitor.env fable-monitor.systemd.env; do
        [ ! -e "$BACKUP/$name" ] || mv "$BACKUP/$name" "$FABLE_HOME/$name"
    done
    if [ "$SCHED_IMPL" = systemd ]; then
        systemctl --user disable --now "$LABEL.timer" >/dev/null 2>&1
        rm -f "$UDIR/$LABEL.service" "$UDIR/$LABEL.timer"
        [ ! -e "$BACKUP/$LABEL.service" ] || mv "$BACKUP/$LABEL.service" "$UDIR/$LABEL.service"
        [ ! -e "$BACKUP/$LABEL.timer" ] || mv "$BACKUP/$LABEL.timer" "$UDIR/$LABEL.timer"
        systemctl --user daemon-reload >/dev/null 2>&1 || true
        [ ! -e "$BACKUP/timer-enabled" ] || systemctl --user enable "$LABEL.timer" >/dev/null 2>&1
        [ ! -e "$BACKUP/timer-active" ] || systemctl --user start "$LABEL.timer" >/dev/null 2>&1
    else
        if [ -e "$BACKUP/had-crontab" ]; then crontab "$BACKUP/crontab" >/dev/null 2>&1; else crontab -r >/dev/null 2>&1; fi
    fi
    rm -rf "$BACKUP" "$STAGED_BIN" "$STAGED_ENV" "$STAGED_SYSTEMD_ENV" "$ARTIFACT_TMP"
    exit "$status"
}
trap rollback ERR
mv "$STAGED_BIN" "$BIN"
mv "$STAGED_ENV" "$ENVFILE"
mv "$STAGED_SYSTEMD_ENV" "$SYSTEMD_ENVFILE"

case "$SCHED_IMPL" in
    systemd)
        mkdir -p "$UDIR"; chmod 700 "$UDIR"
        service_unit > "$UDIR/$LABEL.service"
        timer_unit > "$UDIR/$LABEL.timer"
        chmod 600 "$UDIR/$LABEL.service" "$UDIR/$LABEL.timer"
        systemctl --user daemon-reload
        systemctl --user enable --now "$LABEL.timer"
        echo "Installed systemd user timer '$LABEL.timer' (every ${FAST_INTERVAL}s)."
        ;;
    cron)
        LINE="$(cron_line)"
        ( crontab -l 2>/dev/null | grep -F -v -- "$BIN poll" || true; printf '%s\n' "$LINE" ) | crontab -
        echo "Installed crontab entry (every minute)."
        ;;
esac
trap - ERR
rm -rf "$BACKUP" "$ARTIFACT_TMP"
echo "Durable state: $STATE"
echo "Done. Remove with: bash dist/uninstall-linux.sh"
