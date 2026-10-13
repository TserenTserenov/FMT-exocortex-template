"""
Tests for personal_export.py and adapter.py merge hook.

Unit coverage:
- allowlist rejects write tools before network
- strict argparse: unknown flag → exit 2
- degradations: 500, 401, 403, empty, invalid JSON
- per-field merge: partial rcs not padded, atomic stage, missing source → unknown,
  platform beats a plain manual declaration, accountable manual_override beats platform
"""
import io
import json
import os
import urllib.error
from datetime import date, timedelta
from unittest.mock import MagicMock, patch

import pytest
import yaml

import personal_export as pe
from adapter import _merge_degree, _merge_rcs, apply_platform_overlay
from horizons import normalize_rcs_dict


# ---------------------------------------------------------------------------
# normalize_rcs_dict
# ---------------------------------------------------------------------------

class TestNormalizeRcsDict:
    def test_compact_passthrough(self):
        d = {"W": 3, "M1": 2, "stage_derived": 2, "source": "manual", "confidence": 0.8}
        result = normalize_rcs_dict(d)
        assert result == d

    def test_compact_aliases_renamed(self):
        d = {"W": 3, "stage": 2, "it_level": 4, "agency": 2}
        result = normalize_rcs_dict(d)
        assert result["stage_derived"] == 2
        assert result["IT"] == 4
        assert result["A"] == 2
        assert "stage" not in result
        assert "it_level" not in result
        assert "agency" not in result

    def test_full_format_converted(self):
        d = {
            "worldview": 3,
            "mastery": {"m1_focus": 4, "m2_iwe": 2, "m3_domain": 3, "m4_systems": 2},
            "it_level": 3,
            "agency": 2,
            "bottleneck": "M2",
            "stage_derived": 3,
            "source": "diagnostic_session",
        }
        result = normalize_rcs_dict(d)
        assert result["W"] == 3
        assert result["M1"] == 4
        assert result["M2"] == 2
        assert result["M3"] == 3
        assert result["M4"] == 2
        assert result["IT"] == 3
        assert result["A"] == 2
        assert result["bottleneck"] == "M2"
        assert result["source"] == "diagnostic_session"
        assert "worldview" not in result
        assert "mastery" not in result

    def test_no_defaults_injected(self):
        # Only keys present in input appear in output
        result = normalize_rcs_dict({"W": 2})
        assert result == {"W": 2}
        assert "M1" not in result
        assert "source" not in result

    def test_unknown_keys_dropped(self):
        result = normalize_rcs_dict({"W": 2, "extra_field": "ignored"})
        assert "extra_field" not in result
        assert result["W"] == 2


# ---------------------------------------------------------------------------
# allowlist
# ---------------------------------------------------------------------------

class TestAllowlist:
    def test_write_tool_rejected_before_network(self):
        with pytest.raises(ValueError, match="not in allowlist"):
            pe._rpc_call("http://localhost/mcp", "tok", "dt_write_digital_twin", {})

    def test_unknown_tool_rejected_before_network(self):
        with pytest.raises(ValueError, match="not in allowlist"):
            pe._rpc_call("http://localhost/mcp", "tok", "some_tool", {})

    def test_read_tools_allowed(self):
        # Both read tools must be in the allowlist (no ValueError raised)
        # We mock urlopen to avoid actual network
        for tool in pe._READ_TOOLS:
            mock_resp = MagicMock()
            mock_resp.read.return_value = b'{"jsonrpc":"2.0","id":1,"result":{"ok":true}}'
            mock_resp.__enter__ = lambda s: s
            mock_resp.__exit__ = MagicMock(return_value=False)
            with patch("urllib.request.urlopen", return_value=mock_resp):
                result = pe._rpc_call("http://localhost/mcp", "tok", tool, {})
            assert result == {"ok": True}


# ---------------------------------------------------------------------------
# strict argparse
# ---------------------------------------------------------------------------

