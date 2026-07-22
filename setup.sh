#!/bin/bash
# Exocortex Setup Script
# Configures a forked FMT-exocortex-template: placeholders, memory, launchd, DS-strategy
#
# Usage:
#   bash setup.sh          # Полная установка (git + GitHub CLI + Claude Code + автоматизация)
#   bash setup.sh --core   # Минимальная установка (только git, без сети)
#
set -e

VERSION="0.7.0"  # WP-273 Этап 2: Generated runtime architecture (F)
DRY_RUN=false
CORE_ONLY=false
VALIDATE_ONLY=false
_MCP_AUTH_INCOMPLETE=false

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
        --validate)     VALIDATE_ONLY=true ;;
        --help|-h)
            echo "Usage: setup.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --validate  Проверить текущую установку (env, файлы, extensions, MCP)"
            echo "  --core      Офлайн-установка: только git, без сети"
            echo "  --dry-run   Показать что будет сделано, без изменений"
            echo "  --version   Версия скрипта"
            echo "  --help      Эта справка"
            exit 0
            ;;
    esac
done

# === Validate mode ===
if $VALIDATE_ONLY; then
    echo "=========================================="
    echo "  Exocortex Validate v$VERSION"
    echo "=========================================="
    echo ""
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    # WP-273 / issue #57: search order mirrors the write path in main setup mode.
    # 1. $IWE_ENV_PATH (explicit override via env or exocortex.env.example)
    # 2. $WORKSPACE_DIR/.exocortex.env (standard WP-273 location)
    # 3. parent-of-template heuristic (most common layout: ~/IWE/FMT-exocortex-template)
    # 4. legacy: inside SCRIPT_DIR (pre-WP-273 installs)
    WORKSPACE_GUESS="$(dirname "$SCRIPT_DIR")"
    if [ -n "${IWE_ENV_PATH:-}" ] && [ -f "$IWE_ENV_PATH" ]; then
        ENV_FILE="$IWE_ENV_PATH"
    elif [ -n "${WORKSPACE_DIR:-}" ] && [ -f "$WORKSPACE_DIR/.exocortex.env" ]; then
        ENV_FILE="$WORKSPACE_DIR/.exocortex.env"
    elif [ -f "$WORKSPACE_GUESS/.exocortex.env" ]; then
        ENV_FILE="$WORKSPACE_GUESS/.exocortex.env"
    else
        ENV_FILE="$SCRIPT_DIR/.exocortex.env"  # legacy fallback (pre-WP-273)
    fi
    ERRORS=0

    # Load .exocortex.env
    if [ -f "$ENV_FILE" ]; then
        echo "[1/4] Env-конфиг... ✓ .exocortex.env найден ($ENV_FILE)"
        # Safe read: grep KEY=VALUE, no eval/source (values may contain spaces)
        _env_get() { grep "^$1=" "$ENV_FILE" 2>/dev/null | head -1 | cut -d'=' -f2-; }
        # Check required keys
        for key in GITHUB_USER WORKSPACE_DIR; do
            val=$(_env_get "$key")
            if [ -z "$val" ]; then
                echo "  ✗ $key не задан"
                ERRORS=$((ERRORS + 1))
            fi
        done
    else
        echo "[1/4] Env-конфиг... ✗ .exocortex.env не найден"
        echo "  Запустите setup.sh для первичной настройки"
        ERRORS=$((ERRORS + 1))
    fi

    # Check required files
    echo "[2/4] Файлы..."
    CHECK_FILES="CLAUDE.md memory/MEMORY.md memory/protocol-open.md memory/protocol-close.md memory/protocol-work.md memory/navigation.md memory/roles.md"
    for f in $CHECK_FILES; do
        if [ -f "$SCRIPT_DIR/$f" ]; then
            echo "  ✓ $f"
        else
            echo "  ✗ $f отсутствует"
            ERRORS=$((ERRORS + 1))
        fi
    done

    # Check extensions
    echo "[3/4] Extensions..."
    if [ -d "$SCRIPT_DIR/extensions" ]; then
        EXT_COUNT=$(find "$SCRIPT_DIR/extensions" -name "*.md" 2>/dev/null | wc -l | tr -d ' ')
        echo "  ✓ extensions/ ($EXT_COUNT файлов)"
    else
        echo "  ⚠ extensions/ не найдена (опционально)"
    fi
    if [ -f "$SCRIPT_DIR/params.yaml" ]; then
        echo "  ✓ params.yaml"
    else
        echo "  ⚠ params.yaml не найден (опционально)"
    fi

    # Check MCP accessibility
    echo "[4/4] MCP-доступность..."
    echo "  MCP подключается через claude.ai/settings/connectors"
    echo "  Проверьте командой /mcp в Claude Code"

    # Delegate структурные инварианты валидатору шаблона (installed-режим:
    # пропускает чеки, легитимно нарушаемые после setup — /Users/, /opt/homebrew, MEMORY skeleton).
    # См. setup/validate-template.sh — единый источник чеков 1, 5, 6, 7.
    if [ -x "$SCRIPT_DIR/setup/validate-template.sh" ] || [ -f "$SCRIPT_DIR/setup/validate-template.sh" ]; then
        echo ""
        echo "[5/5] Структурные инварианты (delegate → validate-template.sh --mode=installed)..."
        if bash "$SCRIPT_DIR/setup/validate-template.sh" --mode=installed "$SCRIPT_DIR" 2>&1 | sed 's/^/  /'; then
            :
        else
            ERRORS=$((ERRORS + 1))
        fi
    fi

    echo ""
    if [ "$ERRORS" -eq 0 ]; then
        echo "✓ Валидация пройдена"
    else
        echo "✗ Найдено ошибок: $ERRORS"
    fi
    exit "$ERRORS"
