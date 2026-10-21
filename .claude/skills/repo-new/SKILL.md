---
agents: single
browser_safe: false
description: 'Gate for creating any new IWE repository (ecosystem or personal space).
  Routes the request through: intent classification (Pack / SpacePlan / named project
  / ecosystem DS), name and class validation, data classification (types 2.1–2.4,
  quarantine), writer/owner/readers declaration, privacy decision, mandatory Decision
  Gate (default — pilot approval; for CI — limited delegation), then execution (creation,
  registration, skeleton deployment). Use when the pilot wants to create a new repository,
  or asks where and how to place a new type of data. Not for extending an existing
  repository (→ Repo-Touch/Residency Gate) and not for Pack repositories (delegated
  to `/pack-new`).'
gates_enforced: []
gates_rationale: 'wp — creating a new repository: non-trivial artifact (>15 min)
  with long-lasting consequences (name, data placement, registry entry), requires
  an agreed WP before scaffolding. The skill itself IS the instantiation of IntegrationGate
  for repository creation (promise+scenarios+role already resolved in WP-527); additionally
  Routing/IntegrationGate does not impose Routing/IntegrationGate on its own invocation. IntegrationGate hard-check
  of /skill-creator (Step 3 — search DP.SC.*/DP.ROLE.* in Pack) skipped during creation of
  01.09.2026 (recorded as an agent error), then resolved in the same session: by a special
  Pack-entry for ''repository creation'' does not exist and will not be created, while the skill is in status:
  experimental/testing — formalization in Pack deferred until promotion to template (that
  same order, as for vdv/bottleneck-pick), does not block testing.'
gates_required:
- wp
interaction: multi-step
layer: L2
name: repo-new
status: experimental
triggers:
  phrases:
  - create a repository
  - new IWE repository IWE
  slash:
  - repo-new
version: 0.2.0
---

# /repo-new

> **Scope:** create a NEW IWE repository (ecosystem DS or personal data space) through a mandatory name/data/ownership gate, with the result being a created repository, a Registry entry, and a deployed skeleton.
> **Out of scope:** extending an existing repository (→ Repo-Touch/Residency Gate); Pack repositories (delegate to `/pack-new` at Step 1 and stop); one-shot deployment of the full 5-family structure (that is `setup.sh` / WP-559 — this Skill processes one repository per invocation).
> **Role:** R6 Coder executes the gate and the Execute-phase entries; the default Decision Gate authorization bearer is the pilot (WP-527 Ph0 §3, resolved in round-loop session 01.09.2026, recorded in STAGING.md S-60) — no new Pack Role is introduced, and self-approval by R6 is prohibited.

## When to use

- The pilot wants to create a new repository (ecosystem `DS-*`/instrument/surface, or personal data space `PD-*`/`MC-*`/`PACK-*`).
- The pilot asks where and how to place a new type of data, and no suitable repository yet exists.
- Automation/CI needs to create a repository under an already-approved limited policy (the pilot is not present at that moment).

## Preconditions

1. **WP Gate precondition.** The task must be linked to an agreed Work Product in the weekly plan (this Skill is a product of WP-527).
2. **The data domain map must be current.** `docs/adr/ADR-004-data-domain-map.md` and `docs/DATA-DOMAINS-REGISTRY.yaml` (IWE) must exist and be readable — the Skill has no fallback domain map and must not invent one.
3. **Pack intent — immediate exit.** If the requested repository is a Pack, delegate to `/pack-new` at Step 1 and stop; do not execute the remainder of this Skill's gate (authority there belongs to the Pack Creation Gate, not this one).

## Known exceptions (not gated by this Skill)

