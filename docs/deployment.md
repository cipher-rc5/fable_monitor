# Deployment

Last reviewed: 2026-06-28 · against fable-monitor 0.1.0 (feat/tiered-monitor)

`fable-monitor` does one poll per invocation and exits, so deployment means
"have a scheduler run the binary on an interval." This document covers the
macOS launchd path, the Linux / Zo.computer path (systemd or cron via
`dist/install-linux.sh`), the full environment-variable reference, the notify
hook, and the dead-man's-switch heartbeat.

Run `fable-monitor preflight` before scheduling: it checks the `curl`/`zstd`
binaries, that the state path is writable, network egress to each enabled
source, and whether the optional secrets (webhook / heartbeat / notify) are set.
It prints one summary and returns an error on a hard failure.

## Prerequisites

- A built binary: `zig build` → `zig-out/bin/fable-monitor` (the installers
  build a `ReleaseSafe` binary for you).
- `curl` on the `PATH` the scheduler uses (the binary preflights this and exits
  with a clear message if it's missing).
- `zstd` on the same `PATH`, the binary compresses its state, log, and Parquet
  outputs with it and preflights it in both modes (clear message if missing).
  Preinstalled on recent macOS/Linux; `brew install zstd` / your package manager
  otherwise.
- Writable, absolute state-file and log-file paths that survive restarts.

## Environment variables

All configuration is by environment variable. The cadence and emitter vars are
the new additions for the tiered monitor.

| Variable | Required | Purpose |
|---|---|---|
| `FABLE_MONITOR_STATE` | recommended | Absolute path to the compressed JSONL state file. Defaults to `fable_monitor_state.jsonl.zst` in the working directory. Always set it explicitly under a scheduler. See [state-format.md](state-format.md). |
| `FABLE_MONITOR_LOG` | recommended | Absolute path to the observation log (compressed JSONL). Defaults to `fable_monitor_events.jsonl.zst`. It is the input to `export`. See [data-export.md](data-export.md). |
| `FABLE_MONITOR_SOURCES` | optional | Path to an external JSON source config; replaces the embedded default. See [sources.md](sources.md). |
| `FABLE_MONITOR_ONLY` | optional | Comma-separated source-id whitelist: if set, only these sources are enabled. |
| `FABLE_MONITOR_DISABLE` | optional | Comma-separated source ids to force-disable (wins over `ONLY`). |
| `FABLE_MONITOR_FIXTURES` | optional | Directory of fixture bodies; each source reads `<dir>/<source_id>` instead of the network (offline replay tests). Implies polling all sources. |
| `FABLE_MONITOR_FORCE` | optional | If set, poll every enabled source regardless of cadence (ignore the due-check). |
| `FABLE_MONITOR_FAST_INTERVAL` | optional | Override the fast-loop cadence (seconds) for tier-1 sources; default 45 (from the config's `fast_interval_s`). |
| `FABLE_MONITOR_LOOP` | optional | Run an internal loop polling every N seconds, for environments without a sub-minute scheduler. The in-binary due-cadence still gates per-tier work. |
| `FABLE_MONITOR_EVENT_SINK` | optional | Append each emitted structured event (one JSON line) to this file, in addition to stdout. |
| `FABLE_MONITOR_WEBHOOK` | optional | POST each structured event to this URL, in addition to stdout. |
| `FABLE_MONITOR_HEARTBEAT_URL` | optional | Dead-man's-switch ping target (healthchecks.io style); pinged after a clean run. |
| `FABLE_MONITOR_ESCALATE_AFTER` | optional | Seconds before an unacknowledged high-confidence alert re-fires once; default 3600. |
| `FABLE_MONITOR_NOTIFY` | optional | Shell command run on high-confidence trips and escalations. The alert text is passed as `$1` (injection-safe). |
| `FABLE_MONITOR_METRICS` | optional | If set, also write per-source fetch metric rows (latency / HTTP status) to the observation log. |
| `FABLE_MONITOR_STATS` | optional | If set, log a `getrusage` peak-RSS/CPU summary (process + curl/zstd children) to stderr at the end of each run, and enable metric rows. See [development.md](development.md) → Resource usage. |

Each run also prints a one-line metrics summary to stderr regardless of the
above (counts of ok / not-modified / failed sources, total fetch ms, total
wall-clock ms).

### Structured events (the integration point)

On a trip the monitor emits a single-line JSON event to **stdout always**, and
additionally appends it to `FABLE_MONITOR_EVENT_SINK` and POSTs it to
`FABLE_MONITOR_WEBHOOK` when those are set. The schema is `fable-monitor.event/1`:

```json
{"schema":"fable-monitor.event/1","event_id":"model_present:claude-fable-5",
 "kind":"restoration","tier":1,"confidence":"high","escalation":false,
 "corroborating_sources":["anthropic_model_list","anthropic_pricing"],
 "detected_at":"2026-06-28T14:03:09Z","epoch_ms":1782396189000,
 "title":"Model claude-fable-5 present in public listing",
 "evidence_url":"https://docs.anthropic.com/...","document_number":"","detail":"claude-fable-5"}
```

A downstream trading/execution system consumes this event in a separate process;
the monitor's responsibility ends at emitting the verified signal.

### The dead-man's switch (heartbeat)

Set `FABLE_MONITOR_HEARTBEAT_URL` to a healthchecks.io-style ping URL. After a
successful run the monitor pings it; if the pings stop (the monitor died, the
scheduler is wedged, the host is down), the external service alerts you. This
makes the monitor's own liveness monitored, which a passive poller cannot do for
itself. The `audit` subcommand complements this by surfacing a single source that
is quietly failing while the run as a whole still succeeds.

### Acknowledging and escalation

A fired high-confidence alert is recorded once per event identity and does not
re-fire as the change persists. If it remains unacknowledged for
`FABLE_MONITOR_ESCALATE_AFTER` seconds (default 3600) it re-fires exactly once.
Acknowledge it with `fable-monitor ack <event_id>` (the `event_id` from the
structured event) to stop the escalation.

### The notify hook

When set, `FABLE_MONITOR_NOTIFY` runs as `sh -c <cmd> fable-monitor "<alert>"`,
so reference the message as `$1`. It fires only for high-confidence trips and
escalations (a tier-1 restoration, or an advisory promoted by corroboration),
never for an unconfirmed tier-2/3 advisory.

macOS native notification, no extra install:

```sh
export FABLE_MONITOR_NOTIFY='osascript -e "display notification \"$1\" with title \"fable-monitor\""'
```

With terminal-notifier:

```sh
export FABLE_MONITOR_NOTIFY='terminal-notifier -title "fable-monitor" -message "$1"'
```

Test the hook without spamming yourself by using `echo` first (the `just
test-notify` recipe does exactly this):

```sh
FABLE_MONITOR_NOTIFY='echo ">>> NOTIFY: $1"' FABLE_MONITOR_STATE=/tmp/fm.json zig build run
```

## macOS (launchd)

The easiest path is the installer, which builds a release binary, stages it
under `~/Library/Application Support/fable-monitor/`, generates the LaunchAgent,
validates it (`plutil -lint`), and loads it:

```sh
bash dist/install.sh        # or: just install
just status                 # loaded? last exit code?
just log                    # read the agent's collected history (formatted)
just logs                   # tail the alert/diagnostic logs
bash dist/uninstall.sh      # or: just uninstall, unload and remove
```

**Why Application Support, not the checkout?** On modern macOS, `~/Desktop`,
`~/Documents`, and `~/Downloads` are TCC-protected. A background launchd agent
can't answer the consent prompt, so launching a binary from there hangs in the
loader (`open()`), `last exit code` never set. Staging the binary, state, log,
and stdout/stderr under Application Support (not protected) lets it run
unattended. The agent's data therefore lives at
`~/Library/Application Support/fable-monitor/`, `just log` reads it from there.

Tunables:

- `FABLE_INTERVAL=<seconds> bash dist/install.sh` overrides the poll cadence
  (default 1800 = 30 min).
- The installer prefers `terminal-notifier` (more reliable from a background
  agent) and falls back to `osascript`. `bash dist/install.sh --dry-run` prints
  the plist it would write without installing.

The generated agent sets:

- `StartInterval`, poll every `FABLE_INTERVAL` seconds.
- `RunAtLoad` `true`, also run once immediately on load.
- `EnvironmentVariables`, `FABLE_MONITOR_STATE` / `_LOG` / `_NOTIFY`, plus a
  `PATH` that includes the directories where this machine's `curl` and `zstd`
  live (resolved at install time).
- `StandardOutPath` / `StandardErrorPath`, alerts (stdout) and diagnostics
  (stderr), logged separately under Application Support.

### Manual / reference

`dist/io.zerocreativity.fable-monitor.plist` is a hand-editable reference plist
(with `/path/to/fable_monitor` placeholders). To use it directly, replace the
placeholders, `cp` it to `~/Library/LaunchAgents/`, and
`launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/io.zerocreativity.fable-monitor.plist`
(or the legacy `launchctl load -w`). The installer above does this for you.

After editing the plist you must `unload` then `load` again for changes to take
effect. Validate edits with `plutil -lint <file>`.

## Linux / Zo.computer (systemd or cron)

`dist/install-linux.sh` installs a recurring job on a Linux host (the
Zo.computer deployment target included), parameterized by scheduler. It:

1. builds a `ReleaseSafe` binary;
2. stages the binary and durable state under `FABLE_HOME`
   (default `~/.local/share/fable-monitor`);
3. writes a `0600` env file (`fable-monitor.env`) under `FABLE_HOME`, sourcing
   the secrets from the environment **at install time** (nothing is committed);
4. runs `fable-monitor preflight`;
5. registers the job: a systemd **user timer** firing every
   `FABLE_FAST_INTERVAL` seconds, or a crontab entry.

```sh
bash dist/install-linux.sh                 # auto-detect scheduler
SCHEDULER=systemd bash dist/install-linux.sh
SCHEDULER=cron    bash dist/install-linux.sh
bash dist/install-linux.sh --dry-run       # print the env file + units, install nothing
bash dist/uninstall-linux.sh               # remove the job (leaves binary/state/logs)
```

Or via the task runner: `just install-linux`, `just install-linux-preview`,
`just uninstall-linux`.

**Scheduler selection** (override with `SCHEDULER=systemd|cron|zo`):

- **zo**: a Zo.computer instance is detected; use its native scheduler if a
  `zo` CLI is present, otherwise fall back to cron (always available on the
  instance). For sub-minute cadence on Zo, register a native scheduled task
  running `$BIN poll` with the env sourced from the env file.
- **systemd**: a user timer (`OnUnitActiveSec=$FABLE_FAST_INTERVAL`) running the
  oneshot `fable-monitor poll` service. Status:
  `systemctl --user status fable-monitor.timer`; logs:
  `journalctl --user -u fable-monitor.service -f`.
- **cron**: a once-per-minute crontab entry. cron's finest granularity is one
  minute; the in-binary due-cadence still gates tier-2/3 work, so a 1-minute
  cron approximates the tier-1 fast loop closely enough. Output goes to
  `$FABLE_HOME/cron.out`.

**Durable state.** `FABLE_HOME` must be an absolute path that survives restarts.
On Zo, point it at the instance's persistent volume:

```sh
FABLE_HOME=/persistent/fable-monitor FABLE_FAST_INTERVAL=45 bash dist/install-linux.sh
```

The env file the installer writes sets `FABLE_MONITOR_STATE`,
`FABLE_MONITOR_LOG`, `FABLE_MONITOR_FAST_INTERVAL`, and (when present in the
install-time environment) `FABLE_MONITOR_WEBHOOK`, `FABLE_MONITOR_HEARTBEAT_URL`,
`FABLE_MONITOR_EVENT_SINK`, `FABLE_MONITOR_NOTIFY`, and `FABLE_MONITOR_SOURCES`.
Provide the secrets in your shell before running the installer, e.g.:

```sh
export FABLE_MONITOR_WEBHOOK='https://example.com/hooks/fable'
export FABLE_MONITOR_HEARTBEAT_URL='https://hc-ping.com/<uuid>'
export FABLE_MONITOR_NOTIFY='curl -fsS -X POST -d "text=$1" https://example.com/notify'
FABLE_HOME=/persistent/fable-monitor bash dist/install-linux.sh
```

### Zo.computer user services (the live deployment)

The reference deployment on Zo does not use `install-linux.sh`; it uses Zo's
own **user services** (a supervisord-managed process manager), which is simpler
than provisioning systemd inside the sandbox and gets automatic restarts. Two
services back the running instance:

- **`fable-monitor-poller`** (mode `process`) — runs a wrapper that exports the
  state/log paths plus `FABLE_MONITOR_LOOP=1800`, then `exec`s the binary. The
  in-binary loop (see [Environment variables](#environment-variables)) polls
  every 30 min, so no external scheduler is needed.
- **`fable-monitor-ui`** (mode `http`, port 8787) — the read-only dashboard
  (`serve`; see [ui.md](ui.md)). It is kept **private**: reachable only at its
  `*.zo.computer` URL while signed in to Zo, never exposed publicly.

Repo at `~/fable_monitor`; durable state at
`~/fable-monitor-data/{state,events}.jsonl.zst`.

**Build for a baseline CPU.** Build with:

```sh
zig build -Doptimize=ReleaseSafe -Dcpu=baseline
```

A plain `-Doptimize=ReleaseSafe` targets the *native* CPU of the build host;
supervisord may run the service on a host whose CPU lacks those instructions,
and the process dies with **SIGILL** (the service flaps FATAL/BACKOFF). The
`-Dcpu=baseline` flag pins the generic x86-64 baseline. (Appending `.baseline`
to the target triple is rejected as `InvalidAbiVersion` — use the separate
`-Dcpu` flag.) `zstd` is not preinstalled on Zo (`apt-get install -y zstd`);
`zig`, `git`, and `curl` are.

**Notifications via a Zo automation.** The poller sets

```sh
export FABLE_MONITOR_NOTIFY='printf "%s\n" "$1" >> ~/fable-monitor-data/pending-alerts.ndjson'
```

so every tier-1 trip/escalation appends its alert line to a pending file. A Zo
automation runs every ~15 min; when that file is non-empty it moves it aside
atomically, emails the alert(s) to the account owner, and removes it. This
decouples the always-on poller (which only writes the file) from delivery
(which Zo handles), and is idempotent — an empty file sends nothing.

### Manual cron / reference

If you prefer a hand-written job, the model is identical: run the binary on a
schedule with the env vars set and an absolute, durable state path. Ensure
`curl` and `zstd` are on the scheduler's `PATH` (cron's is minimal; set it
explicitly).

## Operating notes

- **Logs are the dashboard.** stdout carries alerts; stderr carries
  `[fable-monitor]`-prefixed diagnostics. A persistently failing source only
  shows up in stderr (see error isolation in
  [design-decisions.md](design-decisions.md)), so watch the error log.
- **First run is noisy by design**, it baselines everything. Subsequent runs
  are quiet until something actually changes.
- **State is the source of truth for "what's new."** Don't delete it in
  production unless you intend to re-baseline (which will re-alert everything).

## When you change deployment, update the docs

Per the [maintenance policy](README.md), changes to env vars, the notify hook,
the plist, or scheduling must update this file and the top-level
[README](../README.md) in the same change.
