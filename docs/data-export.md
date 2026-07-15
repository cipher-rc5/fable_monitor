# Reading the data & exporting to Parquet

Last reviewed: 2026-07-15 · against fable-monitor 0.1.0

The monitor's state file answers "what have we already seen?" but it is a
*snapshot*, not a history, it is overwritten every run. To make the monitor's
findings queryable over time, each poll also records to an **observation log**,
and an `export` subcommand projects that log (and the current state) into
**Parquet** tables.

The state, observation data frames, and Parquet pages are zstd-compressed; the
observation manifest is small JSON metadata (see
[design-decisions.md](design-decisions.md) entry 11), so there are three ways to
read the data:

1. The **`log` / `view` subcommands**, the built-in formatted reader.
   `fable-monitor log` decompresses the observation log and prints it as an
   aligned, colorized table; no external tools needed. The quickest way to
   eyeball the history. `fable-monitor view` is the same reader with a dataview
   preset: the last 90 days, newest-first.
2. The **logical observation log**, zstd-compressed line-delimited JSON stored
   across a base, manifest, and immutable segments. Use `log`, `view`, or
   `export`; decompressing only the legacy base can omit committed segments.
   `fable-monitor log --plain` emits tab-separated data for pipelines.
3. **Parquet tables**, columnar files (ZSTD-compressed internally) for
   analytical tools (DuckDB, pandas/pyarrow, Polars, Spark).

The Parquet writer is implemented from scratch in std-only Zig; compression is
delegated to the `zstd` binary. The rationale and limits are in
[design-decisions.md](design-decisions.md) (entries 9, 10, and 11).

## The `log` / `view` reader

```
fable-monitor log  [--source ID] [--event KIND] [--since DATE] [--days N]
                   [--relevant] [--desc|--asc] [--limit N] [--width COLS]
                   [--plain] [--color|--no-color]
fable-monitor view [same flags]    # preset: --days 90 --desc
fable-monitor log compact [N]      # retain newest N rows immediately
fable-monitor log recover          # restore a validated manifest backup
```

Both subcommands run the same reader; they differ only in their defaults. `log`
shows the whole history oldest-first. `view` is the **dataview preset**, it
windows to the last 90 days and orders newest-first, for an at-a-glance table of
recent activity. Any explicit flag overrides the preset (e.g. `view --days 7`,
`view --asc`, `log --desc`).

Reads `FABLE_MONITOR_LOG`, decompresses it, and prints the events as a table:

```
TIME              SOURCE        EVENT              REF         INFO
──────────────────────────────────────────────────────────────────────
2026-06-18 15:30  bis_news      changed           ,           https://www.bis.gov/news-updates
2026-06-18 14:03  fr_anthropic  relevant_document  2026-12345  Export controls on Fable 5…
```

| Option | Effect |
|---|---|
| `--source ID` | Only events from that `source_id` (e.g. `fr_bis`). |
| `--event KIND` | Only that event kind (e.g. `restoration`, `advisory`, `relevant_document`, `new_document`, `baseline`). |
| `--since DATE` | Only events at/after an ISO date (e.g. `2026-03-25`). Compared lexicographically against `observed_at`. |
| `--days N` | Only events from the last N days (relative to now). `--since` wins if both are given. |
| `--relevant` | Only high-signal events: `relevant_document` and `changed`. |
| `--desc` / `--asc` | Sort newest-first / oldest-first by `observed_at`. (`view` defaults `--desc`, `log` defaults `--asc`.) |
| `--limit N` | Show only the most recent N events (applied after the window, before the sort flip). |
| `--width COLS` | Total table width; the free-text `INFO` column flexes to fill it (default 100). |
| `--plain` | Tab-separated, untruncated, no color, for `grep`/`awk`/spreadsheets. |
| `--color` / `--no-color` | Force ANSI color on/off (default: on when stdout is a TTY). |

Event kinds are color-coded (relevant = bold red, changed = bold yellow, new =
cyan, baseline = dim). It needs the `zstd` binary (to decompress) but no network
or `curl`. Like `export`, it reads the log read-only and never polls.

## The observation log

Each poll records one compact JSON object per event to the logical log named by
`FABLE_MONITOR_LOG` (default `fable_monitor_events.jsonl.zst` in the working
directory). Runs are committed as immutable zstd frames in an adjacent
`.segments` directory, then made visible by an atomic manifest update. Torn
staging files are ignored, so a crash or full disk cannot hide older history.
Append cost tracks only the new frame, not lifetime history.

The primary `<log>.manifest` selects the active generation, while
`<log>.manifest.backup` retains a validated committed generation. If the primary
is missing or malformed, readers can use a valid backup, but append and
compaction return `ManifestRecoveryRequired` rather
than silently blessing it. Stop the poller and run `fable-monitor log recover`:
it takes the log lock, validates the backup and every referenced base/segment,
then atomically restores both manifest copies. If validation fails, preserve the
whole log family and restore it from an external backup instead.

