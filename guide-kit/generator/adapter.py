"""
adapter.py — guide-kit generator adapter.

Bridges a user's profile.yaml (the 2.1-2.4 data-lifecycle axes) to the deterministic
planner (planner.py + horizons.py) and a configurable LLM backend, producing
either a markdown plan or a diagnostic failure report — never a silently
invented fact (hard-fail policy, see policies/default.yaml).

CLI:
    python3 adapter.py --profile profile.yaml [--config guide-kit.config.yaml]
"""
from __future__ import annotations

import dataclasses
import json
import logging
import os
import sys
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any

import yaml

from horizons import (
    ArtifactsSummary,
    DayEvents,
    DomainTrait,
    HorizonContext,
    MonthThemes,
    OrchestratorTrigger,
    QualificationDegree,
    QuarterFocus,
    RCSProfile,
    WeekHypothesis,
    normalize_rcs_dict,
)
from onboarding_ctas import render_onboarding_ctas
from planner import plan_horizon
from platform_knowledge import _DEFAULT_PLATFORM_URL, fetch_card_content as fetch_platform_card
from work_section import render_work_section
from llm_backends import GenerationContext, PromptSpec, generate as llm_generate

logger = logging.getLogger(__name__)

# Source authority order: lower value = higher priority. Only matters in conflict — an
# offline user has no profile.platform.yaml to conflict with, so this never runs for them.
# A self-reported stage is legitimate on its own (DP.D.252); this order is about
# freshness, not legitimacy — computed_from_events wins by default because an unmarked
# local edit is more often stale than deliberate. A "manual_override" (with
# override_reason + override_at, see _merge_rcs) is the only way to beat it — including
# when the platform trail itself has gone stale.
_SOURCE_PRIORITY: dict[str, int] = {
    "manual_override": 0,
    "computed_from_events": 1,
    "manual": 2,
    "diagnostic_session": 3,
    "unknown": 4,
}
_PRIORITY_TO_SOURCE = {v: k for k, v in _SOURCE_PRIORITY.items()}

# RCS slots that participate in per-field merge (source is computed separately)
_RCS_MERGE_SLOTS = ("W", "M1", "M2", "M3", "M4", "IT", "A", "bottleneck", "stage_derived", "confidence")

_GENERATOR_DIR = os.path.dirname(os.path.abspath(__file__))
DEFAULT_PROMPT_PATH = os.path.join(_GENERATOR_DIR, "prompt.md")
DEFAULT_POLICY_PATH = os.path.join(_GENERATOR_DIR, "policies", "default.yaml")


# ---------------------------------------------------------------------------
# Config / profile / policy loading — all tolerant of missing files
# ---------------------------------------------------------------------------

def _read_yaml(path: str) -> dict:
    """Reads a YAML file. A syntactically broken file gets the same partial-tolerance
    treatment as a missing one: log + empty, not a crash."""
    try:
        with open(path, encoding="utf-8") as fh:
            return yaml.safe_load(fh) or {}
    except yaml.YAMLError as e:
        logger.error("malformed YAML at %r: %s — treating as empty", path, e)
        return {}


def load_config(config_path: str | None) -> dict:
    """Loads guide-kit.config.yaml. A missing file is not an error: all fields are optional."""
    if not config_path or not os.path.isfile(config_path):
        logger.info("no config at %r — using defaults (no curriculum, anthropic backend)", config_path)
        return {}
    return _read_yaml(config_path)


def load_policy(policy_path: str | None) -> dict:
    """Loads the hard-fail policy.

    Unlike config/profile, a missing file here is NOT a safe default: an empty
    policy would mean "no required slots", so the gate would let any result through.
    An explicit error is better than silently disabling the no-invented-facts guard.
    """
    path = policy_path or DEFAULT_POLICY_PATH
    if not os.path.isfile(path):
        raise FileNotFoundError(
            f"hard-fail policy not found at {path!r} — refusing to run with an implicit "
            f"empty policy (that would silently disable the no-invented-facts gate)"
        )
    return _read_yaml(path)


