#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

run() {
    local label="$1"
    shift
    printf '==> %s\n' "$label"
    "$@"
}

run "Zig formatting" zig fmt --check src/ build.zig
run "Unit tests" zig build test --summary all
run "Build" zig build
run "Restoration E2E" bash tests/e2e.sh
run "Notify quoting" bash tests/notify_quoting.sh
run "Installer safety" bash tests/installers.sh
run "Environment and installer preflight" bash tests/env_install_preflight.sh
run "State compatibility" bash tests/state_compat.sh
run "Log capacity (2x documented budget)" bash tests/log_capacity.sh
run "Installer hostile values" bash tests/installer_hostile_values.sh
run "Documentation and source schema" bash tests/docs_schema.sh
run "Scanner configuration" bash tests/scanner_config.sh
run "ShellCheck" shellcheck --exclude=SC1090,SC2016 tests/*.sh scripts/*.sh dist/*.sh
run "Parquet interoperability" bash tests/parquet_interop.sh
run "Clean-tree release package" bash tests/package_clean_tree.sh

# Zig 0.16 has no supported coverage output, and this project has no existing
# reliable coverage tool. Keep this visible rather than publishing a fake gate.
echo "BLOCKED: coverage gate requires reliable Zig 0.16 coverage tooling"

echo "PASS: local CI parity gate"
