---
description: 'Reference guide for FPF patterns applicable in IWE: ecosystem composition
  (Core + DPF suites), key Part C patterns (C.11–C.28), terminology translation'
domains:
- reference
fpf_synced_at: 2026-10-11
fpf_version: e2c6ac1e97dae9b9f54f707477f7d86a12d91852
horizon: warm
name: fpf-reference
originSessionId: 9a0e726a-951e-4408-9e02-94d7eeffbf74
owner: user
schema_version: 1
status: active
type: reference
valid_from: 2026-10-11
---
# FPF (First Principles Framework) — Reference Guide

> Source: repository `ailev/FPF`, local copy `{{HOME_DIR}}/IWE/FPF/`, revision pinned by the `fpf_version` field in frontmatter. Size and line count are intentionally not duplicated here.

## When to Read FPF

- When working with Level 1 concepts (meta-ontology)
- When basic distinctions are unclear (Role/Method/Work, System/Episteme)
- When a precise pattern formulation is needed (A.*, B.*, etc.)
- When creating or reviewing a Pack for FPF compliance

## How to Read

- Do NOT read in full
- First locate the heading of the required part: `grep -nE '^#{1,4} .*Part [A-G]' FPF-Spec.md`
- Then search for the exact pattern code or heading (e.g., `grep -n 'A\.7' FPF-Spec.md`) and read a limited range around the match

## FPF Repository Composition

FPF is not a single file. It is a core plus a set of Domain Principles Framework (DPF) suites. The composition corresponds to `fpf_version` in frontmatter:

- **FPF Core** — `FPF-Spec.md`, parts Part A–G (structure below)
- **Foundational Thinking DPF Suite** — `Foundational Thinking DPF Suite/`: 5 foundational DPFs (mathematical practice, mathematical modeling, physical, computational, and notational thinking) + `README.md` and `FOUNDATIONAL-THINKING-DPF-SUITE-REFERENCE.md`
- **Engineering DPF Suite** — `Engineering DPF Suite/`: 27 domain frameworks (systems engineering, strategizing, methods engineering, human capability development, and others) + `README.md` and `ENGINEERING-DPF-SUITE-REFERENCE.md`
- **Narrativization DPF** — `Narrativization-and-Narrative-Studies-Principles-Framework.md` (narrativization)

### Entry Points in the FPF Repository

- `Readme.md` — section "What is in this repository": selecting a publication for a given task
- `USING-FPF.md` — "Using FPF and its DPF Suites": searching patterns by ID using rg, pattern section structure, linking methods via Suite Reference
- In each suite: `README.md` (overview) + `*-SUITE-REFERENCE.md` (relationships between DPFs in the suite)

### Searching Knowledge by DPF

Search by pattern ID across the entire repository, not only in Core:

```bash
rg -n 'HCD\.1' {{HOME_DIR}}/IWE/FPF        # pattern from Engineering DPF Suite
rg -n 'A\.7' {{HOME_DIR}}/IWE/FPF/FPF-Spec.md  # Core pattern
```

## FPF Core Structure (FPF-Spec.md)

- **Part A** — Kernel: Holon, BoundedContext, Role-Method-Work, Signature Stack
- **Part B** — Aggregation (Γ), Trust (F-G-R), Evolution Loop
- **Part C** — Domain extensions: Sys-CAL, KD-CAL, Kind-CAL, NQD-CAL, CausalUse-CAL
- **Part D** — Ethics & Conflict
- **Part E** — Constitution & Authoring
- **Part F** — Terminology unification (UTS, Bridges)
- **Part G** — SoTA Kit

### Key Part C Patterns (Relevant to IWE)

| Code | Name | Status | Purpose in IWE |
|------|------|--------|----------------|
| C.11 | Decision Theory (Decsn-CAL) | Stable | Alternative selection in ArchGate, Strategy Session |
| C.16 | MM-CHR Measurement & Metrics | Stable | RCS measurements, baseline, pilot metrics |
| C.19 | Explore–Exploit Governor | Stable | Pool policy for experiments and methods |
| C.24 | Agentic Tool-Use & Call-Planning | Stable | Claude Code tool-use budget protocol |
| C.26 | Quantum-Like Modeling Lens | Stable | Probe-coupled interactions, order effects |
| C.27 | Temporal Claim Adequacy | Stable | Claims about speed, rhythm, trends |
| C.28 | **CausalUse-CAL** | Stable | **Causal claims: M1 improves X, lever yields Y** |

## Systems Terminology

| Russian | English (FPF) | Description |
|---------|---------------|-------------|
| Supersystem | Suprasystem | Contains SoI (∋) |
| System of Interest | System-of-Interest (SoI) | What we are building |
| Creation system | Constructor | Creates SoI (→) |

## Universal Distinctions

| Distinction | Why It Matters |
|-------------|---------------|
| Object ≠ Model | A model is a simplification of reality |
| Model ≠ Data | Structure vs. values |
| Data ≠ Representation | Internal vs. external |
| Method ≠ Tool | Way of acting vs. means |
| Method ≠ Scenario | What to do vs. step-by-step plan |
| Knowledge ≠ Training | Pack vs. course |
| Knowledge ≠ Information | Formalized vs. raw data |
| Kinds ≠ Characteristics | Classification vs. measurable quality |

## Working Principles

| Principle | Code | Description |
|-----------|------|-------------|
| Holonic approach | A.1 | Everything is simultaneously part and whole |
| Bounded Context | A.1.1 | A term is defined within the boundaries of a context |
| Strict distinctions | A.7 | Role ≠ Method ≠ Work |
| ADI cycle | B.5 | Abduction → Deduction → Induction |
| CausalUse-CAL | C.28 | Causal claims: rung, evidence base, permitted use |

## C.28 CausalUse-CAL — Practical Application in IWE

