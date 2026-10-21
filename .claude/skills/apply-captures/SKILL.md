---
agents: single
argument-hint: '[path to a specific report | empty = all pending-review]'
browser_safe: false
description: Processing extraction-reports with status pending-review — making R15
  decisions (accept/reject/defer) by a LIVE PILOT, writing to Pack, updating status,
  committing. Call at Close when N>0 pending-review reports exist.
gates_enforced: []
gates_rationale: operational queue-processing skill; WP Gate not needed — is called
  automatically from Close Gate
gates_required: []
interaction: multi-step
layer: L1
name: apply-captures
routing:
  deterministic: false
  executor: sonnet
status: active
triggers:
  phrases: []
  slash:
  - /apply-captures
version: 1.3.0
---

# /apply-captures — processing extractor candidates

Full Work milestone map for the cycle: `${IWE_GOVERNANCE_REPO:-DS-strategy}/inbox/WP-247-ke-pipeline-vdv.md`
The Skill contract is taken from steps 5, 6, 6.5, and 7 of that map.

## When to use

### Scope

**This Skill does:**
- Reads `${IWE_GOVERNANCE_REPO:-DS-strategy}/inbox/extraction-reports/*.md` with `status: pending-review` or `status: deferred`.
- For each candidate in the report — requests an R15 decision (accept / reject / defer).
- Accept → optional editing → Verification → write file to Pack → update MAP → commit.
- Reject → write reason + pattern to `feedback-log.md`.
- Defer → write reason + `defer_until` to the report.
- Updates the report `status` to `applied` / `partially-applied` / `rejected` / `deferred`.

**This Skill does NOT:**
- Does not launch the R2 agent (extractor) — that is `/ke` and launchd `extractor.sh`.
- Does not create extraction-reports — that is R2.
- Does not edit the contents of captures.md / fleeting-notes.md.

### Work milestone contract (steps 5–7 from ke-pipeline-vdv.md)

```
Input:  ${IWE_GOVERNANCE_REPO:-DS-strategy}/inbox/extraction-reports/*.md  with  status: pending-review
Role:   R15 Validator (accept/reject/defer)
        R4 Author (conditional: editing when edits_needed: yes)
        Skill (automated writing, validation, commit)
Action:
  For each pending-review report, for each candidate:
    1. Show the candidate (id, type, proposed target_path, text).
    2. Request R15 decision per the schema below.
    3. Accept + edits_needed=yes → R4 edits the text.
    4. Step 6.5: validate Pack entity (frontmatter, ID uniqueness, path).
    5. Accept + valid → write file to Pack, update MAP, append feedback-log (pattern), commit.
    6. Reject → write reason + pattern to feedback-log.
    7. Defer → write defer_reason + defer_until to the report.
  Update report status based on outcomes.
Output:
  - Updated Pack (new entity files).
  - Updated ${IWE_GOVERNANCE_REPO:-DS-strategy}/inbox/feedback-log.md (reject patterns).
  - Report with final status (applied / partially-applied / rejected / deferred).
  - Commit to PACK-* (on accept).
```

## Algorithm

### R15 = live pilot, not an agent (BLOCKING rule, peer-session 2026-07-07-03)

> **Invariant:** the accept/reject/defer decision for each candidate is made by the human running the current Session — not another agent, not the agent executing the Skill, and not an automatically accepted R2 verdict (extractor). This is not a recommendation — source: `DP.ROLE.001` (R15 Role holder is the user), `DP.SC.040` ("final approval belongs to the human... full automation does not work", citing the SOTA failure of automated rule generation, accuracy <10%).

**Prohibited:**
- Substituting the pilot's decision with a consensus between two agents inside a peer-session (`peer-conversation`/`kimi-peer-writer`) — agreement between Kimi and Claude does NOT constitute an R15 decision, regardless of the quality of their reasoning.
- Automatically accepting the R2 verdict ("Verdict: accept" in the report) as an R15 decision without actually asking the live pilot — even when the R2 justification appears convincing.
- Assigning an agent to the `R15-*` Role in `meta.yaml`/session frontmatter — the R15 Role cannot be transferred to an agent under any circumstances.

