# Architecture

Last reviewed: 2026-06-28 · against fable-monitor 0.1.0 (feat/tiered-monitor)

`fable-monitor` is a single-binary CLI with one job: detect when an official
source says something new about the export-control status of Anthropic's
Fable 5 / Mythos 5 models, and emit a verified, low-latency signal. It is
deliberately small. The code is split into focused modules under `src/`:

- `main.zig`: CLI entrypoint. Argument/subcommand dispatch, environment wiring
  (building `poll.Options` from the `FABLE_MONITOR_*` vars), the optional
  internal loop, and the test root. The poll orchestration now lives in
  `poll.zig`, not here.
- `poll.zig`: the poll orchestrator. `run` (one poll), the per-kind detectors,
  signal coalescing / trip resolution, structured-event emission, and the
  `preflight` / `audit` / `acknowledge` subcommand entry points.
- `config.zig`: `Config` and `load`, which parse the JSON source config
  (embedded default or `FABLE_MONITOR_SOURCES`) into `Source` values and apply
  the enable/disable overrides.
- `context.zig`: the shared `Context` type threaded through a run, plus `log`.
- `sources.zig`: `Source`, `SourceKind`, `Tier`, `PollClass`, and the keyword /
  restoration / model-id / strong-term vocabularies. No hard-coded source list.
- `fetch.zig`: `fetchConditional`, `postJson`, `pingHeartbeat`, and
  `toolAvailable` (network I/O via curl).
- `feed.zig`: a small RSS / Atom / sitemap extractor (`parse` produces entries
  with a stable key, title, and publication timestamp).
- `html.zig`: `normalizeHtml`, `extractKeywordContext`, `containsAny`
  (pure text helpers).
- `state.zig`: `State`, `StateRecord`, `loadState`, `saveState`, `capTail`
  (the v2 record kinds).
- `events.zig`: `Event`, the event-kind constants, `isoUtc`, `epochMsFromIso`,
  `appendLog`.
- `zstd.zig`: `compress` / `decompress` / `compressor` (zstd helpers).
- `export.zig`: `exportParquet`, `exportEvents`, `exportState`.
- `view.zig`: the `log` / `view` subcommands, a formatted, colorized terminal
  reader for the observation log.
- `parquet.zig`: the standalone, std-only Parquet encoder.
- `banner.zig`: a from-scratch TrueType rasterizer for the `banner` subcommand
  (embeds the bundled font from `src/assets/`).

Modules avoid import cycles by keeping `Context` in its own module
(`context.zig`, which only depends on `events.zig` for the `Event` type and
never imports the concern modules back) and by having the lower-level helpers
take primitives rather than `*Context`, `events.appendLog` and the `zstd.*`
functions take `io`/`arena` directly. `poll.zig` keeps its runtime knobs in a
`poll.Options` struct populated by `main`, so it never reads the environment
directly and is unit-testable with explicit options.

## The governing idea: one run = one poll

The tool is **not** a long-running daemon. Each invocation does exactly one pass
over the sources and then exits. Recurring execution is the scheduler's job
(launchd or cron, see [deployment.md](deployment.md)). This keeps the process
model trivial: no event loop, no timers, no in-memory state to corrupt, and a
crash affects at most one poll. Continuity across runs comes entirely from a
small JSON state file (see [state-format.md](state-format.md)).

## Subcommands

The mode is selected by `argv[1]` (default `poll`):

- **(default) / `poll`**: one poll pass over the due sources, described below.
- **`preflight`**: verify the runtime is ready before scheduling (the `curl`
  and `zstd` binaries, write access to the state path, per-source network
  egress, and the presence of the optional secrets: webhook / heartbeat /
  notify). Prints one summary; returns an error on a hard failure.
- **`audit`**: print each source's last successful fetch and last detected
  change (from the `status` state records), to catch a quietly dead source.
  Reads state only.
- **`ack <event_id>`**: mark a fired alert acknowledged so it stops escalating.
- **`log [filters]`** / **`view [filters]`**: print the observation log as a
  formatted table (reads + decompresses it, no network). `view` is a dataview
  preset over the same reader (last 90 days, newest-first). See
  [data-export.md](data-export.md).
- **`export [out_dir]`**: no network; project the observation log and state
  file into Parquet tables. See [data-export.md](data-export.md).
- **`banner [text] [height]`**: print text (default `FABLE`) as a TrueType
  banner. Self-contained (no network/files/compression), so it is dispatched
  before the `zstd`/`curl` preflights. See [banner.md](banner.md).

## Run lifecycle (poll)

`main` builds the `Context` and `poll.Options` from the environment, runs the
`zstd` (and, for a poll, `curl`) preflight, then calls `poll.run(&ctx, opts)`.
That function is the pipeline: **fetch -> detect -> coalesce -> trip -> emit.**

