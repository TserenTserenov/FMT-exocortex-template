#!/bin/bash
# Exocortex Update — pull upstream changes from FMT-exocortex-template
#
# Использование:
#   update.sh              # fetch + merge + reinstall platform-space
#   update.sh --check      # только проверить, есть ли обновления
#   update.sh --dry-run    # показать что изменится, не применять

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Определить рабочую директорию ---
# Если скрипт в fork-е экзокортекса (FMT-exocortex)
if [ -f "$SCRIPT_DIR/CLAUDE.md" ] && [ -d "$SCRIPT_DIR/memory" ]; then
    EXOCORTEX_DIR="$SCRIPT_DIR"
elif [ -d "$HOME/Github/FMT-exocortex" ]; then
    EXOCORTEX_DIR="$HOME/Github/FMT-exocortex"
else
    echo "ERROR: Cannot find exocortex directory."
    echo "Run this script from your exocortex fork root or ~/Github/FMT-exocortex/"
    exit 1
fi

WORKSPACE_DIR="$(dirname "$EXOCORTEX_DIR")"
DRY_RUN=false
CHECK_ONLY=false

case "${1:-}" in
    --dry-run)   DRY_RUN=true ;;
    --check)     CHECK_ONLY=true ;;
esac

echo "=========================================="
echo "  Exocortex Update"
echo "=========================================="
echo "  Source: $EXOCORTEX_DIR"
echo ""

cd "$EXOCORTEX_DIR"

# --- 1. Fetch upstream ---
echo "[1/4] Fetching upstream..."
if ! git remote | grep -q upstream; then
    echo "  Adding upstream remote..."
    git remote add upstream https://github.com/TserenTserenov/FMT-exocortex-template.git
fi

git fetch upstream main 2>&1 | sed 's/^/  /'

# --- 2. Check for changes ---
LOCAL=$(git rev-parse HEAD)
UPSTREAM=$(git rev-parse upstream/main)
BASE=$(git merge-base HEAD upstream/main)

if [ "$LOCAL" = "$UPSTREAM" ]; then
    echo "  Already up to date."
    exit 0
fi

COMMITS_BEHIND=$(git rev-list --count HEAD..upstream/main)
echo "  $COMMITS_BEHIND new commits from upstream"
echo ""

# Show what changed
echo "  Changes:"
git log --oneline HEAD..upstream/main | sed 's/^/    /'
echo ""

if $CHECK_ONLY; then
    echo "Run 'update.sh' to apply these changes."
    exit 0
fi

if $DRY_RUN; then
    echo "[DRY RUN] Would merge $COMMITS_BEHIND commits and reinstall platform-space."
    echo ""
    echo "Files that would change:"
    git diff --stat HEAD..upstream/main | sed 's/^/  /'
    exit 0
fi

# --- 3. Merge upstream ---
echo "[2/4] Merging upstream..."

# Stash local changes if any
STASHED=false
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "  Stashing local changes..."
    git stash push -m "pre-update stash $(date +%Y-%m-%d)"
    STASHED=true
fi

if ! git merge upstream/main --no-edit 2>&1 | sed 's/^/  /'; then
    echo ""
    echo "ERROR: Merge conflict. Resolve manually:"
    echo "  cd $EXOCORTEX_DIR"
    echo "  git status  # see conflicting files"
    echo "  # resolve conflicts, then: git add . && git merge --continue"
    exit 1
fi

# Restore stash if needed
if $STASHED; then
    echo "  Restoring local changes..."
    git stash pop || echo "  WARN: Stash pop conflict. Run 'git stash pop' manually."
fi

# --- 4. Reinstall platform-space ---
echo "[3/5] Reinstalling platform-space..."

# Copy CLAUDE.md to workspace root
if [ -f "$EXOCORTEX_DIR/CLAUDE.md" ]; then
    cp "$EXOCORTEX_DIR/CLAUDE.md" "$WORKSPACE_DIR/CLAUDE.md"
    echo "  Updated: $WORKSPACE_DIR/CLAUDE.md"
