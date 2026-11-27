#!/usr/bin/env bash
# test_issue_1688_hooks_path_kept.sh -- regression for issue #1688.
#
# update.sh rewrote a user's own core.hooksPath (.husky, a shared hooks folder)
# to .githooks without a word, so the user's linters and secret checks stopped
# running. Two writers did it on every update: setup/install-iwe-paths.sh (the
# auto-enable loop over workspace repos with .githooks/) and install-hooks.sh
# of the governance repo (covered by scripts/tests/test_install_hooks.py).
# This test runs the real install-iwe-paths.sh on four repos:
#   - own local value (.husky)      -> kept, warning names it
#   - own global value              -> no local value written, warning
#   - unset                         -> wired to .githooks, no warning
#   - already .githooks             -> unchanged, no warning
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf -- "$TMP"' EXIT
# The installer must not touch the real HOME (rc files, global git config).
export HOME="$TMP/home" TMPDIR="$TMP/tmp" GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME" "$TMPDIR"

fail=0
check() { # <desc> <expected> <actual>
    if [ "$2" = "$3" ]; then
        echo "PASS: $1"
    else
        echo "FAIL: $1 -- ожидалось [$2], получено [$3]"
        fail=1
    fi
}
contains() { # <desc> <needle> <haystack>
    if grep -Fq -- "$2" <<<"$3"; then
        echo "PASS: $1"
    else
        echo "FAIL: $1 -- нет [$2] в выводе"
        fail=1
    fi
}
lacks() { # <desc> <needle> <haystack>
    if grep -Fq -- "$2" <<<"$3"; then
        echo "FAIL: $1 -- лишнее [$2] в выводе"
        fail=1
    else
        echo "PASS: $1"
    fi
}

make_repo() { # <workspace> <name>
    mkdir -p "$1/$2/.githooks"
    git init -q "$1/$2"
}
local_hooks_path() { git -C "$1" config --local --get core.hooksPath || true; }

run_installer() { # <workspace>
    "$BASH" "$ROOT/setup/install-iwe-paths.sh" --workspace "$1" --governance DS-strategy \
        --skip-zshenv 2>&1
}

# 1. Local user value is kept.
WS="$TMP/ws-local"
make_repo "$WS" DS-strategy
git -C "$WS/DS-strategy" config --local core.hooksPath .husky
out=$(run_installer "$WS")
check "local .husky kept" ".husky" "$(local_hooks_path "$WS/DS-strategy")"
contains "warning names the kept value" "core.hooksPath уже задан («.husky»)" "$out"
contains "warning gives the switch command" "config --local core.hooksPath .githooks" "$out"

# 2. Global user value is not shadowed by a local .githooks.
WS="$TMP/ws-global"
make_repo "$WS" DS-strategy
git config --global core.hooksPath "$TMP/shared-hooks"
out=$(run_installer "$WS")
git config --global --unset core.hooksPath
check "no local value over a global one" "" "$(local_hooks_path "$WS/DS-strategy")"
contains "warning names the global value" "«$TMP/shared-hooks»" "$out"

# 3. Unset value is wired.
WS="$TMP/ws-unset"
make_repo "$WS" DS-strategy
out=$(run_installer "$WS")
check "unset -> .githooks" ".githooks" "$(local_hooks_path "$WS/DS-strategy")"
lacks "no warning when unset" "уже задан" "$out"

# 4. Platform value stays and is silent.
WS="$TMP/ws-platform"
make_repo "$WS" DS-strategy
git -C "$WS/DS-strategy" config --local core.hooksPath .githooks
out=$(run_installer "$WS")
check ".githooks unchanged" ".githooks" "$(local_hooks_path "$WS/DS-strategy")"
lacks "no warning for .githooks" "уже задан" "$out"

exit "$fail"
