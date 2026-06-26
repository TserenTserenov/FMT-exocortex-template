#!/usr/bin/env python3
"""Record agent faults into the IWE Agent Fault Profile SQLite database.

WP-316 compatibility backend for /agent-fault.
"""

from __future__ import annotations

import argparse
import json
import os
import sqlite3
from datetime import datetime, timezone
from pathlib import Path


SEVERITY_TRUST = {
    "minor": 0.60,
    "major": 0.80,
    "critical": 0.95,
}


def resolve_db_path() -> Path:
    override = os.environ.get("IWE_MEMORY_DB")
    if override:
        return Path(override).expanduser()

    workspace = Path(
        os.environ.get("WORKSPACE_DIR")
        or os.environ.get("IWE_WORKSPACE")
        or os.environ.get("IWE_DIR")
        or Path.home() / "IWE"
    ).expanduser()
    governance_repo = os.environ.get(
        "GOVERNANCE_REPO", os.environ.get("IWE_GOVERNANCE_REPO", "DS-strategy")
    )
    return workspace / governance_repo / "exocortex" / "agent-fault-profile" / "iwe_memory.db"


def init_db(db_path: Path) -> None:
    db_path.parent.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(db_path) as conn:
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS facts (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                fact_type TEXT NOT NULL,
                content TEXT NOT NULL,
                context TEXT,
                trust_score REAL DEFAULT 0.5,
                created_at TEXT DEFAULT CURRENT_TIMESTAMP,
                session_id TEXT
            )
            """
        )
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS feedback_sync_log (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                source_file TEXT,
                rule_name TEXT,
                synced_at TEXT DEFAULT CURRENT_TIMESTAMP
            )
            """
        )


def record_fault(args: argparse.Namespace) -> int:
    db_path = resolve_db_path()
    init_db(db_path)

    now = datetime.now(timezone.utc).isoformat()
    protocols = args.protocol or ["work"]
    context = {
        "source": "agent-fault",
        "severity": args.severity,
        "protocols": protocols,
        "short_content": args.fault,
        "occurrences": 1,
        "recorded_at": now,
    }
    if args.context:
        context["context"] = args.context

    session_id = args.session_id or os.environ.get("CLAUDE_SESSION_ID") or "agent-fault"
    trust_score = SEVERITY_TRUST[args.severity]

    with sqlite3.connect(db_path) as conn:
        cur = conn.execute(
            """
            INSERT INTO facts (fact_type, content, context, trust_score, session_id)
            VALUES (?, ?, ?, ?, ?)
            """,
            (
                "agent_fault",
                args.fault,
                json.dumps(context, ensure_ascii=False),
                trust_score,
                session_id,
            ),
        )
        row_id = cur.lastrowid

    result = {
        "status": "ok",
        "id": row_id,
        "severity": args.severity,
        "db_path": str(db_path),
    }
    print(json.dumps(result, ensure_ascii=False))
    return 0


def show_stats(_args: argparse.Namespace) -> int:
    db_path = resolve_db_path()
    if not db_path.exists():
        print(json.dumps({"status": "missing", "db_path": str(db_path)}, ensure_ascii=False))
        return 0

    with sqlite3.connect(db_path) as conn:
        total = conn.execute(
            "SELECT COUNT(*) FROM facts WHERE fact_type='agent_fault'"
        ).fetchone()[0]
    print(json.dumps({"status": "ok", "agent_faults": total, "db_path": str(db_path)}, ensure_ascii=False))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="IWE agent fault memory backend")
    sub = parser.add_subparsers(dest="command", required=True)

    record = sub.add_parser("record", help="record an agent fault")
    record.add_argument("--severity", choices=sorted(SEVERITY_TRUST), required=True)
    record.add_argument("--fault", required=True, help="fault description")
    record.add_argument(
        "--protocol",
        action="append",
        choices=["open", "close", "day_close", "work"],
        help="affected protocol; can be repeated",
    )
    record.add_argument("--context", default="", help="optional context")
    record.add_argument("--session-id", default="", help="optional session id")
    record.set_defaults(func=record_fault)

    stats = sub.add_parser("stats", help="show database stats")
    stats.set_defaults(func=show_stats)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
