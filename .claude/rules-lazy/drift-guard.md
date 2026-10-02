# WP-REGISTRY drift guard — полная спецификация

> Hot-триггер: `${IWE_GOVERNANCE_REPO:-DS-strategy}/CLAUDE.md` § WP-REGISTRY drift guard. Этот файл — элаборация (WP-450 Ф1). Источник: peer-session 2026-06-01-21, `sessions/2026-06/2026-06-01-21-wp-registry-drift-guard/report.md`.

**БЛОКИРУЮЩЕЕ.** commit-msg хук блокирует commit при рассинхроне inbox ↔ docs/WP-REGISTRY.md.

**Триггеры блока:**
- Forward: изменён `inbox/WP-*.md` или `archive/wp-contexts/WP-*` без `docs/WP-REGISTRY.md` → commit-msg блок.
- Backward: изменён `docs/WP-REGISTRY.md` без `inbox/WP-*.md` или `archive/wp-contexts/WP-*` → commit-msg блок.

**Стандартный flow при закрытии РП:**
1. Обновить `inbox/WP-NNN/WP-NNN.md` (`status: done`, `closed_date`).
2. Обновить строку в `docs/WP-REGISTRY.md` (статус `✅`, strikethrough).
   - **Формат зачёркивания:** `| ~~430~~ | ~~P2~~ | ~~название~~ | ✅ | ~~репо~~ | ~~бюджет~~ |`
   - Зачёркивать: номер, проект, репо, бюджет. **Не зачёркивать:** название (`~~` уже на нём), статус ✅.
   - Автопроверка: `python3 scripts/check-wp-format.py docs/WP-REGISTRY.md`
   - Массовое исправление: `bash scripts/fix-strikethrough.sh`
3. Перегенерация `current/active-wp.md` — скрипт живёт внутри `FMT-exocortex-template/scripts/build-active-wp.py` (в governance-репо копии нет, issue #905); запускать оттуда или через `scripts/create-wp.sh`'ный двухместный резолвер (сначала `${IWE_GOVERNANCE_REPO:-DS-strategy}/scripts/`, затем `FMT-exocortex-template/scripts/`).
4. `git add` всех трёх файлов + commit.

**Exemption-tag `[no-registry-touch]`** — легитимный escape hatch для случаев:
- Typo / formatting fix в inbox-файле без изменения статуса.
- Frontmatter tag update (например, `priority` без status).
- Subfile внутри `inbox/WP-NNN/` (e.g. `inbox/WP-7/phase-2-notes.md`) при неизменном WP-7.md.
- Structural change в реестре (шапка, footer, ссылка на changelog).

Включить в commit message: `feat(wp-NNN): fixup typo [no-registry-touch]`.

**Аудит exemption-tag** — Week Close считает использования за 7 дней. >2/неделю → флаг для расследования (incentive обхода). См. `${IWE:-$HOME/IWE}/extensions/week-close.after.md`.

**Periodic reconciliation:**
- Day Open: `--deep-check` (orphan detection) — informational, не блокирует.
- Week Close: `--semantic-check` (status vs placement) — informational, генерирует backlog.
