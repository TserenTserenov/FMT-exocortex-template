---
description: IWE operational memory file
domains:
- reference
horizon: warm
name: roles
originSessionId: 9a0e726a-951e-4408-9e02-94d7eeffbf74
owner: user
schema_version: 1
status: active
type: reference
valid_from: 2026-04-06
---
# Platform Roles (lookup)

> Source-of-truth: DP.ROLE.001 §3.2. This is a compact quick-reference for role selection.
> **Rule:** Do NOT guess a role. Check this table. No match found → propose a new one.

## Role Catalog (AI)

> **Role Performer** = implementation mechanism: `skill` (has `/command`), `script` (bash/Python, cron), `sub-agent` (Task tool + context isolation), `inline` (Claude in dialogue). `*` = external skill (FleetView).

| ID | Role | FX | Role Performer | Skill | Typical Tasks |
|----|------|-----|----------------|-------|---------------|
| R1 | **Strategist** | — | skill | `/day-open` `/day-close` `/week-close` `/month-close` `/strategy-session` `/wp-new` `/run-protocol` | Day/week plan, strategy session, review, note-review |
| R2 | **Extractor** | — | skill | `/ke` `/apply-captures` | KE into Pack, inbox check, ontology sync |
| R3 | **Consultant** | — | inline | — | Member Q&A, homework review, feed/marathon content generation |
| R4 | **Author** | FX1 | inline | — | Posts, presentations, pitches, descriptions |
| R5 | **Architect** | FX5 | skill + inline | `/archgate` `/think` `/fpf` | ArchGate, ADR, BC-mapping, SOTA-update |
| R6 | **Coder** | FX5, FX8 | inline + skill | `/transcribe` `/simplify`* `/claude-api`* `/review`* | Code, Refactoring, bug-fix |
| R7 | **Triager** | — | skill | `/iwe-bug-report` | Auto-triage feedback, triage-session |
| R8 | **Synchronizer** | — | script + skill | `/connect-guide`* `/setup-wakatime` `/loop`* `/schedule`* | Scheduler, code-scan, pack projection, notify |
| R9 | **Templater** | FX8 | skill | `/iwe-update` `/extend` `/init`* `/update-config`* `/keybindings-help`* `/fewer-permission-prompts`* | Template sync, drift detection, validation |
| R10 | **Statistician** | — | script | — | Metrics, analytics, time tracking |
| R11 | **Fixer** | — | inline (carrier under construction: WP-516 Phase 3 emergency circuit + WP-545 Phase 8 maintenance circuit, 01.09.2026) | — | FSM unstick, auto-fix, restart, escalate; "repairman" is a colloquial synonym for pilot; fix catalog proposed/validated/enabled — shared Artifact of both Role Performers |
| R12 | **Assessor** | — | sub-agent | — | Bloom eval, WP validation, fixation |
| R13 | **Guide** | FX6 | skill + script | `/consent` | FSM routing, tier gating, progressive disclosure |
| R21 | **Publisher** | FX1 | script | — | Scan ready posts, scheduled publish, comment check |
| R23 | **Verificator** | — | sub-agent | `/verify` | Artifact verification against reference (Pack/SPF). Context isolation |
| R24 | **Auditor** | — | sub-agent + skill | `/audit-installation` `/audit-docs` `/iwe-rules-review` `/check-secret` `/security-review`* | Coverage and consistency check (coverage, cross-context) |
| R29 | **Artifactor** | — | skill | `/artifactor` | Stage-level activity decomposition, material I/O, acceptance checklist, gap detector |
| R30 | **Pack Creator** | — | inline + skill | `/pack-creator` (deferred) | LLM-assisted authoring of PACK-X through SPF cycle 01-11; mode by cp-profile (assembly/hybrid/full); read-only protection of upstream FPF/SPF. See DP.SC.048, DP.ROLE.062 |
| R31 | **Org Development Manager** | — | inline | — | Guides from an org-change request (self/team/organization) to a concrete first step from SI/SM/IL. Step 0 — MIM.M.030 (system type classifier). See DP.SC.049, DP.ROLE.063 |

