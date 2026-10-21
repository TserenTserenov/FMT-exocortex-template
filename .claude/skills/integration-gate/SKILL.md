---
browser_safe: false
description: 'IntegrationGate — a mandatory checklist (4 steps) for designing a new
  tool, agent, detector, or system. Load on triggers: new tool / agent / detector
  / system / method / integration.'
layer: L1
name: integration-gate
related:
- archgate
status: active
triggers:
  phrases:
  - new tool
  - new agent
  - new system
  - new detector
  - new method
  - integration gate
  - IntegrationGate
  slash:
  - /integration-gate
version: 1.0.0
---

# /integration-gate — IntegrationGate

> **Trigger:** new tool / agent / detector / system / method  
> **Priority:** BLOCKING — skipping a Phase = pattern P10 (DP.FM.010)

## Checklist (4 steps — strictly in order)

> Skipping a Phase → record as an Incident: `C2.3.Operations/Incidents/` in your ecosystem-development Repository (if present) or `incidents/` governance repo

1. **Promise (Service Clause).** What promise does the tool make to the consumer?  
   Create or update `DP.SC.NNN` in `PACK-digital-platform/.../08-service-clauses/`.  
   Contains: trigger · inputs · outputs · response time · invariant · failure mode.

2. **Usage scenarios.** Who triggers it? When? Why? In what context? What do they do with the result?  
   Minimum 3 scenarios with different consumers. Attach to the Service Clause.

3. **Role.** What Role does the tool play in the system?  
   Create or update `DP.ROLE.NNN` in `PACK-digital-platform/.../02-domain-entities/`.  
   Contains: responsibilities · authority · relationships · inputs/outputs as Artifacts.  
   Identify the **Kind** and the **Owner Role** (who owns it in the Supersystem). Template: DP.D.033.

4. **Implementation.** Only after steps (1)–(3).  
   Code · tests · registration in hooks/config · smoke-test.  
   Implementation header: `# see DP.SC.NNN, DP.ROLE.NNN`

## Exceptions (IntegrationGate is NOT required)

- Editing an existing tool without changing its promise.
- Bugfix without changing externally visible behavior.
- Refactoring (renaming, reorganization) without functional changes.
- Experimental Script for a single run (if run again — it is already a tool).

<!-- USER-SPACE -->
<!-- /USER-SPACE -->
