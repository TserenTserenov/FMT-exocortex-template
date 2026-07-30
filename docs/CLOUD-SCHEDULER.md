# Cloud Scheduler (GitHub Actions)

IWE автоматика в облаке — работает даже когда Mac выключен. Базовый уровень: backup + health check. $0/мес.

**Сценарий:** [DP.SC.019](../PACK-digital-platform/pack/digital-platform/08-service-clauses/DP.SC.019-autonomous-cloud-runtime.md)

## Что делает

- **Backup memory:** ежедневно копирует `memory/` → `exocortex/` (git commit + push)
- **Health check:** проверяет наличие DayPlan, WeekPlan, свежесть backup, незакрытые сессии
- **Telegram-уведомления** (опционально): отправляет health report в Telegram

## Установка

```bash
bash setup/optional/setup-cloud-scheduler.sh
```

Скрипт проверит gh CLI, настроит секреты и запустит тестовый workflow.

## Ручная настройка

1. Убедитесь, что `.github/workflows/cloud-scheduler.yml` запушен в ваш DS-strategy репо
2. (Опционально) Настройте Telegram:
   ```bash
   gh secret set TELEGRAM_BOT_TOKEN --repo ВАШ_РЕПО --body "ТОКЕН"
   gh secret set TELEGRAM_CHAT_ID --repo ВАШ_РЕПО --body "ВАШ_ID"
   ```
3. Тестовый запуск: `gh workflow run cloud-scheduler.yml --repo ВАШ_РЕПО`

## Расписание

Ежедневно в 04:00 MSK (01:00 UTC): backup + health check.

## Files

| File | Purpose |
|------|---------|
| `cloud-scheduler.yml` | GitHub Actions workflow (backup + health check) |
| `setup-cloud-scheduler.sh` | Скрипт настройки (gh secrets + тест) |
