#!/bin/bash
# strategy-session-isolated-copy-smoke.sh -- regression guard (WP-530 F72 wave 4).
# Text checks on SKILL.md + a behavioural run of the Step 0 block on a synthetic repo.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="${STRATEGY_SKILL_UNDER_TEST:-$SCRIPT_DIR/../../.claude/skills/strategy-session/SKILL.md}"
[ -f "$SKILL" ] || { echo "FAIL: $SKILL not found"; exit 1; }
FAILURES=0
check() { if [ "$2" = ok ]; then echo "PASS: $1"; else echo "FAIL: $1"; FAILURES=$((FAILURES+1)); fi; }
has() { grep -qF -- "$1" "$SKILL"; }

# --- text checks
grep -nE '\{\{WORKSPACE_DIR\}\}/\{\{GOVERNANCE_REPO\}\}/(docs|current|inbox|Lifework|archive)' "$SKILL" >/dev/null \
  && check "no canonical literal in paths" bad || check "no canonical literal in paths" ok
has 'resolve_active_worktree' && has 'GOV_WT=' && check "resolver defines GOV_WT" ok || check "resolver defines GOV_WT" bad
has 'open --isolate' && check "isolation command" ok || check "isolation command" bad
has 'ds-publish.sh' && check "ds-publish" ok || check "ds-publish" bad
has 'GUARD_MODE=absent' && has 'mode=legacy' && check "explicit no-session-guard branch" ok || check "explicit no-session-guard branch" bad
has ': "${GOV_WT:?}"' && has 'cd -- "$GOV_WT" || exit 1' && check "GOV_WT re-check in write blocks" ok || check "GOV_WT re-check in write blocks" bad
has '--git-common-dir' && check "common-dir membership check" ok || check "common-dir membership check" bad
has 'bash "$GOV_WT/scripts/ds-publish.sh" "$GOV_WT"' && has 'source "{{WORKSPACE_DIR}}/scripts/lib/common.sh"' && check "quoted paths" ok || check "quoted paths" bad
# extensions come after the working-copy step
o1=$(grep -n '^### Шаг 0\. Рабочая копия' "$SKILL" | head -1 | cut -d: -f1)
o2=$(grep -n 'load-extensions.sh strategy-session before' "$SKILL" | head -1 | cut -d: -f1)
[ -n "$o1" ] && [ -n "$o2" ] && [ "$o1" -lt "$o2" ] && check "working copy step precedes before-extensions" ok || check "working copy step precedes before-extensions" bad
for t in docs/Strategy.md docs/Dissatisfactions.md 'current/WeekPlan W{N}.md' docs/Backlog.md; do
  has "\$GOV_WT/$t" && check "GOV_WT path: $t" ok || check "GOV_WT path: $t" bad
done

# --- behavioural run of the Step 0 block
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
python3 - "$SKILL" "$TMP/block.sh" <<'PY'
import re,sys
s=open(sys.argv[1]).read()
i=s.index("### Шаг 0. Рабочая копия")
m=re.search(r"```bash\n(.*?)```",s[i:],re.S)
open(sys.argv[2],"w").write(m.group(1))
PY
[ -s "$TMP/block.sh" ] || { check "block extracted" bad; exit 1; }
ROOT="$TMP/ws"; mkdir -p "$ROOT/scripts" "$TMP/other"
git init -q "$ROOT/GOV" && git -C "$ROOT/GOV" -c user.email=a@b -c user.name=t commit -q --allow-empty -m i
git -C "$ROOT/GOV" worktree add -q -b wt "$TMP/wt" 2>/dev/null
git init -q "$TMP/other" && git -C "$TMP/other" -c user.email=a@b -c user.name=t commit -q --allow-empty -m i
sed "s#{{WORKSPACE_DIR}}#$ROOT#g; s#{{GOVERNANCE_REPO}}#GOV#g" "$TMP/block.sh" > "$TMP/run.sh"
run() { (cd "$1" && IWE_SCRIPTS="$ROOT/none" bash "$TMP/run.sh" 2>&1); }
wtreal=$(cd "$TMP/wt" && pwd -P)
# no guard: legacy, canon and worktree both OK, unrelated repo falls back to canon
out=$(run "$ROOT/GOV"); rc=$?; [ $rc -eq 0 ] && echo "$out" | grep -q 'mode=legacy' && check "no guard, canon -> legacy ok" ok || check "no guard, canon -> legacy ok" bad
out=$(run "$TMP/other"); rc=$?; [ $rc -eq 0 ] && echo "$out" | grep -q "GOV_WT=.*/GOV mode=legacy" && check "no guard, foreign repo -> canon, not foreign" ok || check "no guard, foreign repo -> canon, not foreign" bad
# guard present
: > "$ROOT/scripts/session-guard.sh"
out=$(run "$ROOT/GOV"); rc=$?; [ $rc -eq 2 ] && echo "$out" | grep -q 'NOT ISOLATED' && check "guard, canon -> exit 2" ok || check "guard, canon -> exit 2" bad
out=$(run "$TMP/other"); rc=$?; [ $rc -eq 2 ] && check "guard, foreign repo -> exit 2 (not accepted as worktree)" ok || check "guard, foreign repo -> exit 2 (not accepted as worktree)" bad
out=$(run "$TMP"); rc=$?; [ $rc -eq 2 ] && check "guard, non-git cwd -> exit 2" ok || check "guard, non-git cwd -> exit 2" bad
out=$(run "$TMP/wt"); rc=$?; [ $rc -eq 0 ] && echo "$out" | grep -qF "GOV_WT=$wtreal mode=isolated" && check "guard, worktree -> isolated" ok || check "guard, worktree -> isolated" bad
mv "$ROOT/GOV" "$ROOT/GOV.gone"
out=$(run "$TMP/other"); rc=$?; [ $rc -eq 1 ] && check "missing canon -> exit 1" ok || check "missing canon -> exit 1" bad

[ "$FAILURES" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$FAILURES FAILED"; exit 1; }
