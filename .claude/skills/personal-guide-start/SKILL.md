---
name: personal-guide-start
description: Bootstrap-обёртка — создаёт пустой репо `DS-personal-guide` под аккаунтом пилота (плоское имя, без логина в названии; если ещё нет), затем вызывает /personal-guide-render для наполнения 6 файлами. Используй когда пилот в первый раз просит «создай мне персональное руководство», «хочу начать программу личного развития», «собери мне стартовый план».
argument-hint: "[необязательно: override домена — knowledge-worker / generic]"
experimental: true
sunset: "после DONE WP-222 (Портной, ~июнь 2026) и WP-149 Ф6 (книга ЛР v3)"
related: [personal-guide-render, WP-245, WP-222, WP-149, PD.FORM.089, PD.CAT.003]
version: 1.2.0
layer: L1
status: active
triggers:
  slash: [/personal-guide-start]
  phrases: []
routing:
  executor: sonnet
  deterministic: false
agents: single
interaction: multi-step
gates_required: []
gates_enforced: []
gates_rationale: "операционный скилл; WP Gate применим только при создании нового РП, не для операционных вызовов"
---

# Bootstrap персонального руководства

> ⚡ **ВЫПОЛНИ НЕМЕДЛЕННО — НЕ ЗАДАВАЙ ВОПРОСОВ.** Первое действие = вызов `create_repository`. Вопросы о домене, ступени, «главной системе», целях — запрещены на этом шаге; они задача render-скилла (Шаг 2). Даже если MCP-инструменты вернули данные о пилоте — не анализировать, не интерпретировать, сразу Шаг 1.

