---
description: IWE operational memory file
domains:
- reference
horizon: warm
name: checklists
originSessionId: 9a0e726a-951e-4408-9e02-94d7eeffbf74
owner: platform
schema_version: 1
status: active
type: protocol
valid_from: 2026-03-17
---
# Checklists

## Before answering a question

- [ ] At least 1 relevant file is loaded
- [ ] Repository type is identified (Pack/Downstream/...)
- [ ] Answer is grounded in repository context
- [ ] Sources are cited
- [ ] **Pack direct read:** When looking up specific knowledge in a Pack — read the most likely file directly; do not rely on vector search alone (the index may be stale)

> **Lesson (2026-02-17):** Vector search against the Pack returned a stale version of a card (missing the last section), and I replied "this is not in the Pack" — but it was. Cause: relied on vector search without reading the file directly.

## Before modifying a repository

- [ ] REPO-TYPE.md is read (if present)
- [ ] Repository CLAUDE.md is read (if present)
- [ ] The role of this repository in the Architecture is understood
- [ ] Changes do not violate the source of truth
- [ ] A documented process (PROCESSES.md) exists for changes of this scope

## When moving / renaming a repository

- [ ] `grep -r "Github/<old-path>/"` across ALL repositories — find ALL internal links
- [ ] Scripts (.sh): hardcoded paths `$HOME/Github/...`
- [ ] Prompts (.md): `{{HOME_DIR}}/IWE/...` paths to config/routing
- [ ] Configs (config.yaml): `script:` fields
- [ ] LaunchD templates (.plist): `<string>/Users/.../</string>`
- [ ] Loaded plists in `~/Library/LaunchAgents/` (separate from templates in the repository)
- [ ] GH Actions (.yml): symlinks/paths in workflows
- [ ] README.md: invocation examples
- [ ] CLAUDE.md (root + repository): navigation

> **Lesson:** When moving a repository (renaming paths) — check ALL internal links (scripts, prompts, configs, templates, GH Actions). Otherwise the scheduler may mark tasks as done even when they fail.

## When manually cleaning fleeting notes (🔄 notes)

- [ ] Read MEMORY.md → the Work Product table (entries marked ✅)
- [ ] For each 🔄 note: check whether the intent of the note is already covered by a Work Product result
- [ ] If covered → archive as "Already implemented"; do NOT leave as 🔄

> **Lesson (2026-02-21):** The note "Role description standard" was left as 🔄 even though DP.D.033 (WP-54) had already implemented it. Cause: cross-check against the Work Product table was not performed. The "Match against Work Products" rule in note-review covered only tasks, not ideas — corrected to cover ALL categories.

## When recording a process or decision about a system

- [ ] **PROCESSES.md** — recorded in the system's repository
- [ ] **CLAUDE.md** — brief reference added (if cross-system)

> **Lesson (2026-02-16):** The Issue Funnel process was recorded in CLAUDE.md and PROCESSES.md but not in the Pack. Cause: "process ≠ domain knowledge" — a false Distinction. A system's maintenance process is part of that system's passport. **Rule: a system's process always goes in the Pack AND in PROCESSES.md.**

## Before creating a document

- [ ] **Ask the user** — propose a location with justification
- [ ] Document type is identified
- [ ] Placement location is determined (confirmed by the user)
- [ ] Frontmatter is filled in
- [ ] Links to related documents are specified
- [ ] **>80 lines → `<details>/<summary>`:** If the document will exceed 80 lines — apply collapsible sections IMMEDIATELY. Do not defer. Proposals, specifications, and Architecture documents are almost always >80 lines.

> **Rule:** Before writing to any repository — ask the user and propose a location with justification: repository + path + rationale + alternatives.
> **Lesson (2026-03-17):** WP-109-activity-hub-proposal.md — 314 lines with no collapsible sections. Rule §6 of CLAUDE.md was ignored during generation. Cause: focus was on content; Formatting was not verified before finalizing.

## Before proposing a fix or architectural solution

> **RULE (2026-02-13):** Never propose tactical patches without first evaluating against the 7 characteristics (EMOGSSB). If the `/archgate` Assessment returns a verdict of "DOES NOT pass ArchGate" — STOP and find the correct solution.

- [ ] **ArchGate BEFORE responding:** The EMOGSSB table must appear in the FIRST response containing a solution, not in a follow-up after being asked
- [ ] **Existing patterns:** Check "how is this already solved in the codebase?" before proposing a new approach
- [ ] **Root cause:** The cause is being fixed, not the symptom
- [ ] **BC check:** Is the responsibility in the correct Bounded Context? (do not duplicate server logic on the client)
- [ ] **Coupling:** Does the fix introduce a new fragile dependency? (manual dictionaries, magic constants)
- [ ] **Iterative patches:** If a second commit "fixes" the first — stop and reconsider the approach

> **Lesson (2026-02-15):** Proposed `submitted: common.mode_select` (a crude hack) instead of a silent return (the existing pattern). Cause: ArchGate was not applied immediately. Evolvability and Currency checks would have caught the mistake from the start. **Rule: ArchGate goes in the first response, not after criticism is requested.**
> **Lesson (2026-02-13):** 3 iterative patches in retrieval.py — each worked around the problem. The correct solution: trust MCP + fuzzy correction.


- [ ] `docs/README.md` updated (new entry in the correct month)
- [ ] WP-43 updated (post status → done)
- [ ] Committed and pushed

> **Lesson (2026-02-20):** Wrote a post, committed, pushed — but forgot to update README.md. The rule was already in the repository's CLAUDE.md (§4, §5) but was not followed. **Cause:** The post Exit Protocol has 4 steps; the first was skipped. Also, the path in CLAUDE.md was incorrect (`docs/{YYYY}/README.md` instead of `docs/README.md`) — corrected.

## Close (supplement to CLAUDE.md § 2)

> **RULE:** Before executing Close — RE-READ the CLAUDE.md § 2 Close checklist. Do not execute from memory.

- [ ] WP Context File created/updated at `{{GOVERNANCE_REPO}}/inbox/WP-{N}/WP-{N}.md`
  - Current state, decisions, next steps
  - **Create on the FIRST Close** — do not defer
- [ ] If a new repository was created → MAPSTRATEGIC.md (phase Roadmap)
- [ ] If a new repository was created → Strategy.md (as a source for MAPSTRATEGIC)

> **Lesson (2026-02-11):** WP Context File was not created on time because it was not in the todo list and not in the Close protocol. It is now mandatory.
> **Lesson (2026-02-12):** WP Context File and MAPSTRATEGIC were skipped during Close because the protocol was executed from memory without re-reading the checklist. Rule: always re-read the CLAUDE.md § 2 checklist.

## When adding / removing / renaming files in memory/

- [ ] `template-sync.sh` — update the `mem_file` list (passthrough or strip-author)
- [ ] `validate-template.sh` — update the required files list (if the file is mandatory)
- [ ] `{{GOVERNANCE_REPO}}/exocortex/` — remove stale entries, add new ones (Backup)
- [ ] `protocol-open.md` — update the "Exocortex maintenance" table (if structure changed)
- [ ] Run `template-sync.sh` and confirm that validation passes

> **Lesson (2026-02-22):** Refactoring memory/ (slim CLAUDE.md) broke 3 places: template-sync referenced deleted files, the Backup contained stale copies, and IWE did not receive the new files. Cause: no checklist existed for changes to the memory/ structure.
