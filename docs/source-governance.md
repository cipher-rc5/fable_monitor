# Source governance

Last reviewed: 2026-07-14 · against fable-monitor 0.1.0

This policy prevents a source from becoming authoritative through an unnoticed
configuration edit. It supplements the technical source model in
[sources.md](sources.md).

## Ownership

Each enabled source must have a deployment register entry containing source ID,
publisher, endpoint, tier, source family, expected cadence, terms or schema,
data classification, primary and backup role, last review, and next review.
Named owners are deliberately not asserted in this repository. A deployment is
not production-ready until management assigns and records those roles.

The primary role reviews health and publisher changes. The backup role can make
time-critical disable/restore decisions. Security reviews authenticated sources
and trust-boundary changes. A separate approver reviews tier-1 additions or any
change that reduces independent decisive coverage.

## Review policy

- Tier 1: monthly and after any unexpected content/schema/authentication change.
- Tier 2: quarterly.
- Tier 3: every six months.
- All tiers: immediately after incidents, redirects/domain changes, publisher
  ownership changes, sustained freshness failure, or detector changes.

A review verifies endpoint ownership and TLS destination, sample schema/content,
cadence, detector assumptions, false-positive/negative history, source-family
independence, credentials, legal/terms constraints, and fixture coverage. Record
evidence and decision externally; a changed `Last reviewed` stamp is not proof.

Adding or promoting a source requires fixtures for baseline, positive, malformed,
and plausible-decoy cases; updated threat/FMEA analysis; rollback criteria; and
review by the separate approver. Emergency disablement must record reason,
coverage impact, compensating controls, expiration, and restoration criteria.
Never reuse an ID or silently lower minimum decisive coverage.

Retire a source only after checking state/orphan effects, replacement coverage,
historical export needs, and alert rules. Preserve the register entry and reason.
