# fable-monitor

Zig 0.16 command-line tool that polls public sources for the restoration of US
government export-control access to Anthropic's Fable 5 and Mythos 5 models, and
emits a verified, low-latency signal when access comes back.

It runs as a scheduled job (launchd, systemd, or cron). Each invocation is one
poll: it fetches the sources that are due this tick, runs a per-kind detector,
coalesces corroborating signals into one alert, commits the observation batch,
then commits updated state and a durable per-sink outbox before delivering the
structured JSON event and optional notification hook. Audit-first ordering means
a log failure cannot advance detector baselines past an unrecorded transition.
The monitor's job ends at emitting the verified signal; any system that acts on
it lives in a separate process.

## What it watches

Sources are described by a JSON config (an embedded default, overridable via
`FABLE_MONITOR_SOURCES`) and graded into three confidence tiers. The default
config ships 12 sources (11 enabled by default), including four tier-1 trippers. The authenticated API
probe is skipped unless `ANTHROPIC_API_KEY` is set; three public probes remain.

- **Tier 1 (decisive, lowest latency).** The public model listing and pricing
  page (a `model_list_probe` detects an absent-to-present transition of
  `claude-fable-5` / `claude-mythos-5`, the single most decisive confirmation
  that access is live) and the access-statement page (a `statement_watch` trips
  on restoration vocabulary). A tier-1 change trips immediately at high
  confidence.
- **Tier 2 (official record).** The Federal Register documents and
  public-inspection feeds (BIS rules and the term "Anthropic") and the BIS news
  page, with a tightened relevance filter so a document must name Anthropic or a
  specific model, not merely contain the word "fable".
- **Tier 3 (early but noisy).** The Anthropic newsroom sitemap, a Google News
  feed, and a prediction market. Advisory only; never auto-actioned on its own.

A tier-2/3 advisory is promoted to high confidence when a second distinct source
corroborates it on the same event identity. Full details, the config format, and
every source kind are in [`docs/sources.md`](docs/sources.md).

## Design notes

The tool is std-only Zig with two external binaries: `curl` for fetching, and
`zstd` for compressing its outputs. Delegating to these sidesteps the churn in
Zig's in-tree TLS/HTTP client and the fact that std ships no zstd *compressor*,
and both binaries are widely available. Everything else (JSON parsing,
normalization, hashing, state, RSS/Atom/sitemap parsing, and a from-scratch
Parquet writer) is standard library.

Each poll sends conditional requests (ETag / If-Modified-Since) so unchanged
sources return 304 cheaply, and only polls sources that are *due*: tier-1 on a
fast loop, tier-2/3 on a slow loop. State is a single zstd-compressed
line-delimited JSON file (format v5; v1-v4 files migrate on the next save). V4
added occurrence IDs and durable per-sink delivery records; v5 adds random lease
tokens that fence delivery completion and repairs legacy status ordering during
migration. The Federal Register
seen-set is capped at 300 entries, and feed keys at 500 per source.

Fetching is serial in this build; no configuration option implies otherwise.

