"""
Deterministic lesson planner.
SOP MIM.SOP.001 steps 1-4: choose area, impact type, element, depth.

Input contract: PD.SPEC.001
Output contract: LessonPlan — passed to prompt.md (steps 5-6)

guide-kit: a portable copy of the original platform planner.
Selection logic is unchanged — only the platform-specific logging import and the
hardcoded path to the curriculum repo were cut (see GUIDE_KIT_CURRICULUM_PATH below).
"""

from __future__ import annotations

import json
import logging
import os
import random
import re
import sys
from dataclasses import dataclass, field
from typing import TYPE_CHECKING, Literal

logger = logging.getLogger(__name__)

if TYPE_CHECKING:
    from horizons import HorizonContext

# SLOT_LABELS is imported lazily inside plan_horizon() to avoid a
# circular import when planner is loaded without horizons (legacy path)
try:
    from horizons import SLOT_LABELS
except ImportError:
    SLOT_LABELS: dict[str, str] = {}

# ---------------------------------------------------------------------------
# Input data types (PD.SPEC.001)
# ---------------------------------------------------------------------------

ImpactType = Literal["worldview", "mastery"]
State = Literal["chaos", "stuck", "pivot", "development"]
Area = Literal[1, 2, 3, 4, 5]  # knowledge, tools, constraints, environment, organism

AREA_NAMES = {
    1: "knowledge",
    2: "tools",
    3: "constraints",
    4: "environment",
    5: "organism",
}

ROLE_AREA_BOOSTS: dict[str, tuple[int, int]] = {
    # dominant_role → (primary_area, secondary_area)
    "learner":       (1, 3),
    "intellectual":  (1, 2),
    "professional":  (2, 1),
    "researcher":    (1, 3),
    "enlightener":   (4, 1),
}

# Weight matrix: phase (1-4) x area (1-5) — from SOP.001 § Matrix
PHASE_WEIGHTS: dict[int, list[float]] = {
    1: [1.5, 0.5, 0.8, 0.7, 1.0],
    2: [1.0, 1.0, 0.8, 0.8, 1.0],
    3: [0.8, 1.5, 0.8, 0.5, 1.4],
    4: [0.8, 1.8, 0.5, 0.8, 1.4],
}

# impact_type base ratio: stage → probability of worldview
STAGE_WORLDVIEW_PROB: dict[int, float] = {
    1: 0.80,
    2: 0.80,
    3: 0.50,
    4: 0.50,
    5: 0.20,
}

# Narrative arc: stage (0-4 in code = 1-5 in the Pack) → (narrative_phase, worldview_arc)
# Source-of-truth: PD.FORM.080 §3 + PD.FORM.087 §5
STAGE_NARRATIVE: dict[int, tuple[str, str]] = {
    1: ("Я могу меняться", "Я могу меняться"),                          # stage 1, Random
    2: ("Я — система", "Я — система"),                                  # stage 2, Practicing
    3: ("Окружение влияет на меня", "Окружение влияет на меня"),         # stage 3, Systematic
    4: ("Мир — система", "Мир — система, и я в ней деятель"),            # stage 4, Disciplined
    5: ("Мы меняем мир", "Системное мировоззрение, agency"),             # stage 5, Proactive
}

# CAT.002 catalog: leisure practices x area x entry_stage
# element_id → {area, entry_stage, name}
# name: the Russian name from the card's frontmatter (DS-principles-curriculum/.../CAT.002/).
# The name is hardcoded into this dict because the catalog repo isn't guaranteed to be
# present at runtime, and the prompt needs the Russian name instead of a bare code
# (a bare code leaking into generated text is a known failure mode — see element_name() below).
CAT002_ELEMENTS = {
    "CAT.002.A1": {"area": 5, "entry_stage": 1, "name": "Сон и распорядок дня"},
    "CAT.002.A2": {"area": 5, "entry_stage": 1, "name": "Отдых между помидорками"},
    "CAT.002.A3": {"area": 5, "entry_stage": 2, "name": "Двигательная практика"},
    "CAT.002.A4": {"area": 5, "entry_stage": 2, "name": "Питание и гидратация"},
    "CAT.002.A5": {"area": 5, "entry_stage": 3, "name": "Саморегуляция"},
    "CAT.002.A6": {"area": 5, "entry_stage": 3, "name": "Медицинский чек-ап"},
    "CAT.002.B1": {"area": 5, "entry_stage": 2, "name": "Замена удовольствий"},
    "CAT.002.B2": {"area": 5, "entry_stage": 2, "name": "Микро-приключения"},
    "CAT.002.B3": {"area": 5, "entry_stage": 3, "name": "Путешествия и смена контекста"},
    "CAT.002.B4": {"area": 5, "entry_stage": 3, "name": "Фиксация впечатлений"},
}

# CAT.003 catalog: learning practices x area x entry_stage
# Source: DS-principles-curriculum/data/curriculum/CAT.003/
# area: 1=knowledge, 2=tools, 3=constraints, 4=environment, 5=organism
# entry_stage: minimum stage required for access (1 = Random, available to everyone)
# name: the Russian name from the card's frontmatter (see the comment above CAT002_ELEMENTS)
CAT003_ELEMENTS: dict[str, dict] = {
    "CAT.003.METHOD.001": {"area": 2, "entry_stage": 1, "name": "Инвестирование и учёт времени"},
    "CAT.003.METHOD.003": {"area": 1, "entry_stage": 1, "name": "Систематическое медленное чтение"},
    "CAT.003.METHOD.004": {"area": 1, "entry_stage": 1, "name": "Мышление письмом"},
    "CAT.003.METHOD.005": {"area": 1, "entry_stage": 1, "name": "Мышление проговариванием"},
    "CAT.003.METHOD.006": {"area": 5, "entry_stage": 1, "name": "Организация досуга"},
    "CAT.003.METHOD.007": {"area": 4, "entry_stage": 1, "name": "Формирование окружения"},
    "CAT.003.METHOD.008": {"area": 1, "entry_stage": 2, "name": "Стратегирование"},  # Practicing+
    "CAT.003.METHOD.009": {"area": 2, "entry_stage": 1, "name": "Планирование"},
}

