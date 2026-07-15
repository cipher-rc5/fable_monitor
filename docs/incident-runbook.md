# Incident runbook

Last reviewed: 2026-07-14 · against fable-monitor 0.1.0

This is a decision checklist, not evidence of an on-call rotation or completed
exercise. Record timestamps in UTC and preserve originals before remediation.

## Detection

Triggers include two missed runs, stale decisive-source freshness, nonzero
delivery backlog across two runs, retry overdue 15 minutes, state/log growth,
low disk, failed readiness, a false or missing alert report, or suspected secret
exposure. SEV-1 covers unsafe false signals or credential compromise; SEV-2
covers total monitoring loss or missed freshness; SEV-3 covers isolated source
or UI degradation. The assigned incident commander may raise severity.

## Immediate actions

1. Open an incident record with detector, UTC start, current severity, and roles.
2. Preserve state/log plus sidecars, stderr/stdout, scheduler status, environment
   names with values redacted, binary checksum/version, and relevant responses.
3. For false signals, disable downstream action before changing the monitor.
4. For corruption, stop poller and UI writes; do not compact or retry delivery.
5. For credential exposure, revoke the credential before investigation or rotate
   it, then inspect access and sink histories.
6. Establish a communication cadence and an approved internal channel. Do not
   paste credentials, raw payloads, or sensitive evidence into broad channels.

## Diagnosis

Check scheduler/host, disk/inodes and permissions, deployed checksum, state with
`zstd -t`, `audit`, `delivery list`, required-source freshness, source HTTP/schema,
DNS/TLS/redirects, heartbeat, and destination status. Compare against a known
release and offline fixtures. Build a UTC timeline separating observations from
hypotheses; preserve failed artifacts rather than editing them in place.

For a source outage, determine whether independent decisive coverage remains and
whether emergency disablement is safer than continued failure. For backlog,
confirm consumer idempotency before retry. For disk pressure, expand capacity or
move an intact snapshot; do not delete pending state or the newest evidence.

## Recovery

Restore a verified release and consistent backup into a new private directory.
Validate compressed files and representative records, run offline E2E and
`preflight --json`, then `audit`, readiness, one poll, heartbeat, and sink delivery.
Reconcile occurrence IDs with consumers before `delivery retry`. Re-enable
downstream automation only after the incident commander documents validation and
remaining risk. Roll back using [release.md](release.md) if validation fails.

## Closure

Document scope, user/decision impact, detection and recovery times, root and
contributing causes, evidence links, decisions, and corrective actions with due
dates. Review whether telemetry, FMEA, source register, threat model, tests, and
runbooks need updates. Notify affected parties under applicable policy. Store
evidence with access and retention controls.

Required exercises are restore, source outage, sink outage/replay, disk full,
false signal, credential rotation, and release rollback, at least annually and
after material changes. Their schedules/results belong in the deployment's
evidence system. This repository records no completed drill and no approved
incident owner.