Alongside the state snapshot, each poll records its findings to an observation
log (segmented compressed JSONL), giving a queryable history of what changed and when. The
`export` subcommand projects that log and the current state into (ZSTD-coded)
Parquet tables for analysis, see [Reading the data](#reading-the-data)
below and [`docs/data-export.md`](docs/data-export.md).
Immutable per-run segments are published through an atomic manifest and compact
to the newest 100,000 rows by default.

## Build

Requires Zig 0.16.0 or newer.

    zig build              # produces zig-out/bin/fable-monitor
    zig build run          # build and run once
    zig build test         # run unit tests
    zig build check        # type-check without producing a binary

### Task runner (just)

A [`justfile`](justfile) wraps the common workflows so you don't have to
remember the underlying commands (or the convention of running against a
throwaway state file). It is optional, `just` is a language-agnostic command
runner layered on top of `zig build`, not a replacement for it. Install with
`brew install just`, then:

    just              # list all recipes
    just test         # run unit tests
    just ci           # full local CI parity gate (run this before pushing)
    just demo         # baseline run + no-change run, against a temp state file
    just run          # one real poll against a throwaway state file
    just export       # write Parquet tables to ./parquet
    just clean        # remove build artifacts and demo state

## Commands

The mode is selected by the first argument (default `poll`):

| Command | Does |
|---|---|
| `poll` (default) | One poll pass over the due sources. |
| `preflight [--json]` | Verify config, deps, writable state/log/outbox paths, disk, source egress/schema, coverage, and sink/secret configuration. JSON uses schema `fable-monitor.preflight/1`. |
| `audit` | Each source's last successful fetch/change plus pending/failed delivery totals. |
| `ack <event_id>` | Acknowledge a fired alert so it stops escalating. |
| `delivery list` | Inspect durable per-sink delivery status and errors. |
| `delivery retry [event_id\|occurrence_id]` | Force pending delivery retries, optionally filtered. |
| `state inspect` | Print payload-free state status/version/line diagnostic as JSON. |
| `state recover` | Validate and restore `<state>.backup`, quarantine the active generation, and print the result as JSON. |
| `state rebaseline` | Quarantine the active generation, record recovery audit metadata, and intentionally leave state absent. |
| `view` / `log` | Read the observation log as a formatted table (see below). |
| `log compact [max_events]` | Force compaction and retain the newest rows. |
| `log recover` | Validate the logical log through its manifest backup, then restore the primary manifest. |
| `export [out_dir]` | Project the log + state into Parquet tables. |
| `serve [port]` | Serve the read-only local-asset web dashboard over the log + state. See [Web UI](#web-ui). |
| `banner [text] [height]` | Render text as a TrueType terminal banner. |

## Quickstart

```sh
zig build
./zig-out/bin/fable-monitor preflight --json   # automation-friendly readiness checks
just demo-restore                               # offline fixture replay: baseline (silent) then a tier-1 trip
```

Automation output is one JSON object. Representative shapes:

```json
{"schema":"fable-monitor.preflight/1","ok":true,"checks":[{"name":"sources_config","category":"config","status":"pass","source_id":"","detail":"embedded default"}]}
{"status":"valid","version":5,"diagnostic":{"line":0,"reason":"none"}}
{"action":"recover_backup","quarantine_path":"state.zst.corrupt.123","backup_path":"state.zst.backup","restored_version":5}
```

The latter two come from `state inspect` and `state recover`; `state rebaseline`
uses action `rebaseline`, a null backup path, and the quarantine path when an
active generation existed. State diagnostics never include record payloads.

`just demo-restore` replays bundled fixtures (`FABLE_MONITOR_FIXTURES`) against a
throwaway state file: the baseline run is silent, then the restored fixtures fire
a tier-1 trip. On a trip the monitor emits a single-line structured JSON event to
stdout (schema `fable-monitor.event/1`):

```json
{"schema":"fable-monitor.event/1","event_id":"model_present:claude-fable-5",
 "occurrence_id":"occ-0123456789abcdef-1782396189000-initial",
 "idempotency_key":"occ-0123456789abcdef-1782396189000-initial",
 "kind":"restoration","tier":1,"confidence":"high","escalation":false,
 "corroborating_sources":["anthropic_model_list","anthropic_pricing"],
 "detected_at":"2026-06-28T14:03:09Z","epoch_ms":1782396189000,
 "title":"Model claude-fable-5 present in public listing",
 "evidence_url":"https://platform.claude.com/docs/en/about-claude/models/overview","document_number":"",
 "detail":"detector=2; hash=...; excerpt=claude-fable-5"}
```

The event is queued for stdout and, when configured, the event-sink file,
webhook, and high-confidence notify hook. Every configured sink is required.
Failures remain in state v5 and retry with bounded exponential backoff. A random
lease token prevents a late worker from overwriting a newer claimant's result.
Delivery
is at least once across a crash; consumers must deduplicate on `occurrence_id`
(also sent as `idempotency_key` and the webhook `Idempotency-Key` header).

## Run

    ./zig-out/bin/fable-monitor

Diagnostics (and a one-line per-run metrics summary) go to stderr (prefixed
`[fable-monitor]`); structured events and alerts go to stdout. On first run,
transition/feed/watch sources establish baselines; current Federal Register
documents are evaluated as new. Later runs stay quiet until something shifts.

### Environment variables

The most common (the full reference is in
[`docs/deployment.md`](docs/deployment.md)):

- `FABLE_MONITOR_STATE` / `FABLE_MONITOR_LOG`: absolute paths to the state file
  and observation log. Set both explicitly under a scheduler.
- `FABLE_MONITOR_SOURCES`: external JSON source config (overrides the embedded
  default). `FABLE_MONITOR_ONLY` / `FABLE_MONITOR_DISABLE` toggle sources by id.
- `FABLE_MONITOR_WEBHOOK` / `FABLE_MONITOR_EVENT_SINK`: extra sinks for the
  structured event, beyond stdout.
- `FABLE_MONITOR_HEARTBEAT_URL`: dead-man's-switch ping (healthchecks.io style),
  sent only after a healthy run.
- `FABLE_MONITOR_FAST_INTERVAL` / `FABLE_MONITOR_LOOP` / `FABLE_MONITOR_FORCE`:
  cadence controls.
- `FABLE_MONITOR_REQUIRED_SOURCES`: comma-separated enabled decisive source IDs
  that must remain fresh; `FABLE_MONITOR_MIN_DECISIVE_SOURCES` defaults to `1`.
- `FABLE_MONITOR_LOOP_MAX_FAILURES`: consecutive loop failures before exit
  (default `3`).
- `FABLE_MONITOR_MAX_EVENTS`: newest observation rows retained by automatic
  compaction (default `100000`).
- `FABLE_MONITOR_ESCALATE_AFTER`: seconds before an unacknowledged
  high-confidence alert re-fires once (default 3600).

Empty environment values are treated as unset. Boolean controls accept only
`1` or `0`; interval, count, and port controls reject malformed or zero values.
`ANTHROPIC_API_KEY` enables the authenticated API source but is never persisted
by either installer.

`FABLE_MONITOR_NOTIFY` is an optional shell command run on high-confidence trips
and escalations. The alert text is passed as the positional parameter `$1`, so
it is safe against shell injection. Example for macOS using terminal-notifier:

    export FABLE_MONITOR_NOTIFY='terminal-notifier -title "fable-monitor" -message "$1"'

Or with osascript and no extra install:

    export FABLE_MONITOR_NOTIFY='osascript -e '\''on run argv'\'' -e '\''display notification (item 1 of argv) with title "fable-monitor"'\'' -e '\''end run'\'' -- "$1"'

(The osascript form reads the message via `item 1 of argv` so the text is
passed as data, never spliced into AppleScript source.)

`FABLE_MONITOR_STATS`, if set, makes each run log a one-line peak-memory/CPU
summary (process + `curl`/`zstd` children) to stderr. Use `just measure` to
profile all subcommands; see [`docs/development.md`](docs/development.md) →
Resource usage.

## Reading the data

Every poll records what it found to the observation log (compressed JSONL), so
over time you accumulate a history of new Federal Register documents and
keyword-page changes. The quickest way to read it is the built-in formatted
reader. Use `view` for an at-a-glance dataview of recent activity, the last 90
days, newest-first, or `log` for the full history oldest-first:

    ./zig-out/bin/fable-monitor view                 # last 90 days, newest-first
    ./zig-out/bin/fable-monitor view --relevant       # only high-signal events
    ./zig-out/bin/fable-monitor view --days 30 --source fr_bis
    ./zig-out/bin/fable-monitor view --since 2026-03-25 --limit 50

    ./zig-out/bin/fable-monitor log                 # aligned, colorized table
    ./zig-out/bin/fable-monitor log --event changed  # filter by event kind
    ./zig-out/bin/fable-monitor log --source fr_bis --limit 20
    ./zig-out/bin/fable-monitor log --plain          # tab-separated, for grep/awk

Both readers share the same flags: `--source ID`, `--event KIND`, `--since DATE`,
`--days N`, `--relevant`, `--desc`/`--asc`, `--limit N`, `--width COLS`,
`--plain`, and `--color`/`--no-color`. `view` just defaults `--days 90 --desc`;
`log` defaults to the whole log ascending. Flags override either preset.

```
TIME              SOURCE        EVENT              REF         INFO
──────────────────────────────────────────────────────────────────────
2026-06-18 14:03  fr_anthropic  relevant_document  2026-12345  Export controls on Fable 5…
2026-06-18 15:30  bis_news      changed           ,           https://www.bis.gov/news-updates
```

The logical log can span `FABLE_MONITOR_LOG`, its `.manifest`,
`.manifest.backup`, and `.segments/` directory. Use `log`, `view`, or `export`;
decompressing only the legacy path can omit committed segments. If the primary
manifest is missing or corrupt, reads may use its validated backup, but appends
and compaction fail closed until `fable-monitor log recover` validates every
referenced component and restores the primary. Run `fable-monitor log compact
[max_events]` to force count-based retention.

Or export to Parquet for analytical tools:

    ./zig-out/bin/fable-monitor export            # writes ./parquet/
    ./zig-out/bin/fable-monitor export /tmp/out   # or a directory you choose

This reads the log and state files (no network) and writes `events.parquet`
(the full history), `state_seen.parquet`, and `state_keyword_hashes.parquet`.
The files are standard ZSTD-compressed Parquet, read by DuckDB, pandas/pyarrow,
Polars, etc.:

    duckdb -c "SELECT event, count(*) FROM 'parquet/events.parquet' GROUP BY event;"

The Parquet writer is implemented in std-only Zig; page compression is delegated
to the `zstd` binary. Schema, event kinds, and details are in
[`docs/data-export.md`](docs/data-export.md).

## Web UI

A read-only browser dashboard over the same log and state the CLI reads, the
poll status, configured sources, recent events, and any active alerts, with the
tier-1 restoration signal front and centre. Its dependency-free JavaScript and
CSS are vendored under `src/serve/` and embedded in the binary. It makes no CDN
requests and needs no front-end build step or `node_modules`.

Start it:

    just ui                                  # serves the installed agent's data on :8787
    just ui 9000                             # choose a port

    # or directly, pointing at whichever log/state you want to view:
    ./zig-out/bin/fable-monitor serve        # default port 8787
    ./zig-out/bin/fable-monitor serve 9000   # positional port
    FABLE_MONITOR_PORT=9000 ./zig-out/bin/fable-monitor serve

Then open **http://127.0.0.1:8787** (or your chosen port) in a browser.

How it connects: the server binds **127.0.0.1 only** and serves the page shell at
`/`. The local browser script polls small HTML fragment endpoints and swaps them
into the page on an interval, with no manual refresh:

| Endpoint | Refresh | Shows |
|---|---|---|
| `GET /` | — | The page shell; all executable/style assets are embedded locally. |
| `GET /ui/status` | 5s | Stat cards: source count, events logged, active alerts, last observed time. |
| `GET /ui/alerts` | 5s | Active (unacknowledged) alerts with tier, kind, and first-alerted time. |
| `GET /ui/sources` | 30s | Every configured source with its tier, kind, poll class, and last success / change. |
| `GET /ui/events?limit=N` | 10s | The most recent `N` events (default 30), newest first. |
| `GET /healthz` | — | Plaintext `ok` for liveness checks. |
| `GET /readyz` | — | `200 ready` only when state is readable, decisive coverage is fresh, and no delivery is overdue; otherwise `503`. |

Which data it reads is controlled by the same `FABLE_MONITOR_LOG` and
`FABLE_MONITOR_STATE` paths as every other command (see [Environment
variables](#environment-variables)); `just ui` points them at the installed
agent under `~/Library/Application Support/fable-monitor/`. The server is
**read-only** — it never writes the log or state — so it is safe to leave running
alongside the scheduled poller that owns those files. It renders each request
from a fresh arena and escapes all dynamic text. Because it binds loopback only,
expose it beyond your machine with an SSH tunnel or a reverse proxy you control
rather than changing the bind address.

The same-origin article reader is **disabled by default**. Setting
`FABLE_MONITOR_READER=1` enables on-demand fetching only for recorded public
HTTPS URLs on recorded source hosts, port 443 only. It rejects credentials,
private/literal special-use addresses, and redirects, caps responses at 16 MiB,
and uses a 15-second curl timeout. Validated DNS answers are pinned into curl;
accepted client sockets still lack request/header deadlines, so do not expose
it as a general proxy.

## Banner

A bit of flourish for the tool's namesake, render `FABLE` (or any text) as a
terminal banner drawn with the bundled blackletter TrueType font:

    ./zig-out/bin/fable-monitor banner            # FABLE at the default size
    ./zig-out/bin/fable-monitor banner "FABLE 5"  # arbitrary text
    ./zig-out/bin/fable-monitor banner FABLE 16   # custom height (pixel rows)

The TrueType outlines are parsed and rasterized from scratch (no font/graphics
dependency) and printed as Unicode half-blocks; the font is embedded in the
binary, so `banner` needs no network, files, `curl`, or `zstd`. Details are in
[`docs/banner.md`](docs/banner.md).

## Run it in the background (macOS launchd)

The intended use: a scheduled agent that polls in the background and notifies you
on a relevant change. An installer scripts the whole thing, it builds a release
binary, stages it (and its state/log) under
`~/Library/Application Support/fable-monitor/`, generates a LaunchAgent, and
loads it:

    just install            # or: bash dist/install.sh
    just status             # is it loaded? last exit code?
    just log                # read the agent's collected history (formatted table)
    just logs               # tail alert (stdout) + diagnostic (stderr) logs
    just uninstall          # stop and remove

(The binary is staged under Application Support, not run from this checkout,
because macOS TCC-protects `~/Desktop`/`~/Documents`/`~/Downloads`, a background
agent can't satisfy the consent prompt there and would hang at launch.)

It polls every 60 seconds (and once immediately) — conditional requests keep
the fast cadence cheap, and the in-binary due-cadence still holds tier-2/3
sources to their slower intervals. Change it with `FABLE_INTERVAL` (seconds):

    FABLE_INTERVAL=1800 just install     # every 30 minutes

Notifications fire only on high-confidence trips and escalations. The installer uses
[`terminal-notifier`](https://github.com/julienXX/terminal-notifier) if present
(more reliable from a background agent, `brew install terminal-notifier`),
otherwise the built-in `osascript`; macOS may ask you to allow notifications the
first time. To preview the generated agent without installing: `just
install-preview`. The plist at `dist/io.zerocreativity.fable-monitor.plist` is a
hand-editable reference; `just install` generates the real one for you.

### Run it on Linux / Zo.computer (systemd or cron)

`dist/install-linux.sh` installs a recurring job on Linux, parameterized by
scheduler (auto-detect; `SCHEDULER=systemd|cron|zo`). It builds a ReleaseSafe
binary, stages it and durable state under `FABLE_HOME` (default
`~/.local/share/fable-monitor`; point it at a persistent volume on Zo), writes a
`0600` env file sourcing secrets from the environment, runs `preflight`, and
registers a systemd user timer or a crontab entry:

    just install-linux            # or: bash dist/install-linux.sh
    just install-linux-preview    # bash dist/install-linux.sh --dry-run
    just uninstall-linux

See [`docs/deployment.md`](docs/deployment.md) for the env-var reference and the
dead-man's-switch heartbeat.

## Tuning

The source list is a JSON config: the embedded default lives in
`src/sources_default.json`, and `FABLE_MONITOR_SOURCES` points at an external
file to override it without rebuilding. Each source carries an `id`, `kind`,
`tier`, `url`, `match` set, and cadence; toggle sources at runtime with
`FABLE_MONITOR_ONLY` / `FABLE_MONITOR_DISABLE`. The Federal Register queries are
just URL query strings (filterable by agency, date, document type, and full-text
term). Keyword and restoration vocabularies live in `src/sources.zig`. See
[`docs/sources.md`](docs/sources.md).

## Documentation

This README is the quick-start. Deeper technical documentation lives in
[`docs/`](docs/):

- [`docs/architecture.md`](docs/architecture.md), components, data flow, and the run lifecycle.
- [`docs/design-decisions.md`](docs/design-decisions.md), why the tool is built the way it is (curl, single JSON state, fingerprinting, …).
- [`docs/sources.md`](docs/sources.md), the watched sources and how to add or tune one.
- [`docs/state-format.md`](docs/state-format.md), the state file schema and lifecycle.
- [`docs/data-export.md`](docs/data-export.md), the observation log and the `export` subcommand (NDJSON → Parquet).
- [`docs/ui.md`](docs/ui.md), the `serve` subcommand: the read-only local-asset web dashboard and secure reader boundary.
- [`docs/banner.md`](docs/banner.md), the `banner` subcommand (renders text with the bundled TrueType font).
- [`docs/deployment.md`](docs/deployment.md), running under launchd/cron, env vars, and the notify hook.
- [`docs/development.md`](docs/development.md), building, testing, and the documentation-maintenance policy.
- [`docs/operations.md`](docs/operations.md), SLOs, backup/restore, incidents, and retention.
- [`docs/security.md`](docs/security.md), trust boundaries and deployment/supply-chain controls.
- [`docs/release.md`](docs/release.md), baseline-CPU releases, verification, and rollback.

## Security

To report a suspected vulnerability, see [`SECURITY.md`](SECURITY.md), which
summarizes the private reporting channel, response targets, and coordinated
disclosure. The full vulnerability-reporting and support policy lives in
[`docs/security-support.md`](docs/security-support.md).

See [`docs/README.md`](docs/README.md) for the index and the policy that keeps
these documents current.

## License

fable-monitor's **code** is released under the MIT License. See
[`LICENSE`](LICENSE) for the full text.

The **bundled font** used by `banner`
(`src/assets/ManufacturingConsent-Regular.ttf`, *Manufacturing Consent*) is a
separate work licensed under the SIL Open Font License 1.1, included at
[`src/assets/OFL.txt`](src/assets/OFL.txt).
