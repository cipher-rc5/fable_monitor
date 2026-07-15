# Failure mode and effects analysis

Last reviewed: 2026-07-14 · against fable-monitor 0.1.0

Scores are planning aids: severity (S), occurrence (O), and detectability (D)
range from 1 (low/easy) to 5 (high/hard). RPN is `S x O x D`; values are not
measured incident rates. No control or drill is claimed operational here.

## Failure modes

| Failure | Effect | S/O/D (RPN) | Existing control/detection | Required response or gap |
|---|---|---:|---|---|
| Scheduler or host stops | All detections become stale | 5/2/2 (20) | External heartbeat and exit status are designed | Configure independent missed-run alert; verify scheduler. |
| One source changes schema or blocks egress | Coverage and confidence fall | 4/3/2 (24) | Per-source isolation, audit, freshness metric | Triage response/schema; disable only with documented risk acceptance. |
| All decisive sources stale | Restoration may be missed | 5/2/1 (10) | Poll fails closed on minimum coverage | Escalate SEV-2; restore one independent decisive path. |
| False decisive signal | Unsafe downstream action | 5/2/3 (30) | Exact transitions, source tiers, consumer dedup | Disable automation, preserve evidence, validate publisher content. |
| State corruption or rollback | Suppression or replay of events | 5/2/2 (20) | Strict parse, atomic save, backups | Stop writes; preserve directory; restore and reconcile identities. |
| Disk full | State/log commit fails; polling fails | 4/3/1 (12) | Atomic writes, preflight, disk metric | Free or expand disk without deleting evidence; validate files. |
| Sink outage | Alert delivery delayed or repeated | 5/3/1 (15) | Durable outbox, retries, backlog metric | Protect downstream action; repair sink; manually retry with dedup. |
| Crash after sink side effect | Duplicate delivery | 3/2/3 (18) | Occurrence idempotency key | Consumer must deduplicate; reconcile before retry. |
| Credential exposure | Sink abuse or data compromise | 5/2/3 (30) | Secret handling and redaction policy | Revoke first, preserve evidence, rotate and review access. |
| Log/metric collector fails | Degradation becomes less visible | 3/3/3 (27) | Polling is independent of collection | Alert on collector absence from a separate system. |
| Upstream publisher compromised | Plausible false source evidence | 5/1/5 (25) | Corroboration and source-family rules | Verify out of band; downstream must retain independent controls. |

## Review triggers

Re-score quarterly and after an incident, source/schema change, new delivery
sink, state-format migration, deployment-topology change, or material threat
intelligence. Record reviewer, evidence, changed score, accepted residual risk,
and due date outside this document. Roles remain unassigned until deployment
management explicitly assigns them; no listed control implies owner approval.
