# Reading the data & exporting to Parquet

Last reviewed: 2026-06-18 · against fable-monitor 0.1.0

The monitor's state file answers "what have we already seen?" but it is a
*snapshot*, not a history — it is overwritten every run. To make the monitor's
findings queryable over time, each poll also records to an **observation log**,
and an `export` subcommand projects that log (and the current state) into
**Parquet** tables.

All of the tool's persisted outputs are zstd-compressed (see
[design-decisions.md](design-decisions.md) entry 11), so there are three ways to
read the data:

1. The **`log` subcommand** — the built-in formatted reader. `fable-monitor log`
   decompresses the observation log and prints it as an aligned, colorized
   table; no external tools needed. The quickest way to eyeball the history.
2. The **raw observation log** — zstd-compressed line-delimited JSON. Decompress
   and it's readable by anything: `zstd -dc events.jsonl.zst | jq`, or
   `pandas.read_json("events.jsonl.zst", lines=True)` (pandas decompresses by
   extension). `fable-monitor log --plain` emits the same data tab-separated for
   piping into grep/awk.
3. **Parquet tables** — columnar files (ZSTD-compressed internally) for
   analytical tools (DuckDB, pandas/pyarrow, Polars, Spark).

The Parquet writer is implemented from scratch in std-only Zig; compression is
delegated to the `zstd` binary. The rationale and limits are in
[design-decisions.md](design-decisions.md) (entries 9, 10, and 11).

## The `log` reader

```
fable-monitor log [--source ID] [--event KIND] [--limit N]
                  [--width COLS] [--plain] [--color|--no-color]
```

Reads `FABLE_MONITOR_LOG`, decompresses it, and prints the events as a table:

```
TIME              SOURCE        EVENT              REF         INFO
──────────────────────────────────────────────────────────────────────
2026-06-18 14:03  fr_anthropic  relevant_document  2026-12345  Export controls on Fable 5…
2026-06-18 15:30  bis_news      changed            —           https://www.bis.gov/news-updates
```

| Option | Effect |
|---|---|
| `--source ID` | Only events from that `source_id` (e.g. `fr_bis`). |
| `--event KIND` | Only that event kind (`relevant_document`, `new_document`, `baseline`, `changed`). |
| `--limit N` | Show only the most recent N events. |
| `--width COLS` | Total table width; the free-text `INFO` column flexes to fill it (default 100). |
| `--plain` | Tab-separated, untruncated, no color — for `grep`/`awk`/spreadsheets. |
| `--color` / `--no-color` | Force ANSI color on/off (default: on when stdout is a TTY). |

Event kinds are color-coded (relevant = bold red, changed = bold yellow, new =
cyan, baseline = dim). It needs the `zstd` binary (to decompress) but no network
or `curl`. Like `export`, it reads the log read-only and never polls.

## The observation log

Each poll records one compact JSON object per event to the file named by
`FABLE_MONITOR_LOG` (default `fable_monitor_events.jsonl.zst` in the working
directory), zstd-compressed. A run that finds nothing new writes nothing. Since
the file is a single zstd stream, a run *appends* by decompressing the existing
log, adding its lines, and recompressing (a full rewrite — cheap because the log
grows with events, not poll frequency).

All events from a single run share one `observed_at` / `epoch_ms` timestamp (the
poll time). Decompressed, each line looks like:

### Event record

```json
{
  "observed_at": "2026-06-18T14:03:09Z",
  "epoch_ms": 1781877789000,
  "source_id": "fr_anthropic",
  "source_label": "Federal Register (term: Anthropic)",
  "source_kind": "federal_register",
  "event": "relevant_document",
  "document_number": "2026-12345",
  "title": "Export controls on …",
  "publication_date": "2026-06-18",
  "url": "https://www.federalregister.gov/d/2026-12345",
  "detail": ""
}
```

| Field | Type | Meaning |
|---|---|---|
| `observed_at` | string | ISO-8601 UTC instant of the poll that recorded the event. |
| `epoch_ms` | int64 | The same instant in milliseconds since the Unix epoch. |
| `source_id` | string | The `Source.id` that produced the event. |
| `source_label` | string | Human-readable source label. |
| `source_kind` | string | `federal_register` or `keyword_watch`. |
| `event` | string | One of the event kinds below. |
| `document_number` | string | Federal Register document number (empty for keyword events). |
| `title` | string | Federal Register document title (empty for keyword events). |
| `publication_date` | string | Federal Register publication date (empty for keyword events). |
| `url` | string | Link to the document or watched page. |
| `detail` | string | Free-form: the keyword fingerprint hash for keyword events; empty otherwise. |