**If apply-captures is called inside a peer-session** (both participants are agents): the peer-session may prepare candidates, check for duplicates/semantics/placement, and debate details — but at this step it must stop and pass the question directly to the pilot, in the current interactive chat with them (not through a turn file in a dialogue with another agent), before recording a decision on any candidate.

**Found during Audit (2026-07-07):** at least 4 historical sessions (`2026-05-24-apply-captures-bulk-review`, `2026-06-11-02-ke-candidates-review-pack`, `2026-06-26-14-apply-captures-r15`, `2026-06-28-09-peer-apply-captures-dp`) recorded decisions on 90+ candidates entirely within a Kimi↔Claude dialogue, with no single pilot reply. Full analysis → `${IWE_GOVERNANCE_REPO:-DS-strategy}/inbox/bugs/bug-2026-07-07-r15-decisions-bypassed-pilot.md`.

### R15 decision format

Each candidate requires a structured decision:

```yaml
candidate_id: 3
decision: accept        # accept | reject | defer
decision_source: pilot   # REQUIRED — the only valid value. Set only upon direct confirmation from the pilot (see block above).
# --- on accept ---
edits_needed: no        # yes | no
target_path: PACK-digital-platform/pack/.../02-domain-entities/DP.D.NNN.md
# --- on reject ---
reason: "duplicate of PD.METHOD.006"
pattern: "check existing METHOD entries before proposing a new one"
# --- on defer ---
reason: "waiting for ArchGate WP-245"
defer_until: "after WP-245 phase 22"     # REQUIRED — date YYYY-MM-DD or event
```

**decision_source invariant (peer-session 2026-07-07-03):** `decision_source: pilot` is a required field for ANY decision (accept/reject/defer). If absent or set to any other value → the decision is invalid; Step 5 (write to Pack) must refuse and return the candidate to Step 2.

**Defer invariant (peer-session 2026-05-31-22):** `defer_until` is a required field when `decision: defer`. Without it the decision is invalid. Reason: `deferred` without `defer_until` is a masked cancel. Format: date `YYYY-MM-DD` OR event reference ("after WP-NNN phase {N}", "at next Week Close").

### Step 1. Find incomplete reports

```bash
GOV_DIR="${IWE_WORKSPACE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}"
bash "$GOV_DIR/scripts/ke-queue-stats.sh" --reports-dir "$GOV_DIR/inbox/extraction-reports" --list
```

If `$ARGUMENTS` specifies a path — work only with that path.
The reader makes no changes and does not access Git or the network. It counts
`pending`/`pending-review`, `partially-applied`, and `deferred` equally, and
shows separate columns for `decide` (decide), `deliver` (deliver), and `wait`
(waiting for a condition). Zero in only the first column does not mean an empty
queue. YAML errors, unknown statuses, an unavailable directory, and unconfirmed
historical statuses produce diagnostics and a non-zero exit code, not a
successful-empty-queue message.

If no open reports exist and there are no diagnostics → report "No incomplete reports."
In an isolated working tree, specify its `--reports-dir` explicitly to avoid
reading from a shared copy. Preserve previous decisions: continue unresolved
items or delivery of already-accepted candidates; do not re-request the same
decisions.

### Step 2. For each report: show candidates

Read the report. For each candidate (frontmatter + body) show the pilot directly in the current chat:
- `id`, `type`, proposed `target_path`
- First 15–20 lines of text (without service frontmatter)
- The `edits_needed` flag from the report (if set by R2)

Request the R15 decision from the pilot — as a real question in the current interactive Session (`AskUserQuestion` when running via Claude Code adapter, a regular message in chat for other interfaces). One question = one candidate, OR (when there are many pre-approved R2 candidates of the same type) one summary for the entire report with an explicit list of each candidate — the pilot confirms/rejects by number. In all cases the answer must come from the pilot; it must not be inferred by the agent from the context of a conversation with another agent.

### Step 3. Accept — editing (conditional)

If `edits_needed: yes` → offer to edit the text together with the user.
If `edits_needed: no` → use the text as-is from the report.

### Step 4 (= Work milestone step 6.5). Validate Pack entity

Before writing, verify three conditions:

### 4a. Frontmatter per Pack Template

