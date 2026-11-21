#!/usr/bin/env python3
"""Regression test: candidacy criterion, cooldown suppression, canonical-only
scope, field-vs-file mismatch diagnostic — all against a synthetic inbox/.
"""

import json
import subprocess
import sys
import tempfile
from pathlib import Path


SCRIPT = Path(__file__).with_name("archive-cadence-sweep.py")
ON_DATE = "2026-08-21"


def make_card(inbox_dir, wp_id, created, lines, extra_frontmatter=""):
    card_dir = inbox_dir / wp_id
    card_dir.mkdir()
    body = "\n".join(f"line {i}" for i in range(lines))
    text = f"---\ncreated: {created}\n{extra_frontmatter}---\n\n{body}\n"
    (card_dir / f"{wp_id}.md").write_text(text, encoding="utf-8")
    return card_dir


def run(*args):
    return subprocess.run(
        [sys.executable, str(SCRIPT), *args], text=True, capture_output=True, check=False
    )


with tempfile.TemporaryDirectory() as directory:
    inbox = Path(directory) / "inbox"
    inbox.mkdir()

    # 1. Real candidate: old + long, no archive file.
    make_card(inbox, "WP-1", "2026-01-01", 500)

    # 2. Too young: 5 days old, long — must not be a candidate.
    make_card(inbox, "WP-2", "2026-08-16", 500)

    # 3. Too short: old, 100 lines — must not be a candidate.
    make_card(inbox, "WP-3", "2026-01-01", 100)

    # 4. Already archived: old + long, has both -archive.md file AND the
    #    archive: frontmatter field (realistic post-5c state, no mismatch).
    archived_dir = make_card(inbox, "WP-4", "2026-01-01", 500,
                              'archive: "WP-4-archive.md"\n')
    (archived_dir / "WP-4-archive.md").write_text("archived", encoding="utf-8")

    # 5. Declined recently: old + long, archive_declined 10 days ago —
    #    still in cooldown (14-day window), suppressed.
    make_card(inbox, "WP-5", "2026-01-01", 500, "archive_declined: 2026-08-11\n")

    # 6. Declined long ago: old + long, archive_declined 20 days ago —
    #    cooldown expired, resurfaces as a candidate.
    make_card(inbox, "WP-6", "2026-01-01", 500, "archive_declined: 2026-08-01\n")

    # 7. Field/file mismatch: archive: field set, but no -archive.md file —
    #    must still be a candidate (file, not field, decides), plus flagged.
    make_card(inbox, "WP-7", "2026-01-01", 500, 'archive: "WP-7-archive.md"\n')

    # 8. Non-canonical: file name doesn't match dir name — must be invisible.
    noncanon_dir = inbox / "WP-8"
    noncanon_dir.mkdir()
    (noncanon_dir / "WP-9.md").write_text(
        "---\ncreated: 2026-01-01\n---\n\n" + "\n".join(f"l{i}" for i in range(500)),
        encoding="utf-8",
    )

    # 9. Missing created: must land in errors, not silently dropped.
    broken_dir = inbox / "WP-10"
    broken_dir.mkdir()
    (broken_dir / "WP-10.md").write_text("---\n---\n\nbody", encoding="utf-8")

    result = run("--inbox", str(inbox), "--date", ON_DATE, "--format", "json")
    assert result.returncode == 0, result.stderr
    data = json.loads(result.stdout)

    candidate_ids = {c["id"] for c in data["candidates"]}
    assert candidate_ids == {"WP-1", "WP-6", "WP-7"}, candidate_ids

    assert "WP-2" not in candidate_ids, "too-young card must not be a candidate"
    assert "WP-3" not in candidate_ids, "too-short card must not be a candidate"
    assert "WP-4" not in candidate_ids, "already-archived card must not be a candidate"
    assert "WP-9" not in candidate_ids and "WP-8" not in candidate_ids, \
        "non-canonical filename must be invisible to the sweep"

    cooldown_ids = {c["id"] for c in data["suppressed"]["cooldown"]}
    assert cooldown_ids == {"WP-5"}, cooldown_ids

    archived_ids = set(data["suppressed"]["archive_exists"])
    assert archived_ids == {"WP-4"}, archived_ids

    mismatch_ids = {m["id"] for m in data["field_mismatches"]}
    assert mismatch_ids == {"WP-7"}, mismatch_ids
    mismatch = data["field_mismatches"][0]
    assert mismatch["has_field"] is True and mismatch["has_file"] is False, mismatch

    assert any("WP-10:" in e and "created" in e for e in data["errors"]), data["errors"]

    assert data["count"] == 3, data["count"]
    # WP-1..WP-7 + WP-10 discovered (8 canonical dirs with matching
    # filenames); WP-8/WP-9 never counted (non-canonical dir/file name
    # mismatch, invisible at discovery, not even an error entry).
    assert data["total_checked"] == 8, data["total_checked"]

    # md format must not crash and must mention the same candidate count.
    md_result = run("--inbox", str(inbox), "--date", ON_DATE, "--format", "md")
    assert md_result.returncode == 0, md_result.stderr
    assert "Кандидаты на архивацию карточек (3)" in md_result.stdout, md_result.stdout

    # bad --date must fail closed, not silently default to today.
    bad_date = run("--inbox", str(inbox), "--date", "not-a-date")
    assert bad_date.returncode == 2, bad_date.stdout

print("OK")
