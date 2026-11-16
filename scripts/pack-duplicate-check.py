#!/usr/bin/env python3
"""Find possible duplicates of a knowledge candidate in the user's own Pack files.

Issue #1514: the platform search (knowledge_search) indexes the author's Pack, not
the user's fork, so an empty result there is not "no duplicates", and a hit with
the same ID may be a different card. This helper looks at the files themselves:

  KEYWORD_MATCH <n> <path>   Pack files containing n of the given keywords (best first)
  ID_LOCAL <path>            Pack files that already use the candidate ID
  UPSTREAM <status>          ok | no-remote | no-ref | fetch-failed | not-a-git-repo
  ID_UPSTREAM <ref> <path>   files on the upstream branch that use the same ID

It only lists evidence; deciding "duplicate" stays with the human validator (R15).
A same-ID file is a numbering collision, not a duplicate, until contents are compared.

Usage:
  pack-duplicate-check.py --pack <pack root> [--id DP.M.123] [--remote upstream]
                          [--fetch] [--limit 10] [keyword ...]
Exit: 0 — checked (matches or not); 2 — bad arguments or unreadable Pack.
"""
import argparse
import os
import re
import subprocess
import sys
from pathlib import Path


def id_pattern(card_id):
    # DP.M.43 must not match DP.M.438 or XDP.M.43.
    return re.compile(r"(?<![A-Za-z0-9.])" + re.escape(card_id) + r"(?![0-9])")


def read_pack(root):
    """{relative path: text} of the Pack's Markdown files.

    Searches pack/ when the repo has one (the knowledge itself), else the whole root.
    An unreadable file is reported on stderr and skipped, never silently.
    """
    base = root / "pack" if (root / "pack").is_dir() else root
    texts = {}
    for path in sorted(base.rglob("*.md")):
        rel = path.relative_to(root)
        if ".git" in rel.parts:
            continue
        try:
            texts[str(rel)] = path.read_text(encoding="utf-8", errors="replace")
        except OSError as exc:
            print(f"pack-duplicate-check: cannot read {rel}: {exc}", file=sys.stderr)
    return texts


def keyword_matches(texts, keywords, limit):
    lowered = [k.lower() for k in keywords]
    scored = []
    for rel, text in texts.items():
        hits = sum(1 for k in lowered if k in text.lower())
        if hits:
            scored.append((-hits, rel))
    return [(-neg, rel) for neg, rel in sorted(scored)[:limit]]


def local_id_uses(texts, pattern):
    return [rel for rel, text in texts.items() if pattern.search(Path(rel).name) or pattern.search(text)]


def git(root, *args, timeout=30):
    # quotePath=false: Cyrillic file names come back as text, not "\320\234..." escapes
    # that `git show ref:path` cannot resolve. No credential prompt may hang an agent.
    env = {**os.environ, "GIT_TERMINAL_PROMPT": "0"}
    try:
        return subprocess.run(["git", "-c", "core.quotePath=false", "-C", str(root), *args],
                              capture_output=True, text=True, encoding="utf-8", errors="replace",
                              env=env, timeout=timeout)
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(args, 124, "", f"git {args[0]}: timed out after {timeout}s")


def upstream_ref(root, remote, fetch):
    """Return (status, ref). ref is None unless status == 'ok'.

    fetch-failed: the remote could not be fetched, so any local copy may be stale.
    no-ref: no branch of the remote is known locally (even after a fetch, if asked).
    """
    if git(root, "rev-parse", "--git-dir").returncode != 0:
        return "not-a-git-repo", None
    if git(root, "remote", "get-url", remote).returncode != 0:
        return "no-remote", None
    if fetch:
        fetched = git(root, "fetch", "-q", remote, timeout=120)
        if fetched.returncode != 0:
            print(f"pack-duplicate-check: fetch {remote} failed: {fetched.stderr.strip()}", file=sys.stderr)
            return "fetch-failed", None
        # Learn the remote's default branch (it may be neither main nor master).
        git(root, "remote", "set-head", remote, "--auto", timeout=60)
    head = git(root, "symbolic-ref", "-q", "--short", f"refs/remotes/{remote}/HEAD")
    candidates = [head.stdout.strip()] if head.returncode == 0 else []
    candidates += [f"{remote}/main", f"{remote}/master"]
    for ref in candidates:
        if ref and git(root, "rev-parse", "-q", "--verify", f"{ref}^{{commit}}").returncode == 0:
            return "ok", ref
    return "no-ref", None


def upstream_id_uses(root, ref, card_id, pattern):
    listed = git(root, "grep", "-l", "-F", card_id, ref, "--", "*.md")
    paths = {line.split(":", 1)[1] for line in listed.stdout.splitlines() if ":" in line}
    names = git(root, "ls-tree", "-r", "--name-only", ref)
    paths |= {p for p in names.stdout.splitlines() if p.endswith(".md") and pattern.search(Path(p).name)}
    confirmed = []
    for path in sorted(paths):
        blob = git(root, "show", f"{ref}:{path}")
        if blob.returncode != 0:
            print(f"pack-duplicate-check: cannot read {ref}:{path}: {blob.stderr.strip()}", file=sys.stderr)
            continue
        if pattern.search(Path(path).name) or pattern.search(blob.stdout):
            confirmed.append(path)
    return confirmed


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--pack", required=True, help="root directory of the user's Pack")
    parser.add_argument("--id", dest="card_id", help="candidate ID, e.g. DP.METHOD.184")
    parser.add_argument("--remote", default="upstream", help="remote of the author's Pack (default: upstream)")
    parser.add_argument("--fetch", action="store_true", help="fetch the remote before comparing IDs")
    parser.add_argument("--limit", type=int, default=10)
    parser.add_argument("keywords", nargs="*")
    args = parser.parse_args()

    root = Path(args.pack).resolve()
    if not root.is_dir():
        print(f"pack-duplicate-check: Pack directory not found: {root}", file=sys.stderr)
        return 2
    if not args.card_id and not args.keywords:
        print("pack-duplicate-check: give --id and/or keywords", file=sys.stderr)
        return 2

    texts = read_pack(root)
    for hits, rel in keyword_matches(texts, args.keywords, args.limit):
        print(f"KEYWORD_MATCH\t{hits}\t{rel}")

    if args.card_id:
        pattern = id_pattern(args.card_id)
        for rel in local_id_uses(texts, pattern):
            print(f"ID_LOCAL\t{rel}")
        status, ref = upstream_ref(root, args.remote, args.fetch)
        print(f"UPSTREAM\t{status}")
        if ref:
            for path in upstream_id_uses(root, ref, args.card_id, pattern):
                print(f"ID_UPSTREAM\t{ref}\t{path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
