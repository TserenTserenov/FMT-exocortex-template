# Human Guides Specification

This document specifies how to create human-readable guides, courses, and materials from SPF Personal content.

---

## Purpose

Humans learn differently than AI retrieves. Guides need:
- Narrative structure
- Progressive complexity
- Exercises and examples
- Motivational framing

**None of this belongs in SPF itself** — this spec describes the transformation.

---

## Transformation Principles

### Source (SPF)
- Declarative: "Method X does Y"
- Neutral: No "you should" or "try this"
- Complete: All metadata present
- Stable: IDs don't change

### Target (Guide)
- Instructional: "To do Y, use Method X"
- Engaging: "You'll find this useful when..."
- Selective: Curated subset for audience
- Versioned: Tied to SPF version

---

## Guide Structure Template

A guide consuming SPF may follow this structure:

```
1. Introduction
   - Why this matters (motivation — NOT in SPF)
   - Prerequisites (reference other guides or FPF)

2. Core Concepts
   - Pull from: 01-domain-contract/01B-distinctions.md
   - Add: Examples, analogies (NOT in SPF)

3. Methods in Practice
   - Pull from: 03-methods/*.md
   - Add: Step-by-step walkthrough (NOT in SPF)
   - Add: Exercises (NOT in SPF)

4. What You'll Produce
   - Pull from: 04-work-products/*.md
   - Add: Templates, worksheets (NOT in SPF)

5. Common Mistakes
   - Pull from: 05-failure-modes/*.md
   - Add: Recovery strategies (NOT in SPF)

6. Assessment
   - Tie to work products' observability criteria
   - Add: Rubrics, checklists (NOT in SPF)
```

---

## What Guides Add (Not in SPF)

| Element | Example | Why Not in SPF |
|---------|---------|----------------|
| Learning objectives | "By end, you will..." | Didactic framing |
| Step sequences | "Step 1: ..., Step 2: ..." | Scenario, not knowledge |
| Time estimates | "Takes ~30 minutes" | Context-dependent |
| Exercises | "Try this with your..." | Instructional design |
| Examples | "For instance, Alice..." | Illustrative, not canonical |
| Motivation | "This matters because..." | Persuasion, not description |

---

## Attribution Requirements

Guides derived from SPF should:
1. State SPF version used
2. Link to SPF repo
3. Clearly distinguish SPF content from guide additions
4. Not claim SPF endorsement unless authorized

---

## Versioning Guides

- Pin guide to SPF version (e.g., "Based on SPF Personal v1.2.0")
- When SPF updates, diff and decide: update guide or note divergence
- Major SPF changes may require guide rewrite

---

## Anti-Patterns

| Anti-Pattern | Problem |
|--------------|---------|
| Copy-paste SPF as guide | No transformation; SPF is not a guide |
| Invent methods in guide | Guide diverges from source-of-truth |
| Omit SPF attribution | Users can't verify accuracy |
| Never update guide | Guide becomes stale |

---

## Testing Guide Quality

- [ ] All methods referenced exist in SPF
- [ ] SoTA status accurately reflected
- [ ] Guide additions clearly marked or obviously instructional
- [ ] Exercises tie to SPF work products
- [ ] Failure modes from SPF inform "common mistakes" section
