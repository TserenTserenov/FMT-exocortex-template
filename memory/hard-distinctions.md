---
description: IWE operational memory file
domains:
- reference
horizon: warm
modified: 2026-08-24 14:30:00+00:00
name: hard-distinctions
originSessionId: 9a0e726a-951e-4408-9e02-94d7eeffbf74
owner: user
schema_version: 1
status: active
type: reference
valid_from: 2026-04-25
---
# Hard Distinctions

> **PROHIBITED: confuse these pairs.** Critical ontological errors.
> Source: FPF (A.7 Strict Distinction)
> Archive of deprecated distinctions: `hard-distinctions_archive.md` (WP-7 phase-2 trim 2026-04-25).

## 1. Persona ≠ Memory ≠ Context (user data model, DP.D.052 v2)

> Replaces the former term "Digital Twin / DT" as a monolithic entity.
> Layer separation criterion: **writer + owner (source-of-truth)**.
> v2 (2026-05-31, peer session 2026-05-31-11): table split into 4 axes (Writer / Identity-anchor / State-storage / Snapshot-unit) instead of combining Owner+Artifact; added the Distinction: Carrier ≠ Persona ≠ Declaration (see §1.1).
> SoTA 2025–2026: Letta (**human block** = correlate of our Persona, not persona block — that is the agent's self-description); Mem0 (structured attributes vs raw memories); LangMem (semantic/episodic/procedural); Anthropic Memory tool; OLM literature (Bull & Kay 2007 — Learner Profile vs Learner Model); Solid (W3C user pod); Honcho — rejected alternative (unified peer pattern, conflict with GDPR/audit/capture-flow).

### Three layers — four axes (v2, 2026-05-31)

| Layer | Writer | Identity-anchor | State-storage | Snapshot-unit |
|-------|--------|-----------------|---------------|---------------|
| **Persona** | user (or agent on behalf + acceptance) | Ory `subject_id` (UUID immutable; for Pre-Grant — `subscription_grants.claim_token`) | Git (PACK-personal, governance repo, captures, preferences) + Neon refs (`persona_grants`) | Git commit + frontmatter `valid_from` |
| **Memory** | platform automatically | Ory `subject_id` (FK via `persona_grants`) | Neon (Observed events + Derived aggregates) | Event log offset + Derived snapshot version |
| **Context** (= Projection) | agent at runtime | Ory `subject_id` (read for addressing) | Ephemeral (process memory) | LLM-prompt assembly id |

**Distributed identity pattern.** The identity anchor lives separately from content and refs. This is the standard pattern in federated identity systems (Cameron 2005; OAuth2 RFC 6749/7591; W3C DID 2022; Ory "decoupled identity"). A centralized `personas` table in Neon would duplicate the Ory subject_id — rejected.

### Boundary test (v2 — by new axes)

| Delete | What is lost | What remains |
|--------|--------------|--------------|
| Identity-anchor (Ory subject_id or claim_token) | Persona identity → Persona as entity ceases to exist | Declarations in Git as orphan history; Neon refs with broken FK |
| User's Git (PACK-personal etc.) | All declarations (content) | Identity-anchor + Neon refs (Persona survives, but without declaration) |
| One Git commit | One snapshot version of the declaration | Identity, remaining snapshots, Neon refs |
| Neon `persona_grants` records | Link between Persona and Memory (refs) | Identity-anchor + declarations in Git |
| Neon entirely | Memory is gone | Persona intact (anchor + Git) |
| Interrupt LLM call | Projection is gone | Persona + Memory intact |
| Carrier stopped logging in | Nothing in the platform is lost | Everything (Persona ≠ carrier, see §1.1) |

### §1.1 Carrier ≠ Persona ≠ Persona Declaration

> A derived distinction that makes the "entity vs snapshot" axis explicit within the Persona. Introduced following peer session 2026-05-31-11. Addresses the intuition that "the database stores not a Persona, but a version of it."

| Entity | What it is | Where it lives | Who is writer |
|--------|-----------|----------------|---------------|
| **Carrier** | A human in the physical world | Outside the platform | — |
| **Persona** | An entity-in-IWE representing a single carrier; **distributed composition** (anchor + declarations + refs) | Ory subject_id + Git PACK-personal + Neon persona_grants | User (declarations) + Platform (identity-anchor, refs) |
| **Persona Declaration** (Persona Snapshot) | A single slice of declarative content at time T | Git commit + frontmatter `valid_from` | User (or agent on behalf with acceptance) |

**Tests:**
1. "Carrier stopped logging in → Persona is gone?" — No, the Persona remains as an entity inside the platform.
2. "Delete one Git commit → Persona is gone?" — No, the Persona survives (anchor + remaining commits + Neon refs); only one declaration version is lost.
3. "What must be deleted for the Persona to fully cease to exist?" — The identity anchor (Ory subject_id or claim_token). Deleting Git/Neon refs is a partial deletion.

**Lifecycle anchor:** Pre-Grant (anchor = `claim_token`, lead/guest before Ory) → Granted (anchor = `subject_id`, after claim flow). The transition is one-way and atomic.

**What this changes in practice:**
- When discussing "Persona storage" — specify the component (anchor / declarations / refs).
- GDPR right-to-be-forgotten: revoke anchor → wipe Git → wipe Neon refs (a sequence, not a single operation).
- Letta import: our Persona = their `human block`, **not** `persona block` (= agent's self-description).

### Five categories **outside** the user model

| Category | Contains |
|----------|----------|
| **Catalog / Reference** | Pricing plans, qualification level reference (11 stages), accrual rules, multipliers, system constants |
| **Service / Ops** | Metabase #7, health #8, audit logs, Ory sessions, Keto policies, Railway deployments |
| **Relational** | Persona↔Persona links: mentorship, community, Random Coffee matching |
| **Proto-Persona** | Pre-Grant, a lead before Ory registration (email/telegram_id without ory_id); claim flow promotes to Persona |

### Within Memory — split (sub-levels of one layer)

- **Observed** — events, logs, observations (activity-hub #3, payment events #4)
- Boundary: an event ≠ a state (projection). One table = one class (HD R-W17-1).

### Mapping old references to the new terminology

| Old "DT" in text | → | New |
|------------------|---|-----|
| calculated profile (baseline, potential, indicators) | → | **Memory.Derived** (~85%) |
| user's self-declaration of roles and values | → | **Persona** (~10%) |
| LLM window / prompt assembly | → | **Context** (~5%) |

### What remains from the former HD #27 (bot ≠ platform)

- **Bot = platform client**, not the owner of user data. The bot writes events to Memory (via `log_event()`), but the Memory schema belongs to the platform; the bot's operational session state (`user_state.current_state FSM`) is owned by the bot — an ephemeral Memory sub-layer, not part of user data.
- **Event producers** (by significance): LMS → Club → Bot → Web App. The bot is an additional source; primary Observed events come from the LMS/Club.

**Test 1:** "Who owns this table?" → platform (L2) vs bot (L3 instrument). If platform → migration outside the bot.
**Test 2:** "Who writes? Who is source-of-truth owner?" → User's Git = Persona; Platform's Neon = Memory; runtime = Context.

See also: DP.D.052 (`.claude/rules/distinctions.md`), `project_persona_memory_context.md`. DP.ARCH.003 has been split into DP.ARCH.005/006/007 (WP-257 phase 5 DONE 22 Apr).

## 2. Script ≠ Agent (DP.D.048)

| Script | Agent |
|--------|-------|
| **Fixed control flow** — the author wrote the sequence of steps | **LLM chooses the next step** at each iteration |
| One input → one sequence of actions (result may differ due to network/DB) | One input → different sequences (LLM decides) |
| Input: CLI arguments, environment variables | Input: prompt + set of tools |
| Debugged as a program (reproducible trace) | Debugged as a dialogue (different branches) |
| Placement: by Role Performer type (see below) | `.claude/agents/` or `<repo>/agents/` |

**Common ground:** both are Role Performers in IWE. Both can produce different results from the same input (environment non-determinism: network, DB, current time). The difference is not in result predictability but in **who chooses the next step**: the script author in advance, or the LLM at runtime.

**Test:** "If I remove the LLM from runtime — does execution break?"
- **Yes → agent** (without the LLM, there is no one to choose the steps)
- **No → script** (only LLM call implementations fail, but control flow remains)

**Example of confusion:** calling a pre-commit hook that invokes the LLM API to decide pass/fail an "agent." In reality, the sequence of steps (1. collect changes → 2. call LLM → 3. parse response → 4. decide pass/fail) is written by the script author — this is a script using the LLM as a tool, not an agent.

**Script classification by type (where it lives):**

| # | Type | Location | Owner |
|---|------|----------|-------|
| 1 | Universal protocol (standard work session) | FMT/scripts/ → {{WORKSPACE_DIR}}/scripts/ | Platform |
| 1b | Role-specific protocol | FMT/roles/<role>/scripts/ | Platform + role |
| 2 | Author protocol | {{WORKSPACE_DIR}}/scripts/ (not in FMT) | Author |
| 3 | Service | `<service>/scripts/` | Service |
| 4 | Repo operations | `<repo>/.ops/` or `<repo>/scripts/` | Repo |
| 5 | Agent hook | `.claude/hooks/` or `.claude/skills/<skill>/` | Agent infrastructure |
| 6 | Git hook | `<repo>/.git/hooks/` or `.husky/` | Repo |

The trigger (launchd/cron/git hook/manual) is an orthogonal dimension and does not determine placement.

**Placement rule:** "Whose promise breaks if the script fails?" = owner = location. Details: DP.KR.001 §5.6.

**Related:** DP.D.048, DP.KR.001 §5.6, staging S-20 (L3→L1 promotion process).

## 3. MCP Service ≠ Role ≠ Performer (three layers)

> A triple distinction developed in WP-222 (10 Apr → 6 May 2026). Originally it was "MCP ≠ Role" (two-layer), but the empirical Tailor case revealed the need for a third layer — the **performer**.

| Layer | What it is | Example (Tailor) |
|-------|-----------|------------------|
| **Role** | A Functional Position in the system. Has obligations, methods, contracts. Portable across carriers. | R27 "Tailor" in DP.ROLE.001 — composes content for the learner from 8 inputs |
| **Carrier / Performer** | A concrete implementation of the role. Can be a Python script, an AI agent, or a human. Changes without changing the role. | Current: `render-pilot-guides.py` + `planner.py` on the pilot server. Future: AI agent tool-use via MCP Gateway |

| ❌ DO NOT confuse | ✅ Correct |
|------------------|-----------|
| MCP service = role (`tailor-mcp` = Tailor) | MCP is named after data/tools; the role is a separate entity in the Pack |
| Carrier = role (Python script = Tailor) | The script is the carrier of R27. It can be replaced by an AI agent; the role does not change |

### Empirical example: Tailor lifecycle (WP-222 closed 2026-05-06)

| Date | Event | What was the error |
|------|-------|--------------------|
| 30 Mar 2026 | WP-175 phase 9-A: Python stdio service `tailor-mcp` created with tool `get_tailor_context` | Service name = role name. MCP service scoped to one SQL projection. |
| 10 Apr 2026 | WP-222 opened: "why do we need a separate tailor-mcp?" — layer gap discovered | — (diagnosis) |
| 4 May 2026 | WP-245 Block B: actual carrier deployed — Python script `render-pilot-guides.py` on pilot server; reads Neon `indicators` directly, writes to `personal-guide` repo. Nobody calls `tailor-mcp`. | tailor-mcp turned out to be a zombie service |

**Test:** Three questions for separating layers:
1. "Is this a Functional Position in the system with obligations and methods?" → **role** (in DP.ROLE.001)
2. "Is this specific code/script/agent that performs the role?" → **carrier** (in DS-autonomous-agents/agents/{role}/)

**Naming consequences:**
- Give a carrier a name with the implementation version: `tailor-py-v0.1` (Python), future `tailor-llm-v1.0` (AI agent)
- Name a role by its function (Tailor, Navigator) — without binding to the carrier


## 4. Log ≠ Incident ≠ State file (DP.D.049)

| | Log (operational) | Incident (governance) | State file |
|--|-------------------|----------------------|------------|
| **What** | Chronological stream of execution events | A recorded failure + root-cause analysis | Current state (not history) |
| **Who writes** | Automatically — the performer | A human (or agent under supervision) | Automatically — a script overwrites |
| **Format** | Append-only text or JSON | Structured md: what broke, why, lesson | YAML/JSON/text — state snapshot |
| **Example** | `week-draft-append.log`, `payment-worker.log` | P10 (DP.FM.010), P11 (DP.FM.011) | `sync-manifest.yaml`, `last-check.json` |
| **Purpose** | Debug a specific run | Extract a lesson, feed into Retrospective | Next run (idempotency, diff) |

**Test:** "Is this a chronology, an analysis output, or a state at time X?"
- Chronology → **log**
- Analysis output (breakdown + decision) → **incident**
- Snapshot → **state file**

**Anti-patterns:**

1. **Log in governance repo.** "I will write the script execution log to `{{GOVERNANCE_REPO}}/inbox/` for later review" — violates OwnerIntegrity. The fact of execution belongs to the performer, not the decisions repo. A log pollutes git history with incidental messages.
2. **Incident in `<service>/logs/`.** "The failure is minor, I will record it right next to the logs" — it gets lost. Incidents must be aggregated in governance so they appear in the weekly review and become a pattern (P10, P11).
3. **State file as append-only.** `sync-manifest.yaml` accumulates versions instead of overwriting — it becomes a log and loses the meaning of "current state." For history, use `git log` on the state file itself.

**Example of correct routing:**

```
{{WORKSPACE_DIR}}/scripts/week-draft-append.sh                     # script
{{WORKSPACE_DIR}}/scripts/logs/week-draft-append.log               # log (alongside)
{{WORKSPACE_DIR}}/scripts/state/last-append.yaml                   # state file (alongside)
  2026-04-17-week-draft-append-failed.md               # incident (if it fails)
```

**Related:** DP.D.049, DP.KR.001 §5.7, DP.FM.010 (P10), DP.FM.011 (P11).

## 5. Role ≠ Agent; Agent ≠ Tool; Agentic Role ≠ Functional Role (DP.D.023, DP.D.033)

| ❌ | ✅ |
|---|---|
| "Strategist is a separate agent" | Strategist is a **role** (R1). Claude is the holder (performer) |
| "Bot is an agent" | Bot is a tool (I1, Grade 1), plays the role of Guide (R13) |
| "Synchronizer is an agent" | "Synchronizer" is both a role (R8) and a tool (I2). Different perspectives |
| "A role requires agency" | An **agentic** role — its description allows choosing the method. A **functional** role — its description prescribes execution. The holder's Grade is not part of the criterion (CC-A13.4) |

**Role-Centric (DP.D.033):** A role is described independently of its performer. The performer (holder) is selected and prepared separately. One name = both role and system (like "hammer").
**FPF notation:** Holder#Role:Context@Window
**Role catalog:** DP.ROLE.001 §3.2 (R1–R20). Performer registry: §3.1 (A1–A2, I1–I8).
**Performer preparation:** program (script) | prompt (LLM) | train (human).
**Test 1:** Can the entity choose HOW to act? Yes → agent. No → tool.
**Test 2:** Is this a description of a function (what to do) or a description of a system (what to do it with)? Function → role. System → performer.

**Role definition (residency 20.07.2026, refined by pilot 21.07):** A role is not the behavior of an object nor the object itself — it is the **name an object receives in a specific context** when it exhibits certain behavior. Remove the context and the role no longer applies, even though the object is the same. Examples: a stone used to drive a nail is called a driver in that context (the same stone outside the nailing context is just a stone); a sheet of paper can be a note-storage system, a paper plane, or a paper boat — depending on the context of use. Consequences: one object can occupy multiple roles simultaneously (different contexts at once); one role can be performed by different objects (a nail can be driven with a stone or a hammer) — a role is not bound to a specific carrier; it is bound to the context.
**Ontological error anti-pattern:** substituting an object with an impression or characteristic derived from it. "Moscow is a city" — precise (object = object). "Moscow is unforgettable nights" — evocative, but an error: the object has been replaced by an impression. This is harmless in casual speech; in a working text or debate it costs wasted time (participants think they are discussing the same object but are actually discussing different facets of it).

## 6. Designing an agent ≠ Designing an agent's role in context (AS.D.007)

| Designing an agent | Designing an agent's role in context |
|-------------------|--------------------------------------|
| Who: vendor (Anthropic, OpenAI) | Who: IWE architect/user |
| What: LLM + runtime + SDK | What: prompt + context + constraints + governance |
| Artifact: model, API | Artifact: agent-card.yaml, prompt, CLAUDE.md |

**Consequence:** Trust Stack, Graduated Governance, Bounded Agency — applied to the **role in context**, not to the agent. One Claude Code — different roles, different governance.

**Test:** Are you designing the runtime/SDK? → you are designing an agent (vendor's task). Are you designing the prompt/boundaries/governance? → you are designing a role in context (your task).

## 7. Agent code ≠ Agent data ≠ Human decisions (DP.D.041)

| Agent code (instrument) | Agent data (governance) | Human decisions (governance) |
|---|---|---|
| Prompts, scripts, agent-card, trajectory cache | Drafts, reports, findings, extraction-reports | Approved plans, confirmed captures |
| DS-autonomous-agents | **DS-agent-workspace** | {{GOVERNANCE_REPO}} (example implementation) |
| Changes rarely (code versions) | Created daily (nightly cycles) | Created upon approval |
| Author: developer | Author: agent | Author: human |

**Criterion:** Who is the author of the artifact? Agent → workspace. Human → my-strategy. Developer → autonomous-agents.

**Trajectory cache ≠ results:** trajectory affects agent behavior (part of the code, like "trained weights") and stays in the instrument repo. Results are consumed by others and go to the workspace.

**Pipeline:** Agent creates a draft (workspace) → human reviews → approved version (my-strategy or Pack) → draft remains (audit, training).

## 8. Obligation → One role → One scenario (Anti-Bystander)

| ❌ | ✅ |
|---|---|
| "3 agents clean WP" | "R1 Strategist, Session-Prep scenario — sole owner of WP archiving" |
| Obligation is duplicated across multiple scenarios | Obligation belongs to one role, one scenario |
| Everyone is responsible → no one acts (bystander effect) | One owner → always executed |

**Rule:** One obligation = one role = one scenario. Other scenarios may **mark** (status: done), but must **not perform** the primary action.

**Test:** If one of N scenarios performing the obligation is removed — does something break? If no → duplication (bystander). If yes → dependency (ok).

**Correction example (21 Feb 2026):** Archiving of done WP files was in Close (step 7), Note-Review (step 8), Session-Prep (step 8.5). All three skipped it. Solution: Close and Note-Review only set the status → Session-Prep moves the files.

## 9. "Level" = strictly part-whole (physical containment)

| ❌ DO NOT confuse | ✅ Correct |
|------------------|-----------|
| "4 system levels" (Ecosystem→Platform→Template→Personal) | "4 system perimeters" — organizational perimeters, not physical part-whole |
| "At which level?" (about a responsibility perimeter) | "In which perimeter?" — perimeter = boundary of responsibility and governance |
| "Level" = scale, zone, perimeter | **Level** = strictly U.SystemLevel: level 2 is physically contained in level 1 (as an engine in a car) |

**Rule:** The word "level" is permitted ONLY for physical part-whole relationships (car → engine → piston). For organizational boundaries, responsibility zones, and scales → use "perimeter," "zone," or "scope." NEVER "level."

**Test:** Is level 2 fully physically contained within level 1? Yes → level. No → perimeter (or another word).

## 10. Platform ≠ IWE Template ≠ Personal IWE (4 system perimeters)

| Perimeter | What | Governance | Who changes it |
|-----------|------|------------|----------------|
| **L2: Platform** | Infrastructure, services (bot, MCP, DB) | Pack DP, MAP.002 | Platform developer (M2) |
| **L3: IWE Template** | Template for users (CLAUDE.md + memory/ + strategist) | IWE | Template developer (M3) |
| **L4: Personal IWE** | User instance (configured, connected) | Personal CLAUDE.md | IWE user (M4) |

**Tests:**
- Does this affect all users? → L2 (Platform). Template only? → L3 (Template). Only me? → L4 (Personal).
- WakaTime: L3 recommends (optional), L4 configures.
- New MCP server: L2 (Platform) — requires Pack DP entity + MAP.002.

**IntegrationGate:** Before integrating a new tool/agent → define perimeter + type + roles + products + processes. No answers → DO NOT install.

## 11. User repo ≠ platform knowledge core (IWE architecture)

| ❌ DO NOT confuse | ✅ Correct |
|------------------|-----------|
| "Data is at the user's side" = all computation | Repo = source (Git, Markdown, BYOB). Platform = computational core |
| User runs their own MCP server | User connects to Aisystant Gateway (one URL, Ory auth) |
| MimEcoSys knowledge in personal repo | MimEcoSys knowledge (FPF/SPF/ZP/Pack ecosystem) lives on the platform |

**Essence:** The user's repo is a source they own and can take away. Embeddings, search, agents, and the digital twin are computed and stored on the platform. The user does not run a local MCP server — they connect to the Gateway as a URL. Vendor-agnostic: changing the AI client (Claude → ChatGPT) does not lose context.
**Test:** "If the network is removed — what does the user retain?" → only sources (Markdown). Search, agents, and the digital twin are unavailable.
**Related:** WP-158 (C4 diagrams), WP-189 (MCP architecture), ADR-018 (BYOB).

## 12. Pack content ≠ Governance content

| Pack (source-of-truth) | Governance (management) |
|---|---|
| **What is true** in the domain | **What we do** in the project |
| Knowledge, architectures, methods | Plans, timelines, registries |
| Universal (another project) | Local (this project) |

**Test 1:** Can it be used in another project? Yes → Pack. No → Governance.
**Test 2:** "How is it structured?" → Pack. "What are we doing?" → Governance.

## 13. Principle levels: 0 ≠ 1 ≠ 2 ≠ 3

| Level | What | Repo type | Framework |
|-------|------|-----------|-----------|
| 0 (zeroth) | Trans-disciplinary meta-constraints | Foundation (ZP) | None |
| 1 (first) | Foundational bases of disciplines | Framework (FPF) | = bundle with principles |
| 2 (second) | Principles of knowledge domains | Pack | SPF (separately) |
| 3 (third) | Situational, project-specific | Downstream | S2R and others (multiple) |

**Test:** Works in any domain? → zeroth. In any discipline? → first. In a specific domain? → second. In a specific project? → third.

> Pack = second principles. Downstream = third principles. Details: `ZP/README.md`

## 14. Exocortex ≠ IWE

| Exocortex | IWE |
|---|---|
| Subsystem: memory and instructions (CLAUDE.md + memory/) | Environment: all 5 architectural views (DP.IWE.001 §3) |
| 2 views: Systems (files) + Descriptions (content) | 5 views: + Roles + Methods + Work Products |
| componentOf IWE | The whole |

**Test:** Does it only involve instruction/memory files? → Exocortex. Does it involve roles, methods, or Work Products? → IWE.

**Marketing synonym:** "Exocortex 2.0" is acceptable in public-facing texts as a synonym for IWE. Do not use it in the platform's domain language.

## 15. Prosthesis ≠ Exoskeleton (AI–human interaction pattern)

| Prosthesis | Exoskeleton |
|---|---|
| AI replaces the thinking function | AI augments the thinking function |
| Input: "What should I do?" → Output: ready answer | Input: "Here is what I think" → Output: augmentation |
| Human accepts/rejects | Human thinks independently; AI augments |
| Result: task done, human did not learn | Result: task done + human became more competent |
| Atrophy: ability to see affordances degrades | Growth: ability to see affordances is trained |

**Three exoskeleton mechanisms:**
1. **Surfacing, not generating** — AI shows the user's own knowledge at the right moment; it does not generate its own
2. **Questions, not answers** — for strategic decisions, AI asks "what do you think?" before giving an answer
3. **Fading scaffolding** — assistance decreases as competence grows

**IWE design principle (DP.ARCH.001 #21):** IWE is an exoskeleton, not a prosthesis. Criterion: after the interaction, the user became more competent.

**Test:** After the interaction, who became smarter — the user, or did only the AI receive more data?

## 16. Three task classes by verification cost (Levenchuk 2026)

| Class | Verification | AI autonomy | Example |
|-------|-------------|-------------|---------|
| **Closed-loop** (tests) | Cheap, automatic | High (commoditized) | Code with unit tests, mathematics, cryptography |
| **Open-loop** (engineering) | Expensive, delayed | Medium (humans + agents) | Mars rover, product, real SE |
| **Problem framing** | Unknown (evolution) | Low (humans lead) | Strategy, "development for the developed" |

**Consequence for IWE:** The platform operates in classes 2 and 3. Class 1 is commoditized — not the focus.
**Consequence for coordination:** Class 2 requires a process framework (standard work session, WP, captures). Class 3 requires creativity with checkpoints (seminars, exocortex).
**Brandolini's Law:** Generating nonsense is cheap; refuting it is expensive. In classes 2–3, verification costs as much as or more than generation.

**Test:** How much does it cost to verify a solution compared to generating it? Cheap → class 1. Expensive → class 2. Unknown → class 3.

## 17. Verification ≠ Validation (VR.D.001)

| Verification | Validation |
|---|---|
| "Is it done **correctly**?" (conformance to a reference) | "Is the **right thing** done?" (fitness for purpose) |
| Reference: specification, Pack entity, principles | Reference: user need, goal |
| Can be automated by an agent | More often requires a human |

**FM:** Replacing verification with validation — an artifact "works" (valid) but violates principles (not verified).

## 18. Audit ≠ Review (VR.D.002)

| Audit | Review |
|---|---|
| Systematic sweep: **completeness** (coverage) | Expert assessment: **quality** (depth) |
| Role: R24 Auditor | Role: R25 Reviewer |
| Automatable (Haiku/Sonnet) | Requires expertise (Opus/human) |

**Rule:** Audit first (is everything present?), then review (is it correct?).

## 19. Description ≠ Knowledge

| Description (artifact) | Knowledge (capability) |
|---|---|
| In a repository (FPF, SPF, Pack) | In an agent (human, AI) |
| Copyable | Requires learning |
| Verified by reading | Verified by performing a task |

**Test:** Can it be transmitted as a file? Yes → description. No → knowledge.
Details: `PACK-personal/.../01B-distinctions.md` D.013, `PD.FORM.004`

## 20. System ≠ episteme

| ❌ DO NOT confuse | ✅ Correct | Test |
|------------------|-----------|------|
| System = a knowledge domain | **System** ≠ episteme | Can you point to its boundary in space? |
| "System of thinking" | Systems Thinking is a method, not a system | Does the "system" have 4D boundaries? |
| "Management system" = a practice | Distinguish: organizational system vs management practice | Does it have an owner, inputs, outputs? |

**Common case:** "knowledge system" — ❌. Knowledge is not a system (no 4D boundaries). Correct: "exocortex" (a specific system) or "set of descriptions" (repository content).

**Common case:** "type system" — ❌. Types are a classification, not a physical object. Correct: "typing," "four types," "repository classification."

## 21. Method ≠ Tool

| ❌ | ✅ |
|---|---|
| "I do Toggl" | "I track time in Toggl" |
| "Switched from tracking to Clockify" | Changed the tool, not the method |

**Test:** Can the method be described without naming the tool?

## 22. Work Product ≠ description

| ❌ | ✅ |
|---|---|
| "I have a strategy" (no document) | Narrative ≠ product |
| "My architecture is minimalist" | Words ≠ artifact |

**Test:** Can this be handed to another person without words?

## 23. Accounting ≠ Planning

| Accounting | Planning |
|---|---|
| What was (past) | What should be (future) |
| Descriptive | Prescriptive |

**Test:** Is this recording a fact or an intention?

## 24. Problem ≠ Task ≠ Work Specification ≠ Work (4 levels, DP.D.053)

> **The key skill of the AI era:** converting a Problem into a Task through systems modeling.
> The AI autopilot accelerates Task→Work, but does not make the Problem→Task transition.

| Level | Definition | Characteristic |
|-------|-----------|----------------|
| **Problem** | Impasse: it is unclear which method to apply | Requires diagnosis and modeling |
| **Task** | The method is clear; the result is unknown | Ready for execution |
| **Work Specification** | Specification: performer + method + deadline + Work Product | Contract between customer and performer |
| **Work** | What actually happens in the physical world | May diverge from the Work Specification |

**Key distinction of the AI era:**
- AI autopilot (LLM generator): solves Task → Work (output may be wrong)
- AI exoskeleton (LLM with human gate): assists Problem → Task (augments thinking)

**Test 1:** Do I understand which method to apply? Yes → Task. No → Problem.

**Test 2:** Did the AI answer my original question or a simplified version of it? A simplified version → the Problem has not been converted.

**Details:** DP.D.053, `.claude/rules/distinctions.md`, HD #27

## 25. Control role ≠ Operational role (DP.D.080)

| Control | Operational |
|---|---|
| Observes, records, delivers a report | Acts on, changes state |
| Read-only to the object | Write: brings to standard |
| Invariant: independence | Invariant: idempotency |
| Has an explicit report recipient | No recipient — the change is the result |
| Examples: R23–R26 (VR), accounting, audit | Examples: R8 Synchronizer, R11 Configurator |

**Test:** "Did anything change in the inspected system after the role did its work?"
- No → control role
- Yes → operational role

**Why it matters:** An auditor who fixes what they inspect loses independence. An operational role without change is inventory, not throughput. Mixing the two destroys both invariants.

**Details:** DP.D.080, DP.KR.030

---

## 26. System-in-role ≠ Role (FPF A.2.1, R5:2761)

> From WP-352 phase 3. Key element of the notation `system#role:context`.

| ❌ | ✅ |
|---|---|
| "The Builder role did the work" | "Ivanov in the role of Builder did the work" |
| "The method determines who works" | "The role determines contextual participation; the system-in-role does the work" |
| "The project's System of Interest is a special type of system" | "The project's System of Interest is a role that some system plays in the context of the project" |

**Notation:** `physical_system#role:context`. Example: `Ivanov#builder:project_Alpha`.

**Test 1:** "Did the role do something?" — No. The role defines the method and expectations. It does not act by itself.
**Test 2:** "Is this a class of systems or a Functional Position?" — Functional Position → role.

**Details:** FPF A.2.1, `.claude/rules/distinctions.md` (System-in-role ≠ Role)

---

## 30. Method ≠ Work (FPF A.15, R5:2873)

> From WP-352 phase 3. Complements HD #21 (Method ≠ Tool) — a different axis of confusion.

| ❌ | ✅ |
|---|---|
| "The Scrum method completed the task" | "The team in the developer role applied Scrum and completed the task" |
| "The method did not work" | "The system in the role did not apply the method correctly" |
| "Practice/style/type of labor" in definitions | "Method" is the primary term; practice/culture/style are synonyms with nuances |

**Test:** "Who/what did the work?" — The system in the role (HD #26), not the method. The method defines the way.

**Details:** FPF A.15 Role-Method-Work Alignment, HD #26

---

## 31. "Service" ≠ Method ≠ Function (FPF A.6.P, R5)

> From WP-352 phase 3. "Service" is an ambiguous word, not a distinct FPF entity.

**Common meanings of the word "service" (FPF A.6.P §4.11a):**

| Possible referent | Direct owner |
|-------------------|-------------|
| Content of a promise | `U.PromiseContent` (A.2.3) |
| Provider role or assignment | `U.Role` / `U.RoleAssignment` (A.2 / A.2.1) |
| Method of delivery | `U.Method` (A.3.1) |
| Work of delivery | `U.Work` (A.15.1) |
| Evidence and result assessment | direct evidence/evaluation relations |

**Polysemy:** in MAP.002, "service" may mean an IT module or an entry point. FPF does not assign the word a default referent: first name the specific object or relation, then apply its direct rule. DP.D.039 preserves the local distinction.

**Test:** "What exactly does the word 'service' refer to in this phrase?" If the answer does not name a specific promise, role/assignment, method, work, carrier, state, or relation — the statement has not yet been resolved.

**Details:** FPF A.6.P §4.11a, `.claude/rules/distinctions.md` (Service ≠ method)

---

## 32. Mastery ≠ Mastery stage (FPF A.1.SCR, R9:43)

> From WP-352 phase 3. "Mastery" is an ambiguous word, not a distinct entity type: FPF explicitly prohibits deriving `U.Mastery` from a single noun.

| What "mastery" may refer to | Where to route |
|-----------------------------|----------------|
| Capability of a specific carrier | `U.Capability` (A.2.2) |
| Training or practice | Method and specific `U.Work` |
| Verification of achieved quality | Assessment and its evidence |
| Precise physical/operational integral carrier | A.1/A.1.SCR, only if the decision depends on its systemic nature |
| Mastery stage | A measurable characteristic of execution quality |

**Test:** "What exactly is being developed or measured here?"
- Carrier capability → `U.Capability`
- Specific training → method/work
- Execution quality → measurable characteristic
- Proposed integral system → A.1.SCR, without substituting capability or person

**Details:** FPF A.1.SCR §§0, 4–5; R9:43; `.claude/rules/distinctions.md` (Mastery ≠ Mastery stage)
---

## 33. `primary_program` in profile.md — input ≠ output (peer session 2026-05-31-31)

> A subtle clarification of HD §"Development program ≠ Primary key for guide selection" (distinctions.md). After peer-19, `primary_program: "research"` was added to the pilot's `personal-guide/profile.md` as a self-declaration. This is **mixing model and interface**: treating the program as an **input** turns it into a filter rather than a derivative of analysis.

| `primary_program` as input | `program_tag_derived` as output |
|---|---|
| Written to `profile.md` as pilot self-declaration | Written to `lesson/YYYY-MM-DD.md` by Tailor after rendering |
| Routing key: render reads it → selects 1 branch | Result metadata: "which program dominates now" |
| Lifecycle = before analysis | Lifecycle = after analysis |
| Example of violation: peer-19 phase-mpr-a dispatcher by `pilot.primary_program` | Example of correct usage: lesson frontmatter `program_tag_derived: "IR + work mentoring"` |

**Channel specifics:**
- **Universal channel** (guide.system-school.ru): no concept of "pilot's program." Shows LR+RR+IR as parallel navigation branches. Routing by `primary_program` = false constraint.
- **Personal channel** (`personal-guide/lesson/`): no concept of "pilot's program" on input. Tailor composes "today's guide" via polyroot — lookup in seeds of all applicable programs + merge by `(stage, domain, current_request, dissatisfactions, w_reflection)`. Program is an output tag, not a routing key on input.

**Test:** "Is this field read BEFORE rendering to choose a path, or written AFTER rendering as result metadata?"
- Read BEFORE → violation (program as routing key)
- Written AFTER → correct (program as output tag)

**Utilities that do not violate the distinction:**
- `_safe_seed_path(filename)` — path-traversal guard, program-agnostic.
- `resolve_seeds_by_contract(program, stage, domain, roadmap, mode)` — lookup in Pack-personal seeds by (stage, domain). Called N times with different roadmaps for polyroot composition, not once with one program.
- `load_program_roadmap(program)` — reads the DS-program roadmap.yaml. Not a routing key by itself.

**Distinction-violating utilities (deprecated 2026-05-31 peer-31):**
- `resolve_program(pilot)` — reads `pilot.primary_program`. This is a routing key. Deprecated; the sole consumer (`render_pilot()`) no longer calls it.

**Known limitation (peer-31):** existing managed pilots (including the platform author's account) receive rendering via the legacy LR flow (via `generate_guide` / `plan_horizon`) until the polyroot composition phase is implemented. The MShS-stub (phase-A hotfix) masks this for MShS pilots. This is a deferral, not a bug — fix on S2 implementation (program-tag selection from runtime analysis) in the polyroot phase.

**Details:** `.claude/rules/distinctions.md` §"Development program ≠ Primary key for guide selection", `sessions/2026-05/2026-05-31-31-program-tag-not-routing/report.md`.

## 34. SPF ≠ Pack (framework ≠ result); origin axis ≠ scope axis


- **SPF ≠ Pack (framework ≠ its result).** `SPF` is a framework for second/domain principles: requirements + process (`SPF/`), defines the form and domain criteria. `Pack` is the result of applying SPF — a populated domain textbook (`SPF/README.md`: "Pack is the result of applying SPF"). A specialization of A.7 (Method ≠ Tool, Object ≠ Description).
- **Pack = Levenchuk's DPF (NOT SPF = DPF — that earlier claim is incorrect).** Levenchuk's "DPF" ("domain textbook," "second principles") is the populated content = IWE `Pack`. IWE `SPF` is the machine that produces Packs; Levenchuk does not extract it separately — it lives inside FPF (E.8/E.10/F.18/E.21). "Second" = "domain" (synonyms); no need to abandon the term. Asymmetry: `FPF` = framework + content; `SPF` = framework only; `Pack` = content only.
- **Two axes, not one.** `Base/Pack/DS` cut by origin/owner (fallback chain `DS→Pack→Base`). `FPF/DPF/LPF` cut by scope (universal→domain→local). Use both axes together; do not substitute one for the other. `Base` ⊇ {ZP, FPF, SPF, FMT-*} — broader than one level. `PACK-agent-rules` ≈ LPF (marked `type: pack` → reclassify before promotion).

**Test:** "Framework or its result?" → SPF / Pack. "About owner or about scope?" → Base/Pack/DS / FPF/DPF/LPF.

## 35. One authoritative owner ≠ one literal location (OwnerIntegrity)

> One fact — one **authoritative** owner. What is prohibited is not text repetition per se, but multiple independently editable carriers each claiming to be true.

| Carrier type | Who changes the fact | Manual editing of copy permitted | What prevents drift | Required marker |
|---|---|---|---|---|
| **Authoritative carrier** | The designated owner of the fact | Yes, only here | One writer and an explicit reason for change | Owner/source-of-truth in the contract or frontmatter |
| **Derived copy** | Only the generator from the authoritative carrier | No | One-way automatic synchronization and divergence check | `generated`, source command, and prohibition on manual editing |
| **Partial summary** | The document's author, for their own reading purpose | Yes, but it does not become a full source | Explicit reference to the authoritative carrier; the source wins in any dispute | Reference and an explicit boundary of the summary |

### Three limits of the literal "one location" rule

1. **The boundary of a fact is defined by its owner and the reason for change, not by text identity.** The same string in two contexts may express different local decisions; different formulations may duplicate one authoritative fact.
2. **A derived copy is legitimate with one-way automatic synchronization.** For example, `AGENTS.md` may be generated from `CLAUDE.md` if the generator is the sole writer of the copy and divergence is detected automatically.
3. **A summary is acceptable for the sake of reading cost.** A tutorial, an instruction, and a reference serve different purposes; a short summary does not compete with the source as long as it explicitly references it and does not claim to be the full contract.

### Violation and safe forms

- **Unmanaged duplicate — not a fourth carrier class, but a violation state:** two manually editable copies of one rule where an update requires remembering both locations.
- **Safe derived copy:** the full contract is stored in one place; the copy is generated and verified automatically.
- **Safe summary:** a hot trigger line briefly conveys the condition and references the full lazy rule.

Formal prototypes: data normalization eliminates update anomalies; DRY requires a single, unambiguous, authoritative representation; the principle "duplication is cheaper than the wrong abstraction" distinguishes repetition from erroneous unification; transclusion demonstrates legitimate derivation without a second owner.

**Test:** "This fact changed — how many locations must be updated by hand?" One → the schema preserves OwnerIntegrity. Two, and you must remember both → the violation is already embedded.
