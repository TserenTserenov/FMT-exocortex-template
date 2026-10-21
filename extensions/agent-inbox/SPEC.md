---
date: 2026-05-17
phase: Phase2
related:
  pack:
  - DP.SC.135-agent-inbox
  - DP.ROLE.045-dispatcher
  wp:
  - 321
  - 316
  - 272
  - 295
status: draft
type: architecture-spec
wp: 324
---
# Agent Inbox — IWE Agent Task Pipeline Specification

> **Purpose:** A single location in the governance repo where the pilot queues tasks for the agent to run later and retrieves results at Day Open. This extends existing Infrastructure (claude.ai CCR + systemd on a personal server) — it does not replace it.

## 1. Problem

From the Phase 1 inventory (18 routines, 4 channels):
1. **Task submission is scattered** — inline in `RemoteTrigger create`, bash scripts on the personal server, ad-hoc CLI calls. There is no single place to view the list of pending agent tasks.
2. **No prompt Templates** — each prompt is written from scratch. Successful patterns do not accumulate.
3. **Result location is ambiguous.** A single file may land on main, on a feature branch, in a PR, in Gmail, in a Neon table, or simply in a chat thread. The pilot does not know where to look.
4. **Lifecycle status is invisible.** Whether a task started, failed, is in progress, or is waiting for input is only discoverable through an explicit query (`RemoteTrigger get`, `journalctl`).
5. **Audit trail does not scale.** Completed routines accumulate in `run_once_fired` with no summary of what agents accomplished during the week.

## 2. Solution (short narrative)

`<governance-repo>/inbox/agent/` — a single agent inbox folder. Contents:

```
inbox/agent/
├── tasks/        # active task files (frontmatter: id, kind, status, agent, due; body: prompt + acceptance)
├── results/      # result files (link to task + artifact + audit trail)
├── scout/        # daily findings (reuses the existing scout pattern, but as a file registry)
├── templates/    # prompt Templates (analyze-section, scout-daily, evolution-cron, soak-verify, retro)
└── archive/      # YYYY/ closed tasks + results
```

**Dispatcher** (hourly routine) — picks up `tasks/*.md` with `status: pending` and `due ≤ now`, runs them through the selected channel with prompt injection from a Template, and records the `task_id ↔ trigger_id/run_id` mapping.

**Launch channels (choice depends on task needs):**

| Channel | When | Implementation |
|---------|------|----------------|
| `claude` CLI headless (`claude -p`) | **Reference (recommended) implementation** — does not depend on the RemoteTrigger API, works on any machine with the claude CLI installed | `scripts/iwe-agent-dispatcher.py` in this extension. Run via cron / systemd / launchd / GitHub Actions |
| RemoteTrigger (claude.ai CCR) | When the task requires MCP connectors (Gmail / Calendar / IWE) | Via claude.ai API. Note: API is in transition v1→v2 (see WP-324, 17 May) — new triggers may be rejected |
| systemd on own server | Heavy workloads requiring root/sudo | Wrapper script + systemd unit |
| local-launchd (mac) | Light tasks on the primary machine | plist in `~/Library/LaunchAgents/` |

**Minimum Configuration for a single pilot:** one `claude` CLI headless channel. Covers ~80% of tasks (analysis, summary, retro, scouting).

**Scout CCR routine** (daily) — reuses the existing `overnight-scout.sh` pattern but writes findings to `inbox/agent/scout/YYYY-MM-DD.md` (not only to DS-agent-workspace).

**Task lifecycle:** `pending → assigned → in_progress → completed | failed | blocked`.

## 3. Task File Format

`tasks/TASK-YYYY-MM-DD-<slug>.md`:

```yaml
---
id: TASK-2026-05-17-analyze-section-11
kind: analyze | scout | evolution | soak | retro | research | publish
status: pending           # pending → assigned → in_progress → completed | failed | blocked
priority: P0 | P1 | P2 | P3
agent: ccr-opus | ccr-sonnet | remote-systemd | local-launchd
template: analyze-section # reference to templates/<name>.md
created: 2026-05-17T14:30:00+03:00
due: 2026-05-17T22:00:00+03:00       # when the task must be launched
wp: 321                              # link to work product (optional)
result_location:                     # REQUIRED — single source of truth
  repo: DS-principles-curriculum
  branch: main                       # OR "PR: ccr-section-11"
  path: specs/v4-reference/Verification/section-11-notes.md
trigger_id:                           # filled by dispatcher after launch
  ccr: trig_NNNN
acceptance:
  - file at result_location.path exists on result_location.branch
  - score >= 6/10 per WRITING-PIPELINE
  - audit trail recorded in results/RESULT-<id>.md
---

# Task: <human-readable title>

## Context
<brief explanation of purpose>

## Prompt (or reference to template)
<substantive content passed to the agent>

## Parameters (for template)
- section_number: 11
- review_branch: main
```

## 4. Result File Format

`results/RESULT-<task-id>.md`:

```yaml
---
task_id: TASK-2026-05-17-analyze-section-11
trigger_id: trig_NNNN
status: completed | failed | partial
started_at: 2026-05-17T22:01:13+03:00
completed_at: 2026-05-17T22:24:55+03:00
model: claude-opus-4-7
cost_usd: 0.42
artifact_url: https://github.com/aisystant/DS-principles-curriculum/blob/main/specs/v4-reference/Verification/section-11-notes.md
---

# Result for TASK-2026-05-17-analyze-section-11

## Artifact
- File: `specs/v4-reference/Verification/section-11-notes.md` on `main`
- Commit: `abc1234`
- Score: 7/10 (per WRITING-PIPELINE)

## Audit Trail
- Launched: dispatcher #N, 17 May 22:01
- Steps: clone → read → analyze → commit → push
- Errors: none

## Pilot Capsule
Section 11 is ready for Review. Main notes: ...
```

## 5. Dispatcher — Algorithm

**Trigger:** CCR routine with `cron_expression: "0 * * * *"` (every hour).

**Steps on launch:**
1. `git clone <governance-repo> --depth 50` → `cd inbox/agent/`
2. Find `tasks/*.md` with `status: pending` and `due ≤ now()`.
3. For each task:
   a. Read the Template from `templates/<task.template>.md`.
   b. Substitute parameters from the task into the Template.
   c. Call `RemoteTrigger create` with the assembled prompt — `result_location` is embedded in the instructions.
   d. Write `trigger_id` into the task frontmatter.
   e. Change `status: pending → assigned`.
4. For each task with `status: assigned`:
   a. `RemoteTrigger get <trigger_id>` — check `ended_reason`.
   b. If `run_once_fired` → verify acceptance (e.g., file exists on the branch) → set `completed | failed`, write result file.
5. Commit + push `<governance-repo>`.

**Stop conditions:**
- If `tasks/` is empty → exit (0 RemoteTrigger calls).
- If >5 pending in one hour → launch only the top 5 by `priority`, leave the rest for the next hour.
- Lock: `inbox/agent/.dispatcher.lock` file with PID and timestamp. If the lock is less than 50 minutes old — skip the run (protection against parallel Dispatchers).

## 6. Scout — Algorithm