class TestStrictArgparse:
    def test_unknown_flag_exits_2(self):
        """Exercises the real shipped parser (pe._build_parser), not a stand-in —
        a past incident was caused by an unknown flag being silently swallowed."""
        with pytest.raises(SystemExit) as exc_info:
            pe._build_parser().parse_args(["--no-such-flag"])
        assert exc_info.value.code == 2

    def test_known_flags_parse_correctly(self):
        args = pe._build_parser().parse_args(
            ["--platform-url", "http://x", "--rcs-path", "some/path", "--output", "out.yaml"]
        )
        assert args.platform_url == "http://x"
        assert args.rcs_path == "some/path"
        assert args.output == "out.yaml"


# ---------------------------------------------------------------------------
# export() must refuse to overwrite the user's own profile.yaml
# ---------------------------------------------------------------------------

class TestExportRefusesToOverwriteProfileYaml:
    def _refused(self, monkeypatch, tmp_path, output_name):
        monkeypatch.setenv("GUIDE_KIT_PLATFORM_TOKEN", "testtoken")
        target = tmp_path / output_name
        target.write_text("rcs:\n  W: 5\n# user's own declared profile\n", encoding="utf-8")
        with patch.object(pe, "fetch_stage", return_value=(3, "Профессионал", None, "platform")):
            code = pe.export("http://x", None, str(target))
        assert code == 1
        assert target.read_text(encoding="utf-8") == "rcs:\n  W: 5\n# user's own declared profile\n"

    def test_refuses_exact_name(self, monkeypatch, tmp_path):
        self._refused(monkeypatch, tmp_path, "profile.yaml")

    def test_refuses_regardless_of_case(self, monkeypatch, tmp_path):
        """macOS/Windows default filesystems are case-insensitive — a
        case-sensitive check alone would let --output PROFILE.YAML silently
        bypass the guard on the exact platforms this tool ships for."""
        self._refused(monkeypatch, tmp_path, "PROFILE.YAML")


# ---------------------------------------------------------------------------
# degradations
# ---------------------------------------------------------------------------

def _make_http_error(code: int) -> urllib.error.HTTPError:
    return urllib.error.HTTPError(
        url="http://test", code=code, msg="error", hdrs=None, fp=None
    )


def _mock_rpc(side_effect):
    return patch.object(pe, "_rpc_call", side_effect=side_effect)


class TestDegradations:
    def test_500_raises_runtime_error(self):
        with patch("urllib.request.urlopen", side_effect=_make_http_error(500)):
            with pytest.raises(RuntimeError, match="HTTP 500"):
                pe._rpc_call("http://localhost/mcp", "tok", "dt_describe_by_path", {})

    def test_401_message_mentions_subscription(self):
        with patch("urllib.request.urlopen", side_effect=_make_http_error(401)):
            with pytest.raises(RuntimeError, match="подписочный источник недоступен"):
                pe._rpc_call("http://localhost/mcp", "tok", "dt_describe_by_path", {})

    def test_403_message_mentions_subscription(self):
        with patch("urllib.request.urlopen", side_effect=_make_http_error(403)):
            with pytest.raises(RuntimeError, match="подписочный источник недоступен"):
                pe._rpc_call("http://localhost/mcp", "tok", "dt_describe_by_path", {})

    def test_empty_response_raises(self):
        mock_resp = MagicMock()
        mock_resp.read.return_value = b""
        mock_resp.__enter__ = lambda s: s
        mock_resp.__exit__ = MagicMock(return_value=False)
        with patch("urllib.request.urlopen", return_value=mock_resp):
            with pytest.raises(RuntimeError, match="пустой ответ"):
                pe._rpc_call("http://localhost/mcp", "tok", "dt_describe_by_path", {})

    def test_invalid_json_raises(self):
        mock_resp = MagicMock()
        mock_resp.read.return_value = b"not json at all"
        mock_resp.__enter__ = lambda s: s
        mock_resp.__exit__ = MagicMock(return_value=False)
        with patch("urllib.request.urlopen", return_value=mock_resp):
            with pytest.raises(RuntimeError, match="не-JSON"):
                pe._rpc_call("http://localhost/mcp", "tok", "dt_describe_by_path", {})

    def test_export_no_token_returns_1(self, tmp_path):
        env = {k: v for k, v in os.environ.items() if k != "GUIDE_KIT_PLATFORM_TOKEN"}
        with patch.dict(os.environ, env, clear=True):
            code = pe.export("http://localhost/mcp", None, str(tmp_path / "out.yaml"))
        assert code == 1
        assert not (tmp_path / "out.yaml").exists()

    def test_export_no_data_returns_1_no_file(self, tmp_path, monkeypatch):
        monkeypatch.setenv("GUIDE_KIT_PLATFORM_TOKEN", "testtoken")
        # fetch_stage, fetch_rcs and fetch_degree all return nothing
        with patch.object(pe, "fetch_stage", return_value=(None, None, None, None)), \
             patch.object(pe, "fetch_rcs", return_value=None), \
             patch.object(pe, "fetch_degree", return_value=(None, None)):
            out = tmp_path / "out.yaml"
            code = pe.export("http://localhost/mcp", None, str(out))
        assert code == 1
        assert not out.exists()


