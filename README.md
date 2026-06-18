# fable-monitor

Zig 0.16 command-line tool that polls official sources for changes to
the US government export-control status of Anthropic's Fable 5 and Mythos 5
models, and alerts when something moves.

It is built to run as a scheduled job (launchd or cron). Each invocation is one
poll: it fetches each source, diffs against the previous run's state, prints any
changes to stdout, optionally fires a notification hook, and persists updated
state.

## What it watches

Two classes of source:

1. Federal Register JSON API (the reliable signal). Two feeds are polled: every
   document whose full text matches the term "Anthropic", and every rule from
   the Bureau of Industry and Security (BIS), the agency that issued the
   directive. New document numbers are reported; documents whose title contains
   a watched keyword (fable, mythos, anthropic) are tagged `[RELEVANT]`.

2. HTML keyword watchers (best effort). The Anthropic newsroom and the BIS news
   page are fetched, reduced to a normalized fingerprint of the text near each
   watched keyword, and diffed. These catch announcements that never reach the
   Federal Register, but they are inherently noisier than the structured feeds.

The most likely "Fable is back" signal is an Anthropic newsroom change followed
by a Federal Register action, so weight the structured feeds highest.

## Design notes

The tool is std-only Zig with two external binaries: `curl` for fetching, and
`zstd` for compressing its outputs. Delegating to these sidesteps the churn in
Zig's in-tree TLS/HTTP client and the fact that std ships no zstd *compressor*,
and both binaries are widely available. Everything else (JSON parsing,
normalization, hashing, state, and a from-scratch Parquet writer) is standard
library.

State is a single file — zstd-compressed line-delimited JSON. The Federal
Register seen-set is capped at the most recent 200 document numbers so it does
not grow without bound.

