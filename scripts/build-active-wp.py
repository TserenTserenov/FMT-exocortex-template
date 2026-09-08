#!/usr/bin/env python3
"""build-active-wp.py — пересборка current/active-wp.md из docs/WP-REGISTRY.md.

Source-of-truth: WP-REGISTRY.md (markdown-таблица).
Вывод: current/active-wp.md — открытые РП (🔄 ⏳ 🧪 🚧 ⏸) сверху, закрытые (✅ 📦 ↗️ ❌) ниже,
обе секции по убыванию номера РП.

Usage:
  python3 build-active-wp.py [--check | --deep-check | --semantic-check]

  без флагов        — перезаписывает active-wp.md
  --check           — exit 1 если active-wp.md расходится с реестром (pre-commit guard)
  --deep-check      — exit 1 если есть orphan WP-NNN (в реестре нет inbox/archive файла,
                       или файл есть, а в реестре нет) ЛИБО строка реестра не
                       классифицируется (неизвестный статус, битые колонки).
                       Day Open / periodic reconciliation.
  --semantic-check  — exit 1 если статус в реестре расходится с placement (active WP
                       только в archive/, или closed WP только в inbox/). Week Close.

Инвариант (bug WP-285, 2026-07-16): строка с номером РП НИКОГДА не сбрасывается молча.
Неизвестный статус/битые колонки → строка учитывается в orphan-детекции + явный
PARSE-WARN. Раньше строка с «⏸» выпадала из парсера целиком, и deep-check ложно
сообщал «нет строки в WP-REGISTRY.md», а РП исчезал из active-wp.md.

  see peer-session 2026-06-01-21-wp-registry-drift-guard
"""
from __future__ import annotations

import os
import re
import sys
from pathlib import Path

# Governance-репо (где живёт WP-REGISTRY.md) резолвится через IWE_GOVERNANCE_REPO,
# не от расположения скрипта — на пользовательской установке скрипт остаётся внутри
# FMT-exocortex-template/scripts/, а реестр живёт в отдельном governance-репо (#293).
IWE_ROOT = Path(os.environ.get("IWE_ROOT", Path.home() / "IWE"))
GOV_REPO = os.environ.get("IWE_GOVERNANCE_REPO", "DS-strategy")
ROOT = IWE_ROOT / GOV_REPO
REGISTRY = ROOT / "docs" / "WP-REGISTRY.md"
OUTPUT = ROOT / "current" / "active-wp.md"
INBOX_DIR = ROOT / "inbox"
ARCHIVE_DIR = ROOT / "archive" / "wp-contexts"

# Статусы храним без U+FE0F (emoji variation selector): "стрелка с VS16" и без него - один статус.
# ⏹ (снят) и 🔁 (свёрнут в спринт) - issue #473: реестр их уже использует,
# парсер их не знал, обе строки проваливались в PARSE-WARN как "неизвестный статус".
ACTIVE_STATUSES = {"🔄", "⏳", "🧪", "🚧", "⏸"}
CLOSED_STATUSES = {"✅", "📦", "↗", "❌", "⏹", "🔁"}
ALL_STATUSES = ACTIVE_STATUSES | CLOSED_STATUSES


def norm_status(token: str) -> str:
    return token.replace("\ufe0f", "")

# Строка-РП: `| 312 | P2 | **Название** | 🔄 | repo | 8h |`
# Done-вариант: `| ~~306~~ | ~~P3~~ | ~~Название~~ | ✅ | ~~repo~~ | ~~4h~~ |`
ROW_RE = re.compile(r"^\|\s*(?:~~)?(?:\*\*)?(?:WP-)?(\d{1,4})(?:\*\*)?(?:~~)?\s*\|")

# Имя файла WP в inbox/archive: WP-NNN-... .md или WP-NNN.md или папка WP-NNN/
WP_NAME_RE = re.compile(r"^WP-(\d{1,4})(?:[-.].*|/)?$")

# issue #473: колонки реестра читались по жёсткой позиции (cols[3] = статус и
# т.д.), схема таблицы `| # | P | Название | Ст | Репо | Бюджет |`. Реальные
# реестры расходятся и по числу, и по порядку колонок (одна установка добавила
# "Ставка" между Репо и Бюджет, другая использует "Статус | Цель | Создан | P"
# в другом порядке) - жёсткая позиция читала не ту колонку молча. Индекс
# теперь определяется по имени колонки из строки-заголовка.
HEADER_RE = re.compile(r"^\|\s*#\s*\|")
_COLUMN_ALIASES = {
    "wp": {"#", "№"},
    "name": {"название"},
    "status": {"статус", "ст"},
    "repo": {"репо"},
    "budget": {"бюджет"},
    "project": {"p", "п"},
}
_REQUIRED_COLUMNS = {"name", "status"}


