---
description: 'L0 routing vocabulary: phrase → canonical path. Read BEFORE writing
  a new file. Miss → DP.KR.001 §5'
domains:
- routing
- knowledge-management
- exocortex
horizon: warm
name: Routing Vocabulary (L0 fast-path)
owner: user
related: DP.SC.036, DP.KR.001
schema_version: 1
status: active
type: reference
valid_from: 2026-05-12
---

# Routing Vocabulary — L0 Fast-Path

> **Principle:** check this file first. Miss or uncertainty → `memory/repo-type-rules.md` (slow-path, universal).
> Source of truth — `memory/repo-type-rules.md`. This file is a fast-path Projection. On conflict, repo-type-rules.md wins.
> **Setup:** replace `{{STRATEGY_REPO}}`, `{{ECOSYSTEM_REPO}}`, `{{INSTRUMENT_REPO}}` with your actual repository names.
> **Updates:** after every misplacement Incident, add a row and a date.

---

## Project Management ({{STRATEGY_REPO}})

| Phrase / Type | Path | Naming | Notes |
|---------------|------|--------|-------|
| **WP-context** (Work Product context) | `{{STRATEGY_REPO}}/inbox/WP-NNN-<slug>.md` | `WP-NNN-<noun-artifact>.md` | Active → inbox/. Closed → archive/wp-contexts/ |
| **WeekPlan** | `{{STRATEGY_REPO}}/current/WeekPlan W{N} YYYY-MM-DD.md` | `WeekPlan W20 2026-05-11.md` | One active at a time |
| **WeekReport** | `{{STRATEGY_REPO}}/current/WeekReport W{N} YYYY-MM-DD.md` | `WeekReport W20 2026-05-11.md` | Created when WeekPlan is closed |
| **DayPlan** | `{{STRATEGY_REPO}}/current/DayPlan YYYY-MM-DD.md` | `DayPlan 2026-05-12.md` | One per day |
| **MonthClose / monthly summary** | `{{STRATEGY_REPO}}/archive/month-reports/MonthClose YYYY-MM.md` | `MonthClose 2026-05.md` | |
| **Strategy Session / strategy protocol** | `{{STRATEGY_REPO}}/sessions/YYYY-MM-DD.md` | `2026-05-12.md` | |
| **Strategy** (long-term document) | `{{STRATEGY_REPO}}/docs/Strategy.md` | Single file, updated in place | |
| **Dissatisfactions** | `{{STRATEGY_REPO}}/docs/Dissatisfactions.md` | Single file | |
| **Reminder** (date-triggered reminder) | `{{STRATEGY_REPO}}/inbox/reminder-YYYY-MM-DD-<topic>.md` | `reminder-2026-05-12-wp121-backfill-check.md` | |

---

## Meetings and Discussions ({{ECOSYSTEM_REPO}})

| Phrase / Type | Path | Naming | Notes |
|---------------|------|--------|-------|
| **Meeting agenda** (team / external) | `{{ECOSYSTEM_REPO}}/0.OPS/0.9.Inbox/YYYY-MM-DD-<topic>-agenda.md` | `2026-05-12-wp150-architect-agenda.md` | ⚠️ NOT {{STRATEGY_REPO}}/inbox/ — that is for WP-context only! |
| **Proposal** (architectural option) | `{{ECOSYSTEM_REPO}}/0.OPS/0.9.Inbox/YYYY-MM-DD-<topic>-proposal.md` | | |
| **Meeting minutes** | `{{ECOSYSTEM_REPO}}/0.OPS/0.7.Plans-and-Meetings/YYYY-MM-DD-<topic>.md` | | |
| **Discussion material** (questions, diagrams, options) | `{{ECOSYSTEM_REPO}}/0.OPS/0.9.Inbox/<slug>.md` | topic-based | Lifecycle: discussed → decisions in ADR/Pack → archive |

---

## Drafts and Publications

| Phrase / Type | Path | Naming | Notes |
|---------------|------|--------|-------|
| **Post draft / post seed** | `{{STRATEGY_REPO}}/drafts/D-NNN-<slug>.md` | `D-027-december-to-april.md` | ⚠️ NOT inbox/ |

---

## Bugs, Incidents, Audit

