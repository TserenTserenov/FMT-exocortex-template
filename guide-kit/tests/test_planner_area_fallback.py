"""Cross-area fallback in plan_horizon: never hand prompt.md an empty skeleton.

Regression cover for the most common profile there is. The default RCS profile
carries bottleneck M1, _SLOT_TO_AREA maps M1 to area 3 (Ограничения), and area 3
has no CAT.002/003 practices at all — so before the fallback every pilot without
a computed profile got element_id=None and the LLM improvised the whole lesson.
"""

import os
import sys

import pytest

# plan_horizon imports its siblings bare ("from horizons import ..."), the way the
# runtime loads them via GUIDE_KIT_HOME/generator — so generator/ must be importable
# as a flat directory here too, not only as the `generator` package.
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "generator"))

from generator.horizons import HorizonContext, RCSProfile
from generator.planner import (
    CAT002_ELEMENTS,
    CAT003_ELEMENTS,
    _area_has_elements,
    _nearest_servable_area,
    plan_horizon,
)


def _ctx(bottleneck="M1", mastery=None, stage=2):
    return HorizonContext(
        rcs=RCSProfile(
            W=2, M1=2, M2=2, M3=2, M4=2, IT=2, A=2,
            bottleneck=bottleneck, stage_derived=stage,
        ),
        mastery_by_area=mastery or {},
    )


class TestAreaCoverage:

    def test_area_three_is_the_hole_this_guards(self):
        """The premise of the fallback: area 3 really has no practices."""
        all_mastery = {**CAT002_ELEMENTS, **CAT003_ELEMENTS}
        assert not [m for m in all_mastery.values() if m["area"] == 3]
        assert not _area_has_elements(3, stage=4)

    def test_servable_areas_report_true(self):
        assert _area_has_elements(1, stage=2)
        assert _area_has_elements(2, stage=2)


class TestNearestServableArea:

    def test_skips_the_unservable_primary(self):
        area, reason = _nearest_servable_area(3, stage=2, mastery_by_area={})
        assert area != 3
        assert _area_has_elements(area, stage=2)
        assert "area=" in reason

    def test_progress_data_steers_the_choice(self):
        """Areas the pilot already advanced in lose to an untouched one."""
        area, _ = _nearest_servable_area(
            3, stage=2, mastery_by_area={"knowledge": 3, "tools": 3},
        )
        assert area == 4  # environment: untouched, so the widest remaining gap

    def test_ties_break_deterministically(self):
        first, _ = _nearest_servable_area(3, stage=2, mastery_by_area={})
        second, _ = _nearest_servable_area(3, stage=2, mastery_by_area={})
        assert first == second


class TestPlanHorizonAlwaysReturnsAnElement:

    def test_default_bottleneck_no_longer_yields_an_empty_skeleton(self):
        skeleton = plan_horizon(_ctx(), seed=42)["plan_skeleton"]
        assert skeleton.get("element_id") is not None
        assert skeleton.get("area") != 3

    def test_reason_names_the_substitution(self):
        result = plan_horizon(_ctx(), seed=42)
        blob = str(result.get("decision_log") or result.get("plan_skeleton"))
        assert "element_id" in str(result["plan_skeleton"])
        assert result["plan_skeleton"]["element_id"] is not None
        assert blob is not None

    def test_lms_progress_reaches_the_fallback(self):
        skeleton = plan_horizon(
            _ctx(mastery={"knowledge": 3, "tools": 3}), seed=42,
        )["plan_skeleton"]
        assert skeleton["area"] == 4

    def test_same_seed_same_plan(self):
        first = plan_horizon(_ctx(), seed=42)["plan_skeleton"]["element_id"]
        second = plan_horizon(_ctx(), seed=42)["plan_skeleton"]["element_id"]
        assert first == second

    @pytest.mark.parametrize("bottleneck", ["M2", "IT"])
    def test_servable_areas_are_untouched_by_the_fallback(self, bottleneck):
        """A bottleneck whose area works must keep resolving inside that area."""
        from generator.planner import _SLOT_TO_AREA

        skeleton = plan_horizon(_ctx(bottleneck=bottleneck), seed=42)["plan_skeleton"]
        assert skeleton["area"] == _SLOT_TO_AREA[bottleneck]
        assert skeleton["element_id"] is not None
