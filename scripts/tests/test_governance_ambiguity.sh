#!/bin/bash
# test_governance_ambiguity.sh — WP-560 follow-up (peer-session
# 2026-09-11-19-wp560-agentic-cleanup, Claude+Codex).
#
# setup.sh's local governance-repo auto-detect used to take the first
# DS-*strategy* directory it found on disk and `break`, silently ignoring the
# contract's ambiguityPolicy.twoOrMore (fail_closed): with two candidate
# directories present it would adopt/create against the alphabetically-first
# one instead of refusing. A second-round peer review (Codex) found the first
# fix incomplete: a separate, earlier check for the exact default-named
# directory (GOVERNANCE_CONTRACT_DEFAULT_REPO) used to short-circuit the whole
# auto-detect loop before it ever ran, so a default-named dir sitting next to
# a differently-named one still wasn't caught — scenario 4 below pins that.
# Invariants under test (dry-run, fake gh on PATH, no GOVERNANCE_REPO/
# IWE_GOVERNANCE_REPO set so the auto-detect path runs, except scenario 5):
#   1. zero local candidates → unaffected, falls through to the existing
#      GOVERNANCE_CONTRACT_DEFAULT_REPO creation path;
#   2. exactly one local candidate → unaffected, picked as before;
#   3. two non-default local candidates → fails closed with a named-candidates
#      error, before any `gh repo create/view` call;
#   4. the default-named directory plus one other candidate → fails closed
#      too (the default name is not a silent tie-breaker);
#   5. two local candidates but an explicit GOVERNANCE_REPO override →
#      succeeds using the override, auto-detect is never consulted.
#
# Bash 3.2 compatible. Usage: bash scripts/tests/test_governance_ambiguity.sh

set -uo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_ROOT="$(cd "$SELF_DIR/../.." && pwd)"

