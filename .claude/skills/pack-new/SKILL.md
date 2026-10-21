---
argument-hint: '[knowledge area or domain]'
browser_safe: false
description: 'Create a new Pack — guided flow through SPF: choose domain, name Pack,
  scaffold structure, fill roadmap.'
name: pack-new
realized_by:
- DP.SC.048
---

# Pack New — Creating a New Pack

Creating a Pack for the domain: $ARGUMENTS

## What this Skill does

- Checks for the Base repositories (FPF, SPF) and clones them if absent
- Guides through SPF §01 (domain selection)
- Checks domain/name recognizability against one external source (SoTA-Sheet-lite)
- Proposes a provisional Pack name per SPF criteria, records rejected candidates (PFAD-lite), and finalizes the name after the first Distinctions
- Refines the Bounded Context (SPF §02)
- Creates the directory structure and starter files from SPF/pack-template
- Shows the content Roadmap with time estimates

## What this Skill does NOT do

- Does not fill Pack content beyond the starter SoTA Sheet from Step 1.5 (see Step 4) — everything else requires `/ke` and manual work per SPF §03–11
- Proposes creating a GitHub repository by command only — does not create it automatically

---

## Step 0. Check Base repositories (FPF + SPF)

Check that `SPF/` and `FPF/` exist in the IWE working directory.

If absent — notify the user and propose the commands:

```bash
(cd ${IWE_WORKSPACE:-$HOME/IWE}
cp -R "${IWE_TEMPLATE:-$HOME/IWE/IWE}/seed/SPF" SPF  # if SPF/ is missing
git -C SPF init -q
gh repo clone ailev/FPF FPF -- --depth=1             # if FPF/ is missing
)
```

If the repositories exist — record the path to `SPF/pack-template/` for Step 4.

Also record the Work Product in whose context `/pack-new` was launched (from the active Session — the WP Gate must already be passed before calling this Skill per Pack Creation Gate). If the Pack is created outside a Work Product context — record `wp: —`. This value is needed for the `wp:` field in the `.pfad-decision.md` frontmatter in Step 4.

---

## Step 1. Domain ≠ Topic (SPF §01)

> Ask the user **no more than 3 questions** (all at once, in a single message):

1. **Who practices this domain?** (specialty, profession, specific Role)
2. **What do they produce?** (Artifacts, Work Products — specific documents, systems, decisions)
3. **How do they typically fail?** (3–5 failure modes — what goes wrong in this Practice)

**If the answer is "I am interested in topic X"**, explain the Distinction:
> Topic = area of interest (no own methods or Artifacts).
> Domain = Practice with methods, Work Products, and failure modes.
>
> Test: "Are there people who DO this professionally? What do they produce?"
>
> Examples: "machine learning" — topic. "ML systems development" — domain (has: ML engineers, models, quality metrics, failure modes). "Systems Thinking" — topic. "Systems analysis" — domain.

If the user is unsure — help find practitioners and Artifacts through follow-up questions (up to 2 additional questions).

---

## Step 1.5. Domain sources (SoTA-Sheet-lite)

> Source of principle: FPF `E.4.DPF` (source pack — step 2 of 11, before drafting patterns) + `G.2` lightweight variant ("1-page SoTA Sheet", informative). The full `G.2` (CorpusLedger/ClaimSheets/BridgeMatrix) is excessive for a personal Pack.

Before choosing a name (Step 2), quickly verify: how practitioners themselves name and describe this Practice — not from the agent's memory, but from one external source.

Ask the user (or find independently if the user is not an expert):
1. **One authoritative source for this Practice** — a book, method, school, or standard (not a blog)
2. **2–4 claims from that source** worth carrying into the Pack
3. **What supports them** — a quote, page number, or section

This is not a full research pass — the goal is narrow: verify that the domain and the future name (Step 2) are grounded in real Practice. Optional, if time permits: applicability boundaries of the source (validity region), what is explicitly rejected, when the source will become outdated (freshness).

