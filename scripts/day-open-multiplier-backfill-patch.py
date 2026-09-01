#!/usr/bin/env python3
"""Backfill yesterday's DayPlan/ledger multiplier when the local WakaTime CLI
could not compute it at close time (Ф117, WP-484).

wakatime-cli only understands `--today` (day-close-prepare.sh:279-299): if Close
ran after local midnight, or ran on a host without the CLI at all, the day's
facts_digest is written honestly without multiplier_estimated ("PENDING", the
intended anti-fabrication degradation -- see day-close-prepare.sh's own header).
This script queries the WakaTime HTTP API (cloud-side, not tied to a local
client) once that day's data has had time to sync, and appends a CORRECTED
facts_digest event for the same for_date. render-open.py already reads the
LATEST matching facts_digest per date (eligible_digests[-1], "a later append-only
correction wins regardless of schema age") -- so no in-place mutation and no
dedup guard is required. ledger-append.sh is called WITHOUT
--dedup-by-kind-and-date on purpose: that flag only checks the SAME call's own
opt-in (ledger-append.sh:44-52,367-392), not a standing constraint on the kind,
so it does not collide with day-close-prepare.sh's own close-time dedup.

Thresholds pilot-approved 2026-09-01 (peer-session 2026-09-01-18-wp484-backlog-
continue, escalation-00.md, Codex design + Kimi audit):
  - < SYNC_GRACE_MIN minutes after local midnight following the target day ->
    data may simply not have synced yet ("pending_sync"), retry next Open.
  - >= SOURCE_ABSENT_DAYS consecutive calendar days with no successful backfill
    anywhere in the window, observed across >= SOURCE_ABSENT_OPENS distinct
    Open runs -> "source_absent" (still just a visible finding, never blocking,
    never a fabricated value -- "операционная классификация, не доказательство
    «никогда»", Codex).

Every run -- success or not -- appends one small `multiplier_backfill_attempt`
event to TODAY's ledger. No separate mutable counter/state file: the
source_absent classification is derived from these events the same way
day-open-r23-series-patch.py derives the R23 series from ledger events alone.
"""

import argparse
import base64
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

import yaml

try:
    from zoneinfo import ZoneInfo
except Exception:  # pragma: no cover - matches day-open-r23-series-patch.py fallback
    ZoneInfo = None

ATTENTION_HEADER_RE = re.compile(
    r"(<summary><b>Требует внимания</b></summary>\s*\n)"
)
MULT_BLOCK_START = "<!-- multiplier-backfill:start -->"
MULT_BLOCK_END = "<!-- multiplier-backfill:end -->"
MULT_BLOCK_RE = re.compile(
    rf"{re.escape(MULT_BLOCK_START)}\n.*?{re.escape(MULT_BLOCK_END)}\n?",
    re.DOTALL,
)
DAY_FILE_DATE_RE = re.compile(r"day-(\d{4}-\d{2}-\d{2})\.yaml$")

SYNC_GRACE_MIN_DEFAULT = 30
SOURCE_ABSENT_DAYS_DEFAULT = 14
SOURCE_ABSENT_OPENS_DEFAULT = 2


def parse_args():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--dayplan", required=True, help="Path to today's DayPlan .md")
    p.add_argument("--ledger-root", required=True, help="Path to machine/ledger/day")
    p.add_argument("--date", required=True, help="Today's date (Open's own date), YYYY-MM-DD")
    p.add_argument("--ledger-append", required=True, help="Path to ledger-append.sh")
    p.add_argument("--env-file", default=str(Path.home() / ".config/aist/env"))
    p.add_argument("--sync-grace-min", type=int, default=SYNC_GRACE_MIN_DEFAULT)
    p.add_argument("--source-absent-days", type=int, default=SOURCE_ABSENT_DAYS_DEFAULT)
    p.add_argument("--source-absent-opens", type=int, default=SOURCE_ABSENT_OPENS_DEFAULT)
    # --date comes from the pipeline's own `date +%Y-%m-%d` (host-local calendar
    # day, whatever tz that host runs), while --tz below only anchors the grace-
    # period midnight boundary -- if a host's system tz ever drifts materially
    # from Europe/Nicosia this pair can disagree by more than the DST-only slip
    # day-open-r23-series-patch.py accepts for its own peak-window check (cold
    # review Ф117: known limitation, not fixed here -- pass --tz explicitly if
    # that host's date command needs it).
    p.add_argument("--tz", default="Europe/Nicosia", help="Local timezone for the midnight/grace check")
    return p.parse_args()