> **Experimental MVP-скилл — UX-обёртка** (IntegrationGate exception по WP-245 Ф28 Open Decision #7). Делит ответственность с `/personal-guide-render`:
> - **`/personal-guide-start` (этот)** — создание инфраструктуры: GitHub-репо как часть Персоны.инфра. **Один раз** на пилота.
> - **`/personal-guide-render`** — наполнение содержания: чтение Память.Derived (RCS-профиль) + Персона.декларации (домен) → 6 файлов. **N раз** (каждое обновление).
>
> Различение зафиксировано в `.claude/rules/distinctions.md` (AUTHOR-ONLY).

## When to use

Bootstrap-обёртка — создаёт пустой репо `DS-personal-guide` под аккаунтом пилота (плоское имя, без логина в названии; если ещё нет), затем вызывает /personal-guide-render для наполнения 6 файлами. Используй когда пилот в первый раз просит «создай мне персональное руководство», «хочу начать программу личного развития», «собери мне стартовый план».

## Контракт скилла

- **Вход:** активная подписка «Инженерия интеллекта» (ранее «Бесконечное развитие») (DP.SC.112). Доступ к `create_repository`, `github_status`. (Память.Derived и `personal_write` нужны на втором шаге — там их проверит `/personal-guide-render`.)
- **Выход:** репо `DS-personal-guide` под аккаунтом пилота существует на GitHub + 6 файлов записаны (через делегирование render-скиллу). Имя репо — константа для всех пилотов: один личный GitHub-аккаунт = один репо ЛР, ФИО/login в названии не нужен.
- **Время:** ≤60 мин с момента вызова до открытого в VS Code репо (критерий MVP из WP-188 Ф4.5).
- **Идемпотентность:** повторный вызов на существующем репо безопасен — Шаг 1 reuse, Шаг 2 пересобирает контент.

## Algorithm

## Шаг 1. Создать (или переиспользовать) репо

Вызови `create_repository(name: "DS-personal-guide", template_type: "notes", private: false, description: "Персональное руководство пилота программы ЛР (IWE)")`.

Имя репо — **константа** для всех пилотов (не подставлять GitHub-логин). У каждого пилота один личный аккаунт = один репо `DS-personal-guide`. Это упрощает скиллы (имя источника детерминированное, не нужно вычислять `<github-login>` через `github_status`), убирает риск коллизий имён и делает миграцию в Портного (WP-222) однозначной.

После OAuth Gateway создаст репо с базовой notes-структурой (inbox/, docs/, README.md). Эта структура будет переопределена render-скиллом на Шаге 2 (плюс render удалит `inbox/.gitkeep` — артефакт notes-template, не нужный для ЛР).

**Failure modes Шага 1:**

| Симптом | Решение |
|---------|---------|
| 401 от Gateway | Попроси пилота нажать «Authorize» в OAuth, повторить |
| `github_status` пустой | Пилот не подключил GitHub в Aisystant MCP — отправь его в onboarding |
| 409 (репо существует) | OK — переиспользуем; **сразу переходи к Шагу 2** без сообщения об ошибке |

## Шаг 1.5. Раздать скиллы в репо пилота (идемпотентно)

> **Зачем:** скиллы (`/lesson`, `/lesson-close`, `/connect-guide`, `/personal-guide-render`, `/personal-guide-start`) живут в `~/IWE/.claude/skills/` платформы. При работе пилота в **claude.ai/code** (cloud sandbox) user-global `~/.claude/skills/` не пробрасывается. Чтобы скиллы работали в любом канале, их нужно положить в сам репо пилота.

Записать пять скиллов в порядке (порядок важен — `personal-guide-start/SKILL.md` идёт последним, используется как canary проверки):

```python
SKILLS_TO_DISTRIBUTE = [
    "lesson/SKILL.md",
    "lesson-close/SKILL.md",
    "connect-guide/SKILL.md",
    "personal-guide-render/SKILL.md",
    "personal-guide-start/SKILL.md",   # ← canary: последний в очереди
]

for skill_path in SKILLS_TO_DISTRIBUTE:
    content = Read(f"~/IWE/.claude/skills/{skill_path}")
    personal_write(
        source="DS-personal-guide",
        path=f".claude/skills/{skill_path}",
        content=content,
    )
```

Если один из вызовов вернул ошибку — сообщить пилоту: «Не удалось установить скилл {skill_path}. Установка прервана. Повтори /personal-guide-start для завершения.» Стоп.

### CLAUDE.md-заглушка (идемпотентно, WP-527)

> **Зачем:** репо `DS-personal-guide` создаётся напрямую через `create_repository`, минуя гейт `/repo-new` (осознанное разделение — этот скилл UX-обёртка под IntegrationGate exception WP-245 Ф28 Открытое решение #7, не полноценный гейт создания). Без CLAUDE.md первое содержательное действие в этом репо (например, локальный клон + правка) встретит Repo-Touch Gate пустым. Реестр репозиториев экосистемы (`DS-ecosystem-development/0.OPS/REPOSITORY-REGISTRY.md`) сюда НЕ подходит — тот реестр про инфраструктуру самой экосистемы, не про персональные репозитории каждого участника; текущий трекинг per-пилот уже есть через `github_status`/`personal_list_sources`, дублировать не нужно.

Через `personal_search(source: "DS-personal-guide", path: "CLAUDE.md")` проверь наличие. Если нет — записать:

```python
personal_write(
    source="DS-personal-guide",
    path="CLAUDE.md",
    content="""# DS-personal-guide — инструкции для Claude Code

> **Класс:** личное пространство данных пилота. **Назначение:** персональное руководство — план, методы, история занятий пилота. **Писатель:** пилот (правки) + render-скилл `/personal-guide-render` (пересборка). **Владелец:** пилот. **Читатели:** пилот, его агенты сессии.

Создан через `/personal-guide-start` (быстрый bootstrap для этого конкретного случая — не общий гейт создания репозитория).

## Работа с этим репозиторием

Основные правки сюда идут через `/personal-guide-render` (пересборка) или обычные текстовые правки пилота — отдельный процесс/задача здесь не нужны, это личный рабочий репозиторий, не командный.
""",
)
```

### Reflection-template (идемпотентно)

Через `personal_search(source: "DS-personal-guide", path: "history/reflection-template.md")` проверь наличие. Если нет — записать:

```python
template_content = Read("~/IWE/.claude/skills/personal-guide-render/templates/reflection-template.md")
personal_write(
    source="DS-personal-guide",
    path="history/reflection-template.md",
    content=template_content,
)
```

## Шаг 2. Делегировать первый рендер в `/personal-guide-render`

Вызови скилл `personal-guide-render` через Skill tool (без аргументов, дата = сегодня).

Render-скилл вызовет gateway → guide/<date>.md + panel/<date>.md готовы. Дождись завершения, потом переходи к Шагу 3.

Если Skill tool недоступен (например, отладка вне Claude Code) — fallback: прочитай `~/.claude/skills/personal-guide-render/SKILL.md` и выполни Шаги 1-7 инлайн.

## Шаг 3. Финальное подтверждение пилоту

После того как render-скилл выдал своё подтверждение, добавь:

```
Чтобы работать с руководством локально — клонируй репо в свой IWE:
  git clone https://github.com/<github-login>/DS-personal-guide.git ~/IWE/DS-personal-guide

(подставь свой GitHub-login в URL — `gh auth status` покажет, кто ты сейчас.)

После этого правки локально → git push → Aisystant MCP подхватит через reindex.

Это первый запуск. Дальше — никаких спец-скиллов:
- Чтобы пересобрать после изменений в Память.Derived → /personal-guide-render
- Чтобы обновить план / методы / итоги недели → пиши в чате обычными словами
- Автоматизация по расписанию (без запроса) — придёт с Портным летом
```

**Важно:** `create_repository` создаёт репо только в облаке (GitHub) и регистрирует через `personal_list_sources`, но **не клонирует** на диск пилота. Без локального клона все правки идут только через `personal_write` MCP-инструмент. Подсказка про `git clone` обязательна.

## Verification

Bootstrap создаёт внешний ресурс (GitHub-репо) — перед сообщением об успехе проверь контрактный выход (Контракт §Выход), не считай «вызвал create_repository» за «репо готово»:

1. **Репо существует.** Вызови `github_status` — источник `DS-personal-guide` присутствует. Нет → bootstrap не состоялся (вероятно 401 / GitHub не подключён), вернись к Шагу 1, не выдавай подсказку про `git clone`.
2. **Скиллы установлены.** `personal_search(source: "DS-personal-guide", path: ".claude/skills/personal-guide-start/SKILL.md")` — нашёл. Не нашёл → Шаг 1.5 не завершился, перезапусти Шаг 1.5.
3. **Руководство собрано.** Render-скилл (Шаг 2) завершился без ошибки — `guide/<date>.md` готов. Ошибка → перезапусти Шаг 2.

Только при обоих PASS переходи к подсказке `git clone` (Шаг 3). Иначе — сообщи пилоту, какой из двух пунктов не выполнен, и что делать.

## Граница с `/personal-guide-render`

| Аспект | `/personal-guide-start` | `/personal-guide-render` |
|--------|-------------------------|--------------------------|
| Слой пользовательских данных | Персона.инфра (репо как идентичность) | Память.Derived + Персона.декларации + Контекст-сборка |
| Writer | пользователь (через своего агента) | LLM-агент в runtime |
| Owner факта | GitHub-аккаунт пилота | сам репо (git history) |
| Зависит от Память.Derived | Нет | Да |
| Идемпотентность | reuse при 409 | перезапись с архивом в `history/` |
| Частота вызова | один раз на пилота | N раз (еженедельно + по событиям) |

## Что скилл НЕ делает

- Не читает Память.Derived, не вычисляет ступень, не выбирает домен — это всё в `/personal-guide-render`.
- Не пишет файлы напрямую — делегирует render-скиллу.
- Не отправляет уведомления в TG / email — пилот сам открывает репо в VS Code.

Когда Портной (WP-222) выйдет — оба скилла уйдут в архив. Портной возьмёт на себя bootstrap+render+автоматический weekly/daily.
