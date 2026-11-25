#!/usr/bin/env python3
"""Skill audience and executing agents: header contract, check and selection.

Every template skill declares two header fields (WP-592 Ф7, inventory approved
by the pilot on 2026-11-25):

  audience: user | author        who the skill is for
  runs_on: [claude, kimi, codex]  agents that can run it correctly today

A skill that needs a capability another agent lacks (an isolated-context
helper, a Claude Code hook, a Claude-only memory path) leaves that agent out of
runs_on until the skill itself carries a fallback for it.

Usage:
  python3 skill_agents.py --check SKILLS_DIR       exit 1 on any header error
  python3 skill_agents.py --for AGENT SKILLS_DIR   skill names to expose to AGENT

The skill-link program reads the same selection (select_for), so the rule
"user skill + agent in runs_on" lives in one place.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

import yaml

AUDIENCES = ("user", "author")
AGENTS = ("claude", "kimi", "codex")
FRONTMATTER_RE = re.compile(r"\A---\n(.*?)\n---\n", re.DOTALL)


def skill_dirs(skills_dir: Path) -> list[Path]:
    """Skill directories: those holding a SKILL.md, scaffolds (leading '_') excluded."""
    return sorted(
        d for d in skills_dir.iterdir()
        if d.is_dir() and not d.name.startswith("_") and (d / "SKILL.md").is_file()
    )


def read_header(skill_md: Path) -> dict:
    """Parse the SKILL.md front matter as YAML; raise ValueError if it is not a mapping."""
    try:
        text = skill_md.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        raise ValueError(f"cannot read SKILL.md: {exc}") from exc
    match = FRONTMATTER_RE.match(text)
    if not match:
        raise ValueError("no front matter")
    try:
        header = yaml.safe_load(match.group(1))
    except yaml.YAMLError as exc:
        raise ValueError(f"front matter is not valid YAML: {str(exc).splitlines()[0]}") from exc
    if not isinstance(header, dict):
        raise ValueError("front matter is not a mapping")
    return header


def header_errors(header: dict) -> list[str]:
    errors = []
    audience = header.get("audience")
    if audience not in AUDIENCES:
        errors.append(f"audience must be one of {list(AUDIENCES)}, got {audience!r}")
    runs_on = header.get("runs_on")
    if not isinstance(runs_on, list) or not runs_on:
        errors.append(f"runs_on must be a non-empty list of {list(AGENTS)}, got {runs_on!r}")
    elif not all(isinstance(a, str) for a in runs_on):
        errors.append(f"runs_on items must be agent names, got {runs_on!r}")
    else:
        unknown = [a for a in runs_on if a not in AGENTS]
        if unknown:
            errors.append(f"runs_on has unknown agents {unknown}, allowed {list(AGENTS)}")
        if len(set(runs_on)) != len(runs_on):
            errors.append("runs_on lists an agent twice")
    return errors


def check(skills_dir: Path) -> list[str]:
    """Return one line per problem across all skills of SKILLS_DIR."""
    problems = []
    for skill in skill_dirs(skills_dir):
        try:
            errors = header_errors(read_header(skill / "SKILL.md"))
        except ValueError as exc:
            errors = [str(exc)]
        problems.extend(f"{skill.name}: {error}" for error in errors)
    return problems


def select_for(agent: str, skills_dir: Path) -> list[str]:
    """Names of user skills that AGENT can run. A skill with a bad header is not selected."""
    if agent not in AGENTS:
        raise ValueError(f"unknown agent {agent!r}, allowed {list(AGENTS)}")
    selected = []
    for skill in skill_dirs(skills_dir):
        try:
            header = read_header(skill / "SKILL.md")
        except ValueError:
            continue
        if header_errors(header):
            continue
        if header["audience"] == "user" and agent in header["runs_on"]:
            selected.append(skill.name)
    return selected


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true", help="validate every skill header")
    mode.add_argument("--for", dest="agent", choices=AGENTS, help="list skills to expose to AGENT")
    parser.add_argument("skills_dir", type=Path)
    args = parser.parse_args(argv)
    if not args.skills_dir.is_dir():
        print(f"ERROR: {args.skills_dir} is not a directory", file=sys.stderr)
        return 2
    if args.check:
        problems = check(args.skills_dir)
        for problem in problems:
            print(f"FAIL: {problem}", file=sys.stderr)
        if problems:
            return 1
        print(f"OK: {len(skill_dirs(args.skills_dir))} skill headers declare audience and runs_on")
        return 0
    print("\n".join(select_for(args.agent, args.skills_dir)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
