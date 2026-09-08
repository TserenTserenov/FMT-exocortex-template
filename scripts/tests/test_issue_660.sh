#!/usr/bin/env bash
# test_issue_660.sh — regression for fork-owned path matching (issue #660):
# update-manifest.local.json's excluded_paths must now gate file application,
# not just the orphan detector. Tests the pure path-matching function and the
# Python loader that turns excluded_paths entries into FORK_OWNED_PATHS.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)

# Load only the function under test; sourcing update.sh would execute the updater.
eval "$(awk '
  /^is_fork_owned_path\(\)/ { capture=1 }
  capture { print }
  capture && /^}/ { exit }
' "$ROOT/update.sh")"
declare -F is_fork_owned_path >/dev/null

fail=0
assert_owned() {
    local rel="$1"; shift
    FORK_OWNED_PATHS=("$@")
    if ! is_fork_owned_path "$rel"; then
        echo "❌ expected '$rel' to be fork-owned under (${FORK_OWNED_PATHS[*]})"
        fail=1
    fi
}
assert_not_owned() {
    local rel="$1"; shift
    FORK_OWNED_PATHS=("$@")
    if is_fork_owned_path "$rel"; then
        echo "❌ expected '$rel' to NOT be fork-owned under (${FORK_OWNED_PATHS[*]})"
        fail=1
    fi
}

# Exact match.
assert_owned "roles/synchronizer/scripts/templates/strategist.sh" \
    "roles/synchronizer/scripts/templates/strategist.sh"

# Directory-prefix match (declared entry is a directory).
assert_owned "DS-strategy/scripts/build-active-wp.py" "DS-strategy/scripts"
assert_owned "DS-strategy/scripts/build-active-wp.py" "DS-strategy/scripts/"

# A sibling file that merely shares a name prefix must NOT match — this is
# the exact class of bug excluded_paths' string-prefix reasoning must avoid
# (e.g. "scripts" must not swallow "scripts-extra/file.py").
assert_not_owned "scripts-extra/file.py" "scripts"

# Unrelated path must not match.
assert_not_owned "roles/strategist/scripts/strategist.sh" \
    "roles/synchronizer/scripts/templates/strategist.sh"

# Empty declaration list matches nothing.
assert_not_owned "any/path.md"

# --- Python loader: excluded_paths (both string and {"path": ...} object
# forms) becomes the newline list update.sh reads into FORK_OWNED_PATHS.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/update-manifest.local.json" <<'EOF'
{
  "excluded_paths": [
    "roles/synchronizer/scripts/templates/strategist.sh",
    {"path": "DS-strategy/scripts"}
  ]
}
EOF
PY_BIN=$(command -v python3 || command -v python)
loaded=$("$PY_BIN" -c "
import json, sys

path = sys.argv[1]
try:
    with open(path) as f:
        data = json.load(f)
except (json.JSONDecodeError, OSError) as exc:
    print(f'  [warn] update-manifest.local.json unreadable, ignored: {exc}', file=sys.stderr)
    sys.exit(0)
for entry in data.get('excluded_paths', []):
    print(entry['path'] if isinstance(entry, dict) else entry)
" "$TMP/update-manifest.local.json")

expected=$'roles/synchronizer/scripts/templates/strategist.sh\nDS-strategy/scripts'
if [ "$loaded" != "$expected" ]; then
    echo "❌ Python loader mismatch:"
    echo "--- got ---"
    echo "$loaded"
    echo "--- expected ---"
    echo "$expected"
    fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "✅ test_issue_660: OK"
fi
exit "$fail"