_TABLE_SEPARATOR_RE = re.compile(r"^\|[\s:-]+\|[\s:-]*\|?")


def find_header_columns(text: str) -> dict[str, int]:
    """Индекс {роль: позиция} по строке-заголовку `| # | ... |`. Пустой словарь,
    если заголовок не найден - вызывающий код обязан явно на это отреагировать,
    не подставлять позиции по умолчанию.

    Найдено пир-сессией с Codex (ход 3): берём только ПЕРВУЮ строку вида
    "| # | ... |" в файле, а такая строка теоретически может встретиться и
    в легенде статусов внутри <details> раньше настоящей шапки таблицы.
    Кандидат принимается, только если следующая строка - markdown-разделитель
    (`|---|---|...`), как и положено настоящей шапке таблицы."""
    lines = text.splitlines()
    for i, line in enumerate(lines):
        if not HEADER_RE.match(line):
            continue
        next_line = lines[i + 1] if i + 1 < len(lines) else ""
        if not _TABLE_SEPARATOR_RE.match(next_line):
            continue
        cells = [c.strip().lower() for c in line.strip("|").split("|")]
        idx: dict[str, int] = {}
        for j, cell in enumerate(cells):
            for role, aliases in _COLUMN_ALIASES.items():
                if cell in aliases and role not in idx:
                    idx[role] = j
        return idx
    return {}


def parse_registry(text: str) -> tuple[list[dict], list[str]]:
    """Разбор реестра. Строка с номером РП никогда не сбрасывается молча:
    непарсибельные попадают в rows (для orphan-детекции) + в problems (PARSE-WARN)."""
    columns = find_header_columns(text)
    missing_required = _REQUIRED_COLUMNS - columns.keys()
    if missing_required:
        raise ValueError(
            f"в шапке реестра (строка '| # | ... |') не найдены обязательные колонки: "
            f"{sorted(missing_required)} - распознаны: {columns}"
        )

    rows: list[dict] = []
    problems: list[str] = []
    for lineno, line in enumerate(text.splitlines(), 1):
        m = ROW_RE.match(line)
        if not m:
            continue
        wp = int(m.group(1))
        cols = [c.strip() for c in line.strip("|").split("|")]
        max_needed = max(columns.values())
        if len(cols) <= max_needed:
            problems.append(
                f"WP-{wp} (строка {lineno}): {len(cols)} колонок, ожидалось минимум "
                f"{max_needed + 1} по шапке реестра - строка учтена, но не попадает в active-wp.md."
            )
            cols = cols + [""] * (max_needed + 1 - len(cols))

        def cell(role: str, cols=cols) -> str:
            i = columns.get(role)
            return cols[i].strip() if i is not None and i < len(cols) else ""

        # Очистка от ~~ и пробелов; берём только первый токен, чтобы
        # принять варианты вида "🔄 Ф4" (статус + пометка фазы).
        status_raw = cell("status").replace("~~", "").strip()
        token = status_raw.split()[0] if status_raw else ""
        status = norm_status(token)
        if status not in ALL_STATUSES:
            problems.append(
                f"WP-{wp} (строка {lineno}): неизвестный статус {token!r} - строка учтена "
                f"в реестре, но не попадает ни в открытые, ни в закрытые active-wp.md."
            )
        rows.append({
            "wp": wp,
            "project": cell("project").replace("~~", "").strip(),
            "name": cell("name"),
            "status": status,
            "status_display": token,
            "repo": cell("repo"),
            "budget": cell("budget"),
            "raw": line,
            "_status_col": columns.get("status"),
            # Original cell text (markup intact) for re-rendering exactly the
            # header's six roles in active-wp.md (#558) — the raw line carries
            # ALL registry columns and overflowed the 6-column header,
            # spilling everything right of "Бюджет" outside the table. The
            # "wp" role falls back to the numeric id when the registry header
            # names its first column something un-aliased.
            "_view_cells": {
                role: (cell(role) or (str(wp) if role == "wp" else ""))
                for role in ("wp", "project", "name", "repo", "budget")
            },
        })
    return rows, problems


