#!/usr/bin/env python3
"""Fail when agent-instruction markdown hardcodes the workspace path (issue #876).

Skills, memory protocols, rules and role prompts are instructions an agent
executes. A literal `~/IWE/...` or `$HOME/IWE/...` there points to a path that
does not exist on an install with another workspace location; the agent gets
an empty result and takes it for a fact. The accepted form is
`${IWE_WORKSPACE:-$HOME/IWE}` (honours the environment, keeps the default).

Scope: .claude/skills, .claude/rules*, .claude/commands, memory, roles.
User guides (docs/, README) are not scanned: there `~/IWE` is the instruction
"create the folder here".

Lines that talk ABOUT the hardcoding stay allowed (EXEMPT below).

Usage: check-hardcoded-workspace-md.py [--root DIR]
Exit:  0 clean, 1 violations found (listed), 2 bad usage.
"""
import argparse
import os
import re
import sys

SCOPE = (".claude/skills/", ".claude/rules", ".claude/commands", "memory/", "roles/")
SKIP_DIRS = {".git", "node_modules", "seed"}
SKIP_FILES = {"CHANGELOG.md"}
# the accepted parameterized form is not a violation: the preceding ":-" marks it
HARDCODED = re.compile(r"(?<!:-)(~/IWE|\$HOME/IWE|\$\{HOME\}/IWE)(?=[/\s`\"')\]]|$)")
EXEMPT = re.compile(r"хардкод|hardcod|захардкож|~~|expanduser|echo \$HOME/IWE|tr '/' '-'", re.I)
EXEMPT_FILES = {"memory/dry-run-contract.md", ".claude/rules/formatting.md"}


def scan(root):
    found = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in filenames:
            if not name.endswith(".md") or name in SKIP_FILES:
                continue
            path = os.path.join(dirpath, name)
            rel = os.path.relpath(path, root).replace(os.sep, "/")
            if not rel.startswith(SCOPE) or rel in EXEMPT_FILES:
                continue
            with open(path, encoding="utf-8", errors="replace") as fh:
                for number, line in enumerate(fh, 1):
                    if HARDCODED.search(line) and not EXEMPT.search(line):
                        found.append(f"{rel}:{number}: {line.strip()[:120]}")
    return found


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
    args = parser.parse_args()
    if not os.path.isdir(args.root):
        print(f"not a directory: {args.root}", file=sys.stderr)
        return 2
    found = scan(os.path.abspath(args.root))
    if found:
        print(f"hardcoded workspace path in {len(found)} instruction line(s); "
              "use ${IWE_WORKSPACE:-$HOME/IWE} (issue #876):")
        for item in found:
            print("  " + item)
        return 1
    print("check-hardcoded-workspace-md: clean")
    return 0


if __name__ == "__main__":
    sys.exit(main())
