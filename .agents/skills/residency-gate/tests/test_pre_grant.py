#!/usr/bin/env python3
"""Unit tests for the pre-grant list: validation and inbound-only auto-grant."""

import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent))

from lib.parser import DataNeed
from lib.state import ResidencyState
from lib.consent import ResidencyGate, PreGrantError, load_pre_grant_entries


def _write(tmp_dir: str, name: str, content: str) -> Path:
    path = Path(tmp_dir) / name
    path.write_text(content)
    return path


def test_valid_pre_grant_loads():
    with tempfile.TemporaryDirectory() as tmp:
        pg = _write(tmp, "pre-grant.yaml", """
pre_granted:
  - function_id: render-pilot-guides
    approved_by: pilot
    approved_at: "2026-07-16"
""")
        entries = load_pre_grant_entries(pg)
        assert "render-pilot-guides" in entries
        assert entries["render-pilot-guides"]["approved_at"] == "2026-07-16"


def test_entry_without_pilot_approval_raises():
    with tempfile.TemporaryDirectory() as tmp:
        pg = _write(tmp, "pre-grant.yaml", """
pre_granted:
  - function_id: sneaky-consumer
    approved_at: "2026-07-16"
""")
        try:
            load_pre_grant_entries(pg)
        except PreGrantError as e:
            assert "sneaky-consumer" in str(e)
        else:
            raise AssertionError("entry without 'approved_by: pilot' must raise PreGrantError")


def test_entry_without_date_raises():
    with tempfile.TemporaryDirectory() as tmp:
        pg = _write(tmp, "pre-grant.yaml", """
pre_granted:
  - function_id: fn
    approved_by: pilot
""")
        try:
            load_pre_grant_entries(pg)
        except PreGrantError as e:
            assert "approved_at" in str(e)
        else:
            raise AssertionError("entry without approved_at must raise PreGrantError")


def test_missing_file_means_nothing_pre_granted():
    assert load_pre_grant_entries(Path("/nonexistent/pre-grant.yaml")) == {}


def test_pre_grant_auto_grants_inbound_only():
    """Outbound needs of a pre-granted function stay blocked (WP-475 AC 6)."""
    with tempfile.TemporaryDirectory() as tmp:
        state = ResidencyState(str(Path(tmp) / "data-residency.yaml"))
        pg = _write(tmp, "pre-grant.yaml", """
pre_granted:
  - function_id: fn
    approved_by: pilot
    approved_at: "2026-07-16"
""")
        gate = ResidencyGate(state_manager=state, pre_grant_file=pg)
        inbound = DataNeed(name="a", type="2.1", flow_direction="inbound", schema_version=1)
        outbound = DataNeed(name="b", type="2.2", flow_direction="outbound", schema_version=1)

        allowed, blocking = gate.check_activation("fn", [inbound, outbound])

        assert not allowed
        assert any("b" in reason for reason in blocking)
        assert state.get_consent("fn", inbound.key())["status"] == "granted"
        assert state.get_consent("fn", outbound.key())["status"] == "not_asked"


def test_needs_narrowing():
    """An entry with a 'needs' list auto-grants only the listed keys."""
    with tempfile.TemporaryDirectory() as tmp:
        state = ResidencyState(str(Path(tmp) / "data-residency.yaml"))
        pg = _write(tmp, "pre-grant.yaml", """
pre_granted:
  - function_id: fn
    needs: ["2.1_inbound_a"]
    approved_by: pilot
    approved_at: "2026-07-16"
""")
        gate = ResidencyGate(state_manager=state, pre_grant_file=pg)
        listed = DataNeed(name="a", type="2.1", flow_direction="inbound", schema_version=1)
        unlisted = DataNeed(name="c", type="2.1", flow_direction="inbound", schema_version=1)

        allowed, _ = gate.check_activation("fn", [listed, unlisted])

        assert not allowed
        assert state.get_consent("fn", listed.key())["status"] == "granted"
        assert state.get_consent("fn", unlisted.key())["status"] == "not_asked"


def test_mark_pre_granted_is_noop():
    """Programmatic self-marking must grant nothing (WP-476 F1 condition 6)."""
    import warnings as w
    with tempfile.TemporaryDirectory() as tmp:
        state = ResidencyState(str(Path(tmp) / "data-residency.yaml"))
        gate = ResidencyGate(state_manager=state, pre_grant_file=Path(tmp) / "absent.yaml")
        with w.catch_warnings(record=True) as caught:
            w.simplefilter("always")
            gate.mark_pre_granted("self-marking-consumer")
            assert any(issubclass(c.category, DeprecationWarning) for c in caught)
        need = DataNeed(name="a", type="2.1", flow_direction="inbound", schema_version=1)
        allowed, blocking = gate.check_activation("self-marking-consumer", [need])
        assert not allowed
        assert state.get_consent("self-marking-consumer", need.key())["status"] == "not_asked"


def test_shipped_pre_grant_file_is_valid():
    """The pre-grant.yaml shipped with the template must always validate."""
    shipped = Path(__file__).parent.parent / "pre-grant.yaml"
    entries = load_pre_grant_entries(shipped)
    assert "render-pilot-guides" in entries


if __name__ == "__main__":
    test_valid_pre_grant_loads()
    test_entry_without_pilot_approval_raises()
    test_entry_without_date_raises()
    test_missing_file_means_nothing_pre_granted()
    test_pre_grant_auto_grants_inbound_only()
    test_needs_narrowing()
    test_mark_pre_granted_is_noop()
    test_shipped_pre_grant_file_is_valid()
    print("✓ All tests passed")
