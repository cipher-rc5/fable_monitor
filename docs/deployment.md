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
| `FABLE_MONITOR_STATS` | optional | If set (e.g. `=1`), log a `getrusage` peak-RSS/CPU summary (process + curl/zstd children) to stderr at the end of each run. See [development.md](development.md) → Resource usage. |

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

The easiest path is the installer, which builds a release binary, stages it
under `~/Library/Application Support/fable-monitor/`, generates the LaunchAgent,
validates it (`plutil -lint`), and loads it:

```sh
bash dist/install.sh        # or: just install
just status                 # loaded? last exit code?
just log                    # read the agent's collected history (formatted)
just logs                   # tail the alert/diagnostic logs
bash dist/uninstall.sh      # or: just uninstall — unload and remove
```

**Why Application Support, not the checkout?** On modern macOS, `~/Desktop`,
`~/Documents`, and `~/Downloads` are TCC-protected. A background launchd agent
can't answer the consent prompt, so launching a binary from there hangs in the
loader (`open()`), `last exit code` never set. Staging the binary, state, log,
and stdout/stderr under Application Support (not protected) lets it run
unattended. The agent's data therefore lives at
`~/Library/Application Support/fable-monitor/` — `just log` reads it from there.

Tunables:

- `FABLE_INTERVAL=<seconds> bash dist/install.sh` overrides the poll cadence
  (default 1800 = 30 min).
- The installer prefers `terminal-notifier` (more reliable from a background
  agent) and falls back to `osascript`. `bash dist/install.sh --dry-run` prints
  the plist it would write without installing.

The generated agent sets:

- `StartInterval` — poll every `FABLE_INTERVAL` seconds.
- `RunAtLoad` `true` — also run once immediately on load.
- `EnvironmentVariables` — `FABLE_MONITOR_STATE` / `_LOG` / `_NOTIFY`, plus a
  `PATH` that includes the directories where this machine's `curl` and `zstd`
  live (resolved at install time).
- `StandardOutPath` / `StandardErrorPath` — alerts (stdout) and diagnostics
  (stderr), logged separately under Application Support.

### Manual / reference

`dist/io.zerocreativity.fable-monitor.plist` is a hand-editable reference plist
(with `/path/to/fable_monitor` placeholders). To use it directly, replace the
placeholders, `cp` it to `~/Library/LaunchAgents/`, and
`launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/io.zerocreativity.fable-monitor.plist`
(or the legacy `launchctl load -w`). The installer above does this for you.

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
