# Security model

Last reviewed: 2026-07-14 · against fable-monitor 0.1.0

## Trust boundaries

The monitor consumes untrusted public HTTP content through `curl`. Remote text
may reach logs, structured events, the dashboard, and the notification message.
It must remain data, never executable shell or AppleScript. The notify command
itself is trusted operator configuration and runs with the service account's
permissions; `tests/notify_quoting.sh` checks the packaged macOS fallback.

State and observation files are trusted local control data. Anyone able to alter
them can suppress, re-arm, or fabricate transitions. The dashboard is read-only
and loopback-bound, but a reverse proxy changes the exposure boundary and must
provide authentication, TLS, request limits, and access logging.

## Controls

- Run as an unprivileged dedicated account; keep durable and environment files
  private and grant no write access to the UI or downstream consumers.
- Store webhook/heartbeat credentials in the deployment secret mechanism, not
  source, command history, logs, backups without encryption, or release assets.
- Restrict outbound network access to configured sources and notification,
  webhook, and heartbeat endpoints where the platform supports it.
- Keep UI loopback-only. UI JavaScript/CSS is vendored and embedded; there is no
  CDN runtime dependency. The article reader is disabled unless
  `FABLE_MONITOR_READER=1`; keep it disabled on exposed deployments unless the
  residual DNS-rebinding and single-thread blocking risks in [ui.md](ui.md) are
  accepted.
- Actions are commit-pinned and the CI container is digest-pinned. Release
  archives receive checksums, SPDX SBOM, GitHub provenance, and keyless Sigstore
  bundles. Verify these before deployment as described in [release.md](release.md).
- CI uses read-only repository permissions except the tag release job, whose
  scoped write/OIDC permissions are required for publishing and signing.

## Residual risks

Fetching and parsing public sources does not establish that their publishers are
correct or uncompromised. Corroboration reduces but cannot eliminate false
signals. Delivery retries survive restart but can replay after a crash between a
successful side effect and its checkpoint. A compromised service account can
alter state or hooks. Downstream systems must authenticate events where
appropriate, deduplicate `occurrence_id`/`idempotency_key` (not the reusable
subject `event_id`), enforce their own risk controls, and fail closed.

State, event logs, lock files, atomic staging files, curl secret/config files,
and event-sink replacements are created or corrected to mode `0600`. Installers
set `umask 077`, durable directories to `0700`, and environment files to `0600`.
For local development run `chmod 600 .env`; the application does not currently
enforce local `.env` permissions because it does not load that file itself.

Report suspected vulnerabilities privately to repository maintainers. Do not
open a public issue containing exploit details or credentials. No repository
setting, branch-protection rule, credential rotation, secret-scanning service,
or response drill is asserted by this document; those controls require external
configuration and operator evidence. In particular, the review request to rotate
any credential found in a local ignored `.env` remains externally blocked and
must not be marked complete from repository changes.
