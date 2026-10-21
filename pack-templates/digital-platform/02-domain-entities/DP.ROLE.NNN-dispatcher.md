---
created: YYYY-MM-DD
id: DP.ROLE.NNN
name: Agent Task Dispatcher
related:
  component_of:
  - DP.ROLE.001
  downstream_consumers:
  - DP.ROLE.001 IWE Creator — pilot sees status pending tasks and picks up results
  - Scout — writes findings + auto-promotes to tasks/ for P0
  realizes:
  - DP.SC.NNN
  specializes:
  - U.RoleAssignment
  uses:
  - DP.ROLE.NNN
  - inbox/agent/
status: draft
summary: 'IWE agent task queue coordinator: reads inbox/agent/tasks/, launches tasks
  through the appropriate channel (CCR / systemd / local), and records lifecycle and
  audit trail.'
type: role-description
updated: YYYY-MM-DD
valid_from: YYYY-MM-DD
---

<!--
TEMPLATE (IWE/pack-templates/).

This is a role ported from an authored Pack (WP-324, 17 May 2026).
When adapting to your own Pack:
1. Replace `DP.ROLE.NNN` with the next available role number in your Pack
2. Replace `DP.SC.NNN` with your Agent Inbox service clause number
3. Set `created` / `updated` / `valid_from` to today's date
4. Remove this HTML comment before committing
-->

# Agent Task Dispatcher — DP.ROLE.NNN

> # see DP.SC.NNN, DP.ROLE.NNN
>
> **Kind:** Coordinator Role — manages the queue, does not perform substantive work.
> **Owner Role:** IWE Platform — Role Performer: dispatcher (CCR routine / systemd timer on a dedicated server / launchd on mac) + Scout sweeper.

---

## 1. Mission

Guarantee that a task placed in `inbox/agent/tasks/` launches on time through the appropriate channel, and that its result is recorded unambiguously at the declared location (`result_location`).

Analogy: a taxi fleet dispatcher. Does not carry passengers, does not choose routes — only matches an order to a driver, tracks execution, and records delivery.

**Boundary:** The Dispatcher does not parse prompt content, does not choose a branch for a commit, and does not interpret acceptance criteria. All such decisions are already made in the task file (by the pilot or a preceding agent).

---

## 2. Responsibilities

| Responsibility | How it is performed |
|----------------|---------------------|
| Read pending tasks | `git pull --rebase` on a local clone of `{{GOVERNANCE_REPO}}` + `find inbox/agent/tasks -name '*.md'` |
| Parse frontmatter | yq / python yaml parser |
| Filter: `status: pending` AND `due ≤ now()` | python list comprehension |
| Sort by `priority` | P0 → P1 → P2 → P3 |
| Substitute parameters into template | jinja2-like substitution `{{var}}` |
| Launch through channel | `agent: claude-cli` → `claude -p` headless; `agent: ccr-opus` → `RemoteTrigger create`; `agent: remote-systemd` → `systemd-run`; `agent: local-launchd` → osascript |
| Write `trigger_id` + `status: assigned` | git Edit + commit + push |
| Check acceptance | acceptance-check script (part of dispatcher impl) |
| Create result file | Write `RESULT-<task-id>.md` + git commit |
| On P0-failed — notify | via DP.ROLE.NNN (Notification Dispatcher) → Telegram |
| Archive tasks older than 7 days | Scout sweeper: `mv tasks/X.md archive/YYYY/` + corresponding result |
| Clean up stale assigned (>2h) | Scout sweeper: `status: assigned → pending` or `failed` |

---

## 3. Inputs / Outputs

**Inputs (from consumers):**
- `inbox/agent/tasks/TASK-*.md` — placed tasks (from pilot or peer agent).

**Outputs:**
- `inbox/agent/tasks/TASK-*.md` — updated frontmatter (status, trigger_id, completed_at).
- `inbox/agent/results/RESULT-*.md` — Artifacts + audit trail.
- `inbox/agent/archive/YYYY/` — closed tasks after 7 days.
- `inbox/agent/scout/YYYY-MM-DD.md` — Scout findings (written by the Scout agent; the Dispatcher only coordinates).
- Telegram messages to the pilot (via Notification Dispatcher) on P0-failed.

**Artifacts in git:**

| File / folder | What writes it |
|---------------|----------------|
| `inbox/agent/tasks/*.md` | Frontmatter updates (status, trigger_id) |
| `inbox/agent/results/RESULT-*.md` | New result file creation |
| `inbox/agent/archive/YYYY/` | Move of old tasks + results |
| `/tmp/iwe-agent-dispatcher.lock` or equivalent | Lock file (50 min TTL) |
| `~/IWE/scripts/logs/iwe-agent-dispatcher-YYYY-MM-DD.log` | Cycle log |

---

## 4. Architecture (layers)

```
Task submitters
├── DP.ROLE.001 IWE Creator (pilot)    ← Write tasks/TASK-*.md + git push
└── Scout (auto-promote P0)            ← Write tasks/TASK-*.md within its own cycle
        │
        ▼
DP.ROLE.NNN Dispatcher
├── Reader        → git pull --rebase + parse frontmatter
├── Filter        → status==pending AND due<=now
├── Sorter        → by priority P0..P3
├── Template      → substitute {{vars}} from task body
├── Launcher      → switch by agent: → channel-specific call
│     ├── claude CLI headless (`claude -p`)
│     ├── RemoteTrigger create (CCR)
│     ├── ssh + systemd-run (external server)
│     └── osascript + launchctl (local mac)
├── Watcher       → status check (by channel: log scan / RemoteTrigger get / journalctl)
├── Acceptance    → check result_location
└── Archiver      → 7d → archive/YYYY/

Execution channels
├── claude CLI headless (any machine with the CLI installed)
├── claude.ai CCR (RemoteTrigger) — for tasks with MCP connectors
├── systemd on a dedicated server
└── local-launchd (mac)

Notifications
└── DP.ROLE.NNN Notification Dispatcher → Telegram (P0-failed only)
```