1. **Load config + state.** `config.load` parses the source config (embedded
   default or `FABLE_MONITOR_SOURCES`) and applies the ONLY / DISABLE overrides;
   `state.loadState` reads the previous state. A missing/unreadable state file is
   non-fatal: the run starts fresh (first-run / baseline behavior). The
   cumulative sets and alert bookkeeping are carried forward.
2. **Select due sources.** Each enabled source is polled only if it is *due* this
   tick: tier-1 (`fast`) sources on the `fast_interval`, tier-2/3 (`slow`) on
   `slow_interval_s`, gated by the per-source `last_poll_ms` in state. A source
   that is not due has its prior per-source records carried forward unchanged. A
   fixture run or `FABLE_MONITOR_FORCE=1` polls everything.
3. **Fetch.** Each due source is fetched with a conditional request carrying its
   persisted ETag / Last-Modified (or read from a fixture file in test mode),
   timed, and wrapped in its own error handler so one failure never aborts the
   poll. A 304 keeps the prior content records and records nothing new.
4. **Detect.** Dispatch on `SourceKind` to a detector (model-list probe,
   statement/keyword watch, Federal Register, feed, market). Detectors append
   `Event` rows to the audit accumulator and emit trip **`Signal`s**.
5. **Coalesce + decide confidence.** `resolveTrips` groups signals by a
   normalized **event identity**, so one real event seen by several sources
   yields one alert listing all corroborating sources. A tier-2/3 advisory is
   promoted to high confidence when corroborated by a second distinct source on
   the same identity (or by an inherently-high tier-1 signal).
6. **Trip + emit (idempotent).** For each new identity, emit one structured JSON
   event to stdout (and the optional sink file / webhook), fire the notify hook
   for high-confidence trips, and record an `alert` so the same persisting change
   does not re-fire. An unacknowledged high-confidence alert re-fires once after
   `FABLE_MONITOR_ESCALATE_AFTER` seconds. Escalation is intentionally
   **once-per-alert**: a single re-fire, then silence until `ack` — a monitor
   that keeps nagging trains its operator to ignore it.
