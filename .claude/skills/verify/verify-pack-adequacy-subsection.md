---
argument-hint: <path to pack or wp-package context>
description: Package-adequacy verifier across 11 coordinates of E.4.DPF.DA (ordinal
  scale 0–5, status DPFPackageAdequacyStatus). Context isolation. Checks Pack quality
  and is called from /verify with type `pack` or from pack-creator Step 4.
name: verify-pack-adequacy-subsection
---

# Package-Adequacy Verification

> **Role:** Package verifier (specialized sub-agent WP-474 Phase 4, scale and verdict vocabulary — Phase 8.1/Phase 8.3, peer session 2026-09-05-27)
> **Principle:** Context isolation — verify only Pack adequacy across 11 coordinates of specification E.4.DPF.DA; not pedagogy and not FPF boundaries separately.
> **Specification:** E.4.DPF (Framework for Domain Package Formation), section DA (Domain Adequacy) — 11 of 12 specification coordinates (D12 is out of scope for this Phase; see the finding in Step 2).

Path to the Pack or context: $ARGUMENTS

## Step 1. Load Materials

1. Read the Pack's `00-pack-manifest.md` (and WP context if specified).
2. Extract from the manifest:
   - `pack_id` (short code) / `pack_name` — Pack identifiers
   - `status` (`draft | active | deprecated`) and `name_status` (`provisional | finalized`)
   - `sota_sources` (`none | grounded`)
3. **Definition of "seed Pack" (for the floor threshold, Step 2):** A Pack is a seed if the manifest contains `status: draft`. The distinction maturity marker (`**Maturity:** seed` in 01B) is an attribute of an individual distinction, NOT of the Pack; it is not used to classify the Pack.
4. Check for the presence of evidence files (WP-474 Phases 1–3):
   - `06-sota/{slug}-sota-sheet.md` (SoTA sheet, Phase 1)
   - `.pfad-decision.md` (decision record: Domain/Name/Boundary/Kind tables + "Final Choice" section, Phases 2+5)
   - `01-domain-contract/01B-distinctions.md` (distinctions with `**Maturity:**` markers, Phase 3)
   - `ontology.md` (domain terms, SPF/pack-template)
   - `03-methods/` (method cards, D7/D8)
5. **Special note (Phase 8.1, 2026-09-05):** For a seed Pack, low values on maturity coordinates (D2, D4, D7, D8, D10, etc.) are expected — this is an honest result, not a FAIL. `E.4.DPF.DA:4.2` explicitly prohibits dropping a coordinate from assessment in advance ("assign the value that the seed earns"). Immaturity is carried by the Pack through the admission threshold and the `seedOnly` status (Steps 2 and 4), not through a predetermined coordinate verdict.

**Placeholder convention (used by flags below; fixed):** A cell or field value is a placeholder if it is empty, wrapped in `_..._` (template italic), `{{...}}`, or `<...>`, or equals (case-insensitive) one of: `...`, `TBD`, `todo`, `—`. A value is also a placeholder if: (a) the field or row is absent entirely — equivalent to an empty value; (b) for date fields (`created`, `last_updated`) — the literal template default `YYYY-MM-DD` (case-insensitive); (c) for fields with a template list of options — the literal untouched text containing the ` | ` separator (for example `draft | active | deprecated`), because this is a list of template options, not a selected value. (Peer session 2026-07-11-13, code-review finding: without items a–c, an untouched scaffold manifest mechanically passed as `addressed` on coordinate D9.)

## Step 2. Check Coordinates D1–D11 on the Ordinal Scale

> **Phase 8.1/Phase 8.3 (peer session 2026-09-05-27, consensus with Kimi).** Before this phase, coordinates were evaluated with three values — `addressed(4)/partial(2)/missing(0)` — and six coordinates had a verdict assigned in advance — `missing(seed-expected)`, meaning they were dropped from evaluation before any reading of the Pack. `E.4.DPF.DA:4.2` explicitly prohibits this: "Do not drop a coordinate because the package is 'only a seed'; assign the value that the seed earns." Pack immaturity is now carried not by a coordinate annotation but by the admission threshold (below) and the aggregate status `seedOnly` (Step 4).

### Scale (`E.4.DPF.DA:4.1`, verbatim)

