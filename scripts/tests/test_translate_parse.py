"""Тесты _parse_translation_response: снятие XML-меток ответа модели.

Регрессия 2026-07-06: файлы без переводимых полей в frontmatter (fm_values
пуст) получали в вывод необрезанный ответ модели целиком, включая
буквальный тег <body> — 13 из 38 переведённых файлов вышли с "<body>"
первой строкой.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))
import translate  # noqa: E402


def test_strips_body_markers_without_frontmatter_values():
    response = "<body>\nTranslated content.\n</body>"
    fm_translated, body = translate._parse_translation_response(
        response, fm_values={}, translate_keys=["title"]
    )
    assert fm_translated == {}
    assert body == "Translated content.\n"
    assert "<body>" not in body


def test_strips_body_markers_with_frontmatter_values():
    response = (
        "<frontmatter_values>\ntitle: Translated Title\n</frontmatter_values>\n\n"
        "<body>\nTranslated content.\n</body>"
    )
    fm_translated, body = translate._parse_translation_response(
        response, fm_values={"title": "Заголовок"}, translate_keys=["title"]
    )
    assert fm_translated == {"title": "Translated Title"}
    assert body == "Translated content.\n"
    assert "<body>" not in body