> Inventory 01.09 (WP-527, author's working copy): bare `gh repo create`/`create_repository` calls outside this gate. The Skill invokes an LLM agent that reads SKILL.md — a raw bash script cannot invoke it; therefore the channels found are documented exceptions, not candidates for reconnection.

- **`setup.sh`** (the "Create {{GOVERNANCE_REPO}} repo" step, default `DS-strategy`) — creates the governance repository during the very first IWE installation, before the user has an agent with Skills at all. Cannot go through the gate by design (chicken-and-egg). The name is set at installation time (`$GOVERNANCE_REPO`); no gate is needed.
- **`setup/optional/setup-agent-workspace.sh`** — an optional manual script that creates `DS-agent-workspace`, invoked after onboarding (gate is already available at that point). It already writes `REPO-TYPE.md` and CLAUDE.md at creation time — it is intentionally not reconnected to `/repo-new` (rewriting a working bash script to invoke an agent Skill is not architecturally justified). Documented here as a known exception, not a gap.

## Algorithm

<!-- Each step: Input (what must be ready), Action (what the agent does), Output (artifact or state).
     For multi-step Skills — run /vdv audit on this section before finalizing. -->

Eight steps across three phases (Plan → Decision Gate → Execute) — see below.

### Phase 1 — Plan (no mutations)

### Step 1 — Classify intent and select the creation path

Input: repository creation request; read-only access (if available) to the SpacePlan catalog/API and `memory/repo-type-rules.md`.

Action: confirm this is a NEW repository creation request — if it concerns extending an existing repository, stop and redirect to the Repo-Touch/Residency Gate. Then explicit branching:
- **Pack** → delegate to `/pack-new`, stop.
- **SpacePlan intent** → `planId: verified` status is set only after a read-only check against the catalog, with the catalog source and revision/fingerprint recorded; if the check is unavailable — status is `planId: unverified`, and the Decision Gate (Step 5) is blocked. Pilot approval does not substitute for technical validation. The only exit from `unverified` is an explicit reclassification as a named project with a new agreed Plan; automatic downgrade is prohibited.
- **Named project outside SpacePlan** → `create_repository(template_type="project")` by default. For a request that matches an active policy entry in `machine/repo-new-policies.yaml` (Step 5) with a known `bounds.repo_class`, `template_type` is the convention hard-coded in THIS Skill's text for the specific `repo_class` (not a field of the policy entry itself — the 7 mandatory bounds in Step 5 do not include it): for `repo_class: personal-subscriber` — `template_type: "notes"`. Namespace-shadowing of reserved family prefixes `PD-*`, `DS-*`, `PACK-*`, `MC-*` is prohibited — unless the name is a constant fixed in the policy entry itself (for example, `personal-subscriber` fixes `DS-personal-guide`).
- **Ecosystem DS** (governance/instrument/surface) → manual path via `gh repo create`; this Skill only produces a checklist for this branch and does NOT automate it — neither at this step nor at Execute (Steps 7/8 do not apply to this branch; see there).

Output: classified intent, selected creation path, and (for SpacePlan) an explicit `planId: verified | unverified` status with verification evidence when `verified`.

### Step 2 — Determine repository class and name

Input: classified intent and path from Step 1.

Action: check the class and proposed name against `memory/repo-type-rules.md` and ADR-004. A mandatory family prefix applies only to a known repository family. An existing user-supplied name is preserved unchanged unless it violates an applicable rule or a reserved namespace.

Output: validated class and final proposed name, with any name Constraint recorded in the Plan.

### Step 3 — Classify data, then declare writer/owner/readers

Input: validated class and expected repository contents.

Action, in two explicit sub-parts (kept separate intentionally so neither is dropped):
- **Data classification:** classify data by types 2.1–2.4 (canon — `DATA-RESIDENCY.md`, source WP-442: six types total, four of which are personal; there is no separate type for conversational artifacts — personal dialogues/notes in the user's git repository fall under type 2.4 "non-formalizable personal practice"). For conversational sources (AI correspondence), additionally apply the `conversation` processing profile (WP-427 Ph8): separate consent purposes, default prohibition of tool service content, volume/retention bounds, secrets and personal data scan — this is a processing profile, not a separate residency type. Derive `homes`/`sensitivity`/`quarantine` from `DATA-DOMAINS-REGISTRY.yaml`. Separately check for off-axis quarantine (secrets, payment data, third-party PII) using WP-483 heuristics — this is not the same axis as 2.1–2.4 and must not be silently collapsed into it.
- **Responsibility:** explicitly name the writer, owner, and readers for each class. For CI/automation — writer = "system", owner = pilot.

Output: data residency declaration (including off-axis quarantine flag) and a complete writer/owner/readers assignment.

### Step 4 — Decide privacy and skeleton contents

Input: class, data declaration, responsibility assignment.

Action: decide public/private NOW, not later — if public, a publication gate in CI is mandatory in the skeleton (precedent WP-493). Draft the skeleton Manifest: a README passport (class, purpose — one sentence in plain language, data domains, writer/owner/readers, gate receipt Projection) and a CLAUDE.md stub.

Output: privacy decision, publication-gate requirement (if public), planned skeleton Manifest.

### Phase 2 — Decision Gate

### Step 5 — Obtain bounded authorization

Input: complete immutable Plan from Steps 1–4, with no unresolved `planId: unverified`.

Action: present the complete Plan to the authorization bearer. Default — pilot, `approval_scope: instance`. For CI/automation, `approval_scope: policy` is permitted only if the policy explicitly bounds ALL of: repository classes, name namespace, privacy, owner (with a verifiable `owner_selector`, not an arbitrary argument), data domains, instance limit/period, and expiry. A request outside any of these bounds → **STOP**, not a silent rollback: report with the specific violated bound and numbers (e.g. "usage_log: 50/50 in 90 days, next slot available `<date>`"), and an explicit new question to the pilot — extend/expand the policy (new `decision_ref` entry) or initiate a separate instance-level pass. The invoking Skill does not switch scope silently on its own.

**`policy` storage and verification (specification, WP-527 01.09 — inventory found no live CI channel that needs this today; the file is created lazily on the first real policy issuance, not pre-provisioned; the first real consumer is `repo_class: personal-subscriber`, WP-527 Ph4):**
- File: `<governance-repo>/machine/repo-new-policies.yaml`, one entry per `policy_id` with fields `bounds` (all 7 bounds), `decision_ref` (`approved_by`/`decision_session`/`decision_date`/`wp_ref` — reference to the pilot's decision OUTSIDE this file; without it the entry is self-approved by the same agent that verifies it) and `usage_log` (append-only, one line per **successfully created NEW** repository under this policy: timestamp + itemized fact; idempotent reuse on 409 and failed attempts are not added to `usage_log`).
- Verification on every request: re-read the file fresh (do not cache between calls), find `policy_id`, check expiry, confirm `decision_ref` is present, verify that the requested namespace/privacy/owner_selector/domains fall within the declared bounds, count `usage_log` entries for the current period and compare against the limit. Any of these checks fails → STOP (see above), never fail-open.
- **Atomicity (parallel policy execution race condition):** reading `usage_log`, comparing against the limit, and appending after Execute — all under the same file lock already used for shared governance-repo files (`gateway-lock.py acquire <policy file>` for the duration of check+write, `release` immediately after). Without the lock, two parallel requests that both read before either writes their entry can together exceed the limit.
- After successful Execute (Step 7) — append the fact to the `usage_log` of that policy (within the same lock).

Output: explicit approval or rejection with `approval_scope: instance | policy`. Execution remains blocked until the approval covers exactly this Plan.

### Step 6 — Record the gate receipt

Input: approved, unchanged Plan and authorization decision.

Action: create a machine-readable gate receipt with the following fields — do not abbreviate the list; each field carries Audit load:
```yaml
approved_by: pilot | <policy_id>
approved_at: <ISO-8601 timestamp>
approval_scope: instance | policy
request_fingerprint: <stable id/hash of the request>
plan_fingerprint: <stable id/hash of the full Plan from Steps 1-4>
wp_ref: WP-527
```
The receipt references the immutable full Plan saved in the originating WP/session by fingerprint — it does not replace or summarize the Plan. The README and the Registry entry receive at Step 8 a *Projection* of this receipt, not the full field set: the Projection retains `approved_by`, `approved_at`, `approval_scope`, and `wp_ref` — these four fields give a human the understanding of "who/when/how/under which WP", while `request_fingerprint`/`plan_fingerprint` remain only in the originating record (WP/session), where the full Plan lives for machine verification; duplicating them in the human-readable passport is unnecessary.

Output: gate receipt bound to the exact authorized Plan; unlocks Phase 3.

### Phase 3 — Execute (only after a valid gate receipt)

### Step 7 — Create and register the repository

Input: valid gate receipt, creation path from Step 1, final repository name from Step 2 — **except for the "ecosystem DS" branch**, for which Execute (Steps 7/8) is not performed by this Skill: the agent hands the pilot/R6 a final checklist (class, name, data classification, writer/owner/readers, gate receipt) and stops BEFORE this step; the actual `gh repo create` command and subsequent registration are performed manually using that checklist, not automatically by the Skill.

Action (for the remaining three paths — Pack already exited at Step 1, so here SpacePlan and named project apply): create the repository via the selected path (SpacePlan MCP call / `create_repository`). On success, register it in `0.OPS/REPOSITORY-REGISTRY.md` of its ecosystem-development repository, if one exists — this entry is written by the agent, not the pilot (intentional separation from the Decision Gate: pilot authorizes, R6 executes). No such repository exists → skip registration; there is nowhere to write the entry. **Exception — `bounds.repo_class` of the active policy equals `personal-subscriber`** (or any future class with the same property "personal subscriber repository, not ecosystem infrastructure"): registration in `REPOSITORY-REGISTRY.md` is not performed — that Registry is about the ecosystem's own infrastructure; per-subscriber accounting is already maintained via `github_status`/`personal_list_sources`; duplication is unnecessary.

**Name conflict (409):** reuse of an existing repository is permitted only after verifying that it simultaneously (a) belongs to the `owner` in the authorized Plan (not merely a name match), (b) `private` matches the Plan, and (c) does not conflict with the expected `template_type` signature (for example, for `notes` — structure with `inbox/`, `docs/`, `README.md`). If any one condition does not match (typical case — an old repository with a different `private` value, created before the current policy) → **STOP**, reuse is prohibited; a separate Migration task is required — this Skill does not resolve it silently.

Output: created (or safely reused) repository and Registry entry (except the exception above), or a recorded partial state if any operation fails.

### Step 8 — Deploy skeleton and close

Input: created repository, Registry state, skeleton Manifest, privacy decision, gate receipt. Does not apply to the "ecosystem DS" branch (see Step 7).

Action: deploy the README passport (with gate receipt Projection), CLAUDE.md stub, and publication gate in CI if public — **only on the real-creation path of Step 7**. On the safe 409-reuse path (Step 7), the skeleton is NOT redeployed: the reused repository already has its own README/CLAUDE.md, and a blind overwrite would destroy whatever has actually accumulated there. If any Execute-phase operation fails — stop immediately and report exactly what was created and what was not; do not attempt automatic rollback — a failed rollback is a second unauthorized mutation on top of the first failure.

Output: initialized repository with mandatory governance skeleton, or an explicit partial-failure report listing completed and incomplete artifacts.

## Bundled resources

- `assets/repository-skeleton/README.md` — README passport Template, used at Step 8 (placeholders for class, purpose in one line, data domains, writer/owner/readers, gate receipt Projection).
- `assets/repository-skeleton/CLAUDE.md` — minimal CLAUDE.md stub, deployed at Step 8 so that the Repo-Touch Gate does not encounter an empty repository.

## Anti-patterns

- Do not allow the SpacePlan branch at Step 1 to treat `planId: unverified` as "probably fine" — an unverified plan blocks the Decision Gate completely, with no bypass by the pilot other than explicit reclassification.
- Do not collapse the off-axis quarantine check (secrets, payment data, third-party PII) into the standard 2.1–2.4 residency check at Step 3 — these are different axes with different consequences.
- Do not allow the pilot's Decision Gate approval to simultaneously count as the Registry entry step — the Registry entry at Step 7 is always written by the agent; never treat it as "already done" because the pilot said yes.
- Do not attempt automatic rollback of a partial Step 7/8 failure — report and stop.
- Do not issue `approval_scope: policy` without all seven mandatory bounds (classes, namespace, privacy, owner, data domains, instance limit/period, expiry) — a partial policy is not a policy; it is an unrestricted permission with extra steps.
- Do not execute Steps 7/8 (creation, registration, skeleton) for the "ecosystem DS" branch — the Skill produces only a checklist there; execution is manual.

## Verification

```bash
bash .claude/skills/skill-creator/scripts/verify-skill.sh repo-new
```
Expected: PASS on all structural checks (frontmatter fields, gate fields, presence of `## When to use` / `## Algorithm` sections, existence of bundled resources). This Skill currently has no `verification_class` above `closed-loop` structural checks — a live smoke test with a real repository creation is WP-527 Ph3 ("trial run on the first real repository creation"), not part of this file.
