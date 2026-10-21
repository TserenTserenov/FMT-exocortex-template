# Instructions for All Repositories

> Kimi → `AGENTS.md`, Hermes → Aisystant MCP `get_instructions`; delivery of the core from the author's IWE into this template is an internal author Pipeline (not part of the template, not available to the user). Slim core: triggers + hot rules; details → `memory/`, `.claude/rules-lazy/`, `.claude/skills/`.

## 1. Repository Architecture

**Base** (ZP, FPF, SPF, FMT-*) = principles + formats, platform source of truth · **Pack** = Domain passport, user source of truth · **DS** (instrument/governance/surface) = code, plans, courses — derived from Pack.

**Fallback Chain (where is SoT):** DS → Pack → Base (SPF → FPF → ZP). **Pack = source of truth for domain knowledge; DS changes follow Pack.**
**Principles ladder:** ZPF → FPF → SPF → TPF → LPF — full level table → `memory/repo-type-rules.md`; ailev ↔ IWE glossary → `memory/fpf-reference.md`.

**Pack Creation Gate:** to create a Pack → `/pack-new` (structure `SPF/pack-template/`, process `SPF/process/01-11`, FPF/SPF cloned automatically). Name = domain noun (not a topic, not a tool).

## 2. The Opening–Work–Closing Fractal

> Skipping Opening = unplanned work. Skipping Closing = unrecorded result.
> **Session:** `memory/protocol-open.md § Session` → `memory/protocol-work.md` → `/run-protocol close` · **Day:** `/day-open` ("open") → `/run-protocol day-close` · **Week:** `/run-protocol week-close` · **Month:** `/month-close` (first Monday, before Strategy Session).

### Blocking Rules

> **SoT (WP-272 Phase 1):** `PACK-agent-rules/rules/AR.NNN.md` (registry `.claude/rules-registry.yaml`) — author source, not shipped in template (generator `.claude/scripts/generate-rules-registry.py` requires `PACK-agent-rules`, which the user does not have). On user installation — a shipped condensed version of the same 10 rules → `.claude/rules-lazy/blocking-rules-full.md`. **Priority = numbering:** structural (1–5) overrides behavioral (6–10).

1. **WP Gate:** ANY task → `memory/protocol-open.md` BEFORE starting work. New Work Product → Alignment Ritual → explicit "yes"/"let's do it"/"open"; do not register without this.
2. **Push:** "push"/"commit"/"close" → commit + push without questions, BEFORE the Closing report. Any Close: `git status --short` across all repos → commit + push any uncommitted changes BEFORE the next step.
3. **Close:** Closing trigger → Closing protocol → execute.
4. **Pull-on-Touch:** PreToolUse hook automatically performs a best-effort `git pull --rebase --autostash` once per repo. Do not run manual `cd && git pull`; on failure the hook reports `potentially stale` — procedure → `memory/reference/agent-core.md`.
5. **Checklist Verification:** Quick/Day Close — sub-agent Haiku R23 cross-checks against the checklist. Exceptions: ≤15 min or no file changes.
6. **Hooks/Scripts Bypass Gate (S-33):** without explicit permission, do not modify `.claude/hooks|scripts/`, `.iwe-runtime/`, `IWE/`, and do not bypass hooks; hook block → create a bug file + notify pilot + wait. → `.claude/rules-lazy/hooks-bypass-gate.md`.
7. **Autonomy:** do not ask for confirmation — execute → report. Exceptions: irreversibly destructive action; WP Gate Ritual; choice-question. Full text → `.claude/rules-lazy/blocking-rules-full.md` §7.
8. **Reminders (S-44):** "remind me in X" → `send_telegram_message(schedule_at)` + ScheduleWakeup fallback; fallback fires → Telegram first, then chat.
9. **Finish > defer (S-46):** additional task → default is "doing now"; "now or later?" = anti-pattern. Exceptions and WP Gate priority → `.claude/rules-lazy/blocking-rules-full.md` §9.

