# ZP.6 — Computational Constraints

## Definition

Account for what can realistically be computed and accomplished under finite resources.

## Consequence

A beautiful model that cannot be computed in reasonable time is useless. Resources — time, memory, money, attention — are always finite.

## Application Examples

**1. Resource-rational analysis (Lieder & Griffiths, updated 2024–2025).**
Understanding cognition as optimal use of limited computational resources. Trends in Cognitive Sciences (2025): when information-processing costs are high, children shift toward inferences with high prior probability. This is not irrationality — it is optimal computation under constrained resources.

**2. Google Quantum AI — 13,000× speedup (October 2025).**
65-qubit processor: physical simulation in 2.1 hours vs. 3.2 years on the Frontier supercomputer. The speedup applies to a specific problem class (OTOC(2)). JPMorgan + Quantinuum (March 2025): first demonstrable practical quantum advantage for certified randomness. Primary applications: quantum simulation, cryptography, moderate optimization. Quantum computers expand the boundary of the computable but do not cancel the principle of finiteness.

**3. Landauer's principle in the quantum many-body regime (Nature Physics, 2025).**
Experimental verification of Landauer's principle on ultracold Bose gases: the cost of erasing one bit — kT ln 2 — is confirmed, but is achievable only for infinitely slow processes. This establishes a fundamental thermodynamic limit on computation.

**4. AI scaling laws as evidence of computational limits (2024–2025).**
Pre-training scaling follows an S-curve with diminishing returns; high-quality text data is exhausted. The field is shifting to test-time compute (o1/o3) and precision scaling (16-bit and below). This demonstrates ZP.6: performance is bounded by finite resources, and the optimal allocation strategy changes as resources at each scale are exhausted.

**5. P vs NP via the ruliology approach (Wolfram, January 2026).**
Wolfram linked computational irreducibility to P vs NP through the ruliad (the space of all possible computations). Mazor & Pass (ITCS 2024) and Hirahara, Ilango, Williams (STOC 2024) showed that some formulations of the "search hypothesis" are false. The P ≠ NP problem remains open, but the boundaries of computability are being refined.

## Typical Violations

**N1. Ignoring computational costs (Icard, Resource Rationality, 2025).** Standard rational-choice theory assumes unlimited computation. Icard's monograph (Stanford, March 2025): ignoring computational costs leads to normatively incorrect predictions about human and AI behavior.

**N2. Computational irreducibility can be too strong a claim (critique of Wolfram, 2025).** The assertion that some systems are completely irreducible (no shortcuts) has been challenged: real complex systems contain exploitable patterns. The anti-pattern is assuming either complete reducibility (classical reductionism) or complete irreducibility (the Wolfram extreme).

**N3. AI over-parameterization ignores Landauer limits.** Training an LLM consumes megawatt-hours of electricity. At kT ln 2 per bit erased, the thermodynamic minimum is ~10¹⁸ times lower than actual consumption. The gap between the theoretical limit and practice represents colossal computational inefficiency.

**N4. Infinite solution complexity vs. finite user attention.** An engineering system may be optimal on every metric, but if a user cannot understand it in reasonable time, it is useless (learnability, the O characteristic in EMOGSS). Latency budget: bot < 3 s, CLI < 1 s.

## Manifestation in Child Development

Children are the paradigmatic case of resource-constrained agents. Working memory: 5–9 chunks (for 4-year-olds: ~2–3). The resource-rational framework (2025) shows that children's cognitive strategies are optimal given their computational constraints — when processing costs are high, children switch to high-prior-probability inferences instead of exhaustive search. Heuristic reasoning (fast-and-frugal heuristics, Gigerenzer) is not irrationality; it is optimal computation under constrained resources. The development trajectory — from heuristic to analytical reasoning — mirrors the computational trade-off: working memory grows (myelination, prefrontal cortex maturation through age 25), allowing children to afford more costly strategies.

## Relation to FPF

FPF Part C: Domain-specific calculi — finite, computable models. Each domain receives its own calculus that can actually be computed, rather than an abstract theory of infinite complexity. WLNK (Weakest-Link): the whole is no stronger than its weakest part — a computational constraint at the level of aggregation. Epistemic Debt (KD-CAL): knowledge becomes outdated; updating it requires finite resources — a balance between freshness and cost.

## Key Researchers (2024–2026)

- Thomas Icard (Stanford) — resource rationality
- Scott Aaronson (UT Austin) — quantum computational complexity
- Stephen Wolfram — computational irreducibility, P vs NP
- Falk Lieder (Max Planck) — resource-rational cognition
- Ryan Tibshirani (UC Berkeley) — conformal prediction, finite-sample guarantees