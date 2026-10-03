#!/usr/bin/env bash
# Issue #1061: the delivered platform route must require a user-owned systems map.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
INSTALL="$TMP/work space"
TEMPLATE="$INSTALL/FMT-exocortex-template"

# Install only manifest files, verifying their declared bytes. This deliberately
# excludes the author's personal Aisystant memory and every source-only file.
python3 - "$ROOT" "$TEMPLATE" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

root, template = map(Path, sys.argv[1:])
manifest = json.loads((root / "update-manifest.json").read_text(encoding="utf-8"))
paths = {item["path"] for item in manifest["files"]}
required = {
    ".claude/skills/platform-bottleneck/SKILL.md",
    ".claude/skills/bottleneck-pick/SKILL.md",
    "scripts/check-platform-systems-map.sh",
    "setup/install-iwe-paths.sh",
}
assert required <= paths, f"missing delivered route files: {required - paths}"
assert "memory/project_iwe_systems_map.md" not in paths, "personal map entered public manifest"
for item in manifest["files"]:
    data = (root / item["path"]).read_bytes()
    assert hashlib.sha256(data).hexdigest() == item["sha256"], item["path"]
    target = template / item["path"]
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(data)
assert not (template / "memory/project_iwe_systems_map.md").exists()
alias = (template / ".claude/skills/platform-bottleneck/SKILL.md").read_text()
pick = (template / ".claude/skills/bottleneck-pick/SKILL.md").read_text()
for name, skill in (("alias", alias), ("direct route", pick)):
    assert '"$IWE_TEMPLATE/scripts/check-platform-systems-map.sh"' in skill, f"{name} lacks installed-template preflight"
    assert "--systems-map" in skill, f"{name} cannot accept a user-owned map"
PY

# setup.sh copies skills to workspace/.claude, leaves scripts in nested FMT,
# and generates .iwe-paths for the real workspace. Never use a flat install.
mkdir -p "$INSTALL/.claude"
cp -R "$TEMPLATE/.claude/skills" "$INSTALL/.claude/"
bash "$TEMPLATE/setup/install-iwe-paths.sh" --workspace "$INSTALL" --skip-zshenv --quiet
(
    cd "$INSTALL"
    . ./.iwe-paths
    [ "$IWE_SCRIPTS" = "$TEMPLATE/scripts" ]
    [ "$IWE_TEMPLATE" = "$TEMPLATE" ]
)

preflight() (
    cd "$INSTALL"
    . ./.iwe-paths
    bash "$IWE_TEMPLATE/scripts/check-platform-systems-map.sh" "$@"
)

reject() {
    local expected="$1" rc
    shift
    set +e
    preflight "$@" >"$TMP/out" 2>"$TMP/err"
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
printf '# Synthetic C2 systems map\n- C2 test subsystem\n' >"$TMP/private/map with space.md"
resolved=$(preflight --map "$TMP/private/map with space.md")
[ "$resolved" = "$TMP/private/map with space.md" ]
grep -Fq 'C2 test subsystem' "$resolved"
test ! -e "$INSTALL/memory/project_iwe_systems_map.md"

mkdir -p "$INSTALL/memory"
cp "$TMP/private/map with space.md" "$INSTALL/memory/project_iwe_systems_map.md"
resolved=$(preflight)
[ "$resolved" = "$(cd "$INSTALL" && pwd -P)/memory/project_iwe_systems_map.md" ]

# The helper also finds the workspace without a sourced environment when it
# sits in the canonical nested template layout.
resolved=$(env -u IWE_WORKSPACE bash "$TEMPLATE/scripts/check-platform-systems-map.sh")
[ "$resolved" = "$(cd "$INSTALL" && pwd -P)/memory/project_iwe_systems_map.md" ]

# A live workspace scripts checkout may move IWE_SCRIPTS, but this delivered
# helper still lives in IWE_TEMPLATE and both skills must continue to find it.
mkdir -p "$INSTALL/scripts"
: >"$INSTALL/scripts/session-guard.sh"
bash "$TEMPLATE/setup/install-iwe-paths.sh" --workspace "$INSTALL" --skip-zshenv --quiet >"$TMP/path-regeneration.log"
(
    cd "$INSTALL"
    . ./.iwe-paths
    [ "$IWE_SCRIPTS" = "$INSTALL/scripts" ]
    [ "$(bash "$IWE_TEMPLATE/scripts/check-platform-systems-map.sh")" = "$(pwd -P)/memory/project_iwe_systems_map.md" ]
)

echo 'PASS: #1061 setup-layout platform route fails closed and resolves a user map'