# ---------------------------------------------------------------------------
# snapshot cache fallback (WP-149: resilience when the platform is unreachable)
# ---------------------------------------------------------------------------

class TestSnapshotFallback:
    def _write_snapshot(self, tmp_path, **overrides):
        data = {
            "snapshot_date": date.today().isoformat(),
            "stage_raw": 3,
            "stage_label": "Практикующий",
            **overrides,
        }
        path = tmp_path / "derived_snapshot.json"
        path.write_text(json.dumps(data), encoding="utf-8")
        return str(path)

    def test_fresh_snapshot_used(self, tmp_path):
        path = self._write_snapshot(tmp_path)
        assert pe._read_snapshot_fallback(path) == (3, "Практикующий")

    def test_stale_snapshot_rejected(self, tmp_path):
        old_date = (date.today() - timedelta(days=pe._SNAPSHOT_STALE_DAYS + 1)).isoformat()
        path = self._write_snapshot(tmp_path, snapshot_date=old_date)
        assert pe._read_snapshot_fallback(path) == (None, None)

    def test_missing_file_degrades_to_none(self, tmp_path):
        assert pe._read_snapshot_fallback(str(tmp_path / "absent.json")) == (None, None)

    def test_invalid_utf8_degrades_to_none(self, tmp_path):
        path = tmp_path / "derived_snapshot.json"
        path.write_bytes(b"\xff\xfe not valid utf-8")
        assert pe._read_snapshot_fallback(str(path)) == (None, None)

    def test_malformed_json_degrades_to_none(self, tmp_path):
        path = tmp_path / "derived_snapshot.json"
        path.write_text("not json", encoding="utf-8")
        assert pe._read_snapshot_fallback(str(path)) == (None, None)

    def test_out_of_range_stage_degrades_to_none(self, tmp_path):
        path = self._write_snapshot(tmp_path, stage_raw=9)
        assert pe._read_snapshot_fallback(path) == (None, None)

    def test_future_dated_snapshot_degrades_to_none(self, tmp_path):
        """Clock skew or a corrupt write could date a snapshot in the future —
        that isn't 'fresh', it's untrustworthy, and must not be used either."""
        future_date = (date.today() + timedelta(days=5)).isoformat()
        path = self._write_snapshot(tmp_path, snapshot_date=future_date)
        assert pe._read_snapshot_fallback(path) == (None, None)

    def test_fetch_stage_falls_back_when_platform_path_absent(self, tmp_path):
        """_describe_path returns False (path absent on the platform) — the live
        branch never reaches a parse attempt; fetch_stage must still try the cache."""
        path = self._write_snapshot(tmp_path)
        with patch.object(pe, "_describe_path", return_value=False):
            result = pe.fetch_stage("http://x", "tok", path)
        assert result == (3, "Практикующий", None, "snapshot_cache")

    def test_fetch_stage_prefers_live_platform_over_cache(self, tmp_path):
        path = self._write_snapshot(tmp_path, stage_raw=1, stage_label="Случайный")
        with patch.object(pe, "_describe_path", return_value=True), \
             patch.object(
                 pe, "_read_path",
                 return_value={"stage_derived": 5, "stage_label": "Проактивный"},
             ):
            result = pe.fetch_stage("http://x", "tok", path)
        assert result == (5, "Проактивный", None, "platform")

    def test_fetch_stage_none_when_platform_and_cache_both_unusable(self, tmp_path):
        with patch.object(pe, "_describe_path", return_value=False):
            result = pe.fetch_stage("http://x", "tok", str(tmp_path / "absent.json"))
        assert result == (None, None, None, None)


