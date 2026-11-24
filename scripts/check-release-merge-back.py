#!/usr/bin/env python3
"""Check the CHANGELOG of a release back-merge PR (WP-529 Phase 268).

Under the "release from the release branch" order the release PR
release/vX.Y.Z -> main is merged after the release. scripts/changelog-flush.sh
put the version header right under "## [Unreleased]" on the branch, while
entries keep arriving in [Unreleased] of main. Git merges the two cleanly, and
every entry added to main after the cut slides under "## [X.Y.Z]": it silently
leaves [Unreleased], the next release and the board.

This check compares the "## [X.Y.Z]" section of CHANGELOG.md at --ref (the PR
merge result, as GitHub checks it out) with the same section at the release:
tag vX.Y.Z, or the highest vX.Y.Z-rc.N while there is no tag yet. They must be
equal. It also refuses the "на разметке" placeholder outside [Unreleased]:
entries delivered with it never went through a release branch.

Usage:
    check-release-merge-back.py --version X.Y.Z [--ref REF] [--release-ref REF]

Exit: 0 - the merge keeps the released section as released; 1 - problems
(listed on stdout); 2 - invocation or read error (no release ref, no file).
"""

from __future__ import annotations

import argparse
import importlib.util
import re
import subprocess
import sys
from pathlib import Path

PLACEHOLDER = "на разметке"
VERSION = re.compile(r"^\d+\.\d+\.\d+$")


def load_fields_module():
    path = Path(__file__).with_name("check-changelog-fields.py")
    spec = importlib.util.spec_from_file_location("check_changelog_fields", path)
    if spec is None or spec.loader is None:
        raise SystemExit(f"не найден {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


FIELDS = load_fields_module()


def git(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(["git", *args], capture_output=True, text=True, encoding="utf-8")


def release_ref(version: str) -> str | None:
    """Tag vX.Y.Z; without it the highest vX.Y.Z-rc.N; None when neither exists."""
    tag = f"v{version}"
    if git("rev-parse", "-q", "--verify", f"refs/tags/{tag}^{{commit}}").returncode == 0:
        return tag
    pattern = re.compile(r"^v" + re.escape(version) + r"-rc\.(\d+)$")
    rcs = [(int(m.group(1)), name) for name in git("tag", "-l", f"v{version}-rc.*").stdout.split()
           if (m := pattern.match(name))]
    return max(rcs)[1] if rcs else None


def changelog_at(ref: str) -> str:
    result = git("show", f"{ref}:CHANGELOG.md")
    if result.returncode != 0:
        raise SystemExit(f"ОШИБКА: не удалось прочитать CHANGELOG.md в {ref}: {result.stderr.strip()}")
    return result.stdout


def trimmed(lines: list[str]) -> list[str]:
    lines = [line.rstrip() for line in lines]
    while lines and not lines[0]:
        lines.pop(0)
    while lines and not lines[-1]:
        lines.pop()
    return lines


def placeholder_lines(text: str) -> list[str]:
    """Lines with the placeholder outside [Unreleased], prefixed with their section."""
    found: list[str] = []
    section = ""
    for line in text.splitlines():
        if line.startswith("## ["):
            section = line.split("]", 1)[0] + "]"
            continue
        if PLACEHOLDER in line and section != "## [Unreleased]":
            found.append(f"{section or 'вне разделов'}: {line.strip()}")
    return found


def check(version: str, ref: str, released_at: str) -> list[str]:
    problems: list[str] = []
    head_text = changelog_at(ref)
    head = FIELDS.section_lines(head_text, version)
    released = FIELDS.section_lines(changelog_at(released_at), version)
    if released is None:
        raise SystemExit(f"ОШИБКА: в {released_at} нет раздела [{version}] в CHANGELOG.md")
    if head is None:
        problems.append(f"Раздела [{version}] нет в CHANGELOG.md слияния — вышедший выпуск пропал из журнала.")
    elif trimmed(head) != trimmed(released):
        head_tops = [e.top for e in FIELDS.parse_entries(head)]
        released_tops = [e.top for e in FIELDS.parse_entries(released)]
        extra = [top for top in head_tops if top not in released_tops]
        missing = [top for top in released_tops if top not in head_tops]
        problems.append(f"Раздел [{version}] после слияния отличается от вышедшего ({released_at}).")
        if extra:
            problems.append(
                f"Лишние записи в [{version}] — их не было в выпуске, они попали в main после нарезки "
                f"и при слиянии съехали под заголовок версии. Перенесите их обратно в [Unreleased] в этом PR "
                f"(влейте main в ветку выпуска, перенесите записи, отправьте ветку):")
            problems += [f"  {top}" for top in extra]
        if missing:
            problems.append(f"Пропали записи выпуска {released_at} — верните их в [{version}]:")
            problems += [f"  {top}" for top in missing]
        if not extra and not missing:
            problems.append("Записи те же, отличается текст раздела: верните его к виду выпуска.")
    stray = placeholder_lines(head_text)
    if stray:
        problems.append(f"Заглушка «{PLACEHOLDER}» вне [Unreleased] — запись не прошла ветку выпуска, "
                        f"её место в [Unreleased]:")
        problems += [f"  {line}" for line in stray]
    return problems


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--version", required=True)
    parser.add_argument("--ref", default="HEAD", help="merge result to check (default: HEAD)")
    parser.add_argument("--release-ref", help="released commit (default: tag vX.Y.Z or the last rc)")
    args = parser.parse_args(argv)
    if not VERSION.match(args.version):
        print(f"ОШИБКА: версия должна быть вида X.Y.Z, получено: '{args.version}'")
        return 2
    released_at = args.release_ref or release_ref(args.version)
    if released_at is None:
        print(f"ОШИБКА: нет ни метки v{args.version}, ни кандидата v{args.version}-rc.N — сверять не с чем.")
        return 2
    try:
        problems = check(args.version, args.ref, released_at)
    except SystemExit as error:
        print(error)
        return 2
    if problems:
        print("\n".join(problems))
        return 1
    print(f"OK: раздел [{args.version}] совпадает с {released_at}, заглушек вне [Unreleased] нет")
    return 0


if __name__ == "__main__":
    sys.exit(main())