7. **Persist + log + heartbeat.** Save the merged state (FR seen-set capped at
   300, feed seen-set at 500), append this run's events to the observation log,
   print the per-run metrics line, and ping `FABLE_MONITOR_HEARTBEAT_URL` after a
   clean run (the dead-man's switch).

## Components

```
        ┌──────────────────────────────────────────────────────────┐
        │                          main()                           │
        │   env → Context + poll.Options → preflight(zstd/curl)      │
        └───────────────────────────────┬──────────────────────────┘
                                         ▼  poll.run()
        config.load → state.loadState → select DUE sources
                                         │ for each due Source
                                         ▼
                         fetchConditional (curl) / fixture
                                         │  dispatch on SourceKind
              ┌──────────────┬───────────┴──────────┬──────────────┐
              ▼              ▼                       ▼              ▼
   detectModelList   detectKeywordOrStatement  detectFederalReg  detectFeed
   (absent→present)  (fingerprint + restore)   (new doc + filter) (feed.parse)
              │              │                       │              │  detectMarket
              └──────────────┴───────────┬───────────┴──────────────┘
                                         ▼  Signals
                          resolveTrips: coalesce by identity,
                          promote on corroboration, alert-once
                                         ▼
                  emitStructured → stdout + sink + webhook
                  notify (high-confidence) → sh -c
                  save state · append log · heartbeat
```

### Fetching: `fetch.fetchConditional` / `postJson` / `pingHeartbeat`

All network I/O is delegated to the system `curl` binary via `std.process.run`
(in `fetch.zig`). `fetchConditional` sends `If-None-Match` / `If-Modified-Since`
from the persisted validators so an unchanged source returns 304 cheaply, honors
`429`/`Retry-After` with a capped backoff, and reports the new validators plus a
per-fetch latency. `postJson` POSTs a structured event to the webhook;
`pingHeartbeat` hits the dead-man's-switch URL. `toolAvailable(ctx, name)` is the
shared `<name> --version` preflight used for both `curl` and `zstd`. Rationale in
[design-decisions.md](design-decisions.md).

> **Serial in this build, concurrency reserved.** The config carries a
> `concurrency` field, but this build fetches sources serially, logging
> per-source and total wall-clock latency. Parallel fetch is reserved for a
> future build; nothing in the pipeline depends on it.

### Detectors (`poll.zig`)

- **`detectModelList`** (tier-1, decisive). Normalizes the listing text and
  checks each model id for presence. An **absent-to-present** transition (the id
  was not present on a prior poll and now is) emits a high-confidence
  `restoration` signal keyed `model_present:<id>`. The first poll of a source is
  a baseline and never trips.
- **`detectKeywordOrStatement`.** Shared fingerprint path for `keyword_watch`
  (tier-2/3) and `statement_watch` (tier-1): `extractKeywordContext` keeps a
  ±100-byte window around each `match` hit, sorts and de-duplicates the windows,
  and Wyhashes them. A changed hash on the statement page whose new context
  contains restoration vocabulary is a high-confidence trip
  (`statement_restored`); any other change is advisory.
- **`detectFederalRegister`** (tier-2). Parses the FR / public-inspection JSON
  into a minimal projection (`ignore_unknown_fields = true`), records each new
  document number, and applies the tightened relevance filter (title + abstract
  against the strong terms). Relevant docs emit an advisory keyed `fr_doc:<num>`,
  so the same document on multiple FR feeds coalesces.
- **`detectFeed`** (tier-3). `feed.parse` extracts RSS/Atom/sitemap entries by
  stable key; the first poll baselines the backlog without alerting, then new
  matching entries emit advisories keyed `feed:<key>`.
- **`detectMarket`** (tier-3). Records the last price and emits an advisory on a
  `>= 0.10` move (`market:<id>`), a coverage-gap signal only.

### Emitting: `emitStructured` / `notify`

The integration point. `resolveTrips` emits exactly one structured JSON event per
new identity to stdout always (schema `fable-monitor.event/1`), plus the optional
`FABLE_MONITOR_EVENT_SINK` append-file and `FABLE_MONITOR_WEBHOOK` POST. The
portable `FABLE_MONITOR_NOTIFY` hook fires for high-confidence trips and
escalations, invoked as `sh -c <cmd> fable-monitor <message>` so the alert text
arrives as `$1` (injection-safe). The monitor's responsibility ends at emitting
the verified signal; any trading/execution system consumes the event in a
separate process.

### Compression, `zstd.compress` / `zstd.decompress` / `zstd.compressor`

Every persisted file (state, log, Parquet pages) is zstd-compressed. Zig's std
has no zstd compressor, so all compression *and* decompression run through the
system `zstd` binary: an internal `zstdFilter` stages the input in a temp file
(since `std.process.run` can't feed stdin), runs `zstd` over it, and returns the
captured stdout. The public `zstd.compress` / `zstd.decompress` helpers take
primitives (`io`, `arena`) rather than the `Context`, and `zstd.compressor`
builds the `parquet.Compressor` thunk used by the export path. See
[design-decisions.md](design-decisions.md) entry 11.

### History & export, `events.appendLog` / `export.exportParquet` / `src/parquet.zig`

Alerts are ephemeral (stdout); the history of findings is durable. As each
source alerts it also calls `ctx.record(...)`, building a list of `Event`
structs stamped with the run's timestamp. After state is saved,
`events.appendLog` decompresses the existing log (`FABLE_MONITOR_LOG`), appends
this run's events as JSONL, recompresses, and rewrites it.

The `export` subcommand (`export.exportParquet`) is the read side: it decompresses and
parses the JSONL log and state file and emits Parquet tables via the encoder in
`src/parquet.zig`, which is handed a zstd-backed `Compressor` so pages are
ZSTD-coded. Inputs are independent, a missing log or state file is skipped, not
fatal. Full details and schema are in [data-export.md](data-export.md).

## Memory model

Everything allocates from a single arena (`init.arena`) that lives for the whole
process and is released on exit. Because a run is short and bounded, there is no
per-source free; the arena is freed wholesale when the process ends. This is a
deliberate simplification that the one-run-one-poll model makes safe.

## Output streams

- **stdout**, alerts (the signal a human or downstream tool consumes).
- **stderr**, diagnostics, every line prefixed `[fable-monitor]` (via `log`).

Keeping alerts and diagnostics on separate streams means you can pipe alerts
somewhere while still seeing operational logs.

## What this design intentionally does *not* do

- No daemon by default; recurrence is the scheduler's job (launchd/systemd/cron).
  The optional `FABLE_MONITOR_LOOP=<seconds>` internal loop is a convenience for
  environments without a sub-minute scheduler, not a long-lived service model.
- No database (compressed JSONL files are enough).
- No HTTP/TLS stack of its own (delegated to curl).
- No in-process compression (delegated to the zstd binary; std has no encoder).
- No diff of *what* changed on a watched page (only that it changed).
- No parallel fetch in this build (the `concurrency` field is reserved).
- No model in the decisive path: the optional classifier-confirmation sidecar is
  designed but deferred and never gates a tier-1 trip (see [sources.md](sources.md)).

These are conscious trade-offs; see [design-decisions.md](design-decisions.md).
