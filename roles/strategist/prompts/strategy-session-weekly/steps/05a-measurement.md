---
gate: auto
step: 05a
title: 'Caliber: Measurement'
---

# Step 05a: Caliber — Measurement

## IPO

| | |
|---|---|
| **Input** | `Lifework/Caliber-artifacts-tracker.md`, `docs/Dissatisfactions.md`, `Lifework/` |
| **Process** | AI computation: V_scope, A_scope, D_scope, qualitative status, readiness check |
| **Output** | Measurements + recommendation for Step 05b |

## Instructions for Claude

> Method: `PD.METHOD.018` § Strategist Recommendation Mechanism. Three fields and the arithmetic prohibition — `PD.FORM.091 §6.1`.
> **Consent:** before reading digital twin metrics — verify consent, see [../appendix/consent-check.md](../appendix/consent-check.md). If `denied`/`null` — degraded mode (caliber based on self-assessment, no recording).

1. **Read the tracker:** `Lifework/Caliber-artifacts-tracker.md` (if absent — create from template `templates/strategy-skeleton/Lifework/Caliber-artifacts-tracker.md`)

2. **Classify vision → V_scope.** For each STABLE (recurring, not an isolated remark) dissatisfaction, determine its category using the verification questions from `PD.FORM.091 §6.1` (audience + responsibility; system level FORM.027 — supporting reference, not a replacement):

   | FORM.090 Category | Verification Question |
   |---|---|
   | 1. Self | Does the change relate to the person themselves and their way of acting? |
   | 2. Inner circle | Does the change relate to sustained close relationships? |
   | 3. Outer circle | Does the change relate to a team, project, clients, or professional community? |
   | 4. Community | Does the change relate to a sustained community or field? |
   | 5. Society | Does the change relate to a social institution, culture, or country? |
   | 6. Humanity and future generations | Does the change relate to humanity or future generations? |

   V_scope = the highest category reached. System level FORM.027 9–10 alone does NOT yield V_scope=6 — an explicit object of change at the humanity/generations level is required. No stable dissatisfaction classifiable under even one row → `V_scope = unconfirmed`. One dissatisfaction fits multiple rows simultaneously → status `ambiguous`; clarify through diagnostic dialogue, do not guess.

3. **Confirm action → A_scope:**
   - Highest coverage category (`PD.FORM.090`) with an observable produced change or accepted responsibility: completed projects, decisions, external results, Diagnostician confirmation
   - A Lifework document is NOT required for this assessment — read from `Lifework/`, but its absence does not lower A_scope
   - No confirmed actions yet → `A_scope = unconfirmed` (not "zero": a numeric zero level is not used). No document at all → this simultaneously means `D_scope = none`; the first work object is a safe, reversible personal project at level 1 with an observable trace — not a document (`PD.METHOD.018` § New Participant Without a Document)

4. **Audit documentation → D_scope:**
   - Highest coverage category with a mature Lifework document — read from `Lifework/`; maturity is determined by local rules in `PD.METHOD.018` § Advancement Conditions (timeframes vary by transition: ≥6 months for 1→2 and 2→3, ≥1 year for 3→4 and 4→5, ≥3 years for 5→6 — not a single unified timeframe)
   - No documents → `D_scope = none`
   - Check completeness of lower invariants (`PD.FORM.090 §6`): are all levels 1..D_scope present?
   - Gaps at lower levels → recommend "catch up downward," STOP here (a gap at a lower level is a break from below and takes priority over advancement)

5. **Compare V_scope and A_scope on a single coverage scale → qualitative status** (`PD.FORM.091 §6.1`, ordinal comparison within a single scale, NOT arithmetic):
   - V_scope = A_scope → `aligned`
   - V_scope one category above A_scope → `adjacent_frontier`
   - V_scope two or more categories above A_scope → `vision_ahead`
   - A_scope above V_scope → `action_ahead`
   - V_scope or A_scope = unconfirmed → status `unconfirmed`
   - The category of V_scope or A_scope itself is ambiguous (Step 2) → status `ambiguous`

6. **Check local readiness for the next document** (`PD.METHOD.018` § Advancement Conditions + § Local Document Gate):
   - Has the previous Lifework document completed its test period PER THE "Advancement Conditions" TABLE for the specific transition (not a unified timeframe — see Step 4), AND is the real pattern of the next category already observable in A_scope? The table also lists qualitative transition conditions (size and stability of the circle, not only duration) — verify those, not just the date
   - Mastery stage (`PD.FORM.080`) calibrates only the volume of support and guidance — it does NOT open or close this readiness
   - Output `ready_for_next_document: true/false` with a brief rationale

7. **Report results** (V_scope, A_scope, D_scope, qualitative status, `ready_for_next_document`) to the pilot. **STOP — wait for the next message. Do not read the Step 05b file until the next Work turn.**
