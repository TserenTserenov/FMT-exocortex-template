# 07. Method and Product Extraction

## Purpose

Transform "ready" candidates into pack files. This is the stage where analyzed knowledge becomes formal pack content. Methods and work products are extracted together because they are tightly coupled: methods produce products.

---

## When a Candidate Becomes a Method

A candidate is a **method** (not a scenario, habit, or tool) when:

| Criterion | Test |
|-----------|------|
| Repeatable | Can be performed again by same or different agent |
| Describable | Can be specified without reference to specific instance |
| Has inputs | Something is required to begin |
| Has outputs | Something is produced upon completion |
| Not tool-dependent | Method persists across tool changes |
| Not scenario | Describes "what and why," not "do this then that" |

### Method vs. Scenario

| Method | Scenario |
|--------|----------|
| "Time accounting registers time expenditures by category" | "Start your day by opening Toggl and clicking..." |
| What it is | How to do it (one way) |
| Inputs/outputs | Steps/instructions |
| Belongs in pack | Belongs downstream |

**If it has numbered steps, it is probably a scenario, not a method.**

---

## Inputs

| Input | Source | Required |
|-------|--------|----------|
| Ready candidates | Stage 06 | Yes |
| Distinctions | Stage 03 | Yes |
| Domain entities | Stage 04 | Yes |
| Method template | `/pack/_template/03-methods/` | Yes |
| Work product template | `/pack/_template/04-work-products/` | Yes |

---

## Activity

### 1. Select Ready Candidates

From Stage 06 candidate list, select candidates with:
- Status: `ready`
- Type: `method` or `work-product`
- Open questions: resolved or non-blocking

### 2. Assign Stable ID

| Item | Pattern | Example |
|------|---------|---------|
| Method | `<DOMAIN>.METHOD.<NNN>` | `PD.METHOD.001` |
| Work Product | `<DOMAIN>.WP.<NNN>` | `PD.WP.001` |

IDs are:
- Unique (never reused)
- Sequential within type
- Stable (never changed once assigned)

### 3. Create Method Card

File: `/pack/<domain>/03-methods/<ID>-<name>.md`

Required sections:

| Section | Content |
|---------|---------|
| YAML frontmatter | id, name, status, dates |
| Definition | What the method is (not how to do it) |
| Purpose | What function it serves |
| Forces | Competing tensions this method balances (WP-448 Phase 12, required since 2026-07-27) |
| Inputs | What is required |
| Outputs | What is produced (link to WP) |
| Applicability | When to use, when not to use |
| Related distinctions | Which distinctions structure this method |
| Bias-Annotation | Systematic distortion risked when applying this method (WP-448 Phase 12, required since 2026-07-27) |
| Failure modes | Which failures relate to this method |
| SoTA | Status and revision criterion |

### 4. Create Work Product Card

File: `/pack/<domain>/04-work-products/<ID>-<name>.md`

Required sections:

| Section | Content |
|---------|---------|
| YAML frontmatter | id, name, status, dates |
| Definition | What the product is |
| Purpose | What function it serves |
| Produced by | Which method creates it |
| Consumed by | Which roles/methods use it |
| Existence criteria | How to verify it exists |
| Quality criteria | How to assess adequacy |
| Anti-patterns | What this product is NOT |

### 5. Update Indexes

Update `/pack/<domain>/02-domain-entities/02C-methods-index.md`:
- Add row for new method
- Include ID, name, produces, prerequisites

### 6. Cross-Reference

Ensure bidirectional links:
- Method → Work Product (outputs)
- Work Product → Method (produced by)
- Method → Failure Modes (references)
- Method → Distinctions (uses)

---

## Output: Work Products

| Product | Location |
|---------|----------|
| Method card(s) | `/pack/<domain>/03-methods/` |
| Work product card(s) | `/pack/<domain>/04-work-products/` |
| Updated methods index | `/pack/<domain>/02-domain-entities/02C-methods-index.md` |

---

## Completion Criteria

| Criterion | Test |
|-----------|------|
| Method is not scenario | No numbered steps; describes what, not how |
| Method has inputs/outputs | Both sections filled |
| Work product is observable | Existence criteria specified |
| IDs assigned correctly | Follows naming convention |
| Index updated | New entries in methods index |
| Cross-references valid | All links resolve |
| SoTA assigned | Status and revision criterion present |

---

## Typical Errors

### E1. Method Is Actually a Scenario

**Symptom**: "Step 1: Open your tracker. Step 2: Record the activity..."

**Problem**: This is a scenario (how-to), not a method (what-is).

**Correction**: Remove steps; describe what the method achieves and requires.

### E2. Method Is Actually a Tool

**Symptom**: "Method: Toggl" or "Method: Pomodoro Timer"

**Problem**: Tools are artifacts; methods are ways of acting.

**Correction**: What method does the tool support? Document that method.

### E3. Work Product Is a Description

**Symptom**: "The work product is a sense of accomplishment."

**Problem**: Cannot observe "sense"; it is a feeling, not an artifact.

**Correction**: What artifact exists? What can be shown to another person?

### E4. Missing Existence Criteria

**Symptom**: Work product defined but no way to verify it exists.

**Problem**: Cannot distinguish having the product from describing it.

**Correction**: Add "Existence criteria: How to verify this artifact exists."

### E5. No Cross-References

**Symptom**: Method and work product created but not linked.

**Problem**: Relationships invisible; navigation broken.

**Correction**: Add bidirectional links; check that all resolve.

### E6. Copying Candidate Text

**Symptom**: Pack file contains same text as candidate formalization.

**Problem**: Candidate formalization is draft; pack file should be refined.

**Correction**: Rewrite for pack; ensure template compliance.

### E7. Skipping Index Update

**Symptom**: Method exists but not in methods index.

**Problem**: Method undiscoverable; map will be incomplete.

**Correction**: Always update index when creating method.

---

## Method Extraction Checklist

Before committing a new method:

- [ ] Definition describes what, not how
- [ ] No numbered steps (not a scenario)
- [ ] Forces filled (≥1 named tension, not a placeholder)
- [ ] Inputs specified
- [ ] Outputs specified (linked to WP)
- [ ] Applicability boundaries stated
- [ ] At least one related distinction linked
- [ ] Bias-Annotation filled (≥1 named distortion + direction, not a placeholder)
- [ ] Failure modes referenced
- [ ] SoTA status with revision criterion
- [ ] ID follows convention
- [ ] Index updated

---

## Transition to Next Stage

When Method and Product Extraction is complete:
- Method cards exist in `03-methods/`
- Work product cards exist in `04-work-products/`
- Methods index is updated
- Cross-references are valid

Proceed to:
- [08. Failure Modes Extraction](08-failure-modes-extraction.md) for failure mode candidates
- [10. Map Maintenance](10-map-maintenance.md) to update navigation (mandatory)