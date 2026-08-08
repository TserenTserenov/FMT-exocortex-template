# Визуальные схемы IWE для новичков

> Схемы в формате Mermaid. Рендерятся в GitHub, VS Code (с расширением Mermaid), и большинстве Markdown-редакторов.

---

## Схема 1. Четыре компонента IWE

> IWE = ОС интеллектуальной работы. Четыре компонента, ты в центре, инструменты — средства доставки.

```mermaid
graph TB
    subgraph core["<b>ЯДРО МЫШЛЕНИЯ</b>"]
        direction LR
        THEORIES["<b>Теории</b><br/>Системное мышление<br/>Методология, менеджмент"]
        EXO["<b>Экзокортекс</b><br/>Вторая память:<br/>планы, контекст, выводы"]
        PACK["<b>Pack</b><br/>Вторые принципы:<br/>твои доменные знания"]
    end

    subgraph culture["<b>КУЛЬТУРА РАБОТЫ</b>"]
        direction LR
        PROTOCOLS["<b>Протоколы</b><br/>ОРЗ<br/>Day Open/Close"]
        SKILLS["<b>Навыки</b><br/>Capture, Self-correction<br/>Различения"]
        FORMATS["<b>Форматы</b><br/>Pack-структура<br/>WP-context"]
    end

    subgraph mastery["<b>МОДЕЛЬ МАСТЕРСТВА</b>"]
        M1["Ученик"] --> M2["Интеллектуал"] --> M3["Профессионал"] --> M4["Исследователь"] --> M5["Просветитель"]
    end

    subgraph community["<b>СООБЩЕСТВО</b>"]
        COMM["<b>Среда созидателей</b><br/>Обмен, ревью, поддержка"]
    end

    subgraph pair["<b>ПАРА: ТЫ + ИИ</b>"]
        direction LR
        USER["<b>Ты</b><br/>Принимаешь решения<br/>Мыслишь, направляешь"]
        AI["<b>Claude Code</b><br/>Усиливает, структурирует<br/>Берёт рутину"]
        USER <-->|"сотрудничество"| AI
    end

    core -->|"чем думаешь"| pair
    culture -->|"как работаешь"| pair
    mastery -->|"куда растёшь"| pair
    community -->|"где живёшь"| pair

    style core fill:#fce4ec,stroke:#e53935,stroke-width:2px
    style culture fill:#fff3e0,stroke:#fb8c00,stroke-width:2px
    style mastery fill:#e8f5e9,stroke:#43a047,stroke-width:2px
    style community fill:#e3f2fd,stroke:#1e88e5,stroke-width:2px
    style pair fill:#f3e5f5,stroke:#8e24aa,stroke-width:2px
```

---

## Схема 2. Путь пользователя: от нуля до рабочего IWE

> Пять шагов. Каждый — конкретный результат.

```mermaid
graph LR
    S1["<b>Шаг 1</b><br/>Пойми зачем<br/><i>~15 мин</i><br/>────────<br/>Читаешь этот<br/>документ"]
    S2["<b>Шаг 2</b><br/>Установи<br/><i>~20 мин</i><br/>────────<br/>VS Code + Claude Code<br/>+ GitHub аккаунт"]
    S3["<b>Шаг 3</b><br/>Первая сессия<br/><i>~30 мин</i><br/>────────<br/>Стратегический документ<br/>+ план на неделю"]
    S4["<b>Шаг 4</b><br/>Практика<br/><i>1-2 недели</i><br/>────────<br/>Ритуалы ОРЗ<br/>каждый день"]
    S5["<b>Шаг 5</b><br/>Теории<br/><i>свой темп</i><br/>────────<br/>Системное мышление<br/>и курсы ШСМ"]

    S1 -->|"ИИ поможет"| S2
    S2 -->|"Claude ведёт"| S3
    S3 -->|"привыкаешь"| S4
    S4 -->|"готов к глубине"| S5

    style S1 fill:#e3f2fd,stroke:#1e88e5,stroke-width:2px
    style S2 fill:#e8f5e9,stroke:#43a047,stroke-width:2px
    style S3 fill:#fff3e0,stroke:#fb8c00,stroke-width:2px
    style S4 fill:#f3e5f5,stroke:#8e24aa,stroke-width:2px
    style S5 fill:#fce4ec,stroke:#e53935,stroke-width:2px
```

