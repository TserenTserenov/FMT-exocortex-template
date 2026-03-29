#!/bin/bash
# Exocortex Setup Script
# Configures a forked FMT-exocortex-template: placeholders, memory, launchd, DS-strategy
#
# Usage:
#   bash setup.sh          # Полная установка (git + GitHub CLI + Claude Code + автоматизация)
#   bash setup.sh --core   # Минимальная установка (только git, без сети)
#
set -e

VERSION="0.5.0"
DRY_RUN=false
CORE_ONLY=false
INSTALL_LEVEL=""  # T1/T2/T3/T4 — set by --level or interactive prompt

# === Cross-platform sed -i ===
# macOS sed requires '' after -i, GNU sed does not
if sed --version >/dev/null 2>&1; then
    # GNU sed (Linux)
    sed_inplace() { sed -i "$@"; }
else
    # BSD sed (macOS)
    sed_inplace() { sed -i '' "$@"; }
fi

# === Parse arguments ===
for arg in "$@"; do
    case "$arg" in
        --core)     CORE_ONLY=true ;;
        --dry-run)  DRY_RUN=true ;;
        --version)  echo "exocortex-setup v$VERSION"; exit 0 ;;
        --level=T1) INSTALL_LEVEL="T1" ;;
        --level=T2) INSTALL_LEVEL="T2" ;;
        --level=T3) INSTALL_LEVEL="T3" ;;
        --level=T4) INSTALL_LEVEL="T4" ;;
        --help|-h)
            echo "Usage: setup.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --level=T1  Минимум: Claude Code + экзокортекс (≤15 мин)"
            echo "  --level=T2  Стандарт: + ритуалы ОРЗ + extensions/"
            echo "  --level=T3  Рост: + Pack + бот"
            echo "  --level=T4  Полный: + роли + автоматизация (launchd)"
            echo "  --core      Офлайн-установка: только git, без сети"
            echo "  --dry-run   Показать что будет сделано, без изменений"
            echo "  --version   Версия скрипта"
            echo "  --help      Эта справка"
            echo ""
            echo "Без --level: интерактивный вопрос при запуске."
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
    echo "    gh repo fork TserenTserenov/FMT-exocortex-template --clone"
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

# === Select install level ===
if [ -z "$INSTALL_LEVEL" ] && ! $CORE_ONLY; then
    echo "Выбери уровень установки (можно добавить следующий уровень позже):"
    echo ""
    echo "  T1  Минимум      Claude Code + экзокортекс. Требует ≤15 мин."
    echo "  T2  Стандарт     + ритуалы ОРЗ (Day Open/Close, WeekPlan) + extensions/"
    echo "  T3  Рост         + Pack + бот (Telegram)"
    echo "  T4  Полный       + роли + launchd-автоматизация (Стратег, Синхронизатор)"
    echo ""
    while true; do
        read -p "Уровень [T2]: " INSTALL_LEVEL
        INSTALL_LEVEL="${INSTALL_LEVEL:-T2}"
        case "$INSTALL_LEVEL" in
            T1|T2|T3|T4) break ;;
            *) echo "  Введи T1, T2, T3 или T4." ;;
        esac
    done
    echo ""
elif $CORE_ONLY; then
    INSTALL_LEVEL="T1"
fi

echo "  Уровень: $INSTALL_LEVEL"
echo ""

# === Collect configuration ===
read -p "GitHub username (или Enter для пропуска): " GITHUB_USER
GITHUB_USER="${GITHUB_USER:-your-username}"

read -p "Имя вашего экзокортекс-репо [DS-exocortex]: " EXOCORTEX_REPO
EXOCORTEX_REPO="${EXOCORTEX_REPO:-DS-exocortex}"

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

# Compute Claude project slug: /Users/alice/IWE → -Users-alice-IWE
CLAUDE_PROJECT_SLUG="$(echo "$WORKSPACE_DIR" | tr '/' '-')"

echo ""
echo "Configuration:"
echo "  GitHub user:    $GITHUB_USER"
echo "  Exocortex repo: $EXOCORTEX_REPO"
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