fi

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

# jq — обязателен всегда: .claude/hooks/dry-run-gate.sh (устанавливается в любом режиме,
# см. шаг 4b) fail-closed блокирует ВСЕ tool calls без jq, без явного предупреждения (issue #192).
check_command "jq" "jq" "brew install jq (Linux: apt install jq / dnf install jq)"

if $CORE_ONLY; then
    echo ""
    echo "  Режим --core: проверяются только обязательные зависимости (git)."
    echo "  GitHub CLI, Node.js, Claude Code — не требуются."
else
    # В CI-режиме (SETUP_CI=1) node/npm/claude — необязательны: Test 10 проверяет delivery
    # и role-installation, а не наличие runtime-инструментов на машине.
    # Паттерн уже установлен для gh auth ниже (строка с SETUP_CI).
    _TOOL_REQUIRED="${SETUP_CI:+false}"; _TOOL_REQUIRED="${_TOOL_REQUIRED:-true}"
    check_command "gh" "GitHub CLI" "brew install gh" "$_TOOL_REQUIRED"
    check_command "node" "Node.js" "brew install node (or https://nodejs.org)" "$_TOOL_REQUIRED"
    check_command "npm" "npm" "Comes with Node.js" "$_TOOL_REQUIRED"
    # Multi-agent support: Claude Code, Kimi Code, Hermes — любой из них подходит
    AI_CLI_CANDIDATES="${AI_CLI_CANDIDATES:-claude kimi-code kimi hermes}"
    _AGENT_FOUND=false
    for _agent_cmd in $AI_CLI_CANDIDATES; do
        if command -v "$_agent_cmd" >/dev/null 2>&1; then
            echo "  ✓ AI Agent: $_agent_cmd ($(command -v "$_agent_cmd"))"
            _AGENT_FOUND=true
            break
        fi
    done
    if ! $_AGENT_FOUND; then
        if [ "${_TOOL_REQUIRED:-true}" = "true" ]; then
            echo "  ✗ AI Agent: не найден"
            echo "    Установи один из поддерживаемых агентов:"
            echo "      Claude Code: npm install -g @anthropic-ai/claude-code"
            echo "      Kimi Code:   расширение Kimi Code в VS Code"
            echo "      Hermes:      см. https://hermes-agent.nousresearch.com/"
            echo "    Или задай AI_CLI_CANDIDATES=<команда-агента> в окружении"
            echo "    Минимальная установка без агента: bash setup.sh --core"
            PREREQ_FAIL=1
        else
            echo "  ○ AI Agent: не найден (опционально)"
        fi
    fi

    # Check gh auth
    if command -v gh >/dev/null 2>&1; then
        if gh auth status >/dev/null 2>&1; then
            echo "  ✓ GitHub CLI: authenticated"
        else
            echo "  ⚠ GitHub CLI: not authenticated"
            if [ -z "${SETUP_CI:-}" ]; then
                echo "    Run: gh auth login"
                PREREQ_FAIL=1
            fi
        fi
    fi
