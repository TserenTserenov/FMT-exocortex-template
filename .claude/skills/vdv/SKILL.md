---
agents: single
argument-hint: '[build | audit] [description of a process or activity]'
browser_safe: true
description: The VDV Skill is a generator and auditor for staged process descriptions
  based on the 6 Input·Action·Output principles. Use it to build a new process description
  (/vdv build) or to audit a ready-made description (/vdv audit).
gates_enforced: []
gates_rationale: operational skill; WP Gate applicable only when creating a new WP,
  not for operational calls
gates_required: []
interaction: multi-step
layer: L1
name: vdv
routing:
  deterministic: false
  executor: sonnet
service_clause: DP.SC.052
status: active
tests: ./test_cases.md
triggers:
  phrases:
  - audit the process using VDV
  - build a process description
  - audit of a staged process
  slash:
  - /vdv
  - /vdv build
  - /vdv audit
version: 1.0.0
---

# VDV Skill (Input·Action·Output)

> **Service Clause:** DP.SC.052  
> Source of principles: PD.METHOD.008 §174-230 (strategy cascade v9 as reference test case)

Execute: $ARGUMENTS

---

## When to use

The VDV Skill is a generator and auditor for staged process descriptions based on the 6 Input·Action·Output principles. Use it to build a new process description (`/vdv build`) or to audit a ready-made description (`/vdv audit`).

## VDV Principles (audit reference)

Six invariants used in both modes:

| # | Principle | Statement | Violation test |
|---|-----------|-----------|----------------|
| 1 | **Triad at every stage** | Each stage has an Input, an Action, and an Output. Missing one means incomplete. | One of the three fields is absent or empty |
| 2 | **Output→Input chaining** | The output of a stage must become the input of at least one subsequent stage. | The output of stage N does not appear in the Input of any later stage (and is not marked `(external)` / `(perimeter promise)`) |
| 3 | **Input invariant** | Input = outputs of preceding stages + stable documents + "plan for comparison". An artifact with no producer and no `(external)` label signals a missing stage. | The Input of stage N contains an artifact that is not in the Output of any preceding stage and carries no `(external)` label |
| 4 | **Bidirectional traceability** | Every artifact has a producer and a consumer. No consumer — redundant. No producer and no `(external)` — missing stage. | An artifact in an Output has no consumer in the Inputs of subsequent stages (and is not a perimeter promise) |
| 5 | **Carry-over** | Incomplete work carries over into the Input of the next iteration of the same perimeter. | Repeating process (rhythm > 1 iteration): the input of the first stage does not include `carry-over from previous iteration` |
| 6 | **Anti-dummy** | A stage has direct or indirect traceability to the perimeter promise. Remove the stage — does the promise break? If not — dummy candidate. | Check: remove the stage — does the perimeter promise break? No → ❌ dummy candidate. The stage traces neither directly (output = promise) nor indirectly (output chain leads to promise) |

> **Special cases for principle 5:** single-iteration process (one-shot, no cycle) — principle 5 does not apply; mark ⏸ with explanation.  
> **Special cases for principle 6:** perimeter promise is unknown — ⚠️ + request clarification.

---

## Algorithm

## Mode `/vdv build` — Generation

### Algorithm (approach C)

### Step 1. Understand the activity

Read the activity description from $ARGUMENTS. If the description is too brief (fewer than 1 sentence, or no result/output is mentioned) — request clarification:

> "Please describe the activity in more detail: what happens, what is the main result, is there a repeating rhythm?"

### Step 2. Extract stages (quick draft)

Derive a tentative set of stages from the description. Rules:
- Each stage = one semantic action with a verifiable artifact as output
- First stage: mark inputs as `(external)` if they are not produced inside the process
- Specify rhythm if known from context, otherwise `—`
- Format: compact markdown table, columns strictly in order: `# | Stage | Rhythm | Input | Action | Output`

### Step 3. Self-audit principles 1–4

Immediately after the draft, run principles 1–4 against the built table. Show:

```
Preliminary audit (principles 1–4):
P1 (triad): ✅ / ⚠️ / ❌ — <findings>
P2 (chaining): ✅ / ⚠️ / ❌ — <findings>
P3 (input invariant): ✅ / ⚠️ / ❌ — <findings>
P4 (traceability): ✅ / ⚠️ / ❌ — <findings>
P5 (carry-over): ⏸ will be checked after structure is confirmed
P6 (anti-dummy): ⏸ will be checked after perimeter promise is confirmed
```

### Step 4. Inline traceability

After the VDV table, output a compact block:

```
| Artifact | Produced at stage | Consumed at stages |
|----------|-------------------|--------------------|
| Name     | N. Stage          | M. Stage / → perimeter promise / → carry-over (next iteration) |
```

Dangling artifacts (no consumer inside the perimeter) are labeled:
- `→ perimeter promise` — terminal output, serves as the promise
- `→ carry-over (next iteration)` — flows into the next process cycle (P5)
- `→ ❌ consumer not found` — violation of P4

### Step 5. Clarification and final audit

After user edits — run a full audit (steps 1–5 of audit mode) including principles 5–6.

---

## Mode `/vdv audit` — Audit

### Algorithm

### Step 1. Receive the description

Input text from $ARGUMENTS — a stage table or a text description. If it does not contain an explicit stage structure — ask: "Please identify the stages or provide a table with Input/Action/Output columns."

### Step 2. Derive the perimeter promise

Find all outputs that are not the input of any subsequent stage = candidates for the perimeter promise. Show:

> "I see the perimeter promise as: `<list of terminal outputs>`. Is that correct?"

If the user disagrees — clarify. If there are multiple terminal outputs — ask the user to select or confirm all of them.

### Step 3. Run the 6 principles

For each stage and each artifact, check all 6 principles. Verdict format:

```
## Process audit: <name>

### Principle 1: Triad at every stage
✅ All stages have a triad / ❌ Violations:
- Stage N "<name>": missing <Input | Action | Output>
  Fix: <specific suggestion>

### Principle 2: Output→Input chaining
...

### Principle 3: Input invariant
...

### Principle 4: Bidirectional traceability
...

### Principle 5: Carry-over
✅ / ⚠️ / ❌ / ⏸ <explanation>

### Principle 6: Anti-dummy
Perimeter promise: <what was accepted>
✅ / ⚠️ / ❌ — <for each ❌ stage: traceability to promise not found>
  Fix: <remove stage or explicitly link to promise>

---
Summary: ✅ <N principles OK> | ⚠️ <M warnings> | ❌ <K violations>
```

### Step 4. Optional: propose a fix

If there are ❌ violations — propose a corrected stage table with fixes applied.

---

## Reference `/vdv`

```
VDV Skill (Input·Action·Output) — WP-413, DP.SC.052

Modes:
  /vdv build <activity description>  — build a process description
  /vdv audit <stage description>      — audit against 6 VDV principles

6 principles: triad · chaining · input invariant · traceability · carry-over · anti-dummy

Reference test case: strategy cascade v9 (PD.METHOD.008 §185-189)
Development test cases: test_cases.md
```

<!-- USER-SPACE -->
<!-- /USER-SPACE -->
