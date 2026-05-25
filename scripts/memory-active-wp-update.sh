#!/usr/bin/env bash
# routing: helper  skill=day-close,week-close  called-by=haiku
# see DP.SC.159, DP.ROLE.059
# memory-active-wp-update.sh — обновление секции «Текущие РП» в MEMORY.md
# из результатов active-wp-sweep.sh.
# see WP-283 Ф8 (DS-strategy/inbox/WP-283-server-day-open-crossplatform.md)
#
# Использование:
#   bash memory-active-wp-update.sh [IWE_ROOT]
#
# Ищет маркеры <!-- ACTIVE-WP-START --> и <!-- ACTIVE-WP-END --> в MEMORY.md,
# заменяет содержимое между ними на свежий sweep-output.
# Идемпотентно: повторный запуск не меняет файл, если состояние не изменилось.
#
# Совместимость: bash 3.2+ (macOS), bash 4+ (Linux/NixOS)

set -uo pipefail

IWE="${1:-${IWE_ROOT:-$HOME/IWE}}"
GOV_REPO="${IWE_GOVERNANCE_REPO:-DS-strategy}"
MEMORY_FILE="$IWE/memory/MEMORY.md"
SWEEP_SCRIPT="$IWE/scripts/active-wp-sweep.sh"
INBOX_DIR="$IWE/$GOV_REPO/inbox"

START_MARKER="<!-- ACTIVE-WP-START -->"
END_MARKER="<!-- ACTIVE-WP-END -->"

# --- Проверки ---
if [[ ! -f "$MEMORY_FILE" ]]; then
  echo "ERROR: MEMORY.md не найден: $MEMORY_FILE" >&2
  exit 1
fi

if [[ ! -f "$SWEEP_SCRIPT" ]]; then
  echo "ERROR: active-wp-sweep.sh не найден: $SWEEP_SCRIPT" >&2
  exit 1
fi

if ! grep -qF "$START_MARKER" "$MEMORY_FILE"; then
  echo "INFO: маркер $START_MARKER не найден в MEMORY.md — пропускаю (добавь маркеры вручную)" >&2
  exit 0
fi

# --- Запустить sweep ---
SWEEP_OUT=$(bash "$SWEEP_SCRIPT" "$INBOX_DIR" "$IWE" 2>/dev/null) || true

if [[ -z "$SWEEP_OUT" ]]; then
  SWEEP_OUT="<!-- active-wp-sweep: нет активных РП или python3+yaml не найден -->"
fi

# --- Сформировать новый блок ---
TIMESTAMP=$(date +"%Y-%m-%d %H:%M" 2>/dev/null || echo "?")
NEW_BLOCK="${START_MARKER}
${SWEEP_OUT}
> _Обновлено: ${TIMESTAMP} (memory-active-wp-update.sh)_
${END_MARKER}"

# --- Проверка идемпотентности: сравнить текущий блок с новым ---
CURRENT_BLOCK=$(awk "/$START_MARKER/{found=1} found{print} /$END_MARKER/{found=0}" "$MEMORY_FILE" 2>/dev/null)

if [[ "$CURRENT_BLOCK" == *"${SWEEP_OUT}"* ]]; then
  echo "INFO: MEMORY.md уже актуален — изменений нет" >&2
  exit 0
fi

# --- Заменить блок через Python (безопасная многострочная замена) ---
# Передаём данные через env-vars с quoted heredoc <<'PYEOF' — bash НЕ раскрывает
# спецсимволы (`backticks`, $(...), \n, """) внутри NEW_BLOCK. Защита от
# heredoc-инъекции при странных WP-title (Opus review WP-283 #1).
export MEMORY_PATH="$MEMORY_FILE"
export START_MARKER_ENV="$START_MARKER"
export END_MARKER_ENV="$END_MARKER"
export NEW_BLOCK_ENV="$NEW_BLOCK"

python3 - <<'PYEOF'
import os, re, sys

memory_path = os.environ['MEMORY_PATH']
start = os.environ['START_MARKER_ENV']
end = os.environ['END_MARKER_ENV']
new_block = os.environ['NEW_BLOCK_ENV']

try:
    # Если runtime memory read-only — fallback на exocortex source-of-truth
    exocortex_path = os.environ.get('EXOCORTEX_MEMORY', memory_path)
    target_path = memory_path
    if not os.access(memory_path, os.W_OK):
        if os.path.exists(exocortex_path) and os.access(exocortex_path, os.W_OK):
            target_path = exocortex_path
            print(f"INFO: runtime memory read-only, using exocortex: {target_path}", file=sys.stderr)
        else:
            print(f"ERROR: neither runtime nor exocortex MEMORY.md is writable", file=sys.stderr)
            sys.exit(1)

    with open(target_path, 'r', encoding='utf-8') as f:
        content = f.read()

    pattern = re.escape(start) + r'.*?' + re.escape(end)
    # Backslashes в new_block мог бы ломать re.sub (трактуются как backreferences).
    # Используем callable replacement для буквальной подстановки.
    new_content = re.sub(pattern, lambda m: new_block, content, flags=re.DOTALL)

    if new_content == content:
        print("INFO: нет изменений", file=sys.stderr)
        sys.exit(0)

    with open(target_path, 'w', encoding='utf-8') as f:
        f.write(new_content)

    print("OK: MEMORY.md обновлён", file=sys.stderr)

except Exception as e:
    print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
