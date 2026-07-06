# ADR-001: setup.sh Embedded in Template

**Status:** Accepted
**Date:** 2026-02-28
**Context:** FMT-exocortex-template, DS-ai-systems/setup

---

## Context

Before v0.3.0, the `setup.sh` script resided in a separate Repository `DS-ai-systems/setup/`. Users had to:
1. Clone `DS-ai-systems`
2. Navigate to `DS-ai-systems/setup/`
3. Run `bash setup.sh`

Rationale: ontological separation of types (FMT = Format, DS = instrument) and perimeters (L2 Platform → L3 Template → L4 Personal).

## Problem

Users cannot fork the Template and run it — `setup.sh` is absent from the fork. They must clone an additional Repository, which may not be accessible.

**ArchGate (EMOGSSB):**

| Characteristic | Before (external) | After (embedded) |
|----------------|-------------------|-----------------|
| Evolvability | 7 | 8 |
| Scalability | 8 | 8 |
| Learnability | 5 | 9 |
| Generativity | 3 | 9 |
| Speed | 7 | 8 |
| Currency | 7 | 8 |
| Security | 8 | 8 |
| **Average** | **6.4** | **8.3** |

The current solution falls below the threshold of 8. Generativity (3) and Learnability (5) are critically low.

## Solution

Move `setup.sh` to the root of FMT-exocortex-template (alongside `update.sh`).

**What is moved:**
- `setup.sh` — modified: auto-detection of TEMPLATE_DIR, fork step removed (the user forks manually)
- `setup/validate-template.sh` — Template validation

**What remains in DS-ai-systems:**
- `template-sync.sh` + `sync-manifest.yaml` — authoring tools (not needed by the user)
- `.sync-hashes/` — runtime state of the authoring sync

**New user flow:**
```bash
gh repo fork TserenTserenov/FMT-exocortex-template --clone
cd FMT-exocortex-template
bash setup.sh
```

## Principles

- **Module autonomy** — the Template is now self-contained
- **Generativity** — fork = working system (cookiecutter pattern)
- **Separation of concerns** — authoring sync tools remain in DS-ai-systems

## Consequences

- `template-sync.sh` must synchronize `setup.sh` as one more file
- Leave `DS-ai-systems/setup/setup.sh` with a deprecation notice (backward compatibility)
- `sync-manifest.yaml`: add an entry for `setup.sh`