---

## Схема 3. Ритуал ОРЗ (ежедневный цикл)

> Один паттерн для дня и для каждой рабочей сессии.

```mermaid
graph TD
    O["<b>ОТКРЫТИЕ</b><br/>«Открой день»<br/>────────<br/>План на сегодня<br/>Приоритеты<br/>Контекст вчера"]
    R["<b>РАБОТА</b><br/>Делаешь задачи<br/>────────<br/>На каждом рубеже:<br/>фиксируешь выводы<br/>и знания"]
    Z["<b>ЗАКРЫТИЕ</b><br/>«Закрой день»<br/>────────<br/>Итоги дня<br/>Обновление планов<br/>Что дальше"]

    O -->|"утро"| R
    R -->|"вечер"| Z
    Z -->|"завтра"| O

    style O fill:#e3f2fd,stroke:#1e88e5,stroke-width:2px
    style R fill:#e8f5e9,stroke:#43a047,stroke-width:2px
    style Z fill:#fff3e0,stroke:#fb8c00,stroke-width:2px
```

---

## Схема 3.5. Культура работы — три типа элементов

> 14 элементов культуры работы IWE, разделённых на три типа. Культура — то, за что платят.

```mermaid
graph TD
    subgraph culture["<b>КУЛЬТУРА РАБОТЫ (14 элементов)</b>"]
        direction TB

        subgraph protocols["<b>Протоколы</b> (делаешь по шагам)"]
            P1["ОРЗ"]
            P3["Day Open/Close"]
            P4["Week Close"]
        end

        subgraph skills["<b>Навыки</b> (нарабатываешь практикой)"]
            S1["Capture"]
            S2["Self-correction"]
            S3["Различения"]
            S4["WP Gate"]
        end

        subgraph formats["<b>Форматы</b> (оформляешь по стандарту)"]
            F1["Pack-структура"]
            F2["WP-context"]
            F3["Collapsible sections"]
        end
    end

    protocols -->|"формализовано"| RESULT["<b>Результат:</b><br/>поставленная культура работы<br/>= стиль жизни созидателя"]
    skills -->|"по ситуации"| RESULT
    formats -->|"по стандарту"| RESULT

    style protocols fill:#fce4ec,stroke:#e53935,stroke-width:2px
    style skills fill:#fff3e0,stroke:#fb8c00,stroke-width:2px
    style formats fill:#e8f5e9,stroke:#43a047,stroke-width:2px
    style RESULT fill:#f3e5f5,stroke:#8e24aa,stroke-width:2px
```

---

## Схема 4. Путь подключения IWE (сборка локальной среды)

> Начинай с Этапа 1. Добавляй компоненты по мере готовности. Это сборка своей среды, не тир доступа (T0→T4, DP.ARCH.002) и не ступень мастерства (FORM.089).

```mermaid
graph BT
    E1["<b>Этап 1 — Старт</b><br/>Claude Code + экзокортекс<br/>────────<br/>ИИ-ассистент, который<br/>тебя помнит"]
    E2["<b>Этап 2 — Ритуалы</b><br/>+ ОРЗ + план дня<br/>────────<br/>Структурированная работа<br/>без потери контекста"]
    E3["<b>Этап 3 — База знаний</b><br/>+ Pack + бот @aist_me_bot<br/>────────<br/>База знаний +<br/>мобильный доступ"]
    E4["<b>Этап 4 — Автоматизация</b><br/>+ роли + агенты<br/>────────<br/>ИИ-агенты работают<br/>самостоятельно"]

    E1 --> E2
    E2 --> E3
    E3 --> E4

    style E1 fill:#e3f2fd,stroke:#1e88e5,stroke-width:2px
    style E2 fill:#e8f5e9,stroke:#43a047,stroke-width:2px
    style E3 fill:#fff3e0,stroke:#fb8c00,stroke-width:2px
    style E4 fill:#fce4ec,stroke:#e53935,stroke-width:2px
```

---

## Схема 5. Теории → Принципы → Практика

> За IWE стоят теории (ШСМ). Теории порождают принципы. Принципы встроены в ИИ и изучаются тобой.

