---
consumer: DP.ROLE.001
created: YYYY-MM-DD
id: DP.SC.NNN
layer: L2-Platform
name: Agent Inbox — IWE agent task pipeline
related:
  extends: []
  realizes: []
  uses:
  - DP.ROLE.NNN
  - DP.ROLE.NNN
status: draft
summary: The IWE Creator submits a task to the agent in a single location and receives
  the result at the declared point no later than 1 hour after due
type: sc
updated: YYYY-MM-DD
---

<!--
Template (IWE/pack-templates/).

This is a promise transfer from the author's Pack (WP-324, 17 May 2026).
When adapting to your own Pack:
1. Replace `DP.SC.NNN` with the next available number in your Pack
2. Replace `DP.ROLE.NNN` with the corresponding role numbers in your Pack
3. Set `created` / `updated` to today's date
4. Remove this HTML comment before committing
-->

# DP.SC.NNN — Agent Inbox

## Rule (invariant)

- [ ] Every task in a final status (completed / failed / blocked) has a corresponding result file in `inbox/agent/results/`.
- [ ] Tasks in `assigned` status older than 2 hours are automatically returned by the Scout sweeper to `pending` (or marked failed).
- [ ] The `result_location` field of a task is the single source of truth: the agent is not permitted to create a result in any other location via fallback. A mismatch means `status: failed`.
- [ ] A task prompt is executed only through the designated template (no arbitrary bash).

## Promise

**To:** DP.ROLE.001 IWE Creator (platform pilot).

**Why:** To delegate asynchronous/deferred tasks (material analysis, slow-source reconnaissance, soak-verify, weekly evolution) without holding them in an active session. To see in one place what is pending with the agent and what is already done.

**What the recipient gets:**
1. A task from `inbox/agent/tasks/*.md` with `status: pending` will be launched through the appropriate channel (CCR / systemd / local) no later than 1 hour after `due`.
2. The result will appear exactly at `result_location` (repo + branch + path).
3. An audit trail in `inbox/agent/results/RESULT-<task-id>.md`: start time, model, cost, artifact link, errors.

**Trigger:**
- A new `tasks/*.md` with `status: pending` appears in git and `due` is reached.
- Periodic dispatcher cycle (hourly).

**Response time:** ≤1 hour after `due`.

**Failure mode:**
- Dispatcher unavailable → tasks accumulate in `pending`; the next run will pick them up. After 24 h with no dispatcher run → notify the pilot via DP.ROLE.NNN (Notification Dispatcher).
- `result_location` unavailable → `status: failed` with reason; the artifact is embedded in the result file as fallback (not lost).
- Launch channel (RemoteTrigger / SSH / launchd) returned an error → retry 3× after one hour; after 3 failures → `status: failed` with reason.
- More than 5 tasks simultaneously pending → top-N by `priority` are launched (P0 → P1 → P2 → P3); the rest wait for the next cycle.

## Evidence (acceptance criteria)

**Data:**

| Criterion | How to verify |
|----------|--------------|
| `inbox/agent/` structure exists with subdirectories tasks/results/scout/templates/archive | `test -d {{GOVERNANCE_REPO}}/inbox/agent/tasks && test -d ...` |
| Dispatcher is running (cron / systemd timer / CCR) | per selected channel: `systemctl status iwe-agent-dispatcher.timer` OR `RemoteTrigger list \| jq '.data[] \| select(.name == "Dispatcher")'` |
| For every task in `completed/failed/blocked` a result file exists | `for f in tasks/*.md; do id=$(yq .id $f); test -f results/RESULT-$id.md \|\| echo MISSING; done` |
| Artifact at `result_location` matches the declared path | acceptance-check inside the dispatcher (part of the algorithm) |

**Context:**

| Condition | Check |
|---------|---------|
| Pilot has git access to the governance repo | `git push {{GOVERNANCE_REPO}}` as the pilot succeeds |
| Launch channel is available | corresponding health-check (claude CLI installed / RemoteTrigger 200 / SSH ok) |
| task.template exists in templates/ | `test -f inbox/agent/templates/<template>.md` |

**Authority:**

| Role | What it confirms |
|------|-----------------|
| DP.ROLE.NNN Dispatcher | That the task was launched / completed / status recorded |
| DP.ROLE.001 IWE Creator | That the prompt is correctly formulated and acceptance is applicable |
| Git commit history | That the event log (creation → status changes → archive) is preserved |

**Evidence:**

| Evidence | Source |
|--------------|---------|
| RESULT file with completed_at | `inbox/agent/results/RESULT-*.md` |
| Artifact at the declared repo+branch+path | external repository |
| Audit trail in archive/YYYY/ | `inbox/agent/archive/YYYY/{tasks,results}/` after move |

## Implementing services (MAP.002)

| Service | Role | Trigger |
|--------|------|---------|
| Dispatcher (CCR / systemd / local) | DP.ROLE.NNN | ⏰ cron 0 * * * * |
| Scout + sweeper | DP.ROLE.NNN | ⏰ cron 0 4 * * * |
| `inbox/agent/` (governance repo) | artifact storage | 👤 pilot / dispatcher |

## User path

| # | Step | Who | Service |
|---|-----|-----|--------|
| 1 | Create task file from template | DP.ROLE.001 (pilot) | git Write + push |
| 2 | Commit to git | DP.ROLE.001 | git commit |
| 3 | Pick up `pending+due` tasks | DP.ROLE.NNN (Dispatcher) | Dispatcher cycle |
| 4 | Launch agent via channel | DP.ROLE.NNN | claude CLI / RemoteTrigger / SSH / launchd |
| 5 | Record `trigger_id`, `status: assigned` | DP.ROLE.NNN | git commit |
| 6 | Wait for completion | agent | external channel |
| 7 | Run acceptance check | DP.ROLE.NNN | acceptance-check |
| 8 | Write result file, `status: completed/failed` | DP.ROLE.NNN | git commit |
| 9 | On P0-failed — notify pilot | DP.ROLE.NNN → DP.ROLE.NNN | Telegram |
| 10 | Archive after 7 days | DP.ROLE.NNN (Scout sweeper) | mv to archive/YYYY/ |

## Relationship to other promises

- Consumes: **DP.SC.NNN** (Notification Dispatcher — for P0-failed notifications) — insert your number
- Used by: future integrations with bots / onboarding / nudges

---

## Adaptation notes

**When this pattern is appropriate:**
- There are ≥3 types of tasks being delegated to the agent on a schedule or outside a session
- Results are regularly lost (where did the agent put it?), and a single point is needed
- Multiple launch channels (CCR + systemd + local) require a coordinator

**When this pattern is NOT appropriate:**
- One or two one-off tasks — easier to handle manually
- All tasks are the same type and go through a single channel — add an explicit `result_location` to each task without the Dispatcher abstraction

**Principle of unambiguous `result_location` (see distinctions):** a task must contain an explicit result path (`repo+branch+path`). Map-derived routing (where the path is inferred from a table) is only permitted under 4 conditions: no override, total derivation, freeze-at-assignment, and a separate map function. At small scale this is not worthwhile — an explicit path is simpler.
