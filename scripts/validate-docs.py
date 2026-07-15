#!/usr/bin/env python3
"""Validate the operational documentation contract."""

from pathlib import Path
import re
import sys


ROOT = Path(__file__).resolve().parent.parent
REQUIRED = {
    "docs/operational-telemetry.md": ("## Metric contract", "## JSON logging"),
    "docs/fmea.md": ("## Failure modes", "## Review triggers"),
    "docs/source-governance.md": ("## Ownership", "## Review policy"),
    "docs/threat-model.md": ("## Assets", "## Threats"),
    "docs/incident-runbook.md": ("## Detection", "## Closure"),
    "docs/security-support.md": ("## Reporting", "## Support window"),
}


def main():
    failures = []
    for relative, headings in REQUIRED.items():
        path = ROOT / relative
        if not path.is_file():
            failures.append(f"missing {relative}")
            continue
        text = path.read_text(encoding="utf-8")
        if not re.search(r"^Last reviewed: \d{4}-\d{2}-\d{2} · against fable-monitor \S+$", text, re.MULTILINE):
            failures.append(f"{relative}: missing review stamp")
        for heading in headings:
            if heading not in text:
                failures.append(f"{relative}: missing {heading}")
        for target in re.findall(r"\[[^]]+\]\(([^)#]+)(?:#[^)]+)?\)", text):
            if "://" not in target and not (path.parent / target).resolve().exists():
                failures.append(f"{relative}: broken link {target}")
    if failures:
        print("\n".join(f"ERROR: {failure}" for failure in failures), file=sys.stderr)
        return 1
    print(f"PASS: validated {len(REQUIRED)} operational documents")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
