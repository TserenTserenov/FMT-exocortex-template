# IWE Use Cases

> **What this is:** A complete catalog of everything IWE can do for you. Each use case is a platform promise: a specific value you receive.
>
> **Source-of-truth:** [PACK-digital-platform/08-service-clauses/](../../../PACK-digital-platform/pack/digital-platform/08-service-clauses/) — domain use cases. This file is the user-facing Projection.

---

## Overview

| # | Use Case | What You Get | How It Triggers |
|---|----------|--------------|-----------------|
| SC.001 | [Day Planning](#sc001-day-planning) | DayPlan ready by morning with priorities and calendar | ⏰ automatic + 👤 Morning Check |
| SC.002 | [Week Planning and Review](#sc002-week-planning-and-review) | WeekPlan (with "W{N} Results" section) + priority management | ⏰ Monday + 👤 on request |
| SC.003 | [Learning and Development](#sc003-learning-and-development) | Q&A, homework review, knowledge feed, marathons | 👤 via bot |
| SC.004 | [Knowledge Capture and Extraction](#sc004-knowledge-capture-and-extraction) | Notes → formalized Pack entities | 👤 note/capture + ⏰ extraction |
| SC.005 | [Content Publishing](#sc005-content-publishing) | Auto-publish to club + comment tracking | ⏰ automatic + 👤 /club publish |
| SC.006 | [Automatic Maintenance](#sc006-automatic-maintenance) | Sync, scanning, validation — all run automatically | ⏰ automatic |
| SC.007 | [Triage and Tech Debt](#sc007-triage-and-tech-debt) | Negative feedback classified, Backlog prioritized | ⚡ auto + 👤 session |
| SC.008 | [Self-Healing](#sc008-self-healing) | Platform fixes common problems on its own | ⚡ automatic |
| SC.009 | [Analytics and Metrics](#sc009-analytics-and-metrics) | Quality, activity, and time metrics | ⏰ automatic + 👤 /analytics |
| SC.010 | [Work Rhythm (Opening-Work-Closing)](#sc010-work-rhythm-opening-work-closing) | Work structured across four scales — nothing missed | 👤 Day Open / Session Open |
| SC.011 | [Strategizing](#sc011-strategizing) | Dissatisfactions → priorities → approved plan | 👤 Strategy Session (Mon) |
| SC.012 | [Onboarding](#sc012-onboarding) | Configured environment + understanding of capabilities | 👤 first launch |
| SC.013 | [Work Session with Claude Code](#sc013-work-session-with-claude-code) | Task completed, knowledge captured | 👤 any task |
| SC.014 | [Knowledge Formalization (Pack)](#sc014-knowledge-formalization-pack) | Domain knowledge → valid Pack entities | 👤 KE / extraction |
| SC.015 | [System Development (DS)](#sc015-system-development-ds) | New functionality designed and implemented | 👤 development task |

---

## SC.001: Day Planning

**Promise:** Start the workday with clear priorities — not a blank screen.

**What you get:**
- DayPlan — a structured daily plan
- Priorities from WeekPlan + carry-over from yesterday
- Events from Google Calendar
- A recommendation on where to start

**How it works:** The strategist agent automatically generates a DayPlan by 04:00. In the morning you run Morning Check — review overnight services and begin working from the plan.

---

## SC.002: Week Planning and Review

**Promise:** Align work with strategy every week, track Progress, and adjust course.

**What you get:**
- WeekPlan — a weekly plan with Work Products, priorities, and budget (includes a "W{N} Results" section covering the previous week)
- The ability to adjust priorities and add Work Products during the week

**How it works:** By Monday morning, Session Prep (a plan draft) and Week Review (results) are ready. In the Strategy Session you approve the plan. During the week — Check Plan, Update Priorities, Add Workproduct.

---

## SC.003: Learning and Development

**Promise:** Build Competency through personalized interaction with an AI consultant.

**What you get:**
- Answers to Domain questions (drawing on Pack Knowledge)
- Homework Review with feedback mapped to Bloom levels
- Knowledge feed — personalized materials delivered on schedule
- Marathons — step-by-step development programs

**How it works:** Through the Telegram bot. Submit a question → receive an answer in under 3 seconds. Submit homework → receive an Assessment. The feed and marathons arrive on schedule.

---

## SC.004: Knowledge Capture and Extraction

**Promise:** No discovered Knowledge is ever lost.

**What you get:**
- Quick capture of ideas (TG → file, under 2 minutes)
- Capture-to-Pack — announcing Knowledge at the moment of discovery
- Extraction Report — formalized Pack entities
- Updated Ontology for knowledge search via Gateway

**How it works:** Type `.note text` in TG — within 2 minutes it appears in fleeting-notes.md. During work Sessions, Claude announces a Capture. Overnight, the extractor formalizes captures into Pack entities.

---

## SC.005: Content Publishing

**Promise:** Content publishes to the club automatically on schedule.

**What you get:**
- Auto-scan of ready texts (`status: ready`)
- Scheduled publishing to Discourse (systemsworld.club)
- Manual publishing via /club publish
- Notifications about new comments in TG

**How it works:** Set `status: ready` on a text → the system picks it up → publishes it in the scheduled slot → notifies you of comments.

---

## SC.006: Automatic Maintenance

**Promise:** The Platform runs "on its own" — data syncs, Templates update.

**What you get:**
- All ⏰-services run on schedule without intervention
- Daily commit report across all repositories
- Up-to-date YAML Projections for knowledge search via Gateway
- The FMT Template updates and validates automatically

**How it works:** Scheduler Dispatch (10×/day) launches agents. Code Scan, Pack Projection, Template Sync — all run overnight. Everything is ready by morning.

---

## SC.007: Triage and Tech Debt

**Promise:** No problem signal is ever lost.

**What you get:**
- Automatic classification of unhelpful responses with an alert
- Prioritized Backlog from feedback_triage + inbox

**How it works:** User gives 👎 → Auto-Triage classifies it → alert in TG. On request — Triage Session produces a prioritized Backlog.

---

## SC.008: Self-Healing

**Promise:** The Platform fixes common problems on its own — you do not notice failures.

**What you get:**
- L1: automatic reset of stuck users
- L2: correction of recurring errors
- L3: service restart on critical failure
- L4: escalation to a GitHub Issue when the problem cannot be resolved automatically

**How it works:** Four levels. Each next level activates when the previous one fails. Everything up to L4 (developer escalation) is automatic.

---

## SC.009: Analytics and Metrics

**Promise:** Make decisions based on data, not feelings.

**What you get:**
- Daily metrics collection (response quality, activity, feedback)
- On-demand report (/analytics) with trends
- Validation of Pack entities against SPF
- Time tracking by project (WakaTime → Week Review)

**How it works:** Metrics Collection gathers data daily. /analytics delivers a report in TG. WakaTime tracks time continuously; data is available in the dashboard and via API.

---

## SC.010: Work Rhythm (Opening-Work-Closing)

**Promise:** Work is structured around the Opening → Work → Closing cycle across four scales (session, day, week, month). The day and session scales are described below. Nothing is forgotten; everything is recorded.

**What you get:**
- **Day: Opening** — DayPlan ready, calendar reviewed, overnight services checked
- **Day: Work** — tasks completed within Work Products, Captures recorded at Work milestones
- **Day: Closing** — results recorded, carry-over passed on, Backup made
- **Session: Opening** — WP Gate passed, Work Product defined
- **Session: Work** — task executed with Capture-to-Pack
- **Session: Closing** — KE completed, MEMORY updated, report generated
- **Week and Month: Closing** — Week Close and Month Close aggregate closings from lower scales

**How it works:** Opening-Work-Closing is a fractal pattern across four scales (session, day, week, month). Skipping Opening means unplanned work. Skipping Closing means unrecorded results. Claude Code automatically triggers the corresponding Protocols based on triggers.

---

## SC.011: Strategizing

**Promise:** Dissatisfactions become priorities, and priorities become an approved plan.

**What you get:**
- Strategy Session — a weekly session (Mon): dissatisfaction review, Work Product prioritization
- Session Prep — a plan draft prepared by the agent before the session
- Week Review — last week's results as input data
- Priority management throughout the week

**How it works:** By Monday morning, the agent prepares Session Prep (a WeekPlan draft) and Week Review (results). In the Strategy Session you approve the plan. During the week — Check Plan, Update Priorities, Add Workproduct on request.

---

## SC.012: Onboarding

**Promise:** From first contact to first working day — without panic.

**What you get:**
- Configured bot — /start in TG, mode selected, Profile completed
- Configured exocortex — FMT Template deployed, CLAUDE.md configured
- Use case catalog — USE-CASES.md (this file)
- First working day — Day Open completed, DayPlan created

**How it works:** Run setup.sh from the Template → exocortex deployed. /start in the bot → Profile configured. Read USE-CASES.md → understand capabilities. First Day Open → understand the Opening-Work-Closing rhythm.

---

## SC.013: Work Session with Claude Code

**Promise:** Every Session is productive and complete — task done, Knowledge captured.

**What you get:**
- WP Gate — task linked to a Work Product before work begins
- UC Gate — promise (SC) defined
- Completed task — code, document, Configuration
- Captures — Knowledge recorded at Work milestones
- Session Close — KE, MEMORY, report

**How it works:** You give a task → Claude checks WP Gate (is there a Work Product?) → UC Gate (which SC is involved?) → executes the work with Capture-to-Pack at Work milestones → Close with result recording.

---

## SC.014: Knowledge Formalization (Pack)

**Promise:** Domain Knowledge does not stay in people's heads — it becomes formalized Pack entities.

**What you get:**
- Formalized entities — Methods, Distinctions, failure modes, SOTA, Work Products
- Validation against SPF — each entity checked for format compliance
- Connections via frontmatter — accessible through MAP.001
- Updated Ontology — Gateway (iwe-knowledge) receives new entities

**How it works:** Captures from work Sessions → Knowledge Extraction formalizes them into Pack entities (ID, frontmatter, status) → Ontology Sync updates the knowledge index → entities become available to the bot and agents via Gateway (iwe-knowledge).

---

## SC.015: System Development (DS)

**Promise:** Every change goes through a full cycle — from promise to working Service.

**What you get:**
- UC Gate passed — promise (SC) defined before work begins
- IntegrationGate — perimeter, Roles, Work Products, and processes defined
- ArchGate ≥8 — solution evaluated against EMOGSSB
- Working Service — code, PROCESSES.md, entry in MAP.002
- Pilot test — verified before merging to production

**How it works:** Work Product from WeekPlan → UC Gate (which SC?) → IntegrationGate (which perimeter?) → ArchGate (EMOGSSB ≥8) → implementation on pilot → test → cherry-pick to production → MAP.002 + PROCESSES.md updated.

---

*Source-of-truth: PACK-digital-platform/pack/digital-platform/08-service-clauses/*
*Updated: 2026-03-17*
