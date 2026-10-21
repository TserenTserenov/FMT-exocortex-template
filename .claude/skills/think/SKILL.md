---
argument-hint: '[task or question]'
browser_safe: true
description: ADI-cycle structured reasoning (Abduction-Deduction-Induction-Audit-Decide).
  Use for complex decisions when multiple hypotheses need to be considered.
name: think
routing:
  deterministic: false
  executor: opus
---

# ADI Reasoning Cycle

> FPF B.5 (ADI). Data trust: F-G-R (B.3) — fact/assumption/rumor. Option comparison: A.19 — apply identical criteria to all options.

Task: $ARGUMENTS

## 1. Abduction (hypothesis generation)

Generate 2–3 distinct solution hypotheses. Do NOT stop at the first idea!

## 2. Deduction (logic check)

For each hypothesis:
- Verify internal consistency
- Verify alignment with constraints
- Identify potential problems

## 3. Induction (evidence collection)

- Find supporting or refuting evidence in the code
- Review the documentation
- Search for similar patterns in the repository

## 4. Audit (bias check)

- Am I anchored to the first hypothesis?
- Am I ignoring counter-evidence?
- Are the hypotheses sufficiently diverse?

## 5. Decide (selection and justification)

- Select the best hypothesis
- Document the rationale for the choice
- State uncertainty and risks

Output: a structured analysis with a final recommendation.
