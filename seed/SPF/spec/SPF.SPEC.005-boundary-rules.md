---
created: 2026-04-21
depends_on:
- SPF.SPEC.001
- FPF.A.1.1
id: SPF.SPEC.005
name: Boundary Rules — Pack and Database Decomposition
status: draft
---

# Boundary Rules — Pack and Database Decomposition

> SPF specification: decision rules for (a) when a new Pack must be created and (b) when a new runtime database must be separated. Both decisions answer the same structural question — "is this one Bounded Context or two?" — at different scales.

---

## Problem

Two recurring decisions in SPF work:

1. **Pack decision.** A new topic appears (service, domain, concept). Is it a section inside an existing Pack, a new Pack, or a draft that has not earned Pack status yet?
2. **Runtime database decision.** A new data area appears (new entity, new event stream). Does it go into an existing database, or does it require a separate database with its own schema and lifecycle?

Historically both decisions were made ad-hoc, by analogy with neighbouring files/databases, without explicit criteria. Result: Pack-fork (a new Pack that duplicates 80% of an existing one), Pack-process (name is a verb, not a domain), Pack-thin (a Pack with one method and no work-products), and databases whose names encode implementation details (`aist_bot`, `content-pipeline`) rather than bounded contexts.

**SPF.SPEC.005 fixes the form of both decisions as binary multiple-choice gates** — the same shape as ArchGate in PACK-digital-platform. Quantitative thresholds (percentages, weights, scores) are banned: they invite calibration by feel rather than by substance.

---

## Hard constraint: decision form

Every decision below is a **binary checklist**. For each test there is an explicit definition of "passes". The decision rule is the conjunction — all tests must pass. Any "no" or "unclear" blocks the decision.

Banned in boundary decisions:
- percentages (`>30% overlap`)
- weighted scores (`T1=3, T2=2, threshold ≥6`)
- arbitrary "N of M" without reasoned criteria for the choice of M and N

Rationale: quantitative thresholds without calibration on historical data are smoke. Numbers get picked from thin air, applied inconsistently, and fail to catch what they were supposed to catch. A qualitative binary checklist with an explicit "passes" definition for each item is applied uniformly by any agent and can be audited after the fact. ArchGate (DP.ARCH.001) is the reference implementation of this form.

See also: `memory/feedback_decision_gates.md` (authoring memory).

---

## Part A. Pack Boundary Decision

### A.1. Decision gate (T1–T4, ArchGate-style)

A new Pack is created **only when all four tests pass**.

| Test | Statement | Passes when |
|------|-----------|-------------|
| **T1. Own primary question** | The candidate has a distinct primary question | The question is stated in one sentence, references a Bounded Context different from every neighbouring Pack, and is not a rephrasing of a neighbouring Pack's question |
| **T2. Own stable work-product type** | The candidate produces an Artifact type absent in every neighbouring Pack | At least one WP type (contract, diagram class, checklist, report format) exists in the candidate and cannot be placed inside any existing Pack without breaking that Pack's scope |
| **T3. Own set of distinctions** | The candidate has its own semantic boundary | At least one pair of terms (A ≠ B) exists such that without the candidate's context the Distinction cannot be made. Pure import from a neighbouring Pack (same A ≠ B, same justification) does not count |
| **T4. Own glossary** | The candidate carries its own vocabulary | Terms used inside the candidate are defined locally (with references to FPF UTS where applicable). Terms imported from neighbouring Bounded Contexts are imported through an explicit Anti-Corruption Layer, not copy-pasted |

**Decision rule:** all four pass → new Pack (status: `draft` until full manifest is filled). Any "no" or "unclear" → **not a Pack** (section inside an existing Pack, or draft outside Pack tree with `promote_by: YYYY-MM`).

### A.2. Structural rules (apply after the decision)

Once a Pack is created, four structural invariants hold:

| Rule | Statement |
|------|-----------|
| **Context Isolation** | No foreign keys between Pack entities. Cross-Pack links go through Bridges (FPF B.3) only |
| **Cohesion** | Every entity in a Pack sits in a single coherent Bounded Context. The "why does this belong here?" test is answerable in one sentence |
| **Anti-Corruption Layer** | Data imported from upstream (other Packs, external systems) is validated against the local Glossary at the boundary. No silent passthrough |
| **Naming semiotics** | Pack name is unique in the SPF tree, distinguishable from neighbouring Packs, and free of homonyms with FPF kernel terms |

### A.3. Passport fields (SPF.SPEC.005-compliant manifest)

Every Pack manifest (`00-pack-manifest.md`) must include:

