#!/usr/bin/env python3
"""Export fable-monitor durable health as Prometheus text format."""

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time


POLL_RE = re.compile(r"poll metrics: .*?wall (?P<wall>[0-9]+)ms")
DESCRIBED = set()


def metric(name, value, help_text, labels=None):
    if name not in DESCRIBED:
        print(f"# HELP {name} {help_text}")
        print(f"# TYPE {name} gauge")
        DESCRIBED.add(name)
    suffix = ""
    if labels:
        escaped = []
        for key, raw in labels.items():
            value_text = str(raw).replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
            escaped.append(f'{key}="{value_text}"')
        suffix = "{" + ",".join(escaped) + "}"
    print(f"{name}{suffix} {value}")


def read_state(path):
    if not shutil.which("zstd"):
        raise RuntimeError("zstd is required to read the compressed state")
    result = subprocess.run(
        ["zstd", "-dc", "--", str(path)],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    records = []
    for number, line in enumerate(result.stdout.splitlines(), 1):
        if line.strip():
            try:
                records.append(json.loads(line))
            except json.JSONDecodeError as error:
                raise RuntimeError(f"invalid state JSON on line {number}: {error}") from error
    return records


def path_size(path):
    total = 0
    candidates = [path, Path(str(path) + ".manifest"), Path(str(path) + ".lock"), Path(str(path) + ".segments")]
    for candidate in candidates:
        if candidate.is_file():
            total += candidate.stat().st_size
        elif candidate.is_dir():
            total += sum(item.stat().st_size for item in candidate.rglob("*") if item.is_file())
    return total


def latest_poll_duration(path):
    if path is None:
        return None
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except FileNotFoundError:
        return None
    for line in reversed(lines):
        match = POLL_RE.search(line)
        if match:
            return int(match.group("wall")) / 1000
        if line.startswith("{"):
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue
            if entry.get("event") == "poll_complete" and "duration_ms" in entry:
                return int(entry["duration_ms"]) / 1000
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--state", type=Path, required=True, help="state.jsonl.zst path")
    parser.add_argument("--log", type=Path, help="events.jsonl.zst path, used for total on-disk size")
    parser.add_argument("--diagnostic-log", type=Path, help="stderr log, used for latest poll duration")
    parser.add_argument("--now-ms", type=int, help=argparse.SUPPRESS)
    args = parser.parse_args()

    now_ms = args.now_ms if args.now_ms is not None else time.time_ns() // 1_000_000
    records = read_state(args.state)
    statuses = [record for record in records if record.get("kind") == "status"]
    pending = [record for record in records if record.get("kind") == "delivery" and not record.get("delivered", False)]

    for status in sorted(statuses, key=lambda item: str(item.get("id", ""))):
        last_success = int(status.get("last_success_ms", 0))
        freshness = max(0, now_ms - last_success) / 1000 if last_success > 0 else -1
        metric("fable_monitor_source_freshness_seconds", freshness, "Seconds since the source last succeeded; -1 means never.", {"source": status.get("id", "")})

    metric("fable_monitor_delivery_backlog", len(pending), "Number of pending sink deliveries.")
    retry_age = max((max(0, now_ms - int(item.get("next_retry_ms", 0))) for item in pending if int(item.get("next_retry_ms", 0)) > 0), default=0) / 1000
    metric("fable_monitor_delivery_retry_overdue_seconds", retry_age, "Maximum seconds a pending delivery is past its next retry time.")
    metric("fable_monitor_state_size_bytes", path_size(args.state), "Compressed state file and sidecar bytes.")
    if args.log:
        metric("fable_monitor_log_size_bytes", path_size(args.log), "Compressed observation log and sidecar bytes.")

    disk_target = args.state if args.state.exists() else args.state.parent
    disk = os.statvfs(disk_target)
    metric("fable_monitor_disk_available_bytes", disk.f_bavail * disk.f_frsize, "Bytes available to the service account on the state filesystem.")

    duration = latest_poll_duration(args.diagnostic_log)
    metric("fable_monitor_poll_duration_available", int(duration is not None), "Whether latest poll duration was found in the diagnostic log.")
    if duration is not None:
        metric("fable_monitor_poll_duration_seconds", duration, "Latest observed whole-poll duration.")

    metric("fable_monitor_consecutive_failures_available", 0, "Whether durable consecutive-failure data is available (not persisted by state v4).")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f"export-metrics: {error}", file=sys.stderr)
        raise SystemExit(1)
