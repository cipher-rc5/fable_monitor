# State format

Last reviewed: 2026-07-14 · against fable-monitor 0.1.0

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

## Format versioning (v1-v5)

The current on-disk format is **v5** (`current_version` in `src/state.zig`). It
reads v1 through v5:

- **v1** wrote only `seen` and `hash` records and no `meta` line.
- **v2** added a leading `meta` record plus validator, model, feed, status, and
  alert records.
- **v3** adds `term` records containing the negation-aware restoration terms
  present at the last statement poll. When loading v1/v2, the detector records
  a fresh term baseline without tripping; only a subsequent absent-to-present
  transition can produce a restoration event.
- **v4** adds occurrence IDs, alert delivery settlement, and durable `delivery`
  records containing the immutable payload plus per-sink attempts, retry time,
  lease, and last error. Existing v1-v3 alerts migrate as already delivered.
- **v5** adds `lease_token` to fence delivery completion. A completion mutates
  state only while its random token still owns that lease. Saving a v4 file
  clears tokenless leases so they can be claimed safely, and normalizes each
  status record so `last_change_ms` and `last_success_ms` cannot be later than
  `last_poll_ms`.

With no `meta` record the version defaults to 1. Unknown fields are tolerated
within a supported version, but malformed lines, unknown record kinds,
duplicate singleton records, and future versions fail closed.

## Schema

The file is a zstd stream that decompresses to line-delimited JSON: one record
per line, tagged by `kind`. Decompressed, a v5 file looks like:

```jsonl
{"kind":"meta","version":5}
{"kind":"seen","document_number":"fr:published:2026-09266"}
{"kind":"hash","id":"bis_news","hash":"0011223344556677"}
{"kind":"validator","id":"fr_bis","etag":"\"abc\"","last_modified":"Mon, 01 Jan 2026 00:00:00 GMT"}
{"kind":"model","id":"anthropic_model_list","model":"claude-fable-5"}
{"kind":"term","id":"anthropic_statement","term":"available"}
{"kind":"feed","id":"google_news","key":"https://news.example/a"}
{"kind":"status","id":"fr_bis","last_poll_ms":1781877789000,"last_success_ms":1781877789000,"last_change_ms":0}
{"kind":"alert","event_identity":"model_present:claude-fable-5","occurrence_id":"occ-...-initial","epoch_ms":1781877789000,"delivered":false,"acknowledged":false,"escalated":false}
{"kind":"delivery","occurrence_id":"occ-...-initial","event_identity":"model_present:claude-fable-5","sink":"webhook","payload":"{...}","attempts":1,"lease_until_ms":1781877795000,"lease_token":"8f...","last_error":""}
```

| `kind` | Fields | Meaning |
|---|---|---|
| `meta` | `version` | Format version stamp. Written first; absent in v1 files. |
| `seen` | `document_number` | A Federal Register stage key (`fr:preliminary:<number>` or `fr:published:<number>`) already evaluated. Legacy bare numbers suppress preliminary replay but allow published reevaluation. |
| `hash` | `id`, `hash` | One per `keyword_watch` / `statement_watch` source: the 16-hex-digit Wyhash of that source's keyword fingerprint from the last run. `market_watch` sources reuse this record to store their last price. |
| `validator` | `id`, `etag`, `last_modified` | Cached conditional-request validators per source, so the next poll can send `If-None-Match` / `If-Modified-Since` and get a cheap 304. |
| `model` | `id`, `model` | One (source id, model id) pair currently observed present in a model listing. The set of these is what an absent-to-present transition is detected against. |
| `term` | `id`, `term` | One negation-aware restoration term currently present for a statement source. Introduced in v3 to make restoration detection transition-based. |
| `feed` | `id`, `key` | One (source id, entry-key) pair already seen in a feed (guid / link / sitemap loc), so re-seeing it is not a change. |
| `status` | `id`, `last_poll_ms`, `last_success_ms`, `last_change_ms` | Per-source timing: last attempt, last successful fetch, last detected change. In v5, success/change must not be later than poll. Drives adaptive cadence and `audit`. |
| `alert` | `event_identity`, `occurrence_id`, `epoch_ms`, `delivered`, `acknowledged`, `escalated` | Alert-once / escalation bookkeeping. `delivered` becomes true only when every required initial sink succeeds. |
| `delivery` | `occurrence_id`, `event_identity`, `sink`, `payload`, `notify_message`, `attempts`, `next_retry_ms`, `lease_until_ms`, `lease_token`, `last_error`, `delivered` | Durable per-required-sink work. A nonzero lease requires a nonempty token in v5; delivered records have no retry, lease, token, or error. The occurrence ID is also the payload idempotency key. |

Records are parsed with `ignore_unknown_fields = true` for compatible additions,
while unknown kinds and invalid required fields reject the generation. In memory these become the `State` struct in
`src/state.zig` (with lookup helpers such as `hasSeen`, `validatorFor`,
`modelIsPresent`, `feedHasSeen`, `statusFor`, and `alertFor`).

