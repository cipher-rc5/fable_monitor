# State format

Last reviewed: 2026-06-28 · against fable-monitor 0.1.0 (feat/tiered-monitor)

The monitor's only persistent *snapshot* is a single file: zstd-compressed
line-delimited JSON (`.jsonl.zst`). It is read at the start of a run and
rewritten at the end. This document describes its schema and lifecycle. The
rationale for "one file, no database" and for the JSONL + zstd choices is in
[design-decisions.md](design-decisions.md) (decisions 3 and 11).

This snapshot is distinct from the **observation log** that records the *history*
of findings over time; that, and the `export` subcommand that turns both into
Parquet, are documented in [data-export.md](data-export.md).

## Location

Set by the `FABLE_MONITOR_STATE` environment variable; defaults to
`fable_monitor_state.jsonl.zst` in the working directory. Under a scheduler,
always use an absolute path (see [deployment.md](deployment.md)). For testing,
point it at a throwaway path such as `/tmp/fable-monitor-demo.jsonl.zst`. This
is exactly what the `just run` / `just demo` recipes do.

## Format versioning (v1 and v2)

The current on-disk format is **v2** (`current_version` in `src/state.zig`).
v2 is backward compatible with v1:

- **v1** wrote only `seen` and `hash` records and no `meta` line.
- **v2** writes a leading `{"kind":"meta","version":2}` record plus several new
  record kinds (below). A v1 file still loads: with no `meta` record the version
  defaults to 1, and the v2-only record kinds simply never appear. Conversely a
  v2 file read by an older build ignores the records it does not know (lenient
  parse). **No history is invalidated.**

## Schema

The file is a zstd stream that decompresses to line-delimited JSON: one record
per line, tagged by `kind`. Decompressed, a v2 file looks like:

```jsonl
{"kind":"meta","version":2}
{"kind":"seen","document_number":"2026-09266"}
{"kind":"hash","id":"bis_news","hash":"0011223344556677"}
{"kind":"validator","id":"fr_bis","etag":"\"abc\"","last_modified":"Mon, 01 Jan 2026 00:00:00 GMT"}
{"kind":"model","id":"anthropic_model_list","model":"claude-fable-5"}
{"kind":"feed","id":"google_news","key":"https://news.example/a"}
{"kind":"status","id":"fr_bis","last_poll_ms":1781877789000,"last_success_ms":1781877789000,"last_change_ms":0}
{"kind":"alert","event_identity":"model_present:claude-fable-5","epoch_ms":1781877789000,"acknowledged":false,"escalated":false}
```

| `kind` | Fields | Meaning |
|---|---|---|
| `meta` | `version` | Format version stamp. Written first; absent in v1 files. |
| `seen` | `document_number` | A Federal Register `document_number` already reported. A flat **global** seen-set shared across the Federal Register sources, not per-source. |
| `hash` | `id`, `hash` | One per `keyword_watch` / `statement_watch` source: the 16-hex-digit Wyhash of that source's keyword fingerprint from the last run. `market_watch` sources reuse this record to store their last price. |
| `validator` | `id`, `etag`, `last_modified` | Cached conditional-request validators per source, so the next poll can send `If-None-Match` / `If-Modified-Since` and get a cheap 304. |
| `model` | `id`, `model` | One (source id, model id) pair currently observed present in a model listing. The set of these is what an absent-to-present transition is detected against. |
| `feed` | `id`, `key` | One (source id, entry-key) pair already seen in a feed (guid / link / sitemap loc), so re-seeing it is not a change. |
| `status` | `id`, `last_poll_ms`, `last_success_ms`, `last_change_ms` | Per-source timing: last attempt, last successful fetch, last detected change. Drives adaptive cadence (is this source due?) and the `audit` coverage report (is a source quietly dead?). |
| `alert` | `event_identity`, `epoch_ms`, `acknowledged`, `escalated` | Alert-once / escalation bookkeeping, keyed on a normalized event identity so one real event alerts once even as it persists across polls. |

Records are parsed with `ignore_unknown_fields = true` and defaulted fields, and
unknown `kind`s are skipped. In memory these become the `State` struct in
`src/state.zig` (with lookup helpers such as `hasSeen`, `validatorFor`,
`modelIsPresent`, `feedHasSeen`, `statusFor`, and `alertFor`).

## Lifecycle within a run

1. **Load.** `loadState()` reads the file (cap: 64 MiB), zstd-decompresses it,
   and parses each line into the `State`. A missing/unreadable/undecompressable
   file is **non-fatal**: the run starts fresh with an empty `State{}`, which is
   what produces first-run "baseline" behavior.
2. **Carry forward.** The cumulative sets (seen document numbers, seen feed
   keys) and the alert bookkeeping are copied into the next run's accumulator
   before polling. For a source that is *not due* this tick, its per-source
   records (validator, hash, model, status) are carried forward unchanged so a
   slow source's state survives a fast tick.
3. **Accumulate.** As due sources are polled, new document numbers, fresh
   fingerprints, present models, feed keys, validators, and status timings are
   appended.
4. **Cap.** The Federal Register seen-set is truncated to the most recent **300**
   entries, and the feed seen-set to the most recent **500**, so neither grows
   without bound.
5. **Save.** `saveState()` writes the `meta` record, serializes the merged
   `State` to JSONL, zstd-compresses, and rewrites the file. A write failure is
   logged but does not crash the run.

## Operational notes

- **First run** records baselines for everything and reports current Federal
  Register documents. The second run is the quiet one.
- **Acknowledging an alert.** `fable-monitor ack <event_id>` flips the matching
  `alert` record's `acknowledged` flag so it stops escalating; the `event_id` is
  the structured event's `event_id` (the normalized identity). See
  [data-export.md](data-export.md) for the event schema and
  [deployment.md](deployment.md) for escalation.
- **Inspecting.** `zstd -dc fable_monitor_state.jsonl.zst` (or `just inspect
  <file>`) prints the records; pipe through `jq` if you like.
- **Editing for testing.** Because it's compressed you can't edit in place.
  Decompress, edit, recompress:

  ```sh
  zstd -dc state.jsonl.zst > state.jsonl
  # delete a `seen` line to re-report a document, change a `hash` to fire a
  # change, or delete a `model` line to re-arm an absent-to-present transition
  zstd -q -f -o state.jsonl.zst state.jsonl
  ```

- **Resetting.** Delete the file to re-baseline from scratch (`just clean`
  removes the demo state/log files).

## When you change the schema, update the docs

Per the [maintenance policy](README.md), changes to the `State` struct,
`StateRecord`, `capTail`, or `loadState`/`saveState` in `src/state.zig` must
update this file in the same change. A schema change that isn't backward
compatible should bump `current_version` and be noted in
[design-decisions.md](design-decisions.md).