def load_profile(profile_path: str) -> dict:
    """Tolerant of a missing/partial profile — an empty profile is a valid cold-start state."""
    if not os.path.isfile(profile_path):
        logger.info("no profile at %r — cold start (empty profile)", profile_path)
        return {}
    return _read_yaml(profile_path)


def _merge_rcs(declared_rcs: dict, overlay_rcs: dict) -> dict:
    """Per-field merge of declared and platform overlay RCS dicts.

    Priority: manual_override (accountable — requires override_reason + override_at) >
    computed_from_events > manual > diagnostic_session. A missing or unrecognized
    declared source is 'unknown' (lowest priority) — it does not beat platform data.
    Overlay never deletes a declared key. Final source = max authority of used fields.
    """
    declared_source = declared_rcs.get("source") or ""
    if not declared_source:
        print(
            "WARNING: declared rcs.source is missing — treating as 'unknown' (lowest priority)",
            file=sys.stderr,
        )
        declared_source = "unknown"
    elif declared_source == "manual_override" and not (
        declared_rcs.get("override_reason") and declared_rcs.get("override_at")
    ):
        print(
            "WARNING: rcs.source is 'manual_override' but override_reason/override_at is "
            "missing — treating as plain 'manual' (an unaccountable override doesn't count)",
            file=sys.stderr,
        )
        declared_source = "manual"

    overlay_source = overlay_rcs.get("source", "computed_from_events")
    declared_pri = _SOURCE_PRIORITY.get(declared_source, _SOURCE_PRIORITY["unknown"])
    overlay_pri = _SOURCE_PRIORITY.get(overlay_source, _SOURCE_PRIORITY["computed_from_events"])

    merged = dict(declared_rcs)
    declared_merged = False
    overlay_merged = False

    for slot in _RCS_MERGE_SLOTS:
        in_declared = slot in declared_rcs
        in_overlay = slot in overlay_rcs

        if not in_overlay:
            if in_declared:
                declared_merged = True
            continue

        if not in_declared:
            merged[slot] = overlay_rcs[slot]
            overlay_merged = True
            logger.info("rcs.%s filled from platform: %r", slot, overlay_rcs[slot])
            continue

        # Both present — lower priority number wins; tie goes to declared
        if declared_pri <= overlay_pri:
            declared_merged = True
            logger.info(
                "rcs.%s overlay ignored (declared %s >= platform %s): declared=%r",
                slot, declared_source, overlay_source, declared_rcs[slot],
            )
        else:
            merged[slot] = overlay_rcs[slot]
            overlay_merged = True
            logger.info(
                "rcs.%s overridden by platform: %r → %r",
                slot, declared_rcs.get(slot), overlay_rcs[slot],
            )

    # Final source = max authority (min priority number) of fields actually written
    if declared_merged and overlay_merged:
        min_pri = min(declared_pri, overlay_pri)
    elif overlay_merged:
        min_pri = overlay_pri
    elif declared_merged:
        min_pri = declared_pri
    else:
        min_pri = declared_pri
    merged["source"] = _PRIORITY_TO_SOURCE.get(min_pri, declared_source)

    return merged


def _merge_degree(declared: dict, overlay: dict) -> dict:
    """Merge declared and platform-derived qualification_degree.

    Unlike rcs.stage, degree is never behaviorally computed and never freely
    self-assigned — the methodological council is the only source of truth
    (DP.D.252). Platform data wins whenever present, no priority table needed;
    declared.use_declared=true is the one explicit, auditable escape hatch for
    a stale platform record (mirrors _merge_rcs's manual_override, but simpler
    since degree has no "freshness by computation" case to weigh against).
    """
    if not overlay.get("degree"):
        return declared
    if declared.get("use_declared"):
        logger.info("qualification_degree overlay ignored (use_declared=true)")
        return declared

    merged = dict(declared)
    merged["degree"] = overlay["degree"]
    merged["source"] = "platform"
    if overlay.get("certified_at"):
        merged["certified_at"] = overlay["certified_at"]
    logger.info("qualification_degree filled from platform: %r", overlay["degree"])
    return merged


