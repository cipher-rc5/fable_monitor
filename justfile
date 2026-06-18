# fable-monitor task runner. Run `just` to list recipes.
# `just` is a language-agnostic command runner; these recipes just wrap the
# underlying `zig build` invocations and the testing conventions.

# A throwaway state path so test/dev runs never touch real scheduled state.
demo_state := "/tmp/fable-monitor-demo.jsonl.zst"
# Matching throwaway log path for the demo.
demo_log := "/tmp/fable-monitor-demo-events.jsonl.zst"

# Show available recipes (default when you run bare `just`).
default:
    @just --list

# Build the binary into zig-out/bin/fable-monitor.
build:
    zig build

# Fast type-check without producing a binary.
check:
    zig build check

# Run the unit tests.
test:
    zig build test --summary all

# Verify formatting (matches what CI enforces).
fmt-check:
    zig fmt --check src/ build.zig

# Auto-format the source in place.
fmt:
    zig fmt src/ build.zig

# Everything CI runs, in order. Run this before pushing.
ci: fmt-check test build

# Run one real poll against throwaway state/log files (safe; won't touch real state).
run:
    FABLE_MONITOR_STATE={{demo_state}} FABLE_MONITOR_LOG={{demo_log}} zig build run

# Export the observation history + current state into Parquet under <out_dir>.
# Reads the real default state/log files in the working directory.
export out_dir="parquet":
    zig build run -- export {{out_dir}}

# Read the installed agent's observation history as a formatted, colorized table.
# (Points at the launchd agent's log under Application Support; extra args pass
# through to the subcommand.)
# Usage: just log                       (whole history)
#        just log --event changed --limit 20
#        just log --source fr_bis --plain
log *args:
    FABLE_MONITOR_LOG=~/"Library/Application Support/fable-monitor/events.jsonl.zst" zig build run -- log {{args}}

# Inspect a compressed JSONL file (state or log): decompress and pretty-print.
# Usage: just inspect /path/to/file.jsonl.zst   (pipe through jq if installed)
inspect file:
    zstd -dc {{file}}

# Demonstrate the core behavior: a baseline run, then a no-change run.
demo:
    rm -f {{demo_state}} {{demo_log}}
    @echo "===== RUN 1 (baseline) ====="
    -FABLE_MONITOR_STATE={{demo_state}} FABLE_MONITOR_LOG={{demo_log}} zig build run
    @echo "\n===== RUN 2 (should detect no changes) ====="
    -FABLE_MONITOR_STATE={{demo_state}} FABLE_MONITOR_LOG={{demo_log}} zig build run

# Verify a notification fires (prints to the terminal instead of a real notifier).
test-notify:
    rm -f {{demo_state}} {{demo_log}}
    FABLE_MONITOR_NOTIFY='echo ">>> NOTIFY FIRED: $1"' FABLE_MONITOR_STATE={{demo_state}} FABLE_MONITOR_LOG={{demo_log}} zig build run

# Verify the missing-dependency preflight produces a clear error. With an empty
# PATH the zstd preflight fires first (it runs before the curl check).
test-no-deps: build
    -env -i PATH=/nonexistent ./zig-out/bin/fable-monitor

# Install as a macOS launchd background agent: builds a release binary, writes a
# LaunchAgent with this checkout's paths, and loads it (polls + notifies you on a
# relevant change). Override cadence: FABLE_INTERVAL=600 just install
install:
    bash dist/install.sh

# Preview the launchd plist that `just install` would write, without installing.
install-preview:
    bash dist/install.sh --dry-run

# Unload and remove the launchd agent (leaves the binary, state, and logs).
uninstall:
    bash dist/uninstall.sh

# Show whether the background agent is loaded and its last run's exit status.
status:
    @launchctl print "gui/$(id -u)/io.zerocreativity.fable-monitor" 2>/dev/null | grep -E "state =|last exit code|program =" || echo "not loaded (run: just install)"

# Tail the installed agent's alert (stdout) and diagnostic (stderr) logs.
logs:
    @tail -n 40 ~/"Library/Application Support/fable-monitor"/out.log ~/"Library/Application Support/fable-monitor"/err.log 2>/dev/null || echo "no logs yet (agent hasn't run)"

# Measure memory + CPU of each subcommand. Builds ReleaseSafe, times each under
# macOS `/usr/bin/time -l` (peak RSS, CPU), then prints the built-in self-report
# which ALSO accounts for the curl/zstd children. (On Linux use `time -v`.)
measure:
    #!/usr/bin/env bash
    set -euo pipefail
    zig build -Doptimize=ReleaseSafe
    BIN="$PWD/zig-out/bin/fable-monitor"
    echo "binary size: $(du -h "$BIN" | cut -f1)"
    T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
    run() {
        local label="$1"; shift
        printf '\n=== %s ===\n' "$label"
        /usr/bin/time -l "$BIN" "$@" >/dev/null 2>"$T/o" || true
        grep -E 'real|maximum resident set size|peak memory footprint' "$T/o" | sed 's/^[[:space:]]*/  /'
    }
    FABLE_MONITOR_STATE="$T/s.zst" FABLE_MONITOR_LOG="$T/l.zst" run "poll (network)"
    FABLE_MONITOR_LOG="$T/l.zst" run "log" log --no-color
    FABLE_MONITOR_STATE="$T/s.zst" FABLE_MONITOR_LOG="$T/l.zst" run "export" export "$T/pq"
    run "banner" banner FABLE
    printf '\n=== self-report (FABLE_MONITOR_STATS=1 — includes curl/zstd children) ===\n'
    FABLE_MONITOR_STATE="$T/s2.zst" FABLE_MONITOR_LOG="$T/l2.zst" FABLE_MONITOR_STATS=1 "$BIN" 2>&1 | grep "stats:" | sed 's/^/  /'

# Aggregated resource analysis over N samples (min/median/mean/max/stdev), with
# optional CSV export. Standalone script; extra args pass through.
# Usage: just analyze            ·  just analyze --samples 15 --csv out.csv
analyze *args:
    scripts/analyze.py {{args}}

# Remove build artifacts, demo state/log, and the default Parquet export dir.
clean:
    rm -rf zig-out .zig-cache parquet {{demo_state}} {{demo_log}}