# === Data Policy acceptance (skip in dry-run) ===
if ! $DRY_RUN; then
    echo "Data Policy"
    echo "  IWE collects and processes data as described in docs/DATA-POLICY.md"
    echo "  Summary: profile, sessions, and learning data are stored on the platform (Neon DB)."
    echo "  Your personal/ files stay local. Claude API receives prompts + profile context."
    echo "  You can view your data (/mydata) and delete it at any time."
    echo ""
    echo "  Full policy: docs/DATA-POLICY.md"
    echo ""
    read -p "I have read and agree to the Data Policy (y/n): " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Setup cancelled. Please review docs/DATA-POLICY.md first."
        exit 0
    fi
    echo ""

    read -p "Continue with setup? (y/n) " -n 1 -r
    echo ""
    [[ ! $REPLY =~ ^[Yy]$ ]] && exit 1
fi

# === Collect T3+ configuration (Knowledge Gateway) ===
# Secrets section: not substituted into template files, only read by Gateway scripts
ORY_TOKEN=""
L4_BACKEND=""
L4_DATABASE_URL=""
if ! $CORE_ONLY && ! $DRY_RUN; then
    case "$INSTALL_LEVEL" in T3|T4)
        echo "Knowledge Gateway (T3+):"
        echo "  Эти параметры используются для подключения личного Pack к платформе."
        echo "  Можно пропустить сейчас (Enter) и заполнить позже вручную в .exocortex.env"
        echo ""
        read -p "  ORY_TOKEN (токен платформы Aisystant, или Enter): " ORY_TOKEN
        if [ -n "$ORY_TOKEN" ]; then
            read -p "  L4_BACKEND [neon]: " L4_BACKEND
            L4_BACKEND="${L4_BACKEND:-neon}"
            read -p "  L4_DATABASE_URL (postgres://...): " L4_DATABASE_URL
        fi
        echo ""
        ;;
    esac
fi

# === Save configuration to .exocortex.env ===
ENV_FILE="$TEMPLATE_DIR/.exocortex.env"
if $DRY_RUN; then
    echo "[DRY RUN] Would save configuration to $ENV_FILE"
else
    cat > "$ENV_FILE" <<ENVEOF
# Exocortex configuration (generated by setup.sh v$VERSION)
# This file is read by update.sh to substitute placeholders after downloading upstream files.
# SECURITY: chmod 600. Listed in .gitignore. Do NOT commit this file.
# Do not add shell commands — only KEY=VALUE lines are allowed.

# === Core (substituted into template files) ===
GITHUB_USER=$GITHUB_USER
EXOCORTEX_REPO=$EXOCORTEX_REPO
WORKSPACE_DIR=$WORKSPACE_DIR
CLAUDE_PATH=$CLAUDE_PATH
CLAUDE_PROJECT_SLUG=$CLAUDE_PROJECT_SLUG
TIMEZONE_HOUR=$TIMEZONE_HOUR
TIMEZONE_DESC=$TIMEZONE_DESC
HOME_DIR=$HOME_DIR
INSTALL_LEVEL=$INSTALL_LEVEL

# === Knowledge Gateway (T3+, NOT substituted into files — read by Gateway scripts only) ===
# ORY_TOKEN: platform authentication token. Rotate manually if expired. update.sh preserves this value.
ORY_TOKEN=$ORY_TOKEN
# L4_BACKEND: personal knowledge backend (neon|supabase|sqlite)
L4_BACKEND=$L4_BACKEND
# L4_DATABASE_URL: connection string for personal Pack index (may contain '=' chars — safe to store here)
L4_DATABASE_URL=$L4_DATABASE_URL
ENVEOF
    chmod 600 "$ENV_FILE"
    echo "  Configuration saved to $ENV_FILE"
fi

# === Ensure workspace exists ===
if $DRY_RUN; then
    echo "[DRY RUN] Would create workspace: $WORKSPACE_DIR"
else
    mkdir -p "$WORKSPACE_DIR"
fi

# === 1. Substitute placeholders ===
echo ""
echo "[1/6] Configuring placeholders..."

