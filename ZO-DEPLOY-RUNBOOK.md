# fable_monitor - Zo deploy runbook

**Hand this whole file to a Claude Code session running ON the Zo instance.**
That session has native `zo` tooling + the local repo; this runbook is written
for *it*, not for the local Mac. Deploy target: reachable behind the public
`cipher009.zo.space` / `*.zo.computer` proxy.

Authoritative source: `docs/deployment.md` ("Zo.computer user services — the
live deployment") and `docs/ui.md`. If anything here disagrees with those docs
in the freshly pulled repo, trust the docs and tell the user.

---

## Goal

Two Zo **user services** running an operator-selected immutable release:

| Service | Mode | Detail |
|---|---|---|
| `fable-monitor-poller` | `process` | in-binary 30-min loop (`FABLE_MONITOR_LOOP=1800`), writes state + appends alert lines to a pending file |
| `fable-monitor-ui` | `http`, **chosen port** | read-only local-asset dashboard (`serve`) that becomes the authenticated URL. **Do not use the 8787 default** (see Step 4). |

Repo at `~/fable_monitor`; durable state at `~/fable-monitor-data/`; the chosen
UI port is recorded at `~/fable-monitor-data/ui-port.txt`.

---

## Preconditions (verify first, don't assume)

```sh
git --version      # present
curl --version     # present
zstd --version || sudo apt-get install -y zstd   # NOT preinstalled on Zo — required
gh --version        # required to fetch and verify the immutable GitHub release
cosign version      # required to verify the keyless signature bundle
```

`zstd` is mandatory: the binary shells out to it to read/write compressed state.
Run `./fable-monitor preflight --json` after installing the packaged binary and
retain the `fable-monitor.preflight/1` result. Exit 1 or `"ok":false` blocks
registration.

---

## Step 1 — Select and verify an immutable release

Ask the user for a specific `v<version>` tag. Never deploy `main`, a branch
archive, or an unverified local rebuild. Set `RELEASE_TAG` to the answer and
select the archive matching `uname -m` (`linux-x86_64` or `linux-aarch64`).

```sh
RELEASE_TAG=v0.1.0                 # replace with the operator-approved tag
case "$(uname -m)" in
  x86_64) PLATFORM=linux-x86_64 ;;
  aarch64|arm64) PLATFORM=linux-aarch64 ;;
  *) echo "unsupported architecture" >&2; exit 1 ;;
esac

cd ~
if [ -d fable_monitor/.git ]; then
  cd fable_monitor
  test -z "$(git status --porcelain)" || { echo "dirty checkout; preserve/reconcile changes before deployment" >&2; exit 1; }
  git fetch --tags origin
else
  git clone https://github.com/cipher-rc5/fable_monitor.git ~/fable_monitor && cd ~/fable_monitor
fi
git checkout --detach "$RELEASE_TAG"
git log --oneline -1     # record this exact immutable commit

rm -rf ~/fable-monitor-release && mkdir ~/fable-monitor-release
cd ~/fable-monitor-release
gh release download "$RELEASE_TAG" --repo cipher-rc5/fable_monitor
sha256sum -c SHA256SUMS
cosign verify-blob \
  --bundle SHA256SUMS.sigstore.json \
  --certificate-identity-regexp 'https://github.com/cipher-rc5/fable_monitor/.github/workflows/release.yml@refs/tags/v.*' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  SHA256SUMS
ARCHIVE="$(printf '%s\n' fable-monitor-*-${PLATFORM}.tar.gz)"
gh attestation verify "$ARCHIVE" --repo cipher-rc5/fable_monitor
test -s "fable-monitor-${RELEASE_TAG}.spdx.json"
tar -xzf "$ARCHIVE"
install -m 0755 fable-monitor-*-${PLATFORM}/fable-monitor ~/fable_monitor/fable-monitor
```

Record the checksum, attestation result, workflow/tag commit, and reviewed SBOM
in the deployment report. Their presence is not proof until these commands pass.

## Step 2 — Preflight the packaged baseline-CPU binary

```sh
cd ~/fable_monitor
./fable-monitor preflight --json
```

The release workflow builds `ReleaseSafe` with `-Dcpu=baseline` and smoke-tests
each native artifact. Do not replace it with a plain host-native build; that can
die with SIGILL when supervisord moves the service to a different host CPU.

## Step 3 — Durable state dir + the poller wrapper

State must live outside the repo so a rebuild/redeploy never wipes it:

```sh
mkdir -p ~/fable-monitor-data
chmod 700 ~/fable-monitor-data
```

Create `~/fable_monitor/run-poller.sh` (the process the poller service execs):

```sh
cat > ~/fable_monitor/run-poller.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
export FABLE_MONITOR_STATE="$HOME/fable-monitor-data/state.jsonl.zst"
export FABLE_MONITOR_LOG="$HOME/fable-monitor-data/events.jsonl.zst"
export FABLE_MONITOR_LOOP=1800   # in-binary loop: poll every 30 min, no external scheduler
export FABLE_MONITOR_LOOP_MAX_FAILURES=3
export FABLE_MONITOR_MIN_DECISIVE_SOURCES=1
# Optional strict profile, using enabled decisive IDs only:
# export FABLE_MONITOR_REQUIRED_SOURCES='anthropic_model_list,anthropic_statement'
# Alert hook: append each tier-1 trip/escalation line to a pending file.
# A Zo automation (Step 7) drains + emails it. $1 is the alert line.
export FABLE_MONITOR_NOTIFY='printf "%s\n" "$1" >> "$HOME/fable-monitor-data/pending-alerts.ndjson"'
# --- optional extras (only if you have them; all safe to omit) ---
# export FABLE_MONITOR_WEBHOOK='https://…'
# export FABLE_MONITOR_HEARTBEAT_URL='https://hc-ping.com/<uuid>'
exec "$HOME/fable_monitor/fable-monitor" poll
EOF
chmod +x ~/fable_monitor/run-poller.sh
```

Before registering it, run `preflight --json` with the wrapper's state/log/coverage
variables exported in the current shell. Optional secret values must come from
Zo's service secret mechanism or mode-0600 environment storage, not the wrapper
or command line.

## Step 4 — Choose the UI port (DO NOT hardcode 8787)

**Security rationale:** `8787` is the documented default and is trivially
guessable/scannable. Even though Zo fronts the service with an authenticated
`*.zo.computer` proxy, binding the *local* listener to an unpredictable,
non-default port is cheap defense-in-depth. Pick a port, then **write it to
`~/fable-monitor-data/ui-port.txt` as the single source of truth** so the
service and the verification step can't drift.

**First, ask the user** (the LLM running this must literally ask, not assume):
> *"Which local port should the fable_monitor UI bind to? Reply with a specific
> port, or say 'random' and I'll pick a verified-free one."*

Then, based on the answer:

```sh
mkdir -p ~/fable-monitor-data

# If the user gave a specific port, set it here; otherwise leave empty to auto-pick.
REQUESTED_PORT=""      # e.g. REQUESTED_PORT=41537

port_is_free() {
  # true when nothing is listening on $1
  ! { ss -ltnH 2>/dev/null || netstat -ltn 2>/dev/null; } | grep -qE "[:.]$1[[:space:]]"
}

if [ -n "$REQUESTED_PORT" ]; then
  if port_is_free "$REQUESTED_PORT"; then
    PORT="$REQUESTED_PORT"
  else
    echo "requested port $REQUESTED_PORT is in use — pick another" >&2; exit 1
  fi
else
  # Random port in 20000–32767: above the registered-service clutter, below the
  # Linux ephemeral range (32768+) so we won't collide with outbound sockets.
  PORT=""
  for _ in $(seq 1 50); do
    cand=$(( (RANDOM % 12768) + 20000 ))
    if port_is_free "$cand"; then PORT="$cand"; break; fi
  done
  [ -n "$PORT" ] || { echo "no free port found in range" >&2; exit 1; }
fi

# Document it — this file is the ONLY place the port is defined.
printf '%s\n' "$PORT" > ~/fable-monitor-data/ui-port.txt
chmod 600 ~/fable-monitor-data/ui-port.txt
echo "fable_monitor UI port = $PORT (recorded in ~/fable-monitor-data/ui-port.txt)"
```

Report the chosen port back to the user and record it wherever they track
deployment config. From here on, everything reads it from `ui-port.txt` — nobody
retypes the number.

## Step 5 — Register the two Zo user services

Use Zo's native user-service mechanism (the supervisord-backed process manager —
whatever the `zo` CLI / Zo UI exposes on this instance). Register exactly these:

