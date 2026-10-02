#!/usr/bin/env bash
# Issue #933: iwe-env-bootstrap.sh must not hardcode the template folder name.
# A template cloned as "myexocortex" (IWE_TEMPLATE in .exocortex.env) used to
# make WORKSPACE_DIR resolve to the template folder itself instead of its
# parent, so every script looked for memory/ and DS-strategy/ inside the
# template. Simulates the install layout in a temp dir (no Windows needed:
# the bug is path logic, independent of the OS).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BOOT="$ROOT/.claude/lib/iwe-env-bootstrap.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# resolve <template-dir-name> -> prints "WORKSPACE_DIR|IWE_SCRIPTS|IWE_TEMPLATE"
resolve() {
    local name="$1" ws="$TMP/ws-$1"
    mkdir -p "$ws/$name/.claude/lib" "$ws/$name/scripts"
    cp "$BOOT" "$ws/$name/.claude/lib/iwe-env-bootstrap.sh"
    printf 'IWE_TEMPLATE=%s/%s\n' "$ws" "$name" > "$ws/.exocortex.env"
    # Fresh shell, WORKSPACE_DIR and IWE_* deliberately not exported (agent-run
    # script case from the issue).
    env -u WORKSPACE_DIR -u IWE_ROOT -u IWE_TEMPLATE -u IWE_SCRIPTS -u IWE_WORKSPACE \
        bash -c '. "$1/.claude/lib/iwe-env-bootstrap.sh" && printf "%s|%s|%s" "$WORKSPACE_DIR" "$IWE_SCRIPTS" "$IWE_TEMPLATE"' _ "$ws/$name" 2>&1
}

# 1. Renamed template: workspace root is the parent.
got="$(resolve myexocortex)"
ws="$(cd "$TMP/ws-myexocortex" && pwd -P)"
[ "${got%%|*}" = "$ws" ] || fail "renamed template: WORKSPACE_DIR='${got%%|*}', expected '$ws'"
case "$got" in *"|$TMP/ws-myexocortex/myexocortex/scripts|"*) : ;; *) fail "renamed template: IWE_SCRIPTS not under the renamed template: $got" ;; esac

# 2. Historical name keeps working (behaviour unchanged).
got="$(resolve FMT-exocortex-template)"
ws="$(cd "$TMP/ws-FMT-exocortex-template" && pwd -P)"
[ "${got%%|*}" = "$ws" ] || fail "default name: WORKSPACE_DIR='${got%%|*}', expected '$ws'"

# 3. Live workspace root that carries its own .claude and .exocortex.env is not
#    mistaken for a template folder.
live="$TMP/live"
mkdir -p "$live/.claude/lib"
cp "$BOOT" "$live/.claude/lib/iwe-env-bootstrap.sh"
: > "$live/.exocortex.env"
got="$(env -u WORKSPACE_DIR -u IWE_ROOT -u IWE_TEMPLATE -u IWE_SCRIPTS -u IWE_WORKSPACE \
    bash -c '. "$1/.claude/lib/iwe-env-bootstrap.sh" && printf "%s" "$WORKSPACE_DIR"' _ "$live" 2>&1)"
[ "$got" = "$(cd "$live" && pwd -P)" ] || fail "live root: WORKSPACE_DIR='$got'"

echo "PASS: issue 933 bootstrap (3 checks)"
