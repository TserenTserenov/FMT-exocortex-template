---
agents: single
argument-hint: '[code|archgate|capture|pack|wp|chain|adversarial|subsection|section|guide|auto]
  [path or id]'
browser_safe: false
description: Artifact Verification against a Pack reference. Loads role VR.R.001 (Verificator)
  with context isolation — verifies the result, not the creation process.
gates_enforced: []
gates_rationale: operational skill; WP Gate applicable only when creating a new WP,
  not for operational calls
gates_required: []
interaction: multi-step
layer: L1
name: verify
routing:
  deterministic: false
  executor: sonnet
status: active
triggers:
  phrases: []
  slash:
  - /verify
version: 1.0.0
---

# Artifact Verification

> **Role:** VR.R.001 Verificator (PACK-verification)
> **Principle:** Context isolation (VR.SOTA.002) — verify the result against the reference, NOT the creation process.
> **Architecture:** Core (Pack, fixed) + Context (variable) — AS.D.004.

Arguments: $ARGUMENTS

## When to use

Artifact Verification against a Pack reference. Loads role VR.R.001 (Verificator) with context isolation — verifies the result, not the creation process.

## Algorithm

## Extensions `before`

```bash
bash .claude/scripts/load-extensions.sh verify before
```

Code `0` → read each path in alphabetical order and execute instructions before selecting the verification type. Code `1` → no extensions. Any other code or failure of a required extension step → do not start verification; show the actual cause.

## Step 0. Determine the verification type

| Argument | Type | What it verifies |
|----------|------|-----------------|
| `code` | Code review | Code quality: logic, edge cases, security, coupling |
| `archgate` | ArchGate implementation review | Code matches EMOGSSB assessment; principles are embodied |
| `capture` | Capture-candidate review | UL, completeness, consistency with Pack |
| `pack` | Package adequacy review | Checks 11 coordinates of E.4.DPF.DA seed package (Phase1-Phase3 artifacts): SoTA, decision-record, seed-marker, their sufficiency. Used from `/verify pack` or `pack-creator` Step 4 |
| `wp` | Work Product acceptance | Done criteria from WP context file |
| `chain` | Data flow check | Are downstream consumers read? Do contracts match? (CoVe stage 3) |
| `adversarial` | Scope & bias check | Is scope defined by analysis or inference? What was NOT read? (Pre-mortem) |
| `subsection` | Guide subsection review (SS) | 🔴 v4-lint + 🟡 narrative/arc/practice/analogy (G-L) per CHECKLIST-subsection-v1.md |
| `section` | Guide section review (S) | 🔴 v4-lint section + 🟡 SS coherence, arc by mastery stage, topic coverage (D-H) per CHECKLIST-section-v1.md |
| `guide` | Full guide review | 🔴 v4-lint guide + 🟡 object integrity, arc, mastery node coverage, epilogue (E-I) per CHECKLIST-guide-v1.md |
| `auto` or empty | Auto-detect | Based on file type and session context |

**Auto-detection:**
- An ArchGate occurred in the current session → `archgate`
- A path to a .py/.ts/.sh file is specified → `code`
- A path to a Pack entity is specified → `capture`
- A path to a WP context is specified → `wp`
- Changes span >1 file + cross-component → suggest `chain`
- After ArchGate + code → suggest `adversarial`
- Path contains `subsection_id: PD.GUIDE.N.SX.SSY` in frontmatter, or a single guide subsection file → `subsection`
- Path is a section folder (`S{N}-*/`) or a `section_id` is specified in frontmatter → `section`
- Path is `structure-guide-N.md` or a full guide folder → `guide`
- Cannot determine → ask the user

**Pilot triggers:** "verify subsection X" / "verify section S{N}" / "verify guide N" → `subsection` / `section` / `guide` respectively.

## Step 1. Launch the Verificator sub-agent

Launch the Agent tool with context isolation:

**For `code`:**
- Read `git diff` (or specified files)
- Read `CLAUDE.md` of the affected repo
- Pass to sub-agent: diff + CLAUDE.md + code checklist
- Sub-agent model: Sonnet

