#!/usr/bin/env bash
# test_issue_961_note_review_pilot_only.sh - regression for issue #961: Note-Review against the pilot
# decision of 2026-07-29/30. Note-Review only classifies and PROPOSES: it never strips bold, never
# archives or deletes a note on its own, and the scheduler never starts it. A processed note is marked
# "**Title** ✅предложено", stays bold and visible until the pilot closes it (a command, or by
# striking it through).
#
# Layer (no network, no real HOME):
#   A. text contract: roles/strategist/prompts/note-review.md, day-plan.md, the seed box legend,
#      and the cleanup script's safety net (a proposed note is never swept up).
# The scheduler, the Day Open scanner, the Telegram text and the scheduler report (layers B-E) arrive
# with the behaviour change that makes them true.

# SC2016: the single-quoted strings are literal prompt fragments (with backticks) and stub-script bodies
# that must stay unexpanded.
# shellcheck disable=SC2016
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROMPT="$ROOT/roles/strategist/prompts/note-review.md"
DAYPLAN_PROMPT="$ROOT/roles/strategist/prompts/day-plan.md"
SEED_LEGEND="$ROOT/seed/strategy/inbox/fleeting-notes.md"
CLEANUP_PY="$ROOT/roles/strategist/scripts/cleanup-processed-notes.py"

SB="$(cd -P "$(mktemp -d "${TMPDIR:-/tmp}/iwe-issue-961.XXXXXX")" && pwd -P)"
trap '[ "${KEEP:-0}" = "1" ] || rm -rf "$SB"' EXIT INT TERM
mkdir -p "$SB/tmp" "$SB/shim"