| Value | Label | Meaning |
|---|---|---|
| `0` | `wrongKindOrNoBasis` | The evaluated object for the declared use does not exist, or the required basis is absent. |
| `1` | `namedOnly` | A name or topic exists, but the Pack cannot support domain or local work. |
| `2` | `partialSeed` | A useful source, pattern seed, or material exists, but Pack commitments are incomplete or fragile. |
| `3` | `locallyUsableWithVisibleLimits` | The Pack is suitable for limited exploration or local use when limits and repairs are explicitly named. |
| `4` | `wellGroundedForDeclaredDPFUse` | The Pack is coherent, grounded in sources, depends on FPF, and is navigable and updatable for its declared use. |
| `5` | `exceptionallyGroundedForDeclaredDPFUse` | The Pack is reproducible by sources, pattern set, relationship records, heterogeneous cases, publication carriers, improvement route, refresh route, and blocked re-readings. |

**This verifier does not assign `5` automatically.** Reproducibility by publication carriers and blocked re-readings requires evidence that the `pack-new`/`pack-creator` Pipeline does not produce. `5` is assigned only through explicit author analysis with attached loci. The absence of `5` in an automated run is not a Pack defect.

### Admission Threshold (Floor)

`E.4.DPF.DA:4.1` verbatim: "Default floor is `4` for public, teaching, enterprise, operational, or reliance-bearing DPF use. A fast seed or exploratory prompt output may use floor `3` **only when non-use, missing evidence, and next repair are explicit**."

The threshold is derived from the declared use, not from the status label itself:

- **floor = 4** — default for any Pack.
- **floor = 3** — only when ALL three conditions are met:
  1. The manifest carries `status: draft` (the Pack is declared a seed).
  2. In `.pfad-decision.md`, section "Final Choice", the `**Boundary:**` line is filled with a non-placeholder value AND its text names not only what is in scope but also explicitly what the Pack is not suitable for (non-use). The `pack-new` template does not create a separate non-use field — this line is the sole carrier of both meanings. The check is therefore content-based, not structural: "domain is X" alone, without a use boundary, does not qualify.
  3. In the result table (Step 3), EVERY row below the threshold has both `EvidenceLocus` and `RepairOrNoProposal` filled — that is, missing evidence and the next repair are explicitly named.

`status: draft` alone does not lower the threshold (peer session 2026-09-05-27, Kimi clarification): the reduced threshold is granted not for the "draft" label but for the completed work of explaining what the Pack is not suitable for and what to fix next. Condition 3 is satisfied by construction — the `RepairOrNoProposal` column is mandatory (Step 3). The real author commitment is the substantive `**Boundary:**` line (condition 2).

Record in the report: `Declared use: <exploratory | operational>` and `Threshold: <3 | 4>`, noting which of the three conditions was not met if the threshold remained `4` with `status: draft`.

### General Value Ladder (applies unless a coordinate below specifies otherwise)

- `0` — the mandatory evidence carrier is entirely absent
- `1` — the carrier exists, but all its content is placeholder (untouched scaffold)
- `2` — real content exists, coordinate commitments are partially met
- `3` — content is sufficient for limited local use, limits are named
- `4` — evidence is complete for the declared use

### Coordinate Template (for extension)

Each coordinate follows the same structure: code, evaluation question, evidence carrier, ladder `0–4`. Adding a new coordinate means adding one such section plus one row in the Step 3 table; the Step 4 aggregate does not need to be rewritten.

```
### D{N} — {CoordinateName}
**Question:** {what exactly is being evaluated}
**Evidence carrier:** {file or section of the Pack}
**Ladder:** 4 — … · 3 — … · 2 — … · 1 — … · 0 — …
```

> **Finding outside this phase (peer session 2026-09-05-27).** The current edition of `E.4.DPF.DA:4.2` defines **twelve** coordinates: `D12DomainProblemFamilyCoverageAdequacy` has been added (does the current edition fulfil the public-field promise through the chosen pattern sets). Sub-pass `:4.3a` has also grown — `PFM1`…`PFM12` plus `PFM1a`, not `PFM1–PFM11`. This document retains eleven coordinates: expanding scope requires a separate pilot decision (Phase 8.2 owns the form sub-pass; D12 is a candidate for a separate sub-phase). The template above is designed to be extensible for exactly this purpose.

---

### D1 — DomainScopeAndUseAdequacy

**Question:** Can the domain situation, reader, declared use, and non-use boundary be reconstructed?
**Evidence carrier:** `.pfad-decision.md`, section "Final Choice", line `**Boundary:**`, and section `## Boundary` (rejected options). The `pack-new` template does not create a separate non-use field — both sides (what is in scope / what the Pack is not suitable for) are evaluated from the content of the single `**Boundary:**` line.

