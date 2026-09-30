"""Extractor regression tests: disposable Git remotes and a substituted AI CLI only."""

import importlib.util
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[3]
RUNNER = ROOT / "roles/extractor/scripts/extractor.sh"
PREFILTER = ROOT / "roles/extractor/scripts/wp429-extractor-prefilters.py"
spec = importlib.util.spec_from_file_location("prefilter", PREFILTER)
prefilter = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prefilter)


class ExtractorPipelineTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="extractor-test-")
        self.base = Path(self.temporary.name)
        self.workspace = self.base / "workspace"
        self.workspace.mkdir()
        (self.base / "home").mkdir()
        (self.base / "runs").mkdir()
        self.env = {
            **os.environ,
            "HOME": str(self.base / "home"),
            "TMPDIR": str(self.base / "runs") + "/",
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Fixture",
            "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
            "GIT_COMMITTER_NAME": "Fixture",
            "GIT_COMMITTER_EMAIL": "fixture@example.invalid",
        }

    def tearDown(self):
        for directory, dirs, files in os.walk(self.base):
            for name in [directory, *[os.path.join(directory, n) for n in dirs + files]]:
                if not os.path.islink(name):
                    os.chmod(name, os.stat(name).st_mode | 0o700)
        self.temporary.cleanup()

    def run_command(self, args, *, check=True):
        return subprocess.run(args, env=self.env, text=True, capture_output=True, check=check)

    def git(self, repo, *args):
        return self.run_command(["git", "-C", str(repo), *args]).stdout.strip()

    def write(self, path, text):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
        return path

    def published_repo(self, name, files):
        remote = self.base / (name + ".git")
        publisher = self.base / (name + "-publisher")
        canonical = self.workspace / name
        self.run_command(["git", "init", "--bare", "-b", "main", str(remote)])
        self.run_command(["git", "clone", str(remote), str(publisher)])
        for path, content in files.items():
            self.write(publisher / path, content)
        self.git(publisher, "add", "--", *files)
        self.git(publisher, "commit", "-m", "fixture")
        self.git(publisher, "push", "origin", "main")
        self.run_command(["git", "clone", str(remote), str(canonical)])
        return canonical, publisher, remote

    def shell(self, command, *, runner=RUNNER, variables=None, check=True):
        # Load the real function bodies without production startup/auth/notifications.
        functions = re.findall(r"^\w+\(\) \{[^\n]*\n.*?^\}", runner.read_text(), re.M | re.S)
        values = {
            "WORKSPACE": str(self.workspace),
            "IWE_WORKSPACE": str(self.workspace),
            "IWE_GOVERNANCE_REPO": "DS-fixture",
            "IWE_GOVERNANCE_BRANCH": "main",
            "IWE_TEMPLATE": str(ROOT),
            "PROMPTS_DIR": str(ROOT / "roles/extractor/prompts"),
            "SCRIPT_DIR": str(runner.parent),
            "LOG_FILE": str(self.base / "runner.log"),
            "DATE": "2026-09-12",
            "IWE_EXTRACTOR_INBOX_LOCK_DIR": str(self.base / "inbox.lock"),
            **(variables or {}),
        }
        assignments = "\n".join(f"export {key}={shlex.quote(value)}" for key, value in values.items())
        script = self.write(self.base / "test.sh", "\n".join([
            "set -e", *functions, assignments,
            "notify() { :; }", "notify_telegram() { :; }",
            "extractor_scope_open_and_note() { return 0; }",
            "extractor_scope_close() { :; }", command,
        ]))
        return self.run_command(["bash", str(script)], check=check)

    def make_pack(self):
        return self.published_repo("PACK-fixture", {"pack/known.md": "---\nid: DP.M.001\n---\nExisting method\n"})

    def build_runtime(self):
        values = {
            "HOME_DIR": self.base / "home", "USER_NAME": "fixture",
            "WORKSPACE_DIR": self.workspace, "CLAUDE_PATH": "/bin/false",
            "CLAUDE_PROJECT_SLUG": "fixture", "TIMEZONE_HOUR": "3",
            "TIMEZONE_DESC": "UTC", "GITHUB_USER": "fixture",
            "GOVERNANCE_REPO": "DS-fixture", "IWE_TEMPLATE": ROOT,
            "IWE_RUNTIME": self.workspace / ".iwe-runtime", "IWE_SCRIPTS": ROOT / "scripts",
        }
        env_file = self.write(self.workspace / ".exocortex.env", "\n".join(f'{k}="{v}"' for k, v in values.items()))
        self.run_command(["bash", str(ROOT / "setup/build-runtime.sh"), "--quiet", "--workspace", str(self.workspace), "--env-file", str(env_file)])
        return self.workspace / ".iwe-runtime/roles/extractor/scripts/extractor.sh"

    def test_sources_and_empty_heading_boundaries(self):
        inbox = self.workspace / "inbox"
        legacy = self.write(inbox / "captures.md", "# Inbox\n### Empty A\n<!--\n### Comment heading\n-->\n### B\nPlain body\n### Finished [analyzed 2026-09-12]\nBody\n")
        monthly = self.write(inbox / "captures/2026-09.md", "### Code example\n````md\n```\n### Not another capture\n```\n````\n### Deferred [defer]\nBody\n")
        fleeting = self.write(inbox / "fleeting-notes.md", "### Quick thought\nBody\n")
        self.write(inbox / "captures/pattern_helper.md", "### Not an input\nBody\n")
        result = self.shell(f'capture_source_files {shlex.quote(str(inbox))}')
        self.assertEqual(result.stdout.splitlines(), [str(legacy), str(monthly), str(fleeting)])
        result = self.shell("pending_capture_count " + " ".join(shlex.quote(str(p)) for p in [legacy, monthly, fleeting]))
        self.assertEqual(result.stdout.strip(), "3")

    def test_status_marks_with_trailing_text_are_not_pending(self):
        # The model marks duplicates as "[duplicate, см. <report> Кандидат #4]":
        # a comma (or any non-word char) after the status word must still count
        # as marked, otherwise the deterministic pre-check reports pending
        # captures the model correctly finds none of, and inbox-check fails with
        # "success without a new extraction report" every 3h (2026-09-25..29).
        monthly = self.write(self.workspace / "inbox/captures/2026-09.md", "\n".join([
            "### A [duplicate, см. 2026-09-26-inbox-check-4.md Кандидат #4]", "Body",
            "### B [analyzed 2026-09-12]", "Body",
            "### C [defer: ждёт РП]", "Body",
            "### D [processed]", "Body",
            "### E [analyzedX]", "Body",
            "### F", "Body", ""]))
        result = self.shell(f"pending_capture_count {shlex.quote(str(monthly))}")
        self.assertEqual(result.stdout.strip(), "2")  # E (not a status word) and F

    def test_fleeting_only_is_pending(self):
        fleeting = self.write(self.workspace / "inbox/fleeting-notes.md", "### Thought\nBody\n")
        result = self.shell('sources=(); while IFS= read -r src; do sources+=("$src"); done < <(capture_source_files "$WORKSPACE/inbox"); pending_capture_count "${sources[@]}"')
        self.assertEqual(result.stdout.strip(), "1")
        self.assertTrue(fleeting.exists())

    def test_standalone_capture_files_pending_status_only(self):
        # Browser-source captures (run_extractor -> agent-runner direct commit):
        # one file IS one capture, YAML frontmatter status instead of a
        # "### " heading. pending_capture_count() cannot parse this shape at
        # all -- these files sat unprocessed for ~2 months in production
        # before this fix (WP-560 Ф13, 2026-09-14).
        inbox = self.workspace / "inbox"
        pending_lesson = self.write(inbox / "captures/lesson_a.md", "---\nstatus: pending-review\n---\n# A\n")
        pending_pattern = self.write(inbox / "captures/pattern_b.md", "---\nstatus: pending-review\n---\n# B\n")
        self.write(inbox / "captures/distinction_c.md", "---\nstatus: active\n---\n# C\n")
        self.write(inbox / "captures/feedback_d.md", "---\nstatus: applied\n---\n# D\n")
        # No frontmatter at all -- same fixture shape used elsewhere
        # (test_sources_and_empty_heading_boundaries) to prove capture_source_files
        # excludes it; must be excluded here too, for the same reason a real
        # capture always carries frontmatter.
        self.write(inbox / "captures/pattern_helper.md", "### Not an input\nBody\n")
        # A monthly file must never leak into this function -- it has its own.
        self.write(inbox / "captures/2026-09.md", "### Not a standalone file\nBody\n")
        # `|| true`: the last file in sorted order (pattern_helper.md) has no
        # match, so the loop's own last exit status is 1 -- harmless under
        # the real call site (a process-substitution `<(...)` feeding a
        # `while read` loop, whose exit status isn't checked either), but
        # fatal here where the function is the script's own last statement
        # under `set -e`.
        result = self.shell(f'standalone_capture_files {shlex.quote(str(inbox))} || true')
        self.assertEqual(result.stdout.splitlines(), [str(pending_lesson), str(pending_pattern)])

    def test_standalone_capture_files_ignores_status_line_in_body(self):
        # A lesson describing this very bug can legitimately quote the
        # phrase "status: pending-review" in its BODY while its own real
        # frontmatter status is something else entirely (e.g. active). A
        # whole-file grep would wrongly re-open an already-settled capture.
        inbox = self.workspace / "inbox"
        self.write(
            inbox / "captures/lesson_about_this_bug.md",
            "---\nstatus: active\n---\n"
            "# A lesson about a past bug\n\n"
            "The browser writer used `status: pending-review` in its frontmatter.\n",
        )
        result = self.shell(f'standalone_capture_files {shlex.quote(str(inbox))} || true')
        self.assertEqual(result.stdout.splitlines(), [])

    def test_standalone_capture_files_tolerates_whitespace_variants(self):
        # Same bug class as bug-2026-06-10-ke-queue-drift (day-open-scaffold.sh):
        # a literal-space regex silently drops a real pending file when a tab
        # or CRLF follows "status:".
        inbox = self.workspace / "inbox"
        tabbed = self.write(inbox / "captures/lesson_tab.md", "---\nstatus:\tpending-review\n---\n# Tab\n")
        crlf = self.write(inbox / "captures/lesson_crlf.md", "---\r\nstatus: pending-review\r\n---\r\n# CRLF\r\n")
        result = self.shell(f'standalone_capture_files {shlex.quote(str(inbox))}')
        self.assertEqual(result.stdout.splitlines(), [str(crlf), str(tabbed)])

    def test_run_inbox_check_isolated_counts_standalone_alongside_monthly(self):
        # End-to-end: the shell-level pending count feeding run_inbox_check_isolated
        # must add both sources together, not just one of them.
        inbox = self.workspace / "inbox"
        self.write(inbox / "captures/2026-09.md", "### Monthly pending\nBody\n")
        self.write(inbox / "captures/lesson_x.md", "---\nstatus: pending-review\n---\n# X\n")
        result = self.shell(
            'capture_sources=(); EXTRACTOR_CAPTURE_PATHS=(); '
            'while IFS= read -r src; do capture_sources+=("$src"); done < <(capture_source_files "$WORKSPACE/inbox"); '
            'standalone_sources=(); '
            'while IFS= read -r src; do standalone_sources+=("$src"); done < <(standalone_capture_files "$WORKSPACE/inbox"); '
            'actual_pending=0; '
            '[ "${#capture_sources[@]}" -gt 0 ] && actual_pending=$(pending_capture_count "${capture_sources[@]}"); '
            'actual_pending=${actual_pending:-0}; '
            'echo $((actual_pending + ${#standalone_sources[@]}))'
        )
        self.assertEqual(result.stdout.strip(), "2")

    def test_pack_snapshot_uses_remote_default_not_stale_local_head(self):
        canonical, publisher, _ = self.make_pack()
        old_head = self.git(canonical, "rev-parse", "HEAD")
        self.write(publisher / "pack/new.md", "---\nid: DP.D.002\n---\nRemote only\n")
        self.git(publisher, "add", "--", "pack/new.md")
        self.git(publisher, "commit", "-m", "new published card")
        self.git(publisher, "push", "origin", "main")
        destination = self.base / "snapshot"
        destination.mkdir()
        self.shell(f'mount_readonly_packs "$WORKSPACE" {shlex.quote(str(destination))}; pack_snapshot_context')
        self.assertEqual(self.git(destination / "PACK-fixture", "rev-parse", "HEAD"), self.git(publisher, "rev-parse", "HEAD"))
        self.assertTrue((destination / "PACK-fixture/pack/new.md").exists())
        self.assertEqual(self.git(canonical, "rev-parse", "HEAD"), old_head)
        self.assertNotEqual(old_head, self.git(publisher, "rev-parse", "HEAD"))
        fixed_head = self.git(destination / "PACK-fixture", "rev-parse", "HEAD")
        self.write(publisher / "pack/later.md", "Published after the snapshot\n")
        self.git(publisher, "add", "--", "pack/later.md")
        self.git(publisher, "commit", "-m", "later publication")
        self.git(publisher, "push", "origin", "main")
        self.assertEqual(self.git(destination / "PACK-fixture", "rev-parse", "HEAD"), fixed_head)
        self.assertFalse((destination / "PACK-fixture/pack/later.md").exists())

    def test_refresh_failure_never_starts_cli_or_marks_source(self):
        canonical, _, remote = self.make_pack()
        self.git(canonical, "remote", "set-url", "origin", str(remote) + "-missing")
        governance, _, _ = self.published_repo("DS-fixture", {"inbox/fleeting-notes.md": "### Thought\nBody\n"})
        marker = self.base / "cli-called"
        cli = self.write(self.base / "fake-cli", f"#!/bin/sh\ntouch {shlex.quote(str(marker))}\n")
        cli.chmod(0o700)
        result = self.shell("run_inbox_check_isolated", variables={"AI_CLI": str(cli)}, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Pack freshness not verified", result.stdout)
        self.assertFalse(marker.exists())
        self.assertNotIn("[analyzed", (governance / "inbox/fleeting-notes.md").read_text())

    def test_single_letter_ids_and_declarations(self):
        text = "id: DP.D.999\nFile: DP.D.999-new-card.md\nRelated: DP.D.001 DP.M.002 DP.FM.003\n"
        self.assertEqual(prefilter.extract_mentioned_ids(text), {"DP.D.001", "DP.M.002", "DP.FM.003"})

    def test_missing_or_unverified_packs_are_not_clean(self):
        report = self.write(self.workspace / "2026-09-12-inbox-check.md", "**Проверено:** DP.D.123\n")
        result = self.run_command([sys.executable, str(PREFILTER), "--report", str(report), "--iwe-root", str(self.workspace)], check=False)
        self.assertEqual(result.returncode, 2)
        self.assertIn("не подтверждена", result.stdout)

    def test_missing_prefilter_is_visible_and_idempotent(self):
        governance, _, _ = self.published_repo("DS-fixture", {"README.md": "fixture\n"})
        report = self.write(governance / "inbox/extraction-reports/2026-09-12-inbox-check.md", "# Fixture report\nBody remains\n")
        empty_scripts = self.base / "empty-scripts"
        empty_scripts.mkdir()
        self.shell('prefilter_changed_reports "$WORKSPACE/DS-fixture"', variables={"SCRIPT_DIR": str(empty_scripts)})
        first = report.read_text()
        self.shell('prefilter_changed_reports "$WORKSPACE/DS-fixture"', variables={"SCRIPT_DIR": str(empty_scripts)})
        text = report.read_text()
        self.assertEqual(text, first)
        self.assertIn("Статус: not-checked", text)
        self.assertIn("Body remains", text)
        self.assertEqual(text.count("<!-- extractor-prefilter:start -->"), 1)

    def test_present_prefilter_replaces_warning_and_ignores_old_annotation_ids(self):
        pack, _, _ = self.make_pack()
        head = self.git(pack, "rev-parse", "HEAD")
        governance, _, _ = self.published_repo("DS-fixture", {"README.md": "fixture\n"})
        report = self.write(governance / "inbox/extraction-reports/2026-09-12-inbox-check.md", "# Fixture\n**Проверено:** DP.D.999\n")
        command = f'EXTRACTOR_PACK_REFS=(PACK-fixture={head}); EXTRACTOR_PACK_VERIFIED_AT=fixture; prefilter_changed_reports "$WORKSPACE/DS-fixture"'
        self.shell(command)
        self.assertIn("[missing-id] DP.D.999", report.read_text())
        self.write(report, report.read_text().replace("**Проверено:** DP.D.999", "**Проверено:** DP.M.001"))
        self.shell(command)
        self.assertIn("Статус: clean", report.read_text())
        self.assertNotIn("DP.D.999", report.read_text())
        self.assertEqual(report.read_text().count("<!-- extractor-prefilter:start -->"), 1)

    def test_changed_pack_ref_and_missing_report_are_not_clean(self):
        pack, _, _ = self.make_pack()
        report = self.write(self.base / "2026-09-12-inbox-check.md", "# Fixture\n")
        args = [sys.executable, str(PREFILTER), "--report", str(report), "--iwe-root", str(self.workspace)]
        result = self.run_command([*args, "--pack-ref", "PACK-fixture=" + "0" * 40], check=False)
        self.assertEqual(result.returncode, 2)
        self.assertIn("изменился", result.stdout)
        report.unlink()
        result = self.run_command(args, check=False)
        self.assertEqual(result.returncode, 2)

    def test_malformed_annotation_does_not_truncate_report(self):
        report = self.write(self.base / "report.md", "# Fixture\n<!-- extractor-prefilter:start -->\nKeep this body\n")
        before = report.read_text()
        result = self.shell(f'write_prefilter_section {shlex.quote(str(report))} clean fixture', check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(report.read_text(), before)

    def test_annotation_examples_inside_fenced_candidate_are_preserved(self):
        for opening, closing in [("~~~markdown", "~~~"), ("````markdown", "````")]:
            with self.subTest(opening=opening):
                candidate = (
                    "# Fixture\n" + opening + "\n```\n"
                    "<!-- extractor-prefilter:start -->\n"
                    "UNIQUE_CANDIDATE_CONTENT DP.D.999\n"
                    "<!-- extractor-prefilter:end -->\n```\n" + closing + "\n"
                )
                report = self.write(self.base / "report.md", candidate)
                command = f'write_prefilter_section {shlex.quote(str(report))} clean fixture'
                self.shell(command)
                first = report.read_text()
                self.assertTrue(first.startswith(candidate))
                self.assertEqual(prefilter.read_report(report).rstrip(), candidate.rstrip())
                self.shell(command)
                self.assertEqual(report.read_text(), first)

    def inbox_fixture(self):
        self.make_pack()
        governance, _, remote = self.published_repo("DS-fixture", {
            "inbox/fleeting-notes.md": "### Thought\nBody\n",
            "inbox/captures/pattern_helper.md": "helper must remain\n",
        })
        cli = self.write(self.base / "fake-cli", f"#!{sys.executable}\n" + '''from pathlib import Path
import sys
assert "inbox/fleeting-notes.md" in sys.argv[-1]
assert "PACK-fixture=" in sys.argv[-1]
repo = Path("DS-fixture")
source = repo / "inbox/fleeting-notes.md"
source.write_text(source.read_text().replace("### Thought", "### Thought [analyzed 2026-09-12]"))
(repo / "inbox/captures/pattern_helper.md").write_text("unrelated change must not publish\\n")
(repo / "inbox/captures/2026-10.md").write_text("new source outside the input snapshot\\n")
reports = repo / "inbox/extraction-reports"
reports.mkdir()
(reports / "2026-09-12-inbox-check.md").write_text("# Fixture report\\n**Источник capture:** fleeting-notes.md — Thought\\n**Проверено:** DP.M.001 DP.D.999 DP.FM.999\\n")
''')
        cli.chmod(0o700)
        return governance, remote, cli

    def run_inbox(self, cli, *, runner=RUNNER, prefix="", check=True):
        return self.shell(prefix + "run_inbox_check_isolated", runner=runner, variables={
            "AI_CLI": str(cli), "AI_CLI_PROMPT_FLAG": "-p", "AI_CLI_EXTRA_FLAGS": "",
        }, check=check)

    def test_shipped_runner_publishes_fleeting_mark_and_filter_warning(self):
        runner = self.build_runtime()
        shipped_filter = runner.parent / PREFILTER.name
        self.assertEqual(shipped_filter.read_bytes(), PREFILTER.read_bytes())
        governance, remote, cli = self.inbox_fixture()
        result = self.run_inbox(cli, runner=runner)
        self.assertEqual(result.returncode, 0)
        published = self.git(remote, "show", "main:inbox/fleeting-notes.md")
        self.assertIn("[analyzed 2026-09-12]", published)
        report = self.git(remote, "show", "main:inbox/extraction-reports/2026-09-12-inbox-check.md")
        self.assertIn("Статус: warnings", report)
        self.assertIn("[missing-id] DP.D.999", report)
        self.assertIn("[missing-id] DP.FM.999", report)
        self.assertNotIn("[missing-id] DP.M.001", report)
        self.assertIn("PACK-fixture=", report)
        self.assertEqual(self.git(remote, "show", "main:inbox/captures/pattern_helper.md"), "helper must remain")
        self.assertNotIn("inbox/captures/2026-10.md", self.git(remote, "ls-tree", "-r", "--name-only", "main").splitlines())
        self.assertNotIn("[analyzed", (governance / "inbox/fleeting-notes.md").read_text())

    def test_run_inbox_check_isolated_publishes_standalone_capture(self):
        # True end-to-end (not the hand-copied counting snippet in
        # test_run_inbox_check_isolated_counts_standalone_alongside_monthly):
        # a real standalone browser-source pending file goes all the way
        # through capture_source_files/standalone_capture_files wiring ->
        # EXTRACTOR_CAPTURE_PATHS -> LLM context -> git worktree staging ->
        # commit --only -> publish. The fake CLI plays the LLM's part: it
        # flips the file's own frontmatter status (not an inline heading
        # marker, since this source has none) and writes an extraction
        # report, exactly as Step 4 of inbox-check.md instructs.
        self.make_pack()
        governance, _, remote = self.published_repo("DS-fixture", {
            "inbox/captures/lesson_x.md": "---\nstatus: pending-review\n---\n# X\nBody\n",
        })
        cli = self.write(self.base / "fake-cli-standalone", f"#!{sys.executable}\n" + '''from pathlib import Path
import sys
assert "inbox/captures/lesson_x.md" in sys.argv[-1]
repo = Path("DS-fixture")
source = repo / "inbox/captures/lesson_x.md"
source.write_text(source.read_text().replace("status: pending-review", "status: analyzed"))
reports = repo / "inbox/extraction-reports"
reports.mkdir()
(reports / "2026-09-12-inbox-check.md").write_text("# Fixture report\\n**Источник capture:** lesson_x.md\\n**Проверено:** DP.M.001\\n")
''')
        cli.chmod(0o700)
        result = self.run_inbox(cli)
        self.assertEqual(result.returncode, 0)
        published = self.git(remote, "show", "main:inbox/captures/lesson_x.md")
        self.assertIn("status: analyzed", published)
        self.assertNotIn("status: pending-review", published)

    def test_empty_inbox_skips_cli_and_creates_no_publication(self):
        _, _, remote = self.published_repo("DS-fixture", {"README.md": "empty inbox\n"})
        before = self.git(remote, "rev-parse", "main")
        result = self.run_inbox(self.base / "cli-must-not-be-called")
        self.assertIn("SKIP: No pending captures", result.stdout)
        self.assertEqual(self.git(remote, "rev-parse", "main"), before)
        self.assertNotIn("Completed process:", result.stdout)

    def test_cli_zero_without_report_is_failure_and_does_not_publish(self):
        _, remote, cli = self.inbox_fixture()
        self.write(cli, "#!/bin/sh\nexit 0\n")
        before = self.git(remote, "rev-parse", "main")
        result = self.run_inbox(cli, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("without a new extraction report", result.stdout)
        self.assertNotIn("Completed process:", result.stdout)
        self.assertEqual(self.git(remote, "rev-parse", "main"), before)

    def test_report_without_source_marks_is_failure(self):
        _, remote, cli = self.inbox_fixture()
        self.write(cli, cli.read_text().replace("source.write_text(source.read_text().replace", "# source.write_text(source.read_text().replace"))
        before = self.git(remote, "rev-parse", "main")
        result = self.run_inbox(cli, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("without updated input marks", result.stdout)
        self.assertEqual(self.git(remote, "rev-parse", "main"), before)

    def test_session_open_failure_blocks_commit_and_publication(self):
        _, remote, cli = self.inbox_fixture()
        before = self.git(remote, "rev-parse", "main")
        result = self.run_inbox(cli, prefix="extractor_scope_open_and_note() { return 1; }\n", check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("commit and publication blocked", result.stdout)
        self.assertNotIn("Committed DS-fixture", result.stdout)
        self.assertEqual(self.git(remote, "rev-parse", "main"), before)

    def test_publication_failure_preserves_result_and_returns_failure(self):
        _, remote, cli = self.inbox_fixture()
        hook = self.write(remote / "hooks/pre-receive", "#!/bin/sh\nexit 1\n")
        hook.chmod(0o700)
        before = self.git(remote, "rev-parse", "main")
        result = self.run_inbox(cli, check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("git push failed", result.stdout)
        self.assertNotIn("Completed process:", result.stdout)
        self.assertEqual(self.git(remote, "rev-parse", "main"), before)
        self.assertTrue(list((self.base / "runs").rglob("2026-09-12-inbox-check.md")))

    def test_cross_report_warning_contains_no_source_quote(self):
        self.make_pack()
        reports = self.base / "reports"
        self.write(reports / "2026-09-11-inbox-check.md", "**Источник capture:** fixture-source-text\n")
        report = self.write(reports / "2026-09-12-inbox-check.md", "**Источник capture:** fixture-source-text\n")
        head = self.git(self.workspace / "PACK-fixture", "rev-parse", "HEAD")
        result = self.run_command([sys.executable, str(PREFILTER), "--report", str(report), "--iwe-root", str(self.workspace), "--pack-ref", f"PACK-fixture={head}"], check=False)
        self.assertEqual(result.returncode, 1)
        self.assertIn("[cross-report]", result.stdout)
        self.assertNotIn("fixture-source-text", result.stdout)

    # --- isolated feeders (session-close-feed / git-diff-feed) -------------------

    FEED_BLOCK = "### Feed candidate [feed:git-diff 2026-09-12]\\n**Тип:** method\\n"

    def feed_fixture(self, agent_body):
        """Canonical DS-fixture + a second repo; fake CLI = the feeder agent."""
        self.make_pack()
        governance, _, remote = self.published_repo("DS-fixture", {
            "README.md": "fixture\n",
            "inbox/captures/2026-09.md": "# Captures 2026-09\n",
        })
        cli = self.write(self.base / "fake-feed-cli", f"#!{sys.executable}\n" + """from pathlib import Path
import subprocess
import sys
assert Path("PACK-fixture").is_symlink(), "all repositories must be linked into the feed workspace"
assert Path("DS-fixture").is_symlink()
assert "Не выполняй git add/commit/push" in sys.argv[-1]
repo = Path("DS-fixture")
captures = repo / "inbox/captures/2026-09.md"
block = "%s"
""" % self.FEED_BLOCK + agent_body)
        cli.chmod(0o700)
        return governance, remote, cli

    def run_feed(self, cli, *, check=True, label="git-diff", prompt="git-diff-feed", variables=None):
        return self.shell(f'run_feed_isolated {prompt} "12 hours ago" {label}', variables={
            "AI_CLI": str(cli), "AI_CLI_PROMPT_FLAG": "-p", "AI_CLI_EXTRA_FLAGS": "",
            **(variables or {}),
        }, check=check)

    def assert_canonical_untouched(self, governance, head_before):
        self.assertEqual(self.git(governance, "status", "--porcelain"), "")
        self.assertEqual(self.git(governance, "rev-parse", "HEAD"), head_before)
        self.assertEqual(self.git(governance, "branch", "--show-current"), "main")

    def leftover_feed_dirs(self):
        return list((self.base / "runs").glob("iwe-extractor-feed.*"))

    def test_isolated_feed_publishes_block_and_leaves_canonical_untouched(self):
        governance, remote, cli = self.feed_fixture('captures.write_text(captures.read_text() + block)\n')
        head_before = self.git(governance, "rev-parse", "HEAD")
        commits_before = int(self.git(remote, "rev-list", "--count", "main"))
        result = self.run_feed(cli)
        self.assertEqual(result.returncode, 0)
        self.assertIn("[feed:git-diff 2026-09-12]", self.git(remote, "show", "main:inbox/captures/2026-09.md"))
        self.assertEqual(int(self.git(remote, "rev-list", "--count", "main")), commits_before + 1)
        self.assertTrue(self.git(remote, "log", "-1", "--format=%s", "main").startswith("feed(git-diff):"))
        self.assertEqual(self.git(remote, "show", "main:README.md"), "fixture")
        self.assert_canonical_untouched(governance, head_before)
        self.assertNotIn("[feed:", (governance / "inbox/captures/2026-09.md").read_text())
        # Published run: worktree, branch and the whole run directory are gone,
        # and cleanup never reached through the links into the real repositories.
        self.assertEqual(self.leftover_feed_dirs(), [])
        self.assertEqual(self.git(governance, "worktree", "list").count("\n"), 0)
        self.assertEqual(self.git(governance, "branch", "--list", "extractor/feed-*"), "")
        self.assertTrue((self.workspace / "PACK-fixture/pack/known.md").exists())
        self.assertTrue((self.workspace / "PACK-fixture/.git").exists())

    def test_isolated_feed_creates_new_month_file_from_allowlist(self):
        governance, remote, cli = self.feed_fixture(
            '(repo / "inbox/captures/2026-10.md").write_text("# Captures 2026-10\\n" + block)\n')
        head_before = self.git(governance, "rev-parse", "HEAD")
        self.run_feed(cli)
        self.assertIn("[feed:git-diff", self.git(remote, "show", "main:inbox/captures/2026-10.md"))
        self.assert_canonical_untouched(governance, head_before)

    def test_isolated_feed_no_changes_is_success_without_commit(self):
        governance, remote, cli = self.feed_fixture("pass\n")
        head_before = self.git(governance, "rev-parse", "HEAD")
        before = self.git(remote, "rev-parse", "main")
        result = self.run_feed(cli)
        self.assertEqual(result.returncode, 0)
        self.assertIn("no_changes", result.stdout)
        self.assertEqual(self.git(remote, "rev-parse", "main"), before)
        self.assert_canonical_untouched(governance, head_before)
        self.assertEqual(self.leftover_feed_dirs(), [])

    def test_isolated_feed_agent_commit_is_normalised_and_republished_by_script(self):
        # The agent ignores "do not commit": its own commit must not be published
        # as-is; the script re-derives the change from the working tree.
        governance, remote, cli = self.feed_fixture(
            'captures.write_text(captures.read_text() + block)\n'
            'subprocess.run(["git", "-C", "DS-fixture", "add", "--", "inbox/captures/2026-09.md"], check=True)\n'
            'subprocess.run(["git", "-C", "DS-fixture", "commit", "-m", "agent self-commit"], check=True)\n')
        head_before = self.git(governance, "rev-parse", "HEAD")
        commits_before = int(self.git(remote, "rev-list", "--count", "main"))
        self.run_feed(cli)
        self.assertIn("[feed:git-diff", self.git(remote, "show", "main:inbox/captures/2026-09.md"))
        self.assertEqual(int(self.git(remote, "rev-list", "--count", "main")), commits_before + 1)
        self.assertTrue(self.git(remote, "log", "-1", "--format=%s", "main").startswith("feed(git-diff):"))
        self.assertNotIn("agent self-commit", self.git(remote, "log", "--format=%s", "main"))
        self.assert_canonical_untouched(governance, head_before)

    def assert_feed_blocked(self, governance, remote, cli, expected_message, variables=None):
        head_before = self.git(governance, "rev-parse", "HEAD")
        before = self.git(remote, "rev-parse", "main")
        result = self.run_feed(cli, check=False, variables=variables)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(expected_message, result.stdout)
        self.assertNotIn("Completed process:", result.stdout)
        self.assertEqual(self.git(remote, "rev-parse", "main"), before)
        self.assert_canonical_untouched(governance, head_before)
        # Nothing is lost: the worktree is preserved for review.
        self.assertEqual(len(self.leftover_feed_dirs()), 1)
        self.assertNotIn("[feed:", (governance / "inbox/captures/2026-09.md").read_text())

    def test_isolated_feed_change_outside_allowlist_blocks_publication(self):
        governance, remote, cli = self.feed_fixture(
            'captures.write_text(captures.read_text() + block)\n'
            '(repo / "README.md").write_text("agent edited an unrelated file\\n")\n')
        self.assert_feed_blocked(governance, remote, cli, "outside the captures allowlist: README.md")

    def test_isolated_feed_new_untracked_file_outside_allowlist_blocks_publication(self):
        governance, remote, cli = self.feed_fixture(
            'captures.write_text(captures.read_text() + block)\n'
            '(repo / "inbox/extraction-reports").mkdir()\n'
            '(repo / "inbox/extraction-reports/r.md").write_text("report\\n")\n')
        self.assert_feed_blocked(governance, remote, cli, "outside the captures allowlist: inbox/extraction-reports/r.md")

    def test_isolated_feed_agent_commit_outside_allowlist_blocks_publication(self):
        governance, remote, cli = self.feed_fixture(
            'captures.write_text(captures.read_text() + block)\n'
            '(repo / "README.md").write_text("committed by the agent\\n")\n'
            'subprocess.run(["git", "-C", "DS-fixture", "add", "--", "README.md", "inbox/captures/2026-09.md"], check=True)\n'
            'subprocess.run(["git", "-C", "DS-fixture", "commit", "-m", "agent self-commit"], check=True)\n')
        self.assert_feed_blocked(governance, remote, cli, "outside the captures allowlist: README.md")

    def test_isolated_feed_changed_captures_without_feed_marker_blocks_publication(self):
        governance, remote, cli = self.feed_fixture(
            'captures.write_text(captures.read_text() + "### Manual-looking block\\nBody\\n")\n')
        self.assert_feed_blocked(governance, remote, cli, "for this mode")

    def test_isolated_feed_cli_failure_publishes_nothing(self):
        governance, remote, cli = self.feed_fixture("sys.exit(3)\n")
        self.assert_feed_blocked(governance, remote, cli, "AI CLI failed")

    def test_isolated_feed_replacing_captures_with_one_line_is_refused(self):
        # Accumulated captures must never be rewritten: append-only.
        governance, remote, cli = self.feed_fixture(
            'captures.write_text(block)\n')
        self.assert_feed_blocked(governance, remote, cli, "append-only contract")

    def test_isolated_feed_binary_change_to_captures_is_refused(self):
        # numstat reports "-" for binary content; it must not count as zero deletions.
        governance, remote, cli = self.feed_fixture(
            'captures.write_bytes(captures.read_bytes() + b"\\x00\\x01" + block.encode())\n')
        self.assert_feed_blocked(governance, remote, cli, "binary change")

    def test_isolated_feed_git_status_failure_blocks_instead_of_no_changes(self):
        governance, remote, cli = self.feed_fixture(
            'captures.write_text(captures.read_text() + block)\n')
        real_git = shutil.which("git")
        stubs = self.base / "stubs"
        stub = self.write(stubs / "git", f"#!/bin/sh\n"
            'for a in "$@"; do [ "$a" = status ] && exit 1; done\n'
            f'exec {real_git} "$@"\n')
        stub.chmod(0o700)
        self.assert_feed_blocked(governance, remote, cli, "git status failed in feed worktree",
                                 variables={"PATH": f"{stubs}:{os.environ['PATH']}"})

    def test_isolated_feed_foreign_mode_marker_is_refused(self):
        governance, remote, cli = self.feed_fixture(
            'captures.write_text(captures.read_text() + block.replace("git-diff", "session-close"))\n')
        self.assert_feed_blocked(governance, remote, cli, "for this mode")

    def test_isolated_feed_marker_outside_block_heading_is_refused(self):
        governance, remote, cli = self.feed_fixture(
            'captures.write_text(captures.read_text() + "quoted [feed:git-diff 2026-09-12] in prose\\n")\n')
        self.assert_feed_blocked(governance, remote, cli, "for this mode")

    def test_isolated_session_close_feed_accepts_its_own_marker(self):
        governance, remote, cli = self.feed_fixture(
            'captures.write_text(captures.read_text() + block.replace("git-diff", "session-close"))\n')
        self.run_feed(cli, label="session-close", prompt="session-close-feed")
        self.assertIn("[feed:session-close 2026-09-12]", self.git(remote, "show", "main:inbox/captures/2026-09.md"))
        self.assertTrue(self.git(remote, "log", "-1", "--format=%s", "main").startswith("feed(session-close):"))

    def test_isolated_feed_alias_symlink_to_governance_is_not_linked(self):
        governance, remote, cli = self.feed_fixture(
            'assert not Path("DS-alias").exists(), "alias of the frozen canon must not be linked"\n'
            'captures.write_text(captures.read_text() + block)\n')
        (self.workspace / "DS-alias").symlink_to(governance)
        head_before = self.git(governance, "rev-parse", "HEAD")
        result = self.run_feed(cli)
        self.assertEqual(result.returncode, 0)
        self.assertIn("[feed:git-diff", self.git(remote, "show", "main:inbox/captures/2026-09.md"))
        self.assert_canonical_untouched(governance, head_before)
        self.assertTrue((self.workspace / "DS-alias").is_symlink())

    def test_create_isolated_worktree_failure_removes_run_directory(self):
        governance, _, _ = self.published_repo("DS-fixture", {"README.md": "x\n"})
        result = self.shell(f'create_isolated_worktree {shlex.quote(str(governance))} DS-fixture no-such-branch feed', check=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.leftover_feed_dirs(), [])

    def test_feed_subcommands_use_isolated_mode_and_prompts_do_not_self_commit(self):
        text = RUNNER.read_text()
        self.assertIn('run_feed_isolated "session-close-feed"', text)
        self.assertIn('run_feed_isolated "git-diff-feed"', text)
        self.assertNotIn('run_claude "session-close-feed"', text)
        self.assertNotIn('run_claude "git-diff-feed"', text)
        # Both feeders keep the shared lock.
        self.assertEqual(text.count('trap \'release_inbox_lock "$feed_lock_dir"'), 2)
        prompts = ROOT / "roles/extractor/prompts"
        self.assertNotIn("git add inbox", (prompts / "session-close-feed.md").read_text())
        self.assertNotIn("git commit -m", (prompts / "session-close-feed.md").read_text())

    # --- isolated knowledge audit (audit / audit-scheduled): read-only contract --

    def audit_fixture(self, agent_body):
        """Canonical DS-fixture + a Pack; fake CLI = the audit agent."""
        self.make_pack()
        governance, _, remote = self.published_repo("DS-fixture", {
            "README.md": "fixture\n",
            "inbox/captures/2026-09.md": "# Captures 2026-09\n### Pending [feed:git-diff 2026-09-01]\n",
            "inbox/extraction-reports/2026-09-01-inbox-check.md": "old report\n",
        })
        cli = self.write(self.base / "fake-audit-cli", f"#!{sys.executable}\n" + """from pathlib import Path
import subprocess
import sys
assert Path("PACK-fixture").is_symlink(), "Packs must be readable in the audit workspace"
assert Path("DS-fixture").is_symlink()
assert "Scope: только Pack 'PACK-fixture'" in sys.argv[-1]
assert "Не выполняй git add/commit/push" in sys.argv[-1]
assert "аудит только читает" in sys.argv[-1]
repo = Path("DS-fixture")
print("Knowledge Audit Report (printed, not written)")
""" + agent_body)
        cli.chmod(0o700)
        return governance, remote, cli

    def run_audit(self, cli, *, check=True, variables=None):
        scope = "Scope: только Pack 'PACK-fixture' (headless)"
        return self.shell(f'run_feed_isolated knowledge-audit {shlex.quote(scope)} audit isolated-audit', variables={
            "AI_CLI": str(cli), "AI_CLI_PROMPT_FLAG": "-p", "AI_CLI_EXTRA_FLAGS": "",
            **(variables or {}),
        }, check=check)

    def leftover_audit_dirs(self):
        return list((self.base / "runs").glob("iwe-extractor-audit.*"))

    def test_isolated_audit_clean_tree_is_success_without_commit(self):
        governance, remote, cli = self.audit_fixture("pass\n")
        head_before = self.git(governance, "rev-parse", "HEAD")
        before = self.git(remote, "rev-parse", "main")
        result = self.run_audit(cli)
        self.assertEqual(result.returncode, 0)
        self.assertIn("governance tree is clean", result.stdout)
        self.assertIn("Completed process: knowledge-audit (no_changes)", result.stdout)
        self.assertEqual(self.git(remote, "rev-parse", "main"), before)
        self.assert_canonical_untouched(governance, head_before)
        self.assertEqual(self.leftover_audit_dirs(), [])
        self.assertEqual(self.git(governance, "worktree", "list").count("\n"), 0)
        self.assertEqual(self.git(governance, "branch", "--list", "extractor/audit-*"), "")
        self.assertTrue((self.workspace / "PACK-fixture/pack/known.md").exists())
        self.assertTrue((self.workspace / "PACK-fixture/.git").exists())

    def assert_audit_blocked(self, governance, remote, cli, expected_message, variables=None):
        head_before = self.git(governance, "rev-parse", "HEAD")
        before = self.git(remote, "rev-parse", "main")
        result = self.run_audit(cli, check=False, variables=variables)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(expected_message, result.stdout)
        self.assertNotIn("Completed process:", result.stdout)
        self.assertEqual(self.git(remote, "rev-parse", "main"), before)
        self.assert_canonical_untouched(governance, head_before)
        # Nothing is lost: the worktree is preserved for review.
        self.assertEqual(len(self.leftover_audit_dirs()), 1)

    def test_isolated_audit_new_file_blocks_publication(self):
        # Even a well-meant report file is a change: the audit is read-only.
        governance, remote, cli = self.audit_fixture(
            '(repo / "inbox/extraction-reports").mkdir(exist_ok=True)\n'
            '(repo / "inbox/extraction-reports/2026-09-12-knowledge-audit.md").write_text("report\\n")\n')
        self.assert_audit_blocked(governance, remote, cli, "read-only contract): inbox/extraction-reports/2026-09-12-knowledge-audit.md")

    def test_isolated_audit_changed_captures_blocks_publication(self):
        governance, remote, cli = self.audit_fixture(
            '(repo / "inbox/captures/2026-09.md").write_text("# Captures 2026-09\\n### Pending [analyzed 2026-09-12]\\n")\n')
        self.assert_audit_blocked(governance, remote, cli, "read-only contract): inbox/captures/2026-09.md")

    def test_isolated_audit_changed_readme_blocks_publication(self):
        governance, remote, cli = self.audit_fixture('(repo / "README.md").write_text("edited\\n")\n')
        self.assert_audit_blocked(governance, remote, cli, "read-only contract): README.md")

    def test_isolated_audit_deleted_file_blocks_publication(self):
        governance, remote, cli = self.audit_fixture('(repo / "README.md").unlink()\n')
        self.assert_audit_blocked(governance, remote, cli, "read-only contract): README.md")

    def test_isolated_audit_agent_self_commit_is_normalised_and_blocks(self):
        # The agent commits despite the ban: reset --mixed exposes the change, nothing is published.
        governance, remote, cli = self.audit_fixture(
            '(repo / "README.md").write_text("committed by the agent\\n")\n'
            'subprocess.run(["git", "-C", "DS-fixture", "add", "--", "README.md"], check=True)\n'
            'subprocess.run(["git", "-C", "DS-fixture", "commit", "-m", "agent self-commit"], check=True)\n')
        self.assert_audit_blocked(governance, remote, cli, "read-only contract): README.md")

    def test_isolated_audit_cli_failure_publishes_nothing(self):
        governance, remote, cli = self.audit_fixture("sys.exit(3)\n")
        self.assert_audit_blocked(governance, remote, cli, "AI CLI failed")

    def test_isolated_audit_git_status_failure_blocks_instead_of_clean(self):
        governance, remote, cli = self.audit_fixture("pass\n")
        real_git = shutil.which("git")
        stubs = self.base / "stubs"
        stub = self.write(stubs / "git", f"#!/bin/sh\n"
            'for a in "$@"; do [ "$a" = status ] && exit 1; done\n'
            f'exec {real_git} "$@"\n')
        stub.chmod(0o700)
        self.assert_audit_blocked(governance, remote, cli, "git status failed in audit worktree",
                                  variables={"PATH": f"{stubs}:{os.environ['PATH']}"})

    def test_audit_subcommands_use_isolated_mode(self):
        text = RUNNER.read_text()
        self.assertEqual(text.count('run_feed_isolated "knowledge-audit"'), 2)
        self.assertNotIn('run_claude "knowledge-audit"', text)
        self.assertIn('"audit-scheduled")', text)
        self.assertIn("audit-scheduled requires a Pack name", text)


if __name__ == "__main__":
    unittest.main()
