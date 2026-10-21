# F-G-R Trust Pattern (Optional)

> **FPF Reference:** B.3 (Trust & Assurance Calculus)
> Full specification: `~/IWE/FPF/FPF-Spec.md`

## Overview

F-G-R is a pattern from FPF for assessing the **trustworthiness** of claims. It can be used in Packs for a more rigorous evaluation of knowledge quality.

**Status:** Optional pattern. Most Packs can work without it. Recommended for:
- Packs in critical domains (security, medicine)
- Situations where confidence level needs to be made explicit
- Working with hypotheses and unproven claims

---

## F-G-R Tuple

Trust is not a "feeling" — it is a computable tuple `⟨F, G, R⟩`:

| Component | Name | Question | Values |
|-----------|------|----------|--------|
| **F** | Formality | How rigorously is this expressed? | F0 (sketch) → F9 (formal proof) |
| **G** | Claim Scope | Where does this apply? | Set-valued (contexts where the claim holds) |
| **R** | Reliability | How well is this supported? | Evidence-based support level |

---

## F: Formality Scale

| Level | Description | Example |
|-------|-------------|---------|
| F0 | Sketch, informal | "I think X works" |
| F1-F2 | Written but loose | Blog post, notes |
| F3-F4 | Structured text | Method card with definition |
| F5-F6 | Checked specification | Reviewed by expert |
| F7-F8 | Tested/validated | Has tests, passed review |
| F9 | Formal proof | Mathematical/logical proof |

---

## G: Claim Scope

G defines **where** a claim holds. It is set-valued (a set of contexts).

| Scope | Example |
|-------|---------|
| Universal | "Method ≠ Tool" (holds everywhere in FPF-aligned systems) |
| Domain-wide | "Agency is a key characteristic" (holds in the creator Pack) |
| Context-specific | "Method X works for Y" (holds under specific conditions) |

---

## R: Reliability

R indicates **how well** a claim is supported by evidence.

| Level | Evidence | Example |
|-------|----------|---------|
| Low | Hypothesis, no test | "We think that..." |
| Medium | Some evidence | "Practice shows..." |
| High | Strong evidence | "Research confirms..." |
| Very High | Replicated | "Verified repeatedly" |

---

## When to Use F-G-R in Pack

### Recommended

| Situation | Why |
|-----------|-----|
| Critical distinctions | Show that core distinctions are well-established |
| Controversial claims | Be explicit about confidence level |
| Hypotheses | Make clear these need validation |
| Cross-references | Show alignment quality with FPF |

### Not Required

| Situation | Why |
|-----------|-----|
| Simple method cards | SoTA status is sufficient |
| Obvious distinctions | Standard format covers them |
| Work products | They are artifacts, not claims |

---

## Integration with SoTA

F-G-R complements SoTA:

| SoTA | F-G-R |
|------|-------|
| Status (current/hypothesis/deprecated) | Detailed assessment (F, G, R) |
| Revision criterion | What would change F, G, or R |
| Simple | More detailed |

SoTA can be used without F-G-R, but F-G-R without SoTA makes no sense.

---

## Example Annotation

```markdown
**Claim:** Method and Tool are distinct types (D.001)

**F-G-R:**
- **F** = 6 (Checked specification, reviewed)
- **G** = {SPF, Pack, all FPF-aligned systems}
- **R** = High (consistent with FPF A.7, no counter-evidence)

**SoTA:** `current`
- Revision criterion: Would change if evidence shows tool can substitute method
```

---

## References

- FPF B.3: Trust & Assurance Calculus
- FPF B.3.1: Components & Epistemic Spaces
- FPF B.3.3: Assurance Subtypes & Levels
- FPF B.3.4: Evidence Decay & Epistemic Debt