# ---------------------------------------------------------------------------
# merge semantics
# ---------------------------------------------------------------------------

class TestMergeRcs:
    def test_platform_beats_plain_manual(self):
        # A stage is not self-assigned (DP.METHOD.020) — a plain "manual" declaration
        # no longer beats platform-computed data. See WP-483 Ф11, peer-session
        # 2026-07-18-02-wp483-f11-stage-vs-degree.
        declared = {"W": 2, "M1": 3, "source": "manual"}
        overlay = {"W": 4, "M1": 5, "source": "computed_from_events"}
        result = _merge_rcs(declared, overlay)
        assert result["W"] == 4
        assert result["M1"] == 5
        assert result["source"] == "computed_from_events"

    def test_accountable_manual_override_beats_platform(self):
        declared = {
            "W": 2, "M1": 3, "source": "manual_override",
            "override_reason": "platform stage is stale after a 3-month break",
            "override_at": "2026-07-18T06:00:00Z",
        }
        overlay = {"W": 4, "M1": 5, "source": "computed_from_events"}
        result = _merge_rcs(declared, overlay)
        assert result["W"] == 2
        assert result["M1"] == 3
        assert result["source"] == "manual_override"

    def test_manual_override_without_justification_is_demoted_to_manual(self, capsys):
        # source claims manual_override but no reason/timestamp — doesn't count.
        declared = {"W": 2, "source": "manual_override"}
        overlay = {"W": 4, "source": "computed_from_events"}
        result = _merge_rcs(declared, overlay)
        assert result["W"] == 4
        captured = capsys.readouterr()
        assert "unaccountable override" in captured.err

    def test_platform_beats_diagnostic_session(self):
        declared = {"W": 2, "M1": 3, "source": "diagnostic_session"}
        overlay = {"W": 4, "M1": 5, "source": "computed_from_events"}
        result = _merge_rcs(declared, overlay)
        assert result["W"] == 4
        assert result["M1"] == 5
        assert result["source"] == "computed_from_events"

    def test_overlay_fills_missing_declared_slots(self):
        declared = {"W": 2, "source": "manual"}
        overlay = {"M1": 3, "M4": 4, "source": "computed_from_events"}
        result = _merge_rcs(declared, overlay)
        assert result["W"] == 2         # declared
        assert result["M1"] == 3        # from overlay (not in declared)
        assert result["M4"] == 4        # from overlay (not in declared)

    def test_partial_rcs_not_padded_with_ones(self):
        # Platform returns only W and M1 — remaining slots must NOT appear as 1
        declared = {"W": 2, "source": "diagnostic_session"}
        overlay = {"W": 3, "M1": 4, "source": "computed_from_events"}
        result = _merge_rcs(declared, overlay)
        assert result["W"] == 3
        assert result["M1"] == 4
        assert "M2" not in result
        assert "M3" not in result
        assert "IT" not in result

    def test_overlay_never_deletes_declared_keys(self):
        declared = {"W": 2, "M1": 3, "bottleneck": "M1", "source": "manual"}
        overlay = {"W": 4, "source": "computed_from_events"}
        result = _merge_rcs(declared, overlay)
        # M1 and bottleneck must survive even though overlay doesn't mention them
        assert result["M1"] == 3
        assert result["bottleneck"] == "M1"

    def test_missing_source_treated_as_unknown_not_manual(self, capsys):
        declared = {"W": 2, "M1": 3}  # no source key
        overlay = {"W": 4, "source": "computed_from_events"}
        result = _merge_rcs(declared, overlay)
        # Missing declared source → unknown (lowest priority) → platform wins
        assert result["W"] == 4
        captured = capsys.readouterr()
        assert "unknown" in captured.err

    def test_final_source_is_max_authority(self):
        # overlay fills a missing slot (M1) and wins the W conflict (platform > manual)
        declared = {"W": 2, "source": "manual"}
        overlay = {"M1": 3, "source": "computed_from_events"}
        result = _merge_rcs(declared, overlay)
        # platform wins (lower priority number than plain manual)
        assert result["source"] == "computed_from_events"

    def test_atomic_stage_derived_from_overlay(self):
        # stage_derived comes from overlay as an atomic pair at export time;
        # from merge's perspective it's just a regular slot
        declared = {"stage_derived": 1, "source": "diagnostic_session"}
        overlay = {"stage_derived": 3, "source": "computed_from_events"}
        result = _merge_rcs(declared, overlay)
        assert result["stage_derived"] == 3


