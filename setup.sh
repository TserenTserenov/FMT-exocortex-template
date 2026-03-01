#!/bin/bash
# Exocortex Setup Script
# Configures a forked FMT-exocortex-template: placeholders, memory, launchd, DS-strategy
#
# Usage:
#   bash setup.sh          # Полная установка (git + GitHub CLI + Claude Code + автоматизация)
#   bash setup.sh --core   # Минимальная установка (только git, без сети)
#
set -e

VERSION="0.4.0"
DRY_RUN=false
CORE_ONLY=false

# === Parse arguments ===
for arg in "$@"; do
    case "$arg" in
        --core)     CORE_ONLY=true ;;
        --dry-run)  DRY_RUN=true ;;
        --version)  echo "exocortex-setup v$VERSION"; exit 0 ;;
        --help|-h)
            echo "Usage: setup.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --core      Минимальная установка: только git, без сети (офлайн)"
            echo "  --dry-run   Показать что будет сделано, без изменений"
            echo "  --version   Версия скрипта"
            echo "  --help      Эта справка"
            echo ""
            echo "Режимы:"
            echo "  full (по умолчанию)  git + GitHub CLI + Claude Code + автоматизация Стратега"
            echo "  --core               git + любой AI CLI. Без GitHub, без launchd"
            exit 0
            ;;
    esac
done

if $CORE_ONLY; then
    echo "=========================================="
    echo "  Exocortex Setup v$VERSION (core)"
    echo "=========================================="
else
    echo "=========================================="
    echo "  Exocortex Setup v$VERSION"
    echo "=========================================="
fi
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
    local required="${4:-true}"
    if command -v "$cmd" >/dev/null 2>&1; then
        echo "  ✓ $name: $(command -v "$cmd")"
    else
        if [ "$required" = "true" ]; then
            echo "  ✗ $name: NOT FOUND"
            echo "    Install: $install_hint"
            PREREQ_FAIL=1
        else
            echo "  ○ $name: не установлен (опционально)"
            echo "    Install: $install_hint"
        fi
    fi
}

# Git — обязателен всегда
check_command "git" "Git" "xcode-select --install"

if $CORE_ONLY; then
    echo ""
    echo "  Режим --core: проверяются только обязательные зависимости (git)."
    echo "  GitHub CLI, Node.js, Claude Code — не требуются."
else
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
fi

echo ""

if [ "$PREREQ_FAIL" -eq 1 ]; then
    echo "ERROR: Prerequisites check failed. Install missing tools and try again."
    exit 1
fi

# === Collect configuration ===
read -p "GitHub username (или Enter для пропуска): " GITHUB_USER
GITHUB_USER="${GITHUB_USER:-your-username}"

read -p "Workspace directory [$(dirname "$TEMPLATE_DIR")]: " WORKSPACE_DIR
WORKSPACE_DIR="${WORKSPACE_DIR:-$(dirname "$TEMPLATE_DIR")}"
# Expand ~ to $HOME
WORKSPACE_DIR="${WORKSPACE_DIR/#\~/$HOME}"

if $CORE_ONLY; then
    # Core: используем defaults, не спрашиваем Claude-специфичные параметры
    CLAUDE_PATH="${AI_CLI:-claude}"
    TIMEZONE_HOUR="4"
    TIMEZONE_DESC="4:00 UTC"
else
    read -p "Claude CLI path [$(command -v claude || echo '/opt/homebrew/bin/claude')]: " CLAUDE_PATH
    CLAUDE_PATH="${CLAUDE_PATH:-$(command -v claude || echo '/opt/homebrew/bin/claude')}"

    read -p "Strategist launch hour (UTC, 0-23) [4]: " TIMEZONE_HOUR
    TIMEZONE_HOUR="${TIMEZONE_HOUR:-4}"

    read -p "Timezone description (e.g. '7:00 MSK') [${TIMEZONE_HOUR}:00 UTC]: " TIMEZONE_DESC
    TIMEZONE_DESC="${TIMEZONE_DESC:-${TIMEZONE_HOUR}:00 UTC}"
fi

HOME_DIR="$HOME"

# Compute Claude project slug: /Users/alice/Github → -Users-alice-Github
CLAUDE_PROJECT_SLUG="$(echo "$WORKSPACE_DIR" | tr '/' '-')"

echo ""
echo "Configuration:"
echo "  GitHub user:    $GITHUB_USER"
echo "  Workspace:      $WORKSPACE_DIR"
if $CORE_ONLY; then
    echo "  Mode:           core (offline)"
else
    echo "  Claude path:    $CLAUDE_PATH"
    echo "  Schedule hour:  $TIMEZONE_HOUR (UTC)"
    echo "  Time desc:      $TIMEZONE_DESC"
fi
echo "  Home dir:       $HOME_DIR"
echo "  Project slug:   $CLAUDE_PROJECT_SLUG"
echo ""

if $DRY_RUN; then
    echo "[DRY RUN] Would perform the following actions:"
    echo "  1. Substitute placeholders in all .md, .sh, .json, .plist, .yaml files"
    echo "  2. Copy CLAUDE.md → $WORKSPACE_DIR/CLAUDE.md"
    echo "  3. Copy memory/*.md → $HOME/.claude/projects/$CLAUDE_PROJECT_SLUG/memory/"
    if ! $CORE_ONLY; then
        echo "  4. Copy .claude/settings.local.json → $WORKSPACE_DIR/.claude/"
        echo "  5. Install Strategist launchd agent (Extractor + Synchronizer = optional)"
    fi
    echo "  6. Create DS-strategy repo ($(if $CORE_ONLY; then echo "local only"; else echo "+ GitHub"; fi))"
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
if $CORE_ONLY; then
    echo "[4/6] Claude settings... пропущено (--core)"