If the user says "I do not have a source at hand" — do not block, continue. Record this explicitly in Step 4 (`sota_sources: none` in the Manifest), do not stay silent.

**Sync point:** after Step 3 (Bounded Context) — check whether the domain boundary has shifted enough that the source and claims need to be supplemented.

---

## Step 2. Provisional Pack name (SPF §01 §4)

Pack name = **a noun recognizable to practitioners** of the domain.

**Criteria (all required):**
- Specific: excludes neighboring domains (not "management", but "product management")
- Broad: covers the core methods, not just one tool
- Recognizable: a practitioner immediately understands what it refers to
- Slug: Latin characters, kebab-case, ≤30 characters

**Propose 2–3 options** with explanations, then let the user choose.

Format: `PACK-{pack_id_slug}` (examples: `PACK-product-management`, `PACK-system-analysis`, `PACK-digital-marketing`).

Reference examples from IWE: `PACK-digital-platform`, `PACK-education`, `PACK-personal`, `PACK-verification`.

**Anti-examples:**
- `PACK-everything` — too broad
- `PACK-jira` — a tool, not a domain
- `PACK-notes` — no Practice or Artifacts

**Short code (`pack_id_code`, WP-474 phase 3 fix).** Separate from `pack_id_slug` (kebab-case, used as the directory name) — a short mnemonic code of 2–4 uppercase Latin letters used as a prefix in entity codes (`{{PACK_ID}}.D.NNN` → e.g. `DP.D.NNN`). These are two different identifiers — do not confuse them: existing Packs use the short code in this role (`PACK-digital-platform` → code `DP`), not the full slug.

Code proposal algorithm: take the significant words of the slug (excluding prepositions/conjunctions) → if the domain is a single word, take the first 2–4 letters (`education` → `EDU`); if it consists of multiple words, take the first letter of each significant word in uppercase (`product-management` → `PM`; `digital-platform` → `DP`). Propose the resulting code plus one alternative (e.g., first letters of the first word plus the first letter of the second word, if the initials yield fewer than 2 significant words) — let the pilot choose or adjust. If the proposed code is already taken (see anti-example below) — do not blindly ask the pilot again; instead, immediately propose the next option produced by the algorithm (e.g., add a third letter), and only ask the pilot directly if all options are exhausted. The code is also provisional — it is finalized together with the slug (see "Name finalization" below).

**Code anti-examples:**
- Collision with an existing Pack code in IWE — check BEFORE recording: `find ${IWE_WORKSPACE:-$HOME/IWE} -maxdepth 4 -path "*/PACK-*/00-pack-manifest.md" -o -path "*/PACK-*/pack/*/00-pack-manifest.md" | xargs grep -l "^pack_id: <code>$" 2>/dev/null` (Packs can be flat — `PACK-X/00-pack-manifest.md` — or nested — `PACK-X/pack/X/00-pack-manifest.md`; one `find` branch does not cover both variants)
- Code longer than 4 characters — loses compactness in compound IDs (`DIGPLAT.D.001` instead of `DP.D.001`)

**Provisionality (PFAD-lite, source — FPF `E.4.PFAD`/`F.18`).** The name chosen here (slug + code) is **not final**. The directory `PACK-{pack_id_slug}/` is created immediately under this slug (Step 4), but:
- `00-pack-manifest.md` gets `name_status: provisional`;
- rejected domain/name/boundary candidates are recorded in `.pfad-decision.md` (Step 4) with the reason for rejection — a decision record analogous to an ADR, living inside the Pack and traveling with it on moves or renames;
- Distinctions added to `01B-distinctions.md` before finalization (roadmap phase 1, Step 5) receive the heading `### {{PACK_ID}}.D.NNN: <Name>` — `{{PACK_ID}}` is a placeholder, replaced at finalization with the short code (`pack_id_code`), NOT with `pack_id_slug`;
- name finalization is a separate step after content accumulates (see below), not an automatic transition.

