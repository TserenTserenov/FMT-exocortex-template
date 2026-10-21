#!/bin/bash
# Setup Cloud Scheduler (GitHub Actions) for IWE
# DP.SC.019 — Standalone operation IWE (base level)
#
# What it does:
# 1. Checks for the presence of gh CLI and authorization
# 2. Configures GitHub Secrets for Telegram-notifications (optional)
# 3. Runs a test workflow
#
# Usage:
#   bash setup/optional/setup-cloud-scheduler.sh
#
# Prerequisites:
# - gh CLI is installed (brew install gh)
# - gh auth login has been run
# - Repo DS-strategy has been pushed to GitHub

set -euo pipefail

echo "=== Setting up IWE Cloud Scheduler ==="
echo ""

# 1. Checking gh CLI
if ! command -v gh &>/dev/null; then
    echo "❌ gh CLI is not installed. Install it:. Install: brew install gh"
    exit 1
fi

if ! gh auth status &>/dev/null; then
    echo "❌ gh CLI is not authorized. Run:. Run: gh auth login"
    exit 1
fi

echo "✅ gh CLI is ready"

# 2. Determining the repo DS-strategy
# Looking for the first repo matching the pattern DS-strategy in the current workspace DS-*strategy* in the current workspace
WORKSPACE="${WORKSPACE_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
STRATEGY_DIR=$(find "$WORKSPACE" -maxdepth 1 -type d -name "DS-*strategy*" | head -1)

if [ -z "$STRATEGY_DIR" ]; then
    echo "❌ DS-strategy repo not found in DS-strategy repo in $WORKSPACE"
    exit 1
fi

STRATEGY_REPO_NAME=$(cd "$STRATEGY_DIR" && gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || echo "")

if [ -z "$STRATEGY_REPO_NAME" ]; then
    echo "❌ Could not determine GitHub-repo for $STRATEGY_DIR"
    echo "   Make sure, that the repo has been pushed to GitHub"
    exit 1
fi

echo "✅ Repo: $STRATEGY_REPO_NAME"

# 3. Checking for the presence of workflow
if ! gh workflow list --repo "$STRATEGY_REPO_NAME" 2>/dev/null | grep -q "cloud-scheduler"; then
    echo "⚠️  Workflow cloud-scheduler.yml not found in $STRATEGY_REPO_NAME"
    echo "   Make sure, that the file .github/workflows/cloud-scheduler.yml exists and has been pushed"
    exit 1
fi

echo "✅ Workflow cloud-scheduler.yml found"

# 4. Telegram-notifications (optional)
echo ""
echo "--- Telegram-notifications (optional) ---"
echo "To receive health check reports in Telegram you need:"
echo "  - TELEGRAM_BOT_TOKEN (your bot token)"
echo "  - TELEGRAM_CHAT_ID (your Telegram ID)"
echo ""
read -p "Configure Telegram-notifications? (y/n): " SETUP_TG

if [ "$SETUP_TG" = "y" ] || [ "$SETUP_TG" = "Y" ]; then
    read -p "Telegram Bot Token: " TG_TOKEN
    read -p "Telegram Chat ID: " TG_CHAT_ID

    if [ -n "$TG_TOKEN" ] && [ -n "$TG_CHAT_ID" ]; then
        gh secret set TELEGRAM_BOT_TOKEN --repo "$STRATEGY_REPO_NAME" --body "$TG_TOKEN"
        gh secret set TELEGRAM_CHAT_ID --repo "$STRATEGY_REPO_NAME" --body "$TG_CHAT_ID"
        echo "✅ Telegram secrets set"
    else
        echo "⚠️  Skipped — not all values provided"
    fi
else
    echo "⏭  Telegram skipped"
fi

# 5. Test run
echo ""
read -p "Run test workflow? (y/n): " RUN_TEST

if [ "$RUN_TEST" = "y" ] || [ "$RUN_TEST" = "Y" ]; then
    echo "Running cloud-scheduler (health-check)..."
    gh workflow run cloud-scheduler.yml --repo "$STRATEGY_REPO_NAME" -f task=health-check

    echo "⏳ Waiting for completion..."
    sleep 5

    RUN_ID=$(gh run list --repo "$STRATEGY_REPO_NAME" --workflow=cloud-scheduler.yml --limit 1 --json databaseId -q '.[0].databaseId')
    gh run watch "$RUN_ID" --repo "$STRATEGY_REPO_NAME"

    echo ""
    echo "Logs:"
    gh run view "$RUN_ID" --repo "$STRATEGY_REPO_NAME" --log 2>&1 | grep -E "✅|⚠️|Commit|DayPlan|WeekPlan|backup" || true
fi

echo ""
echo "=== Done ==="
echo ""
echo "Cloud Scheduler will run daily at 04:00 MSK (01:00 UTC)."
echo "Manual run: gh workflow run cloud-scheduler.yml --repo $STRATEGY_REPO_NAME"
echo ""
echo "Details: DP.SC.019 (PACK-digital-platform/08-service-clauses/)"
