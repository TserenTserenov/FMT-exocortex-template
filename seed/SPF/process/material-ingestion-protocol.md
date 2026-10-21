# Material Ingestion Protocol

## Purpose

This document defines how external materials (posts, guides, notes, drafts) are processed into SPF knowledge. It ensures that **information is never treated as knowledge** and that Claude operates as analyst, not author.

---

## Core Principle

```
Material → Extraction Report → Human Review → Approved Candidates → Pack Changes
```

**Materials do NOT go directly into pack.**

---

## What Counts as External Material

| Material Type | Examples | How Provided |
|---------------|----------|--------------|
| **Posts** | systemsworld.club articles | Link or text |
| **Guides** | Existing manuals, tutorials | File or text |
| **Drafts** | Unpublished documents | Text |
| **Notes** | Personal observations | Text |
| **Reasoning** | Analytical pieces | Text |
| **Cases** | Real-world examples | Description |
| **Dialogues** | Conversations with insights | Transcript |

---

## When This Protocol Applies

This protocol is **mandatory** when:
- User provides external material for analysis
- User asks to "add this to the pack"
- User shares a post, note, or draft
- Any external content is introduced

---

## Claude's Response Format

When Claude receives external material, the response MUST be an **Extraction Report**, not pack changes.

### Extraction Report Template

```markdown
## Extraction Report

**Material**: [Title or brief description]
**Source**: [Link, file name, or "provided in message"]
**Date analyzed**: [YYYY-MM-DD]

---

### 1. Distinctions Identified

Distinctions that the material uses, assumes, or violates:

| Distinction | How Used/Violated | Pack Reference |
|-------------|-------------------|----------------|
| D.001 Method vs. Tool | Material confuses X with Y | [link] |
| ... | ... | ... |

**New distinction candidates**:
- [If material reveals a contrast not yet in pack]

---

### 2. Candidate Methods

| Candidate | Definition (draft) | Inputs | Outputs | Related Distinction |
|-----------|-------------------|--------|---------|---------------------|
| Method name | What it is | ... | ... | D.XXX |

**Notes**: [Open questions, uncertainties]

---

### 3. Candidate Work Products

| Candidate | Definition (draft) | Existence Criteria | Produced By |
|-----------|--------------------|--------------------|-------------|
| Product name | What it is | How to verify | Method X |

**Notes**: [Open questions, uncertainties]

---

### 4. Candidate Failure Modes

| Candidate | Type | Detection Test | Distinction Violated |
|-----------|------|----------------|---------------------|
| FM name | ontological/methodological/... | How to detect | D.XXX |

**Notes**: [Open questions, uncertainties]

---

### 5. SoTA Signals

| Claim/Interpretation | Signal | Rationale |
|---------------------|--------|-----------|
| "X is the case" | current / deprecated / hypothesis | Why |

---

### 6. Suggested Changes to Pack

| Action | Target File | What Changes | Priority |
|--------|-------------|--------------|----------|
| Add method | 03-methods/PD.METHOD.XXX.md | New method card | High/Medium/Low |
| Update distinction | 01-domain-contract/01B-distinctions.md | Refine D.XXX | ... |
| Add FM | 05-failure-modes/... | New FM card | ... |
| None | — | Material has no new content | — |

---

### 7. What Was NOT Extracted

Content from material that was:
- Out of scope (outside bounded context)
- Already in pack
- Too vague to formalize
- Didactic/scenario (belongs downstream)

---

### 8. Open Questions

- [Questions requiring human judgment]
- [Ambiguities that need clarification]
```

---

## After Extraction Report

### Human Review

The user reviews the extraction report and decides:
- Which candidates to approve
- Which to reject
- Which need clarification

### If Approved

Claude may proceed to pack changes following:
1. Process stages (03 → 06 → 07/08/09 → 10)
2. Process lint
3. Hard gates

### If Rejected or Needs Clarification

No pack changes. Discussion continues.

---

## What Claude Must NOT Do

| Forbidden | Why |
|-----------|-----|
| Copy text from material into pack | Pack uses domain language, not source language |
| Create pack files without extraction report | Bypasses analysis |
| Assume extraction = approval | Human must approve |
| Add scenarios/didactics | Belongs downstream |
| Treat material as authoritative | Must apply distinctions critically |

---

## Working Directory for Raw Materials

If user wants to track materials:

```
/process/working/
  ingestion-log.md      # List of processed materials
  extractions/          # Saved extraction reports
```

These are **process artifacts**, not pack content.

---

## Example Interaction

**User**: "Here's my post about time tracking. Add the relevant knowledge to the pack."

**Claude** (CORRECT):
```
I'll analyze this material and produce an extraction report.

## Extraction Report

**Material**: Post about time tracking
**Source**: Provided in message
...
[Full extraction report]
...

### 6. Suggested Changes to Pack
| Action | Target File | What Changes |
|--------|-------------|--------------|
| Add FM | PD.FAIL.007.md | New failure mode: tracking without categories |

Would you like me to proceed with these changes?
```

**Claude** (WRONG):
```
I'll add this to the pack. Creating PD.METHOD.002.md...
```

---

## Integration with MAPSTRATEGIC

This protocol is the operational core of:
- **Phase 2**: Material Ingestion
- **Phase 3**: Analytical Processing

See [MAPSTRATEGIC.md](/MAPSTRATEGIC.md) for phase context.

---

## Lint Interaction

Extraction reports are **not subject to pack lint** (they are process artifacts).

Pack changes resulting from approved extractions **are subject to full lint**.
