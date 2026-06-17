# Architecture

Last reviewed: 2026-06-17 · against fable-monitor 0.1.0

`fable-monitor` is a single-binary CLI with one job: detect when an official
source says something new about the export-control status of Anthropic's
Fable 5 / Mythos 5 models, and alert on it. It is deliberately small — the
entire program is one file, `src/main.zig`.

## The governing idea: one run = one poll

The tool is **not** a long-running daemon. Each invocation does exactly one pass
over the sources and then exits. Recurring execution is the scheduler's job
(launchd or cron — see [deployment.md](deployment.md)). This keeps the process
model trivial: no event loop, no timers, no in-memory state to corrupt, and a
crash affects at most one poll. Continuity across runs comes entirely from a
small JSON state file (see [state-format.md](state-format.md)).

## Run lifecycle

`main(init: std.process.Init)` executes these steps in order:

1. **Set up context.** Read `FABLE_MONITOR_STATE` and `FABLE_MONITOR_NOTIFY`
   from the environment and build a `Context` (holds the `Io`, the arena
   allocator, the state path, the notify command, and a `changed` flag).
2. **Preflight.** `curlAvailable()` runs `curl --version`; if curl is missing,
   log a clear fatal message and return before doing any work.
3. **Load previous state.** `loadState()` parses the JSON state file. A missing
   or unreadable file is non-fatal — the run simply starts from an empty state
   (first-run / baseline behavior).
4. **Poll each source.** Iterate `sources`; dispatch on `SourceKind` to either
   `checkFederalRegister` or `checkKeywordWatch`. Each source is wrapped in its
   own error handler, so one source failing (network, parse, …) logs an error
   and the others still run.
5. **Persist merged state.** Combine carried-forward and newly-seen data into a
   `State` and write it back with `saveState()`. The Federal Register seen-set
   is capped to the most recent 200 entries via `capTail`.
6. **Report.** If nothing set `ctx.changed`, log "no changes detected".

## Components

```
                 ┌─────────────────────────────────────────────┐
                 │                  main()                      │
                 │  env → Context → preflight → load → poll →   │
                 │             save → report                    │
                 └───────────────┬─────────────────────────────┘
                                 │ for each Source
              ┌──────────────────┴───────────────────┐
              ▼                                       ▼
   checkFederalRegister()                   checkKeywordWatch()
   • httpGet (curl)                         • httpGet (curl)
   • parse JSON (FrResponse)                • normalizeHtml
   • diff vs prev.hasSeen                   • extractKeywordContext
   • alert on new docs                      • Wyhash fingerprint
                                            • diff vs prev.hashFor
              │                                       │
              └──────────────────┬────────────────────┘
                                 ▼
                              alert()
                    stdout  +  (if high-signal) runNotify() → sh -c
```

### Fetching — `httpGet` / `curlAvailable`

All network I/O is delegated to the system `curl` binary via
`std.process.run`. `httpGet` invokes curl with `-sS -L --fail`, a 30s timeout, a
`User-Agent` of `fable-monitor/<version>`, and a 16 MiB stdout cap; a non-zero
exit becomes `error.FetchFailed`. Nothing else in the program speaks HTTP or
TLS. The rationale is in [design-decisions.md](design-decisions.md).

### Federal Register path — `checkFederalRegister`

The structured, high-reliability signal. The response is parsed into a minimal
projection (`FrResponse` / `FrDoc`) with `ignore_unknown_fields = true`, so the
API can add fields without breaking us. Each document is keyed by its
`document_number`; numbers we've already seen are skipped. New numbers are
recorded and alerted, and titles containing a watched keyword are tagged
`[RELEVANT]` rather than plain `new`.

### Keyword-watch path — `checkKeywordWatch`

The best-effort signal for pages that have no structured feed. Raw HTML is far
too volatile to hash directly, so the body is reduced to a stable fingerprint:

- `normalizeHtml` strips tags, lowercases, and collapses whitespace runs.
- `extractKeywordContext` keeps a ±100-byte window around each keyword hit, then
  sorts and de-duplicates the windows so reordering on the page doesn't change
  the result.
- The concatenated windows are hashed with `std.hash.Wyhash`.

The hash is compared to the stored hash for that source: no stored hash means
"baseline recorded"; an equal hash means "unchanged"; a different hash fires a
`[CHANGED]` alert. This deliberately reports *that* something near a keyword
changed, not *what* — diffing the substance is left to the human.

### Alerting — `alert` / `runNotify`

`alert` always writes the message to stdout and sets `ctx.changed`. For
high-signal events (relevant Federal Register docs, page changes) it also fires
the optional notify hook. `runNotify` invokes the user command as
`sh -c <cmd> fable-monitor <message>`, exposing the alert text as `$1` — this
avoids both shell injection and clobbering the child's environment.

## Memory model

Everything allocates from a single arena (`init.arena`) that lives for the whole
process and is released on exit. Because a run is short and bounded, there is no
per-source free; the arena is freed wholesale when the process ends. This is a
deliberate simplification that the one-run-one-poll model makes safe.

## Output streams

- **stdout** — alerts (the signal a human or downstream tool consumes).
- **stderr** — diagnostics, every line prefixed `[fable-monitor]` (via `log`).

Keeping alerts and diagnostics on separate streams means you can pipe alerts
somewhere while still seeing operational logs.

## What this design intentionally does *not* do

- No daemon / no scheduling of its own (delegated to launchd/cron).
- No database (a single JSON file is enough).
- No HTTP/TLS stack of its own (delegated to curl).
- No diff of *what* changed on a watched page (only that it changed).

These are conscious trade-offs; see [design-decisions.md](design-decisions.md).
