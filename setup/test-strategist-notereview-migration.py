#!/usr/bin/env python3
"""Exercise the real installer with private HOME/runtime and launchctl stubs."""

import copy
import importlib.util
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
LABEL = "com.strategist.notereview"


class MigrationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="notereview test ")
        self.addCleanup(self.temporary.cleanup)
        self.base = Path(self.temporary.name)
        self.home = self.base / "home"
        self.workspace = self.base / "workspace"
        self.runtime = self.workspace / ".iwe-runtime"
        self.agents = self.home / "Library/LaunchAgents"
        self.source = self.runtime / "roles/strategist/scripts/launchd"
        self.agents.mkdir(parents=True)
        self.source.mkdir(parents=True)
        self.script = self.source.parent / "strategist.sh"
        self.script.write_text("#!/bin/sh\nexit 0\n")
        values = {
            "IWE_TEMPLATE": str(ROOT),
            "IWE_RUNTIME": str(self.runtime),
            "WORKSPACE_DIR": str(self.workspace),
            "IWE_SCRIPTS": str(ROOT / "scripts"),
            "GOVERNANCE_REPO": "DS-strategy",
            "HOME_DIR": str(self.home),
            "USER_NAME": "fixture",
            "TIMEZONE_HOUR": "4",
        }
        for job in ("morning", "weekreview", "notereview"):
            name = f"com.strategist.{job}.plist"
            text = (ROOT / "roles/strategist/scripts/launchd" / name).read_text()
            for key, value in values.items():
                text = text.replace("{{" + key + "}}", value)
            (self.source / name).write_text(text)
        self.bin = self.base / "bin"
        self.bin.mkdir()
        self.calls = self.base / "launchctl.calls"
        for name, content in {
            "uname": "#!/bin/sh\necho Darwin\n",
            "launchctl": '#!/bin/sh\nprintf "%s\\n" "$*" >> "$TEST_LAUNCHCTL_LOG"\n[ "$1" != list ] || echo com.strategist.morning\nexit 0\n',
        }.items():
            path = self.bin / name
            path.write_text(content)
            path.chmod(0o755)
        self.env = dict(os.environ)
        self.env.pop("SETUP_CI", None)
        self.env.update(
            HOME=str(self.home),
            PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
            IWE_WORKSPACE=str(self.workspace),
            IWE_RUNTIME=str(self.runtime),
            IWE_TEMPLATE=str(ROOT),
            IWE_SCRIPTS=str(ROOT / "scripts"),
            TEST_LAUNCHCTL_LOG=str(self.calls),
        )
        self.installed = {
            "Label": LABEL,
            "ProgramArguments": [
                str(self.workspace / "DS-ai-systems/strategist/scripts/strategist.sh"),
                "note-review",
            ],
            "EnvironmentVariables": {"HOME": str(self.home), "PATH": "/custom/bin", "CUSTOM": "retain"},
            "StartCalendarInterval": [{"Hour": 23, "Minute": 17, "Weekday": 2}],
            "StartInterval": 172800,
            "RunAtLoad": False,
            "Disabled": True,
            "KeepAlive": False,
            "StandardOutPath": "/custom/log",
        }

    def install(self):
        result = subprocess.run(
            ["bash", str(ROOT / "roles/strategist/install.sh")],
            env=self.env, text=True, capture_output=True, timeout=30,
        )
        if self.calls.exists():
            self.assertNotIn(LABEL, self.calls.read_text())
        return result

    def write_installed(self, suffix=".plist.disabled"):
        path = self.agents / (LABEL + suffix)
        path.write_bytes(plistlib.dumps(self.installed, sort_keys=False))
        path.chmod(0o640)
        return path

    def assert_refused(self, path):
        before = path.read_bytes()
        result = self.install()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("note-review", result.stderr)
        self.assertEqual(path.read_bytes(), before)
        self.assertFalse(list(self.agents.glob("*.bak-*")))
        self.assertFalse(self.calls.exists())

    def test_disabled_legacy_migrates_without_activation_and_is_idempotent(self):
        path = self.write_installed()
        original = path.read_bytes()
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        data = plistlib.loads(path.read_bytes())
        expected = copy.deepcopy(self.installed)
        expected["ProgramArguments"] = [str(self.script), "note-review"]
        runtime_env = plistlib.loads((self.source / (LABEL + ".plist")).read_bytes())["EnvironmentVariables"]
        expected["EnvironmentVariables"].update({key: value for key, value in runtime_env.items() if key.startswith("IWE_")})
        self.assertEqual(data, expected)
        self.assertEqual(path.stat().st_mode & 0o777, 0o640)
        backups = list(self.agents.glob(LABEL + "*.bak-*"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_bytes(), original)
        self.assertFalse((self.agents / (LABEL + ".plist")).exists())
        migrated = path.read_bytes()
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(path.read_bytes(), migrated)
        self.assertEqual(list(self.agents.glob(LABEL + "*.bak-*")), backups)

    def test_active_config_preserves_triggers_and_requires_explicit_reload(self):
        self.installed["RunAtLoad"] = True
        self.installed.pop("Disabled")
        path = self.write_installed(".plist")
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        updated = plistlib.loads(path.read_bytes())
        for key in ("StartCalendarInterval", "StartInterval", "RunAtLoad", "KeepAlive"):
            self.assertEqual(updated[key], self.installed[key])
        self.assertNotIn("Disabled", updated)
        self.assertIn("explicit reload", result.stdout)

    def test_fresh_install_keeps_manual_only(self):
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(list(self.agents.glob(LABEL + "*")))
        template = plistlib.loads((self.source / (LABEL + ".plist")).read_bytes())
        self.assertNotIn("StartCalendarInterval", template)
        self.assertFalse(template["RunAtLoad"])

    def test_foreign_workspace_unchanged_even_with_matching_command(self):
        self.installed["EnvironmentVariables"]["IWE_WORKSPACE"] = str(self.base / "foreign")
        self.assert_refused(self.write_installed())

    def test_foreign_legacy_prefix_without_owner_unchanged(self):
        self.installed["ProgramArguments"][0] = str(self.base / "foreign/DS-ai-systems/strategist/scripts/strategist.sh")
        self.assert_refused(self.write_installed())

    def test_legacy_repository_name_is_installation_specific(self):
        self.installed["ProgramArguments"][0] = str(self.workspace / "DS-personal-agents/strategist/scripts/strategist.sh")
        path = self.write_installed()
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(plistlib.loads(path.read_bytes())["ProgramArguments"], [str(self.script), "note-review"])

    def test_legacy_symlink_outside_workspace_is_refused(self):
        foreign = self.base / "foreign"
        foreign.mkdir()
        (self.workspace / "DS-ai-systems").symlink_to(foreign, target_is_directory=True)
        self.assert_refused(self.write_installed())

    def test_nested_legacy_lookalike_is_refused(self):
        self.installed["ProgramArguments"][0] = str(self.workspace / "nested/repo/strategist/scripts/strategist.sh")
        self.assert_refused(self.write_installed())

    def test_unknown_command_unchanged_even_with_matching_owner(self):
        self.installed["EnvironmentVariables"]["IWE_WORKSPACE"] = str(self.workspace)
        self.installed["ProgramArguments"] = ["/custom/strategist.sh", "note-review"]
        self.assert_refused(self.write_installed())

    def test_program_override_unchanged(self):
        self.installed["Program"] = "/custom/executable"
        self.assert_refused(self.write_installed())

    def test_unlabelled_current_command_unchanged(self):
        self.installed["ProgramArguments"][0] = str(self.script)
        self.assert_refused(self.write_installed())

    def test_ambiguous_active_and_disabled_unchanged(self):
        active = self.write_installed(".plist")
        disabled = self.write_installed()
        self.assert_refused(active)
        self.assertEqual(active.read_bytes(), disabled.read_bytes())

    def test_symlink_unchanged(self):
        original = self.write_installed()
        other = self.base / "original.plist"
        original.rename(other)
        original.symlink_to(other)
        self.assert_refused(original)
        self.assertTrue(original.is_symlink())

    def test_dangling_symlink_unchanged(self):
        path = self.agents / (LABEL + ".plist.disabled")
        path.symlink_to(self.base / "missing")
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(path.is_symlink())
        self.assertFalse(self.calls.exists())

    def test_malformed_plist_unchanged(self):
        path = self.write_installed()
        path.write_bytes(b"not a plist")
        self.assert_refused(path)

    def test_wrong_label_unchanged(self):
        self.installed["Label"] = "com.strategist.foreign"
        self.assert_refused(self.write_installed())

    def test_missing_runtime_script_unchanged(self):
        self.script.unlink()
        self.assert_refused(self.write_installed())

    def test_missing_workspace_unchanged(self):
        self.env.pop("IWE_WORKSPACE")
        self.assert_refused(self.write_installed())

    def test_unexpanded_runtime_template_unchanged(self):
        template = self.source / (LABEL + ".plist")
        template.write_text(template.read_text().replace(str(ROOT), "{{IWE_TEMPLATE}}"))
        self.assert_refused(self.write_installed())

    def test_malformed_xml_unchanged(self):
        path = self.write_installed()
        path.write_bytes(b'<?xml version="1.0"?><plist><dict><key>broken</plist>')
        self.assert_refused(path)

    def test_no_schedule_is_added(self):
        for key in ("StartCalendarInterval", "StartInterval", "RunAtLoad", "KeepAlive", "Disabled"):
            self.installed.pop(key)
        path = self.write_installed()
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        data = plistlib.loads(path.read_bytes())
        self.assertFalse(set(data) & {"StartCalendarInterval", "StartInterval", "RunAtLoad", "KeepAlive", "Disabled"})

    def test_edit_during_backup_is_not_overwritten(self):
        path = self.write_installed()
        spec = importlib.util.spec_from_file_location(
            "migration", ROOT / "roles/strategist/migrate-notereview-launchd.py"
        )
        migration = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(migration)
        original = path.read_bytes()
        other_edit = copy.deepcopy(self.installed)
        other_edit["StartInterval"] = 333
        other_bytes = plistlib.dumps(other_edit)
        fsync = os.fsync
        calls = 0

        def concurrent_edit(fd):
            nonlocal calls
            fsync(fd)
            calls += 1
            if calls == 2:  # backup is durable; another writer saves its change
                path.write_bytes(other_bytes)

        with mock.patch.object(migration.os, "fsync", side_effect=concurrent_edit):
            with self.assertRaisesRegex(ValueError, "changed during migration"):
                migration.write_migration(path, original, self.installed)
        self.assertEqual(path.read_bytes(), other_bytes)
        self.assertFalse(list(self.agents.glob("*.tmp-*")))
        backups = list(self.agents.glob(LABEL + "*.bak-*"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
