#!/usr/bin/env bash
# test_issue_544_staged_precommit.sh — regression for issue #544.
#
# The PreToolUse artifact validator reads the index BEFORE the command runs,
# so a combined `git add && git commit` silently bypassed all three artifact
# validators. Fix: a real git pre-commit hook (seed/strategy/.githooks/)
# running scripts/validate-staged-artifacts.sh, which reads staged blobs
# (`git show :path`), not the worktree. This test drives real git commits:
#   1. слитная форма с невалидным WeekPlan обязана блокироваться;
#   2. staged-семантика «за»: валидный staged + сломанное рабочее дерево →
#      коммит проходит (проверяется то, что попадёт в коммит);
#   3. staged-семантика «против»: невалидный staged + починенное рабочее
#      дерево без повторного add → блок;
#   4. валидная слитная форма проходит.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail=0
ok()   { echo "PASS: $1"; }
bad()  { echo "FAIL: $1"; fail=$((fail + 1)); }

# --- Каркас: workspace/FMT-exocortex-template/scripts + governance-репо ---
WS="$TMP/ws"
mkdir -p "$WS/FMT-exocortex-template/scripts"
cp "$ROOT/scripts/validate-staged-artifacts.sh" "$WS/FMT-exocortex-template/scripts/"
GOV="$WS/${GOVERNANCE_REPO:-DS-strategy}"
mkdir -p "$GOV/.githooks" "$GOV/current"
cp "$ROOT/seed/strategy/.githooks/pre-commit" "$GOV/.githooks/pre-commit"
chmod +x "$GOV/.githooks/pre-commit"
git -C "$GOV" init -q
git -C "$GOV" config user.email test@test && git -C "$GOV" config user.name test
git -C "$GOV" config core.hooksPath .githooks
# Герметичность: хук сначала смотрит $IWE_SCRIPTS — без явного значения тест
# исполнял бы валидатор боевой машины, а не копию фикстуры. То же для
# IWE_WORKSPACE/IWE_ROOT: от них валидатор ищет memory/day-rhythm-config.yaml.
export IWE_SCRIPTS="$WS/FMT-exocortex-template/scripts"
export IWE_WORKSPACE="$WS"
export IWE_ROOT="$WS"
echo "init" > "$GOV/README.md"
git -C "$GOV" add README.md && git -C "$GOV" commit -qm init

valid_weekplan() { # <path>
    { echo "# WeekPlan W36"; echo '## План'; echo '<summary>x</summary>'; echo '## Лог';
      for i in $(seq 80); do echo "строка $i"; done; } > "$1"
}
invalid_weekplan() { # <path> — >80 строк без заголовков
    { echo "# WeekPlan W36"; for i in $(seq 85); do echo "строка $i"; done; } > "$1"
}
valid_dayplan() { # <path>
    cat > "$1" <<'EOF'
# DayPlan 2026-08-30
## План на сегодня
| Время | РП |
|-------|----|
| 10:00 | WP-544 |
## Календарь
| Время | Событие |
|-------|---------|
| 11:00 | Встреча |
## IWE за ночь
всё зелёное
## Разбор заметок
нет
## Итоги вчера
сделано
Мультипликатор: ~1.0x
Бюджет: ~5ч РП / ~2ч физ
Carry-over: нет
EOF
}

# --- 1. Слитная форма с невалидным WeekPlan (точное воспроизведение issue) ---
invalid_weekplan "$GOV/current/WeekPlan W36.md"
if (cd "$GOV" && git add "current/WeekPlan W36.md" && git commit -qm "combined") >"$TMP/c1.err" 2>&1; then
    bad "слитная форма с невалидным WeekPlan заблокирована"
else
    ok "слитная форма с невалидным WeekPlan заблокирована"
fi
grep -q 'PROTOCOL ARTIFACT VALIDATION FAILED' "$TMP/c1.err" \
    && ok "блок с человекочитаемым разбором" \
    || bad "блок с человекочитаемым разбором"
git -C "$GOV" reset -q
rm -f "$GOV/current/WeekPlan W36.md"

# --- 2. Staged-семантика «за»: валидный staged, сломанное рабочее дерево ---
valid_dayplan "$GOV/current/DayPlan 2026-08-30.md"
git -C "$GOV" add "current/DayPlan 2026-08-30.md"
echo "мусор без структуры" > "$GOV/current/DayPlan 2026-08-30.md"  # worktree сломан ПОСЛЕ add
if (cd "$GOV" && git commit -qm "staged-valid") >"$TMP/c2.err" 2>&1; then
    ok "валидный staged + сломанное рабочее дерево → коммит проходит"
