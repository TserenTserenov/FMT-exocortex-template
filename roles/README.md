# Exocortex Roles

> Roles describe **what is done**, not **who does it**. A single agent can perform multiple roles. A single role can be shared by multiple performers.
> Source of truth for role architecture: DP.D.033 (Role-Centric Architecture).

---

## Overview

| Role | ID | Type | Scenarios | Automation |
|------|----|------|-----------|------------|
| [Strategist](strategist/) | R1 | AI agent (Claude) | 9 | launchd (morning, weekly) |
| [Extractor](extractor/) | R2 | AI agent (Claude) | 4 | launchd (every 3 hours) |
| [Synchronizer](synchronizer/) | R8 | Bash tool | 5 scripts | launchd (10 points/day) |

## Strategist (R1)

**Purpose:** Planning, review, and reflection. Creates day plans, weekly summaries, and prepares materials for strategy sessions.

**Scenarios:**

| Scenario | When | Output |
|----------|------|--------|
| day-plan | Every morning (Tue–Sun) | `DayPlan YYYY-MM-DD.md` |
| session-prep | Morning (Mon) | `WeekPlan W{N}.md` (draft) |
| week-review | Night (Sun→Mon) | "Week W{N} Summary" section in WeekPlan + post |
| note-review | On pilot command (not scheduled) | Classification of inbox notes: suggestions and `✅suggested` tag, decision belongs to pilot |
| strategy-session | On request | Interactive strategy session |
| + 4 others | On request | See `strategist/prompts/` |

**Installation:** `bash roles/strategist/install.sh`

---

## Knowledge Extractor (R2)

**Purpose:** Extracting, classifying, and routing knowledge into Pack repositories. Human-in-the-loop: always proposes, never writes without approval.

**Scenarios:**

| Scenario | When | Output |
|----------|------|--------|
| session-close | Session closing | Captures → Pack (with approval) |
| on-demand | On request | Extract specific knowledge |
| inbox-check | Every 3 hours | Process notes and captures |
| knowledge-audit | On request | Pack completeness audit |

**Configuration:** `config/routing.md` — routing table (which Pack repos exist, what goes where).

**Installation:** `bash roles/extractor/install.sh`

---

## Synchronizer (R8)

**Purpose:** Central schedule dispatcher, notifications, and monitoring. Not an AI agent — a Bash tool that orchestrates the other roles.

**Scripts:**

| Script | What it does |
|--------|-------------|
| `scheduler.sh` | Dispatcher: determines which tasks to run in the current hour |
| `notify.sh` | Sends notifications to Telegram |
| `code-scan.sh` | Nightly review of commits in downstream repos |
| `daily-report.sh` | Morning summary of nightly task results |
| `sync-files.sh` | File synchronization between repos |

**Telegram (optional):** Create `~/.config/aist/env` with:
```bash
export TELEGRAM_BOT_TOKEN="your-token"
export TELEGRAM_CHAT_ID="your-id"
```

**Installation:** `bash roles/synchronizer/install.sh`

> **Important:** The Synchronizer replaces the individual launchd agents of the Strategist with a single scheduler. After installation, all roles run from a single entry point (com.exocortex.scheduler).

---

## How to Add a Role

Roles are the extension point of the template. Each role follows the [contract](ROLE-CONTRACT.md) — a formalized structure specification.

1. Create `roles/<name>/`
2. Create `role.yaml` using the schema from [ROLE-CONTRACT.md](ROLE-CONTRACT.md)
3. Add `README.md` with a description (template: [DP.D.033 §3](https://github.com/TserenTserenov/PACK-digital-platform/blob/main/pack/digital-platform/01-domain-contract/DP.D.033-role-centric-architecture.md))
4. Add `install.sh` (copy from an existing role and adapt)
5. If AI agent: add `prompts/` with scenarios
6. If scheduling is needed: add a section to `synchronizer/config.yaml`
7. For notifications: add a template at `synchronizer/scripts/templates/<name>.sh`

`setup.sh` will detect the role automatically:
- `install.auto: true` in role.yaml → installs during full setup
- `install.auto: false` → prints instructions for manual installation

---

## Installation Order

```
1. Strategist (base role, install.auto: true → installed via setup.sh)
   └── Runs autonomously, sufficient to get started

2. Extractor (after 1–2 weeks of use)
   └── Requires: at least one Pack repo + configured routing.md

3. Synchronizer (when orchestration is needed)
   └── Replaces individual launchd agents with a single dispatcher
   └── Optional: Telegram notifications
```

> Start with the Strategist. Add the Extractor and Synchronizer once you have mastered the basic cycle.
