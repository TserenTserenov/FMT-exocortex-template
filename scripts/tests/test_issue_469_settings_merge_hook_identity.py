"""Regression coverage for issue #469."""

from __future__ import annotations

import importlib.util
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / ".claude" / "scripts" / "settings-merge-preview.py"


def load_module():
    spec = importlib.util.spec_from_file_location("settings_merge_preview", SCRIPT)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_same_script_old_and_new_path_form_dedupes(tmp_path: Path):
    module = load_module()
    report = {"conflicts": [], "hooks_added_from_template": 0, "hooks_deduped": 0}
    user = [{"matcher": "Bash", "hooks": [{"type": "command", "command": ".claude/hooks/destructive-guard.sh"}]}]
    template = [
        {
            "matcher": "Bash",
            "hooks": [{"type": "command", "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/destructive-guard.sh"}],
        }
    ]
    merged, added, deduped = module.merge_hook_entries(user, template, report, "PreToolUse")
    assert len(merged) == 1
    assert added == 0 and deduped == 1
    assert report["conflicts"] == []


def test_wider_template_matcher_replaces_narrower_user_matcher(tmp_path: Path):
    module = load_module()
    report = {"conflicts": [], "hooks_added_from_template": 0, "hooks_deduped": 0}
    user = [
        {
            "matcher": "Write|Edit|MultiEdit",
            "hooks": [{"type": "command", "command": ".claude/hooks/memory-exocortex-sync.sh"}],
        }
    ]
    template = [
        {
            "matcher": "Write|Edit|MultiEdit|Bash",
            "hooks": [{"type": "command", "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/memory-exocortex-sync.sh"}],
        }
    ]
    merged, added, deduped = module.merge_hook_entries(user, template, report, "PreToolUse")
    assert len(merged) == 1
    assert merged[0]["matcher"] == "Write|Edit|MultiEdit|Bash"
    assert added == 0 and deduped == 1
    assert report["conflicts"] == []


def test_narrower_template_matcher_is_absorbed_not_duplicated(tmp_path: Path):
    module = load_module()
    report = {"conflicts": [], "hooks_added_from_template": 0, "hooks_deduped": 0}
    user = [{"matcher": "Write|Edit|MultiEdit|Bash", "hooks": [{"type": "command", "command": "x.sh"}]}]
    template = [{"matcher": "Bash", "hooks": [{"type": "command", "command": "x.sh"}]}]
    merged, added, deduped = module.merge_hook_entries(user, template, report, "PreToolUse")
    assert len(merged) == 1
    assert merged[0]["matcher"] == "Write|Edit|MultiEdit|Bash"
    assert added == 0 and deduped == 1


def test_unrelated_hooks_are_not_touched(tmp_path: Path):
    module = load_module()
    report = {"conflicts": [], "hooks_added_from_template": 0, "hooks_deduped": 0}
    user = [{"matcher": "Skill", "hooks": [{"type": "command", "command": "a.sh"}]}]
    template = [{"matcher": "Bash", "hooks": [{"type": "command", "command": "b.sh"}]}]
    merged, added, deduped = module.merge_hook_entries(user, template, report, "PreToolUse")
    assert len(merged) == 2
    assert added == 1 and deduped == 0


def test_non_simple_matcher_is_not_guessed_kept_as_conflict(tmp_path: Path):
    module = load_module()
    report = {"conflicts": [], "hooks_added_from_template": 0, "hooks_deduped": 0}
    # A regex group is exactly the shape Codex flagged as unsafe to split on
    # "|" — the safety guard must leave both entries and record a conflict
    # instead of guessing a superset relationship.
    user = [{"matcher": "(Bash|Skill)", "hooks": [{"type": "command", "command": "x.sh"}]}]
    template = [{"matcher": "Bash|Skill|Read", "hooks": [{"type": "command", "command": "x.sh"}]}]
    merged, added, deduped = module.merge_hook_entries(user, template, report, "PreToolUse")
    assert len(merged) == 2, "genuine conflict must keep both entries, not silently merge"
    assert added == 1 and deduped == 0
    assert any("PreToolUse" in c for c in report["conflicts"])


def test_end_to_end_preview_matches_issue_469_scenario(tmp_path: Path):
    module = load_module()
    template_path = tmp_path / "template.json"
    workspace_path = tmp_path / "workspace.json"
    preview_path = tmp_path / "preview.json"
    template_path.write_text(
        json.dumps(
            {
                "hooks": {
                    "PreToolUse": [
                        {
                            "matcher": "Bash",
                            "hooks": [{"type": "command", "command": "$CLAUDE_PROJECT_DIR/.claude/hooks/destructive-guard.sh"}],
                        }
                    ]
                }
            }
        ),
        encoding="utf-8",
    )
    workspace_path.write_text(
        json.dumps(
            {"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": ".claude/hooks/destructive-guard.sh"}]}]}}
        ),
        encoding="utf-8",
    )

    exit_code = module.main(["settings-merge-preview.py", str(template_path), str(workspace_path), str(preview_path)])
    assert exit_code == 0
    merged = json.loads(preview_path.read_text(encoding="utf-8"))
    assert len(merged["hooks"]["PreToolUse"]) == 1, "issue #469: same hook must not be duplicated in the merged preview"
