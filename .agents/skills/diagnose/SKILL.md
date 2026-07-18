---
name: diagnose
description: "Диагностика ступени мастерства (Диагност R28, FORM.089 §6.1 v5.0) прямо в VS Code / claude.ai. До 6 вопросов, ~3 мин. Сохраняет cp-профиль в цифровой двойник (browser) или Neon (VS Code). Запускай когда: пилот говорит «пройди диагностику», «какая моя ступень», «/diagnose» — или ПРОАКТИВНО когда видишь пустой cp_profile или нового пользователя без данных."
argument-hint: "[необязательно: --check для просмотра профиля без нового опроса]"
related: [WP-318, WP-370, DP.ROLE.042, DP.SC.132, PD.FORM.089]
version: 5.0.0
layer: L1
status: active
triggers:
  slash: [/diagnose]
  phrases: []
routing:
  executor: agent
  deterministic: false
agents: single
interaction: multi-step
gates_required: []
gates_enforced: []
gates_rationale: "операционный скилл; WP Gate применим только при создании нового РП, не для операционных вызовов"
---

# /diagnose — диагностика ступени мастерства

> ⚡ **Алгоритм, не свободный разговор.** Шаги 1-5 последовательно. Ждать ответа после каждого вопроса. Без преждевременных выводов.

> **Алгоритм CAT (FORM.089 §6.1 v5.0):** 5 якорных вопросов + до 1 drill-down, старт со ступени 3.
> WP-370: cp.iwe → информационный (не блокирует ступень), cp.skl выводится из cp.rhy.

## When to use

Диагностика ступени мастерства (Диагност R28, FORM.089 §6.1 v5.0) прямо в VS Code / claude.ai. До 6 вопросов, ~3 минуты. Запускай когда: пилот говорит «пройди диагностику», «какая моя ступень», «/diagnose» — или ПРОАКТИВНО когда видишь пустой cp_profile.

## Контракт скилла

- **Вход:** пилот вызвал `/diagnose`, или Агент обнаруживает пустой cp_profile.
- **Выход:** cp-профиль в чате + сохранение (путь зависит от интерфейса — см. Шаг 5).
- **Время:** ≤3 мин (5-6 вопросов).
- **Не делает:** не даёт рекомендации по развитию (это Навигатор R27), не строит персональное руководство.

## Определить интерфейс (ПЕРВЫМ действием)

**Браузер (claude.ai):** инструмент Bash недоступен → сохранение через `dt_write_digital_twin`.
**VS Code / локальный:** Bash доступен → сохранение в Neon через psycopg2 (+ локальный fallback).

Проверка: попробовать Bash. Если недоступен — работаем в браузерном режиме.

## Algorithm

## Шаг 0. Проверить существующий профиль

### Браузерный режим

Вызвать `mcp__claude_ai_IWE__dt_read_digital_twin` с path `1_declarative/cp_profile`.

Если возвращает данные с полем `assessed_at` — проверить возраст:
- Профиль есть и моложе 7 дней → показать, предложить пройти заново (кнопка «Повторить»).
- `--check` → показать и завершить.
- Нет профиля или старше 7 дней → продолжить с Шага 1.

### VS Code режим

```bash
source ~/.config/aist/env
python3 -c "
import os, json
try:
    import psycopg2
    conn = psycopg2.connect(os.environ['NEON_LEARNING_URL'])
    cur = conn.cursor()
    cur.execute('''SELECT stage, bottleneck_slot, recommended_stream, assessed_at, valid_until
                   FROM learning.cp_assessments
                   WHERE account_id = %s::uuid
                   ORDER BY assessed_at DESC LIMIT 1''',
                (os.environ['DT_USER_ID'],))
    row = cur.fetchone()
    conn.close()
    if row:
        stage, bottleneck, stream, assessed_at, valid_until = row
        print(json.dumps({'stage': stage, 'bottleneck': bottleneck, 'stream': stream,
                          'assessed_at': str(assessed_at)[:10], 'valid_until': str(valid_until)[:10]}))
    else:
        print('null')
except Exception as e:
    print(f'error: {e}')
"
```

**Кулдаун:** 7 дней. При свежем профиле — показать и спросить «Пройти заново?».

**Формат вывода существующего профиля:**

