#!/usr/bin/env bash
set -euo pipefail

# issue #458: pending-phases-sweep.sh must recognize three real-world phase
# markup formats (table with status, checklist, ### heading) and must not
# emit false UNSUPPORTED errors on real repo content — that regression was
# found live: 624 false positives against 17 genuine pending phases before
# this test existed. Fixtures below reproduce the exact patterns that
# broke: budget/description suffixes after the phase number, level-2
# headings, letter suffixes on phase numbers, prose lines starting with a
# bolded "ФN", checklist-style trigger lists without checkboxes, and
# Russian morphology on closing words ("закрыта" vs "закрыто").
#
# issue #541 (regression of #458, found by external red-team review
# 2026-08-26): a "### ФN" section whose heading already says "✅ DONE", or
# that has an earlier checked "[x]" item, permanently latched as "closed"
# and silently swallowed any later forgotten "- [ ]" in the same section.
# Fixture 6 reproduces this against real cards found in the wild
# (WP-529/WP-545).

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
SWEEP="$ROOT/scripts/pending-phases-sweep.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

INBOX="$TMP/repo/inbox"

run_sweep() {
    bash "$SWEEP" --repo "$TMP/repo" > "$TMP/stdout.txt" 2>"$TMP/stderr.txt"
    echo "$?"
}

# --- Fixture 1: table format with explicit pending marker (pre-existing
#     supported format, must keep working unchanged). ---
mkdir -p "$INBOX/WP-100"
cat >"$INBOX/WP-100/WP-100.md" <<'EOF'
---
status: in_progress
---
# WP-100

## Фазы

| Ф1 | Первая фаза | ✅ done |
| Ф2 | Вторая фаза | ⏳ pending |
EOF

status=$(run_sweep)
[ "$status" = "0" ] || { echo "table format: expected exit 0, got $status"; cat "$TMP/stderr.txt" >&2; exit 1; }
grep -Fq 'Ф2 — Вторая фаза' "$TMP/stdout.txt"
! grep -Fq 'Ф1 —' "$TMP/stdout.txt" || { echo 'closed Ф1 wrongly reported as pending'; exit 1; }

# --- Fixture 2: checklist format. ---
rm -rf "$INBOX/WP-100"
mkdir -p "$INBOX/WP-101"
cat >"$INBOX/WP-101/WP-101.md" <<'EOF'
---
status: in_progress
---
# WP-101

## Фазы

- [x] Ф1: Готово
- [ ] Ф2: Не готово
EOF

status=$(run_sweep)
[ "$status" = "0" ] || { echo "checklist format: expected exit 0, got $status"; cat "$TMP/stderr.txt" >&2; exit 1; }
grep -Fq 'Ф2 — Не готово' "$TMP/stdout.txt"

# --- Fixture 3: heading format, including real-world variations that broke
#     the earlier stricter version: level-2 heading, budget/status suffix
#     after the number, letter suffix on the phase number. ---
rm -rf "$INBOX/WP-101"
mkdir -p "$INBOX/WP-102"
cat >"$INBOX/WP-102/WP-102.md" <<'EOF'
---
status: in_progress
---
# WP-102

## Ф1 (~1.5h) — ✅ DONE (закрыта 01.08.2026)

Тело закрытой фазы.

### Ф2 (~2.5h)

- [ ] Незакрытый пункт

## Ф3b — буквенный суффикс номера

Статус: pending.

## Ф0. Точка как пунктуация, не десятичный разделитель

Статус: закрыт.
EOF

status=$(run_sweep)
[ "$status" = "0" ] || { echo "heading format: expected exit 0, got $status"; cat "$TMP/stderr.txt" >&2; exit 1; }
# Description comes from the section's own heading text, not from the body
# checkbox line that triggered the pending signal — a heading section can
# have multiple checkbox items, so the heading text is the only stable label.
grep -Fq 'Ф2 —' "$TMP/stdout.txt"
grep -Fq 'Ф3 — буквенный суффикс номера' "$TMP/stdout.txt"
! grep -Fq 'Ф0 —' "$TMP/stdout.txt" || { echo 'closed Ф0 (Русский "закрыт") wrongly reported as pending'; exit 1; }
! grep -Fq 'Ф1 —' "$TMP/stdout.txt" || { echo 'closed Ф1 (DONE marker) wrongly reported as pending'; exit 1; }

# --- Fixture 4: an UNSUPPORTED checklist marker (empty brackets "[]", the
#     only content that truly can't be interpreted) must still be flagged,
#     while any non-empty checkbox content ("[~]", emoji status markers) is
#     a real-world "not done" status and must be treated as pending, not
#     flagged — issue #458, found live: 24+ real "[~]" usages and single-
#     codepoint emoji markers across the repo were false UNSUPPORTED before
#     this widening. Prose that merely starts with "ФN" and a checkbox-less
#     trigger list must also be silently ignored (not flagged). Note: a
#     phase number itself can never be "invalid" once phase_candidate()
#     matches — it requires a digit right after "Ф", and that same digit is
#     always extractable as the phase number, so there is no code path
#     where a recognized phase-like token has an unrecognizable number. ---
rm -rf "$INBOX/WP-102"
mkdir -p "$INBOX/WP-103"
cat >"$INBOX/WP-103/WP-103.md" <<'EOF'
---
status: in_progress
---
# WP-103

## Фазы

- Ф7b Лаборатория: триггер «пилот явно просит калибровку весов»
- Ф8/Ф10/Ф11: триггер «потребитель запросил X»

**Ф5 закрыта полностью 12.08** (ретроспективная запись прозой, не фаза).

- [~] Ф6: частично сделано (реальный маркер статуса, не ошибка)
- [] Ф9: пустые скобки, нераспознаваемо
EOF

