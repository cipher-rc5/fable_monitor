# Development

Last reviewed: 2026-07-14 · against fable-monitor 0.1.0

How to build, test, and contribute to `fable-monitor`, plus the policy that
keeps this documentation current.

## Requirements

- **Zig 0.16.0 or newer** (pinned via `minimum_zig_version` in `build.zig.zon`).
- **`curl`** on `PATH`, only needed to *run* a live poll, not to build or test.
- **`zstd`** on `PATH`, needed to *run* either mode (the tool compresses its
  state, log, and Parquet outputs with it); not needed to build or test.
  `brew install zstd` on macOS if missing.
- **`just`** (optional), task runner; `brew install just`.
- **`duckdb`** (optional), handy for verifying Parquet output end-to-end.

## Project layout

```
build.zig            # build graph: exe, run, test, check, build_options
build.zig.zon        # package manifest (name, version, min Zig, fingerprint)
LICENSE              # MIT license
justfile             # task-runner recipes (wraps zig build + conventions)
src/main.zig         # CLI entrypoint: arg dispatch, poll loop, alerting, test root
src/context.zig      # shared per-run Context type and the log helper
src/sources.zig      # Source/SourceKind, the sources array, keywords
src/fetch.zig        # httpGet + toolAvailable (network I/O via curl)
src/html.zig         # normalizeHtml, extractKeywordContext, containsAny (pure text)
src/state.zig        # State, loadState/saveState, capTail
src/events.zig       # Event model, event kinds, isoUtc, appendLog
src/zstd.zig         # compress/decompress/compressor (system zstd binary)
src/export.zig       # exportParquet and the per-table export helpers
src/view.zig         # the `log` subcommand: formatted terminal reader
src/stats.zig        # opt-in getrusage self-report (FABLE_MONITOR_STATS=1)
src/parquet.zig      # minimal std-only Parquet writer (used by `export`)
src/banner.zig       # from-scratch TrueType rasterizer (the `banner` subcommand)
src/assets/          # bundled font (ManufacturingConsent-Regular.ttf) + OFL.txt
dist/                # launchd plist template + install/uninstall scripts
scripts/             # standalone tooling (analyze.py, resource analysis)
docs/                # this documentation set
.github/workflows/   # CI
```

## Build graph (`build.zig`)

| Step | Command | What it does |
|---|---|---|
| install | `zig build` | Compile and install `zig-out/bin/fable-monitor`. |
| run | `zig build run` | Build, then run one poll. Forwards extra args. |
| test | `zig build test` | Compile and run the unit tests. `src/main.zig` is the test root and references every sibling module, so each module's own tests run. |
| check | `zig build check` | Type-check only, no binary, fast feedback / LSP. |

The exe, test, and check targets all share one `root_module`, so they stay in
sync automatically.

## Tests

Unit tests live next to the code they cover. The current suite has **147 tests**.
`src/html.zig` covers the pure text
logic (`normalizeHtml`, `containsAny`, `extractKeywordContext`) and `src/state.zig`
covers `capTail` and the `State` lookups; `src/parquet.zig` adds tests for the
Parquet encoder's primitives (zigzag varints, compact field headers, the file
envelope). `src/main.zig` is the test root: its `test {}` block references every
module (`_ = parquet;`, `_ = @import("html.zig");`, …) so all of those tests run
under `zig build test`. They need no network. The suite includes v5 lease/status
invariants, corrupt-state inspection, last-known-good recovery/rebaseline audit,
segmented-log failure modes, strict configuration, preflight JSON, delivery
retry/fencing, reader SSRF policy, and UI delivery totals. Shell integration
tests cover fixture restoration, state compatibility, installer transactions and
hostile values, documentation/source schema, 2x log capacity, and DuckDB Parquet
interoperability.

Parquet **format** correctness can't be checked by std-only Zig (it can't parse
Parquet back), so verify it by reading an exported file with a real reader; the
recipe is in [data-export.md](data-export.md).

```sh
zig build test --summary all     # or: just test
```

When adding logic, prefer extracting a pure function and unit-testing it (as the
existing helpers are) over testing through the network paths.

## Task runner (`justfile`)

`just` is a language-agnostic command runner layered over `zig build`; it is not
Zig-specific and not required. Run `just` (or `just --list`) to see all recipes.
The most useful:

| Recipe | Purpose |
|---|---|
| `just ci` | Formatting, 147 unit tests, build, E2E/notify/installer/env/state/log/docs/scanner/Parquet/package tests, and ShellCheck; the full pre-push gate. |
| `just demo` | Baseline run + no-change run against a temp state file. |
| `just run` | One real poll against a throwaway state file. |
| `just export` | Write Parquet tables (`events`, `state_seen`, `state_keyword_hashes`) to `./parquet`. |
| `just install` / `just uninstall` | Install/remove the macOS launchd background agent (see [deployment.md](deployment.md)). |
| `just status` / `just logs` | Inspect the installed agent's state and its alert/diagnostic logs. |
| `just measure` | Peak RSS + CPU of each subcommand, one shot (see Resource usage below). |
| `just analyze` | Aggregated resource stats over N samples + CSV (`scripts/analyze.py`). |
| `just clean` | Remove `zig-out`, `.zig-cache`, the `parquet` export dir, and demo state. |

The run/demo/notify recipes default `FABLE_MONITOR_STATE` to a `/tmp` path so
development runs never touch real scheduled state.

