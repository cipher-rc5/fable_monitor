#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

python3 - "$ROOT/.betterleaks.toml" <<'PY'
import sys
import tomllib

with open(sys.argv[1], "rb") as handle:
    config = tomllib.load(handle)
assert config.get("extend", {}).get("useDefault") is True
allowlists = config.get("allowlists", [])
assert allowlists, "scanner config has no explicit allowlist"
for allowlist in allowlists:
    assert "commits" not in allowlist, "commit-wide allowlists hide history findings"
    assert "stopwords" not in allowlist, "global stopwords are too broad"
print("scanner TOML parsed with default rules enabled")
PY

for workflow in "$ROOT/.github/workflows/ci.yml" "$ROOT/.github/workflows/release.yml"; do
    grep -q 'fetch-depth: 0' "$workflow" || fail "$(basename "$workflow") does not scan full history"
    grep -Eq 'ghcr\.io/betterleaks/betterleaks@sha256:[a-f0-9]{64}' "$workflow" || \
        fail "$(basename "$workflow") does not pin the scanner image by digest"
    grep -q -- '--config /repo/.betterleaks.toml' "$workflow" || \
        fail "$(basename "$workflow") does not load scanner configuration"
done

echo "PASS: secret scanner defaults, narrow allowlists, and pinned CI wiring"