---

## 5. Constraints (role invariants)

1. **Single source of truth — the task file.** The Dispatcher does not store state separately. One pull of the governance repo → full recovery after restart.
2. **No fallback on result location.** `result_location` is set → the agent writes exactly there, the Dispatcher checks exactly there. If unavailable — failed, not a silent push to another location.
3. **Lock-based concurrency.** Two parallel Dispatchers do not run simultaneously. Lock file with 50-min TTL; on expiry, the next Dispatcher cleans up and proceeds.
4. **No bash injection.** The Dispatcher does not execute arbitrary bash from the task body — only via template substitution + the designated channel.
5. **Idempotency on task_id.** Re-running the Dispatcher for an already `assigned` task is a no-op (only checks status; does not create a new one).
6. **Audit trail is mandatory.** Every status change = a git commit with a meaningful message (`dispatch(WP-NNN): TASK-X pending→assigned via <channel>`).

---

## 6. Relations to other roles

| Role | Relation |
|------|----------|
| DP.ROLE.001 IWE Creator | Primary task submitter |
| DP.ROLE.NNN Notification Dispatcher | Dispatcher consumer: on P0-failed → send_telegram_message |
| DP.ROLE.NNN Artifactor | Task source: when a new open-loop Work Product ≥3h appears, may propose decomposition via template `task: artifactor-stages` |
| DP.ROLE.NNN Navigator | Task source: may submit a "week retro" task via template `retro` |

---

## 7. Entry points (interfaces)

### Task submission (for submitters)

```bash
# 1. Copy the template
cp inbox/agent/templates/analyze-section.md \
   inbox/agent/tasks/TASK-YYYY-MM-DD-analyze-section-NN.md

# 2. Fill in frontmatter and parameters

# 3. git push
git add inbox/agent/tasks/
git commit -m "task: analyze section NN"
git push
```

### Dispatcher cycle (pseudocode)

```python
def dispatcher_cycle():
    if lock_held_within_50min(): return
    acquire_lock()
    try:
        git_pull_rebase(governance_repo)
        tasks = parse_tasks(governance_repo / "inbox/agent/tasks/")

        # Stage 1: launch pending + due tasks
        for task in sorted(filter(is_pending_and_due, tasks), key=lambda t: t.priority):
            template = load_template(task.template)
            prompt = substitute(template, task.params)
            trigger_id = launch_by_channel(prompt, agent=task.agent)
            task.trigger_id = trigger_id
            task.status = "assigned"
            git_commit_one_task(task)

        # Stage 2: check assigned tasks
        for task in filter(is_assigned, tasks):
            status = check_status(task.trigger_id, channel=task.agent)
            if status == "done":
                ok = check_acceptance(task)
                task.status = "completed" if ok else "failed"
                write_result_file(task)
                if task.priority == "P0" and not ok:
                    notify_pilot(task)
                git_commit_one_task(task)

        git_push()
    finally:
        release_lock()
```

### Watcher / Sweeper (Scout daily)

```python
def sweep_stale_assigned(repo_path):
    for task in find_assigned(repo_path):
        if hours_since(task.assigned_at) > 2:
            status = check_status(task.trigger_id, channel=task.agent)
            if status == "running":
                continue
            elif status == "done":
                ok = check_acceptance(task)
                task.status = "completed" if ok else "failed"
            else:
                task.status = "pending"  # return to queue
```

---

## 8. Metrics

| Metric | Norm | Source |
|--------|------|--------|
| Median lag (due → run start) | ≤30 min | git log + dispatcher metadata |
| % failed of total | ≤10% | scan results/ |
| Pending count > 5 simultaneously | rare (once per week) | live count from dispatcher cycle result |
| Stale assigned (>2h) | 0 after Scout sweeper | sweeper result |
| Cost (USD/week) | < $30 for pilot workload | dispatcher metadata aggregate |

---

## 9. Open questions (for review after the first week)

1. **Cost throttle.** When cost > N$/day — P0 priority only. Where is the threshold?
2. **Auto-archive >7d.** Is 7 days sufficient? Perhaps 14?
3. **Template versioning.** If a template changes — do existing tasks use the old or new version? Currently — new (substitution happens at dispatcher time). Conflicts are possible.
4. **Peer coordination.** If two peer agents simultaneously submit tasks on the same topic — dedup logic is needed. Currently relies on git merge.

---

## Adaptation notes

**Choosing a launch channel:**

| Channel | When | Pros | Cons |
|---------|------|------|------|
| `claude` CLI headless (`claude -p`) | Default channel for a dedicated server | Does not depend on CCR API; runs locally; full control | Requires a dedicated server with claude CLI |
| RemoteTrigger (CCR) | When MCP connectors are needed (Gmail/Calendar/IWE) | Ready-made claude.ai infrastructure; MCP out of the box | Dependency on claude.ai API (v1→v2 transition is failure-prone) |
| systemd on an external server | Heavy workloads requiring root/sudo | Full environment control | Requires a server |
| local-launchd (mac) | Light tasks on the primary machine | Cheap, always available | Tied to a specific laptop |

**Minimum configuration for a single pilot:** one `claude` CLI headless channel on any machine with `claude` installed (mac/linux/wsl). Covers 80% of tasks.
