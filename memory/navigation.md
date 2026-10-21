---
description: IWE operational memory file
domains:
- reference
horizon: warm
name: navigation
originSessionId: 9a0e726a-951e-4408-9e02-94d7eeffbf74
owner: platform
schema_version: 1
status: active
type: reference
valid_from: 2026-04-13
---
# Repository Navigation (Layer 3)

> `{{GOVERNANCE_REPO}}` in the paths below is the governance repository name from `.exocortex.env` (`GOVERNANCE_REPO`); substitute the value from your installation.


## Key Files

| Topic | File |
|-------|------|
| Distinctions (hard pairs) | `memory/hard-distinctions.md` |
| FPF (navigation, principles) | `memory/fpf-reference.md` |
| Rules by repo type | `memory/repo-type-rules.md` |
| Checklists | `memory/checklists.md` |
| SOTA practices (18 items) | `memory/sota-reference.md` |
| Open Protocol (WP Gate, Ritual) | `memory/protocol-open.md` |
| Close Protocol (routing, Quick Close) | `memory/protocol-close.md` |
| Day Close (full algorithm) | `.claude/skills/day-close/SKILL.md` |
| Week Close (full algorithm) | `.claude/skills/week-close/SKILL.md` |
| DayPlan/WeekPlan Templates | `memory/templates-dayplan.md` |
| Zero Principles + hierarchy | `ZP/README.md` |
| Entity coding | `SPF/spec/SPF.SPEC.001-entity-coding.md` |
| Pack scalability | `SPF/spec/SPF.SPEC.003-pack-scalability.md` |

## Repositories

| Repo | Path |
|------|------|
<!-- Add your DS repos here. Example: -->
<!-- | My bot (READ-ONLY) | `your-org/your-bot/` | -->
<!-- | AI systems monorepo | `your-org/ai-systems/` | -->
| Templating engine | `IWE/setup.sh` |
| Personal ontology | `{{GOVERNANCE_REPO}}/ontology.md` |
| Training curriculum | `DS-principles-curriculum/` |

## Pack Repos

| Pack | Path |
|------|------|
| PACK-personal | Personal development |
| PACK-verification | Verification and acceptance (cross-domain) |
| PACK-autonomous-agents | Autonomous agents (BC, distinctions, methods) |

## Key Documents (Pack DP)

| Document | Code |
|----------|------|
| Service tiers | DP.ARCH.002 |
| Role catalog (Role-Centric) | DP.ROLE.001 § 3.2 |
| Role-Centric Architecture | DP.D.033 |
| Role Performer registry | DP.ROLE.001 § 3.1 |
| Bot error runbook | DP.RUNBOOK.001 |

## MCP

| MCP | Path |
|-----|------|
<!-- | Activity Hub | `your-org/activity-hub/` | -->
| Autonomous agents (code) | `DS-autonomous-agents/` |
| Agent data (workspace) | `DS-agent-workspace/` |

## Strategy

| File | Path |
|------|------|
| Strategy | `{{GOVERNANCE_REPO}}/docs/Strategy.md` |
| Full WP registry (WP-1…WP-85+) | `{{GOVERNANCE_REPO}}/docs/WP-REGISTRY.md` |
| WeekPlan | `{{GOVERNANCE_REPO}}/current/` |

## GitHub Organizations (do NOT mix up!)

| Org | Which repos | Examples |
|-----|-------------|---------|
| `ailev` | FPF | `ailev/FPF` |

> **Rule:** When generating a GitHub link → verify the org against this table. Do NOT default to `aisystant`.

## WP Context Files

> All context files: `{{GOVERNANCE_REPO}}/inbox/WP-{N}/WP-{N}.md` (always a folder — WP-434)
> Archive: `{{GOVERNANCE_REPO}}/archive/wp-contexts/`
