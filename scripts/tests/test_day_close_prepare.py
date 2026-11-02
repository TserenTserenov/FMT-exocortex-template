"""
Тесты day-close-prepare.sh (issue #234, token-discipline Day Close).

Скрипт запускается как subprocess в синтетическом workspace (tmp_path):
  1. Digest-режим печатает все 11 секций и выходит с 0.
  2. --verify без итогов дня — FAIL по 9a/9b, exit 1.
  3. --verify с заархивированным DayPlan (итоги есть) и WeekReport — exit 0,
     включая английский заголовок "Day summary" (языко-толерантность 1c62621).
  4. Секция 6 вызывает memory-bleed.sh --hot-only и показывает его статус
     (issue #1314), с graceful fallback, когда инструмент недоступен.
  5. Отсутствующие необязательные шаги day-close дают skip
     в сводке и логе (#559).
  6. Закрытие дня после полуночи (РП-7 Ф286): все датированные секции и
     --verify берут закрываемый день (--date или day_boundary), не часы.
"""

import datetime
import os
import subprocess
from pathlib import Path

SCRIPT = Path(__file__).parent.parent / "day-close-prepare.sh"
DAY_CLOSE_SCRIPT = Path(__file__).parent.parent / "day-close.sh"

DIGEST_SECTIONS = [
    "1. COMMITS TODAY", "2. DIRTY REPOS", "3. OPEN SESSIONS LOG",
    "4. MEMORY DRIFT", "5. INDEX HEALTH", "6. LESSON / MEMORY STATS",
    "7. WAKATIME", "8. PEER SESSIONS TODAY", "9. DAYPLANS IN current/",
    "10. DONE WP CONTEXTS IN inbox/", "11. WEEKREPORT",
]


def _make_workspace(tmp_path: Path) -> Path:
    ws = tmp_path / "workspace"
    gov = ws / "DS-strategy"
    for sub in ["current", "inbox", "archive/day-plans", "sessions"]:
        (gov / sub).mkdir(parents=True)
    (ws / "memory").mkdir()
    (ws / "memory" / "MEMORY.md").write_text("# memory\n", encoding="utf-8")
    return ws


def _run(
    ws: Path, tmp_path: Path, *args: str, script: Path = SCRIPT, env_overrides: dict = None
) -> subprocess.CompletedProcess:
    env = {
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "HOME": str(tmp_path / "home"),
        "WORKSPACE_DIR": str(ws),
        "IWE_TEMPLATE": str(tmp_path / "no-template"),  # forces dirty_scan fallback
    }
    env.update(env_overrides or {})
    (tmp_path / "home").mkdir(exist_ok=True)
    return subprocess.run(
        ["bash", str(script), *args],
        capture_output=True, text=True, env=env,
    )


def test_digest_emits_all_sections(tmp_path):
    ws = _make_workspace(tmp_path)
    result = _run(ws, tmp_path)
    assert result.returncode == 0, result.stderr
    for section in DIGEST_SECTIONS:
        assert section in result.stdout, f"missing digest section: {section}"
    assert "END DIGEST" in result.stdout


def test_digest_reports_hot_limit_via_memory_bleed(tmp_path):
    # issue #1314: section 6 used to count "lessons_"/"lesson-" filenames against
    # a MEMORY.md "Уроки" section that no longer exists under the frontmatter
    # scheme -- it now runs the already-shipped memory-bleed.sh --hot-only
    # (same tool Week/Month Close already call) instead of that dead grep.
    ws = _make_workspace(tmp_path)
    (ws / "memory" / "feedback-example.md").write_text(
        "---\n"
        "name: feedback-example\n"
        "description: test\n"
        "type: feedback\n"
        "horizon: hot\n"
        "status: active\n"
        "valid_from: 2026-01-01\n"
        "owner: user\n"
        "schema_version: 1\n"
        "---\n"
        "body\n",
        encoding="utf-8",
    )
    repo_root = SCRIPT.parent.parent
    result = _run(ws, tmp_path, env_overrides={"IWE_TEMPLATE": str(repo_root)})
    assert result.returncode == 0, result.stderr
    assert "HOT-лимит" in result.stdout


