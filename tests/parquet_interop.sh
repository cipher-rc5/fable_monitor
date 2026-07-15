#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/zig-out/bin/fable-monitor"
FIX="$ROOT/tests/fixtures/baseline"
TMP="$(mktemp -d -t fable-parquet-interop)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

[ -x "$BIN" ] || fail "binary not built ($BIN). Run: zig build"
command -v zstd >/dev/null 2>&1 || fail "zstd is required"

export FABLE_MONITOR_ONLY="anthropic_model_list,anthropic_pricing,anthropic_statement,fr_pi_bis"
export FABLE_MONITOR_STATE="$TMP/state.jsonl.zst"
export FABLE_MONITOR_LOG="$TMP/events.jsonl.zst"

if FABLE_MONITOR_FIXTURES="$FIX" "$BIN" poll >"$TMP/poll.out" 2>&1; then
    poll_status=0
else
    poll_status=$?
fi
[ "$poll_status" -eq 0 ] || fail "fixture poll exited $poll_status (expected 0)"

if "$BIN" export "$TMP/parquet" >"$TMP/export.out" 2>&1; then
    export_status=0
else
    export_status=$?
fi
[ "$export_status" -eq 0 ] || fail "export exited $export_status (expected 0)"

for table in events state_seen state_keyword_hashes; do
    [ -s "$TMP/parquet/$table.parquet" ] || fail "missing or empty $table.parquet"
done

if command -v duckdb >/dev/null 2>&1; then
    duckdb -c "SELECT count(*) FROM '$TMP/parquet/events.parquet';" >/dev/null
    duckdb -c "SELECT count(*) FROM parquet_metadata('$TMP/parquet/events.parquet') WHERE compression = 'ZSTD';" >/dev/null
elif [ -n "${PARQUET_PYTHON:-}" ]; then
    "$PARQUET_PYTHON" - "$TMP/parquet" <<'PY'
import sys
import duckdb

root = sys.argv[1]
db = duckdb.connect()
for name in ("events", "state_seen", "state_keyword_hashes"):
    db.execute(f"SELECT count(*) FROM '{root}/{name}.parquet'").fetchone()
compression = db.execute(
    f"SELECT DISTINCT compression FROM parquet_metadata('{root}/events.parquet')"
).fetchall()
if not compression or any(row[0] != "ZSTD" for row in compression):
    raise SystemExit(f"unexpected Parquet compression: {compression}")
PY
else
    fail "DuckDB reader unavailable; install duckdb or set PARQUET_PYTHON to a Python with duckdb"
fi

echo "PASS: DuckDB read all exported Parquet tables and confirmed ZSTD metadata"
