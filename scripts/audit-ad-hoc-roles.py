#!/usr/bin/env python3
# see DP.SC.154 v4, WP-367 Ф5
"""
Каскад Pack-расширения для ad-hoc ролей в peer-сессиях.

Проходит по sessions/YYYY-MM/*/meta.yaml, агрегирует частоту ad_hoc_roles.
При freq ≥3 сессий И отсутствии открытого WP-NNN-pack-gap-<role> в inbox/
создаёт WP через FMT-exocortex-template/scripts/create-wp.sh.

Запуск: вручную при Week Close, либо через cron (не рекомендовано —
требует явного контекста пилота).

Output: stdout — отчёт по найденным ad-hoc ролям и созданным WP.
Exit: 0 при успехе, 1 при ошибке pre-flight, 2 при ошибке create-wp.
"""

from __future__ import annotations

import os
import sys
import glob
import yaml
import subprocess
import argparse
from collections import defaultdict
from pathlib import Path
from typing import Optional

WORKSPACE_DIR = Path(
    os.environ.get("WORKSPACE_DIR")
    or os.environ.get("IWE_WORKSPACE")
    or Path.home() / "IWE"
).expanduser()
GOVERNANCE_REPO = os.environ.get(
    "GOVERNANCE_REPO", os.environ.get("IWE_GOVERNANCE_REPO", "DS-strategy")
)
DS_MY_STRATEGY = WORKSPACE_DIR / GOVERNANCE_REPO
SESSIONS_DIR = DS_MY_STRATEGY / "sessions"
INBOX_DIR = DS_MY_STRATEGY / "inbox"
CREATE_WP_SCRIPT = WORKSPACE_DIR / "FMT-exocortex-template" / "scripts" / "create-wp.sh"

FREQ_THRESHOLD = 3  # минимум сессий с одной ad-hoc ролью для создания WP


def find_meta_files():
    return sorted(SESSIONS_DIR.glob("[0-9][0-9][0-9][0-9]-[0-9][0-9]/*/meta.yaml"))


def load_ad_hoc_roles(meta_path):
    # Часть исторических meta.yaml имеют ведущий `---` и трактуются как multi-doc.
    # safe_load_all берёт первый документ — он содержит нужный frontmatter.
    try:
        with meta_path.open(encoding="utf-8") as f:
            docs = list(yaml.safe_load_all(f))
    except (yaml.YAMLError, OSError) as e:
        print(f"WARN: cannot parse {meta_path}: {e}", file=sys.stderr)
        return {}
    meta = next((d for d in docs if isinstance(d, dict)), {}) or {}
    return meta.get("ad_hoc_roles") or {}


def aggregate(meta_files):
    role_to_sessions = defaultdict(list)
    for meta_path in meta_files:
        session_id = meta_path.parent.name
        ad_hoc = load_ad_hoc_roles(meta_path)
        if not isinstance(ad_hoc, dict):
            continue
        for role_name in ad_hoc:
            role_to_sessions[role_name].append(session_id)
    return role_to_sessions


def existing_pack_gap_wp(role_name):
    slug_part = f"pack-gap-{role_name.lower().replace(' ', '-')}"
    # Конвенция inbox (см. INBOX-CONVENTION): inbox/WP-N/WP-N.md ИЛИ inbox/WP-N.md
    registry_path = DS_MY_STRATEGY / "docs" / "WP-REGISTRY.md"
    if registry_path.exists():
        try:
            content = registry_path.read_text(encoding="utf-8")
        except OSError:
            content = ""
        if slug_part in content.lower():
            return registry_path
    candidates = list(INBOX_DIR.glob(f"WP-*{slug_part}*.md")) + list(INBOX_DIR.glob(f"WP-*{slug_part}*"))
    return candidates[0] if candidates else None


def create_pack_gap_wp(role_name, source_sessions, dry_run):
    title = f"Pack-gap для роли «{role_name}» (каскад audit)"
    body = (
        f"Триггер: weekly audit ad-hoc roles (WP-367 Ф5, DP.SC.154 v4 каскад).\n"
        f"Частота: {len(source_sessions)} сессий.\n"
        f"Источники: {', '.join(source_sessions)}.\n"
        f"Действие: формализовать DP.ROLE.NNN или MIM.R.NNN с обязанностями, методом, "
        f"критериями качества; обновить каталог Pack.\n"
    )
    if dry_run:
        print(f"DRY-RUN: would create WP «{title}»")
        print(body)
        return 0
    if not CREATE_WP_SCRIPT.exists():
        print(f"ERROR: create-wp.sh not found at {CREATE_WP_SCRIPT}", file=sys.stderr)
        return 2
    slug = f"pack-gap-{role_name.lower().replace(' ', '-')}"
    result = subprocess.run(
        [
            "bash", str(CREATE_WP_SCRIPT),
            "--title", title,
            "--budget", "2h",
            "--priority", "P3",
            "--slug", slug,
            "--related", "WP-367",
        ],
        cwd=str(DS_MY_STRATEGY),
        capture_output=True,
        text=True,
    )
    print(result.stdout)
    if result.returncode != 0:
        print(f"ERROR: create-wp.sh failed: {result.stderr}", file=sys.stderr)
        return 2
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Audit ad-hoc roles in peer-sessions")
    parser.add_argument("--dry-run", action="store_true", help="Report only, do not create WPs")
    parser.add_argument("--threshold", type=int, default=FREQ_THRESHOLD)
    args = parser.parse_args()

    if not SESSIONS_DIR.exists():
        print(f"ERROR: {SESSIONS_DIR} not found", file=sys.stderr)
        return 1

    meta_files = find_meta_files()
    print(f"Scanned {len(meta_files)} meta.yaml files")

    role_to_sessions = aggregate(meta_files)
    print(f"Unique ad-hoc roles found: {len(role_to_sessions)}")

    rc = 0
    for role_name, sessions in sorted(role_to_sessions.items(), key=lambda kv: -len(kv[1])):
        freq = len(sessions)
        marker = " [BELOW THRESHOLD]" if freq < args.threshold else ""
        print(f"  {role_name}: {freq} sessions{marker}")
        if freq < args.threshold:
            continue
        existing = existing_pack_gap_wp(role_name)
        if existing:
            print(f"    skip: WP already exists at {existing}")
            continue
        rc = max(rc, create_pack_gap_wp(role_name, sessions, args.dry_run))

    return rc


if __name__ == "__main__":
    sys.exit(main())