# CAT.001 catalog: worldview memes x area x entry_stage
# Structure: element_id → {area, entry_stage, max_depth=3}
# Source (platform-side): DS-principles-curriculum/data/curriculum/CAT.001/
# guide-kit: the path is not hardcoded — it's set via GUIDE_KIT_CURRICULUM_PATH
# (guide-kit.config.yaml → curriculum_path). Not set → an honest empty index,
# and prompt.md picks the worldview element on its own (see _load_cat001).
# Loaded from the filesystem on first access (lazy load).

_CAT001_CACHE: dict[str, dict] | None = None


def _load_cat001() -> dict[str, dict]:
    """Reads frontmatter from CAT.001's M-*.md files and builds an index."""
    global _CAT001_CACHE
    if _CAT001_CACHE is not None:
        return _CAT001_CACHE

    result: dict[str, dict] = {}
    curriculum_path = os.environ.get("GUIDE_KIT_CURRICULUM_PATH", "")

    if not curriculum_path or not os.path.isdir(curriculum_path):
        # No curriculum (a portable profile without the platform) — an honest empty index,
        # prompt.md's fallback picks the worldview element on its own.
        _CAT001_CACHE = result
        return result

    cat001_dir = os.path.normpath(curriculum_path)

    frontmatter_re = re.compile(r"^---\s*\n(.*?)\n---", re.DOTALL)

    for fname in os.listdir(cat001_dir):
        if not (fname.startswith("M-") and fname.endswith(".md")):
            continue
        fpath = os.path.join(cat001_dir, fname)
        try:
            with open(fpath, encoding="utf-8") as fh:
                content = fh.read()
        except OSError:
            continue

        m = frontmatter_re.match(content)
        if not m:
            continue

        fm: dict = {}
        for line in m.group(1).splitlines():
            if ":" in line:
                key, _, val = line.partition(":")
                fm[key.strip()] = val.strip().strip('"').strip("'")

        element_id = fm.get("id")
        try:
            area = int(fm["area"])
            entry_stage = int(fm.get("entry_stage", 1))
        except (KeyError, ValueError):
            continue

        # context: 1=Self-development, 2=Work, 3=Leisure (FORM.082)
        context_str = fm.get("context", "")
        context_map = {"Саморазвитие": 1, "Работа": 2, "Досуг": 3}
        context_val = context_map.get(context_str, 0)

        if element_id and area in range(1, 6):
            result[element_id] = {
                "area": area,
                "entry_stage": entry_stage,
                "max_depth": 3,
                "context": context_val,
                "name": fm.get("name", ""),
            }

    _CAT001_CACHE = result
    return result


# Lazy accessor — used inside _choose_element_worldview
def _get_cat001() -> dict[str, dict]:
    return _load_cat001()


def element_name(element_id: str) -> str:
    """The catalog element's Russian name for the prompt text, "" if unknown.

    A bare element code (e.g. "CAT.003.METHOD.003") leaking into the prompt and
    then into the generated lesson text is a known failure mode. The generator
    substitutes the name for the code; the code stays only in decision_log.
    """
    for catalog in (CAT003_ELEMENTS, CAT002_ELEMENTS, _get_cat001()):
        entry = catalog.get(element_id)
        if entry and entry.get("name"):
            return entry["name"]
    return ""


# ---------------------------------------------------------------------------
# FORM.082 context: derivation and hint
# ---------------------------------------------------------------------------

# Catalog → context mapping (for CAT.002/CAT.003 and fallback)
_CATALOG_CONTEXT: dict[str, int] = {
    "CAT.002": 3,   # Leisure
    "CAT.003": 1,   # Self-development
    "DP.M.008": 2,  # Work
}

_CONTEXT_NAMES = {1: "Саморазвитие", 2: "Работа", 3: "Досуг"}

_CONTEXT_HINTS = {
    1: "Выделите 20 минут в своём учебном слоте",
    2: "Применяйте при следующей работе над рабочим продуктом",
    3: "Встройте в досуг на ближайшей неделе",
}


def _derive_context(element_id: str | None) -> int:
    """Derive the context from element_id (FORM.008 §3).

    CAT.001 → from frontmatter (the context field in the cache).
    CAT.002 → 3 (Leisure). CAT.003 → 1 (Self-development). DP.M.008 → 2 (Work).
    Fallback → 1 (Self-development).
    """
    if not element_id:
        return 1

    # CAT.001 — from the frontmatter cache
    if element_id.startswith("CAT.001"):
        cat001 = _get_cat001()
        meta = cat001.get(element_id)
        if meta and meta.get("context"):
            return meta["context"]
        return 1  # fallback

    # Other catalogs — by prefix
    for prefix, ctx in _CATALOG_CONTEXT.items():
        if element_id.startswith(prefix):
            return ctx

    return 1


def _build_context_hint(context: int, student_stage: int) -> str:
    """Hint on when/where to complete the assignment (FORM.008 §3)."""
    return _CONTEXT_HINTS.get(context, _CONTEXT_HINTS[1])


CAT001_ELEMENTS: dict[str, dict] = {}  # legacy alias; real data comes through _get_cat001()


# ---------------------------------------------------------------------------
# Dataclasses
# ---------------------------------------------------------------------------

@dataclass
class RecentLesson:
    element_id: str
    element_type: str  # "worldview" | "mastery"
    area: int
    depth: int
    passed: bool
    errors: list[str] = field(default_factory=list)
    rating: int | None = None
    date: str | None = None


