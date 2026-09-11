#!/usr/bin/env bash
# Regression for AR.293 (headless-вызов ИИ не завязан на одну программу, РП-574).
# Прямой повод: cold-review той же реализации (пир-сессия с Codex,
# 2026-09-11-18-rule-ar-headless-independence) нашёл, что extractor.sh —
# взятый в первой инвентаризации как «уже соответствует правилу» образец —
# на самом деле имел тот же дефект, что чинили в setup-extractor-feeders.sh:
# гейт «claude CLI не найден» (exit 127) срабатывал ДО учёта AI_CLI, поэтому
# override оставался декоративным ровно в сценарии «claude физически
# отсутствует» — том самом, ради которого правило и заводили (сообщение
# update.sh «Экстрактор: claude CLI не установлен — расписание не заводим»).
#
# Usage: bash scripts/tests/ar293-ai-cli-override-smoke.sh   (exit 0 = all green, 1 = failed)
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
FAILED=0

fail() {
  echo "FAIL: $*" >&2
  FAILED=1
}

# Порядок: AI_CLI должен быть объявлен РАНЬШЕ строки, которая жёстко
# завершает скрипт при недоступности CLI — иначе override не может повлиять
# на решение гейта (найденный этой сессией класс регресса).
check_gate_order() {
  local file="$1" ai_cli_pattern="$2" gate_pattern="$3"
  local ai_cli_line gate_line
  [ -f "$file" ] || { fail "$file: файл не найден"; return; }
  ai_cli_line=$(grep -nF "$ai_cli_pattern" "$file" | head -1 | cut -d: -f1)
  gate_line=$(grep -nF "$gate_pattern" "$file" | head -1 | cut -d: -f1)
  [ -n "${ai_cli_line:-}" ] || { fail "$file: объявление AI_CLI ('$ai_cli_pattern') не найдено"; return; }
  [ -n "${gate_line:-}" ] || { fail "$file: гейт ('$gate_pattern') не найден"; return; }
  if [ "$ai_cli_line" -ge "$gate_line" ]; then
    fail "$file: AI_CLI объявлен на строке $ai_cli_line, а гейт — на строке $gate_line. Гейт проверяется раньше override — регресс класса «декоративный AI_CLI» (см. РП-574)."
  fi
}

check_gate_order "$ROOT/roles/extractor/scripts/extractor.sh" \
  'AI_CLI="${AI_CLI:-$CLAUDE_PATH}"' \
  'ERROR: $AI_CLI CLI не найден'

check_gate_order "$ROOT/roles/strategist/scripts/strategist.sh" \
  'AI_CLI="${AI_CLI:-$CLAUDE_PATH}"' \
  'ERROR: $AI_CLI CLI не найден'

check_gate_order "$ROOT/scripts/setup-extractor-feeders.sh" \
  'AI_CLI="${AI_CLI:-claude}"' \
  'command -v "$AI_CLI" >/dev/null 2>&1'

# strategist.sh: точка подмены Claude-специфичных флагов (--allowedTools и
# др.) должна остаться overridable, не захардкожена обратно в вызов.
if ! grep -qF 'AI_CLI_EXTRA_FLAGS' "$ROOT/roles/strategist/scripts/strategist.sh"; then
  fail "roles/strategist/scripts/strategist.sh: точка подмены AI_CLI_EXTRA_FLAGS пропала — Claude-специфичные флаги (--allowedTools) снова захардкожены"
fi

if [ "$FAILED" -eq 0 ]; then
  echo "PASS: test_ar293_ai_cli_override.sh (3 гейт-порядка, 1 точка-подмены)"
  exit 0
fi
exit 1
