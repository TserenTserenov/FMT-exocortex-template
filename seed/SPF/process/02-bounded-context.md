# 02. Bounded Context

## Purpose

Formalize the domain boundaries into a stable reference that governs all subsequent work. Without a bounded context, the pack will accumulate content without coherence — distinctions from one domain, methods from another, failure modes from a third.

---

## Why Bounded Context Is Mandatory

| Without Bounded Context | With Bounded Context |
|------------------------|---------------------|
| Distinctions drift | Distinctions stay relevant |
| Methods imported from adjacent fields | Methods belong to this domain |
| Scope creep | Clear inclusion/exclusion |
| No criterion for "done" | Completeness is assessable |

A bounded context answers: **"What is this pack about, and what is it not about?"**

---

## Inputs

| Input | Source | Required |
|-------|--------|----------|
| Domain Selection Statement | Stage 01 | Yes |
| FPF edition reference | FPF repository | Yes |
| Related pack boundaries (if any) | Other SPF packs | If they exist |

---

## Activity

### 1. Create Pack Manifest

File: `/pack/<domain>/00-pack-manifest.md`

Required sections:

| Section | Content |
|---------|---------|
| **pack_id** | Short code (e.g., `PD`, `MGMT`) |
| **pack_name** | Full domain name |
| **version** | Semantic version |
| **fpf_edition** | Which FPF version this pack uses |
| **status** | `draft` / `active` / `deprecated` |

### 2. Define Scope Explicitly

In the manifest, specify:

| Field | Example |
|-------|---------|
| What this pack covers | "Methods for individual development of skills, capabilities, character" |
| What this pack does NOT cover | "Team development, organizational change, therapy" |
| Primary practitioners | "Agent (individual developing), Mentor, Coach" |
| Excluded practitioners | "Therapist, HR manager, Team lead" |

### 3. Identify FPF Dependencies

List which FPF distinctions this pack relies on:

| FPF Distinction | How Used |
|-----------------|----------|
| method vs. tool | All method cards |
| role vs. person | Role definitions |
| work product vs. description | WP definitions |

### 4. Declare Related Packs

| Pack | Relationship |
|------|--------------|
| Adjacent pack X | "Shares distinction Y; does not overlap in methods" |
| Parent pack (if hierarchical) | "This pack is a sub-domain of..." |

---

## Output: Work Product

**Primary**: `/pack/<domain>/00-pack-manifest.md` (created or updated)

The manifest is the authoritative bounded context. All subsequent work must be consistent with it.

---

## Completion Criteria

| Criterion | Test |
|-----------|------|
| Manifest file exists | File at expected path |
| Scope is explicit | "Covers" and "Does not cover" sections filled |
| FPF dependencies listed | At least basic distinctions referenced |
| Status is set | Not blank |
| Practitioners identified | At least one role type named |

---

## Typical Errors

### E1. Manifest Is Empty Formality

**Symptom**: Manifest created but never referenced; content added without checking scope.

**Problem**: Bounded context exists in name only.

**Correction**: Require explicit scope check before adding any method/WP/FM.

### E2. Scope Is Aspirational, Not Actual

**Symptom**: Manifest says "covers all of personal development" but pack only has time management methods.

**Problem**: Mismatch between claimed and actual scope.

**Correction**: Scope should reflect current content OR explicitly mark uncovered areas as "planned."

### E3. Boundaries Not Enforced

**Symptom**: Methods from adjacent domains creep in ("this is kind of related").

**Problem**: Pack becomes incoherent; distinctions stop working.

**Correction**: Every addition must pass: "Is this inside the bounded context?"

### E4. No FPF Alignment

**Symptom**: Pack uses terms inconsistently with FPF (e.g., calls tools "methods").

**Problem**: Pack will conflict with other SPF packs and FPF.

**Correction**: List FPF dependencies explicitly; ensure definitions align.

### E5. Skipping to Distinctions

**Symptom**: "Bounded context is obvious, let's write distinctions."

**Problem**: "Obvious" boundaries are often wrong; implicit assumptions cause problems later.

**Correction**: Make the manifest explicit before proceeding.

---

## Bounded Context vs. Domain Selection

| Stage 01: Domain Selection | Stage 02: Bounded Context |
|---------------------------|--------------------------|
| Informal statement | Formal manifest file |
| "What domain?" | "What exactly is in/out?" |
| Can be revised | Revisions require process return |
| Not in pack | In pack as `00-pack-manifest.md` |

---

## Transition to Next Stage

When Bounded Context is complete:
- Manifest file exists in `/pack/<domain>/`
- Scope is explicit and testable
- FPF dependencies are listed

Proceed to [03. Distinctions Work](03-distinctions-work.md) to establish the conceptual vocabulary.
