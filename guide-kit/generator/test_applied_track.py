"""
Tests for the applied-mastery track (Ф5b, WP-483/WP-495): domain_traits input,
_choose_domain_step selection, and plan_horizon()'s applied_section output.

Model source: WP-495 Ф3 (2026-07-18) — two-factor hierarchical choice, worldview
lesson stays the primary daily focus, the applied section only supplements it.
"""

import pytest
from adapter import build_horizon_context
from planner import plan_horizon, _choose_domain_step
from horizons import RCSProfile, HorizonContext, OrchestratorTrigger, DomainTrait, DOMAIN_TRAIT_STATUSES


def _make_ctx(domain_traits=None, bottleneck="M2", stage=2):
    rcs = RCSProfile.from_dict({"W": 2, "M1": 3, "M2": 1, "M4": 2, "stage": stage, "bottleneck": bottleneck})
    ctx = HorizonContext.from_render_context(rcs.to_dict(), events_summary="X: 3")
    ctx.trigger = OrchestratorTrigger(kind="routine", detail="test")
    ctx.domain_traits = domain_traits or []
    return ctx


# ─────────────────────────────────────────────────────────────────────────────
# DomainTrait — status validation
# ─────────────────────────────────────────────────────────────────────────────

class TestDomainTraitStatusValidation:
    def test_valid_statuses_construct(self):
        for status in DOMAIN_TRAIT_STATUSES:
            DomainTrait(characteristic="x", domain="y", status=status)

    def test_misspelled_status_rejected_not_silently_active(self):
        """A typo'd status (wrong case, underscore instead of hyphen) must fail
        loud — silently treating it as an active step would be a spot-check
        risk (found by cold-context review)."""
        with pytest.raises(ValueError):
            DomainTrait(characteristic="x", domain="y", status="Measured")
        with pytest.raises(ValueError):
            DomainTrait(characteristic="x", domain="y", status="dormant_no_source")


# ─────────────────────────────────────────────────────────────────────────────
# _choose_domain_step
# ─────────────────────────────────────────────────────────────────────────────

class TestChooseDomainStep:
    def test_empty_traits_returns_none(self):
        assert _choose_domain_step([]) is None

    def test_picks_first_unmeasured_trait_of_active_domain(self):
        traits = [
            DomainTrait(characteristic="water_comfort", domain="swimming", status="measured"),
            DomainTrait(characteristic="water_safety", domain="swimming", status="no_source_yet"),
            DomainTrait(characteristic="stroke_technique_basic", domain="swimming", status="no_source_yet"),
        ]
        result = _choose_domain_step(traits)
        assert result == ("swimming", "water_safety", (
            "прикладной трек «swimming»: следующий нерешённый шаг «water_safety»"
        ))

    def test_skips_dormant_no_source_traits(self):
        traits = [
            DomainTrait(characteristic="musicality", domain="piano", status="dormant-no-source"),
            DomainTrait(characteristic="rhythm_steadiness", domain="piano", status="no_source_yet"),
        ]
        domain, characteristic, _ = _choose_domain_step(traits)
        assert characteristic == "rhythm_steadiness"

    def test_all_measured_returns_none_not_a_guess(self):
        """Every trait of the active domain already measured → no unresolved step
        today. Must return None honestly, not fabricate a next step."""
        traits = [
            DomainTrait(characteristic="water_comfort", domain="swimming", status="measured"),
            DomainTrait(characteristic="stroke_efficiency", domain="swimming", status="measured"),
        ]
        assert _choose_domain_step(traits) is None

    def test_one_active_domain_per_day_ignores_second_domain(self):
        """Program order is not skippable across domains either — only the
        first domain in the list is considered active for the day, even if
        it has no unresolved step and a second domain would."""
        traits = [
            DomainTrait(characteristic="note_reading_basic", domain="piano", status="measured"),
            DomainTrait(characteristic="water_comfort", domain="swimming", status="no_source_yet"),
        ]
        assert _choose_domain_step(traits) is None


# ─────────────────────────────────────────────────────────────────────────────
# plan_horizon() — regression (fundamental-only) + new applied-section path
# ─────────────────────────────────────────────────────────────────────────────

