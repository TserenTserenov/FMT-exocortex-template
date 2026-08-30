#!/usr/bin/env bash
# Regression for issue #557: the Day Close commit guard is sourced in the
# pilot's login shell, which on macOS is zsh. In zsh `path` is tied to PATH
# (localizing it empties command lookup — `git` stops resolving) and `status`
# is a read-only alias of `$?`. The guard must therefore avoid zsh special
# parameter names entirely, and this must be proven by running the real
# extracted functions under `zsh -f`, not only under bash (the old test's
# shebang tested a shell the code never runs in).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL="$ROOT/.claude/skills/day-close/SKILL.md"
TEST_ROOT="$(mktemp -d /tmp/iwe-issue-557-zsh-guard.XXXXXX)"
GUARD_SOURCE="$TEST_ROOT/guard.sh"
REPO="$TEST_ROOT/repo"

FAIL=0
fail() { echo "  ❌ FAIL: $*" >&2; FAIL=$((FAIL + 1)); }
pass() { echo "  ✅ PASS: $*"; }
# Invoked indirectly by the trap below.
# shellcheck disable=SC2329
cleanup() { local rc=$?; rm -rf "$TEST_ROOT"; exit "$rc"; }
trap cleanup EXIT INT TERM

awk '
  /<!-- issue-511-guard:start -->/ { capture=1; next }
  /<!-- issue-511-guard:end -->/ { capture=0 }
  capture && $0 !~ /^```/ { print }
' "$SKILL" > "$GUARD_SOURCE"

if ! grep -q '^stage_and_commit_or_stop()' "$GUARD_SOURCE"; then
    echo "❌ production guard could not be extracted from day-close/SKILL.md" >&2
    exit 1
fi

# --- 1. Static regression: zsh special parameter names must not come back. ---
# `path`/`status` broke live (issue #557); the rest are the same failure class
# waiting to happen. Only declarations/loop variables are dangerous, not
# substrings of longer names — anchor on `local ... <name>` and `for <name>`.
DANGEROUS='path|status|cdpath|fpath|manpath|argv|pipestatus|dirstack|funcstack'
if grep -nE "^[[:space:]]*(local|typeset)([[:space:]]+[A-Za-z_][A-Za-z0-9_]*(=[^[:space:]]*)?)*[[:space:]]+($DANGEROUS)([[:space:]=]|$)" "$GUARD_SOURCE" \
   || grep -nE "^[[:space:]]*for[[:space:]]+($DANGEROUS)[[:space:]]" "$GUARD_SOURCE"; then
    fail "guard declares a zsh special parameter name (see matches above)"
else
    pass "guard avoids zsh special parameter names (path/status/…)"
fi

# --- 2. Behavioral: the guard must produce a real commit under zsh. ---
if ! command -v zsh >/dev/null 2>&1; then
    # macOS (the affected platform) always ships zsh; on minimal Linux CI
    # images the static check above still guards the regression class.
    echo "  SKIP: zsh not installed — behavioral leg not run (static check done)"
    exit "$([ "$FAIL" -eq 0 ] && echo 0 || echo 1)"
fi

mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.name "Issue 557 regression"
git -C "$REPO" config user.email "issue-557@example.invalid"
printf 'original\n' > "$REPO/note.md"
git -C "$REPO" add -- note.md
git -C "$REPO" commit -qm "initial"
printf 'edited\n' >> "$REPO/note.md"

# `zsh -f` skips rc files: a clean interactive-equivalent environment where
# special parameters behave as in the pilot's shell. The run must survive
# sourcing AND end in a real commit (observable result, not just rc=0).
if zsh -f -c '
  emulate -L zsh
  source "$1" || exit 90
  stage_and_commit_or_stop "$2" "zsh commit via guard" note.md || exit $?
' zsh "$GUARD_SOURCE" "$REPO" >"$TEST_ROOT/zsh.out" 2>&1; then
    pass "stage_and_commit_or_stop runs under zsh -f"
else
    fail "guard failed under zsh (rc=$?): $(tail -3 "$TEST_ROOT/zsh.out" | tr '\n' ' ')"
fi
if [ "$(git -C "$REPO" log --oneline | wc -l | tr -d ' ')" = "2" ] \
   && git -C "$REPO" diff --quiet --exit-code -- note.md; then
    pass "zsh run produced a real commit with the edit staged"
else
    fail "no commit landed under zsh — PATH/positional params likely broken"
fi

if [ "$FAIL" -gt 0 ]; then
    echo "❌ issue #557 regression: $FAIL failure(s)" >&2
    exit 1
fi
echo "✅ issue #557 regression: all checks passed"
