#!/usr/bin/env bash
# test_issue_1010_rc_idem.sh — install-iwe-paths.sh must be idempotent on the
# user's shell rc files: every update.sh run used to append one more empty
# line to ~/.zshenv and ~/.bashrc (issue #1010). Two runs give identical
# bytes, user lines survive, exactly one managed block remains, and a
# symlinked rc file stays a symlink.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INSTALL="$ROOT/setup/install-iwe-paths.sh"

FAIL=0
pass() { echo "  ✅ PASS: $*"; }
fail() { echo "  ❌ FAIL: $*"; FAIL=$((FAIL + 1)); }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
H="$TMP/home"; WS="$TMP/ws"
mkdir -p "$H/dotfiles" "$WS/GOV"
printf 'export USER_LINE=1\n' > "$H/.zshenv"
printf 'alias ll="ls -l"\n' > "$H/dotfiles/bashrc"
ln -s "$H/dotfiles/bashrc" "$H/.bashrc"

run() { HOME="$H" bash "$INSTALL" --workspace "$WS" --governance GOV --quiet >/dev/null 2>&1; }
run; cp "$H/.zshenv" "$TMP/z1"; cp "$H/.bashrc" "$TMP/b1"
run; run
if cmp -s "$TMP/z1" "$H/.zshenv" && cmp -s "$TMP/b1" "$H/.bashrc"; then
    pass "repeated runs leave .zshenv and .bashrc byte-identical"
else
    fail "repeated runs changed the rc files: $(diff "$TMP/z1" "$H/.zshenv" | head -3 | tr '\n' ' ')"
fi
if grep -qx 'export USER_LINE=1' "$H/.zshenv" && [ "$(grep -c '^# IWE environment (WP-219' "$H/.zshenv")" -eq 1 ]; then
    pass "user line kept, exactly one managed block"
else
    fail "user line lost or managed block duplicated"
fi
if [ -L "$H/.bashrc" ] && grep -q '_IWE_ROOT=' "$H/dotfiles/bashrc"; then
    pass "symlinked .bashrc stays a symlink and its target gets the block"
else
    fail "symlinked .bashrc was replaced by a regular file"
fi

# A legacy block (marker + $HOME/.iwe-paths line, no `unset _IWE_ROOT`) used to
# swallow every user line after it.
H2="$TMP/home2"; mkdir -p "$H2"
cat > "$H2/.zshenv" <<'LEGACY'
export BEFORE=1
# IWE environment (WP-219, DP.FM.009): lookup-слой для путей к скриптам
[ -f "$HOME/.iwe-paths" ] && source "$HOME/.iwe-paths"
export AFTER_LEGACY=1
LEGACY
HOME="$H2" bash "$INSTALL" --workspace "$WS" --governance GOV --quiet >/dev/null 2>&1
if grep -qx 'export BEFORE=1' "$H2/.zshenv" && grep -qx 'export AFTER_LEGACY=1' "$H2/.zshenv" \
   && ! grep -qF '$HOME/.iwe-paths' "$H2/.zshenv"; then
    pass "legacy block replaced, user lines before and after it kept"
else
    fail "legacy block migration lost user lines: $(tr '\n' '|' < "$H2/.zshenv")"
fi

[ "$FAIL" -eq 0 ] && echo "PASS: issue #1010 rc idempotence" || { echo "FAIL: issue #1010 rc idempotence has $FAIL violation(s)"; exit 1; }