Required fields (for most Pack entities):
- `id:` — present and matches the type (DP.D.NNN, PD.METHOD.NNN, etc.)
- `type:` — present
- `status:` — present (typically `draft` or `active`)
- `created:` — present

Template source: `DP.ROLE.033` and neighboring entities in the target directory.

**4a.1. Method-specific check (WP-448 phase 12, decision B):** if `target_path` → `03-methods/` (candidate `*.M.NNN`/`*.METHOD.NNN`) — the candidate text must contain populated `## Forces` (≥1 pole↔pole, not a placeholder) and `## Bias-Annotation` (≥1 named bias+direction, not a placeholder). This is not grounds for reject — return to Step 3 (`edits_needed: yes`) for R4 to complete, then repeat the check. Applies only to new cards from this Pipeline, not to Backlog Migration.

### 4b. ID uniqueness

The ID in the report is preliminary and does not represent a reservation. Before
writing, select a free ID from a fresh published snapshot of the target Pack via
`routing.yaml`. If the ID is already taken by different content, preserve the
pilot's substantive `accept` decision, assign a free ID, and update the filename,
frontmatter, references, and the `candidate_id → target_path` mapping consistently.
An ID collision is not itself grounds for `reject`. Check a substantive duplicate
via Step 4d and the pilot's decision.

Before publishing, including after a commit transfer, repeat the check against a
fresh target branch. A new collision requires reassigning the ID and checking
references; do not overwrite another author's card. Acceptance criterion: two
parallel writers preserve both distinct cards with different final IDs. This is an
application contract; the presence of this text does not prove machine atomicity of
ID allocation.

### 4c-0. Faceted classifier (WP-429 phase 6.4)

> **When it applies:** before Step 4c, for candidates where `target_path` was not unambiguously set by R2 (domain/shelf is unclear) — or always as a check on the path R2 proposed. Skip if R2 already provided a `target_path` matching the shelf derived by Step 4c below.

Four explicit questions for R15 (or an agent self-check before asking the pilot, if the answer is deterministically derivable):

1. **FPF level.** Base (ZP/FP/SP) / Pack (domain knowledge) / DS (implementation) / LPF (personal)? Determines the repo class.
2. **Artifact Role.** AR (rule) / DRR (decision) / lesson / protocol (ritual) / service-clause (promise) / domain entity (D/METHOD/ROLE/FM/SOTA/…)? Determines the kind code.
3. **Domain.** Which Pack? Use the same `knowledge_search` call as Step 0 above (intra-batch) / kNN domain hint: `knowledge_search(query=<name>+<first 400 characters of text>, limit=5)` → aggregate the neighbor repos. **Confidence band is required** (weak/moderate/strong/none — calibration on a real golden set gave repo-level precision ~75%, below 80%; this is an advisory tie-breaker, not a final answer): at `weak`/`none` — ask R15 directly; do not decide on their behalf.
4. **Shelf.** Derived from (1)+(2)+(3) via `routing.yaml` of the target Pack — see Step 4c below; not a separate judgment.

The result is a proposed `target_path`, which Step 4c validates mechanically.

### 4c. File location

**Source of Truth — `routing.yaml` of the target Pack** (WP-429 phase 6.1): `<PACK-repo>/pack/<domain>/routing.yaml` → `kinds.<KIND>.dir` gives the canonical directory for the candidate's kind code (`DP.D`, `PD.METHOD`, `VR.M`, etc.). Read the file and find the section by the candidate's ID prefix:

```bash
grep -A3 "^  <KIND>:" ${IWE_WORKSPACE:-$HOME/IWE}/<PACK-repo>/pack/<domain>/routing.yaml
```

`dir:` → canonical directory. `id_pattern:` → verify the filename matches. `frontmatter_check:` (if not `null`) → the corresponding field/value must be present in the candidate.

**Fallback (Pack without `routing.yaml` not yet covered by contract):** old heuristic rule —
- `DP.D.*` → `.../02-domain-entities/`
- `DP.METHOD.*` → `.../03-methods/`
- `DP.ROLE.*` → `.../02-domain-entities/` or `.../roles/`
- `DP.SOTA.*` → `.../06-sota/`
- `PD.*` → analogous structure in `PACK-personal/` or another Pack repo for the domain

