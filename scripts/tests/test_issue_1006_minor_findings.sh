#!/usr/bin/env bash
# Regression for the clear-cut minor findings of issue #1006 (and #1010 F6, F-class "cd" in skills):
#  1 roles/lib/scheduler-cron.sh is executable in git
#  2 .claude/parity-contract.yaml is valid YAML (no invalid escapes) and the parity check still reads it
#  3 extractor.sh has a portable timeout (macOS / launchd have no timeout(1))
#  4 strategist.sh finds lib/common.sh in the template, not only in the workspace
#  5 setup-extractor-feeders.sh does not touch systemd/launchd under SETUP_CI=1; the smoke test sets SETUP_CI
#  6 delivered skills and memory do not tell the agent to run a top-level `cd` (blocked by destructive-guard)
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
fails=0
pass() { echo "  PASS: $*"; }
fail() { echo "  FAIL: $*" >&2; fails=$((fails + 1)); }

echo "== 1 scheduler-cron.sh mode"
mode=$(git -C "$ROOT" ls-files -s roles/lib/scheduler-cron.sh 2>/dev/null | cut -d' ' -f1)
if [ -z "$mode" ]; then echo "  skip: not a git checkout"
elif [ "$mode" = 100755 ]; then pass "mode 100755"; else fail "mode is $mode, expected 100755"; fi

echo "== 2 parity-contract.yaml"
if grep -nE 'regex: "[^"]*\\' "$ROOT/.claude/parity-contract.yaml" >/dev/null; then
  fail "a double-quoted regex with a backslash (invalid YAML escape): $(grep -nE 'regex: "[^"]*\\' "$ROOT/.claude/parity-contract.yaml" | head -1)"
else
  pass "no double-quoted regex with a backslash"
fi
if bash "$ROOT/scripts/check-setup-update-parity.sh" >"$TMP/parity.out" 2>&1; then pass "parity check still passes"; else fail "parity check failed: $(tail -3 "$TMP/parity.out" | tr '\n' ' ')"; fi
if python3 -c 'import yaml' 2>/dev/null; then
  python3 -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1], encoding="utf-8"))' "$ROOT/.claude/parity-contract.yaml" 2>"$TMP/y.err" \
    && pass "strict YAML parse" || fail "strict YAML parse: $(tail -1 "$TMP/y.err")"
fi

echo "== 3 extractor.sh portable timeout"
awk '/^    timeout\(\) \{/{c=1} c{print} c&&/^    \}$/{exit}' "$ROOT/roles/extractor/scripts/extractor.sh" > "$TMP/timeout_fn.sh"
if [ ! -s "$TMP/timeout_fn.sh" ]; then
  fail "extractor.sh defines no timeout fallback"
elif command -v perl >/dev/null 2>&1; then
  rc_slow=$(bash -c '. "$1"; timeout 1 sleep 5; echo $?' _ "$TMP/timeout_fn.sh")
  rc_ok=$(bash -c '. "$1"; timeout 5 true; echo $?' _ "$TMP/timeout_fn.sh")
  { [ "$rc_slow" = 124 ] && [ "$rc_ok" = 0 ]; } && pass "fallback times out (124) and passes a fast command (0)" || fail "fallback rc slow=$rc_slow ok=$rc_ok"
  # 124 only on a real timeout: a child killed by a signal reports 128+signal, a plain exit keeps its code
  rc_sig=$(bash -c '. "$1"; timeout 5 sh -c "kill -9 \$\$"; echo $?' _ "$TMP/timeout_fn.sh")
  rc_7=$(bash -c '. "$1"; timeout 5 sh -c "exit 7"; echo $?' _ "$TMP/timeout_fn.sh")
  { [ "$rc_sig" = 137 ] && [ "$rc_7" = 7 ]; } && pass "signalled child -> 137, exit 7 -> 7 (not 124 or 0)" || fail "rc signalled=$rc_sig exit7=$rc_7"
  # a child that ignores TERM is still stopped and reaped
  start=$(date +%s)
  rc_term=$(bash -c '. "$1"; timeout 1 sh -c "trap \"\" TERM; while :; do :; done"; echo $?' _ "$TMP/timeout_fn.sh")
  [ "$rc_term" = 124 ] && [ $(( $(date +%s) - start )) -lt 6 ] && pass "a TERM-ignoring child is killed, 124" || fail "TERM-ignoring child: rc=$rc_term"
