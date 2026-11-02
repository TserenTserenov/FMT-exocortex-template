#!/usr/bin/env bash
# routing: utility  deterministic=true
# see DP.SC.159, DP.ROLE.059
# settings-promote.sh — registering a hook in the template's .claude/settings.json
#
# Adds a hook entry to the needed event with the correct $CLAUDE_PROJECT_DIR/ prefix.
# Idempotent: if the hook is already registered — does not duplicate.
#
# Usage:
#   bash settings-promote.sh <hook-name.sh> <event> [--matcher <pattern>] [--dry-run]
#
# Examples:
#   bash settings-promote.sh my-hook.sh Stop
#   bash settings-promote.sh my-hook.sh PreToolUse --matcher "Bash"
#   bash settings-promote.sh my-hook.sh UserPromptSubmit --dry-run
#
# Events: Stop | PreToolUse | PostToolUse | UserPromptSubmit | PreCompact

set -uo pipefail

HOOK_NAME="${1:-}"
EVENT="${2:-}"
MATCHER=""
DRY_RUN=false

shift 2 2>/dev/null || true
while [[ $# -gt 0 ]]; do
    case "$1" in
        --matcher) MATCHER="${2:-}"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        *) echo "Неизвестный флаг: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$HOOK_NAME" || -z "$EVENT" ]]; then
    echo "Использование: $0 <hook-name.sh> <event> [--matcher <pattern>] [--dry-run]" >&2
    echo "События: Stop | PreToolUse | PostToolUse | UserPromptSubmit | PreCompact" >&2
    exit 1
fi

IWE="${IWE_WORKSPACE:-$HOME/IWE}"
FMT_DIR="${IWE_TEMPLATE:-$IWE/FMT-exocortex-template}"
SETTINGS="$FMT_DIR/.claude/settings.json"
HOOK_PATH="\$CLAUDE_PROJECT_DIR/.claude/hooks/$HOOK_NAME"
HOOK_FILE="$FMT_DIR/.claude/hooks/$HOOK_NAME"

if [[ ! -f "$SETTINGS" ]]; then
    echo "❌ Не найден: $SETTINGS" >&2
    exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
    echo "❌ jq не установлен — необходим для работы" >&2
    exit 1
fi

echo "📌 Регистрация хука: $HOOK_NAME → $EVENT${MATCHER:+ [matcher: $MATCHER]}"

# Check: does the hook file exist in FMT?
# In --dry-run mode absence is a warning (skip side-effect check, dry-run contract).
# Without dry-run — fail: registering a hook with no body for real is pointless.
if [[ ! -f "$HOOK_FILE" ]]; then
    if $DRY_RUN; then
        echo "ℹ️  dry-run: файл хука $HOOK_FILE отсутствует (warning, проверка пропущена)"
    else
        echo "⚠ Файл хука не найден в FMT: $HOOK_FILE" >&2
        echo "  Сначала промотируй тело хука через hook-promote.sh" >&2
        exit 1
    fi
fi

# Idempotency: already registered?
existing=$(jq -r \
    --arg event "$EVENT" \
    --arg cmd "$HOOK_PATH" \
    '.hooks[$event][]?.hooks[]? | select(.command == $cmd) | .command' \
    "$SETTINGS" 2>/dev/null || true)
if [[ -n "$existing" ]]; then
    echo "✅ Уже зарегистрирован — дублирование пропущено."
    exit 0
fi

# Build the new entry
if [[ -n "$MATCHER" ]]; then
    NEW_ENTRY=$(jq -n \
        --arg cmd "$HOOK_PATH" \
        --arg matcher "$MATCHER" \
        '{"matcher": $matcher, "hooks": [{"type": "command", "command": $cmd}]}')
else
    NEW_ENTRY=$(jq -n \
        --arg cmd "$HOOK_PATH" \
        '{"hooks": [{"type": "command", "command": $cmd}]}')
fi

# Add to the needed event (create the array if absent)
UPDATED=$(jq \
    --arg event "$EVENT" \
    --argjson entry "$NEW_ENTRY" \
    '.hooks[$event] = (.hooks[$event] // []) + [$entry]' \
    "$SETTINGS")

if $DRY_RUN; then
    echo "--- dry-run: результат ---"
    echo "$UPDATED" | jq ".hooks[\"$EVENT\"]"
    echo "--- конец ---"
    exit 0
fi

# Validate JSON before writing
echo "$UPDATED" | jq . > /dev/null 2>&1 || { echo "❌ Результат невалидный JSON" >&2; exit 1; }

# Check the hook-path convention via validate-fmt-scripts.sh --settings-json.
# --settings-json runs only check 3 (settings.json) — does not touch scripts.
if ! bash "$FMT_DIR/scripts/validate-fmt-scripts.sh" --settings-json; then
    exit 1
fi

CHANGELOG_SCRIPT="$FMT_DIR/scripts/changelog-append.sh"
if [[ -f "$CHANGELOG_SCRIPT" ]]; then IWE_TEMPLATE="$FMT_DIR" bash "$CHANGELOG_SCRIPT"; fi

echo "✅ Зарегистрирован: $HOOK_PATH → $EVENT"
echo "Следующий шаг:"
echo "  cd $FMT_DIR && git add .claude/settings.json CHANGELOG.md && git commit -m 'feat: register $HOOK_NAME hook for $EVENT'"
