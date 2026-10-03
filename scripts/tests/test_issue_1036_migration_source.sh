#!/usr/bin/env bash
# Issue #1036: migration guidance must not depend on a stale local seed copy.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

python3 - "$repo_root" <<'PY'
import json
import re
import subprocess
import sys
from pathlib import Path

root = Path(sys.argv[1])
changelog = (root / "CHANGELOG.md").read_text(encoding="utf-8")
manifest = json.loads((root / "update-manifest.json").read_text(encoding="utf-8"))

section = re.search(
    r"- \[migration\] \*\*Существующим установкам:\*\*(.*?)(?=\n### Added)",
    changelog,
    re.DOTALL,
)
assert section, "migration guidance for existing installations is missing"

source = re.search(
    r"https://raw\.githubusercontent\.com/[^/]+/"
    r"FMT-exocortex-template/([0-9a-f]{40})/"
    r"seed/strategy/inbox/fleeting-notes\.md",
    section.group(1),
)
assert source, "migration guidance must link to an immutable upstream seed"

seed = subprocess.run(
    ["git", "-C", str(root), "show", f"{source.group(1)}:seed/strategy/inbox/fleeting-notes.md"],
    check=True,
    capture_output=True,
    text=True,
).stdout
assert "Разбирает только пилот" in seed
assert "автоматического ночного разбора нет" in seed
assert "✅предложено" in seed
assert "вручную" in section.group(1)

delivered_paths = {entry["path"] for entry in manifest["files"]}
assert "inbox/fleeting-notes.md" not in delivered_paths, "user notes must not be replaced"
print("PASS: immutable migration legend is available; user notes stay outside delivery")
PY
