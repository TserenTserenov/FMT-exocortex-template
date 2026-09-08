#!/usr/bin/env bash
# WP-7 Ф92: deprecated_files entries for paths that moved files[] -> excluded_paths[]
# must survive regeneration when marked excluded_confirmed=true, while the
# 2026-08-22 protection (auto-purge of any other tracked deprecated path)
# stays intact. Runs generate-manifest.sh + verify-manifest.sh against a
# throwaway git worktree of this repo (both scripts shell out to `git
# ls-files`, so a synthetic repo would not exercise the real code path).
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
WT=$(mktemp -d)
trap 'git -C "$ROOT" worktree remove --force "$WT" >/dev/null 2>&1 || true; rm -rf "$WT"' EXIT

git -C "$ROOT" worktree add --detach "$WT" HEAD >/dev/null

# An excluded_paths[] path that has no history of ever being in files[] and
# no excluded_confirmed marker — the 2026-08-22 incident shape. Any tracked
# file in an excluded pattern works; scripts/lib/common.sh is delivered
# (files[]), so pick something the manifest already lists under excluded_paths.
CONFIRMED_PATH="scripts/tests/test_generate_manifest_deprecated_excluded.sh"
UNCONFIRMED_PATH="scripts/tests/test_release_receipt.sh"

python3 - "$WT/update-manifest.json" "$CONFIRMED_PATH" "$UNCONFIRMED_PATH" <<'PYSETUP'
import json, sys
manifest_path, confirmed_path, unconfirmed_path = sys.argv[1:4]
with open(manifest_path) as f:
    data = json.load(f)
data.setdefault("deprecated_files", [])
data["deprecated_files"] = [
    e for e in data["deprecated_files"]
    if e.get("path") not in (confirmed_path, unconfirmed_path)
]
data["deprecated_files"].append({
    "path": confirmed_path, "reason": "test fixture", "excluded_confirmed": True,
})
data["deprecated_files"].append({
    "path": unconfirmed_path, "reason": "test fixture (no excluded_confirmed)",
})
with open(manifest_path, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
PYSETUP

(cd "$WT" && bash generate-manifest.sh >/tmp/test_generate_manifest_deprecated_excluded.log 2>&1) || {
  echo "FAIL: generate-manifest.sh exited non-zero"
  cat /tmp/test_generate_manifest_deprecated_excluded.log
  exit 1
}

CONFIRMED_KEPT=$(python3 -c "
import json
data = json.load(open('$WT/update-manifest.json'))
print(any(e.get('path') == '$CONFIRMED_PATH' for e in data.get('deprecated_files', [])))
")
[ "$CONFIRMED_KEPT" = "True" ] || {
  echo "FAIL: excluded_confirmed=true entry ($CONFIRMED_PATH) was purged — regen must keep it while the path stays in excluded_paths[]"
  exit 1
}

UNCONFIRMED_KEPT=$(python3 -c "
import json
data = json.load(open('$WT/update-manifest.json'))
print(any(e.get('path') == '$UNCONFIRMED_PATH' for e in data.get('deprecated_files', [])))
")
[ "$UNCONFIRMED_KEPT" = "False" ] || {
  echo "FAIL: unconfirmed tracked deprecated entry ($UNCONFIRMED_PATH) survived regen — 22.08 protection regressed"
  exit 1
}

(cd "$WT" && bash scripts/verify-manifest.sh >/tmp/test_generate_manifest_deprecated_excluded_verify.log 2>&1) || {
  echo "FAIL: verify-manifest.sh rejected a manifest that generate-manifest.sh itself just produced"
  cat /tmp/test_generate_manifest_deprecated_excluded_verify.log
  exit 1
}

echo "PASS: excluded_confirmed deprecated_files entries survive regen; unconfirmed tracked entries still get purged"