While discussion is ongoing (this step and, if needed, Step 3) — maintain a draft list of rejected domain/name/boundary candidates with reasons for rejection (in the working dialog context). This draft is transferred to the tables in `.pfad-decision.md` in Step 4 — if the Session is interrupted between Step 2 and Step 4, the rejected candidates must not be lost.

### Name finalization

Triggered by one of two conditions (record which one in `.pfad-decision.md` field `finalization_trigger`):
- **`pilot-requested`** — the user explicitly requests the name to be fixed, at any time.
- **`agent-proposed-after-N-distinctions`** — the agent proposes finalization after **at least 3 Distinctions** appear in `01B-distinctions.md` (not earlier — one or two are insufficient to judge whether the name fits the content).

The two independent identifiers are finalized together but renamed differently: `pack_id_slug` (kebab-case) — rename the DIRECTORY via `git mv`; `pack_id_code` (short mnemonic code) — replace the PLACEHOLDER `{{PACK_ID}}` in Distinction content. Do not confuse: `{new_slug}` in the steps below is NOT the same as what replaces `{{PACK_ID}}`.

Paths in `provisional_distinction_files` are stored **relative to the Pack root** (e.g. `01-domain-contract/01B-distinctions.md`, without the `PACK-{slug}/` prefix) — always resolve them to a real file path using the CURRENT directory name of the Pack at the time of the operation. Therefore, after `git mv` (step 2 below) the paths from the list are already correct without separate modification — look them up as `PACK-{new_slug}/<path-from-list>`.

Procedure:
1. The user confirms the current `pack_candidate`/`pack_id_slug`/`pack_id_code` or provides new ones (independently — the slug may stay the same while the code changes, and vice versa).
2. If `pack_id_slug` changed: verify that `PACK-{new_slug}/` does not already exist (`git mv` into an existing directory moves files INSIDE it instead of renaming) — on collision, stop and ask the pilot for a different slug. Otherwise run `git mv PACK-{old_slug} PACK-{new_slug}`.
3. If `pack_id_code` changed or is being set for the first time: check for collision with another Pack's code in IWE (see code anti-example in Step 2). On collision — stop and ask for a different code.
4. For each path in `provisional_distinction_files`, resolving it as `PACK-{new_slug}/<path>` (see above): count occurrences of `{{PACK_ID}}` BEFORE replacement (`grep -c '{{PACK_ID}}' <file>` = N), then replace all occurrences of `{{PACK_ID}}` → `{new_code}` (the short code, NOT the slug) in Distinction headings.
5. Verify the replacement: `grep -c '{{PACK_ID}}' <file>` after replacement must be `0`, and the number of `### {new_code}.D.NNN` headings in the file must equal N. Any discrepancy (remaining `{{PACK_ID}}` or heading count ≠ N) — do not commit; show the diff to the user.
6. Update all locations where names are materialized: `pack_id` (= `{new_code}`) and `pack_name` in `00-pack-manifest.md`; if `pack_id_slug` changed — the `# PACK-{new_slug}` heading in the Pack's `CLAUDE.md`, the `pack_id_slug`/`pack_candidate`/`pack_id_code` fields in `.pfad-decision.md`, rename `06-sota/{old_slug}-sota-sheet.md` → `06-sota/{new_slug}-sota-sheet.md` (if the file exists), rename `.iwe-runtime/state/spf/{old_slug}.yaml` → `.iwe-runtime/state/spf/{new_slug}.yaml` (if it exists — `/pack-creator` has already been run, WP-474 phase 3; otherwise it will not find the progress on the next run and will silently restart from Step 0). If a GitHub repository was created under the old slug in Step 4 — notify the pilot that it must be renamed separately (`gh repo rename`); this Skill does not do that automatically.
7. Clear `provisional_distinction_files`, set `name_status: finalized` in the Manifest **and** `status: finalized` in the `.pfad-decision.md` frontmatter, fill in the "Final choice" section of `.pfad-decision.md` (`decided_by`, `proposed_by`; if the `**Kind:**` line was left blank from Step 3 — ask about Kind now and fill it in). Lexicon backstop: if `ontology.md` §2 Domain Glossary remains placeholder-only (terms from Step 3 were not transferred) — fill it in now.
8. Commit the changed files (by explicit path list, not `git add -A`) with a message of the form `feat: finalize Pack name → PACK-{new_slug} (code {new_code})`.

