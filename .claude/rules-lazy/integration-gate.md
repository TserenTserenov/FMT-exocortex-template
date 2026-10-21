# IntegrationGate — Full Specification

> Hot-trigger: `CLAUDE.md` §2, Pre-action Gates table + compact checklist. This file is an elaboration (WP-450 Phase1).

When designing a new tool, agent, detector, system, or method, follow a strict phase sequence. Skipping a phase is pattern P10 (DP.FM.010). Log it as an Incident in the `C.IT-Platform/C2.IT-Platform/C2.3.Operations/Incidents/` directory of your ecosystem-development Repository, if one exists; otherwise log it in the `incidents/` governance repo.

1. **Promise (Service Clause).** What promise does the tool make to the consumer? Create or update `DP.SC.NNN` in `PACK-digital-platform/.../08-service-clauses/`. The promise contains: trigger, inputs, outputs, response time, invariant (what is guaranteed), and failure mode.
2. **Usage Scenarios.** Who triggers it? When? Why? In what context? What do they do with the result? Provide at minimum 3 scenarios with different consumers. Attach to the Service Clause.
3. **Role.** What Role does the tool play in the system? Create or update `DP.ROLE.NNN` in `PACK-digital-platform/.../02-domain-entities/`. The Role contains: responsibilities, authorities, relationships with other Roles, inputs and outputs as Artifacts. When defining the Role, identify the **Kind** (entity type) and **Owner Role** (who owns the Role in the Supersystem). Template: DP.D.033.
4. **Implementation.** Only after steps (1)–(3). Code, tests, registration in hooks/config, smoke-test. The implementation header must include a reference to the Service Clause and Role (`# see DP.SC.NNN, DP.ROLE.NNN`).

## Exceptions (IntegrationGate is NOT required)

- Editing an existing tool without changing its promise.
- Bugfix without changing externally visible behavior.
- Refactoring (renaming, reorganization) without functional changes.
- An experimental Script intended for a single run (but if run repeatedly, it is already a tool).