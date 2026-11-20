"""WP-529 F275: urgent security notice builder.

Regression: on the 0.42.1 release merge eleven developer entries (about 17 000 characters) went
to the bot verbatim and Telegram's 4096 limit cut the message mid-sentence ("закрывает находки F5 и…").
"""

import importlib.util
import subprocess
import sys
from pathlib import Path

import pytest

_PATH = Path(__file__).resolve().parent.parent / "security-notice-build.py"
_spec = importlib.util.spec_from_file_location("security_notice_build", _PATH)
snb = importlib.util.module_from_spec(_spec)
sys.modules["security_notice_build"] = snb
_spec.loader.exec_module(snb)

LONG_TAIL = " Подробное описание для разработчиков с путями `a/b.sh` и примерами команд." * 40
LINES_0421 = [
    "- [security] (#1617) Проверка опасных команд агента (`.claude/hooks/destructive-guard.sh`) читает ограничитель here-doc целиком." + LONG_TAIL,
    "- [security] (#1609) Нижняя граница проверки опасных команд (`.claude/hooks/destructive-guard.sh`) больше не отключается молча." + LONG_TAIL,
    "- [security] (#1602) Проверка опасных команд агента (`.claude/hooks/destructive-guard.sh`) закрывает находки F5 и F6." + LONG_TAIL,
    "- [security] (#1590) Проверка перед применением во время репетиции (`.claude/hooks/dry-run-gate.sh`) блокирует формы записи." + LONG_TAIL,
    # The 0.42.1 CHANGELOG carried #1585 twice; the notice counts it once.
    "- [security] (#1585) Проверка опасных команд агента (`.claude/hooks/destructive-guard.sh`) закрывает три находки." + LONG_TAIL,
    "- [security] (#1585) Проверка опасных команд агента (`.claude/hooks/destructive-guard.sh`) закрывает три находки." + LONG_TAIL,
]


def build(lines):
    return snb.render(snb.parse(lines))


def test_release_merge_fits_one_message_and_groups_topics():
    assert sum(map(len, LINES_0421)) > 4096 * 4  # the input that used to be cut
    text = build(LINES_0421)
    assert len(text) <= snb.MAX_MESSAGE_CHARS
    assert "🔒 Исправления защиты IWE: 5" in text
    assert "• Проверка опасных команд агента — 3 (#1617, #1602, #1585)" in text
    assert "• Нижняя граница проверки опасных команд — 1 (#1609)" in text
    assert "• Проверка перед применением во время репетиции — 1 (#1590)" in text


def test_notice_keeps_developer_details_out():
    text = build(LINES_0421)
    for detail in ("destructive-guard.sh", "here-doc", "F5", "`"):
        assert detail not in text


def test_notice_says_when_fixes_reach_the_reader():
    text = build(LINES_0421)
    assert "с ближайшим выпуском шаблона" in text
    assert "«обнови мой экзокортекс»" in text
    assert snb.CHANGELOG_URL in text


def test_entry_without_code_path_uses_first_sentence_and_no_pr():
    text = build(["- [security] Ключи в журнале скрываются. Подробности ниже."])
    assert "• Ключи в журнале скрываются — 1\n" in text


def test_long_topic_is_cut_at_word_boundary():
    words = "слово " * 40
    topic = snb.topic_of(words + "(`x`) хвост")
    assert len(topic) <= snb.MAX_TOPIC_CHARS
    assert topic.endswith("слово…")


def test_many_topics_are_summarised_not_listed():
    lines = [f"- [security] (#{n}) Тема номер {n} (`p`) текст" for n in range(1, 21)]
    text = build(lines)
    assert text.count("• Тема номер") == snb.MAX_TOPICS
    assert "• и ещё тем: 12, исправлений: 12" in text
    assert "🔒 Исправления защиты IWE: 20" in text


def test_non_security_lines_are_ignored():
    groups = snb.parse(["- [behavior] (#1) Не защита", "", "просто текст"])
    assert groups == []


def test_cli_fails_loudly_without_entries():
    result = subprocess.run([sys.executable, str(_PATH)], check=False, input="- [behavior] (#1) x\n",
                            capture_output=True, text=True)
    assert result.returncode == 1
    assert result.stdout == ""
    assert "no [security] entries" in result.stderr


def test_cli_prints_notice():
    result = subprocess.run([sys.executable, str(_PATH)], check=False, input="\n".join(LINES_0421) + "\n",
                            capture_output=True, text=True)
    assert result.returncode == 0
    assert result.stdout.startswith("🔒 Исправления защиты IWE: 5\n")


def test_oversized_render_raises_instead_of_cutting(monkeypatch):
    monkeypatch.setattr(snb, "MAX_MESSAGE_CHARS", 100)
    with pytest.raises(ValueError, match="limit 100"):
        build(LINES_0421)