fi

echo ""

if [ "$PREREQ_FAIL" -eq 1 ]; then
    echo "ERROR: Prerequisites check failed. Install missing tools and try again."
    exit 1
fi

# === Collect configuration ===
# SETUP_CI=1: non-interactive mode for smoke tests and CI.
# All values read from env vars; interactive prompts skipped.
if [ -n "${SETUP_CI:-}" ]; then
    GITHUB_USER="${GITHUB_USER:-smoke-test}"
    WORKSPACE_DIR="${WORKSPACE_DIR:-$(dirname "$TEMPLATE_DIR")}"
    WORKSPACE_DIR="${WORKSPACE_DIR/#\~/$HOME}"
    CLAUDE_PATH="${CLAUDE_PATH:-claude}"
    TIMEZONE_HOUR="${TIMEZONE_HOUR:-4}"
    TIMEZONE_DESC="${TIMEZONE_DESC:-4:00 UTC}"
    echo "  [CI] GITHUB_USER=$GITHUB_USER WORKSPACE_DIR=$WORKSPACE_DIR"
else
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
fi

HOME_DIR="$HOME"

# Compute Claude project slug: /Users/alice/IWE → -Users-alice-IWE
CLAUDE_PROJECT_SLUG="$(echo "$WORKSPACE_DIR" | tr '/' '-')"

# Auto-detect governance repo (used in placeholder substitution + .exocortex.env).
# Стратегия: (1) DS-strategy (default), (2) wildcard DS-*-strategy* (legacy/локальные имена).
# Если ни один не найден — default DS-strategy (будет создан при первом seed-ритуале).
GOVERNANCE_REPO=""
if [ -d "$WORKSPACE_DIR/DS-strategy" ]; then
    GOVERNANCE_REPO="DS-strategy"
fi
if [ -z "$GOVERNANCE_REPO" ]; then
    for d in "$WORKSPACE_DIR"/DS-*; do
        case "${d##*/}" in
            DS-*strategy*|DS-strategy)
                GOVERNANCE_REPO="${d##*/}"
                break
                ;;
        esac
    done
fi
GOVERNANCE_REPO="${GOVERNANCE_REPO:-DS-strategy}"

# IWE_TEMPLATE = путь к FMT-репо (где живёт setup.sh).
IWE_TEMPLATE_PATH="$TEMPLATE_DIR"

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

# === Data Policy acceptance (skip in dry-run and CI) ===
if ! $DRY_RUN && [ -z "${SETUP_CI:-}" ]; then
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

# === Save configuration to .exocortex.env ===
# WP-273 Этап 2: .exocortex.env живёт в $WORKSPACE_DIR/, не в FMT.
# FMT остаётся clean upstream (immutable). Все substituted значения генерируются
# build-runtime.sh в $WORKSPACE_DIR/.iwe-runtime/.
ENV_FILE="$WORKSPACE_DIR/.exocortex.env"
IWE_RUNTIME_PATH="$WORKSPACE_DIR/.iwe-runtime"
if $DRY_RUN; then
    echo "[DRY RUN] Would save configuration to $ENV_FILE"
else
    mkdir -p "$WORKSPACE_DIR"
    cat > "$ENV_FILE" <<ENVEOF
# Exocortex configuration (generated by setup.sh v$VERSION)
# This file is read by build-runtime.sh / update.sh to substitute placeholders.
# SECURITY: chmod 600. Listed in .gitignore. Do NOT commit this file.
# Do not add shell commands — only KEY=VALUE lines are allowed.

# === Core (substituted into runtime files via build-runtime.sh) ===
# issue #223: значения ВСЕГДА в кавычках — файл читается через `source`,
# непроцитированное значение с пробелом (напр. TIMEZONE_DESC=4:00 UTC)
# ломает sourcing: bash трактует хвост как команду ("UTC: command not found").
GITHUB_USER="$GITHUB_USER"
WORKSPACE_DIR="$WORKSPACE_DIR"
CLAUDE_PATH="$CLAUDE_PATH"
CLAUDE_PROJECT_SLUG="$CLAUDE_PROJECT_SLUG"
TIMEZONE_HOUR="$TIMEZONE_HOUR"
TIMEZONE_DESC="$TIMEZONE_DESC"
HOME_DIR="$HOME_DIR"
GOVERNANCE_REPO="$GOVERNANCE_REPO"
IWE_TEMPLATE="$IWE_TEMPLATE_PATH"
IWE_RUNTIME="$IWE_RUNTIME_PATH"

