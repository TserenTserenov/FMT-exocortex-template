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
        self.assertIn("отстаёт от origin на 1 коммит (причина: `overlapping local edits`; "
                      "пересекающиеся пути: `current/WeekPlan W43.md a b.md`). Реестр РП, план недели "
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
            self.assertIn(f"на {word} (причина: `r`).", text)
            self.assertNotIn("пересекающиеся пути", text)

    def test_old_marker_without_paths_field_uses_sig(self):
        marker = self.marker()
        marker.parent.mkdir(parents=True)
        marker.write_text("head=0\ntarget=0\nbehind=3\nreason=x\nsig=overlap|old.txt\n", encoding="utf-8")
        self.assertIn("пересекающиеся пути: `old.txt`)", self.patch("--print-text").stdout)

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
        self.assertIn('--digest "$SYNC_WARN"', source)

    def test_pipeline_step_end_to_end_with_spaces_in_paths(self):
        self.block()
        source = PIPELINE.read_text(encoding="utf-8")
        step = re.search(r'^SYNC_MARKER=.*?^SYNC_WARN=.*?\|\| true\)\n', source,
                         re.MULTILINE | re.DOTALL)
        self.assertIsNotNone(step, "pipeline step 4.58 moved")
        digest = re.search(r'^if \[ -n "\$\{SYNC_WARN:-\}" \]; then\n.*?^fi\n', source,
                           re.MULTILINE | re.DOTALL)
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

    # ---- review round: bounded size, markup safety, odd plans and markers ----

    def many_paths(self, count=2000):
        return " ".join(f"current/dir {n}/file-{n}.md" for n in range(count))

    def test_two_thousand_paths_keep_banner_and_digest_bounded(self):
        self.block(paths=self.many_paths())
        text = self.patch("--print-text").stdout
        self.assertLess(len(text), 900)
        self.assertRegex(text, "… и ещё [0-9]+")
        self.assertIn("file-0.md", text)
        self.assertNotIn("file-1999.md", text)
        self.assertEqual(text, self.patch("--print-text").stdout)
        self.assertIn(text, self.run_patch())

    def digest(self, base, banner):
        done = subprocess.run(["python3", "-I", str(PATCH), "--digest", banner],
                              input=base.encode("utf-8"), capture_output=True)
        self.assertEqual(0, done.returncode, done.stderr)
        return done.stdout.decode("utf-8")

    def test_digest_is_cut_only_in_the_banner(self):
        def units(text):
            return len(text.encode("utf-16-le")) // 2
        base = "✅ День открыт\n📋 Сегодня:\n" + "  РП строка\n" * 20 + "💾 abcd1234"
        huge = "Вход Day Open мог устареть: " + "я" * 41000
        out = self.digest(base, huge)
        self.assertLessEqual(units(out), 4096)
        self.assertTrue(out.startswith(base + "\n\n⚠️ Вход Day Open"))
        self.assertTrue(out.endswith("…"))
        self.assertEqual(base + "\n\n⚠️ коротко", self.digest(base, "коротко"))
        full = "б" * 4090
        self.assertEqual(full, self.digest(full, huge), "no room: digest alone, intact")
        self.assertEqual(base, self.digest(base, ""))
        self.assertLessEqual(units(self.digest("x" * 3000, "😀" * 3000)), 4096)

    def test_pipeline_message_stays_under_the_limit_with_2000_paths(self):
        self.block(paths=self.many_paths())
        source = PIPELINE.read_text(encoding="utf-8")
        step = re.search(r'^SYNC_MARKER=.*?^SYNC_WARN=.*?\|\| true\)\n', source,
                         re.MULTILINE | re.DOTALL)
        digest = re.search(r'^if \[ -n "\$\{SYNC_WARN:-\}" \]; then\n.*?^fi\n', source,
                           re.MULTILINE | re.DOTALL)
        self.assertIsNotNone(digest, "pipeline digest step moved")
        script = self.root / "limit.sh"
        script.write_text(
            "set -uo pipefail\n" + self.helpers.read_text(encoding="utf-8").replace('\n"$@"\n', "\n")
            + f'SCRIPT_HOME="{ROOT / "scripts"}"\n_PATCH_PY=python3\nDS_STRATEGY="$1"\nDAYPLAN_PATH="$2"\n'
            + step.group() + 'MSG="$(printf \'row %s\\n\' $(seq 1 470))"\nMSG+="💾 abcd1234"\n'
            + digest.group() + 'printf "%s" "$MSG" > "$3"\n', encoding="utf-8")
        out = self.root / "limit.txt"
        done = subprocess.run([BASH, str(script), str(self.repo), str(self.plan), str(out)],
                              env=self.env, capture_output=True, text=True)
        self.assertEqual(0, done.returncode, done.stderr)
        msg = out.read_text(encoding="utf-8")
        self.assertLessEqual(len(msg.encode("utf-16-le")) // 2, 4096)
        self.assertIn("row 470", msg)
        self.assertEqual(1, msg.count("💾 abcd1234"))
        self.assertIn("Вход Day Open мог устареть", msg)
        self.assertTrue(msg.endswith("\u2026"), "banner was cut")

    def test_plan_without_heading_gets_one_block_in_three_runs(self):
        self.block()
        plain = "просто текст\n\nвторой абзац\n"
        self.plan.write_text(plain, encoding="utf-8")
        for _ in range(3):
            text = self.run_patch()
        self.assertEqual(1, text.count(START))
        self.assertEqual(1, text.count("<!-- sync-banner:end -->"))
        self.marker().unlink()
        self.assertEqual(plain, self.run_patch())

    def test_without_heading_block_goes_after_the_frontmatter(self):
        plain = "---\ndate: 2026-10-24\n# not a heading\n---\nтекст\n"
        self.plan.write_text(plain, encoding="utf-8")
        self.block()
        text = self.run_patch()
        head = "---\ndate: 2026-10-24\n# not a heading\n---\n"
        self.assertTrue(text.startswith(head), text)
        self.assertLess(text.index(START), text.index("текст"))
        self.assertEqual(1, text.count(START))
        self.assertEqual(text, self.run_patch())
        self.marker().unlink()
        self.assertEqual(plain, self.run_patch())

    def test_hash_line_in_code_block_is_not_a_heading(self):
        plain = "intro\n\n```\n# comment in code\n```\n\n# Real title\n\nтекст\n"
        self.plan.write_text(plain, encoding="utf-8")
        self.block()
        text = self.run_patch()
        self.assertLess(text.index("# Real title"), text.index(START))
        self.marker().unlink()
        self.assertEqual(plain, self.run_patch())

    def test_heading_without_line_end_round_trips(self):
        self.plan.write_text("# Only title", encoding="utf-8")
        self.block()
        self.assertEqual(1, self.run_patch().count(START))
        self.marker().unlink()
        self.assertEqual("# Only title", self.run_patch())

    def test_garbage_marker_means_no_marker_and_no_traceback(self):
        self.block()
        self.run_patch()
        self.marker().write_bytes(b"\xff\xfe\x00\xff")
        done = self.patch("--dayplan", str(self.plan))
        self.assertEqual(0, done.returncode, done.stderr)
        self.assertNotIn("Traceback", done.stderr)
        self.assertEqual(PLAN, self.plan.read_text(encoding="utf-8"))
        self.marker().write_bytes(b"behind=\xff3\nreason=\xfe\n")
        done = self.patch("--print-text")
        self.assertEqual(0, done.returncode, done.stderr)
        self.assertNotIn("Traceback", done.stderr)

    def test_hostile_paths_cannot_break_out_of_the_block(self):
        hostile = ("a<!--b --!> c`d `` **bold** [l](javascript:alert(1)) <img src=x onerror=alert(1)> "
                   "x|y <!-- sync-banner:end --> <!-- sync-banner:start -->")
        self.block(reason="bad <!-- reason --> `x` [r](javascript:1)", paths=hostile)
        text = self.run_patch()
        self.assertEqual(1, text.count("<!-- sync-banner:start -->"))
        self.assertEqual(1, text.count("<!-- sync-banner:end -->"))
        self.assertEqual(2, text.count("<!--"), "only the two anchors may open comments")
        self.assertEqual(2, text.count("-->"))
        lines = [row for row in text.splitlines() if row.startswith("> ⚠️")]
        self.assertEqual(1, len(lines))
        for forbidden in "<>|[]":
            self.assertNotIn(forbidden, lines[0][1:], forbidden)
        self.assertEqual(text, self.run_patch())
        self.marker().unlink()
        self.assertEqual(PLAN, self.run_patch())

    def test_odd_line_breaks_in_marker_values_keep_fields_apart(self):
        marker = self.marker()
        marker.parent.mkdir(parents=True)
        marker.write_bytes("head=0\ntarget=0\nbehind=4\nreason=one\rtwo\x1ethree\x0bfour\n"
                           "paths=p\x1eq r\rs\n".encode("utf-8"))
        text = self.patch("--print-text").stdout
        self.assertIn("на 4 коммита", text)
        self.assertIn("`one two three four`", text)
        self.assertIn("`p q r s`", text)

    def test_writer_keeps_option_like_values_and_one_line_per_field(self):
        self.block(reason="-n literal\\n -e", paths="-n\nbehind=999\n-e x")
        raw = self.marker().read_text(encoding="utf-8").split("\n")
        self.assertEqual(1, sum(1 for row in raw if row.startswith("behind=")), raw)
        self.assertIn("reason=-n literal\\n -e", raw)
        self.assertIn("paths=-n behind=999 -e x", raw)
        self.assertIn("на 1 коммит", self.patch("--print-text").stdout)


if __name__ == "__main__":
    unittest.main()
