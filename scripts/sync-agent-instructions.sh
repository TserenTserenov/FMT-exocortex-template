#!/usr/bin/env bash
# routing: utility  deterministic=true
# see WP-394 Ф4.2, DP.SC.159
# sync-agent-instructions.sh — генерация AGENTS.md из единого ядра CLAUDE.md + agent-blocks
#
# Single-source инструкций агентов (WP-394 Ф4.2). Устраняет молчаливую дивергенцию
# между CLAUDE.md (Claude), AGENTS.md (Kimi) и инструкциями Hermes.
#
# Сборка (полная регенерация, НЕ маркерная вставка):
#   AGENTS.md = [header] + [SYNC-CORE из CLAUDE.md] + [AGENTS-agent-blocks.md]
#
# Источники (в $IWE_ROOT, default $HOME/IWE):
#   CLAUDE.md             — секция между <!-- SYNC-CORE-START --> и <!-- SYNC-CORE-END -->
#   AGENTS-agent-blocks.md — агент-специфика (commit attribution, MCP, instructions level)
#
# Использование:
#   ./sync-agent-instructions.sh            # dry-run: unified diff, без записи (DEFAULT)
#   ./sync-agent-instructions.sh --force    # записать AGENTS.md (с бэкапом .bak)
#   ./sync-agent-instructions.sh --check    # exit 1 если drift (для CI / Day Open), без записи
#   ./sync-agent-instructions.sh --with-hermes  # дополнительно сгенерить persona.md Гермеса
#   ./sync-agent-instructions.sh --help
#
# Переменные окружения:
#   IWE_ROOT            — корень рабочего пространства (default $HOME/IWE)
#   HERMES_RUNTIME_DIR  — каталог рантайма Hermes для --with-hermes (default $HOME/.hermes)
#
# Инвариант: CLAUDE.md SYNC-CORE — source-of-truth общего ядра. AGENTS.md derived, не править руками.

set -euo pipefail

IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
CLAUDE_MD="$IWE_ROOT/CLAUDE.md"
BLOCKS_MD="$IWE_ROOT/AGENTS-agent-blocks.md"
OUT_MD="$IWE_ROOT/AGENTS.md"
HERMES_DIR="${HERMES_RUNTIME_DIR:-$HOME/.hermes}"

MODE="dry-run"
WITH_HERMES=0
for arg in "$@"; do
  case "$arg" in
    --force)       MODE="force" ;;
    --check)       MODE="check" ;;
    --with-hermes) WITH_HERMES=1 ;;
    --help|-h)
      grep '^#' "$0" | sed 's/^# \{0,1\}//' | head -32
      exit 0 ;;
    *) echo "Неизвестный аргумент: $arg (см. --help)" >&2; exit 2 ;;
  esac
done

# --- Валидация источников ---
for f in "$CLAUDE_MD" "$BLOCKS_MD"; do
  if [ ! -f "$f" ]; then
    echo "[ERROR] Источник не найден: $f" >&2
    exit 1
  fi
done

# --- Guard: маркеры SYNC-CORE обязаны присутствовать (pre-миграция завершена?) ---
if ! grep -q '<!-- SYNC-CORE-START -->' "$CLAUDE_MD" || ! grep -q '<!-- SYNC-CORE-END -->' "$CLAUDE_MD"; then
  echo "[ABORT] В $CLAUDE_MD нет маркеров <!-- SYNC-CORE-START/END -->." >&2
  echo "        Pre-миграция не завершена — разметь ядро ДО генерации (WP-394 Ф4.2)." >&2
  exit 3
fi

# --- Извлечь SYNC-CORE ядро (между маркерами, не включая сами маркеры) ---
extract_core() {
  # Маркеры якорятся ^...$ — строка-маркер внутри тела ядра не закроет блок преждевременно.
  awk '
    /^[[:space:]]*<!-- SYNC-CORE-START -->[[:space:]]*$/ { grab=1; next }
    /^[[:space:]]*<!-- SYNC-CORE-END -->[[:space:]]*$/   { grab=0 }
    grab { print }
  ' "$CLAUDE_MD"
}

