#!/bin/bash
# Exocortex Setup Script
# Configures a forked FMT-exocortex-template: placeholders, memory, launchd, DS-strategy
#
# Usage:
#   1. Fork this repo: gh repo fork TserenTserenov/FMT-exocortex-template --clone --remote
#   2. cd FMT-exocortex-template
#   3. bash setup.sh
#
set -e

VERSION="0.3.0"
DRY_RUN=false

# === Parse arguments ===
case "${1:-}" in
    --dry-run)  DRY_RUN=true ;;
    --version)  echo "exocortex-setup v$VERSION"; exit 0 ;;
    --help|-h)
        echo "Usage: setup.sh [OPTIONS]"
        echo ""
        echo "Options:"
        echo "  --dry-run   Show what would be done without making changes"
        echo "  --version   Show version"
        echo "  --help      Show this help"
        exit 0
        ;;
esac

echo "=========================================="
echo "  Exocortex Setup v$VERSION"
echo "=========================================="
echo ""

# === Detect template directory ===
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_DIR="$SCRIPT_DIR"

# Verify we're inside the template
if [ ! -f "$TEMPLATE_DIR/CLAUDE.md" ] || [ ! -d "$TEMPLATE_DIR/memory" ]; then
    echo "ERROR: This script must be run from the root of FMT-exocortex-template."
    echo "  Expected: $TEMPLATE_DIR/CLAUDE.md and $TEMPLATE_DIR/memory/"
    echo ""
    echo "  Steps:"
    echo "    gh repo fork TserenTserenov/FMT-exocortex-template --clone --remote"
    echo "    cd FMT-exocortex-template"
    echo "    bash setup.sh"
    exit 1
fi

echo "Template: $TEMPLATE_DIR"
echo ""

# === Prerequisites check ===
echo "Checking prerequisites..."
PREREQ_FAIL=0

check_command() {
    local cmd="$1"
    local name="$2"
    local install_hint="$3"
    if command -v "$cmd" >/dev/null 2>&1; then
        echo "  ✓ $name: $(command -v "$cmd")"
    else
        echo "  ✗ $name: NOT FOUND"
        echo "    Install: $install_hint"
        PREREQ_FAIL=1
    fi
}

check_command "git" "Git" "xcode-select --install"
check_command "gh" "GitHub CLI" "brew install gh"
check_command "node" "Node.js" "brew install node (or https://nodejs.org)"
check_command "npm" "npm" "Comes with Node.js"
check_command "claude" "Claude Code" "npm install -g @anthropic-ai/claude-code"

# Check gh auth
if command -v gh >/dev/null 2>&1; then
    if gh auth status >/dev/null 2>&1; then
        echo "  ✓ GitHub CLI: authenticated"
    else
        echo "  ✗ GitHub CLI: not authenticated"
        echo "    Run: gh auth login"
        PREREQ_FAIL=1
    fi
fi

echo ""

if [ "$PREREQ_FAIL" -eq 1 ]; then
    echo "ERROR: Prerequisites check failed. Install missing tools and try again."
    exit 1
fi

# === Collect configuration ===
read -p "GitHub username: " GITHUB_USER
read -p "Workspace directory [$(dirname "$TEMPLATE_DIR")]: " WORKSPACE_DIR
WORKSPACE_DIR="${WORKSPACE_DIR:-$(dirname "$TEMPLATE_DIR")}"
# Expand ~ to $HOME
WORKSPACE_DIR="${WORKSPACE_DIR/#\~/$HOME}"

read -p "Claude CLI path [$(command -v claude || echo '/opt/homebrew/bin/claude')]: " CLAUDE_PATH
CLAUDE_PATH="${CLAUDE_PATH:-$(command -v claude || echo '/opt/homebrew/bin/claude')}"

read -p "Strategist launch hour (UTC, 0-23) [4]: " TIMEZONE_HOUR
TIMEZONE_HOUR="${TIMEZONE_HOUR:-4}"

