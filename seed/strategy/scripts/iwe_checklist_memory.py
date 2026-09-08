#!/usr/bin/env python3
"""Legacy command name delegated to the installed canonical fault CLI."""

from __future__ import annotations

import os
import sys
from pathlib import Path
from typing import NoReturn, Sequence


def _installed_layout() -> tuple[Path, Path]:
    script_dir = Path(__file__).absolute().parent
    governance = script_dir.parent
    return governance.parent, governance


def _canonical_cli(workspace: Path) -> Path:
    physical_candidates = [
        workspace
        / "FMT-exocortex-template"
        / "scripts"
        / "agent-fault"
        / "iwe_checklist_memory.py",
        workspace / "scripts" / "agent-fault" / "iwe_checklist_memory.py",
    ]
    configured_candidates: list[Path] = []
    configured_scripts = os.environ.get("IWE_SCRIPTS", "").strip()
    if configured_scripts:
        configured_candidates.append(
            Path(configured_scripts).expanduser()
            / "agent-fault"
            / "iwe_checklist_memory.py"
        )
    configured_template = os.environ.get("IWE_TEMPLATE", "").strip()
    if configured_template:
        configured_candidates.append(
            Path(configured_template).expanduser()
            / "scripts"
            / "agent-fault"
            / "iwe_checklist_memory.py"
        )
    candidates = [*physical_candidates, *configured_candidates]
    try:
        physical_workspace = workspace.resolve(strict=True)
    except OSError as error:
        raise SystemExit(f"ERROR: installed workspace cannot be resolved: {error}")
    for candidate in candidates:
        try:
            resolved = candidate.resolve(strict=True)
            resolved.relative_to(physical_workspace)
        except (OSError, ValueError):
            continue
        if resolved.is_file():
            return resolved
    raise SystemExit(
        "ERROR: canonical agent-fault CLI is unavailable; expected one of: "
        + ", ".join(str(candidate) for candidate in candidates)
    )


def _translate_personality_subject(arguments: Sequence[str]) -> list[str]:
    translated: list[str] = []
    personality_id: str | None = None
    index = 0
    while index < len(arguments):
        argument = arguments[index]
        if argument == "--personality-id":
            if personality_id is not None or index + 1 >= len(arguments):
                raise SystemExit("ERROR: --personality-id requires one unique value")
            personality_id = arguments[index + 1]
            index += 2
            continue
        if argument.startswith("--personality-id="):
            if personality_id is not None:
                raise SystemExit("ERROR: --personality-id may be supplied only once")
            personality_id = argument.split("=", 1)[1]
            index += 1
            continue
        translated.append(argument)
        index += 1
    if personality_id is None:
        return translated
    if any(
        argument in {"--subject-kind", "--subject-id"}
        or argument.startswith(("--subject-kind=", "--subject-id="))
        for argument in translated
    ):
        raise SystemExit(
            "ERROR: --personality-id cannot be combined with explicit subject flags"
        )
    translated.extend(
        ("--subject-kind", "personality", "--subject-id", personality_id)
    )
    return translated


def main(argv: Sequence[str] | None = None) -> NoReturn:
    workspace, governance = _installed_layout()
    os.environ["IWE_WORKSPACE"] = str(workspace)
    os.environ["WORKSPACE_DIR"] = str(workspace)
    os.environ["IWE_GOVERNANCE_REPO"] = governance.name
    os.environ["GOVERNANCE_REPO"] = governance.name
    arguments = _translate_personality_subject(
        tuple(sys.argv[1:] if argv is None else argv)
    )
    cli = _canonical_cli(workspace)
    os.execv(sys.executable, [sys.executable, str(cli), *arguments])


if __name__ == "__main__":
    main()