**Ladder:**
- `4` — `**Boundary:**` is filled with a non-placeholder value AND the text explicitly names both the domain area and what the Pack is not suitable for
- `3` — `**Boundary:**` is filled with a non-placeholder value, but names only the domain area without explicit non-use
- `2` — `**Boundary:**` is empty, but section `## Boundary` contains ≥1 rejected option with a reason (the boundary was discussed but the decision was not recorded)
- `1` — the file exists, all content is placeholder
- `0` — `.pfad-decision.md` is absent

**Use cases remain out of scope** (peer session 2026-07-11-13): the use-case level does not materialize in any Artifact of the `pack-new`/`pack-creator` Flow. Requiring it for `4` would mean checking a non-existent Artifact.

### D2 — DidacticEntryAndAdoptionAdequacy

**Question:** Can the intended reader find the first useful entry point and obtain a first working result without knowledge of the FPF developer?
**Evidence carrier:** Pack `README.md`, Pack `CLAUDE.md`.

**Ladder:**
- `4` — `README.md` is substantively filled AND names who the Pack is for and which file to start with
- `3` — `README.md` is substantively filled, but no first-use route is given (the reader understands what the Pack is about but not where to begin)
- `2` — `README.md` is partially filled (some sections are placeholder)
- `1` — `README.md` is an untouched scaffold
- `0` — `README.md` is absent

### D3 — ScalableFormalityAndAssurancePathAdequacy

**Question:** Is a ladder defined from ordinary local use to more rigorous records and evidence?
**Evidence carrier:** `01-domain-contract/01B-distinctions.md`, `**Maturity:**` markers (Phase 3 convention: absent line = mature).

**Ladder:**
- `4` — ≥1 distinction, maturity defined for each, and at least one distinction is mature (the ladder has been traversed, not only declared)
- `3` — ≥1 distinction, maturity defined for each, all seed
- `2` — ≥1 distinction, but maturity cannot be determined for some
- `1` — the file exists, no distinctions (scaffold only)
- `0` — the file is absent

### D4 — CoreDependencyAndDomainBoundaryAdequacy

**Question:** Does the Pack rely on core concepts without redefining them locally?
**Evidence carrier:** `ontology.md` §Domain Glossary, Parent Concept (SPF) column.

**Ladder:**
- `4` — all glossary rows have Parent Concept filled, and no local term redefines a same-named concept from the SPF base ontology
- `3` — Parent Concept is filled for some rows
- `2` — the glossary is filled, Parent Concept is not filled anywhere
- `1` — `ontology.md` is an untouched scaffold
- `0` — `ontology.md` is absent

### D5 — PackageFormLayeringAndRelationAdequacy

**Question:** Are the Pack form, its layers, and relationship records separated?
**Evidence carrier:** 8 root structural elements created by `pack-new` Step 4 (NOT the `SPF/pack-template/` tree): `README.md`, `REPO-TYPE.md`, `CLAUDE.md`, `00-pack-manifest.md`, `ontology.md`, `01-domain-contract/`, `06-sota/` (or `sota_sources: none` in the manifest instead of the directory), `07-map/`; plus the content of `07-map/`.

**Ladder:**
- `4` — all 8 elements are present AND `07-map/` contains a non-placeholder relationship map
- `3` — all 8 elements are present, the relationship map is empty or template-only (form is maintained, relationships are not recorded)
- `2` — exactly one element is absent
- `1` — more than one element is absent
- `0` — no Pack structure exists

### D6 — DomainLexiconAndKindSettlementAdequacy

**Question:** Are the domain lexicon and the Kind of the primary concept settled?
**Evidence carrier:** `ontology.md` + `01B-distinctions.md` + `.pfad-decision.md` (peer session 2026-07-10-18: PFAD is a decision record; duplicating terms from ontology in it is prohibited).

**Three binary flags (placeholder convention — Step 1):**
- **O** (lexicon, part 1) = `ontology.md` §Domain Glossary contains ≥1 row in which ALL THREE cells — Term (RU/EN), Definition, Parent Concept (SPF) — are non-placeholder
- **D** (lexicon, part 2) = `01B-distinctions.md` contains ≥1 distinction (heading of the form `### <code>.D.NNN` or `### {{PACK_ID}}.D.NNN`)
- **S** (settlement) = the `**Kind:**` line in the "Final Choice" section of `.pfad-decision.md` is filled with a non-placeholder value. The `## Kind` table (rejected alternatives) is NOT evidence of settlement — it may be filled without a decision having been made.

