#!/usr/bin/env python3
"""Legacy reminder arguments delegated to the canonical fault CLI."""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path
from typing import NoReturn, Sequence


SUBJECT_KINDS = ("personality", "runtime", "system")
COMPATIBILITY_CLI = Path(__file__).absolute().with_name("iwe_checklist_memory.py")


def _subject(arguments: argparse.Namespace) -> tuple[str, str] | None:
    flag_kind = arguments.subject_kind
    flag_id = arguments.subject_id
    if bool(flag_kind) != bool(flag_id):
        raise SystemExit(
            "ERROR: --subject-kind and --subject-id must be supplied together"
        )
    if flag_kind and flag_id:
        return flag_kind, flag_id
    env_kind = os.environ.get("IWE_FAULT_SUBJECT_KIND", "")
    env_id = os.environ.get("IWE_FAULT_SUBJECT_ID", "")
    if bool(env_kind) != bool(env_id):
        raise SystemExit(
            "ERROR: IWE_FAULT_SUBJECT_KIND and IWE_FAULT_SUBJECT_ID must be "
            "supplied together"
        )
    return (env_kind, env_id) if env_kind else None


def main(argv: Sequence[str] | None = None) -> NoReturn:
    parser = argparse.ArgumentParser(
        description="Compatibility reminder for the canonical fault CLI",
        allow_abbrev=False,
    )
    parser.add_argument("--protocol", choices=("open", "close", "day_close", "work", "all"), default="work")
    parser.add_argument("--limit", type=int, default=3)
    parser.add_argument("--context", default="")
    parser.add_argument("--stats", action="store_true")
    parser.add_argument("--subject-kind", choices=SUBJECT_KINDS)
    parser.add_argument("--subject-id")
    arguments = parser.parse_args(argv)
    subject = _subject(arguments)
    if subject is None:
        raise SystemExit("ERROR: reminder and stats require one exact subject")

    if arguments.stats:
        command = [
            "stats",
            "--subject-kind",
            subject[0],
            "--subject-id",
            subject[1],
        ]
    else:
        command = [
            "remind",
            "--protocol",
            arguments.protocol,
            "--limit",
            str(arguments.limit),
            "--context",
            arguments.context,
            "--subject-kind",
            subject[0],
            "--subject-id",
            subject[1],
        ]
    os.execv(
        sys.executable,
        [sys.executable, str(COMPATIBILITY_CLI), *command],
    )


if __name__ == "__main__":
    main()
