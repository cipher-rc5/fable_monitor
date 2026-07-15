#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$ROOT" <<'PY'
import json
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1]).resolve()
markdown = [root / "README.md", *sorted((root / "docs").glob("*.md"))]
link_re = re.compile(r"!?\[[^]]*\]\(([^)]+)\)")
errors = []

for document in markdown:
    text = document.read_text(encoding="utf-8")
    if document.parent == root / "docs" and "Last reviewed:" not in text:
        errors.append(f"{document.relative_to(root)}: missing Last reviewed stamp")
    for raw in link_re.findall(text):
        target = raw.strip().split()[0].strip("<>")
        if not target or target.startswith(("#", "http://", "https://", "mailto:")):
            continue
        path_text = target.split("#", 1)[0].split("?", 1)[0]
        if path_text and not (document.parent / path_text).resolve().exists():
            errors.append(f"{document.relative_to(root)}: broken link {target}")

config = json.loads((root / "src/sources_default.json").read_text(encoding="utf-8"))
if config.get("version") != 1 or not isinstance(config.get("sources"), list):
    errors.append("src/sources_default.json: unsupported top-level schema")
for field in ("fast_interval_s", "slow_interval_s"):
    if not isinstance(config.get(field), int) or config[field] <= 0:
        errors.append(f"src/sources_default.json: {field} must be a positive integer")

allowed_kinds = {
    "api_probe", "federal_register", "federal_register_public_inspection",
    "feed_watch", "keyword_watch", "market_watch", "model_list_probe",
    "statement_watch",
}
ids = set()
source_docs = (root / "docs/sources.md").read_text(encoding="utf-8")
for index, source in enumerate(config.get("sources", [])):
    where = f"src/sources_default.json: sources[{index}]"
    if not isinstance(source, dict):
        errors.append(f"{where} must be an object")
        continue
    for field in ("id", "kind", "url"):
        if not isinstance(source.get(field), str) or not source[field]:
            errors.append(f"{where}.{field} must be a non-empty string")
    if source.get("id") in ids:
        errors.append(f"{where}.id is duplicated")
    ids.add(source.get("id"))
    if source.get("kind") not in allowed_kinds:
        errors.append(f"{where}.kind is unknown")
    if source.get("tier", 3) not in (1, 2, 3):
        errors.append(f"{where}.tier is outside 1..3")
for kind in allowed_kinds:
    if f"`{kind}`" not in source_docs:
        errors.append(f"docs/sources.md: missing source kind {kind}")

# Cross-validate the README's stated source counts against the actual config so
# that adding/removing/toggling a source forces the README to stay in sync.
sources = config.get("sources", [])
total_count = len(sources)
enabled_count = sum(1 for s in sources if isinstance(s, dict) and s.get("enabled", True) is not False)
tier1_count = sum(1 for s in sources if isinstance(s, dict) and s.get("tier", 3) == 1)

readme = (root / "README.md").read_text(encoding="utf-8")
count_match = re.search(r"ships\s+(\d+)\s+sources\s*\((\d+)\s+enabled", readme)
if not count_match:
    errors.append(
        "README.md: missing source-count sentence matching "
        "'ships <N> sources (<M> enabled ...' "
        f"(config has {total_count} sources, {enabled_count} enabled)"
    )
else:
    stated_total = int(count_match.group(1))
    stated_enabled = int(count_match.group(2))
    if stated_total != total_count:
        errors.append(
            f"README.md: states {stated_total} sources but "
            f"src/sources_default.json has {total_count}"
        )
    if stated_enabled != enabled_count:
        errors.append(
            f"README.md: states {stated_enabled} enabled sources but "
            f"src/sources_default.json has {enabled_count} enabled"
        )

# Lenient tier-1 assertion: only enforced when the README uses the "four tier-1"
# phrasing, so config/README wording drift stays a soft, non-brittle check.
if re.search(r"four\s+tier-1", readme) and tier1_count != 4:
    errors.append(
        f"README.md: says 'four tier-1' but src/sources_default.json has "
        f"{tier1_count} tier-1 sources"
    )

if errors:
    raise SystemExit("\n".join(errors))
print("PASS: documentation links, review stamps, and source schema")
PY
