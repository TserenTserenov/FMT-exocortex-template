# see DP.SC.053 §2.bis L-B mode invariant, WP-425 Level 2a
# SNAPSHOT — synced manually via script-promote.sh from FMT-exocortex-template/scripts/. Do not edit here directly.
"""
Periodic updater for the local derived_snapshot.json (WP-425 Level 2a).

Fetches cp-profile from Aisystant Cloud MCP via headless claude subprocess,
parses 3_4_qualification schema, writes to local cache.

Design: runs in launchd (Sunday 08:00) and optionally from Day Open (--if-stale-days).
Zero network calls during guide assembly; this script is the separated update channel.

Usage:
  python3 scripts/update-derived-snapshot.py
  python3 scripts/update-derived-snapshot.py --if-stale-days 10
  python3 scripts/update-derived-snapshot.py --dry-run
"""
import argparse
import datetime
import json
import logging
import os
import pathlib
import subprocess
import sys
from typing import Optional


def _installed_governance_root() -> Optional[pathlib.Path]:
    """Return the physical repo root when this copy is installed in governance."""
    script_repo = pathlib.Path(__file__).resolve().parent.parent
    repo_type_path = script_repo / "REPO-TYPE.md"
    try:
        repo_type = repo_type_path.read_text(encoding="utf-8")
    except (OSError, UnicodeError):
        return None
    if "`DS/governance`" not in repo_type:
        return None
    return script_repo


def _resolve_snapshot_path() -> pathlib.Path:
    """Resolve cache location, preferring an installed copy's physical repo."""
    installed_root = _installed_governance_root()
    if installed_root is not None:
        return installed_root / "inbox/WP-425/cache/derived_snapshot.json"

    configured_root = os.environ.get("IWE_ROOT") or os.environ.get("IWE_WORKSPACE")
    iwe_root = (
        pathlib.Path(configured_root).expanduser()
        if configured_root
        else pathlib.Path.home() / "IWE"
    )
    governance_repo = os.environ.get("IWE_GOVERNANCE_REPO", "DS-strategy")
    return iwe_root / governance_repo / "inbox/WP-425/cache/derived_snapshot.json"


SNAPSHOT_PATH = _resolve_snapshot_path()

# Maps stage_id strings from 3_4_qualification to integer stage levels.
# Source: render-pilot-guides.py _STAGE_ID_TO_INT (OwnerIntegrity: single mapping table).
_STAGE_ID_TO_INT = {
    "STG.Student.Random": 1,
    "STG.Student.Practicing": 2,
    "STG.Student.Systematic": 3,
    "STG.Student.Disciplined": 4,
    "STG.Student.Proactive": 5,
}

_STAGE_INT_TO_LABEL = {
    1: "Случайный", 2: "Практикующий", 3: "Систематический",
    4: "Дисциплинированный", 5: "Проактивный",
}

# RCS slots tracked in rcs_indices (M3/IT/A are rarely bottlenecks but included for completeness).
_RCS_SLOTS = ["W", "M1", "M2", "M3", "M4", "IT", "A"]

# Claude Code registers MCP tools as mcp__<server>__<tool>; the short tool name
# alone never matches --allowedTools, so a headless call is silently denied at
# the permission gate (no TTY to prompt) and every retry fails the same way.
# See bug-2026-07-12-digital-twin-fetch-fails-headless.md.
_ALLOWED_TOOL_DT_READ = "mcp__claude_ai_IWE__dt_read_digital_twin"


def _is_stale(stale_days: int) -> bool:
    """Return True if snapshot is missing or older than stale_days."""
    if not SNAPSHOT_PATH.exists():
        return True
    try:
        data = json.loads(SNAPSHOT_PATH.read_text(encoding="utf-8"))
        snap_date = datetime.date.fromisoformat(data.get("snapshot_date", "2000-01-01"))
        age = (datetime.date.today() - snap_date).days
        return age >= stale_days
    except (json.JSONDecodeError, ValueError):
        return True


