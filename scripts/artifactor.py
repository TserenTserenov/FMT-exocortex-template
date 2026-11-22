#!/usr/bin/env python3
# see DP.SC.160, DP.ROLE.058
"""
Keyword-based task classifier for IWE Artifactor skill.

Exit codes:
  0 — keyword match, JSON on stdout (schema_version 3, WP-575 Phase2)
  1 — INSUFFICIENT_INPUT (< 5 words)
  2 — NO_KEYWORD_MATCH (needs LLM fallback)
  3 — CONFIG_ERROR (PACK-digital-platform is installed, but result-kinds-registry.yaml
      is not readable in it/empty/corrupted — fail-closed, not a silent fallback to schema 1.
      If PACK-digital-platform is not installed at all — issue #1231, expected behavior for
      a standard template installation — this is not a CONFIG_ERROR, but rather result_kind_resolution:
      "unresolved" with expected_result_kind: None)

expected_result_kind (WP-481 Phase7, peer session consensus-session
2026-08-05-14-codex-wp481-f7-impl): discriminator of the expected kind-kind of result
from the open registry PACK-digital-platform/pack/digital-platform/
result-kinds-registry.yaml. Map task_type → kind_id — third element
of the tuple in KEYWORD_MAP (not a separate parallel dictionary, so that it does not diverge
from it), aligned line by line (not derived from class — one verification_class
maps to multiple kind-s). Absence of a matching kind-in the registry
(verified on a real case: spec_writing/«specification scenarios» is not equal to
MethodDescription) → result_kind_resolution: "unresolved", NOT a substitution with
nearest kind- (anti-leak into supertype, the same principle, as in the registry).
peer_session — intentionally "deferred-to-session": meta-trigger for process start,
not a request for a specific result (resolved at Decision Gate inside the session).

result_type (WP-575 Phase2, hard-distinctions.md №36, peer session consensus-session
2026-09-11-14-wp575-artefaktor-tip with Codex): "system" | "episteme" | "unresolved" —
Executor (agent/script/service — the acting entity) vs Information object
(document/knowledge/rule — the readable entity). Independent axis from kind_id — fifth
element of the tuple KEYWORD_MAP, curated manually according to the meaning of EACH ENTRY
(one task_type can appear with different result_type for different keyword result_type for different keyword
entries -- for example migration and plan implementation both yield task_type — for example "migration" and "plan implementation" both yield task_type
wp_implement, but result_type "system" and "unresolved" respectively, i.e.
the result depends on the specific phrase, not only on task_type). NOT
is derived from kind_id runtime-computation (tuple kind_id/task_type/class
is assigned SIMULTANEOUSLY in the same record, so deriving from it would violate
requirement «before name and class»; check: WorkDone-records diverge by
result_type — day_open=episteme, bot_fix=system — meaning the axes do not coincide).
"unresolved" — the type is not obvious from the meaning of the task_type (example: wp_finish/
wp_close/wp_implement from "migration" exception — there the result can be
both code, and a document depending on the specific WP) — forces clarification
from the pilot at WP Gate, is not guessed (the same principle, as hypothesis_relation:
"unclassified").
"""

import os
import sys
import json
import re

# Registry — sibling-repository PACK-digital-platform (see. the same pattern
# resolution in DS-strategy/scripts/check-result-kind.py). IWE_ROOT: explicit env
# override, otherwise the parent of this file two levels above scripts/
# (standard layout {{WORKSPACE_DIR}}/scripts/artifactor.py alongside {{WORKSPACE_DIR}}/PACK-digital-platform).
PACK_ROOT_REL = "PACK-digital-platform"
PACK_REGISTRY_REL = os.path.join(
    PACK_ROOT_REL, "pack", "digital-platform", "result-kinds-registry.yaml"
)
KIND_ID_LINE_RE = re.compile(r"^\s+-\s+kind_id:\s*(\S+)\s*$")


class RegistryPackMissing(Exception):
    """PACK-digital-platform is not installed itself — issue #1231: authored Pack not
    is not part of the template, so this is the normal state of a standard installation, not corruption., this is the normal state of a standard installation, not corruption."""


def resolve_iwe_root():
    return os.environ.get("IWE_ROOT") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def resolve_registry_path():
    return os.path.join(resolve_iwe_root(), PACK_REGISTRY_REL)


def load_registry_kind_ids():
    """Line-based, stdlib-only extraction of a set of kind_id (without gate_ready —
    that is the responsibility of /verify, not the classifier). Returns set() or None on
    read error/corruption of the file (the calling code decides, CONFIG_ERROR this is or
    not). Raises RegistryPackMissing, if PACK-digital-platform entirely
    is not installed — this is a case distinct from corruption (issue #1231): Pack
    is authored and is not part of the template, a regular user does not have it."""
    path = resolve_registry_path()
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.readlines()
    except FileNotFoundError:
        pack_root = os.path.join(resolve_iwe_root(), PACK_ROOT_REL)
        if not os.path.isdir(pack_root):
            raise RegistryPackMissing(pack_root) from None
        return None  # Pack is installed, but the registry file is missing from it — corruption, CONFIG_ERROR
    except OSError:
        return None
    ids = {m.group(1) for line in lines if (m := KIND_ID_LINE_RE.match(line))}
    return ids or None