read -p "Timezone description (e.g. '7:00 MSK') [${TIMEZONE_HOUR}:00 UTC]: " TIMEZONE_DESC
TIMEZONE_DESC="${TIMEZONE_DESC:-${TIMEZONE_HOUR}:00 UTC}"

HOME_DIR="$HOME"

# Compute Claude project slug: /Users/alice/Github → -Users-alice-Github
CLAUDE_PROJECT_SLUG="$(echo "$WORKSPACE_DIR" | tr '/' '-')"

echo ""
echo "Configuration:"
echo "  GitHub user:    $GITHUB_USER"
echo "  Workspace:      $WORKSPACE_DIR"
echo "  Claude path:    $CLAUDE_PATH"
echo "  Schedule hour:  $TIMEZONE_HOUR (UTC)"
echo "  Time desc:      $TIMEZONE_DESC"
echo "  Home dir:       $HOME_DIR"
echo "  Project slug:   $CLAUDE_PROJECT_SLUG"
echo ""

if $DRY_RUN; then
    echo "[DRY RUN] Would perform the following actions:"
    echo "  1. Substitute 7 placeholders in all .md, .sh, .json, .plist, .yaml files"
    echo "  2. Copy CLAUDE.md → $WORKSPACE_DIR/CLAUDE.md"
    echo "  3. Copy memory/*.md → $HOME/.claude/projects/$CLAUDE_PROJECT_SLUG/memory/"
    echo "  4. Copy .claude/settings.local.json → $WORKSPACE_DIR/.claude/"
    echo "  5. Install Strategist launchd agent (Extractor + Synchronizer = optional)"
    echo "  6. Create DS-strategy repo from seed/strategy/ template"
    exit 0
fi

read -p "Continue? (y/n) " -n 1 -r
echo ""
[[ ! $REPLY =~ ^[Yy]$ ]] && exit 1

# === Ensure workspace exists ===
mkdir -p "$WORKSPACE_DIR"

# === 1. Substitute placeholders ===
echo ""
echo "[1/6] Configuring placeholders..."

find "$TEMPLATE_DIR" -type f \( -name "*.md" -o -name "*.json" -o -name "*.sh" -o -name "*.plist" -o -name "*.yaml" -o -name "*.yml" \) | while read file; do
    sed -i '' \
        -e "s|{{GITHUB_USER}}|$GITHUB_USER|g" \
        -e "s|{{WORKSPACE_DIR}}|$WORKSPACE_DIR|g" \
        -e "s|{{CLAUDE_PATH}}|$CLAUDE_PATH|g" \
        -e "s|{{CLAUDE_PROJECT_SLUG}}|$CLAUDE_PROJECT_SLUG|g" \
        -e "s|{{TIMEZONE_HOUR}}|$TIMEZONE_HOUR|g" \
        -e "s|{{TIMEZONE_DESC}}|$TIMEZONE_DESC|g" \
        -e "s|{{HOME_DIR}}|$HOME_DIR|g" \
        "$file"
done

echo "  Placeholders substituted."

# === 2. Copy CLAUDE.md to workspace root ===
echo "[2/6] Installing CLAUDE.md..."
cp "$TEMPLATE_DIR/CLAUDE.md" "$WORKSPACE_DIR/CLAUDE.md"
echo "  Copied to $WORKSPACE_DIR/CLAUDE.md"

# === 3. Copy memory to Claude projects directory ===
echo "[3/6] Installing memory..."
CLAUDE_MEMORY_DIR="$HOME/.claude/projects/$CLAUDE_PROJECT_SLUG/memory"
mkdir -p "$CLAUDE_MEMORY_DIR"
cp "$TEMPLATE_DIR/memory/"*.md "$CLAUDE_MEMORY_DIR/"
echo "  Copied to $CLAUDE_MEMORY_DIR"

