#!/bin/bash
# Cloud Scheduler (GitHub Actions) setup for IWE
# DP.SC.019 — Autonomous IWE operation (basic level)
#
# What it does:
# 1. Checks for the gh CLI and authorization
# 2. Configures GitHub Secrets for Telegram notifications (optional)
# 3. Runs a test workflow
#
# Usage:
#   bash setup/optional/setup-cloud-scheduler.sh
#
# Prerequisites:
# - gh CLI installed (brew install gh)
# - gh auth login done
# - The DS-strategy repo is pushed to GitHub

set -euo pipefail

echo "=== Настройка IWE Cloud Scheduler ==="
echo ""

# 1. Check the gh CLI
if ! command -v gh &>/dev/null; then
    echo "❌ gh CLI не установлен. Установите: brew install gh"
    exit 1
fi

if ! gh auth status &>/dev/null; then
    echo "❌ gh CLI не авторизован. Выполните: gh auth login"
    exit 1
fi

echo "✅ gh CLI готов"

# 2. Determine the DS-strategy repo
# Look for the first repo matching the DS-*strategy* pattern in the current workspace
WORKSPACE="${WORKSPACE_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
STRATEGY_DIR=$(find "$WORKSPACE" -maxdepth 1 -type d -name "DS-*strategy*" | head -1)

if [ -z "$STRATEGY_DIR" ]; then
    echo "❌ Не найден DS-strategy репо в $WORKSPACE"
    exit 1
fi

STRATEGY_REPO_NAME=$(cd "$STRATEGY_DIR" && gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || echo "")

if [ -z "$STRATEGY_REPO_NAME" ]; then
    echo "❌ Не удалось определить GitHub-репо для $STRATEGY_DIR"
    echo "   Убедитесь, что репо запушен на GitHub"
    exit 1
fi

echo "✅ Репо: $STRATEGY_REPO_NAME"

# 3. Check that the workflow exists
if ! gh workflow list --repo "$STRATEGY_REPO_NAME" 2>/dev/null | grep -q "cloud-scheduler"; then
    echo "⚠️  Workflow cloud-scheduler.yml не найден в $STRATEGY_REPO_NAME"
    echo "   Убедитесь, что файл .github/workflows/cloud-scheduler.yml существует и запушен"
    exit 1
fi

echo "✅ Workflow cloud-scheduler.yml найден"

# 4. Telegram notifications (optional)
echo ""
echo "--- Telegram-уведомления (опционально) ---"
echo "Для получения health check отчётов в Telegram нужны:"
echo "  - TELEGRAM_BOT_TOKEN (токен вашего бота)"
echo "  - TELEGRAM_CHAT_ID (ваш Telegram ID)"
echo ""
read -p "Настроить Telegram-уведомления? (y/n): " SETUP_TG

if [ "$SETUP_TG" = "y" ] || [ "$SETUP_TG" = "Y" ]; then
    read -p "Telegram Bot Token: " TG_TOKEN
    read -p "Telegram Chat ID: " TG_CHAT_ID

    if [ -n "$TG_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
        gh secret set TELEGRAM_BOT_TOKEN --repo "$STRATEGY_REPO_NAME" --body "$TG_TOKEN"
        gh secret set TELEGRAM_CHAT_ID --repo "$STRATEGY_REPO_NAME" --body "$TG_CHAT_ID"
        echo "✅ Telegram секреты установлены"
    else
        echo "⚠️  Пропущено — не все значения указаны"
    fi
else
    echo "⏭  Telegram пропущен"
fi

# 5. Test run
echo ""
read -p "Запустить тестовый workflow? (y/n): " RUN_TEST

if [ "$RUN_TEST" = "y" ] || [ "$RUN_TEST" = "Y" ]; then
    echo "Запускаю cloud-scheduler (health-check)..."
    gh workflow run cloud-scheduler.yml --repo "$STRATEGY_REPO_NAME" -f task=health-check

    echo "⏳ Ожидаю завершения..."
    sleep 5

    RUN_ID=$(gh run list --repo "$STRATEGY_REPO_NAME" --workflow=cloud-scheduler.yml --limit 1 --json databaseId -q '.[0].databaseId')
    gh run watch "$RUN_ID" --repo "$STRATEGY_REPO_NAME"

    echo ""
    echo "Логи:"
    gh run view "$RUN_ID" --repo "$STRATEGY_REPO_NAME" --log 2>&1 | grep -E "✅|⚠️|Коммит|DayPlan|WeekPlan|backup" || true
fi

echo ""
echo "=== Готово ==="
echo ""
echo "Cloud Scheduler будет запускаться ежедневно в 04:00 MSK (01:00 UTC)."
echo "Ручной запуск: gh workflow run cloud-scheduler.yml --repo $STRATEGY_REPO_NAME"
echo ""
echo "Подробности: DP.SC.019 (PACK-digital-platform/08-service-clauses/)"