else
  echo "  skip: no perl"
fi

echo "== 4 strategist.sh finds common.sh in the template"
awk '/^find_common_sh\(\) \{/{c=1} c{print} c&&/^\}$/{exit}' "$ROOT/roles/strategist/scripts/strategist.sh" > "$TMP/find_common.sh"
if [ ! -s "$TMP/find_common.sh" ]; then
  fail "strategist.sh has no find_common_sh"
else
  mkdir -p "$TMP/tpl/scripts/lib" "$TMP/ws"
  : > "$TMP/tpl/scripts/lib/common.sh"
  got=$(IWE_TEMPLATE="$TMP/tpl" IWE_WORKSPACE="$TMP/ws" bash -c '. "$1"; find_common_sh' _ "$TMP/find_common.sh")
  [ "$got" = "$TMP/tpl/scripts/lib/common.sh" ] && pass "template copy found with an empty workspace" || fail "got '$got'"
  got=$(IWE_TEMPLATE= IWE_WORKSPACE="$TMP/ws" bash -c '. "$1"; find_common_sh' _ "$TMP/find_common.sh") && fail "found something where nothing exists: $got" || pass "nothing found -> non-zero"
fi
grep -q '_iwe_common="${IWE_WORKSPACE:-$HOME/IWE}/scripts/lib/common.sh"' "$ROOT/roles/strategist/scripts/strategist.sh" \
  && fail "strategist.sh still looks only in the workspace" || pass "no workspace-only lookup left"

echo "== 5 SETUP_CI keeps the scheduler untouched"
grep -q 'SETUP_CI=1' "$ROOT/setup/smoke-test-fresh-install.sh" && pass "smoke test passes SETUP_CI=1" || fail "smoke test never sets SETUP_CI"
if [ "$(uname -s)" = Linux ]; then
  GOV=gov-repo; H="$TMP/home"; W="$TMP/work"; B="$TMP/bin"
  mkdir -p "$H" "$W/.iwe-runtime/roles/extractor/scripts" "$W/$GOV/inbox" "$B"
  printf '#!/bin/sh\nexit 0\n' > "$W/.iwe-runtime/roles/extractor/scripts/extractor.sh"; chmod +x "$W/.iwe-runtime/roles/extractor/scripts/extractor.sh"
  printf '#!/bin/sh\nexit 0\n' > "$B/claude"
  printf '#!/bin/sh\necho "$0 $*" >> "%s/sched-calls.log"\nexit 0\n' "$TMP" > "$B/systemctl"
  chmod +x "$B/claude" "$B/systemctl"
  : > "$TMP/sched-calls.log"
  HOME="$H" IWE_WORKSPACE="$W" PATH="$B:$PATH" SETUP_CI=1 bash "$ROOT/scripts/setup-extractor-feeders.sh" --schedule-only >"$TMP/feeders.out" 2>&1
  if [ ! -s "$TMP/sched-calls.log" ] && [ -f "$H/.config/systemd/user/extractor-git-diff-feed.timer" ]; then
    pass "units written, systemctl not called"
  else
    fail "systemctl called under SETUP_CI or units missing: $(head -2 "$TMP/sched-calls.log" | tr '\n' ' ') $(tail -2 "$TMP/feeders.out" | tr '\n' ' ')"
  fi
fi

echo "== 6 no top-level cd in delivered skills and memory"
bad=$(grep -nE '^[[:space:]]*(`)?cd [^ ]' "$ROOT"/.claude/skills/*/SKILL.md "$ROOT"/memory/*.md 2>/dev/null \
      | grep -vE ':[[:space:]]*\(cd ' | grep -vE 'cd <|^[^:]*:[0-9]+:[[:space:]]*#' || true)
[ -z "$bad" ] && pass "every cd sits in a subshell" || fail "top-level cd: $(printf '%s' "$bad" | head -3 | tr '\n' ' ')"

echo
if [ "$fails" -eq 0 ]; then echo "PASS: #1006"; else echo "FAILED: $fails check(s)"; exit 1; fi
