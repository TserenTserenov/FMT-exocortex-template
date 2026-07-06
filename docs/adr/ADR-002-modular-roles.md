# ADR-002: Modular Role Architecture

**Status:** Accepted
**Date:** 2026-03-01
**Context:** FMT-exocortex-template/roles, PACK-digital-platform (DP.D.033, DP.ROLE.001)

---

## Context

The exocortex template ships with 3 roles: Strategist (R1), Extractor (R2), Synchronizer (R8). Each role is a separate directory under `roles/`, but role names were hardcoded in `setup.sh`, `update.sh`, `scheduler.sh`, and `notify.sh`.

Reviewer note (Evgeny Miller, 2026-03-01): "Packs are extracted into separate modules, but roles remain inside the template. For me, the core value is in the Pack and role descriptions — not in the specific service implementation."

## Problem

1. **Hardcoded roles.** Adding a new role requires editing 4 scripts (`setup.sh`, `update.sh`, `scheduler.sh`, `notify.sh`) — even when the directory structure is correct.
2. **Implicit contract.** All three roles follow the same pattern (README + install.sh + prompts/ + scripts/), but this pattern is never formalized. A new user must reverse-engineer the structure from examples.
3. **Knowledge baked into code.** A role is domain knowledge (DP.D.033: what to do, what obligations apply, what Work Products exist). But the role description and its implementation are mixed in one directory with no explicit separation.

**ArchGate (EMOGSSB):**

| Characteristic | Before (hardcoded) | After (modular) |
|---|---|---|
| Evolvability | 6 | 9 |
| Scalability | 5 | 9 |
| Learnability | 6 | 9 |
| Generativity | 5 | 8 |
| Speed | 10 | 10 |
| Modernity | 6 | 8 |
| Security | 9 | 9 |
| **Average** | **6.7** | **8.9** |

The current solution falls below the threshold of 8. Scalability (5) and Generativity (5) are critically low: a user cannot add a custom role without reading through 4 scripts.

## Alternatives

### A. Central Registry (roles.yaml at root)

A single `roles/roles.yaml` file lists all roles. Scripts read from it.

- (+) Single point of registration
- (−) Two sources of truth: the registry and the directory. They drift out of sync when a role is added without updating the registry.
- (−) Violates the module autonomy principle — the role depends on an external file.

### B. Per-role manifest (role.yaml) + auto-discovery

Each role contains a `role.yaml` with metadata. Scripts scan `roles/*/role.yaml`.

- (+) The role is self-contained (like a Pack repo: everything in one directory)
- (+) Adding a role = creating a directory. No external files to edit.
- (+) Removing a role = deleting a directory. No registry cleanup needed.
- (−) Grepping YAML without a parser is fragile for complex structures.
- (−) No order control (mitigated: `install.priority`)

### C. Convention-only (no manifest)

Auto-discovery by structure: if `install.sh` exists → it is a role. No metadata required.

- (+) No new files
- (−) No way to distinguish auto-install from manual-install
- (−) No machine-readable metadata (display_name, type, id)
- (−) Cannot link to the DP.ROLE.001 catalog

## Decision

**Option B: role.yaml + auto-discovery.**

Rationale:
- **Module autonomy.** Just as a Pack repo contains everything for a Domain, a role directory contains everything for the role — including the manifest. This is analogous to `package.json` in an npm package.
- **Convention over configuration.** Parsing role.yaml is a simple `grep` on flat top-level fields. No dependency on `yq`, `python`, or any other tool. Sufficient for 3–10 roles.
- **Link to Pack.** The `id: R1` field in role.yaml connects the implementation to the source of truth in DP.ROLE.001 §3.2. This provides traceability: template contract → role catalog → role description (DP.D.033).
- **Precedent:** ADR-001 established that generativity (fork = working system) is a priority. Modular roles reinforce this principle: a user can add a custom role without understanding the internals of any script.

## What Changed

**New files:**
- `roles/ROLE-CONTRACT.md` — formal specification (required/optional files, role.yaml schema)
- `roles/strategist/role.yaml` — manifest for R1
- `roles/extractor/role.yaml` — manifest for R2
- `roles/synchronizer/role.yaml` — manifest for R8

**Modified scripts:**
- `setup.sh` — iterates over `roles/*/role.yaml` instead of hardcoded Strategist
- `update.sh` — iterates over `roles/*/install.sh` instead of 3 if/else branches
- `scheduler.sh` — `get_role_runner()` reads `runner:` from role.yaml with convention-based fallback
- `notify.sh` — dynamic agent list from `templates/*.sh`

**Documentation:**
- `roles/README.md` — "How to add a role" section rewritten
- `ONTOLOGY.md` — reference to ROLE-CONTRACT.md added
- `docs/LEARNING-PATH.md` — §7.4 "Role Contract"
- `DP.ROLE.001` (Pack) — note on role contract in the template
- `DP.D.033` (Pack) — §8 "Role modularity as a consequence"

## Principles

- **Module autonomy** — the role is self-contained: manifest + description + implementation in one directory
- **Generativity** — a user adds a role by following the contract, without modifying Infrastructure
- **Traceability** — role.yaml → DP.ROLE.001 §3.2 → DP.D.033 (from code to knowledge)
- **Convention over configuration** — grep over YAML, no parser, minimal complexity

## What Did NOT Change (conscious boundaries)

- **scheduler.sh dispatch** — scheduling logic remains hardcoded. Full config-driven dispatch (reading `schedule:` from role.yaml) is a separate task, deferred until the role count exceeds 5. For now, `config.yaml` in `synchronizer/` documents the schedule; `scheduler.sh` does not read it.
- **Schedule** — still defined in `synchronizer/config.yaml`, not in role.yaml. One place for the full schedule is better than N fragments across N roles.
- **Role description (DP.D.033 template)** — still in each role's README.md (and in system.yaml in DS-ai-systems). role.yaml does not duplicate obligations or methods — it contains only operational metadata.

## Consequences

- template-sync.sh: add role.yaml × 3 and ROLE-CONTRACT.md to the sync manifest
- Users on existing forks: running `update.sh` will pull the new role.yaml files automatically
- Future roles: created by contract, with no script edits required