- `pack_id` — short code
- `pack_name` — full domain name, noun
- `fpf_bounded_context_id` — `<DOMAIN>:<ContextName>_v<version>` (FPF A.1.1)
- `version` — semantic version
- `status` — `draft | active | deprecated`
- `primary_question` — one sentence (T1)
- `glossary` — inline or linked, terms defined locally (T4)
- `invariants` — statements that hold for every entity in this Pack
- `scope_in` — what this Pack covers
- `scope_out` — what it explicitly does not cover
- `bridges` — links to neighbouring Packs with ACL markers
- `name_rationale` — why this name was chosen (paragraph)
- `external_sources` — FPF edition, SoTA references
- `acl_location` — where ACL validators live (if cross-Pack import exists)
- `model_categories` — which of the eight WP-257 categories the Pack describes. Multi-value: one or more of `persona`, `memory`, `context` (user-model layers), `platform-knowledge`, `catalog`, `service-ops`, `relational`, `proto-persona` (outside user-model). A Pack may cover several categories only if the border between them is documented in `scope_in` / `scope_out`. See DP.D.050, WP-257.

---

## Part B. Runtime Database Boundary Decision

### B.0. Model category assignment (prerequisite to B1–B4)

Before applying B1–B4, classify the candidate data into **one** of eight WP-257 categories. The classification determines writer/owner boundary upfront and blocks B1 questions that apply "in a vacuum".

**Three user-model layers** (data about one specific user):

| Category | Writer | Owner (source-of-truth) |
|----------|--------|------------------------|
| `persona` | user (or agent by delegation with acceptance) | user's Git repo |
| `memory` | platform services | Neon |
| `context` | runtime agent | ephemeral (not stored) |

`memory` has two internal levels — **Observed** (events, logs) and **Derived** (aggregates, baselines, indicators). They may share one DB with separate schemas, or split into two DBs if B1–B4 pass independently.

**Five categories outside the user model** (data with non-user writer/owner):

| Category | Typical writer | Typical owner |
|----------|----------------|---------------|
| `platform-knowledge` | platform team via indexers | team's shared ontology (Git + projection) |
| `catalog` | admin/ops via Directus-like tools | reference data registry |
| `service-ops` | observability collectors, finance/ops services | ops team |
| `relational` | matching/community services | community-ops team |
| `proto-persona` | landing/acquisition services | pre-Ory lead registry, claim-transferable |

**Decision rule:** exactly one category → proceed to B1–B4. Two or more categories claimed for one candidate → **split the candidate** (one DB per category), or justify as a deliberate multi-category DB with explicit writer/owner mapping per table.

**Why this step precedes B1–B4:** category assignment fixes writer + owner before boundary tests. Without it, B1 ("single owner") is answered by pointing at a transport writer (ingestion-gateway, relay) and hiding the real semantic owner, which is the WP-257 failure mode.

### B.1. Decision gate (B1–B4, same form as T1–T4)

A new runtime database is created **only when all four tests pass**.

| Test | Statement | Passes when |
|------|-----------|-------------|
| **B1. Single writer-owner (semantic source-of-truth)** | The candidate data has one **semantic** owner of writes — the service that produces the meaning, not a transport relay | One and only one semantic writer. Transport writers (ingestion-gateway, outbox relay, event bus) do not count — the test identifies who produces the meaning, not who persists the bytes. If two services produce meaning, either they share the same Bounded Context (merge) or the data must split (per WP-257 writer/owner criterion) |
| **B2. Own invariant** | The candidate enforces an invariant that neighbouring databases do not | At least one integrity constraint (business invariant, not merely technical FK) holds here and is not meaningful outside this database |
| **B3. Independent blast radius** | Outage of this database does not cascade to neighbouring domains via read/write coupling | If this database is down, neighbouring services either continue with degraded functionality or fail in a bounded way. Tight coupling across the boundary means the boundary is wrong |
| **B4. Own vocabulary** | The candidate's table names, column names, and codes come from a local glossary | Terms align with one Bounded Context's Glossary. If half the tables speak one vocabulary and half another, the boundary is inside the database, not around it |

**Decision rule:** all four pass → new database. Any "no" or "unclear" → **not a new database** (schema inside an existing database, or postpone separation until the data area grows).

### B.2. Naming rules (N1–N5)

Applied to every new database name, and retroactively to existing names under review.

| Rule | Statement | Passes when |
|------|-----------|-------------|
| **N1. Noun-area** | Name is a noun naming a subject area | Name refers to a domain, not an action or a system (no `content-pipeline`, no `aist_bot`) |
| **N2. Central entity** | The central entity of the database is discoverable from the name | A reader who knows the domain can guess the primary table within 2 guesses |
| **N3. No technical markers** | Name is free of technical or historical markers | No `_v2`, no `_new`, no service/technology names (`neon_`, `pg_`, `bot_`) |
| **N4. Source-language concept available** | For projects with a non-English working vocabulary, a single-word concept for the database exists in that vocabulary and is recorded in `name_rationale` | A noun area in the working language captures the same boundary; it is documented even if the DB name uses Latin |
| **N5. Lowercase single word (or hyphenated short phrase)** | Name follows DB conventions | Lowercase; one word or short hyphenated phrase; matches PostgreSQL/Neon identifier conventions |

**Decision rule:** all five pass → name approved. Any "no" → rename required (or naming debt recorded as WP).

### B.3. Physical placement vs. logical boundary

