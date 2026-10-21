# Process Lint Protocol

## What This Is

Process lint is a **mandatory verification protocol** applied to every change in `/pack/`. It is NOT a process stage — it is a cross-cutting quality gate that runs:

| Application Point | Who Runs | When |
|-------------------|----------|------|
| **Pre-commit** | Author (human or AI) | Before `git commit` |
| **Review** | Reviewer | During PR review |
| **Agent work** | AI agent | After each pack modification |

Process lint ensures that changes comply with the SPF constitution before they enter the repository.

---

## Change-Type Matrix

Each type of change triggers specific lint checks. Identify your change type(s) and verify all required items.

### CT-1: Method Card Added/Modified

File pattern: `/pack/<domain>/03-methods/*.md`

| Check | Verification |
|-------|--------------|
| **L-M01** | Definition describes WHAT, not HOW (no numbered steps) |
| **L-M02** | Inputs section is filled |
| **L-M03** | Outputs section links to work product(s) |
| **L-M04** | At least one distinction is referenced |
| **L-M05** | Failure modes are referenced |
| **L-M06** | SoTA status is assigned with revision criterion |
| **L-M07** | ID follows convention `<DOMAIN>.METHOD.<NNN>` |
| **L-M08** | Entry added to `02C-methods-index.md` |
| **L-M09** | Map updated in `07-map/` |
| **L-M10** | No didactic language (see [Universal Bans](#universal-bans)) |
| **L-M11** | Forces section filled — ≥1 named tension, not a placeholder (**Added — new cards only**) |
| **L-M12** | Bias-Annotation section filled — ≥1 named distortion + direction, not a placeholder (**Added — new cards only**) |

> **Scope of L-M11/L-M12 (WP-448 Phase 12, decision B, 2026-07-27):** these two checks apply only to a method card newly **added** in this change — not to a pre-existing card being merely modified (typo fix, cross-reference update, etc.). The backlog of pre-2026-07-27 cards lacking Forces/Bias-Annotation is migrated separately under WP-448 Phase 12 batches; touching an old card for an unrelated edit must not force an ad-hoc migration.

### CT-2: Work Product Added/Modified

File pattern: `/pack/<domain>/04-work-products/*.md`

| Check | Verification |
|-------|--------------|
| **L-WP01** | Definition is observable/verifiable |
| **L-WP02** | Existence criteria specified ("how to verify it exists") |
| **L-WP03** | Quality criteria specified |
| **L-WP04** | Produced-by method is linked |
| **L-WP05** | Consumed-by roles/methods are linked |
| **L-WP06** | ID follows convention `<DOMAIN>.WP.<NNN>` |
| **L-WP07** | Map updated in `07-map/` |
| **L-WP08** | Product is artifact, not description (see [D.005](/pack/personal-development/01-domain-contract/01B-distinctions.md#d005-work-product-vs-description)) |

### CT-3: Failure Mode Added/Modified

File pattern: `/pack/<domain>/05-failure-modes/*.md`

| Check | Verification |
|-------|--------------|
| **L-FM01** | Error type assigned (ontological/methodological/role/deprecated-interpretation) |
| **L-FM02** | Detection test exists ("how to recognize in speech/text/behavior") |
| **L-FM03** | Distinction violated is linked |
| **L-FM04** | Correct understanding stated |
| **L-FM05** | Risk/harm documented |
| **L-FM06** | Related methods/products linked |
| **L-FM07** | ID follows convention `<DOMAIN>.FAIL.<NNN>` |
| **L-FM08** | Map updated in `07-map/` |

### CT-4: Distinction Added/Modified

File pattern: `/pack/<domain>/01-domain-contract/01B-distinctions.md` (single-file mode) **or** `/pack/<domain>/02-domain-entities/<DOMAIN>.D.<NNN>-*.md` (index+entity-card mode — packs past the `SPF.SPEC.003` scalability threshold; 01B holds only the index row, not the full entry — see `03-distinctions-work.md` § Output: Work Product)

| Check | Verification |
|-------|--------------|
| **L-D01** | Contrast is explicit ("X vs. Y") |
| **L-D02** | Distinction test exists ("how to tell X from Y") |
| **L-D03** | Consequence of confusion stated |
| **L-D04** | Related failure mode exists or noted for creation |
| **L-D05** | SoTA status assigned with revision criterion |
| **L-D06** | Does not contradict FPF distinctions |
| **L-D07** | Map updated (if new distinction) |

### CT-5: SoTA Annotation Added/Modified

File pattern: `/pack/<domain>/06-sota/*.md` or inline in other files

| Check | Verification |
|-------|--------------|
| **L-S01** | Status is one of: `current` / `deprecated-interpretation` / `hypothesis` |
| **L-S02** | Revision criterion specified ("would change if...") |
| **L-S03** | Basis for status stated |
| **L-S04** | Target claim/method is linked |
| **L-S05** | ID follows convention `<DOMAIN>.SOTA.<NNN>` (for standalone) |
| **L-S06** | Map updated if new annotation |

### CT-6: Role or Object of Attention Added/Modified

File pattern: `/pack/<domain>/02-domain-entities/02A-roles.md` or `02B-objects-of-attention.md`

| Check | Verification |
|-------|--------------|
| **L-R01** | Role is functional position, not job title or person |
| **L-R02** | Responsibilities are specified |
| **L-R03** | Typical methods linked (for roles) |
| **L-R04** | Object of attention is observable, not abstract |
| **L-R05** | Related methods linked (for objects) |
| **L-R06** | Map updated in `07-map/` |

### CT-7: Map Modified

File pattern: `/pack/<domain>/07-map/*.md`

| Check | Verification |
|-------|--------------|
| **L-MAP01** | All item counts match actual file counts |
| **L-MAP02** | All links resolve |
| **L-MAP03** | Cross-reference matrix is current |
| **L-MAP04** | Update log entry added |

### CT-8: Any Structural Change

Any addition, removal, or relationship change.

| Check | Verification |
|-------|--------------|
| **L-STR01** | Map is updated |
| **L-STR02** | Affected indexes are updated |
| **L-STR03** | Cross-references in affected files are valid |

---

## Universal Bans

These apply to ALL changes. Any violation is a hard fail.

### UB-1: No Didactic Language

**FORBIDDEN** words/phrases in pack content:

| Forbidden | Why |
|-----------|-----|
| "step", "Step 1", "steps" | Scenarios belong downstream |
| "lesson", "module" | Learning design belongs downstream |
| "in N days", "week 1" | Temporal programs belong downstream |
| "implement", "try this" | Imperatives belong downstream |
| "first/then", "next" | Sequences belong downstream |
| "exercise", "practice this" | Activities belong downstream |

**Test**: Could this sentence appear in a course syllabus? If yes, rewrite.

### UB-2: No "Domain as System"

**FORBIDDEN**:
- "Personal development is a system"
- "The system of time management"
- Any claim that a domain IS a system (without specifying which system)

**Allowed**:
- "A person using method X can be modeled as a system"
- "The practice of Y involves these system boundaries"

### UB-3: No Method/Tool/Product Confusion

Every pack file must respect:

| Entity | Is | Is NOT |
|--------|-----|--------|
| Method | Way of acting | Tool, artifact, scenario |
| Tool | Artifact that supports method | Method itself |
| Work Product | Observable artifact | Description, feeling, intention |

**Test**: Apply [D.001](/pack/personal-development/01-domain-contract/01B-distinctions.md#d001-method-vs-tool) and [D.005](/pack/personal-development/01-domain-contract/01B-distinctions.md#d005-work-product-vs-description).

### UB-4: No Information-as-Knowledge

**FORBIDDEN**:
- Copying text from sources into pack files
- Using source terminology without mapping to domain distinctions
- Treating "I read this" as "this is true"

**Required**:
- Information → Analysis (Stage 06) → Candidates → Extraction → Pack

---

## Process Compliance Mini-Checklist

Before committing ANY change to `/pack/`:

### Context
- [ ] **Bounded context exists**: `00-pack-manifest.md` has explicit scope
- [ ] **Change is within scope**: This change belongs in this pack

### Distinctions
- [ ] **Distinctions cover change**: No undefined concepts introduced
- [ ] **Distinction tests exist**: Can operationally distinguish terms used

### Content
- [ ] **SoTA assigned or N/A**: Status with revision criterion, or documented why not needed
- [ ] **No universal ban violations**: Checked UB-1 through UB-4

### Structure
- [ ] **Map updated**: Changes reflected in `07-map/`
- [ ] **IDs stable and valid**: Follow convention, not reused
- [ ] **Links resolve**: All cross-references work

### Process
- [ ] **Change-type identified**: Know which CT-* applies
- [ ] **CT-specific checks passed**: All items for that change type verified

---

## Lint Report Format

When reporting lint results (for AI agents or PR descriptions):

```
## Lint Report

**Change type(s)**: CT-1 (Method), CT-7 (Map)
**Files changed**:
- pack/personal-development/03-methods/PD.METHOD.002.md (new)
- pack/personal-development/07-map/PD.MAP.001.md (updated)

### CT-1 Checks (Method)
- [x] L-M01: Definition describes what, not how
- [x] L-M02: Inputs filled
- [x] L-M03: Outputs link to WP
- [x] L-M04: Distinction referenced
- [x] L-M05: Failure modes referenced
- [x] L-M06: SoTA assigned
- [x] L-M07: ID follows convention
- [x] L-M08: Index updated
- [x] L-M09: Map updated
- [x] L-M10: No didactic language
- [x] L-M11: Forces filled (new card)
- [x] L-M12: Bias-Annotation filled (new card)

### Universal Bans
- [x] UB-1: No didactic language
- [x] UB-2: No "domain as system"
- [x] UB-3: No method/tool/product confusion
- [x] UB-4: No information-as-knowledge

### Process Compliance
- [x] Bounded context exists
- [x] Distinctions cover change
- [x] Map updated
- [x] IDs valid

**Result**: PASS
```

---

## Hard Gates

These conditions BLOCK commit/merge. No exceptions.

| Gate | Condition | Blocked Until |
|------|-----------|---------------|
| **HG-1** | Method added without work product link | Add WP or link to existing |
| **HG-2** | Method added without distinction reference | Add distinction link |
| **HG-3** | Work product without existence criteria | Add criteria |
| **HG-4** | Failure mode without detection test | Add test |
| **HG-5** | Structural change without map update | Update map |
| **HG-6** | Didactic language detected | Rewrite |
| **HG-7** | Scenario instead of method | Rewrite as method |
| **HG-8** | SoTA without revision criterion | Add criterion |
| **HG-9** | New method card added without filled Forces or Bias-Annotation (WP-448 Phase 12, since 2026-07-27; does not apply to modifying a pre-existing card) | Add both sections before commit |

---

## Integration Points

### For Humans
- Run lint checks mentally or with checklist before committing
- Include lint report in PR description
- Reviewer verifies lint during review

### For AI Agents
- Declare change-type before modification
- Run lint checks after modification
- Include lint report in response
- Self-block if hard gate fails

### For CI/CD (Future)
- Automated lint checks on PR
- Block merge on hard gate failure
- Generate lint report automatically
