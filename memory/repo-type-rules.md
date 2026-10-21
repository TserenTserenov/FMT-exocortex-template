---
description: IWE operational memory file
domains:
- reference
horizon: warm
name: repo-type-rules
originSessionId: 9a0e726a-951e-4408-9e02-94d7eeffbf74
owner: platform
schema_version: 1
status: active
type: reference
valid_from: 2026-04-09
---
# Rules for Working With Repository Types


## Principles Ladder and Repository Mapping

| Level | Meaning | Where it lives in IWE |
|---------|-------------|-----------------|
| ZPF (zero principles) | Universal truths (logic, ontology) | Base / ZP |
| FPF (first principles) | Correctness per academic disciplines | Base / FPF |
| SPF-methodology | Domain form for a group of companies (template) | Base / SPF |
| SPF-instance | Populated domain for a specific company | Pack |
| TPF-content | Plans, courses, code — artifacts for an org | DS-repositories (content) |
| TPF-process | How an agent operates: work breakdown, gates, hooks, skills | {{GOVERNANCE_REPO}} + .claude/ + memory/ |
| LPF-declarative | Statements that lose meaning when the role performer is replaced by another performer of the same role | primarily `Lifework/`: "Personal Charter", "My Mission", "Family Way of Life"; selected fragments of "Professional Principles" |
| LPF-operative | Fragments of the actual lived trajectory of a role (decisions, sessions, plans) that cannot be reduced to a universal agent protocol or domain knowledge — both active and archived | fragments in `current/`, `decisions/`, `sessions/`, `inbox/WP-*/` and their archived equivalents (`archive/wp-contexts/`, `archive/decision-log/`, `archive/sessions/`) |

> *LPF (practices of a role tied to a specific performer, term by ailev, June 2026) — a cross-cutting classification of artifacts and fragments, not of containers or whole Work Products. It applies regardless of whether the container is active or archived. Test: does a fragment lose meaning when the role performer is replaced by another performer of the same role? Yes → LPF; No → Pack (domain knowledge, reusable for the role in general) or TPF-content (product for an external consumer). A single Work Product or file may simultaneously contain an LPF-operative trace (decision trajectory) and a TPF-content/Pack output (final artifact) — for example, in session WP-448 Phase 11: the dialogue trajectory is LPF-operative; the final table row is TPF-content. LPF-declarative content lives primarily in `Lifework/`, but not entirely: "Creator Manifesto" and "Ecosystem Constitution/Charter" are excluded by the test (they retain meaning when the signatory is replaced — these are Pack/TPF-content and remain physically in `Lifework/` without relocation; relocation is out of scope for Phase 11). Resolved in peer-session `2026-07-02-03-wp448-f11-lpf-arch`.*

> **Amendment 2026-09-16 (cross-checked against the primary source `FPF/FPF-Spec.md` L.69994, 71344, 76765 + `github.com/ailev/FPF`).** The paragraph above about LPF is not a paraphrase of Levenchuk — it is an IWE adaptation. In Levenchuk, LPF = **Local Practice Framework**, a framework for ONE bounded local setting; the example list of seven variants — organization, project, team, workflow, **tool**, practitioner position, or audience (L.69994). "Role performer" is only one of the seven — not the sole or defining criterion. Structurally, LPF is a full package-framework on par with DPF (its own manifest, edition, and publication form — `E.11.PFP`), and is not necessarily "not a container" — that was an IWE narrowing, decided in Phase 11 not to create a container, by local decision, not by quoting the source. The performer-replacement test below remains a working IWE criterion for "Pack vs personal", but it is a local tool, not a definition of LPF. Starting 2026-09-16, IWE also recognizes a container-LPF — a pack bounded to the practices of a specific practitioner (see the new pack below, if created).

> *DPF (Domain Principles Framework, term by ailev 2026) = renaming of SPF-instance in ailev's terminology. In IWE: DPF and Pack are two names for the same entity. Formally: DPF = principles level for a specific organization (SPF-instance). Substantively: Pack = repository with a populated domain. When reading ailev texts, translate "DPF" → read as "Pack" in IWE. No renaming is planned in IWE — footnotes only (WP-448 Phase 8).*

## 3 Repository Types

