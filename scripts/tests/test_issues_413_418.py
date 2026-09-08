"""Regression coverage for issues #413 through #418."""

from __future__ import annotations

import importlib.util
import json
import os
import shutil
import subprocess
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[2]
STATUS_LEGEND = ROOT / "scripts" / "iwe-drift-helpers" / "check-status-legend.sh"
DAY_OPEN = ROOT / "scripts" / "day-open-scaffold.sh"
CLOSE_WP = ROOT / "scripts" / "close-wp.sh"
DESTRUCTIVE_GUARD = ROOT / ".claude" / "hooks" / "destructive-guard.sh"
MEMORY_DRIFT_SCAN = ROOT / ".claude" / "scripts" / "memory-drift-scan.py"


def load_memory_drift_scan():
    spec = importlib.util.spec_from_file_location("memory_drift_scan", MEMORY_DRIFT_SCAN)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_status_legend_finds_reordered_status_column(tmp_path: Path):
    registry = tmp_path / "WP-REGISTRY.md"
    registry.write_text(
        "\n".join(
            (
                "| Статус | Расшифровка |",
                "|---|---|",
                "| 🔄 | in_progress |",
                "| ✅ | done |",
                "",
                "| # | Название | Репо | Ст | P |",
                "|---|---|---|---|---|",
                "| 418 | Проверка | FMT | 🔄 | P1 |",
                "| ~~417~~ | Готово | FMT | ✅ | P2 |",
            )
        )
        + "\n",
        encoding="utf-8",
    )

    result = subprocess.run(
        ["bash", str(STATUS_LEGEND), "--registry", str(registry), "--critical-only"],
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0, result.stdout + result.stderr
    assert "format-compliance OK: 2" in result.stdout


def test_status_legend_accepts_skeleton_legend_format(tmp_path: Path):
    registry = tmp_path / "WP-REGISTRY.md"
    registry.write_text(
        "\n".join(
            (
                "| Эмодзи | Статус | Что значит |",
                "|---|---|---|",
                "| 🔄 | in_progress | активен |",
                "| ✅ | done | завершён |",
                "",
                "| # | P | Название | Ст |",
                "|---|---|---|---|",
                "| 418 | Проверка | легенды | 🔄 |",
                "| ~~417~~ | P2 | Готово | ✅ |",
            )
        )
        + "\n",
        encoding="utf-8",
    )

    result = subprocess.run(
        ["bash", str(STATUS_LEGEND), "--registry", str(registry), "--critical-only"],
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0, result.stdout + result.stderr


def test_status_legend_accepts_cancelled_wp_as_terminal(tmp_path: Path):
    registry = tmp_path / "WP-REGISTRY.md"
    registry.write_text(
        "\n".join(
            (
                "| Статус | Расшифровка |",
                "|---|---|",
                "| 🔄 | in_progress |",
                "| ❌ | cancelled |",
                "",
                "| # | Название | Ст |",
                "|---|---|---|",
                "| ~~405~~ | Отменённая работа | ❌ |",
            )
        )
        + "\n",
        encoding="utf-8",
    )

    result = subprocess.run(
        ["bash", str(STATUS_LEGEND), "--registry", str(registry), "--critical-only"],
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0, result.stdout + result.stderr
    assert "format-compliance OK: 1" in result.stdout


def test_day_open_uses_priority_draft_from_template_contract(tmp_path: Path):
    governance = tmp_path / "DS-strategy"
    drafts = governance / "drafts"
    drafts.mkdir(parents=True)
    (drafts / "draft-list.md").write_text(
        "\n".join(
            (
                "## Приоритетные (текущий период, 3-7 штук)",
                "",
                "| # | Черновик | Контекст | Источник | Создан | Следующий шаг |",
                "|---|---|---|---|---|---|",
                "| 1 | [D-417](./D-417-regression.md) | проверка | заметка | 2026-08-12 | дописать |",
                "",
                "## Полная коллекция",
            )
        )
        + "\n",
        encoding="utf-8",
    )
    os.symlink(ROOT / "scripts", tmp_path / "scripts")

    result = subprocess.run(
        ["bash", str(DAY_OPEN), "2026-08-12"],
        env={
            **os.environ,
            "IWE_WORKSPACE": str(tmp_path),
            "IWE_ROOT": str(tmp_path),
            "IWE_GOVERNANCE_REPO": "DS-strategy",
        },
        capture_output=True,
        text=True,
        check=False,
        timeout=30,
    )

    assert result.returncode == 0, result.stderr
    assert "[D-417](drafts/D-417-regression.md)" in result.stdout


def test_memory_drift_scan_ignores_status_cell_annotation(tmp_path: Path):
    memory = tmp_path / "MEMORY.md"
    governance = tmp_path / "DS-strategy"
    card = governance / "inbox" / "WP-414" / "WP-414.md"
    card.parent.mkdir(parents=True)
    card.write_text("---\nstatus: in_progress\n---\n", encoding="utf-8")
    memory.write_text(
        "| # | Работа | Статус |\n|---|---|---|\n| 414 | Проверка | **🔄** — ждёт ревью |\n",
        encoding="utf-8",
    )

    module = load_memory_drift_scan()
    assert module.scan(memory, governance) == []


def test_memory_drift_scan_keeps_real_status_difference_visible(tmp_path: Path):
    memory = tmp_path / "MEMORY.md"
    governance = tmp_path / "DS-strategy"
    card = governance / "inbox" / "WP-414" / "WP-414.md"
    card.parent.mkdir(parents=True)
    card.write_text("---\nstatus: in_progress\n---\n", encoding="utf-8")
    memory.write_text(
        "| # | Работа | Статус |\n|---|---|---|\n| 414 | Проверка | ⏳ — ожидает |\n",
        encoding="utf-8",
    )

    module = load_memory_drift_scan()
    assert len(module.scan(memory, governance)) == 1


def test_memory_drift_scan_normalizes_russian_statuses(tmp_path: Path):
    memory = tmp_path / "MEMORY.md"
    governance = tmp_path / "DS-strategy"
    card = governance / "inbox" / "WP-414" / "WP-414.md"
    card.parent.mkdir(parents=True)
    card.write_text("---\nstatus: blocked\n---\n", encoding="utf-8")
    memory.write_text(
        "| # | Работа | Статус |\n|---|---|---|\n| 414 | Проверка | ⏸ ЗАБЛОКИРОВАН — ждёт решения |\n",
        encoding="utf-8",
    )

    module = load_memory_drift_scan()
    assert module.scan(memory, governance) == []


def test_memory_drift_scan_keeps_paused_distinct_from_blocked(tmp_path: Path):
    memory = tmp_path / "MEMORY.md"
    governance = tmp_path / "DS-strategy"
    card = governance / "inbox" / "WP-414" / "WP-414.md"
    card.parent.mkdir(parents=True)
    card.write_text("---\nstatus: blocked\n---\n", encoding="utf-8")
    memory.write_text(
        "| # | Работа | Статус |\n|---|---|---|\n| 414 | Проверка | ⏸ — на паузе |\n",
        encoding="utf-8",
    )

    module = load_memory_drift_scan()
    drifts = module.scan(memory, governance)
    assert len(drifts) == 1
    assert "MEMORY.md=`paused` vs WP-context=`blocked`" in drifts[0]


def test_memory_drift_scan_covers_platform_status_markers():
    module = load_memory_drift_scan()

    assert module.normalize_status("🧪") == "in_progress"
    assert module.normalize_status("🚧") == "blocked"
    assert module.normalize_status("📦") == "done"
    assert module.normalize_status("↗️") == "done"
    assert module.normalize_status("❌") == "cancelled"
    assert module.normalize_status("выполнено") == "done"
    assert module.normalize_status("отменён") == "cancelled"


def test_close_wp_updates_canonical_folder_card(tmp_path: Path):
    governance = tmp_path / "DS-strategy"
    (governance / "docs").mkdir(parents=True)
    card = governance / "inbox" / "WP-413" / "WP-413.md"
    card.parent.mkdir(parents=True)
    (governance / "docs" / "WP-REGISTRY.md").write_text(
        "| # | P | Название | Ст |\n|---|---|---|---|\n| 413 | P1 | Проверка карточки | 🔄 |\n",
        encoding="utf-8",
    )
    card.write_text("---\nstatus: in_progress\ncreated: 2026-08-01\n---\n", encoding="utf-8")

    result = subprocess.run(
        ["bash", str(CLOSE_WP), "--wp", "413", "--summary", "готово"],
        env={**os.environ, "IWE_ROOT": str(tmp_path), "IWE_GOVERNANCE_REPO": "DS-strategy"},
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0, result.stdout + result.stderr
    content = card.read_text(encoding="utf-8")
    assert "status: done" in content
    assert "closed_date:" in content


def test_close_wp_uses_padded_card_and_single_archive_for_bare_number(tmp_path: Path):
    governance = tmp_path / "DS-strategy"
    (governance / "docs").mkdir(parents=True)
    card = governance / "inbox" / "WP-009" / "WP-009.md"
    card.parent.mkdir(parents=True)
    (governance / "docs" / "WP-REGISTRY.md").write_text(
        "| # | P | Название | Ст |\n|---|---|---|---|\n| 9 | P1 | Проверка архива | 🔄 |\n",
        encoding="utf-8",
    )
    card.write_text("---\nstatus: in_progress\ncreated: 2026-08-01\n---\n", encoding="utf-8")
    env = {**os.environ, "IWE_ROOT": str(tmp_path), "IWE_GOVERNANCE_REPO": "DS-strategy"}

    for _ in range(2):
        result = subprocess.run(
            ["bash", str(CLOSE_WP), "--wp", "9", "--summary", "готово"],
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )
        assert result.returncode == 0, result.stdout + result.stderr

    assert "status: done" in card.read_text(encoding="utf-8")
    archives = list((governance / "archive" / "wp-contexts").glob("WP-009-*.md"))
    assert len(archives) == 1
    assert not list((governance / "archive" / "wp-contexts").glob("WP-9-*.md"))


@pytest.mark.skipif(not shutil.which("jq"), reason="destructive guard requires jq")
def test_destructive_guard_ignores_quoted_git_argument_and_allows_no_loss_reset(tmp_path: Path):
    subprocess.run(["git", "init", "-q", str(tmp_path)], check=True)
    subprocess.run(["git", "-C", str(tmp_path), "config", "user.email", "test@example.test"], check=True)
    subprocess.run(["git", "-C", str(tmp_path), "config", "user.name", "Test"], check=True)
    (tmp_path / "tracked.txt").write_text("base\n", encoding="utf-8")
    subprocess.run(["git", "-C", str(tmp_path), "add", "tracked.txt"], check=True)
    subprocess.run(["git", "-C", str(tmp_path), "commit", "-qm", "base"], check=True)

    def run_guard(command: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            ["bash", str(DESTRUCTIVE_GUARD)],
            input=json.dumps({"tool_input": {"command": command}, "cwd": str(tmp_path)}),
            capture_output=True,
            text=True,
            check=False,
        )

    assert run_guard("printf '%s' 'git reset --hard HEAD'").returncode == 0
    assert run_guard(f"git -C {tmp_path} reset --hard HEAD").returncode == 0
    (tmp_path / "tracked.txt").write_text("dirty\n", encoding="utf-8")
    assert run_guard(f"git -C {tmp_path} reset --hard HEAD").returncode == 2