class TestPlanHorizonAppliedTrack:
    def test_no_domain_traits_no_applied_section(self):
        """Regression: fundamental-only path is unaffected — applied_section
        stays absent (None), not an empty placeholder."""
        ctx = _make_ctx(domain_traits=[])
        result = plan_horizon(ctx, seed=0)
        assert result["plan_skeleton"]["applied_section"] is None
        assert result["decision_log"]["applied_track"] == "нет активного домена — секция отсутствует"

    def test_domain_traits_produces_applied_section(self):
        traits = [DomainTrait(characteristic="water_safety", domain="swimming", status="no_source_yet")]
        ctx = _make_ctx(domain_traits=traits)
        result = plan_horizon(ctx, seed=0)
        section = result["plan_skeleton"]["applied_section"]
        assert section is not None
        assert section["domain"] == "swimming"
        assert section["characteristic"] == "water_safety"

    def test_applied_section_never_replaces_worldview_element(self):
        """Объединение №1 invariant: the worldview/mastery lesson stays chosen
        by the existing bottleneck logic, unaffected by the applied section."""
        traits = [DomainTrait(characteristic="water_safety", domain="swimming", status="no_source_yet")]
        ctx_with = _make_ctx(domain_traits=traits, bottleneck="M2")
        ctx_without = _make_ctx(domain_traits=[], bottleneck="M2")
        result_with = plan_horizon(ctx_with, seed=0)
        result_without = plan_horizon(ctx_without, seed=0)
        assert result_with["plan_skeleton"]["element_id"] == result_without["plan_skeleton"]["element_id"]
        assert result_with["plan_skeleton"]["area"] == result_without["plan_skeleton"]["area"]

    def test_applied_section_links_through_worldview_area(self):
        traits = [DomainTrait(characteristic="water_safety", domain="swimming", status="no_source_yet")]
        ctx = _make_ctx(domain_traits=traits, bottleneck="M2")
        result = plan_horizon(ctx, seed=0)
        assert result["plan_skeleton"]["applied_section"]["worldview_area"] == result["plan_skeleton"]["area"]

    def test_all_domain_traits_measured_no_applied_section(self):
        traits = [DomainTrait(characteristic="stroke_efficiency", domain="swimming", status="measured")]
        ctx = _make_ctx(domain_traits=traits)
        result = plan_horizon(ctx, seed=0)
        assert result["plan_skeleton"]["applied_section"] is None


# ─────────────────────────────────────────────────────────────────────────────
# build_horizon_context — profile.yaml domain_traits → HorizonContext (Ф5b adapter)
# ─────────────────────────────────────────────────────────────────────────────

class TestBuildHorizonContextDomainTraits:
    def test_missing_domain_traits_key_yields_empty_list(self):
        ctx = build_horizon_context({})
        assert ctx.domain_traits == []

    def test_domain_traits_parsed_from_profile_dicts(self):
        profile = {
            "domain_traits": [
                {"characteristic": "stroke_efficiency", "domain": "swimming", "status": "measured", "rung": 1},
                {"characteristic": "water_comfort", "domain": "swimming", "status": "no_source_yet"},
            ]
        }
        ctx = build_horizon_context(profile)
        assert len(ctx.domain_traits) == 2
        assert ctx.domain_traits[0] == DomainTrait(
            characteristic="stroke_efficiency", domain="swimming", status="measured", rung=1
        )
        assert ctx.domain_traits[1].status == "no_source_yet"

    def test_domain_trait_with_invalid_status_fails_loud(self):
        """Same hard-fail as constructing DomainTrait directly — a typo'd status
        in profile.yaml must not silently pass through the adapter as valid."""
        profile = {"domain_traits": [{"characteristic": "x", "domain": "y", "status": "Measured"}]}
        with pytest.raises(ValueError):
            build_horizon_context(profile)

    def test_structurally_broken_entry_skipped_not_crashed(self):
        """Unlike an invalid status, a structurally broken entry (missing
        'characteristic', or not a dict at all) degrades honestly — same
        posture as malformed YAML elsewhere in this file (_read_yaml) — instead
        of a bare KeyError/TypeError with no diagnostic (found by cold-context
        review: this field was the one place in build_horizon_context that
        crashed raw instead of logging + skipping)."""
        profile = {
            "domain_traits": [
                {"domain": "swimming", "status": "measured"},  # missing 'characteristic'
                "swimming",  # not a dict at all
                {"characteristic": "water_comfort", "domain": "swimming", "status": "no_source_yet"},
            ]
        }
        ctx = build_horizon_context(profile)
        assert len(ctx.domain_traits) == 1
        assert ctx.domain_traits[0].characteristic == "water_comfort"

    def test_non_list_domain_traits_yields_empty_not_crashed(self):
        """domain_traits itself (not an entry inside it) being the wrong shape —
        a number, a bare string, a dict instead of a list — must not crash
        build_horizon_context either (found by independent review: iterating
        a non-list either threw TypeError before entering the per-entry
        try/except, or silently produced junk per-character/per-key log lines
        instead of one clear diagnostic)."""
        for bad_value in (42, "swimming", {"characteristic": "x"}):
            ctx = build_horizon_context({"domain_traits": bad_value})
            assert ctx.domain_traits == []
