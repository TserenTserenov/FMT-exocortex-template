---
marp: true
theme: default
paginate: true
---

<style>
  section {
    font-family: 'Inter', 'Helvetica Neue', Arial, sans-serif;
    background-color: #f8f9fa;
    color: #1a1a2e;
    padding: 40px 60px;
  }
  h1 {
    color: #1a1a2e !important;
    font-weight: 800;
    font-size: 2em;
  }
  h2 {
    color: #0f3460 !important;
    font-weight: 700;
  }
  h3 {
    color: #e94560 !important;
    font-weight: 600;
  }
  strong { color: #e94560 !important; }
  em { color: #666 !important; font-style: normal; }
  blockquote {
    border-left: 4px solid #e94560;
    background: #fff;
    padding: 16px 24px;
    border-radius: 0 8px 8px 0;
  }
  blockquote p { color: #1a1a2e !important; }
  table { border-collapse: collapse; width: 100%; font-size: 0.82em; }
  th {
    background: #0f3460 !important;
    color: #fff !important;
    padding: 10px 14px;
    text-align: left;
    font-weight: 700;
  }
  td {
    padding: 8px 14px;
    color: #1a1a2e !important;
    border-bottom: 1px solid #ddd;
  }
  tr:nth-child(even) td {
    background: #f0f4ff !important;
  }
  li::marker { color: #e94560; }
  ul, ol { line-height: 1.8; }
  a { color: #e94560 !important; }
  section.title {
    display: flex;
    flex-direction: column;
    justify-content: center;
    align-items: center;
    text-align: center;
    background-color: #1a1a2e !important;
  }
  section.title h1 { color: #fff !important; font-size: 2.4em; }
  section.title h2 { color: #eaeaea !important; font-weight: 400; }
  section.title p { color: #a0a0b0 !important; }
  section.accent {
    background-color: #0f3460 !important;
  }
  section.accent h1,
  section.accent h2,
  section.accent h3,
  section.accent p,
  section.accent li,
  section.accent strong,
  section.accent em,
  section.accent blockquote p { color: #fff !important; }
  section.accent strong { color: #f5a623 !important; }
  section.accent li::marker { color: #f5a623; }
  .box {
    display: inline-block;
    background: #fff;
    border: 2px solid #0f3460;
    border-radius: 12px;
    padding: 16px 20px;
    margin: 8px;
    text-align: center;
    min-width: 140px;
    box-shadow: 0 2px 8px rgba(0,0,0,0.08);
  }
  .box-green { border-color: #43a047; background: #e8f5e9; }
  .box-orange { border-color: #fb8c00; background: #fff3e0; }
  .box-blue { border-color: #1e88e5; background: #e3f2fd; }
  .box-red { border-color: #e53935; background: #fce4ec; }
  .big-number {
    font-size: 3em;
    font-weight: 800;
    color: #e94560;
    line-height: 1;
  }
</style>

<!-- _class: title -->

# IWE для новичков

## Интеллектуальная рабочая среда

*Не программа. Не приложение. Среда, которая меняет способ работы с информацией.*

---

# Что тебя ждёт

1. **Карта IWE** — из чего состоит (визуально)
2. **Твоя проблема** — почему текущий способ не работает
3. **Как IWE решает** — связь проблем и компонентов
4. **Путь от нуля** — 5 шагов до рабочей среды
5. **Не бойся** — почему это проще, чем кажется
6. **Системное мышление** — фундамент, который всё меняет

---

<!-- _class: accent -->

# Карта IWE

## Четыре блока. Одна среда.

---

# Из чего состоит IWE

<div style="display: flex; gap: 24px; justify-content: center; flex-wrap: wrap; margin-top: 20px;">
  <div class="box box-green" style="width: 200px;">
    <b style="color: #43a047 !important;">Инструменты</b><br/>
    <span style="font-size: 0.85em;">Claude Code<br/>VS Code<br/>GitHub</span>
  </div>
  <div class="box box-orange" style="width: 200px;">
    <b style="color: #fb8c00 !important;">Знания</b><br/>
    <span style="font-size: 0.85em;">Экзокортекс<br/>Pack</span>
  </div>
  <div class="box box-blue" style="width: 200px;">
    <b style="color: #1e88e5 !important;">Практика</b><br/>
    <span style="font-size: 0.85em;">Бот @aist_me_bot<br/>Ритуалы ОРЗ</span>
  </div>
  <div class="box box-red" style="width: 200px;">
    <b style="color: #e53935 !important;">Фундамент</b><br/>
    <span style="font-size: 0.85em;">Системное мышление<br/>Принципы</span>
  </div>
</div>

---

# Инструменты

| Что | Зачем | Аналогия |
|-----|-------|----------|
| **Claude Code** | ИИ-ассистент, который читает твои файлы и помнит контекст | Напарник, а не поисковик |
| **VS Code** | Бесплатный редактор — пишешь обычные тексты | Блокнот, но умнее |
| **GitHub** | Облачное хранилище с полной историей изменений | Google Drive + машина времени |

---

# Знания

| Что | Зачем | Аналогия |
|-----|-------|----------|
| **Экзокортекс** | Твоя вторая память. ИИ читает и обновляет её | Дневник, который сам ведётся |
| **Pack** | Структурированная база знаний по предметным областям | Библиотека с каталогом |

> Claude Code знает, на чём ты остановился вчера. Он не забывает.

---

# Практика

| Что | Зачем | Аналогия |
|-----|-------|----------|
| **Бот @aist_me_bot** | Помощник в Telegram: вопросы, напоминания | Наставник в кармане |
| **Ритуалы ОРЗ** | Открытие → Работа → Закрытие (каждый день, каждая сессия) | Расписание + привычка |

> Утро: «Что сегодня делаю?» Вечер: «Что сделал, что дальше?»

---

<!-- _class: accent -->

# Твоя проблема

## (и она реальна)

---

# Знания теряются

- Читаешь книгу → делаешь заметки → через месяц не находишь
- Notion, блокнот, телефон, салфетка — **везде и нигде**
- Нет структуры, нет связей между идеями
- Каждый раз «начинаешь сначала»

---

# Планы не работают

- Составляешь план на неделю → к среде он неактуален
- Новые задачи вытесняют старые
- Нет ревью → ощущение «ничего не успеваю»
- Нет системы приоритетов

---

# ИИ не помогает по-настоящему

- ChatGPT / Claude дают красивые, но **общие** ответы
- Каждый раз начинаешь **с нуля**
- ИИ не знает: твои проекты, цели, что ты уже пробовал
- Это как разговаривать с новым человеком каждый день

---

<!-- _class: accent -->

# Как IWE это решает

---

# Проблема → Решение

| Проблема | Компонент IWE | Как |
|----------|--------------|-----|
| Знания теряются | **Экзокортекс + Pack** | Каждая единица знания — на своём месте. История в GitHub |
| Планы не работают | **Ритуалы ОРЗ** | Утром план, вечером итоги, еженедельно ревью |
| ИИ не помогает | **Claude Code** | Читает ТВОИ файлы, знает ТВОИ цели, помнит ТВОЮ историю |

---

<!-- _class: accent -->

# Твой путь

## От нуля до рабочего IWE

---

# 5 шагов

<div style="display: flex; align-items: center; gap: 12px; justify-content: center; margin-top: 30px;">
  <div class="box box-blue" style="width: 150px;">
    <span class="big-number">1</span><br/>
    <b>Пойми зачем</b><br/>
    <em>15 мин</em>
  </div>
  <div style="font-size: 2em; color: #1e88e5;">→</div>
  <div class="box box-green" style="width: 150px;">
    <span class="big-number">2</span><br/>
    <b>Установи</b><br/>
    <em>20 мин</em>
  </div>
  <div style="font-size: 2em; color: #43a047;">→</div>
  <div class="box box-orange" style="width: 150px;">
    <span class="big-number">3</span><br/>
    <b>Первая сессия</b><br/>
    <em>30 мин</em>
  </div>
  <div style="font-size: 2em; color: #fb8c00;">→</div>
  <div class="box" style="width: 150px; border-color: #8e24aa; background: #f3e5f5;">
    <span class="big-number">4</span><br/>
    <b>Практика</b><br/>
    <em>1-2 нед</em>
  </div>
  <div style="font-size: 2em; color: #8e24aa;">→</div>
  <div class="box box-red" style="width: 150px;">
    <span class="big-number">5</span><br/>
    <b>Мышление</b><br/>
    <em>свой темп</em>
  </div>
</div>

---

# Шаг 2. Установка (~20 мин)

**Тебе не нужно уметь программировать.**

Три действия:
1. Установить VS Code и Claude Code *(бесплатно)*
2. Создать аккаунт на GitHub *(бесплатно)*
3. Запустить одну команду

> **ИИ поможет.** Скажи Claude Code: «Помоги мне установить IWE» — он проведёт через каждый шаг.

*Подробная инструкция: SETUP-GUIDE.md*

---

# Шаг 3. Первая сессия (~30 мин)

После установки ты:

- Заполняешь стратегический документ *(кто ты, что важно, куда двигаешься)*
- Формулируешь 3-5 задач на ближайшую неделю
- ИИ структурирует это в план

> Это не абстрактное упражнение — ты сразу получаешь работающий план.

---

# Шаг 4. Ежедневная практика

Каждый день — один ритм:

| Время | Действие | Что происходит |
|-------|----------|---------------|
| **Утро** | «Открой день» | Claude показывает план, события, контекст |
| **Работа** | Работаешь | Фиксируешь выводы на рубежах |
| **Вечер** | «Закрой день» | Claude записывает итоги, обновляет планы |

> Через неделю: ничего не теряется. Всё на своих местах.

---

<!-- _class: accent -->

# Не бойся

---

# «Я не программист»

Ты и не должен быть.

- VS Code — просто удобный редактор для **текстов**
- GitHub — просто надёжное **хранилище**
- Ты **не будешь** писать код

> IWE — среда для интеллектуальной работы, не для программирования.

---

# «GitHub, CLI, терминал — это страшно»

Только в первый раз.

| Термин | Что это на самом деле |
|--------|----------------------|
| **GitHub** | Google Drive с историей изменений |
| **Терминал** | Окно, куда вводишь текст (Claude подскажет что) |
| **CLI** | Общение с компьютером текстом вместо кнопок |

> После установки ты общаешься с Claude Code **на русском языке**.

---

# Это не монолит — это конструктор

Начинай с минимума, добавляй по мере надобности:

| Уровень | Что используешь | Что получаешь |
|---------|----------------|---------------|
| **T1** | Claude Code + экзокортекс | ИИ-ассистент, который тебя помнит |
| **T2** | + ритуалы ОРЗ | Структурированная работа |
| **T3** | + Pack + бот | База знаний + мобильный доступ |
| **T4** | + роли + автоматизация | ИИ-агенты работают самостоятельно |

---

# Экзоскелет, а не протез

<div style="display: flex; gap: 40px; justify-content: center; margin-top: 30px;">
  <div class="box box-red" style="width: 280px; text-align: left;">
    <b style="color: #e53935 !important;">Протез</b><br/><br/>
    Заменяет способность.<br/>
    ИИ думает <b>за тебя</b>.<br/>
    Ты перестаёшь развиваться.
  </div>
  <div class="box box-green" style="width: 280px; text-align: left;">
    <b style="color: #43a047 !important;">Экзоскелет (IWE)</b><br/><br/>
    Усиливает способность.<br/>
    ИИ берёт <b>рутину</b>.<br/>
    Ты думаешь лучше и быстрее.
  </div>
</div>

> Твоё мышление — главный ресурс. ИИ помогает его не растрачивать.

---

<!-- _class: accent -->

# Системное мышление

## Фундамент, без которого IWE не раскроется

---

# Что это (простыми словами)

Умение видеть **целое**, а не только части.

| Без | С системным мышлением |
|-----|----------------------|
| Неделя = список задач | Неделя = связанные задачи с приоритетами |
| Книга = конспект цитат | Книга = принципы для разных контекстов |
| ИИ = случайные вопросы | ИИ = точные запросы на основе структуры |

---

# Где это используется в IWE

| Концепция | Где в IWE | Простыми словами |
|-----------|----------|-----------------|
| **Различения** | Pack, экзокортекс | Точно определить: чем одно отличается от другого |
| **Описания методов** | Ритуалы ОРЗ | Понимание «как», а не только «что» |
| **Рабочие продукты** | Планирование | Фокус на результатах, а не на активностях |
| **Роли** | ИИ-агенты | Кто что делает (включая ИИ) |

---

# Как начать изучать

<div style="display: flex; gap: 24px; justify-content: center; margin-top: 30px;">
  <div class="box box-blue" style="width: 240px;">
    <b>Неделя 1</b><br/>
    <span style="font-size: 0.85em;">Просто пользуйся IWE.<br/>Привыкни к ритуалам.</span>
  </div>
  <div class="box box-green" style="width: 240px;">
    <b>Неделя 2</b><br/>
    <span style="font-size: 0.85em;">Прочитай «Принципы vs Навыки»<br/>(10 минут).</span>
  </div>
  <div class="box box-orange" style="width: 240px;">
    <b>Далее</b><br/>
    <span style="font-size: 0.85em;">LEARNING-PATH §3 в своём темпе.<br/>Бот поможет с вопросами.</span>
  </div>
</div>

---

<!-- _class: title -->

# Начни сейчас

## Установка: SETUP-GUIDE.md
## Изучение: LEARNING-PATH.md
## Вопросы: @aist_me_bot в Telegram

*IWE — не про инструменты. IWE — про то, как ты думаешь и работаешь.*

---

# Ресурсы

| Что | Ссылка |
|-----|--------|
| Пошаговая установка (7 этапов) | SETUP-GUIDE.md |
| Путь обучения (11 разделов) | LEARNING-PATH.md |
| Что такое IWE (определение) | DP.IWE.001 |
| Принципы vs Навыки | principles-vs-skills.md |
| Сценарии использования | DP.SC.001 — DP.SC.005 |
| Совместимость ОС | PLATFORM-COMPAT.md |

**Стоимость:** Claude Pro ~$20/мес. Всё остальное бесплатно.
**Нужно ли программировать:** Нет.