def render(rows: list[dict]) -> str:
    active = sorted(
        [r for r in rows if r["status"] in ACTIVE_STATUSES],
        key=lambda r: r["wp"],
        reverse=True,
    )
    closed = sorted(
        [r for r in rows if r["status"] in CLOSED_STATUSES],
        key=lambda r: r["wp"],
        reverse=True,
    )

    def table(items: list[dict]) -> str:
        if not items:
            return "_нет_\n"
        # Rows are built from exactly the six roles the header declares (#558):
        # printing the raw registry line spilled every column right of
        # "Бюджет" (the registry has 10) outside the table as plain text.
        # find_header_columns() already reads the registry schema dynamically —
        # a schema change now affects cell PICKING, not the rendered width.
        out = ["| # | P | Название | Ст | Репо | Бюджет |",
               "|---:|---|------------------|:--:|------------------|------:|"]
        for r in items:
            v = r["_view_cells"]
            out.append(
                f"| {v['wp']} | {v['project']} | {v['name']} "
                f"| {r['status_display']} | {v['repo']} | {v['budget']} |"
            )
        return "\n".join(out) + "\n"

    lines = [
        "<!-- AUTO-GENERATED from docs/WP-REGISTRY.md by scripts/build-active-wp.py. Не редактировать вручную. -->",
        "<!-- index-health: skip -->",
        "",
        "# Активные РП — вид на WP-REGISTRY",
        "",
        f"> Открытые ({len(active)}) сверху, закрытые ({len(closed)}) ниже. Обе секции по убыванию номера.",
        "> Source-of-truth — `docs/WP-REGISTRY.md`. Регенерация: `python3 scripts/build-active-wp.py`.",
        "",
        "<details>",
        "<summary><b>Обозначения статусов (Ст)</b></summary>",
        "",
        "| Статус | Расшифровка |",
        "|:------:|-------------|",
        "| ✅ | done |",
        "| 🔄 | in_progress |",
        "| ⏳ | pending |",
        "| 🧪 | passive testing (ждёт замечаний по триггеру) |",
        "| 🚧 | blocked |",
        "| ⏸ | paused (на паузе, РП открыт) |",
        "| 📦 | archived / → MAPSTRATEGIC |",
        "| ↗️ | merged в другой РП |",
        "| ❌ | cancelled |",
        "",
        "</details>",
        "",
        f"## 🔄 Открытые ({len(active)})",
        "",
        table(active),
        "",
        f"<details><summary><b>📦 Закрытые ({len(closed)})</b></summary>",
        "",
        table(closed),
        "",
        "</details>",
        "",
    ]
    return "\n".join(lines)


def _is_valid_wp_entry(p: Path) -> bool:
    """WP-сущность = папка ИЛИ .md/.yaml файл (не .bak/.tmp/.swp/.orig и т.п.)."""
    if p.is_dir():
        return True
    return p.suffix in {".md", ".yaml"}


def find_wp_files(wp: int) -> dict:
    """Найти все файлы и папки, относящиеся к WP-NNN.

    Возвращает {"inbox": [Path,...], "archive": [Path,...]}.
    Отфильтровывает .bak/.tmp/.swp/.orig — только .md/.yaml/директории.
    """
    inbox: list[Path] = []
    archive: list[Path] = []
    if INBOX_DIR.exists():
        for p in INBOX_DIR.iterdir():
            m = WP_NAME_RE.match(p.name)
            if m and int(m.group(1)) == wp and _is_valid_wp_entry(p):
                inbox.append(p)
    if ARCHIVE_DIR.exists():
        for p in ARCHIVE_DIR.iterdir():
            m = WP_NAME_RE.match(p.name)
            if m and int(m.group(1)) == wp and _is_valid_wp_entry(p):
                archive.append(p)
    return {"inbox": inbox, "archive": archive}


def scan_wp_files() -> dict:
    """Собрать множество WP-номеров, для которых найден файл/папка в inbox/ или archive/."""
    inbox_wps: set[int] = set()
    archive_wps: set[int] = set()
    if INBOX_DIR.exists():
        for p in INBOX_DIR.iterdir():
            m = WP_NAME_RE.match(p.name)
            if m and _is_valid_wp_entry(p):
                inbox_wps.add(int(m.group(1)))
    if ARCHIVE_DIR.exists():
        for p in ARCHIVE_DIR.iterdir():
            m = WP_NAME_RE.match(p.name)
            if m and _is_valid_wp_entry(p):
                archive_wps.add(int(m.group(1)))
    return {"inbox": inbox_wps, "archive": archive_wps}


