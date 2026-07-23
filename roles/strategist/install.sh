#!/bin/bash
# Install Strategist Agent launchd jobs
# WP-273 Этап 2: plists берутся из $IWE_RUNTIME (Generated runtime, F).
# Fallback на $SCRIPT_DIR/scripts/launchd/ — для старых установок до 0.29.0.
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROLE_NAME="$(basename "$SCRIPT_DIR")"
TARGET_DIR="$HOME/Library/LaunchAgents"

# Resolve LAUNCHD source (Generated runtime → workspace fallback → FMT legacy)
if [ -n "${IWE_RUNTIME:-}" ] && [ -d "$IWE_RUNTIME/roles/$ROLE_NAME/scripts/launchd" ]; then
    LAUNCHD_DIR="$IWE_RUNTIME/roles/$ROLE_NAME/scripts/launchd"
    SCRIPT_TARGET="$IWE_RUNTIME/roles/$ROLE_NAME/scripts/strategist.sh"
elif [ -n "${IWE_WORKSPACE:-}" ] && [ -d "$IWE_WORKSPACE/.iwe-runtime/roles/$ROLE_NAME/scripts/launchd" ]; then
    LAUNCHD_DIR="$IWE_WORKSPACE/.iwe-runtime/roles/$ROLE_NAME/scripts/launchd"
    SCRIPT_TARGET="$IWE_WORKSPACE/.iwe-runtime/roles/$ROLE_NAME/scripts/strategist.sh"
else
    # Legacy: substituted FMT (до WP-273 Этап 2)
    LAUNCHD_DIR="$SCRIPT_DIR/scripts/launchd"
    SCRIPT_TARGET="$SCRIPT_DIR/scripts/strategist.sh"
    echo "  ⚠ Legacy mode: используются плейсхолдеры из FMT-substituted (запустите setup.sh ≥0.29.0 для архитектуры F)"
fi

echo "Installing Strategist Agent launchd jobs..."
echo "  LAUNCHD_DIR: $LAUNCHD_DIR"

# WP-273 R5 fix (Round 5 Евгения): fail-fast если выбранный plist содержит literal {{...}}.
# Это предотвращает копирование незаменённых плейсхолдеров в ~/Library/LaunchAgents/
# (если IWE_RUNTIME не expanded, fallback падает на FMT с placeholder'ами).
for plist_check in "$LAUNCHD_DIR/com.strategist.morning.plist" "$LAUNCHD_DIR/com.strategist.weekreview.plist"; do
    if [ -f "$plist_check" ] && grep -qE '\{\{[A-Z_]+\}\}' "$plist_check" 2>/dev/null; then
        echo "ERROR: $plist_check содержит незаменённые плейсхолдеры:" >&2
        grep -oE '\{\{[A-Z_]+\}\}' "$plist_check" | sort -u | sed 's/^/  /' >&2
        echo "" >&2
        echo "Возможные причины:" >&2
        echo "  1. IWE_RUNTIME не экспортирован → 'source ~/.zshenv' или 'source ~/.iwe-paths'" >&2
        echo "  2. .iwe-runtime/ ещё не создан → 'bash \$IWE_TEMPLATE/setup/build-runtime.sh'" >&2
        echo "  3. Старый clone до WP-273 Этап 2 → 'bash \$IWE_TEMPLATE/scripts/migrate-to-runtime-target.sh'" >&2
        exit 2
    fi
done

# Skip on non-macOS or headless CI without launchctl
if ! command -v launchctl >/dev/null 2>&1; then
    if [[ "$(uname -s)" == "Linux" ]]; then
        echo "Installing $ROLE_NAME systemd user services (Linux)..."
        SYSTEMD_USER_DIR="$HOME/.config/systemd/user"

        if [ -n "${IWE_RUNTIME:-}" ] && [ -d "$IWE_RUNTIME/roles/$ROLE_NAME/scripts/systemd" ]; then
            SYSTEMD_SRC="$IWE_RUNTIME/roles/$ROLE_NAME/scripts/systemd"
        elif [ -n "${IWE_WORKSPACE:-}" ] && [ -d "$IWE_WORKSPACE/.iwe-runtime/roles/$ROLE_NAME/scripts/systemd" ]; then
            SYSTEMD_SRC="$IWE_WORKSPACE/.iwe-runtime/roles/$ROLE_NAME/scripts/systemd"
        else
            echo "ERROR: systemd units not found. Run setup.sh first." >&2
            exit 1
        fi

        if grep -qrE '\{\{[A-Z_]+\}\}' "$SYSTEMD_SRC" 2>/dev/null; then
            echo "ERROR: systemd units contain unsubstituted placeholders" >&2
            exit 2
        fi

        mkdir -p "$SYSTEMD_USER_DIR"
        mkdir -p "$HOME/logs/strategist"

        # issue #285 (same class of bug, Linux equivalent): пользователь мог явно
        # выключить таймер (`systemctl --user disable iwe-strategist-morning.timer`)
        # — `systemctl --user is-enabled` тогда вернёт "disabled" (не "not-found",
        # это отличает «выключено» от «ещё не установлено»). Безусловный re-enable
        # при каждом апдейте роли отменял бы выбор пользователя молча.
        for unit in iwe-strategist-morning iwe-strategist-weekreview; do
            if [ "$(systemctl --user is-enabled "$unit.timer" 2>/dev/null || true)" = "disabled" ]; then
                echo "  ⊘ $unit.timer — disabled by user, пропускаю (systemctl --user enable --now $unit.timer, чтобы включить обратно)"
                continue
            fi
            cp "$SYSTEMD_SRC/$unit.service" "$SYSTEMD_SRC/$unit.timer" "$SYSTEMD_USER_DIR/"
            systemctl --user daemon-reload
            systemctl --user enable --now "$unit.timer"
            echo "  ✓ Installed: $unit.timer"
        done
        echo "  ✓ Logs: ~/logs/strategist/"
        echo ""
        echo "Verify: systemctl --user list-timers | grep strategist"
        exit 0
    fi
    echo "  ⊠ launchctl not available (non-macOS/Linux), skipping $ROLE_NAME install"
    exit 0
fi

mkdir -p "$TARGET_DIR"

# Make script executable (runtime path)
if [ -f "$SCRIPT_TARGET" ]; then
    chmod +x "$SCRIPT_TARGET"
fi

# issue #285: пользователь отключает агента документированным способом
# (launchctl unload + переименование в <label>.plist.disabled — та же конвенция,
# что уже применяется к com.strategist.scout.plist.disabled). update.sh реагирует
# на изменения в roles/ и безусловно перезапускает install.sh каждой auto-роли —
# без этой проверки .disabled-маркер молча игнорировался, отключённый агент
# возвращался и перезагружался при каждом апдейте шаблона.
for label in com.strategist.morning com.strategist.weekreview; do
    if [ -f "$TARGET_DIR/$label.plist.disabled" ]; then
        echo "  ⊘ $label — disabled by user (найден $label.plist.disabled), пропускаю"
        continue
    fi
    launchctl unload "$TARGET_DIR/$label.plist" 2>/dev/null || true
    cp "$LAUNCHD_DIR/$label.plist" "$TARGET_DIR/"
    launchctl load "$TARGET_DIR/$label.plist"
done

echo "Done. Agents loaded:"
launchctl list | grep strategist