**Trigger:** CCR routine with `cron_expression: "0 4 * * *"` (04:00 UTC — after the local `overnight-scout.timer`, if configured on the pilot's server).

**Steps:**
1. Read sources (defined in trigger config): pilot repos, key dashboards, issue trackers.
2. Apply the Template `templates/scout-daily.md` — search for findings across 5 categories (platform / content / team / world / IWE).
3. Write to `inbox/agent/scout/YYYY-MM-DD.md`.
4. If findings with `priority: P0` exist → create a `tasks/` file with `status: pending` (auto-promote).
5. `git push`.

**Relationship to the existing overnight-scout (B1):** The existing system timer continues to run (reads Discord/Twitter/HN fast-changing sources). CCR-Scout has a different profile (reads slow sources requiring LLM analysis: repo PRs, long posts, GitHub Issues with discussion). They do not duplicate — they are complementary.

## 7. Prompt Templates (templates/)

| Template | Purpose | Parameters | Used by |
|----------|---------|------------|---------|
| `_template.md` | Skeleton with placeholders | — | Base for new templates |
| `analyze-section.md` | Analyze a guide section per WRITING-PIPELINE v4 | section_number, repo, branch | WP-321, WP-300 |
| `scout-daily.md` | Daily scouting of slow sources | sources, focus_areas | Scout CCR |
| `evolution-cron.md` | Weekly Revision of one Pack rule | pack_repo, rule_glob | WP-272 weekly |
| `soak-verify.md` | Verify service stability over N hours | service_name, since, metrics | WP-277 pattern |
| `retro.md` | Retrospective of N incidents over a period | period, source | Week Close supplement |

Each Template:
- Contains `{{placeholder}}` parameters.
- Has an "Acceptance criteria" section (content maps to `task.acceptance`).
- Has a "Result location" section (defines where to write the result — sets an invariant for the agent).
- Has a "Failure modes" section (defines what counts as failure, preventing silent success).

## 8. Idempotency and Location Uniqueness

**Invariant (the core rule, derived from Phase 1 root cause):**
> Each task has exactly one `result_location` (repo + branch + path). The agent is not permitted to independently choose a branch or PR via a fallback. If the location is unavailable → `status: failed`, not a silent push to an alternative location.

**Protection against navigation loss:**
- `result_location` in task ⇒ Dispatcher verifies on acceptance ⇒ if the file is not at the specified location = failed.
- No `gh pr create` via if-else in the prompt. If the solution requires a PR, the task explicitly states `branch: PR:<name>` and acceptance verifies PR existence.

## 9. ArchGate — EMHSRSS (conjunctive screening)

> DP.ARCH.001 §7. One ❌ → Architecture revision. CLAUDE.md §5: Blocking rule.

| Characteristic | Assessment | Rationale |
|----------------|-----------|-----------|
| **E — Evolvability** | ✅ | Task files are markdown with frontmatter. A new kind or Template is added as a file, not as a release. Lifecycle statuses are extended via frontmatter schema (semver). |
| **M — Modularity** | ✅ | Clear boundaries: the Dispatcher does not know the specifics of individual tasks (it reads the Template); Templates do not know about the Dispatcher; a task's `result_location` does not know about the push implementation. Connascence exists only at the task file schema level. |
| **H — Openness** | ✅ | Templates are the user layer. Any pilot adds their own Template without modifying Dispatcher code. Promotion to FMT-extensions is the standard sharing channel. |
| **S — Homeostasis** | ⚠️ | Dispatcher lock prevents parallel runs; retry logic is present. **Weak point:** if the Dispatcher CCR times out, tasks remain in `assigned` without cleanup. Mitigation — a separate "sweeper" in the Scout daily routine: tasks in `assigned` for >2 hours are returned to `pending` or marked `failed`. |
| **R — Recoverability** | ✅ | All artifacts are in git: task files, result files, archive. The pilot server Backup (if configured) covers `<governance-repo>`. Idempotency via `task_id` in RemoteTrigger metadata. |
| **S — Speed** | ✅ | Hourly Dispatcher is acceptable for async tasks. Near-realtime is possible via `due: now()` + manual `RemoteTrigger run`. Dispatcher cycle latency ≤5 min (clone + parse + N×RemoteTrigger create). |
| **S — Security** | ⚠️ | Prompts in task files are committed to git → secret leak is possible if someone writes a token in a task. **Mitigation:** (1) `.gitignore` for `inbox/agent/tasks/*-secrets-*.md`; (2) pre-commit hook grep for API_KEY/TOKEN; (3) explicit rule in README: "secrets go in env, not in the task." Also: the Dispatcher must not execute arbitrary bash from the task body — only through Template wrappers. |

**Verdict:** **2× ⚠️, 0× ❌ → PASS.** Implementation may proceed. Mitigations for S (Homeostasis) and S (Security) are included in Phase 3 (sweeper function in Scout + .gitignore + pre-commit hook + README warning).

## 10. IntegrationGate — Steps 1–3

> CLAUDE.md §2. Before implementation — define the promise (DP.SC), scenarios, and Role (DP.ROLE).

### Step 1. Promise

`DP.SC.135-agent-inbox` (separate file in PACK-digital-platform). See §11 below.

### Step 2. Scenarios (≥3)

**Scenario A: Guide section analysis WP-321 (delayed batch).**
- Who: pilot queues tasks for sections 11–15.
- When: weekend evening; the pilot does not want to wait N hours for 5 analyses to complete.
- What they do: `Write inbox/agent/tasks/TASK-...-analyze-section-N.md` × 5, `git push`.
- What happens: the Dispatcher picks up all 5 tasks in the next hour and launches 5 RemoteTriggers in parallel.
- In the morning: 5 result files in `results/`, 5 notes files on main.

**Scenario B: Service soak-verify (deferred one-shot).**
- Who: pilot (dev Role) after deploy.
- When: deploy commit `abc1234`; pilot wants a check after 24 hours.
- What they do: task with `due: 2026-05-18T11:00`, `template: soak-verify`, `service_name: multi-domain-projection-worker`.
- What happens: the Dispatcher launches the CCR at the specified hour; the agent checks `git log` and sends the pilot an email checklist (WP-277 pattern).

**Scenario C: Scout-finding auto-promote.**
- Who: Scout CCR routine (the agent itself).
- When: the daily scouting finds a critical signal (e.g., a security issue in a pip dependency).
- What happens: Scout writes `inbox/agent/scout/2026-05-17.md` and auto-creates `inbox/agent/tasks/TASK-2026-05-17-cve-patch.md` with `status: pending, priority: P0`.
- Next: the Dispatcher picks it up in the next hour; the agent resolves the task or escalates to Telegram if the task requires human input.

### Step 3. Role

`DP.ROLE.045-dispatcher` (Agent Task Dispatcher) — see §12.

## 11. DP.SC.135 — Agent Inbox Promise (draft)

**For:** IWE Creator (pilot) — DP.ROLE.001.

**Promise:** A task placed in `inbox/agent/tasks/` with `status: pending` and `due ≤ NOW + 2h` will be launched by the agent no later than 1 hour after `due`. The result will appear exactly at `result_location`, or the task will be marked `status: failed` with an explicit reason.

**Trigger:** A new `tasks/*.md` with `status: pending` appears in git and `due` is reached.

**Response time:** ≤1 hour after `due`.

**Invariant:** Every task in a terminal status (completed/failed/blocked) has a result file in `results/`. No tasks remain stuck in `assigned` for >2 hours (Scout sweeper returns them to `pending`).

**Failure modes:**
- Dispatcher CCR crashed → the next hourly run picks up stuck `assigned` tasks (lock cleanup).
- `RemoteTrigger create` returned 5xx → task stays in `pending`, retry in one hour; after 3 failures → `failed` with reason.
- `result_location` unavailable → `status: failed`; artifact saved in the result file as a fallback.

**Control promises:**
- If pending > 5 → tasks below P1 wait for the next hour; P0–P1 tasks launch immediately.
- If `cost_total` for the day exceeds $X → throttle (TBD after the first week of real metrics).

## 12. DP.ROLE.045 — Dispatcher (draft)

**Kind:** Coordinator Role — manages the queue; does not perform substantive work.
**Owner Role:** IWE Platform.

**Mission:** Guarantee that pending tasks from `inbox/agent/` are launched on time through the appropriate channel (CCR / remote-systemd / local) and that results are recorded unambiguously.

**Responsibilities:**
- Read `inbox/agent/tasks/*.md` every hour.
- Map `agent` → channel (`ccr-opus` → `RemoteTrigger create`, `remote-systemd` → SSH + systemd-run, `local-launchd` → osascript).
- Apply the Template (parameter substitution).
- Maintain lifecycle: `pending → assigned → in_progress → completed/failed/blocked`.
- Write result file and audit trail.

**Authority:**
- Launch `RemoteTrigger create` from its own account.
- Commit to `inbox/agent/` (via `git push <governance-repo>`).
- Must NOT execute arbitrary bash from the task body (only through a Template).
- Must NOT modify `result_location` in a task (may only write `trigger_id` + `status`).

**Relationships:**
- DP.ROLE.001 IWE Creator — task submitter.
- DP.ROLE.039 Peer Agent — sibling (a peer agent may write a task for another peer).
- DP.ROLE.044 Notification Dispatcher — consumer: the Dispatcher notifies the pilot via Notification Dispatcher if a P0 task fails.

**Boundary:** Does not parse task content. Does not interpret the prompt. Does not choose the branch.