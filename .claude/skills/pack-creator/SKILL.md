---
browser_safe: false
description: Guide a PACK-X author through the SPF fill cycle 01-11. Calls R28 Diagnostician
  to select mode (assembly/hybrid/full SPF) and leads through phases. Protects the
  read-only upstream invariant via PreToolUse hook.
layer: L3
name: pack-creator
realized_by:
- DP.SC.048
- DP.ROLE.062
related_methods:
- SPF/process (01-11)
- MIM.M.029 Pack Rework
routing:
  deterministic: false
  executor: sonnet
status: active
trigger_phrases:
- 'Pack Creator, '
- 'Pack Creator, '
triggers:
  phrases:
  - 'Pack Creator, '
  - 'Pack Creator, '
  slash:
  - /pack-creator
version: 1.0.0
---

# /pack-creator — Guiding a PACK-X Author Through the SPF Cycle

> ⚡ **Skill guide, not author.** Knowledge originates with the Pack author. The Skill holds
> the process (SPF/process 01-11), protects the **read-only upstream FPF/SPF** invariant,
> and adjusts depth to match the author's cp.iwe.

## Skill Contract

- **Input:** the author intends to create or continue filling PACK-X (after `/pack-new`).
- **Output:** PACK-X with sections 01-11 filled + state file `.iwe-runtime/state/spf/{pack_id_slug}.yaml` (local, outside the Pack — WP-474 Phase 3).
- **Time:** N sessions of 30–90 min, with checkpoints after each phase.
- **Does not:** write to `SPF/` or `FPF/` (blocked by hook), perform cross-pack consistency Audit (that is R24 Auditor), or decompose activity (that is R29 Artifactor).

## When Invoked

**Trigger phrases:** "Pack Creator, …", slash `/pack-creator`.

**Scenarios (DP.SC.048 §5):**

- The author ran `/pack-new`, the scaffold is ready, sections 02-11 need content.
- The author resumes work on PACK-X across multiple sessions — the Skill picks up from `spf_checkpoint` in the state file.
- The author is unsure which originality mode to choose — the Skill calls R28 Diagnostician.

## Step 0 — Author Diagnostics (R28)

Before starting work, determine the author's **cp.iwe** (competency: "working with formalizations"). This sets the mode:

| cp.iwe | Mode      | What the author does                                                         | What the Skill does                              |
|--------|-----------|------------------------------------------------------------------------------|--------------------------------------------------|
| ≤ 2    | assembly  | Selects distinctions from a checklist of templates from neighboring Packs    | Supplies templates, explains the concepts        |
| = 3    | hybrid    | Modifies templates to fit their Domain                                       | Supplies templates + adaptation questions        |
| ≥ 4    | full SPF  | Originates distinctions, methods, and formalizations                         | Advises on form (frontmatter, naming)            |

**If cp.iwe is unavailable** (new pilot, no data in Neon) → default **assembly**.
Do not force-run `/diagnose` — ask the author directly: "What is your experience with formalizations: first time / some experience / confident?" Then map the answer.

## Step 1 — Scaffold via `/pack-new`

If the `PACK-X/` directory does not exist:

```
Invoke Skill: /pack-new
```

Pass the Domain name (a noun — not a topic or a tool; see CLAUDE.md §1).
`/pack-new` creates the structure from `SPF/pack-template/` (sections 01-11 as empty skeletons) and clones FPF/SPF as needed. Then continue from Step 2.

## Step 2 — SPF/process Phases 02-11

The process sequence runs from `SPF/process/01-domain-selection.md` through `11-review-and-evolution-cycle.md`.
The Skill guides the author through phases **while recording progress in the state file** (Step 7).

### Originality depth by mode