def local_tz(name):
    if ZoneInfo is not None:
        try:
            return ZoneInfo(name)
        except Exception as exc:
            print(f"multiplier-backfill: zoneinfo unavailable ({exc}), fixed UTC+3 fallback", file=sys.stderr)
    return timezone(timedelta(hours=3))


def ledger_day_path(root, date_str):
    year, month = date_str[:4], date_str[5:7]
    return Path(root) / year / month / f"day-{date_str}.yaml"


def load_day_events(root, date_str):
    path = ledger_day_path(root, date_str)
    if not path.is_file():
        return []
    try:
        doc = yaml.safe_load(path.read_text(encoding="utf-8"))
    except (OSError, yaml.YAMLError) as exc:
        print(f"multiplier-backfill: skip corrupt {path.name}: {exc}", file=sys.stderr)
        return None
    events = doc.get("events", []) if isinstance(doc, dict) else doc
    return events if isinstance(events, list) else []


def latest_facts_digest(events, for_date):
    """Same selection rule as render-open.py: last eligible event wins."""
    eligible = [
        e
        for e in events
        if isinstance(e, dict)
        and e.get("kind") == "facts_digest"
        and isinstance(e.get("data"), dict)
        and (e["data"].get("for_date") == for_date or "for_date" not in e["data"])
    ]
    return eligible[-1] if eligible else None


def session_minutes_for_date(events):
    """Sum session_closed duration_min for one day's ledger, same exclusion rule
    as day-close-prepare.sh's embedded computation (duration_known=False or a
    non-numeric duration_min is excluded, not counted as zero). Duplicated here
    deliberately -- day-close-prepare.sh's version is an inline heredoc, not an
    importable function, and this script must work even when that CLI-driven
    path never ran at all (the exact case Ф117 backfills). Keep both in sync by
    hand if the exclusion rule ever changes."""
    total_min = 0
    excluded = 0
    for e in events:
        if not isinstance(e, dict) or e.get("kind") != "session_closed":
            continue
        data = e.get("data")
        if not isinstance(data, dict):
            continue
        dur = data.get("duration_min")
        if data.get("duration_known") is False or not isinstance(dur, (int, float)) or isinstance(dur, bool):
            excluded += 1
            continue
        total_min += dur
    return total_min, excluded


