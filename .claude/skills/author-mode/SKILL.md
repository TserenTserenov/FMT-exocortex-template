---
name: author-mode
description: "Инструкции для автора шаблона IWE: staging-канал (обкатка → FMT), авторские правила L3, Extensions Gate. Загружать при: staging / promote / author / шаблон / extensions / L3."
version: 1.0.0
layer: L1
status: active
browser_safe: false
triggers:
  slash: [/author-mode]
  phrases:
    - "staging"
    - "promote"
    - "author"
    - "author_mode"
    - "extensions gate"
    - "L3"
    - "авторское"
    - "шаблон FMT"
---

# /author-mode — Авторский режим IWE

> **Триггер:** staging / promote / author / шаблон / extensions  
> **Применимо:** только для автора шаблона (author_mode: true)

## §8. Staging (обкатка → шаблон)

> Правила на обкатке. Работают → переносятся в шаблон (L1).

### Staging-канал

**Правило добавления:** новое поведение в §9 (авторское) → ОДНОВРЕМЕННО строка в `STAGING.md` (`status: testing`).

**Промоция (при Week Close):**
1. Просмотреть `STAGING.md` → есть `testing`, готовое к промоции? Готовность («`validated`») означает не только «автор прогнал у себя» — правило должно пройти проверку минимум на одном НЕ-авторском профиле/пользователе шаблона (ADR-IWE-014 R8, тест замены носителя): личный путь/ключ/допущение автора, не переживающее эту замену, не готово к промоции — остаётся `testing` или уходит в `rejected`.
2. Убрать авторские константы → заменить на `{{PLACEHOLDER}}`
3. **Режим (ADR-IWE-014 R9, WP-552 Ф5):** спросить — обязательно для всех инсталляций шаблона, или отключаемое расширение маркетплейса? Ось ортогональна R8 и решается отдельно от готовности из шага 1. Отключаемое расширение → см. «Ветка "расширение маркетплейса"» ниже; обязательное правило шаблона → шаг 4 напрямую.
4. Перенести в `FMT-exocortex-template` + commit `feat: promote S-NN from staging`
5. Обновить `STAGING.md`: статус → `promoted`, колонка «Режим» → `обязательное` или `расширение`

**Отклонение:** специфичное для авторского окружения → статус `rejected` (остаётся в §9, не промотируется). Не удалять из таблицы — это решение.

**Ветка «расширение маркетплейса»:** `promote-common.sh` пишет запись не в `promotion-status.yaml`, а в `marketplace-manifest.yaml` — поля `type` (существующий тип артефакта: Pack, skill, `AR.NNN`, роль — новый тип не создаётся), `owner`, `install_point`, `permissions`, `toggleable`, `conflict_rule`, `staging_source` (ссылка на строку `STAGING.md` для аудируемости — какое правило и когда прошло тест R8).

## §9. Авторское (L3 — только мой IWE)

> Этот раздел — личный L3-слой. `update.sh` его **не трогает** при обновлении.  
> Добавляйте сюда правила и константы, актуальные только для вашего окружения.  
> Архитектура L1/L2/L3: `CONTRIBUTING.md §Three Layers`.

### Extensions Gate (БЛОКИРУЮЩЕЕ)

**Для пользователей:** кастомизация протоколов/скиллов → ТОЛЬКО в `extensions/*.md`.  
Прямое редактирование `.claude/skills/` или `memory/protocol-*.md` = ошибка.

**Архитектурное обоснование:** платформенные файлы (L1) и пользовательские расширения (L3) — разные слои. Смешение слоёв = хрупкость при обновлении.  
Разделение: платформенное → `FMT-exocortex-template` → `update.sh`. Пользовательское → `extensions/` + `params.yaml`.

**Автор (author_mode: true):** прямое редактирование L1 РАЗРЕШЕНО.  
Delivery в FMT: `bash $IWE_SCRIPTS/{script|hook|skill}-promote.sh <файл> [--dry-run]`  
CLAUDE.md: `bash $IWE_SCRIPTS/template-sync.sh` (sync / `--dry-run` / `--check`)

### Именование (плейсхолдеры)

- `{{GOVERNANCE_REPO}}` — личный governance-хаб
- `$HOME/IWE/` — рабочая директория

### Блокирующие (авторские)

> Заполнить специфичными для авторского окружения правилами.

### Различения (авторские)

> Хранятся в `memory/distinctions-warm.md` и `extensions/`. Файл `.claude/rules/distinctions.md` принадлежит платформенному hot-слою; `update.sh` сохраняет только явно размеченный `USER-SPACE` блок.

<!-- USER-SPACE -->
<!-- /USER-SPACE -->
