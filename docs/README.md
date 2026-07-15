# fable-monitor documentation

Technical documentation for the `fable-monitor` codebase. The top-level
[`../README.md`](../README.md) is the user-facing quick-start; these documents
go deeper into how the tool works and *why* it is built the way it is.

## Index

| Document | Covers |
|---|---|
| [architecture.md](architecture.md) | Modules, poll outcomes, fetch -> detect -> commit -> deliver, and event lifecycle. |
| [design-decisions.md](design-decisions.md) | Rationale for the major choices (ADR-style). |
| [sources.md](sources.md) | The tier model, the JSON source config, source kinds, and toggles. |
| [state-format.md](state-format.md) | The compressed JSONL state file: v5 schema, lease fencing, migration, recovery, and retention. |
| [data-export.md](data-export.md) | Observation storage, manifest recovery, `log` / `view`, and Parquet export. |
| [ui.md](ui.md) | The `serve` subcommand: local assets, probes, and the default-disabled reader. |
| [banner.md](banner.md) | The `banner` subcommand (renders text with the bundled TrueType font). |
| [deployment.md](deployment.md) | Running under launchd/cron, env vars, the notify hook. |
| [development.md](development.md) | Build, test, the justfile, and the doc-maintenance policy. |
| [operations.md](operations.md) | SLOs, monitoring, backup/restore, incidents, retention, and recovery. |
| [operational-telemetry.md](operational-telemetry.md) | JSON diagnostic schema and Prometheus metric export contract. |
| [fmea.md](fmea.md) | Operational failure modes, effects, controls, and review triggers. |
| [source-governance.md](source-governance.md) | Source ownership register requirements and review policy. |
| [incident-runbook.md](incident-runbook.md) | Detection, containment, diagnosis, recovery, and closure checklist. |
| [security.md](security.md) | Trust boundaries, secrets, network exposure, and supply-chain controls. |
| [threat-model.md](threat-model.md) | Assets, trust boundaries, threats, mitigations, and residual risks. |
| [security-support.md](security-support.md) | Private vulnerability reporting and supported-version window. |
| [release.md](release.md) | Baseline-CPU release process, verification, and rollback. |

## Documentation-maintenance policy

Documentation rots when it drifts from the code. To keep these documents
current, we follow three rules:

1. **Docs are part of the change, not a follow-up.** A pull request that changes
   behavior must update the affected document(s) in the *same* PR. The
   code→doc map below says which doc each area maps to. `tests/docs_schema.sh`
   enforces local links, review stamps, and the documented source kinds; reviewers
   remain responsible for behavioral accuracy.

2. **Every document carries a review stamp.** Each doc starts with a
   `Last reviewed:` line naming the date and the version it was checked against.
   When you touch a document, update that line. When you cut a release, skim
   every doc and refresh the stamp even if nothing changed, a recent stamp is
   the signal that the content was actually re-verified.

3. **The map is the contract.** If you add a new subsystem, add a row to the
   code→doc map and a `Last reviewed:` stamp to whatever document describes it.

### Code → doc map

| If you change… | Update… |
|---|---|
| The `Source`/`SourceKind`/`Tier` types or vocabularies in `src/sources.zig`, the config schema in `src/config.zig`, or the default config in `src/sources_default.json` | [sources.md](sources.md), and the "What it watches" section of the top-level README |
| The `State` struct, `StateRecord`, `capTail`, or `loadState`/`saveState` in `src/state.zig` | [state-format.md](state-format.md) |
| `src/parquet.zig`, the `Event` struct (`src/events.zig`), `events.appendLog`, `src/export.zig` (`exportParquet`), `src/view.zig` (the `log` reader), or the `export`/`log` subcommands | [data-export.md](data-export.md) |
| The poll pipeline / detectors / trip logic in `src/poll.zig`, `fetch.*` (`src/fetch.zig`), `feed.parse` (`src/feed.zig`), the `zstd.*` helpers (`src/zstd.zig`), `extractKeywordContext`/`normalizeHtml` (`src/html.zig`), or arg dispatch in `src/main.zig` | [architecture.md](architecture.md) |
| `src/serve.zig`, `src/serve/*`, the `serve` subcommand, probes, reader, or `/ui/*` endpoints | [ui.md](ui.md) |
| `src/banner.zig`, the `banner` subcommand, or the bundled font in `src/assets/` | [banner.md](banner.md) |
| Why a dependency / approach was chosen (e.g. dropping curl, adding a real HTTP client) | [design-decisions.md](design-decisions.md) |
| Env vars, the notify hook, the structured-event schema, the plist, `dist/install-linux.sh`, or scheduling | [deployment.md](deployment.md), and the README |
| `build.zig`, `build.zig.zon`, the `justfile`, tests, CI, `src/stats.zig`, or resource measurement | [development.md](development.md) |
| Release workflows, packaging, signing, or rollback | [release.md](release.md) |
| Production SLOs, backup, retention, or incident response | [operations.md](operations.md) |
| `src/context.zig` logging or `scripts/export-metrics.py` | [operational-telemetry.md](operational-telemetry.md) |
| Source ownership, approval, review cadence, or retirement | [source-governance.md](source-governance.md) |
| Trust boundaries, secrets, exposure, or supply-chain controls | [security.md](security.md) |
| Threat analysis, vulnerability handling, or version support | [threat-model.md](threat-model.md), [security-support.md](security-support.md) |

---

Last reviewed: 2026-07-14 · against fable-monitor 0.1.0
