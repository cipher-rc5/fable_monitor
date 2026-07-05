# fable-monitor task runner. Run `just` to list recipes.
# `just` is a language-agnostic command runner; these recipes just wrap the
# underlying `zig build` invocations and the testing conventions.

# A throwaway state path so test/dev runs never touch real scheduled state.
demo_state := "/tmp/fable-monitor-demo.jsonl.zst"
# Matching throwaway log path for the demo.
demo_log := "/tmp/fable-monitor-demo-events.jsonl.zst"

# Where the installed agent keeps its state/log data. Defaults to the macOS
# launchd location (dist/install.sh); on the Linux deployment point it at the
# durable home from dist/install-linux.sh, e.g.
#   FABLE_DATA_DIR=$HOME/.local/share/fable-monitor just view
data_dir := env_var_or_default("FABLE_DATA_DIR", env_var("HOME") / "Library/Application Support/fable-monitor")

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

# End-to-end fixture replay: proves the full pipeline trips on a simulated
# restoration and stays silent on baseline/decoy. Builds first.
e2e: build
    bash tests/e2e.sh

# Everything CI runs, in order. Run this before pushing.
ci: fmt-check test build e2e

# Run one real poll against throwaway state/log files (safe; won't touch real state).
run:
    FABLE_MONITOR_STATE={{demo_state}} FABLE_MONITOR_LOG={{demo_log}} zig build run

# Export the observation history + current state into Parquet under <out_dir>.
# Reads the real default state/log files in the working directory.
export out_dir="parquet":
    zig build run -- export {{out_dir}}

# Read the installed agent's observation history as a formatted, colorized table.
# (Points at the installed agent's log under {{data_dir}}; extra args pass
# through to the subcommand.)
# Usage: just log                       (whole history)
#        just log --event changed --limit 20
#        just log --source fr_bis --plain
log *args:
    FABLE_MONITOR_LOG="{{data_dir}}/events.jsonl.zst" zig build run -- log {{args}}

# Dataview of the installed agent's recent activity: last 90 days, newest-first.
# Same reader/flags as `log`, just a different preset.
# Usage: just view                        (last 90 days, newest-first)
#        just view --relevant             (only high-signal events)
#        just view --days 30 --source fr_bis
view *args:
    FABLE_MONITOR_LOG="{{data_dir}}/events.jsonl.zst" zig build run -- view {{args}}

# Serve the read-only htmx + Tailwind v4 dashboard over the installed agent's
# data on http://127.0.0.1:8787 (override the port: `just ui 9000`).
ui port="8787":
    FABLE_MONITOR_STATE="{{data_dir}}/state.jsonl.zst" \
    FABLE_MONITOR_LOG="{{data_dir}}/events.jsonl.zst" \
    zig build run -- serve {{port}}

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

# Replay the restoration fixtures against a throwaway state and show the trip
# (structured events on stdout + notify hook firing). Safe; touches no real state.
demo-restore: build
    #!/usr/bin/env bash
    set -euo pipefail
    S=$(mktemp); L=$(mktemp)
    export FABLE_MONITOR_STATE="$S" FABLE_MONITOR_LOG="$L"
    export FABLE_MONITOR_ONLY="anthropic_model_list,anthropic_pricing,anthropic_statement,fr_pi_bis"
    export FABLE_MONITOR_NOTIFY='echo ">>> NOTIFY: $1"'
    echo "== baseline (no trip) =="
    FABLE_MONITOR_FIXTURES=tests/fixtures/baseline ./zig-out/bin/fable-monitor poll | grep '^{' || true
    echo "== restored (tier-1 trip) =="
    FABLE_MONITOR_FIXTURES=tests/fixtures/restored ./zig-out/bin/fable-monitor poll | grep '^{'
    rm -f "$S" "$L"

# Verify the runtime is ready (deps, state path, egress, secrets) before scheduling.
preflight:
    zig build run -- preflight

# Coverage audit: each source's last successful fetch and last detected change.
audit:
    FABLE_MONITOR_LOG="{{data_dir}}/events.jsonl.zst" FABLE_MONITOR_STATE="{{data_dir}}/state.jsonl.zst" zig build run -- audit

# Install as a Linux recurring job (Zo.computer / systemd / cron). Override:
# SCHEDULER=systemd|cron  FABLE_HOME=/persistent/path  FABLE_FAST_INTERVAL=45
install-linux:
    bash dist/install-linux.sh

# Preview the Linux scheduler install without writing anything.
install-linux-preview:
    bash dist/install-linux.sh --dry-run

# Remove the Linux scheduler job (leaves binary/state/logs).
uninstall-linux:
    bash dist/uninstall-linux.sh

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
    @tail -n 40 "{{data_dir}}"/out.log "{{data_dir}}"/err.log 2>/dev/null || echo "no logs yet (agent hasn't run)"

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
    uv run scripts/analyze.py {{args}}

# Remove build artifacts, demo state/log, and the default Parquet export dir.
clean:
    rm -rf zig-out .zig-cache parquet {{demo_state}} {{demo_log}}
