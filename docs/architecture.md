# Architecture

Last reviewed: 2026-07-14 · against fable-monitor 0.1.0

`fable-monitor` is a single-binary CLI with one job: detect when an official
source says something new about the export-control status of Anthropic's
Fable 5 / Mythos 5 models, and emit a verified, low-latency signal. It is
deliberately small. The code is split into focused modules under `src/`:

- `main.zig`: CLI entrypoint. Argument/subcommand dispatch, environment wiring
  (building `poll.Options` from the `FABLE_MONITOR_*` vars), the optional
  internal loop, and the test root. The poll orchestration now lives in
  `poll.zig`, not here.
- `poll.zig`: the poll orchestrator. `run` (one poll), the per-kind detectors,
  signal coalescing / trip resolution, durable delivery, and the `preflight` /
  `audit` / `acknowledge` / delivery subcommand entry points.
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
- `state.zig`: state v5 parsing/commit, migration, locks, alerts, recovery, and
  lease-fenced delivery
  records.
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

The poll command is one-shot by default. Each invocation does exactly one pass
over the sources and then exits. Recurring execution is the scheduler's job
(launchd or cron, see [deployment.md](deployment.md)). This keeps the process
model trivial, and a crash affects at most one poll. `FABLE_MONITOR_LOOP` is an
optional long-lived mode with a fresh arena per tick and a consecutive-failure
exit threshold. Continuity across runs comes entirely from a
small JSON state file (see [state-format.md](state-format.md)).

## Subcommands

The mode is selected by `argv[1]` (default `poll`):

- **(default) / `poll`**: one poll pass over the due sources, described below.
- **`preflight [--json]`**: verify config, dependencies, writable state/log/
  outbox paths, disk, source egress/schema, decisive coverage, and sink/secret
  configuration. JSON uses `fable-monitor.preflight/1`; failed checks exit 1.
- **`audit`**: print each source's last successful fetch/change plus pending and
  failed delivery totals. Reads state only.
- **`ack <event_id>`**: mark a fired alert acknowledged so it stops escalating.
- **`delivery list` / `delivery retry [event_id|occurrence_id]`**: inspect or
  force retry of durable pending sink work.
- **`state inspect|recover|rebaseline`**: emit JSON state diagnostics or perform
  an explicit locked restore/rebaseline with quarantine and recovery audit.
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
That function is the pipeline: **fetch -> detect -> coalesce -> audit -> commit -> deliver.**

1. **Load config + state.** `config.load` parses the source config (embedded
   default or `FABLE_MONITOR_SOURCES`) and applies the ONLY / DISABLE overrides;
   `state.loadState` reads the previous state. Only `FileNotFound` means first
   run; corrupt, malformed, or future state fails the poll without overwriting
   the generation. Cumulative sets, alerts, and deliveries carry forward.
2. **Select due sources.** Each enabled source is polled only if it is *due* this
   tick: tier-1 (`fast`) sources on the `fast_interval`, tier-2/3 (`slow`) on
   `slow_interval_s`, gated by the per-source `last_poll_ms` in state. A source
   that is not due has its prior per-source records carried forward unchanged. A
   fixture run or `FABLE_MONITOR_FORCE=1` polls everything.
3. **Fetch.** Each due source is fetched with a conditional request carrying its
   persisted ETag / Last-Modified (or read from a fixture file in test mode),
   timed, and wrapped in its own error handler so another source can still run.
   A failed fetch preserves the previous baseline as unknown, never absence. A
   304 keeps prior content records and records nothing new.
4. **Detect.** Dispatch on `SourceKind` to a detector (model-list probe,
   statement/keyword watch, Federal Register, feed, market). Detectors append
   `Event` rows to the audit accumulator and emit trip **`Signal`s**.
5. **Coalesce + decide confidence.** `resolveTrips` groups signals by a
   normalized **event identity**, so one real event seen by several sources
   yields one alert listing all corroborating sources. A tier-2/3 advisory is
   promoted to high confidence when corroborated by a second distinct source on
   the same identity (or by an inherently-high tier-1 signal).
6. **Create occurrence + outbox.** `event_id` is the logical subject identity.
   A new active episode gets an immutable `occurrence_id`; escalation gets a
   second occurrence. Required delivery records are queued for stdout and every
   configured file/webhook/notify sink. The occurrence ID is the idempotency key.
7. **Audit + commit.** Append this run's observation events as a committed zstd
   frame first. Only after that succeeds, atomically save state v5, including all
   outbox records. This ordering prevents a log failure from advancing detector
   baselines past an unrecorded transition. Either failure makes the poll failed;
   no sink side effect starts before both commits.
8. **Deliver + classify.** Claim due records under the state lock, perform side
   effects outside it, and checkpoint each result. Failures retry with bounded
   exponential backoff and jitter. The outcome is `healthy` when decisive
   coverage is fresh and no source/heartbeat fails, `degraded` for a
   non-coverage source or heartbeat failure, and `failed` for inadequate
   coverage, persistence, or pending delivery. Only healthy runs ping success.

## Event identity and re-arm

`event_id` identifies the logical subject, such as
`model_present:claude-fable-5` or `statement_restored`. `occurrence_id` identifies
one immutable initial or escalation delivery occurrence and is the
deduplication key. Replays after a crash preserve it.