**For `archgate`:**
- Find the EMOGSSB table from the current session (or request it)
- Read the changed implementation files
- Read DP.ARCH.001 §7 (21 principles)
- Pass to sub-agent: files + table + principles + archgate checklist
- Sub-agent model: Opus

**For `capture`:**
- Read the capture-candidate
- Read the target Pack manifest
- Pass to sub-agent: candidate + manifest + capture checklist
- Sub-agent model: Sonnet

**For `pack`:**
- Read the package WP context (WP-474.md or the package folder)
- Read Phase1-Phase3 artifact files:
  - `06-sota/{slug}-sota-sheet.md` (Phase1: SoTA sheet)
  - `.pfad-decision.md` (Phase2: decision record)
  - `01B-distinctions.md` with marker `**Maturity:** seed` (Phase3: seed-marker + mature-lite checklist)
- Pass to sub-agent the prompt: `verify-pack-adequacy-subsection.md` + data from context
- Sub-agent model: Sonnet
- **Verdict**: `DPFPackageAdequacyStatus` — `admissibleForDeclaredDPFUse` / `seedOnly` / `repairBeforeDPFUse` (auto) + escalation statuses `holdForPFADDecision` / `holdForCoreAmendmentDecision` / `refreshNeeded` — per coordinates D1-D11, ordinal scale 0-5 (WP-474 Phase8.1/Phase8.3, peer session 2026-09-05-27)

**For `wp`:**
- Read WP context file (`{{GOVERNANCE_REPO}}/inbox/WP-{N}-*.md`)
- Read the Work Product artifact
- Pass to sub-agent: artifact + done criteria + wp checklist
- Sub-agent model: per verification_class

**For `chain` (CoVe — Chain-of-Verification, Meta ACL 2024):**
- Read `git diff` of changed files
- For each changed output: `grep` across the codebase — find all files that import/require/call the changed functions
- Read each downstream consumer
- Pass to sub-agent: diff + consumers + chain checklist
- Sub-agent model: Sonnet
- **Chain checklist:**
  1. For each changed output — who consumes it?
  2. Has each consumer been read?
  3. Do output types/format match consumer expectations?
  4. Variables used in the proposed code — where are they defined? Do they exist in scope?
  5. Env vars / configs the code relies on — are they defined in the same file or passed explicitly?

