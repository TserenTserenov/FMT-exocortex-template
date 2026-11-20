---
name: peer-conversation
description: Многотуровый диалог писателя (Claude) с одним или несколькими напарниками (любой набор из kimi/codex/hermes/claude-headless/grok) по задаче пилота (DP.SC.154). Ведёт turn-loop (2 участника) или round-loop (3+, WP-509), обнаруживает CONSENSUS/ESCALATE, после консенсуса — Decision Gate (зафиксировать vs реализовать → ревью → проверить → задеплоить), синтезирует report.md через Agent tool.
argument-hint: "<описание задачи> [--peer kimi|codex|hermes|claude|grok[,vendor2,...]] | --list | --interrupt <session_id> | --finalize <session_id>"
version: 1.8.0
layer: L1
status: active
browser_safe: false
triggers:
  slash: [/peer-conversation]
  phrases:
    - "начни peer-сессию"
    - "запусти диалог с Кими"
    - "запусти диалог с Codex"
    - "peer-сессия"
    - "скилл пир-беседа"
routing:
  executor: sonnet
  deterministic: false
agents: single
interaction: multi-step
gates_required: []
gates_enforced: []
gates_rationale: "операционный скилл не создаёт РП сам; при новой пир-сессии по существующему РП обязательна сверка контекста по memory/protocol-open.md §Сессия"
---

# Peer Conversation (DP.SC.154)

Задача: $ARGUMENTS

> **Архитектура:** я (Claude) = писатель всегда (Skill tool доступен только мне в этой сессии). Напарник(и) — параметр `--peer` (default `kimi`), список из одного или нескольких зарегистрированных вендоров (§0в). При 2+ напарниках (N>2 участников целиком) — расширение WP-509, см. §0в и §3р.
> Каждый напарник вызывается через свой `<vendor>-peer-adapter.sh` напрямую — Bash tool, stdin pipe. Общий контракт задаёт stdin, stdout и значения кодов 0–7, если адаптер их использует (§0в.1). **Напарнику запрещено писать файлы своими инструментами внутри `SESSION_DIR`** — только stdout (гонка file-write vs stdout-capture портит журнал, найдено WP-509 2026-07-30).
> `list_peer_statuses` (Local Gateway) — координация файлов, **не** проверка доступности напарника CLI.
> Gateway offline ≠ напарник недоступен.

---

## When to use

Многотуровый диалог писателя (Claude) с одним или несколькими напарниками (любой набор зарегистрированных вендоров — Kimi, Codex, Hermes, второй Claude-инстанс headless) по задаче пилота (DP.SC.154). При одном напарнике — turn-loop (пара реплик). При двух и более напарниках — round-loop (WP-509): каждый раунд высказывается каждый участник, с явной role-discovery фазой (раунды 0–2), валидацией реплик по 4 критериям, лимитом повторных вызовов и классификацией результата `agreed|partial|escalated|not-agreed`. Обнаруживает CONSENSUS/ESCALATE, после консенсуса — Decision Gate (зафиксировать vs реализовать → ревью → проверить → задеплоить), синтезирует report.md через Agent tool.

## Scope boundary — не подменяет решения, зарезервированные за пилотом (найдено 2026-07-07)

> Peer-сессия пригодна для: технических решений, дизайна, code review, поиска компромисса между подходами, подготовки кандидатов к решению.
> **НЕ пригодна** для решений, которые процесс явно закрепляет за человеком (например, R15 Валидатор в `/apply-captures` — accept/reject/defer кандидатов знания; R1 Стратег — приоритеты месяца). Согласие двух агентов между собой — не решение пилота, даже единогласное и хорошо обоснованное.
>
> Если задача внутри пир-сессии требует такого решения — писатель обязан остановиться и спросить пилота напрямую в текущем чате (не через turn-файл), прежде чем фиксировать результат. См. `.claude/skills/apply-captures/SKILL.md` раздел «R15 = живой пилот, не агент» и `${IWE_GOVERNANCE_REPO:-DS-strategy}/inbox/bugs/bug-2026-07-07-r15-decisions-bypassed-pilot.md` — прецедент, из-за которого добавлено это ограничение.
>
> **Это предупреждение само по себе не держит ограничение (найдено в Цехе 11-12.10.2026, пятый повтор одного класса ошибки за три месяца — 07.07, 24.07, 21.09, 11-12.10).** Текст читается один раз в начале скилла, а нарушение происходит на много шагов позже — на Шаге 3.6.1 (Implementation), когда согласие на Decision Gate (Шаг 3.5, вопрос о МЕТОДЕ/объёме — «зафиксировать или реализовать сейчас») молча принимается за решение по СОДЕРЖАНИЮ зарезервированного документа, которое пилоту не показывали. Механический стопор внутри самого шага реализации → см. «Гейт содержимого» в Шаге 3.6.1.

## Шаг 0. Режим

Определить режим из `$ARGUMENTS`:

- `--list` → прочитать ОПУБЛИКОВАННУЮ таблицу: `git -C "$SESSIONS_DIR" fetch -q origin main && git -C "$SESSIONS_DIR" show origin/main:./00-index.md` (`SESSIONS_DIR` — тем же общим выбором папки журнала, что в Шаге 1) (WP-526 Ф2; WP-484/585, 21.09: снапшотер публикует индекс из приватной копии и общий каталог не обновляет, поэтому файл в рабочем дереве может отставать на любое время; без сети читать `00-index.md` из рабочего дерева), вывести таблицу. Стоп.
- `--interrupt <id>` → перейти к **Шагу 5 (interrupt-режим)**. Стоп после.
- `--finalize <id>` → перейти к **Шагу 6 (finalize-режим)**. Стоп после.
- Иначе → новая сессия, продолжать к Шагу 0в.

**Шаг 0а. Родительский РП — читать карточку до позиции писателя (урок 27.05, WP-351).** Если тема сессии привязана к РП с context-файлом (`DS-strategy/inbox/WP-N/`): grep по теме в `WP-REGISTRY.md` → прочитать `inbox/WP-N/WP-N.md` целиком (первоисточник, не саммари Explore-агентов) ДО составления 00-writer.md; в 00-writer.md перечислить, какие требования родительского РП учтены. Родительский РП часто содержит зафиксированные ответы на «новые открытия» — без этого сессия тратит ходы на уже записанное.

---

## Шаг 0в. Выбор напарника(ов) (`--peer`)

> **Добавлено 2026-07-29** (АрхГейт: вариант «параметризовать» против «отдельный скилл на вендора» — эволюционируемость заблокировала копипаст, см. `sessions/2026-07/2026-07-29-*-wp401-peer-vendor.md`). **Расширено 2026-07-30 (WP-509):** список из N>1 напарников вместо одного.

Извлечь `--peer <vendor1,vendor2,...>` из `$ARGUMENTS` (через запятую, без пробелов). Нет флага → `PEER_VENDORS=(kimi)` (обратная совместимость с версией до 1.4.0). Один vendor без запятой → `PEER_VENDORS=(<vendor>)`, поведение идентично версии 1.4.0 — отдельного code path для одного напарника не заводить, `PEER_COUNT=${#PEER_VENDORS[@]}` управляет веткой (turn loop §3 при `PEER_COUNT==1`, round loop §3р при `PEER_COUNT>=2`).

**Реестр вендоров** (единственное место маппинга — OwnerIntegrity; новый вендор добавляется только здесь):

| `PEER_VENDOR` | Адаптер | `peer_agent` (meta.yaml) | Поддерживает `--add-dir` | Поддерживает `--model` | Особый флаг |
|---|---|---|---|---|---|
| `kimi` | `scripts/kimi-peer-adapter.sh` | `kimi-headless` | да, только как отфильтрованная inline-проекция | да | text-only agent |
| `codex` | `scripts/codex-peer-adapter.sh` | `codex` | да | да | — |
| `hermes` | `scripts/hermes-peer-adapter.sh` | `hermes` | **нет** | **нет** | `--session-id <id>` вместо |
| `claude` | `scripts/claude-peer-adapter.sh` | `claude-code-headless` | **нет** | да | text-only; контекст в stdin |
| `grok` | `scripts/grok-peer-adapter.sh` | `grok` | да, только как отфильтрованная копия (PII/.agentigore) | да | read-only: `--sandbox read-only`+`--tools ""` жёстко зашиты адаптером, не проброс |

**Grok (xAI) — принятые митигации (АрхГейт WP-530 Ф51, 18.09.2026).** Только read-only участник: адаптер не открывает/не коммитит сессии, `session-guard.sh` не расширялся под этого вендора. Пилот принял риск передачи контекста хода внешнему провайдеру с условием: (1) реплики Grok помечать как «непроверенный критик» на первых сессиях — ответственность писателя при показе пилоту, не механика адаптера; (2) тот же content-filter/.agentigore, что у остальных вендоров, без исключений — уже так (адаптер переиспользует те же шаблонные скрипты); (3) передавать только минимальный контекст хода, как остальным вендорам. Сбой применения `--sandbox read-only` при разрешении симлинка `/var/run/docker.sock` имел успешный смоук-тест 26.09.2026: адаптер вернул валидный ответ, но это подтверждает только тот запуск. 02.10.2026 сбой повторился в РП-516: адаптер завершился с кодом 1 до ответа, не ослабив защиту. Причина переменного поведения неизвестна. При таком отказе считать Grok недоступным и продолжать с доступными напарниками по §0в.2, не ослабляя песочницу; повторение оформить отдельным bug-файлом.

Каждый элемент `PEER_VENDORS` валидировать отдельно. Неизвестный `PEER_VENDOR` в списке → СТОП **на этом элементе, не на всём списке**: сообщить пилоту, какой конкретно vendor не распознан («Напарник `<vendor>` не зарегистрирован. Известные: kimi, codex, hermes, claude, grok.»), предложить продолжить с оставшимися распознанными или прервать целиком. Добавление нового вендора — правка таблицы выше + написание `<vendor>-peer-adapter.sh` по контракту §0в.1.

**§0в.1 Общий контракт адаптера** (для добавления нового вендора; WP-516 Ф4–Ф5). Общий контракт задаёт наблюдаемое поведение, а не командную строку конкретного CLI:

- **Запрос и ответ.** Адаптер читает весь stdin и передаёт модели его содержимое без молчаливого усечения; при лимите отказывает до вызова CLI с длиной запроса в stderr, без самого текста. В stdout при успехе — только одна реплика. Служебный баннер CLI, журнал и диагностика туда не попадают. Первая непустая строка peer-реплики — `---`, затем идёт закрывающий `---` и содержательное тело. Пустой после удаления пробелов ответ даёт код `1`; если адаптер реализует отдельную категорию `7`, она используется только для пустого ответа. Неверный frontmatter при непустом ответе даёт код `1`. Служебные вызовы писателя, которым не нужна peer-реплика, могут явно включить `IWE_PEER_PLAIN=1`; это исключение слоя интеграции, не режим обхода фильтрации.
- **Аргументы.** Максимальный межвендорский набор — `-p`, `--model <имя>`, `--add-dir <каталог>`; таблица §0в ограничивает поддержку конкретного вендора. Неизвестный или неподдержанный флаг отвергается с диагностикой; имя чужой модели отображается в поддерживаемое или явно отвергается. `--permission-mode` исключён: у вендоров нет общей безопасной семантики, а выбор вызывающим процессом может ослабить режим только чтения. Для `claude` по WP-458 запрещён и `--add-dir`.
- **Коды адаптера.** `0` — успешная реплика; `1` — общая ошибка, включая сбой/ненулевой код CLI, неверный формат, отказ CLI или превышение срока; `2` — ошибка или нарушение контентного фильтра; `3` — жёсткая блокировка PII; `4` — слишком большой `--add-dir`; `5` — уже идёт вызов с тем же ключом сессии; `6` — подтверждённая ошибка аутентификации; `7` — пустой ответ после очистки пробелов. Обязательны `0`/`1`; категории `2`–`7` необязательны, но при использовании имеют только указанный смысл. Сырые коды CLI в диапазоне `2`–`7` не проходят наружу без классификации. Шаги 3.1/3р.1 трактуют любой ненулевой код как отсутствие ответа напарника.
- **Доступ и срок.** По умолчанию нет доступа к дереву писателя: текстовый режим отключает инструменты в фактической конфигурации CLI и запускается в пустом рабочем каталоге. Разрешённый `--add-dir` даёт только отфильтрованную копию каталога и режим только чтения; исходный путь не становится рабочим корнем. При любом файловом контексте PII-, `.agentignore`- и контентная фильтрация выполняется до CLI; отсутствие или отказ обязательного фильтра останавливает вызов. Текстовую проекцию для вендора без файлового доступа писатель готовит с учётом правил чувствительного содержимого; адаптер не обещает очистку произвольного stdin, если она в нём не реализована. Новый адаптер задаёт настраиваемый срок ожидания, при превышении возвращает код `1` и завершает всю группу процессов CLI, если CLI создаёт дочерние процессы. Также он определяет ключ защиты от параллельных вызовов одной сессии и проверяет занятость до CLI. Наличие этих механизмов у уже зарегистрированных вендоров проверяется отдельно.
- **Граница интеграции IWE.** Выбор способа входа, статусы, журнал, проверка доступности и привязка к сессии относятся к IWE-интеграции. Поиск бинарного файла идёт через явную переменную, PATH и известные пути установки, если они есть. Для нового адаптера приёмочные проверки охватывают длинный запрос, неверный флаг/модель, баннер и пустой ответ CLI, срок с завершением группы процессов, коллизию, PII и оба режима доступа. Это требование к новому адаптеру, а не утверждение, что механизмы есть у всех зарегистрированных вендоров: их проверяют отдельно. Живой запрет записи подтверждается контролируемой попыткой вместе с проверкой конфигурации песочницы; отсутствие файла в одном опыте не доказывает абсолютную изоляцию.

**Минимальный скелет адаптера** (последний результат WP-516 Ф5). Это иллюстративная заготовка для `scripts/<vendor>-peer-adapter.sh`, а не готовый к запуску файл и не регистрация нового вендора. Она намеренно отказывает до вызова CLI, пока не реализованы фильтры, блокировка и песочница конкретного вендора; копирование само по себе не даёт права включать адаптер в таблицу §0в.

```bash
#!/usr/bin/env bash
set -uo pipefail
die() { printf 'ERROR: %s\n' "$1" >&2; exit "${2:-1}"; }
tmp_root=$(mktemp -d) || die 'cannot create temporary directory'
trap 'rm -rf -- "$tmp_root"' EXIT
prompt_file="$tmp_root/prompt"
reply_file="$tmp_root/reply"
model=''
add_dirs=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -p) shift ;;
    --model|--add-dir)
      flag="$1"
      [ "$#" -ge 2 ] && [ -n "$2" ] || die "$flag requires a value"
      case "$2" in -*) die "$flag requires a value, got another flag" ;; esac
      if [ "$flag" = --model ]; then model="$2"; else add_dirs+=("$2"); fi
      shift 2 ;;
    *) die "unknown or unsupported flag '$1'" ;;
  esac
done
cat > "$prompt_file" || die 'cannot read complete stdin'
[ -s "$prompt_file" ] || die 'empty prompt' 1

# Реализовать для вендора и проверить ДО запуска CLI. Каждая заглушка
# останавливает вызов: нельзя заменить её прямой передачей исходного каталога.
filter_prompt_and_context() { die 'content and PII filters not implemented' 2; }
acquire_session_lock() { die 'session lock not implemented' 1; }
run_vendor_read_only_with_deadline() { die 'read-only CLI sandbox not implemented' 1; }
filter_prompt_and_context "$prompt_file" "${add_dirs[@]}"
acquire_session_lock "$model"
run_vendor_read_only_with_deadline "$model" "$reply_file"

grep -q '[^[:space:]]' "$reply_file" || die 'empty peer response' 7
if [ "${IWE_PEER_PLAIN:-0}" != 1 ]; then
  first_line=$(awk 'length { print; exit }' "$reply_file")
  fences=$(grep -c '^---$' "$reply_file" || true)
  [ "$first_line" = '---' ] && [ "$fences" -ge 2 ] || die 'missing peer frontmatter'
  awk '/^---$/ { fences++; next } fences >= 2 && /[[:alnum:]]/ { body = 1 } END { exit !body }' \
    "$reply_file" || die 'empty peer response body' 7
fi
cat "$reply_file" || die 'cannot emit peer response'
```

**PID владельца семафора.** Когда адаптер или планировщик открывает сессию через `session-guard.sh`, он передаёт `--owner-pid <PID>` только если это PID процесса, который действительно остаётся владельцем сессии до её штатного `close` (например, процесс планировщика, ожидающий CLI). PID временного Bash-подпроцесса `session-guard.sh` или короткого launcher-а передавать запрещено: он умирает сразу после `open`, и sweep ошибочно карантинирует живую сессию. Если достоверного PID нет, параметр не передаётся; семафор остаётся ambiguous и может быть только предупреждён, но не автоматически удалён. `session-guard.sh` принимает только числовой PID; явный параметр имеет приоритет над `CLAUDE_PID`.

*Реестр вендоров (OwnerIntegrity):* таблица §0в выше — единый реестр. Writer-скиллы (peer-conversation, kimi-peer-writer) держат свои маппинги vendor→адаптер согласованными с ней для реально поддерживаемых вендоров (runtime-чтение чужого SKILL.md не требуется и не допускается); добавление вендора = правка реестра + затронутых writer-маппингов одним коммитом.

