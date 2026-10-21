# Template: scout-daily

> Daily reconnaissance of slow sources (requiring LLM analysis), complementary to the local overnight-scout.

## Parameters (params)

| Parameter | Type | Example |
|-----------|------|---------|
| `date` | date | 2026-05-17 |
| `focus_areas` | list | [platform, content, community, world, iwe] |
| `sources` | list | github_repos, twitter_handles, hn_threads, telegram_channels |
| `result_repo` | str | `{{GOVERNANCE_ORG}}/{{GOVERNANCE_REPO}}` |

## Prompt

```
You are a scout agent. Find significant signals from slow sources over the last 24 hours.

## Focus areas ({{focus_areas}})

- **platform** — what is new in our infrastructure (PRs, deployments, incidents)
- **content** — relevant publications (long reads, AI news, systematics)
- **community** — what users are discussing, what difficulties they face
- **world** — geopolitics/economics (only if it affects R1–R6)
- **iwe** — complaints about IWE, feature requests, bugs

## Steps

1. For each `source` — read new materials from the last 24h.
2. Filter: noise → discard; relevant → keep with a quote.
3. Classify findings by `priority`: P0 (action required <24h), P1 (note), P2 (ignore for now).
4. For each P0 — propose a task to add to the Agent Inbox.

## Step 5: Write the result

Path: `{{result_repo}}/inbox/agent/scout/{{date}}.md`

Structure:
```
---
date: {{date}}
generated_by: ccr-scout
findings_count:
  P0: N
  P1: M
  P2: K
---

# Scout {{date}}

## Platform
- [P1] <short description> | <link> | action: <proposed action>

## Content
- [P2] ...

## Community
- [P0] ...

## World
- ...

## IWE
- ...

## Auto-promoted tasks (P0)

If at least one P0 exists → create a task file:

`{{result_repo}}/inbox/agent/tasks/TASK-{{date}}-<slug>.md`

With status: pending, priority: P0, agent: ccr-sonnet (or ccr-opus for complex tasks).
```

## Step 6: Commit + push

```bash
cd /path/to/{{result_repo}}
git add inbox/agent/scout/{{date}}.md inbox/agent/tasks/TASK-*.md
git commit -m "scout({{date}}): findings + auto-promoted P0 tasks"
git push
```

## Failure modes

- Source unavailable → skip and mark in the result as «source <name> unavailable».
- No findings → create the file with `findings_count: 0` (important — Day Open reads for file presence).
- git push fails → status: failed, do not fall back to a feature branch.

## Acceptance

- File `inbox/agent/scout/{{date}}.md` exists on main.
- Contains sections for all `focus_areas`.
- If P0 > 0 → task files are created in `tasks/`.
```