def test_digest_falls_back_when_memory_bleed_unavailable(tmp_path):
    # Same section 6, but IWE_TEMPLATE is the fake path _run() defaults to --
    # memory-bleed.sh does not exist there, and the digest must say so instead
    # of silently printing nothing or crashing (set -uo pipefail, no `set -e`).
    ws = _make_workspace(tmp_path)
    result = _run(ws, tmp_path)
    assert result.returncode == 0, result.stderr
    assert "memory-bleed.sh: нет данных" in result.stdout


def test_day_close_records_missing_optional_steps_as_skipped(tmp_path):
    ws = _make_workspace(tmp_path)
    result = _run(
        ws, tmp_path, "--reindex", "--linear", "--sessions", script=DAY_CLOSE_SCRIPT
    )
    assert result.returncode == 0, result.stderr
    assert "selective-reindex.sh не найден" in result.stdout
    assert "linear-sync.sh не найден" in result.stdout
    assert "Шаг 4/4: Консолидация сессий дня" in result.stdout
    assert (
        "Папка " in result.stdout
        or "Консолидация сессий: пропущено — pyyaml не найден" in result.stdout
    )
    expected = "backup=skip  reindex=skip  linear=skip  sessions=skip"
    assert expected in result.stdout
    log = (tmp_path / "home" / "logs" / "day-close.log").read_text(
        encoding="utf-8"
    )
    assert "backup=skip reindex=skip linear=skip sessions=skip" in log


def test_verify_fails_when_day_not_closed(tmp_path):
    ws = _make_workspace(tmp_path)
    result = _run(ws, tmp_path, "--verify")
    assert result.returncode == 1
    assert "9a FAIL" in result.stdout
    assert "9b FAIL" in result.stdout


def test_verify_passes_with_closed_day_english_headings(tmp_path):
    ws = _make_workspace(tmp_path)
    gov = ws / "DS-strategy"
    today = datetime.date.today()
    (gov / "archive/day-plans" / f"DayPlan {today.isoformat()}.md").write_text(
        f"# DayPlan\n## Day summary ({today.isoformat()})\ndone\n", encoding="utf-8"
    )
    (gov / "current" / "WeekReport W29.md").write_text(
        f"<details><summary><b>Results — {today.day} July</b></summary>ok</details>\n",
        encoding="utf-8",
    )
    result = _run(ws, tmp_path, "--verify")
    assert result.returncode == 0, result.stdout
    assert "9a OK" in result.stdout
    assert "9b OK" in result.stdout
    assert "dirty OK" in result.stdout


CLOSED = "2026-10-31"  # a past day, never the clock date
NEXT = "2026-11-01"


def _git_repo_with_commits(ws: Path) -> None:
    """One commit inside the closed day, one just after its midnight."""
    repo = ws / "DS-sample"
    repo.mkdir()
    git = ["git", "-C", str(repo)]
    subprocess.run([*git, "init", "-q"], check=True)
    for stamp, msg in [(f"{CLOSED}T15:00:00", "feat: closed-day work"),
                       (f"{NEXT}T00:30:00", "feat: after-midnight work")]:
        env = {**os.environ, "GIT_AUTHOR_DATE": stamp, "GIT_COMMITTER_DATE": stamp}
        subprocess.run(
            [*git, "-c", "user.name=t", "-c", "user.email=t@t", "commit",
             "-q", "--allow-empty", "-m", msg],
            check=True, env=env,
        )


def _run_live_path(ws: Path, tmp_path: Path, *args: str) -> subprocess.CompletedProcess:
    # git and date must resolve on hosts where they are not in /usr/bin (NixOS).
    return _run(ws, tmp_path, *args, env_overrides={"PATH": os.environ["PATH"]})


