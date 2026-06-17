# Development

Last reviewed: 2026-06-17 · against fable-monitor 0.1.0

How to build, test, and contribute to `fable-monitor`, plus the policy that
keeps this documentation current.

## Requirements

- **Zig 0.16.0 or newer** (pinned via `minimum_zig_version` in `build.zig.zon`).
- **`curl`** on `PATH` — only needed to *run* a live poll, not to build or test.
- **`just`** (optional) — task runner; `brew install just`.

## Project layout

```
build.zig            # build graph: exe, run, test, check steps
build.zig.zon        # package manifest (name, version, min Zig, fingerprint)
justfile             # task-runner recipes (wraps zig build + conventions)
src/main.zig         # the entire program (single file)
dist/                # launchd plist template
docs/                # this documentation set
.github/workflows/   # CI
```

## Build graph (`build.zig`)

| Step | Command | What it does |
|---|---|---|
| install | `zig build` | Compile and install `zig-out/bin/fable-monitor`. |
| run | `zig build run` | Build, then run one poll. Forwards extra args. |
| test | `zig build test` | Compile and run the unit tests in `src/main.zig`. |
| check | `zig build check` | Type-check only, no binary — fast feedback / LSP. |

The exe, test, and check targets all share one `root_module`, so they stay in
sync automatically.

## Tests

Unit tests live at the bottom of `src/main.zig` and cover the pure logic
(`normalizeHtml`, `containsAny`, `extractKeywordContext`, `capTail`, and the
`State` lookups). They need no network. The I/O paths (curl, state file, notify)
are exercised end-to-end by running the binary — see `just demo`,
`just test-notify`, and `just test-no-curl`.

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
| `just ci` | `fmt-check` + `test` + `build` — the full pre-push gate. |
| `just demo` | Baseline run + no-change run against a temp state file. |
| `just run` | One real poll against a throwaway state file. |
| `just clean` | Remove `zig-out`, `.zig-cache`, and demo state. |

The run/demo/notify recipes default `FABLE_MONITOR_STATE` to a `/tmp` path so
development runs never touch real scheduled state.

## CI

`.github/workflows/ci.yml` runs on every push and pull request: it installs Zig
0.16.0 (`mlugg/setup-zig@v2`), then runs `zig build test`, `zig build`, and
`zig fmt --check src/ build.zig`. Keep the pinned Zig version here in step with
`minimum_zig_version` in `build.zig.zon`. Run `just ci` locally to reproduce the
gate before pushing.

## Formatting

`zig fmt` is the authority; CI enforces `zig fmt --check`. Use `just fmt` to
format in place before committing.

## Documentation maintenance (read before changing behavior)

Documentation is treated as part of the change, not a follow-up. The full policy
and the **code → doc map** live in [docs/README.md](README.md). In short:

1. A PR that changes behavior updates the affected doc(s) in the **same** PR.
2. Each doc carries a `Last reviewed:` stamp — update it when you touch the doc,
   and refresh every stamp at release time after a skim.
3. New subsystem → new row in the code→doc map + a stamped doc.

Reviewers are the enforcement mechanism: a behavior change with stale docs is an
incomplete change. If CI doc-freshness enforcement is added later, document it
here and in [docs/README.md](README.md).

## Releasing

1. Bump `version` in both `build.zig.zon` and the `version` constant in
   `src/main.zig` (they should match).
2. Run `just ci`.
3. Skim every doc in `docs/` and refresh the `Last reviewed:` stamps.
4. Tag the release.
