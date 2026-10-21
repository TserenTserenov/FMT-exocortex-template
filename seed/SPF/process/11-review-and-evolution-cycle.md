# 11. Review and Evolution Cycle

> **FPF Reference:** B.4 (Canonical Evolution Loop: Run → Observe → Refine → Deploy)
> Also: B.5 (Reasoning Cycle: Abduction → Deduction → Induction)
> Full specification: `~/IWE/FPF/FPF-Spec.md`

## Purpose

Establish the ongoing cycle of review and evolution that keeps the pack current. A pack is never "done" — it is a living repository that must be maintained as domain understanding evolves.

**Relationship to FPF:** This process implements FPF B.4 (Canonical Evolution Loop). The pack goes through cycles: run → observe (identify issues) → refine (make changes) → deploy (publish). The cycle is infinite.

---

## Process as Cycle, Not Project

| Project View (Wrong) | Cycle View (Correct) |
|---------------------|---------------------|
| "Create pack, then done" | "Pack is continuously maintained" |
| "Version 1.0 is complete" | "Current version is best-so-far" |
| "Distinctions are settled" | "Distinctions may need refinement" |
| "Methods are documented" | "Methods may become outdated" |

The process diagram loops: Stage 11 returns to earlier stages.

---

## Types of Evolution

| Type | Trigger | Process Path |
|------|---------|--------------|
| **Extension** | Gap identified | 05 → 06 → 07/08/09 → 10 → 11 |
| **Refinement** | Ambiguity found | 03/04 → 10 → 11 |
| **Revision** | Evidence changes | 09 → 10 → 11 |
| **Deprecation** | Understanding superseded | 09 → 10 → 11 |
| **Restructure** | Boundaries need change | 02 → 03 → ... → 11 |

---

## When Distinctions Need Review

| Signal | Action |
|--------|--------|
| Confusion persists despite distinction | Refine or restate distinction |
| New failure mode does not map to distinction | May need new distinction |
| Distinction rarely referenced | May be unnecessary |
| Two distinctions overlap | Consolidate or clarify |
| FPF updates relevant distinction | Align with FPF |

Return to [03. Distinctions Work](03-distinctions-work.md).

---

## When Methods Need Review

| Signal | Action |
|--------|--------|
| Method description is misunderstood | Clarify definition |
| Method produces unexpected products | Review inputs/outputs |
| Method confused with other methods | Sharpen distinction |
| Method is never referenced | May be unnecessary |
| Better method understanding emerges | Update or deprecate |

Return to [07. Method and Product Extraction](07-method-and-product-extraction.md).

---

## When SoTA Needs Review

| Signal | Action |
|--------|--------|
| Revision criterion met | Change status |
| New evidence available | Re-evaluate status |
| Review date reached | Scheduled review |
| Related claim changes | Check consistency |

Return to [09. SoTA Annotation](09-sota-annotation.md).

---

## Scheduled Review

Establish review cadence:

| Review Type | Frequency | Focus |
|-------------|-----------|-------|
| **Map audit** | Every extraction | Links, counts, relationships |
| **SoTA review** | Per annotation schedule | Status currency |
| **Distinction review** | Quarterly | Are distinctions holding? |
| **Full pack review** | Annually | Overall coherence |

---

## How to Conduct Pack Review

### Step 1: Check SoTA Statuses

For each SoTA annotation:
- Is review date passed?
- Is revision criterion met?
- Has relevant evidence emerged?

### Step 2: Audit Map

- Do counts match actual files?
- Are all links valid?
- Are relationships current?

### Step 3: Review Distinctions

For each distinction:
- Is it still being violated (failure modes occurring)?
- Is it clear enough to apply?
- Does it conflict with newer understanding?

### Step 4: Identify Gaps

- Are there methods without failure modes?
- Are there failure modes without distinctions?
- Are there work products without methods?

### Step 5: Document Review Findings

Create review log entry (not in pack):

```
Review Date: YYYY-MM-DD
Reviewer: [name/agent]
Scope: [full / partial]
Findings:
- [Finding 1]
- [Finding 2]
Actions:
- [Action 1: Stage to return to]
- [Action 2: Stage to return to]
```

### Step 6: Execute Actions

Return to appropriate process stages for each action.

---

## Making Changes Without Destruction

| Do | Do Not |
|----|--------|
| Deprecate outdated content | Delete history |
| Add revision notes | Overwrite without trace |
| Maintain ID stability | Reuse IDs |
| Update map after changes | Leave map stale |
| Document rationale | Change silently |

### Deprecation Pattern

When content becomes outdated:

1. Change status to `deprecated` in YAML frontmatter
2. Add deprecation note with rationale
3. Link to replacement (if any)
4. Update SoTA if applicable
5. Update map to show deprecated status
6. Do NOT delete the file

```markdown
---
status: deprecated
deprecated_date: YYYY-MM-DD
deprecated_reason: Superseded by METHOD.003
replacement: PD.METHOD.003
---
```

---

## Inputs

| Input | Source | Required |
|-------|--------|----------|
| Current pack content | All pack files | Yes |
| Previous review log | Process records | If exists |
| External evidence | Domain developments | As available |

---

## Output: Work Products

| Product | Location |
|---------|----------|
| Review log | `/process/working/` (not in pack) |
| Updated content | Relevant pack files |
| Updated map | `/pack/<domain>/07-map/` |

---

## Completion Criteria

| Criterion | Test |
|-----------|------|
| SoTA statuses reviewed | All annotations checked |
| Map audited | Counts and links verified |
| Findings documented | Review log created |
| Actions identified | Next stages determined |
| Actions executed | Returns to stages completed |

---

## Typical Errors

### E1. No Review Cycle

**Symptom**: Pack created and never revisited.

**Problem**: Content becomes stale; SoTA statuses become lies.

**Correction**: Establish and follow review cadence.

### E2. Review Without Action

**Symptom**: Issues identified but nothing changes.

**Problem**: Review is theater, not process.

**Correction**: Every finding → action → stage return.

### E3. Destructive Changes

**Symptom**: Content deleted; IDs reused; history lost.

**Problem**: Downstream references break; traceability lost.

**Correction**: Deprecate, do not delete. IDs are forever.

### E4. Change Without Map Update

**Symptom**: Content changes but map shows old state.

**Problem**: Map becomes unreliable.

**Correction**: Map update is part of every change.

### E5. Skipping Deprecation

**Symptom**: Outdated content removed without deprecation.

**Problem**: No record of what was believed; history lost.

**Correction**: Always deprecate with rationale before removal.

---

## The Infinite Loop

The process never terminates. After any significant change:

```
... → 07/08/09 → 10 → 11 → (02/03/04/05/06) → 07/08/09 → 10 → 11 → ...
```

Stage 11 always asks: "What needs attention next?" and returns to the appropriate stage.

---

## Process as Living System

| The pack | The process |
|----------|-------------|
| Captures domain knowledge | Governs knowledge maintenance |
| Is the product | Is the production system |
| Changes when domain changes | Persists across changes |
| May be wrong about domain | May be inefficient |
| Evaluated by accuracy | Evaluated by effectiveness |

Both pack and process can be improved. This document describes the process; the process can itself be reviewed and updated (meta-process).