# === Platform LLM Proxy (optional own API key for unlimited usage) ===
PLATFORM_LLM_PROXY_URL=https://llm.aisystant.com/v1
# ANTHROPIC_API_KEY=  # Optional: own key for unlimited usage (Direct MCP mode)

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

# === 1. Build generated runtime (.iwe-runtime/) ===
# WP-273 Этап 2: substituted-файлы живут в $WORKSPACE_DIR/.iwe-runtime/
# (Generated runtime, F). FMT остаётся clean upstream — никаких sed по $TEMPLATE_DIR.
# Реестр overlay-файлов: .claude/runtime-overlay.yaml. Реализация: setup/build-runtime.sh.
echo ""
echo "[1/6] Building generated runtime..."

if $DRY_RUN; then
    bash "$TEMPLATE_DIR/setup/build-runtime.sh" --dry-run \
        --workspace "$WORKSPACE_DIR" --env-file "$ENV_FILE" 2>&1 | sed 's/^/  /'
else
    bash "$TEMPLATE_DIR/setup/build-runtime.sh" \
        --workspace "$WORKSPACE_DIR" --env-file "$ENV_FILE" 2>&1 | sed 's/^/  /'

    # Enable pre-commit hook for platform compatibility checks
    if [ -d "$TEMPLATE_DIR/.githooks" ]; then
        git -C "$TEMPLATE_DIR" config core.hooksPath .githooks 2>/dev/null && \
            echo "  Pre-commit hook enabled (.githooks/)" || true
    fi
fi

# (Repo rename removed — folder stays as FMT-exocortex-template)

# === 2. Copy CLAUDE.md to workspace root (with substitution) ===
# FMT/CLAUDE.md остаётся clean upstream (плейсхолдеры). В workspace/CLAUDE.md
# плейсхолдеры подставляются (single-file substitution, не sed по дереву).
# .base копии — substituted (для 3-way merge).
echo "[2/6] Installing CLAUDE.md..."
if $DRY_RUN; then
    echo "  [DRY RUN] Would copy: $TEMPLATE_DIR/CLAUDE.md → $WORKSPACE_DIR/CLAUDE.md (substituted)"
else
    cp "$TEMPLATE_DIR/CLAUDE.md" "$WORKSPACE_DIR/CLAUDE.md"
    sed_inplace \
        -e "s|{{GITHUB_USER}}|$GITHUB_USER|g" \
        -e "s|{{WORKSPACE_DIR}}|$WORKSPACE_DIR|g" \
        -e "s|{{CLAUDE_PATH}}|$CLAUDE_PATH|g" \
        -e "s|{{CLAUDE_PROJECT_SLUG}}|$CLAUDE_PROJECT_SLUG|g" \
        -e "s|{{TIMEZONE_HOUR}}|$TIMEZONE_HOUR|g" \
        -e "s|{{TIMEZONE_DESC}}|$TIMEZONE_DESC|g" \
        -e "s|{{HOME_DIR}}|$HOME_DIR|g" \
        -e "s|{{GOVERNANCE_REPO}}|$GOVERNANCE_REPO|g" \
        -e "s|{{IWE_TEMPLATE}}|$IWE_TEMPLATE_PATH|g" \
        -e "s|{{IWE_RUNTIME}}|$IWE_RUNTIME_PATH|g" \
        "$WORKSPACE_DIR/CLAUDE.md"
    # Save base copies for 3-way merge on future updates (substituted version)
    cp "$WORKSPACE_DIR/CLAUDE.md" "$WORKSPACE_DIR/.claude.md.base"
    cp "$WORKSPACE_DIR/CLAUDE.md" "$TEMPLATE_DIR/.claude.md.base"  # legacy compat for update.sh
    echo "  Copied to $WORKSPACE_DIR/CLAUDE.md (+ merge base, substituted)"
fi

