# Release and rollback

Last reviewed: 2026-07-15 · against fable-monitor 0.1.0

## Prepare

1. Update only `build.zig.zon`'s `version`; it is the binary version source.
2. Run `just ci`. Review dependency pins, operational docs, and all outstanding
   changes. Do not release from an unreviewed dirty tree.
3. Create an annotated `v<version>` tag on the reviewed commit and push it.
   Repository branch protection and required approvals must be configured on
   GitHub; this repository cannot claim those external settings are enabled.

`.github/workflows/release.yml` requires the tag to equal the package version.
It builds ReleaseSafe archives with `-Dcpu=baseline` for Linux (static musl) and
macOS on x86_64 and aarch64. It publishes SHA-256 checksums, an SPDX JSON SBOM, GitHub
artifact provenance, and keyless Sigstore bundles. Workflow actions are pinned
to verified commits. A manual dispatch builds artifacts for validation but does
not publish a release.

This is implemented workflow code, not proof that a release run succeeded or
that tag signing/branch policy is enforced. Record the workflow URL,
attestation verification, SBOM review, and signer/tag evidence for each release.

## Verify and deploy

Deploy an immutable `v<version>` asset, never a mutable branch build. Download
release assets into an empty directory, then verify:

```sh
sha256sum -c SHA256SUMS
cosign verify-blob \
  --bundle SHA256SUMS.sigstore.json \
  --certificate-identity-regexp 'https://github.com/cipher-rc5/fable_monitor/.github/workflows/release.yml@refs/tags/v.*' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  SHA256SUMS
gh attestation verify fable-monitor-*.tar.gz --repo cipher-rc5/fable_monitor
```

Also inspect the SBOM and confirm the GitHub workflow run belongs to the tag's
commit. Stage the archive, run `preflight --json`, back up durable data, stop the old
service, replace only the binary, and restart. Verify service status, `/healthz`,
`/readyz`, `audit`, delivery backlog, heartbeat, and one healthy poll before
declaring deployment successful.

## Verifying a release

Consumer-side verification of a published `v<version>` release. Each release
(`.github/workflows/release.yml`) attaches, per tag:

- per-target archives `fable-monitor-<platform>-*.tar.gz`
  (`linux-x86_64`, `linux-aarch64`, `macos-x86_64`, `macos-aarch64`);
- an SPDX SBOM `fable-monitor-v<version>.spdx.json`;
- a `SHA256SUMS` manifest covering the archives and the SBOM;
- a GitHub build-provenance attestation for the archives; and
- keyless cosign (Sigstore) bundles `<file>.sigstore.json` for each `.tar.gz`,
  the `.spdx.json`, and `SHA256SUMS`.

Download every asset for the tag into an empty directory, then verify all three
independent controls. Any failure means do not deploy the artifact.

**(a) Checksums.** Confirm the bytes match the signed manifest:

```sh
sha256sum -c SHA256SUMS
```

**(b) Cosign signatures.** Each signed file has a sidecar bundle. The signing
identity is this repository's release workflow, and the OIDC issuer is GitHub
Actions. Verify the checksum manifest (and, the same way, any archive or the
SBOM by swapping the target and its `.sigstore.json`):

```sh
cosign verify-blob \
  --bundle SHA256SUMS.sigstore.json \
  --certificate-identity-regexp 'https://github.com/cipher-rc5/fable_monitor/.github/workflows/release.yml@refs/tags/v.*' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  SHA256SUMS

# and, for the archive you intend to deploy:
cosign verify-blob \
  --bundle fable-monitor-linux-x86_64-*.tar.gz.sigstore.json \
  --certificate-identity-regexp 'https://github.com/cipher-rc5/fable_monitor/.github/workflows/release.yml@refs/tags/v.*' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  fable-monitor-linux-x86_64-*.tar.gz
```

**(c) Build-provenance attestation.** Verify the GitHub-issued attestation ties
the archive to a workflow run in this repository (requires `gh auth login`):

```sh
gh attestation verify fable-monitor-*.tar.gz --repo cipher-rc5/fable_monitor
```

Only after all three pass should you inspect the SBOM and confirm the workflow
run belongs to the tag's commit, then proceed to stage and deploy as above.

## Rollback

The current binary writes v5 and reads v1-v5 state. Saving v1-v4 migrates it to
v5; tokenless v4 delivery leases are cleared and status timestamps are normalized
to the v5 ordering invariant. A rollback may
not understand records introduced by a newer release. Before every deployment,
take a consistent backup of state/log and retain the previous verified binary.

1. Stop poller and UI; disable downstream actions if signal correctness is in
   question.
2. Restore the previous verified binary. Restore its matching pre-upgrade state
   only if the release changed persistence semantics or state appears damaged.
3. Run `preflight --json` and `audit`; start the UI, verify `/healthz` and `/readyz`,
   then start the poller.
4. Observe a full cadence and reconcile duplicate or missed event identities
   before re-enabling downstream action.
5. Mark the bad GitHub release as withdrawn or add an explicit warning. Do not
   move or overwrite a published tag; issue a new patch version for the fix.

Rollback completion and restore drills require operator evidence; this document
does not claim either has been performed.
