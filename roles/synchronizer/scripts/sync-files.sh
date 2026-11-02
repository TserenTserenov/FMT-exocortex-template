#!/bin/bash
# sync-files.sh — targeted update of files from the remote
#
# Usage:
#   sync-files.sh <repo-path> <file1> [file2] ...
#
# Examples:
#   sync-files.sh ~/IWE/DS-strategy inbox/fleeting-notes.md
#   sync-files.sh ~/IWE/DS-strategy inbox/fleeting-notes.md inbox/captures.md
#
# The script does a git fetch and updates ONLY the specified files,
# leaving other local changes untouched.

set -euo pipefail

REPO_PATH="${1:?Ошибка: укажи путь к репозиторию}"
shift

if [ $# -eq 0 ]; then
  echo "Ошибка: укажи хотя бы один файл для синхронизации" >&2
  exit 1
fi

cd "$REPO_PATH"

BRANCH=$(git rev-parse --abbrev-ref HEAD)
REMOTE="origin"

# Fetch only (no merge, no pull)
if ! git fetch "$REMOTE" "$BRANCH" --quiet 2>/dev/null; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') [sync-files] fetch failed (offline?)" >&2
  exit 0
fi

SYNCED=0
for FILE in "$@"; do
  if git cat-file -e "${REMOTE}/${BRANCH}:${FILE}" 2>/dev/null; then
    LOCAL_HASH=$(git hash-object "$FILE" 2>/dev/null || echo "none")
    REMOTE_HASH=$(git rev-parse "${REMOTE}/${BRANCH}:${FILE}" 2>/dev/null || echo "none")

    if [ "$LOCAL_HASH" != "$REMOTE_HASH" ]; then
      git checkout "${REMOTE}/${BRANCH}" -- "$FILE"
      SYNCED=$((SYNCED + 1))
      echo "$(date '+%Y-%m-%d %H:%M:%S') [sync-files] updated: $FILE"
    fi
  else
    echo "$(date '+%Y-%m-%d %H:%M:%S') [sync-files] skip: $FILE (not in remote)" >&2
  fi
done

if [ "$SYNCED" -gt 0 ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') [sync-files] synced $SYNCED file(s)"
fi
