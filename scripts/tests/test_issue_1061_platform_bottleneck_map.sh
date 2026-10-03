#!/usr/bin/env bash
# Issue #1061: the delivered platform route must require a user-owned systems map.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
INSTALL="$TMP/install"

# Install only manifest files, verifying their declared bytes. This deliberately
# excludes the author's personal Aisystant memory and every source-only file.
python3 - "$ROOT" "$INSTALL" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

root, install = map(Path, sys.argv[1:])
manifest = json.loads((root / "update-manifest.json").read_text(encoding="utf-8"))
paths = {item["path"] for item in manifest["files"]}
required = {
    ".claude/skills/platform-bottleneck/SKILL.md",
    ".claude/skills/bottleneck-pick/SKILL.md",
    "scripts/check-platform-systems-map.sh",
}
assert required <= paths, f"missing delivered route files: {required - paths}"
assert "memory/project_iwe_systems_map.md" not in paths, "personal map entered public manifest"
for item in manifest["files"]:
    data = (root / item["path"]).read_bytes()
    assert hashlib.sha256(data).hexdigest() == item["sha256"], item["path"]
    target = install / item["path"]
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(data)
assert not (install / "memory/project_iwe_systems_map.md").exists()
alias = (install / ".claude/skills/platform-bottleneck/SKILL.md").read_text()
pick = (install / ".claude/skills/bottleneck-pick/SKILL.md").read_text()
for name, skill in (("alias", alias), ("direct route", pick)):
    assert "check-platform-systems-map.sh" in skill, f"{name} lacks executable preflight"
    assert "--systems-map" in skill, f"{name} cannot accept a user-owned map"
PY

reject() {
    local expected="$1" rc
    shift
    set +e
    (cd "$INSTALL" && bash scripts/check-platform-systems-map.sh "$@") >"$TMP/out" 2>"$TMP/err"
    rc=$?
    set -e
    [ "$rc" -eq 2 ] || { echo "expected fail-closed code 2, got $rc" >&2; exit 1; }
    [ ! -s "$TMP/out" ] || { echo "failed preflight exposed a map path" >&2; exit 1; }
    grep -Fq -- "$expected" "$TMP/err" || { cat "$TMP/err" >&2; exit 1; }
}

reject 'пользовательская карта систем'
reject '--systems-map' --map "$TMP/missing.md"
test ! -e "$INSTALL/memory/project_iwe_systems_map.md"

mkdir -p "$TMP/private"
printf '  \n\t\n' >"$TMP/private/blank.md"
reject 'пуста' --map "$TMP/private/blank.md"
printf '# Synthetic C2 systems map\n- C2 test subsystem\n' >"$TMP/private/map.md"
resolved=$(cd "$INSTALL" && bash scripts/check-platform-systems-map.sh --map "$TMP/private/map.md")
[ "$resolved" = "$TMP/private/map.md" ]
grep -Fq 'C2 test subsystem' "$resolved"
test ! -e "$INSTALL/memory/project_iwe_systems_map.md"

mkdir -p "$INSTALL/memory"
cp "$TMP/private/map.md" "$INSTALL/memory/project_iwe_systems_map.md"
resolved=$(cd "$INSTALL" && bash scripts/check-platform-systems-map.sh)
[ "$resolved" = "$(cd "$INSTALL" && pwd -P)/memory/project_iwe_systems_map.md" ]

echo 'PASS: #1061 installed platform route refuses a missing map and accepts only a supplied user map'