if $DRY_RUN; then
    PLACEHOLDER_FILES=$(find "$TEMPLATE_DIR" -type f \( -name "*.md" -o -name "*.json" -o -name "*.sh" -o -name "*.plist" -o -name "*.yaml" -o -name "*.yml" \) | wc -l | tr -d ' ')
    echo "  [DRY RUN] Would substitute placeholders in $PLACEHOLDER_FILES files"
    echo "    {{GITHUB_USER}} → $GITHUB_USER"
    echo "    {{WORKSPACE_DIR}} → $WORKSPACE_DIR"
    echo "    {{CLAUDE_PATH}} → $CLAUDE_PATH"
    echo "    {{CLAUDE_PROJECT_SLUG}} → $CLAUDE_PROJECT_SLUG"
    echo "    {{TIMEZONE_HOUR}} → $TIMEZONE_HOUR"
    echo "    {{TIMEZONE_DESC}} → $TIMEZONE_DESC"
    echo "    {{HOME_DIR}} → $HOME_DIR"
else
    find "$TEMPLATE_DIR" -type f \( -name "*.md" -o -name "*.json" -o -name "*.sh" -o -name "*.plist" -o -name "*.yaml" -o -name "*.yml" \) | while IFS= read -r file; do
        sed_inplace \
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

    # Enable pre-commit hook for platform compatibility checks
    if [ -d "$TEMPLATE_DIR/.githooks" ]; then
        git -C "$TEMPLATE_DIR" config core.hooksPath .githooks 2>/dev/null && \
            echo "  Pre-commit hook enabled (.githooks/)" || true
    fi
fi

# === 1b. Rename repo (if name differs from FMT-exocortex-template) ===
CURRENT_DIR_NAME="$(basename "$TEMPLATE_DIR")"
if [ "$EXOCORTEX_REPO" != "$CURRENT_DIR_NAME" ]; then
    echo ""
    echo "[1b] Renaming repo: $CURRENT_DIR_NAME → $EXOCORTEX_REPO..."
    TARGET_DIR="$(dirname "$TEMPLATE_DIR")/$EXOCORTEX_REPO"

    if [ -d "$TARGET_DIR" ]; then
        echo "  WARN: $TARGET_DIR already exists. Skipping rename."
    elif $DRY_RUN; then
        echo "  [DRY RUN] Would rename: $TEMPLATE_DIR → $TARGET_DIR"
        if ! $CORE_ONLY && command -v gh >/dev/null 2>&1; then
            echo "  [DRY RUN] Would rename GitHub repo to $EXOCORTEX_REPO"
        fi
    else
        # Replace references in all text files
        find "$TEMPLATE_DIR" -type f \( -name "*.md" -o -name "*.json" -o -name "*.sh" -o -name "*.plist" -o -name "*.yaml" -o -name "*.yml" \) | while IFS= read -r file; do
            # Skip lines marked UPSTREAM-CONST (e.g., upstream repo URL in update.sh)
            if grep -q 'UPSTREAM-CONST' "$file" 2>/dev/null; then
                sed_inplace "/UPSTREAM-CONST/!s|$CURRENT_DIR_NAME|$EXOCORTEX_REPO|g" "$file"
            else
                sed_inplace "s|$CURRENT_DIR_NAME|$EXOCORTEX_REPO|g" "$file"
            fi
        done

        # Rename GitHub repo (if gh is available and not core mode)
        if ! $CORE_ONLY && command -v gh >/dev/null 2>&1; then
            gh repo rename "$EXOCORTEX_REPO" --yes 2>/dev/null && \
                echo "  ✓ GitHub repo renamed to $EXOCORTEX_REPO" || \
                echo "  ○ GitHub rename skipped (rename manually: gh repo rename $EXOCORTEX_REPO)"
        fi

        # Rename local directory
        mv "$TEMPLATE_DIR" "$TARGET_DIR"
        TEMPLATE_DIR="$TARGET_DIR"
        echo "  ✓ Local directory renamed to $EXOCORTEX_REPO"
    fi
else
    echo "  Repo name unchanged ($CURRENT_DIR_NAME)."
fi

# === 2. Copy CLAUDE.md to workspace root ===
echo "[2/6] Installing CLAUDE.md..."
if $DRY_RUN; then
    echo "  [DRY RUN] Would copy: $TEMPLATE_DIR/CLAUDE.md → $WORKSPACE_DIR/CLAUDE.md"
else
    cp "$TEMPLATE_DIR/CLAUDE.md" "$WORKSPACE_DIR/CLAUDE.md"
    # Save base copy for 3-way merge on future updates
    cp "$TEMPLATE_DIR/CLAUDE.md" "$TEMPLATE_DIR/.claude.md.base"
    cp "$TEMPLATE_DIR/CLAUDE.md" "$WORKSPACE_DIR/.claude.md.base"
    echo "  Copied to $WORKSPACE_DIR/CLAUDE.md (+ merge base)"