fi

# Copy memory files
CLAUDE_MEMORY_DIR="$HOME/.claude/projects/-$(echo "$WORKSPACE_DIR" | tr '/' '-')/memory"
if [ -d "$EXOCORTEX_DIR/memory" ] && [ -d "$CLAUDE_MEMORY_DIR" ]; then
    # Update all memory files EXCEPT MEMORY.md (user's РП table)
    for f in "$EXOCORTEX_DIR/memory/"*.md; do
        fname=$(basename "$f")
        if [ "$fname" != "MEMORY.md" ]; then
            cp "$f" "$CLAUDE_MEMORY_DIR/$fname"
            echo "  Updated: memory/$fname"
        fi
    done
    echo "  Skipped: memory/MEMORY.md (user data preserved)"
fi

# Update MCP configuration (.claude/settings.local.json)
# Strategy: update mcpServers URLs from upstream, preserve user's custom permissions
SETTINGS_SRC="$EXOCORTEX_DIR/.claude/settings.local.json"
SETTINGS_DST="$WORKSPACE_DIR/.claude/settings.local.json"
if [ -f "$SETTINGS_SRC" ]; then
    if [ -f "$SETTINGS_DST" ]; then
        # Merge: take mcpServers from upstream, keep user permissions
        if command -v python3 &>/dev/null; then
            python3 -c "
import json, sys
with open('$SETTINGS_SRC') as f: src = json.load(f)
with open('$SETTINGS_DST') as f: dst = json.load(f)
# Update mcpServers from upstream
dst['mcpServers'] = src.get('mcpServers', {})
# Merge permissions: add new MCP tools from upstream, keep user's custom permissions
src_perms = set(src.get('permissions', {}).get('allow', []))
dst_perms = set(dst.get('permissions', {}).get('allow', []))
# Add any new permissions from upstream that user doesn't have
merged = sorted(dst_perms | src_perms)
dst.setdefault('permissions', {})['allow'] = merged
with open('$SETTINGS_DST', 'w') as f: json.dump(dst, f, indent=2, ensure_ascii=False)
print('  Updated: .claude/settings.local.json (merged)')
" 2>&1
        else
            # Fallback: just copy (no merge)
            cp "$SETTINGS_SRC" "$SETTINGS_DST"
            echo "  Updated: .claude/settings.local.json (replaced, python3 not found for merge)"
        fi
    else
        # First install: just copy
        mkdir -p "$(dirname "$SETTINGS_DST")"
        cp "$SETTINGS_SRC" "$SETTINGS_DST"
        echo "  Installed: .claude/settings.local.json"
    fi
fi

# --- 5. Reinstall roles ---
echo "[4/5] Reinstalling roles..."

# Check which role files changed and reinstall if needed
CHANGED_FILES=$(git diff --name-only "$LOCAL".."$UPSTREAM" 2>/dev/null || echo "")

reinstall_role() {
    local role_name="$1"
    local install_script="$EXOCORTEX_DIR/roles/$role_name/install.sh"
    if [ -f "$install_script" ]; then
        echo "  Reinstalling $role_name..."
        chmod +x "$install_script"
        bash "$install_script" 2>&1 | sed 's/^/    /'
    fi
}

# Reinstall roles whose files changed (autodiscovery)
for role_dir in "$EXOCORTEX_DIR"/roles/*/; do
    [ -d "$role_dir" ] || continue
    role_name=$(basename "$role_dir")
    [ -f "$role_dir/install.sh" ] || continue

    if echo "$CHANGED_FILES" | grep -q "^roles/$role_name/"; then
        reinstall_role "$role_name"
    else
        echo "  $role_name: no changes"
    fi
done

# --- Done ---
echo "[5/5] Pushing merge commit..."
git push 2>&1 | sed 's/^/  /'

echo ""
echo "=========================================="
echo "  Update Complete!"
echo "=========================================="
echo "  Merged $COMMITS_BEHIND commits from upstream"
echo "  Platform-space reinstalled"
echo "  Roles checked for reinstallation"
echo ""