else
    echo "[4/6] Installing Claude settings..."
    mkdir -p "$WORKSPACE_DIR/.claude"
    if [ -f "$TEMPLATE_DIR/.claude/settings.local.json" ]; then
        cp "$TEMPLATE_DIR/.claude/settings.local.json" "$WORKSPACE_DIR/.claude/settings.local.json"
        echo "  Copied to $WORKSPACE_DIR/.claude/settings.local.json"
    else
        echo "  WARN: settings.local.json not found in template, skipping."
    fi
fi

# === 5. Install roles (autodiscovery via role.yaml) ===
if $CORE_ONLY; then
    echo "[5/6] Автоматизация... пропущена (--core)"
    echo "  Установить позже: см. $TEMPLATE_DIR/roles/ROLE-CONTRACT.md"
else
    echo "[5/6] Installing roles..."

    MANUAL_ROLES=()

    # Discover roles by role.yaml manifests (sorted by priority)
    for role_dir in "$TEMPLATE_DIR"/roles/*/; do
        [ -d "$role_dir" ] || continue
        role_yaml="$role_dir/role.yaml"
        [ -f "$role_yaml" ] || continue
        role_name=$(basename "$role_dir")

        if grep -q 'auto:.*true' "$role_yaml" 2>/dev/null; then
            # Auto-install role
            if [ -f "$role_dir/install.sh" ]; then
                chmod +x "$role_dir/install.sh"
                runner=$(grep '^runner:' "$role_yaml" | sed 's/runner: *//' | tr -d '"' | tr -d "'")
                [ -n "$runner" ] && chmod +x "$role_dir/$runner" 2>/dev/null || true
                bash "$role_dir/install.sh"
                echo "  ✓ $role_name installed"
            else
                echo "  WARN: $role_name/install.sh not found, skipping."
            fi
        else
            display=$(grep 'display_name:' "$role_yaml" 2>/dev/null | sed 's/display_name: *//' | tr -d '"')
            MANUAL_ROLES+=("  - ${display:-$role_name}: bash $role_dir/install.sh")
        fi
    done

    if [ ${#MANUAL_ROLES[@]} -gt 0 ]; then
        echo ""
        echo "  Additional roles (install later when ready):"
        printf '%s\n' "${MANUAL_ROLES[@]}"
        echo "  See: $TEMPLATE_DIR/roles/ROLE-CONTRACT.md"
    fi
fi

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

        if ! $CORE_ONLY; then
            # Create GitHub repo (full mode only)
            gh repo create "$GITHUB_USER/DS-strategy" --private --source=. --push 2>/dev/null || \
                echo "  GitHub repo DS-strategy already exists or creation skipped."
        else
            echo "  Локальный репозиторий создан. Для публикации на GitHub:"
            echo "    cd $MY_STRATEGY_DIR && gh repo create $GITHUB_USER/DS-strategy --private --source=. --push"
        fi
    else
        echo "  WARN: seed/strategy/ template not found. Creating minimal DS-strategy."
        mkdir -p "$MY_STRATEGY_DIR"/{current,inbox,archive/wp-contexts,docs,exocortex}
        cd "$MY_STRATEGY_DIR"
        git init
        git add -A
        git commit -m "Initial exocortex: DS-strategy governance hub (minimal)"

        if ! $CORE_ONLY; then
            gh repo create "$GITHUB_USER/DS-strategy" --private --source=. --push 2>/dev/null || \
                echo "  GitHub repo DS-strategy already exists or creation skipped."
        fi
    fi
fi

# === Done ===
echo ""
echo "=========================================="
if $CORE_ONLY; then
    echo "  Setup Complete! (core)"
else
    echo "  Setup Complete!"
fi
echo "=========================================="
echo ""
echo "Verify installation:"
echo "  ✓ CLAUDE.md:   $WORKSPACE_DIR/CLAUDE.md"
echo "  ✓ Memory:      $CLAUDE_MEMORY_DIR/ ($(ls "$CLAUDE_MEMORY_DIR"/*.md 2>/dev/null | wc -l | tr -d ' ') files)"
echo "  ✓ DS-strategy: $MY_STRATEGY_DIR/"
echo "  ✓ Template:    $TEMPLATE_DIR/"
echo ""

if $CORE_ONLY; then
    echo "Next steps:"
    echo "  1. cd $WORKSPACE_DIR"
    echo "  2. Запустите ваш AI CLI (Claude Code, Codex, Aider, Continue.dev и др.)"
    echo "  3. Скажите: «Проведём первую стратегическую сессию»"
    echo ""
    echo "Переход на полную установку (GitHub + автоматизация):"
    echo "  bash $TEMPLATE_DIR/setup.sh"
    echo ""
else
    echo "Next steps:"
    echo "  1. cd $WORKSPACE_DIR"
    echo "  2. claude"
    echo "  3. Ask Claude: «Проведём первую стратегическую сессию»"
    echo ""
    echo "Strategist will run automatically:"
    echo "  - Morning ($TIMEZONE_DESC): strategy (Mon) / day-plan (Tue-Sun)"
    echo "  - Sunday night: week review"
    echo ""
fi
echo "Update from upstream:"
echo "  cd $TEMPLATE_DIR && bash update.sh"
echo ""
