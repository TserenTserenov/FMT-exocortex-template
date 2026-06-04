#!/bin/bash
# claude-peer-adapter.sh — адаптер Claude для peer-conversation (роль напарника)
# see DP.SC.154 (симметричный аналог kimi-peer-adapter.sh)
#
# Вызывается агентом-ПИСАТЕЛЕМ (Kimi или другим) когда Claude выступает НАПАРНИКОМ.
# Принимает аргументы в стиле kimi-peer-adapter.sh, читает промпт из stdin,
# передаёт Claude headless (-p), возвращает ответ в stdout.
#
# Использование (из скрипта Kimi-писателя):
#   echo "$peer_prompt" | bash scripts/claude-peer-adapter.sh \
#     --add-dir "$SESSION_DIR" 2>/dev/null > "$PEER_FILE"

set -euo pipefail

# CLAUDE_BIN auto-detect: env override → PATH → user-local fallbacks.
# Системные пути (homebrew, /usr/local/bin) обычно в PATH и подхватываются через command -v.
CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude 2>/dev/null || true)}"
if [ -z "$CLAUDE_BIN" ]; then
  for candidate in \
    "$HOME/.local/bin/claude" \
    "$HOME/.npm-global/bin/claude" \
    "$HOME/.nvm/versions/node/*/bin/claude"; do
    # Expand glob (для nvm-paths)
    for resolved in $candidate; do
      [ -x "$resolved" ] && CLAUDE_BIN="$resolved" && break 2
    done
  done
fi
if [ -z "$CLAUDE_BIN" ] || [ ! -x "$CLAUDE_BIN" ]; then
  echo "ERROR: claude binary not found. Install Claude CLI or set CLAUDE_BIN env var." >&2
  echo "  Install: https://docs.claude.com/en/docs/claude-code/setup" >&2
  exit 1
fi

ADD_DIRS=()
MODEL_ARG=("--model" "sonnet")
PERMISSION_MODE_ARG=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p)              shift ;;
    --model)         MODEL_ARG=("--model" "$2"); shift 2 ;;
    --add-dir)       ADD_DIRS+=("--add-dir" "$2"); shift 2 ;;
    --permission-mode) PERMISSION_MODE_ARG=("--permission-mode" "$2"); shift 2 ;;
    *)               shift ;;
  esac
done

# Kimi-only aliases фильтровать не нужно — claude -p принимает любые модели
# По умолчанию sonnet (closed-loop, синтез — DP.D.distinctions Model Tiering)

"$CLAUDE_BIN" -p \
  "${MODEL_ARG[@]}" \
  ${ADD_DIRS[@]+"${ADD_DIRS[@]}"} \
  ${PERMISSION_MODE_ARG[@]+"${PERMISSION_MODE_ARG[@]}"} \
  2>/dev/null