def apply_platform_overlay(profile: dict, profile_path: str) -> dict:
    """Merge profile.platform.yaml into the profile dict if it exists.

    Per-field merge on rcs and mastery_by_area, whole-block merge on
    qualification_degree. Returns a new dict; does not mutate the caller's
    profile. A missing overlay file is not an error.
    """
    overlay_path = os.path.join(
        os.path.dirname(os.path.abspath(profile_path)), "profile.platform.yaml"
    )
    if not os.path.isfile(overlay_path):
        return profile

    overlay = _read_yaml(overlay_path)
    if not overlay:
        return profile

    profile = dict(profile)

    overlay_rcs = overlay.get("rcs") or {}
    if overlay_rcs:
        declared_rcs_raw = profile.get("rcs") or {}
        declared_rcs = normalize_rcs_dict(declared_rcs_raw)
        overlay_rcs_compact = dict(overlay_rcs)  # overlay already uses compact keys
        profile["rcs"] = _merge_rcs(declared_rcs, overlay_rcs_compact)

    overlay_mastery = overlay.get("mastery_by_area") or {}
    if overlay_mastery:
        declared_mastery = dict(profile.get("mastery_by_area") or {})
        for k, v in overlay_mastery.items():
            if k not in declared_mastery:
                declared_mastery[k] = v
                logger.info("mastery_by_area.%s filled from platform: %r", k, v)
            else:
                logger.info("mastery_by_area.%s overlay ignored (declared present)", k)
        profile["mastery_by_area"] = declared_mastery

    overlay_degree = overlay.get("qualification_degree") or {}
    if overlay_degree:
        declared_degree = dict(profile.get("qualification_degree") or {})
        profile["qualification_degree"] = _merge_degree(declared_degree, overlay_degree)

    return profile


def load_card_content(
    element_id: str | None,
    cards_path: str | None,
    platform_knowledge_on: bool = False,
    platform_url: str | None = None,
) -> dict | None:
    """Looks up a card by element_id under the local cards_path first (demo catalog /
    user-supplied cards). Local miss + platform_knowledge_on → falls back to a live
    query against the platform's public MCP layer (DP.SC.060 scenario 1) instead of
    leaving the slot empty. No path/file/broken JSON/unreachable platform → None
    (honestly) — the caller (generate_daily_plan) already treats a None card_content
    as an llm-assisted gap, not a hard failure.
    """
    if not element_id:
        return None

    if cards_path:
        candidate = os.path.join(cards_path, f"{element_id}.json")
        if os.path.isfile(candidate):
            try:
                with open(candidate, encoding="utf-8") as fh:
                    return json.load(fh)
            except json.JSONDecodeError as e:
                logger.error("malformed card content at %r: %s — treating as absent", candidate, e)

    if not platform_knowledge_on:
        return None

    found = fetch_platform_card(element_id, platform_url or _DEFAULT_PLATFORM_URL)
    if found:
        logger.info("card content for %s fetched from platform-mcp", element_id)
    return found


# ---------------------------------------------------------------------------
# profile.yaml → HorizonContext
# ---------------------------------------------------------------------------

def _from_dict_safe(cls, d: dict):
    """Build a dataclass from a dict, ignoring unknown keys — a partial profile must not crash."""
    known = {f.name for f in dataclasses.fields(cls)}
    return cls(**{k: v for k, v in d.items() if k in known})


def _parse_domain_traits(raw) -> list[DomainTrait]:
    """Structurally broken entries (not a dict, missing 'characteristic'/'domain') get
    the same honest-degradation treatment as the rest of this file (see _read_yaml):
    log + skip that entry, don't crash the whole profile. An invalid *status*
    (a typo like 'Measured') stays loud — DomainTrait.__post_init__'s ValueError
    is intentional (Ф5b: a misspelled status must not silently pass as active).

    A non-list `domain_traits` (e.g. a number or a bare dict — a plausible
    YAML authoring mistake) gets the same treatment at the container level,
    not just per-entry: one clear log, not a crash or per-character/per-key
    junk from iterating something that isn't a list of records."""
    if not isinstance(raw, list):
        logger.error("domain_traits is not a list (got %s) — treating as empty", type(raw).__name__)
        return []
    traits = []
    for entry in raw:
        try:
            traits.append(DomainTrait.from_dict(entry))
        except (TypeError, KeyError) as e:
            logger.error("malformed domain_traits entry %r: %s — skipping", entry, e)
    return traits


