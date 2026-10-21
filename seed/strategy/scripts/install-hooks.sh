#!/bin/bash
# install-hooks.sh — sets .githooks/ as core.hooksPath for governance-repo.
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
# WP-484 (31.08.2026): a hook that exists but differs from canonical is never
# overwritten anymore — only a MISSING hook gets copied. The previous
# behavior force-synced content on every drift, which discarded a governance
# repo's own repo-specific composite pre-commit hook during an unrelated
# core.hooksPath repair. Divergent local content is assumed intentional; the
# backup-then-overwrite dance existed only to make that destructive overwrite
# less bad, so it's gone along with it.
#
# see WP-436 (force-push guard) + seed/strategy/.githooks/

set -euo pipefail

REPO="${1:-${PWD}}"
HOOK_DIR="$REPO/.githooks"

if [ -L "$REPO" ] || [ -L "$REPO/.git" ] || [ ! -d "$REPO/.git" ]; then
  echo "❌ Not a git repo: $REPO"
  exit 1
fi

CANONICAL_HOOKS_DIR=""
for candidate in \
  "${IWE_TEMPLATE:-}/seed/strategy/.githooks" \
  "${IWE_ROOT:-$HOME/IWE}/IWE/seed/strategy/.githooks" \
  "$HOME/IWE/IWE/seed/strategy/.githooks"
do
  if [ -n "$candidate" ] && [ ! -L "$candidate" ] && [ -d "$candidate" ]; then
    CANONICAL_HOOKS_DIR="$candidate"
    break
  fi
done

MISSING_SOURCE=""
for hook in pre-commit pre-push; do
  [ -n "$CANONICAL_HOOKS_DIR" ] \
    && [ ! -L "$CANONICAL_HOOKS_DIR/$hook" ] \
    && [ -f "$CANONICAL_HOOKS_DIR/$hook" ] \
    || MISSING_SOURCE="$MISSING_SOURCE $hook"
done
if [ -n "$MISSING_SOURCE" ]; then
  echo "⚠️  Canonical hooks source hooks not found or incomplete:$MISSING_SOURCE"
  echo "   Looked in \$IWE_TEMPLATE, \$IWE_ROOT/IWE, \$HOME/IWE/IWE."
  echo "   core.hooksPath not changed."
  exit 1
fi

if [ -L "$HOOK_DIR" ]; then
  echo "❌ Refusing symlink hook directory in $REPO" >&2
  echo "   core.hooksPath not changed." >&2
  exit 1
fi
for hook in pre-commit pre-push; do
  if [ -L "$HOOK_DIR/$hook" ]; then
    echo "❌ Refusing symlink hook target: $HOOK_DIR/$hook" >&2
    echo "   No hook hook and core.hooksPath not changed." >&2
    exit 1
  fi
done
mkdir -p "$HOOK_DIR"

copy_hook_atomically() {
  local source_hook="$1" target="$2" temporary
  temporary=$(mktemp "$HOOK_DIR/.iwe-hook-copy.XXXXXX")
  if ! cp "$source_hook" "$temporary" \
    || ! chmod +x "$temporary" \
    || ! mv -f "$temporary" "$target"; then
    rm -f "$temporary"
    echo "❌ Hook copy failed atomically: $target" >&2
    return 1
  fi
}

for hook in pre-commit pre-push; do
  target="$HOOK_DIR/$hook"
  source_hook="$CANONICAL_HOOKS_DIR/$hook"

  if [ ! -f "$target" ]; then
    copy_hook_atomically "$source_hook" "$target"
  elif ! cmp -s "$source_hook" "$target"; then
    echo "⚠️  $hook differs from the canonical template — keeping the local version (do not self-heal content, see. WP-484 in the comment above)."
  fi

  [ -f "$target" ] && chmod +x "$target"
done

git -C "$REPO" config core.hooksPath .githooks

MISSING=""
for hook in pre-commit pre-push; do
  [ -x "$HOOK_DIR/$hook" ] || MISSING="$MISSING $hook"
done

if [ -n "$MISSING" ]; then
  echo "⚠️  core.hooksPath = .githooks, but are missing or not executable:$MISSING"
  echo "   Hooks are NOT active, until these files appear in $HOOK_DIR."
  exit 1
fi

echo "✅ Hooks wired: $HOOK_DIR"
echo "   core.hooksPath = $(git -C "$REPO" config core.hooksPath)"
