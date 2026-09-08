"""
Регрессионный тест WeekPlan-writer в create-wp.sh (issue #324).

Фикс afdce30 (2026-07-27) переписал writer на поиск таблицы по реальному
заголовку («РП»+«Статус» в предыдущей строке) вместо текстового anchor'а —
это остановило порчу документа, но осталось хрупким: полагается на то,
что заголовок содержит ОБА этих слова. Два кейса:

1. Стандартная схема (заголовок содержит «РП» и «Статус») — строка
   вставляется корректно, значения распределены по именованным колонкам.
2. Нераспознанная схема (заголовок без слова «Статус», например
   4-колоночная `# | РП | Бюджет | Артефакт-критерий`) — writer НЕ портит
   файл: печатает предупреждение в stderr, содержимое файла не меняется.

Тест выполняет python-блок ИЗ РЕАЛЬНОГО create-wp.sh (извлекается по
семантическому маркеру секции WeekPlan и следующему PYEOF),
не копию логики — иначе тест проверял бы дубликат, не продакшен-код.
"""

import re
import subprocess
import sys
from pathlib import Path

CREATE_WP = Path(__file__).parent.parent / "create-wp.sh"


def _extract_weekplan_writer() -> str:
    """Достаёт WeekPlan-writer без привязки к порядковому номеру шага."""
    text = CREATE_WP.read_text(encoding="utf-8")
    marker = re.search(r"^# --- Шаг \d+: WeekPlan ---$", text, flags=re.MULTILINE)
    assert marker, "В create-wp.sh отсутствует секция WeekPlan"
    start = marker.end()
    heredoc_start = text.index("<<'PYEOF'\n", start) + len("<<'PYEOF'\n")
    heredoc_end = text.index("\nPYEOF", heredoc_start)
    return text[heredoc_start:heredoc_end]


WEEKPLAN_WRITER_SRC = _extract_weekplan_writer()


def _run_writer(weekplan_path: Path, wp_num: str, title: str, priority: str, budget: str):
    return subprocess.run(
        [sys.executable, "-", str(weekplan_path), wp_num, title, priority, budget],
        input=WEEKPLAN_WRITER_SRC,
        capture_output=True,
        text=True,
    )


def test_standard_schema_inserts_row(tmp_path):
    weekplan = tmp_path / "WeekPlan W31.md"
    weekplan.write_text(
        "# WeekPlan W31\n\n"
        "**Бюджет:** 40h\n\n"
        "🚦 | # | РП | h | Источник | P | Статус | Результат\n"
        "|---|---|---|---|----------|---|---|--------|-----------|\n"
        "🟢 | 10 | **Существующий РП** | 5h | R1 | P3 | done | готово\n",
        encoding="utf-8",
    )

    result = _run_writer(weekplan, "16", "Новый РП", "P2", "3h")

    assert result.returncode == 0, result.stderr
    assert "добавлена" in result.stdout
    content = weekplan.read_text(encoding="utf-8")
    # h_val = re.sub(r"[^0-9\-]", "", budget) — единица измерения обрезается,
    # колонка "h" содержит только число (единица уже в заголовке колонки).
    assert "🟡 | 16 | **Новый РП** — [описание] | 3 | — | P2 | pending | [заполнить] |" in content
    # исходная строка не тронута
    assert "🟢 | 10 | **Существующий РП** | 5h | R1 | P3 | done | готово" in content


def test_unrecognized_schema_does_not_corrupt_file(tmp_path):
    weekplan = tmp_path / "WeekPlan W31.md"
    original = (
        "# WeekPlan W31\n\n"
        "**Бюджет:** 40h\n\n"
        "| # | РП | Бюджет | Артефакт-критерий |\n"
        "|---|-----|--------|--------------------|\n"
        "| 1 | WP-10 | 5h | done |\n"
    )
    weekplan.write_text(original, encoding="utf-8")

    result = _run_writer(weekplan, "16", "Новый РП", "P4", "1h")

    assert result.returncode == 0
    assert "не найдена" in result.stderr
    assert "добавлена" not in result.stdout
    # файл не изменился ни на байт
    assert weekplan.read_text(encoding="utf-8") == original


def test_column_order_independent(tmp_path):
    """Порядок/число колонок в заголовке не имеет значения — writer мапит по имени."""
    weekplan = tmp_path / "WeekPlan W31.md"
    weekplan.write_text(
        "# WeekPlan W31\n\n"
        "**Бюджет:** 40h\n\n"
        "# | Статус | РП | h\n"
        "|---|---|---|---|\n",
        encoding="utf-8",
    )

    result = _run_writer(weekplan, "5", "РП с другим порядком колонок", "P1", "2h")

    assert result.returncode == 0, result.stderr
    content = weekplan.read_text(encoding="utf-8")
    # порядок должен соответствовать заголовку (# | Статус | РП | h), не фиксированному 7-полю
    inserted_line = [ln for ln in content.splitlines() if "5" in ln and "РП с другим" in ln][0]
    cells = [c.strip() for c in inserted_line.strip().strip("|").split("|")]
    assert cells == ["5", "pending", "**РП с другим порядком колонок** — [описание]", "2"]