def build_horizon_context(profile: dict) -> HorizonContext:
    """profile.yaml (2.1-2.4 axes) → HorizonContext. An empty profile → RCSProfile() + empty horizons."""
    rcs_dict = profile.get("rcs") or {}
    rcs = RCSProfile.from_dict(rcs_dict) if rcs_dict else RCSProfile()
    degree_dict = profile.get("qualification_degree") or {}
    degree = QualificationDegree.from_dict(degree_dict) if degree_dict else QualificationDegree()
    trigger_dict = profile.get("trigger") or {}
    trigger = _from_dict_safe(OrchestratorTrigger, trigger_dict) if trigger_dict else OrchestratorTrigger()

    return HorizonContext(
        rcs=rcs,
        qualification_degree=degree,
        trigger=trigger,
        quarter=_from_dict_safe(QuarterFocus, profile.get("quarter") or {}),
        month=_from_dict_safe(MonthThemes, profile.get("month") or {}),
        week=_from_dict_safe(WeekHypothesis, profile.get("week") or {}),
        day=_from_dict_safe(DayEvents, profile.get("day") or {}),
        artifacts=_from_dict_safe(ArtifactsSummary, profile.get("artifacts") or {}),
        mastery_by_area=profile.get("mastery_by_area") or {},
        domain_traits=_parse_domain_traits(profile.get("domain_traits") or []),
        pilot_reflection=profile.get("pilot_reflection", ""),
        reflection_learned=profile.get("reflection_learned") or [],
        tomorrow_intention=profile.get("tomorrow_intention", ""),
    )


# ---------------------------------------------------------------------------
# decision_log + hard-fail gate
# ---------------------------------------------------------------------------

def build_decision_log(planner_result: dict, llm_ok: bool, timestamp: str) -> list[dict]:
    """Per-slot provenance log: where each required fact came from.

    confidence is present on EVERY entry, not just llm-assisted ones (the Phase 1
    §2 spec shows it on the direct example too — a uniform schema, not an
    optional field). For derived — always 1.0: bottleneck-first in planner.py
    either finds a specific element deterministically, or returns None (in which
    case it's already llm-assisted below); there's no such thing as partial
    confidence here.
    """
    element_id = planner_result["plan_skeleton"]["element_id"]
    entries = [
        {
            "slot": "plan_day.element_choice",
            "source_file": "planner.py",
            "source_field": planner_result["decision_log"].get("element_choice", ""),
            "extraction_method": "derived" if element_id else "llm-assisted",
            "confidence": 1.0 if element_id else None,  # llm-assisted: policy will fill this in below
            "timestamp": timestamp,
        },
    ]
    if llm_ok:
        entries.append(
            {
                "slot": "narrative",
                "source_file": "llm_backend",
                "source_field": "narrative",
                "extraction_method": "llm-assisted",
                "confidence": None,  # policy will fill this in inside apply_hard_fail_gate
                "timestamp": timestamp,
            }
        )
    return entries


def apply_hard_fail_gate(decision_log: list[dict], policy: dict) -> tuple[bool, str]:
    """Checks ONLY provenance (required_attribution_slots). Returns (passed, reason).

    This is the first of two checks in the pipeline, not the only one: whether
    the content itself (narrative/plan_day) is non-empty is a separate check
    right after this function is called, in generate_daily_plan (an independent
    review finding — valid JSON with empty content could pass THIS function
    since attribution was fine).

    confidence for extraction_method="llm-assisted" is a constant taken from the
    policy (set by the policy author ahead of time), not computed here and not
    self-assessed by the LLM: otherwise the confidence threshold would pass
    trivially and the hard-fail would become decoration (found during the
    peer-session, turn 3).
    """
    by_slot = {entry["slot"]: entry for entry in decision_log}
    for required in policy.get("required_attribution_slots", []):
        slot = required.get("slot")
        if not slot:
            return False, f"policy has a required_attribution_slots entry with no 'slot' key: {required!r}"
        accepted = set(required.get("accepted_methods", ["direct", "derived"]))
        entry = by_slot.get(slot)
        if entry is None:
            return False, f"required slot {slot!r} has no decision_log entry — adapter produced nothing for it"
        method = entry.get("extraction_method")
        if method not in accepted:
            return False, f"required slot {slot!r}: extraction_method={method!r} not in accepted {sorted(accepted)}"
        if method == "llm-assisted":
            confidence = required.get("llm_assisted_confidence")
            if confidence is None:
                return False, (
                    f"policy allows llm-assisted for slot {slot!r} but sets no "
                    f"llm_assisted_confidence — refusing to guess a value"
                )
            entry["confidence"] = confidence
    return True, ""