**Ladder:**
- `4` — O ∧ D ∧ S
- `3` — exactly two flags of three
- `2` — exactly one flag
- `1` — no flags, but `ontology.md` and `01B-distinctions.md` exist
- `0` — both files are absent

**Rejected terms (not Kind) remain out of scope**, deliberately: there is no place for such a registry in the current template (`ontology.md` has no rejected-synonyms column); adding one requires a `SPF/pack-template` change via §8.2 procedure, which is a separate decision.

### D7 — PracticeUtilityAndProblemResolutionAdequacy

**Question:** Does the Pack change real domain action — diagnosis, design, explanation, repair?
**Evidence carrier:** `03-methods/` — method cards (template `_method-card-template.md`).

**Ladder:**
- `4` — ≥1 method card with non-placeholder Definition, Purpose, and Failure Modes filled (problem, resolution path, and known failure mode are all named)
- `3` — ≥1 card, some mandatory sections are placeholder
- `2` — `03-methods/` exists but contains only `_method-card-template.md`
- `1` — `03-methods/` exists and is empty
- `0` — `03-methods/` is absent

### D8 — HeterogeneousCaseAndTransferAdequacy

**Question:** Has the Pack been tested against sufficiently different domain cases and reader roles?
**Evidence carrier:** Worked-through cases wherever they reside — example sections in method cards, a dedicated cases directory, `01-domain-contract/`.

**Ladder:**
- `4` — ≥2 different worked-through cases, and it is visible where the same set of concepts works and where it fails
- `3` — exactly one worked-through case
- `2` — cases are mentioned but not worked through (enumeration without analysis)
- `1` — no case mentions, but substantive Pack content exists
- `0` — no content to evaluate

### D9 — EditionStateAndCurrentnessAdequacy

**Question:** Can the reader determine which exact edition they are using and how current it is?
**Evidence carrier:** `00-pack-manifest.md`.

**Three binary flags (placeholder convention — Step 1):**
- **O** (edition) = `version` is non-placeholder
- **E** (currentness) = `last_updated` is non-placeholder
- **S** (state) = `status` is non-placeholder

**Ladder:**
- `4` — O ∧ E ∧ S
- `3` — exactly two flags of three
- `2` — exactly one flag
- `1` — the manifest exists, all three are placeholder
- `0` — no manifest

### D10 — ImprovementAndRefreshAdequacy

**Question:** Can the Pack be improved and refreshed without major rediscovery?
**Evidence carrier:** `00-pack-manifest.md`, `README.md` — source-return condition and staleness route.

**Ladder:**
- `4` — both the revision condition (what observation triggers a return to sources) and the staleness route (what happens to the Pack when it becomes outdated) are recorded
- `3` — the revision condition is named, no staleness route
- `2` — updating is mentioned without a verifiable condition
- `1` — no condition and no route, but the carriers (manifest, README) are filled
- `0` — no carriers

### D11 — DomainSoTAAlignmentAdequacy

**Question:** Does the Pack content discipline the current state of domain practice, or are sources attached as a bibliography?
**Evidence carrier:** `06-sota/{slug}-sota-sheet.md`, manifest `sota_sources`.

**Ladder:**
- `4` — the SoTA sheet contains ≥1 source with non-placeholder Claims and Evidence, AND the Pack content shows influence from that source (a distinction or method card references it)
- `3` — ≥1 source with filled Claims and Evidence, no visible influence on content (the source is attached but changed nothing)
- `2` — the SoTA sheet exists, Claims or Evidence are placeholder
- `1` — no SoTA sheet, AND the manifest carries `sota_sources: none` (the absence of sources is honestly recorded)
- `0` — no SoTA sheet, AND the manifest carries `sota_sources: grounded` (the manifest contradicts the fact — the basis is absent)

**The `4` threshold here currently requires one source, not three.** `G.2` sets `FamilyCoverageFloorK := 3`; aligning with that Requirement is the subject of WP-474 Phase 8.5, not this phase.

## Step 3. Build the Result Row

The row format is defined by `E.4.DPF.DA:4.3` — five columns, not four:

| Coordinate | Value | ShortRationale | EvidenceLocus | RepairOrNoProposal |
|---|---|---|---|---|
| `<D1..D11>` | `<0..5>` | Why this value: why lower would understate the evidence, why higher would overstate it | Specific location: file, section, manifest line, or absent locus | Repair OR explicit "no proposal" with a list of checked locations |

**`RepairOrNoProposal` is mandatory. An empty cell makes the row invalid** — a result with such a row is not returned. Exactly two forms are acceptable: a specific repair, or an explicit "no proposal" with a list of checked locations. Prose such as "see recommendations below" does not count as a repair.

