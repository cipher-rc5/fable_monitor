# fable-monitor task runner. Run `just` to list recipes.
# `just` is a language-agnostic command runner; these recipes just wrap the
# underlying `zig build` invocations and the testing conventions.

# A throwaway state path so test/dev runs never touch real scheduled state.
demo_state := "/tmp/fable-monitor-demo.json"

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

# Run one real poll against a throwaway state file (safe; won't touch real state).
run:
    FABLE_MONITOR_STATE={{demo_state}} zig build run

# Demonstrate the core behavior: a baseline run, then a no-change run.
demo:
    rm -f {{demo_state}}
    @echo "===== RUN 1 (baseline) ====="
    -FABLE_MONITOR_STATE={{demo_state}} zig build run
    @echo "\n===== RUN 2 (should detect no changes) ====="
    -FABLE_MONITOR_STATE={{demo_state}} zig build run

# Verify a notification fires (prints to the terminal instead of a real notifier).
test-notify:
    rm -f {{demo_state}}
    FABLE_MONITOR_NOTIFY='echo ">>> NOTIFY FIRED: $1"' FABLE_MONITOR_STATE={{demo_state}} zig build run

# Verify the missing-curl preflight path produces a clear error.
test-no-curl: build
    -env -i PATH=/nonexistent ./zig-out/bin/fable-monitor

# Remove build artifacts and demo state.
clean:
    rm -rf zig-out .zig-cache {{demo_state}}