# === 3. Copy memory to Claude projects directory ===
echo "[3/6] Installing memory..."
CLAUDE_MEMORY_DIR="$HOME/.claude/projects/$CLAUDE_PROJECT_SLUG/memory"
if $DRY_RUN; then
    MEM_COUNT=$(ls "$TEMPLATE_DIR/memory/"*.md 2>/dev/null | wc -l | tr -d ' ')
    YAML_COUNT=$(ls "$TEMPLATE_DIR/memory/"*.yaml "$TEMPLATE_DIR/memory/"*.yml 2>/dev/null | wc -l | tr -d ' ')
    echo "  [DRY RUN] Would copy $MEM_COUNT .md + $YAML_COUNT .yaml/.yml memory files → $CLAUDE_MEMORY_DIR/"
    if [ ! -e "$WORKSPACE_DIR/memory" ]; then
        echo "  [DRY RUN] Would create symlink: $WORKSPACE_DIR/memory → $CLAUDE_MEMORY_DIR"
    else
        echo "  WARN: $WORKSPACE_DIR/memory already exists, symlink would be skipped."
    fi
else
    mkdir -p "$CLAUDE_MEMORY_DIR"
    cp "$TEMPLATE_DIR/memory/"*.md "$CLAUDE_MEMORY_DIR/"
    # Deliver yaml/yml configs (e.g. day-rhythm-config.yaml) alongside .md files
    for f in "$TEMPLATE_DIR/memory/"*.yaml "$TEMPLATE_DIR/memory/"*.yml; do
        [ -f "$f" ] && cp "$f" "$CLAUDE_MEMORY_DIR/"
    done
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
if $CORE_ONLY; then
    echo "[4/6] Claude settings... пропущено (core mode)"
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

        # MCP knowledge servers connect through Gateway (OAuth auto-flow)
        echo "  Знаниевые MCP-серверы подключаются через Gateway (автоматически):"
        echo ""
        echo "  .mcp.json содержит iwe-knowledge → https://mcp.aisystant.com/mcp"
        echo "  T1-T2: при первом запуске откроется браузер (OAuth через Ory)."
        echo "  T3-T4: CLI-режим (IWE_TIER=T3 в env или tier: T3 в ~/.iwe/config.yaml)."
        echo "  Необходима подписка «Инженерия интеллекта» (ранее «Бесконечное развитие»)."
        echo "  После входа: /mcp в Claude Code."
    fi
fi

# === 4b. Propagate skills, hooks, rules, lib, config, detectors, scripts, styles to workspace ===
echo "[4b] Installing skills, hooks, rules, rules-lazy, lib, config, detectors, scripts, styles..."
if $DRY_RUN; then
    echo "  [DRY RUN] Would copy .claude/{skills,hooks,rules,rules-lazy,lib,config,detectors,scripts,agents,styles}/ → $WORKSPACE_DIR/.claude/"
else
    mkdir -p "$WORKSPACE_DIR/.claude"
    # lib/config/detectors — runtime dependencies капчер-шины (capture-bus.sh) и детекторов
    # scripts — требуется скиллами (напр. load-extensions.sh)
    # styles — дисциплина языковых стилей (WP-412)
    # rules-lazy — lazy-loaded rule expansions (role-prefixes-full), parity with update.sh
    for subdir in skills hooks rules rules-lazy lib config detectors scripts agents styles templates; do
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

# Resolves IWE_TIER: env var → ~/.iwe/config.yaml → default T1
check_user_tier() {
    [ -n "${IWE_TIER:-}" ] && { echo "$IWE_TIER"; return; }
    local cfg="${IWE_CONFIG:-$HOME/.iwe/config.yaml}"
    if [ -f "$cfg" ]; then
        local t; t=$(grep -E '^tier:' "$cfg" 2>/dev/null | head -1 | awk '{print $2}' | tr -d '"')
        [ -n "$t" ] && { echo "$t"; return; }
    fi
    echo "T1"
}

# === 4c. Copy .mcp.json to workspace ===
echo "[4c] Configuring .mcp.json..."

MCP_TEMPLATE="$TEMPLATE_DIR/.mcp.json"
MCP_DEST="$WORKSPACE_DIR/.mcp.json"
MCP_USER_EXT="$WORKSPACE_DIR/extensions/mcp-user.json"

if $DRY_RUN; then
    _IWE_TIER=$(check_user_tier)
    echo "  [DRY RUN] Would generate $MCP_DEST (tier=$_IWE_TIER)"
    case "$_IWE_TIER" in
        T3|T4) echo "    iwe-knowledge → https://mcp.aisystant.com/mcp (ict-token auth — требует IWE_ICT_TOKEN или ~/.iwe/config.yaml ict_token)" ;;
        *)     echo "    iwe-knowledge → https://mcp.aisystant.com/mcp (браузерный OAuth)" ;;
    esac
    if [ -f "$MCP_USER_EXT" ] && command -v jq >/dev/null 2>&1; then
        echo "  [DRY RUN] Would merge extensions/mcp-user.json into .mcp.json"
    fi