> **Update 12.08 (registry Audit WP-498):** R27/R28 previously listed Navigator/Diagnostician in error — those are `IWE` conventions (Cluster A), not `DP.ROLE.001` canon (Cluster B: **R27=Tailor**, **R28=Profiler**, see §3.2 of the platform registry). Full rename across template/downstream is a separate work package (not yet opened). Navigator = `MIM.R.007`, Diagnostician = `MIM.R.009`/`DP.ROLE.042` — MimEcoSys Pack roles, no platform R-number. See also **Mentor** (`MIM.R.001`, umbrella role: Mode 1 — scheduled review; Mode 2 — always-on bundle MIM.R.001⊗MIM.R.007⊗MIM.R.009⊗MIM.R.011, WP-498), **Onboarder** (`DP.ROLE.067`, WP-406), and **Secretary** (`DP.ROLE.098`, WP-389, draft 15.08 — reads hypothesis/event log and work package portfolio, delivers matured commitments with cancellations, answers direct pilot questions; do not confuse with "Decision Queue Secretary" inside WP-503, which operates only on the work package portfolio at shop-1) — these roles are active but absent from the numbered catalog §3.2 of `DP.ROLE.001` (Pack roles are identified by their own ID, not an R-number).

## Project Sub-Roles (S2R 3×3 Matrix)

> Source-of-truth: `FMT-s2r/0.OPS/0.3.Roles-Matrix-3x3/roles-matrix.md`.
> This is a compact quick-reference. Sub-roles come from the pilot's personal ecosystem-development Repository, if one exists (folder structure X.Y.Z).
> FX = activity context ("hat"). A role (R-N) is performed by a carrier (LLM agent / human / script) within an FX.

| FX | Sub-role | System × Dimension | Functional sub-roles |
|----|----------|--------------------|----------------------|
| FX1 | Promoter | Supersystem × Meaning | Educator, Marketer, Salesperson, Content Promoter, Outbound Practitioner, Seminar Host |
| FX2 | Product Owner | Supersystem × Architecture | — (cuts by application context, not roles) |
| FX3 | PR/GR | Supersystem × Operations | PR and reputation, Partner, Legal/Compliance, Stakeholder manager |
| FX4 | System of Interest Visionary | System of Interest × Meaning | — |
| FX5 | System of Interest Engineer | System of Interest × Architecture | — (subject-matter blocks, not roles) |
| FX6 | System of Interest Operator | System of Interest × Operations | Registrar, Onboarding Manager, Practicum Curator |
| FX7 | Businessman | Creation × Meaning | — |
| FX8 | Development Organizer | Creation × Architecture | — (subsystems and ADR, not roles) |
| FX9 | Administrator | Creation × Operations | HR/Team, Service Manager, Community Manager, Ops Manager |

## Roles With Typical Carrier

> Column "Carrier": Human = human, AI = LLM agent (Claude), Script = script/automation. This is the **typical** carrier — a role is portable across implementations (D.141 PD).
> FX = which project sub-roles this role participates in.

| ID | Role | Carrier | FX | What it does |
|----|------|---------|----|--------------|
| R14 | Client | Human | — | Formulates tasks for Claude |
| R15 | Validator | Human | — | Human-in-the-loop: approves KE, decisions, PR (`/apply-captures` skill) |
| R16 | Learner | Human | — | Learns in the bot (marathon/feed) |
| R17 | Strategist (interactive) | Human | — | Participates in strategy-session |
| R18 | Note Author | Human | — | Writes notes in TG → fleeting-notes |
| R19 | Tester | Human | — | Tests the bot (pilot) |
| R20 | Reviewer | Human | — | Reviews reports, digests |
| R22 | Marketer | Human | FX1 | Defines target audience, forms key ideas, selects channels and frequency |
| R25 | Expert Reviewer | Human | — | Expert content assessment (AI Opus or human) |
| R26 | Acceptor | Human | — | Pass/fail decision based on verdict (usually = R15 Validator) |


## Specifics: R4 Author — Presentations (MimEcoSys)

> The pilot is a MimEcoSys speaker and content author for multiple audiences.

**Style:** short slides, minimal text. Structure: hook → pain → tool → constraint → depth.

**Three segments:** A (beginners), B (practitioners), C (experts). Signal phrases mark the intended audience.

**Order:** A — simple example, no terminology → B — case study → checklist → template → C — hint at depth, do not reveal.

**Seminar structure:** 0. Hook (everyone) → 1. Pain (A+B) → 2. Diagnosis (A+B) → 3. Example (A) → 4. Mini-tool (B) → 5. Constraint (B→C) → 6. Hint at depth (C) → 7. Where to go next (everyone).

**Transitions:** via the trap: *"This works. But here is the trap..."*

**Questions:** from A → keep simple, do not go deep. From C → "good question for a separate deep-dive" + 1 line of depth. Do not pull the audience up to the questioner's level.

**Main rule:** Depth is not revealed — it is glimpsed.
