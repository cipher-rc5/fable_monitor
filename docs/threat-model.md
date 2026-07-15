# Threat model

Last reviewed: 2026-07-14 · against fable-monitor 0.1.0

Scope includes source fetch, local state/logging, scheduler, dashboard, delivery
sinks, release artifacts, and the operator. It excludes the internal security of
upstream publishers and downstream automated consumers.

## Assets

- Correctness and timeliness of restoration decisions.
- Integrity and availability of state, outbox, event history, and configuration.
- API, webhook, heartbeat, signing, and deployment credentials.
- Authentic release artifacts and operational evidence.
- Availability of the host, disk, scheduler, and notification path.

Trust crosses from public publishers into `curl` and parsers; from operator
configuration into commands and credentials; from the process into local
durable files; from the outbox into external sinks; and, when enabled, from the
loopback dashboard through any reverse proxy. Public content is always untrusted
data. Local state is security-sensitive control data, not inherently trustworthy
when the service account or filesystem is compromised.

## Threats

| Threat | Consequence | Principal mitigations | Residual risk |
|---|---|---|---|
| Malicious/compromised source content | False alert, parser pressure, injection | Exact typed parsing, size limits, no shell interpolation, tiers/corroboration | Legitimate-looking publisher compromise remains possible. |
| DNS/redirect/egress manipulation | Fetch attacker-controlled content or leak auth | TLS, no redirects for source/sink requests, reader public-IP validation and DNS pinning | Host resolver and CA compromise remain trusted for normal source polling. |
| Config/state tampering | Suppress, fabricate, or replay transitions | Dedicated account, `0600` files, atomic strict state parsing | Account compromise defeats local controls. |
| Command-hook injection | Code execution as service account | Trusted hook config; remote text passed as argv data | A malicious operator-configured hook is intentionally executable. |
| Credential disclosure | Sink/API impersonation | Secret manager, redaction, private env files, rotation | Process/account readers can access runtime secrets. |
| Sink replay or spoofing | Duplicate/forged downstream action | TLS, idempotency key, consumer authentication/dedup | Crash window provides at-least-once duplicates. |
| Dashboard exposure/reader SSRF-like use | Information leak, internal requests, DoS | Loopback default, reader disabled, proxy auth/rate limits | Reverse proxy and DNS-rebinding risks are operator-owned. |
| Dependency/release compromise | Arbitrary code execution | Pinned CI, checksums, SBOM, provenance/signatures | Build platform and toolchain remain trusted. |
| Resource exhaustion | Missed polls or failed persistence | Fetch cap, bounded retention, disk/size metrics | Serial long responses and disk exhaustion still degrade service. |
| Log forging/secret logging | Mis-triage or disclosure | JSON escaping, fixed routing fields, no body/secret logging | Legacy text is not authenticated and local writers may forge lines. |

Security assumptions and controls must be revisited for a new protocol, source
kind, sink, externally exposed UI, privilege change, or multi-host deployment.
See [security.md](security.md) and [security-support.md](security-support.md).
