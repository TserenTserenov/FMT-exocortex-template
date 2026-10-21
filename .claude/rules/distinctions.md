# Distinctions (Key Terms)

> Always loaded. 1–2 lines per distinction. Criterion: DP.KR.001 §6.
> Expanded (tests, examples): `memory/hard-distinctions.md`. Authored warm: `memory/distinctions-warm.md`.

- **IWE = Intellectual Work Environment** (not "Intelligent", not "Working"). Analogy: IDE.
- **Development ≠ Education.** Do not use: "school", "university", "student", "teacher". "Apprentice" — allowed only as a Mastery stage name (qualification) or as a Role name; in all other meanings use "participant".
- **Skill ≠ SKILL.md ≠ Role ≠ Protocol.** Agent capability (mastery) / specification-contract / Functional Position / ORZ ritual. Test: skill = ability to play, SKILL.md = score.
- **settings.json ≠ settings.local.json.** Project-level (hooks, git) vs personal (permissions, .gitignore).
- **Pack knowledge ≠ Implementation decision** (HD #29). Domain truth → Pack. Technical choice → DS.
- **OwnerIntegrity** (HD #35): One fact — one **authoritative** owner. An unmanaged duplicate is a synchronization error; a derived copy is allowed only with auto-sync (such as AGENTS.md); a partial retelling is allowed only with an explicit reference to the source. Fact boundaries are defined by owner and reason for change, not by text.
- **WP-context ≠ Work result.** Context lives in the governance repo; the result lives in the target DS/Pack.
- **Persona ≠ Memory ≠ Context** (HD #27, DP.D.052 v2). Criterion: writer + owner. Persona = **distributed composition** (Ory anchor + Git declarations + Neon refs), Memory = Neon (Observed + Derived), Context/Projection = runtime ephemeral. v2 (2026-05-31): table split into 4 axes — Writer / Identity-anchor / State-storage / Snapshot-unit.
- **Bearer ≠ Persona ≠ Persona Declaration** (DP.D.052 §10, DP.ARCH.005 §0, 2026-05-31). Bearer = a person in the physical world (outside the platform); Persona = entity-in-IWE as composition (anchor + decls + refs); Declaration = one Git snapshot. Test: "I delete Git → the declaration disappears, the Persona remains (anchor lives)." Addresses the intuition "what is in the DB is not the Persona but its Version" without renaming. Lifecycle anchor: Pre-Grant `claim_token` → Granted `Ory subject_id`. Letta import: our Persona = their `human block`, **not** `persona block` (= agent self-description).
- **Problem ≠ Task ≠ FR ≠ Work** (HD #24, DP.D.053). Deadlock / method is known / specification / physical world.
- **System ≠ Role** (D.141 PD). The bearer exists independently; role = Functional Position, transferable.
- **System-in-role ≠ Role** (FPF A.2.1, R5, HD #26). Work is performed by the system-in-role; the role only defines the method and contextual participation. Notation: `system#role:context`. The role itself does nothing.
- **System of Interest of a project ≠ system class** (FPF A.2.1, R5, HD #26). The System of Interest of a project is the role that a given system plays in a specific project. One physical system in different projects = different roles. Test: "is this a class of things or a Functional Position in context?"
- **Service ≠ method** (FPF A.6.P, HD #31). "Service" is a trigger word for decomposition: separate the promise, the provider role, the delivery method, the delivery work and its evidence — each under its own rule. Method is only one facet; collapsing them back into a single "service package" is not allowed.
- **Mastery ≠ Mastery stage** (FPF A.1.SCR, HD #32). "Mastery" is an ambiguous word, not an entity: the source explicitly states `no U.Mastery is admitted`. Behind it stands the holder's capability (`U.Capability`), the learning work, the assessment, or a specific bearer. Mastery stage = a measurable characteristic of execution quality. Test: "is this who/what can perform, or how well was it performed?"
- **Exoskeleton ≠ Autopilot** (DP.D.046). Augmented thinking / autonomous LLM. Test: can you explain it without saying "the AI suggested it"?
- **Log ≠ Incident ≠ State file** (DP.D.049). Chronology at the performer / failure + analysis in governance / snapshot at the performer.
- **Script ≠ Agent** (DP.D.048). Fixed flow / LLM chooses the step. Test: remove the LLM — does it break?
- **TPF (principles level) ≠ DS (repository layer).** TPF — a position in the principles hierarchy; DS — the repository where that work materializes.

<!-- USER-SPACE -->
<!-- /USER-SPACE -->