#!/usr/bin/env python3
"""Детектор раздутых индекс-файлов.

Правило: feedback_memory_index_discipline.md (auto-memory).
Шапки и колонки файлов-реестров держим как индекс с one-line hooks;
changelog / статус / контекст сущности — в source-of-truth, не в индексе.

Usage:
    check-index-health.py [ROOT]

ROOT: корень скана (default: ~/IWE).

Exit code:
    0 — все OK
    1 — найдены WARN или FAIL
    2 — ошибка запуска (root не найден)

Сканирует по именам файлов: MEMORY.md, WP-REGISTRY.md, REGISTRY.md, INDEX.md,
CATALOG.md, TOC.md, MAPSTRATEGIC.md, Projects.md, *-registry.md, *-index.md,
*-catalog.md. Пропускает archive/, node_modules/, .git/, .venv/.

Критерии (char count, не bytes):
    FAIL: размер >100KB | любая строка >500 ch | ячейка таблицы >400 ch
    WARN: размер >30KB | любая строка >300 ch | ячейка таблицы >200 ch
    OK: всё под порогами.
    Размер сам по себе — слабый маркер: реестр 300 РП × 100 ch = 30KB.

Пропуск файлов через комментарий в начале файла:
    <!-- index-health: skip --> — не сканировать
    <!-- index-health: skip-cells --> — не проверять ячейки таблиц
        (для методологических таблиц-матриц типа Projects.md каскад ВДВ)
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

# Строка-РП в реестре: первая ячейка = номер (возможно жирный/зачёркнутый).
# Done-форматирование (formatting.md §Done): закрытый РП зачёркнут (~~...~~).
# Дефект: статус ✅ проставлен, а номер не обёрнут в ~~ → строка выглядит активной.
_WP_NUM_CELL = re.compile(r"^\*{0,2}~{0,2}\*{0,2}\d+\*{0,2}~{0,2}\*{0,2}$")
_DONE_EMOJI = "✅"
_STATUS_EMOJI = (
    "✅", "🔄", "⏳", "⏸", "↗️", "📦", "🚧", "❌", "⚪",
    "🟢", "🟡", "🔴", "⚫",
)
_CELL_LEAD_MARKUP = "*~ \t"
_STATUS_HEADERS = {"ст", "статус", "status", "state"}
_WP_NUMBER_HEADERS = {"#", "№", "wp", "рп", "id"}

NAME_PATTERNS = {
    "MEMORY.md",
    "WP-REGISTRY.md",
    "REGISTRY.md",
    "INDEX.md",
    "CATALOG.md",
    "TOC.md",
    "MAPSTRATEGIC.md",
    "Projects.md",
}
GLOB_PATTERNS = ["*-registry.md", "*-index.md", "*-catalog.md"]
SKIP_DIRS = {"archive", "inbox", "drafts", "sessions", "exocortex",
             "node_modules", ".git", ".venv", "__pycache__"}
# exocortex/ пропускается: это backup-зеркало auto-memory (Day Close snapshot).
# Настоящий source — ~/.claude/projects/.../memory/. Файлы обновляются автоматически.

SIZE_WARN = 30 * 1024       # 30 KB — информационный порог
SIZE_FAIL = 100 * 1024      # 100 KB — явно гипертрофия
LINE_WARN = 300
LINE_FAIL = 500
CELL_WARN = 200
CELL_FAIL = 400
# Размер сам по себе — слабый маркер: реестр из 300 РП × 100 chars = 30KB, норма.
# Настоящие маркеры — длинные строки/ячейки.


def _plain_table_cell(cell: str) -> str:
    return cell.strip("*~` \t").rstrip(".").casefold()


def _status_column(cells: list[str]) -> int | None:
    """Find the status column from a Markdown registry header."""
    if not cells or _plain_table_cell(cells[0]) not in _WP_NUMBER_HEADERS:
        return None
    for index, cell in enumerate(cells[1:], start=1):
        if _plain_table_cell(cell) in _STATUS_HEADERS:
            return index
    return None


def _status_cell(cells: list[str], status_column: int | None) -> str | None:
    """Return the header-bound status, with a legacy emoji fallback."""
    if status_column is not None and status_column < len(cells):
        return cells[status_column].lstrip(_CELL_LEAD_MARKUP)
    for cell in cells[1:]:
        head = cell.lstrip(_CELL_LEAD_MARKUP)
        if head.startswith(_STATUS_EMOJI):
            return head
    return None


def check_file(path: Path) -> dict:
    size = path.stat().st_size
    out = {
        "size": size,
        "long_lines": [],      # list of (lineno, char_len)
        "long_cells": [],      # list of (lineno, cell_idx, char_len)
        "done_no_strike": [],  # list of (lineno, wp_number) — ✅ без зачёркивания
        "skip": False,
        "skip_cells": False,
        "size_skip": False,
    }
    try:
        text = path.read_text(encoding="utf-8")
    except (UnicodeDecodeError, OSError):
        out["skip"] = True
        return out

    head = text[:512]
    # index-health: skip отключает проверки РАЗДУТИЯ (размер/длина/ячейки),
    # но НЕ семантику done-форматирования — она дешёвая и не зависит от размера.
    size_skip = "<!-- index-health: skip -->" in head
    out["size_skip"] = size_skip
    if "<!-- index-health: skip-cells -->" in head:
        out["skip_cells"] = True

    status_column = None
    for lineno, line in enumerate(text.splitlines(), start=1):
        n = len(line)
        is_table_row = line.lstrip().startswith("|")
        if not is_table_row:
            status_column = None
        # skip-cells: таблица с допустимо большими ячейками → не алертим
        # ни на ячейки, ни на длину самой строки таблицы
        if not size_skip and n > LINE_WARN and not (out["skip_cells"] and is_table_row):
            out["long_lines"].append((lineno, n))

        if is_table_row:
            # markdown table row: split by | and drop outer empties
            raw = line.split("|")
            cells = [c.strip() for c in raw[1:-1]] if len(raw) >= 3 else []
            detected_status_column = _status_column(cells)
            if detected_status_column is not None:
                status_column = detected_status_column
            # skip separator rows (all cells are dashes)
            if cells and all(set(c) <= set("-: ") for c in cells):
                continue
            # done-форматирование: только ведущий эмодзи ЯЧЕЙКИ СТАТУСА
            # задаёт состояние РП. Галочка внутри описания завершённой фазы не
            # превращает активный РП в закрытый (issue #531).
            if cells and _WP_NUM_CELL.match(cells[0]) and "~~" not in cells[0]:
                status = _status_cell(cells, status_column)
                if status is not None and status.startswith(_DONE_EMOJI):
                    num = re.sub(r"[*~]", "", cells[0])
                    out["done_no_strike"].append((lineno, num))
            if not out["skip_cells"] and not size_skip:
                for idx, cell in enumerate(cells):
                    cn = len(cell)
                    if cn > CELL_WARN:
                        out["long_cells"].append((lineno, idx, cn))
    return out


def classify(findings: dict) -> str:
    size = 0 if findings["size_skip"] else findings["size"]
    max_line = max((n for _, n in findings["long_lines"]), default=0)
    max_cell = max((n for _, _, n in findings["long_cells"]), default=0)
    if size > SIZE_FAIL or max_line > LINE_FAIL or max_cell > CELL_FAIL:
        return "FAIL"
    if size > SIZE_WARN or max_line > LINE_WARN or max_cell > CELL_WARN \
            or findings["done_no_strike"]:
        return "WARN"
    return "OK"


def iter_index_files(root: Path):
    for path in root.rglob("*.md"):
        if any(p in SKIP_DIRS for p in path.parts):
            continue
        if path.name in NAME_PATTERNS:
            yield path
            continue
        for pat in GLOB_PATTERNS:
            if path.match(pat):
                yield path
                break


def fmt_file_line(path: Path, root: Path, findings: dict) -> str:
    rel = path.relative_to(root)
    size_kb = findings["size"] / 1024
    parts = [f"{rel}  {size_kb:.1f}KB"]
    if findings["long_lines"]:
        top = max(findings["long_lines"], key=lambda x: x[1])
        parts.append(f"long-line L{top[0]}={top[1]}ch ({len(findings['long_lines'])}×)")
    if findings["long_cells"]:
        top = max(findings["long_cells"], key=lambda x: x[2])
        parts.append(f"long-cell L{top[0]}={top[2]}ch ({len(findings['long_cells'])}×)")
    if findings["done_no_strike"]:
        nums = ",".join(n for _, n in findings["done_no_strike"])
        parts.append(f"done-no-strike WP-[{nums}] ({len(findings['done_no_strike'])}×)")
    return "  " + "  ".join(parts)


def main() -> int:
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path.home() / "IWE"
    if not root.is_dir():
        print(f"FAIL: root dir not found: {root}", file=sys.stderr)
        return 2

    buckets = {"FAIL": [], "WARN": [], "OK": [], "SKIP": []}
    for path in sorted(iter_index_files(root)):
        findings = check_file(path)
        if findings["skip"]:
            buckets["SKIP"].append((path, findings))
            continue
        buckets[classify(findings)].append((path, findings))

    total = sum(len(v) for v in buckets.values())
    print(f"Index health scan — root: {root}")
    print(f"Scanned: {total} files ({len(buckets['FAIL'])} FAIL, "
          f"{len(buckets['WARN'])} WARN, {len(buckets['OK'])} OK, "
          f"{len(buckets['SKIP'])} skip)")

    for level in ("FAIL", "WARN"):
        if not buckets[level]:
            continue
        print(f"\n=== {level} ({len(buckets[level])}) ===")
        for path, findings in buckets[level]:
            print(fmt_file_line(path, root, findings))

    if buckets["SKIP"]:
        print(f"\n=== SKIP ({len(buckets['SKIP'])}) ===")
        for path, _ in buckets["SKIP"]:
            print(f"  {path.relative_to(root)}")

    return 1 if (buckets["FAIL"] or buckets["WARN"]) else 0


if __name__ == "__main__":
    sys.exit(main())