## CI

`.github/workflows/ci.yml` runs on every push and pull request. It installs Zig
0.16.0 and the validation dependencies, then invokes the same `scripts/ci.sh`
gate as `just ci`, including the offline restoration E2E, hostile-input notify
and installer tests, state compatibility, log capacity, documentation links and
source schema, scanner configuration, ShellCheck, DuckDB Parquet
interoperability, and clean-tree release packaging. Actions and the betterleaks
image are pinned by commit/digest. Keep Zig in step with `minimum_zig_version` in
`build.zig.zon`. Run `just ci` locally to reproduce the gate before pushing.

A separate scheduled workflow contains a sanitized one-source live canary, but
it runs only when repository variable `ENABLE_LIVE_CANARY=true`; workflow
presence is not evidence that a hosted canary has passed. Reliable Zig 0.16 code
coverage tooling remains unavailable, so `scripts/ci.sh` reports that blocker
rather than publishing a false threshold.

## Formatting

`zig fmt` is the authority; CI enforces `zig fmt --check`. Use `just fmt` to
format in place before committing.

## Editor / language server (ZLS)

The version string is injected by `build.zig` as a generated `build_options`
module (`@import("build_options")` in `src/main.zig`; see the Releasing section).
That module only exists once `build.zig` runs, so a language server that
analyzes the source statically reports *"no module named 'build_options'"*. The
committed [`zls.json`](../zls.json) fixes this by enabling build-on-save against
the `check` step, which makes ZLS evaluate `build.zig` and pick up the module , 
reload your editor/ZLS after first checkout for it to take effect. `zig build`
and `zig build test` are unaffected either way.

## Resource usage

The tool is one-shot: each invocation is a fresh, short-lived process that
allocates from a single arena and frees everything on exit (decision 8), so
there is **no cross-run growth to chase**, what matters is per-invocation peak
memory and CPU, plus on-disk growth of the log.

Measure it with:

```sh
just measure        # builds ReleaseSafe, times each subcommand
```

It runs each subcommand under macOS `/usr/bin/time -l` (peak RSS, CPU) and then
prints the built-in self-report, which **also** accounts for the `curl`/`zstd`
child processes that `time -l` on the parent misses. Representative numbers
(ReleaseSafe, ~2.7 MB binary):

| Subcommand | Process peak RSS | Children (curl/zstd) | CPU | Wall |
|---|---|---|---|---|
| `banner` | ~2–4 MB |, | ~0.003s | instant |
| `log` | ~2–4 MB | ~2 MB | ~0.005s | 0.01s |
| `export` | ~2–4 MB | ~2 MB | ~0.06s | 0.08s |
| `poll` | **~16–18 MB** | ~7.6 MB | ~0.2s | network-bound |

For repeated, aggregated measurements (min/median/mean/max/stdev over N samples,
plus CSV export for your own analysis), use the standalone
[`scripts/analyze.py`](../scripts/analyze.py), `just analyze`, or run it
directly: `uv run scripts/analyze.py --samples 15 --csv samples.csv`. It is run
strictly through [uv](https://docs.astral.sh/uv/), which provisions the pinned
Python (`requires-python = ">=3.14"`, declared in the script's PEP 723 inline
metadata), no manual interpreter or virtualenv setup. It is pure stdlib, works
on macOS and Linux, and sources its figures from the same `FABLE_MONITOR_STATS`
self-report (so it captures the child processes too).

The `poll` figure dominates because the arena holds every fetched body for the
whole run (it never frees mid-run), so peak ≈ the sum of the fetched pages,
bounded by the 16 MiB per-fetch cap in `httpGet`. Each poll lasts a few seconds
then exits, so the scheduled agent's steady-state footprint is ~0.

### Self-report in production

Set `FABLE_MONITOR_STATS=1` and the program logs a one-line `getrusage` summary
(process + children peak RSS and CPU) to stderr at the end of any run. Enabling
it in the launchd agent (the plist's `EnvironmentVariables`) records each poll's
footprint into the agent's `err.log`, handy for spotting a page that has grown
pathologically large. The probe is `getrusage(2)`, so it costs nothing.

### Disk

State caps Federal Register keys at 300 and feed keys at 500 per source; settled
alerts expire after 90 days and fully delivered outbox records are removed. The
observation log grows with *events* (not poll frequency) and appends one zstd
frame per run. Automatic compaction retains the configured maximum event count;
archive its base and sidecars as described in [data-export.md](data-export.md)
and [design-decisions.md](design-decisions.md) decision 9.

## Documentation maintenance (read before changing behavior)

Documentation is treated as part of the change, not a follow-up. The full policy
and the **code → doc map** live in [docs/README.md](README.md). In short:

1. A PR that changes behavior updates the affected doc(s) in the **same** PR.
2. Each doc carries a `Last reviewed:` stamp, update it when you touch the doc,
   and refresh every stamp at release time after a skim.
3. New subsystem → new row in the code→doc map + a stamped doc.

`tests/docs_schema.sh` checks local Markdown links, every doc review stamp, the
default source schema, and documented source kinds. Reviewers still enforce
behavioral accuracy: a behavior change with stale prose is incomplete.

## Releasing

See [release.md](release.md). The tag workflow builds baseline-CPU Linux and
macOS archives, checksums, SPDX SBOM, provenance, and keyless signatures.
