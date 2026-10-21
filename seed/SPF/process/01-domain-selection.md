# 01. Domain Selection

## Purpose

Establish what domain the pack will cover before any content is created. A domain is not a topic, keyword, or area of interest — it is a bounded field of practice with identifiable practitioners, methods, and work products.

---

## When This Stage Occurs

| Trigger | Action |
|---------|--------|
| New pack creation | Mandatory first stage |
| Scope expansion of existing pack | Return to this stage |
| Domain split (pack becomes too broad) | New selection for sub-domain |

---

## Inputs

| Input | Source | Required |
|-------|--------|----------|
| Intent to create pack | Stakeholder decision | Yes |
| Candidate domain name | Initial proposal | Yes |
| Preliminary understanding of field | General knowledge | Yes |

---

## Activity

### 1. Articulate Domain, Not Topic

| Domain | Topic (incorrect framing) |
|--------|--------------------------|
| Personal Development | Self-improvement tips |
| Software Engineering | Programming languages |
| Medical Diagnosis | Diseases |
| Project Management | Deadlines |

A domain has:
- Practitioners (who does this?)
- Methods (how do they act?)
- Work products (what do they produce?)
- Failure modes (how does it go wrong?)

A topic lacks these structural elements.

### 2. Identify Domain Boundaries

What is inside vs. outside this domain?

| Inside | Outside |
|--------|---------|
| Core methods of the field | Adjacent fields |
| Primary practitioners | Consumers of outputs |
| Direct work products | Downstream uses |

### 3. Check for Prior Art

| Check | Why |
|-------|-----|
| Existing SPF packs | Avoid duplication, identify interfaces |
| FPF distinctions | Ensure compatibility |
| Established domain boundaries | Respect existing conventions |

### 4. Name the Domain

The name must be:
- Specific enough to exclude adjacent fields
- General enough to include core methods
- Recognizable to practitioners

---

## Output: Work Product

**Domain Selection Statement** (informal, not a pack file yet)

```
Domain: [Name]
Scope: [What is included]
Exclusions: [What is explicitly outside]
Practitioners: [Who operates in this domain]
Adjacent domains: [Related but separate fields]
```

This statement becomes input to Stage 02 (Bounded Context).

---

## Completion Criteria

| Criterion | Test |
|-----------|------|
| Domain is nameable | One or two word name exists |
| Boundaries are articulable | Can list what is in/out |
| Practitioners exist | Can identify who does this work |
| Not a topic | Can identify methods, not just subjects |
| Not too broad | One pack can cover it |
| Not too narrow | Worth creating a pack |

---

## Typical Errors

### E1. Domain Is Too Broad

**Symptom**: "The domain is Management" or "The domain is Science"

**Problem**: No single pack can cover the breadth; distinctions will be too abstract to be useful.

**Correction**: Subdivide until practitioners are identifiable. "Project Management" or "Experimental Design" are tighter.

### E2. Domain Is a Topic, Not a Practice Field

**Symptom**: "The domain is Happiness" or "The domain is Technology"

**Problem**: No methods, no practitioners, no work products — just a subject.

**Correction**: Find the practice. "Positive Psychology Practice" or "Software Development" have structure.

### E3. Domain Is a Method, Not a Field

**Symptom**: "The domain is Agile" or "The domain is Time Accounting"

**Problem**: A method is inside a domain, not a domain itself.

**Correction**: Identify the containing domain. "Project Management" contains Agile; "Personal Development" contains Time Accounting.

### E4. Domain Boundaries Are Vague

**Symptom**: Cannot answer "Is X inside or outside?"

**Problem**: Distinctions will be arbitrary; methods will overlap with other packs.

**Correction**: Make explicit boundary decisions before proceeding.

### E5. Skipping to Content

**Symptom**: "We already know the methods, let's just document them"

**Problem**: Without domain selection, there is no criterion for what methods belong.

**Correction**: Complete this stage even if it feels obvious.

---

## Transition to Next Stage

When Domain Selection is complete:
- Domain name is fixed
- Boundaries are articulated
- Practitioners are identified

Proceed to [02. Bounded Context](02-bounded-context.md) to formalize these decisions into a pack manifest.
