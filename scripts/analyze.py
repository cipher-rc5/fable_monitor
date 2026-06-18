#!/usr/bin/env python3
"""Analyze fable-monitor's memory and resource consumption.

Runs each subcommand several times and reports peak RSS and CPU/wall time,
aggregated (min / median / mean / max / stdev). Memory and CPU come from the
binary's own FABLE_MONITOR_STATS self-report (getrusage), so the numbers are
accurate, OS-normalized, and — unlike `/usr/bin/time` on the parent — include
the curl/zstd child processes. Wall time is measured by this script.

Pure standard library; works on macOS and Linux.

Examples:
    scripts/analyze.py                          # build + analyze, 5 samples each
    scripts/analyze.py --samples 15             # more samples for tighter stats
    scripts/analyze.py --subcommands poll,banner
    scripts/analyze.py --csv samples.csv        # also dump raw per-sample rows
    scripts/analyze.py --bin /path/to/fable-monitor --no-build
"""

from __future__ import annotations

import argparse
import csv as csvmod
import os
import platform
import re
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DEFAULT_BIN = REPO / "zig-out" / "bin" / "fable-monitor"

# Matches the line emitted with FABLE_MONITOR_STATS=1:
#   stats: process peak RSS 16.3 MiB, CPU 0.054s · children (curl/zstd) peak RSS 7.6 MiB, CPU 0.150s
STATS_RE = re.compile(
    r"process peak RSS ([\d.]+) MiB, CPU ([\d.]+)s.*?"
    r"children.*?peak RSS ([\d.]+) MiB, CPU ([\d.]+)s"
)

# subcommand -> argv (after the binary). State/log/output paths are injected per
# run via the environment so runs don't touch your real data.
SUBCOMMANDS = {
    "poll": [],
    "log": ["log", "--no-color"],
    "export": ["export"],  # output dir appended at run time
    "banner": ["banner", "FABLE"],
}

METRICS = [
    ("wall (s)", "wall"),
    ("proc RSS (MiB)", "rss"),
    ("proc CPU (s)", "cpu"),
    ("child RSS (MiB)", "crss"),
    ("child CPU (s)", "ccpu"),
]


def build() -> None:
    print("building ReleaseSafe binary…", file=sys.stderr)
    subprocess.run(
        ["zig", "build", "-Doptimize=ReleaseSafe"], cwd=REPO, check=True
    )


def run_once(binary: Path, args: list[str], env: dict) -> dict:
    """Run the binary once; return wall time, parsed stats, and exit code."""
    full_env = os.environ.copy()
    full_env.update(env)
    full_env["FABLE_MONITOR_STATS"] = "1"
    t0 = time.perf_counter()
    proc = subprocess.run(
        [str(binary), *args], env=full_env, capture_output=True, text=True
    )
    wall = time.perf_counter() - t0
    sample = {"wall": wall, "rss": float("nan"), "cpu": float("nan"),
              "crss": float("nan"), "ccpu": float("nan"), "rc": proc.returncode}
    m = STATS_RE.search(proc.stderr)
    if m:
        sample["rss"], sample["cpu"], sample["crss"], sample["ccpu"] = map(float, m.groups())
    else:
        sample["stderr"] = proc.stderr.strip()
    return sample


def aggregate(values: list[float]) -> dict | None:
    vals = [v for v in values if v == v]  # drop NaN
    if not vals:
        return None
    return {
        "min": min(vals),
        "med": statistics.median(vals),
        "mean": statistics.fmean(vals),
        "max": max(vals),
        "std": statistics.pstdev(vals) if len(vals) > 1 else 0.0,
    }


