#!/usr/bin/env python3
"""build-active-wp.py — пересборка current/active-wp.md из docs/WP-REGISTRY.md.

Source-of-truth: WP-REGISTRY.md (markdown-таблица).
Вывод: current/active-wp.md — открытые РП (🔄 ⏳ 🧪) сверху, закрытые (✅ 📦 ↗️) ниже,
обе секции по убыванию номера РП.

Usage:
  python3 build-active-wp.py [--check | --deep-check | --semantic-check]

  без флагов        — перезаписывает active-wp.md
  --check           — exit 1 если active-wp.md расходится с реестром (pre-commit guard)
  --deep-check      — exit 1 если есть orphan WP-NNN (в реестре нет inbox/archive файла,
                       или файл есть, а в реестре нет). Day Open / periodic reconciliation.
  --semantic-check  — exit 1 если статус в реестре расходится с placement (active WP
                       только в archive/, или closed WP только в inbox/). Week Close.

  see peer-session 2026-06-01-21-wp-registry-drift-guard
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REGISTRY = ROOT / "docs" / "WP-REGISTRY.md"
OUTPUT = ROOT / "current" / "active-wp.md"
INBOX_DIR = ROOT / "inbox"
ARCHIVE_DIR = ROOT / "archive" / "wp-contexts"

ACTIVE_STATUSES = {"🔄", "⏳", "🧪", "🚧"}
CLOSED_STATUSES = {"✅", "📦", "↗️", "❌"}
ALL_STATUSES = ACTIVE_STATUSES | CLOSED_STATUSES

# Строка-РП: `| 312 | P2 | **Название** | 🔄 | repo | 8h |`
# Done-вариант: `| ~~306~~ | ~~P3~~ | ~~Название~~ | ✅ | ~~repo~~ | ~~4h~~ |`
ROW_RE = re.compile(r"^\|\s*(?:~~)?(?:\*\*)?(\d{1,4})(?:\*\*)?(?:~~)?\s*\|")

# Имя файла WP в inbox/archive: WP-NNN-... .md или WP-NNN.md или папка WP-NNN/
WP_NAME_RE = re.compile(r"^WP-(\d{1,4})(?:[-.].*|/)?$")


def parse_registry(text: str) -> list[dict]:
    rows = []
    for line in text.splitlines():
        m = ROW_RE.match(line)
        if not m:
            continue
        wp = int(m.group(1))
        cols = [c.strip() for c in line.strip("|").split("|")]
        if len(cols) < 6:
            continue
        status = cols[3]
        # Очистка от ~~ и пробелов; берём только первый токен, чтобы
        # принять варианты вида "🔄 Ф4" (статус + пометка фазы).
        status_raw = status.replace("~~", "").strip()
        status_clean = status_raw.split()[0] if status_raw else ""
        if status_clean not in ALL_STATUSES:
            continue
        rows.append({
            "wp": wp,
            "project": cols[1].replace("~~", "").strip(),
            "name": cols[2].strip(),
            "status": status_clean,
            "repo": cols[4].strip(),
            "budget": cols[5].strip(),
            "raw": line,
        })
    return rows


def clean_status_in_row(raw: str, status: str) -> str:
    """Заменяет содержимое колонки «Ст» на очищенный статус и обрезает лишние колонки."""
    parts = raw.split("|")
    if len(parts) >= 6:
        parts[4] = f" {status} "
        parts = parts[:7]
    return "|".join(parts) + "|"


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
        out = ["| # | P | Название | Ст | Репо | Бюджет |",
               "|---:|---|------------------|:--:|------------------|------:|"]
        for r in items:
            out.append(clean_status_in_row(r["raw"], r["status"]))
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

    rows = parse_registry(REGISTRY.read_text(encoding="utf-8"))
    if not rows:
        print("build-active-wp: ни одной РП-строки не распознано — проверь схему таблицы", file=sys.stderr)
        return 2

    if deep_mode or semantic_mode:
        total = 0
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