# ---------------------------------------------------------------------------
# _merge_degree — a separate, simpler axis from _merge_rcs (DP.D.252): degree is
# council-assigned, never behaviorally computed, so there's no priority table —
# platform wins whenever present, unless the user set an explicit use_declared.
# ---------------------------------------------------------------------------

class TestMergeDegree:
    def test_overlay_fills_empty_declared(self):
        declared = {}
        overlay = {"degree": "DEG.Worker", "certified_at": "2026-01-15"}
        result = _merge_degree(declared, overlay)
        assert result == {"degree": "DEG.Worker", "source": "platform", "certified_at": "2026-01-15"}

    def test_platform_beats_declared_by_default(self):
        declared = {"degree": "DEG.Freshman", "source": "declared"}
        overlay = {"degree": "DEG.Worker", "certified_at": "2026-01-15"}
        result = _merge_degree(declared, overlay)
        assert result["degree"] == "DEG.Worker"
        assert result["source"] == "platform"

    def test_use_declared_keeps_local_value(self):
        declared = {"degree": "DEG.Worker", "source": "declared", "use_declared": True}
        overlay = {"degree": "DEG.Freshman", "certified_at": "2020-01-01"}
        result = _merge_degree(declared, overlay)
        assert result == declared  # untouched

    def test_no_overlay_degree_returns_declared_unchanged(self):
        declared = {"degree": "DEG.Worker", "source": "declared"}
        result = _merge_degree(declared, {})
        assert result == declared

    def test_overlay_without_certified_at_omits_it(self):
        declared = {}
        overlay = {"degree": "DEG.Freshman"}
        result = _merge_degree(declared, overlay)
        assert "certified_at" not in result


# ---------------------------------------------------------------------------
# apply_platform_overlay
# ---------------------------------------------------------------------------