> Added to FPF 2026-05-05 (pull +4138 lines). Source ailev: systemsworld.club.
> Full text: `FPF-Spec.md:45197`

**Core idea.** Three collapses that C.28 prevents:
1. **Rung collapse** — association, intervention, and counterfactual mixed into one "cause X→Y"
2. **Support collapse** — observation, experiment, and simulation treated as a single "evidence base"
3. **Use collapse** — a result valid for reporting is used for deployment or certification

**Ladder of causation (Pearl Causal Hierarchy):**
| Rung | Question | Example in IWE |
|------|----------|---------------|
| 1 Association | "What co-occurs?" | "Pilots with M1 reach stage 3 more often" |
| 2 Intervention | "What will happen if we do X?" | "Adding M1 will raise a pilot's baseline" |
| 3 Counterfactual | "What would have happened if X?" | "Without M4 the pilot would not have reached caliber 3" |

**C.28 activation** — when a claim changes what is permitted for publication, deployment, audit, or benchmarking.

**Quick test (CausalUseTriageRecord):**
1. Is there a causal use? yes / no / unclear
2. Which rung? (1 = association / 2 = intervention / 3 = counterfactual)
3. What is the evidence base? (observational / interventional / realized-counterfactual / identified-estimate / simulation-only)
4. What is permitted? What is NOT permitted? (supportedUse / unsupportedUse — always a pair)
5. nextMove: cheapStop (restate as association) or escalate (open DurableCard)

**Applications in IWE/Pack:**

| Context | Typical error | C.28 fix |
|---------|--------------|----------|
| WP-151 levers (M1/M4) | "M1 raises focus" — rung 2 without evidence | Rewrite as rung 1: "associated with baseline growth in sample N" |
| Tailor recommendations | "Add tomatoes — improve your stage" — rung 2 pretend | Add: "based on correlation in N=k pilots; no interventional data available" |
| ArchGate arguments | "If we implement X, we will get Y" — rung 3 without SCM | State rung, basis, and unsupportedUse explicitly |
| Strategy Session | "This practice worked in April" | Rung 1 (association); rival causes not excluded |
| dt_snapshot_rcs measurements | Snapshot ≠ causal evidence | basis = observationalAssociation, not interventional |

**Route in FPF:** C.28 → **builds on** A.10, B.3, C.11, C.19, C.24, C.26, C.27, D.5, G.5, G.9

## FPF → Engineering Language Translation

> Use this when presenting `/fpf` output. Users work in engineering terms, not FPF jargon.

| FPF term | Engineering equivalent | When you encounter it |
|----------|-----------------------|----------------------|
| Holon | Component with a defined boundary (part and whole) | A.1 — system decomposition |
| Bounded Context (A.1.1) | Context with a clear scope: its own language, its own rules | DDD, microservices |
| F-G-R (Fact/Guess/Rumor) | Fact / assumption / rumor — trust level for data | B.3 — decision evaluation |
| Role ≠ Method ≠ Work (A.7) | Who acts ≠ how they act ≠ a specific execution | Process design |
| Role Assignment (A.2.1) | System in a role: `system#role:context` — functional participation of a system; the role does not act on its own | Pack role ontology, distinctions.md HD #26 |
| Service-word restoration (A.6.P §4.11a) | "Service" does not fix one FPF referent: restore the promise, role/purpose, method, work, carrier, state, evidence, or direct relation | DP services MAP.002 vs. precise FPF objects and relations |
| Mastery-word restoration (A.1.SCR) | `U.Mastery` is not introduced: distinguish the carrier's capability, training/work, assessment, quality characteristic, or the precise holistic carrier | PACK-personal cp.skl, distinctions.md HD #32 |
| Alpha | Key Work Product by which progress is tracked | Project management |
| Mereology | Part-whole relationship between components | Architecture, composition |
| Affordance | What a component allows a user to do | API design, UX |
| ADI cycle (B.5) | Hypothesis → verification by logic → verification by data | Decision-making (/think) |
| Lawful Comparison (A.19) | Comparing options against the same criteria | Architecture selection (/archgate) |
| Strict Distinction (A.7) | Different things get different names. Do not merge into one type or enum | Code review, naming |

## ailev ↔ IWE Terminology (DPF/SPF/TPF/LPF, WP-448 Phase 8)

> Anatoly Levenchuk (ailev) renamed Second Principles Framework to DPF (Domain Principles Framework), establishing the stack `FPF → DPF → LPF`. IWE does not plan to rename — only footnotes apply (CLAUDE.md §1, SPF/README.md). The table below is a translation dictionary for reading his texts.

| ailev term | IWE equivalent | Note |
|------------|----------------|------|
| DPF (Domain Principles Framework) | Pack (SPF instance) | formal equivalence, not a rename |
| TPF (Third Principles Framework) | DS + agent operational layer | process TPF vs. content TPF — see [[TPF ≠ DS]] |
| LPF (role practices of a specific carrier) | particular role practices (Lifework/ + operational fragments) | cross-cutting classification of fragments, not a separate container (WP-448 Phase 11) |
| `E.4.DPF` (authoring framework) | `SPF/pack-template/` + `SPF/process/01-11` | both define the form and the process of populating a domain |
| NSTD (method-card slots: Forces, Bias-Annotation, …) | `_method-card-template.md` (enrichment — WP-448 Phase 9) | our method card format is enriched with two sections modeled on NSTD |
| Narrativization | Guide Factory (WP-364) | method for converting structure into instructional text — referenced, not duplicated |

## Updating

Periodically run: `git -C {{HOME_DIR}}/IWE/FPF pull`. FPF is updated approximately every two weeks (upstream). After pulling, check `memory/fpf-term-map.yaml` for new renames (WP-481 Phase 11).