---

## Step 3. Bounded Context (SPF §02)

Fill in three fields together with the user:

| Field | Content |
|-------|---------|
| What is included | 3–5 key methods and Practices of the domain |
| What is excluded | Neighboring domains (boundary) |
| Key terms | 5–7 domain-specific terms (Ubiquitous Language) |

Result → recorded in `01-domain-contract/01A-bounded-context.md`

**Term materialization (WP-474 phase 5, flag O of coordinate D6).** Key terms from the table above are recorded NOT only in 01A: each term becomes a row in `ontology.md` §2 Domain Glossary (Term RU/EN, Definition in 1–2 sentences, Parent Concept from the SPF base ontology — see `SPF/pack-template/ontology.md §1`). Without this, `/verify pack` will correctly report the lexicon as unfilled — 01A verify does not read it.

**Kind of the main concept (WP-474 phase 5, flag S of coordinate D6).** At this point, ask: "What is the base Kind of the main concept of the domain — `U.Method` (way of acting), `U.System` (carrier), `U.Episteme` (Knowledge), or another from the SPF base ontology?" Discussed and rejected candidates go into the `## Kind` table in `.pfad-decision.md` (Step 4); the accepted decision goes into the `**Kind:**` line in "Final choice" immediately — it does not wait for name finalization.

Source sync point (Step 1.5): if the domain boundary has changed noticeably here — go back and supplement the SoTA Sheet before Step 4.

---

## Step 4. Scaffold the structure

`{slug}` throughout = the `{pack_id_slug}` chosen in Step 2.

Create `${IWE_WORKSPACE:-$HOME/IWE}/PACK-{slug}/` with the following structure:

```
PACK-{slug}/
├── README.md                      ← name + one sentence about the domain
├── REPO-TYPE.md                   ← type: Pack, upstream: FPF + SPF
├── CLAUDE.md                      ← agent instructions for this Pack
├── .pfad-decision.md              ← PFAD-lite: rejected domain/name/boundary candidates (Step 2)
├── 00-pack-manifest.md            ← metadata + entity index
├── ontology.md                    ← domain terms (Ubiquitous Language)
├── 01-domain-contract/
│   ├── 01A-bounded-context.md     ← from Step 3
│   └── 01B-distinctions.md        ← key Distinctions (starter template)
├── 02-domain-entities/            ← entities: roles, methods, Work Products
├── 03-methods/                    ← Practice methods
├── 04-work-products/              ← Work Products
├── 05-failure-modes/              ← typical errors
├── 06-sota/
│   └── {slug}-sota-sheet.md       ← from Step 1.5 (if a source was provided)
└── 07-map/                        ← domain map
```

**Fill in the starter files:**

`README.md` — one line describing the domain.

`REPO-TYPE.md`:
```markdown
# Repository type

**Type**: `Pack`
**Source-of-truth**: yes

## Scope
{domain name and what it covers}

## Upstream dependencies
- [Bundled SPF](https://github.com/iwesys/IWE/tree/main/seed/SPF) — Second Principles Framework
- [ailev/FPF](https://github.com/ailev/FPF) — First Principles Framework

## Non-goals
- Does NOT contain code and Configurations (→ DS)
- Does NOT contain plans and registries (→ DS/governance)
```

