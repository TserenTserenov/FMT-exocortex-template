# 09. SoTA Annotation

> **FPF Reference:** Part G (SoTA Kit), particularly G.2 (SoTA-packs) and G.4 (TraditionCards, OperatorCards)
> Full specification: `~/IWE/FPF/FPF-Spec.md`

## Purpose

Assign and maintain state-of-the-art (SoTA) status for claims, distinctions, and methods. SoTA in SPF is NOT a literature review — it is a **status attribute** that tracks whether understanding is current, outdated, or hypothetical.

**Relationship to FPF:** FPF Part G defines a detailed SoTA Kit with TraditionCards, OperatorCards and selector-ready portfolios. SPF uses a simplified version sufficient for most Packs. For deeper SoTA work, see FPF Part G.

---

## What SoTA Is and Is Not

| SoTA IS | SoTA IS NOT |
|---------|-------------|
| Status of a claim | Literature review |
| Attribute attached to content | Separate "research" section |
| Tracks currency of understanding | Tracks publication history |
| Has revision criterion | Fixed label |
| Updated when evidence changes | Static once assigned |

---

## SoTA Status Values

| Status | Meaning | When Assigned |
|--------|---------|---------------|
| `current` | Best available understanding | Evidence supports; no superior alternative |
| `deprecated-interpretation` | Previously held; now superseded | Evidence contradicts or better understanding exists |
| `hypothesis` | Proposed but not yet validated | Plausible but awaiting evidence |

---

## Inputs

| Input | Source | Required |
|-------|--------|----------|
| Claims requiring status | Methods, distinctions, assertions | Yes |
| Evidence for status | Analysis, research, practice | Yes |
| SoTA template | `/pack/_template/06-sota/` | Yes |

---

## Activity

### 1. Identify Claims Requiring SoTA

SoTA status applies to:

| Content Type | Example Claim |
|--------------|---------------|
| Methods | "Time accounting is a registration method" |
| Distinctions | "Method and tool are distinct types" |
| Interpretations | "Accounting produces discipline" (deprecated) |
| Mechanisms | "Registration alone does not change behavior" |

### 2. Assess Current Status

For each claim:

| Question | If Yes → Status |
|----------|----------------|
| Is this the best available understanding? | `current` |
| Was this believed but is now superseded? | `deprecated-interpretation` |
| Is this proposed but awaiting validation? | `hypothesis` |

### 3. Define Revision Criterion

Every SoTA status MUST have a revision criterion: **"What evidence would change this status?"**

| Status | Revision Criterion Format |
|--------|--------------------------|
| `current` | "Would change to deprecated if [evidence X]" |
| `deprecated-interpretation` | "Would change to current if [evidence Y]" |
| `hypothesis` | "Would change to current if [evidence Z]; would change to deprecated if [evidence W]" |

### 4. Create or Update SoTA Annotation

**Option A: Inline annotation** (in method/distinction file)
```markdown
**SoTA**: `current`
- Revision criterion: Would change to deprecated-interpretation if evidence shows registration directly causes behavior change without intermediate analysis.
```

**Option B: Standalone SoTA file** (for complex interpretations)

File: `/pack/<domain>/06-sota/<ID>-<name>.md`

| Section | Content |
|---------|---------|
| YAML frontmatter | id, target_type, target_id, dates |
| Target | What claim/method/distinction this annotates |
| Interpretations table | List of interpretations with status |
| Per-interpretation entry | Status, basis, revision criterion |
| Review schedule | When to revisit |

### 5. Assign Stable ID (for standalone files)

| Item | Pattern | Example |
|------|---------|---------|
| SoTA Annotation | `<DOMAIN>.SOTA.<NNN>` | `PD.SOTA.001` |

### 6. Cross-Reference

Link SoTA to target:
- SoTA → Method/Distinction (annotates)
- Method/Distinction → SoTA (has annotation)

---

## Output: Work Products

| Product | Location |
|---------|----------|
| Inline SoTA annotations | In method/distinction files |
| Standalone SoTA files | `/pack/<domain>/06-sota/` |
| Updated cross-references | In linked files |

---

## Completion Criteria

| Criterion | Test |
|-----------|------|
| Status assigned | current / deprecated-interpretation / hypothesis |
| Revision criterion present | "Would change if..." is specified |
| Basis stated | Why this status (briefly) |
| Target linked | What claim/method this annotates |
| Review date set | When to revisit (for standalone files) |

---

## Typical Errors

### E1. SoTA as Literature Review

**Symptom**: Long section citing papers and studies.

**Problem**: SoTA is a status, not a bibliography.

**Correction**: State the status and revision criterion; cite evidence briefly.

### E2. SoTA Without Revision Criterion

**Symptom**: "SoTA: current" with no revision criterion.

**Problem**: Status is unfalsifiable; will never be updated.

**Correction**: Add "Would change to X if Y."

### E3. Deprecated Without Replacement

**Symptom**: "This interpretation is deprecated" but no current interpretation stated.

**Problem**: Reader knows what's wrong but not what's right.

**Correction**: Always state the current understanding alongside deprecated.

### E4. All Hypotheses, No Current

**Symptom**: Everything marked as hypothesis.

**Problem**: Pack provides no confident knowledge.

**Correction**: Some claims should be current (with revision criteria).

### E5. Status Never Updated

**Symptom**: SoTA assigned once and never revisited.

**Problem**: Pack becomes stale; outdated claims remain current.

**Correction**: Set review schedule; actually review.

### E6. Inline vs. Standalone Confusion

**Symptom**: Minor claims get standalone files; major interpretations get inline only.

**Problem**: Inconsistent structure; hard to navigate.

**Correction**: Use standalone for complex interpretations with multiple statuses; inline for simple single-status claims.

---

## SoTA Annotation Checklist

Before committing a SoTA annotation:

- [ ] Status is one of: current / deprecated-interpretation / hypothesis
- [ ] Revision criterion is specific and falsifiable
- [ ] Basis for status is stated
- [ ] Target (what this annotates) is clear
- [ ] For standalone files: review date set
- [ ] Cross-references valid

---

## SoTA Status Transitions

```
               evidence supports
                      ↓
    ┌────────────────────────────────┐
    │                                │
    │    hypothesis ────────────► current
    │        │                       │
    │        │ evidence              │ better
    │        │ contradicts           │ understanding
    │        ↓                       ↓
    │    (rejected) ◄──── deprecated-interpretation
    │                                │
    │                                │ evidence
    │                                │ reinstates
    │                                ↓
    └────────────────────────────► current
```

---

## Transition to Next Stage

When SoTA Annotation is complete:
- Claims have status assigned
- Revision criteria are specified
- For complex interpretations, standalone files exist
- Cross-references are valid

Proceed to [10. Map Maintenance](10-map-maintenance.md) to update navigation (mandatory).
