"""extractor-branches-prune.sh: only branches whose every commit reached the
governance branch (by cherry-pick or ancestry) are deleted; disposable repos only."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[3]
PRUNE = ROOT / "roles/extractor/scripts/extractor-branches-prune.sh"


class ExtractorBranchesPruneTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="extractor-prune-")
        base = Path(self.temporary.name)
        self.env = {
            **os.environ,
            "HOME": str(base),
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Fixture",
            "GIT_AUTHOR_EMAIL": "fixture@example.invalid",
            "GIT_COMMITTER_NAME": "Fixture",
            "GIT_COMMITTER_EMAIL": "fixture@example.invalid",
        }
        self.remote = base / "gov.git"
        self.repo = base / "gov"
        self.run_command(["git", "init", "-q", "--bare", "-b", "main", str(self.remote)])
        self.run_command(["git", "clone", "-q", str(self.remote), str(self.repo)])
        self.commit("README.md", "base\n")
        self.git("push", "-q", "-u", "origin", "main")
        # Published the way the extractor does it: cherry-picked onto main.
        self.git("checkout", "-q", "-b", "extractor/published")
        self.commit("report-1.md", "one\n")
        self.git("checkout", "-q", "main")
        self.commit("other.md", "main moved on\n")  # so the tip is not an ancestor
        self.git("cherry-pick", "extractor/published")
        # Same content reached main through a fast-forward ancestor.
        self.git("checkout", "-q", "-b", "extractor/ancestor")
        self.git("checkout", "-q", "main")
        # Never published: the only copy of its report.
        self.git("checkout", "-q", "-b", "extractor/unpublished")
        self.commit("report-2.md", "two\n")
        self.git("checkout", "-q", "main")
        self.git("push", "-q", "origin", "main", "extractor/published", "extractor/unpublished")

    def tearDown(self):
        self.temporary.cleanup()

    def run_command(self, args, *, check=True):
        return subprocess.run(args, env=self.env, text=True, capture_output=True, check=check)

    def git(self, *args):
        return self.run_command(["git", "-C", str(self.repo), *args]).stdout.strip()

    def commit(self, name, text):
        (self.repo / name).write_text(text, encoding="utf-8")
        self.git("add", name)
        self.git("commit", "-q", "-m", name)

    def prune(self, *args):
        return self.run_command(["bash", str(PRUNE), "--repo", str(self.repo), *args], check=False)

    def local_branches(self):
        return set(self.git("for-each-ref", "--format=%(refname:short)", "refs/heads/extractor/").split())

    def remote_branches(self):
        out = self.run_command(["git", "--git-dir", str(self.remote), "for-each-ref", "--format=%(refname:short)", "refs/heads/extractor/"])
        return set(out.stdout.split())

    def test_report_only_by_default(self):
        result = self.prune()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("published  local  extractor/published", result.stdout)
        self.assertIn("published  local  extractor/ancestor", result.stdout)
        self.assertIn("KEEP       local  extractor/unpublished (1 unpublished commit(s))", result.stdout)
        self.assertIn("KEEP       origin extractor/unpublished", result.stdout)
        self.assertEqual(self.local_branches(), {"extractor/published", "extractor/ancestor", "extractor/unpublished"})
        self.assertEqual(self.remote_branches(), {"extractor/published", "extractor/unpublished"})

    def test_apply_deletes_only_published_local_branches(self):
        result = self.prune("--apply")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.local_branches(), {"extractor/unpublished"})
        self.assertEqual(self.remote_branches(), {"extractor/published", "extractor/unpublished"})

    def test_apply_remote_needs_confirmation(self):
        result = self.prune("--apply-remote")
        self.assertEqual(result.returncode, 2)
        self.assertIn("rerun with --yes", result.stderr)
        self.assertEqual(self.remote_branches(), {"extractor/published", "extractor/unpublished"})

    def test_apply_remote_with_yes_keeps_unpublished(self):
        result = self.prune("--apply-remote", "--yes")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.remote_branches(), {"extractor/unpublished"})
        self.assertEqual(len(self.local_branches()), 3)

    def test_apply_with_unconfirmed_remote_deletes_nothing(self):
        result = self.prune("--apply", "--apply-remote")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(len(self.local_branches()), 3)
        self.assertEqual(self.remote_branches(), {"extractor/published", "extractor/unpublished"})

    def test_branch_with_merge_commit_is_kept(self):
        # The merged side is already on main; the merge itself adds a file
        # that exists nowhere else -- git cherry cannot see it.
        self.git("checkout", "-q", "-b", "extractor/merge", "extractor/published")
        self.git("merge", "-q", "--no-ff", "--no-commit", "main")
        (self.repo / "only-here.md").write_text("only copy\n", encoding="utf-8")
        self.git("add", "only-here.md")
        self.git("commit", "-q", "-m", "merge with own content")
        self.git("checkout", "-q", "main")
        result = self.prune("--apply")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("KEEP       local  extractor/merge (merge commits)", result.stdout)
        self.assertIn("extractor/merge", self.local_branches())

    def test_extractor_upstream_is_not_used_as_base(self):
        self.git("checkout", "-q", "extractor/unpublished")
        self.git("branch", "-q", "--set-upstream-to=origin/extractor/unpublished")
        result = self.prune()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("base: origin/main", result.stdout)
        self.assertIn("KEEP       local  extractor/unpublished", result.stdout)


if __name__ == "__main__":
    unittest.main()
