# session-record — автоматический захват записи стратегической сессии
# Extension: protocol-close / after
# see DP.SC.153 (условный auto-шаг, не блокирующий Close)

## Условие автозапуска

Выполнять ТОЛЬКО если одновременно:
1. Длительность сессии **>15 мин** (оценить по числу обменов / видимой работе)
2. Сессия содержит **маркеры стратегической работы** — хотя бы одно из:
   - упомянут или создан файл в `sessions/`
   - обсуждалась Strategy Session / стратсессия
   - затронуты РП из типа "strategy" / "planning"

Если условие **НЕ** выполнено → **noop**, молча пропустить (не анонсировать).

## Что делать при выполнении условия

1. Определить тему сессии по основному РП или доминирующей теме обсуждения (≤5 слов, kebab-case)
2. Определить каталог тем же `iwe_sessions_dir`, что использует диспетчер `/strategy-session`. `GOV_WT` — активная рабочая копия governance-репозитория, выбранная протоколом; если копия не создавалась, использовать корень governance-репозитория установки. Не подставлять репозиторий шаблона вместо governance.

```bash
GOV_WT="${GOV_WT:-{{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}}"
IWE_ROOT="${IWE_ROOT:-${IWE_WORKSPACE:-{{WORKSPACE_DIR}}}}"
case "${IWE_SESSIONS_ROOT:-}" in
  ""|/*) ;;
  *) IWE_SESSIONS_ROOT="$IWE_ROOT/$IWE_SESSIONS_ROOT" ;;
esac
if [ -n "${IWE_SESSIONS_ROOT:-}" ] && [ ! -d "$IWE_SESSIONS_ROOT" ]; then
  echo "ERROR: IWE_SESSIONS_ROOT недоступен: $IWE_SESSIONS_ROOT" >&2
  exit 1
fi
SESSIONS_DIR=$(
  GOVERNANCE_REPO="${GOVERNANCE_REPO:-${IWE_GOVERNANCE_REPO:-{{GOVERNANCE_REPO}}}}"
  source "${IWE_SCRIPTS:-{{IWE_TEMPLATE}}/scripts}/lib/common.sh" 2>/dev/null \
    || source "{{WORKSPACE_DIR}}/scripts/lib/common.sh" 2>/dev/null \
    || exit 1
  iwe_sessions_dir "$GOV_WT"
) || SESSIONS_DIR="${IWE_SESSIONS_ROOT:-$GOV_WT/sessions}"
mkdir -p -- "$SESSIONS_DIR" || exit 1
SESSION_RECORD="$SESSIONS_DIR/$(date +%F)-<тема>.md"
```

Приоритет каталогов: явно заданный `IWE_SESSIONS_ROOT`, затем `MC-sessions`, затем `$GOV_WT/sessions` для legacy-установки. Относительный `IWE_SESSIONS_ROOT` разрешается от корня установки, независимо от текущего каталога процесса. Если библиотека недоступна — существующий явный override либо `$GOV_WT/sessions`. Недоступный явный override — ошибка: сообщить о ней и пропустить запись, не создавать её в другом каталоге; сам Close это расширение не блокирует.

3. Создать запись по фактическому пути `$SESSION_RECORD`. Если файл уже существует — сначала прочитать его: дополнить запись той же сессии без потери прежнего содержания; при совпадении имени с другой сессией уточнить тему. В `session_type` выбрать ровно одно значение: `strategy` только для состоявшейся Strategy Session (initial/weekly/monthly), иначе `work`, `review` или `planning`. Это поле позволяет диспетчеру найти запись независимо от языка заголовка. Заполнить структуру:

```markdown
---
date: YYYY-MM-DD
session_type: strategy | work | review | planning
session_variant: weekly | monthly | initial  # только для session_type: strategy, иначе убрать
wp: WP-NNN  # основной РП (если один), иначе убрать
duration_estimate: Xh
---

# Стратегическая сессия YYYY-MM-DD — <тема>

## Контекст

[Откуда пришли: какие РП, какой этап]

## Достигнуто

[Что сделали / решили / создали — конкретные артефакты]

## Ключевые решения

[Если были архитектурные или стратегические решения — 1-3 строки на каждое]

## Следующий шаг

[Конкретное: что, где, кто]
```

4. Анонсировать сохранение записи и её фактический путь `$SESSION_RECORD`.
5. Определить репозиторий по каталогу записи (`git -C "$SESSIONS_DIR" rev-parse --show-toplevel`), включить в `git add` только этот файл и сохранить через штатный механизм публикации этого репозитория. Для `MC-sessions` это репозиторий журнала, для legacy — governance; текущий каталог процесса не определяет владельца файла. Если каталог не находится в Git-репозитории, оставить запись локально и сообщить об этом; не инициализировать репозиторий и не копировать запись в шаблон.
