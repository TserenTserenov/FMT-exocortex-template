#!/usr/bin/env bash
# routing: utility  deterministic=true
# see DP.SC.159, DP.ROLE.059
# setup-extractor-feeders.sh — Onboarding скрипт для активации feeder-системы
# (WP-247 Ф-MULTI-SOURCE).
#
# Что делает:
#  1. Проверяет платформу (macOS/Linux)
#  2. Создаёт launchd plist (macOS) или systemd timer (Linux) для git-diff-feed
#  3. Включает git-templates для post-commit hook (одна команда)
#  4. Создаёт пустой fleeting-notes.md если его нет
#  5. Сообщает что включено
#
# Использование:
#   bash {{IWE_TEMPLATE}}/scripts/setup-extractor-feeders.sh
#   bash {{IWE_TEMPLATE}}/scripts/setup-extractor-feeders.sh --check  # только проверка
#   bash {{IWE_TEMPLATE}}/scripts/setup-extractor-feeders.sh --uninstall

set -euo pipefail

IWE_RUNTIME="${IWE_RUNTIME:-$HOME/IWE/.iwe-runtime}"
GOVERNANCE_REPO="${IWE_GOVERNANCE_REPO:-DS-strategy}"
EXTRACTOR_SH="$IWE_RUNTIME/roles/extractor/scripts/extractor.sh"
FLEETING="$HOME/IWE/$GOVERNANCE_REPO/inbox/fleeting-notes.md"

MODE="${1:-install}"

log() { echo "[setup-extractor] $*"; }
ok() { echo "  ✅ $*"; }
warn() { echo "  ⚠️  $*"; }
fail() { echo "  ❌ $*"; }

# === 1. Проверки ===

log "1/4 Проверка зависимостей"

if [ ! -x "$EXTRACTOR_SH" ]; then
    fail "extractor.sh не найден в $EXTRACTOR_SH — запустите update.sh"
    exit 1
fi
ok "extractor.sh найден"

if ! command -v claude >/dev/null 2>&1; then
    fail "claude CLI не установлен (https://docs.anthropic.com/en/docs/claude-code)"
    exit 1
fi
ok "claude CLI: $(command -v claude)"

PLATFORM=$(uname -s)
case "$PLATFORM" in
    Darwin)  log "Платформа: macOS (используем launchd)";;
    Linux)   log "Платформа: Linux (используем systemd --user)";;
    *)       fail "Неподдерживаемая платформа: $PLATFORM"; exit 1;;
esac

# === 2. Git-templates (post-commit hook) ===

log "2/4 Git-templates для post-commit hook"

GIT_TEMPLATES="$HOME/.git-templates"
TEMPLATE_HOOK="$GIT_TEMPLATES/hooks/post-commit"

if [ "$MODE" = "--check" ]; then
    if [ -f "$TEMPLATE_HOOK" ] && grep -q "WP-247 Ф-TRIGGER-BASED" "$TEMPLATE_HOOK"; then
        ok "post-commit hook в git-templates установлен"
    else
        warn "post-commit hook не установлен — запустите без --check"
    fi
elif [ "$MODE" = "--uninstall" ]; then
    if [ -f "$TEMPLATE_HOOK" ]; then
        # Удаляем только наш блок
        sed -i.bak '/WP-247 Ф-TRIGGER-BASED/,/^fi$/d' "$TEMPLATE_HOOK"
        ok "post-commit hook (наш блок) удалён"
    fi
else
    mkdir -p "$GIT_TEMPLATES/hooks"
    if [ ! -f "$TEMPLATE_HOOK" ] || ! grep -q "WP-247 Ф-TRIGGER-BASED" "$TEMPLATE_HOOK"; then
        cp "$IWE_RUNTIME/scripts/post-commit-template.sh" "$TEMPLATE_HOOK" 2>/dev/null || \
        cat > "$TEMPLATE_HOOK" <<'HOOK'
#!/bin/bash
# post-commit hook — WP-247 Ф-TRIGGER-BASED
# При изменении inbox/captures.md или fleeting-notes.md → запускает extractor inbox-check
set -uo pipefail

# Load unified environment: WORKSPACE_DIR, IWE_ROOT, IWE_SCRIPTS, etc.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../../.claude/lib/iwe-env-bootstrap.sh" || exit 1
REPO_DIR=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
[[ "$REPO_DIR" != "$IWE_ROOT"* ]] && exit 0
REPO_NAME=$(basename "$REPO_DIR")
GOVERNANCE_REPO="${IWE_GOVERNANCE_REPO:-DS-strategy}"
if [ "$REPO_NAME" = "$GOVERNANCE_REPO" ]; then
    CHANGED=$(git diff-tree --no-commit-id -r --name-only HEAD 2>/dev/null | grep -E '^inbox/(captures|fleeting-notes)\.md$' || true)
    if [ -n "$CHANGED" ]; then
        EXTRACTOR_SH="$IWE_ROOT/.iwe-runtime/roles/extractor/scripts/extractor.sh"
        [ -x "$EXTRACTOR_SH" ] && (nohup "$EXTRACTOR_SH" inbox-check >/dev/null 2>&1 &) 2>/dev/null
    fi