elif [ ! -f "$MCP_TEMPLATE" ]; then
    echo "  WARN: $MCP_TEMPLATE not found, skipping."
else
    _IWE_TIER=$(check_user_tier)
    _MCP_LOG="$WORKSPACE_DIR/logs/mcp-auth.log"
    mkdir -p "$WORKSPACE_DIR/logs" && touch "$_MCP_LOG"

    case "$_IWE_TIER" in
        T3|T4)
            # Resolve ict_ token: IWE_ICT_TOKEN env (primary) → ~/.iwe/config.yaml (best-effort)
            # config.yaml expected format: ict_token: "ict_VALUE"  (no inline comments, no spaces in value)
            _ICT_TOKEN="${IWE_ICT_TOKEN:-}"
            if [ -z "$_ICT_TOKEN" ]; then
                _cfg="${IWE_CONFIG:-$HOME/.iwe/config.yaml}"
                if [ -f "$_cfg" ]; then
                    _ICT_TOKEN=$(grep -E '^ict_token[[:space:]]*:' "$_cfg" 2>/dev/null | head -1 | \
                        sed 's/^[[:space:]]*ict_token[[:space:]]*:[[:space:]]*//' | \
                        tr -d '"' | tr -d "'" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                fi
            fi

            if [ -n "$_ICT_TOKEN" ]; then
                if jq -n \
                    --arg token "$_ICT_TOKEN" \
                    '{"mcpServers":{"iwe-knowledge":{"type":"http","url":"https://mcp.aisystant.com/mcp","headers":{"Authorization":("Bearer " + $token)}}}}' \
                    > "$MCP_DEST" 2>/dev/null; then
                    echo "  ✓ $MCP_DEST → iwe-knowledge (аутентифицирован, tier=$_IWE_TIER)"
                    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) setup tier=$_IWE_TIER mode=ict_token" >> "$_MCP_LOG"
                else
                    echo "  ✗ jq error generating .mcp.json (check jq is installed)"
                    _MCP_AUTH_INCOMPLETE=true
                    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) setup tier=$_IWE_TIER mode=jq_error" >> "$_MCP_LOG"
                fi
            else
                echo ""
                echo "  ✗ Tier=$_IWE_TIER — токен аутентификации не найден. .mcp.json не записан."
                echo "  ─────────────────────────────────────────────────────────────"
                echo "  Для активации T3-доступа к знаниям:"
                echo "  1. Напишите боту @aisystant_bot команду: /connect_external"
                echo "  2. Добавьте токен в ~/.iwe/config.yaml:"
                echo "     ict_token: \"ict_ВАШТОКЕН\""
                echo "     (или: export IWE_ICT_TOKEN=ict_ВАШТОКЕН && bash setup.sh)"
                echo "  ─────────────────────────────────────────────────────────────"
                _MCP_AUTH_INCOMPLETE=true
                echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) setup tier=$_IWE_TIER mode=missing_token" >> "$_MCP_LOG"
            fi
            ;;
        *)
            cp "$MCP_TEMPLATE" "$MCP_DEST"
            echo "  ✓ $MCP_DEST → iwe-knowledge (браузерный OAuth, tier=$_IWE_TIER)"
            echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) setup tier=$_IWE_TIER mode=browser" >> "$_MCP_LOG"
            ;;
    esac

    # Merge extensions/mcp-user.json if it exists and has content (skip if MCP_DEST was not written)
    if [ -f "$MCP_USER_EXT" ] && [ -f "$MCP_DEST" ]; then
        if command -v jq >/dev/null 2>&1; then
            USER_COUNT=$(jq '.mcpServers | length' "$MCP_USER_EXT" 2>/dev/null || echo "0")
            if [ "$USER_COUNT" -gt 0 ]; then
                MCP_MERGED=$(jq -s '.[0].mcpServers * .[1].mcpServers | {mcpServers: .}' "$MCP_DEST" "$MCP_USER_EXT" 2>/dev/null)
                if [ -n "$MCP_MERGED" ]; then
                    echo "$MCP_MERGED" > "$MCP_DEST"
                    echo "  ✓ Merged $USER_COUNT server(s) from extensions/mcp-user.json"
                fi
            fi
        else
            echo "  ○ jq not found — extensions/mcp-user.json merge skipped"
            echo "    Install jq: brew install jq"
        fi
    fi