@dataclass
class TailorContext:
    """Input contract (PD.SPEC.001)."""
    student_stage: int                     # 0-4
    it_level: int                          # 0-3
    dominant_role: str                     # learner | intellectual | professional | researcher | enlightener
    state: State                           # chaos | stuck | pivot | development
    energy: int                            # 1-5
    phase: int                             # 1-4 (from SOP step 2, or computed from the stage)
    mastery_by_area: dict[str, int]        # {knowledge: N, tools: N, ...} — N = current depth
    last_area: int | None                  # area of the last session (1-5)
    recent_history: list[RecentLesson]
    worldview_gaps: list[str]              # [] if L3 has not been computed
    mastery_gaps: list[str]               # [] if L3 has not been computed
    domain: str                            # the student's professional domain

    @classmethod
    def from_dict(cls, d: dict) -> "TailorContext":
        history = [
            RecentLesson(**r) if isinstance(r, dict) else r
            for r in d.get("recent_history", [])
        ]
        return cls(
            student_stage=int(d["student_stage"]),
            it_level=int(d["it_level"]),
            dominant_role=str(d["dominant_role"]),
            state=d["state"],
            energy=int(d["energy"]),
            phase=int(d.get("phase") or _stage_to_phase(int(d["student_stage"]))),
            mastery_by_area=d.get("mastery_by_area", {}),
            last_area=d.get("last_area"),
            recent_history=history,
            worldview_gaps=d.get("worldview_gaps", []),
            mastery_gaps=d.get("mastery_gaps", []),
            domain=str(d.get("domain", "")),
        )


@dataclass
class LessonPlan:
    """The planner's output contract → input to prompt.md (steps 5-6)."""
    area: int                      # 1-5
    element_id: str               # CAT.001.A3, CAT.002.B1, ...
    element_type: str             # "worldview" | "mastery"
    impact_type: ImpactType
    target_depth: int             # 1-4
    session_goal: str             # the session's stated goal
    decision_log: dict            # audit trail


# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

def _stage_to_phase(stage: int) -> int:
    """SOP step 2: stage → phase."""
    return {0: 1, 1: 1, 2: 2, 3: 3, 4: 4}.get(stage, 1)


def _compute_area_weights(ctx: TailorContext) -> list[float]:
    """
    SOP step 3: compute the area weights.
    Returns a list of 5 weights [w1, w2, w3, w4, w5].
    """
    weights = list(PHASE_WEIGHTS[ctx.phase])  # copy

    # Adjust by state
    state_adjustments: dict[str, dict[int, float]] = {
        "chaos":       {5: 2.0, 1: 0.5},
        "stuck":       {3: 1.5, 1: 1.5},
        "pivot":       {},
        "development": {2: 1.5},
    }
    for area_idx, multiplier in state_adjustments.get(ctx.state, {}).items():
        weights[area_idx - 1] *= multiplier

    # Adjust by energy
    if ctx.energy <= 2:
        weights[4] *= 1.5  # area 5 (Organism) — index 4

    # Adjust by dominant role
    role_areas = ROLE_AREA_BOOSTS.get(ctx.dominant_role)
    if role_areas:
        for area_idx in role_areas:
            weights[area_idx - 1] *= 1.5

    # Rotation: zero out yesterday's area
    if ctx.last_area is not None:
        weights[ctx.last_area - 1] = 0.0

    return weights


def _choose_area(weights: list[float], mastery_by_area: dict[str, int]) -> tuple[int, str]:
    """
    SOP step 3: choose the area.
    Criterion: max(weight x gap), where gap = 1 if depth < 4 else 0.
    Returns (area_int, reason_str).
    """
    area_keys = ["knowledge", "tools", "constraints", "environment", "organism"]
    scores = []
    for i, key in enumerate(area_keys):
        current_depth = mastery_by_area.get(key, 0)
        gap = max(0, 4 - current_depth)
        score = weights[i] * gap
        scores.append(score)

    total = sum(scores)
    if total == 0:
        # All areas are at max depth — fallback: take the first one with a non-zero weight
        for i, w in enumerate(weights):
            if w > 0:
                chosen = i + 1
                return chosen, f"fallback: все области max depth, первая с ненулевым весом: {AREA_NAMES[chosen]}"
        return 1, "fallback: все веса нулевые, выбрана область 1"

    chosen_idx = scores.index(max(scores))
    chosen_area = chosen_idx + 1
    reason = (
        f"area={chosen_area} ({AREA_NAMES[chosen_area]}): "
        f"score={scores[chosen_idx]:.2f} "
        f"(weight={weights[chosen_idx]:.2f} × gap={scores[chosen_idx]/weights[chosen_idx]:.0f})"
        if weights[chosen_idx] > 0 else
        f"area={chosen_area}: выбран как максимальный score"
    )
    return chosen_area, reason


def _choose_impact_type(ctx: TailorContext) -> tuple[ImpactType, str]:
    """
    SOP step 3: choose the impact type.
    Base ratio by stage + adjustment by GAP if present.
    """
    worldview_prob = STAGE_WORLDVIEW_PROB.get(ctx.student_stage, 0.5)

    # Adjustment based on the GAP report
    reason = f"base_prob_worldview={worldview_prob:.0%} (stage={ctx.student_stage})"
    if ctx.worldview_gaps or ctx.mastery_gaps:
        wv_gap_count = len(ctx.worldview_gaps)
        ms_gap_count = len(ctx.mastery_gaps)
        if wv_gap_count > ms_gap_count:
            worldview_prob = min(1.0, worldview_prob + 0.2)
            reason += f"; GAP-корректировка: worldview_gaps({wv_gap_count}) > mastery_gaps({ms_gap_count}) → +0.2"
        elif ms_gap_count > wv_gap_count:
            worldview_prob = max(0.0, worldview_prob - 0.2)
            reason += f"; GAP-корректировка: mastery_gaps({ms_gap_count}) > worldview_gaps({wv_gap_count}) → -0.2"
        else:
            reason += "; GAP-отчёт: равные пробелы → без корректировки"
    else:
        reason += "; GAP-отчёт: нет (L3 не вычислен) → weighted random"

    impact = "worldview" if random.random() < worldview_prob else "mastery"
    reason += f" → выбран {impact}"
    return impact, reason