# ---------------------------------------------------------------------------
# Markdown rendering
# ---------------------------------------------------------------------------

def render_markdown(
    narrative: str,
    plan_day: list[dict],
    decision_log: list[dict],
    onboarding_appendix: str = "",
    work_section_markdown: str = "",
    applied_note: str = "",
) -> str:
    """work_section_markdown sits in the body, after the visible
    plan and before onboarding_appendix — unlike the appendix, it DOES carry
    provenance (each listed item has a decision_log entry), so it belongs among
    the guide's regular content, not after it.

    applied_note (WP-483 Ф5b) is the applied-mastery mini-section text, present
    only when plan_skeleton.applied_section was non-null — it sits right after
    the assignment list, framed as a side practice (WP-495 Ф3: "дополняет
    мыслительный урок, не заменяет"), never merged into the main narrative.

    onboarding_appendix sits after everything else and before
    the decision_log comment — it carries no provenance and is outside the
    hard-fail gate, so it does not belong inside decision_log itself."""
    lines = ["# План на сегодня", "", narrative, "", "## Задания"]
    for item in plan_day:
        label = item.get("label") or item.get("element_id") or "?"
        tomatoes = item.get("tomatoes", 1)
        rationale = item.get("rationale", "")
        lines.append(f"- **{label}** ({tomatoes} помидорок) — {rationale}")
    if applied_note:
        lines += ["", "## Прикладная практика", "", applied_note]
    if work_section_markdown:
        lines += ["", work_section_markdown]
    if onboarding_appendix:
        lines += ["", onboarding_appendix]
    lines += ["", "<!-- decision_log:", json.dumps(decision_log, ensure_ascii=False, indent=2), "-->"]
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Orchestration
# ---------------------------------------------------------------------------

@dataclass
class GuideResult:
    ok: bool
    markdown: str | None = None
    diagnostic: dict[str, Any] | None = None