```mermaid
graph TD
    THEORIES["<b>ТЕОРИИ</b><br/>Системное мышление, методология<br/>менеджмент, инженерия<br/><i>Курсы ШСМ</i>"]

    ZP["<b>Нулевые принципы (ZP)</b><br/>Базовые правила мышления<br/><i>Даны IWE</i>"]
    FPF["<b>Первые принципы (FPF)</b><br/>Фреймворк корректности<br/><i>Даны IWE</i>"]
    PACK["<b>Вторые принципы (Pack)</b><br/>Доменные знания<br/><i>Создаёшь ты</i>"]
    DS["<b>Третьи принципы (DS)</b><br/>Реализация<br/><i>Создаёшь ты + ИИ</i>"]

    THEORIES -->|"порождают"| ZP
    ZP -->|"формируют"| FPF
    FPF -->|"направляют"| PACK
    PACK -->|"определяют"| DS

    USER["<b>Ты</b><br/>Изучаешь теории →<br/>системное мышление"]
    AI["<b>ИИ</b><br/>Теории встроены в правила"]

    THEORIES -.->|"изучаешь"| USER
    ZP -.->|"встроены"| AI
    FPF -.->|"встроены"| AI
    USER -->|"создаёт"| PACK
    PACK -->|"обогащает"| AI
    AI -->|"помогает структурировать"| PACK

    style THEORIES fill:#e8eaf6,stroke:#3f51b5,stroke-width:2px
    style ZP fill:#fce4ec,stroke:#e53935,stroke-width:2px
    style FPF fill:#fce4ec,stroke:#e53935,stroke-width:2px
    style PACK fill:#fff3e0,stroke:#fb8c00,stroke-width:2px
    style DS fill:#e8f5e9,stroke:#43a047,stroke-width:2px
    style USER fill:#f3e5f5,stroke:#8e24aa,stroke-width:2px
    style AI fill:#e3f2fd,stroke:#1e88e5,stroke-width:2px
```

---

## Схема 6. Экзотело vs Протез

> Ключевое различение IWE: ИИ **расширяет** мышление, а не **заменяет** его. IWE = экзотело для мышления.

```mermaid
graph LR
    subgraph bad["<b>ПРОТЕЗ</b>"]
        direction TB
        B1["ИИ думает за тебя"]
        B2["Ты перестаёшь<br/>развиваться"]
        B3["Зависимость<br/>от инструмента"]
        B1 --> B2 --> B3
    end

    subgraph good["<b>ЭКЗОТЕЛО (IWE)</b>"]
        direction TB
        G1["ИИ берёт рутину"]
        G2["Ты думаешь<br/>лучше и быстрее"]
        G3["Навыки растут<br/>вместе с инструментом"]
        G1 --> G2 --> G3
    end

    style bad fill:#fce4ec,stroke:#e53935,stroke-width:2px
    style good fill:#e8f5e9,stroke:#43a047,stroke-width:2px
```

---

## Схема 7. Проблема → Решение

> Связь между типичными проблемами и компонентами IWE.

```mermaid
graph LR
    P1["Знания<br/>теряются"]
    P2["Планы<br/>не работают"]
    P3["ИИ не помогает<br/>по-настоящему"]

    S1["<b>Ядро мышления</b><br/>Экзокортекс + Pack<br/>+ GitHub"]
    S2["<b>Культура работы</b><br/>Ритуалы ОРЗ<br/>+ Claude Code"]
    S3["<b>Ядро + культура</b><br/>Claude Code<br/>+ экзокортекс"]

    P1 -->|"решает"| S1
    P2 -->|"решает"| S2
    P3 -->|"решает"| S3

    style P1 fill:#fce4ec,stroke:#e53935,stroke-width:2px
    style P2 fill:#fce4ec,stroke:#e53935,stroke-width:2px
    style P3 fill:#fce4ec,stroke:#e53935,stroke-width:2px
    style S1 fill:#e8f5e9,stroke:#43a047,stroke-width:2px
    style S2 fill:#e8f5e9,stroke:#43a047,stroke-width:2px
    style S3 fill:#e8f5e9,stroke:#43a047,stroke-width:2px
```

---

*Создан: 2026-03-17 | Обновлён: 2026-03-27 | WP-120 | [FMT-exocortex-template](https://github.com/TserenTserenov/FMT-exocortex-template)*
