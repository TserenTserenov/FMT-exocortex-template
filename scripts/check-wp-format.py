#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
check-wp-format.py — линтер WP-REGISTRY.md (WP-7 T2 + name contamination guard)

Проверяет два класса нарушений:
  T2. Форматирование done-строк: ✅/↗️/📦 без полного ~~strikethrough~~
  NC. Загрязнение имён: служебные данные в колонке «Название»

Использование:
  python3 check-wp-format.py [path/to/WP-REGISTRY.md] [--fix] [--exit-nonzero]

  --fix          автоматически исправить NC-нарушения (T2 исправлять рискованно)
  --exit-nonzero выйти с кодом 1 при любых нарушениях (для pre-commit hook)

Без аргументов: читает $IWE/DS-strategy/docs/WP-REGISTRY.md или ${IWE_GOVERNANCE_REPO:-DS-strategy}/...
"""

import sys
import re
import os

# --- Name pollution patterns (NC) ---
NAME_CONTAMINATION_PATTERNS = [
    re.compile(r"—\s*closed\b", re.IGNORECASE),
    re.compile(r"—\s*closed-partial\b", re.IGNORECASE),
    re.compile(r"\(peer-session\b", re.IGNORECASE),
    re.compile(r"\bPHASE\d*\s*="),
    re.compile(r"\bbacklinks\s*:"),
    re.compile(r"(?:^|\s)[0-9a-f]{40}(?:\s|$)"),  # full SHA (40 chars)
    re.compile(r"(?:^|\s)[0-9a-f]{7}(?:\s|$)"),   # short SHA (7 chars) — only with whitespace boundaries
    re.compile(r"Ф\d+[-–—]Ф\d+\s+done"),    # e.g. «Ф1-Ф5 done»
    re.compile(r"\bФ\d+\s+done\b"),
    re.compile(r"\bФ\d+-Ф\d+\b"),
    re.compile(r"\bpassed\b", re.IGNORECASE),
    re.compile(r"\bPASS\b"),
    re.compile(r"\btests?\b.*\d+"),          # «39 tests passed»
    re.compile(r"batch disposition"),
    re.compile(r"final closeout"),
    re.compile(r"зомби-триаж"),
]

DONE_STATUS_EMOJIS = {"✅", "↗️", "📦"}
ACTIVE_STATUS_EMOJIS = {"⏳", "🔄"}

def is_table_row(line):
    stripped = line.strip()
    return stripped.startswith("|") and stripped.endswith("|") and not stripped.startswith("|---")

def parse_cells(line):
    """Разбить строку таблицы на ячейки."""
    parts = line.strip().split("|")
    # parts[0] is empty (before the first |), parts[-1] is empty (after the last |)
    return [p.strip() for p in parts[1:-1]]

# Fallback indices for the canonical 6-column schema
# (# | P | Название | Ст | Репо | Бюджет) — used only if the table header
# is not found/not recognized (see find_column_indices).
FALLBACK_INDICES = {"#": 0, "P": 1, "Название": 2, "Ст": 3, "Репо": 4, "Бюджет": 5}

def find_column_indices(lines):
    """Определить позиции колонок по строке заголовка (| # | P | Название | ... |).

    issue #263: раньше индекс колонки «Название» был хардкожен (cells[2]) под
    актуальную 6-колоночную схему — на реестре со старой/другой схемой (например,
    | # | Название | Статус | Активация |) это тихо проверяло/чистило не ту ячейку.
    Вместо хардкода — читаем реальный заголовок таблицы и вычисляем индексы по нему,
    так проверка остаётся верной для любой схемы конкретного REGISTRY.

    Возвращает (indices, warning) — indices всегда заполнен (fallback при неудаче),
    warning — строка с пояснением, если пришлось использовать fallback, иначе None.
    """
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("| #"):
            cells = parse_cells(line)
            found = {name: i for i, name in enumerate(cells)}
            # Targeted fallback: a column missing from the header of this particular
            # table is filled from the canonical schema — but the columns found
            # (e.g. «Название» in the old 4-column schema) are not lost for the sake of
            # missing neighbors (P/Репо are simply absent there by the schema's meaning).
            missing = [name for name in FALLBACK_INDICES if name not in found]
            indices = {name: found.get(name, FALLBACK_INDICES[name]) for name in FALLBACK_INDICES}
            if missing:
                return indices, (
                    f"заголовок таблицы не содержит колонок {missing} "
                    f"— для них использую индексы канонической схемы как fallback"
                )
            return indices, None
    return FALLBACK_INDICES, (
        "заголовок таблицы (строка «| # | ...») не найден — "
        "использую индексы канонической 6-колоночной схемы как fallback"
    )

def is_done_row(cells):
    """Строка со статусом done (✅/↗️/📦)."""
    for cell in cells:
        if cell in DONE_STATUS_EMOJIS:
            return True
    return False

def has_strikethrough(text):
    """Текст обёрнут в ~~ ... ~~."""
    return "~~" in text

def check_t2(cells, line_num, indices):
    """T2: done-строки должны иметь ~~ на полях #, P, Название, Репо."""
    issues = []
    if not is_done_row(cells):
        return issues
    # Check the cells #, P, Название, Репо — positions are taken from the actual
    # table header (indices), not hardcoded (issue #263).
    if len(cells) >= 5:
        check_indices = sorted({indices["#"], indices["P"], indices["Название"], indices["Репо"]})
    else:
        check_indices = range(min(3, len(cells)))
    for i in check_indices:
        if i >= len(cells):
            continue
        cell = cells[i]
        if not cell or cell in DONE_STATUS_EMOJIS | ACTIVE_STATUS_EMOJIS:
            continue
        # The field with content must be wrapped in ~~...~~
        if not has_strikethrough(cell):
            # Check that it is not just a dash/hyphen placeholder
            if cell not in ("—", "-", ""):
                issues.append({
                    "line": line_num,
                    "type": "T2",
                    "cell_index": i,
                    "cell_value": cell[:60],
                    "message": f"done-строка, ячейка [{i}] без ~~strikethrough~~: «{cell[:40]}»"
                })
    return issues

def check_nc(cells, line_num, name_col):
    """NC: загрязнение имён — служебные данные в колонке «Название»."""
    issues = []
    if name_col >= len(cells):
        return issues
    name_cell = cells[name_col]
    for pattern in NAME_CONTAMINATION_PATTERNS:
        if pattern.search(name_cell):
            issues.append({
                "line": line_num,
                "type": "NC",
                "pattern": pattern.pattern,
                "cell_value": name_cell[:80],
                "message": f"загрязнение имени (паттерн «{pattern.pattern}»): «{name_cell[:60]}»"
            })
            break  # one message per row is enough
    return issues

def clean_name_cell(name_cell):
    """Очистить колонку «Название» от служебных данных."""
    cleaned = name_cell

    # Remove «— closed DATE (details)»
    cleaned = re.sub(r"\s*—\s*closed(?:-partial)?\b.*$", "", cleaned, flags=re.DOTALL | re.IGNORECASE)
    # Remove «— Ф1-Ф5 done DATE (...); Ф6 — backlog» (all kinds of dashes)
    cleaned = re.sub(r"\s*[-–—]\s*Ф\d[^|]*$", "", cleaned, flags=re.DOTALL)
    # Remove «(backlinks: WP-123 ...)»
    cleaned = re.sub(r"\s*\(backlinks\s*:[^)]*\).*$", "", cleaned, flags=re.DOTALL | re.IGNORECASE)
    # Remove «(peer-session ...) ...»
    cleaned = re.sub(r"\s*\(peer-session\b[^)]*\).*$", "", cleaned, flags=re.DOTALL | re.IGNORECASE)
    # Remove «(PHASE1=5...) ...»
    cleaned = re.sub(r"\s*\(PHASE\d*\s*=[^)]*\).*$", "", cleaned, flags=re.DOTALL | re.IGNORECASE)
    # Remove batch disposition / final closeout tails
    cleaned = re.sub(r"\s*—\s*(?:batch disposition|final closeout|зомби-триаж)\b.*$", "", cleaned,
                     flags=re.DOTALL | re.IGNORECASE)

    return cleaned.strip()


def fix_t2_row(parts, cells, indices):
    """Добавить ~~ вокруг ячеек done-строки без strikethrough (#, P, Репо — не Название,
    её вручную оборачивать рискованно из-за markdown-разметки внутри)."""
    # Mapping: cell_index -> part_index (parts[0] is empty, parts[-1] is empty, cells start at 1)
    cell_to_part = {i: i + 1 for i in range(len(cells))}
    changed = False
    for cell_idx in sorted({indices["#"], indices["P"], indices["Репо"]}):
        if cell_idx >= len(cells):
            continue
        part_idx = cell_to_part[cell_idx]
        if part_idx >= len(parts):
            continue
        cell = cells[cell_idx]
        if not cell or cell in DONE_STATUS_EMOJIS | ACTIVE_STATUS_EMOJIS:
            continue
        if cell in ("—", "-", ""):
            continue
        if has_strikethrough(cell):
            continue
        # Cell without ~~ -> wrap
        # Remove ** around if present
        clean = re.sub(r"^\*\*(.+)\*\*$", r"\1", cell.strip())
        parts[part_idx] = f" ~~{clean}~~ "
        changed = True
    return parts, changed


def process_file(registry_path, fix=False, fix_t2=False, exit_nonzero=False):
    with open(registry_path, "r", encoding="utf-8") as f:
        lines = f.readlines()

    indices, warning = find_column_indices(lines)
    if warning:
        print(f"⚠️  {warning}", file=sys.stderr)
    name_col = indices["Название"]

    all_issues = []
    new_lines = list(lines)

    for i, line in enumerate(lines):
        line_num = i + 1
        if not is_table_row(line):
            continue
        cells = parse_cells(line)
        if len(cells) < 3:
            continue

        t2_issues = check_t2(cells, line_num, indices)
        nc_issues = check_nc(cells, line_num, name_col)
        all_issues.extend(t2_issues)
        all_issues.extend(nc_issues)

        if fix_t2 and t2_issues and is_done_row(cells):
            parts = new_lines[i].rstrip("\n").split("|")
            parts, changed = fix_t2_row(parts, cells, indices)
            if changed:
                new_lines[i] = "|".join(parts) + "\n"

        if fix and nc_issues:
            # Fix NC in this row
            parts = line.rstrip("\n").split("|")
            name_part = name_col + 1  # parts[0] is empty because of the leading "|"
            if len(parts) >= name_part + 1:
                original_cell = parts[name_part]
                stripped_content = original_cell.strip()

                # Deal with the ~~...~~ wrapper
                has_strike_before = stripped_content.startswith("~~") and "~~" in stripped_content[2:]
                if has_strike_before:
                    # Extract the content from ~~...~~ with the tail
                    inner_match = re.match(r"~~(.+?)~~(.*)", stripped_content, re.DOTALL)
                    if inner_match:
                        inner = inner_match.group(1)
                        tail = inner_match.group(2)
                        cleaned_inner = clean_name_cell(inner)
                        cleaned_tail = clean_name_cell(tail) if tail.strip() else ""
                        cleaned_cell = f"~~{cleaned_inner}~~"
                        if cleaned_tail:
                            cleaned_cell += f" {cleaned_tail}"
                    else:
                        cleaned_cell = clean_name_cell(stripped_content)
                else:
                    # Active row (without ~~)
                    inner_match = re.match(r"\*?\*?(.+?)\*?\*?$", stripped_content, re.DOTALL)
                    inner = inner_match.group(1) if inner_match else stripped_content
                    # Remove ** around
                    inner = re.sub(r"^\*\*(.+)\*\*$", r"\1", inner)
                    cleaned = clean_name_cell(inner)
                    # Restore ** if there were any
                    if stripped_content.startswith("**"):
                        cleaned_cell = f"**{cleaned}**"
                    else:
                        cleaned_cell = cleaned

                parts[name_part] = f" {cleaned_cell} "
                new_lines[i] = "|".join(parts) + "\n"

    if (fix or fix_t2) and any(new_lines[i] != lines[i] for i in range(len(lines))):
        with open(registry_path, "w", encoding="utf-8", newline="\n") as f:
            f.writelines(new_lines)
        print(f"   ✅ Исправлено {sum(1 for i in range(len(lines)) if new_lines[i] != lines[i])} строк")

    # Summary
    t2_count = sum(1 for iss in all_issues if iss["type"] == "T2")
    nc_count = sum(1 for iss in all_issues if iss["type"] == "NC")

    print(f"\ncheck-wp-format.py — {registry_path}")
    print(f"  T2 (форматирование done-строк): {t2_count} нарушений")
    print(f"  NC (загрязнение имён):          {nc_count} нарушений")

    if all_issues:
        print("\nДетали:")
        for iss in all_issues:
            print(f"  [{iss['type']}] строка {iss['line']}: {iss['message']}")

    if not all_issues:
        print("  ✅ Нарушений не найдено")

    if exit_nonzero and all_issues:
        sys.exit(1)

    return all_issues


if __name__ == "__main__":
    args = sys.argv[1:]
    fix_mode = "--fix" in args
    fix_t2_mode = "--fix-t2" in args
    exit_nonzero = "--exit-nonzero" in args
    args = [a for a in args if not a.startswith("--")]

    if args:
        registry = args[0]
    else:
        iwe = os.environ.get("IWE_ROOT", os.path.expanduser("~/IWE"))
        gov = os.environ.get("IWE_GOVERNANCE_REPO", "DS-strategy")
        # Try to find REGISTRY via the repo-name env var
        for gov_name in [gov]:
            candidate = os.path.join(iwe, gov_name, "docs", "WP-REGISTRY.md")
            if os.path.exists(candidate):
                registry = candidate
                break
        else:
            print("Не найден WP-REGISTRY.md. Укажите путь явно.", file=sys.stderr)
            sys.exit(1)

    process_file(registry, fix=fix_mode, fix_t2=fix_t2_mode, exit_nonzero=exit_nonzero)