### Event kinds

| `event` | Emitted when |
|---|---|
| `new_document` | A new Federal Register document number is seen whose title does *not* contain a watched keyword. |
| `relevant_document` | A new Federal Register document whose title contains a watched keyword (the `[RELEVANT]` alert). |
| `baseline` | A keyword-watch source is fingerprinted for the first time (no prior hash). |
| `changed` | A keyword-watch source's fingerprint differs from the stored one (the `[CHANGED]` alert). |

Note what is *not* logged: a keyword source that is unchanged on a run produces
no row. The log is a record of *events*, not of every poll, so its size tracks
how much actually moves rather than how often the scheduler fires.

## Exporting to Parquet

```
fable-monitor export [out_dir]      # out_dir defaults to ./parquet
```

or via the task runner:

```
just export                          # writes ./parquet
just export /tmp/fable-parquet       # writes to a chosen directory
```

`export` reads the default (real) state and log files in the working directory
(decompressing them) — it does **not** poll the network. It creates `out_dir` if
needed and writes these ZSTD-compressed Parquet tables:

| File | Columns | Source |
|---|---|---|
| `events.parquet` | the 11 event fields above (`epoch_ms` is INT64; the rest UTF-8 strings) | the observation log |
| `state_seen.parquet` | `document_number` | the `seen` records in the state file |
| `state_keyword_hashes.parquet` | `id`, `hash` | the `hash` records in the state file |

A missing input is logged and skipped, not fatal: with no log file you still get
the two state tables, and vice-versa. The state file path honors
`FABLE_MONITOR_STATE`, exactly as a poll does.

### Querying the result

DuckDB (zero-config, reads Parquet directly):

```sh
duckdb -c "SELECT event, count(*) FROM 'parquet/events.parquet' GROUP BY event;"
duckdb -c "SELECT observed_at, title FROM 'parquet/events.parquet'
           WHERE source_kind = 'federal_register' ORDER BY epoch_ms DESC LIMIT 10;"
```

pandas / pyarrow:

```python
import pandas as pd
df = pd.read_parquet("parquet/events.parquet")
```

## What the Parquet writer produces

The on-disk format is intentionally minimal but standards-compliant:

- one row group, one `DATA_PAGE` per column;
- two physical types — `INT64` and `BYTE_ARRAY` (annotated `UTF8` for strings);
- `PLAIN` value encoding, `ZSTD` page compression (each page is compressed via
  the `zstd` binary);
- all columns `REQUIRED` (no nulls), so pages carry no repetition/definition
  levels.

This is read as ordinary tables by DuckDB, pandas/pyarrow, and Polars, all of
which decompress ZSTD pages natively. It deliberately omits dictionary encoding,
column statistics, and multi-row-group striping — features that matter at
gigabyte scale, not here. The writer stays free of compression code itself: it
takes an optional compressor callback and the monitor supplies a zstd-backed one
(see [design-decisions.md](design-decisions.md) entries 10 and 11).

## Verifying changes to the writer

Because std-only Zig cannot parse Parquet back, the encoder's unit tests
(`src/parquet.zig`) pin the low-level primitives (zigzag varints, compact field
headers, the file envelope), and **format correctness is verified end-to-end by
reading an exported file with a real reader**. The quickest check:

```sh
just build
./zig-out/bin/fable-monitor export /tmp/fp
duckdb -c "SELECT * FROM '/tmp/fp/events.parquet' LIMIT 5;"
# type/encodings/compression should read BYTE_ARRAY|INT64, PLAIN, ZSTD:
duckdb -c "SELECT path_in_schema, type, encodings, compression
           FROM parquet_metadata('/tmp/fp/events.parquet');"
```

To verify the compressed JSONL files directly, decompress them:

```sh
zstd -dc fable_monitor_state.jsonl.zst | jq .
zstd -dc fable_monitor_events.jsonl.zst | jq .
```

If you change `src/parquet.zig`, the event schema, or the `export` paths, update
this document in the same change (see the
[doc-maintenance policy](README.md)).
