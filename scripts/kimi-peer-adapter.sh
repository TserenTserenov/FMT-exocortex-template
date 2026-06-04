#!/bin/bash
# kimi-peer-adapter.sh v2 — адаптер Kimi для peer-conversation.sh с PII-фильтрацией
# see DP.SC.154 (З-Ф5), DP.ROLE.039, WP-365 Ф2-Ф3 (peer-session 2026-05-29-27)
#
# Принимает аргументы в стиле Claude (-p --model X --add-dir Y --permission-mode Z),
# применяет .agentigore filter + PII sanity-check,
# вызывает Kimi с очищенной директорией.
#
# Exit codes:
#   0 — OK
#   1 — general error (kimi not found, args)
#   2 — .agentigore filter violation (Python filter error)
#   3 — PII Hard Block (sanity-check found high-severity pattern)
#   4 — --add-dir too large (>100MB or >5000 files)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# KIMI_BIN auto-detect: env override → PATH → VS Code extension paths (macOS/Linux/WSL)
KIMI_BIN="${KIMI_BIN:-$(command -v kimi 2>/dev/null || true)}"
if [ -z "$KIMI_BIN" ]; then
  for candidate in \
    "$HOME/Library/Application Support/Code/User/globalStorage/moonshot-ai.kimi-code/bin/kimi/kimi" \
    "$HOME/.config/Code/User/globalStorage/moonshot-ai.kimi-code/bin/kimi/kimi" \
    "$HOME/AppData/Roaming/Code/User/globalStorage/moonshot-ai.kimi-code/bin/kimi/kimi"; do
    [ -x "$candidate" ] && KIMI_BIN="$candidate" && break
  done
fi

if [ -z "$KIMI_BIN" ] || [ ! -x "$KIMI_BIN" ]; then
  echo "ERROR: kimi binary not found. Install Kimi CLI or set KIMI_BIN env var." >&2
  echo "  Looked in: PATH, ~/Library/.../moonshot-ai.kimi-code (macOS)," >&2
  echo "             ~/.config/Code/.../moonshot-ai.kimi-code (Linux)," >&2
  echo "             ~/AppData/Roaming/Code/.../moonshot-ai.kimi-code (Windows)" >&2
  exit 1
fi

ADD_DIRS=()
MODEL_ARG=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p)                shift ;;
    --model)           MODEL_ARG=("--model" "$2"); shift 2 ;;
    --add-dir)         ADD_DIRS+=("$2"); shift 2 ;;
    --permission-mode) shift 2 ;;
    *)                 shift ;;
  esac
done

if [ ${#MODEL_ARG[@]} -ge 2 ]; then
  case "${MODEL_ARG[1]-}" in
    sonnet|opus|haiku|claude-*) MODEL_ARG=() ;;
  esac
fi

# === Фильтрация --add-dir через .agentigore + PII sanity-check ===

FILTERED_DIRS=()
TMP_ROOT=$(mktemp -d -t kimi-peer-XXXXXX)
trap 'rm -rf "$TMP_ROOT"' EXIT INT TERM

# Merged .agentigore (union: ~/.iwe → git-root → session_dir)
MERGED_AGENTIGORE="$TMP_ROOT/.agentigore"
: > "$MERGED_AGENTIGORE"
[ -f "$HOME/.iwe/.agentigore" ] && cat "$HOME/.iwe/.agentigore" >> "$MERGED_AGENTIGORE"

# Per --add-dir: merge git-root + session-dir .agentigore (если есть)
for ADD_DIR in "${ADD_DIRS[@]+"${ADD_DIRS[@]}"}"; do
  [ ! -d "$ADD_DIR" ] && continue
  GIT_ROOT=$(git -C "$ADD_DIR" rev-parse --show-toplevel 2>/dev/null || true)
  [ -n "$GIT_ROOT" ] && [ -f "$GIT_ROOT/.agentigore" ] && cat "$GIT_ROOT/.agentigore" >> "$MERGED_AGENTIGORE"
  [ -f "$ADD_DIR/.agentigore" ] && cat "$ADD_DIR/.agentigore" >> "$MERGED_AGENTIGORE"
done

# === Fail-fast на размер ===
for ADD_DIR in "${ADD_DIRS[@]+"${ADD_DIRS[@]}"}"; do
  [ ! -d "$ADD_DIR" ] && continue
  SIZE_MB=$(du -sm "$ADD_DIR" 2>/dev/null | awk '{print $1}')
  FILES=$(find "$ADD_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')
  if [ "${SIZE_MB:-0}" -gt 100 ] || [ "${FILES:-0}" -gt 5000 ]; then
    echo "ABORT: --add-dir $ADD_DIR too large (${SIZE_MB}MB / ${FILES} files; limit 100MB/5000)" >&2
    exit 4
  fi
done

# === Фильтрация через Python fnmatch + PII sanity-check ===
for ADD_DIR in "${ADD_DIRS[@]+"${ADD_DIRS[@]}"}"; do
  [ ! -d "$ADD_DIR" ] && continue
  CLEAN_DIR="$TMP_ROOT/$(basename "$ADD_DIR")"
  mkdir -p "$CLEAN_DIR"

  AGENTIGORE_FILE="$MERGED_AGENTIGORE" SRC_DIR="$ADD_DIR" DST_DIR="$CLEAN_DIR" \
    python3 "$SCRIPT_DIR/peer-adapter-filter.py"
  RC=$?
  if [ $RC -eq 3 ]; then
    exit 3
  elif [ $RC -ne 0 ]; then
    echo "ABORT: filter failed with code $RC" >&2
    exit 2
  fi

  FILTERED_DIRS+=("--add-dir" "$CLEAN_DIR")
done

# === Запуск Kimi с очищенной директорией ===
KIMI_OUTPUT=$(cat | "$KIMI_BIN" --quiet --yolo \
  ${MODEL_ARG[@]+"${MODEL_ARG[@]}"} \
  ${FILTERED_DIRS[@]+"${FILTERED_DIRS[@]}"} \
  2>/dev/null | grep -v "^To resume this session:")

# Empty output guard — writer-сторона должна отличать "Kimi не ответил" от "Kimi ответил пусто"
if [ -z "$KIMI_OUTPUT" ]; then
  echo "ERROR: kimi returned empty output (network/auth/quota?)" >&2
  exit 1
fi

# === Hindsight L2 retain — writer-only per-turn (opt-in via env) ===
# Skipped silently if hindsight_trigger.py is not present (template installs without it).
HINDSIGHT_SCRIPT="$SCRIPT_DIR/hindsight_trigger.py"
if [ "${IWE_HINDSIGHT_RETAIN:-}" = "1" ] && [ -n "$KIMI_OUTPUT" ] && [ -x "$HINDSIGHT_SCRIPT" ]; then
  {
    echo "{\"action\":\"retain\",\"source\":\"kimi-peer\",\"text\":$(echo "$KIMI_OUTPUT" | head -c 4000 | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')}" \
    | python3 "$HINDSIGHT_SCRIPT" 2>/dev/null || true
  } &
fi

echo "$KIMI_OUTPUT"