`CLAUDE.md` — minimal, contains:
```markdown
# PACK-{slug}

Source-of-truth for the domain: {name}.
Structure: SPF/pack-template. Upstream: FPF, SPF.

When working with this Pack: read 00-pack-manifest.md for navigation.

While `name_status: provisional` in the Manifest: each new Distinction in `01-domain-contract/01B-distinctions.md` receives the heading `### {{PACK_ID}}.D.NNN: <Name>` (the placeholder `{{PACK_ID}}`, not the real Pack code), and the path `01-domain-contract/01B-distinctions.md` is added to `provisional_distinction_files` in `.pfad-decision.md` (if not already present — do not duplicate). If `01B-distinctions.md` contains 3 or more Distinctions — propose name finalization to the user (see `pack-new/SKILL.md` Step 2 "Name finalization" in IWE).
```

`01-domain-contract/01A-bounded-context.md` — from Step 3.

`01-domain-contract/01B-distinctions.md` — template (heading per Distinction, aligned with the actual format used in active Packs, e.g. `PACK-digital-platform` — the table from the previous version of this template matched neither the provisional-placeholder heading format used below nor the actual format of active Packs; corrected in WP-474 phase 3. `SPF/pack-template/01-domain-contract/01B-distinctions.md` uses a different notation — `### [D.001] Name` without a Pack code prefix — the upstream template diverges from Practice; noted separately, not resolved by this fix):
```markdown
# Key Distinctions of {domain}

> Source: FPF A.7 (Strict Distinction)
> Criterion: if two terms are frequently confused — this is a Distinction.

### {{PACK_ID}}.D.001: <Name>

**Definition A:** ...
**Definition B:** ...
**Test:** ...
```

While `name_status: provisional` (see Step 2) — each added Distinction uses the heading `### {{PACK_ID}}.D.NNN: <Name>` (not the real Pack code), and the path `01-domain-contract/01B-distinctions.md` is added to `provisional_distinction_files` in `.pfad-decision.md` (if the path is not already there — do not duplicate on repeated Distinctions in the same file). After name finalization (Step 2 "Finalization") `{{PACK_ID}}` is replaced with the short code (`pack_id_code`) — NOT the slug — in one verifiable step.

**Seed/mature (WP-474 phase 3, peer session 2026-07-09-14-seed-mature-spf-state).** Every new Distinction is a draft (seed) by default. Mark it with a line immediately below the heading, not with a suffix in the heading itself (a suffix in the heading breaks the stability of markdown anchors during the seed→mature transition — links from other files to `#packid-d-001-name-seed` will break when the label is removed). The field is named `**Maturity:**`, not `**Status:**` — in existing Pack cards `**Status:**` is already used for SoTA status (`current`/`deprecated`/`hypothesis`, a different axis), and reusing the field name would create confusion for any future tool that searches for `Status` across a Pack:

```markdown
### {{PACK_ID}}.D.001: <Name>
**Maturity:** seed

**Definition A:** ...
```

mature = absence of the `**Maturity:**` line (symmetric with the rest of the format — the "normal" state is not marked explicitly).

**seed → mature transition** — not automatic; triggered by the author's request or by an agent proposal when a Distinction appears stable. "mature-lite" checklist (lightweight version of FPF `E.8` — the 13 canonical pattern sections are excessive for a short Pack Distinction, following the same lightweight principle as in phases 1/2):

1. **Problem/motivation** — why this Distinction is needed, what gets confused without it
2. **Forces** — what alternative or tension it resolves (without this point, maturity is a declaration: it is unclear whether the author worked through the conflict or the Distinction does not exist in practice)
3. **Example** — at least one real worked example, not an abstraction
4. **Common mistake** — at least one real misuse case, not a placeholder
5. **Consequences** — what breaks in Practice if the Distinction is ignored

All 5 points must be filled substantively (not with placeholders) before removing the `**Maturity:** seed` line. If a point does not apply — state explicitly why; do not leave it blank.

