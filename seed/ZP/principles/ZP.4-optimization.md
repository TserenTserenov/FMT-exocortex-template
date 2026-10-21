# ZP.4 — Optimization

## Definition

Frame any task as a search for the extremum of a functional (variational principles).

## Consequence

Instead of "enumerate all options" — define what you are optimizing and find the extremum. Nature operates through optimization (the principle of least action); engineering does too.

## Application Examples

**1. Free Energy Principle as variational optimization (Friston, 2023--2025).**
Planning under FEP = minimization of variational free energy on a generative model with epistemic and pragmatic priors. "Active inference goes to school" (Phil Trans R Soc B, 2024): learning = epistemic foraging and prediction error minimization. Dynamic programming reduces the computational cost of long-horizon planning.

**2. Physics-Informed Neural Networks + Optimal Transport (2024--2025).**
AAS (Adversarial Adaptive Sampling): PINN + optimal transport, Wasserstein distance in the loss function. MC-PINN reduces climate forecast errors by 37% with 82% less computation. SeisPINN: earthquake localization with 0.5 km accuracy in 5 seconds. PIKANs (Physics-Informed Kolmogorov-Arnold Networks, 2025) outperform MLP-PINNs on multi-scale problems.

**3. Grokking as a phase transition during optimization (ICLR 2024).**
During training, a network passes through a phase transition from memorization to generalization. Complexity (in the Kolmogorov sense) grows during the memorization phase, then drops sharply when the pattern is discovered. Direct evidence: optimization leads to compression (ZP.5), and compression occurs through a phase transition (ZP.3).

**4. Optimal transport in generative models (2024--2025).**
OT is the mathematical framework for comparing distributions in GANs, diffusion models, and transformer token dynamics. Neural network training via gradient flows (IEEE, 2025). Wasserstein distance = the "transport cost" of moving one distribution to another.

**5. Multi-objective Pareto optimization in RL (ICLR 2025).**
C-MORL: a bridge between constrained policy optimization and multi-objective RL for Pareto front discovery. Handles up to 9 simultaneous objectives in continuous control tasks. Pareto optimality = the state where no objective can be improved without degrading another.

## Typical Violations

**N1. Single-objective trap.** Optimizing one metric (next-token prediction loss) without accounting for other objectives leads to diminishing returns. The shift to multi-objective training (helpfulness + harmlessness + honesty) and test-time compute shows that real systems require multi-objective variational formulations.

**N2. Ill-conditioning in variational optimization (2025).** The paper "Fundamental flaws of PINNs" demonstrates cases where variational optimization fails due to poor Jacobian conditioning. Without a correct constraint formulation, the optimization landscape becomes pathological.

**N3. Pareto optimization on test problems ≠ on real problems.** MOEAs with strong results on standard benchmarks fail on real-world problems (stochastic objectives, heavy constraints, complex Pareto fronts). The assumption that "clean optimization is sufficient without accounting for problem structure" is a violation.

**N4. Rote learning as brute force without a model.** Learning without an optimizable criterion (simply "read and memorize") is the antithesis of the variational approach. Retrieval practice (MIM.M.011, d=0.50) works precisely because it creates an internal optimizable signal (the error during a recall attempt).

## Manifestation in Child Development

A study of children (Nature Human Behaviour, 2023) formally models development as multi-parameter optimization: children simultaneously tune reward generalization, exploration temperature, and research directionality. Children explore more actively than adults (high exploration temperature) but receive less reward — they optimize for information gain (epistemic value) rather than reward (pragmatic value). This mirrors the balance of epistemic and pragmatic priors in FEP.

## Connection to FPF

FPF Part B: NQD-CAL — Novelty-Quality-Diversity optimization. Evolutionary search along three axes: novelty, quality, diversity. Not scalarization into a single metric, but a Pareto front. E/E-LOG: Explore-Exploit governance — named policies for balancing exploration and exploitation. Trust Calculus: R (reliability) as an optimization object — it improves monotonically through formalization (↑F), expansion (↑G), and replication (↑R).

## Key Researchers (2024--2026)

- Karl Friston (UCL) — Free Energy Principle, active inference
- Gabriel Peyre (ENS Paris) — optimal transport
- George Karniadakis (Brown) — scientific ML, PINNs
- Marco Cuturi (Apple/CREST) — computational optimal transport
- Maziar Raissi (Colorado) — PINNs pioneer