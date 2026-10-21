#!/usr/bin/env python3
"""Compatibility entrypoint for explicit feedback import.

All database access belongs to ``scripts/agent-fault/iwe_checklist_memory.py``;
this file intentionally contains no SQLite implementation of its own.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path


CLI = Path(__file__).resolve().parent / "agent-fault" / "iwe_checklist_memory.py"


def main() -> None:
    if not CLI.is_file():
        raise SystemExit(f"ERROR: canonical agent-fault CLI is missing: {CLI}")
    for argument in sys.argv[1:]:
        if argument in {"--subject-kind", "--subject-id"} or argument.startswith(
            ("--subject-kind=", "--subject-id=")
        ):
            raise SystemExit(
                "ERROR: this compatibility wrapper fixes attribution to "
                "system:feedback-import; subject overrides are not allowed"
            )
    os.execv(
        sys.executable,
        [
            sys.executable,
            str(CLI),
            "import-feedback",
            *sys.argv[1:],
            "--subject-kind",
            "system",
            "--subject-id",
            "feedback-import",
        ],
    )


if __name__ == "__main__":
    main()