def _get_recent_element_ids(recent: list[RecentLesson], n: int = 5) -> set[str]:
    return {r.element_id for r in recent[:n]}


# Area order used to break ties when falling back to another area — the planner
# must be deterministic for the same input (same seed → same plan).
_AREA_KEYS_BY_INDEX = ["knowledge", "tools", "constraints", "environment", "organism"]


def _area_has_elements(area: int, stage: int) -> bool:
    """True if some catalog can serve this area at this stage."""
    for meta in {**CAT002_ELEMENTS, **CAT003_ELEMENTS}.values():
        if meta["area"] == area and meta["entry_stage"] <= stage:
            return True
    for meta in _load_cat001().values():
        if meta.get("area") == area and meta.get("entry_stage", 1) <= stage:
            return True
    return False


def _nearest_servable_area(
    primary_area: int, stage: int, mastery_by_area: dict[str, int]
) -> tuple[int | None, str]:
    """Pick a replacement area when `primary_area` has nothing in any catalog.

    Preference is the same one _choose_area uses when it works normally — the
    largest remaining gap (4 - depth), so real progress data (including the
    interim LMS snapshot) still steers the choice. Ties break on the lower area
    number, so the plan stays reproducible for a given seed.

    Returns (area, reason) or (None, reason) when no area can be served at all —
    the caller then keeps the empty skeleton, exactly as before this fallback.
    """
    servable = [a for a in range(1, 6) if a != primary_area and _area_has_elements(a, stage)]
    if not servable:
        return None, "ни одна область не обслуживается каталогом"
    best = max(
        servable,
        key=lambda a: (4 - mastery_by_area.get(_AREA_KEYS_BY_INDEX[a - 1], 0), -a),
    )
    depth = mastery_by_area.get(_AREA_KEYS_BY_INDEX[best - 1], 0)
    return best, f"замена на area={best} (gap={4 - depth}, обслуживается каталогом)"


def _choose_element_worldview(
    area: int,
    stage: int,
    recent_ids: set[str],
    worldview_gaps: list[str],
    mastery_by_area: dict[str, int],
    recent_history: list | None = None,
) -> tuple[str | None, int, str]:
    """
    SOP step 4: choose a meme from CAT.001.
    Returns (element_id, target_depth, reason), or (None, 1, reason) if there are no elements.

    Priorities:
    1. worldview_gaps (from the Diagnostician) — if present and not in recent
    2. CAT.001 from the filesystem — bottleneck-first by depth
    3. Fallback → prompt.md
    """
    history = recent_history or []

    # 1. GAP report from the Diagnostician
    if worldview_gaps:
        candidates = [e for e in worldview_gaps if e not in recent_ids]
        if candidates:
            chosen = candidates[0]
            current_depth = _get_current_depth(chosen, history)
            target = min(current_depth + 1, 3)
            return chosen, target, f"worldview_gaps → {chosen}, depth {current_depth}→{target}"
        chosen = worldview_gaps[0]
        current_depth = _get_current_depth(chosen, history)
        target = min(current_depth + 1, 3)
        return chosen, target, f"worldview_gaps (все recent) → {chosen}, depth {current_depth}→{target}"

    # 2. Load the catalog from the filesystem
    cat001 = _get_cat001()
    if not cat001:
        return None, 1, "нет GAP-отчёта и CAT001 не загружен → prompt.md выбирает из каталога"

    # Filter by area and stage-based availability
    candidates_pool = {
        eid: meta
        for eid, meta in cat001.items()
        if meta["area"] == area and meta["entry_stage"] <= stage
    }

    if not candidates_pool:
        # Widen the search: any area
        candidates_pool = {
            eid: meta
            for eid, meta in cat001.items()
            if meta["entry_stage"] <= stage
        }
        if not candidates_pool:
            return None, 1, f"CAT001: нет доступных мемов для stage={stage}"

    # Exclude recent ones, if there's anything outside them
    non_recent = {eid: m for eid, m in candidates_pool.items() if eid not in recent_ids}
    pool = non_recent if non_recent else candidates_pool

    # Bottleneck-first: choose the meme with the largest gap (max_depth - current_depth)
    best_eid = None
    best_gap = -1
    for eid in pool:
        current_depth = _get_current_depth(eid, history)
        max_depth = pool[eid].get("max_depth", 3)
        gap = max_depth - current_depth
        if gap > best_gap:
            best_gap = gap
            best_eid = eid

    if best_eid is None:
        return None, 1, "CAT001: bottleneck-first не нашёл кандидата"

    current_depth = _get_current_depth(best_eid, history)
    target = min(current_depth + 1, 3)
    reason = (
        f"CAT001 bottleneck-first → {best_eid} "
        f"(area={candidates_pool.get(best_eid, pool[best_eid])['area']}, "
        f"gap={best_gap}, depth {current_depth}→{target})"
    )
    return best_eid, target, reason