def _fetch_derived_via_headless_claude() -> dict:
    """
    Call headless claude to read 3_derived path from Aisystant MCP.

    Returns the parsed qualification dict, or raises RuntimeError on failure.
    """
    prompt = (
        "Use the dt_read_digital_twin MCP tool with path='3_derived'. "
        "Return ONLY a valid JSON object with the full response content — "
        "no explanation, no markdown fences, just raw JSON."
    )
    try:
        result = subprocess.run(
            ["claude", "-p", prompt, "--allowedTools", _ALLOWED_TOOL_DT_READ,
             "--output-format", "text"],
            capture_output=True, text=True, timeout=120,
        )
    except FileNotFoundError as exc:
        raise RuntimeError("claude CLI not found — ensure it is in PATH") from exc
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError("claude subprocess timed out after 120s") from exc

    if result.returncode != 0:
        raise RuntimeError(
            f"claude exited {result.returncode}: {result.stderr[:300]}"
        )

    raw = result.stdout.strip()
    if not raw:
        raise RuntimeError("claude returned empty output")

    # Strip markdown code fences if claude adds them despite the prompt.
    if raw.startswith("```"):
        lines = raw.splitlines()
        raw = "\n".join(lines[1:-1] if lines[-1] == "```" else lines[1:])

    try:
        return json.loads(raw)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"Failed to parse JSON from claude output: {exc}\nOutput: {raw[:200]}") from exc


def _parse_qualification(response: dict) -> dict:
    """
    Extract stage, bottleneck, rcs_indices from dt_read_digital_twin response.

    Expected shape (from digital_twins.data->'3_derived'->'3_4_qualification'):
      {"stage_id": "STG.Student.Proactive", "rcs_indices": {"W": N, "M1": N, ...}}
    The MCP response may wrap this under a content key.
    """
    # Unwrap common MCP response envelope shapes.
    data = response
    for key in ("content", "data", "3_derived", "result"):
        if isinstance(data, dict) and key in data and isinstance(data[key], dict):
            data = data[key]

    # Locate 3_4_qualification — may be nested or top-level, under either the
    # current key or the pre-WP-462 name (render-pilot-guides.py:_rcs_from_digital_twin
    # hit the same profiler rename and checks both; mirrored here).
    def _find_qual(d: dict):
        return d.get("3_4_qualification_estimate") or d.get("3_4_qualification")

    qual = _find_qual(data) or _find_qual(data.get("3_derived", {})) or data
    if not isinstance(qual, dict):
        raise RuntimeError(f"Cannot locate 3_4_qualification in response: {str(response)[:300]}")

    stage_id = qual.get("stage_id", "")
    stage = _STAGE_ID_TO_INT.get(stage_id)
    if not stage:
        raw_stage = qual.get("stage")
        stage = int(raw_stage) if raw_stage and str(raw_stage).isdigit() and int(raw_stage) >= 1 else None
    if not stage:
        raise RuntimeError(f"Unknown stage_id '{stage_id}' and no fallback stage in response")

    rcs = qual.get("rcs_indices", {})
    if isinstance(rcs, str):
        rcs = json.loads(rcs)
    if not isinstance(rcs, dict):
        raise RuntimeError(f"rcs_indices has unexpected type {type(rcs).__name__}")
    # Each slot is {"idx": N, ...metadata} (calibrated/streak/events), not a bare
    # number — same shape render-pilot-guides.py:_rcs_from_digital_twin already
    # unwraps. Surfaced only once the fetch itself started working (bug-2026-07-12):
    # the old `rcs.get(s, 0)` returned the dict itself, TypeError on min() below.
    slot_vals = {
        s: rcs[s]["idx"] for s in _RCS_SLOTS
        if isinstance(rcs.get(s), dict) and "idx" in rcs[s]
    }
    if not slot_vals:
        raise RuntimeError("rcs_indices missing or empty in qualification data")

    # Bottleneck = slot with minimum value; M1 preferred on ties.
    bottleneck = min(slot_vals, key=lambda k: (slot_vals[k], k != "M1"))

    # bottleneck can land on a rare slot (M3/IT/A, kept in _RCS_SLOTS "for
    # completeness") not among the 4 always shown — keep it in rcs too, so
    # bottleneck_slot never names a key absent from the snapshot's own rcs.
    rcs_keys = ["W", "M1", "M2", "M4"]
    if bottleneck not in rcs_keys:
        rcs_keys.append(bottleneck)

    return {
        "stage_raw": stage,
        "stage_label": _STAGE_INT_TO_LABEL.get(stage, f"Ступень {stage}"),
        "bottleneck_slot": bottleneck,
        "rcs": {s: slot_vals[s] for s in rcs_keys if s in slot_vals},
    }


