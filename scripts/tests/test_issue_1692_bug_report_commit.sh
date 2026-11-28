#!/usr/bin/env bash
# Regression for issue #1692: step 3 of /iwe-bug-report put the LAST commit of the user's local
# copy of the template into the issue ("IWE commit"). On a fork that commit is not in the upstream
# history, so it tells the template author nothing. The step now reports the upstream commit
# (upstream/main) when the copy has it, the copy's commit when its origin IS the upstream, and the
# copy's commit with an explicit note otherwise; "неизвестно" when there is no repository at all.
#
# The bash block is taken from .claude/skills/iwe-bug-report/SKILL.md itself (the text the agent
# follows) and run against disposable repositories.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
SKILL="$ROOT/.claude/skills/iwe-bug-report/SKILL.md"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/bugreport-1692.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
unset IWE_ROOT IWE_TEMPLATE IWE_GOVERNANCE_REPO

PASSES=0
FAILS=0
ok()  { echo "  ✅ PASS: $*"; PASSES=$((PASSES + 1)); }
bad() { echo "  ❌ FAIL: $*" >&2; FAILS=$((FAILS + 1)); }
expect_has()  { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1: [$2] not found in: $3" ;; esac; }
expect_lacks() { case "$3" in *"$2"*) bad "$1: [$2] must not be in: $3" ;; *) ok "$1" ;; esac; }

# The first fenced bash block after the "Шаг 3" heading.
STEP3=$(awk '/^## Шаг 3\./ {f=1; next} f && /^```bash$/ {b=1; next} b && /^```$/ {exit} b {print}' "$SKILL")
if [ -n "$STEP3" ]; then ok "step 3 block found in the skill"; else bad "step 3 block not found"; exit 1; fi

commit_at() {  # <repo> <message> <author date>: one commit with a fixed date, prints its short hash
  echo "$2" >> "$1/f.txt"
  git -C "$1" add f.txt
  GIT_AUTHOR_DATE="$3T10:00:00" GIT_COMMITTER_DATE="$3T10:00:00" git -C "$1" commit -q -m "$2"
  git -C "$1" log -1 --format=%h
}

run_step3() {  # <workspace>
  IWE_WORKSPACE="$1" HOME="$TMP/home" bash -c "$STEP3" 2>&1
}
mkdir -p "$TMP/home"

# --- A: a fork with the upstream configured: the upstream commit is reported, not the fork's ---
UP="$TMP/upstream.git"; SEED="$TMP/seed"
git init -q --bare -b main "$UP"
git init -q -b main "$SEED"
UP_HASH=$(commit_at "$SEED" "upstream commit" 2026-11-01)
git -C "$SEED" remote add origin "$UP"; git -C "$SEED" push -q origin main

WS_A="$TMP/ws-a"; mkdir -p "$WS_A"
git init -q -b main "$WS_A/FMT-exocortex-template"
FORK_HASH=$(commit_at "$WS_A/FMT-exocortex-template" "fork-only commit" 2026-11-20)
git -C "$WS_A/FMT-exocortex-template" remote add origin "https://github.com/someone/FMT-exocortex-template.git"
git -C "$WS_A/FMT-exocortex-template" remote add upstream "$UP"
git -C "$WS_A/FMT-exocortex-template" fetch -q upstream
echo "--- #1692 A: fork + upstream -> the upstream commit ---"
out=$(run_step3 "$WS_A")
expect_has "A: the upstream commit and its date are reported" "$UP_HASH 2026-11-01" "$out"
expect_lacks "A: the fork's own commit is not reported" "$FORK_HASH" "$out"
expect_lacks "A: no 'local copy' note when upstream/main is known" "коммит локальной копии" "$out"

# --- B: origin IS the upstream: the copy's commit is already an upstream commit ---
WS_B="$TMP/ws-b"; mkdir -p "$WS_B"
git init -q -b main "$WS_B/FMT-exocortex-template"
B_HASH=$(commit_at "$WS_B/FMT-exocortex-template" "installed from upstream" 2026-11-10)
git -C "$WS_B/FMT-exocortex-template" remote add origin "https://github.com/TserenTserenov/FMT-exocortex-template.git"
echo "--- #1692 B: origin is the upstream -> the copy's commit, no note ---"
out=$(run_step3 "$WS_B")
expect_has "B: the copy's commit and date" "$B_HASH 2026-11-10" "$out"
expect_lacks "B: no 'local copy' note" "коммит локальной копии" "$out"

# --- C: a fork without the upstream remote: the commit is reported WITH a note that says so ---
WS_C="$TMP/ws-c"; mkdir -p "$WS_C"
git init -q -b main "$WS_C/FMT-exocortex-template"
C_HASH=$(commit_at "$WS_C/FMT-exocortex-template" "fork only" 2026-11-15)
git -C "$WS_C/FMT-exocortex-template" remote add origin "https://github.com/someone/FMT-exocortex-template.git"
echo "--- #1692 C: fork, no upstream -> commit with the note ---"
out=$(run_step3 "$WS_C")
expect_has "C: the copy's commit is still given" "$C_HASH 2026-11-15" "$out"
expect_has "C: the note says the commit may not be in the upstream history" "коммит локальной копии" "$out"
expect_has "C: the note names the missing upstream/main" "upstream/main нет" "$out"

# --- D: the upstream remote exists but was never fetched: same note, not a silent fork commit ---
WS_D="$TMP/ws-d"; mkdir -p "$WS_D"
git init -q -b main "$WS_D/FMT-exocortex-template"
commit_at "$WS_D/FMT-exocortex-template" "fork only" 2026-11-16 >/dev/null
git -C "$WS_D/FMT-exocortex-template" remote add origin "https://github.com/someone/FMT-exocortex-template.git"
git -C "$WS_D/FMT-exocortex-template" remote add upstream "$UP"
echo "--- #1692 D: upstream remote not fetched -> note ---"
expect_has "D: the note is present" "коммит локальной копии" "$(run_step3 "$WS_D")"

# --- E: no repository at all ---
WS_E="$TMP/ws-e"; mkdir -p "$WS_E/FMT-exocortex-template"
echo "--- #1692 E: no repository -> неизвестно ---"
out=$(run_step3 "$WS_E")
case "$out" in *"неизвестно"*) ok "E: unknown version is reported" ;; *) bad "E: expected 'неизвестно', got: $out" ;; esac

echo
echo "issue #1692: $PASSES passed, $FAILS failed"
[ "$FAILS" -eq 0 ]