def _choose_element_mastery(
    area: int,
    stage: int,
    recent_ids: set[str],
    mastery_gaps: list[str],
    mastery_by_area: dict[str, int],
    recent_history: list[RecentLesson],
) -> tuple[str | None, int, str]:
    """
    SOP step 4: choose a practice from CAT.002 or CAT.003.
    Returns (element_id, target_depth, reason).
    """
    # Merge CAT.002 and CAT.003
    all_mastery = {**CAT002_ELEMENTS, **CAT003_ELEMENTS}

    # Filter by area and stage-based availability
    candidates = {
        eid: meta
        for eid, meta in all_mastery.items()
        if meta["area"] == area and meta["entry_stage"] <= stage
    }

    if not candidates:
        # Fallback: a different area → prompt.md will handle it
        return None, 1, f"нет mastery-элементов для area={area}, stage={stage} → prompt.md fallback"

    # Exclude recent_ids
    non_recent = {eid: meta for eid, meta in candidates.items() if eid not in recent_ids}
    pool = non_recent if non_recent else candidates  # if all are recent — return all of them

    # If mastery_gaps exist — give them priority
    if mastery_gaps:
        gap_candidates = [e for e in mastery_gaps if e in pool]
        if gap_candidates:
            chosen = gap_candidates[0]
            # Determine the current depth from recent_history
            current_depth = _get_current_depth(chosen, recent_history)
            target = current_depth + 1
            return chosen, target, f"mastery_gaps → {chosen}, depth {current_depth}→{target}"

    # Bottleneck-first: find the element with the largest gap
    # Error history: prioritize elements with errors when the gap is equal
    history_map = {r.element_id: r for r in recent_history}

    best_eid = None
    best_gap = -1
    best_has_errors = False

    for eid in pool:
        current = _get_current_depth(eid, recent_history)
        target_max = 4  # max degree for CAT.002/003
        gap = target_max - current
        has_errors = len(history_map.get(eid, RecentLesson(eid, "", 0, 0, False)).errors) > 0

        better = (
            gap > best_gap
            or (gap == best_gap and has_errors and not best_has_errors)
        )
        if better:
            best_eid = eid
            best_gap = gap
            best_has_errors = has_errors

    if best_eid is None:
        return None, 1, "нет подходящих mastery-элементов"

    current_depth = _get_current_depth(best_eid, recent_history)
    target = current_depth + 1
    reason = f"bottleneck-first → {best_eid}, gap={best_gap}, errors={best_has_errors}, depth {current_depth}→{target}"
    return best_eid, target, reason


def _get_current_depth(element_id: str, history: list[RecentLesson]) -> int:
    """Find the maximum passed depth for the element in the history."""
    passed = [
        r.depth for r in history
        if r.element_id == element_id and r.passed
    ]
    return max(passed) if passed else 0


def _mastery_gate(element_id: str, target_depth: int, history: list[RecentLesson]) -> tuple[int, str]:
    """
    SOP step 4c: mastery-gate — do not raise the depth without passing the can-do check.
    Returns (actual_depth, reason).
    """
    if target_depth <= 1:
        return 1, "новый элемент → depth=1"

    previous_depth = target_depth - 1
    can_do_passed = any(
        r.element_id == element_id and r.depth == previous_depth and r.passed
        for r in history
    )

    if can_do_passed:
        return target_depth, f"mastery-gate ✓: depth {previous_depth} пройден → повышаем до {target_depth}"
    else:
        return previous_depth, f"mastery-gate ✗: depth {previous_depth} НЕ пройден → остаёмся на {previous_depth}"


def _build_session_goal(element_id: str | None, impact_type: ImpactType, area: int, depth: int) -> str:
    area_name = AREA_NAMES.get(area, str(area))
    if impact_type == "worldview":
        return f"Переосмыслить мировоззренческий паттерн в области «{area_name}» (глубина {depth})"
    else:
        return f"Освоить практику в области «{area_name}»: {element_id or 'по каталогу'} (степень {depth})"


# ---------------------------------------------------------------------------
# Applied track (Ф5b): domain_traits → daily applied-mastery mini-section.
# Model fixed in WP-495 Ф3 (2026-07-18) — two-factor hierarchical choice:
# primary = the applied program's next unresolved step (one active domain,
# program order is not skippable); secondary (optional) = link to today's
# worldview lesson. The applied section never replaces the worldview lesson.
# ---------------------------------------------------------------------------

def _choose_domain_step(domain_traits: list) -> tuple[str, str, str] | None:
    """Pick the next unresolved step of the ONE active applied domain.

    "Unresolved" = the first not-yet-measured trait, in list order (the order
    IS the program sequence — domain_traits is expected pre-sorted by the
    domain's own scale, e.g. threshold characteristics before growth ones).
    A domain with no unresolved trait (everything measured or dormant) has no
    active step today — returns None, not a guess.

    Returns (domain, characteristic, reason) or None if no domain is active.
    """
    if not domain_traits:
        return None

    active_domain = domain_traits[0].domain
    for trait in domain_traits:
        if trait.domain != active_domain:
            continue  # one active domain per day — program order is not skipped across domains
        if trait.status == "dormant-no-source":
            continue  # failed the 6-point activation checklist — not offered
        if trait.status != "measured":
            return trait.domain, trait.characteristic, (
                f"прикладной трек «{trait.domain}»: следующий нерешённый шаг «{trait.characteristic}»"
            )

    return None  # every trait of the active domain is already measured or dormant


def _build_applied_section(domain: str, characteristic: str, worldview_area: int) -> dict:
    """Builds the daily applied-mastery mini-section (Объединение №1, WP-495 Ф3).

    `link_mode` names how the connection to the worldview lesson should be
    shown, per the decided model: either through the lesson's theme, or as an
    adjacent related case. The exact choice of framing text is prompt.md's
    job (LLM stage) — the planner only supplies the deterministic skeleton.
    """
    return {
        "domain": domain,
        "characteristic": characteristic,
        "link_mode": "theme_lens",  # shown through the worldview lesson's theme, by default
        "worldview_area": worldview_area,
        "note": "мини-секция дополняет мыслительный урок, не заменяет и не продвигает программу автоматически",
    }


# ---------------------------------------------------------------------------
# Main function
# ---------------------------------------------------------------------------

