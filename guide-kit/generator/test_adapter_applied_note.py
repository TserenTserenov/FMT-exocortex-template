"""Tests for adapter.py's applied_note wiring (WP-483 Ф5b).

The LLM was previously never asked for applied_note and generate_daily_plan
never read it from the response — these cover the new field end to end:
render_markdown's placement and generate_daily_plan's extraction from the
LLM's JSON output.
"""

from unittest.mock import patch

from adapter import generate_daily_plan, render_markdown
from llm_backends import GenerationResult


class TestRenderMarkdownAppliedNote:
    def test_no_applied_note_is_unchanged(self):
        md = render_markdown("narrative text", [], [])
        assert "## Прикладная практика" not in md

    def test_empty_applied_note_adds_nothing(self):
        md = render_markdown("narrative text", [], [], applied_note="")
        assert "Прикладная практика" not in md

    def test_applied_note_appears_after_assignments_before_work_section(self):
        md = render_markdown(
            "narrative text",
            [{"label": "задание", "tomatoes": 1, "rationale": "почему"}],
            [],
            work_section_markdown="## Рабочая часть\n\n- **item**",
            applied_note="Та же дистинкция, только в бассейне.",
        )
        tasks_pos = md.index("## Задания")
        applied_pos = md.index("## Прикладная практика")
        work_pos = md.index("## Рабочая часть")
        assert tasks_pos < applied_pos < work_pos
        assert "Та же дистинкция, только в бассейне." in md


class TestGenerateDailyPlanAppliedNoteIntegration:
    def _fake_llm_with_applied_note(self, *_args, **_kwargs):
        return GenerationResult(
            text=(
                '{"narrative": "текст", '
                '"plan_day": [{"label": "задание", "tomatoes": 1}], '
                '"applied_note": "Сегодня в плавании — комфорт в воде."}'
            ),
            backend_id="fake",
            model="fake",
        )

    def _fake_llm_without_applied_note(self, *_args, **_kwargs):
        return GenerationResult(
            text='{"narrative": "текст", "plan_day": [{"label": "задание", "tomatoes": 1}]}',
            backend_id="fake",
            model="fake",
        )

    def _fake_llm_non_string_applied_note(self, *_args, **_kwargs):
        return GenerationResult(
            text=(
                '{"narrative": "текст", '
                '"plan_day": [{"label": "задание", "tomatoes": 1}], '
                '"applied_note": {"unexpected": "object"}}'
            ),
            backend_id="fake",
            model="fake",
        )

    def test_applied_note_from_llm_reaches_markdown(self, tmp_path):
        profile_path = tmp_path / "profile.yaml"
        profile_path.write_text("{}", encoding="utf-8")
        with patch("adapter.llm_generate", side_effect=self._fake_llm_with_applied_note):
            result = generate_daily_plan(str(profile_path))
        assert result.ok
        assert "## Прикладная практика" in result.markdown
        assert "Сегодня в плавании — комфорт в воде." in result.markdown

    def test_absent_applied_note_from_llm_omits_section(self, tmp_path):
        profile_path = tmp_path / "profile.yaml"
        profile_path.write_text("{}", encoding="utf-8")
        with patch("adapter.llm_generate", side_effect=self._fake_llm_without_applied_note):
            result = generate_daily_plan(str(profile_path))
        assert result.ok
        assert "Прикладная практика" not in result.markdown

    def test_non_string_applied_note_from_llm_is_ignored_not_crashed(self, tmp_path):
        """The LLM is an untrusted source — a malformed (non-string) applied_note
        must degrade honestly (section omitted), not raise inside render_markdown's
        "\\n".join(lines) (found during independent review)."""
        profile_path = tmp_path / "profile.yaml"
        profile_path.write_text("{}", encoding="utf-8")
        with patch("adapter.llm_generate", side_effect=self._fake_llm_non_string_applied_note):
            result = generate_daily_plan(str(profile_path))
        assert result.ok
        assert "Прикладная практика" not in result.markdown
