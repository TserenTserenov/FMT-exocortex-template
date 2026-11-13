"""WP-529 Ф270, findings 1 and 2 of the v0.42.0-rc.14 red team (settings.json merge on update)."""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / ".claude" / "scripts" / "settings-merge-preview.py"
TRASH = "$CLAUDE_PROJECT_DIR/.claude/hooks/check-trash.sh"
BOOTSTRAP = "$CLAUDE_PROJECT_DIR/.claude/hooks/session-start-hooks-bootstrap.sh"


def load_module():
    spec = importlib.util.spec_from_file_location("settings_merge_preview", SCRIPT)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def group(*commands, matcher=None):
    entry = {"hooks": [{"type": "command", "command": c} for c in commands]}
    if matcher is not None:
        entry["matcher"] = matcher
    return entry


def run_merge(tmp_path: Path, template: dict, workspace: dict) -> tuple[dict, dict]:
    (tmp_path / "t.json").write_text(json.dumps(template), encoding="utf-8")
    (tmp_path / "w.json").write_text(json.dumps(workspace), encoding="utf-8")
    out = subprocess.run(
        [sys.executable, str(SCRIPT), str(tmp_path / "t.json"), str(tmp_path / "w.json"), str(tmp_path / "p.json")],
        capture_output=True,
        text=True,
        check=True,
    )
    return json.loads(out.stdout), json.loads((tmp_path / "p.json").read_text(encoding="utf-8"))


def test_acceptedits_shipped_by_old_platform_is_replaced(tmp_path: Path):
    report, merged = run_merge(
        tmp_path,
        {"permissions": {"defaultMode": "default", "allow": []}},
        {"permissions": {"defaultMode": "acceptEdits", "allow": ["Bash(ls:*)"]}},
    )
    assert merged["permissions"]["defaultMode"] == "default"
    assert merged["permissions"]["allow"] == ["Bash(ls:*)"]
    assert report["retired_defaults_replaced"] == ["permissions.defaultMode: acceptEdits -> default"]
    assert "permissions.defaultMode" not in report["conflicts"]


def test_other_user_chosen_mode_is_kept_as_conflict(tmp_path: Path):
    report, merged = run_merge(
        tmp_path,
        {"permissions": {"defaultMode": "default"}},
        {"permissions": {"defaultMode": "plan"}},
    )
    assert merged["permissions"]["defaultMode"] == "plan"
    assert report["retired_defaults_replaced"] == []
    assert report["conflicts"] == ["permissions.defaultMode"]


def test_hook_regrouped_by_template_is_not_duplicated(tmp_path: Path):
    report, merged = run_merge(
        tmp_path,
        {"hooks": {"SessionStart": [group(TRASH, BOOTSTRAP), group("x.sh", matcher="compact")]}},
        {"hooks": {"SessionStart": [group(TRASH)]}},
    )
    commands = [h["command"] for e in merged["hooks"]["SessionStart"] for h in e["hooks"]]
    assert commands.count(TRASH) == 1
    assert BOOTSTRAP in commands and "x.sh" in commands
    assert report["hooks_regrouped"] == 1


def test_user_group_with_own_command_is_left_alone():
    module = load_module()
    report = {"conflicts": [], "hooks_added_from_template": 0, "hooks_deduped": 0}
    user = [group(TRASH, "my-own.sh")]
    merged, added, _deduped, _orphaned = module.merge_hook_entries(user, [group(TRASH, BOOTSTRAP)], report, "SessionStart")
    assert merged[0] == group(TRASH, "my-own.sh")
    assert added == 1
    assert report.get("hooks_regrouped", 0) == 0


def test_same_command_under_another_matcher_is_not_absorbed():
    module = load_module()
    report = {"conflicts": [], "hooks_added_from_template": 0, "hooks_deduped": 0}
    user = [group(TRASH, matcher="compact")]
    merged, _added, _deduped, _orphaned = module.merge_hook_entries(user, [group(TRASH, BOOTSTRAP)], report, "SessionStart")
    assert merged[0] == group(TRASH, matcher="compact")
    assert len(merged) == 2