def test_date_arg_scopes_every_dated_section_to_the_closed_day(tmp_path):
    ws = _make_workspace(tmp_path)
    gov = ws / "DS-strategy"
    _git_repo_with_commits(ws)
    (gov / "inbox" / "open-sessions.log").write_text(
        f"{CLOSED} 21:00 | closed-day session\n{NEXT} 00:40 | next-day session\n",
        encoding="utf-8",
    )
    result = _run_live_path(ws, tmp_path, "--date", CLOSED)
    assert result.returncode == 0, result.stderr
    assert f"DAY CLOSE DIGEST {CLOSED} " in result.stdout
    assert "date from: --date" in result.stdout
    assert "closed-day work" in result.stdout
    assert "after-midnight work" not in result.stdout
    assert "closed-day session" in result.stdout
    assert "next-day session" not in result.stdout


def test_day_boundary_moves_after_midnight_work_into_the_closed_day(tmp_path):
    # Boundary 04:30: the 00:30 commit of NEXT still belongs to CLOSED.
    ws = _make_workspace(tmp_path)
    _git_repo_with_commits(ws)
    (ws / "memory" / "day-rhythm-config.yaml").write_text(
        'day_open:\n  day_boundary: "04:30"\n', encoding="utf-8"
    )
    result = _run_live_path(ws, tmp_path, "--date", CLOSED)
    assert result.returncode == 0, result.stderr
    assert "closed-day work" in result.stdout
    assert "after-midnight work" in result.stdout


def test_auto_date_honours_day_boundary(tmp_path):
    # Boundary 23:59 puts the clock before it all day except one minute,
    # so the auto date is the previous calendar day.
    now = datetime.datetime.now()
    if now.hour == 23 and now.minute == 59:
        return
    ws = _make_workspace(tmp_path)
    (ws / "memory" / "day-rhythm-config.yaml").write_text(
        'day_open:\n  day_boundary: "23:59"\n', encoding="utf-8"
    )
    yesterday = (datetime.date.today() - datetime.timedelta(days=1)).isoformat()
    result = _run_live_path(ws, tmp_path)
    assert result.returncode == 0, result.stderr
    assert f"DAY CLOSE DIGEST {yesterday} " in result.stdout
    assert "date from: day_boundary 23:59" in result.stdout


def test_commented_day_boundary_keeps_the_clock_date(tmp_path):
    ws = _make_workspace(tmp_path)
    (ws / "memory" / "day-rhythm-config.yaml").write_text(
        'day_open:\n  # day_boundary: "23:59"\n', encoding="utf-8"
    )
    result = _run_live_path(ws, tmp_path)
    assert result.returncode == 0, result.stderr
    assert f"DAY CLOSE DIGEST {datetime.date.today().isoformat()} " in result.stdout
    assert "date from: clock" in result.stdout


def test_verify_checks_the_closed_day_not_the_clock(tmp_path):
    ws = _make_workspace(tmp_path)
    gov = ws / "DS-strategy"
    (gov / "archive/day-plans" / f"DayPlan {CLOSED}.md").write_text(
        f"# DayPlan\n## Итоги дня ({CLOSED})\ndone\n", encoding="utf-8"
    )
    (gov / "current" / "WeekReport W44.md").write_text(
        "## Итоги 31 октября\nok\n", encoding="utf-8"
    )
    result = _run_live_path(ws, tmp_path, "--verify", "--date", CLOSED)
    assert result.returncode == 0, result.stdout
    assert f"9a OK: day summary present in archived DayPlan {CLOSED}" in result.stdout
    assert "9b OK" in result.stdout


def test_invalid_date_is_rejected(tmp_path):
    ws = _make_workspace(tmp_path)
    for bad in ["2026-13-01", "2026-02-30", "yesterday"]:
        result = _run_live_path(ws, tmp_path, "--date", bad)
        assert result.returncode == 2, (bad, result.stdout)
        assert "--date ожидает YYYY-MM-DD" in result.stderr
    assert _run_live_path(ws, tmp_path, "--bogus").returncode == 2


def test_for_date_is_an_alias_of_date(tmp_path):
    # The governance-repo port of this script and its skill pass --for-date.
    ws = _make_workspace(tmp_path)
    result = _run_live_path(ws, tmp_path, "--for-date", CLOSED)
    assert result.returncode == 0, result.stderr
    assert f"DAY CLOSE DIGEST {CLOSED} " in result.stdout
