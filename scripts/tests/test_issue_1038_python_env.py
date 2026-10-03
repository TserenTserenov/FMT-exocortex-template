"""Operational Python scripts must resolve governance paths from the environment (#1038)."""

import runpy
from pathlib import Path

import pytest
import yaml


SCRIPTS = Path(__file__).parent.parent


@pytest.mark.parametrize(
    ("setting", "expected"),
    [("Pilot-Strategy", "Pilot-Strategy"), ("", "DS-strategy")],
)
def test_helper_catalog_uses_governance_repo(tmp_path, monkeypatch, setting, expected):
    monkeypatch.setattr(Path, "home", classmethod(lambda cls: tmp_path))
    monkeypatch.setenv("IWE_GOVERNANCE_REPO", setting)
    workspace = tmp_path / "IWE"
    for name in ("scripts", "FMT-exocortex-template/scripts", f"{expected}/scripts"):
        scripts = workspace / name
        scripts.mkdir(parents=True)
        (scripts / "example.sh").write_text(
            "# routing: helper skill=example\n", encoding="utf-8"
        )

    runpy.run_path(str(SCRIPTS / "generate-helper-catalog.py"))

    catalog_path = workspace / expected / "scripts/helper-scripts-catalog.yaml"
    catalog = yaml.safe_load(catalog_path.read_text(encoding="utf-8"))
    assert catalog["total"] == 3
    assert catalog["generator"] == f"{expected}/scripts/generate-helper-catalog.py"


@pytest.mark.parametrize(
    ("setting", "expected"),
    [("Pilot-Strategy", "Pilot-Strategy"), ("", "DS-strategy")],
)
def test_ad_hoc_audit_reads_governance_sessions(tmp_path, monkeypatch, setting, expected):
    monkeypatch.setattr(Path, "home", classmethod(lambda cls: tmp_path))
    monkeypatch.setenv("IWE_GOVERNANCE_REPO", setting)
    session = tmp_path / "IWE" / expected / "sessions/2026-10/session-1"
    session.mkdir(parents=True)
    meta = session / "meta.yaml"
    meta.write_text("ad_hoc_roles:\n  reviewer: true\n", encoding="utf-8")

    namespace = runpy.run_path(str(SCRIPTS / "audit-ad-hoc-roles.py"))

    assert namespace["find_meta_files"]() == [meta]
    assert namespace["aggregate"]([meta]) == {"reviewer": ["session-1"]}


@pytest.mark.parametrize(
    ("owner", "governance", "expected"),
    [
        ("pilot-org", "Pilot-Strategy", "pilot-org/Pilot-Strategy"),
        ("", "", "owner/DS-strategy"),
    ],
)
def test_session_dispatcher_builds_repo_from_environment(
    monkeypatch, owner, governance, expected
):
    monkeypatch.delenv("GITHUB_SESSION_REPO", raising=False)
    monkeypatch.setenv("GITHUB_OWNER", owner)
    monkeypatch.setenv("IWE_GOVERNANCE_REPO", governance)

    namespace = runpy.run_path(str(SCRIPTS / "session-dispatcher-tsekh.py"))

    assert namespace["GITHUB_REPO"] == expected


def test_session_dispatcher_prefers_explicit_repo(monkeypatch):
    monkeypatch.setenv("GITHUB_SESSION_REPO", "explicit-org/explicit-repo")
    monkeypatch.setenv("GITHUB_OWNER", "pilot-org")
    monkeypatch.setenv("IWE_GOVERNANCE_REPO", "Pilot-Strategy")

    namespace = runpy.run_path(str(SCRIPTS / "session-dispatcher-tsekh.py"))

    assert namespace["GITHUB_REPO"] == "explicit-org/explicit-repo"