```
📊 Текущий cp-профиль (диагностика от YYYY-MM-DD)

Ступень: [название] ([N] из 5)
Приоритет роста: [слот по-русски]
Рекомендованное руководство: [SN]
Действителен до: YYYY-MM-DD

Хочешь пройти диагностику заново?
```

## Шаг 1. Объявить диагностику

Открыть одним сообщением:

```
🔬 Диагностика ступени мастерства

До 5 вопросов с вариантами ответа. Занимает ~3 минуты.
Выбирайте то, что ближе всего к вашей текущей практике.

Готов? Тогда начнём.
```

Ждать ответа («да», «давай», «начнём» или любой другой — сигнал готовности).

## Шаг 2. Фаза 1 — якорные вопросы (все 5)

Задавать по одному, ждать ответ 1-5 после каждого. Записывать в `scores`.

**Вопрос 1 (cp.rhy):**
```
📍 Вопрос 1 из 5

Как вы ведёте учёт времени на саморазвитие и насколько регулярный ритм?
Сколько примерно часов в неделю?

1 — Не выделяю, как пойдёт
2 — Стараюсь, но без ритма (1-2 ч/нед)
3 — Еженедельно явно (3-4 ч/нед)
4 — Ежедневная практика + трекер (5-10 ч/нед)
5 — Автоматизировано + артефакты (10+ ч/нед)
```

**Вопрос 2 (cp.wld):**
```
📍 Вопрос 2 из 5

Как вы принимаете важные решения?
Через интуицию, ценности или системный анализ?

1 — В основном интуитивно
2 — Пробую разные подходы, не сложилось
3 — Через сформулированные принципы / мировоззрение
4 — Системно: цели, ограничения, альтернативы
5 — Передаю свои методы и принципы другим
```

**Вопрос 3 (cp.int):**
```
📍 Вопрос 3 из 5

Применяете ли вы системное мышление — видите ли роли, границы,
интерфейсы, надсистемы в реальных задачах?

1 — Нет опыта
2 — Слышал(а), но не применяю
3 — Базовые различения (роль/функция/граница)
4 — Системный разбор в работе
5 — Формализую модели, учу других
```

**Вопрос 4 (cp.agt):**
```
📍 Вопрос 4 из 5

Какая доля задач за последний месяц инициирована вами лично —
не «спустили», а вы сами увидели и взяли?

1 — Почти всё спущено сверху
2 — Иногда сам(а), редко
3 — Около половины — мои
4 — Большинство задач — моя инициатива
5 — Задаю повестку для других
```

**Вопрос 5 (cp.iwe — информационный, не блокирует ступень):**
```
📍 Вопрос 5 из 5

Насколько у вас настроена среда работы со знаниями —
заметки, база знаний, инструменты (VS Code + Pack + ИИ, или альтернативы)?

1 — Среды нет
2 — Простейшее (заметки в телефоне, папка в облаке)
3 — Базово настроено, пользуюсь регулярно
4 — Несколько сервисов, структура, связи, поиск
5 — Развиваю как систему — Pack/протоколы/агенты
```

После всех 5 вопросов: `scores = {cp.rhy: X, cp.wld: X, cp.int: X, cp.agt: X, cp.iwe: X}`.

**WP-370: cp.skl выводится из cp.rhy** (§6.1 v5.0 — ритм и мастерство коррелируют):
```python
scores['cp.skl'] = scores['cp.rhy']
```

## Шаг 3. Фаза 2 — drill-down (при необходимости)

**MANDATORY_SLOTS = ['cp.rhy', 'cp.wld', 'cp.skl', 'cp.int', 'cp.agt']** — cp.iwe исключён.

```python
mandatory_scores = {s: scores[s] for s in MANDATORY_SLOTS}
bottleneck_slot = min(mandatory_scores, key=mandatory_scores.get)
need_drilldown = mandatory_scores[bottleneck_slot] < 3
```

Если `need_drilldown = True` — задать один уточняющий вопрос по bottleneck:

