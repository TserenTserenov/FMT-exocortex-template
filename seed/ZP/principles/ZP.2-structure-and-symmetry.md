# ZP.2 — Structurality and Symmetries

## Definition

Describe through invariants and structures, not through individual objects.

## Consequence

Look for what does NOT change under transformations (the invariant). If you have described 10 objects but have not described their structure and relationships, you have described nothing yet.

## Application Examples

**1. Equivariant neural networks (E(n)-GNN, 2024–2025).**
Networks that "bake in" symmetries (translation, rotation, permutation) into the Architecture itself via group theory. PNAS 2025 (Smidt, Batzner et al.): hybrid invariant–equivariant approaches achieve higher accuracy. Key insight: describing data through invariants (symmetry-respecting features) outperforms describing individual data points.

**2. Applied category theory (ACT, 2024–2025).**
ACT 2024 at Oxford (49 talks): categories applied to mechanics, quantum physics, probability, linguistics, epidemiology, and thermodynamics. Knowledge is not a collection of objects but a structure of relationships (morphisms). Analogy = functor (a mapping that preserves structure across Domains). Fong & Spivak: "Seven Sketches in Compositionality".

**3. PtBi₂ — a superconductor with a new symmetry breaking (January 2026).**
The first known superconductor where electron pairing is constrained to a sixfold-symmetric pattern, distinct from all known cases. A topological superconductor discovered through symmetry analysis.

**4. Emergent gravity from spontaneous symmetry breaking (2026).**
Demonstrates how spacetime and gravity emerge from spontaneous breaking of a larger gauge symmetry, reproducing key properties of general relativity. Structure (the spacetime metric) arises from symmetry, not from individual objects.

**5. Quantum liquid-crystal phase (August 2025).**
At the boundary between a Weyl semimetal and a magnetic spin ice, electrons flow in unpredictable directions, breaking traditional symmetry. A new symmetry-breaking pattern produces a new state of matter (Rutgers, ScienceDaily).

## Typical Violations

**N1. Strict equivariance is too rigid for real data.** When symmetry is approximate (broken or partial), strictly equivariant networks underperform. PEnGUiN (2025): real data often has partial symmetry — treating all symmetries as exact is an anti-pattern.

**N2. Mirror invariance interferes with reading.** A child's visual system treats mirror images as identical by default (bilateral symmetry) — adaptive for object recognition, but catastrophic for reading: 'b' and 'd' are structurally identical under reflection. Learning to read (ages 5–7) requires suppressing this innate invariance.

**N3. Variant-oriented genomics loses invariant information.** Standard VCF files omit invariant genome positions: it becomes impossible to distinguish "no data" from "no variation." Systematic disregard of invariant structure distorts diversity statistics. Tool: vcfsim (2025).

**N4. Accumulating facts without searching for invariants.** The learning-styles myth (visual/auditory/kinesthetic): d=0.04 across 4 meta-analyses (Pashler et al. 2008). Describing learners by surface features (objects) rather than by learning invariants (prior knowledge, d=0.94 per Hattie).

## Expression in Child Development

Symmetry perception is one of the earliest cognitive invariants. At 4 months, infants habituate to symmetric polygons faster than to asymmetric ones: the brain builds invariant detectors before cataloguing individual objects. By ages 4–6, children distinguish types of symmetry in the following order: bilateral > rotational > translational. The paradox: learning to read (ages 5–7) requires suppressing innate mirror invariance — cultural learning sometimes demands violating a natural principle.

## Relationship to FPF

Holon = structural unit, Bounded Contexts. A holon is a unit of structure; a Bounded Context is the boundary of a consistent structure. FPF Γ-algebra: Invariant Quintet (IDEM, COMM, LOC, WLNK, MONO) — five aggregation invariants whose violation leads to silent failures. Category theory: FPF morphisms (Role → Capability → Service → Work) preserve structure under transformations.

## Key Researchers (2024–2026)

- Tess Smidt (MIT) — equivariant neural networks (E3NN)
- Max Welling (Amsterdam) — geometric deep learning
- John Carlos Baez (UC Riverside) — applied category theory
- Emily Riehl (Johns Hopkins) — foundations of category theory
- Michael Bronstein (Oxford) — geometric deep learning