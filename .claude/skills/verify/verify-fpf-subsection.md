---
argument-hint: <path to subsection.md>
description: FPF-verifier for a guide subsection. Context isolation. Checks conceptual
  boundaries, the meme→method→worldview narrative, and Pack consistency.
name: verify-fpf-subsection
---

# FPF Subsection Verification

> **Role:** FPF-verifier (specialized sub-agent F14, WP-322)
> **Principle:** Context isolation — checks FPF quality only, not pedagogy.
> **Does NOT check:** practice duration, can-do achievability, tone for mastery stage (those belong to verify-pedagogy).

Path to subsection: $ARGUMENTS

## Step 1. Load Materials

1. Read the specified subsection file (frontmatter + body)
2. Extract from frontmatter: `subsection_id`, `introduces`, `uses`, `stage_relevant`, `mastery_node`

## Step 2. Check Blocks G, H, L

For each item, return: **PASS** / **FAIL** + quote from the text (≤2 lines) + specific recommendation.

### G. Concept Boundaries (A.6 Boundary Discipline, FPF)

G.1 **No level mixing.** One concept describes one level of abstraction. For example, a method and its physical carrier must not be treated as a single entity.

G.2 **No tautology.** A concept must not be defined in terms of itself (e.g., "A Method is a methodical way of doing something").

G.3 **Clear ≠ boundary.** Every introduced concept has an explicit "≠ X, ≠ Y" — stating what it is NOT.

G.4 **Concepts listed in `introduces` are actually introduced in the text** (a definition or context is provided). They are not merely mentioned — they are explained.

### H. Narrative Chain (FPF H-pattern)

H.1 **Meme → method → worldview.** The subsection follows this structure: (1) show an ineffective or habitual thinking pattern (meme), (2) offer a method as an alternative, (3) show how applying the method shifts the overall picture.

H.2 **No dangling memes.** If a meme is named, the path out of it is explained. There is no "here is the problem — now the next topic."

H.3 **A "What's next" block or closing bridge.** The subsection does not end abruptly — it includes a bridge to the next subsection or a reflective question for the reader.

H.4 **The worldview shift is stated** (explicitly or as a question). The reader must understand: "after this subsection, I see X differently."

### L. Pack Consistency

L.1 **cp.* / bh.* indices are correct.** If referenced, they match PD.FORM.089 (cp.rhy, cp.wld, cp.skl, cp.iwe, cp.int, cp.agt, bh.sys, bh.inv, bh.awr).

L.2 **No contradictions with Pack definitions.** Concepts from `introduces` and `uses` are used in the text with the same meaning as in PACK-personal/ontology.md.

L.3 **`prerequisites` are logically respected.** If a subsection treats a concept as already known (`uses`), that concept was introduced in a preceding subsection (per `prerequisites`).

## Step 3. Special Check: Border Objects

**Border objects** are concepts easily confused with a concept from another discipline or Pack. The signal: the word is in common use (method, system, role, culture), but this guide uses it in a specific Pack sense.

Check: does the text contain border objects? If yes — is the Distinction introduced explicitly (at least once within the section)?

## Step 4. Return Verdict

```
## FPF-Verdict: [PASS / FAIL / CONDITIONAL]

**Subsection:** <subsection_id>

### Issues

| # | Block | Item | Severity | Quote | Problem | Recommendation |
|---|-------|------|----------|-------|---------|----------------|

### Summary

- Critical (G/H/L FAIL): N
- Conditional (border object without Distinction): N
- Total issues: N

### Verdict

PASS = 0 critical, 0 high.
CONDITIONAL = 0 critical, ≥1 high (border objects).
FAIL = ≥1 critical (G/H/L FAIL).
```