| Phrase / Type | Path | Naming | Notes |
|---------------|------|--------|-------|
| **Bug report** (IWE/Platform error) | `<governance-repo>/inbox/bugs/bug-YYYY-MM-DD-<topic>.md` | `bug-2026-05-12-routing-gate-miss.md` | governance repo = {{STRATEGY_REPO}} or {{ECOSYSTEM_REPO}} |
| **Incident** (failure postmortem) | `{{ECOSYSTEM_REPO}}/C.IT-Platform/C2.IT-Platform/C2.3.Operations/Incidents/` | folder `YYYY-MM-DD-<slug>/` | |
| **Security posture** (dashboard) | `{{ECOSYSTEM_REPO}}/C.IT-Platform/C2.IT-Platform/C2.2.Architecture/security-posture.md` | Single file | |

---

## Agent Memory (memory/)

| Phrase / Type | Path | Naming | Notes |
|---------------|------|--------|-------|
| **Feedback** (behavioral rule, lesson from user) | `memory/feedback_<topic>.md` | `memory/feedback_routing_gate_always.md` | Test: did the user correct agent behavior? |
| **Lesson** (major cross-system lesson) | `memory/lessons_<topic>.md` | `memory/lessons_lift_and_shift_ddl.md` | Test: useful in future conversations? |
| **Project** (initiative context) | `memory/project_<topic>.md` | `memory/project_first_cohort.md` | |
| **Reference** (tokens, API, DB, URLs) | `memory/reference_<topic>.md` | `memory/reference_neon_connections.md` | |
| **Protocol** (algorithm for IWE) | `memory/protocol-<name>.md` | `memory/protocol-open.md` | SoT in Pack 03-methods/. memory/ = implementation |
| **Routing vocab** (this file) | `memory/routing-vocab.md` | | Update after every misplacement Incident |

---

## Agent Rules and Distinctions

| Phrase / Type | Path | Naming | Notes |
|---------------|------|--------|-------|
| **Distinction** 1–3 lines, always-loaded | `.claude/rules/distinctions.md` | add a line | Test: agent Systematically confuses A and B |
| **Distinction** expanded (test + examples) | `memory/hard-distinctions.md` | add a section | Test: 1–3 lines are not sufficient |
| **Agent rule** global | `CLAUDE.md` §8 (staging) → §9 (authored) | | Affects all repositories |
| **Agent rule** local (single repo) | `<repo>/CLAUDE.md` | | |
| **Formatting** | `.claude/rules/formatting.md` | add a line | |
| **Skill** | `.claude/skills/<name>/SKILL.md` | | |

---

## Pack (Domain Knowledge)

| Phrase / Type | Path | Naming | Notes |
|---------------|------|--------|-------|
| **Service Clause** L4-Personal | `<PACK>/pack/<domain>/08-service-clauses/DP.SC.NNN-<slug>.md` | `DP.SC.036-knowledge-routing-gate.md` | DP.SC.001-099 = L4 |
| **Service Clause** L2-Platform | same, `DP.SC.101-199` | | |
| **Role** | `<PACK>/pack/<domain>/02-domain-entities/DP.ROLE.NNN-<slug>/` | | |
| **Method** (invariant) | `<PACK>/pack/<domain>/03-methods/` | | |
| **Failure mode** | `<PACK>/pack/<domain>/05-failure-modes/` | | |

---

## Implementation (DS-instrument)

| Phrase / Type | Path | Naming | Notes |
|---------------|------|--------|-------|
| **SQL Migration** for a service | `{{INSTRUMENT_REPO}}/<service>/migrations/NNN-*.sql` | `0012-add-consent-column.sql` | |
| **Ad-hoc SQL** (one-off backfill) | `{{INSTRUMENT_REPO}}/<service>/scripts/` | `backfill-YYYY-MM-DD-*.sql` | Delete after execution |
| **ADR** (architectural decision record) | `{{ECOSYSTEM_REPO}}/.../decisions/ADR-NNN-<slug>.md` | | |

---

## Diagnostic Questions on Miss (before asking the user)

1. Is this domain truth or a technical choice? → Pack vs DS
2. Is this a WP-context (Work Product plan) or discussion material? → {{STRATEGY_REPO}}/inbox vs 0.9.Inbox
3. Is this a rule (always) or a lesson (contextual)? → CLAUDE.md vs memory/
4. Is this for the agent or for the user/team? → .claude/ vs DS

---

*Created: 2026-05-12 (WP-216 Phase 4/Phase 5, promoted to IWE). Update on routing Incidents.*
*Replace placeholders: {{STRATEGY_REPO}} → your governance repository name, {{ECOSYSTEM_REPO}} → your ecosystem repository name, {{INSTRUMENT_REPO}} → your tools folder/repository.*
