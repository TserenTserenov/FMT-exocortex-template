#!/usr/bin/env python3
"""Stale-input banner in the DayPlan and the digest (issue #1245).

Real temporary repositories and files; the marker is written by the production
day_open_sync_blocked helper, the banner by the production patch script.
"""
import importlib.util
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PIPELINE = ROOT / "scripts/day-open-pipeline.sh"
PATCH = ROOT / "scripts/day-open-sync-banner-patch.py"
BASH = os.environ.get("TEST_BASH", "bash")
START = "<!-- sync-banner:start -->"
PLAN = ("---\ndate: 2026-10-24\n---\n\n# DayPlan 2026-10-24\n\n"
        "<details open><summary><b>План на сегодня</b></summary>\n\n| a | b |\n\n</details>\n")


class SyncBannerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="sync banner ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.repo = self.root / "my repo"
        self.repo.mkdir()
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.email", "t@example.com")
        self.git("config", "user.name", "t")
        (self.repo / "a.txt").write_text("1\n", encoding="utf-8")
        self.git("add", "a.txt")
        self.git("commit", "-qm", "one")
        self.base = self.git("rev-parse", "HEAD")
        (self.repo / "a.txt").write_text("2\n", encoding="utf-8")
        self.git("commit", "-qam", "two")
        self.tip = self.git("rev-parse", "HEAD")
        self.git("reset", "-q", "--hard", self.base)
        self.state = self.root / "state dir"
        self.env = dict(os.environ, DAY_OPEN_STATE_DIR=str(self.state))
        self.plan = self.root / "DayPlan 2026-10-24.md"
        self.plan.write_text(PLAN, encoding="utf-8")
        source = PIPELINE.read_text(encoding="utf-8")
        defs = [m.group() for m in re.finditer(r"^day_open_\w+\(\) \{\n.*?^\}\n", source,
                                               re.MULTILINE | re.DOTALL)]
        self.helpers = self.root / "helpers.sh"
        self.helpers.write_text("set -uo pipefail\n" + "\n".join(defs)
                                + '\ntg_notify() { return 0; }\n"$@"\n', encoding="utf-8")

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.repo), *args], check=True,
                              capture_output=True, text=True).stdout.strip()

    def block(self, reason="overlapping local edits", paths="current/WeekPlan W43.md a b.md"):
        done = subprocess.run([BASH, str(self.helpers), "day_open_sync_blocked", str(self.repo),
                               self.tip, "overlap", reason, paths], env=self.env,
                              capture_output=True, text=True)
        self.assertEqual(0, done.returncode, done.stderr)

    def marker(self):
        done = subprocess.run([BASH, str(self.helpers), "day_open_sync_marker_file", str(self.repo)],
                              env=self.env, capture_output=True, text=True)
        return Path(done.stdout.strip())

    def patch(self, *extra):
        return subprocess.run(["python3", "-I", str(PATCH), "--marker", str(self.marker()),
                               "--repo", str(self.repo), *extra], capture_output=True, text=True)

    def run_patch(self):
        done = self.patch("--dayplan", str(self.plan))
        self.assertEqual(0, done.returncode, done.stderr)
        return self.plan.read_text(encoding="utf-8")

    def test_marker_gives_exactly_one_block_with_details(self):
        self.block()
        text = self.run_patch()
        self.assertEqual(1, text.count(START))
        self.assertEqual(1, text.count("Вход Day Open мог устареть"))
        self.assertIn("отстаёт от origin на 1 коммит (причина: overlapping local edits; "
                      "пересекающиеся пути: current/WeekPlan W43.md a b.md). Реестр РП, план недели "
                      "и входящие читались из этой копии.", text)
        self.assertLess(text.index("# DayPlan"), text.index(START))
        self.assertLess(text.index(START), text.index("План на сегодня"))
        self.assertEqual(text, self.run_patch(), "second run must not duplicate the block")

    def test_no_marker_output_is_byte_identical(self):
        before = self.plan.read_bytes()
        self.assertFalse(self.marker().exists())
        self.assertEqual("", self.patch("--print-text").stdout)
        self.run_patch()
        self.assertEqual(before, self.plan.read_bytes())

    def test_marker_cleared_removes_block_and_restores_plan(self):
        self.block()
        self.run_patch()
        self.marker().unlink()
        self.assertEqual(PLAN, self.run_patch())

    def test_marker_cleared_by_production_helper(self):
        self.block()
        self.run_patch()
        moved = subprocess.run([BASH, str(self.helpers), "day_open_sync_marker_clear", str(self.repo)],
                               env=self.env, capture_output=True, text=True)
        self.assertEqual(0, moved.returncode, moved.stderr)
        self.assertNotIn(START, self.run_patch())

    def test_marker_already_satisfied_in_checkout_is_ignored(self):
        self.block()
        self.git("merge", "-q", "--ff-only", self.tip)
        self.assertEqual("", self.patch("--print-text").stdout)
        self.assertNotIn(START, self.run_patch())

    def test_digest_text_equals_plan_text(self):
        self.block()
        text = self.patch("--print-text").stdout
        self.assertTrue(text.startswith("Вход Day Open мог устареть: общая копия"))
        self.assertIn(text, self.run_patch())

    def test_plurals_and_missing_paths(self):
        marker = self.marker()
        marker.parent.mkdir(parents=True)
        for behind, word in (("2", "2 коммита"), ("5", "5 коммитов"), ("11", "11 коммитов"),
                             ("21", "21 коммит")):
            marker.write_text(f"head=0\ntarget=0\nbehind={behind}\nreason=r\nsig=unpublished|\n",
                              encoding="utf-8")
            text = self.patch("--print-text").stdout
            self.assertIn(f"на {word} (причина: r).", text)
            self.assertNotIn("пересекающиеся пути", text)

    def test_old_marker_without_paths_field_uses_sig(self):
        marker = self.marker()
        marker.parent.mkdir(parents=True)
        marker.write_text("head=0\ntarget=0\nbehind=3\nreason=x\nsig=overlap|old.txt\n", encoding="utf-8")
        self.assertIn("пересекающиеся пути: old.txt)", self.patch("--print-text").stdout)

    def test_llm_fill_chunks_keep_the_block_outside_pending_sections(self):
        spec = importlib.util.spec_from_file_location("fill", ROOT / "scripts/day-open-llm-fill.py")
        fill = importlib.util.module_from_spec(spec)
        try:
            spec.loader.exec_module(fill)
        except ImportError as error:
            self.skipTest(f"fill dependencies missing: {error}")
        self.block()
        text = self.run_patch().replace("| a | b |", "| <!-- PENDING --> | b |")
        chunks = fill.split_into_chunks(text)
        self.assertEqual(text, "".join("".join(c["lines"]) for c in chunks))
        holder = [c for c in chunks if START in "".join(c["lines"])]
        self.assertEqual(1, len(holder))

    def test_pipeline_runs_patch_after_the_fill_and_feeds_the_digest(self):
        source = PIPELINE.read_text(encoding="utf-8")
        self.assertLess(source.index('"$SCRIPT_HOME/day-open-llm-fill.py"'),
                        source.index("day-open-sync-banner-patch.py"))
        self.assertLess(source.index("day-open-sync-banner-patch.py"),
                        source.index('MSG+="💾 ${SHORT_HASH}"'))
        self.assertIn('MSG+=$\'\\n\\n\'"⚠️ ${SYNC_WARN}"', source)

    def test_pipeline_step_end_to_end_with_spaces_in_paths(self):
        self.block()
        source = PIPELINE.read_text(encoding="utf-8")
        step = re.search(r'^SYNC_MARKER=.*?^SYNC_WARN=.*?\|\| true\)\n', source,
                         re.MULTILINE | re.DOTALL)
        self.assertIsNotNone(step, "pipeline step 4.58 moved")
        digest = re.search(r'^\[ -z "\$\{SYNC_WARN:-\}" \].*\n', source, re.MULTILINE)
        script = self.root / "step.sh"
        script.write_text(
            "set -uo pipefail\n" + self.helpers.read_text(encoding="utf-8").replace('\n"$@"\n', "\n")
            + f'SCRIPT_HOME="{ROOT / "scripts"}"\n_PATCH_PY=python3\nDS_STRATEGY="$1"\nDAYPLAN_PATH="$2"\n'
            + step.group() + 'MSG="digest"\n' + digest.group() + 'printf "%s" "$MSG" > "$3"\n',
            encoding="utf-8")
        out = self.root / "digest.txt"
        done = subprocess.run([BASH, str(script), str(self.repo), str(self.plan), str(out)],
                              env=self.env, capture_output=True, text=True)
        self.assertEqual(0, done.returncode, done.stderr)
        plan = self.plan.read_text(encoding="utf-8")
        self.assertEqual(1, plan.count(START))
        digest_text = out.read_text(encoding="utf-8")
        self.assertEqual(1, digest_text.count("Вход Day Open мог устареть"))
        self.assertIn("a b.md", digest_text)


if __name__ == "__main__":
    unittest.main()
