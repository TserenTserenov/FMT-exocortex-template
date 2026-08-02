#!/bin/bash
# install-hooks.sh — устанавливает .githooks/ как core.hooksPath для governance-репо.
#
# Usage:
#   bash scripts/install-hooks.sh [REPO_PATH]
#
# If REPO_PATH is omitted, uses the current working directory.
# This script is intentionally minimal and template-safe: it does not hardcode
# governance-repo paths or agent-specific checks. It only wires the repository
# to the tracked .githooks/ directory (pre-commit + pre-push guards).
#
# issue #342: an install where .githooks/ predates the pre-push guard (only
# pre-commit tracked) would run this script, get "✅ Hooks wired" and still
# have no force-push protection — nothing here ever copied the hook content,
# only backed up / chmod'd whatever already happened to exist. Fixed by
# copying missing hooks from the template's canonical seed/strategy/.githooks/
# (found via IWE_TEMPLATE / IWE_ROOT, same fallback chain roles/extractor and
# create-wp.sh already use) and by refusing to claim success if a hook is
# still missing afterwards.
#
# see WP-436 (force-push guard) + seed/strategy/.githooks/

set -euo pipefail

REPO="${1:-${PWD}}"
HOOK_DIR="$REPO/.githooks"
BACKUP_DIR="$REPO/.git/hook-backups"

if [ ! -d "$REPO/.git" ]; then
  echo "❌ Not a git repo: $REPO"
  exit 1
fi

CANONICAL_HOOKS_DIR=""
for candidate in \
  "${IWE_TEMPLATE:-}/seed/strategy/.githooks" \
  "${IWE_ROOT:-$HOME/IWE}/FMT-exocortex-template/seed/strategy/.githooks" \
  "$HOME/IWE/FMT-exocortex-template/seed/strategy/.githooks"
do
  if [ -n "$candidate" ] && [ -d "$candidate" ]; then
    CANONICAL_HOOKS_DIR="$candidate"
    break
  fi
done

mkdir -p "$HOOK_DIR" "$BACKUP_DIR"

for hook in pre-commit pre-push; do
  target="$HOOK_DIR/$hook"
  source_hook="$CANONICAL_HOOKS_DIR/$hook"

  if [ -f "$target" ]; then
    backup="$BACKUP_DIR/$hook.backup.$(date +%s)"
    cp "$target" "$backup"
    echo "📝 Existing $hook backed up to: $backup"
  fi

  if [ -n "$CANONICAL_HOOKS_DIR" ] && [ -f "$source_hook" ]; then
    cp "$source_hook" "$target"
  fi

  [ -f "$target" ] && chmod +x "$target"
done

git -C "$REPO" config core.hooksPath .githooks

MISSING=""
for hook in pre-commit pre-push; do
  [ -x "$HOOK_DIR/$hook" ] || MISSING="$MISSING $hook"
done

if [ -n "$MISSING" ]; then
  echo "⚠️  core.hooksPath = .githooks, но отсутствуют:$MISSING"
  echo "   Канонический источник не найден (искали в \$IWE_TEMPLATE, \$IWE_ROOT/FMT-exocortex-template, \$HOME/IWE/FMT-exocortex-template)."
  echo "   Хуки НЕ активны, пока эти файлы не появятся в $HOOK_DIR."
  exit 1
fi

echo "✅ Hooks wired: $HOOK_DIR"
echo "   core.hooksPath = $(git -C "$REPO" config core.hooksPath)"
