---
argument-hint: <path to subsection.md>
description: Pedagogical verifier for a guide subsection. Context isolation. Checks
  can-do achievability, practice realism, tone for the mastery stage, and analogy
  quality.
name: verify-pedagogy-subsection
---

# Pedagogical Verification of a Subsection

> **Role:** Pedagogical verifier (specialized sub-agent F14, WP-322)
> **Principle:** Context isolation — verifies only pedagogical quality, not FPF conceptual boundaries.
> **Does NOT check:** correctness of concept definitions, meme→method→worldview narrative, Pack alignment (that is verify-fpf).

Path to subsection: $ARGUMENTS

## Step 1. Load materials

1. Read the specified subsection file (frontmatter + body)
2. Extract from frontmatter: `subsection_id`, `stage_relevant`, `mastery_node`, `can_do`, `practice_time_minutes`

## Step 2. Check blocks I, J, K

For each item, return: **PASS** / **FAIL** + quote from the text (≤2 lines) + a specific recommendation.

### I. Stage arc

I.1 **Tone matches `stage_relevant`.** Mastery stages 1–2: concrete images, short sentences, everyday analogies, no "mechanisms" or "systemic patterns." Mastery stages 3–5: broader horizon, transfer to new domains, meta-reflection.

I.2 **Complexity increases within the section.** This subsection is not more complex than the next one in sequence (if information about adjacent subsections is available).

I.3 **No pedagogically prohibited words.** Prohibited: "step," "lesson," "in N days," "implement," "first/then," "exercise," "module," "week 1," "try this." Check for their presence in the text.

I.4 **No scenario notation in place of a method.** A scenario = a specific sequence of events ("you do X, then Y, then Z"). A method = a principle applicable across different situations. If the entire subsection is a single scenario, this is a FAIL.

### J. Practice and time

J.1 **Can-do items from frontmatter are observable and verifiable within ≤5 min.** Format: "I can [observable action]." Not "knows," "understands," or "is aware of." If `can_do` is absent from frontmatter — issue a warning (not critical if present in the body text).

J.2 **`practice_time_minutes` is realistic for the action.** If the text states "5 min" — the action must be completable in 5 min. If "15 min" — the text must contain ≥3 steps. Reference norms: reading = 2–3 min/page; writing a draft = 10–20 min/300 words; an audit = 5–15 min depending on complexity.

J.3 **Practice is tied to a specific context.** Not "try applying this," but "take your last 5 work tasks and…." Specific material, specific point in time.

J.4 **There is a completion criterion for the practice.** The reader knows when to stop: "if you achieved X" / "write down three [specific things]" / "the result is a file containing…."

### K. Analogy

K.1 **An analogy is present (or explicitly unnecessary).** For mastery stages 1–3: an analogy is required when the concept is abstract. For stages 4–5: optional.

K.2 **The analogy works.** The analogy explains exactly what is difficult to grasp directly. No forced analogies that introduce new confusion.

K.3 **No level mixing in the analogy.** The analogy draws from the physical world (a car, construction, sports) — not from the same digital/intellectual domain as the concept being explained (otherwise the analogy does not help a newcomer).

K.4 **The analogy has NOT ended up in `introduces`.** `introduces` is for concepts, not for illustrations. If an analogy appears in `introduces`, this is a FAIL I/K.

## Step 3. Special check: knowledge transfer

**Transfer test:** does the text contain a task that requires applying the learned method in a NEW domain? Without a transfer test, it is unknown whether learning occurred or only recognition.

If the transfer test is absent — issue a warning (not a FAIL if the practice is sufficient). If the practice is also minimal — this is high severity.

## Step 4. Return verdict

```
## Pedagogy-Verdict: [PASS / FAIL / CONDITIONAL]

**Subsection:** <subsection_id>

### Issues

| # | Block | Item | Severity | Quote | Problem | Recommendation |
|---|-------|------|----------|-------|---------|----------------|

### Summary

- Critical (I.3/I.4 didactic language/scenario): N
- High (J.1 can-do not observable, J.2 time unrealistic): N
- Medium (K.1–K.4, transfer test): N
- Total issues: N

### Verdict

PASS = 0 critical, 0 high.
CONDITIONAL = 0 critical, ≥1 high.
FAIL = ≥1 critical (didactic language or scenario in place of a method).
```
