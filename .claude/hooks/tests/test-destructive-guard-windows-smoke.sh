#!/usr/bin/env bash
# test-destructive-guard-windows-smoke.sh — WP-529 F275, rc.11 red team F12 follow-up: the
# released-guard floor of destructive-guard.sh (perl Digest::SHA, Cwd, a process group per
# run, a time limit) must work where the hook really runs, including Git Bash on Windows; if any
# part failed there, the hook would block every command. Ordinary commands must pass without an
# ask, the F8 text and `rm -rf ~` must block, and the hook called by its real path from another
# folder must pass an ordinary command. Commands are hook input only; nothing is executed.
#
# Run: bash .claude/hooks/tests/test-destructive-guard-windows-smoke.sh
set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)/destructive-guard.sh"
ROOT="$(cd "$(dirname "$HOOK")/../.." && pwd -P)"
OTHER=$(mktemp -d "${TMPDIR:-/tmp}/dg-smoke.XXXXXX")
trap 'rmdir "$OTHER" 2>/dev/null || true' EXIT
FAILS=0
F8=$(printf ': x[ <<W\necho %sa\nW\nfind . -delete' "'")

# check WANT CWD COMMAND — WANT is pass (exit 0, no output) or block (exit 2).
check() {
  local want=$1 dir=$2 cmd=$3 input out err rc got
  input=$(jq -n --arg c "$cmd" --arg d "$dir" '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d}')
  local t0=${EPOCHREALTIME:-0}
  out=$(cd "$dir" && printf '%s' "$input" | bash "$HOOK" 2>"$OTHER.err")
  rc=$?
  local took
  took=$(awk -v a="$t0" -v b="${EPOCHREALTIME:-0}" 'BEGIN { printf "%.2f", b - a }')
  err=$(cat "$OTHER.err" 2>/dev/null); rm -f "$OTHER.err"
  if [ "$rc" -eq 2 ]; then got=block
  elif [ "$rc" -eq 0 ] && [ -z "$out" ]; then got=pass
  else got="exit $rc, output ${out:0:80}"; fi
  if [ "$got" = "$want" ]; then
    echo "ok   $want: ${cmd%%$'\n'*} (${took} s)"
  else
    echo "FAIL $want: ${cmd%%$'\n'*} -> $got ${err:0:300}"
    FAILS=$((FAILS + 1))
  fi
}

# How jq writes a newline here (a native Windows jq writes CR LF in text mode).
echo "jq: $(jq --version 2>&1); jq -j of \"a\\nb\": $(printf '"a\\nb"' | jq -j . | od -c | head -1)"
check pass "$ROOT" "git status"
check pass "$ROOT" "ls -la"
check block "$ROOT" "$F8"
check block "$ROOT" "rm -rf ~"
check pass "$OTHER" "git status"
leftover=$(ls -d "${TMPDIR:-/tmp}"/dg-legacy.* 2>/dev/null | wc -l | tr -d ' ')
echo "dg-legacy folders in TMPDIR after the run: $leftover"

if [ "$FAILS" -gt 0 ]; then
  # Diagnostics: each released guard alone on the F8 text, and the runner as the hook starts it.
  input=$(jq -n --arg c "$F8" --arg d "$ROOT" '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d}')
  for g in "$(dirname "$HOOK")"/destructive-guard.d/*.sh; do
    printf '%s' "$input" | DG_LEGACY_HOOK_DIR="$(dirname "$HOOK")" bash "$g" >/dev/null 2>"$OTHER.e"; rc=$?
    echo "diag: $(basename "$g") alone -> exit $rc $(head -c 200 "$OTHER.e")"
  done
  rm -f "$OTHER.e"
  command -v bash perl jq; perl -v | sed -n 2p
  perl -MPOSIX -e 'my $p = fork(); if (!$p) { setpgrp(0, 0); exec("bash", "-c", "exit 7"); } my $w = 0; for (1 .. 400) { $w = waitpid($p, POSIX::WNOHANG()); last if $w == $p; select(undef, undef, undef, 0.01); } print "diag: fork/waitpid -> w=$w st=", $? >> 8, "\n";'
  echo "FAILED: $FAILS"
  exit 1
fi
echo "PASS: destructive-guard and its released-guard floor work here"
