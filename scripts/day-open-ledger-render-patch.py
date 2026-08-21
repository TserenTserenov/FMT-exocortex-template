#!/usr/bin/env python3
"""day-open-ledger-render-patch.py — WP-484 Ф16.2 2b: appends render-open.py's
ledger-derived sections ("Итоги вчера"/"Очередь решений"/"Предлагаемые действия",
Ф16.2 2c) into an already-scaffolded+filled DayPlan.

Design decision (documented per task instructions, read this before changing anchor
logic): day-open-scaffold.sh ALREADY renders its own non-ledger "Итоги вчера"
<details> block (render_yesterday() in day-open-scaffold.sh, git-log based). This
script does NOT touch or replace that block — CONCEPT-night-cycle.md §16 "Миграция"
explicitly specifies a parallel run, not a big-bang replacement ("не big-bang,
параллельный прогон... работают одновременно минимум один полный цикл своего такта"),
so the ledger-rendered sections are appended as an ADDITIONAL block near the end of
the file, never overwriting the legacy section. Once the ledger path has proven itself
(§16.5 — N clean autoruns), a future phase can retire the legacy block; not this one.

Graceful no-op invariant (the single biggest risk this script must avoid, per task
instructions): when no real ledger data exists yet for the target date (the normal
case until scripts/day-close-prepare.sh, WP-484 Ф16.2 2a, starts landing facts_digest
events most nights), this script changes NOTHING in the DayPlan — no PENDING marker,
no empty section, no visual noise. Each of the three sub-sections is gated
independently on the ledger event kind it actually needs (facts_digest / blocked_
question / pilot_answer) rather than render-open.py's own PENDING fallback text, so
this script never has to parse render-open.py's markdown output to tell "real data"
from "honest placeholder" apart — it just doesn't call render-open.py for a
sub-section it has no real data for.

Idempotent by fact (CONCEPT-night-cycle.md §5 invariant): a marker HTML comment is
checked before inserting — a second run against an already-patched DayPlan is a no-op,
not a duplicate block.

Self-heal on marker mismatch (added 2026-07-26, WP-484 — root-caused the 04:35 26.07
incident): the marker used to mean "trust whatever's there, skip." That let a stray
write (e.g. strategist.sh's free-form LLM fallback, which has no awareness of this
marker at all) fabricate a block carrying this exact marker with numbers no
deterministic render could produce, and this script would silently accept it forever
after — exactly the "no fabrication" invariant §5 exists to prevent, via a path this
script's own idempotency check didn't cover. Now: marker present → recompute the
block fresh from the ledger and diff it against what's on disk. Identical → true
no-op (unchanged, matches the invariant this script has always claimed). Different →
overwrite with the freshly-computed honest text (self-heal, logged). No real ledger
data anymore → remove the block entirely (back to the true no-op state a fresh render
would produce).

Usage:
  day-open-ledger-render-patch.py --dayplan PATH --date YYYY-MM-DD
      [--ledger-dir DIR] [--ledger-archive-dir DIR]

--date is TODAY's date (matches day-open-pipeline.sh's $DATE) — the ledger period
rendered for the summary is the PREVIOUS calendar day ("Итоги ВЧЕРА"), computed here
the same way day-open-scaffold.sh computes $YDAY (calendar day before --date, not
"yesterday" by wall clock — deterministic and testable with an arbitrary --date).

Day split (WP-481 Ф22 audit №3 repair, 2026-08-08): the summary belongs to the
closed day (D−1), but the morning queue and the night drift scan belong to TODAY's
ledger day (D) — night WP-503 jobs write blocked_question / wp_drift_found into D
around 01:00, before this render runs. Reading them from D−1 surfaced yesterday's
already-stale queue and never surfaced drift at all (render_drift_scan existed in
render-open.py but was never called from here). Contract: summary/actions ← D−1,
queue/drift_scan ← D.

Exit code: always 0 (this is a best-effort deterministic patch in the same family as
day-open-bottleneck-patch.sh / day-open-budget-patch.py, both called with `|| true` /
non-fatal semantics in day-open-pipeline.sh — a problem here must never abort Day Open).
"""
import argparse
import datetime
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
from ledger_path import resolve_ledger_path  # noqa: E402

try:
    import yaml
except ImportError:
    yaml = None

MARKER = "<!-- LEDGER-RENDER: WP-484 Ф16.2 2b -->"
FOOTER_PATTERN = re.compile(
    r"^\*Создан: \d{4}-\d{2}-\d{2} \(Day Open / day-open-scaffold\.sh WP-264 Ф2\)\*\s*$",
    re.MULTILINE,
)
# Captures the entire previously-inserted block (marker through its closing
# </details>\n\n) so a second run can diff/replace it instead of just detecting its
# presence — see "Self-heal on marker mismatch" in the module docstring.
BLOCK_PATTERN = re.compile(
    re.escape(MARKER) + r"\n\n<details>\n.*?\n</details>\n\n",
    re.DOTALL,
)