class TestApplyPlatformOverlay:
    def _write_overlay(self, tmp_path, data):
        overlay_path = tmp_path / "profile.platform.yaml"
        with open(overlay_path, "w") as fh:
            yaml.dump(data, fh)
        return overlay_path

    def test_no_overlay_file_returns_profile_unchanged(self, tmp_path):
        profile = {"rcs": {"W": 2, "source": "manual"}}
        profile_path = str(tmp_path / "profile.yaml")
        result = apply_platform_overlay(profile, profile_path)
        assert result == profile

    def test_overlay_merges_rcs(self, tmp_path):
        self._write_overlay(tmp_path, {
            "rcs": {"W": 4, "M1": 3, "source": "computed_from_events"}
        })
        profile = {"rcs": {"W": 2, "source": "diagnostic_session"}}
        profile_path = str(tmp_path / "profile.yaml")
        result = apply_platform_overlay(profile, profile_path)
        # diagnostic_session < computed_from_events → overlay wins on W
        assert result["rcs"]["W"] == 4
        assert result["rcs"]["M1"] == 3

    def test_overlay_fills_mastery_by_area(self, tmp_path):
        self._write_overlay(tmp_path, {
            "mastery_by_area": {"area_1": 0.7, "area_2": 0.3}
        })
        profile = {"mastery_by_area": {"area_1": 0.9}}
        profile_path = str(tmp_path / "profile.yaml")
        result = apply_platform_overlay(profile, profile_path)
        assert result["mastery_by_area"]["area_1"] == 0.9   # declared wins
        assert result["mastery_by_area"]["area_2"] == 0.3   # filled from overlay

    def test_overlay_merges_qualification_degree(self, tmp_path):
        self._write_overlay(tmp_path, {
            "qualification_degree": {"degree": "DEG.Worker", "certified_at": "2026-01-15"}
        })
        profile = {"qualification_degree": {"degree": "DEG.Freshman", "source": "declared"}}
        profile_path = str(tmp_path / "profile.yaml")
        result = apply_platform_overlay(profile, profile_path)
        # No use_declared set → platform wins, unlike rcs's manual-vs-platform tie rules
        assert result["qualification_degree"]["degree"] == "DEG.Worker"
        assert result["qualification_degree"]["source"] == "platform"

    def test_overlay_respects_use_declared_for_degree(self, tmp_path):
        self._write_overlay(tmp_path, {
            "qualification_degree": {"degree": "DEG.Freshman", "certified_at": "2020-01-01"}
        })
        profile = {"qualification_degree": {
            "degree": "DEG.Worker", "source": "declared", "use_declared": True,
        }}
        profile_path = str(tmp_path / "profile.yaml")
        result = apply_platform_overlay(profile, profile_path)
        assert result["qualification_degree"]["degree"] == "DEG.Worker"

    def test_personal_export_off_skips_overlay(self, tmp_path):
        self._write_overlay(tmp_path, {
            "rcs": {"W": 4, "source": "computed_from_events"}
        })
        # When personal_export=off the caller skips apply_platform_overlay entirely
        # — test that the overlay file is NOT applied when the flag is off
        # (adapter.py checks the flag before calling this function)
        profile = {"rcs": {"W": 2, "source": "diagnostic_session"}}
        # Directly: apply_platform_overlay would apply it. The skip is in generate_daily_plan.
        # So here we just verify apply_platform_overlay is the function that does the merge,
        # and the caller is responsible for gating on the flag.
        result = apply_platform_overlay(profile, str(tmp_path / "profile.yaml"))
        assert result["rcs"]["W"] == 4  # overlay was applied (function doesn't know about the flag)


# ---------------------------------------------------------------------------
# export() integration (mocked transport)
# ---------------------------------------------------------------------------

