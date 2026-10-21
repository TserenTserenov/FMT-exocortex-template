# /process/ — Knowledge Creation Process

## Purpose of This Directory

This directory contains the **normative process for creating and evolving SPF packs**. It describes the activity of knowledge production, not the knowledge itself.

| Directory | Contains |
|-----------|----------|
| `/pack/` | Domain knowledge (second principles) |
| `/process/` | Activity of producing that knowledge |

These are fundamentally different:
- `/pack/` answers "What does the domain know?"
- `/process/` answers "How is that knowledge created, validated, and maintained?"

---

## Knowledge vs. Knowledge-Creation Process

| Aspect | Domain Knowledge (pack) | Knowledge-Creation Process |
|--------|------------------------|---------------------------|
| **Subject matter** | Distinctions, methods, products of a domain | Activity of formalizing knowledge |
| **Changes when** | Domain understanding evolves | Process methodology improves |
| **FPF type** | Content of second principles | Meta-process for producing them |
| **Can be wrong about** | Domain facts | Procedure effectiveness |

The process is **not part of the pack**. A medical SPF pack contains medical knowledge; this process describes how any SPF pack (medical, engineering, personal development) is created.

---

## Relationship to FPF and SPF

```
FPF (First Principles)
    ↓ provides meta-language
/process/ (Knowledge Creation)
    ↓ produces
SPF Pack (Second Principles)
    ↓ consumed by
Downstream (courses, guides, AI agents)
```

- **FPF** provides the language of distinctions (method vs. tool, role vs. person, etc.)
- **This process** uses FPF distinctions to formalize domain knowledge
- **SPF pack** is the output of this process
- **Downstream** uses the pack but does not modify it

---

## Mandatory Use

This process is **not optional**. Any modification to `/pack/` must follow this process.

| Action | Required Process Steps |
|--------|----------------------|
| Adding a method | 03 → 06 → 07 → 10 |
| Adding a distinction | 03 → 10 |
| Adding a failure mode | 06 → 08 → 10 |
| Updating SoTA status | 09 → 10 |
| Expanding domain scope | 01 → 02 → 03 → ... |

Skipping steps produces:
- Incoherent distinctions
- Methods without proper boundaries
- Missing failure modes
- Outdated knowledge presented as current

---

## Process Files

| File | Stage |
|------|-------|
| [00-process-overview.md](00-process-overview.md) | What this process is |
| [01-domain-selection.md](01-domain-selection.md) | Selecting and bounding the domain |
| [02-bounded-context.md](02-bounded-context.md) | Establishing context boundaries |
| [03-distinctions-work.md](03-distinctions-work.md) | Working with distinctions |
| [04-domain-entities-identification.md](04-domain-entities-identification.md) | Identifying stable entities |
| [05-information-ingestion.md](05-information-ingestion.md) | Admitting information for analysis |
| [06-analysis-and-formalization.md](06-analysis-and-formalization.md) | Analyzing through distinctions |
| [07-method-and-product-extraction.md](07-method-and-product-extraction.md) | Extracting methods and products |
| [08-failure-modes-extraction.md](08-failure-modes-extraction.md) | Extracting failure modes |
| [09-sota-annotation.md](09-sota-annotation.md) | Assigning SoTA status |
| [10-map-maintenance.md](10-map-maintenance.md) | Maintaining the navigation map |
| [11-review-and-evolution-cycle.md](11-review-and-evolution-cycle.md) | Ongoing review and evolution |

---

## Process Lint (Mandatory)

**Every change to `/pack/` must pass process lint before commit.**

Process lint is NOT a process stage — it is a **cross-cutting verification protocol** that ensures compliance with the SPF constitution.

| When Applied | By Whom |
|--------------|---------|
| Pre-commit | Author (human or AI) |
| PR Review | Reviewer |
| Agent work | AI after each modification |

### Lint Document

**See: [process-lint.md](process-lint.md)** for:
- Change-type matrix (what to check for each type of change)
- Universal bans (didactics, scenarios, method/tool confusion)
- Hard gates (conditions that block commit)
- Lint report format

### Quick Reference

| Change Type | Key Checks |
|-------------|------------|
| Method | No scenarios, has WP link, has distinction link |
| Work Product | Has existence criteria, links to method |
| Failure Mode | Has detection test, links to distinction |
| Distinction | Has contrast, has test, has consequence |
| SoTA | Has status, has revision criterion |
| Any structural | Map updated |

### Hard Gates

These block commit. No exceptions:
- Method without work product link
- Work product without existence criteria
- Failure mode without detection test
- Structural change without map update
- Didactic language detected

---

## For AI Agents

AI agents working on this repository:
1. Must identify current process stage before modifying pack files
2. Must produce the work products specified for that stage
3. Must not skip to later stages without completing earlier ones
4. Must update the map after any structural change
5. **Must run process lint and report results before committing**

See [CLAUDE.md](/CLAUDE.md) for explicit working rules and lint requirements.