- **assembly (cp.iwe ≤ 2)** — candidates come from the Domain, not from neighboring Packs (WP-474 Phase 6, gap #2: copying neighbor content produced "IWE-style Packs" not grounded in real practice — a D11 violation):
  1. **Distinction candidates** are extracted by the Skill from the Pack's own SoTA sources (`06-sota/*.md`, collected in Step 1.5 of pack-new): deterministic parsing of lines of the form `distinction: X vs Y` — the line is searched for ANYWHERE in the sota-sheet file (line starts with `distinction:`, separator ` vs `), not only near Claims. Found candidates are presented to the author as a checklist — the author selects applicable ones (the checklist mechanic is preserved; it is what makes the mode manageable at cp.iwe ≤ 2; only the material has changed).
  2. **LLM fallback:** if no marked lines exist in the SoTA sheet — the Skill proposes reformulations of claims into the form "X ≠ Y", each labeled "agent proposal, requires author confirmation." Accepted items are added to the SoTA sheet as `distinction: X vs Y` lines — the next pass is then deterministic.
  3. **`sota_sources: none` in the Manifest** → first obtain a source (return to Step 1.5 of pack-new) OR formalize the author's own practice as a source — fallback is allowed only when no external SoTA is available for the Domain, with an explicit record in `06-sota/`: `source: author practice`, `evidence: self-report / interview`, `claims: 2-4 statements`, `validity region: author's personal experience`. A bare "I do it this way" without formalization is not a source (it dilutes D11).
  4. **Neighboring Packs (`PACK-*` in `${IWE:-$HOME/IWE}/`) — for FORM reference only:** header structure `### <code>.D.NNN`, the `**Maturity:**` line, the test "can this be verified?". Copying their CONTENT (distinction wording, terms) into a new Pack is prohibited.

- **hybrid (cp.iwe = 3):** candidates from SoTA sources (same as assembly) + questions: "What is different in your Domain?", "Which term do you replace, which do you keep?" The author modifies the wording; neighboring Packs — form only.

- **full SPF (cp.iwe ≥ 4):** the Skill does not supply templates — it only reminds the author of form requirements (id scheme `<PACK>.D.NNN`, required frontmatter fields, the "can this be verified?" test). The author originates distinctions from scratch.

### Checkpoint after each phase

After completing a section (for example, 03-distinctions is filled):

1. Update `.iwe-runtime/state/spf/{pack_id_slug}.yaml`: `spf_checkpoint: 03`.
2. Offer the author a pause or transition to the next phase.
3. Record the decision; do not insist.

## Step 3 — Invariant Protection (PreToolUse Hook)

The Skill sets the environment variable `PACK_CREATOR_ACTIVE=1` for the duration of the session.
The hook `pack-creator-spf-guard.sh` blocks Write/Edit/NotebookEdit on paths
`${IWE_WORKSPACE:-$HOME/IWE}/SPF/*` and `${IWE_WORKSPACE:-$HOME/IWE}/FPF/*`. When triggered, the hook returns exit 2 with an explanation.

**What to do when the hook fires:**

- Do NOT attempt to bypass it (that is a hook bypass, CLAUDE.md §2.6).
- If the change is **specific to PACK-X** (new distinction, method, or formalization) → rewrite the path to `PACK-X/pack/X/<section>/`. See the extension mechanism in `SPF/process/00-process-overview.md#extension-mechanism`.
- If the change is **systemic** (affects all Packs, edits the SPF process or specification) → this is **a separate work item for editing SPF** (governance work), not `/pack-creator` work. Complete the current phase, then open `/wp-new` with the upstream owner.

## Step 4 — Verify via R23

After completing phases 02-11 (or at an intermediate checkpoint):

1. **Structural check (SPF.SPEC.001):**

```
Invoke Skill: /verify
```

Artifact: `PACK-X/pack/X/`. Reference: `SPF.SPEC.001` (Pack structure and required sections). VR.R.001 runs context-isolated and checks the result, not the process.

2. **Package adequacy per E.4.DPF.DA (WP-474 Phase 4, for seed package):**

```
Invoke Skill: /verify
Argument: pack <path-to-PACK-X>
```

Checks 11 Domain Adequacy coordinates (D1-D11) against artifacts from phases Phase 1–Phase 3 (SoTA sheet, decision record, seed marker) on an ordinal scale of 0–5 with an admissibility threshold (floor 4, or 3 with an explicit draft marker — WP-474 Phase 8.1). Verdict: `DPFPackageAdequacyStatus` (`admissibleForDeclaredDPFUse` / `seedOnly` / `repairBeforeDPFUse`, plus escalation values). The check is honest for a draft: low values on maturity coordinates (pedagogy, practices, transfer, etc.) do not block `seedOnly` — repair Priority is set by sorting result rows by value, not by a list of "critical" coordinates (WP-474 Phase 8.3, peer session 2026-09-05-27).

If a discrepancy with the reference is found (either check): the Skill receives the report, returns to the failing phase, and repeats.

## Step 5 — State Management

> **Moved outside the Pack tree (WP-474 Phase 3, peer session 2026-07-09-14-seed-mature-spf-state).**
> `.spf-state.yaml` is the machine state of the fill process (who, when, up to which checkpoint) — not Pack content. Keeping it inside the Pack would mean that when the Pack is moved or copied (team fork, publication), another author receives a fill-process tracker that is meaningless to them. Contrast: `.pfad-decision.md` (Phase 2) stays INSIDE the Pack — it is the human-readable provenance history that must travel with the Pack.

File: `.iwe-runtime/state/spf/{pack_id_slug}.yaml` — local, outside git (`.iwe-runtime/` is already in the `.gitignore` at the IWE root).

`pack_id_slug` is the Pack directory name without the `PACK-` prefix (for example, `PACK-product-management/` → `pack_id_slug: product-management`). It is NOT the `pack_id` field in the Manifest — that field contains a short mnemonic code (`DP`, `MIM`), not a slug (this discrepancy was found and fixed during WP-474 Phase 3: the original version of this rule incorrectly assumed that the Manifest `pack_id` was the slug with a prefix).

The directory name is determined in this order of Priority: (1) if `/pack-creator` is called with an explicit Pack path or name as an argument ("Pack Creator, continue PACK-X") — take `{slug}` from there; (2) otherwise, if the current working directory is the Pack itself (contains `00-pack-manifest.md`) — take the slug from its name; (3) otherwise — ask the user which Pack to continue; do not guess.

Minimum schema:

```yaml
pack_id: DP   # short code from the manifest, for reference — not used in the state file path
mode: assembly | hybrid | full
cp_iwe_at_start: 2
spf_checkpoint: 03   # last completed SPF/process section
last_session: 2026-05-31
notes: |
  free text from the author between sessions
```

On a subsequent `/pack-creator` run: determine `pack_id_slug` from the Pack directory path or name (`PACK-{slug}` → `{slug}`) → read `.iwe-runtime/state/spf/{pack_id_slug}.yaml` if it exists → restore mode and entry point; do not repeat Step 0 (if `cp_iwe_at_start` is less than 30 days old). Do not read `.pfad-decision.md` for this lookup — the `wp:` field there remains a human-readable audit reference, not a mechanical Skill entry point.

If `.iwe-runtime/state/spf/{pack_id_slug}.yaml` is not found (first run, or the machine changed and state was not transferred manually) — treat this as a first run and start from Step 0. This does not corrupt progress history: the Pack itself (the filled sections) is the source of truth about what has actually been done; `.spf-state.yaml` is only a convenience shortcut, not a required dependency.

## Step 6 — Neighbors (Pack Distinctions)

| Skill/Role                   | When                                               | Boundary                         |
|------------------------------|----------------------------------------------------|----------------------------------|
| `/pack-new`                  | Scaffold PACK-X directories (one-time)             | Skill, not Role                  |
| `/pack-creator` (this one)   | Fill sections 02-11, guide across N sessions       | R30, long process                |
| `/ke`                        | Capture a single fact into Pack/CLAUDE.md/memory   | Point action, not a process      |
| R29 Artifactor-Decompositor  | Break activity into stages (≥3h work item)         | Activity, not Ontology           |
| R24 Auditor                  | Cross-pack consistency, installation Audit         | Outside R30 boundary             |

**R30 boundary test:** "Is this about filling the Ontology of one Pack?" Yes → R30.
"Is this about breaking work into stages?" → R29. "Is this about verifying that N Packs conform to a common standard?" → R24.

## Step 7 — Session Closing

At the end of each Skill session:

1. Write progress to `.iwe-runtime/state/spf/{pack_id_slug}.yaml` (`spf_checkpoint`, `last_session`, `notes`).
2. Unset `PACK_CREATOR_ACTIVE` (via `unset` in the wrapper or by closing the Claude session).
3. If phase 11 is complete and `/verify` passes → offer to commit + push PACK-X.
4. If not end-of-process → note "continue from phase N" in the chat.

## Anti-Patterns

- ❌ The Skill originates distinctions on behalf of the author (especially in full SPF mode).
- ❌ The Skill edits SPF/FPF "because it makes more logical sense" — the hook must fire; bypassing it violates CLAUDE.md §2.6.
- ❌ Skipping phases (03 → 07 without 04-06) — the Pack will have gaps and R23 will fail Verification.
- ❌ Running without a state file, repeating Step 0 on every session.

## Sources

- **DP.SC.048** — service clause "Pack Creation"
- **DP.ROLE.062** — Role "Pack Creator" (R30)
- **SPF/process/00-process-overview.md** — overall process map + extension mechanism
- **CLAUDE.md §1** — Pack Creation Gate, fallback chain
- **WP-369** — closed 31 May, context for Role creation
- **WP-377 Phase 2.4** — Skill implementation + hook (current)