`.pfad-decision.md` — PFAD-lite decision record (SPF `E.4.PFAD`, lightweight version — 3 tables instead of the full format), created together with the scaffold in Step 4, populated from the results of Step 2 (and Step 3, if the boundary was discussed):
```markdown
---
wp: "{Work Product in whose context the Pack is created}"
pack_candidate: "{name proposed in Step 2}"
pack_id_slug: "{slug}"
pack_id_code: "{short code, 2-4 letters}"
created: "{YYYY-MM-DD}"
status: provisional
finalization_trigger: ""
provisional_distinction_files: []
---

# PFAD-lite: {pack_candidate}

## Domain

| Candidate | Why rejected |
|-----------|-------------|

## Name

| Candidate | Why rejected |
|-----------|-------------|

## Boundary

| Candidate | Why rejected |
|-----------|-------------|

## Kind

| Kind candidate | Why rejected |
|----------------|-------------|

## Final choice

**Domain:** ...
**Name (slug):** ... (was provisional: "...")
**Code:** ... (was provisional: "...")
**Boundary:** ...
**Kind:** ...
**decided_by:** pilot
**proposed_by:** agent | pilot
```
Fill in the tables with candidates that were actually discussed in Step 2 (and Step 3) — do not invent rejected candidates after the fact; if the user immediately agreed with the first proposal, the tables remain empty. The "Final choice" section is filled in at finalization (Step 2 "Name finalization"), not in Step 4.

**The `## Kind` table and the `**Kind:**` line (WP-474 phase 5, D6-settlement).** Kind is the base type of the domain's main concept per the SPF base ontology (`U.Method` / `U.System` / `U.Episteme` / ... — see `SPF/pack-template/ontology.md §1`). The Kind decision is made in Step 3 (the question is asked there). The `## Kind` table is a registry of rejected Kind alternatives (it may remain empty per the general rule of not inventing candidates after the fact); the table itself is NOT evidence of a decision. The evidence of settlement is only the filled `**Kind:**` line in "Final choice" (checked by `/verify pack`, coordinate D6). **Exception to the rule in the paragraph above:** unlike Domain/Name/Boundary, the `**Kind:**` line is filled immediately upon the decision (Step 3) and does not wait for name finalization.

`06-sota/{slug}-sota-sheet.md` — from Step 1.5:
```markdown
# SoTA Sheet: {source}

**Claims:** {2-4 claims carried into the Pack}
distinction: {X} vs {Y}
**Evidence:** {quote/page/section}
**Validity region:** {where it applies, where it does not — optional}
**Rejected:** {what is explicitly rejected and why — optional}
**Freshness:** {when to revisit — optional}
```

`distinction: X vs Y` lines (0..N, optional) — Distinction candidates that the source draws explicitly. The format is strict (the line begins with `distinction:`, separator ` vs `), position is free — the pack-creator parser looks for such lines anywhere in the sota-sheet file. The `/pack-creator` assembly mode uses them to deterministically build a candidate checklist (WP-474 phase 6). They are not required in Step 1.5 — they can be added later, including via LLM-fallback pack-creator with author confirmation.
If no source was provided (Step 1.5, user skipped) — do not create the file; record this only in `00-pack-manifest.md` (`sota_sources: none`).

`ontology.md` — take the template from `SPF/pack-template/ontology.md`, then IMMEDIATELY fill in §2 Domain Glossary with the terms established in Step 3 ("Term materialization"): row by row — Term (RU/EN) / Definition / Parent Concept (SPF) from the discussion. Do not leave template placeholders `_Term 1_` / `_TBD_` — `/verify pack` (flag O of coordinate D6) treats placeholder lines as an unfilled lexicon.

