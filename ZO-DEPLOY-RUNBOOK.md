# fable_monitor — Zo deploy runbook

**Hand this whole file to a Claude Code session running ON the Zo instance.**
That session has native `zo` tooling + the local repo; this runbook is written
for *it*, not for the local Mac. Deploy target: reachable behind the public
`cipher009.zo.space` / `*.zo.computer` proxy.

Authoritative source: `docs/deployment.md` ("Zo.computer user services — the
live deployment") and `docs/ui.md`. If anything here disagrees with those docs
in the freshly pulled repo, trust the docs and tell the user.

---

## Goal

Two Zo **user services** running from the latest `main`:

| Service | Mode | Detail |
|---|---|---|
| `fable-monitor-poller` | `process` | in-binary 30-min loop (`FABLE_MONITOR_LOOP=1800`), writes state + appends alert lines to a pending file |
| `fable-monitor-ui` | `http`, **chosen port** | read-only htmx dashboard (`serve`) — becomes the public URL. **Do not use the 8787 default** (see Step 4). |

Repo at `~/fable_monitor`; durable state at `~/fable-monitor-data/`; the chosen
UI port is recorded at `~/fable-monitor-data/ui-port.txt`.

---

## Preconditions (verify first, don't assume)

```sh
zig version        # present on Zo
git --version      # present
curl --version     # present
zstd --version || sudo apt-get install -y zstd   # NOT preinstalled on Zo — required
```

`zstd` is mandatory: the binary shells out to it to read/write compressed state.
Run `./zig-out/bin/fable-monitor preflight` after building to confirm deps.

---

## Step 1 — Get the code (latest `main`)

```sh
cd ~
if [ -d fable_monitor/.git ]; then
  cd fable_monitor && git fetch origin && git checkout main && git reset --hard origin/main
else
  git clone https://github.com/cipher-rc5/fable_monitor.git ~/fable_monitor && cd ~/fable_monitor
fi
git log --oneline -1     # expect: 6b2938f Merge pull request #3 ... (api-probe) or newer
```

Sanity: `test -f src/serve.zig && grep -q '"relaunch"' src/sources.zig && echo OK`
— confirms the UI + return-family detection are present.

## Step 2 — Build for the baseline CPU (critical)

```sh
cd ~/fable_monitor
zig build -Doptimize=ReleaseSafe -Dcpu=baseline
./zig-out/bin/fable-monitor preflight
```

⚠️ **`-Dcpu=baseline` is not optional.** A plain `ReleaseSafe` targets the build
host's native CPU; supervisord may run the service on a host lacking those
instructions and the process dies with **SIGILL** (service flaps FATAL/BACKOFF).
Do NOT append `.baseline` to the target triple (rejected as `InvalidAbiVersion`)
— use the separate `-Dcpu` flag.

## Step 3 — Durable state dir + the poller wrapper

State must live outside the repo so a rebuild/redeploy never wipes it:

```sh
mkdir -p ~/fable-monitor-data
```

Create `~/fable_monitor/run-poller.sh` (the process the poller service execs):

```sh
cat > ~/fable_monitor/run-poller.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
export FABLE_MONITOR_STATE="$HOME/fable-monitor-data/state.jsonl.zst"
export FABLE_MONITOR_LOG="$HOME/fable-monitor-data/events.jsonl.zst"
export FABLE_MONITOR_LOOP=1800   # in-binary loop: poll every 30 min, no external scheduler
# Alert hook: append each tier-1 trip/escalation line to a pending file.
# A Zo automation (Step 7) drains + emails it. $1 is the alert line.
export FABLE_MONITOR_NOTIFY='printf "%s\n" "$1" >> "$HOME/fable-monitor-data/pending-alerts.ndjson"'
# --- optional extras (only if you have them; all safe to omit) ---
# export FABLE_MONITOR_WEBHOOK='https://…'
# export FABLE_MONITOR_HEARTBEAT_URL='https://hc-ping.com/<uuid>'
exec "$HOME/fable_monitor/zig-out/bin/fable-monitor" poll
EOF
chmod +x ~/fable_monitor/run-poller.sh
```

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
exec "$HOME/fable_monitor/zig-out/bin/fable-monitor" serve
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
curl -s "localhost:$PORT/ui/status" | head # expect an HTML fragment with stat cards
```

Then open the public URL in a browser signed into Zo. Expect the dashboard
(status cards, sources, recent events, alerts). **First poll is noisy by
design** — it baselines every source; subsequent polls are quiet until
something actually changes. The page pulls htmx + Tailwind from a CDN, so the
*viewing* browser needs internet (the data itself is local).

## Step 7 — (optional) Wire the alert email automation

The poller only *writes* `~/fable-monitor-data/pending-alerts.ndjson`. Delivery
is decoupled: create a Zo automation (~every 15 min) that, when that file is
non-empty, atomically moves it aside, emails the line(s) to the account owner,
and removes it. Idempotent — empty file sends nothing. This is Zo-native; set it
up with the instance's automation tooling. Skip for now if you just want the
dashboard up.

---

## Report back to the user

- the public dashboard URL and that it renders,
- **the chosen UI port** (from `~/fable-monitor-data/ui-port.txt`) and that it's
  a non-default port,
- both services' status,
- `git log --oneline -1` (the deployed commit),
- whether the alert automation (Step 7) was set up or deferred.

## Guardrails

- Don't delete `~/fable-monitor-data/state.*` in production — it's the source of
  truth for "what's new"; deleting it re-baselines and re-alerts everything.
- Don't delete `~/fable-monitor-data/ui-port.txt` either — the UI wrapper reads
  it at start; if it's missing the service won't know which port to bind.
- Secrets (webhook/heartbeat/API key) are all optional and must be provided in
  the service env at register time — never commit them.
- If a service won't stay up: check its log, and first suspect the
  baseline-CPU/SIGILL issue before anything else.
