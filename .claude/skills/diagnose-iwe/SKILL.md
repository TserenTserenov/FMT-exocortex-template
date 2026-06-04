---
name: diagnose-iwe
description: "Диагностика ступени мастерства (Диагност R28, FORM.089 §6.1) прямо в VS Code / claude.ai. До 5 вопросов, ~5 мин. Сохраняет cp-профиль в цифровой двойник (browser) или Neon (VS Code). Запускай когда: пилот говорит «пройди диагностику», «какая моя ступень», «/diagnose-iwe» — или ПРОАКТИВНО когда видишь пустой cp_profile или нового пользователя без данных."
argument-hint: "[необязательно: --check для просмотра профиля без нового опроса]"
related: [WP-318, DP.ROLE.042, DP.SC.132, PD.FORM.089]
version: 1.0.0
layer: L3
status: active
triggers:
  slash: [/diagnose-iwe]
  phrases: []
routing:
  executor: sonnet
  deterministic: false
---

# /diagnose-iwe — диагностика ступени мастерства

> ⚡ **Алгоритм, не свободный разговор.** Шаги 1-5 последовательно. Ждать ответа после каждого вопроса. Без преждевременных выводов.

> **Алгоритм CAT (FORM.089 §6.1 v4.2):** 4–7 вопросов, старт со ступени 3, не со ступени 1. Фаза 1 — 4 якорных вопроса. Фаза 2 — drill-down для каждого слота с оценкой < 3.

## Контракт скилла

- **Вход:** пилот вызвал скилл или Claude видит пустой cp_profile.
- **Выход:** cp-профиль в чате + сохранение (путь зависит от интерфейса — см. Шаг 5).
- **Время:** ≤7 мин (4–7 вопросов).
- **Не делает:** не даёт рекомендации по развитию (это Навигатор R27), не строит персональное руководство (это Портной R28).

## Определить интерфейс (ПЕРВЫМ действием)

**Браузер (claude.ai):** инструмент Bash недоступен → сохранение через `dt_write_digital_twin`.
**VS Code / локальный:** Bash доступен → сохранение в Neon через psycopg2 (+ локальный fallback).

Проверка: попробовать Bash. Если недоступен — работаем в браузерном режиме.

## Шаг 0. Проверить существующий профиль

### Браузерный режим

Вызвать `mcp__claude_ai_IWE__dt_read_digital_twin` с path `1_declarative/cp_profile`.

Если возвращает данные с полем `assessed_at` — проверить возраст:
- Профиль есть и моложе 30 дней → показать, предложить пройти заново.
- `--check` → показать и завершить.
- Нет профиля или старше 30 дней → продолжить с Шага 1.

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

**Формат вывода существующего профиля (оба режима):**

```
📊 Текущий cp-профиль (диагностика от YYYY-MM-DD)

Ступень: [название] ([N] из 5)
Приоритет роста: [слот по-русски]
Рекомендованный поток: [SN]
Действителен до: YYYY-MM-DD

Хочешь пройти диагностику заново? (она обновит профиль)
```

## Шаг 1. Объявить диагностику

Открыть одним сообщением:

```
🔬 Диагностика ступени мастерства

До 5 вопросов. Для каждого выбери цифру от 1 до 5, где:
1 — совсем не про меня / нет опыта
5 — полностью про меня / устойчивая практика

Выбирай то, что ближе к реальности прямо сейчас, не к идеалу.

Готов? Тогда начнём.
```

Ждать ответа («да», «давай», «начнём» или любой другой — сигнал готовности).


## Шаг 2. Фаза 1 — якорные вопросы (все 4)

Задавать по одному, ждать ответ 1-5 после каждого. Записывать в `scores`.

**Вопрос 1 (cp.skl):**
```
Вопрос 1 из 5

Вы осознанно выделяете время на изучение нового — не просто читаете что попадётся,
а именно отводите время под развитие?
Сколько примерно часов в неделю?

1 — Не выделяю осознанно, по ситуации
2 — Стараюсь всегда учиться, но ритма нет
3 — Явно знаю, что получается 3-4 ч/нед
4 — Регулярно, не менее 1 часа в день и до 8 ч/нед
5 — Ежедневная практика и более 10 ч/нед
```

**Вопрос 2 (cp.agt):**
```
Вопрос 2 из 5

Используете ли вы конкретные методы для своего развития?
Например: ведение заметок, учёт времени, регулярные сессии стратегирования и планирования.

1 — Нет
2 — Иногда пробую что-то, но не приживается
3 — Есть 1-2 приёма, применяю
4 — Есть много методов, которые осознанно добавляю
5 — Развиваю и передаю методы другим
```

**Вопрос 3 (cp.wld):**
```
Вопрос 3 из 5

Есть ли у вас принципы, которые определяют ваши важные решения?
Насколько они явные — вы могли бы их сформулировать прямо сейчас?

1 — Решаю интуитивно
2 — Что-то есть, но смутно
3 — Могу назвать 2-3 принципа
4 — Принципы явные, записаны
5 — Есть целостное мировоззрение, передаю другим
```

**Вопрос 4 (cp.iwe):**
```
Вопрос 4 из 5

Насколько хорошо у вас настроен инструмент хранения и обработки знаний —
заметки, база знаний, инструменты?

1 — У меня его нет
2 — Сделал самый простой (заметки в телефоне, папка в облаке)
3 — Есть рабочий инструмент, пользуюсь регулярно
4 — Настроен процесс работы с несколькими сервисами: структура, связи, поиск
5 — Регулярно развиваю его
```

После всех 4 вопросов: `scores = {cp.skl: X, cp.agt: X, cp.wld: X, cp.iwe: X}`.

