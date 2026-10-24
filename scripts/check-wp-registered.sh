#!/usr/bin/env bash
# check-wp-registered.sh — блокирующая проверка: РП зарегистрирован согласованно (issue #1257).
#
# Использование: check-wp-registered.sh <номер РП> <каталог governance> <файл WeekPlan>
#   номер: 1, WP-1 и WP-001 — один номер; WP-10 — другой.
#
# Проверяет (каждое нарушение — строка в stderr, код возврата 1):
#   1. карточка inbox/WP-<NNN>/WP-<NNN>.md существует, её поле `wp:` равно номеру;
#   2. ровно одна строка таблицы docs/WP-REGISTRY.md, где номер стоит в ОТДЕЛЬНОЙ
#      ячейке колонки «#» (подстрока не считается: WP-1 не находит WP-10);
#   3. ровно одна строка в таблице «План» файла WeekPlan (таблицы под заголовками
#      «Итоги», «Сводка», «Summary» и упоминания вне таблиц записью не считаются;
#      если есть таблица под заголовком «План», считаются только такие таблицы;
#      заголовок: «Статус…» и («#» или «Работа»), номер — в колонке «#», иначе «РП»);
#   4. колонка названия в обеих строках содержит первые 80 символов названия из карточки
#      (create-wp.sh режет название в реестре до 80 символов).
# Код 2 — неверные аргументы или нечитаемые файлы.
set -uo pipefail

if [ "$#" -ne 3 ]; then
  echo "Использование: $0 <номер РП> <каталог governance> <файл WeekPlan>" >&2
  exit 2
fi

exec python3 - "$1" "$2" "$3" <<'PY'
import re
import sys
from pathlib import Path

raw_number, governance, weekplan = sys.argv[1:4]
match = re.fullmatch(r'(?:WP-)?0*(\d+)', raw_number.strip())
if not match:
    print(f'Неверный номер РП: {raw_number!r}', file=sys.stderr)
    sys.exit(2)
number = int(match.group(1))
errors = []


def cells(line):
    return [c.strip() for c in line.strip().strip('|').split('|')]


def is_row(line):
    s = line.strip()
    return s.startswith('|') and s.endswith('|')


def is_separator(line):
    return bool(re.fullmatch(r'[\s|:\-]+', line.strip())) and '-' in line


def cell_number(cell):
    """Номер из ячейки «#»; None, если ячейка — не номер (ячейка целиком, не подстрока)."""
    m = re.fullmatch(r'[*_~\s]*(?:\[)?(?:WP-)?0*(\d+)(?:\]\([^)]*\))?[*_~\s]*', cell, re.IGNORECASE)
    return int(m.group(1)) if m else None


def plain(text):
    return re.sub(r'\s+', ' ', re.sub(r'[*_~`]', '', text)).strip()


def read(path):
    try:
        return Path(path).read_text(encoding='utf-8').splitlines()
    except OSError as exc:
        print(f'Не удалось прочитать {path}: {exc}', file=sys.stderr)
        sys.exit(2)


# 1. Карточка
gov = Path(governance)
card = gov / f'inbox/WP-{number:03d}/WP-{number:03d}.md'
title = None
if not card.is_file():
    errors.append(f'нет карточки {card}')
else:
    front = {}
    lines = read(card)
    if lines and lines[0].strip() == '---':
        for line in lines[1:]:
            if line.strip() == '---':
                break
            key, _, value = line.partition(':')
            front[key.strip()] = value.strip()
    wp_value = front.get('wp', '')
    if not re.fullmatch(r'0*' + str(number), wp_value.strip('"\' ')):
        errors.append(f'поле wp карточки равно {wp_value!r}, ожидался номер {number}')
    title_raw = front.get('title', '').strip()
    if len(title_raw) >= 2 and title_raw[0] == title_raw[-1] and title_raw[0] in '"\'':
        title_raw = title_raw[1:-1].replace('\\"', '"').replace('\\\\', '\\')
    title = plain(title_raw) or None
    if title is None:
        errors.append('в карточке нет названия (поле title)')


def check_title(where, title_cell):
    if title is not None and plain(title[:80]) not in plain(title_cell):
        errors.append(f'название в {where} не совпадает с карточкой: ожидалось «{title[:80]}»')


