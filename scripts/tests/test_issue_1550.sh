#!/usr/bin/env bash
# Regression for issue #1550: week-close step 0б wrote the retro answer into the week ledger,
# no publisher service ships with the template, and the step looked done while the ledger file
# stayed unsaved. The skill now (a) points IWE_LEDGER_DIR at the copy step 11 commits from,
# (b) adds the ledger file to the week-close commit, (c) counts 0б done only when that file is
# in a commit that reached origin/main.
#
# The check block is taken from .claude/skills/week-close/SKILL.md itself and run against a
# disposable repo with a bare origin: once with the ledger committed and pushed, once without.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
SKILL="$ROOT/.claude/skills/week-close/SKILL.md"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/ledger-1550.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT
mkdir -p "$TMP/home" "$TMP/tmp"
# ledger-append.sh needs PyYAML; a --user install lives under the real HOME (same pin as run-issue-tests.sh)
PYTHONUSERBASE="${PYTHONUSERBASE:-$(python3 -m site --user-base 2>/dev/null || true)}"
export PYTHONUSERBASE
export HOME="$TMP/home" TMPDIR="$TMP/tmp"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
unset IWE_ROOT IWE_WORKSPACE IWE_GOVERNANCE_REPO IWE_TEMPLATE IWE_LEDGER_DIR

PASSES=0
FAILS=0
ok()  { echo "  ✅ PASS: $*"; PASSES=$((PASSES + 1)); }
bad() { echo "  ❌ FAIL: $*" >&2; FAILS=$((FAILS + 1)); }
expect_has() { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1: [$2] not found in: $3" ;; esac; }

skill=$(cat "$SKILL")
echo "--- #1550 A: skill text contract ---"
expect_has "0б sets IWE_LEDGER_DIR to the commit copy" 'export IWE_LEDGER_DIR="$WC_REPO/machine/ledger"' "$skill"
expect_has "step 11 stages the ledger file" '"$LEDGER_WEEK_REL")' "$skill"
expect_has "0б is not marked done before step 11" 'Шаг 0б здесь ещё не выполнен' "$skill"

# The fenced bash block that follows the «Проверка шага 0б» heading.
CHECK_BLOCK=$(awk '/^\*\*Проверка шага 0б/ {f=1; next} f && /^```bash$/ {b=1; next} b && /^```$/ {exit} b {print}' "$SKILL")
if [ -n "$CHECK_BLOCK" ]; then ok "check block found in the skill"; else bad "check block not found"; fi

new_repo() {  # prints the path of a clone with a bare origin and one initial commit
  local d
  d=$(mktemp -d "$TMP/case.XXXXXX")
  git init -q --bare "$d/origin.git"
  git init -q -b main "$d/gov"
  git -C "$d/gov" remote add origin "$d/origin.git"
  echo seed > "$d/gov/README.md"
  git -C "$d/gov" add README.md && git -C "$d/gov" commit -q -m seed && git -C "$d/gov" push -q origin main
  printf '%s\n' "$d/gov"
}

append_retro() {  # <repo>: the step-0б write with IWE_LEDGER_DIR as the skill sets it
  IWE_LEDGER_DIR="$1/machine/ledger" bash "$ROOT/scripts/ledger-append.sh" week 2099-W01 pilot_answer \
    '{"subtype":"preclose_retro","retro_worked":"a","retro_failed":"b"}' week-close >/dev/null 2>&1
}

run_check() {  # <repo>
  WC_REPO="$1" LEDGER_WEEK_REL="machine/ledger/week/2099/week-2099-W01.yaml" bash -c "$CHECK_BLOCK" 2>&1
}

echo "--- #1550 B: ledger committed and pushed -> saved ---"
R=$(new_repo)
append_retro "$R"
if [ -f "$R/machine/ledger/week/2099/week-2099-W01.yaml" ]; then ok "ledger written into the commit copy"
else bad "ledger not written into $R/machine/ledger"; fi
git -C "$R" add machine/ledger/week/2099/week-2099-W01.yaml && git -C "$R" commit -q -m "week-close: W01" && git -C "$R" push -q origin main
expect_has "pushed ledger: step 0б counts as done" "журнал недели сохранён" "$(run_check "$R")"

echo "--- #1550 C: ledger written but not committed -> warning with path ---"
R=$(new_repo)
append_retro "$R"
out=$(run_check "$R")
expect_has "unsaved ledger: warning" "ЖУРНАЛ НЕДЕЛИ НЕ СОХРАНЁН" "$out"
expect_has "unsaved ledger: path printed" "$R/machine/ledger/week/2099/week-2099-W01.yaml" "$out"

echo "--- #1550 D: committed locally, not pushed -> warning ---"
R=$(new_repo)
append_retro "$R"
git -C "$R" add machine/ledger/week/2099/week-2099-W01.yaml && git -C "$R" commit -q -m "week-close: W01"
expect_has "unpushed ledger: warning" "ЖУРНАЛ НЕДЕЛИ НЕ СОХРАНЁН" "$(run_check "$R")"

echo
echo "issue #1550: $PASSES passed, $FAILS failed"
[ "$FAILS" -eq 0 ]
