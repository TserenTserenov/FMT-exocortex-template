#!/usr/bin/env python3
"""Check the language catalogs in .claude/lib/locale/ (WP-610 F9 step 2).

Every catalog is a flat JSON object of strings with the same keys as the
others. Template keys (msg.*, agent.*, format.*) use only %s and %%, with the
same number of %s in every language. recognition.* keys are raw grep -E
expressions: non-empty and accepted by grep -E. Every key that shipped shell
code (update-manifest.json) names literally in an i18n_* call exists in the
catalogs; keys built at run time (close_$gate) are not seen here.

Usage: check-locale-catalogs.py [repo root]
Exit codes: 0 clean; 1 offences (printed); 2 usage error.
"""

import json
import re
import subprocess
import sys
from pathlib import Path

TEMPLATE_PREFIXES = ("msg.", "agent.", "format.")
PATTERN_PREFIX = "recognition."
PLACEHOLDER = re.compile(r"%(.?)")
LITERAL_KEY = re.compile(r"\bi18n_(?:msg|pattern|match)\s+[\"']?((?:msg|agent|format|recognition)\.[a-z0-9_.]+)(?![a-z0-9_.$])")


def placeholder_count(template: str) -> int:
    """Number of %s; raises ValueError on any other % sequence."""
    count = 0
    for match in PLACEHOLDER.finditer(template):
        spec = match.group(1)
        if spec == "s":
            count += 1
        elif spec != "%":
            raise ValueError(f"only %s and %% are allowed, found %{spec}")
    return count


def grep_status(pattern: str) -> int:
    """grep -E on one empty line: 0 matches it, 1 does not, other is invalid."""
    return subprocess.run(["grep", "-qE", "--", pattern], input="\n", text=True, capture_output=True).returncode


def load(path: Path, offences: list[str]) -> dict[str, str]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        offences.append(f"{path.name}: not readable JSON ({exc})")
        return {}
    if not isinstance(data, dict):
        offences.append(f"{path.name}: not a JSON object")
        return {}
    for key, value in data.items():
        if not isinstance(value, str):
            offences.append(f"{path.name}: {key} is not a string")
    return {k: v for k, v in data.items() if isinstance(v, str)}


def check_catalogs(catalogs: dict[str, dict[str, str]], offences: list[str]) -> None:
    all_keys = set().union(*catalogs.values())
    for lang, data in catalogs.items():
        for key in sorted(all_keys - data.keys()):
            offences.append(f"{lang}.json: missing {key}")
    for key in sorted(all_keys):
        values = {lang: data[key] for lang, data in catalogs.items() if key in data}
        if key.startswith(PATTERN_PREFIX):
            for lang, value in values.items():
                if not value:
                    offences.append(f"{lang}.json: {key} is empty")
                else:
                    status = grep_status(value)
                    if status == 0:
                        offences.append(f"{lang}.json: {key} matches an empty line, so it matches anything")
                    elif status != 1:
                        offences.append(f"{lang}.json: {key} is not a valid grep -E expression")
        elif key.startswith(TEMPLATE_PREFIXES):
            counts = {}
            for lang, value in values.items():
                try:
                    counts[lang] = placeholder_count(value)
                except ValueError as exc:
                    offences.append(f"{lang}.json: {key}: {exc}")
            if len(set(counts.values())) > 1:
                offences.append(f"{key}: different number of %s across catalogs {counts}")
        else:
            offences.append(f"{key}: unknown key space")


def check_code_keys(root: Path, keys: set[str], offences: list[str]) -> None:
    manifest = json.loads((root / "update-manifest.json").read_text(encoding="utf-8"))
    for rel in sorted(f["path"] for f in manifest["files"] if f["path"].endswith(".sh")):
        path = root / rel
        if not path.is_file():
            continue
        for key in LITERAL_KEY.findall(path.read_text(encoding="utf-8", errors="replace")):
            if key not in keys:
                offences.append(f"{rel}: uses {key}, absent from the catalogs")


def main(argv: list[str]) -> int:
    if len(argv) > 2:
        print(__doc__, file=sys.stderr)
        return 2
    root = Path(argv[1] if len(argv) == 2 else Path(__file__).resolve().parent.parent)
    files = sorted((root / ".claude/lib/locale").glob("*.json"))
    if not files:
        print(f"no catalogs in {root / '.claude/lib/locale'}", file=sys.stderr)
        return 2
    if not (root / "update-manifest.json").is_file():
        print(f"no update-manifest.json in {root}", file=sys.stderr)
        return 2
    offences: list[str] = []
    catalogs = {path.stem: load(path, offences) for path in files}
    check_catalogs(catalogs, offences)
    check_code_keys(root, set().union(*catalogs.values()), offences)
    for offence in offences:
        print(offence)
    print(f"{len(files)} catalog(s), {len(offences)} offence(s)")
    return 1 if offences else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
