#!/usr/bin/env bash
# WP-358 Phase10 — detector of unclosed external-sessions.
# Outputs markdown-section for insertion into DayPlan (Day Open) or warning (Day Close).
#
# Open session = SESSION-<id>.md in inbox/agent/sessions/ AND:
#   - mtime ≥ CUTOVER_DATE (after introduction of Phase10, backfill 52 backfill of 52 old ones is not done) AND
#   - status != "completed" OR (status: completed AND age ≥ STALE_HOURS)
#
# Finalized (per Phase10) = moved to sessions/external/YYYY-MM/SESSION-<id>/
# — the detector does not see it, because the file is not present in inbox/agent/sessions/.
#
# Exit 0 always. Stdout = markdown (empty if N=0).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../.claude/lib/iwe-env-bootstrap.sh" || exit 1

REPO_ROOT="$IWE_DS_MY_STRATEGY"
SESSIONS_DIR="$REPO_ROOT/inbox/agent/sessions"
CUTOVER_DATE="${SESSION_CUTOVER_DATE:-2026-05-29}"   # ISO date
STALE_HOURS="${SESSION_STALE_HOURS:-24}"             # for status: completed

[[ -d "$SESSIONS_DIR" ]] || exit 0

python3 - <<'PY' "$SESSIONS_DIR" "$REPO_ROOT" "$CUTOVER_DATE" "$STALE_HOURS"
import os, re, sys, time
from datetime import datetime, timezone
from pathlib import Path

sessions_dir = Path(sys.argv[1])
repo_root    = Path(sys.argv[2])
cutover      = datetime.fromisoformat(sys.argv[3]).replace(tzinfo=timezone.utc)
stale_hours  = float(sys.argv[4])

now = datetime.now(tz=timezone.utc)

FM_RE     = re.compile(r"^---\n(.*?)\n---", re.S)
STATUS_RE = re.compile(r'^\s*status:\s*"?([^"\n]+)"?\s*$', re.M)

def parse_status(text):
    m = FM_RE.match(text)
    if not m:
        return None
    sm = STATUS_RE.search(m.group(1))
    return sm.group(1).strip() if sm else None

def first_pilot_turn(thread_path):
    if not thread_path.exists():
        return ""
    try:
        with thread_path.open(encoding="utf-8") as f:
            block, capture = [], False
            for line in f:
                if line.startswith("[turn:1, role:pilot"):
                    capture = True
                    continue
                if capture:
                    if line.startswith("[turn:"):
                        break
                    s = line.strip()
                    if s:
                        block.append(s)
                    if len(block) >= 1:
                        break
        return (block[0] if block else "")[:80]
    except Exception:
        return ""

rows = []
for path in sorted(sessions_dir.glob("SESSION-*.md")):
    if path.name.endswith("-thread.md"):
        continue
    mtime = datetime.fromtimestamp(path.stat().st_mtime, tz=timezone.utc)
    if mtime < cutover:
        continue
    try:
        text = path.read_text(encoding="utf-8")
    except Exception:
        continue
    status = parse_status(text) or "?"
    age_h  = (now - mtime).total_seconds() / 3600.0
    open_  = status != "completed" or age_h >= stale_hours
    if not open_:
        continue

    thread_path = path.with_name(path.stem + "-thread.md")
    topic = first_pilot_turn(thread_path)
    rel   = path.relative_to(repo_root).as_posix()

    age_str = (f"{age_h:.0f}h" if age_h < 48 else f"{age_h/24:.1f}d")
    rows.append((path.name.replace(".md", ""), status, age_str, topic, rel))

if not rows:
    sys.exit(0)

print(f"### 🔴 Unclosed sessions ({len(rows)})\n")
print("> Finalize: create `sessions/external/YYYY-MM/SESSION-<id>/report.md` + `git mv` into the same folder. See also — DP.SC.162 §close.\n")
print("| Session | Status | Age | Topic |")
print("|--------|--------|---------|------|")
for name, status, age, topic, rel in rows:
    safe_topic = (topic or "—").replace("|", "\\|")
    print(f"| [{name}]({rel}) | `{status}` | {age} | {safe_topic} |")
PY
