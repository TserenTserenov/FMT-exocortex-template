# ZP.5 — Probability and Information

## Definition

Describe complex systems through probabilities, entropy, and information.

## Consequence

Not "X will happen," but "X will happen with probability P under conditions C." Uncertainty is not an enemy — it is an object of description.

## Application Examples

**1. Learning = compression (Kolmogorov/MDL, 2024–2025).**
"Bridging Kolmogorov Complexity and Deep Learning" (September 2025): asymptotically optimal description-length objectives for transformers based on Kolmogorov complexity. "Complexity Dynamics of Grokking" (2025): the phase transition from memorization to generalization equals a sharp drop in complexity. Learning is the discovery of shorter programs that generate the same observations.

**2. Generalized Information Bottleneck (2025).**
GIB reformulates the bottleneck principle through SYNERGY — information obtained only through joint feature processing. Synergistic functions achieve better generalization. GIB reveals compression phases even for ReLU architectures and transformers.

**3. Statistical learning in infants (Saffran, 1996 → 2024).**
Eight-month-old infants automatically extract transition probabilities from continuous speech streams, discarding irrelevant variation (voice, speed, pitch) and retaining structural patterns (word boundaries). Information Bottleneck in action: compressing high-dimensional auditory input into low-dimensional structural representations.

**4. IIT 4.0 — update to Integrated Information Theory (2023–2025).**
IIT 4.0 introduces unique intrinsic information measures aligned with 5 axioms of phenomenal existence. The identity: experience = cause-effect structure unfolded from the maximum substrate. Critique (Erkenntnis, 2025): IIT ignores the role of attention — information without a selection mechanism is insufficient.

**5. Conformal prediction for causal effects (2024–2025).**
Distribution-free predictive intervals for counterfactual outcomes, even under hidden confounders. 14th Symposium on Conformal Prediction (London, September 2025). Applications: transportation, medicine.

**6. Unification of Shannon ↔ Kolmogorov (2024–2026).**
Every linear inequality that holds for Kolmogorov complexity holds for Shannon entropy, and vice versa. However, the analogy breaks down for nonlinear statements. Special issue of Entropy (2024–2025).

## Typical Violations

**N1. IIT 4.0 ignores attention (Erkenntnis, 2025).** By treating consciousness as purely information-theoretic (integrated information) without accounting for the computational process of attention, IIT makes predictions that contradict phenomenological data. Information without a selection mechanism is insufficient.

**N2. Conformal prediction under distribution shift.** Standard conformal prediction assumes exchangeability, which breaks down under distribution shift. Applying probabilistic guarantees from one distribution to another violates the principle.

**N3. p < 0.05 as "proof" (reproducibility crisis).** When researchers treat p < 0.05 as proof rather than probabilistic evidence, they violate ZP.5. The reproducibility crisis is partly a base-rate error: the prior probability of a hypothesis is ignored.

**N4. Overfit (memorization without compression).** A model that memorizes training data without compressing it (without extracting sufficient statistics) violates the information principle. Regularization = enforced compression.

## Manifestation in Child Development

Infants are Bayesian reasoners from birth. At 12 months, preverbal infants form time-varying expectations about future events consistent with a Bayesian ideal observer (Science, 2011). At 4.5–6 months, infants use proportional (probabilistic) reasoning. By ages 4–5, children make predictive inferences under uncertainty but struggle with diagnostic (inverse) inferences, which require full Bayesian reasoning. Critically: when information is presented as natural frequencies (rather than probabilities), even young children solve Bayesian problems correctly — the format of probabilistic information matters as much as its content.

## Connection to FPF

Trust Calculus (F + G + R), TGA. Trust in statements is expressed quantitatively: facts (F), justifications (G), reputation (R) — all through probabilistic estimates. WLNK (Weakest-Link): R_eff = max(0, min_i(R_i) − Φ(CL_min)) — no averaging; the weakest link determines the whole. KD-CAL: knowledge ages, trust decays without updates — entropy of knowledge.

## Key Researchers (2024–2026)

- Giulio Tononi (UW-Madison) — IIT 4.0
- Vladimir Vovk (Royal Holloway) — conformal prediction
- Judea Pearl (UCLA) — causal inference, Pearl Causal Hierarchy
- Naftali Tishby (posthumously) — Information Bottleneck (1999)
- Noga Zaslavsky (MIT) — efficient coding, IB in cognition
- Josh Tenenbaum (MIT) — Bayesian models of cognitive development