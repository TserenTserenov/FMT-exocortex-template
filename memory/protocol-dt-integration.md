---
type: protocol
name: "Протокол интеграции цифрового двойника"
description: "DT Guide Prep + Consent Check для шагов 04/05a стратегической сессии"
horizon: warm
domains: [platform, personal-profile]
status: active
valid_from: 2026-06-02
owner: platform
schema_version: 1
---

# Протокол интеграции цифрового двойника

> Применяется на шагах 04 (dt-guide-prep) и 05a (consent-check) пошаговой стратегической сессии.
> Источник истины для consent: `learning.tracking_consent` (Neon).

---

## DT Guide Prep

### Артефакт

`context/session-context-YYYY-MM-DD.md` — файл, создаваемый перед сессией стратегирования.

### Формат

```markdown
---
date: YYYY-MM-DD
session_type: weekly | monthly
source: dt_read_digital_twin
generated_by: session-prep
---

# Контекст сессии YYYY-MM-DD

## Индикаторы (из ЦД)

| Индикатор | Значение | Тренд |
|-----------|----------|-------|
| ... | ... | ↑ ↓ → |

## Активные НЭП

| Код | Формулировка | Возраст | Движение |
|-----|-------------|---------|----------|
| ... | ... | Nd | +/- |

## Рекомендации Портного

- ...

## Carry-over из прошлой сессии

- ...
```

### Правила

1. **Источник:** только `dt_read_digital_twin` (Neon). Не дублировать вручную.
2. **TTL:** файл актуален 24ч. Перед использованием проверить `mtime`:
   - Если `> 24h` → пересоздать через `dt_read_digital_twin` → записать новый `context/session-context-*.md`
   - Если `≤ 24h` → использовать существующий
   - Если файла нет → создать через `dt_read_digital_twin`
3. **RLS:** файл содержит персональные данные → хранить в private-репо, не коммитить в публичный Pack.

---

## Consent Check

### Сценарии

| Сценарий | Условие | Действие |
|----------|---------|----------|
| **Granted** | `learning.tracking_consent = true` | Proceed: читать ЦД, генерировать `session-context`, использовать Портного |
| **Denied** | `learning.tracking_consent = false` | Skip DT-интеграцию. Сессия без Портного и ЦД. Предложить `/consent opt-in` в конце. |
| **Null** | `learning.tracking_consent IS NULL` | Запросить consent до начала DT-интеграции. Показать: что собирается, зачем, кто видит. |

### Поведение при Null

1. **Информирование:** показать пилоту:
   - Что собирается: activity_log, indicators, assessments
   - Зачем: персонализация Портного, калибровка сессий
   - Кто видит: только пилот + Platform Admin (RLS)
2. **Запрос:** «Согласен на tracking для персонализации? Да / Нет / Позже»
3. **Запись:** при «Да» → `learning.tracking_consent = true`; при «Нет» → `false`; при «Позже» → `null`, skip DT

### Поведение при Denied

- Не читать `dt_read_digital_twin`
- Не генерировать `session-context`
- Не использовать рекомендации Портного
- В конце сессии: мягкий reminder «Для персонализации можно включить /consent opt-in»

---

## Связи

- Роль Стратег (R1): использует этот протокол на шагах 04/05a
- Портной (tailor-mcp): источник рекомендаций при granted
- R28 Диагност: обновляет `learning.cp_assessments`, влияет на контекст