When in doubt (both paths are plausible) — check neighboring files in the target directory.

**Validation result:**
- `valid` → proceed to Step 4d
- `invalid` + reason → reject this candidate, write to feedback-log, continue to the next candidate

### 4d. Semantic check (substantive consistency)

**Step 0 — pairwise intra-batch (WP-376 CC-120, pilot decision 2026-07-16, variant A).**
The Pack index/database at the time of the check does not yet contain neighbors from the CURRENT report — comparison against the database (Steps 1–2 below) is blind to duplicates within a single batch of candidates. Before Step 1: for each candidate in the report with `decision: accept`, compare it against all other accept candidates OF THE SAME TYPE (`DP.D.*` vs `DP.D.*`, `PD.METHOD.*` vs `PD.METHOD.*`, etc.) from the same report:
- Compare `name`/`name_ru` + first 3 sentences of each pair's body.
- Verdict per pair: `duplicate | related | unrelated` (same scale as Step 2 below).
- `duplicate` → warn R15: "candidates <id1> and <id2> from this report duplicate each other" → R15 chooses to reject one / accept both with mutual `see_also`.
Skip if the report has fewer than two accept candidates of the same type.

Before writing, check the substantive compatibility of the candidate against neighboring Pack entities of the same type:

**Step 1 — read ±5 neighboring IDs** of the same type in the target directory:
```bash
ls <target_dir>/ | sort | grep -A5 -B5 "<ID-slug>"
```
For each neighboring file: read `summary:` or the first 3 lines of the body — check for overlap.

**Step 2 — grep key nouns**. Take 2–3 key nouns from the candidate's name. Search the target Pack repo:
```bash
grep -ri "<keyword>" ${IWE_WORKSPACE:-$HOME/IWE}/<PACK-repo>/pack/ --include="*.md" -l | head -10
```
If a match is found: read the file. Check:
- **Overlap**: the candidate describes the same thing in different words → reject (duplicate), add pattern for R2.
- **Contradiction**: the candidate asserts the opposite of an existing entity → determine which is newer/more accurate; if the new candidate supersedes the old one — accept + mark in the report as `supersedes: <ID>`.
- **Refinement**: the candidate adds detail without conflict → accept, add `see_also: [<ID>]` to frontmatter.

**Step 4d result:**
- `clear` → proceed to Step 4e
- `overlap` → reject; pattern + reference to existing ID in feedback-log
- `contradiction` → identify the most recent; on accept add `supersedes:`
- `refinement` → accept + `see_also:` in the candidate's frontmatter
- `intra-batch duplicate` (Step 0) → R15 decision on the pair; the surviving candidate continues from Step 1

### 4e. Semantic Gate — WP-429 Contour A (write-time soft gate)

> **When it applies:** candidate with `decision: accept` and type `DP.*` (DP.D.*, DP.ROLE.*, DP.SC.*, DP.METHOD.*) or `PD.*` in `PACK-digital-platform` or `PACK-personal`.
> **Soft gate:** does not block — informs R15. R15 makes the final decision.
> **When skipped:** `decision: reject` / `defer`, or the type is not a Pack entity (Script, Template, docs).

**Step 1 — semantic neighbor search** (inline, no external Script):

Call the MCP tool `knowledge_search` with the candidate's text:
```
knowledge_search(query=<first 400 characters of candidate text>, limit=5)
```

Filter results: keep only entities with IDs of type `DP.*` or `PD.*` (game concepts, not guides).
Take the top 3 with the highest similarity.

**Step 2 — inline LLM assessment** for each pair (candidate × neighbor):

For each of the top-3 neighbors, make a judgment:
- Candidate: `<name> — <first 500 characters of text>`
- Neighbor: `<neighbor_id> "<neighbor_name>" — <first 500 characters>`
- Verdict: `duplicate | contradiction | related | unrelated`

Criteria (from detector.py):
- `duplicate` — both describe the same concept with the same meaning; keeping both causes confusion
- `contradiction` — incompatible assertions about the same concept
- `related` — connected but clearly distinct; no conflict
- `unrelated` — different topics

**Step 3 — gate result:**