## Шаг 3. Фаза 2 — drill-down (при необходимости)

Найти все слоты с оценкой < 3 (включая дефолтовые). Для каждого такого слота задать уточняющий вопрос по таблице ниже.

| Слабый слот | Drill-down слот | Вопрос |
|---|---|---|
| cp.skl | cp.rhy | «Как часто вы занимаетесь саморазвитием в последние 3 месяца? (учебные сессии, чтение, практика)» |
| cp.agt | cp.agt | «Берёте ли вы на себя ответственность за результат, даже если обстоятельства были неблагоприятные?» |
| cp.wld | cp.wld | «Можете назвать 2-3 принципа, которые направляют ваши решения? Насколько они сформулированы явно?» |
| cp.iwe | cp.int | «Системное мышление — видеть связи между частями целого, понимать надсистему и подсистему. Как вы с ним?» |
| cp.rhy | cp.rhy | «Как часто вы занимаетесь саморазвитием в последние 3 месяца? (учебные сессии, чтение, практика)» |
| cp.int | cp.int | «Системное мышление — видеть связи между частями целого, понимать надсистему и подсистему. Как вы с ним?» |

Ответы для drill-down (1-5):

**cp.rhy:** 1-Реже раза в месяц / 2-1-2 раза в месяц / 3-Еженедельно / 4-3-5 раз в неделю / 5-Ежедневно
**cp.agt:** 1-Обычно жду / 2-Иногда пробую / 3-Инициирую в своей зоне / 4-Регулярно запускаю / 5-Создаю среду
**cp.wld** (уточнение): 1-Принципы не сформулированы / 2-Есть смутное ощущение / 3-Могу назвать 1-2 / 4-Явные, записаны / 5-Работающая система
**cp.int** (уточнение): 1-Незнакомо / 2-Слышал, не применял / 3-Применяю интуитивно / 4-Применяю осознанно / 5-Учу других

После drill-down добавить оценку в `scores`.

**Дефолты для незаданных слотов (conservative fallback):**
Любой слот из `[cp.rhy, cp.wld, cp.skl, cp.iwe, cp.int, cp.agt]`, не заданный в диалоге → присвоить дефолт 2.

## Шаг 4. Вычислить профиль

```
cp_confirmed_stage = min(cp.rhy, cp.wld, cp.skl, cp.iwe, cp.int, cp.agt)
bottleneck_slot    = argmin(mandatory)
recommended_stream = "S" + str(max(1, min(4, stage)))
```

Ступени: 1-Случайный / 2-Практикующий / 3-Систематический / 4-Дисциплинированный / 5-Проактивный

Bottleneck по-русски:
- cp.rhy → «регулярность и ритм занятий»
- cp.wld → «мировоззрение и системный взгляд»
- cp.skl → «осознанное инвестирование времени»
- cp.iwe → «инструмент работы со знаниями»
- cp.int → «системное мышление»
- cp.agt → «методы и агентность»

Потоки: S1-«Фундамент» / S2-«Систематизация» / S3-«Масштаб» / S4-«Передача»

## Шаг 5. Показать результат и сохранить

Сначала показать итог в чате:

```
📊 Результаты диагностики

Ступень: [НАЗВАНИЕ] ([N] из 5)
Приоритет роста: [bottleneck по-русски]
Рекомендованный поток: [SN] — [label потока]

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
  "bottleneck_slot": "<cp.xxx>",
  "recommended_stream": "<SN>",
  "skip_to_stage": <N>,
  "cp_scores": {
    "cp.rhy": <N>, "cp.wld": <N>, "cp.skl": <N>,
    "cp.iwe": <N>, "cp.int": <N>, "cp.agt": <N>
  },
  "source": "self_report",
  "interface": "browser",
  "rcs_version": "v4.2",
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

slots = ['cp.rhy', 'cp.wld', 'cp.skl', 'cp.iwe', 'cp.int', 'cp.agt']
scores = json.loads(scores_raw)
vals   = {s: int(scores.get(s, 2)) for s in slots}
stage  = min(vals.values())
bn     = min(vals, key=vals.get)
stream = 'S' + str(max(1, min(4, stage)))
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
             'self_report', 'vscode', q_count, 'v4.2', valid)
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
        'questions_count': q_count, 'rcs_version': 'v4.2',
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
→ /diagnose в боте @aist_pilot_me — пройти диагностику там тоже
→ /progress в боте — посмотреть полный профиль прогресса
```

## Граничные случаи

| Ситуация | Действие |
|---|---|
| Пилот не отвечает числом 1-5 | Переспросить: «Выбери цифру от 1 до 5» |
| Пилот хочет пропустить вопрос | Присвоить дефолт 2 (conservative), перейти дальше |
| dt_write_digital_twin недоступен | Показать профиль в чате, попросить скопировать |
| psycopg2 не установлен (VS Code) | Сохранить в `~/.aist/cp-assessments/YYYY-MM-DD.json` |
| Профиль уже есть (< 30 дней) | Показать и спросить: «Пройти заново?» |

## Проактивный триггер

Claude должен предложить `/diagnose-iwe` **без явного запроса** когда:
1. В `dt_read_digital_twin` по path `1_declarative/cp_profile` нет данных или `stage = null`
2. В `day-open` IWE-данные пустые или `stage = null`
3. Пилот говорит «с чего начать», «как мне развиваться», «что делать дальше» — без контекста ступени

Формулировка предложения:
```
Вижу, что cp-профиль не заполнен (или устарел).
Хочешь пройти диагностику ступени? ~5 мин, 4-5 вопросов — скажи «да» или `/diagnose-iwe`.
```