## Lifecycle within a run

1. **Load.** `loadState()` reads the file (cap: 64 MiB), zstd-decompresses it,
   and parses each line into the `State`. Only a missing file is first run.
   Unreadable, corrupt-zstd, malformed, unknown-kind, duplicate, and future
   generations fail closed and are not replaced by the poll.
2. **Carry forward.** The cumulative sets (seen document numbers, seen feed
   keys) and the alert bookkeeping are copied into the next run's accumulator
   before polling. For a source that is *not due* this tick, its per-source
   records (validator, hash, model, term, status) are carried forward unchanged so a
   slow source's state survives a fast tick.
3. **Accumulate.** As due sources are polled, new document numbers, fresh
   fingerprints, present models, feed keys, validators, and status timings are
   appended.
4. **Cap.** The Federal Register seen-set is truncated to the most recent **300**
   entries, and the feed seen-set to the most recent **500**, so neither grows
   without bound.
5. **Audit.** Append the observation batch to the logical log first. If this
   fails, detector baselines are not advanced and no delivery begins.
6. **Commit.** `saveState()` validates and atomically retains the current
   generation as `<state>.backup`, then atomically commits detector state,
   alerts, and all required delivery records before delivery work.
7. **Deliver.** Due records receive random lease tokens under the state lock,
   are delivered outside
   it, and checkpointed individually. Failures use bounded exponential backoff
   with jitter and survive restart; exhausted work is never discarded. A stale
   claimant's completion is ignored if its token no longer matches.
8. **Settle.** An initial alert is delivered only when every delivery for that
   occurrence succeeds. Completed delivery records are removed on a later save
   once the whole occurrence is settled; pending siblings remain.

## Operational notes

- **First run** establishes transition/feed/watch baselines and evaluates
  current Federal Register documents as new. The second run is normally quiet.
- **Subject and occurrence.** `event_identity` is the stable logical subject.
  `occurrence_id` is one initial or escalation delivery episode. Model and
  statement restoration subjects re-arm after a successful absence observation;
  a fetch failure is unknown and cannot re-arm. Other detector identities have
  no explicit absence-based re-arm.
- **Acknowledging an alert.** `fable-monitor ack <event_id>` flips the matching
  `alert` record's `acknowledged` flag so it stops escalating; the `event_id` is
  the structured event's `event_id` (the normalized identity). See
  [data-export.md](data-export.md) for the event schema and
  [deployment.md](deployment.md) for escalation.
- **Inspecting.** `zstd -dc fable_monitor_state.jsonl.zst` (or `just inspect
  <file>`) prints the records; pipe through `jq` if you like.
- **CLI inspection and recovery.** `fable-monitor state inspect` prints JSON with
  `status`, `version`, and a payload-free `{line,reason}` diagnostic. `state
  recover` validates and restores `<state>.backup` after quarantining the active
  generation. `state rebaseline` quarantines the active generation and leaves
  state absent for the next poll. The mutation commands hold the state lock and
  print their action/paths/version as JSON.
- **Delivery operations.** `fable-monitor delivery list` shows sink status and
  `fable-monitor delivery retry [event_id|occurrence_id]` retries pending work.
  All configured sinks are required. Webhooks receive `Idempotency-Key`; every
  payload carries `occurrence_id` and `idempotency_key`. Consumers of stdout
  and notify must deduplicate on that key because a crash after side-effect
  success but before checkpoint can cause an at-least-once replay.
- **Editing for testing.** Because it's compressed you can't edit in place.
  Decompress, edit, recompress:

  ```sh
  zstd -dc state.jsonl.zst > state.jsonl
  # delete a `seen` line to re-report a document, change a `hash` to fire a
  # change, or delete a `model` line to re-arm an absent-to-present transition
  zstd -q -f -o state.jsonl.zst state.jsonl
  ```

- **Recovery audit.** Recovery writes `<state>.recovery.json` atomically with the
  action, epoch, state version, and applicable backup/quarantine paths. A
  quarantine is named `<state>.corrupt.<random>` and preserves the original
  bytes.

## Retention

State save keeps the newest 300 Federal Register stage/document keys and 500
feed keys per source. Settled alerts (`acknowledged` or `escalated`) older than
90 days are pruned; unresolved alerts are retained regardless of age. Completed
delivery records are pruned only after every sink in their occurrence succeeds,
so retention does not discard pending work. Each
save retains the validated prior generation at `<state>.backup`; this is a
single rollback point, not a substitute for independent operational backups.

## When you change the schema, update the docs

Per the [maintenance policy](README.md), changes to the `State` struct,
`StateRecord`, `capTail`, or `loadState`/`saveState` in `src/state.zig` must
update this file in the same change. A schema change that isn't backward
compatible should bump `current_version` and be noted in
[design-decisions.md](design-decisions.md).
