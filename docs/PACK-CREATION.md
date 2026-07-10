# Creating a Pack: From Zero to a Working Knowledge Base

> A Pack is a Repository with formalized Domain knowledge.
> It is the single source-of-truth for domain knowledge in IWE.
> Process source-of-truth: [SPF](https://github.com/TserenTserenov/SPF)

---

## Why You Need a Pack

Without a Pack, Claude has no knowledge of your Domain's specifics each time — terminology, Methods, failure modes. With a Pack, that Knowledge loads into context automatically.

The generative chain (details: [principles-vs-skills.md](principles-vs-skills.md)):

```
FPF (meta-ontology)  →  SPF (Pack framework)  →  Pack (domain)  →  DS (implementation)
```

A Pack lives between SPF and DS: SPF defines the structure, the Pack fills it with domain Knowledge.

---

## Step 0: Distinguish a Domain From a Topic

A Pack is created for a **Domain**, not a topic.

| Domain | Topic (not for a Pack) |
|--------|------------------------|
| ML systems development | Machine learning |
| Systems analysis | Systems Thinking |
| Product management | Product thinking |
| Technical API design | REST API |

**Test:** are there people who DO this professionally? What do they produce (Artifacts)?
If yes — it is a Domain. If you just "find it interesting" — it is a topic.

---

## Quick Start: `/pack-new`

Type in Claude Code:

```
/pack-new
```

or simply: **"I want to create a pack"**, **"new pack on topic X"**, **"create a Pack for Y"**.

The Skill will guide you through the steps:

| Step | What happens |
|------|--------------|
| 0 | Checks for FPF and SPF — clones them if needed |
| 1 | 3 questions: who practices it? what do they produce? how do they make mistakes? |
| 1.5 | One external Domain source (SoTA-Sheet-lite): a book/standard/school + 2-4 theses — BEFORE choosing a name, so the name and Domain stay grounded in real practice |
| 2 | Proposes 2-3 name options + a short code → you choose; the name is provisional and is finalized after the first Distinctions |
| 3 | Fills in the Bounded Context; terms go into `ontology.md`, the Kind decision (the entity type of the core concept) goes into `.pfad-decision.md` |
| 4 | Creates the `PACK-{slug}/` structure with starter files (including the decision record and SoTA sheet) |
| 5 | Shows the Ф1-Ф6 content Roadmap + recommends `/verify pack` (baseline Assessment across 11 adequacy dimensions) |

---

## Pack Structure

```
PACK-{slug}/
├── README.md                      # Name + one-line Domain description
├── REPO-TYPE.md                   # Type: Pack, upstream: FPF + SPF
├── CLAUDE.md                      # Agent instructions
├── .pfad-decision.md              # Decision record: rejected Domain/name/boundary/Kind options
├── 00-pack-manifest.md            # Metadata + entity index
├── ontology.md                    # Domain terms (Ubiquitous Language) — populated from Step 3
├── 01-domain-contract/
│   ├── 01A-bounded-context.md     # What is in scope / out of scope / terms
│   └── 01B-distinctions.md        # Key Distinctions (A.7 FPF), maturity marker: seed/mature
├── 02-domain-entities/            # Roles, Methods, WPs — listing only
├── 03-methods/                    # Method Practice cards
├── 04-work-products/              # Work Product cards
├── 05-failure-modes/              # Typical errors and signals
├── 06-sota/                       # Domain sources (starter SoTA sheet — from Step 1.5)
└── 07-map/                        # Map of relationships between entities
```

Template: [SPF/pack-template](https://github.com/TserenTserenov/SPF/tree/main/pack-template)

---

## Pack Naming

**Formula:** `PACK-{slug}` where slug is a domain noun in Latin characters, kebab-case.

**Name criteria (all required):**
1. Specific: excludes neighboring Domains (`product-management`, not `management`)
2. Broad: covers the core Methods, not a single tool (not `jira`)
3. Recognizable: a Practitioner immediately understands what it covers

**Examples:** `PACK-product-management`, `PACK-system-analysis`, `PACK-technical-writing`

**Anti-examples:** `PACK-everything`, `PACK-jira`, `PACK-notes`, `PACK-ideas`

---

## What to Do After Creation: the Ф1-Ф6 Roadmap

A Pack is not filled in one sitting. Content grows iteratively.

**Phase order by value:**

| Phase | File | Purpose | Time | Priority |
|-------|------|---------|------|----------|
| **Ф1. Distinctions** | `01B-distinctions.md` | 7-10 "X ≠ Y" pairs for the Domain (FPF A.7) | 1-2h | First — without it, everything else is unreliable |
| **Ф2. Entities** | `02-domain-entities/` | Roles, WPs, Methods — listing only | 1-2h | Second — provides the map |
| **Ф3. Methods** | `03-methods/` | Inputs, outputs, quality criteria | 2-4h | Third — the core of the Pack |
| **Ф4. Work Products** | `04-work-products/` | Artifacts + Definition of Done | 1-2h | Fourth |
| **Ф5. Failure modes** | `05-failure-modes/` | 5-10 FMs: cause + signal | 1h | High value, often skipped |
| **Ф6. SoTA — expansion** | `06-sota/` | Deepen sources beyond the starter SoTA sheet (the first source is collected at Step 1.5 of pack-new) | 1-2h | Last; the starter source already exists |

**Principle:** start with Ф1 (Distinctions). Even the first 5 Distinctions add value — Claude stops confusing Domain terms.

---

## How to Fill a Pack During Work

You do not need to fill a Pack from scratch in one session. The right approach is to capture Knowledge as you work:

```
Discover a pattern or Distinction → /ke → Capture: [what] → PACK-{slug}/01B-distinctions.md
```

**The `/ke` command (Knowledge Extraction):**
- Call it at a Work milestone or when an important Distinction is found
- Claude announces: "Capture: [what] → [where]"
- When 5+ captures accumulate — run `/apply-captures`

---

## Pack-to-DS Relationship

A Pack contains **"what this is"** (domain Knowledge).
A DS contains **"how we do it"** (implementations, code, plans).

```
Pack-{slug}/03-methods/           ← the Method as such (domain)
DS-{project}/docs/how-we-do-X.md ← how this Method is implemented for us
```

Do not store in a Pack: code, configs, plans, registries. Those go in the DS.
Do not store in a DS: definitions, Distinctions, Methods, failure modes. Those go in the Pack.

---

## Further Reading

| Resource | What |
|----------|------|
| [SPF/process/](https://github.com/TserenTserenov/SPF/tree/main/process) | Detailed instructions for all 11 stages |
| [SPF/pack-template/](https://github.com/TserenTserenov/SPF/tree/main/pack-template) | Templates for each Pack file |
| [LEARNING-PATH.md §6](LEARNING-PATH.md) | Principles and frameworks: FPF, SPF, Pack |
| [principles-vs-skills.md](principles-vs-skills.md) | Why a Pack matters more than Skills |
| `/fpf` in Claude Code | Verify entity correctness against FPF |

