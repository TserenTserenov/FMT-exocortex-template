"""WP-529: release announcement builder. The model is replaced by a scripted fake client.

Regressions from the 0.41.10 announcement: cut-off text ("3. Встроенный"), a ```html fence,
a distorted Day Open item. None of them may reach the message; the fallback is the short notice.
"""

import importlib.util
import json
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

_PATH = Path(__file__).resolve().parent.parent / "release-notice-build.py"
_spec = importlib.util.spec_from_file_location("release_notice_build", _PATH)
rnb = importlib.util.module_from_spec(_spec)
sys.modules["release_notice_build"] = rnb
_spec.loader.exec_module(rnb)

ENTRIES_TEXT = """### Fixed

- [behavior] Day Open: если общая копия не переносится на вершину, план дня и Telegram-дайджест теперь содержат одно предупреждение «Вход Day Open мог устареть».
- [behavior] Сессия стратегирования: шаги калибра больше не создают пустой трекер.
  Продолжение строки записи.
- [behavior] update.sh --check показывает сводку «Главное в этом обновлении» до установки.
- [behavior] Закрытие дня не велит удалять строки накопительного журнала.
* [optional] Проверка перевода принимает новые метки фаз.
"""
ENTRIES = rnb.parse_entries(ENTRIES_TEXT)

GOOD_ITEMS = [
    {"title": "Предупреждение при открытии дня", "text": "Если рабочие данные не удалось обновить, при открытии дня появляется предупреждение.", "source_index": 1},
    {"title": "Без пустого трекера", "text": "Шаги калибра в сессии стратегирования больше не создают пустой трекер.", "source_index": 2},
    {"title": "Сводка до установки", "text": "Проверка обновления заранее показывает главное в новой версии.", "source_index": 3},
    {"title": "Журнал не теряется", "text": "Закрытие дня больше не предлагает удалять строки журнала.", "source_index": 4},
]
QUOTES = [
    "план дня и Telegram-дайджест теперь содержат одно предупреждение",
    "шаги калибра больше не создают пустой трекер",
    "показывает сводку «Главное в этом обновлении» до установки",
    "Закрытие дня не велит удалять строки накопительного журнала",
]


def editor_ok(quotes=QUOTES, supported=True, problems=()):
    return {
        "ok": supported and not problems,
        "items": [
            {"number": n, "supported": supported, "quote": q, "problems": list(problems)}
            for n, q in enumerate(quotes, 1)
        ],
    }


def response(payload, stop_reason="end_turn"):
    text = payload if isinstance(payload, str) else json.dumps(payload, ensure_ascii=False)
    return SimpleNamespace(stop_reason=stop_reason, content=[SimpleNamespace(type="text", text=text)])


class FakeClient:
    """Returns scripted responses in order and records which model was asked."""

    def __init__(self, *responses):
        self._responses = list(responses)
        self.models = []
        self.messages = SimpleNamespace(create=self._create)

    def _create(self, **kwargs):
        self.models.append(kwargs["model"])
        assert kwargs["output_config"]["format"]["type"] == "json_schema"
        return self._responses.pop(0)


def test_parse_entries_joins_continuations_and_accepts_both_bullets():
    assert len(ENTRIES) == 5
    assert ENTRIES[1].endswith("пустой трекер. Продолжение строки записи.")
    assert ENTRIES[4].startswith("[optional]")


def test_happy_path_builds_escaped_html_from_items():
    items = [dict(GOOD_ITEMS[0], text="Если данные <не> обновились & т.п., будет предупреждение.")] + GOOD_ITEMS[1:]
    client = FakeClient(response({"items": items}), response(editor_ok()))

    record = rnb.build("0.41.10", ENTRIES, client)

    assert record["kind"] == "built"
    assert client.models == [rnb.GENERATOR_MODEL, rnb.EDITOR_MODEL]
    html = record["message_html"]
    assert "1. <b>Предупреждение при открытии дня</b> — Если данные &lt;не&gt; обновились &amp; т.п." in html
    assert "4. <b>Журнал не теряется</b>" in html
    assert "releases/tag/v0.41.10" in html
    assert "```" not in html


def test_truncated_generation_is_not_published():
    """stop_reason=max_tokens twice → no partial text, short notice."""
    client = FakeClient(response('{"items": [{"title": "Встроенный', stop_reason="max_tokens"),
                        response('{"items": [', stop_reason="max_tokens"))

    record = rnb.build("0.41.10", ENTRIES, client)

    assert record["kind"] == "short"
    assert record["message_html"] == rnb.short_notice("0.41.10")
    assert all("stop_reason=max_tokens" in a["error"] for a in record["attempts"])


def test_invalid_json_counts_as_failure():
    client = FakeClient(response("```html\n<b>Обновление</b>\n```"), response("not json"))

    record = rnb.build("0.41.10", ENTRIES, client)

    assert record["kind"] == "short"
    assert all("invalid JSON" in a["error"] for a in record["attempts"])


