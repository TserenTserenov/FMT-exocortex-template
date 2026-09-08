#!/usr/bin/env bash
# see .claude/skills/iwe-platform-redteam/SKILL.md — step 0 Calibrate.
#
# Two legs:
#   1. boundary-guard behaviour — the safety-critical production code. Proves it
#      refuses real / non-disposable / workspace-nested targets, runs a command
#      under a disposable temp fixture, and redirects HOME/WORKSPACE_DIR (not
#      just IWE_ROOT) into the fixture so no env-derived path escapes.
#   2. environment smoke-test — that `shasum`/`cp -R` behave here and that the
#      manifest-integrity contract distinguishes a clean release from a tampered
#      one. This leg validates the ENVIRONMENT and the integrity contract, not
#      the LLM audit reasoning (that is runbook-driven and not executed here).
#
# Committed fixtures are never mutated: each is copied into a fresh mktemp first.
# Bash 3.2 compatible.

set -u

SKILL_DIR=$(cd "$(dirname "$0")/.." && pwd -P)
GUARD="$SKILL_DIR/boundary-guard.sh"
FIXTURES="$SKILL_DIR/fixtures"

fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

sha() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi; }

# Echo a fresh temp dir on stdout and return 0; return non-zero on failure so
# the caller's `x=$(mk) || halt` actually halts. A plain `exit` inside command
# substitution would only leave the subshell, letting the script continue with
# an empty path (and later `cp` into `/`) — so failure must travel via status.
mk() { d=$(mktemp -d 2>/dev/null) && [ -d "$d" ] && printf '%s' "$d"; }

# Deterministic integrity reflex: recompute each manifest hash, check the CI
# receipt, and return GO only when every delivered file matches and required
# checks passed. Returns a reason code on failure so a green result cannot hide
# the wrong cause.  `|| [ -n "$expected" ]` keeps a final line lacking a
# trailing newline (a real manifest could) from being silently skipped.
classify_release() {
  release_dir="$1"
  manifest="$release_dir/manifest.txt"
  receipt="$release_dir/ci-receipt.txt"
  [ -f "$manifest" ] || { echo BLOCKED_MANIFEST; return; }
  [ -f "$receipt" ]  || { echo BLOCKED_RECEIPT; return; }
  while read -r expected relpath || [ -n "$expected" ]; do
    [ -n "$expected" ] || continue
    target="$release_dir/$relpath"
    [ -f "$target" ] || { echo BLOCKED_MISSING; return; }
    [ "$(sha "$target")" = "$expected" ] || { echo BLOCKED_HASH; return; }
  done < "$manifest"
  grep -q '^required_checks: passed$' "$receipt" || { echo BLOCKED_RECEIPT; return; }
  grep -q '^status: green$' "$receipt" || { echo BLOCKED_RECEIPT; return; }
  echo GO
}

# --- guard: refuse a real workspace path --------------------------------------
if IWE_REDTEAM_FIXTURE_ROOT="$HOME/IWE" bash "$GUARD" -- true 2>/dev/null; then
  bad "guard should refuse a real IWE workspace path but ran the command"
else
  pass "guard refuses a real IWE workspace path"
fi

# --- guard: refuse a real, non-disposable path (real home) --------------------
if IWE_REDTEAM_FIXTURE_ROOT="$HOME" bash "$GUARD" -- true 2>/dev/null; then
  bad "guard should refuse a real non-temp path (\$HOME) but ran the command"
else
  pass "guard refuses a real non-disposable path"
fi

# --- guard: refuse a fixture nested inside a (temp-located) workspace ----------
# Exercises the defense-in-depth nesting branch: HOME points at a temp dir that
# contains an IWE/ subtree, and the fixture lives under it.
fakehome=$(mk) || { bad "mktemp -d failed"; exit 1; }
mkdir -p "$fakehome/IWE/sub"
if HOME="$fakehome" IWE_REDTEAM_FIXTURE_ROOT="$fakehome/IWE/sub" bash "$GUARD" -- true 2>/dev/null; then
  bad "guard should refuse a fixture nested inside the workspace root but ran it"
