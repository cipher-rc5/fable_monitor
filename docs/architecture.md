# Architecture

Last reviewed: 2026-06-18 · against fable-monitor 0.1.0

`fable-monitor` is a single-binary CLI with one job: detect when an official
source says something new about the export-control status of Anthropic's
Fable 5 / Mythos 5 models, and alert on it. It is deliberately small. The code
is split into focused modules under `src/`:

- `main.zig` — CLI entrypoint: argument/subcommand dispatch, the poll
  orchestration loop, the Federal Register / keyword-watch check functions,
  alerting, and the test root.
- `context.zig` — the shared `Context` type threaded through a run, plus `log`.
- `sources.zig` — `Source`, `SourceKind`, the `sources` array, and `keywords`.
- `fetch.zig` — `httpGet` and `toolAvailable` (network I/O via curl).
- `html.zig` — `normalizeHtml`, `extractKeywordContext`, `containsAny`,
  `lessThanSlice` (pure text helpers).
- `state.zig` — `State`, `StateRecord`, `loadState`, `saveState`, `capTail`.
- `events.zig` — `Event`, the event-kind constants, `isoUtc`, `appendLog`.
- `zstd.zig` — `compress` / `decompress` / `compressor` (zstd helpers).
- `export.zig` — `exportParquet`, `exportEvents`, `exportState`, `row`,
  `readFileMaybe`.
- `view.zig` — the `log` subcommand: a formatted, colorized terminal reader for
  the observation log.
- `parquet.zig` — the standalone, std-only Parquet encoder.
- `banner.zig` — a from-scratch TrueType rasterizer for the `banner` subcommand
  (embeds the bundled font from `src/assets/`).

Modules avoid import cycles by keeping `Context` in its own module
(`context.zig`, which only depends on `events.zig` for the `Event` type and
never imports the concern modules back) and by having the lower-level helpers
take primitives rather than `*Context` — `events.appendLog` and the `zstd.*`
functions take `io`/`arena` directly.

## The governing idea: one run = one poll

The tool is **not** a long-running daemon. Each invocation does exactly one pass
over the sources and then exits. Recurring execution is the scheduler's job
(launchd or cron — see [deployment.md](deployment.md)). This keeps the process
model trivial: no event loop, no timers, no in-memory state to corrupt, and a
crash affects at most one poll. Continuity across runs comes entirely from a
small JSON state file (see [state-format.md](state-format.md)).

## Subcommands

The binary has four modes, selected by `argv[1]`:

- **(default) / `poll`** — one poll pass over the sources, described below.
- **`log [filters]`** — print the observation log as a formatted table (reads
  + decompresses it, no network). See [data-export.md](data-export.md).
- **`export [out_dir]`** — no network; project the observation log and state
  file into Parquet tables. See [data-export.md](data-export.md).
- **`banner [text] [height]`** — print text (default `FABLE`) as a TrueType
  banner. Self-contained (no network/files/compression), so it is dispatched
  before the `zstd`/`curl` preflights. See [banner.md](banner.md).

## Run lifecycle (poll)

`main(init: std.process.Init)` executes these steps in order:

1. **Set up context.** Read `FABLE_MONITOR_STATE`, `FABLE_MONITOR_LOG`, and
   `FABLE_MONITOR_NOTIFY` from the environment, capture the poll time once (via
   `Io.Timestamp.now(io, .real)`, formatted by `isoUtc`), and build a `Context`
   (holds the `Io`, the arena allocator, the state and log paths, the notify
   command, the run timestamp, an `events` accumulator, and a `changed` flag).
   Then run the `zstd` preflight (`fetch.toolAvailable(&ctx, "zstd")`) — required
   in both modes since every persisted file is compressed — and dispatch the
   subcommand (`export` returns early here, via `export_mod.exportParquet`).
2. **Preflight.** `fetch.toolAvailable(&ctx, "curl")` runs `curl --version`; if
   curl is missing, log a clear fatal message and return before doing any work.
3. **Load previous state.** `state.loadState(&ctx)` reads the state file, zstd-decompresses
   it, and parses one JSONL record per line into a `State`. A missing or
   unreadable file is non-fatal — the run simply starts from an empty state
   (first-run / baseline behavior).
4. **Poll each source.** Iterate `sources`; dispatch on `SourceKind` to either
   `checkFederalRegister` or `checkKeywordWatch`. Each source is wrapped in its
   own error handler, so one source failing (network, parse, …) logs an error
   and the others still run. Both paths call `ctx.record(...)` to append an
   `Event` to the in-memory accumulator as they alert.
5. **Persist merged state.** Combine carried-forward and newly-seen data into a
   `State` and write it back with `state.saveState(&ctx, next)`. The Federal
   Register seen-set is capped to the most recent 200 entries via
   `state.capTail`.
6. **Append history.** `events.appendLog(io, arena, log_path, events_slice)`
   decompresses the existing log, appends this run's `events` as JSONL lines,
   recompresses, and rewrites it (a no-op when nothing was recorded). It takes
   primitives, not the `Context`. A logging failure is reported but never fails
   the poll.
7. **Report.** If nothing set `ctx.changed`, log "no changes detected".

## Components

