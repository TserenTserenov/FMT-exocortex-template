#!/bin/bash
# Exercise real prompt routing and diagnostics on the final table in both deliveries.
# All LLM and machine-data boundaries are mocked; no network or personal sidecars.
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

TABLE = "| РП | Часы |\n|---|---|\n| WP-901 | 1 |\n"
PENDING = "| <!-- PENDING: рабочий продукт --> | 1 |\n"


class FillTests(unittest.TestCase):
    def run_main(self, scaffold, response=TABLE, final_patch=None):
        with tempfile.TemporaryDirectory() as tmp, contextlib.ExitStack() as stack:
            root = Path(tmp)
            (root / "scaffold.md").write_text(scaffold)
            (root / "week.md").write_text("")
            (root / "registry.md").write_text("")
            (root / "inbox").mkdir()
            argv = ["fill", "--scaffold", str(root / "scaffold.md"),
                    "--weekplan", str(root / "week.md"),
                    "--wp-registry", str(root / "registry.md"),
                    "--wp-dir", str(root / "inbox"), "--out", str(root / "out.md"),
                    "--proxy-url", "http://unused.invalid", "--proxy-secret", ""]
            stack.enter_context(patch.object(sys, "argv", argv))
            stack.enter_context(patch.object(mod, "load_fault_profile", return_value=""))
            for name in ["rebuild_compact_dashboard", "inject_panel_tile", "inject_gate_metrics"]:
                transform = final_patch if name == "inject_gate_metrics" and final_patch else lambda text: text
                stack.enter_context(patch.object(mod, name, side_effect=transform))
            kwargs = {"side_effect": response} if isinstance(response, Exception) else {"return_value": response}
            proxy = stack.enter_context(patch.object(mod, "call_proxy", **kwargs))
            stack.enter_context(patch.object(mod.urllib.request, "urlopen", side_effect=AssertionError("network forbidden")))
            log = stack.enter_context(contextlib.redirect_stderr(io.StringIO()))
            stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
            status = 0
            try:
                mod.main()
            except SystemExit as exc:
                status = exc.code
            return (root / "out.md").read_text(), log.getvalue(), status, proxy.call_count

    def test_real_prompt_routing(self):
        cases = [
            ("<details open>", "<summary>План на сегодня</summary>\n", True),
            ("## План на сегодня", "", True),
            ("<details>", "today_plan marker\n", True),
            ("## today_plan", "", True),
            ("## Вчера", "", False),
        ]
        for header, content, expected in cases:
            with self.subTest(header=header, content=content), patch.object(mod, "call_proxy", return_value=TABLE) as proxy:
                chunk = {"header": header, "lines": [header + "\n", content, PENDING]}
                result = mod.fill_chunk(chunk, "", "", "", "", "unused", None,
                                        [{"wp": "WP-901", "title": "Тест", "budget_h": 1}])
                self.assertEqual(result, TABLE)
                self.assertEqual(proxy.call_args.kwargs.get("temperature"), 0.0 if expected else None)

    def test_final_placeholder_formats(self):
        for placeholder in ["<!-- PENDING -->", "<!-- PENDING: название -->", "NNN", "X"]:
            with self.subTest(placeholder=placeholder):
                row = f"| {placeholder} | 1 |"
                out, log, status, calls = self.run_main("## План на сегодня\n" + TABLE + PENDING, TABLE + row)
                self.assertEqual(status, 0)
                self.assertEqual(calls, 1)
                self.assertIn(row, out)
                self.assertIn("Block DOF", log)
                self.assertIn(row, log)


    def test_last_postprocessor_is_checked(self):
        row = "| WP-902 | <!-- PENDING: поздняя вставка --> |"
        out, log, status, _ = self.run_main("## План на сегодня\n" + TABLE + PENDING,
                                          final_patch=lambda text: text + row)
        self.assertEqual(status, 0)
        self.assertIn(row, out)
        self.assertIn(row, log)

    def test_failed_fill_reports_preserved_scaffold(self):
        out, log, status, _ = self.run_main("## План на сегодня\n" + TABLE + PENDING, RuntimeError("proxy unavailable"))
        self.assertEqual(status, 2)
        self.assertIn(PENDING, out)
        self.assertIn(PENDING.strip(), log)

    def test_other_section_table_is_not_today_plan(self):
        _, log, status, _ = self.run_main("## Вчера\n" + TABLE + PENDING, TABLE + PENDING)
        self.assertEqual(status, 0)
        self.assertNotIn("Block DOF", log)

    def test_no_pending_fast_path_reports_plain_placeholder(self):
        scaffold = "## План на сегодня\n" + TABLE + "| NNN | 1 |\n"
        out, log, status, calls = self.run_main(scaffold)
        self.assertEqual(status, 0)
        self.assertEqual(calls, 0)
        self.assertEqual(out, scaffold)
        self.assertIn("Block DOF", log)


unittest.main(verbosity=2)
PY
done