def generate_daily_plan(
    profile_path: str,
    config_path: str | None = None,
    policy_path: str | None = None,
    seed: int | None = None,
) -> GuideResult:
    """profile.yaml → planner → LLM backend → hard-fail gate → markdown or diagnostic.

    ok=True  → .markdown — the finished text.
    ok=False → .diagnostic — reason for the failure (never a silent empty result).
    """
    config = load_config(config_path)
    policy = load_policy(policy_path)
    backend_name = config.get("llm_backend", "anthropic")
    logger.info("generate_daily_plan: profile=%r backend=%r", profile_path, backend_name)

    curriculum_path = config.get("curriculum_path")
    if curriculum_path:
        os.environ["GUIDE_KIT_CURRICULUM_PATH"] = curriculum_path

    profile = load_profile(profile_path)

    personal_export_on = str(config.get("personal_export", "on")).lower() != "off"
    if personal_export_on:
        profile = apply_platform_overlay(profile, profile_path)

    ctx = build_horizon_context(profile)
    planner_result = plan_horizon(ctx, seed=seed)

    element_id = planner_result["plan_skeleton"]["element_id"]
    platform_knowledge_on = str(config.get("platform_knowledge", "off")).lower() == "on"
    card_content = load_card_content(
        element_id,
        config.get("cards_path"),
        platform_knowledge_on=platform_knowledge_on,
        platform_url=config.get("platform_knowledge_url"),
    )
    llm_input = dict(planner_result)
    if card_content:
        llm_input["card_content"] = card_content

    with open(DEFAULT_PROMPT_PATH, encoding="utf-8") as fh:
        system_prompt = fh.read()

    gen_context = GenerationContext(
        backend=backend_name,
        base_url=config.get("llm_base_url"),
        api_key=config.get("llm_api_key") or os.environ.get("GUIDE_KIT_LLM_API_KEY"),
        model=config.get("llm_model"),
    )
    llm_result = llm_generate(PromptSpec(system=system_prompt, user_json=llm_input), gen_context)

    timestamp = datetime.now(timezone.utc).isoformat()
    decision_log = build_decision_log(planner_result, llm_ok=llm_result.ok, timestamp=timestamp)

    # Rendered and merged into decision_log before the hard-fail gate runs (not
    # after): apply_hard_fail_gate's by_slot lookup only sees entries already in
    # decision_log at call time — a future policy requiring the "work_section"
    # slot would otherwise always fail (found during review).
    work_section_markdown, work_section_log = render_work_section(config, config.get("base_path") or ".")
    decision_log.extend(work_section_log)

    if not llm_result.ok:
        logger.error("LLM backend %r failed: %s", backend_name, llm_result.error)
        return GuideResult(
            ok=False,
            diagnostic={
                "reason": f"LLM backend вызов не удался: {llm_result.error}",
                "backend": backend_name,
                "decision_log": decision_log,
                "timestamp": timestamp,
            },
        )

    passed, reason = apply_hard_fail_gate(decision_log, policy)
    if not passed:
        logger.error("hard-fail gate: %s", reason)
        return GuideResult(
            ok=False,
            diagnostic={"reason": reason, "decision_log": decision_log, "timestamp": timestamp},
        )

    try:
        llm_output = json.loads(llm_result.text)
    except json.JSONDecodeError as e:
        logger.error("LLM output is not valid JSON: %s", e)
        return GuideResult(
            ok=False,
            diagnostic={
                "reason": f"LLM вернул невалидный JSON: {e}",
                "raw_text_head": llm_result.text[:500],
                "decision_log": decision_log,
                "timestamp": timestamp,
            },
        )

    narrative = llm_output.get("narrative", "")
    plan_day = llm_output.get("plan_day", [])
    applied_note_raw = llm_output.get("applied_note")
    applied_note = applied_note_raw if isinstance(applied_note_raw, str) else ""
    if not narrative or not plan_day:
        # decision_log only checks the PROVENANCE of a fact, not whether the LLM
        # actually returned something — valid JSON with an empty plan_day would
        # have passed the gate silently (found during review).
        logger.error("LLM returned valid JSON but empty content: narrative=%r plan_day=%r", bool(narrative), plan_day)
        return GuideResult(
            ok=False,
            diagnostic={
                "reason": "LLM вернул валидный JSON, но без содержимого (narrative и/или plan_day пусты) — руководство с пустым разделом не публикуется",
                "narrative_empty": not narrative,
                "plan_day_count": len(plan_day),
                "decision_log": decision_log,
                "timestamp": timestamp,
            },
        )

    onboarding_appendix = render_onboarding_ctas(config)
    markdown = render_markdown(narrative, plan_day, decision_log, onboarding_appendix, work_section_markdown, applied_note)
    return GuideResult(ok=True, markdown=markdown)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    import argparse

    logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"), format="%(asctime)s %(levelname)s %(name)s %(message)s")

    parser = argparse.ArgumentParser(description="guide-kit generator adapter")
    parser.add_argument("--profile", default="profile.yaml")
    parser.add_argument("--config", default="guide-kit.config.yaml")
    parser.add_argument("--policy", default=None)
    parser.add_argument("--out", default=None, help="куда писать результат; по умолчанию — stdout")
    parser.add_argument("--seed", type=int, default=None)
    args = parser.parse_args()

    result = generate_daily_plan(args.profile, args.config, args.policy, seed=args.seed)
    if result.ok:
        output = result.markdown
    else:
        # diagnostic YAML — never a silent empty result (hard-fail policy)
        output = "---\n" + yaml.safe_dump(result.diagnostic, allow_unicode=True, sort_keys=False) + "---\n"

    if args.out:
        with open(args.out, "w", encoding="utf-8") as fh:
            fh.write(output)
    else:
        print(output)

    sys.exit(0 if result.ok else 1)
