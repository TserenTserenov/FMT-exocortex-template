---
browser_safe: true
description: Decompose work into stages with physical artifacts and acceptance checklists.
  Gap detector. Use when opening a WP ≥3h (open-loop/problem-framing) or on explicit
  request to break into stages. Executes R29 Decomposer role.
layer: L3
name: decompose
routing:
  deterministic: false
  executor: sonnet
status: active
triggers:
  phrases: []
  slash:
  - /decompose
version: 1.0.0
---

# /decompose — Decomposer (R29)

> **Role:** R29 Decomposer. **Carrier:** this Skill.
> **Goal:** break an activity into ≤4 stages with physical I/O and checklists. Detect gaps.

## When invoked

- **WP Gate:** WP ≥3h AND class ∈ {open-loop, problem-framing} → runs automatically after Step 4 of the Ritual (Step 4.5 protocol-open.md)
- **IntegrationGate:** new tool/agent/system → after Service Clause and Role
- **Strategy Session:** decomposing a large initiative (>1 week)
- **Explicit request:** `/decompose`, "break into stages"

## Algorithm (5 steps)

### Step 1. Context map (3–5 lines)

- **Who holds the roles:** initiator / performer / reviewer (by name or R-ID)
- **Top success criterion:** one verifiable phrase
- **Key constraints:** time / money / ethics / dependencies

### Step 2. Stage tree (≤4 nodes)

One line per stage: name + purpose. If >4 result — consolidate.

### Step 3. Stage breakdown

For each stage:

```
**Stage N: <name>**
- Input: <physical artifact>
- Method: <how we do it, reference to SOP/PROCESSES.md if available>
- Output: <physical artifact, distinct from input>
- Acceptance checklist (3–5 items):
  - [ ] criterion 1
  - [ ] criterion 2
  - [ ] criterion 3
- Roles:
  - <Name/R-ID> in the role of <role name>
```

### Step 4. Gap detector

For each stage, verify:
- Input and output are physical and **distinct**? ("understanding", "decision in one's head" — not allowed)
- Method is defined or requires clarification?
- Checklist has ≥3 items?
- Role Performer is assigned?

Each gap → block:
```
**Missing:** <what>
**Risk:** <what it threatens>
**Options:**
1. <lean — minimum effort>
2. <reliable — reduces risk>
3. <fast — saves time> (optional)
```

### Step 5. Optional detail (on request only)

Not included in the first output. Expanded on request:
- Risks and countermeasures
- Metrics (units, scale)
- Budget (hours, money)
- First 7 days (micro-plan)
- Signals to trigger reassembly

## Rules

1. **Physical I/O.** Input/output must be an artifact, document, file, photo, video, audio, money, signature, tracker label, commit, or PR. "Understanding" and "agreement in one's head" are not allowed.
2. **Plans ≠ Facts.** Intention (WorkPlan) and result (Work) are distinct artifacts stored in separate files.
3. **Role phrasing.** Not "you will do," but "<Name> in the role of <role name>." If the role is not in roles.md → mark as "(new role, requires registration in roles.md)."
4. **≤4 stages in the first output.** Deeper breakdown — on request.
5. **Checklist is mandatory.** A stage without a checklist is an intention, not a stage.
6. **Scope >10h or independent lifecycle** → recommend: (a) phases within a single WP, or (b) separate WPs. Registration via `/wp-new` is performed by the user, not the Decomposer.
7. **Output — in response, not to a file.** The main agent decides where to insert it: WP-context, dialogue, or another Skill.

## Distinctions (important)

- **vs R5 Architect:** The Architect evaluates solutions (via `/archgate`). The Decomposer breaks down activities.
- **vs R1 Strategist:** The Strategist plans at the week/month scale. The Decomposer works on a specific WP.
- **vs R28 Diagnostician:** The Diagnostician determines the Mastery stage. The Decomposer breaks down work — it does not diagnose people.
- **vs IntegrationGate:** IntegrationGate is a rule (when to decompose). The Decomposer is the executor (how).
