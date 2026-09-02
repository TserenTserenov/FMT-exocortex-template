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

# WP-5 Ф46: the scheduled run is headless — warn now (not blocking) if Claude
# Code has no login at all, instead of a silent failure at the first 3h tick.
# The saved subscription token is picked up by extractor.sh load_env, so its
# presence counts even though `claude auth status` here does not see it.
if [ ! -f "$HOME/.secrets/claude_code_oauth_token" ] \
   && command -v claude >/dev/null 2>&1 \
   && ! claude auth status --json >/dev/null 2>&1; then
    echo "  ⚠ Claude Code не подключён — автоматический inbox-check не сможет войти."
    echo "    Выполните: bash \$IWE_TEMPLATE/roles/extractor/scripts/connect.sh"
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

# Skip on non-macOS or headless CI without launchctl
if ! command -v launchctl >/dev/null 2>&1; then
    if [[ "$(uname -s)" == "Linux" ]]; then
        if [ -n "${SETUP_CI:-}" ]; then
            echo "  ⊠ SETUP_CI: systemd activation skipped for $ROLE_NAME"
            exit 0
        fi

        source "$(cd "$SCRIPT_DIR/../lib" && pwd)/scheduler-cron.sh"

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

        mkdir -p "$HOME/logs/extractor"

        # issue #454: same functional bus probe as synchronizer/strategist
        # install.sh. iwe-extractor-inbox-check.timer is interval-based
        # (OnUnitActiveSec=3h, no OnCalendar), so there's nothing to parse —
        # "every 3 hours starting at :00" is the direct cron equivalent.
        if ! iwe_systemd_user_bus_ok; then
            echo "  ⚠ systemd --user недоступен (нет пользовательской сессионной шины — типично для WSL2/контейнера/сервера без активного логина)"
            echo "  Installing $ROLE_NAME via cron fallback (issue #454)..."
            iwe_install_cron_fallback "extractor" \
                "0 */3 * * * $(iwe_cron_env_prefix) $SCRIPT_TARGET inbox-check >> $HOME/logs/extractor/cron-inbox-check.log 2>&1"
            echo "  ✓ Installed via crontab. Verify: crontab -l | grep extractor.sh"
            echo "  ✓ Logs: ~/logs/extractor/"
            exit 0
        fi

        echo "Installing $ROLE_NAME systemd user service (Linux)..."
        SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
        mkdir -p "$SYSTEMD_USER_DIR"

        cp "$SYSTEMD_SRC"/*.service "$SYSTEMD_SRC"/*.timer "$SYSTEMD_USER_DIR/"
        systemctl --user daemon-reload
        systemctl --user enable --now iwe-extractor-inbox-check.timer

        echo "  ✓ Installed: iwe-extractor-inbox-check.timer"
        echo "  ✓ Interval: every 3 hours"
        echo "  ✓ Logs: ~/logs/extractor/"
        echo ""
        echo "Verify: systemctl --user status iwe-extractor-inbox-check.timer"
        echo "Uninstall: systemctl --user disable --now iwe-extractor-inbox-check.timer && rm $SYSTEMD_USER_DIR/iwe-extractor-inbox-check.{service,timer}"
        exit 0
    fi
    echo "  ⊠ launchctl not available (non-macOS/Linux), skipping $ROLE_NAME install"
    exit 0
fi

mkdir -p "$(dirname "$PLIST_DST")"

# Выгружаем старый агент (если есть)
launchctl unload "$PLIST_DST" 2>/dev/null || true

# Копируем plist
cp "$PLIST_SRC" "$PLIST_DST"

# Загружаем агент
if [ -z "${SETUP_CI:-}" ]; then
    launchctl load "$PLIST_DST"
else
    echo "  ⊠ SETUP_CI: plist copied, launchctl activation skipped"
fi

echo "  ✓ Installed: com.extractor.inbox-check"
echo "  ✓ Interval: every 3 hours"
echo "  ✓ Logs: ~/logs/extractor/"
echo ""
echo "Verify: launchctl list | grep extractor"
echo "Uninstall: launchctl unload $PLIST_DST && rm $PLIST_DST"