| Bottleneck | Вопрос |
|---|---|
| cp.rhy / cp.skl | «Есть ли у вас «ритуалы» начала/завершения рабочей недели? Или регулярные точки рефлексии?»<br>1-Нет ничего / 2-Иногда делаю итоги / 3-Еженедельный ритуал / 4-Структурированные ритуалы / 5-Полная ОРЗ-практика |
| cp.wld | «Можете назвать 2-3 принципа, которые направляют ваши решения? Насколько они явные?»<br>1-Не сформулированы / 2-Смутное ощущение / 3-Могу назвать 1-2 / 4-Явные, записаны / 5-Работающая система |
| cp.int | «Пробовали ли вы разбирать ситуацию через надсистему и подсистему? Выделять роли, функции, ограничения?»<br>1-Незнакомо / 2-Слышал(а), не применял(а) / 3-Интуитивно / 4-Осознанно / 5-Учу других |
| cp.agt | «Берёте ли вы на себя ответственность за результат, даже если обстоятельства были неблагоприятные?»<br>1-Объясняю обстоятельствами / 2-Иногда беру / 3-Обычно беру / 4-Всегда беру / 5-Задаю стандарты |

Ответ drill-down обновляет соответствующий слот в `scores`. Если bottleneck = cp.skl — обновить cp.rhy, и снова переопределить `scores['cp.skl'] = scores['cp.rhy']`.

## Шаг 4. Вычислить профиль

```python
MANDATORY_SLOTS = ['cp.rhy', 'cp.wld', 'cp.skl', 'cp.int', 'cp.agt']

vals = {s: scores.get(s, 2) for s in MANDATORY_SLOTS}
stage = min(vals.values())
bottleneck = 'none' if stage >= 4 else min(vals, key=vals.get)

if stage == 5:
    recommended_stream = 'РР'
else:
    recommended_stream = f'S{max(1, min(4, stage))}'
```

Ступени: 1-Случайный / 2-Практикующий / 3-Систематический / 4-Дисциплинированный / 5-Проактивный

Bottleneck по-русски:
- cp.rhy → «регулярность и ритм занятий»
- cp.wld → «мировоззрение и системный взгляд»
- cp.skl → «учёт времени и собранность»
- cp.iwe → «рабочая среда и инструменты»
- cp.int → «системное мышление»
- cp.agt → «агентность и инициатива»
- 'none' → «Узких мест нет — поддерживайте темп и берите следующие ступени»

Потоки: S1-«Фундамент» / S2-«Систематизация» / S3-«Масштаб» / S4-«Передача» / РР-«Рабочее развитие»

## Шаг 5. Показать результат и сохранить

Сначала показать итог в чате:

```
📊 Результаты диагностики

Ступень: [НАЗВАНИЕ] ([N] из 5)

[Приоритет роста: <bottleneck по-русски>]
ИЛИ
[Узких мест нет — поддерживайте темп.]

Рекомендованное руководство: [SN] — [label]
[При stage=5: «Следующая программа: Рабочее развитие (РР)»]

Профиль по слотам:
cp.rhy [N] | cp.wld [N] | cp.skl [N]
cp.iwe [N] | cp.int [N] | cp.agt [N]

(действителен 180 дней)
```

Затем сохранить — путь зависит от интерфейса:

### Браузерный режим (claude.ai) — сохранить через dt_write_digital_twin

Вычислить `assessed_at` (сегодняшняя дата ISO) и `valid_until` (+180 дней).

Вызвать `mcp__claude_ai_IWE__dt_write_digital_twin`:
- **path:** `1_declarative/cp_profile`
- **data:**
```json
{
  "stage": <N>,
  "bottleneck_slot": "<cp.xxx или 'none'>",
  "recommended_stream": "<SN или 'РР'>",
  "skip_to_stage": <N>,
  "cp_scores": {
    "cp.rhy": <N>, "cp.wld": <N>, "cp.skl": <N>,
    "cp.iwe": <N>, "cp.int": <N>, "cp.agt": <N>
  },
  "source": "self_report",
  "interface": "browser",
  "rcs_version": "v5.0",
  "assessed_at": "YYYY-MM-DD",
  "valid_until": "YYYY-MM-DD"
}
```

Если `dt_write_digital_twin` вернул успех → сообщить: `✅ Профиль сохранён в цифровой двойник`.
Если ошибка → показать профиль в чате и попросить пользователя скопировать его вручную.

### VS Code режим — сохранить в Neon через Bash

