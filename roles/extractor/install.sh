#!/bin/bash
# Extractor: установка launchd-агента для inbox-check
# Запускает inbox-check каждые 3 часа.
# WP-273 Этап 2: plist берётся из $IWE_RUNTIME (Generated runtime, F).
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROLE_NAME="$(basename "$SCRIPT_DIR")"
PLIST_DST="$HOME/Library/LaunchAgents/com.extractor.inbox-check.plist"

# Resolve PLIST source (Generated runtime → workspace fallback → FMT legacy)
if [ -n "${IWE_RUNTIME:-}" ] && [ -d "$IWE_RUNTIME/roles/$ROLE_NAME/scripts/launchd" ]; then
    PLIST_SRC="$IWE_RUNTIME/roles/$ROLE_NAME/scripts/launchd/com.extractor.inbox-check.plist"
    SCRIPT_TARGET="$IWE_RUNTIME/roles/$ROLE_NAME/scripts/extractor.sh"
elif [ -n "${IWE_WORKSPACE:-}" ] && [ -d "$IWE_WORKSPACE/.iwe-runtime/roles/$ROLE_NAME/scripts/launchd" ]; then
    PLIST_SRC="$IWE_WORKSPACE/.iwe-runtime/roles/$ROLE_NAME/scripts/launchd/com.extractor.inbox-check.plist"
    SCRIPT_TARGET="$IWE_WORKSPACE/.iwe-runtime/roles/$ROLE_NAME/scripts/extractor.sh"
else
    PLIST_SRC="$SCRIPT_DIR/scripts/launchd/com.extractor.inbox-check.plist"
    SCRIPT_TARGET="$SCRIPT_DIR/scripts/extractor.sh"
    echo "  ⚠ Legacy mode: используются плейсхолдеры из FMT-substituted (запустите setup.sh ≥0.29.0 для архитектуры F)"
fi

echo "Installing Extractor launchd agent..."
echo "  PLIST_SRC: $PLIST_SRC"

# Проверяем что plist существует
if [ ! -f "$PLIST_SRC" ]; then
    echo "ERROR: $PLIST_SRC not found"
    exit 1
fi

# WP-273 R5 fix: fail-fast если plist содержит literal {{...}}
if grep -qE '\{\{[A-Z_]+\}\}' "$PLIST_SRC" 2>/dev/null; then
    echo "ERROR: $PLIST_SRC содержит незаменённые плейсхолдеры:" >&2
    grep -oE '\{\{[A-Z_]+\}\}' "$PLIST_SRC" | sort -u | sed 's/^/  /' >&2
    echo "" >&2
    echo "Возможные причины:" >&2
    echo "  1. IWE_RUNTIME не экспортирован → 'source ~/.zshenv' или 'source ~/.iwe-paths'" >&2
    echo "  2. .iwe-runtime/ ещё не создан → 'bash \$IWE_TEMPLATE/setup/build-runtime.sh'" >&2
    echo "  3. Старый clone до WP-273 Этап 2 → 'bash \$IWE_TEMPLATE/scripts/migrate-to-runtime-target.sh'" >&2
    exit 2
fi

# Делаем скрипт исполняемым (runtime path)
if [ -f "$SCRIPT_TARGET" ]; then
    chmod +x "$SCRIPT_TARGET"
fi

# Выгружаем старый агент (если есть)
launchctl unload "$PLIST_DST" 2>/dev/null || true

# Копируем plist
cp "$PLIST_SRC" "$PLIST_DST"

# Загружаем агент
launchctl load "$PLIST_DST"

echo "  ✓ Installed: com.extractor.inbox-check"
echo "  ✓ Interval: every 3 hours"
echo "  ✓ Logs: ~/logs/extractor/"
echo ""
echo "Verify: launchctl list | grep extractor"
echo "Uninstall: launchctl unload $PLIST_DST && rm $PLIST_DST"