status=$(run_sweep)
[ "$status" = "2" ] || { echo "unsupported checklist marker: expected exit 2, got $status"; cat "$TMP/stdout.txt" "$TMP/stderr.txt" >&2; exit 1; }
grep -Fq 'некорректная checklist-фаза' "$TMP/stderr.txt"
grep -Fq 'Ф6 — частично сделано' "$TMP/stdout.txt"
! grep -Fq 'Ф7b' "$TMP/stderr.txt" || { echo 'checkbox-less trigger list line wrongly flagged as UNSUPPORTED'; exit 1; }
! grep -Fq 'Ф5 закрыта' "$TMP/stderr.txt" || { echo 'prose retrospective line wrongly flagged as UNSUPPORTED'; exit 1; }

# --- Fixture 5: Russian closing-word morphology (закрыта/закрыто/закрыт all
#     count as closed, not just the one exact form used originally). ---
rm -rf "$INBOX/WP-103"
mkdir -p "$INBOX/WP-104"
cat >"$INBOX/WP-104/WP-104.md" <<'EOF'
---
status: in_progress
---
# WP-104

## Ф1

**Статус:** закрыта.

## Ф2

**Статус:** закрыт.

## Ф3

**Статус:** pending.
EOF

status=$(run_sweep)
[ "$status" = "0" ] || { echo "morphology: expected exit 0, got $status"; cat "$TMP/stderr.txt" >&2; exit 1; }
grep -Fq 'Ф3 —' "$TMP/stdout.txt"
! grep -Fq 'Ф1 —' "$TMP/stdout.txt" || { echo '"закрыта" (feminine) not recognized as closed' >&2; exit 1; }
! grep -Fq 'Ф2 —' "$TMP/stdout.txt" || { echo '"закрыт" (masculine) not recognized as closed' >&2; exit 1; }

# --- Fixture 6: issue #541 (regression of #458) — a "### ФN" heading section
#     whose OWN title already claims "✅ DONE" (or that contains an earlier
#     already-checked "[x]" item) but still has a forgotten open checkbox
#     somewhere in its body must be reported pending. The earlier version
#     latched section_closed permanently on the first "done" signal found
#     anywhere in the section — heading text, prose, or a sibling checked
#     item — so any later "- [ ]" in the same section was silently
#     swallowed. Live examples this reproduces: WP-529 "### Ф2 — ... ✅
#     DONE" with an orphaned "- [ ] Acceptance-критерий" underneath, and
#     WP-545 "### Ф2" (no DONE marker at all) whose first checklist item is
#     "[x]" and second is "[ ]". Ф3 below is the negative control: a section
#     with only checked items and no open checkbox must stay silent. ---
rm -rf "$INBOX/WP-104"
mkdir -p "$INBOX/WP-105"
cat >"$INBOX/WP-105/WP-105.md" <<'EOF'
---
status: in_progress
---
# WP-105

## Ф1 — ✅ DONE (закрыта 01.08.2026)

- [x] Пункт 1 сделан
- [ ] Забытый пункт

## Ф2 — обычная секция без DONE в заголовке

- [x] Первый пункт сделан
- [ ] Второй пункт не сделан

## Ф3 — по-настоящему закрыта

- [x] Всё сделано
- [x] Реально всё
EOF

status=$(run_sweep)
[ "$status" = "0" ] || { echo "done-heading-with-orphan-checkbox: expected exit 0, got $status"; cat "$TMP/stderr.txt" >&2; exit 1; }
grep -Fq 'Ф1 —' "$TMP/stdout.txt" || { echo '"✅ DONE" heading with a forgotten open checkbox wrongly stayed silent (issue #541)'; exit 1; }
grep -Fq 'Ф2 —' "$TMP/stdout.txt" || { echo 'section with an earlier [x] item followed by a later [ ] item wrongly stayed silent (issue #541)'; exit 1; }
! grep -Fq 'Ф3 —' "$TMP/stdout.txt" || { echo 'fully-closed section (all [x], no open checkbox) wrongly reported as pending'; exit 1; }

# --- Fixture 7: known, deliberate trade-off (issue #541 cold-review). A
#     section can be genuinely fully closed (every real item is "[x]") and
#     still quote checkbox syntax as documentation prose ("Пример: `- [ ]
#     пункт`"). A line-based parser cannot tell that quote apart from a real
#     forgotten item without fenced-code-block awareness, so it is reported
#     pending too. This is intentional, not a bug to silently "fix" back
#     toward the #541 regression: a false positive here just costs the pilot
#     one glance at an already-done section; a false negative (the original
#     bug) silently hid real incomplete work from Week Close. This fixture
#     pins the current, accepted behavior so a future change doesn't
#     accidentally reintroduce the #541 false negative while "fixing" this
#     false positive. ---
rm -rf "$INBOX/WP-105"
mkdir -p "$INBOX/WP-106"
cat >"$INBOX/WP-106/WP-106.md" <<'EOF'
---
status: in_progress
---
# WP-106

## Ф1 — полностью закрыта, документирует формат чекбоксов

- [x] Пункт 1 сделан
- [x] Пункт 2 сделан

Пример синтаксиса чекбокса для документации:
- [ ] пример пункта, не реальная работа

Итог: секция закрыта 20.08.2026.
EOF

status=$(run_sweep)
[ "$status" = "0" ] || { echo "documentation-quoted-checkbox: expected exit 0, got $status"; cat "$TMP/stderr.txt" >&2; exit 1; }
grep -Fq 'Ф1 —' "$TMP/stdout.txt" || { echo 'known trade-off regressed: a quoted checkbox example no longer flags its section pending (see code comment above section_open_checkbox)'; exit 1; }

echo 'PASS: pending-phases-sweep.sh recognizes table/checklist/heading formats without false positives on real-world phrasing'