### Work Protocol (full → `memory/protocol-work.md`)

**Capture-to-Pack** — at each Work milestone: is there knowledge to record? Announce: *"Capture: [what] → [where]."* Routing: rule → CLAUDE.md, domain knowledge → Pack, implementation detail → DS docs/, lesson learned → memory/; for any new Artifact apply the Routing Gate (DP.KR.001 §5) first.
**Self-correction:** discrepancy within the scope of the current Work turn (files from agenda, `git diff HEAD`) → immediately propose a fix; outside scope → Drift Reporting (SYNC-CORE), do not fix.

### Pre-action Gates

> Full wording → `.claude/rules-lazy/blocking-rules-full.md`.

- Starting work → which services (MAP.002) are affected?
- User scenario → **SC Gate:** which promise (08-service-clauses/) is affected?
- Creating/placing an Artifact → **Routing Gate:** map DP.KR.001 §5; "by analogy with a neighboring file" is prohibited.
- Creating a new registry file/catalog with identifiers (its own numbering scheme) → specify the uniqueness scope and the owner of the scheme; if the scope overlaps with another registry — find where schemes are tracked and align the new scheme there; do not silently create a parallel numbering system.
- First substantive action in a repo → **Repo-Touch Gate:** read `<repo>/CLAUDE.md`; section "required load" → load BEFORE responding.
- Architectural decision → **ArchGate** `/archgate`.
- Work Product involves PII → **Security Gate (B7.3):** ArchGate checklist §B BEFORE implementation; logging PII = blocker.
- Work Product ≥3h → **Priority Gate:** which R{N} does this lead to?
- New tool/agent/system → **IntegrationGate (BLOCKING):** only (1) promise → (2) scenarios → (3) role → (4) implementation → `.claude/rules-lazy/integration-gate.md`.
- Replacing a legacy component → **LegacyPortGate (BLOCKING):** first, a 15-min sub-agent "how does this work now?" → `.claude/rules-lazy/blocking-rules-full.md`.

## 3. Method Descriptions (PROCESSES.md)

≤15 min — not required. Within a system — `<repo>/PROCESSES.md`. New system — scenario + processes + data.

## 4. Memory (Layer 3)

Files/repos → `memory/navigation.md` · Pack repos → `memory/repo-type-rules.md` · terminology → `memory/hard-distinctions.md` · FPF/SOTA/Roles → `memory/fpf-reference.md`, `memory/sota-reference.md`, `memory/roles.md` · document/checklist → `memory/checklists.md`.