FAIL_COUNT=0
PASS_COUNT=0
fail() { echo "  ❌ FAIL: $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }
pass() { echo "  ✅ PASS: $*"; PASS_COUNT=$((PASS_COUNT + 1)); }
check() {  # <description> <expected> <actual>
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}
check_at_least() {  # <description> <minimum> <actual>
    if [ "$3" -ge "$2" ] 2>/dev/null; then pass "$1"; else fail "$1 (expected at least $2, got '$3')"; fi
}
count_fixed() {  # <fixed string> <file> -> number of matching lines, 0 for a missing file
    if [ -f "$2" ]; then grep -cF -- "$1" "$2" || true; else echo 0; fi
}

# ==== LAYER A: text contract ====
echo "== A1: the prompt marks processed notes instead of stripping bold =="
for category in "НЭП" "Задача" "Гипотеза" "Знание доменное" "Знание реализационное" "Черновик" "Личные данные"; do
    check "step 4: $category becomes '**Заголовок** ✅предложено'" "1" \
        "$(count_fixed "| $category | \`**Заголовок**\` | \`**Заголовок** ✅предложено\` |" "$PROMPT")"
done
check "step 4: noise becomes '**Заголовок** ✅предложено (шум)', it is not struck through by the agent" "1" \
    "$(count_fixed '| Шум | `**Заголовок**` | `**Заголовок** ✅предложено (шум)` |' "$PROMPT")"
check "no instruction to strip bold remains" "0" "$(count_fixed '(снять bold)' "$PROMPT")"
check "no instruction to strike noise through automatically remains" "0" "$(count_fixed '→ зачеркнуть ~~текст~~' "$PROMPT")"
check "the legend describes the proposed state" "1" "$(count_fixed '| `**Заголовок** ✅предложено` | Классифицирована, предложение записано — ждёт решения пилота |' "$PROMPT")"
check "new notes exclude the already proposed ones" "1" "$(count_fixed '- Заметки с `✅предложено` — уже обработаны, не переклассифицировать, оставить как есть' "$PROMPT")"

echo "== A2: the prompt no longer archives or deletes on its own =="
check "the old mandatory 'archive processed notes' step is gone" "0" "$(count_fixed '#### 10. Архивировать обработанные заметки' "$PROMPT")"
check "the old 'delete from fleeting-notes.md' step is gone" "0" "$(count_fixed 'Шаг 10b. Удалить из fleeting-notes.md' "$PROMPT")"
check "the old 'Step 10 is mandatory' block is gone" "0" "$(count_fixed 'Шаг 10 ОБЯЗАТЕЛЕН' "$PROMPT")"
check "step 10 never edits the box beyond the proposed mark" "1" "$(count_fixed '`fleeting-notes.md` НЕ редактируется этим шагом, кроме простановки `✅предложено` в шаге 4 выше.' "$PROMPT")"
check_at_least "every archive record format carries the pilot decision (step 10 and the manual cleanup)" 2 "$(count_fixed '**Разбор:** YYYY-MM-DD — **Решение пилота:**' "$PROMPT")"
check "principle: a note leaves the box only with the pilot decision recorded" "1" "$(count_fixed '**Каждый разбор — запись решения:**' "$PROMPT")"
check "manual cleanup is the only way to remove a note" "1" "$(count_fixed 'Это единственный путь физического удаления из `fleeting-notes.md`' "$PROMPT")"

echo "== A3: pilot-only contract: no automatic and no headless run =="
check "the precondition says automatic runs are off" "1" "$(count_fixed 'Автоматические запуски отключены' "$PROMPT")"
check "the old 'runs every evening automatically' sentence is gone" "0" "$(count_fixed 'Процесс запускается вечером (~23:00) автоматически' "$PROMPT")"
check "headless mode is forbidden" "1" "$(count_fixed 'Headless-режим запрещён' "$PROMPT")"
check "the old 'headless: do not wait for approval' block is gone" "0" "$(count_fixed '**Headless-режим:** НЕ ждать одобрения' "$PROMPT")"

echo "== A4: the box legend and the Day Plan prompt follow the decision =="
check "seed legend: the proposed mark is described" "1" "$([ "$(count_fixed '✅предложено' "$SEED_LEGEND")" -ge 1 ] && echo 1 || echo 0)"
check "seed legend: no 'reviewed every day at 23:00' promise" "0" "$(count_fixed 'ежедневно, 23:00' "$SEED_LEGEND")"
check "seed legend: the box is reviewed by the pilot only" "1" "$(count_fixed 'Разбирает только пилот' "$SEED_LEGEND")"
check "day-plan prompt: no claim that Note-Review marks and archives notes at 23:00" "0" "$(count_fixed 'это делает Note-Review в 23:00' "$DAYPLAN_PROMPT")"

echo "== A5: the cleanup safety net never sweeps up a proposed note =="
PY3="$(bash "$ROOT/scripts/lib/find-python3.sh" --stdlib-only)" || { echo "no python3 for the cleanup case" >&2; exit 2; }
mkdir -p "$SB/clean/inbox" "$SB/clean/archive/notes" "$SB/clean-home"
cat > "$SB/clean/inbox/fleeting-notes.md" <<'EOF'
---
title: Fleeting
---

# Fleeting Notes

> legend

---

**Note A** ✅предложено

---

**Note B noise** ✅предложено (шум)

---

**Note C new**

---

~~Note D closed by the pilot~~

---
EOF
CLEAN_OUT="$(env HOME="$SB/clean-home" IWE_CLEANUP_REPO_DIR="$SB/clean" "$PY3" "$CLEANUP_PY" 2>&1)"
check "cleanup run: 1 archived (the one the pilot struck through), 3 kept" "Cleaned: 1 archived, 3 kept" "$CLEAN_OUT"
check "cleanup: the proposed notes and the new note stay in the box" "3" "$(grep -c '^\*\*Note' "$SB/clean/inbox/fleeting-notes.md")"
check "cleanup: the struck-through note went to the archive" "1" "$(count_fixed 'Note D closed by the pilot' "$SB/clean/archive/notes/Notes-Archive.md")"

# ==== END LAYERS ====

echo
echo "Passed: $PASS_COUNT, failed: $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
