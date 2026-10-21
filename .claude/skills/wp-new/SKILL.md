---
agents: single
argument-hint: '[WP title]'
browser_safe: false
description: Creates a new Work Product (WP) with atomic writes to 4 local locations
  (+ conditional post-step to an external tracker if connected). Use when a new task
  appears that is not in the week plan.
gates_enforced: []
gates_rationale: operational skill; WP Gate applicable only when creating a new WP,
  not for operational calls
gates_required: []
interaction: multi-step
layer: L1
name: wp-new
routing:
  deterministic: false
  executor: haiku
status: active
triggers:
  phrases: []
  slash:
  - /wp-new
version: 1.0.0
---

# Creating a New WP

New Work Product: $ARGUMENTS

---

## When to use

Creates a new Work Product (WP) with atomic writes to 4 local locations (+ conditional post-step to an external tracker if connected). Use when a new task appears that is not in the week plan.

## ⛔ BLOCKING RULE (Step 0): explicit user consent

**Creating a WP is an irreversible action** (writes to 4 local locations: REGISTRY/WeekPlan/Strategy/context-file; external tracker — conditional post-step, only when MCP is connected, issue #321). Rollback costs time and creates noise in the system. Therefore:

1. **Check first:** can the task be completed within an **existing open WP** (as a new phase, sub-task, or continuation)?
   - Open the current week's WeekPlan + WP-REGISTRY → find a WP with a similar scope.
   - If the task is an extension of an existing scope → **continue within that WP** (add Phase 2 / a new track / a context-file extension).
2. **If a new WP is objectively needed** (separate lifecycle, separate Artifact, does not fit within an existing one):
   - First perform result type classification and obtain a name per Step 1; this is preparation only — no new WP is written yet.
   - **Propose** the resulting title to the user: "This warrants a new WP #{N} `<title>`. Create it?"
   - **Wait for an explicit "yes" / "create it" / "ok"** before writing to 4 locations.
   - This request is legitimate (not a violation of P5 "do not ask questions") — **creating a WP = creating an artifact in the system**, which requires explicit user buy-in.
3. **Prohibited:**
   - Creating a WP "by analogy" / "because the task looks like new scope" / "to record a plan."
   - Creating a WP in response to the user's command "make a plan for X" — a plan can be a document within an existing WP.
   - Creating a WP "just in case" / "for transparency."

**This is an exception to Rule 1 of feedback_behaviour** (autonomy). Rule 1 prohibits asking permission for actions that already have sufficient context. Creating a WP does not: it requires explicit buy-in because (a) writing to 4 locations is irreversible without rollback, (b) it affects the week budget and Strategy mapping, (c) when an external tracker is connected, the WP is added there as well (visible to others).

**Violation log:** 26 Apr 2026 WP-270 — created a WP after the pilot said "let's make a new migration plan" without explicit consent. The plan was a separate document that could have been Phase 2 within WP-268. Rollback: WP-270 cancelled, plan moved to WP-268 §Phase 2.

---

## Algorithm

## Step 1. Information gathering

### Result type — before name and class (WP-575)

Call the `artifactor` Skill with a raw task description and save its JSON response. The call is mandatory for any task class, including trivial/closed-loop. Read `result_type` first, then use `artifact` for the name and `class` for Verification. `expected_result_kind` is a separate axis — do not derive the result type from it.

| `result_type` | Next action |
|---|---|
| `system` | Check applicability of IntegrationGate (`.claude/rules-lazy/integration-gate.md`): for a new tool/agent/Script/Service, record the promise → scenarios → Role → implementation. For a change to an existing system, state its current promise/scenario/Role and the boundaries of the change; do not create a new passport automatically. |
| `episteme` | Run the Routing Gate (`memory/routing-vocab.md`; if ambiguous — `memory/repo-type-rules.md`, DP.KR.001 §5) and record the target home for the document/knowledge. A system description is an information object even if the name contains "service" or "agent." |
| `unresolved`, field absent, or any other value | Before naming and registration, clarify with the pilot what the result will be: a working system or an information object. Repeat Artifactor with the refined request. Do not write a new WP until `system` or `episteme` is determined. Do not substitute the type based on the name, Verification class, or the nearest `expected_result_kind`. |

If both a system and its description are needed, explicitly distinguish the primary result from supporting documents; if the primary result is not determined, clarify it. The Routing Gate also applies to documents about a system — IntegrationGate does not override it. Use an answer the pilot has already given explicitly without asking again.

Save the original JSON for passing to `create-wp.sh` in Step 4; do not compose a replacement JSON manually. After creation, add the `result_type` field from this JSON to the card, plus a brief entry under "Artifact": the classification basis, the gate applied, and links to its result. The Script saves a checksum of the JSON but does not yet transfer `result_type` automatically or verify gate completion — the agent performs this write and check.

**Evidence for `system` at registration.** Under "Artifact," state the applicability of IntegrationGate. For a new system, record links to the already completed promise, scenarios, and Role, or the open phases preparing them; do not mark future documents as done. Registering the card does not mean IntegrationGate has been passed: implementation begins only after mandatory steps 1–3. For a change to an existing system where its promise does not change, record the basis for the IntegrationGate exclusion from `.claude/rules-lazy/integration-gate.md` and a link to the existing system; if the promise changes, update the promise, scenarios, and Role first.

**Changing the result after registration.** If the pilot explicitly changes the result (for example, orders only a description instead of a system), repeat Artifactor with the new assignment and re-apply the corresponding gate before continuing. Save the original JSON and the original `artifactor_result_sha256`; under "Artifact," add the pilot's decision, the previous and new type, a link and checksum of the new JSON, and the new route. Update the `result_type` field with the new classification result. If the agent only detects a discrepancy between plan and execution, report it to the pilot; this is not authorization to change the WP result or overwrite the original evidence independently.

Request or determine:
- **Title:** the artifact formulation (not the task formulation) from the saved Artifactor response above — do not formulate the title independently (WP-563, WP-7 Phase142). The saved file (e.g. `$STATE_DIR/artifactor-result-{slug}.json`) is passed to `create-wp.sh` in Step 4: the Script takes `title` from its `artifact` field and refuses if the file is missing or if a separately passed `--title` differs from it (Artifactor gate, see Step 4). A response of `INSUFFICIENT_INPUT` or `{"error": "INSUFFICIENT_INPUT"}` → request a more detailed description and repeat the call. Do not show the title to the pilot before result type classification is complete.
- **Pilot revision.** The pilot may correct the Artifactor formulation directly — in that case pass `--pilot-revision "reason"` together with the corrected `--title` in Step 4; without this flag, a `--title` that differs from the Artifactor result causes the Script to refuse, not a silent substitution.
- **Repo:** target Repository
- **Budget:** estimate in hours
- **Priority:** critical / high / medium / low
- **Monthly result:** (only for WPs ≥3h) which monthly result (R1, R2, …) is this linked to? Allowed values: R{N}, support, off-plan. Source-of-truth for mapping: `${IWE_GOVERNANCE_REPO:-DS-strategy}/docs/Strategy.md` → "WP → Results"
- **Completion criterion:** what the result must be
- **Stake — state transition (WP-457, WP-505):** an axis from `docs/state-axes-registry.yaml` (only `gate_ready`: permission/Trust, belonging/Readiness, engagement/Engagement, mastery/Competency) + a "from → to" formulation in one line; the subject of the transition is the platform user / pilot / team. **Mandatory** if the axis registry file exists — the Script will block creation without `--state`. If the file does not exist (typical installation) → skip.
- **Hypothesis link:** choose before starting the WP: `tests H-NNN`, `enables H-NNN`, `responds H-NNN`, `researches`, or `operational`. The first three require exactly one hypothesis; the last two require an explicit "—". The value `unclassified` is only allowed when creating a reversible draft and blocks starting work.

## Step 2. Numbering

Find the last WP number in `docs/WP-REGISTRY.md` → use the next sequential number. Integers only (74, 75…). Letter suffixes (73a, 73b) are prohibited.

## Step 3. Budget check

Read the current week budget from WeekPlan. Warn if it is exceeded.

## Step 4. Write — run `$IWE_SCRIPTS/create-wp.sh`

All steps below are automated by the Script `$IWE_SCRIPTS/create-wp.sh`. The Script writes to 4 locations:

1. **`inbox/WP-{N}/WP-{N}.md`** → context file (always a folder — WP-434, see INBOX-CONVENTION)
2. **`docs/WP-REGISTRY.md`** → new table row
3. **`current/WeekPlan W{N}…md`** → new row in the WP table
4. **`current/active-wp.md`** → rebuilt automatically (`build-active-wp.py`)

> **issue #280:** before this fix, the Script additionally created a stub `archive/wp-contexts/WP-{N}-{slug}.md` (Closing §stub). This stub is no longer created at registration — `close-wp.sh` creates the file itself when closing a WP; the canonical `git mv` path from `protocol-close.md` does not conflict with an existing file. Empty stubs found in `archive/wp-contexts/` with a date before this fix are a trace of the old behavior, not current practice.

**After the Script — the agent updates the card and calls MCP:**
- **WP card** — add `result_type: system|episteme` from the saved JSON and the routing evidence from Step 1 before confirming creation.
- **Linear issue** — call `mcp__claude_ai_linear__save_issue`:
  `title: "WP-{N} {Title}"`, `team: "{{LINEAR_TEAM_ID}}"` <!-- L3-author: teamId was here, replaced with {{LINEAR_TEAM_ID}} -->
  `priority: 2` (P2 → High), description: brief description of phases + path to context file
- **`docs/Strategy.md` § "WP → Results"** — only for WPs ≥3h. Pass `--result R{N}` to the Script for auto-insertion; without the flag — add manually.

**Script syntax:**
```bash
touch "${IWE_ROOT:-$HOME/IWE}/.claude/state/wp-consent-{N}"   # WP Gate — mandatory before running (same path that create-wp.sh checks — NOT ~/.claude, issue #556)
bash "$IWE_SCRIPTS/create-wp.sh" \
  --artifactor-result "$STATE_DIR/artifactor-result-{slug}.json" \  # result from Step 1, always required
  --budget 5h \
  --priority P2 \
  --verification-class open-loop \  # always required: trivial|closed-loop|open-loop|problem-framing
  --state "belonging (Readiness): pilot without X → with X" \  # required when docs/state-axes-registry.yaml exists
  --hypothesis H-101 \ # for tests/enables/responds
  --hypothesis-relation tests \ # tests|enables|responds|researches|operational
  --result R3 \        # optional; pass for auto-insertion into Strategy.md if ≥3h
  --repo "DS-repo"     # optional
  # --pilot-revision "reason" \    # only if the pilot corrected the Artifactor formulation
  # --title "Title" \              # same case — only together with --pilot-revision
```

**Artifactor gate (WP-7 Phase142, 2026-09-11) — mechanical, not just an instruction.** `create-wp.sh` refuses (exit 1) if `--artifactor-result` is not passed (except for explicit `--no-artifactor-check` — for tests/Scripts only, never for normal agent WP creation) or if the JSON is unreadable or missing the `artifact` field. The title is always taken from this file; a separately passed `--title` that differs without `--pilot-revision` also causes refusal. This closes the gap found in peer session 2026-09-11-04-wp7-f140-artifactor-process: previously nothing verified that the agent actually used the call result rather than writing its own.

**Context file template** (created by the Script automatically; the agent adds `result_type` and routing evidence per Step 1):
```markdown
---
wp: {N}
title: {title}
status: pending
priority: {P1-P5}
budget: {Nh}
created: {YYYY-MM-DD}
last_session: {YYYY-MM-DD}
related: []
verification_class: {trivial|closed-loop|open-loop|problem-framing}
state_transition: "{axis (English name): from → to}"
hypothesis: "{H-NNN or —}"
hypothesis_relation: "{tests|enables|responds|researches|operational}"
artifactor_resolution_path: {keyword|llm|bypassed}
artifactor_result_sha256: {sha256 of Artifactor result}
result_type: {system|episteme}
---

# WP-{N}: {title}

## Problem
## Artifact
## WP links
## Implementation phases
## Remaining
```

## Step 5. Confirmation

Output: *"WP #{N} created. Script wrote to 4 locations: context file, Registry, WeekPlan, active-wp rebuilt. Linear — {TSR-NN}."*
If ≥3h and `--result` was not passed: add "+ add mapping to Strategy.md manually."

```bash
# Postcondition check — substitute {N} with the real WP number before running
WP_NUM={N}   # real number from Step 2
grep -q "WP-${WP_NUM}" "{{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}/docs/WP-REGISTRY.md" \
  && echo "✅ WP-${WP_NUM} found in WP-REGISTRY.md" \
  || echo "❌ WP-${WP_NUM} NOT found — check create-wp.sh output above"
```

<!-- USER-SPACE -->
<!-- /USER-SPACE -->