# --- Извлечь агент-блоки (убрать внешние маркер-комментарии и HTML-комментарий-инструкцию) ---
extract_blocks() {
  awk '
    /^[[:space:]]*<!-- AGENT-SPECIFIC-START -->[[:space:]]*$/ { grab=1; next }
    /^[[:space:]]*<!-- AGENT-SPECIFIC-END -->[[:space:]]*$/   { grab=0; next }
    grab {
      # пропустить вводный HTML-комментарий (<!-- ... -->) в начале блока
      if ($0 ~ /^<!--/) { incomment=1 }
      if (incomment) { if ($0 ~ /-->/) { incomment=0 }; next }
      print
    }
  ' "$BLOCKS_MD"
}

# --- Собрать целевой AGENTS.md ---
build_agents() {
  cat <<'HEADER'
# AGENTS.md

> **Сгенерировано `scripts/sync-agent-instructions.sh` (WP-394 Ф4.2). НЕ РЕДАКТИРОВАТЬ ВРУЧНУЮ.**
> Общее ядро → блок `<!-- SYNC-CORE -->` в `CLAUDE.md`. Агент-специфика → `AGENTS-agent-blocks.md`.

HEADER
  extract_core
  echo
  extract_blocks
}

GENERATED="$(build_agents)"

# --- Режимы ---
case "$MODE" in
  check)
    if [ ! -f "$OUT_MD" ]; then
      echo "[DRIFT] $OUT_MD не существует — нужна генерация (--force)." >&2
      exit 1
    fi
    if diff -q <(printf '%s\n' "$GENERATED") "$OUT_MD" >/dev/null 2>&1; then
      echo "Синхронизация: OK (AGENTS.md соответствует ядру)"
      exit 0
    else
      echo "[DRIFT] AGENTS.md расходится с ядром CLAUDE.md + agent-blocks. Запусти --force." >&2
      exit 1
    fi
    ;;
  dry-run)
    echo "=== sync-agent-instructions.sh: dry-run ==="
    echo "IWE_ROOT: $IWE_ROOT"
    if [ -f "$OUT_MD" ]; then
      if diff -q <(printf '%s\n' "$GENERATED") "$OUT_MD" >/dev/null 2>&1; then
        echo "AGENTS.md уже актуален — изменений нет."
      else
        echo "--- unified diff (текущий → сгенерированный) ---"
        diff -u "$OUT_MD" <(printf '%s\n' "$GENERATED") || true
        echo "--- для записи: --force ---"
      fi
    else
      echo "AGENTS.md не существует — будет создан при --force. Превью:"
      printf '%s\n' "$GENERATED" | head -20
    fi
    ;;
  force)
    if [ -f "$OUT_MD" ]; then
      cp "$OUT_MD" "$OUT_MD.bak"
      echo "Бэкап: $OUT_MD.bak"
    fi
    printf '%s\n' "$GENERATED" > "$OUT_MD"
    echo "Записано: $OUT_MD ($(wc -l < "$OUT_MD" | tr -d ' ') строк)"
    ;;
esac

# --- Опционально: persona.md Hermes ---
if [ "$WITH_HERMES" -eq 1 ]; then
  if [ ! -d "$HERMES_DIR" ]; then
    echo "[WARN] --with-hermes: каталог $HERMES_DIR не найден — persona.md пропущен (рантайм Hermes отсутствует)." >&2
  elif [ "$MODE" = "force" ]; then
    PERSONA="$HERMES_DIR/persona.md"
    [ -f "$PERSONA" ] && cp "$PERSONA" "$PERSONA.bak"
    {
      echo "# Hermes Persona — IWE Core (generated by sync-agent-instructions.sh)"
      echo
      echo "> Общее ядро IWE. Hermes-специфика — в рантайме Hermes, не здесь."
      echo
      extract_core
    } > "$PERSONA"
    echo "Записано: $PERSONA"
  else
    echo "[INFO] --with-hermes активен, но persona.md пишется только в режиме --force."
  fi
fi
