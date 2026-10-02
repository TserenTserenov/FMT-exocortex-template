#!/bin/bash
# The real main path may replace only the world lens; news/markup stay byte-identical.
# Network and personal machine-data sidecars are mocked, fixtures are temporary.
set -euo pipefail
REPO="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
for MODULE in "$REPO/scripts/day-open-llm-fill.py" "$REPO/seed/strategy/scripts/day-open-llm-fill.py"; do
  echo "Testing ${MODULE#"$REPO/"}"
  python3 -B - "$MODULE" <<'PY'
import contextlib
import importlib.util
import io
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("day_open_llm_fill", sys.argv.pop())
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

PENDING = "**Вывод:** <!-- PENDING: news-lens — 2-4 предложения -->"
ANSWER = "Новость про модель релевантна WP-901."
WORLD = """<details>
<summary><b>Мир</b></summary>

**AI/LLM:** [Статья про модель](https://example.com/a) · [Вторая](https://example.com/b)
**Инженерия:** [Релиз инструмента](https://example.com/c)

{lens}

</details>
"""


class WorldTests(unittest.TestCase):
    def run_fill(self, scaffold, response):
        with tempfile.TemporaryDirectory() as tmp, contextlib.ExitStack() as stack:
            root = Path(tmp)
            (root / "scaffold.md").write_text(scaffold)
            (root / "week.md").write_text("WP-901")
            (root / "registry.md").write_text("| 901 | Тестовый РП | in_progress |\n")
            (root / "inbox").mkdir()
            stack.enter_context(patch.object(sys, "argv", ["fill",
                "--scaffold", str(root / "scaffold.md"), "--weekplan", str(root / "week.md"),
                "--wp-registry", str(root / "registry.md"), "--wp-dir", str(root / "inbox"),
                "--out", str(root / "out.md"), "--proxy-url", "http://unused.invalid", "--proxy-secret", ""]))
            stack.enter_context(patch.object(mod, "load_fault_profile", return_value=""))
            for name in ["rebuild_compact_dashboard", "inject_panel_tile", "inject_gate_metrics"]:
                stack.enter_context(patch.object(mod, name, side_effect=lambda text: text))
            kwargs = {"side_effect": response} if isinstance(response, Exception) else {"return_value": response}
            proxy = stack.enter_context(patch.object(mod, "call_proxy", **kwargs))
            stack.enter_context(patch.object(mod.urllib.request, "urlopen", side_effect=AssertionError("network forbidden")))
            stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
            stack.enter_context(contextlib.redirect_stderr(io.StringIO()))
            status = 0
            try:
                mod.main()
            except SystemExit as exc:
                status = exc.code
            return (root / "out.md").read_text(), status, proxy.call_count

    def test_success_changes_only_lens(self):
        scaffold = WORLD.format(lens=PENDING)
        result, status, calls = self.run_fill(scaffold, ANSWER)
        self.assertEqual(status, 0)
        self.assertEqual(calls, 1)
        self.assertEqual(result, scaffold.replace(PENDING, "**Вывод:** " + ANSWER))

    def test_proxy_failure_preserves_every_byte(self):
        scaffold = WORLD.format(lens=PENDING)
        result, status, calls = self.run_fill(scaffold, RuntimeError("proxy unavailable"))
        self.assertEqual(status, 2)
        self.assertEqual(calls, 1)
        self.assertEqual(result, scaffold)

    def test_no_news_does_not_call_model(self):
        scaffold = WORLD.format(lens="**Вывод:** нет данных — источники не вернули материалов.\n\n<!-- PENDING: world — RSS недоступны -->")
        result, status, calls = self.run_fill(scaffold, AssertionError("model must not run"))
        self.assertEqual(status, 0)
        self.assertEqual(calls, 0)
        self.assertEqual(result, scaffold)

    def test_empty_answer_preserves_pending(self):
        scaffold = WORLD.format(lens=PENDING)
        result, status, calls = self.run_fill(scaffold, "   ")
        self.assertEqual(status, 2)
        self.assertEqual(calls, 1)
        self.assertEqual(result, scaffold)

    def test_multiline_or_html_answer_preserves_pending(self):
        scaffold = WORLD.format(lens=PENDING)
        for response in [ANSWER + "\nДругая строка.", ANSWER + "</details>", "**Вывод:** "]:
            with self.subTest(response=response):
                result, status, calls = self.run_fill(scaffold, response)
                self.assertEqual(status, 2)
                self.assertEqual(calls, 1)
                self.assertEqual(result, scaffold)

    def test_world_stays_whole_across_layout_and_nested_content(self):
        base = WORLD.format(lens=PENDING)
        variants = [
            base.replace("<details>\n", "<details>\n\n", 1),
            base.replace("**AI/LLM:**", "## Новости\n**AI/LLM:**"),
            base.replace("**AI/LLM:**", "<details>\n<summary>Источники</summary>\n**AI/LLM:**")
                .replace(PENDING, "</details>\n" + PENDING),
            base.replace("<details>\n<summary>", "<details><summary>"),
        ]
        for scaffold in variants:
            with self.subTest(scaffold=scaffold):
                result, status, calls = self.run_fill(scaffold, ANSWER)
                self.assertEqual(status, 0)
                self.assertEqual(calls, 1)
                self.assertEqual(result, scaffold.replace(PENDING, "**Вывод:** " + ANSWER))
                result, status, calls = self.run_fill(scaffold, "<summary>Неверный ответ</summary>")
                self.assertEqual(status, 2)
                self.assertEqual(calls, 1)
                self.assertEqual(result, scaffold)

    def test_world_preserves_fenced_examples_and_neighbour_sections(self):
        literal = "```md\n## Заголовок примера\n<details>\n" + PENDING + "\n</details>\n```\n"
        world = WORLD.format(lens=PENDING).replace("**AI/LLM:**", literal + "**AI/LLM:**")
        before = "## До\n\n\nТекст до.\n"
        after = "## После\n\n\nТекст после.\n"
        scaffold = before + world + after
        result, status, calls = self.run_fill(scaffold, ANSWER)
        self.assertEqual(status, 0)
        self.assertEqual(calls, 1)
        self.assertEqual(result, before + world.replace("\n" + PENDING + "\n\n</details>",
                                                       "\n**Вывод:** " + ANSWER + "\n\n</details>") + after)
        self.assertIn(literal, result)

    def test_ambiguous_world_lens_preserves_original(self):
        scaffold = WORLD.format(lens=PENDING + "\n" + PENDING)
        result, status, calls = self.run_fill(scaffold, ANSWER)
        self.assertEqual(status, 2)
        self.assertEqual(calls, 0)
        self.assertEqual(result, scaffold)

    def test_world_keeps_inline_and_html_code_examples(self):
        sample = "<details>\n<summary><b>Мир</b></summary>\n" + PENDING + "\n</details>\n"
        real = WORLD.format(lens=PENDING)
        for before, after in [("`", "`"), ("``", "``"), ("<pre><code>", "</code></pre>"), ("<code>", "</code>")]:
            example = before + sample + after + "\n"
            scaffold = example + real.replace("**AI/LLM:**", example + "**AI/LLM:**")
            with self.subTest(wrapper=before):
                result, status, calls = self.run_fill(example, AssertionError("code sample must not call model"))
                self.assertEqual(status, 0)
                self.assertEqual(calls, 0)
                self.assertEqual(result, example)
                result, status, calls = self.run_fill(scaffold, ANSWER)
                self.assertEqual(status, 0)
                self.assertEqual(calls, 1)
                self.assertEqual(result, scaffold.replace("\n" + PENDING + "\n\n</details>",
                                                          "\n**Вывод:** " + ANSWER + "\n\n</details>"))
                self.assertEqual(result.count(example), 2)


unittest.main(verbosity=2)
PY
done