Alongside the state snapshot, each poll records its findings to an observation
log (compressed JSONL), giving a queryable history of what changed and when. The
`export` subcommand projects that log and the current state into (ZSTD-coded)
Parquet tables for analysis — see [Reading the data](#reading-the-data)
below and [`docs/data-export.md`](docs/data-export.md).

## Build

Requires Zig 0.16.0 or newer.

    zig build              # produces zig-out/bin/fable-monitor
    zig build run          # build and run once
    zig build test         # run unit tests
    zig build check        # type-check without producing a binary

### Task runner (just)

A [`justfile`](justfile) wraps the common workflows so you don't have to
remember the underlying commands (or the convention of running against a
throwaway state file). It is optional — `just` is a language-agnostic command
runner layered on top of `zig build`, not a replacement for it. Install with
`brew install just`, then:

    just              # list all recipes
    just test         # run unit tests
    just ci           # fmt-check + test + build (run this before pushing)
    just demo         # baseline run + no-change run, against a temp state file
    just run          # one real poll against a throwaway state file
    just export       # write Parquet tables to ./parquet
    just clean        # remove build artifacts and demo state

## Run

    ./zig-out/bin/fable-monitor

Diagnostics go to stderr (prefixed `[fable-monitor]`); alerts go to stdout. On
the first run every source records a baseline and reports no changes on
subsequent runs until something actually shifts.

### Environment variables

`FABLE_MONITOR_STATE` sets the state file path. Defaults to
`fable_monitor_state.jsonl.zst` in the working directory. Use an absolute path
when running under a scheduler.

`FABLE_MONITOR_LOG` sets the observation-log path. Defaults to
`fable_monitor_events.jsonl.zst` in the working directory. Each poll records its
findings here (zstd-compressed JSONL); this is the history the `export`
subcommand reads. Use an absolute path under a scheduler.

`FABLE_MONITOR_NOTIFY` is an optional shell command run on high-signal alerts
(relevant Federal Register documents and page changes). The alert text is passed
as the positional parameter `$1`, so it is safe against shell injection. Example
for macOS using terminal-notifier:

    export FABLE_MONITOR_NOTIFY='terminal-notifier -title "fable-monitor" -message "$1"'

Or with osascript and no extra install:

    export FABLE_MONITOR_NOTIFY='osascript -e "display notification \"$1\" with title \"fable-monitor\""'

`FABLE_MONITOR_STATS`, if set, makes each run log a one-line peak-memory/CPU
summary (process + `curl`/`zstd` children) to stderr. Use `just measure` to
profile all subcommands; see [`docs/development.md`](docs/development.md) →
Resource usage.

## Reading the data

Every poll records what it found to the observation log (compressed JSONL), so
over time you accumulate a history of new Federal Register documents and
keyword-page changes. The quickest way to read it is the built-in formatted
reader:

    ./zig-out/bin/fable-monitor log                 # aligned, colorized table
    ./zig-out/bin/fable-monitor log --event changed  # filter by event kind
    ./zig-out/bin/fable-monitor log --source fr_bis --limit 20
    ./zig-out/bin/fable-monitor log --plain          # tab-separated, for grep/awk

```
TIME              SOURCE        EVENT              REF         INFO
──────────────────────────────────────────────────────────────────────
2026-06-18 14:03  fr_anthropic  relevant_document  2026-12345  Export controls on Fable 5…
2026-06-18 15:30  bis_news      changed            —           https://www.bis.gov/news-updates
```

You can also read the raw log directly by decompressing:

    zstd -dc fable_monitor_events.jsonl.zst | jq .

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

## Banner

A bit of flourish for the tool's namesake — render `FABLE` (or any text) as a
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
on a relevant change. An installer scripts the whole thing — it builds a release
binary, stages it (and its state/log) under
`~/Library/Application Support/fable-monitor/`, generates a LaunchAgent, and
loads it:

    just install            # or: bash dist/install.sh
    just status             # is it loaded? last exit code?
    just log                # read the agent's collected history (formatted table)
    just logs               # tail alert (stdout) + diagnostic (stderr) logs
    just uninstall          # stop and remove

(The binary is staged under Application Support, not run from this checkout,
because macOS TCC-protects `~/Desktop`/`~/Documents`/`~/Downloads` — a background
agent can't satisfy the consent prompt there and would hang at launch.)

It polls every 30 minutes (and once immediately). Change the cadence with
`FABLE_INTERVAL` (seconds):

    FABLE_INTERVAL=600 just install      # every 10 minutes

Notifications fire only on high-signal alerts (a `[RELEVANT]` Federal Register
document or a watched-page change). The installer uses
[`terminal-notifier`](https://github.com/julienXX/terminal-notifier) if present
(more reliable from a background agent — `brew install terminal-notifier`),
otherwise the built-in `osascript`; macOS may ask you to allow notifications the
first time. To preview the generated agent without installing: `just
install-preview`. The plist at `dist/io.zerocreativity.fable-monitor.plist` is a
hand-editable reference; `just install` generates the real one for you.

## Tuning

The source list, keywords, and per-source keyword overrides live in
`src/sources.zig`. The Federal Register queries can be tightened or broadened by
editing their query strings (the API supports filtering by agency, date,
document type, and full-text term).

## Documentation

This README is the quick-start. Deeper technical documentation lives in
[`docs/`](docs/):

- [`docs/architecture.md`](docs/architecture.md) — components, data flow, and the run lifecycle.
- [`docs/design-decisions.md`](docs/design-decisions.md) — why the tool is built the way it is (curl, single JSON state, fingerprinting, …).
- [`docs/sources.md`](docs/sources.md) — the watched sources and how to add or tune one.
- [`docs/state-format.md`](docs/state-format.md) — the state file schema and lifecycle.
- [`docs/data-export.md`](docs/data-export.md) — the observation log and the `export` subcommand (NDJSON → Parquet).
- [`docs/banner.md`](docs/banner.md) — the `banner` subcommand (renders text with the bundled TrueType font).
- [`docs/deployment.md`](docs/deployment.md) — running under launchd/cron, env vars, and the notify hook.
- [`docs/development.md`](docs/development.md) — building, testing, and the documentation-maintenance policy.

See [`docs/README.md`](docs/README.md) for the index and the policy that keeps
these documents current.

## License

fable-monitor's **code** is released under the MIT License. See
[`LICENSE`](LICENSE) for the full text.

The **bundled font** used by `banner`
(`src/assets/ManufacturingConsent-Regular.ttf`, *Manufacturing Consent*) is a
separate work licensed under the SIL Open Font License 1.1, included at
[`src/assets/OFL.txt`](src/assets/OFL.txt).
