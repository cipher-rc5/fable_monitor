# Deployment

Last reviewed: 2026-06-18 · against fable-monitor 0.1.0

`fable-monitor` does one poll per invocation and exits, so deployment means
"have a scheduler run the binary on an interval." This document covers the
macOS launchd path (shipped template), cron, the environment variables, and the
notify hook.

## Prerequisites

- A built binary: `zig build` → `zig-out/bin/fable-monitor`.
- `curl` on the `PATH` the scheduler uses (the binary preflights this and exits
  with a clear message if it's missing).
- `zstd` on the same `PATH` — the binary compresses its state, log, and Parquet
  outputs with it and preflights it in both modes (clear message if missing).
  Preinstalled on recent macOS/Linux; `brew install zstd` / your package manager
  otherwise.
- Writable, absolute state-file and log-file paths.

## Environment variables

| Variable | Required | Purpose |
|---|---|---|
| `FABLE_MONITOR_STATE` | recommended | Absolute path to the compressed JSONL state file. Defaults to `fable_monitor_state.jsonl.zst` in the working directory — fine for manual runs, but always set it explicitly under a scheduler. See [state-format.md](state-format.md). |
| `FABLE_MONITOR_LOG` | recommended | Absolute path to the observation log (compressed JSONL). Defaults to `fable_monitor_events.jsonl.zst` in the working directory. Set it explicitly under a scheduler so the history accrues in a known location; it is the input to `export`. See [data-export.md](data-export.md). |
| `FABLE_MONITOR_NOTIFY` | optional | Shell command run on high-signal alerts. The alert text is passed as `$1` (injection-safe). |

### The notify hook

When set, `FABLE_MONITOR_NOTIFY` runs as `sh -c <cmd> fable-monitor "<alert>"`,
so reference the message as `$1`. It fires only for high-signal events: relevant
Federal Register documents and keyword-watch page changes.

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

A ready template lives at `dist/io.zerocreativity.fable-monitor.plist`. Its
paths are already set for this checkout; if you move the project, update the
binary path, `WorkingDirectory`, `FABLE_MONITOR_STATE`, `FABLE_MONITOR_LOG`, and
the two log paths.

```sh
cp dist/io.zerocreativity.fable-monitor.plist ~/Library/LaunchAgents/
launchctl load ~/Library/LaunchAgents/io.zerocreativity.fable-monitor.plist
```

Key fields in the plist:

- `StartInterval` `1800` — poll every 30 minutes.
- `RunAtLoad` `true` — also run once immediately on load.
- `StandardOutPath` / `StandardErrorPath` — alerts (stdout) and diagnostics
  (stderr) are logged separately.
- `PATH` includes `/opt/homebrew/bin` so a Homebrew `curl`/notifier resolves.

To stop:

```sh
launchctl unload ~/Library/LaunchAgents/io.zerocreativity.fable-monitor.plist
```

After editing the plist you must `unload` then `load` again for changes to take
effect. Validate edits with `plutil -lint <file>`.

## Linux / cron

There is no shipped cron template, but the model is identical — run the binary
on a schedule with the env vars set and an absolute state path. Example crontab
entry polling every 30 minutes:

```cron
*/30 * * * * FABLE_MONITOR_STATE=/var/lib/fable-monitor/state.jsonl.zst \
  FABLE_MONITOR_LOG=/var/lib/fable-monitor/events.jsonl.zst \
  FABLE_MONITOR_NOTIFY='notify-send "fable-monitor" "$1"' \
  /opt/fable-monitor/zig-out/bin/fable-monitor >> /var/log/fable-monitor.log 2>&1
```

Ensure `curl` is on the cron environment's `PATH` (cron's `PATH` is minimal;
set it explicitly in the crontab if needed). A systemd timer is a cleaner
alternative if you prefer journald logging.

## Operating notes

- **Logs are the dashboard.** stdout carries alerts; stderr carries
  `[fable-monitor]`-prefixed diagnostics. A persistently failing source only
  shows up in stderr (see error isolation in
  [design-decisions.md](design-decisions.md)), so watch the error log.
- **First run is noisy by design** — it baselines everything. Subsequent runs
  are quiet until something actually changes.
- **State is the source of truth for "what's new."** Don't delete it in
  production unless you intend to re-baseline (which will re-alert everything).

## When you change deployment, update the docs

Per the [maintenance policy](README.md), changes to env vars, the notify hook,
the plist, or scheduling must update this file and the top-level
[README](../README.md) in the same change.
