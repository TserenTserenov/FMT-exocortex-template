# ZP.1 — Axiomaticity

## Definition

Theories are built according to strict rules (axioms, proofs), not intuition.

## Consequence

Every claim must be derivable from explicit premises. "It seems to me" is not an argument. "Here are the axioms, here is the conclusion" is an argument.

## Application Examples

**1. AlphaProof and Aristotle: formal proof by AI (2024–2026).**
DeepMind AlphaProof (Nature, 2025) solved 4 out of 6 IMO problems in Lean4 — each solution is 100% verified, hallucination is impossible. Harmonic Aristotle (2026) solved open Erdős problems in 6 hours with formal verification in 1 minute. The axiomatic approach transforms mathematical reasoning from probabilistic to provable.

**2. Constitutional AI as axiomatization of values (2024–2025).**
Anthropic Constitutional AI uses a set of explicit rules (axioms) for self-improvement. C3AI (ACM, 2025) applies graph-based principle selection to refine "constitutions." The values of an AI system cease to be implicit and become verifiable.

**3. Core Knowledge — axioms of cognition (Spelke, BBS 2024).**
Elizabeth Spelke demonstrated that human cognition rests on 6 innate computational systems (objects, navigation, number, geometry, actions, social agents). These are the "axioms" of cognition — explicit, testable, operational from birth. Language serves as the mechanism for composing the outputs of these systems into new concepts (Carey, BBS 2024).

**4. Machine-Assisted Proof (Terence Tao, 2024–2025).**
Tao converted a mathematics paper into Lean code using ChatGPT. The AI for Math Fund ($9.2M) was launched to automate proofs. The axiomatic approach from mathematics is spreading across all of science.

**5. Safe Framework (2025): verification of reasoning chains.**
Each step of an LLM chain-of-thought is translated into Lean4: if the proof does not pass, the reasoning is incorrect. Axiomatization is applied to the AI thinking process itself.

## Typical Violations

**N1. Boeing 737 MAX MCAS (2018–2019).** MCAS relied on a single sensor with no formal failure specification. Safety assumptions were implicit (non-axiomatized). 346 people died. The problem was not in the code — it was the absence of formal requirements.

**N2. The replication crisis in psychology.** A Northwestern study (2024) found that fabricated publications outpace legitimate ones. The root cause: psychology "isolates methods from theories and premises" — there is no axiomatic foundation. Biology acknowledges the absence of fundamental axioms (unlike mathematics).

**N3. Therac-25 (1985–1987).** Race conditions in untested code paths caused patient deaths from radiation overdose. The axiom "the program never fires the beam without a target" was implicit and never formalized.

**N4. Reasoning by analogy without verifying premises.** Analogy-based reasoning is effective, but without checking whether the axioms of the source and target domains match, it leads to false conclusions. "The brain as a computer" is an analogy that became an implicit axiom and distorted neuroscience for decades.

## Manifestation in Child Development

Children progress from intuitive to axiomatic thinking. Before age 11 — inductive reasoning (from examples to generalization = ZP.1 violated). From age 11 onward (Piaget's formal operational stage), hypothetico-deductive thinking emerges: the ability to formulate hypotheses and derive logical consequences. This is the "axiom → proof" pattern. The adolescent discovery "I can reason from premises I do not believe" is the birth of axiomaticity in development.

## Connection to FPF

FPF Part A: Kernel Architecture — the axiomatic structure of holons. A holon is defined through a set of explicit axioms, not through intuitive descriptions. FPF Part B.3: Trust Calculus — formality (F) as an ordinal scale: F0 (prose) → F3 (proof level). Constitutional AI is a downstream application: values as explicit axioms.

## Key Researchers (2024–2026)

- David Silver, Pushmeet Kohli (DeepMind) — AlphaProof
- Tudor Achim (Harmonic AI) — Aristotle, Lean4-native reasoning
- Terence Tao (UCLA) — machine-assisted proofs
- Leonardo de Moura (AWS/Lean FRO) — Lean4
- Kevin Buzzard (Imperial College) — Mathlib, formalization of mathematics
- Elizabeth Spelke (Harvard) — Core Knowledge, axioms of cognition