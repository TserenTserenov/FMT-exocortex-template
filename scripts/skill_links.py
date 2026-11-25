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


def is_own_link(path: Path, skills_root: Path) -> bool:
    """A symlink whose target, once resolved, lies inside skills_root (broken targets included)."""
    if not path.is_symlink():
        return False
    # realpath resolves every symlink on the way (macOS /tmp -> /private/tmp) and
    # still answers for a broken target, so a dangling own link stays ours.
    target = Path(os.path.realpath(path.parent / os.readlink(path)))
    return skills_root == target.parent or skills_root in target.parents


def sync(workspace: Path, agent: str, dry_run: bool = False) -> Report:
    skills_root = (workspace / ".claude" / "skills").resolve()
    folder = workspace / AGENT_FOLDERS[agent]
    wanted = set(skill_agents.select_for(agent, skills_root))
    report = Report()
    occupied: set[str] = set()  # wanted names whose place holds something that is not ours

    if folder.exists() or folder.is_symlink():
        if folder.is_symlink() or not folder.is_dir():
            report.conflicts.append(f"{folder} is not a plain directory; nothing linked")
            return report
        for entry in sorted(folder.iterdir()):
            if not is_own_link(entry, skills_root):
                if entry.name in wanted:
                    occupied.add(entry.name)
                    report.conflicts.append(f"{entry.name}: {entry} is not our link, left untouched")
                continue
            target_ok = (skills_root / entry.name / "SKILL.md").is_file()
            if entry.name in wanted and target_ok and entry.resolve() == skills_root / entry.name:
                report.kept.append(entry.name)
                continue
            report.removed.append(entry.name)
            if not dry_run:
                entry.unlink()

    for name in sorted(wanted - set(report.kept) - occupied):
        report.created.append(name)
        if dry_run:
            continue
        try:
            folder.mkdir(parents=True, exist_ok=True)
            relative = os.path.relpath(skills_root / name, folder.resolve())
            (folder / name).symlink_to(relative, target_is_directory=True)
        except OSError as exc:
            report.created.remove(name)
            report.refused.append(f"{name}: cannot create a symlink ({exc.strerror}); see docs/AGENT-VENDOR-SETUP.md")
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
    except OSError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    print("\n".join(report.lines(args.dry_run)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