def fetch_wakatime_hours(target_date, env_file):
    """Returns (hours: float | None, error: str | None). None hours + None error
    means "no positive data for that day", not a transport failure."""
    api_key = None
    if Path(env_file).is_file():
        try:
            out = subprocess.run(
                ["bash", "-c", f'set -a; source "{env_file}" 2>/dev/null; set +a; printf %s "$WAKATIME_API_KEY"'],
                capture_output=True, text=True, timeout=10,
            )
            api_key = out.stdout.strip() or None
        except Exception as exc:
            return None, f"env-read-failed:{exc}"
    if not api_key:
        return None, "no-api-key"

    url = f"https://wakatime.com/api/v1/users/current/summaries?start={target_date}&end={target_date}"
    auth = base64.b64encode(f"{api_key}:".encode()).decode()
    req = urllib.request.Request(url, headers={"Authorization": f"Basic {auth}", "Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            body = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        return None, f"http-{exc.code}"
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        return None, f"transport:{exc}"

    days = body.get("data") if isinstance(body, dict) else None
    if not isinstance(days, list) or not days:
        return None, None
    day_entry = next((d for d in days if isinstance(d, dict) and d.get("range", {}).get("date") == target_date), days[0])
    grand_total = day_entry.get("grand_total") if isinstance(day_entry, dict) else None
    seconds = grand_total.get("total_seconds") if isinstance(grand_total, dict) else None
    if not isinstance(seconds, (int, float)) or isinstance(seconds, bool) or seconds <= 0:
        return None, None
    return round(seconds / 3600, 4), None


def ledger_parent_root(ledger_root):
    """ledger-append.sh's IWE_LEDGER_DIR is the machine/ledger/ parent that
    contains day/week/month -- one level above the --ledger-root convention
    this script shares with day-open-r23-series-patch.py (which points
    straight at the day/ subfolder for its own glob)."""
    return str(Path(ledger_root).parent)


def append_attempt(ledger_append, ledger_root, today, target_date, outcome, detail):
    """Best-effort telemetry -- never allowed to raise into main()'s non-blocking
    contract, so a hung ledger-append.sh (its own flock wait already caps at
    10s) can't turn this into a blocked Open."""
    payload = json.dumps({"for_date": target_date, "outcome": outcome, "detail": detail})
    try:
        ret = subprocess.run(
            [ledger_append, "day", today, "multiplier_backfill_attempt", payload, "multiplier-backfill"],
            env={**os.environ, "IWE_LEDGER_DIR": ledger_parent_root(ledger_root)},
            capture_output=True, text=True, timeout=20,
        )
    except subprocess.TimeoutExpired:
        print("multiplier-backfill: attempt-telemetry write timed out", file=sys.stderr)
        return
    if ret.returncode != 0:
        print(f"multiplier-backfill: attempt-telemetry write failed: {ret.stderr.strip()}", file=sys.stderr)


def recent_attempt_days(ledger_root, today, window_days):
    """(days_with_any_attempt, days_with_success) over the last window_days
    calendar days ending today, scanning ledger day files directly (no
    mutable counter -- same derive-from-events principle as the R23 series
    reader)."""
    start = datetime.strptime(today, "%Y-%m-%d").date() - timedelta(days=window_days - 1)
    any_days, success_days = set(), set()
    for day_file in sorted(Path(ledger_root).glob("*/*/day-*.yaml")):
        m = DAY_FILE_DATE_RE.search(day_file.name)
        if not m:
            continue
        file_date = m.group(1)
        try:
            file_date_d = datetime.strptime(file_date, "%Y-%m-%d").date()
        except ValueError:
            continue
        if file_date_d < start:
            continue
        events = load_day_events(ledger_root, file_date)
        if not events:
            continue
        for e in events:
            if not isinstance(e, dict) or e.get("kind") != "multiplier_backfill_attempt":
                continue
            data = e.get("data") if isinstance(e.get("data"), dict) else {}
            any_days.add(file_date)
            if data.get("outcome") == "success":
                success_days.add(file_date)
    return any_days, success_days


def classify_source_absence(ledger_root, today, source_absent_days, source_absent_opens):
    """True only once failure evidence genuinely spans the full window -- NOT
    merely >= source_absent_opens failures anywhere inside it (cold review
    Ф117, 2026-09-01: the first version conflated "how many failure days
    observed" with "how long has this persisted", so 2 failures 3 days apart
    inside a fresh 14-day window could trip the alarm on day 3). Requires:
    no success anywhere in the window, at least source_absent_opens distinct
    failure days (avoids a single-day glitch), AND the earliest failure day
    reaches back to the window's start (proves the streak is actually old,
    not just observed a couple of times recently)."""
    any_days, success_days = recent_attempt_days(ledger_root, today, source_absent_days)
    if success_days or len(any_days) < source_absent_opens:
        return False, len(any_days)
    window_start = datetime.strptime(today, "%Y-%m-%d").date() - timedelta(days=source_absent_days - 1)
    earliest_failure = min(datetime.strptime(d, "%Y-%m-%d").date() for d in any_days)
    return earliest_failure <= window_start, len(any_days)


def finding_lines(outcome, detail):
    labels = {
        "pending_sync": f"⏳ Мультипликатор за вчера ещё не досчитан — WakaTime-данные ещё не синхронизировались ({detail}).",
        "wakatime_unavailable": f"⚠️ Мультипликатор за вчера не досчитан — WakaTime API недоступен ({detail}), повтор на следующем Открытии.",
        "source_absent": f"ℹ️ Мультипликатор за вчера не досчитан — источник WakaTime-данных не отвечает уже {detail} дней подряд, возможно клиент не установлен.",
        "already_present": None,
        "no_digest": None,
    }
    text = labels.get(outcome, f"⚠️ Мультипликатор за вчера: {outcome} ({detail}).")
    return [f"- {text}\n"] if text else []


def patch_dayplan(dayplan_path, lines):
    text = Path(dayplan_path).read_text(encoding="utf-8")
    text = MULT_BLOCK_RE.sub("", text)
    if not lines:
        Path(dayplan_path).write_text(text, encoding="utf-8")
        return True
    block = f"{MULT_BLOCK_START}\n{''.join(lines)}{MULT_BLOCK_END}\n"
    match = ATTENTION_HEADER_RE.search(text)
    if not match:
        print("multiplier-backfill: DayPlan has no «Требует внимания» section, skip", file=sys.stderr)
        return False
    insert_at = match.end()
    Path(dayplan_path).write_text(text[:insert_at] + block + text[insert_at:], encoding="utf-8")
    return True


def main():
    args = parse_args()
    tz = local_tz(args.tz)
    today = args.date
    target = (datetime.strptime(today, "%Y-%m-%d").date() - timedelta(days=1)).isoformat()

    events = load_day_events(args.ledger_root, target)
    if events is None:
        # Counts as a failed attempt (not silently skipped) so a corrupt ledger
        # doesn't understate a genuine source_absent streak in
        # classify_source_absence()'s window scan (cold review Ф117 Medium).
        append_attempt(args.ledger_append, args.ledger_root, today, target, "wakatime_unavailable", "corrupt-ledger")
        patch_dayplan(args.dayplan, finding_lines("wakatime_unavailable", "ledger повреждён"))
        return 0
    digest_event = latest_facts_digest(events, target)
    if digest_event is None:
        # No facts_digest at all for yesterday (e.g. --no-ledger close) -- outside
        # this script's scope, r23/version-check patches already surface a missing
        # Close separately. Stay silent rather than duplicate that finding.
        patch_dayplan(args.dayplan, [])
        return 0
    digest_data = digest_event.get("data", {})
    if isinstance(digest_data.get("multiplier_estimated"), (int, float)) and not isinstance(digest_data.get("multiplier_estimated"), bool):
        patch_dayplan(args.dayplan, [])
        return 0

    now_utc = datetime.now(timezone.utc)
    target_end_local = datetime.strptime(target, "%Y-%m-%d").replace(tzinfo=tz) + timedelta(days=1)
    grace_deadline = target_end_local.astimezone(timezone.utc) + timedelta(minutes=args.sync_grace_min)
    if now_utc < grace_deadline:
        append_attempt(args.ledger_append, args.ledger_root, today, target, "pending_sync", "within-grace")
        patch_dayplan(args.dayplan, finding_lines("pending_sync", f"грейс-период {args.sync_grace_min} мин"))
        return 0

    hours, err = fetch_wakatime_hours(target, args.env_file)
    if err is not None and hours is None:
        is_absent, _ = classify_source_absence(
            args.ledger_root, today, args.source_absent_days, args.source_absent_opens
        )
        outcome = "source_absent" if is_absent else "wakatime_unavailable"
        append_attempt(args.ledger_append, args.ledger_root, today, target, outcome, err)
        detail = str(args.source_absent_days) if is_absent else err
        patch_dayplan(args.dayplan, finding_lines(outcome, detail))
        return 0
    if hours is None:
        is_absent, _ = classify_source_absence(
            args.ledger_root, today, args.source_absent_days, args.source_absent_opens
        )
        outcome = "source_absent" if is_absent else "pending_sync"
        append_attempt(args.ledger_append, args.ledger_root, today, target, outcome, "zero-or-missing-day")
        detail = str(args.source_absent_days) if is_absent else "нет данных за день ещё"
        patch_dayplan(args.dayplan, finding_lines(outcome, detail))
        return 0

    session_minutes, excluded = session_minutes_for_date(events)
    if session_minutes <= 0:
        append_attempt(args.ledger_append, args.ledger_root, today, target, "wakatime_unavailable", "no-session-minutes")
        patch_dayplan(args.dayplan, finding_lines("wakatime_unavailable", "нет данных о длительности сессий за вчера"))
        return 0

    multiplier = round(hours / (session_minutes / 60), 2)
    corrected = dict(digest_data)
    corrected.update({
        "for_date": target,
        "wakatime_h": hours,
        "multiplier_estimated": multiplier,
        "session_minutes_observed": session_minutes,
        "session_events_excluded": excluded,
        "multiplier_observed_at": now_utc.isoformat().replace("+00:00", "Z"),
        "multiplier_source": "wakatime_api",
        "corrects_source": digest_event.get("source", "unknown"),
    })
    try:
        ret = subprocess.run(
            [args.ledger_append, "day", target, "facts_digest", json.dumps(corrected), "multiplier-backfill"],
            env={**os.environ, "IWE_LEDGER_DIR": ledger_parent_root(args.ledger_root)},
            capture_output=True, text=True, timeout=20,
        )
    except subprocess.TimeoutExpired:
        print("multiplier-backfill: ledger-append.sh timed out", file=sys.stderr)
        patch_dayplan(args.dayplan, finding_lines("wakatime_unavailable", "запись в ledger не удалась (timeout)"))
        return 0
    if ret.returncode != 0:
        print(f"multiplier-backfill: ledger-append.sh failed: {ret.stderr.strip()}", file=sys.stderr)
        patch_dayplan(args.dayplan, finding_lines("wakatime_unavailable", "запись в ledger не удалась"))
        return 0
    append_attempt(args.ledger_append, args.ledger_root, today, target, "success", f"multiplier={multiplier}")
    print(f"multiplier-backfill: backfilled {target} multiplier_estimated={multiplier}", file=sys.stderr)
    patch_dayplan(args.dayplan, [])
    return 0


if __name__ == "__main__":
    sys.exit(main())
