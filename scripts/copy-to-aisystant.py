#!/usr/bin/env python3
# see WP-415 (Pipeline 1: personal RU template -> aisystant private RU repos)
"""Pull-only mirror: publish this repo's current tree onto configured
private RU repos in the aisystant GitHub org (Pipeline 1, Variant A,
pilot decision 2026-07-13).

Variant A is one-directional: aisystant reads/comments, never edits the
source here -- so there is no merge or conflict-resolution logic, only
"does the target tree already match the source tree, and if not, publish
a new commit on top of the target's own history" (same commit-tree pattern
already used for the iwesys publish job in translate-sync.yml).

SAFETY CONTRACT (do not weaken without a pilot decision):
  - Never creates, deletes, or renames a repository.
  - Never touches org/repo settings, permissions, or billing.
  - Only ever pushes a single commit onto an EXISTING branch of an
    EXISTING target repo.
  - Defaults to --dry-run; a live push additionally requires both a
    push token (via --token-env) and the literal --confirm=PUBLISH flag,
    so an accidental bare invocation can never push.
  - A target repo that does not exist yet is reported and skipped, never
    auto-created.

Usage:
    # Report only -- default, safe to run anytime, no network writes.
    python3 scripts/copy-to-aisystant.py

    # Actually publish (requires a real push token and explicit confirm).
    GH_TOKEN=... python3 scripts/copy-to-aisystant.py --live --confirm=PUBLISH
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

import yaml

DEFAULT_CONFIG = Path(__file__).parent.parent / "aisystant-sync-targets.yaml"
CONFIRM_TOKEN = "PUBLISH"


@dataclass
class SyncTarget:
    repo: str  # "org/repo"
    branch: str = "main"


@dataclass
class TargetReport:
    target: SyncTarget
    exists: bool
    up_to_date: bool | None  # None when exists is False (unknown)
    source_tree: str
    parent_commit: str | None
    would_publish: bool

    def describe(self) -> str:
        if not self.exists:
            return f"{self.target.repo}: SKIP (repo does not exist yet, not creating it)"
        if self.up_to_date:
            return f"{self.target.repo}@{self.target.branch}: up to date, nothing to publish"
        return (
            f"{self.target.repo}@{self.target.branch}: new commit needed "
            f"(source tree {self.source_tree[:12]}, "
            f"parent {self.parent_commit[:12] if self.parent_commit else '<empty branch>'})"
        )


def load_targets(config_path: Path) -> list[SyncTarget]:
    """Read the target list; an empty/missing list is a valid, quiet outcome."""
    if not config_path.exists():
        return []
    with open(config_path, encoding="utf-8") as handle:
        data = yaml.safe_load(handle) or {}
    return [
        SyncTarget(repo=entry["repo"], branch=entry.get("branch", "main"))
        for entry in data.get("targets", [])
    ]


def run(cmd: list[str], **kwargs) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, check=False, **kwargs)


def source_tree_sha(repo_dir: Path) -> str:
    """Tree of the currently checked-out commit -- the published state is
    whatever HEAD points to, not uncommitted working-tree changes."""
    result = run(["git", "-C", str(repo_dir), "rev-parse", "HEAD^{tree}"])
    if result.returncode != 0:
        raise RuntimeError(f"cannot resolve HEAD tree: {result.stderr.strip()}")
    return result.stdout.strip()


def target_exists(repo: str) -> bool:
    """Read-only existence check via `gh`; never a mutating call."""
    result = run(["gh", "repo", "view", repo, "--json", "name"])
    return result.returncode == 0


def fetch_remote_head(repo_dir: Path, repo: str, branch: str, token: str | None) -> str | None:
    """Return the target branch's current commit sha, or None if the branch
    does not exist yet (first publish)."""
    remote_url = _remote_url(repo, token)
    result = run(["git", "-C", str(repo_dir), "ls-remote", remote_url, f"refs/heads/{branch}"])
    if result.returncode != 0:
        raise RuntimeError(f"cannot query {repo}: {result.stderr.strip()}")
    line = result.stdout.strip()
    return line.split()[0] if line else None


def _remote_url(repo: str, token: str | None) -> str:
    if token:
        return f"https://x-access-token:{token}@github.com/{repo}.git"
    return f"https://github.com/{repo}.git"


def build_report(repo_dir: Path, target: SyncTarget, token: str | None) -> TargetReport:
    tree = source_tree_sha(repo_dir)
    if not target_exists(target.repo):
        return TargetReport(target, exists=False, up_to_date=None, source_tree=tree,
                             parent_commit=None, would_publish=False)

    parent = fetch_remote_head(repo_dir, target.repo, target.branch, token)
    if parent is None:
        return TargetReport(target, exists=True, up_to_date=False, source_tree=tree,
                             parent_commit=None, would_publish=True)

    parent_tree = run(["git", "-C", str(repo_dir), "rev-parse", f"{parent}^{{tree}}"]).stdout.strip()
    up_to_date = parent_tree == tree
    return TargetReport(target, exists=True, up_to_date=up_to_date, source_tree=tree,
                         parent_commit=parent, would_publish=not up_to_date)


def publish(repo_dir: Path, report: TargetReport, token: str, author_name: str, author_email: str) -> str:
    """Commit-tree the source tree onto the target's own history and push.
    Only ever called from the --live path, after the confirm gate."""
    message = "chore(sync): publish personal RU template snapshot"
    commit_cmd = ["git", "-C", str(repo_dir), "commit-tree", report.source_tree, "-m", message]
    if report.parent_commit:
        commit_cmd += ["-p", report.parent_commit]
    env = {
        "GIT_AUTHOR_NAME": author_name,
        "GIT_AUTHOR_EMAIL": author_email,
        "GIT_COMMITTER_NAME": "canon-sync[bot]",
        "GIT_COMMITTER_EMAIL": "canon-sync[bot]@users.noreply.github.com",
    }
    result = run(commit_cmd, env={**_inherited_env(), **env})
    if result.returncode != 0:
        raise RuntimeError(f"commit-tree failed: {result.stderr.strip()}")
    new_commit = result.stdout.strip()

    remote_url = _remote_url(report.target.repo, token)
    push = run(["git", "-C", str(repo_dir), "push", remote_url, f"{new_commit}:refs/heads/{report.target.branch}"])
    if push.returncode != 0:
        raise RuntimeError(f"push to {report.target.repo} failed: {push.stderr.strip()}")
    return new_commit


def _inherited_env() -> dict:
    import os

    return dict(os.environ)


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument("--repo-dir", type=Path, default=Path.cwd())
    parser.add_argument("--live", action="store_true", help="publish for real (default: report only)")
    parser.add_argument("--confirm", default="", help=f"must equal '{CONFIRM_TOKEN}' to allow --live")
    parser.add_argument("--token-env", default="GH_TOKEN", help="env var holding the push token")
    parser.add_argument("--author-name", default="canon-sync[bot]")
    parser.add_argument("--author-email", default="canon-sync[bot]@users.noreply.github.com")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    import os

    args = parse_args(argv)
    targets = load_targets(args.config)
    if not targets:
        print("No sync targets configured (aisystant-sync-targets.yaml has an empty list) -- nothing to do.")
        return 0

    token = os.environ.get(args.token_env)
    live = args.live
    if live and args.confirm != CONFIRM_TOKEN:
        print(f"--live requires --confirm={CONFIRM_TOKEN} -- refusing to publish.", file=sys.stderr)
        return 1
    if live and not token:
        print(f"--live requires a push token in ${args.token_env} -- refusing to publish.", file=sys.stderr)
        return 1

    exit_code = 0
    for target in targets:
        report = build_report(args.repo_dir, target, token)
        print(report.describe())
        if not report.would_publish:
            continue
        if not live:
            print(f"  (dry-run: would publish here -- rerun with --live --confirm={CONFIRM_TOKEN})")
            continue
        try:
            new_commit = publish(args.repo_dir, report, token, args.author_name, args.author_email)
            print(f"  published {new_commit[:12]} to {target.repo}@{target.branch}")
        except RuntimeError as exc:
            print(f"  FAILED: {exc}", file=sys.stderr)
            exit_code = 1
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
