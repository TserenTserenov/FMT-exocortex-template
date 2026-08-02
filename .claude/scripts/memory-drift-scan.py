#!/usr/bin/env python3
"""Детектор дрейфа статусов между MEMORY.md и WP-context.

Правило: day-close/SKILL.md шаг 4б «Memory Drift Scan» (issue #326).
Прежняя реализация была чисто лексической (grep по словам «ждёт/блокер/
blocked/остановлен») и пропускала расхождения, где статус в MEMORY.md
устарел, но текст строки не содержит триггерных слов (например, строка
осталась `pending`, хотя WP-context уже `done`).

Этот скрипт добавляет ВТОРУЮ, структурную проверку: сверяет значение
колонки статуса в таблице «РП текущей недели» / «Текущая работа»
MEMORY.md с полем `status` во frontmatter соответствующего WP-context
файла. Лексическую проверку (текстовые блокеры без изменения статуса)
day-close выполняет отдельно, этот скрипт её не заменяет.

Формат колонки статуса: заголовок «Статус» (дефолт, текстовые значения
pending/in_progress/done) или сокращённое «ст» (пользовательская
кастомизация, эмодзи-значения — см. `_EMOJI_TO_STATUS`).

Usage:
    memory-drift-scan.py [--memory PATH] [--governance-repo PATH]

--memory: путь к MEMORY.md (default: ~/IWE/memory/MEMORY.md)
--governance-repo: корень governance-репо, где искать inbox/WP-N/
    (default: ~/IWE/DS-strategy, переопределяется $IWE_GOVERNANCE_REPO)

Exit code:
    0 — дрейфов не найдено
    1 — найдены дрейфы (вывод — markdown-список, day-close вставляет
        в отчёт без дополнительного парсинга)
    2 — ошибка запуска (MEMORY.md не найден)
"""
from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path

import yaml

# Строка таблицы РП: `| 1 | Название | Бюджет | Статус | ... |` — берём
# первую числовую ячейку (номер РП) и ячейку под заголовком «Статус».
_TABLE_ROW = re.compile(r"^\|\s*(\d+)\s*\|(.+)\|\s*$")

# Заголовок колонки статуса: дефолтный шаблон использует полное слово
# «Статус» с текстовыми значениями (pending/in_progress/done); наблюдалась
# и сокращённая пользовательская колонка «ст» с эмодзи-значениями —
# оба варианта распознаём по алиасу заголовка.
_STATUS_HEADER_ALIASES = {"Статус", "ст"}

# Эмодзи → канонический текстовый статус (см. .claude/rules/formatting.md
# «Эмодзи-статусы»). Список best-effort по наблюдаемому употреблению в
# MEMORY.md пользователей, не закрытый — расширять по мере встречи новых
# значений. Эмодзи без записи в маппинге сравниваются как есть (буквально)
# и, скорее всего, не совпадут ни с одним текстовым `status:` — это то же
# поведение, что было бы без маппинга вообще, не регрессия.
_EMOJI_TO_STATUS = {
    "🔄": "in_progress",
    "⏳": "pending",
    "🏭": "in_progress",
    "⚠️": "blocked",
    "✅": "done",
}


def normalize_status(raw: str) -> str:
    """Эмодзи-значение → канонический текстовый статус; текст возвращается как есть."""
    return _EMOJI_TO_STATUS.get(raw, raw)


def find_status_column(header_line: str) -> int | None:
    """Индекс колонки статуса (по алиасам заголовка) в разделённой `|` строке."""
    cells = [c.strip() for c in header_line.strip().strip("|").split("|")]
    for idx, name in enumerate(cells):
        if name in _STATUS_HEADER_ALIASES:
            return idx
    return None


def parse_memory_table(memory_path: Path) -> dict[int, str]:
    """Возвращает {номер_РП: нормализованный_статус_из_MEMORY.md} для активной таблицы РП."""
    lines = memory_path.read_text(encoding="utf-8").splitlines()
    status_col = None
    result: dict[int, str] = {}
    for i, line in enumerate(lines):
        if line.strip().startswith("|") and status_col is None:
            candidate_col = find_status_column(line)
            if candidate_col is not None:
                status_col = candidate_col
            continue
        if status_col is None:
            continue
        if line.strip().startswith("|---"):
            continue
        m = _TABLE_ROW.match(line)
        if not m:
            # Пустая строка или конец таблицы — сбрасываем колонку, ищем следующую таблицу.
            if not line.strip().startswith("|"):
                status_col = None
            continue
        wp_num = int(m.group(1))
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        if status_col >= len(cells):
            continue
        result[wp_num] = normalize_status(cells[status_col])
    return result


def find_wp_context(governance_repo: Path, wp_num: int) -> Path | None:
    """Ищет inbox/WP-N/WP-N.md, fallback archive/wp-contexts/WP-N*.md."""
    active = governance_repo / "inbox" / f"WP-{wp_num}" / f"WP-{wp_num}.md"
    if active.is_file():
        return active
    archive_dir = governance_repo / "archive" / "wp-contexts"
    if archive_dir.is_dir():
        matches = sorted(archive_dir.glob(f"WP-{wp_num}-*.md"))
        if matches:
            return matches[0]
    return None


def read_context_status(context_path: Path) -> str | None:
    """Извлекает `status:` из YAML frontmatter WP-context файла."""
    text = context_path.read_text(encoding="utf-8")
    if not text.startswith("---"):
        return None
    end = text.find("\n---", 3)
    if end == -1:
        return None
    try:
        frontmatter = yaml.safe_load(text[3:end])
    except yaml.YAMLError as exc:
        print(f"WARN: невалидный YAML frontmatter, пропускаю: {context_path} ({exc})", file=sys.stderr)
        return None
    if not isinstance(frontmatter, dict):
        return None
    status = frontmatter.get("status")
    return str(status) if status is not None else None


def scan(memory_path: Path, governance_repo: Path) -> list[str]:
    """Возвращает список markdown-строк с найденными дрейфами."""
    memory_statuses = parse_memory_table(memory_path)
    drifts: list[str] = []
    for wp_num, memory_status in sorted(memory_statuses.items()):
        context_path = find_wp_context(governance_repo, wp_num)
        if context_path is None:
            continue
        context_status = read_context_status(context_path)
        if context_status is None:
            continue
        if context_status != memory_status:
            drifts.append(
                f"- РП-{wp_num}: MEMORY.md=`{memory_status}` vs "
                f"WP-context=`{context_status}` "
                f"({context_path.relative_to(governance_repo)})"
            )
    return drifts


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--memory",
        type=Path,
        default=Path.home() / "IWE" / "memory" / "MEMORY.md",
    )
    parser.add_argument(
        "--governance-repo",
        type=Path,
        default=Path.home() / "IWE" / os.environ.get("IWE_GOVERNANCE_REPO", "DS-strategy"),
    )
    args = parser.parse_args()

    if not args.memory.is_file():
        print(f"FAIL: MEMORY.md не найден: {args.memory}", file=sys.stderr)
        return 2

    drifts = scan(args.memory, args.governance_repo)
    if not drifts:
        print("Drift-scan (структурный): 0 расхождений")
        return 0

    print(f"Drift-scan (структурный): {len(drifts)} расхождений")
    for line in drifts:
        print(line)
    return 1


if __name__ == "__main__":
    sys.exit(main())