def load_events(ledger_dir, archive_dir, period):
    if yaml is None:
        return [], "pyyaml not available"
    try:
        path = resolve_ledger_path("day", period, ledger_dir, archive_dir)
    except RuntimeError as exc:
        return [], str(exc)
    if not os.path.isfile(path):
        return [], None
    try:
        with open(path, encoding="utf-8") as f:
            doc = yaml.safe_load(f)
    except Exception as exc:
        return [], str(exc)
    if not isinstance(doc, dict):
        return [], "ledger document is not a mapping"
    events = doc.get("events")
    return (events if isinstance(events, list) else []), None


def has_kind(events, kind):
    return any(isinstance(e, dict) and e.get("kind") == kind for e in events)


def has_digest_for_period(events, period):
    """Accept an explicit target match, or a legacy event with no for_date field."""
    for event in events:
        if not isinstance(event, dict) or event.get("kind") != "facts_digest":
            continue
        data = event.get("data")
        if not isinstance(data, dict):
            continue
        if data.get("for_date") == period or "for_date" not in data:
            return True
    return False


def render_section(render_open_py, period, ledger_dir, archive_dir, section):
    cmd = [sys.executable, render_open_py, "--scale", "day", "--period", period, "--section", section]
    if ledger_dir:
        cmd += ["--ledger-dir", ledger_dir]
    if archive_dir:
        cmd += ["--ledger-archive-dir", archive_dir]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
    except Exception as e:
        return None, str(e)
    if proc.returncode != 0:
        return None, proc.stderr.strip() or f"exit {proc.returncode}"
    text = proc.stdout.rstrip("\n")
    return (text or None), None


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dayplan", required=True)
    parser.add_argument("--date", required=True, help="today's date (YYYY-MM-DD), matches day-open-pipeline.sh $DATE")
    parser.add_argument("--ledger-dir", default=None)
    parser.add_argument("--ledger-archive-dir", default=None)
    args = parser.parse_args()

    if not re.match(r"^\d{4}-\d{2}-\d{2}$", args.date):
        print(f"  ledger-render-patch: invalid --date '{args.date}' — skip", file=sys.stderr)
        return 0

    if not os.path.isfile(args.dayplan):
        print(f"  ledger-render-patch: {args.dayplan} not found — skip")
        return 0

    with open(args.dayplan, encoding="utf-8") as f:
        content = f.read()

    had_marker = MARKER in content

    iwe_root = os.environ.get("IWE_ROOT", os.path.expanduser("~/IWE"))
    governance = os.environ.get("IWE_GOVERNANCE_REPO", "DS-strategy")
    ledger_dir = args.ledger_dir or os.environ.get(
        "IWE_LEDGER_DIR", os.path.join(iwe_root, governance, "machine/ledger")
    )
    archive_dir = args.ledger_archive_dir or os.environ.get("IWE_LEDGER_ARCHIVE_DIR")
    if archive_dir is None and args.ledger_dir is None and "IWE_LEDGER_DIR" not in os.environ:
        archive_dir = os.path.join(iwe_root, governance, "archive/ledger")
    render_open_py = os.path.join(iwe_root, governance, "scripts/render-open.py")

    if not os.path.isfile(render_open_py):
        print(f"  ledger-render-patch: render-open.py not found at {render_open_py} — skip")
        return 0
    if yaml is None:
        print("  ledger-render-patch: pyyaml not available — skip")
        return 0

    today = datetime.datetime.strptime(args.date, "%Y-%m-%d").date()
    yday = (today - datetime.timedelta(days=1)).isoformat()
    today_str = today.isoformat()

    events, load_error = load_events(ledger_dir, archive_dir, yday)

    # Queue and drift read from TODAY's ledger (D), not the closed day — see
    # "Day split" in the module docstring. A missing/corrupt today-ledger must
    # not take down yesterday's summary: treat it as "no morning events yet".
    events_today, load_error_today = load_events(ledger_dir, archive_dir, today_str)
    if load_error_today:
        print(f"  ledger-render-patch: today ledger ({today_str}): {load_error_today} — queue/drift skipped")
        events_today = []

    if load_error:
        # Symmetric degradation (cold review 2026-08-08): a corrupt YESTERDAY
        # ledger kills summary/actions, but the morning queue/drift from D do
        # not depend on it — render them anyway. Bail out untouched only when
        # D has nothing renderable either (the old safe behavior).
        print(f"  ledger-render-patch: yday ledger ({yday}): {load_error} — summary/actions skipped")
        events = []
        if not (has_kind(events_today, "blocked_question") or has_kind(events_today, "wp_drift_found")):
            print("  ledger-render-patch: nothing renderable from today either — left DayPlan untouched")
            return 0

    blocks = []
    errors = []
    if has_digest_for_period(events, yday):
        text, err = render_section(render_open_py, yday, ledger_dir, archive_dir, "summary")
        if text:
            blocks.append(text)
        elif err:
            errors.append(f"summary: {err}")
    if has_kind(events_today, "blocked_question"):
        text, err = render_section(render_open_py, today_str, ledger_dir, archive_dir, "queue")
        if text:
            blocks.append(text)
        elif err:
            errors.append(f"queue: {err}")
    if has_kind(events_today, "wp_drift_found"):
        text, err = render_section(render_open_py, today_str, ledger_dir, archive_dir, "drift_scan")
        if text:
            blocks.append(text)
        elif err:
            errors.append(f"drift_scan: {err}")
    if has_kind(events, "pilot_answer"):
        text, err = render_section(render_open_py, yday, ledger_dir, archive_dir, "actions")
        if text:
            blocks.append(text)
        elif err:
            errors.append(f"actions: {err}")

    if not blocks:
        # The graceful no-op invariant this whole script exists to protect: no
        # facts_digest/blocked_question/pilot_answer for yesterday yet (expected
        # for the next several nights, until day-close-prepare.sh, WP-484 Ф16.2 2a,
        # starts landing facts_digest events) — leave the DayPlan untouched, don't
        # inject an empty or PENDING-looking section.
        if had_marker:
            if load_error:
                # Yesterday's ledger is corrupt — a block on disk may carry a
                # perfectly good summary we cannot recompute right now. Never
                # remove on partial data (cold review 2026-08-08).
                print("  ledger-render-patch: marker present but yday ledger unreadable — left untouched, needs manual look")
                return 0
            # A block exists on disk but a fresh render says there's no real data for
            # it anymore — it can't have come from this script (it never writes a
            # block with nothing behind it), so it's a stray/fabricated one. Remove
            # it to reach the same honest no-op state a clean run would produce.
            new_content = BLOCK_PATTERN.sub("", content, count=1)
            if new_content == content:
                print("  ledger-render-patch: marker present but block pattern didn't match — left untouched, needs manual look")
                return 0
            with open(args.dayplan, "w", encoding="utf-8") as f:
                f.write(new_content)
            print(f"  ledger-render-patch: SELF-HEAL — removed stray block for {yday} (no real ledger data behind it)")
            return 0
        detail = f" (errors: {'; '.join(errors)})" if errors else ""
        print(f"  ledger-render-patch: no real ledger data for {yday}/{today_str} yet — no-op{detail}")
        return 0

    insertion = (
        MARKER
        + "\n\n<details>\n<summary><b>Ночной цикл (ledger, WP-484 Ф16.2)</b></summary>\n\n"
        + "\n\n".join(blocks)
        + "\n\n</details>\n\n"
    )

    if had_marker:
        existing_match = BLOCK_PATTERN.search(content)
        if existing_match and existing_match.group(0) == insertion:
            print("  ledger-render-patch: already inserted, matches fresh render — skip")
            return 0
        if load_error:
            # Same partial-data guard as above: with yesterday's ledger corrupt
            # the fresh insertion can be missing a summary the on-disk block
            # legitimately has — overwriting would destroy honest data.
            print("  ledger-render-patch: block differs but yday ledger unreadable — left untouched, needs manual look")
            return 0
        if not existing_match:
            print("  ledger-render-patch: marker present but block pattern didn't match — left untouched, needs manual look")
            return 0
        # Marker present but content differs from what a fresh, honest render
        # produces — self-heal (see module docstring "Self-heal on marker mismatch").
        new_content = BLOCK_PATTERN.sub(lambda m: insertion, content, count=1)
        with open(args.dayplan, "w", encoding="utf-8") as f:
            f.write(new_content)
        print(f"  ledger-render-patch: SELF-HEAL — block for {yday} didn't match a fresh render, overwrote with honest data"
              + (f" (partial — errors: {'; '.join(errors)})" if errors else ""))
        return 0

    new_content, n = FOOTER_PATTERN.subn(lambda m: insertion + m.group(0), content, count=1)
    if n == 0:
        print("  ledger-render-patch: footer anchor not found — DayPlan structure unexpected, left untouched")
        return 0

    with open(args.dayplan, "w", encoding="utf-8") as f:
        f.write(new_content)
    print(f"  ledger-render-patch: inserted {len(blocks)} section(s) for {yday}/{today_str}"
          + (f" (partial — errors: {'; '.join(errors)})" if errors else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main())