**Где искать адаптер.** Адаптеры и фильтры поставляются в папке программ шаблона (`${IWE_TEMPLATE:-${IWE_WORKSPACE:-$HOME/IWE}/FMT-exocortex-template}/scripts/`, issues #830, #1513). У автора шаблона их рабочие копии живут в репозитории управления; изменение исходника туда само не доставляется. Поэтому поиск идёт по цепочке: копия в репозитории управления, если она есть, иначе папка шаблона (одна строка на вендора):

```bash
ADAPTER_PATH[$vendor]="${IWE_WORKSPACE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}/<адаптер из таблицы>"
[ -x "${ADAPTER_PATH[$vendor]}" ] || ADAPTER_PATH[$vendor]="${IWE_TEMPLATE:-${IWE_WORKSPACE:-$HOME/IWE}/FMT-exocortex-template}/<адаптер из таблицы>"
echo "адаптер: ${ADAPTER_PATH[$vendor]}" >&2
```

и `PEER_AGENT_ID[$vendor]="<peer_agent из таблицы>"` (bash associative arrays; порядок вызова = порядок `PEER_VENDORS`). Используются везде ниже вместо хардкода `kimi-peer-adapter.sh`/`kimi-headless`.

**§0в.2 Проверка доступности vendor'ов (capability-check, WP-509 Ф5).** После построения `ADAPTER_PATH`, до анонса напарников:

1. **Дубликаты** в списке (`--peer codex,codex`) → отклонить: N участников не подменяется повторными вызовами одного напарника; сообщить пилоту, стоп до исправления списка.
2. **Проверка каждого `vendor`** (накопить доступных в `remaining`):
   ```bash
   remaining=()
   for vendor in "${PEER_VENDORS[@]}"; do
     ok=true
     if [[ ! -x "${ADAPTER_PATH[$vendor]}" ]]; then ok=false; fi  # адаптер отсутствует/не исполняем
     if [[ "$vendor" == hermes ]] && ! command -v hermes >/dev/null 2>&1; then ok=false; fi  # CLI hermes недоступен
     $ok && remaining+=("$vendor") || :  # недоступный — кандидат на исключение (п. 3)
   done
   ```
   Живой probe-вызов CLI НЕ делать: ошибки всплывут при вызове по контракту адаптера (exit ≠ 0, Шаг 3.1/3р.1); vendor-specific знания сверх `hermes` в скилл не добавлять (иначе Шаг 0в расходится с адаптерами).
3. **Недоступный vendor** → сообщить пилоту какой именно и почему (нет адаптера / нет CLI), предложить продолжить с оставшимися или прервать — тот же UX, что для незарегистрированного vendor (стоп на элементе, не на списке).
4. **Нормализация после исключений (атомарно):**
   ```bash
   PEER_VENDORS=("${remaining[@]}")
   PEER_COUNT=${#PEER_VENDORS[@]}
   round_order=("${PEER_VENDORS[@]}")
   ```
   Режим выбирается заново: `PEER_COUNT>=2` → round-loop (§3р), `==1` → turn-loop (§3 — сценарий «запрошены codex,hermes, остался codex» идёт классическим диалогом вдвоём, не усечённым кругом), `==0` → безусловный стоп с сообщением пилоту.

Анонсировать пилоту:
```
Напарник: <PEER_VENDOR> (<peer_agent>)                    # PEER_COUNT == 1, как раньше
```
или при `PEER_COUNT >= 2`:
```
Напарники (<PEER_COUNT>):
  1. kimi (kimi-headless)
  2. codex (codex)
```

---

## Шаг 0б. Открытие (WP Gate — для каждой новой пир-сессии)

До поиска РП выполнить короткий маршрутизатор `memory/protocol-open.md`.

Найти WP по задаче: прочитать `${IWE_GOVERNANCE_REPO:-DS-strategy}/WP-REGISTRY.md` (grep по ключевым словам) и `${IWE_GOVERNANCE_REPO:-DS-strategy}/current/WeekPlan W{N}.md`.

После нахождения РП, до выбора фазы выполнить Sync Gate — тот же вызов и разбор exit-кодов, что в `memory/protocol-open.md` Шаг 3a (владелец правила свежести — РП-561 Ф24), а не словесная отсылка к нему (найдено 22.10, Ф224 — прежняя формулировка этого абзаца только описывала Sync Gate прозой, не вызывала его, и пир-сессии не получали выгоду от фикса Ф219 — цитаты report.md в выводе сборщика):

```bash
bash "${IWE_WORKSPACE:-$HOME/IWE}/.claude/scripts/wp-sync-bundle.sh" WP-N > /tmp/wp-sync-bundle-$$.md; BUNDLE_RC=$?; head -3 /tmp/wp-sync-bundle-$$.md; echo "bundle_rc=$BUNDLE_RC"
```

`$$` переживает только этот один вызов Bash-инструмента — чтение файла и его удаление (ниже) делать в том же вызове или зафиксировать путь явно.

Разбор `BUNDLE_RC` и третьей строки `CARD_SOURCE` — та же таблица, что в `memory/protocol-open.md` Шаг 3a (`worktree`/`origin-pinned`/`worktree-forced` при exit 0; exit 1 — РП не найден; exit 2 — ошибка парсинга; exit 3 — свежесть не подтверждена, см. ниже). Прочитать секцию «## Последний отчёт сессии этого РП» из вывода (`grep -A 30 '^## Последний отчёт сессии этого РП' /tmp/wp-sync-bundle-$$.md` или аналог) — это первоисточник report.md последней сессии, не пересказ из карточки; отдельно проверить отчёты текущего дня по этому РП в `MC-sessions`, поскольку за день может быть несколько сессий. `rm -f /tmp/wp-sync-bundle-$$.md` после использования.

**Exit 3** (свежесть карточки не подтверждена) — выполнить переход в изолированную копию, предписанный там же (`session-guard.sh open --isolate`, либо, при явном согласии пилота работать по неполным данным, `--force-sync`), и повторить проверку. По отстающей локальной карточке (`CARD_SOURCE: worktree` при `GIT_SYNC_STATUS: STALE/DIVERGED`) фазу не выбирать.

Анонс пилоту:
```
Открываю peer-сессию (DP.SC.154)
Роль: Писатель (Claude) | Напарник(и): <PEER_VENDOR (PEER_AGENT_ID)>[, ...]
Задача: <задача>
РП: WP-NNN «<название>» | или: не найден в плане
Метод: turn-loop ≤10 ходов (PEER_COUNT==1) | round-loop ≤rounds_limit раундов (PEER_COUNT>=2, WP-509)
```

Если РП **не найден** в плане недели → полный WP Gate Ритуал (`memory/protocol-open.md §Сессия`):
объявить артефакт + дождаться подтверждения пилота → **только после «да» переходить к Шагу 1**.

Если РП найден → продолжать без ожидания.

**Определение рекомендуемой модели писателя (WP-394 Ф4.6):**
```
# informational — pilot selects model at Claude Code startup, not auto-applied here
verification_class = из WP контекста или из описания задачи
WRITER_MODEL_RECOMMENDED = "sonnet"   # default: закрытые задачи с тестами/чёткой проверкой
if verification_class in ("open-loop", "problem-framing"):
    WRITER_MODEL_RECOMMENDED = "opus"
```
Анонсировать пилоту:
```
Модель писателя (рекомендуется): <WRITER_MODEL_RECOMMENDED>
(Класс задачи: <verification_class>. Выбери модель при запуске Claude Code.)
```

**Подсказка маршрутизации агента (WP-383, информационная — не enforcement).**
По классу работы есть рекомендуемый инициатор/агент. Это подсказка пилоту, не блокировка:

| Класс работы | Рекомендуемый агент |
|--------------|---------------------|
| Уборка / форматирование / триаж | Kimi (дёшево, быстро) |
| Верификация shallow (формат/чеклист/drift) | Kimi |
| Верификация deep (cross-file invariant) | Claude (statefulness) |
| Реализация multi-file / tight-loop | Claude (держит состояние сессии) |
| Дизайн / scope / планирование | сильная модель (Claude/Opus или Kimi) |

**Trigger эскалации (лог, не блок):** если пилот 2 раза подряд выбирает агента вопреки подсказке — записать сигнал «routing-таблица устарела или классификация неверна» в `inbox/WP-383/routing-drift.log` (создать при первом срабатывании). Не блокировать выбор пилота.

> Источник таблицы: `${IWE_GOVERNANCE_REPO:-DS-strategy}/inbox/WP-383/routing-design-v1.md §3`. Statefulness-пробел Kimi закрыт автопередачей git-diff в `kimi-peer-adapter.sh` (§8).

---

## Шаг 1. Инициализация

Slug = первые 4 латинских слова из задачи строчными буквами через дефис (не-латиница и дата убираются). Никакой даты в slug — она уже в SESSION_ID. Если латиницы нет → `session`.

Номер сессии выдаёт **скрипт, а не инлайновый bash** (WP-530, пир-сессия `2026-09-05-24` с Kimi). Прежняя формула `find | wc -l + 1` с последующим `mkdir -p` давала две ошибки: гонку (две сессии в узком окне получали один номер, `mkdir -p` не отказывает на существующем каталоге — и обе молча писали журнал в один каталог) и перевыдачу номера после любой уборки (`count+1` ≠ `max+1`). Живой прогон 12 одновременных писателей на старой формуле: 12 сессий, 6 уникальных номеров. Инлайновый цикл-retry в markdown эту гонку не закрывает — спецификацию исполняет LLM, и два разных агента исполнят её по-разному; закрыть можно только там, где код один и исполняется буквально.

```bash
# Journal folder: the shared resolver used by session-guard.sh (explicit IWE_SESSIONS_ROOT,
# then $IWE_WORKSPACE/MC-sessions, then the legacy sessions/ folder of the governance repo).
IWE_COMMON="${IWE_SCRIPTS:-$HOME/IWE/scripts}/lib/common.sh"
[ -f "$IWE_COMMON" ] || IWE_COMMON="${IWE_TEMPLATE:-${IWE_WORKSPACE:-$HOME/IWE}/FMT-exocortex-template}/scripts/lib/common.sh"
. "$IWE_COMMON"
SESSIONS_DIR=$(IWE_ROOT="${IWE_ROOT:-${IWE_WORKSPACE:-$HOME/IWE}}" iwe_sessions_dir) \
  || { echo "папка журнала сессий не найдена (задан недоступный IWE_SESSIONS_ROOT?)" >&2; exit 1; }
TODAY=$(date +%Y-%m-%d)
MONTH=$(date +%Y-%m)
DAY=$(date +%d)
DAY_DIR="$SESSIONS_DIR/$MONTH/$DAY"
mkdir -p "$DAY_DIR"
# Порядок резолва: настроенный каталог скриптов, затем корневой чекаут. На
# хостах, где IWE_SCRIPTS указывает на копию шаблона, она может отставать.
RESERVE="${IWE_SCRIPTS:-$HOME/IWE/scripts}/session-dir-reserve.sh"
[ -x "$RESERVE" ] || RESERVE="${IWE_TEMPLATE:-${IWE_WORKSPACE:-$HOME/IWE}/FMT-exocortex-template}/scripts/session-dir-reserve.sh"
SESSION_ID=$(bash "$RESERVE" "$DAY_DIR" "$TODAY" "$SLUG") || { echo "резервация номера сессии не удалась (см. stderr выше)" >&2; exit 1; }
SESSION_DIR="${DAY_DIR}/${SESSION_ID}"
```

Скрипт отказал (exit ≠ 0) → СТОП, сообщить пилоту причину из stderr. Не подставлять номер вручную: ручная подстановка возвращает ровно ту гонку, ради которой скрипт и написан.

**1.0 Session-guard open (WP-398, обязательно, ДО любых Write/Edit в сессии).** Синхронизирует пир-сессию с `session-guard.sh` Scope gate — без этого коммит на Шаге 4.5 будет заблокирован pre-commit хуком (mtime файлов сессии старше семафора). WP берётся из Шага 0б (найденный или «day-close»/«unknown», если РП не назначен). `--close-path peer-session` (WP-484 Ф118, 19.08) объявляет протокол закрытия заранее — без него проверки закрытия перед коммитом требуют раннер закрытия дня для прямого коммита Шага 4.5.1, хотя это другой протокол (живой симптом, воспроизводившийся каждую сессию до этой фазы):

```bash
GOV_REPO_ROOT="${IWE_WORKSPACE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}"
OPEN_OUTPUT=$(cd "$GOV_REPO_ROOT" && IWE_AGENT=claude-code bash "${IWE_SCRIPTS:-$HOME/IWE/scripts}/session-guard.sh" open \
  --wp "<WP-NNN из Шага 0б>" --agent claude-code --close-path peer-session \
  --task "<задача одной строкой>" --slug "$SESSION_ID" 2>&1)
OPEN_STATUS=$?
printf '%s\n' "$OPEN_OUTPUT"
```

> **`cd "$GOV_REPO_ROOT" &&` перед вызовом — обязательно, не косметика (WP-484, найдено 14.09 вечером, пир-сессия `2026-09-14-13-wp484-close-proof-drift`, Claude+Kimi+Codex).** `session-guard.sh` резолвит и freeze-проверку (`frozen_checkout_match()`), и целевой репозиторий для `--isolate` (`ISOLATE_BASE_DIR`, `scripts/session-guard.sh:3387`) через `git rev-parse --show-toplevel` от РАБОЧЕЙ ДИРЕКТОРИИ ПРОЦЕССА, не от `GOV_REPO_ROOT` как значения переменной — так и задумано (WP-484 Ф104, 16.08): `--isolate` обязан снимать копию именно того репозитория, откуда его реально вызвали, не тихо подставлять канон вместо cwd (это была ОБРАТНАЯ ошибка Ф104, которую нельзя откатывать правкой самого скрипта). Раньше эта строка запускала `session-guard.sh` с cwd = каталог, откуда стартовала сама сессия (обычно `$HOME/IWE`, корень) — при работе над `DS-strategy` это (а) молча гасило freeze-проверку (сверялся не тот repo, совпадения не находилось), и (б) при freeze-fallback `--isolate` ниже изолировал КОРЕНЬ (`iwe-local-config`), а не governance-репо, записывая эту чужую копию как `governance_worktree:` в семафор — живой инцидент этой же сессии, независимо повторённый в тот же вечер сессией РП-7 Ф147 (`lessons_session_guard_isolate_targets_root_repo_not_governance`).



> **Не хардкодить `$HOME/IWE/scripts/session-guard.sh`.** Пир-сессия 2026-07-31-16-wp484-new-order-cutover сначала внесла такой хардкод по образцу `day-close/SKILL.md`, но холодный ревью нашёл: у обычного пользователя шаблона `setup.sh` НЕ копирует корневую `scripts/` — существует только каталог скриптов внутри шаблона, и `${IWE_SCRIPTS:-...}` резолвится именно туда намеренно (issue #266, commit `835d5ea` — тот же хардкод уже один раз чинили этим фоллбэком). Хардкод в `day-close/SKILL.md` — недокументированный долг, ждущий той же поломки при промоции, не образец для копирования. Для author-mode расхождение реальное (FMT-копия `session-guard.sh` отстаёт от корневой на фиксы WP-484 Нить1) — но лечится синком `template-sync.sh` (с отдельного разрешения пилота, S-33) или личной правкой `~/.iwe-paths`, не хардкодом в файле, который промотируется всем пользователям шаблона.

**Freeze-fallback (WP-484 Ф133, 24.08 — живой инцидент Ф132 п.3: freeze-гейт блокировал интерактивную пир-сессию без штатного пути закрыться).** `open` без `--isolate` — быстрый путь, достаточный вне freeze (большинство сессий). Если `OPEN_STATUS != 0` И `$OPEN_OUTPUT` содержит `под freeze` (`printf '%s\n' "$OPEN_OUTPUT" | grep -q 'под freeze'` — без here-string, см. пометку ниже) — canonical checkout заморожен (WP-520/WP-484 Ф104), сам гейт рекомендует `--isolate`, он для этого и существует (найдено этой же фазой — Класс 2, `--isolate` уже решает проблему, просто не был подключён здесь). Повторить с флагом:
```bash
ISOLATE_OUTPUT=$(cd "$GOV_REPO_ROOT" && IWE_AGENT=claude-code bash "${IWE_SCRIPTS:-$HOME/IWE/scripts}/session-guard.sh" open \
  --wp "<WP-NNN из Шага 0б>" --agent claude-code --close-path peer-session \
  --task "<задача одной строкой>" --slug "$SESSION_ID" --isolate)
```
> Тот же `cd "$GOV_REPO_ROOT" &&`, что и выше, и по той же причине: `--isolate` без него снимает копию каталога, откуда физически стартовала сессия (обычно корень `$HOME/IWE`), а не governance-репо, для которого только что сработал freeze. `$GOV_REPO_ROOT` в этой точке — ещё канонический путь (переопределение на `worktree_path` идёт строкой ниже, после этого вызова).
Успех → `$ISOLATE_OUTPUT` содержит строку JSON `{"worktree_path": "...", "branch": "...", "session_id": "..."}`. Извлечь `worktree_path` (`python3 -c 'import json,sys; print(json.loads(sys.argv[1])["worktree_path"])' "$(printf '%s\n' "$ISOLATE_OUTPUT" | grep -o '{.*}' | tail -1)"`) и переопределить корень репозитория на оставшуюся часть скилла:

> **Без here-string `<<<"$VAR"` (WP-484 Ф161 / bug-2026-09-27-secret-guard-analyzer-fails-on-here-string, найдено живьём 27.09, пир-сессия 2026-09-27-09).** Анализатор стража секретов (`secret_patterns.py analyze-bash`) читает `<<<"$VAR"` как незакрытый heredoc и падает; хук трактует это как отказ самого стража и блокирует ВЕСЬ Bash-вызов с текстом «анализатор не отработал». Прежняя формулировка этого шага с `grep -o '{.*}' <<<"$ISOLATE_OUTPUT"` блокировала открытие изолированной сессии у любого писателя на хосте с этим стражем; `printf | grep` даёт тот же результат. Фикс анализатора — РП-544; сюда — не возвращать here-string и после него.
```bash
GOV_REPO_ROOT="<извлечённый worktree_path>"
```
Сообщить пилоту одной строкой: «Канон под заморозкой — сессия работает в изолированной копии (`$GOV_REPO_ROOT`), коммит на Шаге 4.5.1 уйдёт оттуда через штатный `isolate-push.sh`». Любой другой exit ≠ 0 (не freeze, и isolate-попытка тоже не помогла) → не блокировать сессию как раньше: сообщить пилоту одной строкой «session-guard open не сработал (<причина>), продолжаю без семафора — на Шаге 4.5 возможна ручная разблокировка через touch/note-file», `GOV_REPO_ROOT` остаётся канонический путь, идти дальше.

Semaphore-файл session-guard создаёт СВОЙ ORZ-скаффолд-заготовку по пути `$SESSIONS_DIR/<MONTH>/<TODAY>-<CLEAN_SLUG>.md` — тот же путь, что закрывающий файл пир-сессии из Шага 4.4/4.5.0 (до 2026-08-03 эти два места ошибочно считали разные пути, см. пометку на Шаге 4.4); Шаг 4.5.0 дописывает в этот же файл финальное содержимое, а не создаёт новый. **WP-526 Ф2:** ORZ-скаффолд идёт в `MC-sessions` (`$SESSIONS_DIR`) безусловно, isolate или нет, — `session-guard.sh` больше не привязывает его к `$GOV_REPO_ROOT`. `GOV_REPO_ROOT` (переопределённый на isolate-fallback выше) по-прежнему нужен для остальных шагов скилла, которые читают/пишут файлы в самом governance-репо (не сессионные), — эти два пути больше не связаны между собой.

**1.1 Каталог сессии уже создан** — его создаёт `session-dir-reserve.sh` в тот же момент, когда выигрывает номер. Отдельный `mkdir -p` здесь был бы не просто лишним: он маскирует отказ резервации (создаёт каталог под номером, который скрипт не выдавал).

**1.2 Записать `meta.yaml`** (Write):
```yaml
task_id: ""
date: "<TODAY>"
session_id: "<SESSION_ID>"
start_time: "<ISO-8601 UTC>"
end_time: ""
writer_agent: "claude-code"
personality: "<unassigned|UUID>"   # WP-510 Патч 4, слой 3: writer_agent = конструктивная реализация; personality = какая ИИ-личность (если есть авторитетная запись в `current/AI Personalities Registry.md` для текущего хоста/раннера) вела сессию. Ищи по хосту/раннеру в реестре — не выдумывай; нет однозначного совпадения → "unassigned". Маршрутизирующая метка, не допуск к памяти.
peer_agent: "<первый PEER_AGENT_ID из §0в>"      # backward-compat (PEER_COUNT==1: единственный); полный список — peer_agents
peer_cmd: "<первый PEER_VENDOR>-peer-adapter"     # backward-compat; полный список — peer_cmds
peer_agents: ["<PEER_AGENT_ID>", "..."]   # WP-509: в порядке PEER_VENDORS, длина 1 при PEER_COUNT==1 (дублирует peer_agent); §4.2 читает ТОЛЬКО это поле для report.md peer: при PEER_COUNT>=2
peer_cmds: ["<vendor>-peer-adapter", "..."]   # WP-509: та же длина/порядок, что peer_agents
round_order: ["<vendor>", "..."]   # WP-509: фиксированный порядок раунда (= PEER_VENDORS), только при PEER_COUNT>=2
write_token_holder: "writer_agent"   # WP-509: держатель write token сейчас; default = writer_agent, меняется только через подтверждённый ACCEPT_HANDOFF (см. §3р.3)
peer_model: ""
status: "started"
turns_count: 0
turns_limit: 10        # PEER_COUNT==1: лимит реплик, без изменений с v4
rounds_limit: 6         # WP-509: лимит раундов, применяется только при PEER_COUNT>=2, НЕ переопределяет turns_limit
round_skips: {}        # WP-509: {round_NN: [vendor, ...]} — кто не ответил/пропустил раунд; исключаются из требования "консенсус у каждого" в §3р.3
participant_status: {}  # WP-509: {vendor: active|failed} — финальный статус участника после исчерпания попыток
max_peer_attempts: 2    # WP-509: лимит повторных вызовов одного peer подряд
peer_attempts: {}     # WP-509: {vendor: N} — счётчик вызовов в текущем раунде
peer_failures: []      # WP-509: [{round, vendor, reason}] — зафиксированные отказы участников
handoff_history: []    # WP-509: [{round, from, to, reason}] — журнал OFFER_HANDOFF/ACCEPT_HANDOFF (write token, DP.SC.154 «Write token ≠ process_position»)
escalations_count: 0
extensions: []
result_path: ""
task_description: "<задача>"
implementation_pipeline: false
review_iterations: 0
verify_status: ""
deploy_shas: {}
writer_model_recommended: "sonnet"  # informational — pilot selects model at startup, not auto-applied; opus only for open-loop|problem-framing
# Sequential role-discovery (WP-367) — заполняется во время Opening:
# Если пилот задал явно — сразу заполни `roles`.
# Если не задал — initiator в ход 0 заполняет `proposed_roles` в frontmatter 00-writer.md;
#                  после согласования (ход 2) переноси в `roles`.
roles: {}            # финальное: {agent_id: [DP.ROLE.NNN, ...]} после consensus
discovery_turns: 0   # сколько ходов ушло на role-discovery (не считается в turns_limit)
# Двухосная модель (WP-367 Ф5, DP.SC.154 v4):
ad_hoc_roles: {}     # {role_name: {agent_id, rationale, first_used_turn}} — для каскада audit
swap_history: []     # [{turn, from, to, reason}] — журнал SWAP_WRITER переходов
```

**Если пилот не назначил роли** при запуске сессии — initiator в ход/раунд 0 предлагает свою роль и роль **каждого** напарника (см. DP.SC.154 раздел «Opening сессии: Sequential role-discovery», при `PEER_COUNT>=2` — раздел «Role-discovery для N>2»). Discovery-ходы/раунды (0-2) **не входят** в `turns_limit`/`rounds_limit`.

**In-session ad-hoc role signal** (DP.SC.154 v4, каскад Pack-расширения уровень 1). При использовании ad-hoc роли (нет в Pack `DP.ROLE.NNN`/`MIM.R.NNN`/`VR.R.NNN`) агент **обязан сразу** объявить пилоту — формат:

```
Беру ad-hoc роль «<имя>». В каталоге Pack такой нет.
Обязанности: <одной строкой>. Метод: <одной строкой>.
Предлагаю создать РП на формализацию (~30 мин: passport + scenarios + templates).
Выбери:
  А. Создать сейчас → отдельный РП «pack-gap-<имя>» через create-wp.sh.
  Б. Отложить → продолжу как ad-hoc, сторож напомнит при Week Close.
```

Запись в `meta.yaml.ad_hoc_roles` идёт независимо от выбора (для back-up на уровне 2 — Week Close audit). Если пилот выбрал А — после сессии писатель открывает отдельный РП и делает формализацию.

**1.3 Записать открывающую запись в индекс-черновик** (WP-537 Ф4: `00-index.md` в MC-sessions (WP-526 Ф2) больше не пишется напрямую — session-index-snapshot.sh единственный писатель git-tracked файла, все остальные пишут в свой runtime-черновик, см. `scripts/lib/session-index-draft.sh`). Колонка «Агенты» — при `PEER_COUNT>=2` напарники соединяются через `+`:
```bash
IDX_LIB="$GOV_REPO_ROOT/scripts/lib/session-index-draft.sh"
[ -f "$IDX_LIB" ] || IDX_LIB="${IWE_TEMPLATE:-${IWE_WORKSPACE:-$HOME/IWE}/FMT-exocortex-template}/scripts/lib/session-index-draft.sh"
. "$IDX_LIB"
session_index_draft_write "$SESSION_ID" "$TODAY" "<задача ≤50 симв>" \
  "claude-code / <PEER_VENDOR1>[+<PEER_VENDOR2>...]" "0" "0" "started" "—"
```

Установка без переносчика черновиков в индекс (программы session-index-snapshot.sh в папке программ репозитория управления; так у пользователей шаблона) — черновик никто не перенесёт, поэтому ещё и вести `00-index.md` напрямую, как до WP-537 (файла нет → создать, issue #568; строку сессии заменить по `SESSION_ID` или вставить первой в таблицу):
```bash
if [ ! -f "${IWE_WORKSPACE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}/scripts/session-index-snapshot.sh" ]; then
  IDX="$SESSIONS_DIR/00-index.md"
  [ -f "$IDX" ] || printf '%s\n' '# Индекс пир-сессий' '' \
    '| Дата | Сессия | Задача | Агенты | Ходы | Эскалации | Статус | Отчёт |' \
    '|------|--------|--------|--------|------|-----------|--------|-------|' > "$IDX"
  ROW="| $TODAY | $SESSION_ID | <задача ≤50 симв> | claude-code / <PEER_VENDOR1>[+<PEER_VENDOR2>...] | 0 | 0 | started | — |"
  if grep -qF "| $SESSION_ID |" "$IDX"; then
    ID="| $SESSION_ID |" ROW="$ROW" awk 'index($0, ENVIRON["ID"]) { print ENVIRON["ROW"]; next } { print }' "$IDX" > "$IDX.tmp"
  else
    ROW="$ROW" awk '{ print } /^\|------/ && !done { print ENVIRON["ROW"]; done = 1 }
      END { if (!done) print ENVIRON["ROW"] }' "$IDX" > "$IDX.tmp"
  fi
  mv "$IDX.tmp" "$IDX"
fi
```
В этом режиме `00-index.md` идёт в коммит сессии (Шаг 4.5) вместе с её файлами.

---

## Шаг 2. Реплика писателя 00-writer.md

Записать `${SESSION_DIR}/00-writer.md` (Write):

```markdown
---
turn: 0
role: writer
agent_id: claude-code
timestamp: <ISO-8601 UTC>
consensus: none
---

<Моя начальная позиция — анализ задачи, тезисы, конкретные вопросы к напарнику(ам).
При `PEER_COUNT>=2` — предложить содержательную роль каждому напарнику отдельно (не только «роль для группы»), с обоснованием на каждого (DP.SC.154 «Role-discovery для N>2»).
НЕ пересказ задачи. Позиция с аргументами.>
```

После заполнения `meta.yaml` и `00-writer.md` заявить оба файла в семафоре
этой пир-сессии. Это даёт проверке закрытия явную связь с каталогом журнала
в дополнение к поиску по `slug`. Пустые файлы не заявлять.

```bash
for PEER_CORE_FILE in "$SESSION_DIR/meta.yaml" "$SESSION_DIR/00-writer.md"; do
  [ -s "$PEER_CORE_FILE" ] || { echo "пир-журнал ещё не заполнен: $PEER_CORE_FILE" >&2; exit 1; }
  IWE_AGENT=claude-code bash "${IWE_SCRIPTS:-$HOME/IWE/scripts}/session-guard.sh" \
    note-file "$PEER_CORE_FILE" --agent claude-code --wp "<WP-NNN из Шага 0б>" \
    --slug "$SESSION_ID" || exit 1
done
```

Показать пилоту краткое резюме: что написал в 00-writer.md.

---

## Шаг 2.5. Role-discovery для N>2 (PEER_COUNT >= 2, WP-509)

> **Пропустить, если PEER_COUNT == 1.** Для двух участников discovery сводится к предложению ролей в 00-writer.md и согласованию в turn-loop.

После 00-writer.md запустить **раунды 0–2**, которые **не входят** в `rounds_limit`.

### 2.5.1 Раунд 0 — писатель предлагает роли

В 00-writer.md (Шаг 2) писатель уже предлагает содержательную роль каждому напарнику. Дополнительно записать в frontmatter `00-writer.md`:
```yaml
proposed_roles: { "<PEER_AGENT_ID>": "<role_name>", ... }
suggested_initiator_role: "<role_name>"
```

### 2.5.2 Раунд 1 — каждый peer подтверждает или спорит роль

Вызвать каждого напарника по порядку `round_order` с промптом, аналогичным §3р.1, но с единственной задачей:
- прочитать 00-writer.md;
- согласиться с предложенной ролью, предложить правку или запросить уточнение у пилота;
- явно подтвердить, что понимает ограничение «ответ только в stdout, никаких файловых операций в SESSION_DIR».

Формат реплики:
```yaml
---
turn: 0
role: peer
agent_id: <PEER_AGENT_ID>
content_role: <согласованная/предложенная роль>
process_position: peer
timestamp: <ISO-8601 UTC>
consensus: none
role_accepted: true | false | clarify
---

<Обоснование принятия роли или запрос уточнения>
```

Если `role_accepted: clarify` — писатель уточняет у пилота и повторяет раунд 1 только для этого участника (не считается отдельным раундом discovery).

### 2.5.3 Раунд 2 — фиксация agreed_roles

Писатель записывает `01-writer.md` (turn: 0, role: writer) с итоговой таблицей ролей:
```yaml
---
turn: 0
role: writer
agent_id: claude-code
consensus: none
agreed_roles: { "<PEER_AGENT_ID>": "<role_name>", ... }
writer_role: "<role_name>"
discovery_turns: 1   # сколько дополнительных проходов раунда 1 потребовалось
---
```

Обновить `meta.yaml`:
```yaml
roles: { "claude-code": ["<writer_role>"], "<PEER_AGENT_ID>": ["<role_name>"], ... }
discovery_turns: <N>
```

Только после этого переходить к **Шагу 3р (ROUND=1)** с содержательными раундами.

---

## Шаг 3. Turn loop (PEER_COUNT == 1)

> **При `PEER_COUNT >= 2` — пропустить этот шаг целиком, перейти к Шагу 3р (round loop, WP-509).** Этот шаг не менялся с версии 1.4.0 — один напарник, поведение идентично.

Переменные: `TURN=1`, `ESCALATIONS=0`, `DONE=false`.

### 3.1 Вызов напарника

Прочитать все предыдущие реплики из `SESSION_DIR` в порядке нумерации.
Составить промпт:

```
Ты — напарник (peer agent) в диалоговой сессии (DP.SC.154).
Сессия: <SESSION_ID>
Ход: <TURN> из 10
Сейчас (UTC): <ISO-8601 UTC, из `date -u`; в timestamp реплики ставь это время, дату не выдумывай>
Задача: <задача>

PILOT_ORDERS: <действующие запреты и поручения пилота по предмету, требующие его разрешения на изменение; режим работы, например «пилот просил закрыть сессию»; каждое с датой. Если их нет: «нет на <дата>, проверено по <источнику>»>

Контекстная проекция ниже — единственный источник о сессии. Не читай файлы и не используй инструменты:
<минимальная текстовая проекция предыдущих реплик и проверяемых фактов>

Напиши реплику в stdout с frontmatter:
---
turn: <TURN>
role: peer
agent_id: <PEER_AGENT_ID>
timestamp: <ISO-8601 UTC>
consensus: none | proposed | reached | escalate
---

<Твой ответ>

Правило критика: найди ХОТЯ БЫ ОДИН тезис или допущение писателя, с которым не согласен. Не сдавайся после первого возражения — держись аргументированно. Если всё действительно ОК — объясни почему конкретно, не просто «согласен».

Проверь строку с меткой PILOT_ORDERS; если она пуста или «нет» без даты и источника, скажи об этом в первой же реплике.

Маркер пиши, только когда он применяется. При несогласии или отсутствии маркер не пиши вовсе и без отрицаний: строки «CONSENSUS: нет согласия» и «ESCALATE_TO_USER: не требуется» запрещены, писатель читает любую строку, начинающуюся с маркера, как его наличие.
Маркеры (строго в начале строки):
CONSENSUS: <резюме> — если считаешь что договорились
ESCALATE_TO_USER: <причина> — если писатель игнорирует существенное возражение
```

Вызов напарника через Bash — флаги зависят от вендора (таблица §0в):

```bash
PEER_FILE="${SESSION_DIR}/$(printf '%02d' $TURN)-peer.md"
if [ "$PEER_VENDOR" = "hermes" ]; then
  # hermes-peer-adapter.sh не принимает --add-dir/--model — свой --session-id.
  # НЕ путать с $SESSION_ID пир-сессии: адаптер всегда шлёт переданный --session-id
  # как `--resume <id>` в hermes CLI — на самом первом вызове этой пир-сессии
  # у Hermes ещё не существует диалога с ID пир-сессии (это два разных
  # пространства идентификаторов), `hermes chat --resume <несуществующий>`
  # падает молча (set -euo pipefail в адаптере гасит его же диагностику до того,
  # как она успевает напечататься) — найдено живьём 2026-07-31/08-01, WP-484/WP-509.
  # Родной session_id Hermes читаем С ДИСКА (последний уже записанный NN-peer.md),
  # не из shell-переменной — агент делает каждый вызов отдельным Bash-тулом, и
  # переменные не переживают границу между вызовами (найдено code review 01.08).
  HERMES_LAST_ID=$(grep -h "^session_id: " "${SESSION_DIR}"/[0-9][0-9]-peer.md 2>/dev/null | tail -1 | sed 's/^session_id: //')
  if [ -z "$HERMES_LAST_ID" ]; then
    echo "<промпт>" | IWE_PEER_PLAIN=0 bash "$ADAPTER_PATH" > "$PEER_FILE" 2> "${PEER_FILE%.md}.err"
  else
    echo "<промпт>" | IWE_PEER_PLAIN=0 bash "$ADAPTER_PATH" --session-id "$HERMES_LAST_ID" > "$PEER_FILE" 2> "${PEER_FILE%.md}.err"
  fi
else
  printf '%s\n' "<промпт с минимальной текстовой проекцией>" | IWE_PEER_PLAIN=0 bash "$ADAPTER_PATH" \
    > "$PEER_FILE" 2> "${PEER_FILE%.md}.err"
fi
# Integrity warning check (WP-524 F6) — same as in the round-loop below, and
# before the cleanup, which may delete the file.
if grep -q '^INTEGRITY-WARNING:' "${PEER_FILE%.md}.err" 2>/dev/null; then
  echo "⚠️  ЦЕЛОСТНОСТЬ: адаптер сообщил о возможной потере целого сообщения в ответе напарника." >&2
  grep '^INTEGRITY-WARNING:' "${PEER_FILE%.md}.err" >&2
  # Показать пилоту и не принимать реплику как полную: перезапросить ход
  # либо сверить с журналом сессии напарника (scripts/kimi-final-text.py).
  # The session journal never keeps .err (`**/*.err` in its .gitignore, WP-524 F7):
  # copy the fact and the warning text into the writer's next reply or report §5,
  # a link to the .err file alone is lost.
fi
# Same rule as in the round-loop below: an empty .err is noise, not evidence
# (WP-481 F13). Optional tidy-up (WP-524 F7): if Claude Code's safety check
# refuses this rm (e.g. inside a bash function with variables), skip it, the
# journal ignores .err anyway. Never note-file a .err and never pass one to
# `git add` by explicit path: the journal refuses ignored paths (see §4.4а).
[ -s "${PEER_FILE%.md}.err" ] || rm -f "${PEER_FILE%.md}.err"
# Пустой $PEER_FILE (адаптер отказал без вывода, напр. известный класс
# bug-2026-10-05-grok-peer-adapter-empty-response-exit-1.md) нечего заявлять
# и нечего коммитить — удаляем сразу, чтобы список файлов сессии (§4.4а,
# `git ls-files --others`) не подхватил его молча мимо scope gate. `--forget` на
# путь, который ещё не заявлен (обычный случай), безопасно отказывает кодом 1
# без побочных эффектов — тот же путь мог быть заявлен ПРЕДЫДУЩЕЙ попыткой
# этого же раунда (3р.1а допускает повторный вызов одного peer с тем же
# $PEER_FILE), и тогда заявка должна быть снята вместе с файлом.
if [ ! -s "$PEER_FILE" ]; then
  rm -f "$PEER_FILE"
  bash "${IWE_SCRIPTS:-$HOME/IWE/scripts}/session-guard.sh" note-file --forget "${PEER_FILE#"$SESSIONS_DIR"/}" \
    --slug "$SESSION_ID" >/dev/null 2>&1 || true
else
  # $PEER_FILE идёт через Bash-редирект, не через Write/Edit — scope gate
  # session-guard его не увидит и заблокирует коммит на Шаге 4.5.1 (найдено
  # 2026-08-10, сессия 2026-08-10-08-wp7-update-fatigue-community: блокировка
  # сразу на обоих peer-файлах сессии). Регистрируем сразу, не дожидаясь блока.
  # Отказ регистрации — громкий (WP-530 Ф67, 25.09): три сессии за день молча
  # потеряли заявки на файлы напарников (прежнее `2>/dev/null || true`), scope-proof
  # при закрытии не сошёлся, семафоры остались открытыми. Раунд не роняем, но
  # писатель ОБЯЗАН увидеть WARN и повторить note-file до Шага 4.5.
  if ! note_err=$(bash "${IWE_SCRIPTS:-$HOME/IWE/scripts}/session-guard.sh" note-file "$PEER_FILE" \
      --wp "<WP-NNN из Шага 0б>" --slug "$SESSION_ID" 2>&1); then
    printf 'WARN: note-file failed for %s: %s\n' "$PEER_FILE" "$note_err" >&2
    printf 'NOTE_FILE_WARN %s\n' "$PEER_FILE"
  fi
fi
```

Если файл пустой (значит, уже удалён предыдущим шагом) или exit ≠ 0 → сообщить пилоту: «<PEER_VENDOR> не ответил. Повторить или прервать?»

### 3.2 Показать пилоту

Прочитать `$PEER_FILE`. Вывести ключевые тезисы напарника (не всю реплику дословно — краткое резюме + цитаты ключевых позиций).

### 3.3 Проверить маркеры

**ESCALATE_TO_USER:**
Если `grep -q "^ESCALATE_TO_USER:" "$PEER_FILE"`:
- Извлечь причину: `grep "^ESCALATE_TO_USER:" "$PEER_FILE" | sed 's/^ESCALATE_TO_USER: //'`
- `ESCALATIONS += 1`
- Записать `${SESSION_DIR}/escalation-$(printf '%02d' $((ESCALATIONS-1))).md`:

```markdown
---
escalation_number: <N>
turn: <TURN>
timestamp: <now>
reason: "<причина>"
pilot_response: ""
---

# Эскалация <N> (ход <TURN>)

**Причина:** <причина>
**Реплика напарника:** <PEER_FILE>
**Ответ пилота:** (ввести ниже)
```

- Сообщить пилоту: «<PEER_VENDOR> эскалирует: <причина>. Нужно твоё решение: <вариант(ы) решения одной фразой>. Подробности — `escalation-<NN>.md`.»
- Дождаться ответа пилота, записать в `pilot_response` в escalation-файл.
- Обновить `meta.yaml`: `escalations_count: <ESCALATIONS>` (Bash sed).

**CONSENSUS:**
Если `grep -q "^CONSENSUS:" "$PEER_FILE"`:
- Извлечь резюме.
- **Проверка поведенческих утверждений (найдено 18.10, WP-529 — пир-сессия `2026-10-18-14-wp529-a3-f214-checklist`).** Если резюме утверждает «механизм/код уже делает X» (поведение существующей системы, не только что реализованное в этой сессии) — не принимать по памяти участника. Найти и процитировать точный текст/строку кода, подтверждающую утверждение (file:line или цитата правила). Нет цитаты → резюме не считается фактом: вернуться к напарнику с запросом подтверждения ИЛИ отложить (`DONE` не выставлять) до появления цитаты. Коренная причина инцидента: решение о гейте перехода состояния основывалось на формулировке «уже так, fail-open по умолчанию», которая разошлась с буквальным текстом правила (fail-closed) — расхождение обнаружилось только на Decision Gate, а не здесь, где его было дешевле поймать.
- `DONE=true`, перейти к **Шагу 3.5 (Decision Gate)** — НЕ к Шагу 4 напрямую.

### 3.4 Реплика писателя

Если `TURN >= 10` → `DONE=true`, перейти к Шагу 3.8 (Close-Trigger Gate) — turn-лимит исчерпан без консенсуса не отменяет проверку триггера.

Написать `$(printf '%02d' $((TURN+1)))-writer.md` (Write):
```markdown
---
turn: <TURN+1>
role: writer
agent_id: claude-code
timestamp: <now>
consensus: none
---

<Моя реплика: ответ на аргументы напарника + учёт направления пилота>
```

`TURN += 1` → вернуться к 3.1.

---

## Шаг 3р. Round loop (PEER_COUNT >= 2, WP-509)

> **Пропустить, если `PEER_COUNT == 1`** — там действует классический Шаг 3.

Переменные: `ROUND=1`, `ESCALATIONS=0`, `DONE=false`. Порядок раунда = `PEER_VENDORS` в порядке `--peer` (записан в `meta.yaml.round_order` на Шаге 1.2).

### 3р.1 Вызов каждого напарника по порядку раунда

`WRITE_TOKEN_HOLDER` — читать из `meta.yaml.write_token_holder` (default, записанный на Шаге 1.2, = `writer_agent`: писатель держит write token, пока не было ни одного `ACCEPT_HANDOFF`). Значение передаётся в промпт явно — напарники не обязаны сами читать `meta.yaml` в поисках держателя.

Для `vendor` в `round_order` (по очереди, не параллельно — каждый следующий видит реплики предыдущих этого же раунда) составить промпт:

```
Ты — напарник (peer agent) в диалоговой сессии (DP.SC.154, N>2 участников).
ПЕРВАЯ СТРОКА твоего ответа (до frontmatter) — ровно: «Я — <PEER_AGENT_ID>».
В frontmatter ровно `agent_id: <PEER_AGENT_ID>` — не копируй agent_id/роль из
реплик других участников, даже если их текст лежит ниже в этом промпте.
Сессия: <SESSION_ID>
Раунд: <ROUND> из <rounds_limit>
Сейчас (UTC): <ISO-8601 UTC, из `date -u`; в timestamp реплики ставь это время, дату не выдумывай>
Задача: <задача>
Текущий держатель write token: <WRITE_TOKEN_HOLDER>

PILOT_ORDERS: <действующие запреты и поручения пилота по предмету, требующие его разрешения на изменение; режим работы, например «пилот просил закрыть сессию»; каждое с датой. Если их нет: «нет на <дата>, проверено по <источнику>»>

Для Claude: передай в его stdin минимальную текстовую проекцию всех нужных реплик и фактов этого раунда. Он не читает журнал сессии и не использует инструменты. Для остальных напарников применяй их собственный контракт.

Реплики других участников этого раунда (если есть) — ПОСЛЕ этого задания, под
заголовком «РЕПЛИКИ ДРУГИХ УЧАСТНИКОВ (не копировать их frontmatter, это чужая
идентичность)». Киму в N>2 обязательно: без явной собственной идентификацией в
первых строках она дважды копировала чужой frontmatter (08.10.2026) и реплика
сгорала по валидации 3р.1а.

ВАЖНО: ответ только в stdout. Не используй свои файловые инструменты ни для одного
файла в этой папке — это создаёт гонку с перехватом stdout и портит журнал сессии.

Напиши реплику в stdout с frontmatter:
---
turn: <ROUND>
role: peer
agent_id: <PEER_AGENT_ID>
content_role: <согласованная роль или предложение, если ещё не согласована>
process_position: peer
timestamp: <ISO-8601 UTC>
consensus: none | proposed | reached | escalate
---

<Твой ответ>

Правило критика: найди ХОТЯ БЫ ОДИН тезис, с которым не согласен — свой или другого напарника.
Проверь строку с меткой PILOT_ORDERS; если она пуста или «нет» без даты и источника, скажи об этом в первой же реплике.

Маркер пиши, только когда он применяется. При несогласии или отсутствии маркер не пиши вовсе и без отрицаний: строки «CONSENSUS: нет согласия» и «ESCALATE_TO_USER: не требуется» запрещены, писатель читает любую строку, начинающуюся с маркера, как его наличие.
Маркеры (строго в начале строки):
PASS — если нечего добавить в этом раунде (не ошибка, явное право промолчать)
CONSENSUS: <резюме> — если согласен с итогом
ESCALATE_TO_USER: <причина> — если есть проигнорированное существенное возражение
OFFER_HANDOFF: <agent_id> — <причина> — если хочешь предложить свой write token другому (только если ты сейчас держатель)
ACCEPT_HANDOFF — если принимаешь предложенный тебе OFFER_HANDOFF
REQUEST_HANDOFF: <причина> — необязывающая просьба к держателю
```

**Разогрев после смены роли (WP-481 Ф24, пятый семинар FPF, 11.08).** Первая реплика участника сразу после подтверждённого `ACCEPT_HANDOFF`/смены роли — короткое подтверждение новой роли (1-2 предложения: «принимаю роль X»), не засчитывается как содержательный ход раунда. Причина: участник по инерции первую реплику часто пишет ещё в старой роли. Процедурное правило, без новых полей в схеме.

Вызов напарника через Bash (промпт — во временный файл, не inline `echo` — тот же B7.7c-риск, что в §0в.1):

```bash
PEER_FILE="${SESSION_DIR}/$(printf '%02d' $ROUND)-peer-${vendor}.md"
PROMPT_FILE=$(mktemp)
# записать промпт (см. шаблон выше) в $PROMPT_FILE
if [ "$vendor" = "hermes" ]; then
  # Тот же контракт и та же ловушка, что в Шаге 3.1 (turn-loop) — hermes не берёт
  # --add-dir, и переданный --session-id всегда трактуется как --resume. Родной
  # hermes session_id читаем С ДИСКА (последний уже записанный NN-peer-hermes.md),
  # не из shell-переменной — агент делает каждый вызов отдельным Bash-тулом, и
  # переменные не переживают границу между вызовами (найдено code review 01.08).
  HERMES_LAST_ID=$(grep -h "^session_id: " "${SESSION_DIR}"/[0-9][0-9]-peer-hermes.md 2>/dev/null | tail -1 | sed 's/^session_id: //')
  if [ -z "$HERMES_LAST_ID" ]; then
    cat "$PROMPT_FILE" | IWE_PEER_PLAIN=0 bash "${ADAPTER_PATH[$vendor]}" > "$PEER_FILE" 2> "${PEER_FILE%.md}.err"
    STATUS=$?
  else
    cat "$PROMPT_FILE" | IWE_PEER_PLAIN=0 bash "${ADAPTER_PATH[$vendor]}" --session-id "$HERMES_LAST_ID" > "$PEER_FILE" 2> "${PEER_FILE%.md}.err"
    STATUS=$?
  fi
else
  if [ "$vendor" = "claude" ]; then
    cat "$PROMPT_FILE" | IWE_PEER_PLAIN=0 bash "${ADAPTER_PATH[$vendor]}" > "$PEER_FILE" 2> "${PEER_FILE%.md}.err"
  else
    # stderr в .err, НЕ в /dev/null (WP-524 Ф6, 05.09): адаптер пишет туда
    # предупреждение «ответ пришёл, но, возможно, потерялось целое сообщение».
    # В /dev/null оно исчезало ровно в главном сценарии round-loop.
    cat "$PROMPT_FILE" | IWE_PEER_PLAIN=0 bash "${ADAPTER_PATH[$vendor]}" --add-dir "$SESSION_DIR" > "$PEER_FILE" 2> "${PEER_FILE%.md}.err"
  fi
  STATUS=$?
fi
# Integrity warning check (WP-524 F6): the adapter can hand back a reply that
# looks whole while a whole message was lost in transport. Read it BEFORE the
# empty-.err cleanup below, or the file may already be gone.
if grep -q '^INTEGRITY-WARNING:' "${PEER_FILE%.md}.err" 2>/dev/null; then
  echo "⚠️  ЦЕЛОСТНОСТЬ: адаптер сообщил о возможной потере целого сообщения в ответе напарника." >&2
  grep '^INTEGRITY-WARNING:' "${PEER_FILE%.md}.err" >&2
  # Показать пилоту и не принимать реплику как полную: перезапросить ход
  # либо сверить с журналом сессии напарника (scripts/kimi-final-text.py).
  # The session journal never keeps .err (`**/*.err` in its .gitignore, WP-524 F7):
  # copy the fact and the warning text into the writer's next reply or report §5,
  # a link to the .err file alone is lost.
fi
# Keep the stderr file only when the adapter actually wrote to it. An empty
# .err carries no diagnostics and just adds noise to the session folder
# (WP-481 F13: 232 .err files in one week, 115 of them empty). Placed after
# STATUS is captured so the cleanup cannot clobber the adapter's exit code.
# Optional tidy-up (WP-524 F7): if Claude Code's safety check refuses this rm,
# skip it. Never note-file a .err and never pass one to `git add` by explicit
# path: the journal ignores `**/*.err` and refuses such paths (see §4.4а).
[ -s "${PEER_FILE%.md}.err" ] || rm -f "${PEER_FILE%.md}.err"
rm -f "$PROMPT_FILE"
# Пустой $PEER_FILE (адаптер отказал без вывода, напр.
# bug-2026-10-05-grok-peer-adapter-empty-response-exit-1.md) нечего заявлять
# и нечего коммитить — удаляем сразу, чтобы список файлов сессии (§4.4а,
# `git ls-files --others`) не подхватил его молча мимо scope gate. `--forget` на
# ещё не заявленный путь (обычный случай) безопасно отказывает кодом 1 без
# побочных эффектов — тот же путь мог быть заявлен ПРЕДЫДУЩЕЙ попыткой этого
# же раунда (3р.1а допускает повторный вызов peer с тем же $PEER_FILE).
if [ ! -s "$PEER_FILE" ]; then
  rm -f "$PEER_FILE"
  bash "${IWE_SCRIPTS:-$HOME/IWE/scripts}/session-guard.sh" note-file --forget "${PEER_FILE#"$SESSIONS_DIR"/}" \
    --slug "$SESSION_ID" >/dev/null 2>&1 || true
else
  # Тот же разрыв, что в турн-loop Шага 3.1 (найдено 2026-08-10) — $PEER_FILE
  # идёт через Bash-редирект, scope gate его не видит без явной регистрации.
  # Отказ регистрации — громкий (WP-530 Ф67, 25.09): три сессии за день молча
  # потеряли заявки на файлы напарников (прежнее `2>/dev/null || true`), scope-proof
  # при закрытии не сошёлся, семафоры остались открытыми. Раунд не роняем, но
  # писатель ОБЯЗАН увидеть WARN и повторить note-file до Шага 4.5.
  if ! note_err=$(bash "${IWE_SCRIPTS:-$HOME/IWE/scripts}/session-guard.sh" note-file "$PEER_FILE" \
      --wp "<WP-NNN из Шага 0б>" --slug "$SESSION_ID" 2>&1); then
    printf 'WARN: note-file failed for %s: %s\n' "$PEER_FILE" "$note_err" >&2
    printf 'NOTE_FILE_WARN %s\n' "$PEER_FILE"
  fi
fi
```

**3р.1а Валидация реплики (WP-509)**

Применить **перед** записью в `round_skips` или консенсус. Реплика считается `valid`, если все 4 проверки прошли (с исключением для discovery-раундов, см. ниже):

1. **По предмету:** файл не пуст, frontmatter распарсен, тело содержит ответ на задачу раунда (не только формальные фразы / повтор условия).
2. **Роль исполнена:**
   - В **discovery-раундах 0–2** (`PEER_COUNT >= 2`): `content_role` совпадает с ролью, предложенной в `00-writer.md.proposed_roles` для этого `agent_id`, либо peer явно предлагает другую ad-hoc роль с обоснованием.
   - В **содержательных раундах** (`ROUND >= 1` после §2.5.3): `content_role` совпадает с ролью, согласованной в `meta.yaml.roles` для этого `agent_id`; если в реплике предлагается ad-hoc роль — см. §1.2 «In-session ad-hoc role signal».
3. **Нет побочных действий:** в stdout-ответе нет маркеров вида `FILE_WRITTEN`, `MEMORY_UPDATED`, `TOOL_CALLED` и т.п.; кроме того, **не проверять файловую систему напрямую** — адаптер гарантирует изоляцию, но агент-участник может декларировать действия в тексте.
4. **Непротиворечивость фактам:** если реплика ссылается на конкретный факт (SHA, имя файла, статус РП, commit), проверить его по доступным источникам; при несовпадении — `failed` с причиной `fact_mismatch`.

Если реплика `invalid`:
- Инкремент `meta.yaml.peer_attempts[vendor]`.
- Если `peer_attempts[vendor] < max_peer_attempts` — повторить вызов этого же peer в том же раунде с уточняющим промптом (причина invalid + контекст раунда).
- Если `peer_attempts[vendor] >= max_peer_attempts` — зафиксировать `meta.yaml.peer_failures += [{round: ROUND, vendor: vendor, reason: <проверка>}]`, установить `meta.yaml.participant_status[vendor] = "failed"`, исключить vendor из требования консенсуса в §3р.3 (как `round_skips`, но с явным статусом `failed`).

Пустой файл или `STATUS != 0` → этот напарник пропущен в этом раунде (не блокирует раунд, DP.SC.154 «Раунды вместо бесконечного круга»): записать `meta.yaml.round_skips.round_<NN>: [..., vendor]`, инкремент `peer_attempts[vendor]`; при исчерпании попыток — `participant_status[vendor] = "failed"` и `peer_failures += [...]`.

### 3р.2 Показать пилоту

Резюме по КАЖДОМУ напарнику раунда (не только последнему) — кто что сказал, кратко.

### 3р.3 Проверить маркеры у всех реплик раунда

Применяется к репликам напарников этого раунда (3р.1) **и**, при возврате из 3р.4, к реплике писателя того же раунда — обработка маркеров одинаковая для обеих ролей, разница только в том, что писатель пишет последним в раунде.

- `ESCALATE_TO_USER` у любого участника (включая писателя) → тот же процесс, что в §3.3 (запись `escalation-NN.md`, пауза на ответ пилота).
- `OFFER_HANDOFF`/`ACCEPT_HANDOFF`/`REQUEST_HANDOFF` у любого участника → при подтверждённом `ACCEPT_HANDOFF` (реплика-адресат отвечает на `OFFER_HANDOFF` предыдущей реплики) — append `{round, from, to, reason}` в `meta.yaml.handoff_history` И обновить `meta.yaml.write_token_holder` на нового держателя. `REQUEST_HANDOFF` без ответного `OFFER_HANDOFF` держателя — не меняет ничего, просьба зафиксирована в реплике и всё.
- `CONSENSUS` — «консенсус раунда»: учитываются только участники со статусом `active` (не `round_skips` этого раунда и не `participant_status == failed`). `DONE=true`, если у каждого активного участника есть либо `CONSENSUS`, либо `PASS` без встречных возражений в теле реплики. Хотя бы один содержательный контраргумент без `CONSENSUS` у активного участника → раунд не закрыт. **Проверка поведенческих утверждений — та же, что в §3.3** (цитата file:line/правила обязательна для любого «уже делает X» в резюме консенсуса, иначе не факт, DONE не выставлять).
  - Если все активные участники поставили `CONSENSUS`/`PASS` → `result_class` для report.md = `agreed`.
  - Если консенсус достигнут среди активных, но один или несколько участников имеют `participant_status == failed` (исчерпаны попытки в этом или предыдущих раундах) → `DONE=true`, но `result_class` = `partial`; отказавшиеся участники и причины фиксируются в `report.md §5`.
  - Если ни один участник не имеет `CONSENSUS`/`PASS`, но все технически ответили — раунд не закрыт, продолжаем (или `ROUND >= rounds_limit` → §3р.5).

### 3р.4 Реплика писателя

Если 3р.3 уже установил `DONE=true` по репликам напарников этого раунда → писатель реплику в этом раунде не пишет, сразу к Шагу 3.5 (Decision Gate).

Иначе — писатель отвечает (`$(printf '%02d' $ROUND)-writer.md`, тот же формат frontmatter, что в Шаге 2, плюс те же маркеры `CONSENSUS`/`ESCALATE_TO_USER`/`OFFER_HANDOFF`/`ACCEPT_HANDOFF`/`REQUEST_HANDOFF`, что и у напарников — писатель тоже может держать или передавать write token). Применить к этой реплике проверку маркеров из 3р.3.

Если после этого `DONE=true` (писатель сам поставил `CONSENSUS`, приняв позицию раунда) → Шаг 3.5.

Иначе, если `ROUND >= rounds_limit` (default 6) → к 3р.5 (спор без консенсуса).

Иначе — `ROUND += 1` → 3р.1.

### 3р.5 Спор между 3+ позициями (после исчерпания rounds_limit без консенсуса)

> Учитывать `participant_status`: участники со статусом `failed` не голосуют и не блокируют принятие решения оставшимися.

Применить критерий обратимости (DP.SC.154 «Разрешение спора между 3+ позициями») **до** эскалации:
- Решение обратимо и в пределах полномочий **активных** участников → писатель фиксирует позицию большинства среди `active` (2 из 3 или большинство при N>3), несогласие меньшинства — в `report.md` §3 «Отвергнутые альтернативы`, `DONE=true`, `result_class` = `partial` если есть `failed`-участники, иначе `agreed` → Шаг 3.5.
- Решение необратимо, вне полномочий, ИЛИ сам вопрос обратимости спорен → `ESCALATE_TO_USER: rounds_limit exhausted, no consensus, irreversible or scope-disputed` → пауза на пилота.

---

## Шаг 3.5. Decision Gate (после консенсуса)

> **Когда срабатывает:** `DONE=true` через CONSENSUS-маркер в Шаге 3.3 (турн-loop) или 3р.3 (round-loop) — не через `TURN >= 10`/`ROUND >= rounds_limit` без консенсуса, там сразу Шаг 3р.5 или Шаг 3.8 (Close-Trigger Gate).
> **Зачем:** консенсус ≠ реализация. Это **легитимный choice-question** для пилота (выбор объёма работы, не yes/no на готовое решение). Исключение из P5 — пилот сам подтвердил: «здесь от меня нужно согласование» (триггер 2026-05-30, WP-367 Ф5).
> **Обязательно:** перед запросом — **краткое резюме консенсуса на пальцах**, чтобы пилот мог осознанно выбрать. Запрос без резюме = механический «выберите А/Б» без понимания.

Извлечь резюме консенсуса: `PEER_COUNT==1` → `grep "^CONSENSUS:" "$PEER_FILE" | sed 's/^CONSENSUS: //'`. `PEER_COUNT>=2` → пройти все `${SESSION_DIR}/$(printf '%02d' $ROUND)-peer-*.md` последнего раунда, взять резюме первого файла с маркером `CONSENSUS:` (если формулировки разошлись — писатель сводит их одним предложением сам, не берёт произвольно один голос).

**Финальный стоп-контроль поведенческих утверждений (двойная проверка, найдено 18.10, WP-529).** §3.3/3р.3 уже должны были поймать это на входе — этот повтор здесь специально для случая, когда писатель сам переформулировал резюме при сведении нескольких голосов (строка выше) и мог ВНЕСТИ поведенческое утверждение, которого не было в исходных репликах участников. Если итоговое резюме (после сведения) утверждает «механизм/код уже делает X» — проверить, что цитата (file:line/правило) есть именно в ЭТОМ, сведённом тексте, не только где-то раньше в журнале хода. Нет цитаты → не показывать резюме пилоту как факт: вернуться в цикл за цитатой или явно пометить как непроверенное предположение прямо в тексте «на пальцах» ниже.

**Верификация первоисточника перед Decision Gate (уроки 18.09 WP-581 и 24.09 WP-484).** Если консенсус опирается на внешний проверяемый факт (политика платформы, статус GitHub issue, доступность фичи у вендора) или на одно утверждение, прочитанное в одном месте (включая комментарий в коде) — и решение существенно меняется в зависимости от него: до объявления резюме пилоту сделать один цикл проверки первоисточника (WebFetch/WebSearch на сам объект, не пересказ; для «внутренних» фактов — `ls` соседних скриптов/их последних коммитов, не только названный файл). Консенсус двух агентов не проверяет входные данные: критик без собственного доступа к источнику физически не может заметить ошибку в факте. Признак необходимости: решение держится на одной ссылке/заголовке, а не на прочтении полного источника.

**Резюме на пальцах** — обязательная часть. Формат (без технических терминов, кодов, путей):

```
Консенсус достигнут.

Что обсуждалось: <одной фразой>
К чему пришли: <2-3 строки человеческим языком — суть решения>
Что предлагается реализовать: <список изменений, по 1 строке каждое; без файлов, путей>
Сколько займёт реализация: ~<N>h (включая ревью + smoke + deploy)
Изменения у других пользователей: <если есть — что и как доставляется; если нет — «только локально»>
```

После резюме — choice question:

```
Что дальше?
  А. Только зафиксировать → report-draft.md и остановка. Закрытие сессии — отдельное решение: Шаг 3.8 (Close-Trigger Gate), только по слову пилота «закрывай»; выбор этого варианта слова о закрытии не заменяет.
     Реализация — отдельный РП/фаза при следующей сессии.
  Б. Реализовать сейчас → ревью → проверить → задеплоить → Шаг 3.8 (Close-Trigger Gate).
```

Дождаться ответа пилота. Записать выбор в `meta.yaml` (Bash sed):
```yaml
implementation_pipeline: false | true
```

- **А** → `IMPLEMENTATION=false`, перейти к Шагу 3.8 (Close-Trigger Gate).
- **Б** → `IMPLEMENTATION=true`, перейти к Шагу 3.6.

**Default при молчании пилота:** Б (реализация сейчас), per правило 11 «финиш > отлог». Применять только если пилот явно не ответил в течение разумного времени (например, пропустил Decision Gate в скрипте). Молчание пилота на ЭТОМ вопросе (объём работы) не эквивалентно триггеру закрытия — Шаг 3.8 после реализации проверяется в любом случае, дефолт-Б сюда не переносится.

**Triggers automatic-defer** (без запроса пилоту — сразу А):
1. Реализация требует нового РП (новый scope, не покрытый текущим РП).
2. Требуется ArchGate (новое архитектурное решение системного уровня).
3. Контекст полностью переключился (другая часть системы; нужен новый framing).

При срабатывании trigger — анонс пилоту с резюме (НЕ запрос), потом Шаг 3.8 (Close-Trigger Gate).

---

## Шаг 3.6. Implementation Pipeline (опциональный)

> **Активируется:** только при `IMPLEMENTATION=true` в Шаге 3.5.
> **Принцип:** writer применяет решение → cold-context Agent делает code review → writer фиксит → built-in `/verify` запускает smoke → deploy → секция «Реализация и проверка» в report-draft.md.
> **Завершение:** в любой подшаг можно эскалировать к пилоту через `ESCALATE_TO_USER:` маркер (как в Шаге 3.3) — записать `escalation-NN.md`, дождаться ответа.

### 3.6.1 Implementation

**Гейт содержимого для зарезервированных решений (найдено в Цехе 11-12.10.2026 — см. «Scope boundary» выше; усилено 12.10 после второго и третьего повтора в той же сессии, см. ниже).** До анонса ниже проверить каждый файл будущего `CHANGED_FILES` против списка «решения, зарезервированные за пилотом» (Scope boundary: WeekPlan, Strategy.md, monthly-priorities.md, пул/список РП недели, вердикты журнала гипотез — любой документ, где содержание есть решение, а не метод его исполнения):

- Согласие напарника(ов) на Decision Gate (Шаг 3.5) покрывает ТОЛЬКО то, что там спрашивалось явно — как правило, метод и объём работы («зафиксировать или реализовать сейчас», «делать Х сейчас или потом»). Оно не распространяется на содержание такого файла, если конкретный текст правки пилоту не предъявлялся.
- **Правило ≠ готовый результат (найдено в Цеху 12.10, тот же день, третий повтор подряд).** Пилот может ответить не готовым построчным списком, а правилом или критерием («оставь только то, что относится к N направлениям месяца»). Правило — не решение по каждой строке: писатель обязан сначала ПРИМЕНИТЬ правило и ПОСЧИТАТЬ результат, затем показать пилоту именно этот посчитанный результат (кого оставляет, кого убирает) и дождаться подтверждения ИМЕННО его — до какой-либо правки файла. Формулировка правила от пилота сама по себе гейт не закрывает.
- **Перед КАЖДОЙ правкой файла из списка, не только перед первой за сессию (найдено в Цеху 12.10, тот же день, второй повтор).** Прежняя формулировка «перед первым Edit/Write этого файла» ошибочно разрешала не повторять показ для второй и последующих правок того же файла в одной сессии — живой случай: первая правка плана недели в сессии прошла через показ-и-ожидание, вторая (другое содержание, другая причина правки) была опубликована без повторного показа, потому что «первая правка этого файла» уже состоялась раньше. Каждая правка, меняющая содержание набора/решения (не только самая первая), требует своего предъявления и своего ожидания — расход «гейт уже пройден для этого файла в этой сессии» запрещён.
- Если хотя бы один файл попадает в этот список — анонс файлов и метода (ниже) НЕ достаточен сам по себе. Перед КАЖДЫМ Edit/Write такого файла, меняющим содержание (не форматирование без изменения решения), предъявить пилоту полное содержимое предлагаемой правки (построчный диф для правок существующих строк; полная таблица кандидатов — если меняется состав набора, например пул РП недели) и дождаться его решения по каждой строке/изменению отдельно, не общего «да, продолжай».
- Без этого предъявления Edit/Write такого файла запрещён — это стоп самого шага, не напоминание выше по тексту скилла.

Анонс пилоту:
```
Реализация консенсуса <SESSION_ID>
Файлы: <list of files with absolute paths>
Репо: <repo names, separated by " · ">
Метод: Edit/Write tools напрямую
```

Writer применяет изменения через Edit/Write. Запрещено:
- Менять файлы вне анонсированного списка без нового анонса.
- Делать commit на этом этапе (commit — только Шаг 3.6.5).
- Применять Edit/Write к файлу из списка «решения, зарезервированные за пилотом» без прохождения гейта содержимого выше — каждый раз заново, включая повторные правки того же файла в этой же сессии.

Зафиксировать список изменённых файлов в переменной `CHANGED_FILES` (один путь на строку).

### 3.6.2 Code Review (cold-context)

Переменные итерации: `REVIEW_ITER=1` при первом входе в 3.6.2, инкрементируется в 3.6.3 при Critical.

Сохранять отчёт в `${SESSION_DIR}/review-$(printf '%02d' $REVIEW_ITER).md` (Write).

Вызвать `Agent` (subagent_type: general-purpose) с явным чек-листом:

```
Agent(
  description: "Code review post-consensus",
  subagent_type: "general-purpose",
  prompt: """
    Cold-context code review результатов peer-сессии <SESSION_ID>.

    Контекст консенсуса: <резюме из 3.5>
    Изменённые файлы:
    <CHANGED_FILES>

    Прочитай каждый файл (только указанные строки/функции, не весь файл если он большой).
    Проверь по чек-листу:
    1. asyncio runtime: ищи `wait_for(coro)` без `shield` → coroutine reuse. Ищи fire-and-forget tasks которые читают/пишут одну строку БД из разных мест.
    2. Shell ordering: function call ДО function definition. `set -u` соблюдён?
    3. SQL race: cross-file writers в одну строку без атомарности (UPDATE ... RETURNING или SELECT FOR UPDATE).
    4. Lock enforcing: при collision — `exit N` или `log WARN && continue`? Если advisory — это intentional или баг?
    5. Контекст-специфика консенсуса: <дополни из резюме, если есть инварианты>.

    Верни отчёт в формате:
    ## Critical (must fix before deploy)
    - <file:line-range>: <issue> | fix: <conkr>
    ## High
    - ...
    ## Medium
    - ...
    ## OK (что проверено и норм)
    - ...

    Не предлагай рефакторинг или стиль — только runtime баги и нарушения чек-листа.
  """
)
```

Сохранить отчёт ревьюера в `${SESSION_DIR}/review-NN.md` где `NN = printf '%02d' $REVIEW_ITER` (Write).

### 3.6.3 Review Outcome

Показать пилоту краткое резюме отчёта (Critical + High count + один пример).

**Если есть Critical:**
- Обобщить каждую находку в тип дефекта (не только «эта строка неверна»), пройти весь артефакт на этот тип (CLAUDE.md § Code Style) → применить фиксы (Edit) → инкремент `REVIEW_ITER += 1` → вернуться к 3.6.2 (новый review-NN.md).
- Лимит итераций: 3. Если на 3-й итерации остался Critical → ESCALATE_TO_USER с приложением последнего review.

**Если только High/Medium:**
- Спросить пилота: «Есть N High и M Medium замечаний. Фиксить сейчас или после deploy?»
- Записать решение в meta.yaml (`review_iterations: <N>`, `unresolved: <count>`).

**Если только OK:**
- Продолжить к 3.6.4.

### 3.6.4 Smoke Verification

Вызвать built-in `/verify` через Skill tool:

```
Skill(
  skill: "verify",
  args: "code Smoke test changes from peer-session <SESSION_ID>. Files: <CHANGED_FILES>. Consensus invariants to check: <list из 3.5 — что должно работать>. Falsification conditions (одно условие на строку, у каждого свой якорь: код в обратных кавычках, путь, строка, файл:N):\n<для каждого инварианта — какое наблюдаемое его нарушило бы>. Запусти приложение/тесты, проверь поведение, верни вердикт с traceback при FAIL."
)
```

`/verify` сам решит как проверять (запуск приложения, pytest, manual instructions для UI). Условие опровержения — обязательный вход `/verify` (его Шаг 2); формулируется из инвариантов консенсуса, а не после результата.

**Результат (все пять исходов `/verify`, ни один не трактуется молча как другой):**
- PASS → перейти к 3.6.5.
- CONDITIONAL → показать пилоту высокие замечания, спросить «фиксить сейчас или деплоить с ними?»; без ответа к 3.6.5 не переходить.
- FAIL → показать traceback пилоту, спросить «фиксить и повторить или escalate?»
  - «фиксить» → Edit → вернуться к 3.6.2 (review после фиксов) или сразу 3.6.4 если фикс точечный (по согласию пилота).
  - «escalate» → ESCALATE_TO_USER + escalation-NN.md.
- UNKNOWN → не подтверждено, но и не провал: показать пилоту «Недостающее свидетельство» и «Как получить»; добыть свидетельство и повторить 3.6.4, либо пилот явно принимает деплой без него.
- NOT_VERIFIABLE → проверка не поставлена: показать «Причину» (обычно — условие опровержения не сформулировано); переформулировать условие и повторить 3.6.4. Не FAIL артефакта, не PASS.

Сохранить вывод `/verify` в `${SESSION_DIR}/verify-01.md`.

### 3.6.5 Deploy

Для каждого репо в списке изменённых файлов. Сообщение коммита сначала записать инструментом записи файлов (не через оболочку) в `${IWE_WORKSPACE:-$HOME/IWE}/.iwe-runtime/peer-prompts/<SESSION_ID>-commit-msg.txt`:

```text
<type>(<scope>): <короткое описание>

Refs: peer-session <SESSION_ID>
Review iters: <REVIEW_ITER>
Verify: <вердикт /verify из 3.6.4: PASS | CONDITIONAL (принято пилотом) | UNKNOWN (деплой без свидетельства принят пилотом)>
```

```bash
cd <repo path>
git status --short
# pathspec после `--`: commit ТОЛЬКО свои файлы. Bare `git commit` сметает
# чужое pre-staged из общего индекса (mis-attribution, см. 2026-06-20-39).
git add <specific files — НЕ git add . и НЕ git add -u>
# Message text is written to a file with a file-writing tool, never inlined in
# double quotes: backticks and $(...) in a description would be executed.
git commit -F "${IWE_WORKSPACE:-$HOME/IWE}/.iwe-runtime/peer-prompts/<SESSION_ID>-commit-msg.txt" -- <те же specific files>

# WP-537: заявить свой коммит в семафоре сессии. Без этой строки закрытие
# сессии проверяет «моя работа опубликована» по состоянию ВСЕЙ ветки, и один
# непушенный коммит соседней сессии отклоняет честную заявку.
# `-C "$NC_ROOT"` явно, не полагаясь на `cd` выше: верхнеуровневый `cd` в этом
# репозитории блокирует собственный PreToolUse-хук (destructive-guard.sh),
# и агент, переписывающий блок под `git -C`, без явного корня получил бы
# HEAD текущего каталога вызова, а не репозитория деплоя — то самое ложное
# свидетельство, ради исключения которого коммит выводился не из истории
# файлов, а из явной заявки (найдено холодным ревью этой же сессии).
NC_ROOT=$(git -C <repo path> rev-parse --show-toplevel)
NOTE_COMMIT="${IWE_SCRIPTS:-$HOME/IWE/scripts}/session-guard.sh"
[ -x "$NOTE_COMMIT" ] || NOTE_COMMIT="${IWE_WORKSPACE:-$HOME/IWE}/scripts/session-guard.sh"
if ! bash "$NOTE_COMMIT" note-commit "$(git -C "$NC_ROOT" rev-parse HEAD)" \
       --repo "$(basename "$NC_ROOT")" --agent claude-code --slug "$SESSION_ID"; then
  echo "WARN: коммит не заявлен в семафоре — закрытие сессии проверится по всей ветке" >&2
fi
```

**Публикация — через общий шлюз координации, не голым `git push`** (WP-530 Ф9, 19.08, пир-сессия с Codex: голый push здесь обходил тот же `ds-publish.sh`, которым уже пользуются quick-close/day-close/week-close/month-close/day-open — живой тест 18.08 дал 7 из 8 конфликтов при параллельной интерактивной записи без него). `REPO_ROOT` — обязательно через `git rev-parse --show-toplevel` вызывающего репо, не сырой путь (caller может стоять в поддиректории):

```bash
REPO_ROOT=$(git -C "<repo path>" rev-parse --show-toplevel)
. "${IWE_WORKSPACE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}/scripts/lib/publish-gate.sh"
SHA=$(git -C "$REPO_ROOT" rev-parse HEAD)
# normal по умолчанию; high — ТОЛЬКО если пилот на Decision Gate (Шаг 3.5)
# явно пометил реализацию как срочную (никакого отдельного CLI-флага —
# приоритет уже единственная ручка).
PRIORITY="normal"
if is_ds_repo_by_origin "$REPO_ROOT"; then
    IWE_AGENT=claude-code publish_commit "$REPO_ROOT" "$SHA" "$PRIORITY" "peer-session <SESSION_ID> deploy" \
        || { echo "publish_commit не удался — см. stderr/Telegram-алерт ds-publish.sh" >&2; exit 1; }
else
    push_branch "$REPO_ROOT"
fi
```

> **Код возврата обязателен, не только текст в stderr** (найдено холодным ревью Ф9): `|| echo ...` без `exit 1` делает последней командой ветки `echo`, который сам всегда успешен — компаунд `if/else` тогда выглядит завершившимся успешно даже когда `publish_commit` реально упал (ровно тот сбой, ради обработки которого существует шлюз). `exit 1` в конце `||`-блока — обязательная часть паттерна, не опция.

> **`IWE_AGENT=claude-code` перед `publish_commit` — обязательно, не косметика** (найдено 06.10, холодная проверка Fable + пир-сессия `2026-10-06-03-session-close-problems-audit`). `publish_commit` зовёт канонический `ds-publish.sh` → `isolate-push.sh:record_publication_receipts()`, который молча пишет `WARN: receipt v2 not recorded: no bound publishing agent/guard` и пропускает квитанцию, если `IWE_AGENT` не задан в окружении вызова — семафор закрывается по legacy-доказательству, но публикация остаётся без квитанции v2. Этот скилл задавал `IWE_AGENT` для `session-guard.sh open/close`, но не для публикации — живой `.iwe-runtime/publication-receipt-gaps.log` показал 21 пропуск за 05-06.10, 20 из них с этой причиной.

Записать commit SHA для каждого репо в переменную `DEPLOY_SHAS` (map: repo → sha).

**Если commit/publish fail** (pre-commit hook отказал, конфликт с remote, `ds-publish.sh`/`publish_commit` вернул non-zero):
- НЕ обходить хуки (`--no-verify` запрещён правилом 6).
- **НЕ пересчитывать `$SHA` заново через `git rev-parse HEAD` и не вызывать `publish_commit` повторно с новым значением** (живой дефект, `inbox/bugs/bug-2026-09-09-publish-commit-against-canonical-checkout-silently-drops-commit.md`, WP-530 Ф36/Ф38 — общая рабочая копия могла сдвинуться между двумя вызовами по причине, не связанной с этим коммитом; повторный вызов с фрешовым HEAD обнаруживает, что HEAD уже патч-эквивалентен чему-то опубликованному, и возвращает ложноположительный `PUBLISH_OK`, реально не опубликовав исходный `$SHA` — тот остаётся только в `reflog`). `$SHA` — значение конкретного коммита, зафиксированное один раз сразу после `git commit`; при неудаче публикации это же значение остаётся единственно верным на протяжении всего дальнейшего разбора этой публикации.
- Зафиксировать полный вывод шлюза и технический диагноз в файл эскалации; пилоту — одной короткой фразой причину и требуемое решение, со ссылкой на файл эскалации (тот же формат, что в §3.3), ESCALATE_TO_USER. Если пилот просит повторить — пересобрать через `session-guard.sh open --isolate` (изолированный worktree от актуального `origin/main`, как и предписывает сам `isolate-push.sh`) и разрешить конфликт там, а не повторным вызовом `publish_commit` на этом же `$SHA` в общем чекауте.
  **Передай `IWE_SESSION_ID` явно, тот же что и на первой попытке `open --isolate` этой сессии** (WP-484 Ф204, 18.10 — без него, для агентов без встроенной идентичности разговора, `open --isolate` теперь отказывает сразу; для claude-code/codex код сам выводит устойчивый id из идентичности разговора, но передать `IWE_SESSION_ID` вручную надёжнее и одинаково работает для любого напарника). Храни одно значение `IWE_SESSION_ID` на всю пир-сессию, не генерируй новое на каждый повтор — живой инцидент 16.10 (восемь осиротевших семафоров с одной беседы) получился именно из повторных `open --isolate` без этого.

### 3.6.6 Outcome дополнение к report-draft.md

Перед Шагом 4 (финализация) writer дописывает в `${SESSION_DIR}/report-draft.md` (если файл уже создан — append; если ещё нет — отметить что будет создан в 4.2 с включением этой секции) пометку для синтезатора:

В `${SESSION_DIR}/_outcome.md` (Write) — служебный файл для синтезатора:
```markdown
## Реализация и проверка

**Изменённые файлы:**
<CHANGED_FILES with one-line description each>

**Code review итераций:** <REVIEW_ITER>
**Unresolved (отложено на потом):** <count High/Medium или «нет»>

**Smoke verification:** PASS | FAIL (с пометкой что fix'нули)

**Deploy:**
- <repo1>: commit <sha1>
- <repo2>: commit <sha2>

**Открытые задачи после deploy:** <список или «нет»>
```

Этот файл будет включён синтезатором (Шаг 4.2) как обязательная секция при `implementation_pipeline: true`.

---

## Шаг 3.7. Рефлексия перед финализацией (WP-484, решение пилота 30.07)

> **Почему здесь:** пир-сессия — тоже сессия работы, вопрос рефлексии обязателен так же, как и в обычной Quick Close (Ф18), а не только там (Ф28 — этот разрыв и был найден 29.07). Порог и формулировка те же, что уже используются везде — не новый механизм, применение существующего.

**Порог:** тот же порог, что в `quick-close.yaml`, и та же формула вычисления, что уже проверена и починена в `gather-session-facts.sh` (WP-484 Ф26, 30.07 — наивный разбор ISO-даты дал баг «duration_min всегда 0» на BSD-date/macOS, эта же формула переиспользуется, не изобретается заново):
```bash
START_TIME=$(grep '^start_time:' "$SESSION_DIR/meta.yaml" | sed -E 's/^start_time: *"?([^"]*)"?$/\1/')
NOW_EPOCH=$(date -u +%s)
START_EPOCH=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$START_TIME" +%s 2>/dev/null \
    || date -u -d "$START_TIME" +%s 2>/dev/null \
    || echo "$NOW_EPOCH")
DURATION_MIN=$(( (NOW_EPOCH - START_EPOCH) / 60 ))
```
Если `DURATION_MIN ≤ 45` — пропустить рефлексию (короткая сессия, не задерживать пилота), перейти к Шагу 3.8 (Close-Trigger Gate) — длительность сессии освобождает только от вопроса рефлексии, не от проверки триггера закрытия.

Если `duration_min > 45` (порог поднят с 30 решением пилота 18.10, `CONCEPT-night-cycle.md §23`):

1. Показать пилоту краткий итог (2-3 строки, что сделали в этой пир-сессии — не пересказ turn-файлов, суть).
2. Спросить: «Что в этой сессии стоит запомнить на будущее — не про саму задачу, а про то, как шла работа?» (дословно вопрос Ф18, `CONCEPT-night-cycle.md §18`).
3. Записать ответ в дневной ledger (issue #409: скрипт есть не на каждой установке — не блокировать при отсутствии):
   ```bash
   if [ -f "$GOV_REPO_ROOT/scripts/ledger-append.sh" ]; then
     bash "$GOV_REPO_ROOT/scripts/ledger-append.sh" day "$(date +%F)" session_reflection "{\"wp\": \"<WP-NNN>\", \"answer\": <экранированный ответ>}" peer-conversation
   else
     echo "ledger-append.sh недоступен на этой установке — рефлексия не записана в дневной ledger"
   fi
   ```
4. Перейти к **Шагу 3.8 (Close-Trigger Gate)** — рефлексия НЕ равна разрешению закрывать, это отдельная проверка.

Пропуск ответа пилотом (ушёл, не ответил) — не блокировать: записать `"answer": "нет ответа"`, продолжить к Шагу 3.8 как обычно.

---

## Шаг 3.8. Close-Trigger Gate (обязательный, применяется всегда — с рефлексией и без неё)

> **Почему здесь:** найдено 14.08.2026 (пир-сессия `2026-08-14-07-wp520-freeze-enforce`) — писатель довёл implementation pipeline до конца (Decision Gate «Б. Реализовать сейчас») и без единого дополнительного слова пилота запустил весь конвейер финализации (Шаг 4: report.md, commit, `session-guard close`, ledger-запись). Пилот такого не просил ни разу за сессию. Корень: «реализовать сейчас» (ответ на Decision Gate Шага 3.5) — это решение об ОБЪЁМЕ работы, не о ЗАВЕРШЕНИИ сессии; правило «финиш > отлог» (довести реализацию до конца автономно) не даёт права автономно решать, что сессия закрыта. Готовая работа = сигнал доложить и остановиться, не сигнал закрывать.

**Проверка (механическая, не полагаться на память агента):** пилот произнёс явное триггерное слово закрытия («закрывай», «заливай и закрывай», «всё», «закрой сессию») ИМЕННО в этом обмене репликами — до или сразу после последнего сообщения писателя?

- **Да, триггер есть** → перейти к Шагу 4 (Финализация) как обычно.
- **Нет триггера** → **НЕ переходить к Шагу 4.** Показать пилоту итог одним сообщением: что реализовано, что задеплоено (repo + commit/PR), что осталось (декларативно, без вопроса) — и остановиться. Сессия остаётся технически открытой (семафор не снят, `report.md` не создан, ledger не тронут) до отдельного явного триггера пилота в следующем сообщении. Долгая автономная работа без закрывающего триггера — штатное состояние, не зависшая сессия и не повод торопиться закрыть «чтобы не оставлять хвост».

**Отличие от Decision Gate (Шаг 3.5):** Decision Gate спрашивает «зафиксировать план или реализовать сейчас» — про то, ЧТО делать. Этот гейт — про то, КОГДА заканчивать сам разговор с пилотом. Ответ «Б» на Decision Gate не переносится на этот гейт по умолчанию, даже если оба вопроса звучат похоже на «продолжай сам».

---

## Шаг 4. Финализация

### 4.1 Обновить meta.yaml

```bash
TURNS_DONE=$(find "$SESSION_DIR" -maxdepth 1 -name "[0-9][0-9]-*.md" | wc -l | tr -d ' ')
END_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)
tmpf=$(mktemp)
sed "s/^status:.*/status: \"completed\"/" "$SESSION_DIR/meta.yaml" |
  sed "s/^end_time:.*/end_time: \"$END_TIME\"/" |
  sed "s/^turns_count:.*/turns_count: $TURNS_DONE/" |
  sed "s/^escalations_count:.*/escalations_count: $ESCALATIONS/" > "$tmpf"
mv "$tmpf" "$SESSION_DIR/meta.yaml"
```

### 4.2 Синтез report-draft.md (не report.md — см. 4.2a)

> **Архитектурное ограничение:** Claude-писатель использует Agent tool для синтеза, т.к. Claude может запустить субагента Sonnet внутри сессии. Kimi-писатель (скилл `/peer-writer`) вынужден использовать bash pipe через `claude-peer-adapter.sh`, т.к. Kimi не имеет доступа к Claude Agent tool. Это осознанное различие, а не дрейф.
>
> **Субагент не пишет файл сам (найдено 2026-08-10, сессия `2026-08-10-08-wp7-update-fatigue-community`).** Платформенный guardrail блокирует `Write` у субагентов безусловно — это не временный сбой и не зависит от промпта, повтор `--finalize` не поможет. Субагент возвращает готовый текст отчёта как свой финальный ответ; файл пишет писатель (главный агент) сам.

Запустить субагент через Agent tool (Sonnet, context isolation) — промпт ниже прямо требует вернуть текст, не писать файл.
**Fallback:** если субагент вернул пустой текст, текст короче нескольких строк, или текст не начинается с `schema_version:` во frontmatter — синтез не удался (не пытаться отличить «недоступен» от «вернул мусор», причина неважна для дальнейшего шага). Писатель сам записывает заглушку (Write) в `report-draft.md`:

```markdown
---
session_id: <SESSION_ID>
generated_at: <now>
note: синтез не выполнен (субагент недоступен или вернул пустой результат)
---

# Итоговый отчёт

Стенограмма: см. файлы реплик в папке сессии.
Повтори синтез: `/peer-conversation --finalize <SESSION_ID>`
```

**Сверка атрибуции перед финализацией (урок 13.09, сессия `2026-09-13-05`).** Синтез систематически ошибается не в выводах, а в том, кому принадлежит довод и в каком раунде он прозвучал (независимая проверка нашла 4 ошибки атрибуции на 7 тем). После синтеза — сверить §2 отчёта построчно с репликами: для каждого тезиса открыть названный якорь и убедиться, что довод там и принадлежит названному агенту; проверяются только строки «Инициатор», «Эволюция», «Разрешение». Дополнительно: (а) ограничение возможностей напарника (нет дерева, нет инструментов), объявленное им в реплике, обязано попасть в отчёт рядом с зависимым выводом; (б) «согласился без возражений» — только про участника, который реально видел спорную реплику (порядок ходов — по времени файлов, не по порядку в таблице); (в) задание раунда писателя — тоже реплика: сохранять его как `NN-writer.md` в журнале сессии, не только отправлять напарникам, иначе в журнале остаётся разрыв (обе реплики раунда цитируют факты, которых нет ни в одном сохранённом файле).

### 4.2a Правило отложенной финализации (post-2026-05-22)

> **Инвариант:** `report.md` — только финальная версия. До явного Close-сигнала от пилота файл называется `report-draft.md`.

**При консенсусе (turn ≤ 10):**
- Не переименовывать в `report.md`.
- Спросить пилота: «Консенсус достигнут. Закрываем сессию или нужно дозакрытие?»
- Если пилот говорит «закрываем» → переименовать `report-draft.md → report.md` (шаг 4.3) **и снять заявку на черновик** (хук Write заявил путь в семафоре сам, а файла больше нет, поэтому `session-guard.sh close` откажет «путь не найден ни в одном checkout», WP-484 21.09): `bash "${IWE_SCRIPTS:-$HOME/IWE/scripts}/session-guard.sh" note-file --forget "<путь черновика относительно репозитория сессий, как в семафоре>" --agent claude-code --slug "$SESSION_ID"`, затем `note-file` для `report.md`. Отказ команды значит, что путь ещё есть на диске, в HEAD, в индексе, в истории веток/reflog или в заявленном коммите: заявка законна, черновик не удалять. Ответ «неизвестный флаг: --forget» значит устаревшую копию охранника на этом хосте (корневой чекаут `$HOME/IWE` отстаёт от `origin/main`): вызвать `session-guard.sh` из свежего checkout корневого репозитория (worktree от `origin/main`) абсолютным путём с `IWE_ROOT="${IWE_WORKSPACE:-$HOME/IWE}"`, не править семафор руками.
- Если пилот запрашивает дозакрытие → продолжить turn-loop, а при финальном Close дописать `## Дополнение (turns N–M, <timestamp>)` в тот же `report-draft.md`, затем переименовать.

**При дозакрытии:**
```markdown
## Дополнение (turns N–M, <timestamp>)

### Turn N — <тема>
...
```

**В `meta.yaml`:**
```yaml
extensions:
  - turns: [4, 5, 6]
    reason: "verification R23 + multiplier recalculation"
    appended_at: "2026-05-23T04:25"
```

**Запрещено:**
- Создавать `report-v1.md`, `report-v2.md` — одна сессия = один отчёт.
- Создавать supplement-директории — `$SESSIONS_DIR/YYYY-MM/DD/<id>/` (MC-sessions) = единое пространство.
- Продолжать писать `-writer.md`/`-peer.md` при `status: completed` — статус меняется только после Close-сигнала.

### 4.2b Стиль report.md (DP.SC.050)

> **Канал определяет стиль.** Turn-файлы (00-writer.md, 01-peer.md, ...) — технические, для агентов. report.md — разговорный, для пилота.
>
> При синтезе report.md из turn-файлов: **перепиши**, не копируй. Замени технические термины на бытовые (A1-A11), убери машинные маркеры (PASS, SHA, exit), переведи пассивный залог в активный.

Промпт субагенту:

```
Ты — синтезатор итогов диалога нескольких агентов (DP.SC.154, писатель + <PEER_COUNT> напарник(а/ов)).
Задача сессии: <задача>

Стиль: разговорный для пилота (A1-A11). Перепиши, не копируй turn-файлы.

Прочитай все файлы реплик в <SESSION_DIR> (00-writer.md, затем 01-peer.md.../01-peer-<vendor>.md... — в порядке нумерации, при PEER_COUNT>=2 несколько файлов на один номер раунда, читать все) в порядке нумерации.
Если в папке есть `_outcome.md` — прочитай его, он обязателен для §6.
Если есть review-NN.md / verify-NN.md — включи как якоря в §5/§6.
У тебя НЕТ доступа к Write — не пытайся создать файл. Верни готовый текст отчёта
целиком строго по схеме ниже как свой финальный ответ (это и есть механизм
доставки — вызывающий агент сам запишет то, что ты вернёшь, в report-draft.md).
Не оборачивай в ```markdown``` — пиши markdown напрямую, это единственное, что
должно быть в твоём ответе (без предисловий вида «вот отчёт:»).
Инвариант: result_class=agreed → §4 непустой; not-agreed → §4 = «Консенсус не достигнут».
Verify-якоря обязательны для код-ссылок (file:line-range). Теги [synthesized] в §4.

---
schema_version: 1
session_id: <SESSION_ID>
generated_at: <ISO-8601 UTC>
writer: <из meta.yaml: writer_agent>
peer: <из meta.yaml: peer_agent, при PEER_COUNT>=2 — все peer_agents через ", ">
duration_min: <(end_time − start_time) в минутах, целое>
escalations_count: <из meta.yaml>
result_class: agreed | partial | escalated | not-agreed
confidence: low | med | high
confidence_basis: <обязателен если confidence <= med; иначе omit>
ttl_event: <«до merge PR-NNN» | «до WP-NNN» | «до отмены пилотом» | omit>
cost_usd: <если известно; иначе omit>
cost_source: api | estimated | missing
---

# Итоговый отчёт

## 1. Исходная постановка
- **Задача:** <цитата из задания пилота, дословно>
- **Первоначальная позиция писателя:** <если зафиксирована в 00-writer.md; omit если нет>

## 2. Позиции по темам
Под каждой темой (затронута 2+ сторонами и повлияла на итог). При PEER_COUNT==1 — секция «Писатель/Напарник» как раньше. При PEER_COUNT>=2 — по каждому участнику, приславшему позицию, отдельной строкой (не сводить всех напарников в одну общую «Напарник»):

**Тема N: <формулировка>**
- Инициатор: <agent_id, кто поднял тему>
- **<agent_id 1>:** тезис → обоснование → якорь (file:line-range / Pack-ID)
- **<agent_id 2>:** тезис → обоснование → якорь
- **<agent_id N>:** ... (по одной строке на каждого участника, высказавшегося по теме)
- Эволюция (опц.): если позиция менялась — раунд/ход и причина
- Разрешение: что приняли + чей аргумент перевесил

## 3. Отвергнутые альтернативы
Omit если пусто. Только аргументированные обеими сторонами ИЛИ отвергнутые с контраргументом.
- Альтернатива → причина отказа → ссылка на ход

## 4. Зафиксированное решение
- <Исполняемая формулировка> [synthesized]
- **Главный аргумент:** <одной строкой>
- **Confidence:** low | med | high (если ≤ med — обоснование обязательно)
- **TTL-event:** <привязка к событию или omit>

Инвариант: agreed → непустой; not-agreed → «Консенсус не достигнут».

## 5. Открытые вопросы и эскалации
Omit если пусто.
- <Вопрос или эскалация>
- Статус: needs-decision | needs-verification | deferred
- Ссылка: escalation-NN.md или NN-peer.md (если есть)

## 6. Реализация и проверка
Omit если `implementation_pipeline: false` в meta.yaml.
Если true — обязательная секция, источник = `${SESSION_DIR}/_outcome.md`.
- **Изменённые файлы:** список с one-line описанием каждого
- **Code review итераций:** <N>
- **Unresolved:** <count High/Medium или «нет»>
- **Smoke verification:** PASS | FAIL
- **Deploy:** repo → commit SHA (по каждому затронутому репо)
- **Открытые задачи после deploy:** список или «нет»
- **Ссылки:** review-NN.md, verify-NN.md

## 7. Метаданные и навигация
- **Журнал:** ссылки на все NN-writer.md / NN-peer.md (или NN-peer-<vendor>.md при PEER_COUNT>=2) по порядку
- **Связанные артефакты:** Pack-IDs, файлы (PR, спецификации) — если упоминались
- **Пропуски раундов** (только при PEER_COUNT>=2 и непустом `meta.yaml.round_skips`): кто и в каком раунде не ответил — omit если пусто
- **Передача write token** (только при PEER_COUNT>=2 и непустом `meta.yaml.handoff_history`): раунд → от кого → к кому → причина, по каждой записи — omit если пусто
- **Стоимость:** $X (источник: api / estimated / missing) — omit если missing
```

Субагент вернул этот текст как финальный ответ (Agent tool без schema возвращает
его напрямую строкой) — прочитать этот ответ и применить fallback-критерий выше.
Прошёл проверку → записать (Write) как есть в `${SESSION_DIR}/report-draft.md`.
Не прошёл → записать заглушку из fallback вместо него. В обоих случаях пишет
писатель, не субагент.

### 4.3 Обновить индекс-черновик

Тот же черновик, что Шаг 1.3 открыл — `opened_at` сохраняется, остальные поля заменяются целиком (колонка «Агенты» — та же `+`-склейка при PEER_COUNT>=2):
```bash
IDX_LIB="$GOV_REPO_ROOT/scripts/lib/session-index-draft.sh"
[ -f "$IDX_LIB" ] || IDX_LIB="${IWE_TEMPLATE:-${IWE_WORKSPACE:-$HOME/IWE}/FMT-exocortex-template}/scripts/lib/session-index-draft.sh"
. "$IDX_LIB"
session_index_draft_write "$SESSION_ID" "$TODAY" "<задача ≤50>" \
  "claude-code / <PEER_VENDOR1>[+<PEER_VENDOR2>...]" "<TURNS/ROUNDS>" "<ESCALATIONS>" \
  "completed" "[report.md](<MONTH>/<DAY>/<SESSION_ID>/report.md)"
```

Установка без переносчика черновиков в индекс (программы session-index-snapshot.sh в папке программ репозитория управления; так у пользователей шаблона) — черновик никто не перенесёт, поэтому ещё и вести `00-index.md` напрямую, как до WP-537 (файла нет → создать, issue #568; строку сессии заменить по `SESSION_ID` или вставить первой в таблицу):
```bash
if [ ! -f "${IWE_WORKSPACE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}/scripts/session-index-snapshot.sh" ]; then
  IDX="$SESSIONS_DIR/00-index.md"
  [ -f "$IDX" ] || printf '%s\n' '# Индекс пир-сессий' '' \
    '| Дата | Сессия | Задача | Агенты | Ходы | Эскалации | Статус | Отчёт |' \
    '|------|--------|--------|--------|------|-----------|--------|-------|' > "$IDX"
  ROW="| $TODAY | $SESSION_ID | <задача ≤50> | claude-code / <PEER_VENDOR1>[+<PEER_VENDOR2>...] | <TURNS/ROUNDS> | <ESCALATIONS> | completed | [report.md](<MONTH>/<DAY>/<SESSION_ID>/report.md) |"
  if grep -qF "| $SESSION_ID |" "$IDX"; then
    ID="| $SESSION_ID |" ROW="$ROW" awk 'index($0, ENVIRON["ID"]) { print ENVIRON["ROW"]; next } { print }' "$IDX" > "$IDX.tmp"
  else
    ROW="$ROW" awk '{ print } /^\|------/ && !done { print ENVIRON["ROW"]; done = 1 }
      END { if (!done) print ENVIRON["ROW"] }' "$IDX" > "$IDX.tmp"
  fi
  mv "$IDX.tmp" "$IDX"
fi
```
В этом режиме `00-index.md` идёт в коммит сессии (Шаг 4.5) вместе с её файлами.

### 4.4 Закрытие (ОРЗ — сессионный файл рядом с папкой сессии)

> **До 2026-08-03 этот шаг и Шаг 4.5.0 писали в файл независимо, разными шаблонами и разными путями** (`SESSION_SLUG` здесь отбрасывал дату И номер сессии, `CLEAN_SESSION_ID` в 4.5.0 отбрасывал только дату) — на диске оставались два сиротских файла вместо одного (пример: `sessions/2026-08/2026-08-03-codex-wp510-strategy-questions.md` рядом с `sessions/2026-08/2026-08-03-04-codex-wp510-strategy-questions.md`). Найдено и исправлено в peer-session `2026-08-03-09-launchd-focustodo-weekly-export`. Теперь запись в файл — единственная, на Шаге 4.5.0; этот шаг только определяет общую переменную пути.

Slug-часть (без даты, с номером — та же формула, что `session-guard.sh` использует для своего ORZ-скаффолда, `session-guard.sh:241-243`): `SESSION_SLUG="${SESSION_ID#"$TODAY"-}"`

Целевой путь (используется здесь и на Шаге 4.5.0, WP-526 Ф2): `<MC-sessions>/<MONTH>/<TODAY>-<SESSION_SLUG>.md` — плоский Quick Close файл под месячной папкой внутри `$SESSIONS_DIR` (Шаг 1), без DD/ (DD/ — только для peer-session-папок). Тот же путь, что `session-guard.sh` уже создал (или создаст) как свой ORZ-скаффолд на Шаге 1.0 — содержимое пишется один раз, на Шаге 4.5.0.

### 4.4а Список файлов сессии для заявки и коммита (WP-524 Ф7, 20.11)

> **Почему отдельно.** Журнал сессий игнорирует `**/*.err` (`.gitignore` журнала, решение 10.09), а шаги 3.1/3р.1 оставляют непустой stderr адаптера рядом с репликой. Когда список файлов составляли перечислением папки сессии, `.err` попадал в заявку или явным путём в `git add`, и сохранение отказывало целиком (18.11, сессия `2026-11-18-21`: «paths are ignored»; 20.11, сессия `2026-11-20-10`: заявленный `.err` не сохраняется, снять заявку нельзя, пока файл на диске). Раннер закрытия папку сам не перебирает: он берёт пути у писателя (`commit-push.sh`, `commits[].paths`). Поэтому список строит писатель, одним способом для заявки (§4.5 п.3 и 4.5.1), для раннера (§4.5 п.4) и для коммита (4.5.1).

Правило: `.err` никогда не заявляется (`note-file`) и не передаётся в `git add`, `git commit` или раннеру явным путём, ни новый игнорируемый, ни старый отслеживаемый (в журнале их больше двух тысяч, до правила 10.09). Единственное исключение — отслеживаемый `.err`, который уже заявлен по ошибке (последний абзац ниже). Перечислять папку сессии целиком (`ls`, `find`, glob) для списка запрещено.

```bash
# Paths relative to the root of the journal copy the commit goes to.
# `git -C` instead of a top-level `cd` (a PreToolUse hook blocks it); `-z` with a
# NUL read loop works on macOS bash 3.2 (no mapfile). --no-renames lists a rename
# as delete + add, so the deletion reaches the commit too; `diff HEAD` covers
# staged and unstaged changes, deletions included. --relative: paths stay
# relative to $SESSIONS_DIR even when it is a subfolder (legacy sessions/).
REL="$MONTH/$DAY/$SESSION_ID"
SESSION_PATHS=()
SKIPPED_ERR=()
while IFS= read -r -d '' p; do
  case "$p" in
    *.err) SKIPPED_ERR+=("$p") ;;
    *) SESSION_PATHS+=("$p") ;;
  esac
done < <(
  {
    git -C "$SESSIONS_DIR" ls-files -z --others --exclude-standard -- "$REL"
    git -C "$SESSIONS_DIR" diff -z --name-only --relative --no-renames HEAD -- "$REL"
  } | sort -zu
)
[ "${#SESSION_PATHS[@]}" -gt 0 ] || { echo "в папке сессии $REL нет файлов для сохранения" >&2; exit 1; }
```

`SKIPPED_ERR` содержит только изменённые **отслеживаемые** `.err` (новые игнорируемые `--exclude-standard` уже отсёк). Пустой массив — обычный случай. Непустой бывает при дозакрытии старой сессии: изменённый отслеживаемый `.err` оставляет копию журнала грязной, и закрытие в отдельной копии откажет. Выход: скопировать файл за пределы рабочей папки IWE (например в scratchpad) для разбора и вернуть отслеживаемую версию: `git -C "$SESSIONS_DIR" restore --source=HEAD --staged --worktree -- <путь>`.

**Если `.err` уже заявлен по ошибке** (старый порядок, ручная заявка). Новый игнорируемый `.err`: перенести файл за пределы рабочей папки IWE → `session-guard.sh note-file --forget <путь>` → вернуть файл на место; охранник снимает заявку только когда пути нет на диске. Отслеживаемый `.err` так снять нельзя: путь есть в HEAD и истории, охранник заявку оставит. Такой файл сохранить вместе с сессией: добавить его путь к `SESSION_PATHS` (отслеживаемый путь git принимает явным путём, правило игнорирования на него не действует) и в отчёте одной строкой отметить, почему `.err` попал в коммит.

Предупреждение о целостности (`INTEGRITY-WARNING:`) из `.err` в историю само не попадёт: писатель переносит факт и текст предупреждения в свою реплику или §5 отчёта (шаги 3.1/3р.1).

### 4.5 Commit + push

**Сначала: включён ли выключатель пути закрытия (РП-561 Ф61 этап 2, решения пилота 15.11).** Проверить: `[ "${IWE_CLOSE_ROUTE_ENFORCE:-}" = 1 ] || [ -f "${IWE_WORKSPACE:-$HOME/IWE}/.iwe-runtime/close-route-enforce" ]` (переменная файл не выключает; выключить на хосте = удалить файл). Выключен — шаги 4.5.0–4.5.4 ниже как раньше. **Включён — короткого закрытия пир-сессии нет:** любая сессия с изменениями, пир-сессия тоже, закрывается обычным закрытием, чтобы закрытые фазы и завершённый РП ушли в архив; объявление `--close-path peer-session` от раннера не освобождает ни `close`, ни хуки (`close-runner-gate.sh` после слов о закрытии не пропустит прямой коммит 4.5.1 до старта раннера, Stop-гейт требует закрытия раннером, у Кодекса — `quick_close_gate.py`). Порядок при включённом выключателе:

1. 4.5.0 — записать закрывающий ОРЗ-файл, как ниже.
2. 4.5.0а — только пункты 1 и 1а (поле «Следующий шаг» и файл для сверки); пункт 2 (проверка опубликованной карточки) пропустить: публикация карточки до раннера заблокирована, а поле проверяют шаг раннера `wp-context-update` и итоговая проверка R23 (`handoff_next_step`). 4.5.0б — как ниже, без коммита.
3. Составить список файлов сессии по §4.4а, собрать из него `PATHS` первыми строками блока 4.5.1 (до цикла `git add`) и заявить их изнутри репозитория сессий циклом `note-file` из 4.5.1, но без `git add` и `git commit`: раннер откажет коммиту незаявленного пути. Файлы `.err` в список не входят.
4. `/run-protocol close` той же сессии: раннеру передать в коммитах репозитория сессий ОРЗ-файл и пути `SESSION_PATHS` поштучно (не папку журнала целиком: раннер делает `git add` переданных путей, и папка унесла бы изменённый отслеживаемый `.err`), в коммитах DS — карточку РП. Раннер сам делает коммит и публикацию, архивацию, итоговую проверку R23 и в конце вызывает `close`.
5. Шаги 4.5.1–4.5.4 не выполнять. Рефлексию шага 3.7 второй раз не задавать, если раннер спросит её сам.

Сессия без изменений (доказано в отдельной копии, журнала пир-сессии нет) закрывается одним `session-guard.sh close ... --pilot-close-word "<слово пилота>"`: он снимает отметку и обязательство закрытия. Что выберет программа, видно заранее: `session-guard.sh close --explain --agent claude-code --slug "$SESSION_ID"`.

**4.5.0 Записать закрывающий ОРЗ-файл сессии** (единственная точка записи — формула пути и обоснование см. Шаг 4.4; заодно закрывает служебный семафор session-guard, если Шаг 1.0 его создал):

```bash
# Путь строится ТОЙ ЖЕ формулой, что session-guard.sh использует для своего
# ORZ-скаффолда (session-guard.sh:241-243, WP-484 31.07 — защита от задвоения
# даты) — $SESSION_SLUG уже определён на Шаге 4.4. SESSION_ID здесь ВСЕГДА
# начинается с "$TODAY-" (Шаг 1: "${TODAY}-${NUM}-${SLUG}"), поэтому склейка
# "${TODAY}-${SESSION_ID}" без предварительного вычитания задваивала бы дату.
# `agent:` — обязательный ключ по списку session-guard.sh:474 (validate_orz);
# без него Шаг 4.5.2 (close) падает "в frontmatter отсутствует ключ 'agent:'".
# `writer:` держим тоже — для согласованности с meta.yaml.writer_agent.
# WP-526 Ф2: GUARD_ORZ и все относительные пути внутри файла — теперь
# относительно $SESSIONS_DIR (MC-sessions), не $GOV_REPO_ROOT/sessions.
GUARD_ORZ="$SESSIONS_DIR/$MONTH/${TODAY}-${SESSION_SLUG}.md"
cat > "$GUARD_ORZ" <<EOF
---
date: $TODAY
type: peer-session
wp: <WP-NNN>
agent: claude-code
writer: claude-code
peer: [<PEER_AGENT_ID>, ...]      # список; при PEER_COUNT==1 — один элемент
duration_h: <(end_time - start_time) в часах, 1 знак>
artifacts: [$MONTH/$DAY/$SESSION_ID/report.md]
session_id: $SESSION_ID
---

## Главный инсайт

EOF
# The insight is free text (backticks, $(...), even a line "EOF"): written
# beforehand with a file-writing tool to the path below, never through the shell.
INSIGHT_FILE="${IWE_WORKSPACE:-$HOME/IWE}/.iwe-runtime/peer-prompts/$SESSION_ID-insight.txt"
test -s "$INSIGHT_FILE" || { echo "нет файла инсайта $INSIGHT_FILE — записать его инструментом записи файлов" >&2; exit 1; }
cat "$INSIGHT_FILE" >> "$GUARD_ORZ"
cat >> "$GUARD_ORZ" <<EOF

## Контекст

Пир-сессия $SESSION_ID — полная стенограмма и синтез в MC-sessions:$MONTH/$DAY/$SESSION_ID/.

## Достигнуто

| Артефакт | Описание |
|----------|----------|
| $MONTH/$DAY/$SESSION_ID/report.md | Итоговый отчёт пир-сессии |

## Ключевые решения

См. report.md §4.
EOF
```

Если запись упала (директория недоступна, диск полон) — не блокировать финализацию: сообщить пилоту одной строкой и продолжить; Шаг 4.5.1 возьмёт `$GUARD_ORZ` в PATHS, только если файл есть на диске, иначе коммит пойдёт без него с предупреждением.

**4.5.0а Поле «Следующий шаг» карточки РП (WP-484 Ф257, M2/M6).** Пир-сессия закрывается мимо раннера Quick Close, поэтому поле, с которого начнётся следующая сессия, обновляет писатель сам, ДО коммита:

1. В карточке РП (`inbox/WP-N/WP-N.md`, секция `## Осталось`) переписать на месте поле «Следующий шаг»: метка ровно `**Следующий шаг:**` (без даты), одна строка на фазу, `ФN — первое действие`; фаза другого РП — только с номером РП (`РП-561 Ф46`); параллельные сессии того же РП — своя строка фазы заменяется, строки других фаз остаются. Значение — по последнему решению пилота в этом чате, а не по тому, что было в карточке при последней правке (РП-611, 04.11: поле обновили за полтора часа до закрытия, решение пилота прозвучало позже и в поле не попало). Не «продолжай по плану», не «см. фазы», не прежнее значение. Формат и стоп-фразы — `protocol-close.md` § «Формат «Осталось»». Карточку закоммитить и опубликовать в репозитории управления тем же путём, что остальные изменения РП (Шаг 3.6.5).
1а. **Свой следующий шаг для сверки (WP-484 Ф285, М1).** Записать инструментом записи файлов ровно текст поля «Следующий шаг» (свой следующий шаг для следующей сессии, как в отчёте; строку «Дальше» пилоту пишешь отдельно простыми словами по правилу 6 пака, РП-605 — с полем она не совпадает) в `${IWE_ROOT:-$HOME/IWE}/.iwe-runtime/peer-prompts/$SESSION_ID-next-step.txt`. Проверка сравнивает его с полем карточки; без файла — отказ `HANDOFF_AGENT_NEXT_MISSING`. Предел: если устаревший текст скопирован и в поле, и в файл, проверка его не поймает — сверка с последним решением пилота остаётся на писателе.
2. Прогнать проверку (решение пилота 10.11, Ф285: проверяется опубликованная карточка; блокируют только `HANDOFF_AGENT_NEXT_MISSING`, `HANDOFF_AGENT_PHASE_MISSING`, `HANDOFF_UNKNOWN_PHASE` вне белого списка `machine/handoff-phase-allowlist.yaml`, остальные коды предупреждают; `session-guard.sh close` на Шаге 4.5.2 вызывает ту же проверку ещё раз и при блокирующем коде отказывает, семафор остаётся):

```bash
HANDOFF_CHECK="${IWE_SCRIPTS:-$HOME/IWE/scripts}/wp-handoff-peer-check.sh"
if [ -f "$HANDOFF_CHECK" ]; then
  bash "$HANDOFF_CHECK" --agent claude-code --slug "$SESSION_ID" || true
else
  echo "проверки поля «Следующий шаг» на этой установке нет — пропущена" >&2
fi
```

Любой `HANDOFF_*` — отказ для самого писателя: поправить поле (и файл шага 1а), опубликовать карточку и повторить проверку, прежде чем идти к 4.5.1; блокирующий код без исправления не даст закрыть сессию на Шаге 4.5.2; не прошло — сказать пилоту об этом одной строкой в итоговом сообщении. Читатель на следующей сессии: `wp-handoff-show.sh WP-N` (его вызывает `declare-intent.sh`).

**4.5.0б Снимок открытых фаз карточки (WP-484 Ф299, вход И-6 из РП-561).** Если сессия меняла статусы или разделы фаз карточки РП — до коммита обновить self-entry `handoff_snapshot` тем же скриптом, что `memory/protocol-close.md` §5 (без него гейт Ф42 на следующем открытии даёт ложное MISMATCH; живой случай РП-484 10.11: снимок 06.11, расхождение 16+5 фаз):

```bash
SNAPSHOT_WRITER="${IWE_WORKSPACE:-$HOME/IWE}/scripts/wp-phase-snapshot-write.py"
if [ -f "$SNAPSHOT_WRITER" ]; then
  "$(bash "${IWE_SCRIPTS:-$HOME/IWE/scripts}/lib/find-python3.sh" --stdlib-only)" "$SNAPSHOT_WRITER" "<WP-NNN>" --governance-repo "$GOV_REPO_ROOT"
else
  echo "записи снимка фаз на этой установке нет — пропущена" >&2
fi
```

`--governance-repo "$GOV_REPO_ROOT"` обязателен под заморозкой: карточка правится в изолированной копии, без флага скрипт перепишет снимок в замороженной главной копии. Код 0 — записано или уже актуально; код 3 — проверка списка фаз не сошлась, скрипт отказался писать: руками не чинить, одна строка пилоту в итоговом сообщении. Карточка с изменённым снимком идёт в коммит 4.5.1 вместе с остальной правкой.

**4.5.1 Commit + push:**

```bash
# WP-526 Ф2: коммит и push сессии идут в MC-sessions, не в $GOV_REPO_ROOT —
# session-manifest-write.sh живёт в DS-strategy (обычный скрипт), но
# работает НАД репозиторием MC-sessions (первый аргумент — $WORKTREE).
# No top-level `cd` (a PreToolUse hook blocks it): git runs with -C, the guard in a
# subshell, because it takes the claim's repository from its working directory.
# pathspec после `--`: commit ТОЛЬКО файлы сессии, не подметаем чужое
# pre-staged из общего индекса (mis-attribution, см. 2026-06-20-39).
# $GUARD_ORZ (Шаг 4.5.0) — тот же путь, что "$TODAY-$SESSION_SLUG.md" (Шаг 4.4),
# одна запись вместо двух хардкодов одного и того же файла.
# 00-index.md больше НЕ входит сюда (WP-537 Ф4): эта сессия пишет
# только в свой runtime-черновик (Шаги 1.3/4.3), не в git-tracked файл —
# коммитить его отсюда означало бы подхватывать чужие параллельные правки
# того же общего файла, ровно тот класс бага, который черновик закрывает.
# SESSION_PATHS comes from §4.4а: explicit files, no .err, deletions included.
# The session folder itself is never passed (WP-524 F7): `git commit -- <dir>`
# would take a modified tracked .err along.
PATHS=("${SESSION_PATHS[@]}")
# Install without the index snapshotter: the index is kept directly and goes in the commit.
[ -f "${IWE_WORKSPACE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}/scripts/session-index-snapshot.sh" ] || PATHS+=("00-index.md")
if [ -e "$GUARD_ORZ" ]; then
  PATHS=("${GUARD_ORZ#"$SESSIONS_DIR"/}" "${PATHS[@]}")
else
  echo "WARN: ОРЗ-файл $GUARD_ORZ не записан (Шаг 4.5.0) — коммит без него" >&2
fi
for P in "${PATHS[@]}"; do
  if [ -e "$SESSIONS_DIR/$P" ]; then
    git -C "$SESSIONS_DIR" add -- "$P" || { echo "не удалось добавить $P" >&2; exit 1; }
  elif git -C "$SESSIONS_DIR" ls-files --error-unmatch -- "$P" >/dev/null 2>&1; then
    # Tracked file deleted on disk, deletion not staged yet.
    git -C "$SESSIONS_DIR" rm --cached --quiet -- "$P" || { echo "не удалось снять $P с индекса" >&2; exit 1; }
  fi   # deletion already staged: nothing to do, `git commit -- <path>` takes it
done
# Заявка файлов ИЗНУТРИ репозитория сессий (РП-484 Ф257, 28.10): охранник берёт репозиторий
# заявки из текущего каталога; заявка из корня IWE записывается за корневым репозиторием,
# и закрытие отказывает «commit changes an unclaimed sessions path».
for CLAIM in "${PATHS[@]}"; do
  (cd "$SESSIONS_DIR" && bash "${IWE_SCRIPTS:-$HOME/IWE/scripts}/session-guard.sh" note-file "$CLAIM" --wp "<WP-NNN>" --slug "$SESSION_ID" --agent claude-code) \
    || { echo "заявка файла $CLAIM не прошла" >&2; exit 1; }
done
# Task text: written beforehand with a file-writing tool (not the shell) to
# ${IWE_WORKSPACE:-$HOME/IWE}/.iwe-runtime/peer-prompts/<SESSION_ID>-task.txt — never inline it in quotes.
TASK_FILE="${IWE_WORKSPACE:-$HOME/IWE}/.iwe-runtime/peer-prompts/$SESSION_ID-task.txt"
test -s "$TASK_FILE" || { echo "нет файла задачи $TASK_FILE — записать его инструментом записи файлов" >&2; exit 1; }
# Заявлять коммит только после УСПЕШНОГО коммита: при отказе HEAD чужой, и note-commit заявил бы
# чужой коммит (РП-484 Ф257, 27.10) — после публикации такую заявку снимает только
# `note-commit --forget` для коммита, не пересекающегося с файлами сессии.
{ printf 'feat(peer): %s — ' "$SESSION_ID"; cat "$TASK_FILE"; } | git -C "$SESSIONS_DIR" commit -F - -- "${PATHS[@]}" \
  || { echo "коммит сессии отклонён — note-commit НЕ вызывать, разобрать причину" >&2; exit 1; }
OUR_SHAS=("$(git -C "$SESSIONS_DIR" rev-parse HEAD)")   # публикуем ровно свои коммиты по одному, см. блок публикации ниже

# WP-537: заявить свой коммит в семафоре — тот же паттерн, что на Шаге 3.6.5,
# явный `-C "$SESSIONS_DIR"` по той же причине (верхнеуровневый `cd` этот хук
# блокирует, а implicit cwd после переписывания дал бы HEAD не того репозитория).
NOTE_COMMIT="${IWE_SCRIPTS:-$HOME/IWE/scripts}/session-guard.sh"
[ -x "$NOTE_COMMIT" ] || NOTE_COMMIT="${IWE_WORKSPACE:-$HOME/IWE}/scripts/session-guard.sh"
if ! bash "$NOTE_COMMIT" note-commit "$(git -C "$SESSIONS_DIR" rev-parse HEAD)" \
       --repo "$(basename "$SESSIONS_DIR")" --agent claude-code --slug "$SESSION_ID"; then
  echo "WARN: коммит не заявлен в семафоре — закрытие сессии проверится по всей ветке" >&2
fi

# F1 (пир-сессия 2026-08-21-02-day-close-anomaly-classes): attest-манифест
# сессии — ПОСЛЕ payload-коммита с отчётом, ДО публикации. Без манифеста
# догоняющий quick-close уже запушенной сессии не доказывает «всё на remote»
# и падает в ручной обход. Отказ (грязное дерево и т.п.) не блокирует
# закрытие — WARN и legacy-путь confirmed_clean_repos.
MANIFEST_WRITER="${IWE_WORKSPACE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}/scripts/session-manifest-write.sh"
[ -f "$MANIFEST_WRITER" ] || MANIFEST_WRITER="${IWE_TEMPLATE:-${IWE_WORKSPACE:-$HOME/IWE}/FMT-exocortex-template}/scripts/session-manifest-write.sh"
bash "$MANIFEST_WRITER" "$(git -C "$SESSIONS_DIR" rev-parse --show-toplevel)" "$SESSION_ID" \
  || echo "WARN: attest-манифест не создан — догоняющее закрытие пойдёт legacy-путём"
# attest-манифест — второй наш коммит (если он создан): порядок публикации «payload, затем манифест»
[ "$(git -C "$SESSIONS_DIR" rev-parse HEAD)" = "${OUR_SHAS[0]}" ] || OUR_SHAS+=("$(git -C "$SESSIONS_DIR" rev-parse HEAD)")
```

**Продуктовая публикация вне `main` (РП-484, 03.10):** после подтверждённой доставки в `origin/pilot` или `origin/new-architecture` записать проверяемую квитанцию перед закрытием. Использовать точный опубликованный SHA, имя продуктового репозитория и собственный guard session ID:

```bash
bash "${IWE_SCRIPTS:-$HOME/IWE/scripts}/session-guard.sh" note-publication "$PUBLISHED_SHA" \
  --repo "$PRODUCT_REPO" --target-ref "refs/heads/$PUBLISHED_BRANCH" \
  --agent "$WRITER_AGENT" --session-id "$GUARD_SESSION_ID"
```

`PUBLISHED_BRANCH` берётся из фактической разрешённой публикации, не угадывается. Это подтверждение доставки, не разрешение публиковать в прод. Команда допускает только `peer-session`, продуктовые репозитории и две названные ветки; root/governance/MC-sessions по-прежнему требуют `main`. Если старая заявка осталась после перебазирования, квитанция доказывает полный перенос её изменения на опубликованную версию, сохраняя обе заявки. Команду можно повторить после остановки закрытия в `PREPARED`: она дописывает только доказательство, не меняет замороженный набор. Не удалять заявки/маркеры вручную и не обещать, что завершение процесса само снимет блокировку. При отказе доказательства разбирать конкретную причину; незавершённую доставку нельзя объявлять завершённой.

**Публикация репозитория сессий (`MC-sessions`): только свои коммиты, по одному, через шлюз с `--exact-commit`; НИКОГДА `git push` текущей ветки** (WP-484 21.09, пир-сессия 2026-09-21-08). Общий checkout `MC-sessions` может стоять НЕ на `main` (найдено 21.09: чужая ветка `peer/2026-09-19-11-...` с 19.09, её создал шаг 4.5 скилла kimi-peer-writer через `git checkout -b`). Тогда `push_branch` кладёт коммиты в чужую ветку и они не попадают в `main`, а `ds-publish.sh --from-commit <sha>` БЕЗ `--exact-commit <sha>` переносит весь диапазон `origin/main..<sha>` (14 чужих коммитов, конфликт в `00-index.md`). `--exact-commit` принимает аргумент (SHA) и переносит ровно один коммит от свежего `origin/main`; повтор идемпотентен (уже опубликованный patch-эквивалент пропускается). Зависимые коммиты (payload, затем attest-манифест) доставляются НЕ атомарно: при сбое между ними повторить цикл, он безопасен. Манифест сверяет по patch-id, а не по SHA, поэтому перенос cherry-pick'ом ему не мешает.

```bash
REPO_ROOT=$(git -C "$SESSIONS_DIR" rev-parse --show-toplevel)
git -C "$REPO_ROOT" fetch -q origin main
# Служебный id охранника = имя файла семафора `claude-code-<id>.open`. Дата-слаг пир-сессии
# ($SESSION_ID) им НЕ является: с слагом квитанция отказывала «нет открытой сессии claude-code-<слаг>»
# (WP-539 Ф21 Б5, 15 отказов за 29.10). Ищем семафор по полю slug; ровно один, иначе стоп.
if [ -f "${IWE_WORKSPACE:-$HOME/IWE}/.iwe-runtime/sessions/claude-code-${SESSION_ID}.open" ]; then
    GUARD_SESSION_ID="$SESSION_ID"   # уже служебный id
else
    GUARD_SEM_MATCHES=$(grep -lxF "slug: ${SESSION_ID}" "${IWE_WORKSPACE:-$HOME/IWE}"/.iwe-runtime/sessions/claude-code-*.open 2>/dev/null)
    [ "$(printf '%s\n' "$GUARD_SEM_MATCHES" | grep -c .)" -eq 1 ] \
        || { echo "семафор сессии $SESSION_ID не найден или не единственный: $GUARD_SEM_MATCHES" >&2; exit 1; }
    GUARD_SESSION_ID=$(basename "$GUARD_SEM_MATCHES" .open)
    GUARD_SESSION_ID="${GUARD_SESSION_ID#claude-code-}"
fi
for SHA in "${OUR_SHAS[@]}"; do
    # IWE_PUBLICATION_SESSION_ID обязателен: без него квитанция публикации (v2) не записывается
    # (в журнале пропусков «session=none»), и закрытие отказывает «lacks exact publication receipt».
    IWE_AGENT=claude-code IWE_PUBLICATION_SESSION_ID="$GUARD_SESSION_ID" bash "${IWE_WORKSPACE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}/scripts/ds-publish.sh" "$REPO_ROOT" high \
        --from-commit "$SHA" --exact-commit "$SHA" --reason "peer-session $SESSION_ID close" \
        || { echo "ds-publish --exact-commit не удался для $SHA — см. вывод шлюза" >&2; exit 1; }
done
```

> **`IWE_AGENT=claude-code` здесь обязательно, та же причина, что у Шага 3.6.5** (см. примечание там, найдено 06.10). Это публикует `MC-sessions` — именно тот busy-репозиторий, в котором `publication-receipt-gaps.log` показал пропуски квитанций.

Приоритет `high`, а не `normal` как в 3.6.5: пилот реально ждёт закрытие сессии сейчас, это не фоновый деплой (WP-530 Ф9: голый push обходил шлюз координации, которым уже пользуются quick-close/day-close).

**Если публикация не удалась** (`exit 1` в блоке выше — обязательная часть паттерна, не текст-предупреждение: без него неудачная публикация выглядела бы завершившейся успешно; найдено холодным ревью WP-530 Ф9): НЕ переходить к Шагу 4.5.2 — семафор session-guard не закрыт, коммит существует только локально. Зафиксировать полный вывод шлюза в файл эскалации; пилоту — одной короткой фразой причину и требуемое решение, со ссылкой на файл эскалации (тот же формат, что в §3.3), ESCALATE_TO_USER. НЕ обходить хуки (`--no-verify` запрещён правилом 6). Конфликт в `00-index.md` в выводе шлюза при `--exact-commit` невозможен для наших коммитов (они его не трогают): если он появился, значит `--exact-commit` не передан.

**4.5.2 Session-guard close** (ПОСЛЕ успешного push — закрывать семафор раньше нельзя, иначе Scope gate на 4.5.1 не найдёт активного семафора):

```bash
# PILOT_CLOSE_WORD — дословная реплика пилота о закрытии из ЭТОГО чата («закрывай», «всё», ПСЗ, СЗ);
# присвоить ее до вызова: PILOT_CLOSE_WORD='закрывай'. Слова пилота нет — не закрывать (Шаг 3.8):
# охранник сессий (РП-561, 18.11) откажет сам. «Не закрывай», вопрос и подпись варианта не принимаются.
GUARD="${IWE_SCRIPTS:-$HOME/IWE/scripts}/session-guard.sh"
if grep -q -- '--pilot-close-word' "$GUARD"; then
  IWE_AGENT=claude-code bash "$GUARD" close --agent claude-code --slug "$SESSION_ID" --pilot-close-word "$PILOT_CLOSE_WORD"
else
  # Older guard copy (template install): no close-word flag yet; step 3.8 already required the pilot's word.
  IWE_AGENT=claude-code bash "$GUARD" close --agent claude-code --slug "$SESSION_ID"
fi
CLOSE_RC=$?
if [ "$CLOSE_RC" -ne 0 ]; then
  echo "Закрытие не подтверждено: разобрать причину отказа; шаги 4.5.3–4.5.4 пока не выполнять." >&2
  exit 1
fi
```

Для другого runtime указать его фактического агента; slug должен принадлежать закрываемой пир-сессии. Отказ этой команды не отменяет уже доставленную работу, но завершение сессии ещё не подтверждено. Продолжить диагностику и штатное восстановление в разрешённом объёме. Не обещать автоматическое снятие по TTL или завершению процесса: обработка осиротевшей записи требует отдельной проверки состояния. Шаг 4.5.3 допускается только после успешного закрытия.

**4.5.3 Очистить close_obligation этой harness-сессии** (WP-484 «Восьмой случай», 03.09 — peer-session 2026-09-03-11-wp484-remaining-kimi-session-open, Kimi+Codex; фикс сужен после cold-review той же сессии). `close_obligation.cmd_stop_check()` разрешает Stop сразу при `close_path: peer-session` (Шаг 1.0), но НИЧЕГО не мутирует — если до или во время этой пир-сессии где-то в том же CLI-процессе успел встать `armed` close_obligation (например, ложное срабатывание close-intent-sentinel), он остаётся на диске нетронутым, и `close_obligation.cmd_mode()` продолжает возвращать его непустым — следующий `process-runner.py start quick-close` в этом же непрерывном разговоре падает на «completed-карточка не удовлетворяет обязательству закрытия», хотя Stop-гейт всё это время отвечал allow.

Действие `cancel --action peer-session-close` (не `cancel-close`/`close-override` — те остаются только для явной команды пилота, поведение не менялось) — новое, узкое: очищает `armed` obligation тем же аудируемым (ledger `close_obligation`) путём, но **no-op при `state=="running"`**. Один долгий `$CLAUDE_CODE_SESSION_ID` может накрывать несколько РП подряд (`waiting`-шаг легитимно приостанавливает раннер и разрешает Stop, обязательство при этом остаётся `running`) — безусловная очистка здесь стёрла бы чужой ещё выполняющийся Quick Close другого РП той же сессии (cold-review нашёл эту дыру в первой версии фикса с `cancel-close`). Без `--force`: отказ ledger оставляет obligation на месте (fail-closed), шаг просто сообщает и не блокирует пилота — сильнее не нужно, следующий реальный Quick Close покажет проблему явно, если она не устранилась.

```bash
CLOSE_OBLIGATION="${IWE_WORKSPACE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}/scripts/close_obligation.py"
if [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] && [ -f "$CLOSE_OBLIGATION" ]; then
  "$(bash "${IWE_SCRIPTS:-$HOME/IWE/scripts}/lib/find-python3.sh")" "$CLOSE_OBLIGATION" cancel \
    --session-id "$CLAUDE_CODE_SESSION_ID" --action peer-session-close --actor peer-session-close \
    --reason "peer-session $SESSION_ID closed via direct commit (Шаг 4.5.1), no runner obligation applies" \
    2>&1 || echo "close_obligation cancel не прошёл — не блокирует пилота, следующий Quick Close покажет это явно, если проблема повторится"
fi
```

**4.5.4 Приёмка закрытия такта «сессия»** (WP-561 Ф6-а, design/impl peer-session `2026-09-03-14-wp561-continue-tacts`, Kimi critic-consistency). До этой фазы закрытие через пир-сессию не имело НИКАКОЙ механической проверки — `close-runner-gate.sh` явно пропускает типизированный раннер (и его шаг R23-чеклиста) для `close_path: peer-session`, значит закрытие полагалось только на то, что 4.5.0-4.5.3 не упали. Три факта, которые TACT-02 (`docs/orz-pipeline-registry.yaml`) считает признаком «зелёного» закрытия, здесь никогда не сверялись вместе явно. Проверка читает общий вид опубликованного журнала и локального буфера через `ledger_read_yaml`, чтобы событие закрытия было видно до публикации. Best-effort в том смысле, что сбой этой проверки НЕ откатывает уже сделанное закрытие (семафор уже закрыт на 4.5.2) — но расхождение эскалируется громко, тем же `ESCALATE_TO_USER`-механизмом, что и остальной скилл, а не тонет в stderr как обычный `|| echo warning`. Жёсткий блок здесь сознательно не сделан: у этого же РП уже было минимум два инцидента с зависающими закрытиями сессии от новых, необстрелянных gate (карантин семафора терял исключение peer-session; `close_obligation` застревал в armed) — риск добавить третий такой способ застрять выше риска пропустить одно расхождение.

> **Запуск только через bash и без пересказа (WP-484 Ф290, 05.11).** Блок ниже исполнять целиком в `bash` (сохранить в файл и `bash <файл>` или `bash -c '…'`), не в оболочке по умолчанию: в zsh `BASH_SOURCE` пуст, `ledger_read_yaml` ищет `ledger_path.py` от текущего каталога и возвращает пустой документ — так 05.11 сессия 06 получила ложную эскалацию «нет события session_closed», хотя оба события лежали в буфере журнала. Строки `ACCEPTANCE_ISSUES` переносить в эскалацию дословно: «журнал не удалось прочитать» и «нет события» — разные расхождения с разным разбором.

> **Cold-review фиксы (та же сессия, до деплоя):** (1) дата journal-файла — локальное время, как `now_date()` в `session-guard.sh`, не `date -u` (UTC-вычисление ночью давало ложный «нет события», уже был класс инцидента «ночная сессия» в этом РП); (2) `git ls-remote` обёрнут в `timeout` (тот же риск зависания, из-за которого сам этот шаг не делает жёсткий блок); (3) journal-путь — канонический `${IWE_WORKSPACE:-$HOME/IWE}/DS-strategy`, не `$GOV_REPO_ROOT` (в isolate/freeze-сценарии тот указывает на изолированную копию СОВСЕМ ДРУГОГО репозитория — `session-guard.sh` пишет ledger-событие всегда в канонический governance-репо через свой собственный `$IWE_ROOT/$GOV_REPO`, а не через переменную этого скилла); (4) значения в Python — через переменные окружения, не строковой интерполяцией в исходный код (slug формируется словесной инструкцией агенту, не санитируется регуляркой); (5) сам файл эскалации получает отдельный маленький коммит+push — без этого он остаётся незакоммиченным после единственного commit+push Шага 4.5.1 и никогда не публикуется, вопреки заявленному «эскалируется громко».

```bash
LEDGER_DAY=$(date +%Y-%m-%d)
LEDGER_REPO="${IWE_WORKSPACE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}"
. "$LEDGER_REPO/scripts/lib/ledger-path.sh"
ACCEPTANCE_ISSUES=()

# Факт 1: событие session_closed* с этим slug — в опубликованном журнале или буфере.
if LEDGER_DOC=$(ledger_read_yaml day "$LEDGER_DAY" "$LEDGER_REPO/machine/ledger" "$LEDGER_REPO/archive/ledger"); then
  HAS_EVENT=$(printf '%s\n' "$LEDGER_DOC" | SESSION_ID_ENV="$SESSION_ID" python3 -c "
import os, sys
try:
    import yaml
    data = yaml.safe_load(sys.stdin) or {}
    events = data.get('events', [])
    slug = os.environ['SESSION_ID_ENV']
    found = any(
        str(e.get('kind', '')).startswith('session_closed')
        and (e.get('data') or {}).get('slug') == slug
        for e in events
    )
    print('yes' if found else 'no')
except Exception as exc:
    print('error:' + str(exc))
")
  [ "$HAS_EVENT" = "yes" ] || ACCEPTANCE_ISSUES+=("нет события session_closed* со slug=$SESSION_ID в журнале за $LEDGER_DAY (нашёл: $HAS_EVENT)")
else
  ACCEPTANCE_ISSUES+=("журнал за $LEDGER_DAY не удалось прочитать")
fi

# Факт 2: закрывающий ОРЗ-файл действительно закоммичен (не только записан на диск).
if ! git -C "$SESSIONS_DIR" diff --quiet HEAD -- "$GUARD_ORZ" 2>/dev/null; then
  ACCEPTANCE_ISSUES+=("$GUARD_ORZ отличается от закоммиченной версии")
fi

# Факт 3: коммит реально дошёл до remote (не только push вернул 0 локально).
# timeout — та же дисциплина, что session-guard.sh:1956 (git fetch) и
# git-dirty-guard.sh (git ls-remote) уже применяют к сетевым git-вызовам.
# Доставка идёт cherry-pick'ом (`ds-publish.sh --exact-commit`), поэтому на
# origin/main наш коммит лежит под ДРУГИМ SHA: проверка «мой SHA — предок
# origin/main» дала бы ложное расхождение. Сравниваем по patch-id: `git cherry`
# помечает коммит `-`, если на origin/main есть эквивалентный патч, и `+`, если нет
# (пустые коммиты patch-id не имеют и здесь не встречаются).
if ! timeout 20 git -C "$SESSIONS_DIR" fetch -q origin main 2>/dev/null; then
  ACCEPTANCE_ISSUES+=("не удалось получить origin/main (таймаут/сеть) — доставку проверить нельзя")
else
  for OUR_SHA in "${OUR_SHAS[@]}"; do
    if git -C "$SESSIONS_DIR" cherry origin/main "$OUR_SHA" "$OUR_SHA"^ 2>/dev/null | grep -q '^+'; then
      ACCEPTANCE_ISSUES+=("на origin/main нет эквивалента нашего коммита $OUR_SHA (по patch-id)")
    fi
  done
fi

if [ "${#ACCEPTANCE_ISSUES[@]}" -gt 0 ]; then
  ESCALATIONS=$((ESCALATIONS + 1))
  ACCEPT_ESC_FILE="${SESSION_DIR}/escalation-$(printf '%02d' $((ESCALATIONS-1))).md"
  {
    echo "---"
    echo "escalation_number: $ESCALATIONS"
    echo "turn: close"
    echo "timestamp: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "reason: \"приёмка закрытия такта сессия нашла расхождение\""
    echo "pilot_response: \"\""
    echo "---"
    echo ""
    echo "# Эскалация $ESCALATIONS (закрытие)"
    echo ""
    echo "**Причина:** закрытие прошло (семафор закрыт), но приёмка нашла расхождение:"
    for issue in "${ACCEPTANCE_ISSUES[@]}"; do echo "- $issue"; done
  } > "$ACCEPT_ESC_FILE"
  # Единственный commit+push сессии — Шаг 4.5.1, ДО этой проверки; без
  # отдельной публикации файл эскалации остался бы untracked навсегда
  # (cold-review, High) — маленький выделенный коммит именно под него.
  sed "s/^escalations_count:.*/escalations_count: $ESCALATIONS/" "$SESSION_DIR/meta.yaml" > "$SESSION_DIR/meta.yaml.tmp" \
    && mv "$SESSION_DIR/meta.yaml.tmp" "$SESSION_DIR/meta.yaml"
  git -C "$SESSIONS_DIR" add "$ACCEPT_ESC_FILE" "$SESSION_DIR/meta.yaml"
  git -C "$SESSIONS_DIR" commit -m "fix(peer): $SESSION_ID — эскалация приёмки закрытия" \
    -- "$ACCEPT_ESC_FILE" "$SESSION_DIR/meta.yaml" 2>&1 || true
  IWE_AGENT=claude-code bash "${IWE_WORKSPACE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}/scripts/ds-publish.sh" "$SESSIONS_DIR" high \
    --from-commit "$(git -C "$SESSIONS_DIR" rev-parse HEAD)" --exact-commit "$(git -C "$SESSIONS_DIR" rev-parse HEAD)" \
    --reason "peer-session $SESSION_ID close: escalation" 2>&1 \
    || echo "⚠️  публикация эскалации не удалась — коммит существует локально, файл не тонет, но не на remote" >&2
  echo "⚠️  Приёмка закрытия сессии нашла расхождение (см. $ACCEPT_ESC_FILE) — сессия закрыта, но требует внимания пилота." >&2
fi
```

**Известные ограничения v1** (Kimi, critic-consistency, ход 3 сессии выше — условие деплоя): (1) таймаут `ls-remote` попадает в ту же ветку, что «коммита реально нет» — сетевая нестабильность к origin выглядит как нарушение процесса, хотя это не одно и то же; не блокер, но при повторных срабатываниях стоит различить. (2) Файл эскалации не удаляется и не архивируется автоматически — накопление таких файлов при частых срабатываниях не рассмотрено. (3) Одна общая эскалация на все найденные расхождения сразу (не по одной на каждый тип) — при росте числа проверок читаемость может деградировать, пересмотреть схему при добавлении 4-й проверки.

**Показать пилоту in-chat summary** (прочитать `report.md`, извлечь и вывести):

```
Сессия завершена.

Ходов/раундов: <turns_count|rounds> | Роли: <writer_agent> (писатель) · <peer_agent(s)> (напарник(и)) | Эскалаций: <escalations_count>

Решение: <первый пункт §4 из report.md — одна строка на пальцах, без технических кодов>

Подробный отчёт: MC-sessions:<MONTH>/<DAY>/<SESSION_ID>/report.md
```

Если report.md пустой или субагент-синтезатор не создал его — показать только ссылку без §4.

---

## Шаг 5. Interrupt-режим

При `--interrupt <session_id>`:

1. Извлечь месяц и день из id: `MONTH=$(echo "$session_id" | cut -c1-7)`, `DAY=$(echo "$session_id" | cut -c9-10)` → найти `$SESSIONS_DIR/$MONTH/$DAY/$session_id/meta.yaml` (Шаг 1, WP-526 Ф2 — MC-sessions, не `sessions/` внутри governance-репо).
2. Обновить (Bash sed): `status: interrupted`, `end_time: <now>`, `turns_count: <число файлов>`.
3. Обновить индекс-черновик (WP-537 Ф4, `session_index_draft_write`, см. Шаг 4.3): статус → `interrupted`, report → `—`.
4. Commit + push внутри `$SESSIONS_DIR`: список файлов — по §4.4а (явные файлы, без папки и без `.err`), коммит и публикация — по 4.5.1. На установке без переносчика черновиков в индекс (`[ -f "${IWE_WORKSPACE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}/scripts/session-index-snapshot.sh" ]` не выполняется) сначала обновить `00-index.md` тем же блоком, что в Шаге 4.3 (статус `interrupted`, report → `—`), и добавить `00-index.md` в список.

---

## Шаг 6. Finalize-режим

При `--finalize <session_id>`:

1. Извлечь месяц и день: `MONTH=$(echo "$session_id" | cut -c1-7)`, `DAY=$(echo "$session_id" | cut -c9-10)`. Проверить что папка `$SESSIONS_DIR/$MONTH/$DAY/$session_id` (MC-sessions, WP-526 Ф2) существует и содержит хотя бы `00-writer.md`.
2. Прочитать `meta.yaml` — взять `task_description`, `start_time`, `escalations_count`.
3. Выполнить **Шаг 4.2** (синтез report.md через Agent tool) с теми же инвариантами и fallback.
4. Обновить `meta.yaml` (Bash sed): `status: completed`, `end_time: <now>`, `turns_count: <число файлов>`.
5. Обновить индекс-черновик (WP-537 Ф4, `session_index_draft_write`, см. Шаг 4.3): статус → `completed`, report → ссылка.
6. Commit + push внутри `$SESSIONS_DIR`: список файлов — по §4.4а (явные файлы, без папки и без `.err`), коммит и публикация — по 4.5.1. На установке без переносчика черновиков в индекс (`[ -f "${IWE_WORKSPACE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}/scripts/session-index-snapshot.sh" ]` не выполняется) сначала обновить `00-index.md` тем же блоком, что в Шаге 4.3 (статус `completed`, report → ссылка), и добавить `00-index.md` в список.

Используется для восстановления прерванных сессий без перезапуска turn-loop.

---

## Верификация отчёта

Для проверки любого существующего report.md написать в чат:
«проверь отчёт сессии `<session_id>`»

Запустить субагент (Sonnet, context isolation): прочитать все файлы сессии + report.md, сверить с инвариантами schema_version=1 (frontmatter, §4 непустой при agreed, verify-якоря).

<!-- USER-SPACE -->
<!-- /USER-SPACE -->
