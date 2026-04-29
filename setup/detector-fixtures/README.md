# Detector Regression Fixtures

> Назначение: regression samples для каждого detector в `setup/integration-contract-validator.sh`.
> Каждый sample — реальный паттерн, который ловился detector'ом в прошлом.
> Если detector regex регрессирует (как было с backtick+slash gap в 0.29.14) — `test-detectors.sh` поймает.

## Структура

- `detector_NN/positive_*.md` или `.sh` или `.py` — sample, который detector NN ДОЛЖЕН поймать
- `detector_NN/negative_*.md` — sample, который detector NN НЕ должен ловить (false-positive guard)

## Расширение

При добавлении нового detector'а или фиксе regex'а — положить sample в эту папку.
Test runner (`setup/test-detectors.sh`) автоматически прогонит на каждый коммит.

## История

| Detector | Fixture | Регрессия которая привела к появлению |
|----------|---------|---------------------------------------|
| #7 | `detector_07/positive_backtick_slash.md` | 0.29.13 → 0.29.14 — пропускался `` `DS-strategy/path` `` (backtick без пробела) |