def plan(tailor_context: dict, seed: int | None = None) -> dict:
    """
    Deterministic planner: SOP.001 steps 1-4.

    Args:
        tailor_context: a dict per PD.SPEC.001
        seed: pin random for reproducibility (tests)

    Returns:
        dict with LessonPlan fields + decision_log
    """
    if seed is not None:
        random.seed(seed)

    # --- Step 1: Validate and parse the input ---
    try:
        ctx = TailorContext.from_dict(tailor_context)
    except (KeyError, TypeError, ValueError) as e:
        raise ValueError(f"Невалидный tailor_context (PD.SPEC.001): {e}") from e

    # Sanitize user-generated fields
    safe_domain = ctx.domain[:200].replace("\n", " ").replace("\r", "")
    safe_state = ctx.state if ctx.state in ("chaos", "stuck", "pivot", "development") else "development"
    ctx.state = safe_state

    # --- Step 2: Phase (already computed in TailorContext.from_dict) ---
    phase = ctx.phase

    # --- Step 3: Weights, area, impact type ---
    weights = _compute_area_weights(ctx)
    area, area_reason = _choose_area(weights, ctx.mastery_by_area)
    impact_type, impact_reason = _choose_impact_type(ctx)

    # --- Step 4: Element and depth ---
    recent_ids = _get_recent_element_ids(ctx.recent_history)

    if impact_type == "worldview":
        element_id, raw_depth, element_reason = _choose_element_worldview(
            area, ctx.student_stage, recent_ids,
            ctx.worldview_gaps, ctx.mastery_by_area,
            ctx.recent_history,
        )
    else:
        element_id, raw_depth, element_reason = _choose_element_mastery(
            area, ctx.student_stage, recent_ids,
            ctx.mastery_gaps, ctx.mastery_by_area, ctx.recent_history,
        )

    # Mastery-gate
    if element_id:
        target_depth, gate_reason = _mastery_gate(element_id, raw_depth, ctx.recent_history)
    else:
        target_depth = 1
        gate_reason = "элемент не выбран — prompt.md выбирает самостоятельно"

    # Fallback: no elements → switch impact_type
    if element_id is None and impact_type == "worldview":
        fallback_note = "worldview → нет элементов → fallback mastery"
        impact_type = "mastery"
        element_id, raw_depth, element_reason = _choose_element_mastery(
            area, ctx.student_stage, recent_ids,
            ctx.mastery_gaps, ctx.mastery_by_area, ctx.recent_history,
        )
        target_depth = raw_depth
        gate_reason += f"; {fallback_note}"
    elif element_id is None and impact_type == "mastery":
        fallback_note = "mastery → нет элементов → fallback worldview"
        impact_type = "worldview"
        element_id, raw_depth, element_reason = _choose_element_worldview(
            area, ctx.student_stage, recent_ids,
            ctx.worldview_gaps, ctx.mastery_by_area,
            ctx.recent_history,
        )
        target_depth = raw_depth
        gate_reason += f"; {fallback_note}"

    element_type = "worldview" if impact_type == "worldview" else "mastery"
    session_goal = _build_session_goal(element_id, impact_type, area, target_depth)

    # FORM.082 context
    context_code = _derive_context(element_id)
    context_hint = _build_context_hint(context_code, ctx.student_stage)

    decision_log = {
        "area_choice": area_reason,
        "element_choice": element_reason,
        "impact_type_choice": impact_reason,
        "depth_rationale": gate_reason,
        "context": f"{context_code} ({_CONTEXT_NAMES.get(context_code, '?')})",
        "phase": phase,
        "weights": {AREA_NAMES[i + 1]: round(w, 3) for i, w in enumerate(weights)},
    }

    return {
        "lesson_plan": {
            "area": area,
            "element_id": element_id,
            "element_type": element_type,
            "impact_type": impact_type,
            "target_depth": target_depth,
            "session_goal": session_goal,
            "context": context_code,
            "context_hint": context_hint,
        },
        "decision_log": decision_log,
        # Metadata for prompt.md
        "context_for_llm": {
            "student_stage": ctx.student_stage,
            "it_level": ctx.it_level,
            "state": safe_state,
            "energy": ctx.energy,
            "dominant_role": ctx.dominant_role,
            "domain": safe_domain,
            "narrative_phase": STAGE_NARRATIVE.get(ctx.student_stage, ("Я — система", "Я — система"))[0],
            "worldview_arc": STAGE_NARRATIVE.get(ctx.student_stage, ("Я — система", "Я — система"))[1],
            "recent_history": [
                {
                    "element_id": r.element_id,
                    "area": r.area,
                    "depth": r.depth,
                    "passed": r.passed,
                    # errors are sanitized: only the first 5, capped at 100 chars each
                    "errors": [str(e)[:100] for e in (r.errors or [])[:5]],
                }
                for r in ctx.recent_history[:5]
            ],
        },
    }


# ---------------------------------------------------------------------------
# plan_horizon() — horizon-aware planner
# ---------------------------------------------------------------------------

# RCS slot → FORM.081 area and impact type mapping
# Source: PD.FORM.089 + the SOP.001 weight matrix
_SLOT_TO_AREA: dict[str, int] = {
    "W":  1,  # knowledge — worldview through concepts
    "M1": 3,  # constraints — focus/self-organization as a constraint on attention
    "M2": 2,  # tools — IWE/ORZ as a tool
    "M3": 1,  # knowledge — domain knowledge
    "M4": 1,  # knowledge — systems thinking
    "IT": 2,  # tools — IT tools
    "A":  4,  # environment — agency through environment and connections
}

_SLOT_TO_IMPACT: dict[str, ImpactType] = {
    "W":  "worldview",  # worldview — CAT.001 memes
    "M1": "mastery",    # focus — CAT.003 practices
    "M2": "mastery",    # IWE — CAT.003 practices
    "M3": "mastery",    # domain — CAT.003 practices
    "M4": "worldview",  # systems thinking → worldview (CAT.001 memes)
    "IT": "mastery",    # IT proficiency — practices
    "A":  "worldview",  # agency → worldview
}

