#!/usr/bin/env bash
# Regression for issue #1555: the nightly week-review step 8c carried per-line limits
# ("MEMORY.md ≤ 100", "справочники ≤ 100") and the scheduler run cut MEMORY.md, deleting the
# only pointers to existing memory files. Policy (CLAUDE.md §4, issue #736): only
# distinctions.md is limited by lines; the rest is a context budget. The step must not delete a
# pointer to an existing file.
set -uo pipefail
ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)}"
PROMPT="$ROOT/roles/strategist/prompts/week-review.md"
PASSES=0
FAILS=0
ok()  { echo "  ✅ PASS: $*"; PASSES=$((PASSES + 1)); }
bad() { echo "  ❌ FAIL: $*" >&2; FAILS=$((FAILS + 1)); }

step=$(awk '/^#### 8c\./ {f=1; print; next} f && /^#{2,4} / {exit} f {print}' "$PROMPT")
if [ -n "$step" ]; then ok "step 8c found"; else bad "step 8c not found in $PROMPT"; fi

if grep -Eq '≤ *[0-9]+' <<<"$step"; then
  bad "step 8c still has a per-line limit: $(grep -E '≤ *[0-9]+' <<<"$step" | head -1)"
else
  ok "step 8c has no per-line limit"
fi
if grep -q 'Указатель на существующий файл не удалять' <<<"$step"; then ok "pointer to an existing file is protected"
else bad "no rule protecting pointers to existing files"; fi
if grep -q 'verify-context-budget.sh' <<<"$step"; then ok "budget is checked by verify-context-budget.sh"
else bad "budget check missing"; fi
if grep -Eq 'MEMORY\.md[^|]*\|[^|]*\| *≤ *100' "$ROOT/docs/LEARNING-PATH.md"; then
  bad "LEARNING-PATH.md still states MEMORY.md ≤100"
else
  ok "LEARNING-PATH.md has no MEMORY.md line limit"
fi

echo
echo "issue #1555: $PASSES passed, $FAILS failed"
[ "$FAILS" -eq 0 ]