def human_size(path: Path) -> str:
    n = path.stat().st_size
    if n < 1024:
        return f"{n} B"
    if n < 1024 ** 2:
        return f"{n / 1024:.0f} KB"
    return f"{n / 1024 ** 2:.1f} MB"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--samples", type=int, default=5, help="runs per subcommand (default 5)")
    ap.add_argument("--subcommands", default="poll,log,export,banner",
                    help="comma-separated subset to measure (default all)")
    ap.add_argument("--bin", type=Path, default=DEFAULT_BIN, help="path to the binary")
    ap.add_argument("--no-build", action="store_true", help="use the existing binary, don't rebuild")
    ap.add_argument("--csv", type=Path, help="write raw per-sample rows to this CSV file")
    args = ap.parse_args()

    chosen = [s.strip() for s in args.subcommands.split(",") if s.strip()]
    for s in chosen:
        if s not in SUBCOMMANDS:
            print(f"error: unknown subcommand '{s}' (choose from {', '.join(SUBCOMMANDS)})", file=sys.stderr)
            return 2

    if not args.no_build:
        build()
    if not args.bin.exists():
        print(f"error: binary not found at {args.bin} (drop --no-build to build it)", file=sys.stderr)
        return 1

    tmp = Path(tempfile.mkdtemp(prefix="fable-analyze-"))
    seed_state = tmp / "seed_state.jsonl.zst"
    seed_log = tmp / "seed_log.jsonl.zst"

    # `log` and `export` need a populated log/state to read — seed one poll.
    if {"log", "export"} & set(chosen):
        print("seeding a log for log/export (one poll)…", file=sys.stderr)
        run_once(args.bin, [], {"FABLE_MONITOR_STATE": str(seed_state), "FABLE_MONITOR_LOG": str(seed_log)})

    all_rows: list[dict] = []
    results: dict[str, dict] = {}
    failures: dict[str, int] = {}

    for name in chosen:
        samples = []
        fails = 0
        for i in range(args.samples):
            if name == "poll":  # fresh state each time → a full (baseline) poll
                env = {"FABLE_MONITOR_STATE": str(tmp / f"p_{i}.zst"),
                       "FABLE_MONITOR_LOG": str(tmp / f"pl_{i}.zst")}
                argv = SUBCOMMANDS[name]
            elif name == "log":
                env = {"FABLE_MONITOR_LOG": str(seed_log)}
                argv = SUBCOMMANDS[name]
            elif name == "export":
                env = {"FABLE_MONITOR_STATE": str(seed_state), "FABLE_MONITOR_LOG": str(seed_log)}
                argv = SUBCOMMANDS[name] + [str(tmp / f"pq_{i}")]
            else:  # banner
                env = {}
                argv = SUBCOMMANDS[name]
            s = run_once(args.bin, argv, env)
            if s["rc"] != 0:
                fails += 1
            s["subcommand"], s["sample"] = name, i
            samples.append(s)
            all_rows.append(s)
        results[name] = {key: aggregate([s[key] for s in samples]) for _, key in METRICS}
        failures[name] = fails

    # --- report ---
    print()
    rel = args.bin.relative_to(REPO) if args.bin.is_relative_to(REPO) else args.bin
    print("fable-monitor resource analysis")
    print(f"  binary:  {rel}  ({human_size(args.bin)}, ReleaseSafe)")
    print(f"  host:    {platform.system()} {platform.machine()} · {args.samples} samples each")
    print()
    hdr = f"{'subcommand':<11} {'metric':<16}{'min':>9}{'med':>9}{'mean':>9}{'max':>9}{'std':>9}"
    print(hdr)
    print("-" * len(hdr))
    for name in chosen:
        first = True
        for label, key in METRICS:
            a = results[name][key]
            if a is None:
                continue
            # Skip the child rows when there were never any children (e.g. banner).
            if key in ("crss", "ccpu") and a["max"] == 0.0 and a["min"] == 0.0:
                continue
            prefix = name if first else ""
            first = False
            print(f"{prefix:<11} {label:<16}"
                  f"{a['min']:>9.3f}{a['med']:>9.3f}{a['mean']:>9.3f}{a['max']:>9.3f}{a['std']:>9.3f}")
        if failures[name]:
            print(f"{'':<11} (note: {failures[name]}/{args.samples} runs exited non-zero — e.g. network)")
        print()

    if args.csv:
        with open(args.csv, "w", newline="") as fh:
            w = csvmod.writer(fh)
            w.writerow(["subcommand", "sample", "wall_s", "proc_rss_mib", "proc_cpu_s",
                        "child_rss_mib", "child_cpu_s", "exit_code"])
            for r in all_rows:
                w.writerow([r["subcommand"], r["sample"], f"{r['wall']:.6f}",
                            r["rss"], r["cpu"], r["crss"], r["ccpu"], r["rc"]])
        print(f"raw samples written to {args.csv} ({len(all_rows)} rows)")

    # Cleanup.
    for p in tmp.rglob("*"):
        if p.is_file():
            p.unlink()
    try:
        for d in sorted(tmp.rglob("*"), reverse=True):
            d.rmdir()
        tmp.rmdir()
    except OSError:
        pass

    print("\nNotes:")
    print("  • RSS/CPU come from the binary's getrusage self-report (process + curl/zstd children).")
    print("  • `poll` uses a fresh state each run (a full baseline poll) and is network-bound,")
    print("    so its wall time varies; RSS ≈ the fetched page sizes held in the arena.")
    print("  • Each run is a short-lived process that frees its arena on exit — no cross-run growth.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