Model episodes re-arm only after at least one successful model-list/API source
observes the model absent across current successful observations. Statement
restoration re-arms only after a successful statement observation contains no
present restoration terms. Failed fetches do neither. Keyword, market, feed,
and Federal Register identities have no explicit absence-based re-arm: their
identities encode source/content/document keys and active alert records suppress
repeats. Settled alerts are pruned after 90 days; unresolved alerts are retained.

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
                          resolveTrips: coalesce by subject,
                          create occurrence + per-sink outbox
                                         ▼
                  append log → save state → claim/deliver/checkpoint
                  classify outcome → healthy-only heartbeat
```

### Fetching: `fetch.fetchConditional` / `postJson` / `pingHeartbeat`

All network I/O is delegated to the system `curl` binary via `std.process.run`
(in `fetch.zig`). `fetchConditional` sends `If-None-Match` / `If-Modified-Since`
from the persisted validators so an unchanged source returns 304 cheaply, honors
`429`/`Retry-After` with a capped backoff, and reports the new validators plus a
per-fetch latency. `postJson` POSTs a structured event to the webhook;
`pingHeartbeat` hits the dead-man's-switch URL. Webhook and heartbeat URLs are
placed in mode-0600 curl config files rather than process arguments; only 2xx is
success. `toolAvailable(ctx, name)` is the
shared `<name> --version` preflight used for both `curl` and `zstd`. Rationale in
[design-decisions.md](design-decisions.md).

> **Serial in this build.** Sources are fetched serially, logging per-source and
> total wall-clock latency. Nothing in the pipeline implies parallel fetching.

### Detectors (`poll.zig`)

- **`detectModelList`** (tier-1, decisive). Exact-matches typed `data[].id` for
  the API probe and boundary/negation-aware visible text for HTML probes. An
  **absent-to-present** transition (the id
  was not present on a prior poll and now is) emits a high-confidence
  `restoration` signal keyed `model_present:<id>`. The first poll of a source is
  a baseline and never trips.
- **`detectKeywordOrStatement`.** Shared fingerprint path for `keyword_watch`
  (tier-2/3) and `statement_watch` (tier-1): `extractKeywordContext` keeps a
  ±100-byte window around each `match` hit, sorts and de-duplicates the windows,
  and Wyhashes them. A changed hash on the statement page whose new context
  gains a non-negated restoration term near a controlled model reference is a
  high-confidence trip (`statement_restored`); any other change is advisory.
- **`detectFederalRegister`** (tier-2). Parses the FR / public-inspection JSON
  into a minimal projection (`ignore_unknown_fields = true`), records each new
  stage-qualified document key, and applies the tightened relevance filter (title + abstract
  against the strong terms). Relevant docs emit an advisory keyed
  `fr_doc:<stage>:<num>`,
  so preliminary and published records can be evaluated independently.
- **`detectFeed`** (tier-3). `feed.parse` extracts RSS/Atom/sitemap entries by
  stable key; the first poll baselines the backlog without alerting, then new
  matching entries emit advisories keyed `feed:<key>`.
- **`detectMarket`** (tier-3). Records the last price and emits an advisory on a
  `>= 0.10` move (`market:<id>`), a coverage-gap signal only.

### Delivering: state-v5 outbox

All configured sinks are required. Delivery is durable and at least once: a
crash after a sink accepts data but before checkpoint can replay the same
occurrence. The event-sink file deduplicates by occurrence, and webhooks receive
`Idempotency-Key`; stdout/notify consumers must deduplicate themselves. The
notify command receives remote-derived text as `$1`, not interpolated shell
source. Each claim gets a random lease token. Completion applies only when that
token still matches, so an expired claimant cannot overwrite a newer success.
On v4-to-v5 save, tokenless v4 leases are cleared rather than preserved as
unfenced claims.

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

Alert side effects are emitted from the durable outbox; the history of findings
is durable. As each
source alerts it also calls `ctx.record(...)`, building a list of `Event`
structs stamped with the run's timestamp. `events.appendLog` atomically commits
the audit batch before detector state advances; state v5 then commits outbox
work before delivery starts. A manifest selects the current compacted base and
active segments, so torn writes are never reader-visible. Reads may fall back to
a validated manifest backup, while append/compaction require explicit `log
recover` first. Automatic retention and `log compact` rewrite the newest
configured number of events as a new base generation before atomically switching
that manifest.

The `export` subcommand (`export.exportParquet`) is the read side: it decompresses and
parses the JSONL log and state file and emits Parquet tables via the encoder in
`src/parquet.zig`, which is handed a zstd-backed `Compressor` so pages are
ZSTD-coded. Inputs are independent, a missing log or state file is skipped, not
fatal. Full details and schema are in [data-export.md](data-export.md).

## Memory model

One-shot commands allocate from the startup arena and release it on exit. Loop
mode creates and resets a per-tick arena, retaining one tick's capacity. Because
a run is short and bounded, there is no
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
- No parallel fetch in this build.
- No model in the decisive path: the optional classifier-confirmation sidecar is
  designed but deferred and never gates a tier-1 trip (see [sources.md](sources.md)).

These are conscious trade-offs; see [design-decisions.md](design-decisions.md).
