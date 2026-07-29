# Cloud Scheduler (GitHub Actions)

IWE automation in the cloud — runs even when your Mac is off. Base level: backup + health check. $0/month.

**Scenario:** [DP.SC.019](../PACK-digital-platform/pack/digital-platform/08-service-clauses/DP.SC.019-autonomous-cloud-runtime.md)

## What It Does

- **Backup memory:** copies `memory/` → `exocortex/` daily (git commit + push)
- **Health check:** verifies the presence of DayPlan and WeekPlan, checks backup freshness, and detects unclosed sessions
- **Telegram notifications** (optional): sends a health report to Telegram

## Installation

```bash
bash setup/optional/setup-cloud-scheduler.sh
```

The Script checks the gh CLI, configures secrets, and runs a test workflow.

## Manual Setup

1. Make sure `.github/workflows/cloud-scheduler.yml` is pushed to your DS-strategy repo
2. (Optional) Configure Telegram:
   ```bash
   gh secret set TELEGRAM_BOT_TOKEN --repo YOUR_REPO --body "TOKEN"
   gh secret set TELEGRAM_CHAT_ID --repo YOUR_REPO --body "YOUR_ID"
   ```
3. Test run: `gh workflow run cloud-scheduler.yml --repo YOUR_REPO`

## Schedule

Daily at 04:00 MSK (01:00 UTC): backup + health check.

## Files

| File | Purpose |
|------|---------|
| `cloud-scheduler.yml` | GitHub Actions workflow (backup + health check) |
| `setup-cloud-scheduler.sh` | Setup Script (gh secrets + test) |

