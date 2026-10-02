#!/usr/bin/env bash
#
# kimi-standalone-preflight.sh
# Hard gate для Kimi standalone-сессий.
# Проверяет, что сессия открыта через session-guard.sh и не устарела.
#
# Usage: bash scripts/kimi-standalone-preflight.sh

set -euo pipefail

IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
SESSION_DIR="$IWE_ROOT/.iwe-runtime/sessions"
STALE_THRESHOLD="${IWE_SESSION_STALE_THRESHOLD:-1800}"  # 30 min

SEM_FILE=$(ls -t "$SESSION_DIR/kimi"-*.open 2>/dev/null | head -1 || true)

if [ -z "$SEM_FILE" ]; then
  echo "ERROR: Kimi standalone session is NOT OPEN." >&2
  echo "Run first:" >&2
  echo "  bash ~/IWE/scripts/session-guard.sh open --wp WP-N --task \"...\" --agent kimi" >&2
  exit 1
fi

SEM_AGE=0
if command -v stat >/dev/null 2>&1; then
  # GNU stat first: its `stat -f` is "file system status" and succeeds (#1010 F14).
  if stat -c %Y "$SEM_FILE" >/dev/null 2>&1; then
    # Linux / Git Bash
    SEM_MTIME=$(stat -c %Y "$SEM_FILE")
  else
    # macOS
    SEM_MTIME=$(stat -f %m "$SEM_FILE")
  fi
  SEM_AGE=$(($(date +%s) - SEM_MTIME))
fi

if [ "$SEM_AGE" -gt "$STALE_THRESHOLD" ]; then
  echo "WARNING: active session $(basename "$SEM_FILE") is stale (${SEM_AGE}s)." >&2
  echo "Consider closing and reopening the session." >&2
fi

echo "OK: $(basename "$SEM_FILE") (age: ${SEM_AGE}s)"
