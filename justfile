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

# Read the observation history as a formatted, colorized table. Reads the real
# default log; extra args pass through to the subcommand.
# Usage: just log                       (whole history)
#        just log --event changed --limit 20
#        just log --source fr_bis --plain
log *args:
    zig build run -- log {{args}}

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

# Remove build artifacts, demo state/log, and the default Parquet export dir.
clean:
    rm -rf zig-out .zig-cache parquet {{demo_state}} {{demo_log}}
