# Operations

Last reviewed: 2026-07-14 · against fable-monitor 0.1.0

This runbook defines operational targets and recovery procedures. They are
targets, not evidence that monitoring, branch protection, backups, or drills
have been configured on a particular deployment.

## Service objectives

| Objective | Target | Measurement |
|---|---|---|
| Poller availability | 99.5% successful scheduled runs over 30 days | Heartbeat arrivals plus scheduler exit status. |
| Tier-1 freshness | 99% of successful tier-1 polls start within 2x the configured fast interval | `status.last_poll_ms` via `audit`; account for the scheduler interval. |
| Source health | Every enabled source has a successful fetch within 2x its configured cadence | Daily `fable-monitor audit`; alert on overdue sources. |
| Fixture detection | Restoration fixture emits high-confidence model and statement events in under 5 seconds | `tests/e2e.sh` in CI. This is offline processing latency, not internet latency. |
| Notification delivery | High-confidence test alert reaches the external destination within 15 minutes | Deployment-specific canary; CI only validates safe command invocation. |

The heartbeat must alert after two missed expected runs and recover after one
successful run. A green heartbeat does not prove every source works, so run the
coverage audit independently. Record measured SLO results outside this repo.

## Routine checks

1. Check scheduler/service status and the latest nonzero exit.
2. Check heartbeat freshness and `fable-monitor audit` for overdue sources.
3. Run `fable-monitor delivery list`; investigate pending attempts and errors.
   `audit` also ends with separate pending and failed delivery totals.
4. Inspect stderr for repeated fetch, state-save, webhook, or zstd errors.
5. Confirm disk space and the age/size of state, event log, and pending alerts.
6. After upgrades, verify the deployed tag/commit, artifact checksum,
   `preflight --json`, local `/healthz` and `/readyz`, and one healthy poll.

## Backup and restore

Back up the durable directory, including `state.jsonl.zst`, the complete logical
event log (`events.jsonl.zst`, `.manifest`, `.manifest.backup`, `.lock`, and
`.segments/`), pending alert files, the selected UI port, and deployment
environment metadata.
Do not include secret values in a broadly readable archive. Because poll writes
state atomically but the log is a separate file, stop the poller or snapshot the
filesystem to obtain a consistent pair.

Recommended targets: encrypted daily backups, 30 daily copies and 12 monthly
copies, stored in a separate failure domain. Restrict backup and durable files
to the service account (`0700` directory, `0600` files where practical).

Restore procedure:

1. Stop the poller and UI; preserve the failed directory for investigation.
2. Run `fable-monitor state inspect`. If the active generation is invalid and its
   fixed last-known-good backup is valid, `state recover` performs a locked,
   audited restore; use `state rebaseline` only with explicit incident approval.
3. If the event log reads through `.manifest.backup`, stop the poller and run
   `fable-monitor log recover`; it restores the primary only after validating
   every component referenced by the backup. Restore external backup data to a
   new private directory when local state or manifest recovery is insufficient.
   Validate state and every event base/segment
   with `zstd -t`; inspect the manifest and representative JSON through
   `fable-monitor log --plain` without editing.
4. Point `FABLE_MONITOR_STATE` and `FABLE_MONITOR_LOG` at the restored files.
5. Run `fable-monitor audit`, `fable-monitor export /tmp/fable-restore-check`,
   and the DuckDB checks in [data-export.md](data-export.md).
6. Run `preflight --json`, restart the UI, verify `/healthz` and `/readyz`, then restart
   the poller.
7. Watch one complete cadence and pending notifications before closing recovery.

Deleting or restoring an old state can re-arm historical transitions. Suppress
external automation during validation and reconcile emitted event identities.
No restore drill is represented as complete until its result and timestamp are
recorded by the operator.

## Incident response

Severity guidance: SEV-1 is a false high-confidence restoration sent to an
automated consumer or a secret compromise; SEV-2 is total monitoring loss or
missed freshness SLO; SEV-3 is one degraded source or delayed UI.

1. Acknowledge and timestamp the incident; preserve logs, state, deployed
   checksum, commit, scheduler status, and relevant external responses.
2. Contain: disable downstream action first for false signals, stop the poller
   for state corruption, or revoke/rotate exposed webhook and heartbeat tokens.
3. Restore service from a verified release and backup, following the rollback
   procedure in [release.md](release.md).
4. Validate with offline E2E, `preflight --json`, `audit`, heartbeat, and destination
   delivery before re-enabling downstream action.
5. Document impact, timeline, root cause, corrective actions, and owners. Avoid
   publishing sensitive payloads or tokens in the incident record.

## Retention and deletion

The application caps Federal Register keys at 300 and feed keys at 500 per
source, prunes settled alerts after 90 days, and removes completed delivery
records only after their whole occurrence settles. Pending deliveries and
unresolved alerts are retained. The observation log automatically compacts to
the newest 100,000 events. Set `FABLE_MONITOR_MAX_EVENTS` to the required online
limit and use `fable-monitor log compact [max_events]` to enforce it
immediately. Back up the configured log path together with its `.manifest`,
`.manifest.backup`, `.lock`, and `.segments` sidecars. Operators should retain
archives for one year unless legal or privacy requirements demand less. Retain service logs 30 days
and release verification evidence for the lifetime of the release plus one
year. Securely delete expired backups according to the storage provider's
capabilities and record exceptions.

## Runbook ownership

Review this runbook quarterly and after incidents or architecture changes.
Schedule backup-restore and notification-delivery drills at least quarterly, but
track their execution externally; this document does not claim they occurred.
No operational owner, on-call rotation, drill result, backup job, or alerting
configuration has been evidenced in this repository as of the review date.
Assigning owners and completing restore, sink-outage, and rollback drills remain
external blockers to production readiness.