# Energy/trigger → number of pomodoros per day
_TRIGGER_TOMATOES: dict[str, int] = {
    "slot_miss": 1,
    "calendar_event": 1,
    "routine": 2,
    "focus_shift": 2,
    "metric_jump": 2,
    "blocker": 1,
    "hypothesis_fail": 2,
}


def _rcs_to_tailor_context_dict(ctx: "HorizonContext") -> dict:
    """Converts a HorizonContext into a dict compatible with plan().

    Used as an intermediate step: we choose the area and the element
    through plan()'s existing logic, but with RCS-based parameters.
    """
    from horizons import HorizonContext as HC
    rcs = ctx.rcs
    # RCS stage_derived (1-5 in the Pack) → student_stage (0-4 in code) mapping
    stage_code = max(0, min(4, rcs.stage_derived - 1))

    # Bottleneck → state
    bottleneck = ctx.effective_bottleneck()
    if ctx.trigger.kind == "slot_miss":
        state = "chaos"
    elif ctx.trigger.kind == "blocker":
        state = "stuck"
    elif ctx.trigger.kind == "focus_shift":
        state = "pivot"
    else:
        state = "development"

    # Energy: Orchestrator override, or a default based on the trigger
    energy = ctx.day.energy_override or (1 if ctx.trigger.kind == "slot_miss" else 3)

    # GAP lists: give priority to the monthly themes from HorizonContext
    worldview_gaps = list(ctx.month.memes) if ctx.month.memes else []
    mastery_gaps = list(ctx.month.methods) if ctx.month.methods else []

    return {
        "student_stage": stage_code,
        "it_level": rcs.IT,
        "dominant_role": "learner",   # not in RCS — default
        "state": state,
        "energy": energy,
        "mastery_by_area": {},
        "last_area": None,
        "recent_history": [],
        "worldview_gaps": worldview_gaps,
        "mastery_gaps": mastery_gaps,
        "domain": "",
    }