**`fable-monitor-poller`**
- mode: `process`
- command: `~/fable_monitor/run-poller.sh`
- working dir: `~/fable_monitor`
- autorestart: yes

**`fable-monitor-ui`** — first write the wrapper, which reads the port from the
documented file so there's one source of truth:

```sh
cat > ~/fable_monitor/run-ui.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
export FABLE_MONITOR_STATE="$HOME/fable-monitor-data/state.jsonl.zst"
export FABLE_MONITOR_LOG="$HOME/fable-monitor-data/events.jsonl.zst"
export FABLE_MONITOR_PORT="$(cat "$HOME/fable-monitor-data/ui-port.txt")"
exec "$HOME/fable_monitor/fable-monitor" serve
EOF
chmod +x ~/fable_monitor/run-ui.sh
```
- mode: `http`
- port: **the value in `~/fable-monitor-data/ui-port.txt`** (`cat` it and use
  that exact number when registering the http service — it must match what
  `run-ui.sh` exports)
- command: `~/fable_monitor/run-ui.sh`

`serve` binds `127.0.0.1:<port>`; Zo's `http` service proxies the public URL to
that local port, so loopback binding is correct — do NOT try to bind 0.0.0.0.

## Step 6 — Verify it's live

```sh
PORT="$(cat ~/fable-monitor-data/ui-port.txt)"
# service status: both RUNNING, not FATAL/BACKOFF (BACKOFF ⇒ almost always the
# SIGILL/baseline mistake from Step 2 — rebuild with -Dcpu=baseline)
#   <zo user-services status command>

curl -s "localhost:$PORT/healthz"          # expect: ok
curl -fsS "localhost:$PORT/readyz"         # expect: ready after a healthy poll
curl -s "localhost:$PORT/ui/status" | head # expect an HTML fragment with stat cards
```

