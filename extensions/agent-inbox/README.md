# Agent Inbox IWE

> Unified Pipeline for agent tasks: assignment → dispatch → result.
> **Source-of-truth for Architecture:** [SPEC.md](SPEC.md). Work Product context: [WP-324](../WP-324-agentnyj-konvejer-iwe.md).

## Why

Assign a task to an agent for later execution and retrieve the result at Day Open. No need to remember where to look or which channel to use.

## Contents

| Folder | What it stores |
|--------|---------------|
| `tasks/` | Active tasks (markdown + frontmatter), `status: pending | assigned | in_progress` |
| `results/` | Results of completed tasks (Artifact + audit trail) |
| `scout/` | Daily scout findings (`YYYY-MM-DD.md`) |
| `templates/` | Prompt Templates: analyze-section, scout-daily, evolution-cron, soak-verify |
| `archive/YYYY/` | Closed tasks and results older than 7 days |

## How to assign a task

1. Copy the appropriate Template:
   ```bash
   cp inbox/agent/templates/analyze-section.md \
      inbox/agent/tasks/TASK-$(date +%Y-%m-%d)-<slug>.md
   ```
2. Fill in the frontmatter:
   - `id` — matches the filename
   - `kind` — task type (see SPEC §3)
   - `priority` — P0 (critical), P1 (high), P2 (medium), P3 (low)
   - `agent` — execution channel (`ccr-opus` / `ccr-sonnet` / `remote-systemd` / `local-launchd`)
   - `due` — when the task must be launched
   - `result_location` — **required**: repo + branch + path. Single source of truth.
   - `acceptance` — readiness criteria
   - `params` — parameters for template substitution
3. `git add tasks/ && git commit && git push`

## Where to retrieve the result

In the task's `result_location` (external repo) OR in `results/RESULT-<task-id>.md` (audit trail + link).

## Available Templates

| Template | Purpose |
|----------|---------|
| `_template.md` | Skeleton — copy for new kinds |
| `analyze-section.md` | Section analysis of the guide using WRITING-PIPELINE (WP-321, WP-300) |
| `scout-daily.md` | Daily scouting of slow sources |
| `evolution-cron.md` | Weekly evolution of Pack rules (WP-272 pattern) |
| `soak-verify.md` | Soak-verify of a Service after deploy (WP-277 pattern) |

## Task lifecycle

```
pending ─→ assigned ─→ in_progress ─→ completed | failed | blocked
   ↑           │
   └───────────┘ (sweeper returns stale assigned >2h to pending)
```

## Invariant (critical)

> Every task has a **single `result_location`**. The agent must not create the result anywhere else via fallback (if the main branch is protected → do NOT automatically create a feature branch + PR). A mismatch sets `status: failed`.

Root cause of this rule: May 17 Incident — navigation confusion where results from 07–10 ended up on different branches + 1 PR + stray commits on main, caused by a fallback instruction in the prompt. See [inventory-2026-05-17.md](inventory-2026-05-17.md) §"Investigation".

## Security

- `tasks/*-secrets-*.md` — listed in `.gitignore` (to pass private data, use env variables, not files).
- Pre-commit Hook grep for `API_KEY|TOKEN|PASSWORD` (B7.7a) guards against accidentally committing secrets into a prompt.
- The Dispatcher does NOT execute arbitrary bash from the task body — only via template substitution and the designated channel.

## Automation status (as of May 17, 2026)

- ✅ Architecture: SPEC.md + DP.SC.135 + DP.ROLE.045 published.
- ✅ Folder structure + 5 Templates + dispatcher/scout prompts (reference).
- ⚠️ **Dispatcher CCR** blocked by API issue (RemoteTrigger v1→v2 event_type, see [bug-2026-05-17](../bugs/bug-2026-05-17-remote-trigger-v1-v2-event-type.md)).
- ⚠️ Task assignment is currently manual (via git). Dispatch is manual via local Claude.

## Roadmap

1. Resolve the RemoteTrigger v2 API issue → unblock the automatic Dispatcher.
2. Alternative (if v2 API takes too long): local Dispatcher on a personal server (systemd timer + Python + RemoteTrigger v1 API via saved OAuth) — delivers the same functionality without depending on the CCR environment.
3. Promotion to FMT (Phase 6 WP-324) — `extensions/agent-inbox/` Template for other IWE installations.

## Related documents

- [SPEC.md](SPEC.md) — full Architecture (10 sections)
- [inventory-2026-05-17.md](inventory-2026-05-17.md) — Registry of existing IWE routines
- [DP.SC.135 Agent Inbox](https://github.com/{{GOVERNANCE_ORG}}/PACK-digital-platform/blob/main/pack/digital-platform/08-service-clauses/DP.SC.135-agent-inbox.md) — promise
- [DP.ROLE.045 Dispatcher](https://github.com/{{GOVERNANCE_ORG}}/PACK-digital-platform/blob/main/pack/digital-platform/02-domain-entities/DP.ROLE.045-dispatcher.md) — Role