fi
exit 0
HOOK
        chmod +x "$TEMPLATE_HOOK"
        ok "post-commit hook установлен в $TEMPLATE_HOOK"
        log "  Применить к существующим репо: cd <repo> && git init"
    else
        ok "post-commit hook уже установлен"
    fi
    git config --global init.templateDir "$GIT_TEMPLATES" || warn "не смог установить init.templateDir"
fi

# === 3. Cron для git-diff-feed (06:00 / 21:00) ===

log "3/4 Cron для git-diff-feed"

if [ "$PLATFORM" = "Darwin" ]; then
    PLIST="$HOME/Library/LaunchAgents/com.extractor.git-diff-feed.plist"
    if [ "$MODE" = "--check" ]; then
        if [ -f "$PLIST" ]; then ok "launchd plist установлен"; else warn "launchd plist не установлен"; fi
    elif [ "$MODE" = "--uninstall" ]; then
        if [ -f "$PLIST" ]; then launchctl unload "$PLIST" 2>/dev/null || true; rm "$PLIST"; ok "launchd plist удалён"; fi
    else
        cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>Label</key><string>com.extractor.git-diff-feed</string>
    <key>ProgramArguments</key>
    <array>
        <string>$EXTRACTOR_SH</string>
        <string>git-diff-feed</string>
        <string>12 hours ago</string>
    </array>
    <key>StartCalendarInterval</key>
    <array>
        <dict><key>Hour</key><integer>6</integer><key>Minute</key><integer>0</integer></dict>
        <dict><key>Hour</key><integer>21</integer><key>Minute</key><integer>0</integer></dict>
    </array>
    <key>StandardOutPath</key><string>$HOME/logs/extractor/launchd-git-diff-feed.log</string>
    <key>StandardErrorPath</key><string>$HOME/logs/extractor/launchd-git-diff-feed-error.log</string>
</dict></plist>
PLIST
        launchctl load "$PLIST" 2>/dev/null || warn "launchctl load failed (повторите вручную)"
        ok "launchd plist установлен в $PLIST"
    fi
elif [ "$PLATFORM" = "Linux" ]; then
    UNIT_DIR="$HOME/.config/systemd/user"
    mkdir -p "$UNIT_DIR"
    if [ "$MODE" = "--uninstall" ]; then
        rm -f "$UNIT_DIR/extractor-git-diff-feed.service" "$UNIT_DIR/extractor-git-diff-feed.timer"
        systemctl --user daemon-reload
        ok "systemd units удалены"
    elif [ "$MODE" != "--check" ]; then
        cat > "$UNIT_DIR/extractor-git-diff-feed.service" <<UNIT
[Unit]
Description=IWE Extractor: git-diff-feed (WP-247 Ф-MULTI-SOURCE.2)
[Service]
Type=oneshot
ExecStart=$EXTRACTOR_SH git-diff-feed "12 hours ago"
UNIT
        cat > "$UNIT_DIR/extractor-git-diff-feed.timer" <<TIMER
[Unit]
Description=IWE Extractor git-diff-feed schedule (06:00 + 21:00)
[Timer]
OnCalendar=*-*-* 06:00:00
OnCalendar=*-*-* 21:00:00
Persistent=true
[Install]
WantedBy=timers.target
TIMER
        systemctl --user daemon-reload
        systemctl --user enable --now extractor-git-diff-feed.timer
        ok "systemd timer установлен и активирован"
    fi
fi

# === 4. Fleeting-notes.md ===

log "4/4 Fleeting-notes inbox"

if [ "$MODE" != "--check" ] && [ "$MODE" != "--uninstall" ]; then
    if [ ! -f "$FLEETING" ]; then
        mkdir -p "$(dirname "$FLEETING")"
        cat > "$FLEETING" <<'FN'
# Fleeting Notes (быстрый inbox)

> Сюда падают быстрые мысли в течение дня. R2 (extractor) читает оба файла:
> `captures.md` (формализованные) и `fleeting-notes.md` (черновые).
> Маркеры `[analyzed]`/`[processed]`/`[duplicate]`/`[defer]` ставятся при обработке.

FN
        ok "Создан $FLEETING"
    else
        ok "fleeting-notes.md уже существует"
    fi
fi

# === Итог ===

echo ""
log "Готово."
log "Что включено (по результатам):"
log " - post-commit hook на изменения captures/fleeting-notes (для нового clone — git init)"
log " - cron 06:00 + 21:00 для git-diff-feed (на этой машине)"
log " - fleeting-notes.md inbox создан"
log ""
log "Что НЕ требует настройки (работает автоматически после update.sh):"
log " - regex fix в pending counter (WP-7 Ф-EXTRACTOR-FP)"
log " - inbox-check читает fleeting-notes как 2-й inbox (Ф-MULTI-SOURCE.3)"
log " - session-close-feed вызывается из Quick Close шаг 2.6 (Ф-MULTI-SOURCE.1)"
log ""
log "Проверка: $0 --check"
log "Удалить:  $0 --uninstall"