fi

# === 3. Copy memory to Claude projects directory ===
echo "[3/6] Installing memory..."
CLAUDE_MEMORY_DIR="$HOME/.claude/projects/$CLAUDE_PROJECT_SLUG/memory"
if $DRY_RUN; then
    MEM_COUNT=$(ls "$TEMPLATE_DIR/memory/"*.md 2>/dev/null | wc -l | tr -d ' ')
    echo "  [DRY RUN] Would copy $MEM_COUNT memory files → $CLAUDE_MEMORY_DIR/"
    if [ ! -e "$WORKSPACE_DIR/memory" ]; then
        echo "  [DRY RUN] Would create symlink: $WORKSPACE_DIR/memory → $CLAUDE_MEMORY_DIR"
    else
        echo "  WARN: $WORKSPACE_DIR/memory already exists, symlink would be skipped."
    fi
else
    mkdir -p "$CLAUDE_MEMORY_DIR"
    cp "$TEMPLATE_DIR/memory/"*.md "$CLAUDE_MEMORY_DIR/"
    echo "  Copied to $CLAUDE_MEMORY_DIR"

    # Create symlink so CLAUDE.md references (memory/protocol-open.md etc.) resolve from workspace root
    if [ ! -e "$WORKSPACE_DIR/memory" ]; then
        ln -s "$CLAUDE_MEMORY_DIR" "$WORKSPACE_DIR/memory"
        echo "  Symlink: $WORKSPACE_DIR/memory → $CLAUDE_MEMORY_DIR"
    else
        echo "  WARN: $WORKSPACE_DIR/memory already exists, symlink skipped."
    fi
fi

# === 4. Copy .claude settings ===
if $CORE_ONLY || [ "$INSTALL_LEVEL" = "T1" ]; then
    echo "[4/6] Claude settings... пропущено (уровень $INSTALL_LEVEL)"
else
    echo "[4/6] Installing Claude settings..."
    if $DRY_RUN; then
        if [ -f "$TEMPLATE_DIR/.claude/settings.local.json" ]; then
            echo "  [DRY RUN] Would copy: settings.local.json → $WORKSPACE_DIR/.claude/settings.local.json"
        else
            echo "  WARN: settings.local.json not found in template."
        fi
        echo "  [DRY RUN] Would show MCP setup instructions (claude.ai/settings/connectors)"
    else
        mkdir -p "$WORKSPACE_DIR/.claude"
        if [ -f "$TEMPLATE_DIR/.claude/settings.local.json" ]; then
            cp "$TEMPLATE_DIR/.claude/settings.local.json" "$WORKSPACE_DIR/.claude/settings.local.json"
            echo "  Copied to $WORKSPACE_DIR/.claude/settings.local.json"
        else
            echo "  WARN: settings.local.json not found in template, skipping."
        fi

        # MCP servers are managed through claude.ai connectors (not local CLI)
        echo "  MCP серверы подключаются через claude.ai:"
        echo ""
        echo "  1. Откройте https://claude.ai/settings/connectors"
        echo "  2. Добавьте: https://knowledge-mcp.aisystant.workers.dev/mcp"
        echo "  3. Добавьте: https://digital-twin-mcp.aisystant.workers.dev/mcp"
        echo "  4. Перезапустите Claude Code"
        echo ""
        echo "  После подключения проверьте командой /mcp в Claude Code."
    fi
fi

# === 4b. Propagate skills, hooks, rules to workspace ===
echo "[4b] Installing skills, hooks, rules..."
if $DRY_RUN; then
    echo "  [DRY RUN] Would copy .claude/skills/, .claude/hooks/, .claude/rules/ → $WORKSPACE_DIR/.claude/"
