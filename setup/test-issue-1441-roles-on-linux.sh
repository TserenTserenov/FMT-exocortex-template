#!/usr/bin/env bash
# test-issue-1441-roles-on-linux.sh — setup.sh step 5 installs roles on Linux
# too: the role install.sh scripts choose systemd --user or cron themselves
# (issue #1441). The condition is extracted from the real setup.sh and checked
# with stubbed uname/launchctl.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SETUP="$ROOT/setup.sh"

FAIL=0
pass() { echo "  ✅ PASS: $*"; }
fail() { echo "  ❌ FAIL: $*"; FAIL=$((FAIL + 1)); }

FUNC=$(awk '/^setup_roles_supported\(\) \{/,/^}/' "$SETUP")
[ -n "$FUNC" ] || { echo "FAIL: setup_roles_supported() not found in $SETUP"; exit 1; }
grep -q 'elif ! setup_roles_supported; then' "$SETUP" \
    || fail "step 5 does not use setup_roles_supported"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Run the extracted function with a stub bin dir first in PATH and the system
# dirs after it, minus any real launchctl (so the stub decides).
supported() { # <uname -s output> <with launchctl: yes|no>
    local bin="$TMP/bin-$1-$2"
    mkdir -p "$bin"
    printf '#!/bin/sh\necho %s\n' "$1" > "$bin/uname"
    chmod +x "$bin/uname"
    if [ "$2" = yes ]; then
        printf '#!/bin/sh\nexit 0\n' > "$bin/launchctl"
        chmod +x "$bin/launchctl"
    fi
    PATH="$bin:/usr/bin:/bin" bash -c "$FUNC"$'\nsetup_roles_supported'
}

supported Darwin yes && pass "macOS with launchd: roles installed" || fail "macOS with launchd rejected"
supported Linux no && pass "Linux without launchd: roles installed (#1441)" || fail "Linux without launchd still skipped"
# On a macOS host /bin/launchctl is real, so "no launchd" cannot be simulated.
if PATH="/usr/bin:/bin" command -v launchctl >/dev/null 2>&1; then
    echo "  (host has launchctl in /usr/bin or /bin: the other-OS case is skipped)"
else
    supported FreeBSD no && fail "an OS with neither launchd nor Linux is not skipped" || pass "other OS without launchd: skipped with a manual hint"
fi
grep -q 'bash $TEMPLATE_DIR/roles/<роль>/install.sh' "$SETUP" \
    && pass "skip message names the manual install command" || fail "skip message lacks the install.sh hint"

[ "$FAIL" -eq 0 ] && echo "PASS: issue #1441 roles on Linux" || { echo "FAIL: issue #1441 has $FAIL violation(s)"; exit 1; }