| Type | Subtype | Contents | Source-of-truth | Who creates it |
|-----|--------|-------------|-----------------|-------------|
| **Base** | Principles | ZP, FPF, SPF | Yes | Platform |
| **Base** | Formats | FMT-* (structure protocols) | Yes (for format) | Platform |
| **Pack** | — | Domain knowledge (second principles) | Yes | User |
| **DS** | instrument / governance / surface | Derived from Pack | No | User |

> Base = provided by the platform. Pack and DS = created by the user.
> Pack = second principles. DS = third principles. Details: `ZP/README.md`

## Base (Platform)

### Base/Principles (ZP, FPF, SPF)

**Contains:** Zero principles (ZP), correctness frameworks (FPF, SPF), hierarchy map.

**Allowed:** Refine principle formulations, update the hierarchy map, update form/process specifications.

**Not allowed:** Domain content (→ Pack). Didactic content (→ DS/surface).

### Base/Formats (FMT-*)

**Contains:** Repository structure protocols (IWE, FMT-s2r).

**Allowed:** Refine format specifications, add examples.

**Not allowed:** Subject-matter content (→ Pack). Code (→ DS/instrument).

> A user may create their own format — this becomes a DS with `template: true` in REPO-TYPE.md.

## Pack (source-of-truth) = Second Principles

**Contains:** Formalized domain knowledge, methods, Work Products, failure modes, distinctions, SoTA annotations.

**Allowed:** Add or change domain knowledge, methods, Work Products, failure modes. Update SoTA.

**Not allowed:** Didactic content (steps, lessons). Conflating method with tool. Copying without formalization. Storing general FPF/SPF concepts. Storing plans, timelines, or roles (→ Governance).

**Lint:** Run process-lint before committing.

> Pack contains ONLY domain knowledge. FPF/SPF → Base/Principles. Plans → DS/governance.

### Test: Do You Need a Pack at All?

**Role performer replacement test** (IWE criterion "Pack vs personal practice", WP-448 Phase 11 — not a Levenchuk quote; his LPF is broader, see amendment above): does the formulation hold if you replace the specific Practitioner with another performer of the same role? No — it only holds for this particular person (their body, history, taste) → not Pack; this is LPF content (personal role practice) → DS (Lifework declaration or operative record). Yes — the truth holds for the role in general → Pack candidate.

**Replace the performer, not necessarily the author.** The performer in the test is whoever ACTUALLY carries out the practice:
- Performer = the person themselves (body, hands, voice — swimming, playing an instrument) → replace with another PERSON in the same role. A personal adjustment usually does not survive this replacement → LPF/DS.
- Performer = a delegate (AI performs the work on behalf of the person — generates text/code/images in their style) → replace with another DELEGATE-performer (a different model, a future session). A formalized style must survive this replacement — otherwise it is non-portable and would need to be re-extracted from the author's head at every generation. Such a style usually passes the test → Pack.

**Which author role-mode more often produces Pack content.** Cause 1 (domain development) rarely triggers in "Professional" mode (applying a method) or "Learner" mode (acquiring it) — these produce no new transferable knowledge. It triggers in "Researcher" mode (exploring new ground) or "Educator" mode (formalizing for transfer) — see the role catalog in `PACK-personal/README.md`. Status (professional/amateur) alone does not determine this — what matters is which of the five modes the person is in at the moment of content creation.

**Three reasons to create a Pack (any one of three is sufficient — not a sum):**
1. **Domain development** — new knowledge is being formalized that remains true for the role in general, not only for the author.
2. **Personal method raised to normative status** — a proven amendment to a general method that the author wants AI to apply as a rule. Verified by the same test: does the amendment hold only for this specific person (body, context) → fails the test, remains LPF/DS, even when the author frames it as "my rule."
3. **Coordination** — multiple consumers (people/agents/artifacts) must rely on a single definition; otherwise duplicated definitions diverge (OwnerIntegrity).

**Common false signal:** "AI produces a finished Work Product (text/image/code) from this → therefore a Pack is needed." This is incorrect — the generator's output does not change the performer-replacement test. A personal style fed into a generation pipeline remains LPF content; what changes is not the Pack/DS choice, but the required rigor of the DS artifact (loose notes for self vs. a formal parameter specification for automated generation).

## DS (All Subtypes)

> DS is NOT source-of-truth. Knowledge comes from Pack.

| Subtype | Allowed | Not allowed |
|--------|-------|--------|
| `instrument` | Code, tests, code documentation | Changing source-of-truth |
| `governance` | Plans, registries, decisions | Changing subject-matter knowledge |
| `surface` | Courses, guides, learning paths | Creating knowledge (consume only) |

