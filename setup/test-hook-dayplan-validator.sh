#!/bin/bash
# test-hook-dayplan-validator.sh — регрессионный тест для
# .claude/hooks/protocol-artifact-validate.sh
#
# Назначение: ловить регрессию триггера. Хук — PreToolUse на Bash, и он читает
# `git diff --cached` ДО того, как команда выполнится. Если `git add` находится
# внутри той же команды, что и `git commit` (`git add X && git commit -m ...`),
# то на момент проверки индекс ещё пуст — раньше хук выходил с `{}` и коммит
# проходил без валидации. Тест фиксирует, что обе формы коммита валидируются
# и что при этом не появилось ложных срабатываний по тексту команды (WP-273).
#
# Usage:
#   bash setup/test-hook-dayplan-validator.sh
#
# Exit:
#   0 — все проверки прошли
#   1 — есть провалы (или не найден хук / jq)

set -u

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
HOOK="$REPO_ROOT/.claude/hooks/protocol-artifact-validate.sh"
[ -f "$HOOK" ] || { echo "SKIP: хук не найден: $HOOK"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq не установлен"; exit 0; }

FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE"' EXIT
mkdir -p "$FIXTURE/GOV/current"
git -C "$FIXTURE/GOV" init -q

# DayPlan, заведомо не проходящий check 4 (нет слова «mandatory»),
# но валидный по всем остальным проверкам.
cat > "$FIXTURE/GOV/current/DayPlan 2026-07-24.md" <<'EOF'
# Day Plan
<summary><b>План на сегодня</b></summary>
| # | РП | h |
|---|-----|---|
| 1 | Пример | 5 |
**Бюджет дня:** ~7.5h РП всего / ~7.5h физ / мультипликатор ~1.0x
<summary><b>Календарь</b></summary>
нет событий
строка два
строка три
<summary><b>IWE за ночь</b></summary>
ок
<summary><b>Разбор заметок</b></summary>
пусто
<summary><b>Итоги вчера</b></summary>
carry-over: нет
EOF

export IWE_WORKSPACE="$FIXTURE" IWE_GOVERNANCE_REPO="GOV"
FAILED=0

run_case() {
  local name="$1" cmd="$2" expect="$3" out verdict
  out=$(jq -n --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}' | bash "$HOOK")
  case "$out" in
    *'"decision": "block"'*) verdict="BLOCK" ;;
    '{}')                    verdict="PASS-THROUGH" ;;
    *additionalContext*)     verdict="VALIDATED-OK" ;;
    *)                       verdict="UNKNOWN" ;;
  esac
  if [ "$verdict" = "$expect" ]; then
    echo "  ok   $name -> $verdict"
  else
    echo "  FAIL $name -> $verdict (ожидалось $expect)"
    echo "       вывод: $out"
    FAILED=$((FAILED + 1))
  fi
}

echo "== Невалидный DayPlan: связка add+commit обязана блокироваться =="
run_case "add+commit одной командой, путь в кавычках" \
  'cd ~/x && git add "current/DayPlan 2026-07-24.md" && git commit -m "test"' BLOCK
run_case "add+commit, абсолютный путь" \
  "git add '$FIXTURE/GOV/current/DayPlan 2026-07-24.md' && git commit -m x" BLOCK
run_case "git add . && commit (массовый стейджинг)" \
  'git add . && git commit -m x' BLOCK
run_case "add+commit через точку с запятой" \
  'git add "current/DayPlan 2026-07-24.md"; git commit -m x' BLOCK

echo "== Отсутствие ложных срабатываний (принцип WP-273) =="
run_case "commit без add, индекс пуст" \
  'git commit -m "правил current/DayPlan 2026-07-24.md"' PASS-THROUGH
run_case "сообщение упоминает DayPlan, стейджится другой файл" \
  'git add README.md && git commit -m "см. current/DayPlan 2026-07-24.md"' PASS-THROUGH
run_case "git add без commit" \
  'git add "current/DayPlan 2026-07-24.md"' PASS-THROUGH
run_case "посторонняя команда" 'ls -la' PASS-THROUGH

echo "== Валидный DayPlan проходит =="
printf '\n**Mandatory check:** обязательных РП нет.\n' >> "$FIXTURE/GOV/current/DayPlan 2026-07-24.md"
run_case "add+commit одной командой, валидный DayPlan" \
  'git add "current/DayPlan 2026-07-24.md" && git commit -m x' VALIDATED-OK

echo
if [ "$FAILED" -eq 0 ]; then
  echo "OK: все 9 проверок прошли."
else
  echo "FAIL: провалено проверок: $FAILED"
  exit 1
fi