| Verdict | Action |
|---------|---------|
| All `related`/`unrelated` | `clear` → proceed to Step 5 |
| `duplicate` found | Warn R15 (format below) |
| `contradiction` found | Warn R15 (format below) |
| `partial` | Warn R15 "judge unavailable, manual check or retry" |

**R15 warning format:**
```
⚠️  Semantic Gate (WP-429 Contour A): possible <duplicate/contradiction>
Candidate: <id/name>
Conflict with: <neighbor_id> "<neighbor_name>"
Assessment: <verdict> (confidence ~<confidence>%)
Reason: <reasoning>

Options:
  A. Reject candidate → pattern in feedback-log: "duplicate of <neighbor_id>"
  B. Accept as refinement → add `see_also: [<neighbor_id>]` to frontmatter
  C. Accept as replacement → add `supersedes: <neighbor_id>` + mark old as superseded
R15 chooses option:
```

Wait for R15's response. Update the candidate's `decision` and frontmatter according to the choice.

**If `knowledge_search` is unavailable** (MCP offline, network error):
- Mark in the report: `semantic_gate: skipped (MCP unavailable)`
- Proceed to Step 5 without blocking.

**CLI equivalent** (for batch/automation):
```bash
(cd ${IWE_WORKSPACE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}
OPENROUTER_API_KEY="sk-or-v1-..." WP429_DB_ID=3 WP429_TABLE=concept_graph.concepts \
  python3 inbox/WP-429/f2-poc/detector.py --check-candidate \
    --name "<candidate name>" \
    --text "<candidate text>"
)
```

### Step 5. Write to Pack and commit

**Gate before writing (BLOCKING rule):** verify that the candidate decision has `decision_source: pilot`. If the field is absent or set to another value → STOP, return to Step 2 and obtain the decision from the pilot directly. Only decisions with confirmed `decision_source: pilot` may be written to Pack.

### 5a. Write the file

```
Write target_path (from R15 decision) ← candidate text (after editing if applicable)
```

### 5b. Update MAP (if present)

Pack registries are typically at:
- `PACK-digital-platform/pack/.../MAP.md`
- `hard-distinctions.md` — when adding DP.D.*

Check whether a MAP exists in the target directory. Add a line.

### 5c. Write to feedback-log (on reject)

File: `${IWE_GOVERNANCE_REPO:-DS-strategy}/inbox/feedback-log.md` (create if absent).
Entry format:

```markdown
## <date> — reject candidate <id> from report <filename>
**Reason:** <reason>
**Pattern (for R2):** <pattern>
```

### 5d. Commit

```bash
git add <target_path> [MAP if updated] && git commit -m "feat(KE apply): <id> — <short name>" -- <target_path> [MAP if updated]
```

Repo for the commit: the same repo as `target_path` (PACK-digital-platform, PACK-personal, etc.)

### Step 6. Update report status

**Pilot decision and confirmed delivery are separate facts (WP-170/WP-569).**
Append a `## R15 decisions` section to the end of the selected report containing a single YAML block.
The `candidate_id` number is the original candidate number from that report, independent of the new
ID in Pack. The shared `decided_at` (ISO timestamp with timezone) and `decision_session`
are inherited by entries; an entry may override them with its own values.

````markdown
## R15 decisions

```yaml
decided_at: "2026-09-12T23:00:00+03:00"
decision_session: "<identifier of the session containing the pilot's decision>"
decisions:
  - candidate_id: 1
    decision: accept
    decision_source: pilot
    action: merge  # optional; merging with an existing card
    target_path: PACK-digital-platform/pack/digital-platform/03-methods/<file>.md
    publication:
      repo: PACK-digital-platform
      branch: main
      commit: "<full SHA of the actually published commit>"
      blob: "<git blob OID of the exact bytes of the target file in this commit>"
  - candidate_id: 2
    decision: reject
    decision_source: pilot
    reason: "<reason>"
  - candidate_id: 3
    decision: defer
    decision_source: pilot
    reason: "<reason>"
    defer_until: "2099-01-01"
```
````