else
    bad "валидный staged + сломанное рабочее дерево → коммит проходит"
    cat "$TMP/c2.err"
fi

# --- 3. Staged-семантика «против»: невалидный staged, починенное дерево ---
git -C "$GOV" reset -q
rm -f "$GOV/current/DayPlan 2026-08-30.md"
invalid_weekplan "$GOV/current/WeekPlan W36.md"
git -C "$GOV" add "current/WeekPlan W36.md"          # staged = невалидный
valid_weekplan "$GOV/current/WeekPlan W36.md"        # worktree починен, add НЕ повторялся
echo x >> "$GOV/README.md"
if (cd "$GOV" && git add README.md && git commit -qm "combined-other") >"$TMP/c3.err" 2>&1; then
    bad "невалидный staged + починенное дерево без re-add → блок"
else
    ok "невалидный staged + починенное дерево без re-add → блок"
fi
git -C "$GOV" reset -q
rm -f "$GOV/current/WeekPlan W36.md"
git -C "$GOV" checkout -q README.md 2>/dev/null || true

# --- 4. Валидная слитная форма проходит ---
valid_weekplan "$GOV/current/WeekPlan W36.md"
if (cd "$GOV" && git add "current/WeekPlan W36.md" && git commit -qm "combined-valid") >"$TMP/c4.err" 2>&1; then
    ok "валидная слитная форма проходит"
else
    bad "валидная слитная форма проходит"
    cat "$TMP/c4.err"
fi

# --- 5. Контракт поставки: валидатор подключён в seed-хуке и не требует
# PreToolUse-контекста ---
grep -q 'validate-staged-artifacts.sh' "$ROOT/seed/strategy/.githooks/pre-commit" \
    && ok "seed pre-commit вызывает валидатор" \
    || bad "seed pre-commit вызывает валидатор"
if grep -qF 'git show ":$p"' "$ROOT/scripts/validate-staged-artifacts.sh"; then
    ok "валидатор читает staged blob (git show :path), не рабочее дерево"
else
    bad "валидатор читает staged blob (git show :path), не рабочее дерево"
fi

# --- 6. Два WeekPlan одним коммитом: невалидный не прячется за валидным
# (ревью: sort|tail -1 проверял бы только лексикографически последний) ---
valid_weekplan "$GOV/current/WeekPlan W36.md"
echo "допустимая правка W36, чтобы файл реально попал в индекс" >> "$GOV/current/WeekPlan W36.md"
invalid_weekplan "$GOV/current/WeekPlan W99.md"
# Санити: оба файла обязаны быть staged, иначе тест ничего не доказывает.
STAGED_NOW=$(git -C "$GOV" add "current/WeekPlan W36.md" "current/WeekPlan W99.md" && git -C "$GOV" diff --cached --name-only)
if [ "$(echo "$STAGED_NOW" | grep -c 'WeekPlan')" != "2" ]; then
    bad "кейс 6 негерметичен: staged не оба WeekPlan"
fi
if (cd "$GOV" && git commit -qm "two-weekplans") >"$TMP/c6.err" 2>&1; then
    bad "два WeekPlan одним коммитом: невалидный заблокирован"
else
    ok "два WeekPlan одним коммитом: невалидный заблокирован"
fi
grep -qF 'WeekPlan W99' "$TMP/c6.err" \
    && ok "разбор называет именно невалидный файл" \
    || bad "разбор называет именно невалидный файл"
git -C "$GOV" reset -q
rm -f "$GOV/current/WeekPlan W99.md"

# --- 7. Mandatory fail-closed: конфиг существует, но не читается ---
mkdir -p "$WS/scripts/lib" "$WS/memory"
cp "$ROOT/scripts/lib/find-python3.sh" "$WS/scripts/lib/"
printf 'mandatory_daily_wps: [сломано\n  без закрывающей скобки\n' > "$WS/memory/day-rhythm-config.yaml"
valid_dayplan "$GOV/current/DayPlan 2026-08-31.md"
if (cd "$GOV" && git add "current/DayPlan 2026-08-31.md" && git commit -qm "broken-config") >"$TMP/c7.err" 2>&1; then
    bad "битый day-rhythm-config.yaml блокирует коммит DayPlan (fail-closed)"
else
    ok "битый day-rhythm-config.yaml блокирует коммит DayPlan (fail-closed)"
fi
grep -qF 'day-rhythm-config.yaml существует, но не читается' "$TMP/c7.err" \
    && ok "fail-closed называет причину (конфиг не читается)" \
    || bad "fail-closed называет причину (конфиг не читается)"
