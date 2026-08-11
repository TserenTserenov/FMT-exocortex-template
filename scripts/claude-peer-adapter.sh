#!/bin/bash
# claude-peer-adapter.sh — адаптер Claude для peer-conversation (роль напарника)
# see DP.SC.154 (симметричный аналог kimi-peer-adapter.sh)
#
# Вызывается агентом-ПИСАТЕЛЕМ (Kimi или другим) когда Claude выступает НАПАРНИКОМ.
# Принимает аргументы в стиле kimi-peer-adapter.sh, читает промпт из stdin,
# передаёт Claude headless (-p), возвращает ответ в stdout.
#
# Контракт безопасности (WP-458, WP-510): адаптер принимает только текстовую
# проекцию через stdin. Он не получает рабочих каталогов и не даёт Claude
# файловые или shell-инструменты.
# Использование:
#   bash scripts/claude-peer-adapter.sh < peer-prompt.md > peer.md 2> peer.err
# Промпт передаётся файлом, не inline `echo "$peer_prompt" | ...` — иначе текст
# промпта попадает в командную строку и хук B7.7c ложно блокирует повторные
# вызовы (bug-2026-06-30-peer-adapter-b77c-block).

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

# Модель не выбирает адаптер: без явного --model Claude CLI применяет свою
# настроенную по умолчанию модель. Это сохраняет разделение между личностью,
# каналом и конструктивной реализацией.
MODEL_ARG=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p)              shift ;;
    --model)         MODEL_ARG=("--model" "$2"); shift 2 ;;
    --add-dir)
      echo "ERROR: --add-dir is disabled for claude-peer-adapter.sh. Put a minimal text projection in stdin instead." >&2
      exit 64
      ;;
    --permission-mode)
      echo "ERROR: permission mode is fixed to dontAsk for claude-peer-adapter.sh." >&2
      exit 64
      ;;
    *)               shift ;;
  esac
done

# Модель передаётся только при явном выборе вызывающего агента. Адаптер не
# назначает и не подменяет конструктивную реализацию напарника.

# WP-510 Ф17: text-only must be fail-closed. `plan` plus a deny-list did not
# provide that boundary: Claude could still call Agent, whose child discovered
# ToolSearch and MCP, then the parent timed out without stdout. `--safe-mode`
# removes project customizations/hooks/MCP, while the empty `--allowedTools` allow-list
# disables every tool namespace (including future tools not known today).
# `--no-session-persistence` prevents this ephemeral reviewer from leaving a
# resumable conversation. --add-dir remains forbidden above.
#
# This is still a Claude Code policy boundary, not an OS sandbox. Sensitive
# material requires a separately isolated runner and explicit pilot approval.
#
# perl alarm 300: 5-minute hard timeout, same as kimi-peer-adapter.sh.
# On timeout: SIGALRM → exit 142 → caller sees exit≠0 + empty file → reports to pilot.
CLAUDE_STDERR="$(mktemp)"
trap 'rm -f "$CLAUDE_STDERR"' EXIT

CLAUDE_OUTPUT=$(perl -e 'alarm 300; exec @ARGV' -- \
  "$CLAUDE_BIN" -p \
  --safe-mode \
  --allowedTools "" \
  --permission-mode dontAsk \
  --max-turns 1 \
  --no-session-persistence \
  ${MODEL_ARG[@]+"${MODEL_ARG[@]}"} \
  "$@" 2>"$CLAUDE_STDERR") && CLAUDE_EXIT=0 || CLAUDE_EXIT=$?

# Auth-failure detection (peer-session 2026-08-04-08-wp7-f44-sandbox-review):
# macOS Keychain can be unreachable from a sandboxed child process (e.g. a
# Codex workspace-write sandbox) even when the pilot's own Claude Code login
# is valid — that surfaces as literal "Not logged in" text, not necessarily a
# non-zero exit. stderr is checked unconditionally (diagnostic channel);
# stdout only when the process itself also exited non-zero, so a genuine
# reply that happens to discuss login/auth text isn't misclassified as a
# failure (this environment discusses login issues often).
AUTH_PATTERN='Not logged in|Please run.*login'
if grep -qE "$AUTH_PATTERN" "$CLAUDE_STDERR" 2>/dev/null || \
   { [ "$CLAUDE_EXIT" -ne 0 ] && printf '%s' "$CLAUDE_OUTPUT" | grep -qE "$AUTH_PATTERN"; }; then
  echo "ERROR: Claude peer call looks unauthenticated (Not logged in). Common sandbox/Keychain artifact, not necessarily lost login — verify from a trusted terminal before re-running /login." >&2
  if [ -s "$CLAUDE_STDERR" ]; then
    echo "--- claude stderr (tail) ---" >&2
    tail -20 "$CLAUDE_STDERR" >&2
  fi
  exit 4
fi

if [ "$CLAUDE_EXIT" -ne 0 ]; then
  echo "ERROR: Claude peer call failed with exit code $CLAUDE_EXIT." >&2
  [ -s "$CLAUDE_STDERR" ] && tail -20 "$CLAUDE_STDERR" >&2
  exit "$CLAUDE_EXIT"
fi

if [ -z "$CLAUDE_OUTPUT" ]; then
  echo "ERROR: Claude peer call returned no response." >&2
  [ -s "$CLAUDE_STDERR" ] && tail -20 "$CLAUDE_STDERR" >&2
  exit 5
fi

printf '%s\n' "$CLAUDE_OUTPUT"
