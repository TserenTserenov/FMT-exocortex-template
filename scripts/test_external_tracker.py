#!/usr/bin/env python3
"""Regression tests for scripts/external-tracker.py."""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
TRACKER = ROOT / "scripts" / "external-tracker.py"


class ExternalTrackerTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tempdir.name)
        self.context = self.root / "inbox" / "WP-123" / "WP-123.md"
        self.context.parent.mkdir(parents=True)
        self.context.write_text("---\nwp: 123\ntitle: Test adapter\nstatus: in_progress\n---\nbody\n", encoding="utf-8")
        self.config = self.root / "params.yaml"
        self.config.write_text("external_tracker:\n  adapter: github_issues\n  failure_policy: preserve_local\n  source_of_truth: iwe\n  github:\n    owner: acme\n    repositories:\n      - acme/widgets\n", encoding="utf-8")
        self.gh = self.root / "gh"
        self.gh.write_text(textwrap.dedent("""\
            #!/usr/bin/env python3
            import json, os, sys
            mode = os.environ.get('FAKE_GH_MODE', 'missing')
            if sys.argv[1:3] == ['issue', 'list']:
                if mode == 'duplicate': print(json.dumps([{'number': 1, 'url': 'https://github.com/acme/widgets/issues/1', 'title': 'WP-123 first'}, {'number': 2, 'url': 'https://github.com/acme/widgets/issues/2', 'title': 'WP-123 second'}]))
                elif mode == 'existing': print(json.dumps([{'number': 3, 'url': 'https://github.com/acme/widgets/issues/3', 'title': 'WP-123 Test adapter', 'state': 'OPEN'}]))
                else: print('[]')
            elif sys.argv[1:3] == ['issue', 'view']:
                print(json.dumps({'number': 3, 'url': 'https://github.com/acme/widgets/issues/3', 'title': 'WP-123 Test adapter', 'state': 'OPEN'}))
            elif sys.argv[1:3] == ['issue', 'create']:
                print('https://github.com/acme/widgets/issues/3')
            else: raise SystemExit(2)
        """), encoding="utf-8")
        self.gh.chmod(0o755)

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def run_tracker(self, *arguments: str, mode: str = "missing") -> dict:
        environment = os.environ | {"IWE_GITHUB_CLI": str(self.gh), "FAKE_GH_MODE": mode}
        completed = subprocess.run(["python3", str(TRACKER), *arguments], text=True, capture_output=True, check=True, env=environment)
        return json.loads(completed.stdout)

    def test_check_requires_no_network_when_link_missing(self) -> None:
        answer = self.run_tracker("check", "--context", str(self.context), "--config", str(self.config))
        self.assertEqual("MISSING", answer["status"])

    def test_none_adapter_with_inline_comment_stays_disabled(self) -> None:
        self.config.write_text("external_tracker:\n  adapter: none # default\n", encoding="utf-8")
        answer = self.run_tracker("check", "--context", str(self.context), "--config", str(self.config))
        self.assertEqual("DISABLED", answer["status"])

    def test_create_reuses_single_existing_issue(self) -> None:
        answer = self.run_tracker("create", "--context", str(self.context), "--repository", "acme/widgets", "--config", str(self.config), mode="existing")
        self.assertEqual("OK", answer["status"])
        self.assertTrue(answer["reused"])
        self.assertIn("external_tracker_id: \"3\"", self.context.read_text(encoding="utf-8"))

    def test_create_stops_on_duplicate(self) -> None:
        answer = self.run_tracker("create", "--context", str(self.context), "--repository", "acme/widgets", "--config", str(self.config), mode="duplicate")
        self.assertEqual("DUPLICATE", answer["status"])
        self.assertNotIn("external_tracker_id", self.context.read_text(encoding="utf-8"))

    def test_wrong_repository_is_rejected_before_write(self) -> None:
        answer = self.run_tracker("create", "--context", str(self.context), "--repository", "other/repo", "--config", str(self.config))
        self.assertEqual("WRONG_REPO", answer["status"])


if __name__ == "__main__":
    unittest.main()