else
  pass "guard refuses a fixture nested inside the workspace root"
fi
rm -rf "$fakehome"

# --- guard: allow a disposable temp path and run the command ------------------
tmp_ok=$(mk) || { bad "mktemp -d failed"; exit 1; }
tmp_ok_abs=$(cd "$tmp_ok" && pwd -P)
out=$(IWE_REDTEAM_FIXTURE_ROOT="$tmp_ok" bash "$GUARD" -- sh -c 'printf ran' 2>/dev/null)
if [ "$out" = "ran" ]; then
  pass "guard runs the command under a disposable temp path"
else
  bad "guard should run under a temp path (got: '$out')"
fi

# --- guard: redirect HOME into the fixture (not the real home) ----------------
home_in=$(IWE_REDTEAM_FIXTURE_ROOT="$tmp_ok" bash "$GUARD" -- sh -c 'printf "%s" "$HOME"' 2>/dev/null)
if [ "$home_in" = "$tmp_ok_abs" ]; then
  pass "guard redirects HOME into the fixture"
else
  bad "guard should set HOME to the fixture (got: '$home_in', want: '$tmp_ok_abs')"
fi

# --- guard: redirect WORKSPACE_DIR into the fixture (Critical #1) --------------
ws_in=$(IWE_REDTEAM_FIXTURE_ROOT="$tmp_ok" WORKSPACE_DIR="/real/workspace" \
  bash "$GUARD" -- sh -c 'printf "%s" "$WORKSPACE_DIR"' 2>/dev/null)
if [ "$ws_in" = "$tmp_ok_abs" ]; then
  pass "guard redirects WORKSPACE_DIR into the fixture"
else
  bad "guard should override WORKSPACE_DIR to the fixture (got: '$ws_in', want: '$tmp_ok_abs')"
fi

# --- guard: strip inherited IWE_* variables -----------------------------------
leak=$(IWE_ROOT="/nonexistent/leaked-workspace/IWE" IWE_REDTEAM_FIXTURE_ROOT="$tmp_ok" \
  bash "$GUARD" -- sh -c 'printf "%s" "${IWE_ROOT:-clean}"' 2>/dev/null)
if [ "$leak" = "clean" ]; then
  pass "guard strips inherited IWE_ROOT from the command environment"
else
  bad "guard leaked IWE_ROOT into the command (got: '$leak')"
fi
rm -rf "$tmp_ok"

# --- integrity contract: known-good -> GO -------------------------------------
good_run=$(mk) || { bad "mktemp -d failed"; exit 1; }
cp -R "$FIXTURES/known-good-release/." "$good_run/"
verdict_good=$(classify_release "$good_run")
if [ "$verdict_good" = "GO" ]; then
  pass "known-good release classified GO"
else
  bad "known-good release must be GO (got: $verdict_good)"
fi
rm -rf "$good_run"

# --- integrity contract: known-bad -> BLOCKED_HASH (planted mismatch) ---------
# The bad fixture differs from good ONLY in one manifest hash line, so the hash
# mismatch is the sole cause — assert that specific reason, not just "blocked".
bad_run=$(mk) || { bad "mktemp -d failed"; exit 1; }
cp -R "$FIXTURES/known-bad-release/." "$bad_run/"
verdict_bad=$(classify_release "$bad_run")
if [ "$verdict_bad" = "BLOCKED_HASH" ]; then
  pass "known-bad release BLOCKED by the planted manifest hash mismatch"
else
  bad "known-bad release must be BLOCKED_HASH (got: $verdict_bad) — false-green or wrong cause"
fi
rm -rf "$bad_run"

if [ "$fail" -eq 0 ]; then
  printf '\ncalibration OK — guard containment and integrity contract behave as required\n'
  exit 0
fi
printf '\ncalibration FAILED — do not trust a real audit verdict in this environment\n' >&2
exit 1