FAIL_COUNT=0; PASS_COUNT=0
fail() { echo "  ❌ FAIL: $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }
pass() { echo "  ✅ PASS: $*"; PASS_COUNT=$((PASS_COUNT + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM
TEMPLATE_COPY="$TMP/FMT-exocortex-template"; FAKE_BIN="$TMP/fake-bin"; GH_LOG="$TMP/gh.log"
mkdir -p "$TEMPLATE_COPY" "$FAKE_BIN" "$TMP/home"
tar -C "$TEMPLATE_ROOT" --exclude='./.git' -cf - . | tar -C "$TEMPLATE_COPY" -xf -

# Fake gh: every repo always reports "remote absent" — irrelevant to what
# this test checks (the ambiguity gate runs before any gh call), but the
# script still probes `gh auth status`/`gh repo view` on the way there.
cat > "$FAKE_BIN/gh" <<'SH'
#!/bin/sh
printf '%s\n' "gh $*" >>"$FAKE_GH_LOG"
case "$1 $2" in
  "auth status") exit 0 ;;
  "repo view") exit 1 ;;
  *) exit 97 ;;
esac
SH
chmod +x "$FAKE_BIN/gh"
for c in curl wget; do printf '#!/bin/sh\nexit 97\n' > "$FAKE_BIN/$c"; chmod +x "$FAKE_BIN/$c"; done

run_setup() { # $1 = workspace dir (candidates already created there); $2 = optional GOVERNANCE_REPO override
  : >"$GH_LOG"
  # .exocortex.env deliberately omits GOVERNANCE_REPO (build-runtime.sh --dry-run
  # requires the file to exist at all, same fixture shape as test_adopt_governance.sh).
  cat > "$1/.exocortex.env" <<ENVEOF
GITHUB_USER="contract-test"
WORKSPACE_DIR="$1"
CLAUDE_PATH="claude"
CLAUDE_PROJECT_SLUG="contract-test"
TIMEZONE_HOUR="4"
TIMEZONE_DESC="4:00 UTC"
HOME_DIR="$TMP/home"
USER_NAME="contract-test"
IWE_TEMPLATE="$TEMPLATE_COPY"
IWE_RUNTIME="$1/.iwe-runtime"
ENVEOF
  # GOVERNANCE_REPO and IWE_GOVERNANCE_REPO must both be pinned (empty unless
  # $2 overrides), not just omitted: the caller's own shell may already
  # export either one (this repo's dev environment does, for both), and
  # `env` without `-i` still lets inherited variables leak straight through
  # untouched — GOVERNANCE_REPO is setup.sh's highest-precedence source, so a
  # leaked value here would skip the auto-detect loop under test entirely and
  # silently pass for the wrong reason (found live: an early version of this
  # test "passed" on a leaked value that happened to match its fixture).
  env HOME="$TMP/home" PATH="$FAKE_BIN:$PATH" FAKE_GH_LOG="$GH_LOG" \
      SETUP_CI=1 GITHUB_USER=contract-test WORKSPACE_DIR="$1" \
      GOVERNANCE_REPO="${2:-}" IWE_GOVERNANCE_REPO= \
      bash "$TEMPLATE_COPY/setup.sh" --dry-run >"$TMP/out.log" 2>&1
  echo $?
}

echo "=== 1. Zero local candidates -> unaffected, falls through to default creation path ==="
WS1="$TMP/ws-zero"; mkdir -p "$WS1"
rc=$(run_setup "$WS1")
[ "$rc" = "0" ] && pass "setup.sh --dry-run exits 0" || fail "exit $rc; $(tail -8 "$TMP/out.log")"
grep -qF "Would create DS-strategy from seed/strategy" "$TMP/out.log" \
  && pass "creation path uses the contract default name" || fail "no default creation line; output: $(tail -8 "$TMP/out.log")"

echo "=== 2. Exactly one local candidate -> unaffected, picked as before ==="
WS2="$TMP/ws-one"; mkdir -p "$WS2/DS-teamalpha-strategy"
rc=$(run_setup "$WS2")
[ "$rc" = "0" ] && pass "setup.sh --dry-run exits 0" || fail "exit $rc; $(tail -8 "$TMP/out.log")"
grep -qF "Would create DS-teamalpha-strategy from seed/strategy" "$TMP/out.log" \
  && pass "sole local candidate is picked up" || fail "candidate not used; output: $(tail -8 "$TMP/out.log")"

echo "=== 3. Two local candidates -> fail closed, before any gh call ==="
WS3="$TMP/ws-two"; mkdir -p "$WS3/DS-teamalpha-strategy" "$WS3/DS-teambeta-strategy"
rc=$(run_setup "$WS3")
[ "$rc" != "0" ] && pass "setup.sh refuses (exit $rc)" || fail "accepted an ambiguous local match"
grep -qF "найдено несколько локальных кандидатов на governance-репо" "$TMP/out.log" \
  && pass "refusal names the ambiguity" || fail "no ambiguity message; output: $(tail -8 "$TMP/out.log")"
grep -qF "DS-teamalpha-strategy" "$TMP/out.log" && grep -qF "DS-teambeta-strategy" "$TMP/out.log" \
  && pass "both candidate names are listed" || fail "candidate names missing from the error"
# `gh auth status` is a generic prerequisite check that runs before any
# repo is even chosen — only `repo view/create/clone` would mean the script
# picked one of the two ambiguous candidates and moved on regardless.
grep -qE "^gh repo (view|create|clone)" "$GH_LOG" \
  && fail "a repo was queried/created despite the ambiguity ($(cat "$GH_LOG"))" \
  || pass "no repo query/create/clone before refusal"

echo "=== 4. Default-named directory plus one other candidate -> still fails closed ==="
WS4="$TMP/ws-default-plus-other"; mkdir -p "$WS4/DS-strategy" "$WS4/DS-teamalpha-strategy"
rc=$(run_setup "$WS4")
[ "$rc" != "0" ] && pass "setup.sh refuses (exit $rc)" || fail "silently picked the default name over the other candidate"
grep -qF "найдено несколько локальных кандидатов на governance-репо" "$TMP/out.log" \
  && pass "refusal names the ambiguity" || fail "no ambiguity message; output: $(tail -8 "$TMP/out.log")"
grep -qF "DS-strategy" "$TMP/out.log" && grep -qF "DS-teamalpha-strategy" "$TMP/out.log" \
  && pass "both candidate names are listed, default included" || fail "candidate names missing from the error"

echo "=== 5. Two local candidates but an explicit override -> override wins, no ambiguity check ==="
WS5="$TMP/ws-override"; mkdir -p "$WS5/DS-teamalpha-strategy" "$WS5/DS-teambeta-strategy"
rc=$(run_setup "$WS5" "DS-teamalpha-strategy")
[ "$rc" = "0" ] && pass "setup.sh --dry-run exits 0" || fail "exit $rc; $(tail -8 "$TMP/out.log")"
grep -qF "найдено несколько локальных кандидатов" "$TMP/out.log" \
  && fail "ambiguity check ran despite an explicit override" || pass "auto-detect not consulted, override honored"
grep -qF "DS-teamalpha-strategy" "$TMP/out.log" \
  && pass "the overridden name is the one used" || fail "override name not reflected in output; output: $(tail -8 "$TMP/out.log")"

echo ""
echo "Result: $PASS_COUNT PASS, $FAIL_COUNT FAIL"
[ "$FAIL_COUNT" -eq 0 ]
