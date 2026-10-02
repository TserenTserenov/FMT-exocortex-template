#!/usr/bin/env bash
# issue #984: setup-extractor-feeders.sh wrote com.extractor.git-diff-feed.plist without
# IWE_SCRIPTS, so extractor.sh could not find session-guard.sh under launchd and the
# git-diff-feed run failed at the save step. The script is run on a fake macOS
# (stub uname/launchctl/claude, throwaway HOME); the generated plist is inspected.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

EXTRACTOR_DIR="$T/ws/.iwe-runtime/roles/extractor/scripts"
mkdir -p "$T/bin" "$T/home" "$EXTRACTOR_DIR"
printf '#!/bin/sh\necho Darwin\n' > "$T/bin/uname"
printf '#!/bin/sh\nexit 1\n' > "$T/bin/launchctl"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/claude"
printf '#!/bin/sh\nexit 0\n' > "$EXTRACTOR_DIR/extractor.sh"
chmod +x "$T/bin/uname" "$T/bin/launchctl" "$T/bin/claude" "$EXTRACTOR_DIR/extractor.sh"

PLIST="$T/home/Library/LaunchAgents/com.extractor.git-diff-feed.plist"
mkdir -p "$(dirname "$PLIST")"

# run [VAR=value ...]: regenerate the plist with a clean IWE_SCRIPTS unless given.
run() {
    rm -f "$PLIST"
    env -u IWE_SCRIPTS "$@" HOME="$T/home" IWE_WORKSPACE="$T/ws" PATH="$T/bin:$PATH" \
        bash "$ROOT/scripts/setup-extractor-feeders.sh" --schedule-only >"$T/out" 2>&1
}

fail=0
check() { # name expected-value
    local got
    got=$(grep '<key>IWE_SCRIPTS</key>' "$PLIST" 2>/dev/null | sed -E 's#.*<string>(.*)</string>.*#\1#')
    if [ "$got" = "$2" ]; then
        echo "  ✅ $1: IWE_SCRIPTS=$got"
    else
        echo "  ❌ $1: ожидалось '$2', получено '$got'"
        sed 's/^/    /' "$T/out"
        fail=1
    fi
}

run env;                          check "по умолчанию — каталог scripts шаблона" "$ROOT/scripts"
run env IWE_SCRIPTS=/custom/scripts; check "явное значение сохраняется" "/custom/scripts"
exit $fail
