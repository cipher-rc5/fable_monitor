#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASH_BIN="$(command -v bash)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

for script in "$ROOT"/dist/*.sh; do bash -n "$script" || fail "syntax: $script"; done

PWNED="$TMP/pwned"
HOSTILE="\$(touch '$PWNED'); quote'\"&<tag>"
OUT="$(HOME="$TMP/home space'&" SCHEDULER=cron FABLE_MONITOR_WEBHOOK="$HOSTILE" \
    FABLE_MONITOR_NOTIFY="$HOSTILE" bash "$ROOT/dist/install-linux.sh" --dry-run)"
[ ! -e "$PWNED" ] || fail "Linux dry-run evaluated a hostile value"
[[ "$OUT" != *"$HOSTILE"* ]] || fail "Linux dry-run exposed secrets"
[[ "$OUT" == *"<redacted>"* ]] || fail "Linux dry-run did not mark redacted values"

OUT="$(HOME="$TMP/home space'&" SCHEDULER=systemd FABLE_MONITOR_WEBHOOK="$HOSTILE" \
    bash "$ROOT/dist/install-linux.sh" --dry-run)"
[[ "$OUT" != *"$HOSTILE"* ]] || fail "systemd dry-run exposed secrets"
[[ "$OUT" == *'EnvironmentFile="'* ]] || fail "systemd paths are not quoted"
[[ "$OUT" == *'UMask=0077'* ]] || fail "systemd service has no explicit private umask"
for setting in NoNewPrivileges PrivateTmp ProtectSystem ProtectHome ReadWritePaths RestrictSUIDSGID MemoryDenyWriteExecute; do
    [[ "$OUT" == *"$setting="* ]] || fail "systemd service lacks $setting hardening"
done
CURL_DIR="$(dirname "$(type -P curl)")"
ZSTD_DIR="$(dirname "$(type -P zstd)")"
[[ "$OUT" == *"$CURL_DIR"* && "$OUT" == *"$ZSTD_DIR"* ]] || fail "runtime PATH omits discovered tools"

if FABLE_FAST_INTERVAL=0 SCHEDULER=cron bash "$ROOT/dist/install-linux.sh" --dry-run >/dev/null 2>&1; then
    fail "Linux installer accepted a zero interval"
fi
if FABLE_INTERVAL='1; touch /tmp/no' bash "$ROOT/dist/install.sh" --dry-run >/dev/null 2>&1; then
    fail "macOS installer accepted a hostile interval"
fi
for code in {1..31} 127; do
    printf -v octal '%03o' "$code"
    printf -v control '%b' "\\$octal"
    if FABLE_MONITOR_NOTIFY="$control" SCHEDULER=cron bash "$ROOT/dist/install-linux.sh" --dry-run >/dev/null 2>&1; then
        fail "Linux installer accepted control byte $code in an environment value"
    fi
done
if HOME=$'bad\tvalue' bash "$ROOT/dist/install.sh" --dry-run >/dev/null 2>&1; then
    fail "macOS installer accepted a control byte in HOME"
fi

# Exercise build, preflight, artifact verification, and scheduler transactions
# with all external commands isolated in a fixture PATH.
PROJ="$TMP/project"
TOOLS="$TMP/tools"
INSTALL="$TMP/install"
mkdir -p "$PROJ/dist" "$PROJ/zig-out/bin" "$TOOLS" "$INSTALL"
cp "$ROOT/dist/install-linux.sh" "$PROJ/dist/"
cat > "$PROJ/zig-out/bin/fable-monitor" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" != preflight ]
EOF
cat > "$TOOLS/zig" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = version ] && printf '0.16.0\n'
exit 0
EOF
cat > "$TOOLS/curl" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
    printf 'curl 7.71.0 fixture\nProtocols: http https\n'
elif [ "${1:-}" = --help ]; then
    printf '%s\n' '--proto-redir <protocols>'
fi
EOF
cat > "$TOOLS/zstd" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = --version ]; then
    printf '*** Zstandard CLI v1.4.0 ***\n'
else
    /bin/cat
fi
EOF
cat > "$TOOLS/crontab" <<EOF
#!/usr/bin/env bash
STATE='$TMP/crontab-state'
case "\${1:-}" in
    -l) [ -e "\$STATE" ] && /bin/cat "\$STATE" ;;
    -) /bin/cat > "\$STATE" ;;
    -r) rm -f "\$STATE"; touch '$TMP/crontab-removed' ;;
    *) cp "\$1" "\$STATE" ;;
esac
EOF
chmod +x "$PROJ/zig-out/bin/fable-monitor" "$TOOLS/"*

# Every minimum and capability check must fail before an installation starts.
cp "$TOOLS/curl" "$TMP/curl-good"
perl -pi -e 's/7\.71\.0/7.70.0/' "$TOOLS/curl"
if PATH="$TOOLS:/usr/bin:/bin" HOME="$TMP" FABLE_HOME="$INSTALL" SCHEDULER=cron \
    "$BASH_BIN" "$PROJ/dist/install-linux.sh" >/dev/null 2>&1; then
    fail "installer accepted an old curl"
fi
cp "$TMP/curl-good" "$TOOLS/curl"
perl -pi -e 's/--proto-redir/--no-required-option/' "$TOOLS/curl"
if PATH="$TOOLS:/usr/bin:/bin" HOME="$TMP" FABLE_HOME="$INSTALL" SCHEDULER=cron \
    "$BASH_BIN" "$PROJ/dist/install-linux.sh" >/dev/null 2>&1; then
    fail "installer accepted curl without required protocol controls"
fi
cp "$TMP/curl-good" "$TOOLS/curl"
cp "$TOOLS/zstd" "$TMP/zstd-good"
perl -pi -e 's/1\.4\.0/1.3.9/' "$TOOLS/zstd"
if PATH="$TOOLS:/usr/bin:/bin" HOME="$TMP" FABLE_HOME="$INSTALL" SCHEDULER=cron \
    "$BASH_BIN" "$PROJ/dist/install-linux.sh" >/dev/null 2>&1; then
    fail "installer accepted an old zstd"
fi
cp "$TMP/zstd-good" "$TOOLS/zstd"
perl -pi -e 's#/bin/cat#/usr/bin/false#' "$TOOLS/zstd"
if PATH="$TOOLS:/usr/bin:/bin" HOME="$TMP" FABLE_HOME="$INSTALL" SCHEDULER=cron \
    "$BASH_BIN" "$PROJ/dist/install-linux.sh" >/dev/null 2>&1; then
    fail "installer accepted zstd without streaming capability"
fi
cp "$TMP/zstd-good" "$TOOLS/zstd"
perl -pi -e 's/0\.16\.0/0.15.9/' "$TOOLS/zig"
if PATH="$TOOLS:/usr/bin:/bin" HOME="$TMP" FABLE_HOME="$INSTALL" SCHEDULER=cron \
    "$BASH_BIN" "$PROJ/dist/install-linux.sh" >/dev/null 2>&1; then
    fail "installer accepted an old Zig"
fi
perl -pi -e 's/0\.15\.9/0.16.0/' "$TOOLS/zig"

# A failed preflight must preserve the previous installation and never register.
printf 'old binary\n' > "$INSTALL/fable-monitor"
printf 'old env\n' > "$INSTALL/fable-monitor.env"
if PATH="$TOOLS:/usr/bin:/bin" HOME="$TMP" FABLE_HOME="$INSTALL" SCHEDULER=cron \
    FABLE_MONITOR_NOTIFY="$HOSTILE" "$BASH_BIN" "$PROJ/dist/install-linux.sh" >/dev/null 2>&1; then
    fail "installer continued after failed preflight"
fi
[ ! -e "$PWNED" ] || fail "staged env evaluated a hostile value"
[ "$(<"$INSTALL/fable-monitor")" = "old binary" ] || fail "failed preflight replaced the binary"
[ "$(<"$INSTALL/fable-monitor.env")" = "old env" ] || fail "failed preflight replaced the env file"
[ ! -e "$TMP/crontab-state" ] || fail "failed preflight registered a scheduler job"

# Installing a release archive requires its digest and invokes an optional
# provenance verifier before extracting or replacing anything.
ARTDIR="$TMP/artifact/fable-monitor-0.1.0-linux"
mkdir -p "$ARTDIR"
cat > "$ARTDIR/fable-monitor" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$ARTDIR/fable-monitor"
tar -C "$TMP/artifact" -czf "$TMP/release.tar.gz" "$(basename "$ARTDIR")"
SHA="$(shasum -a 256 "$TMP/release.tar.gz")"; SHA="${SHA%% *}"
cat > "$TOOLS/verifier" <<EOF
#!/usr/bin/env bash
[ "\$1" = '$TMP/release.tar.gz' ] && [ "\$2" = '$SHA' ]
touch '$TMP/verifier-called'
EOF
chmod +x "$TOOLS/verifier"
if PATH="$TOOLS:/usr/bin:/bin" HOME="$TMP" FABLE_HOME="$TMP/artifact-install" SCHEDULER=cron \
    FABLE_MONITOR_ARTIFACT="$TMP/release.tar.gz" FABLE_MONITOR_ARTIFACT_SHA256=deadbeef \
    "$BASH_BIN" "$PROJ/dist/install-linux.sh" >/dev/null 2>&1; then
    fail "installer accepted an invalid artifact digest"
fi
PATH="$TOOLS:/usr/bin:/bin" HOME="$TMP" FABLE_HOME="$TMP/artifact-install" SCHEDULER=cron \
    FABLE_MONITOR_ARTIFACT="$TMP/release.tar.gz" FABLE_MONITOR_ARTIFACT_SHA256="$SHA" \
    FABLE_MONITOR_ARTIFACT_VERIFIER="$TOOLS/verifier" \
    "$BASH_BIN" "$PROJ/dist/install-linux.sh" >/dev/null
[ -e "$TMP/verifier-called" ] || fail "artifact verifier hook was not called"
[ -x "$TMP/artifact-install/fable-monitor" ] || fail "verified artifact was not installed"

# Once replacement begins, a cron registration failure must restore both files
# and the exact previous crontab.
cat > "$PROJ/zig-out/bin/fable-monitor" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$PROJ/zig-out/bin/fable-monitor"
printf 'old cron\n' > "$TMP/crontab-state"
cat > "$TOOLS/crontab" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = -l ]; then
    /bin/cat '$TMP/crontab-state'
elif [ "\${1:-}" = - ]; then
    /bin/cat > '$TMP/cron-attempted'
    exit 1
elif [ "\${1:-}" = -r ]; then
    rm -f '$TMP/crontab-state'
else
    cp "\$1" '$TMP/crontab-state'
fi
EOF
chmod +x "$TOOLS/crontab"
if PATH="$TOOLS:/usr/bin:/bin" HOME="$TMP" FABLE_HOME="$INSTALL" SCHEDULER=cron \
    "$BASH_BIN" "$PROJ/dist/install-linux.sh" >"$TMP/install.out" 2>&1; then
    fail "installer ignored cron registration failure"
fi
[ "$(<"$INSTALL/fable-monitor")" = "old binary" ] || fail "cron rollback did not restore the binary"
[ "$(<"$INSTALL/fable-monitor.env")" = "old env" ] || fail "cron rollback did not restore the env file"
[ "$(<"$TMP/crontab-state")" = "old cron" ] || fail "cron rollback did not restore the crontab"

# A systemd failure must restore unit files and the timer's prior enabled and
# active state, not merely reload the old files.
UDIR="$TMP/.config/systemd/user"
mkdir -p "$UDIR"
printf 'old service\n' > "$UDIR/fable-monitor.service"
printf 'old timer\n' > "$UDIR/fable-monitor.timer"
cat > "$TOOLS/systemctl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$TMP/systemctl.log'
[ "\${1:-}" = --user ] && shift
case "\${1:-}" in
    is-enabled|is-active) exit 0 ;;
    enable) [ "\${2:-}" != --now ] ;;
esac
EOF
chmod +x "$TOOLS/systemctl"
if PATH="$TOOLS:/usr/bin:/bin" HOME="$TMP" FABLE_HOME="$INSTALL" SCHEDULER=systemd \
    "$BASH_BIN" "$PROJ/dist/install-linux.sh" >/dev/null 2>&1; then
    fail "installer ignored systemd registration failure"
fi
[ "$(<"$UDIR/fable-monitor.service")" = "old service" ] || fail "systemd rollback did not restore service"
[ "$(<"$UDIR/fable-monitor.timer")" = "old timer" ] || fail "systemd rollback did not restore timer"
grep -Fq -- '--user disable --now fable-monitor.timer' "$TMP/systemctl.log" || fail "systemd rollback did not disable partial timer"
grep -Fq -- '--user enable fable-monitor.timer' "$TMP/systemctl.log" || fail "systemd rollback did not re-enable old timer"
grep -Fq -- '--user start fable-monitor.timer' "$TMP/systemctl.log" || fail "systemd rollback did not restart old timer"

echo "PASS: installer safety, tools, artifacts, service hardening, and rollback"
