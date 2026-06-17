# State format

Last reviewed: 2026-06-17 · against fable-monitor 0.1.0

The monitor's only persistent memory is a single JSON file. It is read at the
start of a run and rewritten at the end. This document describes its schema and
lifecycle. The rationale for "one JSON file, no database" is in
[design-decisions.md](design-decisions.md).

## Location

Set by the `FABLE_MONITOR_STATE` environment variable; defaults to
`fable_monitor_state.json` in the working directory. Under a scheduler, always
use an absolute path (see [deployment.md](deployment.md)). For testing, point it
at a throwaway path such as `/tmp/fable-monitor-demo.json` — this is exactly
what the `just run` / `just demo` recipes do.

## Schema

Serialized from the `State` struct in `src/main.zig`:

```json
{
  "federal_register_seen": [
    "2026-09266",
    "2026-07663"
  ],
  "keyword_hashes": [
    { "id": "anthropic_news", "hash": "a1b2c3d4e5f60718" },
    { "id": "bis_news",       "hash": "0011223344556677" }
  ]
}
```

| Field | Type | Meaning |
|---|---|---|
| `federal_register_seen` | array of strings | Federal Register `document_number`s already reported. Shared across all `.federal_register` sources — it is a flat global seen-set, not per-source. |
| `keyword_hashes` | array of `{id, hash}` | One entry per `.keyword_watch` source. `id` matches the source's `id`; `hash` is the 16-hex-digit Wyhash of that source's keyword fingerprint from the last run. |

The struct is deliberately flat and parsed with `ignore_unknown_fields = true`,
so older/newer files with extra keys load without error.

## Lifecycle within a run

1. **Load.** `loadState()` reads and parses the file (cap: 8 MiB). A missing or
   unparseable file is **non-fatal**: the run logs a warning and proceeds with an
   empty `State{}`. That is what produces first-run "baseline" behavior.
2. **Carry forward.** Every existing `federal_register_seen` entry is copied into
   the next run's accumulator before polling, so nothing already known is lost.
3. **Accumulate.** As sources are polled, new document numbers and fresh keyword
   hashes are appended.
4. **Cap.** `federal_register_seen` is truncated to the most recent 200 entries
   by `capTail` so the file cannot grow without bound.
5. **Save.** `saveState()` writes the merged `State` back as pretty-printed JSON
   (2-space indent). A write failure is logged but does not crash the run.

## Operational notes

- **First run** records baselines for everything and reports every current
  Federal Register document as `[new]`/`[RELEVANT]`. This is expected; the
  second run is the quiet one.
- **Editing for testing.** Because it's plain JSON, you can hand-edit it to
  simulate change: delete a `document_number` from `federal_register_seen` and
  the next run re-reports it; change a `hash` and the matching keyword source
  fires `[CHANGED]`.
- **Resetting.** Delete the file to re-baseline from scratch (`just clean`
  removes the demo state file).
- **The 200-entry cap** is intentional: once a document scrolls past the cap it
  could theoretically re-alert if it reappeared in a feed, but the Federal
  Register returns newest-first and documents don't reappear, so in practice the
  cap only ever drops genuinely stale numbers.

## When you change the schema, update the docs

Per the [maintenance policy](README.md), changes to the `State` struct,
`capTail`, or `loadState`/`saveState` must update this file in the same change.
A schema change that isn't backward-compatible should also bump the version and
be noted in [design-decisions.md](design-decisions.md).