fi

# === 4d. IWE environment variables (WP-219, DP.FM.009) ===
# Lookup-слой для путей к скриптам: протоколы и скиллы ссылаются на
# $IWE_SCRIPTS / $IWE_ROLES, а не на абсолютные пути. Перемещение скрипта
# ломает одну переменную, а не N протоколов.
#
# Source-of-truth: setup/install-iwe-paths.sh (WP-273 R5).
# Раньше блок дублировался здесь и в migrate-to-runtime-target.sh не было —
# при миграции ~/.iwe-paths не апгрейдился (R5.3 Евгения, 27 апр).
echo "[4d] Installing IWE environment variables..."

if $DRY_RUN; then
    bash "$TEMPLATE_DIR/setup/install-iwe-paths.sh" \
        --workspace "$WORKSPACE_DIR" --governance "$GOVERNANCE_REPO" --dry-run 2>&1 | sed 's/^/  /'
else
    bash "$TEMPLATE_DIR/setup/install-iwe-paths.sh" \
        --workspace "$WORKSPACE_DIR" --governance "$GOVERNANCE_REPO" 2>&1 | sed 's/^/  /'
    echo "  ℹ  Restart shell or run: source $HOME/.zshenv"
fi

# === 4e. Generate executor-catalog.yaml for task routing (issue #197) ===
# route-task.sh (DP.ROLE.059, Маршрутизатор) looks this up at
# ~/IWE/$GOVERNANCE_REPO/scripts/executor-catalog.yaml — without generating it on
# install, a fresh install has no catalog and route-task.sh always fails ("not found").
# Non-fatal on error: routing is a convenience feature, not a hard setup prerequisite
# (PyYAML availability etc. is already checked at consumption time in route-task.sh).
if $CORE_ONLY; then
    echo "[4e] executor-catalog.yaml... пропущено (core mode, нет агента для маршрутизации)"
elif $DRY_RUN; then
    echo "[DRY RUN] Would generate executor-catalog.yaml (IWE_GOVERNANCE_REPO=$GOVERNANCE_REPO)"
else
    echo "[4e] Generating executor-catalog.yaml..."
    if CATALOG_OUTPUT=$(IWE_GOVERNANCE_REPO="$GOVERNANCE_REPO" python3 "$TEMPLATE_DIR/scripts/generate-executor-catalog.py" 2>&1); then
        echo "$CATALOG_OUTPUT" | sed 's/^/  /'
    else
        echo "$CATALOG_OUTPUT" | sed 's/^/  /'
        echo "  ⚠ executor-catalog.yaml не сгенерирован — запусти вручную:"
        echo "    python3 $TEMPLATE_DIR/scripts/generate-executor-catalog.py"
    fi
fi

# === 4f. Regenerate hot-files.list for the actual governance repo (issue #294/#291) ===
# The repo ships hot-files.list pre-baked with the author's GOVERNANCE_REPO name —
# without regenerating here, verify-context-budget.sh reports MISSING on any install
# where GOVERNANCE_REPO differs from the author's.
if $DRY_RUN; then
    echo "[DRY RUN] Would regenerate hot-files.list (IWE_GOVERNANCE_REPO=$GOVERNANCE_REPO)"
else
    echo "[4f] Regenerating hot-files.list..."
    if HOTFILES_OUTPUT=$(IWE_ROOT="$WORKSPACE_DIR" IWE_GOVERNANCE_REPO="$GOVERNANCE_REPO" bash "$TEMPLATE_DIR/scripts/generate-hot-files-list.sh" 2>&1); then
        echo "$HOTFILES_OUTPUT" | sed 's/^/  /'
    else
        echo "$HOTFILES_OUTPUT" | sed 's/^/  /'
        echo "  ⚠ hot-files.list не пересобран — запусти вручную:"
        echo "    IWE_GOVERNANCE_REPO=$GOVERNANCE_REPO bash $TEMPLATE_DIR/scripts/generate-hot-files-list.sh"
    fi
fi

# === 5. Install roles (autodiscovery via role.yaml) ===
if $CORE_ONLY; then
    echo "[5/6] Автоматизация... пропущена (core mode)"