The log automatically compacts to the newest 100,000 events by default. Set
`FABLE_MONITOR_MAX_EVENTS` to another positive limit, or run
`fable-monitor log compact [max_events]` for immediate maintenance. Readers and
Parquet export treat the base generation and segments as one NDJSON stream.

All events from a single run share one `observed_at` / `epoch_ms` timestamp (the
poll time). Decompressed, each line looks like:

### Event record

```json
{
  "observed_at": "2026-06-28T14:03:09Z",
  "epoch_ms": 1782396189000,
  "source_id": "fr_anthropic",
  "source_label": "Federal Register (term: Anthropic)",
  "source_kind": "federal_register",
  "event": "relevant_document",
  "document_number": "2026-12345",
  "title": "Export controls on …",
  "publication_date": "2026-06-28",
  "url": "https://www.federalregister.gov/d/2026-12345",
  "detail": "",
  "tier": 2,
  "confidence": "advisory",
  "event_identity": "fr_doc:published:2026-12345",
  "published_at": "2026-06-28",
  "published_epoch_ms": 1782345600000,
  "fetch_ms": 0,
  "http_status": 0
}
```

| Field | Type | Meaning |
|---|---|---|
| `observed_at` | string | ISO-8601 UTC instant of the poll that recorded the event. |
| `epoch_ms` | int64 | The same instant (detection time) in milliseconds since the Unix epoch. |
| `source_id` | string | The `Source.id` that produced the event. |
| `source_label` | string | Human-readable source label. |
| `source_kind` | string | The `SourceKind` tag name (`model_list_probe`, `api_probe`, `statement_watch`, `federal_register`, `federal_register_public_inspection`, `feed_watch`, `keyword_watch`, `market_watch`). |
| `event` | string | One of the event kinds below. |
| `document_number` | string | Federal Register document number (empty for non-FR events). |
| `title` | string | Document or entry title (empty where not applicable). |
| `publication_date` | string | Federal Register publication date (empty where not applicable). |
| `url` | string | Link to the document, entry, or watched page. |
| `detail` | string | Free-form: keyword fingerprint hash, model id, market price, byte counts, etc. |
| `tier` | int | Source confidence tier (1/2/3); 0 = unset (pre-v2 rows). |
| `confidence` | string | `high`, `advisory`, or empty. Set on the coalesced trip rows. |
| `event_identity` | string | Normalized subject used to coalesce signals (for example `model_present:claude-fable-5`, `statement_restored`, or `fr_doc:<stage>:<number>`). Delivery occurrences use a separate `occurrence_id` in the outbox payload/state. |
| `published_at` | string | Source publication timestamp, if known. |
| `published_epoch_ms` | int64 | The same instant in epoch ms; 0 when unknown (e.g. an RFC-822 `pubDate` we don't parse). The basis for the latency backtest below. |
| `fetch_ms` | int64 | Per-source fetch latency, on metric rows only. |
| `http_status` | int64 | HTTP status on metric rows (304 = not modified). |

The v2 fields default to empty/0, so rows written by older builds parse
unchanged and older readers ignore the extra columns.

### Schema versioning and compatibility

The JSON contracts the monitor emits carry an explicit version suffix in their
`schema` field, using a `name/N` shape: the observation/delivery event is
`fable-monitor.event/1`, and the readiness check is `fable-monitor.preflight/1`.
The state inspection and recovery JSON shapes (`state inspect`, `state recover`,
`state rebaseline`) are covered by the same policy; they identify their payload
by stable `status`/`action` keys rather than an unbounded field set.

- The integer after the slash is a **stable major version**. Within one major,
  changes are **additive and backward-compatible**: new fields may be appended,
  but existing fields keep their name, type, and meaning.
- A **breaking change** (removing or renaming a field, changing a field's type,
  or changing the meaning of an existing value) **bumps the integer suffix**,
  e.g. `fable-monitor.event/1` → `fable-monitor.event/2`. The two majors may be
  emitted side by side during an overlap window.
- **Consumers must ignore unknown fields** and **key on the version suffix**,
  not on field presence. Match the `name/` prefix and branch on the integer;
  treat an unrecognized major as one you do not support rather than failing on
  extra keys. This is the same forward-compatibility rule the event columns
  already follow (older readers ignore the v2 columns above).
- **Deprecations are announced in the CHANGELOG / release notes** with an
  overlap period: a field or major slated for removal is documented as deprecated
  for at least one release before it is dropped, and where practical the old and
  new majors are emitted together so consumers can migrate without a flag day.

### Event kinds

| `event` | Emitted when |
|---|---|
| `restoration` | A decisive tier-1 trip: a controlled model appeared in the public listing (absent-to-present) or the statement page gained restoration language. |
| `advisory` | A lower-confidence tier-2/3 change (feed entry, statement/keyword shift without restoration vocabulary, market move). May be promoted to `high` confidence when corroborated. |
| `relevant_document` | A new Federal Register document whose title/abstract passes the tightened relevance filter (names Anthropic or a specific model). |
| `new_document` | A new Federal Register document number that does *not* pass the relevance filter. |
| `baseline` | A watch source is fingerprinted for the first time (no prior hash). |
| `market` | A `market_watch` source's price was recorded. |
| `fetch` | A per-source fetch metric row (latency / HTTP status), written only when metrics logging is on (`FABLE_MONITOR_METRICS=1` or `FABLE_MONITOR_STATS=1`). |

Note what is *not* logged: a source that is unchanged on a run produces no row
(unless metrics logging is on). The log is a record of *events*, not of every
poll, so its size tracks how much actually moves rather than how often the
scheduler fires.

Automatic compaction enforces `FABLE_MONITOR_MAX_EVENTS` (100,000 by default).
`fable-monitor log compact [max_events]` applies a limit immediately; archive
the logical log and its sidecars according to [operations.md](operations.md).

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
(decompressing them), it does **not** poll the network. It creates `out_dir` if
needed and writes these ZSTD-compressed Parquet tables:

| File | Columns | Source |
|---|---|---|
| `events.parquet` | all 18 event fields above. The INT64 columns are `epoch_ms`, `tier`, `published_epoch_ms`, `fetch_ms`, `http_status`; the rest are UTF-8 strings. | the observation log |
| `state_seen.parquet` | `document_number` | the `seen` records (current values are stage-qualified Federal Register keys; legacy state may contain bare numbers) |
| `state_keyword_hashes.parquet` | `id`, `hash` | the `hash` records in the state file |

A missing input is logged and skipped, not fatal: with no log file you still get
the two state tables, and vice-versa. The state file path honors
`FABLE_MONITOR_STATE`, exactly as a poll does.

### Detection-latency backtest

The headline analytical question: how fast does each tier detect a real event,
measured from the source's own publication time to our detection time? For any
trip row where `published_epoch_ms > 0`, the detection latency is
`epoch_ms - published_epoch_ms`. This single DuckDB query reports per-tier
median and p95 detection latency:

```sql
-- Median and p95 detection latency (source publication -> detection), per tier.
SELECT tier,
       count(*)                                              AS events,
       median((epoch_ms - published_epoch_ms) / 1000.0)      AS median_latency_s,
       quantile_cont((epoch_ms - published_epoch_ms) / 1000.0, 0.95) AS p95_latency_s
FROM 'parquet/events.parquet'
WHERE published_epoch_ms > 0
  AND confidence <> ''            -- coalesced trip rows
GROUP BY tier
ORDER BY tier;
```

The `confidence <> ''` filter keeps the coalesced trip rows (one per event
identity) and drops baselines and metric rows. Rows where the source publishes
no parseable timestamp (`published_epoch_ms = 0`) are excluded rather than
counted as zero-latency.

### Other queries

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
- two physical types, `INT64` and `BYTE_ARRAY` (annotated `UTF8` for strings);
- `PLAIN` value encoding, `ZSTD` page compression (each page is compressed via
  the `zstd` binary);
- all columns `REQUIRED` (no nulls), so pages carry no repetition/definition
  levels.

This is read as ordinary tables by DuckDB, pandas/pyarrow, and Polars, all of
which decompress ZSTD pages natively. It deliberately omits dictionary encoding,
column statistics, and multi-row-group striping, features that matter at
gigabyte scale, not here. The writer stays free of compression code itself: it
takes an optional compressor callback and the monitor supplies a zstd-backed one
(see [design-decisions.md](design-decisions.md) entries 10 and 11).

## Verifying changes to the writer

Because std-only Zig cannot parse Parquet back, the encoder's unit tests
(`src/parquet.zig`) pin the low-level primitives (zigzag varints, compact field
headers, the file envelope), and **format correctness is verified end-to-end by
reading an exported file with a real reader**. `just parquet-test` performs this
check against offline fixture data with DuckDB and is part of `just ci`. The
manual equivalent is:

```sh
just build
./zig-out/bin/fable-monitor export /tmp/fp
duckdb -c "SELECT * FROM '/tmp/fp/events.parquet' LIMIT 5;"
# type/encodings/compression should read BYTE_ARRAY|INT64, PLAIN, ZSTD:
duckdb -c "SELECT path_in_schema, type, encodings, compression
           FROM parquet_metadata('/tmp/fp/events.parquet');"
```

To verify state directly and read the logical history through its manifest:

```sh
zstd -dc fable_monitor_state.jsonl.zst | jq .
fable-monitor log --plain
```

If you change `src/parquet.zig`, the event schema, or the `export` paths, update
this document in the same change (see the
[doc-maintenance policy](README.md)).
