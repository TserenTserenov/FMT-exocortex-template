"""ledger_path.py — Python twin of lib/ledger-path.sh (WP-484, 31.07: same
year/month hierarchy migration for machine/ledger/, kept in lock-step by hand
since there are only two languages here, not a build step worth adding for two files).
"""

import os
from typing import Optional

_SCALE_TEMPLATES = {
    "day": "day/{year}/{month}/day-{period}.yaml",
    "week": "week/{year}/week-{period}.yaml",
    "month": "month/{year}/month-{period}.yaml",
}


def ledger_path_rel(scale: str, period: str) -> str:
    """Suffix only (no root, no mkdir) -- for existence checks against multiple
    roots (ledger_dir vs archive_dir) or a git-relative string, where creating
    a directory would be wasteful or wrong.

    day   period=YYYY-MM-DD -> day/YYYY/MM/day-YYYY-MM-DD.yaml
    week  period=YYYY-Wnn   -> week/YYYY/week-YYYY-Wnn.yaml
    month period=YYYY-MM    -> month/YYYY/month-YYYY-MM.yaml
    """
    template = _SCALE_TEMPLATES.get(scale)
    if template is None:
        raise ValueError(f"ledger_path_rel: недопустимый scale {scale!r} (day|week|month)")
    return template.format(year=period[:4], month=period[5:7], period=period)


def ledger_path(scale: str, period: str, root: str) -> str:
    """Full hierarchical path for a ledger file; creates parent dirs."""
    path = os.path.join(root, ledger_path_rel(scale, period))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    return path


def resolve_ledger_path(
    scale: str,
    period: str,
    active_root: str,
    archive_root: Optional[str] = None,
) -> str:
    """Return the period's one canonical readable path without creating anything.

    An archived file is used only when the active copy is absent. Two existing copies
    are split-brain drift, not an arbitrary precedence decision.
    """
    relative = ledger_path_rel(scale, period)
    active_path = os.path.join(active_root, relative)
    archive_path = os.path.join(archive_root, relative) if archive_root else None
    if archive_path and os.path.exists(active_path) and os.path.exists(archive_path):
        raise RuntimeError(
            f"ledger drift for {scale} {period}: both active and archived files exist "
            f"({active_path}; {archive_path})"
        )
    if os.path.exists(active_path):
        return active_path
    if archive_path and os.path.exists(archive_path):
        return archive_path
    return active_path
