# Vulnerability reporting and support

Last reviewed: 2026-07-14 · against fable-monitor 0.1.0

## Reporting

Report suspected vulnerabilities privately through the repository host's
private security-advisory channel. If that channel is unavailable, contact the
maintainer through a private address published on their repository profile and
request an encrypted channel before sending exploit details. Do not open a
public issue or include live credentials, personal data, or destructive proof.

Include affected version/commit and platform, prerequisites, minimal
reproduction, impact, logs with secrets removed, and any suggested mitigation.
The project will attempt acknowledgement within 3 business days, triage within
7, and a status update at least every 7 days until resolution. These are targets,
not a warranty or evidence that a response team has been assigned.

Coordinated disclosure defaults to 90 days after acknowledgement, shortened for
active exploitation or extended by mutual agreement. A fix should include tests,
an advisory, affected/fixed versions, mitigations, and release verification.
Rotate exposed credentials independently of the software release.

## Support window

Until a 1.0 release, only the latest published version is supported. A new
release ends routine support for the prior release immediately; for 30 calendar
days the project may backport a critical security fix when upgrading is not
practical. After 1.0, the latest minor release is supported until 90 days after
the next minor release; only the latest patch in a supported minor receives
fixes. Unsupported versions may receive public mitigations but no fix commitment.

Support covers reproducible defects in the shipped source and release artifacts.
It excludes upstream content correctness, custom hooks/configuration, modified
binaries, unsupported platforms, downstream automation, and deployment/on-call
operation. Security fixes may remove compatibility when needed to fail safely.

No maintainer, security owner, funding, or response coverage is approved by this
policy. Deployments requiring contractual response times must establish their
own staffed support arrangement.