# Third element — expected kind_id (WP-481 Phase7), fourth — name
# artifact, fifth — result_type (WP-575 Phase2: "system" | "episteme" |
# "unresolved", see. module docstring). All values live in one map:
# separate parallel dictionaries would silently diverge from routing.
# None/"unresolved" + entry in SPECIAL_RESOLUTION — for intentional exceptions
# (peer_session, spec_writing, and entries with an ambiguous result_type), not
# «forgot to fill in».
KEYWORD_MAP = {
    # trivial — WorkDone: deterministic trace of a completed protocol
    "day-open": ("day_open", "trivial", "WorkDone", "Day plan", "episteme"),
    "day open": ("day_open", "trivial", "WorkDone", "Day plan", "episteme"),
    "open the day": ("day_open", "trivial", "WorkDone", "Day plan", "episteme"),
    "week-close": ("week_close", "trivial", "WorkDone", "Weekly summary", "episteme"),
    "week close": ("week_close", "trivial", "WorkDone", "Weekly summary", "episteme"),
    "close the week": ("week_close", "trivial", "WorkDone", "Weekly summary", "episteme"),
    "month-close": ("month_close", "trivial", "WorkDone", "Monthly summary", "episteme"),
    "peer-sessi": ("peer_session", "trivial", None, "Peer session report-session", "unresolved"),  # stem matches «peer-session/-ii/-iu/-iei»; SPECIAL_RESOLUTION: deferred-to-session; result_type also unknown until Decision Gate inside the session
    "peer sessi": ("peer_session", "trivial", None, "Peer session report-session", "unresolved"),
    # closed-loop
    "bot crashed": ("bot_fix", "closed-loop", "WorkDone", "Bot", "system"),
    "bot error stem": ("bot_fix", "closed-loop", "WorkDone", "Bot", "system"),     # matches «error» and «errors»
    "fixes": ("bug_fix", "closed-loop", "WorkDone", "Code patch", "system"),
    "resolve": ("bug_fix", "closed-loop", "WorkDone", "Code patch", "system"),
    "finish WP": ("wp_finish", "closed-loop", "WorkDone", "WP Phase files", "unresolved"),  # result depends on the specific WP — code or document
    "WP loose ends": ("wp_finish", "closed-loop", "WorkDone", "WP Phase files", "unresolved"),
    "close WP": ("wp_close", "closed-loop", "WorkDone", "WP closure report", "unresolved"),
    "hand off to Andrei": ("wp_close", "closed-loop", "WorkDone", "WP files", "unresolved"),
    "actualization wp": ("wp_actualize", "closed-loop", "WorkDone", "WP card", "episteme"),
    "WP review": ("code_review", "closed-loop", "Episteme", "Review report", "episteme"),
    "work review": ("code_review", "closed-loop", "Episteme", "Review report", "episteme"),
    "breakdown ke": ("ke_review", "closed-loop", "ChoiceResult", "Decision on knowledge candidates", "episteme"),  # R15 accept/reject/defer, not a graph claim's
    "triage": ("wp_triage", "closed-loop", "ChoiceResult", "WP triage decision", "episteme"),
    "plan implementation": ("wp_implement", "closed-loop", "WorkDone", "Work packages from the plan", "unresolved"),  # plan already existed; WPs are produced, with code or a document
    "migration": ("wp_implement", "closed-loop", "WorkDone", "Data in the target contour", "system"),
    "create pack": ("pack_create", "closed-loop", "Episteme", "Passport Pack", "episteme"),
    "new pack": ("pack_create", "closed-loop", "Episteme", "Passport Pack", "episteme"),
    "secrets rotation": ("ops_security", "closed-loop", "WorkDone", "Secrets in the vault", "system"),
    "fmt remaining": ("fmt_deploy", "closed-loop", "WorkDone", "FMT template files FMT", "system"),
    # open-loop
    "diagnostics": ("diagnosis", "open-loop", "Episteme", "Diagnostics report", "episteme"),
    "topics for post": ("content_plan", "open-loop", "ChoiceResult", "Publication plan", "episteme"),   # matches «post» and «posts»; topic selection+audience+day, not just a list
    "topics, ideas": ("content_plan", "open-loop", "ChoiceResult", "Publication plan", "episteme"),
    "topics ideas": ("content_plan", "open-loop", "ChoiceResult", "Publication plan", "episteme"),
    "scenarios spec": ("spec_writing", "open-loop", None, "Scenarios assignment", "episteme"),  # SPECIAL_RESOLUTION: unresolved kind — none of the 6 kind-kinds do not fit (found on WP-421); result_type is unambiguous in this case (document)
    "strateg": ("strategy", "open-loop", "ChoiceResult", "Strategy document", "episteme"),
    # problem-framing
    "come up with": ("design", "problem-framing", "ProblemCard", "Problem card", "episteme"),
    "some-thing with": ("design", "problem-framing", "ProblemCard", "Problem card", "episteme"),
    "need some-thing": ("design", "problem-framing", "ProblemCard", "Problem card", "episteme"),
}