**`EvidenceLocus` is mandatory for value `0` as well** — it names the absent carrier ("``03-methods/`` does not exist"), not a dash. `E.4.DPF.DA:4.3` explicitly discards a table without evidence loci as "only assessment material."

**Row order — sorting, not a fixed list** (peer session 2026-09-05-27, replacing the "critical coordinates" rule): ascending by value, with ties broken by ascending coordinate code (D1 < D2 < … < D11). The sort is stable and deterministic: what to fix first appears at the top, derived from the data rather than from a once-written priority list. Before this phase, priority was carried by a hardcoded rule — "D1, D7, D11 are critical" — which was wrong for educational Pack use, where D2 (reader entry) matters more than D11.

## Step 4. Return Pack Status

The aggregate is `DPFPackageAdequacyStatus` (`E.4.DPF.DA:4.5`), six values replacing the earlier `PASS/CONDITIONAL/FAIL`.

The specification separately limits the force of this status: it is a **local claim about admissibility for the declared use** — not an admission decision, publication state, warranty result, or work permission. The consuming process uses it only through its own rule.

### Three statuses are assigned automatically (first match wins)

| Status | Condition |
|---|---|
| `admissibleForDeclaredDPFUse` | All coordinates ≥ threshold, non-use boundary and rediscovery condition are named |
| `seedOnly` | Some coordinates are below threshold, AND the threshold has actually dropped to 3 (all three floor=3 conditions from Step 2 are met — not only `status: draft`) |
| `repairBeforeDPFUse` | Some coordinates are below threshold, AND the threshold remained 4 — either the manifest does not carry `status: draft`, or it does but at least one floor=3 condition is not met (the author declared a seed but did not name the non-use or did not provide `RepairOrNoProposal` for every low row) |

`seedOnly` is not a failure. `E.4.DPF.DA:5` verbatim: "That status is not failure or admission; it is an honest package-use result and next repair route." A seed Pack honestly earns low values on maturity coordinates and the `seedOnly` status. This is the expected result for a fresh Pack, not a sign of failure.

### Three statuses are escalation hatches — not assigned automatically

The verifier does not assign these itself, but checks the condition and, if met, adds a warning line to the report: "Result inclines toward `<status>` — author decision required." The Pack author makes the decision.

| Status | Escalation Condition | How It Is Checked |
|---|---|---|
| `holdForPFADDecision` | The repair for a below-threshold coordinate touches Pack architecture, not file content | The `RepairOrNoProposal` cell for D4 or D5 proposes a repair at the level of "restructure the Pack," "change the pattern set," or "change the publication unit" |
| `holdForCoreAmendmentDecision` | A Pack claim may belong to the core and should not be hidden inside a domain | The repair requires changing FPF or SPF itself, not the Pack |
| `refreshNeeded` | The Pack was adequate before, but the source, core edition, or dependency pin has since changed | Requires a **previous verification result** stored in the Pack. No such storage exists in the `pack-new`/`pack-creator` Pipeline — this status is structurally unreachable in an automated run and is assigned only by the author manually. This is a Constraint, not a verification defect |

### Report Format

```
## Package-Adequacy Result

**Pack:** <pack_id_code> / <slug>
**Declared use:** <exploratory | operational>
**Threshold (floor):** <3 | 4>   <if 4 with status: draft — which of the three conditions was not met>
**Status:** <admissibleForDeclaredDPFUse | seedOnly | repairBeforeDPFUse>

### Result Rows (ascending by value)

| Coordinate | Value | ShortRationale | EvidenceLocus | RepairOrNoProposal |
|---|---|---|---|---|
| (fill and sort) | | | | |

### Escalations

<lines "Result inclines toward <status> — author decision required", or "none">

### Below Threshold

<list of coordinates with value < floor, in sort order>
```

## Step 5. Context Isolation

**NOT verified:**
- Pedagogical quality (that is verify-pedagogy-subsection)
- FPF concept boundaries (that is verify-fpf-subsection)
- Code or tool quality within the Pack (that is domain-specific review)

**VERIFIED ONLY:**
- Presence and quality of Phase 1–3 Artifacts (SoTA sheet, decision record, maturity marker)
- Compliance with 11 of 12 coordinates of specification E.4.DPF.DA (D12 is a separate sub-phase; see the finding in Step 2)
- Honesty of assessment: a seed Pack earns honest low values and the `seedOnly` status, not a predetermined coordinate verdict