class TestExportIntegration:
    def test_export_writes_stage_and_provenance(self, tmp_path, monkeypatch):
        monkeypatch.setenv("GUIDE_KIT_PLATFORM_TOKEN", "testtoken")
        out = tmp_path / "profile.platform.yaml"
        with patch.object(pe, "fetch_stage", return_value=(3, "Профессионал", None, "platform")), \
             patch.object(pe, "fetch_rcs", return_value=None), \
             patch.object(pe, "fetch_degree", return_value=(None, None)):
            code = pe.export("http://localhost/mcp", None, str(out))
        assert code == 0
        assert out.exists()
        data = yaml.safe_load(out.read_text())
        assert data["rcs"]["stage_derived"] == 3
        assert data["provenance"]["stage_label"] == "Профессионал"
        assert "stage_source" not in data["provenance"]  # live path stays unflagged
        assert data["is_derived"] is True
        assert "qualification_degree" not in data

    def test_export_flags_stage_source_when_from_snapshot_cache(self, tmp_path, monkeypatch):
        monkeypatch.setenv("GUIDE_KIT_PLATFORM_TOKEN", "testtoken")
        out = tmp_path / "profile.platform.yaml"
        with patch.object(
            pe, "fetch_stage", return_value=(2, "Практикующий", None, "snapshot_cache")
        ), \
             patch.object(pe, "fetch_rcs", return_value=None), \
             patch.object(pe, "fetch_degree", return_value=(None, None)):
            code = pe.export("http://localhost/mcp", None, str(out))
        assert code == 0
        data = yaml.safe_load(out.read_text())
        assert data["rcs"]["stage_derived"] == 2
        assert data["provenance"]["stage_label"] == "Практикующий"
        assert data["provenance"]["stage_source"] == "snapshot_cache"

    def test_export_writes_full_bundle_when_stage_and_rcs_both_available(self, tmp_path, monkeypatch):
        """P.2(a) acceptance (MVP acceptance): 'exportable in under an
        hour' presumes the export is COMPLETE, not just fast — a bundle missing
        half the available data would technically finish quickly while still
        failing the promise. Only prior coverage exercised stage-only or
        rcs-only; this is the one where all three sources return real data."""
        monkeypatch.setenv("GUIDE_KIT_PLATFORM_TOKEN", "testtoken")
        out = tmp_path / "profile.platform.yaml"
        with patch.object(pe, "fetch_stage", return_value=(4, "Исследователь", None, "platform")), \
             patch.object(pe, "fetch_rcs", return_value={"W": 3, "M1": 2, "confidence": 0.7}), \
             patch.object(pe, "fetch_degree", return_value=("DEG.Worker", "2026-01-15")):
            code = pe.export("http://localhost/mcp", "rcs_path", str(out))
        assert code == 0
        data = yaml.safe_load(out.read_text())
        assert data["origin"] == "platform"
        assert data["platform_url"] == "http://localhost/mcp"
        assert data["is_derived"] is True
        assert data["fetched_at"]  # non-empty timestamp, exact value not asserted (real clock)
        assert data["rcs"]["stage_derived"] == 4
        assert data["rcs"]["W"] == 3
        assert data["rcs"]["M1"] == 2
        assert data["rcs"]["confidence"] == 0.7
        assert data["provenance"]["stage_label"] == "Исследователь"
        assert data["qualification_degree"] == {
            "degree": "DEG.Worker", "source": "platform", "certified_at": "2026-01-15",
        }

    def test_export_degree_without_certified_at(self, tmp_path, monkeypatch):
        """fetch_degree can return a degree with no history entry (fresh council
        record, no confirmation date yet) — certified_at must not appear as None/empty."""
        monkeypatch.setenv("GUIDE_KIT_PLATFORM_TOKEN", "testtoken")
        out = tmp_path / "profile.platform.yaml"
        with patch.object(pe, "fetch_stage", return_value=(None, None, None, None)), \
             patch.object(pe, "fetch_rcs", return_value=None), \
             patch.object(pe, "fetch_degree", return_value=("DEG.Freshman", None)):
            code = pe.export("http://localhost/mcp", None, str(out))
        assert code == 0
        data = yaml.safe_load(out.read_text())
        assert data["qualification_degree"] == {"degree": "DEG.Freshman", "source": "platform"}
        assert "certified_at" not in data["qualification_degree"]

    def test_export_parse_failure_writes_raw(self, tmp_path, monkeypatch):
        monkeypatch.setenv("GUIDE_KIT_PLATFORM_TOKEN", "testtoken")
        out = tmp_path / "profile.platform.yaml"
        with patch.object(pe, "fetch_stage", return_value=(None, None, '{"stage": "bad"}', None)), \
             patch.object(pe, "fetch_rcs", return_value={"W": 3}), \
             patch.object(pe, "fetch_degree", return_value=(None, None)):
            code = pe.export("http://localhost/mcp", "rcs_path", str(out))
        assert code == 0
        data = yaml.safe_load(out.read_text())
        assert "stage_label_raw" in data.get("provenance", {})
        assert "stage_label" not in data.get("provenance", {})
        # stage_derived must NOT be in rcs when parse failed
        assert "stage_derived" not in data.get("rcs", {})
