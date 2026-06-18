# State format

Last reviewed: 2026-06-18 · against fable-monitor 0.1.0 (src/ modularization)

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
point it at a throwaway path such as `/tmp/fable-monitor-demo.jsonl.zst` — this
is exactly what the `just run` / `just demo` recipes do.

## Schema

The file is a zstd stream that decompresses to line-delimited JSON: one record
per line, tagged by `kind`. Decompressed, it looks like:

```jsonl
{"kind":"seen","document_number":"2026-09266"}
{"kind":"seen","document_number":"2026-07663"}
{"kind":"hash","id":"anthropic_news","hash":"a1b2c3d4e5f60718"}
{"kind":"hash","id":"bis_news","hash":"0011223344556677"}
```

| `kind` | Fields | Meaning |
|---|---|---|
| `seen` | `document_number` | A Federal Register `document_number` already reported. The set of all `seen` records is a flat **global** seen-set, shared across the `.federal_register` sources — not per-source. |
| `hash` | `id`, `hash` | One per `.keyword_watch` source. `id` matches the source's `id`; `hash` is the 16-hex-digit Wyhash of that source's keyword fingerprint from the last run. |

Records are parsed with `ignore_unknown_fields = true` and defaulted fields, and
unknown `kind`s are skipped — so older/newer files with extra keys or record
types load without error. In memory these become the `State` struct
(`federal_register_seen` and `keyword_hashes`) in `src/state.zig`.

## Lifecycle within a run

1. **Load.** `loadState()` reads the file (cap: 64 MiB), zstd-decompresses it,
   and parses each line into the `State`. A missing/unreadable/undecompressable
   file is **non-fatal**: the run logs a warning and proceeds with an empty
   `State{}`. That is what produces first-run "baseline" behavior.
2. **Carry forward.** Every existing `seen` document number is copied into the
   next run's accumulator before polling, so nothing already known is lost.
3. **Accumulate.** As sources are polled, new document numbers and fresh keyword
   hashes are appended.
4. **Cap.** The seen-set is truncated to the most recent 200 entries by
   `capTail` so the file cannot grow without bound.
5. **Save.** `saveState()` serializes the merged `State` to JSONL records,
   zstd-compresses, and writes the file. A write failure is logged but does not
   crash the run.

## Operational notes

- **First run** records baselines for everything and reports every current
  Federal Register document as `[new]`/`[RELEVANT]`. This is expected; the
  second run is the quiet one.
- **Inspecting.** `zstd -dc fable_monitor_state.jsonl.zst` (or `just inspect
  <file>`) prints the records; pipe through `jq` if you like.
- **Editing for testing.** Because it's compressed you can't edit in place —
  decompress, edit, recompress:

  ```sh
  zstd -dc state.jsonl.zst > state.jsonl
  # delete a `seen` line to make the next run re-report that document,
  # or change a `hash` value to make the matching keyword source fire [CHANGED]
  zstd -q -f -o state.jsonl.zst state.jsonl
  ```

- **Resetting.** Delete the file to re-baseline from scratch (`just clean`
  removes the demo state/log files).
- **The 200-entry cap** is intentional: once a document scrolls past the cap it
  could theoretically re-alert if it reappeared in a feed, but the Federal
  Register returns newest-first and documents don't reappear, so in practice the
  cap only ever drops genuinely stale numbers.

## When you change the schema, update the docs

Per the [maintenance policy](README.md), changes to the `State` struct,
`capTail`, or `loadState`/`saveState` must update this file in the same change.
A schema change that isn't backward-compatible should also bump the version and
be noted in [design-decisions.md](design-decisions.md).