B1–B4 define the **logical** Bounded Context boundary. Physical placement (one PostgreSQL cluster vs. many, one schema vs. many inside one cluster) is an implementation decision. The rule: every logical BC has a visible boundary — either a separate database, or a separate schema with an explicit `owner_service` marker in a central DB registry. Conflating physical "one cluster to save cost" with logical "one Bounded Context" is the most frequent source of boundary rot.

---

## Part C. Cross-cutting concerns

### C.1. Order of operations

When both Pack and database are created together (most common case for a new service):
1. Apply Part A (T1–T4). If Pack fails — stop; do not create a database for a Pack that does not exist.
2. If Pack passes, fill the manifest (including `model_categories`).
3. Apply Part B.0 — assign one of eight WP-257 categories to the data candidate.
4. Apply Part B (B1–B4) to decide runtime database.
5. Apply Part B.2 (N1–N5) for the name.

Reverse order ("name the DB first, Pack later") is a **known failure mode** — the DB name locks the conceptual boundary prematurely.

### C.2. Retroactive audit

Existing Packs and databases are audited using the same checklists. A failed test is not automatic deletion — it becomes a decision:
- **Pack fails T-tests** → downgrade to section of neighbouring Pack, or keep as `draft` with `promote_by`
- **Database fails B-tests** → plan merge/split in an architecture Roadmap (not immediate operation)
- **Name fails N-tests** → rename in a coordinated Migration (separate WP)

### C.3. Hard bans

- SPF itself must not ship domain content while specifying these rules (SPF/CLAUDE.md §5.2). Examples below use placeholders, not real Pack content.
- No didactics in rule wording (SPF/CLAUDE.md §5.1). No "step 1 / step 2 / first learn then apply".

---

## Part D. Worked example (placeholder)

**Candidate:** a hypothetical service "Financing" (financing and accounting).

**Pack decision (T1–T4):**
- **T1** — primary question "How are payments distributed across multiple recipients?" → yes (distinct from PD, DP, MIM, VR primary questions).
- **T2** — Artifact types: ledger entry (double-entry), period close report, reconciliation report. Not present in any existing Pack → yes.
- **T3** — Distinctions: "Payment ≠ Posting", "Recipient ≠ Account", "Billing ≠ Acquiring". Not reducible to other Packs → yes.
- **T4** — glossary: accruals, ledger, journal entry, chart of accounts. Defined locally with ACL to PD.ARCH.004 §2 (payment classes) → yes.
- Decision: **new Pack** (candidate name: PACK-financing or working-language equivalent).

**Database decision (B1–B4):**
- **B1** — single owner: the Financing service writes ledger and reconciliation. The Promotion service writes promotion events but not the ledger → separate write ownership → yes.
- **B2** — own invariant: "every credit has a matching debit, balance closes at period end". Meaningful only inside accounting → yes.
- **B3** — blast radius: if the ledger DB is down, bot/LMS/knowledge-mcp continue (they do not read the ledger on the hot path); billing writes are queued → yes.
- **B4** — vocabulary: accounts, entries, postings, periods. Local to one Glossary → yes.
- Decision: **new database** (candidate name subject to N1–N5).

**Name (N1–N5):**
- Candidates: `ledger`, `finance`, `accounting`, `billing`.
- `ledger` — N1 noun ✅, N2 central entity (ledger entries) ✅, N3 no tech markers ✅, N4 working-language concept "general ledger" ✅, N5 single lowercase ✅ → approved.
- `billing` — N2 central entity ambiguous (billing events vs. invoices) ⚠️ → runner-up.
- Working-language concept recorded: "general ledger" / "payment accounting".

**Split consideration.** Billing (raw payment events, idempotency keys, payment_method tokens) may itself be a separate Bounded Context from accounting (ledger, period close). Retest B1–B4 for each candidate — if both pass independently, two databases; if billing fails B2 (no own invariant beyond idempotency), it is a schema inside `ledger`.

---

## References

- FPF A.1.1 — Bounded Context as kernel holon
- FPF B.3 — Bridges between Bounded Contexts
- DP.ARCH.001 §7 — ArchGate form (binary criteria pattern)
- DP.D.050 — Persona ≠ Memory ≠ Context (user-model layer classification)
- WP-257 — Persona / Memory / Context replacing the monolithic "digital twin"; writer+owner criterion; eight-category taxonomy
- SPF.SPEC.001 — entity coding
- `memory/feedback_decision_gates.md` — authoring rule: no percentages, no weights, no scores

---

## Completion criteria for this spec

| Criterion | Test |
|-----------|------|
| Both gates are binary | Every test has an explicit "passes when" definition |
| No quantitative thresholds | No percentages, weights, or scores anywhere |
| Order of operations is fixed | Pack decision precedes category assignment, category precedes B1–B4 |
| WP-257 category assignment is explicit | Part B.0 lists all eight categories with writer/owner |
| Passport fields listed | Manifest required fields enumerated, including `model_categories` |
| Worked example present | At least one placeholder application shown |