else
    mkdir -p "$WORKSPACE_DIR/.claude"
    for subdir in skills hooks rules; do
        if [ -d "$TEMPLATE_DIR/.claude/$subdir" ]; then
            cp -r "$TEMPLATE_DIR/.claude/$subdir" "$WORKSPACE_DIR/.claude/"
            echo "  ✓ .claude/$subdir/ → $WORKSPACE_DIR/.claude/$subdir/"
        fi
    done
    # Copy settings.json (project-level, not local)
    if [ -f "$TEMPLATE_DIR/.claude/settings.json" ]; then
        cp "$TEMPLATE_DIR/.claude/settings.json" "$WORKSPACE_DIR/.claude/settings.json"
        echo "  ✓ .claude/settings.json"
    fi
fi

# === 5. Install roles (autodiscovery via role.yaml) ===
if $CORE_ONLY || [ "$INSTALL_LEVEL" = "T1" ] || [ "$INSTALL_LEVEL" = "T2" ] || [ "$INSTALL_LEVEL" = "T3" ]; then
    echo "[5/6] Автоматизация... пропущена (уровень $INSTALL_LEVEL — нужен T4)"
    echo "  Установить позже: bash $TEMPLATE_DIR/setup.sh --level=T4"
elif ! command -v launchctl >/dev/null 2>&1; then
    echo "[5/6] Автоматизация... пропущена (launchd не найден — не macOS)"
    echo "  Роли используют launchd (macOS). На Linux используйте cron/systemd вручную."
    echo "  См. $TEMPLATE_DIR/roles/ROLE-CONTRACT.md"
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
                if $DRY_RUN; then
                    echo "  [DRY RUN] Would install role: $role_name (auto)"
                else
                    chmod +x "$role_dir/install.sh"
                    runner=$(grep '^runner:' "$role_yaml" | sed 's/runner: *//' | tr -d '"' | tr -d "'")
                    [ -n "$runner" ] && chmod +x "$role_dir/$runner" 2>/dev/null || true
                    bash "$role_dir/install.sh"
                    echo "  ✓ $role_name installed"
                fi
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
elif $DRY_RUN; then
    if [ -d "$STRATEGY_TEMPLATE" ]; then
        echo "  [DRY RUN] Would create DS-strategy from seed/strategy → $MY_STRATEGY_DIR"
        echo "  [DRY RUN] Would init git repo + initial commit"
        if ! $CORE_ONLY; then
            echo "  [DRY RUN] Would create GitHub repo: $GITHUB_USER/DS-strategy (private)"
        fi
    else
        echo "  [DRY RUN] Would create minimal DS-strategy (seed/strategy not found)"
    fi
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
        echo "  ERROR: seed/strategy/ not found. DS-strategy will be incomplete."
        echo "  Fix: re-clone the template and run setup.sh again."
        echo "  Creating minimal structure as fallback..."
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
if $DRY_RUN; then
    echo "=========================================="
    echo "  [DRY RUN] No changes made."
    echo "=========================================="
    echo ""
    echo "Run 'bash setup.sh' (without --dry-run) to apply."
else
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
    echo "  ✓ Symlink:     $WORKSPACE_DIR/memory → $CLAUDE_MEMORY_DIR"
    echo "  ✓ DS-strategy: $MY_STRATEGY_DIR/"
    echo "  ✓ Template:    $TEMPLATE_DIR/"
    echo ""

    echo "Next steps:"
    echo "  1. cd $WORKSPACE_DIR"
    if $CORE_ONLY || [ "$INSTALL_LEVEL" = "T1" ]; then
        echo "  2. Запустите ваш AI CLI (Claude Code, Codex, Aider, Continue.dev и др.)"
        echo "  3. Скажите: «Проведём первую стратегическую сессию»"
        echo ""
        echo "Следующий уровень (ритуалы ОРЗ + extensions):"
        echo "  bash $TEMPLATE_DIR/setup.sh --level=T2"
        echo ""
    elif [ "$INSTALL_LEVEL" = "T2" ]; then
        echo "  2. claude"
        echo "  3. Ask Claude: «Открывай» (Day Open)"
        echo ""
        echo "Следующий уровень (Pack + бот):"
        echo "  bash $TEMPLATE_DIR/setup.sh --level=T3"
        echo ""
    elif [ "$INSTALL_LEVEL" = "T3" ]; then
        echo "  2. claude"
        echo "  3. Ask Claude: «Открывай» (Day Open)"
        echo ""
        echo "Следующий уровень (роли + автоматизация):"
        echo "  bash $TEMPLATE_DIR/setup.sh --level=T4"
        echo ""
    else
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
fi