VALID_RESULT_TYPES = ("system", "episteme", "unresolved")
for _kw, _entry in KEYWORD_MAP.items():
    if _entry[4] not in VALID_RESULT_TYPES:
        raise AssertionError(f"KEYWORD_MAP[{_kw!r}]: invalid result_type {_entry[4]!r}")
del _kw, _entry

# task_type → why expected_result_kind = None. The only legitimate
# justification for None — one of these two reasons, not «forgotten to resolve».
SPECIAL_RESOLUTION = {
    "peer_session": "deferred-to-session",  # meta-process start trigger, kind is resolved at the Decision Gate inside the session, kind resolves to Decision Gate inside the session
    "spec_writing": "unresolved",           # none of the 6 kind-kinds cover it — do not substitute the nearest (anti-leak into supertype)
}

BUDGET_BY_CLASS = {
    "trivial": "~0.5h",
    "closed-loop": "~2h",
    "open-loop": "~3h",
    "problem-framing": "?",
}


def classify(
    text: str,
) -> tuple[str, str, str | None, str, str] | tuple[None, None, None, None, None]:
    """Return (task_type, cls, kind_id, artifact, result_type) or five None values.

    kind_id may be None (see SPECIAL_RESOLUTION) even when task_type matched.
    """
    lower = text.lower()
    for kw, (task_type, cls, kind_id, artifact, result_type) in KEYWORD_MAP.items():
        if kw in lower:
            return task_type, cls, kind_id, artifact, result_type
    return None, None, None, None, None


def resolve_result_kind(task_type: str, kind_id: str | None) -> tuple[str | None, str]:
    """Validate kind_id kind_id by membership in the live registry (catches drift of KEYWORD_MAP KEYWORD_MAP
    vs registry, does not rely solely on hardcoded values). Returns (expected_result_kind,
    result_kind_resolution). PACK-digital-platform is not installed (issue #1231,
    normal for a standard template installation) → result_kind_resolution: "unresolved".
    Pack is installed, but the registry in it is unreadable/empty/corrupted → CONFIG_ERROR
    (exit 3), not a silent fallback to schema 1 — the same fail-closed principle, as in
    check-result-kind.py."""
    if kind_id is None:
        reason = SPECIAL_RESOLUTION.get(task_type)
        if reason is None:
            raise AssertionError(f"KEYWORD_MAP: {task_type!r} has kind_id=None without an entry in SPECIAL_RESOLUTION")
        return None, reason

    try:
        registry_ids = load_registry_kind_ids()
    except RegistryPackMissing as exc:
        print(
            f"WARNING: PACK-digital-platform is not installed ({exc}) — "
            "expected_result_kind cannot be resolved, result_kind_resolution=unresolved",
            file=sys.stderr,
        )
        return None, "unresolved"
    if registry_ids is None:
        print(
            f"CONFIG_ERROR: registry is not readable at {resolve_registry_path()} "
            f"(IWE_ROOT={os.environ.get('IWE_ROOT') or '<derived>'})",
            file=sys.stderr,
        )
        sys.exit(3)
    if kind_id not in registry_ids:
        print(
            f"CONFIG_ERROR: KEYWORD_MAP references kind_id {kind_id!r}, "
            f"which does not exist in the live registry ({sorted(registry_ids)}) — drift "
            f"artifactor.py vs result-kinds-registry.yaml",
            file=sys.stderr,
        )
        sys.exit(3)
    return kind_id, "static"


def main() -> None:
    if len(sys.argv) > 1:
        text = " ".join(sys.argv[1:])
    else:
        text = sys.stdin.read()

    text = text.strip()

    # Keyword check first — short protocol triggers (e.g. "day-open") must be recognised
    # before the length guard fires.
    task_type, cls, kind_id, artifact, result_type = classify(text)
    if task_type is not None:
        expected_result_kind, result_kind_resolution = resolve_result_kind(task_type, kind_id)
        result = {
            "task_type": task_type,
            "class": cls,
            "artifact": artifact,
            "budget_estimate": BUDGET_BY_CLASS.get(cls, "?"),
            "confidence": "high",
            "routing_tag": task_type,
            "resolution_path": "keyword",
            "schema_version": 3,
            "result_type": result_type,
            "expected_result_kind": expected_result_kind,
            "result_kind_resolution": result_kind_resolution,
            # Strategic link is not inferred from keywords: Artifactor
            # passes the mandatory question to WP Gate, and does not assign H-NNN.
            "hypothesis_relation": "unclassified",
        }
        print(json.dumps(result, ensure_ascii=False))
        sys.exit(0)

    if len(text.split()) < 5:
        print("INSUFFICIENT_INPUT")
        sys.exit(1)

    print("NO_KEYWORD_MATCH")
    sys.exit(2)


if __name__ == "__main__":
    main()