```
                 ┌─────────────────────────────────────────────┐
                 │                  main()                      │
                 │  env → Context → preflight → load → poll →   │
                 │             save → report                    │
                 └───────────────┬─────────────────────────────┘
                                 │ for each Source
              ┌──────────────────┴───────────────────┐
              ▼                                       ▼
   checkFederalRegister()                   checkKeywordWatch()
   • httpGet (curl)                         • httpGet (curl)
   • parse JSON (FrResponse)                • normalizeHtml
   • diff vs prev.hasSeen                   • extractKeywordContext
   • alert on new docs                      • Wyhash fingerprint
                                            • diff vs prev.hashFor
              │                                       │
              └──────────────────┬────────────────────┘
                                 ▼
                              alert()
                    stdout  +  (if high-signal) runNotify() → sh -c
```

### Fetching — `fetch.httpGet` / `fetch.toolAvailable`

All network I/O is delegated to the system `curl` binary via
`std.process.run` (in `fetch.zig`). `httpGet` invokes curl with `-sS -L --fail`,
a 30s timeout, a `User-Agent` of `fable-monitor/<version>` (a comptime string
built from the `build_options` version), and a 16 MiB stdout cap; a non-zero
exit becomes `error.FetchFailed`. Nothing else in the program speaks HTTP or
TLS. `toolAvailable(ctx, name)` is the shared `<name> --version` preflight used
for both `curl` and `zstd`. The rationale is in
[design-decisions.md](design-decisions.md).

### Federal Register path — `checkFederalRegister`

The structured, high-reliability signal. The response is parsed into a minimal
projection (`FrResponse` / `FrDoc`) with `ignore_unknown_fields = true`, so the
API can add fields without breaking us. Each document is keyed by its
`document_number`; numbers we've already seen are skipped. New numbers are
recorded and alerted, and titles containing a watched keyword are tagged
`[RELEVANT]` rather than plain `new`.

### Keyword-watch path — `checkKeywordWatch`

The best-effort signal for pages that have no structured feed. Raw HTML is far
too volatile to hash directly, so the body is reduced to a stable fingerprint:

- `normalizeHtml` strips tags, lowercases, and collapses whitespace runs.
- `extractKeywordContext` keeps a ±100-byte window around each keyword hit, then
  sorts and de-duplicates the windows so reordering on the page doesn't change
  the result.
- The concatenated windows are hashed with `std.hash.Wyhash`.

The hash is compared to the stored hash for that source: no stored hash means
"baseline recorded"; an equal hash means "unchanged"; a different hash fires a
`[CHANGED]` alert. This deliberately reports *that* something near a keyword
changed, not *what* — diffing the substance is left to the human.

### Alerting — `alert` / `runNotify`

`alert` always writes the message to stdout and sets `ctx.changed`. For
high-signal events (relevant Federal Register docs, page changes) it also fires
the optional notify hook. `runNotify` invokes the user command as
`sh -c <cmd> fable-monitor <message>`, exposing the alert text as `$1` — this
avoids both shell injection and clobbering the child's environment.

### Compression — `zstd.compress` / `zstd.decompress` / `zstd.compressor`

Every persisted file (state, log, Parquet pages) is zstd-compressed. Zig's std
has no zstd compressor, so all compression *and* decompression run through the
system `zstd` binary: an internal `zstdFilter` stages the input in a temp file
(since `std.process.run` can't feed stdin), runs `zstd` over it, and returns the
captured stdout. The public `zstd.compress` / `zstd.decompress` helpers take
primitives (`io`, `arena`) rather than the `Context`, and `zstd.compressor`
builds the `parquet.Compressor` thunk used by the export path. See
[design-decisions.md](design-decisions.md) entry 11.

### History & export — `events.appendLog` / `export.exportParquet` / `src/parquet.zig`

Alerts are ephemeral (stdout); the history of findings is durable. As each
source alerts it also calls `ctx.record(...)`, building a list of `Event`
structs stamped with the run's timestamp. After state is saved,
`events.appendLog` decompresses the existing log (`FABLE_MONITOR_LOG`), appends
this run's events as JSONL, recompresses, and rewrites it.

The `export` subcommand (`export.exportParquet`) is the read side: it decompresses and
parses the JSONL log and state file and emits Parquet tables via the encoder in
`src/parquet.zig`, which is handed a zstd-backed `Compressor` so pages are
ZSTD-coded. Inputs are independent — a missing log or state file is skipped, not
fatal. Full details and schema are in [data-export.md](data-export.md).

## Memory model

Everything allocates from a single arena (`init.arena`) that lives for the whole
process and is released on exit. Because a run is short and bounded, there is no
per-source free; the arena is freed wholesale when the process ends. This is a
deliberate simplification that the one-run-one-poll model makes safe.

## Output streams

- **stdout** — alerts (the signal a human or downstream tool consumes).
- **stderr** — diagnostics, every line prefixed `[fable-monitor]` (via `log`).

Keeping alerts and diagnostics on separate streams means you can pipe alerts
somewhere while still seeing operational logs.

## What this design intentionally does *not* do

- No daemon / no scheduling of its own (delegated to launchd/cron).
- No database (compressed JSONL files are enough).
- No HTTP/TLS stack of its own (delegated to curl).
- No in-process compression (delegated to the zstd binary; std has no encoder).
- No diff of *what* changed on a watched page (only that it changed).

These are conscious trade-offs; see [design-decisions.md](design-decisions.md).
