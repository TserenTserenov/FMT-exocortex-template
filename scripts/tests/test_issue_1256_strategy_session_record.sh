#!/usr/bin/env bash
# Execute the documented writer/reader snippets against isolated installations.
set -euo pipefail
TEST_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TEMPLATE_ROOT="${STRATEGY_RECORD_ROOT_UNDER_TEST:-$TEST_DIR/../..}"
python3 - "$TEMPLATE_ROOT" <<'PY'
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(sys.argv[1]).resolve()
WRITER = (ROOT / "extensions/protocol-close.after.session-record.md").read_text(encoding="utf-8")
SKILL = (ROOT / ".claude/skills/strategy-session/SKILL.md").read_text(encoding="utf-8")
MONTHLY = (ROOT / "roles/strategist/prompts/strategy-session-monthly.md").read_text(encoding="utf-8")


def first_bash(text):
    match = re.search(r"```bash\n(.*?)```", text, re.S)
    if not match:
        raise AssertionError("Missing executable bash block")
    return match.group(1)


class SessionRecordTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="issue-1256-")
        self.addCleanup(self.temp.cleanup)
        self.ws = Path(self.temp.name) / "workspace with spaces"
        self.gov = self.ws / "GOV"
        self.gov.mkdir(parents=True)
        self.template = self.ws / "template"
        self.common = self.template / "scripts/lib/common.sh"
        self.common.parent.mkdir(parents=True)
        shutil.copyfile(ROOT / "scripts/lib/common.sh", self.common)
        self.env = {
            key: value for key, value in os.environ.items()
            if not key.startswith("IWE_")
            and key not in {"GOVERNANCE_REPO", "GOV_WT", "WORKSPACE_DIR", "BASH_ENV", "ENV"}
        }
        self.env["GOV_WT"] = str(self.gov)

    def run_block(self, block, *, env=None, tail="", cwd=None):
        replacements = {
            "{{WORKSPACE_DIR}}": str(self.ws),
            "{{IWE_TEMPLATE}}": str(self.template),
            "{{GOVERNANCE_REPO}}": "GOV",
            "<записанный путь>": str(self.gov),
            "<тема>": "topic",
            "$(date +%Y-%m)": "2026-10",
            "$(date +%F)": "2026-10-02",
        }
        for old, new in replacements.items():
            block = block.replace(old, new)
        return subprocess.run(
            ["bash", "-c", block + tail], cwd=cwd or self.gov,
            env={**self.env, **(env or {})}, capture_output=True, text=True, check=False,
        )

    def record_path(self, env=None):
        result = self.run_block(first_bash(WRITER), env=env, tail='\nprintf "%s\\n" "$SESSION_RECORD"\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        return Path(result.stdout.strip())

    def search(self, env=None):
        return self.run_block(first_bash(SKILL[SKILL.index("## Шаг 1."):]), env=env)

    def roundtrip(self, expected, env=None):
        path = self.record_path(env)
        self.assertEqual(path.parent, expected)
        template = re.search(r"```markdown\n(.*?)```", WRITER, re.S).group(1)
        template = template.replace("strategy | work | review | planning", "strategy")
        template = template.replace("YYYY-MM-DD", "2026-10-02").replace("<тема>", "topic")
        path.write_text(template, encoding="utf-8")
        self.assertIn(str(path), self.search(env).stdout.splitlines())
        return path

    def test_migrated_install_without_root_scripts(self):
        sessions = self.ws / "MC-sessions"
        sessions.mkdir()
        self.roundtrip(sessions)
        self.assertFalse((self.gov / "sessions").exists())

    def test_scripts_override(self):
        scripts = self.ws / "runtime scripts"
        scripts.mkdir(exist_ok=True)
        (scripts / "lib").mkdir(exist_ok=True)
        shutil.move(str(self.common), str(scripts / "lib/common.sh"))
        sessions = self.ws / "MC-sessions"
        sessions.mkdir()
        self.roundtrip(sessions, {"IWE_SCRIPTS": str(scripts)})

    def test_explicit_sessions_override(self):
        sessions = self.ws / "custom journal"
        sessions.mkdir()
        (self.ws / "MC-sessions").mkdir()
        self.roundtrip(sessions, {"IWE_SESSIONS_ROOT": str(sessions)})

    def test_legacy(self):
        self.roundtrip(self.gov / "sessions")

    def test_legacy_uses_active_copy_with_library_available(self):
        canon = self.gov
        self.gov = self.ws / "isolated governance"
        self.gov.mkdir()
        self.env["GOV_WT"] = str(self.gov)
        self.roundtrip(self.gov / "sessions")
        self.assertFalse((canon / "sessions").exists())

    def test_relative_override_is_independent_of_current_directory(self):
        sessions = self.ws / "journal"
        sessions.mkdir()
        (self.gov / "journal").mkdir()
        env = {"IWE_SESSIONS_ROOT": "journal"}
        result = self.run_block(
            first_bash(WRITER), env=env, cwd=self.ws,
            tail='\nprintf "%s\\n" "$SESSION_RECORD"\n',
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        path = Path(result.stdout.strip())
        self.assertEqual(path.parent, sessions)
        path.write_text("---\nsession_type: strategy\n---\n# Встреча\n", encoding="utf-8")
        self.assertIn(str(path), self.search(env).stdout.splitlines())
        self.assertEqual(list((self.gov / "journal").iterdir()), [])

    def test_resolver_without_argument_keeps_legacy_contract(self):
        result = self.run_block(
            f'source "{self.common}"\niwe_sessions_dir\n',
            env={"IWE_ROOT": str(self.ws), "GOVERNANCE_REPO": "GOV"},
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), str(self.gov / "sessions"))

    def test_missing_library_uses_active_governance_copy(self):
        self.common.unlink()
        self.gov = self.ws / "isolated governance"
        self.gov.mkdir()
        self.env["GOV_WT"] = str(self.gov)
        self.roundtrip(self.gov / "sessions")

    def test_root_library_fallback(self):
        root_common = self.ws / "scripts/lib/common.sh"
        root_common.parent.mkdir(parents=True)
        shutil.move(str(self.common), str(root_common))
        sessions = self.ws / "MC-sessions"
        sessions.mkdir()
        self.roundtrip(sessions)

    def test_missing_library_preserves_valid_override(self):
        self.common.unlink()
        sessions = self.ws / "custom journal"
        sessions.mkdir()
        self.roundtrip(sessions, {"IWE_SESSIONS_ROOT": str(sessions)})

    def test_invalid_override_fails_without_fallback(self):
        env = {"IWE_SESSIONS_ROOT": str(self.ws / "missing journal")}
        for block in [first_bash(WRITER), first_bash(SKILL[SKILL.index("## Шаг 1."):])]:
            result = self.run_block(block, env=env)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("IWE_SESSIONS_ROOT", result.stderr)
        self.assertFalse((self.gov / "sessions").exists())
        self.assertFalse((self.ws / "missing journal").exists())

    def test_non_strategy_types_do_not_count(self):
        path = self.record_path()
        for kind in ["work", "review", "planning", "strategy-other"]:
            path.write_text(f"---\nsession_type: {kind}\n---\n# Рабочая встреча\n", encoding="utf-8")
            self.assertNotIn(str(path), self.search().stdout)

    def test_legacy_markers_and_month_subdirectories(self):
        path = self.record_path()
        nested = path.parent / "2026-10/02/report.md"
        nested.parent.mkdir(parents=True)
        for marker in ["strategy-session", "Strategy Session"]:
            nested.write_text(f"# {marker}\n", encoding="utf-8")
            self.assertIn(str(nested), self.search().stdout.splitlines())

    def test_monthly_loads_suffix_extension(self):
        block = first_bash(MONTHLY[MONTHLY.index("## Завершение monthly-сессии"):])
        loader = self.ws / ".claude/scripts/load-extensions.sh"
        loader.parent.mkdir(parents=True)
        shutil.copyfile(ROOT / ".claude/scripts/load-extensions.sh", loader)
        extensions = self.ws / "extensions"
        extensions.mkdir()
        extension = extensions / "strategy-session.after.session-record.md"
        extension.write_text("# Record session\n", encoding="utf-8")
        (extensions / "strategy-session.before.other.md").write_text("# Before\n", encoding="utf-8")
        result = self.run_block(block, env={"IWE_WORKSPACE": str(self.ws)})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), [str(extension)])

    def test_monthly_completion_contract(self):
        self.assertEqual(MONTHLY.count("load-extensions.sh"), 1)
        self.assertIn("Только после успешного шага 8", MONTHLY)
        self.assertIn("after не запускать", MONTHLY)
        self.assertIn("один раз за завершённую сессию", MONTHLY)
        self.assertIn("повторно здесь не вызывать", SKILL)
        self.assertIn("дата сессии ≤7 числа", SKILL)


unittest.main(argv=[sys.argv[0]], verbosity=2)
PY