git -C "$GOV" reset -q
rm -f "$GOV/current/DayPlan 2026-08-31.md" "$WS/memory/day-rhythm-config.yaml"

# --- 8. Резолюция пути: template-fallback без IWE_SCRIPTS (основной путь
# обычного git commit вне сессии агента) ---
unset IWE_SCRIPTS
invalid_weekplan "$GOV/current/WeekPlan W37.md"
if (cd "$GOV" && git add "current/WeekPlan W37.md" && git commit -qm "fallback-path") >"$TMP/c8.err" 2>&1; then
    bad "без IWE_SCRIPTS невалидный WeekPlan блокируется (template-fallback)"
else
    ok "без IWE_SCRIPTS невалидный WeekPlan блокируется (template-fallback)"
fi
git -C "$GOV" reset -q
rm -f "$GOV/current/WeekPlan W37.md"

# --- 9. Резолюция пути: деградированный repo-local режим с WARN ---
mv "$WS/FMT-exocortex-template/scripts/validate-staged-artifacts.sh" "$WS/FMT-exocortex-template/scripts/validate-staged-artifacts.sh.away"
mkdir -p "$GOV/scripts"
cp "$WS/FMT-exocortex-template/scripts/validate-staged-artifacts.sh.away" "$GOV/scripts/validate-staged-artifacts.sh"
invalid_weekplan "$GOV/current/WeekPlan W38.md"
if (cd "$GOV" && git add "current/WeekPlan W38.md" && git commit -qm "degraded") >"$TMP/c9.err" 2>&1; then
    bad "repo-local fallback: невалидный WeekPlan блокируется"
else
    ok "repo-local fallback: невалидный WeekPlan блокируется"
fi
grep -qF 'деградированный режим' "$TMP/c9.err" \
    && ok "repo-local fallback помечен WARNом о деградации" \
    || bad "repo-local fallback помечен WARNом о деградации"
mv "$WS/FMT-exocortex-template/scripts/validate-staged-artifacts.sh.away" "$WS/FMT-exocortex-template/scripts/validate-staged-artifacts.sh"
rm -rf "$GOV/scripts"
git -C "$GOV" reset -q
rm -f "$GOV/current/WeekPlan W38.md"

# --- 10. Пустой YAML-конфиг — fail-closed (корень не map) ---
: > "$WS/memory/day-rhythm-config.yaml"
valid_dayplan "$GOV/current/DayPlan 2026-09-01.md"
if (cd "$GOV" && git add "current/DayPlan 2026-09-01.md" && git commit -qm "empty-config") >"$TMP/c10.err" 2>&1; then
    bad "пустой day-rhythm-config.yaml блокирует коммит DayPlan (fail-closed)"
else
    ok "пустой day-rhythm-config.yaml блокирует коммит DayPlan (fail-closed)"
fi
git -C "$GOV" reset -q
rm -f "$GOV/current/DayPlan 2026-09-01.md" "$WS/memory/day-rhythm-config.yaml"

# --- 11. Интерпретатор падает нестандартным кодом (126) — fail-closed ---
mkdir -p "$WS/memory"
printf 'mandatory_daily_wps: []
' > "$WS/memory/day-rhythm-config.yaml"
FAKEPY="$WS/fake-python3"
printf '#!/bin/sh\nexit 126\n' > "$FAKEPY"; chmod +x "$FAKEPY"
# Подменяем резолвер: он должен вернуть путь к падающему интерпретатору.
mv "$WS/scripts/lib/find-python3.sh" "$WS/scripts/lib/find-python3.sh.away"
printf '#!/bin/sh\necho "%s"\n' "$FAKEPY" > "$WS/scripts/lib/find-python3.sh"; chmod +x "$WS/scripts/lib/find-python3.sh"
valid_dayplan "$GOV/current/DayPlan 2026-09-02.md"
if (cd "$GOV" && git add "current/DayPlan 2026-09-02.md" && git commit -qm "weird-rc") >"$TMP/c11.err" 2>&1; then
    bad "нестандартный rc интерпретатора (126) блокирует коммит (fail-closed)"
else
    ok "нестандартный rc интерпретатора (126) блокирует коммит (fail-closed)"
fi
mv "$WS/scripts/lib/find-python3.sh.away" "$WS/scripts/lib/find-python3.sh"
git -C "$GOV" reset -q
rm -f "$GOV/current/DayPlan 2026-09-02.md" "$WS/memory/day-rhythm-config.yaml" "$FAKEPY"

if [ "$fail" -gt 0 ]; then
    echo "FAIL: $fail проверок упало"
    exit 1
fi
echo "PASS: real pre-commit validates staged artifacts regardless of add/commit form (issue #544)"
