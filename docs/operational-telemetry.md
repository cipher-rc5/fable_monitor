# Operational telemetry

Last reviewed: 2026-07-14 · against fable-monitor 0.1.0

This contract separates diagnostics on stderr, durable state, and alert events
on stdout. Alert consumers must not parse stderr, and telemetry collectors must
not treat stdout alert events as process logs.

## JSON logging

`context.logJson` and `Context.telemetry` emit one JSON object per stderr line.
They are incremental APIs: the existing `[fable-monitor]` text logger remains
unchanged, so a deployment may contain both formats during migration. Every
JSON diagnostic has these stable fields:

| Field | Contract |
|---|---|
| `level` | `debug`, `info`, `warn`, or `err`. |
| `event` | Stable snake-case event name suitable for routing. |
| `run` | Correlation value, normally an explicit run ID or the run timestamp. |
| `source` | Source ID, or an empty string when not source-specific. |
| `error` | Zig error name or external error class, or an empty string. |
| `message` | Human-readable detail; never use it for routing. |

Callers must keep credentials and fetched response bodies out of every field.
Collectors should parse lines beginning with `{` as JSON and retain other lines
as legacy text. An encoding failure falls back to a text diagnostic on stderr.

## Metric contract

Run `scripts/export-metrics.py --state STATE --log LOG --diagnostic-log STDERR`
to emit Prometheus text format. The helper is read-only and invokes `zstd`
without a shell. Write output to a temporary file and rename it into a node
exporter textfile directory; do not let a failed invocation replace a good file.

| Metric | Meaning |
|---|---|
| `fable_monitor_source_freshness_seconds{source}` | Age of last successful fetch; `-1` means no success recorded. |
| `fable_monitor_delivery_backlog` | Pending sink records in state. |
| `fable_monitor_delivery_retry_overdue_seconds` | Oldest amount by which `next_retry_ms` is overdue. |
| `fable_monitor_state_size_bytes` | State plus known sidecars. |
| `fable_monitor_log_size_bytes` | Event base, manifest, lock, and segment bytes. |
| `fable_monitor_disk_available_bytes` | Space available to the service account on the state filesystem. |
| `fable_monitor_poll_duration_seconds` | Latest whole-poll duration parsed from the diagnostic log. |
| `fable_monitor_poll_duration_available` | `1` when duration was found, otherwise `0`. |
| `fable_monitor_consecutive_failures_available` | Always `0` for state v5 because this counter is not durable. |

Do not infer consecutive failures from `last_poll_ms - last_success_ms`: skipped
cadences and process failures make that incorrect. Scheduler exit history is the
authoritative input until a future state schema persists the counter.

Suggested alerts, to tune from observed baselines: freshness above twice the
configured source cadence, backlog above zero for two runs, retry overdue above
15 minutes, disk below 100 MiB, missing poll duration for two expected runs, and
rapid state/log growth. These are design defaults, not evidence alerts exist.

## Collection safety

Metrics may reveal source names and operational timing. Bind the collector to a
management interface, authenticate remote access, cap retention, and avoid
including alert payloads or URLs as labels. Use source ID as the only unbounded
label. Collection failure must alert independently and must never stop polling.
