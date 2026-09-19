#!/usr/bin/env python3
"""Platform-agnostic smoke tests for the ResidencyState backend."""

import sys
import tempfile
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent.parent))

from lib.state import ResidencyState, ResidencyStateError


def test_residency_state_persists_across_instances():
    """All six public methods work and survive re-instantiation."""
    with tempfile.TemporaryDirectory() as tmp:
        state_path = Path(tmp) / "data-residency.yaml"
        state = ResidencyState(str(state_path))

        state.grant_consent("function-a", "type_inbound_name")
        state.deny_consent("function-a", "type_outbound_name", reason="outbound blocked")
        state.revoke_consent("function-b", "type_inbound_other", reason="pilot revoked")

        fresh = ResidencyState(str(state_path))
        assert fresh.get_consent("function-a", "type_inbound_name")["status"] == "granted"
        assert fresh.get_consent("function-a", "type_inbound_name")["granted_at"] is not None

        denied = fresh.get_consent("function-a", "type_outbound_name")
        assert denied["status"] == "denied"
        assert denied["denied_reason"] == "outbound blocked"

        revoked = fresh.get_consent("function-b", "type_inbound_other")
        assert revoked["status"] == "revoked"
        assert revoked["revoked_reason"] == "pilot revoked"

        all_consents = fresh.list_all_consents()
        assert "function-a" in all_consents
        assert "function-b" in all_consents
        assert "type_inbound_name" in all_consents["function-a"]

        fresh.reset_function_consents("function-a")
        assert fresh.get_consent("function-a", "type_inbound_name")["status"] == "not_asked"

        another = ResidencyState(str(state_path))
        assert another.get_consent("function-a", "type_inbound_name")["status"] == "not_asked"
        assert another.get_consent("function-b", "type_inbound_other")["status"] == "revoked"


def test_corrupted_yaml_with_init_marker_raises():
    """A missing/corrupt state file next to an init marker is an integrity failure."""
    with tempfile.TemporaryDirectory() as tmp:
        state_path = Path(tmp) / "data-residency.yaml"
        marker_path = Path(tmp) / ".data-residency.initialized"

        state = ResidencyState(str(state_path))
        state.grant_consent("fn", "need")
        assert marker_path.exists()

        state_path.write_text("not valid yaml: [", encoding="utf-8")
        fresh = ResidencyState(str(state_path))
        try:
            fresh.list_all_consents()
        except ResidencyStateError:
            pass
        else:
            raise AssertionError("corrupted YAML with init marker must raise ResidencyStateError")


def test_legacy_state_blocks_default_location(monkeypatch):
    """On Windows, a leftover legacy state file must not be silently ignored."""
    import os
    if os.name != "nt":
        # POSIX backend migrates instead of refusing; Windows behavior is
        # validated by inspection and on a native Windows runner.
        pytest.skip("Windows-only legacy-state quarantine test")
    with tempfile.TemporaryDirectory() as tmp:
        state_home = Path(tmp) / ".iwe" / "state"
        state_home.mkdir(parents=True)
        workspace = Path(tmp) / "IWE"
        workspace.mkdir(parents=True)
        (workspace / "current").mkdir(parents=True)
        legacy = workspace / "current" / "data-residency.yaml"
        legacy.write_text("functions: {}", encoding="utf-8")
        monkeypatch.setenv("IWE_STATE_HOME", str(state_home))
        monkeypatch.setenv("IWE_WORKSPACE", str(workspace))
        try:
            ResidencyState()
        except ResidencyStateError as exc:
            assert "legacy" in str(exc).lower()
        else:
            raise AssertionError("legacy state on Windows must raise ResidencyStateError")


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-v"]))