Then open the public URL in a browser signed into Zo. Expect the dashboard
(status cards, sources, recent events, alerts). **First poll is noisy by
design** — it baselines every source; subsequent polls are quiet until
something actually changes. JavaScript and CSS are embedded in the binary; the
dashboard has no CDN dependency. The article reader remains disabled by default;
do not set `FABLE_MONITOR_READER=1` on this proxied service without a separate
security review of the residual risks in `docs/ui.md`.

## Step 7 — (optional) Wire the alert email automation

The state-v5 outbox retries the notify command until appending to
`pending-alerts.ndjson` succeeds. A separate Zo automation may drain and email
that file, but this repository does not create, own, or verify that external
automation. If configured, require it to deduplicate the occurrence key in each
message and record a canary result. Otherwise report it as an explicit blocker,
not completed work.

---

## Report back to the user

- the public dashboard URL and that it renders,
- **the chosen UI port** (from `~/fable-monitor-data/ui-port.txt`) and that it's
  a non-default port,
- both services' status,
- release tag, `git log --oneline -1`, checksum, provenance result, and SBOM
  review record,
- whether the alert automation (Step 7) was set up or deferred.

## Guardrails

- Don't delete `~/fable-monitor-data/state.*` in production: it is the source of
  truth for "what's new"; deleting it re-baselines transition detectors and
  reevaluates current Federal Register history.
- Don't delete `~/fable-monitor-data/ui-port.txt` either — the UI wrapper reads
  it at start; if it's missing the service won't know which port to bind.
- Secrets (webhook/heartbeat/API key) are all optional and must be provided in
  the service env at register time, never committed, and stored with mode 0600
  where file-backed. This runbook does not claim credentials were rotated.
- If a service won't stay up: check its log, and first suspect the
  baseline-CPU/SIGILL issue before anything else.
- Before replacing the binary, take a consistent backup while the poller is
  stopped and retain the previous verified binary. Follow
  `docs/operations.md` and `docs/release.md` for restore, incidents, retention,
  and rollback. Roll back by stopping both services, restoring the previous
  verified binary and, only when required by persistence compatibility, its
  matching pre-upgrade state backup; then run preflight/audit and verify both
  probes before restarting the poller. This runbook does not claim operational
  ownership, backup/notification/rollback drills, credential rotation, or
  branch-protection settings are complete.
- Before manual recovery, stop the poller and run `fable-monitor state inspect`.
  `state recover` validates `<state>.backup`, quarantines the active generation,
  and writes `<state>.recovery.json`; `state rebaseline` is an explicit
  destructive-baseline decision and must be recorded in the deployment report.
- If log reads report manifest recovery is required, keep the complete log
  family together and run `fable-monitor log recover` while the poller is
  stopped. It validates the backup manifest and every referenced component
  before restoring the primary; do not hand-edit either manifest.
