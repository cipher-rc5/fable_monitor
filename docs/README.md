# fable-monitor documentation

Technical documentation for the `fable-monitor` codebase. The top-level
[`../README.md`](../README.md) is the user-facing quick-start; these documents
go deeper into how the tool works and *why* it is built the way it is.

## Index

| Document | Covers |
|---|---|
| [architecture.md](architecture.md) | Components, data flow, the one-run-one-poll lifecycle. |
| [design-decisions.md](design-decisions.md) | Rationale for the major choices (ADR-style). |
| [sources.md](sources.md) | The watched sources and how to add or tune one. |
| [state-format.md](state-format.md) | The JSON state file: schema, lifecycle, capping. |
| [data-export.md](data-export.md) | The observation log and the `export` subcommand (NDJSON → Parquet). |
| [banner.md](banner.md) | The `banner` subcommand (renders text with the bundled TrueType font). |
| [deployment.md](deployment.md) | Running under launchd/cron, env vars, the notify hook. |
| [development.md](development.md) | Build, test, the justfile, and the doc-maintenance policy. |

## Documentation-maintenance policy

Documentation rots when it drifts from the code. To keep these documents
current, we follow three rules:

1. **Docs are part of the change, not a follow-up.** A pull request that changes
   behavior must update the affected document(s) in the *same* PR. The
   code→doc map below says which doc each area maps to. CI does not (yet)
   enforce this, so reviewers are the backstop — treat a behavior change with
   stale docs as an incomplete PR.

2. **Every document carries a review stamp.** Each doc starts with a
   `Last reviewed:` line naming the date and the version it was checked against.
   When you touch a document, update that line. When you cut a release, skim
   every doc and refresh the stamp even if nothing changed — a recent stamp is
   the signal that the content was actually re-verified.

3. **The map is the contract.** If you add a new subsystem, add a row to the
   code→doc map and a `Last reviewed:` stamp to whatever document describes it.

### Code → doc map

| If you change… | Update… |
|---|---|
| The `sources` array, `keywords`, or `Source`/`SourceKind` in `src/sources.zig` | [sources.md](sources.md), and the "What it watches" section of the top-level README |
| The `State` struct, `capTail`, or `loadState`/`saveState` in `src/state.zig` | [state-format.md](state-format.md) |
| `src/parquet.zig`, the `Event` struct (`src/events.zig`), `events.appendLog`, `src/export.zig` (`exportParquet`), `src/view.zig` (the `log` reader), or the `export`/`log` subcommands | [data-export.md](data-export.md) |
| `httpGet`/`toolAvailable` (`src/fetch.zig`), the `zstd.*` helpers (`src/zstd.zig`), `extractKeywordContext`/`normalizeHtml` (`src/html.zig`), or the poll flow in `src/main.zig` | [architecture.md](architecture.md) |
| `src/banner.zig`, the `banner` subcommand, or the bundled font in `src/assets/` | [banner.md](banner.md) |
| Why a dependency / approach was chosen (e.g. dropping curl, adding a real HTTP client) | [design-decisions.md](design-decisions.md) |
| Env vars, the notify hook, the plist, or scheduling | [deployment.md](deployment.md), and the README |
| `build.zig`, `build.zig.zon`, the `justfile`, tests, or CI | [development.md](development.md) |

---

Last reviewed: 2026-06-18 · against fable-monitor 0.1.0