def _build_snapshot(parsed: dict, existing: dict) -> dict:
    """Merge parsed qualification into existing snapshot, updating fields."""
    now = datetime.date.today().isoformat()
    snapshot = dict(existing)
    snapshot.update({
        "snapshot_date": now,
        "stage_raw": parsed["stage_raw"],
        "stage_label": parsed["stage_label"],
        "bottleneck_slot": parsed["bottleneck_slot"],
        "rcs": parsed["rcs"],
        "valid_for_stage": parsed["stage_raw"],
        "source": "mcp-fetched",
        "refresh_channel": "periodic-bundle",
    })
    return snapshot


def main() -> int:
    parser = argparse.ArgumentParser(
        description="WP-425 Level 2a: periodic derived_snapshot updater"
    )
    parser.add_argument(
        "--if-stale-days", type=int, default=0, metavar="N",
        help="Skip update if snapshot is fresher than N days (0 = always update)"
    )
    parser.add_argument(
        "--dry-run", action="store_true",
        help="Fetch and parse data but do not write to disk"
    )
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO, stream=sys.stderr,
                        format="%(levelname)s %(message)s")

    if args.if_stale_days > 0 and not _is_stale(args.if_stale_days):
        logging.info("Snapshot is fresh (< %d days old) — skipping update", args.if_stale_days)
        return 0

    logging.info("Fetching 3_derived via headless claude...")
    try:
        response = _fetch_derived_via_headless_claude()
    except Exception as exc:
        # Broad on purpose: this is a cron/launchd entry point — any unexpected
        # failure (incl. shapes we didn't anticipate) must log one clean line,
        # not a raw traceback, so the cron log stays scannable.
        logging.error("Fetch failed: %s", exc)
        return 1

    logging.info("Parsing 3_4_qualification...")
    try:
        parsed = _parse_qualification(response)
    except Exception as exc:
        logging.error("Parse failed: %s", exc)
        return 1

    existing = {}
    if SNAPSHOT_PATH.exists():
        try:
            existing = json.loads(SNAPSHOT_PATH.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            logging.warning("Existing snapshot is corrupt — overwriting")

    snapshot = _build_snapshot(parsed, existing)
    logging.info(
        "stage=%s bottleneck=%s (was: stage=%s bottleneck=%s)",
        snapshot["stage_raw"], snapshot["bottleneck_slot"],
        existing.get("stage_raw", "?"), existing.get("bottleneck_slot", "?"),
    )

    if args.dry_run:
        print(json.dumps(snapshot, ensure_ascii=False, indent=2))
        return 0

    SNAPSHOT_PATH.parent.mkdir(parents=True, exist_ok=True)
    SNAPSHOT_PATH.write_text(json.dumps(snapshot, ensure_ascii=False, indent=2), encoding="utf-8")
    logging.info("Wrote snapshot to %s", SNAPSHOT_PATH)
    return 0


if __name__ == "__main__":
    sys.exit(main())
