#!/usr/bin/env python3
"""Exercise Day Open's Git helpers with real local repositories (issue #1245).

Extract only the production helper definitions: running the full pipeline would
render real plans, load credentials and send notifications. No helper is mocked.
"""
import os
import json
from datetime import datetime
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
PIPELINE = ROOT / "scripts/day-open-pipeline.sh"


class DayOpenGitTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="day-open-no-autostash-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.origin = self.root / "origin.git"
        self.repo = self.root / "source"
        self.git(self.root, "init", "--bare", "--quiet", str(self.origin))
        self.git(self.root, "clone", "--quiet", str(self.origin), str(self.repo))
        self.git(self.repo, "checkout", "-qb", "main")
        self.configure(self.repo)
        (self.repo / "shared.txt").write_text("base\n")
        self.git(self.repo, "add", "shared.txt")
        self.git(self.repo, "commit", "-qm", "base")
        self.git(self.repo, "push", "-qu", "origin", "main")
        self.git(self.origin, "symbolic-ref", "HEAD", "refs/heads/main")
        self.env = dict(os.environ, IWE_WORKSPACE=str(self.root),
                        IWE_ROOT=str(self.root), IWE_GOVERNANCE_REPO="source",
                        IWE_SCRIPTS=str(ROOT / "scripts"))
        self.env["DAY_OPEN_STATE_DIR"] = str(self.root / "state")
        source = PIPELINE.read_text()
        definitions = [match.group() for match in re.finditer(
            r"^day_open_\w+\(\) \{\n.*?^\}\n", source, re.MULTILINE | re.DOTALL)]
        names = {re.match(r"day_open_\w+", d).group() for d in definitions}
        for required in ("day_open_fast_forward", "day_open_publish",
                         "day_open_isolated_push", "day_open_pending_clear"):
            self.assertIn(required, names, required + " production helper missing")
        self.helpers = self.root / "helpers.sh"
        # `published` reports the SHA the production helper recorded as published.
        self.helpers.write_text(
            "set -uo pipefail\n" + "\n".join(definitions)
            + '\npublished() { day_open_publish "$@" && printf "published=%s\\n" "$DAY_OPEN_PUBLISHED_SHA"; }\n"$@"\n')

    @staticmethod
    def git(repo, *args, check=True):
        return subprocess.run(["git", "-C", str(repo), *args], check=check,
                              capture_output=True).stdout

    def configure(self, repo):
        self.git(repo, "config", "user.name", "Test")
        self.git(repo, "config", "user.email", "test@example.invalid")
        self.git(repo, "config", "merge.autoStash", "true")
        self.git(repo, "config", "rebase.autoStash", "true")
        self.git(repo, "config", "status.showUntrackedFiles", "no")

    def advance_remote(self):
        other = self.root / "other"
        self.git(self.root, "clone", "-q", str(self.origin), str(other))
        self.configure(other)
        (other / "shared.txt").write_text("remote\n")
        self.git(other, "commit", "-qam", "remote")
        self.git(other, "push", "-q")

    PLAN = "current/DayPlan 2000-01-01.md"

    def commit_plan(self, text="DayPlan\n"):
        (self.repo / "current").mkdir(exist_ok=True)
        (self.repo / self.PLAN).write_text(text)
        self.git(self.repo, "add", self.PLAN)
        self.git(self.repo, "commit", "-qm", "DayPlan")
        return self.head()

    def head(self, repo=None):
        return self.git(repo or self.repo, "rev-parse", "HEAD").decode().strip()

    def origin_main(self):
        return self.git(self.origin, "rev-parse", "main").decode().strip()

    def pending(self):
        path = self.root / "state/day-open-pending-publish.list"
        return path.read_text() if path.exists() else ""

    def published_sha(self, result):
        lines = [l for l in result.stdout.splitlines() if l.startswith("published=")]
        self.assertEqual(1, len(lines), result.stdout + result.stderr)
        return lines[0].split("=", 1)[1]

    def dirty(self):
        (self.repo / "shared.txt").write_text("staged work\n")
        self.git(self.repo, "add", "shared.txt")
        (self.repo / "shared.txt").write_text("unstaged work\n")
        (self.repo / "draft.md").write_text("new work\n")

    def snapshot(self):
        return (self.git(self.repo, "rev-parse", "HEAD"),
                self.git(self.repo, "ls-files", "--stage", "-z"),
                self.git(self.repo, "rev-parse", "--verify", "refs/stash", check=False),
                {str(p.relative_to(self.repo)): p.read_bytes()
                 for p in self.repo.rglob("*")
                 if ".git" not in p.relative_to(self.repo).parts and p.is_file()})

    def run_helper(self, name, *args):
        return subprocess.run(["bash", str(self.helpers), name, str(self.repo), *args],
                              env=self.env, capture_output=True, text=True)

    def test_clean_sync_fast_forwards(self):
        self.advance_remote()
        result = self.run_helper("day_open_fast_forward")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(self.git(self.origin, "rev-parse", "main"),
                         self.git(self.repo, "rev-parse", "HEAD"))
        self.assertEqual(b"", self.git(self.repo, "stash", "list"))

    def test_sync_refreshes_main_with_restricted_fetch_mapping(self):
        self.advance_remote()
        self.git(self.repo, "config", "remote.origin.fetch",
                 "+refs/heads/topic:refs/remotes/origin/topic")
        result = self.run_helper("day_open_fast_forward")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(self.git(self.origin, "rev-parse", "main"),
                         self.git(self.repo, "rev-parse", "HEAD"))

    def test_fetch_does_not_apply_extra_local_branch_mapping(self):
        self.git(self.repo, "checkout", "-qb", "local-work")
        local_commit = self.commit_plan()
        self.git(self.repo, "checkout", "-q", "main")
        self.advance_remote()
        self.git(self.repo, "config", "remote.origin.fetch",
                 "+refs/heads/main:refs/heads/local-work")
        result = self.run_helper("day_open_fast_forward")
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual((local_commit + "\n").encode(),
                         self.git(self.repo, "rev-parse", "local-work"))
        self.assertEqual(self.git(self.origin, "rev-parse", "main"),
                         self.git(self.repo, "rev-parse", "HEAD"))

    def test_dirty_sync_preserves_staged_unstaged_and_hidden_untracked(self):
        self.advance_remote()
        self.dirty()
        before = self.snapshot()
        result = self.run_helper("day_open_fast_forward")
        self.assertNotEqual(0, result.returncode)
        self.assertEqual(before, self.snapshot())

    def test_untracked_only_sync_is_not_hidden_by_config(self):
        self.advance_remote()
        (self.repo / "draft.md").write_text("untracked\n")
        before = self.snapshot()
        self.assertNotEqual(0, self.run_helper("day_open_fast_forward").returncode)
        self.assertEqual(before, self.snapshot())

    def test_failed_status_never_allows_sync(self):
        self.advance_remote()
        before = self.snapshot()
        wrapper_dir = self.root / "bin"
        wrapper_dir.mkdir()
        wrapper = wrapper_dir / "git"
        wrapper.write_text('#!/usr/bin/env python3\nimport os,sys\n'
                           'if "status" in sys.argv[1:]: sys.exit(70)\n'
                           'os.execv(' + repr(shutil.which("git"))
                           + ', ["git", *sys.argv[1:]])\n')
        wrapper.chmod(0o755)
        self.env["PATH"] = str(wrapper_dir) + os.pathsep + self.env["PATH"]
        self.assertNotEqual(0, self.run_helper("day_open_fast_forward").returncode)
        self.assertEqual(before, self.snapshot())

    def equivalent_on_origin(self, sha):
        """True when origin/main carries sha's change (same commit or cherry-picked twin)."""
        self.git(self.repo, "fetch", "-q", "origin", "main")
        cherry = self.git(self.repo, "cherry", "FETCH_HEAD", sha, sha + "^").decode()
        return "+" not in cherry

    def install_origin_shift_hook(self, shifts):
        """pre-push hook: the first `shifts` pushes see origin move just before they land."""
        counter = self.root / "shift-count"
        counter.write_text("0")
        hook = self.repo / ".git/hooks/pre-push"
        hook.write_text(
            "#!/bin/bash\n"
            # Git exports GIT_DIR to hooks; without this `git -C origin` would hit the pusher's repo.
            "unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE\n"
            f"n=$(cat '{counter}')\n"
            f'if [ "$n" -lt {shifts} ]; then\n'
            f"  echo $((n + 1)) > '{counter}'\n"
            f"  tree=$(git -C '{self.origin}' rev-parse 'main^{{tree}}')\n"
            f"  new=$(git -C '{self.origin}' commit-tree \"$tree\" -p main -m \"shift $n\")\n"
            f"  git -C '{self.origin}' update-ref refs/heads/main \"$new\"\n"
            "fi\n")
        hook.chmod(0o755)
        return counter

    def test_publish_uses_plain_push_when_origin_has_not_moved(self):
        commit = self.commit_plan()
        self.dirty()
        before = self.snapshot()
        result = self.run_helper("published", commit)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(commit, self.published_sha(result))
        self.assertEqual(commit, self.origin_main())
        self.assertEqual("", self.pending())
        self.assertEqual(before, self.snapshot())

    def test_dirty_tree_and_moved_origin_publish_from_isolated_copy(self):
        self.advance_remote()
        commit = self.commit_plan()
        self.dirty()
        before = self.snapshot()
        result = self.run_helper("published", commit)
        self.assertEqual(0, result.returncode, result.stderr)
        published = self.published_sha(result)
        self.assertEqual(published, self.origin_main())
        self.assertNotEqual(commit, published)
        self.assertEqual(b"DayPlan\n", self.git(self.origin, "show", published + ":" + self.PLAN))
        self.assertTrue(self.equivalent_on_origin(commit))
        self.assertEqual("", self.pending())
        self.assertEqual(before, self.snapshot())
        self.assertEqual(b"", self.git(self.repo, "stash", "list"))
        worktrees = self.git(self.repo, "worktree", "list", "--porcelain").decode()
        self.assertEqual(1, worktrees.count("worktree "), worktrees)

    def test_second_origin_shift_before_push_is_retried(self):
        self.advance_remote()
        commit = self.commit_plan()
        counter = self.install_origin_shift_hook(2)
        result = self.run_helper("published", commit)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual("2", counter.read_text().strip())
        self.assertEqual(self.published_sha(result), self.origin_main())
        self.assertTrue(self.equivalent_on_origin(commit))
        self.assertEqual("", self.pending())

    def test_network_failure_keeps_the_commit_recorded_and_retry_publishes(self):
        self.advance_remote()
        commit = self.commit_plan()
        self.dirty()
        good_url = self.git(self.repo, "remote", "get-url", "origin").decode().strip()
        self.git(self.repo, "remote", "set-url", "origin", str(self.root / "missing.git"))
        before = self.snapshot()
        failed = self.run_helper("published", commit)
        self.assertNotEqual(0, failed.returncode)
        self.assertIn("preserved", failed.stderr)
        self.assertIn(commit, self.pending())
        self.assertEqual(before, self.snapshot())
        self.git(self.repo, "remote", "set-url", "origin", good_url)
        retry = self.run_helper("published")
        self.assertEqual(0, retry.returncode, retry.stderr)
        self.assertEqual(self.published_sha(retry), self.origin_main())
        self.assertTrue(self.equivalent_on_origin(commit))
        self.assertEqual("", self.pending())
        self.assertEqual(before, self.snapshot())

    def test_same_file_conflict_is_refused_without_choosing_a_side(self):
        other = self.root / "other"
        self.git(self.root, "clone", "-q", str(self.origin), str(other))
        self.configure(other)
        (other / "current").mkdir()
        (other / self.PLAN).write_text("remote plan\n")
        self.git(other, "add", self.PLAN)
        self.git(other, "commit", "-qm", "remote plan")
        self.git(other, "push", "-q")
        remote = self.origin_main()
        commit = self.commit_plan("local plan\n")
        self.dirty()
        before = self.snapshot()
        result = self.run_helper("published", commit)
        self.assertNotEqual(0, result.returncode)
        self.assertIn("conflict", result.stderr)
        self.assertIn("DayPlan 2000-01-01.md", result.stderr)
        self.assertEqual(remote, self.origin_main())
        self.assertEqual(b"remote plan\n", self.git(self.origin, "show", "main:" + self.PLAN))
        self.assertIn(commit, self.pending())
        self.assertEqual(before, self.snapshot())

    def test_only_the_recorded_commit_is_published_not_foreign_local_work(self):
        (self.repo / "foreign.txt").write_text("another agent\n")
        self.git(self.repo, "add", "foreign.txt")
        self.git(self.repo, "commit", "-qm", "foreign local commit")
        foreign = self.head()
        commit = self.commit_plan()
        result = self.run_helper("published", commit)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(b"DayPlan\n", self.git(self.origin, "show", "main:" + self.PLAN))
        self.assertEqual(b"", self.git(self.origin, "ls-tree", "-r", "--name-only", "main", "foreign.txt"))
        self.assertEqual(foreign, self.git(self.repo, "rev-parse", commit + "^").decode().strip())
        self.assertEqual(commit, self.head())

    def test_commit_touching_other_paths_is_never_published(self):
        (self.repo / "shared.txt").write_text("not a plan\n")
        self.git(self.repo, "commit", "-qam", "edit shared file")
        commit = self.head()
        remote = self.origin_main()
        result = self.run_helper("published", commit)
        self.assertNotEqual(0, result.returncode)
        self.assertIn("outside DayPlan", result.stderr)
        self.assertEqual(remote, self.origin_main())
        self.assertEqual("", self.pending())

    def test_receipt_lost_after_push_is_recovered_without_a_new_commit(self):
        self.advance_remote()
        commit = self.commit_plan()
        first = self.run_helper("published", commit)
        self.assertEqual(0, first.returncode, first.stderr)
        tip = self.origin_main()
        count = self.git(self.origin, "rev-list", "--count", "main")
        again = self.run_helper("published", commit)
        self.assertEqual(0, again.returncode, again.stderr)
        self.assertEqual(tip, self.published_sha(again))
        self.assertEqual(tip, self.origin_main())
        self.assertEqual(count, self.git(self.origin, "rev-list", "--count", "main"))

    def test_ambiguous_destination_is_rejected_before_any_write(self):
        commit = self.commit_plan()
        remote = self.origin_main()
        self.git(self.repo, "config", "branch.main.pushRemote", "elsewhere")
        pushed = self.run_helper("published", commit)
        self.assertNotEqual(0, pushed.returncode)
        self.assertIn("push remote", pushed.stderr)
        self.git(self.repo, "config", "--unset", "branch.main.pushRemote")
        self.git(self.repo, "config", "branch.main.remote", ".")
        local = self.run_helper("published", commit)
        self.assertNotEqual(0, local.returncode)
        self.assertIn("not a configured remote", local.stderr)
        self.assertEqual(remote, self.origin_main())
        self.assertEqual("", self.pending())

    def test_push_preserves_configured_topic_destination(self):
        main = self.git(self.origin, "rev-parse", "main")
        self.git(self.repo, "checkout", "-qb", "topic")
        self.git(self.repo, "push", "-qu", "origin", "topic")
        commit = self.commit_plan()
        result = self.run_helper("published", commit)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(main, self.git(self.origin, "rev-parse", "main"))
        self.assertEqual((commit + "\n").encode(), self.git(self.origin, "rev-parse", "topic"))

    def test_ignored_collision_preserves_local_bytes(self):
        (self.repo / ".gitignore").write_text("draft.md\n")
        self.git(self.repo, "add", ".gitignore")
        self.git(self.repo, "commit", "-qm", "ignore local draft")
        self.git(self.repo, "push", "-q")
        self.advance_remote()
        other = self.root / "other"
        (other / "draft.md").write_text("remote file\n")
        self.git(other, "add", "-f", "draft.md")
        self.git(other, "commit", "-qm", "new tracked file")
        self.git(other, "push", "-q")
        (self.repo / "draft.md").write_bytes(b"local ignored\x00draft\n")
        before = self.snapshot()
        self.assertNotEqual(0, self.run_helper("day_open_fast_forward").returncode)
        self.assertEqual(before, self.snapshot())

    def run_dashboard_sync(self):
        source = PIPELINE.read_text()
        start = source.index('if [ -d "$PD_DASHBOARD_DIR/.git" ]; then')
        block = source[start:source.index("\nFILL_ERR_TMP=", start)]
        script = self.root / "dashboard-sync.sh"
        script.write_text(self.helpers.read_text().replace('\n"$@"\n', "\n")
                          + 'PD_DASHBOARD_DIR="$1"\nDAY_OPEN_LOG="$2"\n'
                          + block)
        return subprocess.run(["bash", str(script), str(self.repo),
                               str(self.root / "dashboard.log")],
                              env=self.env, capture_output=True, text=True)

    def test_dashboard_caller_preserves_dirty_work(self):
        self.advance_remote()
        self.dirty()
        before = self.snapshot()
        result = self.run_dashboard_sync()
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("safe update skipped", result.stdout)
        self.assertEqual(before, self.snapshot())

    def test_dashboard_caller_uses_configured_remote(self):
        self.advance_remote()
        self.git(self.repo, "remote", "rename", "origin", "dashboard")
        result = self.run_dashboard_sync()
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(self.git(self.origin, "rev-parse", "main"),
                         self.git(self.repo, "rev-parse", "HEAD"))

    def commit_today_plan(self):
        day = datetime.now().astimezone().strftime("%Y-%m-%d")
        (self.repo / "current").mkdir()
        plan = "current/DayPlan " + day + ".md"
        (self.repo / plan).write_text("preserve this plan\n")
        self.git(self.repo, "add", plan)
        self.git(self.repo, "commit", "-qm", "today plan")
        return day

    def run_dedup(self, day):
        source = PIPELINE.read_text()
        start = source.index("# --- Guard: already published today")
        block = source[start:source.index("# Notify pilot that pipeline has started", start)]
        # Redirect only the receipt directory; run the production guard and Git.
        block = block.replace("$HOME/.claude/state", "$TEST_STATE")
        script = self.root / "dedup.sh"
        script.write_text(self.helpers.read_text().replace('\n"$@"\n', "\n")
                          + 'FORCE=false\nDS_STRATEGY="$1"\n'
                          'DATE="$2"\nTEST_STATE="$3"\n'
                          'tg_notify() { echo "$1"; }\n'
                          + block + '\necho generation-next\n')
        return subprocess.run(["bash", str(script), str(self.repo), day,
                               str(self.root / "receipts")],
                              env=self.env, capture_output=True, text=True)

    def test_local_plan_is_published_by_the_guard_without_regeneration(self):
        self.advance_remote()
        day = self.commit_today_plan()
        local = self.head()
        self.dirty()
        before = self.snapshot()
        result = self.run_dedup(day)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertNotIn("generation-next", result.stdout)
        receipt = json.loads((self.root / "receipts/day-open-pipeline-last-success.json").read_text())
        self.assertEqual("success", receipt["status"])
        self.assertEqual(self.origin_main(), receipt["commit_hash"])
        self.assertNotEqual(local, receipt["commit_hash"])
        self.assertEqual(b"preserve this plan\n", self.git(
            self.origin, "show", "main:current/DayPlan " + day + ".md"))
        self.assertEqual(before, self.snapshot())

    def test_local_plan_that_cannot_be_published_never_records_success(self):
        self.advance_remote()
        day = self.commit_today_plan()
        local = self.head()
        self.git(self.repo, "remote", "set-url", "origin", str(self.root / "missing.git"))
        before = self.snapshot()
        result = self.run_dedup(day)
        self.assertEqual(1, result.returncode, result.stderr)
        self.assertNotIn("generation-next", result.stdout)
        self.assertFalse((self.root / "receipts").exists())
        self.assertIn(local, self.pending())
        self.assertEqual(before, self.snapshot())

    def test_published_plan_records_success(self):
        day = self.commit_today_plan()
        self.git(self.repo, "push", "-q")
        result = self.run_dedup(day)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertNotIn("generation-next", result.stdout)
        receipt = json.loads((self.root / "receipts/day-open-pipeline-last-success.json").read_text())
        self.assertEqual("success", receipt["status"])
        self.assertEqual(day, receipt["date"])
        self.assertEqual(self.git(self.origin, "rev-parse", "main").decode().strip(),
                         receipt["commit_hash"])

    def test_stale_remote_ref_is_not_publication_proof(self):
        day = self.commit_today_plan()
        self.git(self.repo, "push", "-q")
        self.git(self.repo, "remote", "set-url", "origin", str(self.root / "missing.git"))
        before = self.snapshot()
        result = self.run_dedup(day)
        self.assertEqual(1, result.returncode, result.stderr)
        self.assertFalse((self.root / "receipts").exists())
        self.assertEqual(before, self.snapshot())

    def test_dedup_refreshes_main_with_restricted_fetch_mapping(self):
        day = self.commit_today_plan()
        self.git(self.repo, "push", "-q")
        # Disposable bare remote rolls back; the local tracking ref is now stale.
        parent = self.git(self.origin, "rev-parse", "main^").decode().strip()
        self.git(self.origin, "update-ref", "refs/heads/main", parent)
        self.git(self.repo, "config", "remote.origin.fetch",
                 "+refs/heads/topic:refs/remotes/origin/topic")
        before = self.snapshot()
        result = self.run_dedup(day)
        # The rolled-back remote no longer holds the plan: the refreshed state
        # shows it unpublished, so the guard publishes it instead of trusting the stale ref.
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertNotIn("generation-next", result.stdout)
        receipt = json.loads((self.root / "receipts/day-open-pipeline-last-success.json").read_text())
        self.assertEqual(self.origin_main(), receipt["commit_hash"])
        self.assertEqual(b"preserve this plan\n", self.git(
            self.origin, "show", "main:current/DayPlan " + day + ".md"))
        self.assertEqual(before, self.snapshot())
        self.assertEqual((parent + "\n").encode(),
                         self.git(self.repo, "rev-parse", "origin/main"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