Policy: only distinctions.md is checked line-by-line (≤150); everything else uses a combined M1/M2 budget (WP-7 NR1.2); lazy-reference without limit (issue #736: the old "≤11 files" had no enforcing code and diverged from practice — the memory Architecture has long used HOT/WARM/COLD with a token budget, not a file count; see `memory/memory-lifecycle-spec.md`). Horizons/frontmatter → `memory/memory-lifecycle-spec.md`; temporal metadata → `memory/protocol-work.md §2`.
Working directory: `{{WORKSPACE_DIR}}/`; `memory/` = symlink to auto-memory.

## 5. ArchGate — Mandatory Assessment

> **BLOCKING.** Architectural decision → `/archgate`: principles DP.ARCH.001 §7 → EMOGSSB profile (✅/⚠️/❌) → conjunctive screening; modernity checklist (SOTA.002/001/011 + CGUS/PUA) — inside `.claude/skills/archgate/SKILL.md`. Profile without an aggregate score — that is intentional (conjunctive screening, not weighted average).

## 6. Formatting → `.claude/rules/formatting.md` · Distinctions → `.claude/rules/distinctions.md`

## IWE Context Budget (WP-445)

Hot frame ≤20K tokens (M1), strict target ≤12K (M2). If you modify a file from `hot-files.list` (both CLAUDE.md files, rules/*.md) → run `{{IWE_TEMPLATE}}/scripts/verify-context-budget.sh` before committing.

## 7. Updating This File

> **3 layers:** L1 (§1–§7) = platform (`update.sh`). L2 (§8) = staging. L3 (§9) = author.
> Protocols → `memory/protocol-*.md` · distinctions → `.claude/rules/distinctions.md` · formatting → `.claude/rules/formatting.md` · stable knowledge → `memory/*.md` · your own rules → §8/§9.

> **Extensions Gate (BLOCKING for Edit/Write; advisory in general):** user rules go into `extensions/*.md`, settings go into the parameters file (example `params.yaml.example`); a new project-local Skill is allowed in `.claude/skills/<name>/` if that directory is not listed in `update-manifest.json` (issue #311); platform Skills and `memory/protocol-*.md` must not be edited directly (an update will overwrite them). The hook intercepts `Edit|Write` but does not parse arbitrary Bash commands: this is protection against accidental edits, not a security boundary.

> **Obsidian:** the supported vault is a separate governance repository `{{GOVERNANCE_REPO}}`; do not open `{{WORKSPACE_DIR}}` root as a vault — it contains large Markdown files (e.g., `FPF/FPF-Spec.md`). Browse the entire workspace through VS Code.

<!-- PLATFORM-END -->

---

## Agent Core (SYNC-CORE → AGENTS.md)

> **WP-394 Phase 4.2.** Single core for all agents (Claude, Kimi, Codex, Hermes). `AGENTS.md` is generated from this file by `scripts/sync-agent-instructions.sh` — **do not edit `AGENTS.md` manually**. Elaboration → `memory/reference/agent-core.md`.

<!-- SYNC-CORE-START -->

## WP Gate — CRITICAL

**ANY task → Opening protocol → BEFORE starting work.** When creating a new Work Product: declare Role, work, Work Product, verification class, Method, Assessment, model. Wait for pilot approval.

## State-Transition Gate — CRITICAL

**If `{{GOVERNANCE_REPO}}/docs/state-axes-registry.yaml` exists → before any non-trivial action or Work Product, fully read and follow `.claude/rules-lazy/state-transition-gate.md`; if the lazy file is missing or unreadable → inventory only, STOP. No registry → gate is inactive.**

## Git Staging — CRITICAL

**NEVER `git add -u`, `git add .`, `git add -A`** — these pick up changes from OTHER agents (Kimi/Hermes work in parallel) → incorrect attribution. Stage only specific files; before committing run `git diff --cached --name-only` and unstage anything unintended with `git restore --staged`. Examples → `memory/reference/agent-core.md`.

**After `git mv` in the same Work turn — verify content, not just the name (issue #511).** The list of names from `--name-only` may look correct while the diff is empty (rename with no edits) or stale (edits via Edit went to the wrong path). If a `git mv` of any file being committed occurred in this Work turn: run `git diff --cached <new_path>` before `git commit` and confirm the intended changes are present; commit only the new path after `git mv`, not the old one; separately verify the exit code of `git add` before proceeding to `git commit`.

## Artifact Naming

**Do not invent artifact names.** Names for sections, documents, Work Products, and deliverables must come from the plan/task you received. If the task is silent on a name — report "need clarification on name" instead of making one up.

## Drift Reporting

Discrepancy found (file ≠ plan, stale content): **report to pilot, do not silently fix.** Format: "Found drift: [what] in [file]. Should I fix it?" Fix only if explicitly instructed.

## Working Directory

`{{WORKSPACE_DIR}}/`

## FPF Usage

Work relies on FPF/DPF → Skill `/fpf` (step 0 reads the author's instruction file (USING-FPF.md inside the FPF copy) and verifies the full text). Full text unavailable → tell the user and do not draw any conclusion that depends on it; include in the response: copy version, pattern numbers, assumptions.

## Status Reporting — Agent Status Registry (WP-395)

**Primary (required):** at task start `agent_status_update(agent=<claude-code|kimi|codex|hermes>, status=working, task=<brief description>, files=[...])`; on completion — `status=idle`. Statuses: `idle|working|peer-session|blocked`; pilot sees all agents via `agent_status_list`. Team mode (`repo=`) and fail-safe Script → `memory/reference/agent-core.md`.

## Long Operation Protocol — 180 s Silence Threshold

**Do not stay silent for more than 180 seconds.** Operation >180 s → BEFORE starting, report: what is being run, duration, step X of Y, background task id. >180 s of silence → micro-report "Still working. Current step: [X of Y]. Next: [Z]." Applies to everything where the pilot sees an empty "Thinking" (bash, subagent, background tasks, Close protocols).

## WP-REGISTRY Naming — CRITICAL

**The "Name" column in WP-REGISTRY contains ONLY the Artifact name ≤80 characters** — no dates, session references, metrics, SHA values, or other metadata.

**Where to put everything else:** Closing summary → `## Closing` in `archive/wp-contexts/`; phases/progress → frontmatter `inbox/WP-NNN/WP-NNN.md` (always a folder — WP-434); on phase status change update frontmatter, NOT the registry name. Full text and ✅/❌ examples → `memory/reference/agent-core.md`.

## WP Context Scope — Umbrella Work Products

Umbrella Work Products with `agent_scope: open-only` (WP-5, WP-7) — read **only** phases with status `pending`/`in_progress`/`blocked`; do not read archived phases without an explicit user request.

## Calendar Events — CRITICAL

**All agent-created reminders and calendar events must be scheduled BEFORE 09:00 AM** (later only with explicit pilot approval). Created after 09:00 by mistake → delete + recreate before 09:00 + notify pilot (steps → `memory/reference/agent-core.md`).

## Language

Respond in Russian unless the user writes in English.

## Response Style — Pilot-Facing

Rules for clear pilot-facing responses (full text — `memory/feedback_response_clarity_for_pilot.md`) — applies to chat, synthesis reports, and post-action reports.

**Channel detector:** technical style — peer-session transcripts, commits, PRs; plain language — chat with the pilot (unless the pilot writes `grep`/`git`/paths/SHA themselves) and §1–§4 of the report.md synthesis.

**Eleven rules (A1–A11), short:** A1 file path is not the subject of a sentence (put it in parentheses after a plain-language verb); A2 English term only after a plain-language description in parentheses; A3 first mention of a column/function — one-word explanation; A4 pre-flight: will the pilot be able to make a decision from this sentence; A5 WHAT before HOW; A6 one consequence arrow per sentence; A7 "did → effect", `<details>` — only when the pilot needs the details or explicitly requests them; A7.1 log entries (SHA, commits, defects) — write to the report file only, not to chat; A8 do not write a process log by default; A9 channel detector; A10 English status markers (exit/PASS/SHA) → plain-language words; A11 active voice for errors and findings.

## Code Style — Engineering (DP.SC.172)

**P-rules, short:** P0 before committing — run the repo's formatter + linter (tooling handles the mechanics); P1 a test without checking an observable result is prohibited (`assert True` — code smell); P2 third repetition → extract a function, not `locals()[str]`; P3 delete dead branches/enums, do not keep them "for compatibility"; P4 `except: pass` without logging is prohibited; P5 split a long function with mixed responsibilities / boolean mode flags. Boundary: hard prohibitions (`git add -A`, secrets) belong in PACK-agent-rules (AR.*), not here. (Delivery/detectors per agent → `memory/reference/agent-core.md`.)

<!-- SYNC-CORE-END -->

---

## 8. Staging (testing before promotion to template)

> Template authors' section: rules under testing and their promotion. Delivered empty; maintain your own rules in `extensions/*.md` and in the parameters file.

---

## 9. Author (your rules)

> This section is yours: the platform does not populate it. Write project rules inside the block below; template updates preserve the USER-SPACE block.

<!-- USER-SPACE -->
<!-- /USER-SPACE -->

---

*Last updated: 2026-07-16 (M2-slim, WP-7 HOTBUDGET-M2)*