def deep_check(rows: list[dict]) -> list[str]:
    """Orphan detection: реестр vs файлы — двусторонне.

    Сценарии:
      1. WP-NNN в реестре, но нет ни inbox/, ни archive/ файла → registry-orphan.
      2. Файл inbox/WP-NNN или archive/wp-contexts/WP-NNN существует, но нет строки в реестре → file-orphan.
    """
    issues: list[str] = []
    registry_wps = {r["wp"] for r in rows}
    files = scan_wp_files()
    all_file_wps = files["inbox"] | files["archive"]

    for r in rows:
        wf = find_wp_files(r["wp"])
        if not wf["inbox"] and not wf["archive"]:
            issues.append(
                f"WP-{r['wp']} ({r['status']}): запись в реестре есть, "
                f"но нет ни inbox/WP-{r['wp']}* ни archive/wp-contexts/WP-{r['wp']}*."
            )

    for wp in sorted(all_file_wps - registry_wps):
        wf = find_wp_files(wp)
        locations = []
        for p in wf["inbox"]:
            locations.append(str(p.relative_to(ROOT)))
        for p in wf["archive"]:
            locations.append(str(p.relative_to(ROOT)))
        issues.append(
            f"WP-{wp}: файл(ы) найдены ({', '.join(locations)}), но нет строки в WP-REGISTRY.md."
        )

    return issues


def semantic_check(rows: list[dict]) -> list[str]:
    """Status-placement consistency: active в inbox, closed в archive.

    Сценарии:
      1. WP-NNN в реестре active (🔄 ⏳ 🧪), но файл только в archive/ → status drift.
         (Реестр говорит «работа идёт», но контекст уже архивирован.)
      2. WP-NNN в реестре closed (✅ 📦 ↗️), но файл только в inbox/ → context drift.
         (Реестр говорит «закрыт», но контекст не перенесён в archive.)
    """
    issues: list[str] = []
    for r in rows:
        wf = find_wp_files(r["wp"])
        in_inbox = bool(wf["inbox"])
        in_archive = bool(wf["archive"])
        if not in_inbox and not in_archive:
            continue  # покрывается deep_check
        is_active = r["status"] in ACTIVE_STATUSES
        is_closed = r["status"] in CLOSED_STATUSES
        if is_active and not in_inbox and in_archive:
            issues.append(
                f"WP-{r['wp']} (status {r['status']} ACTIVE): файл только в archive/, "
                f"ожидался в inbox/. Реестр и контекст рассинхронизированы."
            )
        if is_closed and in_inbox and not in_archive:
            issues.append(
                f"WP-{r['wp']} (status {r['status']} CLOSED): файл в inbox/, "
                f"не перенесён в archive/wp-contexts/. Кандидат на перенос."
            )
    return issues


def report_issues(label: str, issues: list[str]) -> None:
    print(f"\n=== {label} ({len(issues)} issue(s)) ===", file=sys.stderr)
    if not issues:
        print("  OK — расхождений не найдено", file=sys.stderr)
        return
    for i in issues:
        print(f"  - {i}", file=sys.stderr)


def main() -> int:
    check_mode = "--check" in sys.argv
    deep_mode = "--deep-check" in sys.argv
    semantic_mode = "--semantic-check" in sys.argv

    if not REGISTRY.exists():
        print(f"build-active-wp: REGISTRY не найден: {REGISTRY}", file=sys.stderr)
        return 2

    try:
        rows, parse_problems = parse_registry(REGISTRY.read_text(encoding="utf-8"))
    except ValueError as exc:
        print(f"build-active-wp: {exc}", file=sys.stderr)
        return 2
    if not rows:
        print("build-active-wp: ни одной РП-строки не распознано — проверь схему таблицы", file=sys.stderr)
        return 2
    if parse_problems and not (deep_mode or semantic_mode):
        report_issues("PARSE-WARN (строки реестра вне классификации)", parse_problems)

    if deep_mode or semantic_mode:
        total = 0
        if parse_problems:
            report_issues("PARSE-WARN (строки реестра вне классификации)", parse_problems)
            total += len(parse_problems)
        if deep_mode:
            issues = deep_check(rows)
            report_issues("DEEP-CHECK (orphans)", issues)
            total += len(issues)
        if semantic_mode:
            issues = semantic_check(rows)
            report_issues("SEMANTIC-CHECK (status vs placement)", issues)
            total += len(issues)
        if total:
            print(
                f"\nbuild-active-wp: integrity-check failed ({total} issue(s)). "
                f"Реестр: {len(rows)} строк.",
                file=sys.stderr,
            )
            return 1
        print(f"\nbuild-active-wp: integrity-check OK ({len(rows)} строк проверено).")
        return 0

    new_content = render(rows)
    current = OUTPUT.read_text(encoding="utf-8") if OUTPUT.exists() else ""

    if check_mode:
        if new_content != current:
            print(f"build-active-wp: {OUTPUT.relative_to(ROOT)} расходится с REGISTRY.", file=sys.stderr)
            print("Пересобрать: python3 scripts/build-active-wp.py", file=sys.stderr)
            return 1
        return 0

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(new_content, encoding="utf-8")
    print(f"build-active-wp: {OUTPUT.relative_to(ROOT)} обновлён ({len(rows)} РП)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
