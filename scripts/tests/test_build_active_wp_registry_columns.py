"""Регрессия: build-active-wp читает старый реестр по именам колонок."""

import importlib.util
from pathlib import Path


BUILD_ACTIVE_WP = Path(__file__).parent.parent / "build-active-wp.py"
SPEC = importlib.util.spec_from_file_location("build_active_wp", BUILD_ACTIVE_WP)
assert SPEC and SPEC.loader
BUILD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BUILD)


def test_reordered_legacy_registry_is_rendered_in_canonical_order():
    registry = """| # | Название | Статус | P | Репо | Бюджет |
|---|---|---|---|---|---|
| 34 | **Обновление FMT-exocortex-template** | ⏳ | P3 | FMT-exocortex-template | 1h |
"""

    rows, problems = BUILD.parse_registry(registry)

    assert problems == []
    assert rows[0]["project"] == "P3"
    assert rows[0]["name"] == "**Обновление FMT-exocortex-template**"
    assert rows[0]["status"] == "⏳"
    assert rows[0]["repo"] == "FMT-exocortex-template"
    assert "| 34 | P3 | **Обновление FMT-exocortex-template** | ⏳ | FMT-exocortex-template | 1h |" in BUILD.render(rows)


def test_minimal_legacy_registry_keeps_active_row():
    registry = """| # | Название | Статус |
|---|---|---|
| 7 | Старый РП | 🔄 |
"""

    rows, problems = BUILD.parse_registry(registry)

    assert problems == []
    assert rows[0]["project"] == "—"
    assert rows[0]["status"] == "🔄"
    assert "## 🔄 Открытые (1)" in BUILD.render(rows)


def test_wp_prefixed_legacy_identifier_is_not_dropped():
    registry = """| # | Название | Статус |
|---|---|---|
| ~~WP-33~~ | ~~Закрытый РП~~ | ✅ |
"""

    rows, problems = BUILD.parse_registry(registry)

    assert problems == []
    assert rows[0]["wp"] == 33
    assert rows[0]["status"] == "✅"
    assert "## 🔄 Открытые (0)" in BUILD.render(rows)
    assert "📦 Закрытые (1)" in BUILD.render(rows)


def test_legacy_revision_identifiers_are_not_dropped():
    registry = """| # | Название | Статус |
|---|---|---|
| WP-9-r3 | Актуальная ревизия | 🔄 |
| ~~WP-9-r2~~ | ~~Закрытая ревизия~~ | ✅ |
| ~~WP-1.2~~ | ~~Отменённая ревизия~~ | ❌ |
"""

    rows, problems = BUILD.parse_registry(registry)
    rendered = BUILD.render(rows)

    assert problems == []
    assert [row["wp"] for row in rows] == [9, 9, 1]
    assert "| WP-9-r3 |" in rendered
    assert "| ~~WP-9-r2~~ |" in rendered
    assert "| ~~WP-1.2~~ |" in rendered
    assert "## 🔄 Открытые (1)" in rendered
    assert "📦 Закрытые (2)" in rendered