**For `adversarial` (Pre-mortem + Devil's Advocate, PROClaim 2026):**
- Read `git diff` of changed files
- Build a list of files the author did NOT read but that may be affected (`git diff --stat` vs files in diff)
- Read the task description (from WP context or commit message)
- Pass to sub-agent: diff + unread files list + task description + adversarial checklist
- Sub-agent model: Sonnet
- **Adversarial checklist:**
  1. Is scope defined by code analysis, or fitted to a pre-selected conclusion?
  2. Which files/components were NOT read but may be affected?
  3. Assume this fix breaks in production. What are the 3 most likely causes?
  4. Are there alternative explanations for the problem that were not considered?
  5. Does the declared scope ("1 file", "not an archgate", "simple fix") match reality?

**For `subsection` (single guide subsection, WP-322 Phase0.10):**

> Two-stage verification: 🔴 machine (orchestrator) → 🟡 semantic (sub-agent). 🟢 pilot stage is not handled by the agent.

**Environment variables:**
- `IWE_ROOT` — root of the working directory (default: `${IWE_WORKSPACE:-$HOME/IWE}`). Used for paths to Pack and `DS-principles-curriculum`.

**Hotfix exception:** if the latest commit message contains `[hotfix]` — only 🔴 runs, without 🟡 (see CHECKLIST-subsection-v1.md §"Rule").

**Auxiliary mode:** if the subsection frontmatter contains `format_version: 4.1-aux` — this is an auxiliary subsection (.08-concepts, .09-exercises, .10-review-questions, .11-section-conclusions). A **simplified** review applies: only 🔴 B (minimal frontmatter: `subsection_id`, `title`, `order`) + 🟡 content-type check (concepts = summary, exercises = practices, review = questions, conclusions = summary). Full G-L does NOT apply (auxiliary subsections do not introduce concepts and have no meme→method→worldview chain).

- **Stage 🔴 (orchestrator, local):**
  ```bash
  IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
  (cd "$IWE_ROOT/DS-principles-curriculum"
  PACK_FORM_089="$IWE_ROOT/PACK-personal/pack/personal-development/02-domain-entities/formalizations/PD.FORM.089-learner-rcs.md"
  # 1. Structure (A.1-A.11) + Porter contract (B.1-B.9)
  python3 tools/v4-lint.py porter <subsection.md>
  # 2. Cross-guide consistency
  python3 tools/v4-lint.py cross-guide specs/v4-reference/
  # 3. Pack-drift (cp/bh)
  python3 tools/v4-lint.py pack-drift specs/v4-reference/ --pack "$PACK_FORM_089"
  # 4. Concept graph
  python3 tools/v4-lint.py graph build specs/v4-reference/ --out-json /tmp/graph.json
  # 5. Block F (Git integrity + F.4 mastery stage format) — outside v4-lint:
  git -C "$IWE_ROOT/DS-principles-curriculum" status --porcelain specs/v4-reference/   # F.1 clean
  grep -l "$(basename <subsection.md>)" "$IWE_ROOT/aisystant/docs" 2>/dev/null || \
    echo "F.3 WARN: file may not be in the correct repo"
  # F.4 ("Mastery Stages" format — table, not list) verified manually or in 🟡
  )
  ```
  - Any FAIL → verdict `FAIL` with diagnostics from stderr; sub-agent does NOT launch
  - All PASS → proceed to 🟡

- **Stage 🟡 (two specialized sub-agents, Opus, context isolation) — WP-322 Phase14:**

  > Split into two sub-agents: a mixed prompt degrades quality in both branches. The FPF agent sees only FPF; the pedagogy agent sees only pedagogy.

  **Skip for auxiliary:** if `format_version: 4.1-aux` — Stage 🟡 is replaced by a simplified content-type check.

  **Order: FPF → pedagogy** (FPF violations often block pedagogical assessment).

  **Sub-agent 1 — verify-fpf (prompt: `verify-fpf-subsection.md`):**
  - Input: subsection file
  - Prompt: `.claude/skills/verify/verify-fpf-subsection.md`
  - Model: Opus
  - Checks: G (concept boundaries, A.6), H (meme→method→worldview narrative), L (Pack consistency), border-objects
  - If FPF-Verdict = FAIL → stop, return FAIL to the author; do not launch Sub-agent 2

  **Sub-agent 2 — verify-pedagogy (prompt: `verify-pedagogy-subsection.md`):**
  - Input: subsection file
  - Prompt: `.claude/skills/verify/verify-pedagogy-subsection.md`
  - Model: Opus
  - Checks: I (arc by mastery stage, no didactic forbidden words), J (practice and time), K (analogy), transfer test

- **Final Verdict (aggregated):**
  - PASS = FPF-PASS + Pedagogy-PASS → ready for 🟢 pilot test (output issue template `pilot-feedback.yml`)
  - CONDITIONAL = any CONDITIONAL without FAIL → can proceed to 🟢 with caveats
  - FAIL = any FAIL → diagnostics to the author with a breakdown by block

**For `section` (guide section S, WP-322 Phase0.10):**

> Precondition: ALL subsections in the section have already passed `verify subsection` (🔴+🟡 PASS). If not — stop and ask to close all SS first.

**Hotfix exception:** if the latest commit message contains `[hotfix]` AND only one SS is affected — run `verify subsection` for that SS; do not run a full `verify section`.

- **Stage 🔴 (orchestrator):**
  ```bash
  IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
  (cd "$IWE_ROOT/DS-principles-curriculum"
  # 1. Section structural completeness (A.1-A.4, B.1-B.3, C.1-C.2)
  python3 tools/v4-lint.py section --id <section-id> specs/v4-reference/
  # 2. Prerequisites coherence within the section (separate check B.1-B.3, partially overlaps section)
  python3 tools/v4-lint.py prerequisites-graph --scope section --id <section-id> specs/v4-reference/
  )
  ```
  - Any FAIL → verdict `FAIL`
  - PASS → proceed to 🟡

- **Stage 🟡 (sub-agent, Opus, context isolation):**
  - Read: ALL SS in the section (in table-of-contents order) + section frontmatter + `CHECKLIST-section-v1.md` §🟡 (D-H)
  - Volume: typically 5-12 SS × 0.5-1.5K words = 3-20K words
  - Pass to sub-agent: all SS in sequence + frontmatter + checklist §D-H
  - **Model: Opus** — per `CHECKLIST-section-v1.md` §🟡 reference ("Claude Opus, context isolation"). Sonnet handles the volume, but narrative coherence and metaphor consistency across a section require deeper analysis — Opus.
  - **Checklist D-H (5 blocks of 3-4 items each):**
    - D. Narrative coherence of subsections (logical transitions, no "orphan" SS, no repetition)
    - E. Arc by mastery stage within the section (stage_relevant is consistent, tone, complexity increases)
    - F. Topic coverage (all promises fulfilled, no gaps in the section's scope, no extraneous content)
    - G. Analogies in the section (consistency of through-metaphors, no competing metaphors)
    - H. Connection to other sections (references are correct, no contradictions)
  - Sub-agent for each item: PASS/FAIL + specific SS references

- **Verdict:** PASS = 🔴+🟡 PASS → ready for 🟢 section pilot test (≥3 pilots × 6/6). FAIL = diagnostics by specific SS.

**For `guide` (full guide, WP-322 Phase0.10):**

> Precondition: ALL sections of the guide have already passed `verify section`. If not — stop.
> This is the **most expensive** verification type — Opus, volume 20-100K words.

**Hotfix exception:** when a commit contains `[hotfix]` — run only `verify subsection` for affected files; do not run a full `verify guide`. A full guide run is for quarterly content audits or new guide releases.

- **Stage 🔴 (orchestrator):**
  ```bash
  IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
  (cd "$IWE_ROOT/DS-principles-curriculum"
  PACK_FORM_089="$IWE_ROOT/PACK-personal/pack/personal-development/02-domain-entities/formalizations/PD.FORM.089-learner-rcs.md"
  GUIDE_ID="<guide-id>"   # PD.GUIDE.<N> or N (1-4)
  # 1. Guide structural completeness (A.1-A.5, B.1-B.4, C.1-C.3)
  python3 tools/v4-lint.py guide --id "$GUIDE_ID" --pack "$PACK_FORM_089" specs/v4-reference/
  # 2. Cross-guide consistency (within guide + between guides)
  python3 tools/v4-lint.py cross-guide --scope guide --id "$GUIDE_ID" specs/v4-reference/
  # 3. Guide concept graph
  python3 tools/v4-lint.py graph build --scope guide --id "$GUIDE_ID" --out-json /tmp/guide-graph.json specs/v4-reference/
  # 4. Pack-drift at guide scale (if not already run via cmd_guide --pack)
  python3 tools/v4-lint.py pack-drift --scope guide --id "$GUIDE_ID" --pack "$PACK_FORM_089" specs/v4-reference/
  )
  ```
  - Any FAIL → verdict `FAIL`
  - PASS → proceed to 🟡

- **Stage 🟡 (sub-agent, Opus, context isolation):**
  - Read: ALL S/SS of the guide + structure (`structure-guide-N.md`) + README + `CHECKLIST-guide-v1.md` §🟡 (E-I) + guide frontmatter
  - Volume: typically 4-8 sections × 5-12 SS × 0.5-1.5K words = 20-100K words — requires Opus with large context
  - **Strategy for large volume (20-100K words):**
    - If volume ≤ 30K words — pass the entire guide in a single Opus prompt with extended thinking
    - If volume > 30K — batching: sub-agent reads 2-3 sections at a time, accumulates findings; in the final pass — a meta-pass for arc consistency (E-I criteria require seeing the whole guide)
    - Alternative: split the guide checklist into "object integrity + arc" (E, F — require holistic view, one pass) and "coverage + coherence + epilogue" (G, H, I — can be done in parts)
  - Pass to sub-agent: the full guide + structure + checklist §E-I
  - Model: Opus (volume + depth of worldview-shift analysis)
  - **Checklist E-I (5 blocks of 3-4 items each):**
    - E. Object integrity (clear from the first section, not substituted, boundaries respected)
    - F. Narrative arc (progression 1-2 → 3-5, no "jumps", worldview shift is distinct, tone is consistent)
    - G. Mastery node coverage (cp/bh dimensions covered, no gaps by mastery stage, bottleneck nodes marked)
    - H. Coherence with other guides (cross-references, no duplication, junction points explained)
    - I. Epilogue and navigation (epilogue present, connection to mastery stages, README with map)
  - Sub-agent for each item: PASS/FAIL + specific S/SS references

- **Verdict:** PASS = 🔴+🟡 PASS → ready for 🟢 guide pilot test (≥3 pilots × 6/6, typically 2-4 weeks). FAIL = diagnostics by specific S/SS.

## Step 2. Sub-agent: prompt

The sub-agent receives a prompt populated with data from Step 1.

**⛔ The sub-agent does NOT receive:**
- The discussion history of the current session
- The creator's task assignment
- Intermediate reasoning

**For `code`, `capture`, `wp`, `archgate`** — determine the reference:

| Artifact type | Reference |
|---------------|-----------|
| Pack entity | SPF pack-template + Pack domain principles |
| Method description | SPF process/07 + Pack |
| Code (DS) | Repo CLAUDE.md + Pack service descriptions |
| Architectural decision | DP.ARCH.001 §7 (→ use /archgate instead of /verify) |
| Plan (WeekPlan/DayPlan) | Open/Close Protocols |
| Guide subsection (SS) | `DS-principles-curriculum/specs/v4-reference/CHECKLIST-subsection-v1.md` (v1.2+) |
| Guide section (S) | `DS-principles-curriculum/specs/v4-reference/CHECKLIST-section-v1.md` |
| Full guide | `DS-principles-curriculum/specs/v4-reference/CHECKLIST-guide-v1.md` |

If the reference cannot be determined → **STOP.** Report: "Reference not found. A reviewer is needed, not a verificator."

**For `chain`, `adversarial`** — the reference is the code itself (downstream consumers, scope analysis). Checklists are embedded in Step 1.

## Step 3. Verdict

Before forming the final verdict, run Extensions `checks`:

```bash
bash .claude/scripts/load-extensions.sh verify checks
```

Code `0` → read and execute each file on top of the main checker's results. Code `1` → no additional checks. Any other code or a check failure → the result cannot be `PASS`; return `FAIL` with the extension name and the observed cause.

The sub-agent returns a verdict:

```
## Verdict: [PASS / FAIL / CONDITIONAL]

**Context:** [verification type]
**Artifact:** [what was verified]
**Reference:** [what it was verified against]

### Discrepancies

| # | Severity | File | Line | What | Why (reasoning) | Reference |
|---|----------|------|------|------|-----------------|-----------|
| 1 | critical / high / medium / low | path | N | description | why it is a problem | principle/rule |

### Summary

- **Critical:** N
- **High:** N
- **Medium:** N
- **Low:** N

### Recommendation

[1-3 sentences]
```

**Verdict rules:**
- **PASS:** 0 critical, 0 high
- **CONDITIONAL:** 0 critical, ≥1 high
- **FAIL:** ≥1 critical

## Step 4. Show the user

Display the verdict. The user decides:
- **Accept** → continue working
- **Fix** → make changes per the recommendations
- **Reject the verdict** → provide reasoning (→ feedback for training)

After displaying the result, run Extensions `after`:

```bash
bash .claude/scripts/load-extensions.sh verify after
```

Code `0` → read and execute files in alphabetical order. Code `1` → no extensions. An `after` error does not overwrite the already-displayed verdict, but must be shown as a separate warning with the extension name and cause.

<!-- USER-SPACE -->
<!-- /USER-SPACE -->
