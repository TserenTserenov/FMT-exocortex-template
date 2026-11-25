#!/usr/bin/env python3
"""Per-skill links that let another agent see the workspace skills (WP-592 Ф7).

Codex reads skills only from <workspace>/.agents/skills, not from .claude/skills.
Instead of copies (a second editable version that drifts), this program puts one
relative symlink per skill into the agent's folder, pointing at the skill in
.claude/skills. Which skills: skill_agents.select_for(agent) — user skills that
list the agent in runs_on (decision DRR-f7-skills-delivery-links, 2026-11-25).

Link contract:
  * only skills from the selection get a link;
  * a link is "ours" when it is a symlink whose target resolves inside
    <workspace>/.claude/skills; only ours are created, replaced or removed;
  * anything else at a link's place (a real directory, a file, a symlink
    elsewhere) is left untouched and reported as a conflict;
  * an own link whose skill left the selection or no longer exists is removed;
  * no copy fallback: where a symlink cannot be created, the skill is reported
    and the agent setup guide explains the manual step.

Usage:
  python3 skill_links.py --workspace DIR [--agent codex] [--dry-run]
Exit 0 after a completed pass (conflicts and refused links are reported on
stdout, they do not fail an install); 2 on bad arguments or unreadable skills.
"""
from __future__ import annotations

import argparse
import os
import sys
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import skill_agents  # noqa: E402  (sibling module, path set above)

AGENT_FOLDERS = {"codex": Path(".agents") / "skills"}


@dataclass
class Report:
    created: list[str] = field(default_factory=list)
    removed: list[str] = field(default_factory=list)
    kept: list[str] = field(default_factory=list)
    conflicts: list[str] = field(default_factory=list)
    refused: list[str] = field(default_factory=list)

    def lines(self, dry_run: bool) -> list[str]:
        verb = "would " if dry_run else ""
        out = [f"{verb}link: {n}" for n in self.created]
        out += [f"{verb}unlink: {n}" for n in self.removed]
        out += [f"CONFLICT: {n}" for n in self.conflicts]
        out += [f"REFUSED: {n}" for n in self.refused]
        out.append(
            f"skill links: {len(self.created)} new, {len(self.kept)} kept, {len(self.removed)} removed, "
            f"{len(self.conflicts)} conflicts, {len(self.refused)} refused"
        )
        return out


def link_target(path: Path) -> Path:
    """Where a symlink points after one step: its parent resolved, its own target not.

    One step only, so a skill folder that is itself a symlink does not move the
    answer outside .claude/skills (that skill is refused before linking instead).
    """
    return Path(os.path.normpath(os.path.join(os.path.realpath(path.parent), os.readlink(path))))


def is_own_link(path: Path, skills_root: Path) -> bool:
    """A symlink pointing (one step) at an entry inside skills_root; dangling ones included."""
    return path.is_symlink() and link_target(path).parent == skills_root


def skill_inside(name: str, skills_root: Path) -> bool:
    """The skill folder, after every symlink is resolved, still lies inside skills_root."""
    return skills_root in Path(os.path.realpath(skills_root / name)).parents


def folder_problem(folder: Path) -> str:
    """Why the agent folder cannot be used, or '' when it is usable (absent or a plain directory)."""
    for level in (folder.parent, folder):
        if level.is_symlink():
            return f"{level} is a symlink; links there would land in another place, nothing linked"
        if level.exists() and not level.is_dir():
            return f"{level} is not a directory; nothing linked"
    return ""


def remove_link(entry: Path, report: Report, dry_run: bool) -> None:
    report.removed.append(entry.name)
    if dry_run:
        return
    try:
        if entry.is_symlink():  # re-check right before unlink: never remove a real file
            entry.unlink()
    except OSError as exc:
        report.removed.remove(entry.name)
        report.refused.append(f"{entry.name}: cannot remove the old link ({exc.strerror})")


def create_link(name: str, folder: Path, skills_root: Path, report: Report, dry_run: bool) -> None:
    if not skill_inside(name, skills_root):
        report.refused.append(f"{name}: the skill folder points outside .claude/skills, not linked")
        return
    report.created.append(name)
    if dry_run:
        return
    try:
        folder.mkdir(parents=True, exist_ok=True)
        relative = os.path.relpath(skills_root / name, os.path.realpath(folder))
        (folder / name).symlink_to(relative, target_is_directory=True)
    except OSError as exc:
        report.created.remove(name)
        report.refused.append(f"{name}: cannot create a symlink ({exc.strerror}); see docs/AGENT-VENDOR-SETUP.md")


def sync(workspace: Path, agent: str, dry_run: bool = False) -> Report:
    skills_root = Path(os.path.realpath(workspace / ".claude" / "skills"))
    folder = workspace / AGENT_FOLDERS[agent]
    wanted = set(skill_agents.select_for(agent, skills_root))
    report = Report()
    problem = folder_problem(folder)
    if problem:
        report.conflicts.append(problem)
        return report

    occupied: set[str] = set()  # wanted names whose place holds something that is not ours
    for entry in sorted(folder.iterdir()) if folder.is_dir() else []:
        if not is_own_link(entry, skills_root):
            if entry.name in wanted:
                occupied.add(entry.name)
                report.conflicts.append(f"{entry.name}: {entry} is not our link, left untouched")
            continue
        current = entry.name in wanted and link_target(entry) == skills_root / entry.name \
            and skill_inside(entry.name, skills_root) and (skills_root / entry.name / "SKILL.md").is_file()
        if current:
            report.kept.append(entry.name)
        else:
            remove_link(entry, report, dry_run)

    for name in sorted(wanted - set(report.kept) - occupied):
        create_link(name, folder, skills_root, report, dry_run)
    return report


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--workspace", type=Path, required=True)
    parser.add_argument("--agent", choices=sorted(AGENT_FOLDERS), default="codex")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args(argv)
    if not (args.workspace / ".claude" / "skills").is_dir():
        print(f"ERROR: {args.workspace}/.claude/skills not found", file=sys.stderr)
        return 2
    try:
        report = sync(args.workspace, args.agent, args.dry_run)
    except Exception as exc:  # install/update print this line and go on; no traceback for users
        print(f"ERROR: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 2
    print("\n".join(report.lines(args.dry_run)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