`00-pack-manifest.md` — take the template from `SPF/pack-template/00-pack-manifest.md`, fill in `pack_id` = the `pack_id_code` from Step 2 (the short mnemonic code, e.g. `DP`, NOT `pack_id_slug` and NOT `PACK-{slug}` — the discrepancy was found and corrected in WP-474 phase 3: real Packs use the short code in this field), `pack_name` = `pack_candidate`. In the `## Metadata` block, immediately after `pack_name`, add two new lines (they are not yet in the upstream template — do not confuse this with filling an existing placeholder; adding them to the template, if needed for all Packs, is a separate SPF decision, not pack-new's responsibility):
- `sota_sources: none | grounded` from the result of Step 1.5 — `none` if no source was provided, `grounded` if a source and claims were gathered.
- `name_status: provisional | finalized` from the result of Step 2 — always `provisional` at scaffold time (Step 4); transitions to `finalized` only at name finalization (Step 2 "Finalization").

Then initialize the repository and install the CI guard:
```bash
(cd ${IWE_WORKSPACE:-$HOME/IWE}/PACK-{slug}
git init

# Install CI guard (ID collision detector)
IWE_TEMPLATE="${IWE_TEMPLATE:-$HOME/IWE/IWE}"
if [ -d "$IWE_TEMPLATE/pack-templates/.github" ]; then
  cp -r "$IWE_TEMPLATE/pack-templates/.github" .
fi

git add -A
git commit -m "feat: initial scaffold PACK-{slug} (SPF/pack-template) + CI guard R4"
)
```

The CI guard is a GitHub Action that checks ID uniqueness (DP.M.NNN, AR.NNN, etc.) on every push/PR and blocks merging on collision.

Optionally — create on GitHub:
```bash
gh repo create {GITHUB_USER}/PACK-{slug} --private --source="${IWE_WORKSPACE:-$HOME/IWE}/PACK-{slug}" --push
```

---

## Step 5. Content Roadmap

Show the user the plan — what to do next:

```
═══════════════════════════════════════════════════════
  PACK-{slug} — content roadmap
═══════════════════════════════════════════════════════

Current state: scaffold complete. Pack is empty — value appears after phase 1.

[ ] Phase 1. DISTINCTIONS (SPF §03) ← start here
        File: 01-domain-contract/01B-distinctions.md
        Goal: 7-10 key domain Distinctions
        Time: ~1-2h
        How: list what is frequently confused; check each against FPF A.7
        Tool: /ke — capture Distinctions while working with the domain

[ ] Phase 2. ENTITIES (SPF §04)
        File: 02-domain-entities/
        Goal: list Roles, Work Products, methods — without detailed descriptions
        Time: ~1-2h
        How: answer the question "who acts, what do they produce, how do they verify?"

[ ] Phase 3. METHODS (SPF §07)
        File: 03-methods/
        Goal: describe the key Practice methods
        Time: ~2-4h
        Template: for each method — inputs, outputs, quality criteria

[ ] Phase 4. WORK PRODUCTS (SPF §07)
        File: 04-work-products/
        Goal: describe the Practice Artifacts
        Time: ~1-2h
        Template: name, description, Definition of Done

[ ] Phase 5. FAILURE MODES (SPF §08) ← high value
        File: 05-failure-modes/
        Goal: 5-10 typical domain errors
        Time: ~1h
        Format: FM.NNN — cause, signal, how to avoid

[ ] Phase 6. SoTA — expand sources (SPF §09)
        File: 06-sota/
        Goal: gather the first source (if Step 1.5 was skipped, sota_sources: none)
             or deepen sources beyond the starter SoTA Sheet — as the Pack grows
        Time: ~1-2h

═══════════════════════════════════════════════════════
  Tools for content work:
  /ke — capture Knowledge into the Pack during work
  /fpf — verify entity correctness per FPF A.*
  /verify pack — baseline adequacy Assessment across 11 coordinates
      E.4.DPF.DA (expect `seedOnly` for a fresh scaffold:
      some coordinates will honestly be below threshold — normal for a template).
      Required run — in /pack-creator Step 4.
  SPF/process/03-distinctions-work.md — detailed process for phase 1
  SPF/process/08-failure-modes-extraction.md — process for phase 5
═══════════════════════════════════════════════════════

Principle: a Pack is not filled in a single sitting.
First value — 7-10 Distinctions (phase 1, 1-2h).
The Pack then grows through work with the domain via /ke.
```