### Minimum-content Rule for DS/instrument

> **Agent/bot repositories = primarily code and text-as-code.**
> Architectural decisions, UX models, domain descriptions → Pack for the digital platform.
> What stays in an instrument repository: code, configs, CLAUDE.md (binding to Pack), README (how to run).

### Naming DS/instrument for AI Systems

Convention: `DS-{slug}` (examples: `DS-strategist-agent`, `DS-extractor-agent`).
Bind to Pack via `source-of-truth: {ID}` in the repository's CLAUDE.md, not via the name.

### Naming DS/surface and DS/governance

Same prefix as `instrument`: `DS-{slug}`. This rule applies to all three subtypes (instrument/governance/surface). A flat name without the prefix — a legacy decision made before the gap became apparent — is not used for new repositories of these subtypes.

### DS/governance: {{GOVERNANCE_REPO}} (Personal Database)

**Contains:** Weekly plans, notes (inbox/), Work Product contexts, extraction reports, ontology.

**STRICTLY NOT ALLOWED:** Scripts, code, prompts, launchd configs, agents. This is a DATABASE ONLY — inputs and outputs for agents. Agents live in their own DS-*-agent/ repositories or DS-synchronizer/.

### DS/governance (Team)

**Contains:** Governance (registries, plans, ADR, org structure) + operational work (seminars, proposals, drafts).

**Staging for Pack:** Operational content is an intermediate version of knowledge. At Close: KE extracts formalized knowledge → Pack; artifact → archive. This is the self-cleaning mechanism.

**Rule:** Formalized domain knowledge is NOT stored here permanently — only in transit through KE.

**0.9.Inbox:** Only materials for team discussion (agendas, proposals, questions). Do NOT store Work Product context files here — those go in {{GOVERNANCE_REPO}}/inbox/. Details: DP.KR.001 §5.3.

## PD and MC (Personal Data and Machine Context) — 4th and 5th Families

These two parallel repository families extend the Base/Pack/DS triad. They are not DS subtypes — they are independent families with their own naming conventions.

### Naming PD-*

Convention: `PD-{slug}` (examples: `PD-metrics`, `PD-persona`, `PD-dashboard`). One repository — one type of personal data. The specific subtype 2.1–2.4 lives in the repository passport (`personal_data_profile.data_type`), not in the name itself. No code — only data and minimal structure: README with a "Record Routing" section (the single source of truth for the layout of that repository).

**Allowed:** Personal data of one type for a single user, minimal record schema.
**Not allowed:** Code, other people's data, secrets/payment data (keep outside git), mixing data types within one repository.

### Naming MC-*

**MC = machine context.** The family name in Russian is "machine perimeter."

Convention: `MC-{slug}` (examples: `MC-sessions`, `MC-data`). Machine data for agents — humans do not read it day-to-day (agent dialogues, service logs, intermediate session artifacts, entry journals).

The repository kind in the registry (field `kind`) for this entire family is **`machine-artifacts`**.

**Allowed:** Agent-to-agent data, session transcripts, service logs, entry journals — raw user input with a routing trace.
**Not allowed:** Domain knowledge (→ Pack), decisions/plans (→ DS/governance), a home of facts about the user (type 2.1 → PD).

> **Entry journal ≠ home of facts.** Verbatim user input in the MC family is permitted if it is a log of the routing act. Two tests: the content is routed to its home, not kept in the journal; delete the journal — knowledge about the person does not disappear, because text is written only together with the route to the home, and refused or owner-rejected records are stored without their content. Both tests fail → this is not a journal; it belongs in PD.
> **The internal layout of an MC repository** is described only in its README, in the "Record Routing" section, and nowhere else.

## Repository-First Mode

**Never answer from general knowledge without grounding in the repository.**

1. Find at least 1–2 relevant files in the repository.
2. Assemble a Context Pack.
3. Only then form the response.

If no context is found → state "no source in the repository" and offer to create a document.


## Context Pack (Format)

```markdown
## Context Pack for [query]
### Sources:
1. `path/to/file.md` — description
### Key excerpts:
> [quote with source]
### Not used:
- Document X — not relevant because ...
```


## Frontmatter (Basic)

```yaml
type: doc    # doc, spec, process, report
status: draft # draft, active, archived
created: YYYY-MM-DD
updated: YYYY-MM-DD
```