Before publication, the `publication` field is absent for an accepted candidate. After the
standard gateway `scripts/ds-publish.sh`, write the **final** SHA — not the SHA before
the commit transfer — and the `blob` from `git rev-parse <SHA>:<path-in-repo>`.
The verifier cross-checks the actual tip of `origin` on the specified branch via `ls-remote`,
SHA reachability, and the exact blob at `commit:target_path`. It does not fetch, commit,
or push; if the object at the fresh remote tip is not yet available locally, first perform
the standard safe update of the local copy. Having only the file, a local `main`, an
unconfirmed SHA, or an old `Reports-Closed` does not close delivery.

All **explicit** `## R15 decisions` sections are read in sequence: a later section overrides
only the listed candidates; all other previous decisions are preserved. They take priority
over historical inline YAML. Examples inside a fenced Markdown block are not decisions.
Do not delete history. An extractor "Verdict" is not a pilot decision. Old narrative R15
summaries and terminal statuses without new evidence are preserved with diagnostics;
do not reconstruct missing decisions or publications on the pilot's behalf.

| Condition | Status |
|---|---|
| No decisions yet | `pending-review` (`pending` is read as compatible) |
| Items remain to decide or deliver, including all accepts with zero publications | `partially-applied` |
| All remaining items are deferred with a reason and trigger | `deferred` |
| Nothing incomplete remains and at least one accept is confirmed by published bytes | `applied` |
| Everything rejected by the pilot, reasons preserved | `rejected` |

`defer` always remains incomplete. A date returns the candidate to `decide` when
the deadline arrives; a natural-language event requires a verified fact or pilot
confirmation recorded as `defer_trigger_confirmed: true`. An agent's assumption alone
does not authorize setting this field. Without `defer_until` the decision is invalid
and the candidate remains in `decide`. A remote re-check failure preserves the
previously confirmed terminal status with `reconciliation_stale: true`.

Only the reconciler changes status and the service Projection, addressed to the selected report:

```bash
bash "$GOV_DIR/scripts/ke-report-reconcile.sh" --reports-dir "$GOV_DIR/inbox/extraction-reports" --report "<report name>.md" --dry-run
bash "$GOV_DIR/scripts/ke-report-reconcile.sh" --reports-dir "$GOV_DIR/inbox/extraction-reports" --report "<report name>.md"
```

`--report` may be repeated. Processing the entire queue requires a separate explicit `--all`;
a call without a write scope is refused. `--dry-run` writes nothing. JSON output contains
incomplete item numbers and diagnostic reasons; exit code 1 means confirmation is incomplete
even if the non-terminal Projection was successfully saved.
Review the actual diff of the selected reports, add **the exact files** to the commit,
and publish via the same gateway. A Projection on disk does not by itself constitute
delivery to other readers. Requires Python 3 and PyYAML from the Template's `requirements.txt`.

### Step 7. Final report

Output a summary:
```
Report: <filename>
  Total candidates: N
  Accept: N_a (written to Pack)
  Reject: N_r (patterns in feedback-log)
  Defer: N_d
  Report status: applied / partially-applied / rejected / deferred
```

## Appendix

### Report states (reference)

| Status | Session-Prep cleanup |
|--------|----------------------|
| `pending-review` | Do not touch |
| `partially-applied` | Do not touch |
| `deferred` | Do not touch |
| `applied` | Delete after 7 days |
| `rejected` | Delete after 7 days |
| `no-pending` | Delete after 7 days |

### Integration into the workflow

**DayPlan (daily review):** The DayPlan Template contains an "AI Output → Extractor" section with an overview of:
- N pending-review reports
- Date of the oldest report
- SLA status (✅ on track / ⚠️ overdue)
- Reminder: process in a separate Session `/apply-captures`

**Close Gate:** `extensions/protocol-close.checks.md` — when N > 0 pending-review, issues a ⚠️ warning and SLA reminder (DP.SC.004 §Hard gate). Soft gate — does not block Close, but requires a decision within ≤24h.

**Full cycle:**
1. Cron / `extractor.sh` → creates `extraction-reports/*.md` (status: `pending-review`)
2. Day Open → "AI Output → Extractor" section in DayPlan shows N pending
3. Close → `protocol-close.checks.md` reminds about SLA
4. User runs `/apply-captures` in a separate Session → R15 Review → write to Pack

<!-- USER-SPACE -->
<!-- /USER-SPACE -->
