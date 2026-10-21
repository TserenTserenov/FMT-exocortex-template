#!/usr/bin/env python3
"""Legacy feedback import name pinned to the canonical system subject."""

from __future__ import annotations

import os
import sys
from pathlib import Path
from typing import NoReturn, Sequence


COMPATIBILITY_CLI = Path(__file__).absolute().with_name("iwe_checklist_memory.py")


def main(argv: Sequence[str] | None = None) -> NoReturn:
    arguments = list(sys.argv[1:] if argv is None else argv)
    if any(
        argument in {"--subject-kind", "--subject-id"}
        or argument.startswith(("--subject-kind=", "--subject-id="))
        for argument in arguments
    ):
        raise SystemExit(
            "ERROR: feedback compatibility import is fixed to "
            "system:feedback-import; subject overrides are not allowed"
        )
    os.execv(
        sys.executable,
        [
            sys.executable,
            str(COMPATIBILITY_CLI),
            "import-feedback",
            *arguments,
            "--subject-kind",
            "system",
            "--subject-id",
            "feedback-import",
        ],
    )


if __name__ == "__main__":
    main()