elif ! command -v launchctl >/dev/null 2>&1; then
    echo "[5/6] Автоматизация... пропущена (launchd не найден — не macOS)"
    echo "  Роли используют launchd (macOS). На Linux используйте cron/systemd вручную."
    echo "  См. $TEMPLATE_DIR/roles/ROLE-CONTRACT.md"
else
    echo "[5/6] Installing roles..."

    # Source $WORKSPACE_DIR/.iwe-paths — гарантирует IWE_RUNTIME / IWE_WORKSPACE / IWE_TEMPLATE
    # в env для role install.sh (тот же паттерн что в update.sh:836).
    # Без этого install.sh падает в legacy fallback и видит {{плейсхолдеры}}.
    [ -f "$WORKSPACE_DIR/.iwe-paths" ] && . "$WORKSPACE_DIR/.iwe-paths"

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

# === 7. Clone Base repos (ZP + FPF + SPF) ===
echo "[7/7] Installing Base repos (ZP, FPF, SPF)..."
if $CORE_ONLY; then
    echo "  пропущено (core mode)"
elif ! command -v gh >/dev/null 2>&1; then
    echo "  пропущено (gh CLI не найден)"
else
    clone_base_repo() {
        local name="$1"
        local gh_repo="$2"
        local dest="$WORKSPACE_DIR/$name"
        if [ -d "$dest/.git" ]; then
            echo "  ✓ $name: уже установлен ($dest)"
        elif $DRY_RUN; then
            echo "  [DRY RUN] Would clone $gh_repo → $dest (--depth=1)"
        else
            if gh repo clone "$gh_repo" "$dest" -- --depth=1 --quiet 2>/dev/null; then
                echo "  ✓ $name: клонирован ($dest)"
            else
                echo "  ⚠ $name: не удалось клонировать — проверьте сеть или доступ к $gh_repo"
                echo "    Клонировать вручную: gh repo clone $gh_repo $dest -- --depth=1"
            fi
        fi
    }

    clone_base_repo "ZP" "TserenTserenov/ZP"
    clone_base_repo "FPF" "ailev/FPF"
    clone_base_repo "SPF" "TserenTserenov/SPF"
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
    if $CORE_ONLY; then
        echo "  2. Запустите ваш AI CLI (Claude Code, Codex, Aider, Continue.dev и др.)"
        echo "  3. Скажите: «Проведём первую стратегическую сессию»"
    else
        echo "  2. claude"
        echo "  3. Ask Claude: «Проведём первую стратегическую сессию»"
        echo ""
        echo "Strategist will run automatically:"
        echo "  - Morning ($TIMEZONE_DESC): strategy (Mon) / day-plan (Tue-Sun)"
        echo "  - Sunday night: week review"
    fi
    echo ""
    echo "Developer onboarding (T4+) — single entry point:"
    echo "  cat docs/developer/README.md"
    echo ""
    echo "Update from upstream:"
    echo "  cd $TEMPLATE_DIR && bash update.sh"
    echo ""

    # === Post-install validation (WP-265 Ф8) ===
    # Не запускаем автоматически — это interactive prompt. Skip в --core (нет gh/claude).
    if ! $CORE_ONLY; then
        echo "Финальная проверка инсталляции (рекомендуется):"
        echo "  validate-режим setup.sh проверит: env-конфиг, обязательные файлы,"
        echo "  extensions, доступность MCP, структурные инварианты."
        echo ""
        read -p "Запустить проверку сейчас? (y/n) " -n 1 -r || true
        echo ""
        if [[ ${REPLY:-} =~ ^[Yy]$ ]]; then
            echo ""
            bash "$TEMPLATE_DIR/setup.sh" --validate
        else
            echo "Пропущено. Запустить позже: cd $TEMPLATE_DIR && bash setup.sh --validate"
        fi
        echo ""
    fi

    # === Final: MCP auth check ===
    if [ "${_MCP_AUTH_INCOMPLETE:-false}" = "true" ]; then
        echo ""
        echo "════════════════════════════════════════════════════════════════"
        echo "  ⚠ SETUP INCOMPLETE: T3/T4 MCP-аутентификация не настроена."
        echo "  Выполните шаги в секции [4c] выше и повторите: bash setup.sh"
        echo "════════════════════════════════════════════════════════════════"
        exit 1
    fi
fi
