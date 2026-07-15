# Security Policy

Last reviewed: 2026-07-15

This is a summary of the full [vulnerability-reporting and support
policy](docs/security-support.md); consult that document for detail. The targets
and windows below match it.

## Reporting a vulnerability

Report suspected vulnerabilities **privately**. Do not open a public issue and
do not include live credentials, personal data, or destructive proof.

- Preferred: use this repository's **private security-advisory** channel on
  GitHub ("Report a vulnerability" in the Security tab).
- Fallback: if that channel is unavailable, contact the maintainer through a
  private address published on their repository profile and request an encrypted
  channel before sending exploit details.

Include the affected version/commit and platform, prerequisites, a minimal
reproduction, the impact, logs with secrets removed, and any suggested
mitigation.

## Response targets

These are targets, not a warranty or evidence that a response team has been
assigned:

- Acknowledgement within **3 business days**.
- Triage within **7 days**.
- A status update at least every **7 days** until resolution.

Coordinated disclosure defaults to **90 days** after acknowledgement, shortened
for active exploitation or extended by mutual agreement. Rotate exposed
credentials independently of the software release.

## Supported versions

Until a 1.0 release, only the latest published version is supported. A new
release ends routine support for the prior release immediately; for 30 calendar
days the project may backport a critical security fix when upgrading is not
practical. See [docs/security-support.md](docs/security-support.md) for the
post-1.0 window and the full support scope.