def test_editor_quote_not_in_source_triggers_one_regeneration_then_passes():
    distorted = [dict(GOOD_ITEMS[0], text="При открытии дня всегда показывается встроенный журнал.")] + GOOD_ITEMS[1:]
    bad_quotes = ["встроенный журнал показывается всегда"] + QUOTES[1:]
    client = FakeClient(
        response({"items": distorted}), response(editor_ok(quotes=bad_quotes)),
        response({"items": GOOD_ITEMS}), response(editor_ok()),
    )

    record = rnb.build("0.41.10", ENTRIES, client)

    assert record["kind"] == "built"
    assert len(record["attempts"]) == 2
    first_remarks = record["attempts"][0]["editor_problems"]
    assert any("цитата редактора не найдена в записи 1" in r for r in first_remarks)
    assert record["attempts"][1]["remarks_in"] == []  # editor's own fault is not a remark for the generator


def test_unsupported_item_is_sent_back_as_remark():
    client = FakeClient(
        response({"items": GOOD_ITEMS}), response(editor_ok(supported=False)),
        response({"items": GOOD_ITEMS}), response(editor_ok()),
    )

    record = rnb.build("0.41.10", ENTRIES, client)

    assert record["kind"] == "built"
    assert any("нет опоры" in r for r in record["attempts"][1]["remarks_in"])


def test_quote_matches_despite_markdown_and_quotes():
    entries = ["[behavior] `update.sh --check` показывает сводку **«Главное»** — см. [доку](docs/x.md)."]
    verdict = {"ok": True, "items": [{"number": 1, "supported": True, "problems": [],
                                       "quote": "update.sh --check показывает сводку Главное — см. доку"}]}
    problems, remarks = rnb.editor_problems(verdict, [dict(GOOD_ITEMS[0], source_index=1)], entries)
    assert problems == [] and remarks == []


def test_apostrophe_is_not_escaped_as_entity():
    html = rnb.render("0.41.10", [dict(GOOD_ITEMS[0], title="Claude's day")] + GOOD_ITEMS[1:])
    assert "Claude's day" in html and "&#x27;" not in html


def test_unsupported_item_twice_gives_short_notice():
    client = FakeClient(
        response({"items": GOOD_ITEMS}), response(editor_ok(supported=False)),
        response({"items": GOOD_ITEMS}), response(editor_ok(problems=["орфография: «Встроеный»"])),
    )

    record = rnb.build("0.41.10", ENTRIES, client)

    assert record["kind"] == "short"
    assert any("орфография" in r for r in record["attempts"][1]["editor_problems"])


def test_program_checks_reject_bad_items_before_editor():
    too_few = GOOD_ITEMS[:2]
    duplicate = GOOD_ITEMS[:3] + [dict(GOOD_ITEMS[3], source_index=1)]
    client = FakeClient(response({"items": too_few}), response({"items": duplicate}))

    record = rnb.build("0.41.10", ENTRIES, client)

    assert record["kind"] == "short"
    assert client.models == [rnb.GENERATOR_MODEL, rnb.GENERATOR_MODEL]  # editor never asked
    assert any("пунктов 2" in p for p in record["attempts"][0]["program"])
    assert any("одну запись" in p for p in record["attempts"][1]["program"])


def test_program_checks_reject_unknown_source_and_long_message():
    items = GOOD_ITEMS[:3] + [dict(GOOD_ITEMS[3], source_index=99, text="x" * 400)]
    problems = rnb.program_problems(items, ENTRIES, "y" * (rnb.MAX_MESSAGE_CHARS + 1))
    assert any("нет записи с номером 99" in p for p in problems)
    assert any("длиннее 300" in p for p in problems)
    assert any("сообщение длиннее" in p for p in problems)


def test_no_client_gives_short_notice():
    record = rnb.build("0.41.10", ENTRIES, None)
    assert record["kind"] == "short"
    assert record["reason"] == "no ANTHROPIC_API_KEY"


def test_main_writes_artifacts_without_key(tmp_path, monkeypatch):
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    entries = tmp_path / "entries.txt"
    entries.write_text(ENTRIES_TEXT, encoding="utf-8")
    monkeypatch.setattr(sys, "argv", ["x", "--version", "0.41.10", "--entries", str(entries),
                                      "--out-dir", str(tmp_path / "out"), "--sha", "abc123"])

    assert rnb.main() == 0
    record = json.loads((tmp_path / "out" / "notice.json").read_text(encoding="utf-8"))
    assert record["sha"] == "abc123" and record["source_entries"] == 5 and record["kind"] == "short"
    assert (tmp_path / "out" / "notice.html").read_text(encoding="utf-8") == rnb.short_notice("0.41.10")


@pytest.mark.parametrize("version", ["[0.41.10] — 2026-10-27", "0.41", "0.41.10; rm -rf /"])
def test_main_rejects_bad_version(tmp_path, monkeypatch, version):
    entries = tmp_path / "entries.txt"
    entries.write_text(ENTRIES_TEXT, encoding="utf-8")
    monkeypatch.setattr(sys, "argv", ["x", "--version", version, "--entries", str(entries), "--out-dir", str(tmp_path)])
    assert rnb.main() == 2