def plan_horizon(ctx: "HorizonContext", seed: int | None = None) -> dict:
    """Horizon-aware planner.

    Input: HorizonContext (RCS + 4 horizons + trigger)
    Output: a dict with keys {mode, plan_skeleton, horizon_context, context_for_llm,
    decision_log} for prompt.md → the LLM assembles a PlanDay (type defined in horizons.py).
    `PlanDay` is deliberately not returned from the planner — it stays the output
    contract of the LLM stage (SOP steps 5-6), while the planner is only responsible
    for the skeleton.

    Differences from plan():
    - Area and impact_type are chosen from the RCS bottleneck (not from stage weights)
    - Monthly themes → worldview_gaps / mastery_gaps (element priority)
    - Orchestrator trigger → state, energy, tomatoes
    - The horizon cascade is passed to the LLM explicitly, for the narrative

    mastery_by_area comes from ctx.mastery_by_area.
    recent_history stays [] — the domain_event → RecentLesson conversion is deferred.

    ctx.domain_traits (Ф5b, applied track) has no production adapter yet — no
    caller populates it from a real source (e.g. characteristics/*.yaml on
    disk). Only tests set it directly. Wiring a real adapter is a separate,
    not-yet-scheduled step (pilot decides which domain goes first).
    """
    from horizons import HorizonContext

    if seed is not None:
        random.seed(seed)

    rcs = ctx.rcs
    bottleneck = ctx.effective_bottleneck()

    # Determine the area and impact_type from the bottleneck
    primary_area = _SLOT_TO_AREA.get(bottleneck, 1)
    impact_type = _SLOT_TO_IMPACT.get(bottleneck, "worldview")

    # If week sets focus_area — override
    if ctx.week.focus_area:
        primary_area = ctx.week.focus_area

    stage_code = max(0, min(4, rcs.stage_derived - 1))

    # GAP priorities from the monthly themes
    worldview_gaps = list(ctx.month.memes) if ctx.month.memes else []
    mastery_gaps = list(ctx.month.methods) if ctx.month.methods else []

    # Choose the element through the planner's existing functions
    # mastery_by_area from Memory.Derived — activates _mastery_gate
    mastery_by_area = getattr(ctx, "mastery_by_area", {}) or {}
    recent_ids: set[str] = set()
    if impact_type == "worldview":
        element_id, raw_depth, element_reason = _choose_element_worldview(
            primary_area, stage_code, recent_ids, worldview_gaps, mastery_by_area, []
        )
        if element_id is None:
            impact_type = "mastery"
            element_id, raw_depth, element_reason = _choose_element_mastery(
                primary_area, stage_code, recent_ids, mastery_gaps, mastery_by_area, []
            )
            if element_id is None:
                # bidirectional fallback: mastery is also empty → fall back to worldview
                impact_type = "worldview"
                element_id, raw_depth, element_reason = _choose_element_worldview(
                    primary_area, stage_code, recent_ids, worldview_gaps, mastery_by_area, []
                )
    else:
        element_id, raw_depth, element_reason = _choose_element_mastery(
            primary_area, stage_code, recent_ids, mastery_gaps, mastery_by_area, []
        )
        if element_id is None:
            impact_type = "worldview"
            element_id, raw_depth, element_reason = _choose_element_worldview(
                primary_area, stage_code, recent_ids, worldview_gaps, mastery_by_area, []
            )
            if element_id is None:
                # bidirectional fallback: worldview is also empty → fall back to mastery
                impact_type = "mastery"
                element_id, raw_depth, element_reason = _choose_element_mastery(
                    primary_area, stage_code, recent_ids, mastery_gaps, mastery_by_area, []
                )

    # Cross-area fallback: both catalogs are empty FOR THIS AREA, so no amount of
    # retrying inside it can help. Without this the planner hands prompt.md an
    # empty skeleton and the LLM improvises the whole lesson — which is exactly
    # what happens today for the most common profile there is: the default RCS
    # bottleneck is M1, _SLOT_TO_AREA maps M1 to area 3 (Ограничения), and area 3
    # has no CAT.002/003 practices at all, while CAT.001 stays empty whenever
    # GUIDE_KIT_CURRICULUM_PATH is unset. Pick the nearest area that can actually
    # be served instead of serving nothing.
    if element_id is None:
        fallback_area, fallback_reason = _nearest_servable_area(
            primary_area, stage_code, mastery_by_area
        )
        if fallback_area is not None:
            element_id, raw_depth, element_reason = _choose_element_mastery(
                fallback_area, stage_code, recent_ids, mastery_gaps, mastery_by_area, []
            )
            impact_type = "mastery"
            if element_id is None:
                element_id, raw_depth, element_reason = _choose_element_worldview(
                    fallback_area, stage_code, recent_ids, worldview_gaps, mastery_by_area, []
                )
                impact_type = "worldview"
            if element_id is not None:
                element_reason = (
                    f"area={primary_area} не обслуживается каталогом → {fallback_reason}; "
                    f"{element_reason}"
                )
                primary_area = fallback_area

    # Mastery-gate: do not raise the depth without passing the can-do check (P5 fix)
    if element_id:
        target_depth, gate_reason = _mastery_gate(element_id, raw_depth, [])
    else:
        target_depth = 1
        gate_reason = "элемент не выбран — prompt.md выбирает самостоятельно"

    # Pomodoros: based on trigger + energy
    base_tomatoes = _TRIGGER_TOMATOES.get(ctx.trigger.kind, 2)
    energy = ctx.energy()
    if energy <= 2 or ctx.day.calendar_load == "heavy":
        tomatoes = 1
    elif energy >= 4 and base_tomatoes >= 2:
        tomatoes = 2
    else:
        tomatoes = base_tomatoes

    # Narrative: which phase to use
    narrative_phase = STAGE_NARRATIVE.get(stage_code, ("Я — система", "Я — система"))

    # Format the horizons for the LLM
    quarter_block = {
        "bottleneck_slot": ctx.quarter.bottleneck_slot or bottleneck,
        "theme": ctx.quarter.theme,
        "target_delta": ctx.quarter.target_delta,
    }
    month_block = {
        "memes": ctx.month.memes,
        "methods": ctx.month.methods,
        "label": ctx.month.label,
    }
    week_block = {
        "expected_delta": ctx.week.expected_delta,
        "slack_budget": ctx.week.slack_budget,
        "focus_area": ctx.week.focus_area,
        "label": ctx.week.label,
    }
    day_block = {
        "missed_slots": ctx.day.missed_slots,
        "calendar_load": ctx.day.calendar_load,
        "energy": energy,
        "notes": ctx.day.notes,
    }

    # Applied track (Ф5b): the daily mini-section, alongside the worldview lesson
    # above — never replacing it. domain_traits absent/empty → section stays
    # off, same honest-absence principle as the rest of the planner (no guess).
    domain_step = _choose_domain_step(ctx.domain_traits)
    applied_section = (
        _build_applied_section(domain_step[0], domain_step[1], primary_area)
        if domain_step else None
    )

    decision_log = {
        "bottleneck": bottleneck,
        "primary_area": f"{primary_area} ({AREA_NAMES.get(primary_area, '?')})",
        "impact_type": impact_type,
        "element_choice": element_reason,
        "target_depth": target_depth,
        "depth_rationale": gate_reason,
        "tomatoes": tomatoes,
        "trigger": f"{ctx.trigger.kind}: {ctx.trigger.detail}",
        "rcs_stage": rcs.stage_derived,
        "applied_track": domain_step[2] if domain_step else "нет активного домена — секция отсутствует",
    }

    return {
        "mode": "horizon",
        "plan_skeleton": {
            "element_id": element_id,
            "element_type": "worldview" if impact_type == "worldview" else "mastery",
            "area": primary_area,
            "target_depth": target_depth,
            "tomatoes": tomatoes,
            "applied_section": applied_section,
        },
        "horizon_context": {
            "quarter": quarter_block,
            "month": month_block,
            "week": week_block,
            "day": day_block,
            "artifacts_summary": {
                "count": ctx.artifacts.count,
                "by_type": ctx.artifacts.by_type,
                "recent_titles": ctx.artifacts.recent_titles[:5],
            },
            "summary_events": ctx.summary_events,
            "pilot_reflection": ctx.pilot_reflection,
            "reflection_learned": ctx.reflection_learned,
            "tomorrow_intention": ctx.tomorrow_intention,
        },
        "context_for_llm": {
            "rcs": rcs.to_dict(),
            "stage_derived": rcs.stage_derived,
            "it_level": rcs.IT,
            "narrative_phase": narrative_phase[0],
            "worldview_arc": narrative_phase[1],
            "bottleneck_slot": bottleneck,
            "bottleneck_label": SLOT_LABELS.get(bottleneck, bottleneck),
            # Unset (no council record, connected or not) → key omitted, not a guessed
            # default degree — the LLM must not assume a knowledge level it wasn't told.
            **({"qualification_degree": ctx.qualification_degree.degree}
               if ctx.qualification_degree.degree else {}),
        },
        "decision_log": decision_log,
    }


# ---------------------------------------------------------------------------
# CLI entry point (headless)
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    # Read tailor_context from stdin (JSON), write lesson_plan to stdout (JSON)
    raw = sys.stdin.read()
    try:
        context = json.loads(raw)
    except json.JSONDecodeError as e:
        print(json.dumps({"error": f"Невалидный JSON на stdin: {e}"}))
        sys.exit(1)

    try:
        result = plan(context)
        print(json.dumps(result, ensure_ascii=False, indent=2))
    except ValueError as e:
        print(json.dumps({"error": str(e)}))
        sys.exit(1)
