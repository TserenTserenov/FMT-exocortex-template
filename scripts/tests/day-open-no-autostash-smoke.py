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
import time
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
        self.env["TG_LOG"] = str(self.root / "tg.log")
        self.env["TG_ATTEMPTS"] = str(self.root / "tg-attempts.log")
        source = PIPELINE.read_text()
        definitions = [match.group() for match in re.finditer(
            r"^day_open_\w+\(\) \{\n.*?^\}\n", source, re.MULTILINE | re.DOTALL)]
        names = {re.match(r"day_open_\w+", d).group() for d in definitions}
        for required in ("day_open_fast_forward", "day_open_publish",
                         "day_open_isolated_push", "day_open_adopt_twins"):
            self.assertIn(required, names, required + " production helper missing")
        self.helpers = self.root / "helpers.sh"
        # `published` reports the SHA the production helper recorded as published.
        self.helpers.write_text(
            "set -uo pipefail\n" + "\n".join(definitions)
            + '\npublished() { day_open_publish "$@" && printf "published=%s\\n" "$DAY_OPEN_PUBLISHED_SHA"; }\n'
            + 'isolated() { day_open_isolated_push "$@"; local rc=$?; printf "published=%s\\n" "$DAY_OPEN_PUBLISHED_SHA"; return $rc; }\n'
            + 'tg_notify() { printf "%s\\n" "$2" >> "$TG_ATTEMPTS"; [ "${TG_RC:-0}" -eq 0 ] || return 1; printf "%s\\t%s\\n" "$2" "$1" >> "$TG_LOG"; }\n'
            + 'adopt() { day_open_adopt_twins "$@"; }\n'
            + 'prune() { day_open_prune_superseded "$@"; }\n"$@"\n')

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

    def commit_plan(self, text="DayPlan\n", plan=None):
        plan = plan or self.PLAN
        (self.repo / "current").mkdir(exist_ok=True)
        (self.repo / plan).write_text(text)
        self.git(self.repo, "add", plan)
        # Pathspec: unrelated staged work must never ride along in the plan commit.
        self.git(self.repo, "commit", "-qm", "DayPlan", "--", plan)
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
        self.assertIn(commit, result.stderr)
        self.assertIn("DayPlan 2000-01-01.md", result.stderr)
        self.assertIn("removed from the publication list", result.stderr)
        self.assertEqual(remote, self.origin_main())
        self.assertEqual(b"remote plan\n", self.git(self.origin, "show", "main:" + self.PLAN))
        self.assertEqual("", self.pending())
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

    def ahead_behind(self):
        """(local-only, origin-only) commit counts against a freshly fetched origin/main."""
        self.git(self.repo, "fetch", "-q", "origin", "main")
        out = self.git(self.repo, "rev-list", "--left-right", "--count", "HEAD...FETCH_HEAD")
        ahead, behind = out.decode().split()
        return int(ahead), int(behind)

    def shift_origin(self, name, text="remote\n"):
        """Another machine pushes a commit adding file `name`."""
        other = self.root / "other"
        if other.exists():
            self.git(other, "pull", "-q", "--ff-only")
        else:
            self.git(self.root, "clone", "-q", str(self.origin), str(other))
            self.configure(other)
        (other / name).write_text(text)
        self.git(other, "add", name)
        self.git(other, "commit", "-qm", "remote " + name)
        self.git(other, "push", "-q")

    def work_state(self, paths):
        """Observable local work: staged and unstaged diffs plus bytes of untracked files."""
        return (self.git(self.repo, "diff", "--", "notes.txt"),
                self.git(self.repo, "diff", "--cached", "--", "notes.txt"),
                {p: (self.repo / p).read_bytes() for p in paths})

    def test_three_days_in_a_row_leave_the_checkout_in_sync_with_origin(self):
        (self.repo / "notes.txt").write_text("notes\n")
        self.git(self.repo, "add", "notes.txt")
        self.git(self.repo, "commit", "-qm", "notes")
        self.git(self.repo, "push", "-q")
        drafts = []
        for day in (1, 2, 3):
            self.shift_origin("remote-%d.txt" % day)
            plan = "current/DayPlan 2000-01-0%d.md" % day
            commit = self.commit_plan("plan %d\n" % day, plan)
            (self.repo / "notes.txt").write_text("staged %d\n" % day)
            self.git(self.repo, "add", "notes.txt")
            (self.repo / "notes.txt").write_text("unstaged %d\n" % day)
            drafts.append("draft-%d.md" % day)
            (self.repo / drafts[-1]).write_text("untracked %d\n" % day)
            before = self.work_state(drafts)
            result = self.run_helper("published", commit)
            self.assertEqual(0, result.returncode, "day %d: %s" % (day, result.stderr))
            self.assertEqual((0, 0), self.ahead_behind(), "day %d diverged" % day)
            self.assertEqual(self.published_sha(result), self.head())
            self.assertEqual(before, self.work_state(drafts), "day %d lost work" % day)
            self.assertTrue((self.repo / ("remote-%d.txt" % day)).exists())
            self.assertEqual("", self.pending())
        self.assertEqual(b"plan 3\n", self.git(self.origin, "show", "main:current/DayPlan 2000-01-03.md"))
        self.assertEqual(b"", self.git(self.repo, "stash", "list"))

    def close_yesterday_elsewhere(self):
        """Day Close on the other machine archived yesterday's plan with different content."""
        yesterday = "current/DayPlan 2000-01-01.md"
        archived = "archive/day-plans/DayPlan 2000-01-01.md"
        (self.repo / "current").mkdir(exist_ok=True)
        (self.repo / yesterday).write_text("yesterday\n")
        self.git(self.repo, "add", yesterday)
        self.git(self.repo, "commit", "-qm", "yesterday plan")
        self.git(self.repo, "push", "-q")
        other = self.root / "other"
        self.git(self.root, "clone", "-q", str(self.origin), str(other))
        self.configure(other)
        (other / "archive/day-plans").mkdir(parents=True)
        self.git(other, "mv", yesterday, archived)
        (other / archived).write_text("closed on the other machine\n")
        self.git(other, "add", archived)
        self.git(other, "commit", "-qm", "day close")
        self.git(other, "push", "-q")
        (self.repo / "archive/day-plans").mkdir(parents=True)
        self.git(self.repo, "mv", yesterday, archived)
        return yesterday, archived

    def test_day_close_elsewhere_does_not_block_todays_plan(self):
        _, archived = self.close_yesterday_elsewhere()
        today = "current/DayPlan 2000-01-02.md"
        (self.repo / today).write_text("today\n")
        self.git(self.repo, "add", today)
        self.git(self.repo, "commit", "-qm", "day open")
        commit = self.head()
        result = self.run_helper("published", commit)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(b"today\n", self.git(self.origin, "show", "main:" + today))
        self.assertEqual(b"closed on the other machine\n",
                         self.git(self.origin, "show", "main:" + archived))
        self.assertEqual("", self.pending())
        self.assertEqual(commit, self.git(self.repo, "rev-parse", "refs/day-open/superseded/" + commit)
                         .decode().strip())
        self.assertEqual(self.origin_main(), self.head())

    def test_move_only_commit_is_already_published_by_the_other_machine(self):
        self.close_yesterday_elsewhere()
        self.git(self.repo, "commit", "-qm", "move only")
        commit = self.head()
        remote = self.origin_main()
        result = self.run_helper("published", commit)
        # Day Close elsewhere already did this move: nothing to push, nothing to keep.
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(remote, self.origin_main())
        self.assertEqual(remote, self.published_sha(result))
        self.assertEqual("", self.pending())
        self.assertEqual(b"closed on the other machine\n", self.git(
            self.origin, "show", "main:archive/day-plans/DayPlan 2000-01-01.md"))

    def test_three_days_with_day_close_on_the_other_machine(self):
        """Every morning the other machine has already archived (and edited) yesterday's plan."""
        (self.repo / "notes.txt").write_text("notes\n")
        (self.repo / "current").mkdir(exist_ok=True)
        (self.repo / "current/DayPlan 2000-01-00.md").write_text("plan 0\n")
        self.git(self.repo, "add", "notes.txt", "current/DayPlan 2000-01-00.md")
        self.git(self.repo, "commit", "-qm", "notes and plan 0")
        self.git(self.repo, "push", "-q")
        other = self.root / "other"
        self.git(self.root, "clone", "-q", str(self.origin), str(other))
        self.configure(other)
        drafts = []
        for day in (1, 2, 3):
            yesterday = "DayPlan 2000-01-0%d.md" % (day - 1)
            self.git(other, "pull", "-q", "--ff-only")
            (other / "archive/day-plans").mkdir(parents=True, exist_ok=True)
            self.git(other, "mv", "current/" + yesterday, "archive/day-plans/" + yesterday)
            (other / "archive/day-plans" / yesterday).write_text("closed with a summary %d\n" % day)
            self.git(other, "add", "archive/day-plans/" + yesterday)
            self.git(other, "commit", "-qm", "day close %d" % day)
            self.git(other, "push", "-q")
            # This machine still holds yesterday's plan in current/ and moves it itself.
            (self.repo / "archive/day-plans").mkdir(parents=True, exist_ok=True)
            self.git(self.repo, "mv", "current/" + yesterday, "archive/day-plans/" + yesterday)
            today = "current/DayPlan 2000-01-0%d.md" % day
            (self.repo / today).write_text("plan %d\n" % day)
            self.git(self.repo, "add", today)
            # Pathspec: the staged notes of the previous day must not ride along.
            self.git(self.repo, "commit", "-qm", "day open %d" % day, "--",
                     today, "current/" + yesterday, "archive/day-plans/" + yesterday)
            commit = self.head()
            (self.repo / "notes.txt").write_text("staged %d\n" % day)
            self.git(self.repo, "add", "notes.txt")
            (self.repo / "notes.txt").write_text("unstaged %d\n" % day)
            drafts.append("draft-%d.md" % day)
            (self.repo / drafts[-1]).write_text("untracked %d\n" % day)
            before = self.work_state(drafts)
            result = self.run_helper("published", commit)
            self.assertEqual(0, result.returncode, "day %d: %s" % (day, result.stderr))
            self.assertEqual((0, 0), self.ahead_behind(), "day %d diverged: %s" % (day, result.stderr))
            self.assertEqual(before, self.work_state(drafts), "day %d lost work" % day)
            self.assertEqual("", self.pending(), "day %d left records" % day)
            self.assertEqual(commit, self.git(self.repo, "rev-parse", "refs/day-open/superseded/" + commit)
                             .decode().strip(), "day %d: replaced commit is not kept by a ref" % day)
            self.assertEqual(("closed with a summary %d\n" % day).encode(), self.git(
                self.origin, "show", "main:archive/day-plans/" + yesterday))
            self.assertEqual(("plan %d\n" % day).encode(), self.git(self.origin, "show", "main:" + today))

    def isolated(self, target, commit):
        return self.run_helper("isolated", "origin", "refs/heads/main", target, commit)

    def test_empty_cherry_pick_counts_as_published_and_clears_the_list(self):
        commit = self.commit_plan()
        other = self.root / "other"
        self.git(self.root, "clone", "-q", str(self.origin), str(other))
        self.configure(other)
        (other / "current").mkdir()
        (other / self.PLAN).write_text("DayPlan\n")
        (other / "extra.txt").write_text("makes the patch-id differ\n")
        self.git(other, "add", self.PLAN, "extra.txt")
        self.git(other, "commit", "-qm", "same plan, different patch")
        self.git(other, "push", "-q")
        tip = self.origin_main()
        self.git(self.repo, "fetch", "-q", "origin", "main")
        before = self.snapshot()
        result = self.isolated(tip, commit)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("published=" + tip, result.stdout)
        self.assertEqual(tip, self.origin_main())
        self.assertEqual(before, self.snapshot())

    def test_salvaged_original_is_published_again_without_new_commits(self):
        _, archived = self.close_yesterday_elsewhere()
        today = "current/DayPlan 2000-01-02.md"
        (self.repo / today).write_text("today\n")
        self.git(self.repo, "add", today)
        self.git(self.repo, "commit", "-qm", "day open")
        commit = self.head()
        first = self.run_helper("published", commit)
        self.assertEqual(0, first.returncode, first.stderr)
        tip = self.origin_main()
        count = self.git(self.origin, "rev-list", "--count", "main")
        again = self.run_helper("published", commit)
        self.assertEqual(0, again.returncode, again.stderr)
        self.assertEqual(tip, self.origin_main())
        self.assertEqual(count, self.git(self.origin, "rev-list", "--count", "main"))
        self.assertEqual("", self.pending())

    def test_head_moved_during_adopt_is_not_rolled_back(self):
        self.advance_remote()
        commit = self.commit_plan()
        real_git = shutil.which("git")
        marker = self.root / "raced"
        wrapper_dir = self.root / "racing-bin"
        wrapper_dir.mkdir()
        wrapper = wrapper_dir / "git"
        wrapper.write_text(
            "#!/bin/bash\n"
            f"'{real_git}' \"$@\"\nrc=$?\n"
            # Another agent commits right after the tree was merged, before the ref moves.
            f"if [ \"$3\" = read-tree ] && [ ! -e '{marker}' ]; then\n"
            f"  touch '{marker}'\n"
            f"  '{real_git}' -C \"$2\" commit -q --allow-empty -m 'racing commit'\n"
            "fi\nexit $rc\n")
        wrapper.chmod(0o755)
        self.env["PATH"] = str(wrapper_dir) + os.pathsep + self.env["PATH"]
        result = self.run_helper("published", commit)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertTrue(marker.exists())
        self.assertIn("HEAD moved during the update", result.stderr)
        self.assertEqual(b"racing commit", self.git(self.repo, "log", "-1", "--format=%s").strip())
        self.assertEqual(b"", self.git(self.repo, "status", "--porcelain"))
        self.assertEqual(self.git(self.repo, "rev-parse", "HEAD^{tree}"),
                         self.git(self.origin, "rev-parse", "main^{tree}"))

    def run_parallel_records(self, count):
        root = self.git(self.repo, "rev-parse", "--show-toplevel").decode().strip()
        script = self.root / "writers.sh"
        script.write_text(
            self.helpers.read_text().replace('\n"$@"\n', "\n")
            + 'day_open_pending_record "$ROOT" origin refs/heads/main "$1" || exit 1\n')
        env = dict(self.env, ROOT=root)
        shas = ["%040d" % n for n in range(1, count + 1)]
        jobs = [subprocess.Popen(["bash", str(script), sha], env=env, stderr=subprocess.PIPE, text=True)
                for sha in shas]
        for job in jobs:
            _, err = job.communicate(timeout=120)
            self.assertEqual(0, job.returncode, err)
        kept = [line.split("\t")[3] for line in self.pending().splitlines()]
        self.assertEqual(sorted(shas), sorted(kept))

    def test_thirty_writers_with_leftover_lock_files_lose_nothing(self):
        # A crashed run leaves its lock files behind; the kernel lock does not care.
        state = self.root / "state"
        state.mkdir()
        (state / "day-open-pending-publish.list.flock").write_text("")
        leftover = state / "day-open-pending-publish.list.lock"
        leftover.mkdir()
        (leftover / "pid").write_text("999999\nThu Jan  1 00:00:00 1970\n")
        self.run_parallel_records(30)

    def test_writer_killed_while_holding_the_lock_does_not_block_the_next_run(self):
        # The holder dies without releasing anything; the next run must still get in at once.
        root = self.git(self.repo, "rev-parse", "--show-toplevel").decode().strip()
        holder = self.root / "holder.sh"
        holder.write_text(
            self.helpers.read_text().replace('\n"$@"\n', "\n")
            + '"${DAY_OPEN_PYTHON:-python3}" -I -c \'import fcntl,sys,time\n'
            'f=open(sys.argv[1]+".flock","a"); fcntl.flock(f, fcntl.LOCK_EX); print("held", flush=True); time.sleep(60)\' '
            '"$(day_open_pending_file)"\n')
        (self.root / "state").mkdir(exist_ok=True)
        process = subprocess.Popen(["bash", str(holder)], env=self.env, stdout=subprocess.PIPE,
                                   text=True, start_new_session=True)
        self.assertEqual("held", process.stdout.readline().strip())
        os.killpg(process.pid, 9)  # the whole group: the python child owns the lock
        process.wait()
        self.run_parallel_records(5)

    def test_edit_of_an_existing_archive_file_is_not_adopted_away(self):
        archived = "archive/day-plans/DayPlan 2000-01-01.md"
        (self.repo / "archive/day-plans").mkdir(parents=True)
        (self.repo / archived).write_text("shared base\n")
        self.git(self.repo, "add", archived)
        self.git(self.repo, "commit", "-qm", "common archive file")
        self.git(self.repo, "push", "-q")
        other = self.root / "other"
        self.git(self.root, "clone", "-q", str(self.origin), str(other))
        self.configure(other)
        (other / archived).write_text("shared base\nsummary from machine B\n")
        self.git(other, "commit", "-qam", "machine B closes the day")
        self.git(other, "push", "-q")
        today = "current/DayPlan 2000-01-02.md"
        (self.repo / "current").mkdir()
        (self.repo / today).write_text("today\n")
        (self.repo / archived).write_text("shared base\nlocal edit\n")
        self.git(self.repo, "add", today, archived)
        self.git(self.repo, "commit", "-qm", "machine A edits the archive and opens today", "--", today, archived)
        local = self.head()
        result = self.run_helper("published", local)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(b"today\n", self.git(self.origin, "show", "main:" + today))
        self.assertIn(archived, result.stderr)
        self.assertEqual(local, self.head())
        self.assertEqual(b"shared base\nlocal edit\n", self.git(self.repo, "show", "HEAD:" + archived))
        self.assertNotEqual((0, 0), self.ahead_behind())
        # The skipped fast-forward must refuse for the same reason and lose nothing.
        moved = self.run_helper("day_open_fast_forward")
        self.assertNotEqual(0, moved.returncode)
        self.assertEqual(local, self.head())
        self.assertEqual(b"shared base\nlocal edit\n", (self.repo / archived).read_bytes())
        self.assertEqual(b"", self.git(self.repo, "for-each-ref", "refs/day-open/superseded"))

    def test_missing_python_does_not_block_publication(self):
        self.env["DAY_OPEN_PYTHON"] = "/nonexistent/python"
        self.advance_remote()
        commit = self.commit_plan()
        good_url = self.git(self.repo, "remote", "get-url", "origin").decode().strip()
        self.git(self.repo, "remote", "set-url", "origin", str(self.root / "missing.git"))
        failed = self.run_helper("published", commit)
        self.assertNotEqual(0, failed.returncode)
        self.assertIn("python3 with fcntl", failed.stderr)
        self.assertIn(commit, self.pending())
        self.git(self.repo, "remote", "set-url", "origin", good_url)
        retry = self.run_helper("published")
        self.assertEqual(0, retry.returncode, retry.stderr)
        self.assertEqual(self.published_sha(retry), self.origin_main())
        self.assertEqual("", self.pending())

    def commit_evil_path(self):
        evil = "current/DayPlan y/s/evil.md"
        (self.repo / "current/DayPlan y/s").mkdir(parents=True)
        (self.repo / evil).write_text("nested path\n")
        self.git(self.repo, "add", evil)
        self.git(self.repo, "commit", "-qm", "nested path under a plan prefix")
        return evil, self.head()

    def test_plan_path_with_extra_directories_is_rejected(self):
        _, evil_commit = self.commit_evil_path()
        remote = self.origin_main()
        result = self.run_helper("published", evil_commit)
        self.assertNotEqual(0, result.returncode)
        self.assertIn("outside DayPlan", result.stderr)
        self.assertEqual(remote, self.origin_main())
        self.assertEqual("", self.pending())

    def test_recorded_commit_is_rechecked_when_read_from_the_list(self):
        evil, evil_commit = self.commit_evil_path()
        self.seed_pending(("origin", "refs/heads/main", evil_commit))
        legit = self.commit_plan()
        result = self.run_helper("published", legit)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("touches paths outside DayPlan/archive", result.stderr)
        self.assertEqual(b"", self.git(self.origin, "ls-tree", "-r", "--name-only", "main", evil))
        self.assertNotIn(evil_commit, self.pending())

    def tg_messages(self):
        path = self.root / "tg.log"
        return path.read_text(encoding="utf-8").splitlines() if path.exists() else []

    def markers(self):
        return sorted((self.root / "state").glob("day-open-sync-blocked.*.marker"))

    def test_four_days_then_clean(self):
        """Salvage publishes only the new plan; Day Close elsewhere later removes it from current/."""
        (self.repo / "current").mkdir(exist_ok=True)
        (self.repo / "current/DayPlan 2000-01-00.md").write_text("plan 0\n")
        self.git(self.repo, "add", "current/DayPlan 2000-01-00.md")
        self.git(self.repo, "commit", "-qm", "plan 0")
        self.git(self.repo, "push", "-q")
        other = self.root / "other"
        self.git(self.root, "clone", "-q", str(self.origin), str(other))
        self.configure(other)
        (self.repo / "shared.txt").write_text("local work\n")  # overlaps every remote change
        for day in (1, 2, 3, 4):
            prev = "DayPlan 2000-01-0%d.md" % (day - 1)
            self.git(other, "pull", "-q", "--ff-only")
            (other / "archive/day-plans").mkdir(parents=True, exist_ok=True)
            self.git(other, "mv", "current/" + prev, "archive/day-plans/" + prev)
            (other / "archive/day-plans" / prev).write_text("closed %d\n" % day)
            (other / "shared.txt").write_text("remote %d\n" % day)
            self.git(other, "add", "archive/day-plans/" + prev, "shared.txt")
            self.git(other, "commit", "-qm", "day close %d" % day)
            self.git(other, "push", "-q")
            (self.repo / "archive/day-plans").mkdir(parents=True, exist_ok=True)
            self.git(self.repo, "mv", "current/" + prev, "archive/day-plans/" + prev)
            today = "current/DayPlan 2000-01-0%d.md" % day
            (self.repo / today).write_text("plan %d\n" % day)
            self.git(self.repo, "add", today)
            self.git(self.repo, "commit", "-qm", "day open %d" % day, "--",
                     today, "current/" + prev, "archive/day-plans/" + prev)
            commit = self.head()
            result = self.run_helper("published", commit)
            self.assertEqual(0, result.returncode, "day %d: %s" % (day, result.stderr))
            self.assertEqual(commit, self.head(), "day %d: the overlapping edit must hold the branch" % day)
        # The last plan is archived on the other machine as well.
        self.git(other, "pull", "-q", "--ff-only")
        self.git(other, "mv", "current/DayPlan 2000-01-04.md", "archive/day-plans/DayPlan 2000-01-04.md")
        self.git(other, "commit", "-qm", "day close 5")
        self.git(other, "push", "-q")
        self.git(self.repo, "checkout", "--", "shared.txt")
        moved = self.run_helper("day_open_fast_forward")
        self.assertEqual(0, moved.returncode, moved.stderr)
        self.assertEqual((0, 0), self.ahead_behind())
        self.assertEqual(self.origin_main(), self.head())
        self.assertEqual([], self.markers())

    def test_bad_ids_rejected(self):
        commit = self.commit_plan()
        bad = ("HEAD", "main", "", "-x", "abc123")
        self.seed_pending(*[("origin", "refs/heads/main", sha) for sha in bad])
        result = self.run_helper("published", commit)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("malformed commit id", result.stderr)
        self.assertEqual(commit, self.origin_main())
        self.assertEqual("", self.pending())
        refused = self.run_helper("published", "HEAD")
        self.assertNotEqual(0, refused.returncode)
        self.assertIn("not a commit id", refused.stderr)

    def test_mixed_ops_no_python(self):
        self.env["DAY_OPEN_PYTHON"] = "/nonexistent/python"
        root = self.git(self.repo, "rev-parse", "--show-toplevel").decode().strip()
        seeded = ["%040d" % n for n in range(1, 31)]
        added = ["%040d" % n for n in range(101, 106)]
        self.seed_pending(*[("origin", "refs/heads/main", sha) for sha in seeded])
        script = self.root / "mixed.sh"
        script.write_text(
            self.helpers.read_text(encoding="utf-8").replace('\n"$@"\n', "\n")
            + 'case "$1" in\n'
            '  record) day_open_pending_record "$ROOT" origin refs/heads/main "$2" ;;\n'
            '  remove) day_open_pending_remove "$ROOT" "$2" ;;\nesac\n')
        env = dict(self.env, ROOT=root)
        jobs = [subprocess.Popen(["bash", str(script), mode, sha], env=env,
                                 stderr=subprocess.PIPE, text=True)
                for mode, sha in [("remove", s) for s in seeded] + [("record", s) for s in added]]
        for job in jobs:
            _, err = job.communicate(timeout=180)
            self.assertEqual(0, job.returncode, err)
        kept = sorted(line.split("\t")[3] for line in self.pending().splitlines())
        self.assertEqual(sorted(added), kept)

    def test_marker_and_telegram(self):
        (self.repo / "notes.txt").write_text("notes\n")
        self.git(self.repo, "add", "notes.txt")
        self.git(self.repo, "commit", "-qm", "notes")
        self.git(self.repo, "push", "-q")
        self.advance_remote()
        commit = self.commit_plan()
        self.dirty()
        result = self.run_helper("published", commit)
        self.assertEqual(0, result.returncode, result.stderr)
        markers = self.markers()
        self.assertEqual(1, len(markers))
        text = markers[0].read_text(encoding="utf-8")
        self.assertIn("head=" + commit, text)
        self.assertIn("target=" + self.origin_main(), text)
        self.assertIn("behind=2", text)
        self.assertIn("overlapping local edits", text)
        first = self.tg_messages()
        self.assertEqual(1, len(first), first)
        self.assertTrue(first[0].startswith("protective"))
        self.assertIn("shared.txt", first[0])
        self.assertIn("на 2 коммитов", first[0])
        # Same reason, same paths: silent.
        self.assertNotEqual(0, self.run_helper("adopt", self.origin_main()).returncode)
        self.assertEqual(1, len(self.tg_messages()))
        # The overlap grows by a path: one new message naming it.
        other = self.root / "other"
        self.git(other, "pull", "-q", "--ff-only")
        (other / "notes.txt").write_text("remote notes\n")
        self.git(other, "commit", "-qam", "remote notes")
        self.git(other, "push", "-q")
        self.git(self.repo, "fetch", "-q", "origin", "main")
        (self.repo / "notes.txt").write_text("local notes\n")
        self.assertNotEqual(0, self.run_helper("adopt", self.origin_main()).returncode)
        second = self.tg_messages()
        self.assertEqual(2, len(second), second)
        self.assertIn("notes.txt", second[1])
        # Same state a week later: one reminder, then silence again.
        week = int(time.time()) + 8 * 86400
        self.env["DAY_OPEN_NOW"] = str(week)
        self.run_helper("adopt", self.origin_main())
        self.assertEqual(3, len(self.tg_messages()))
        self.env["DAY_OPEN_NOW"] = str(week + 86400)
        self.run_helper("adopt", self.origin_main())
        self.assertEqual(3, len(self.tg_messages()))
        # Once the overlapping work is gone, the move succeeds and the marker disappears.
        self.git(self.repo, "reset", "-q", "--hard")
        (self.repo / "draft.md").unlink()
        moved = self.run_helper("day_open_fast_forward")
        self.assertEqual(0, moved.returncode, moved.stderr)
        self.assertEqual([], self.markers())
        self.assertEqual(3, len(self.tg_messages()))
        self.assertEqual((0, 0), self.ahead_behind())

    def commit_at(self, repo, days_ago, message):
        when = "%d +0000" % (int(time.time()) - days_ago * 86400)
        env = dict(os.environ, GIT_AUTHOR_DATE=when, GIT_COMMITTER_DATE=when)
        subprocess.run(["git", "-C", str(repo), "commit", "--allow-empty", "-qm", message],
                       check=True, env=env, capture_output=True)
        return self.head(repo)

    def test_prune_old_refs(self):
        old_reachable = self.commit_at(self.repo, 200, "old but published")
        recent_reachable = self.commit_at(self.repo, 1, "recent and published")
        self.git(self.repo, "checkout", "-qb", "side", "HEAD~2")
        old_lost = self.commit_at(self.repo, 200, "old and never published")
        self.git(self.repo, "checkout", "-q", "main")
        self.git(self.repo, "branch", "-qD", "side")
        for sha in (old_reachable, recent_reachable, old_lost):
            self.git(self.repo, "update-ref", "refs/day-open/superseded/" + sha, sha)
        result = self.run_helper("prune", self.head())
        self.assertEqual(0, result.returncode, result.stderr)
        left = self.git(self.repo, "for-each-ref", "--format=%(refname:lstrip=3)",
                        "refs/day-open/superseded/").decode().split()
        self.assertEqual(sorted([recent_reachable, old_lost]), sorted(left))

    def tg_attempts(self):
        path = self.root / "tg-attempts.log"
        return path.read_text(encoding="utf-8").splitlines() if path.exists() else []

    def blocked_setup(self):
        """An overlapping local edit holds the checkout behind a published plan."""
        self.advance_remote()
        commit = self.commit_plan()
        self.dirty()
        return self.run_helper("published", commit)

    def test_tg_failure_is_retried(self):
        self.env["TG_RC"] = "1"
        result = self.blocked_setup()
        self.assertEqual(0, result.returncode, result.stderr)
        marker = self.markers()[0]
        self.assertNotIn("notified", marker.read_text(encoding="utf-8"))
        self.assertEqual(1, len(self.tg_attempts()))
        self.assertEqual([], self.tg_messages())
        self.assertNotEqual(0, self.run_helper("adopt", self.origin_main()).returncode)
        self.assertEqual(2, len(self.tg_attempts()), "a failed send must be tried again")
        self.assertNotIn("notified", marker.read_text(encoding="utf-8"))
        self.env["TG_RC"] = "0"
        self.assertNotEqual(0, self.run_helper("adopt", self.origin_main()).returncode)
        self.assertEqual(1, len(self.tg_messages()))
        text = marker.read_text(encoding="utf-8")
        self.assertIn("notified=", text)
        self.assertIn("notified_sig=", text)
        # Delivered once, so the next runs stay silent.
        self.assertNotEqual(0, self.run_helper("adopt", self.origin_main()).returncode)
        self.assertEqual(1, len(self.tg_messages()))
        self.assertEqual(3, len(self.tg_attempts()))

    def test_probe_writes_no_marker(self):
        self.env["PROBE"] = "true"
        result = self.blocked_setup()
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual([], self.markers())
        self.assertEqual([], self.tg_attempts())
        del self.env["PROBE"]
        self.assertNotEqual(0, self.run_helper("adopt", self.origin_main()).returncode)
        self.assertEqual(1, len(self.markers()))
        self.assertEqual(1, len(self.tg_messages()))

    def run_call_site(self):
        source = PIPELINE.read_text(encoding="utf-8")
        match = re.search(r'if ! day_open_fast_forward "\$DS_STRATEGY"; then\n.*?\nfi', source, re.DOTALL)
        self.assertIsNotNone(match, "the pipeline call site moved")
        script = self.root / "call-site.sh"
        script.write_text(self.helpers.read_text(encoding="utf-8").replace('\n"$@"\n', "\n")
                          + 'DS_STRATEGY="$1"\n' + match.group() + "\n", encoding="utf-8")
        return subprocess.run(["bash", str(script), str(self.repo)], env=self.env,
                              capture_output=True, text=True)

    def test_call_site_gag_only_when_reported(self):
        # A clean checkout with an unpublished local commit: refused, reported once, no general message.
        (self.repo / "foreign.txt").write_text("another agent\n")
        self.git(self.repo, "add", "foreign.txt")
        self.git(self.repo, "commit", "-qm", "foreign local commit")
        self.shift_origin("remote.txt")
        result = self.run_call_site()
        self.assertEqual(0, result.returncode, result.stderr)
        messages = self.tg_messages()
        self.assertEqual(1, len(messages), messages)
        self.assertIn("отстаёт", messages[0])
        self.assertNotIn("обновление пропущено", messages[0])
        # Same run again: the pilot already knows, nothing new is sent.
        self.run_call_site()
        self.assertEqual(1, len(self.tg_messages()))

    def test_old_marker_does_not_gag(self):
        self.shift_origin("remote.txt")
        self.dirty()
        marker = Path(subprocess.run(
            ["bash", str(self.helpers), "day_open_sync_marker_file", str(self.repo)],
            env=self.env, capture_output=True, text=True).stdout.strip())
        marker.parent.mkdir(parents=True, exist_ok=True)
        # An old block for another reason, delivered long ago.
        marker.write_text("head=0\ntarget=0\nbehind=9\nreason=old\nsig=overlap|old.txt\n"
                          "notified_sig=overlap|old.txt\nnotified=1\n", encoding="utf-8")
        result = self.run_call_site()
        self.assertEqual(0, result.returncode, result.stderr)
        messages = self.tg_messages()
        self.assertEqual(1, len(messages), messages)
        self.assertIn("обновление пропущено", messages[0])

    def test_failed_marker_send_still_gets_the_general_message(self):
        self.env["TG_RC"] = "1"
        (self.repo / "foreign.txt").write_text("another agent\n")
        self.git(self.repo, "add", "foreign.txt")
        self.git(self.repo, "commit", "-qm", "foreign local commit")
        self.shift_origin("remote.txt")
        self.run_call_site()
        attempts = self.tg_attempts()
        # One attempt for the marker message, one for the general one: silence is not an option.
        self.assertEqual(2, len(attempts), attempts)

    def seed_pending(self, *entries):
        root = self.git(self.repo, "rev-parse", "--show-toplevel").decode().strip()
        state = self.root / "state"
        state.mkdir(exist_ok=True)
        with open(state / "day-open-pending-publish.list", "a", encoding="utf-8") as handle:
            for remote, ref, sha in entries:
                handle.write("\t".join([root, remote, ref, sha]) + "\n")

    def test_lost_commit_and_foreign_destination_do_not_block_the_rest(self):
        commit = self.commit_plan()
        self.seed_pending(("origin", "refs/heads/main", "0" * 39 + "1"),
                          ("elsewhere", "refs/heads/main", "0" * 39 + "2"))
        result = self.run_helper("published", commit)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(commit, self.origin_main())
        self.assertIn("is gone from the repository", result.stderr)
        self.assertIn("skipping", result.stderr)
        left = self.pending()
        self.assertNotIn("0" * 39 + "1", left)
        self.assertIn("0" * 39 + "2", left)

    def test_parallel_updates_of_the_list_do_not_lose_each_other(self):
        root = self.git(self.repo, "rev-parse", "--show-toplevel").decode().strip()
        seeded = ["%040d" % n for n in range(1, 41)]
        self.seed_pending(*[("origin", "refs/heads/main", sha) for sha in seeded])
        first = ["%040d" % n for n in range(101, 141)]
        second = ["%040d" % n for n in range(201, 241)]
        script = self.root / "parallel.sh"
        script.write_text(
            self.helpers.read_text().replace('\n"$@"\n', "\n")
            + 'record_all() { for sha in "$@"; do day_open_pending_record "$ROOT" origin refs/heads/main "$sha" || exit 1; done; }\n'
            'remove_all() { for sha in "$@"; do day_open_pending_remove "$ROOT" "$sha" || exit 1; done; }\n'
            'mode="$1"; shift\n"$mode" "$@"\n')
        env = dict(self.env, ROOT=root)
        jobs = [subprocess.Popen(["bash", str(script), mode, *shas], env=env,
                                 stderr=subprocess.PIPE, text=True)
                for mode, shas in (("record_all", first), ("record_all", second),
                                   ("remove_all", seeded))]
        for job in jobs:
            _, err = job.communicate(timeout=120)
            self.assertEqual(0, job.returncode, err)
        kept = {line.split("\t")[3] for line in self.pending().splitlines()}
        self.assertEqual(set(first + second), kept)

    def test_adopt_refuses_overlapping_edits_and_loses_nothing(self):
        self.advance_remote()
        commit = self.commit_plan()
        self.dirty()
        before = self.snapshot()
        result = self.run_helper("published", commit)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn("left on its own commits", result.stderr)
        self.assertIn("overlapping local edits", result.stderr)
        self.assertIn("shared.txt", result.stderr)
        self.assertEqual(before, self.snapshot())
        self.assertEqual((1, 2), self.ahead_behind())
        # Once the overlapping work is gone, the skipped fast-forward adopts the twins.
        self.git(self.repo, "reset", "-q", "--hard")
        (self.repo / "draft.md").unlink()
        moved = self.run_helper("day_open_fast_forward")
        self.assertEqual(0, moved.returncode, moved.stderr)
        self.assertEqual((0, 0), self.ahead_behind())
        self.assertEqual(self.origin_main(), self.head())

    def test_adopt_refuses_when_a_local_commit_has_no_twin(self):
        (self.repo / "foreign.txt").write_text("another agent\n")
        self.git(self.repo, "add", "foreign.txt")
        self.git(self.repo, "commit", "-qm", "foreign local commit")
        commit = self.commit_plan()
        result = self.run_helper("published", commit)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertEqual(commit, self.head())
        self.assertEqual(b"", self.git(self.origin, "ls-tree", "--name-only", "main", "foreign.txt"))

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
