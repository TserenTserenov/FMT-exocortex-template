#!/bin/bash
# Synchronizer: установка центрального диспетчера (launchd)
# Заменяет отдельные launchd-агенты Стратега единым scheduler
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROLE_NAME="$(basename "$SCRIPT_DIR")"
PLIST_DST="$HOME/Library/LaunchAgents/com.exocortex.scheduler.plist"

# Resolve PLIST source (Generated runtime → workspace fallback → FMT legacy).
# WP-273 Этап 2: substituted plists и runtime-скрипты живут в $IWE_RUNTIME.
if [ -n "${IWE_RUNTIME:-}" ] && [ -d "$IWE_RUNTIME/roles/$ROLE_NAME/scripts/launchd" ]; then
    PLIST_SRC="$IWE_RUNTIME/roles/$ROLE_NAME/scripts/launchd/com.exocortex.scheduler.plist"
    SCRIPTS_DIR_RUNTIME="$IWE_RUNTIME/roles/$ROLE_NAME/scripts"
elif [ -n "${IWE_WORKSPACE:-}" ] && [ -d "$IWE_WORKSPACE/.iwe-runtime/roles/$ROLE_NAME/scripts/launchd" ]; then
    PLIST_SRC="$IWE_WORKSPACE/.iwe-runtime/roles/$ROLE_NAME/scripts/launchd/com.exocortex.scheduler.plist"
    SCRIPTS_DIR_RUNTIME="$IWE_WORKSPACE/.iwe-runtime/roles/$ROLE_NAME/scripts"
else
    PLIST_SRC="$SCRIPT_DIR/scripts/launchd/com.exocortex.scheduler.plist"
    SCRIPTS_DIR_RUNTIME="$SCRIPT_DIR/scripts"
    echo "  ⚠ Legacy mode: используются плейсхолдеры из FMT-substituted (запустите setup.sh ≥0.29.0 для архитектуры F)"
fi

echo "Installing Synchronizer (central scheduler)..."
echo "  PLIST_SRC: $PLIST_SRC"

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

# Делаем скрипты исполняемыми (runtime path)
if [ -d "$SCRIPTS_DIR_RUNTIME" ]; then
    chmod +x "$SCRIPTS_DIR_RUNTIME/"*.sh 2>/dev/null || true
    chmod +x "$SCRIPTS_DIR_RUNTIME/templates/"*.sh 2>/dev/null || true
fi

# Skip on non-macOS or headless CI without launchctl
if ! command -v launchctl >/dev/null 2>&1; then
    if [[ "$(uname -s)" == "Linux" ]]; then
        echo "Installing $ROLE_NAME systemd user service (Linux)..."
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
        mkdir -p "$HOME/.local/state/exocortex"
        mkdir -p "$HOME/logs/synchronizer"

        cp "$SYSTEMD_SRC"/*.service "$SYSTEMD_SRC"/*.timer "$SYSTEMD_USER_DIR/"
        systemctl --user daemon-reload
        systemctl --user enable --now iwe-exocortex-scheduler.timer

        echo "  ✓ Installed: iwe-exocortex-scheduler.timer"
        echo "  ✓ Schedule: 10 dispatch points per day"
        echo "  ✓ State: ~/.local/state/exocortex/"
        echo "  ✓ Logs: ~/logs/synchronizer/"
        echo ""
        echo "Verify: systemctl --user list-timers | grep exocortex"
        echo "Status: bash $SCRIPTS_DIR_RUNTIME/scheduler.sh status"
        echo ""
        echo "Auto-wake (recommended): sudo rtcwake -m no -t \$(date -d 'tomorrow 03:55' +%s)"
        echo ""
        echo "Telegram (optional): create ~/.config/aist/env with:"
        echo "  export TELEGRAM_BOT_TOKEN=\"your-token\""
        echo "  export TELEGRAM_CHAT_ID=\"your-id\""
        exit 0
    fi
    echo "  ⊠ launchctl not available (non-macOS/Linux), skipping $ROLE_NAME install"
    exit 0
fi

mkdir -p "$(dirname "$PLIST_DST")"

# Выгружаем старые агенты
launchctl unload "$PLIST_DST" 2>/dev/null || true
# Выгружаем также legacy Стратег-агенты (если были)
launchctl unload "$HOME/Library/LaunchAgents/com.strategist.morning.plist" 2>/dev/null || true
launchctl unload "$HOME/Library/LaunchAgents/com.strategist.weekreview.plist" 2>/dev/null || true

# Создаём директории состояния
mkdir -p "$HOME/.local/state/exocortex"
mkdir -p "$HOME/logs/synchronizer"

# Копируем и загружаем
cp "$PLIST_SRC" "$PLIST_DST"
launchctl load "$PLIST_DST"

echo "  ✓ Installed: com.exocortex.scheduler"
echo "  ✓ Schedule: 10 dispatch points per day"
echo "  ✓ Manages: Strategist, Extractor, Code-Scan, Daily Report"
echo "  ✓ State: ~/.local/state/exocortex/"
echo "  ✓ Logs: ~/logs/synchronizer/"
echo ""
echo "Verify: launchctl list | grep exocortex"
echo "Status: bash $SCRIPTS_DIR_RUNTIME/scheduler.sh status"
echo ""
echo "Auto-wake (recommended): plan ready before you wake up"
if [[ "$(uname)" == "Darwin" ]]; then
    echo "  sudo pmset repeat wakeorpoweron MTWRFSU 03:55:00"
    echo "  sudo pmset -b sleep 0 && sudo pmset -b standby 0  # laptop: prevent sleep on battery profile"
    echo "  (Cancel: sudo pmset repeat cancel)"
else
    echo "  Linux: sudo rtcwake or systemd timer with WakeSystem=true"
    echo "  See docs/SETUP-GUIDE.md for details"
fi
echo ""
echo "Telegram (optional): create ~/.config/aist/env with:"
echo "  export TELEGRAM_BOT_TOKEN=\"your-token\""
echo "  export TELEGRAM_CHAT_ID=\"your-id\""
echo ""
echo "Uninstall: launchctl unload $PLIST_DST && rm $PLIST_DST"