# === 4. Copy .claude settings ===
echo "[4/6] Installing Claude settings..."
mkdir -p "$WORKSPACE_DIR/.claude"
if [ -f "$TEMPLATE_DIR/.claude/settings.local.json" ]; then
    cp "$TEMPLATE_DIR/.claude/settings.local.json" "$WORKSPACE_DIR/.claude/settings.local.json"
    echo "  Copied to $WORKSPACE_DIR/.claude/settings.local.json"
else
    echo "  WARN: settings.local.json not found in template, skipping."
fi

# === 5. Install roles ===
echo "[5/6] Installing roles..."

# Strategist (always installed)
STRATEGIST_DIR="$TEMPLATE_DIR/roles/strategist"
if [ -f "$STRATEGIST_DIR/install.sh" ]; then
    chmod +x "$STRATEGIST_DIR/scripts/strategist.sh"
    chmod +x "$STRATEGIST_DIR/install.sh"
    bash "$STRATEGIST_DIR/install.sh"
    echo "  ✓ Strategist installed"
else
    echo "  WARN: roles/strategist/install.sh not found, skipping."
    echo "  Install manually: bash $STRATEGIST_DIR/install.sh"
fi

echo ""
echo "  Additional roles (install later when ready):"
echo "  - Extractor:     bash $TEMPLATE_DIR/roles/extractor/install.sh"
echo "  - Synchronizer:  bash $TEMPLATE_DIR/roles/synchronizer/install.sh"
echo "  See: $TEMPLATE_DIR/roles/README.md"

# === 6. Create DS-strategy repo ===
echo "[6/6] Setting up DS-strategy..."
MY_STRATEGY_DIR="$WORKSPACE_DIR/DS-strategy"
STRATEGY_TEMPLATE="$TEMPLATE_DIR/seed/strategy"

if [ -d "$MY_STRATEGY_DIR/.git" ]; then
    echo "  DS-strategy already exists as git repo."
else
    if [ -d "$STRATEGY_TEMPLATE" ]; then
        # Copy my-strategy template into its own repo
        cp -r "$STRATEGY_TEMPLATE" "$MY_STRATEGY_DIR"
        cd "$MY_STRATEGY_DIR"
        git init
        git add -A
        git commit -m "Initial exocortex: DS-strategy governance hub"

        # Create GitHub repo
        gh repo create "$GITHUB_USER/DS-strategy" --private --source=. --push 2>/dev/null || \
            echo "  GitHub repo DS-strategy already exists or creation skipped."
    else
        echo "  WARN: seed/strategy/ template not found. Creating minimal DS-strategy."
        mkdir -p "$MY_STRATEGY_DIR"/{current,inbox,archive/wp-contexts,docs,exocortex}
        cd "$MY_STRATEGY_DIR"
        git init
        git add -A
        git commit -m "Initial exocortex: DS-strategy governance hub (minimal)"
        gh repo create "$GITHUB_USER/DS-strategy" --private --source=. --push 2>/dev/null || \
            echo "  GitHub repo DS-strategy already exists or creation skipped."
    fi
fi

# === Done ===
echo ""
echo "=========================================="
echo "  Setup Complete!"
echo "=========================================="
echo ""
echo "Verify installation:"
echo "  ✓ CLAUDE.md:  $WORKSPACE_DIR/CLAUDE.md"
echo "  ✓ Memory:     $CLAUDE_MEMORY_DIR/ ($(ls "$CLAUDE_MEMORY_DIR"/*.md 2>/dev/null | wc -l | tr -d ' ') files)"
echo "  ✓ DS-strategy: $MY_STRATEGY_DIR/"
echo "  ✓ Template:   $TEMPLATE_DIR/"
echo ""
echo "Next steps:"
echo "  1. cd $WORKSPACE_DIR"
echo "  2. claude"
echo "  3. Ask Claude: «Проведём первую стратегическую сессию»"
echo ""
echo "Strategist will run automatically:"
echo "  - Morning ($TIMEZONE_DESC): strategy (Mon) / day-plan (Tue-Sun)"
echo "  - Sunday night: week review"
echo ""
echo "Update from upstream:"
echo "  cd $TEMPLATE_DIR && bash update.sh"
echo ""
