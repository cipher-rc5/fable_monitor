# fable-monitor

A small Zig 0.16 command-line tool that polls official sources for changes to
the US government export-control status of Anthropic's Fable 5 and Mythos 5
models, and alerts when something moves.

It is built to run as a scheduled job (launchd or cron). Each invocation is one
poll: it fetches each source, diffs against the previous run's state, prints any
changes to stdout, optionally fires a notification hook, and persists updated
state.

## What it watches

Two classes of source:

1. Federal Register JSON API (the reliable signal). Two feeds are polled: every
   document whose full text matches the term "Anthropic", and every rule from
   the Bureau of Industry and Security (BIS), the agency that issued the
   directive. New document numbers are reported; documents whose title contains
   a watched keyword (fable, mythos, anthropic) are tagged `[RELEVANT]`.

2. HTML keyword watchers (best effort). The Anthropic newsroom and the BIS news
   page are fetched, reduced to a normalized fingerprint of the text near each
   watched keyword, and diffed. These catch announcements that never reach the
   Federal Register, but they are inherently noisier than the structured feeds.

The most likely "Fable is back" signal is an Anthropic newsroom change followed
by a Federal Register action, so weight the structured feeds highest.

## Design notes

The tool is std-only Zig with one external dependency: the system `curl` binary,
used for fetching. This sidesteps the churn in Zig's in-tree TLS and HTTP client
across releases, and `curl` is present by default on macOS. Everything else
(JSON parsing, normalization, hashing, state) is standard library.

State is a single JSON file. The Federal Register seen-set is capped at the most
recent 200 document numbers so it does not grow without bound.

## Build

Requires Zig 0.16.0 or newer.

    zig build              # produces zig-out/bin/fable-monitor
    zig build run          # build and run once
    zig build test         # run unit tests
    zig build check        # type-check without producing a binary

## Run

    ./zig-out/bin/fable-monitor

Diagnostics go to stderr (prefixed `[fable-monitor]`); alerts go to stdout. On
the first run every source records a baseline and reports no changes on
subsequent runs until something actually shifts.

### Environment variables

`FABLE_MONITOR_STATE` sets the state file path. Defaults to
`fable_monitor_state.json` in the working directory. Use an absolute path when
running under a scheduler.

`FABLE_MONITOR_NOTIFY` is an optional shell command run on high-signal alerts
(relevant Federal Register documents and page changes). The alert text is passed
as the positional parameter `$1`, so it is safe against shell injection. Example
for macOS using terminal-notifier:

    export FABLE_MONITOR_NOTIFY='terminal-notifier -title "fable-monitor" -message "$1"'

Or with osascript and no extra install:

    export FABLE_MONITOR_NOTIFY='osascript -e "display notification \"$1\" with title \"fable-monitor\""'

## Scheduling on macOS (launchd)

A sample agent is in `dist/io.zerocreativity.fable-monitor.plist`. Edit the
paths inside it, then:

    cp dist/io.zerocreativity.fable-monitor.plist ~/Library/LaunchAgents/
    launchctl load ~/Library/LaunchAgents/io.zerocreativity.fable-monitor.plist

It runs every 30 minutes. Logs are written to the paths set in the plist. To
stop:

    launchctl unload ~/Library/LaunchAgents/io.zerocreativity.fable-monitor.plist

## Tuning

The source list, keywords, and per-source keyword overrides live at the top of
`src/main.zig`. The Federal Register queries can be tightened or broadened by
editing their query strings (the API supports filtering by agency, date,
document type, and full-text term).