```bash
source ~/.config/aist/env
CP_SCORES='<JSON с финальными scores>' \
CP_Q_COUNT=<число заданных вопросов> \
python3 -c "
import os, json, datetime as dt_lib

scores_raw = os.environ['CP_SCORES']
q_count    = int(os.environ.get('CP_Q_COUNT', '5'))
account_id = os.environ.get('DT_USER_ID', '')
url        = os.environ.get('NEON_LEARNING_URL', '')

ALL_SLOTS     = ['cp.rhy', 'cp.wld', 'cp.skl', 'cp.iwe', 'cp.int', 'cp.agt']
MANDATORY     = ['cp.rhy', 'cp.wld', 'cp.skl', 'cp.int', 'cp.agt']
scores = json.loads(scores_raw)
vals   = {s: int(scores.get(s, 2)) for s in ALL_SLOTS}

# derive cp.skl from cp.rhy (FORM.089 §6.1 v5.0)
vals['cp.skl'] = vals['cp.rhy']

stage  = min(vals[s] for s in MANDATORY)
bn     = 'none' if stage >= 4 else min(MANDATORY, key=lambda s: vals[s])
stream = 'РР' if stage == 5 else 'S' + str(max(1, min(4, stage)))
valid  = dt_lib.datetime.now(dt_lib.timezone.utc) + dt_lib.timedelta(days=180)

saved = False
if url and account_id:
    try:
        import psycopg2
        conn = psycopg2.connect(url)
        cur  = conn.cursor()
        cur.execute(
            '''INSERT INTO learning.cp_assessments
               (account_id, stage, bottleneck_slot, recommended_stream, skip_to_stage,
                cp_scores, source, interface, questions_count, rcs_version, valid_until)
               VALUES (%s::uuid, %s, %s, %s, %s, %s::jsonb, %s, %s, %s, %s, %s)
               RETURNING id''',
            (account_id, stage, bn, stream, stage, json.dumps(vals),
             'self_report', 'vscode', q_count, 'v5.0', valid)
        )
        row_id = cur.fetchone()[0]
        conn.commit()
        conn.close()
        print(f'OK neon id={row_id}')
        saved = True
    except Exception as e:
        print(f'neon error: {e}')

if not saved:
    import pathlib
    d = pathlib.Path.home() / '.aist' / 'cp-assessments'
    d.mkdir(parents=True, exist_ok=True)
    path = d / (dt_lib.date.today().isoformat() + '.json')
    path.write_text(json.dumps({'account_id': account_id, 'stage': stage,
        'bottleneck_slot': bn, 'recommended_stream': stream,
        'cp_scores': vals, 'source': 'self_report', 'interface': 'vscode',
        'questions_count': q_count, 'rcs_version': 'v5.0',
        'valid_until': valid.isoformat()}, indent=2))
    print(f'saved local: {path}')
"
```

Если вывод содержит `OK neon` — профиль в Neon. Если `saved local` — сохранён локально.

## Шаг 6. Следующий шаг

После показа результата — предложить:
```
Следующий шаг:
→ Навигатор, как развивать [bottleneck по-русски]? — рекомендации по росту
→ /diagnose в боте @aist_pilot_me — синхронизировать профиль
→ /progress в боте — посмотреть полный профиль прогресса
```

## Граничные случаи

| Ситуация | Действие |
|---|---|
| Пилот не отвечает числом 1-5 | Переспросить: «Выбери цифру от 1 до 5» |
| Пилот хочет пропустить вопрос | Присвоить дефолт 2 (conservative), перейти дальше |
| Менее 4 mandatory-ответов | Показать «Диагностика не завершена», предложить `/diagnose` заново |
| dt_write_digital_twin недоступен | Показать профиль в чате, попросить скопировать |
| psycopg2 не установлен (VS Code) | Сохранить в `~/.aist/cp-assessments/YYYY-MM-DD.json` |
| Профиль уже есть (< 7 дней) | Показать и спросить: «Пройти заново?» |

## Проактивный триггер

Агент должен предложить `/diagnose` **без явного запроса** когда:
1. В `dt_read_digital_twin` по path `1_declarative/cp_profile` нет данных или `stage = null`
2. В `day-open` IWE-данные пустые или `stage = null`
3. Пилот говорит «с чего начать», «как мне развиваться», «что делать дальше» — без контекста ступени

Формулировка предложения:
```
Вижу, что cp-профиль не заполнен (или устарел).
Хочешь пройти диагностику ступени? ~3 мин, 5 вопросов — скажи «да» или /diagnose.
```

<!-- USER-SPACE -->

<!-- /USER-SPACE -->