# 2. Реестр
registry_lines = read(gov / 'docs/WP-REGISTRY.md')
registry_rows = []
number_col = None
registry_title_col = None
for line in registry_lines:
    if not is_row(line):
        number_col = None  # a table ended: never reuse its column in the next one
        registry_title_col = None
        continue
    if is_separator(line):
        continue
    row = cells(line)
    names = [plain(c) for c in row]
    if '#' in names and 'Название' in names:
        number_col = names.index('#')
        registry_title_col = names.index('Название')
        continue
    if number_col is not None and number_col < len(row) and cell_number(row[number_col]) == number:
        registry_rows.append(row[registry_title_col] if registry_title_col < len(row) else '')
if len(registry_rows) != 1:
    errors.append(f'в реестре строк с номером {number}: {len(registry_rows)} (нужна ровно одна)')
else:
    check_title('реестре', registry_rows[0])

# 3. WeekPlan: таблицы с ячейками «РП», «#» и «Статус…», не под заголовками фактов
FACTS = re.compile(r'итог|сводк|summary', re.IGNORECASE)
PLAN = re.compile(r'план', re.IGNORECASE)
plan_rows = []      # (ячейка названия, под заголовком «План»)
heading_stack = []  # (уровень, текст)
summaries = []      # <summary> открытых <details>
in_fence = False
in_comment = False
table_ok = None     # None — вне таблицы, True/False — кандидат или нет
plan_col = None
plan_title_col = None
table_titled = False
titled_table_seen = False
plan_lines = read(weekplan)
for line in plan_lines:
    stripped = line.strip()
    if in_comment:
        if '-->' in stripped:
            in_comment = False
        continue
    if stripped.startswith('<!--') and '-->' not in stripped:
        in_comment = True
        continue
    if stripped.startswith('```') or stripped.startswith('~~~'):
        in_fence = not in_fence
        table_ok = None
        continue
    if in_fence:
        continue
    heading = re.match(r'(#{1,6}) +(.*)', line)
    if heading:
        level = len(heading.group(1))
        heading_stack = [h for h in heading_stack if h[0] < level] + [(level, heading.group(2))]
        table_ok = None
        continue
    if re.match(r'<details', stripped):
        summaries.append(None)
    sm = re.search(r'<summary>(.*?)</summary>', stripped)
    if sm and summaries and summaries[-1] is None:
        summaries[-1] = sm.group(1)
    if stripped.startswith('</details>') and summaries:
        summaries.pop()
    if not is_row(line):
        table_ok = None
        continue
    row = cells(line)
    if table_ok is None:
        names = [plain(c) for c in row]
        starts_status = any(c.startswith('Статус') for c in names)
        has_number = '#' in names or 'РП' in names
        has_title = ('#' in names and 'РП' in names) or 'Работа' in names
        if starts_status and has_number and has_title:
            ancestors = [h[1] for h in heading_stack] + [s or '' for s in summaries]
            table_ok = not any(FACTS.search(a) for a in ancestors)
            table_titled = any(PLAN.search(a) for a in ancestors)
            plan_col = names.index('#') if '#' in names else names.index('РП')
            plan_title_col = names.index('РП') if '#' in names and 'РП' in names else names.index('Работа')
            titled_table_seen |= table_ok and table_titled
        else:
            table_ok = False
        continue
    if is_separator(line) or not table_ok:
        continue
    if plan_col < len(row) and cell_number(row[plan_col]) == number:
        title_cell = row[plan_title_col] if plan_title_col < len(row) else ''
        plan_rows.append((title_cell, table_titled))
if titled_table_seen:
    plan_rows = [r for r in plan_rows if r[1]]
plan_rows = [title_cell for title_cell, _ in plan_rows]
if len(plan_rows) != 1:
    errors.append(f'в таблице «План» {weekplan} строк с номером {number}: {len(plan_rows)} (нужна ровно одна)')
else:
    check_title('плане недели', plan_rows[0])

if errors:
    print(f'РП {number}: регистрация не согласована:', file=sys.stderr)
    for e in errors:
        print(f'  - {e}', file=sys.stderr)
    sys.exit(1)
print(f'РП {number}: карточка, реестр и план недели согласованы')
PY
