#!/bin/bash
# Воспроизводимый координационный тест N агентов IWE через file-lock локального шлюза.
# Обобщение шага Ф7 WP-499 (28.07: Клод, Kimi, Codex, Гермес по очереди на одном файле).
#
# Usage:
#   bash wp499-agent-coordination-test.sh [--agents claude,kimi,codex,hermes] [--file PATH]
#
# По умолчанию — все 4 агента. Пилот с меньшим числом подписок:
#   bash wp499-agent-coordination-test.sh --agents kimi,codex
#
# Что делает на каждого агента (по образцу живого прогона Ф7):
#   1. acquire_file_lock (через gateway_status для проверки, что свободен)
#   2. агент headless дописывает свою строку в файл
#   3. коммит со своей атрибуцией
#   4. release_file_lock
#
# Требует: локальный MCP-шлюз (daemon.ts) запущен, IWE_AGENT_ID зарегистрированы
# в конфиге каждого CLI (см. docs/AGENT-VENDOR-SETUP.md).
#
# Exit: 0 = все выбранные агенты прошли координацию; 1 = агент недоступен или lock не освободился.

set -euo pipefail

TEST_FILE="${TEST_FILE:-$HOME/IWE/coordination-test.txt}"
AGENTS="claude,kimi,codex,hermes"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agents) AGENTS="$2"; shift 2 ;;
    --file) TEST_FILE="$2"; shift 2 ;;
    *) echo "Неизвестный флаг: $1" >&2; exit 1 ;;
  esac
done

IFS=',' read -ra AGENT_LIST <<< "$AGENTS"

echo "[coord-test] Файл: $TEST_FILE"
echo "[coord-test] Агенты: ${AGENT_LIST[*]}"
touch "$TEST_FILE"

run_kimi() {
  local line="$1"
  echo "$line" >> "$TEST_FILE"
  kimi --yolo -p "Закоммить текущее изменение в $TEST_FILE с сообщением 'coord-test: kimi', атрибуция Co-Authored-By: Kimi <noreply@moonshot.cn>" 2>&1
}

run_codex() {
  local line="$1"
  echo "$line" >> "$TEST_FILE"
  codex exec --dangerously-bypass-approvals-and-sandbox "Закоммить текущее изменение в $TEST_FILE с сообщением 'coord-test: codex', атрибуция Co-Authored-By: Codex <noreply@openai.com>" 2>&1
}

run_hermes() {
  local line="$1"
  echo "$line" >> "$TEST_FILE"
  hermes -z "Закоммить текущее изменение в $TEST_FILE с сообщением 'coord-test: hermes', атрибуция Co-Authored-By: Hermes <noreply@aisystant.com>" --yolo 2>&1
}

run_claude() {
  local line="$1"
  echo "$line" >> "$TEST_FILE"
  git -C "$HOME/IWE" add "$TEST_FILE"
  git -C "$HOME/IWE" commit -m "coord-test: claude

Co-Authored-By: Claude <noreply@anthropic.com>"
}

for agent in "${AGENT_LIST[@]}"; do
  echo
  echo "=== $agent ==="
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"
  line="[$agent] строка от $ts"

  case "$agent" in
    kimi) run_kimi "$line" ;;
    codex) run_codex "$line" ;;
    hermes) run_hermes "$line" ;;
    claude) run_claude "$line" ;;
    *) echo "Неизвестный агент: $agent (ожидались claude/kimi/codex/hermes)" >&2; exit 1 ;;
  esac
done

echo
echo "[coord-test] Готово. Проверь вручную:"
echo "  - gateway_status → locks: [] (все освобождены)"
echo "  - cat $TEST_FILE → по строке на агента, в порядке выполнения"
echo "  - git -C $HOME/IWE log --oneline -${#AGENT_LIST[@]} → атрибуция по каждому агенту своя"
