# Release Audit Log

> Adversarial post-release audits. Process: после каждого релиза auto-issue `Post-release adversarial audit: vX.Y.Z` сейчас мигрирует в эту таблицу. Триггер: `verify-before-promote.sh` warn gate при PASS-merge без записи в log.

## Назначение

Adversarial audit — субагент или внешний пилот ищет регрессии вне покрытия:
- 8 detectors (`integration-detectors.sh`)
- smoke 14 (`integration-smoke.sh`)
- promote-checks (`validate-fmt-scripts.sh`)

Любой найденный класс регрессий → новый detector в `integration-detectors.sh` (если воспроизводимо в CI) или smoke (если требует среды пилота).

## Process

```
release tag vX.Y.Z → auto-issue (legacy) | новая практика → запись здесь
```

| Поле | Описание |
|------|----------|
| `version` | Тег релиза (vX.Y.Z) |
| `status` | `pending` / `in-progress` / `completed` / `skipped-unverified` |
| `date` | Дата audit'а (YYYY-MM-DD) или `—` |
| `findings` | Количество находок или `—` |
| `result` | Cross-reference: PR/commit/issue с фиксами или `—` |
| `notes` | Источник migration или дополнительная инфо |

## Log

| Version | Status | Date | Findings | Result | Notes |
|---------|--------|------|----------|--------|-------|
| v0.34.1 | skipped-unverified | — | — | — | migrated from #133 |
| v0.34.0 | skipped-unverified | — | — | — | migrated from #130 |
| v0.33.x | skipped-unverified | — | — | — | migrated from #129, #127 |
| v0.32.x | skipped-unverified | — | — | — | migrated from #126, #123 |
| v0.31.x | skipped-unverified | — | — | — | migrated from #117 |
| v0.30.x | skipped-unverified | — | — | — | migrated from #55, #54 |
| v0.29.25 | skipped-unverified | — | — | — | migrated from #41 |
| v0.29.x (legacy) | skipped-unverified | — | — | — | migrated from #15, #16, #18, #21, #22, #27, #32, #43, #44, #45, #52, #53 |
| v0.29.x (round-2) | **completed** | 2026-05-06 | 40 | TESTING.md known limitations | confirmed via M1.6 #75 — 40 findings, all ✅ Fixed |

## Скрытое наблюдение из мигрированных issues

При spot-check мигрируемых issue (peer-session [2026-06-01-18](https://github.com/TserenTserenov/DS-my-strategy/tree/main/sessions/2026-06/2026-06-01-18-fmt-issues-triage-verify)) обнаружено: M-checklist #75 (M1.6) содержит подтверждение что **adversarial audit 2026-05-06 нашёл 40 findings и все они зафиксированы** (status: ✅ Fixed по C1-C4, H2, ...). То есть один из мигрированных аудитов был реально проведён — это не «skipped-unverified», это **completed без записи в публичный log**. Запись восстановлена в строке `v0.29.x (round-2)`.

## Дальнейшее использование

- Каждый новый релиз → строка в этой таблице (вместо auto-issue).
- `verify-before-promote.sh` warn-gate: при попытке промоушна без записи о предыдущем релизе — warning (не блок).
- Раз в квартал — review log: `skipped-unverified` старше 90 дней → принять решение (run-now / accept-debt / wontfix).

## Связанные

- `verify-before-promote.sh` — gate для record-keeping
- `integration-detectors.sh` — куда возвращаются находки audit'а
- `TESTING.md` — общая стратегия
- Peer-session [2026-06-01-18](https://github.com/TserenTserenov/DS-my-strategy/tree/main/sessions/2026-06/2026-06-01-18-fmt-issues-triage-verify) — миграция из 22 open issues
