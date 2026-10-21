---
consumer: R14 Customer — pilot outside the desktop
created: 2026-05-27
id: DP.SC.NNN
layer: L4-Platform
name: External Session Request
name_en: External Working Session
name_ru: External Working Session
related:
  differs_from: DP.SC.135
  differs_from_2: DP.SC.013
  see_also:
  - DP.SC.161
  uses:
  - DP.ROLE.NNN
  - DP.SC.135
status: draft
summary: 'The Pilot runs a full multi-turn work session via Telegram — equivalent
  to a VS Code window, but asynchronous. Supported: question→answer→question dialogue,
  Work Product operations, calendar operations, Work Product creation, IWE search.
  All actions are tracked.'
type: sc
updated: 2026-05-27
wp: WP-358
---

# [DP.SC.NNN] External Session Request

## Rule (invariant)

> Violating any item = SC failure.

1. **Idempotency.** Composite key `(tg_chat_id, message_id)` — one Telegram message creates exactly one Work turn. A retry on failure does not produce a duplicate Work turn.

2. **Acknowledgment SLA.** The bot replies "Working…" in Telegram at P95 ≤10s from message send time. Acknowledgment does not depend on processing duration.

3. **Completion SLA.** P95 ≤45s for `category: light` Work turns (expected response ≤200 tokens). For `category: heavy` — async mode: progress notifications every 15s, final response with no SLA guarantee.

4. **PII guard.** Flag `--private` → the thread file is not committed to git, stored only in local SQLite (`~/.iwe/sessions.db`). Only metadata is written to the SESSION file (session_id, status, timestamps).

5. **Timeout + Heartbeat.** `max_session_duration = 60 minutes` from the last Work turn (the Session closes after 60 min of silence). Hard cut-off for a single Work turn — 15 minutes. Dispatcher heartbeat (self-check): ping to SQLite every 30s; miss >90s → status `failed` + TG alert. Cancellation contract: `/cancel` from the Pilot → SIGTERM to the dispatcher → partial transcript is saved → status `cancelled`.

6. **Cleanup.** The SESSION file and thread file are archived to `inbox/agent/sessions/archive/` 24h after the last Work turn, or immediately on `/close`. The `sessions/` folder is not permanent storage.

7. **Multi-turn continuity.** Each subsequent Pilot message in the same Telegram chat (without an explicit `/close`) is treated as the next Work turn of the same Session and is appended to `SESSION-<id>-thread.md`. Claude Code is launched with the full thread context. Session identification: `(tg_chat_id, active_session_id)` from SQLite.

**Failure mode:** VS Code is not open or the dispatcher is not running → TG notification "Environment not started, please open VS Code." Silent failure is not allowed.

---

## Promise

**To:** Pilot (Customer, R14) — away from the workstation (subway, lunch, walk, travel).

**Why:** Telegram becomes a full work window on par with VS Code. Work is not interrupted when away from the computer. A fix requires several Iterations? A question→answer→question dialogue proceeds without losing context. Need to create a Work Product, schedule a meeting, or find Knowledge from IWE? All through one Interface.

**What the Pilot receives:**
- Acknowledgment in Telegram ≤10s (confirmation that the Work turn is accepted)
- Claude Code response — in the same Telegram chat, with the context of previous Work turns preserved
- Support for capability requests: `→ Calendar`, `→ Work Product`, `→ IWE Knowledge` (see §Capability scope)
- Activity tracking: all Work turns are written as domain events (WakaTime + activity_log)
- Audit trail — SESSION thread in git (unless `--private`)
- Graceful failure — explicit message if the Environment is unavailable

**Acceptance criterion:** end-to-end from first message to response, P95 ≤45s for light Work turns, 5-turn smoke dialogue green 5/5, activity tracking recorded.

---

## Usage scenarios

### Scenario 1: Urgent fix in a multi-turn dialogue

**Consumer:** Pilot in transit, discovered a bot bug via an alert.

```
Pilot:  /claude figure out why activity_emitter is crashing
Claude: Checked the Railway logs. I see ConnectionDoesNotExistError at line 47.
        The pooler is masking a FATAL. Switch to the unpooled endpoint?
Pilot:  yes, switch it
Claude: Updated DATABASE_URL in Railway env to unpooled. A redeploy is needed.
        Deploy?
Pilot:  yes
Claude: Deployed. Smoke test: 3/3 PASS. Activity emitter is working.
```

Session: 5 Work turns, ~8 minutes. Context (Railway logs, files) is maintained through the thread.

---

### Scenario 2: Full Work Product session "on the go"

**Consumer:** Pilot riding 40 minutes in a taxi, wants to advance WP-358 Phase 2.

```
Pilot:  /claude let's work on WP-358 Phase 2, need to write the spec at inbox/agent/sessions/SPEC.md
Claude: Opening WP-358 context… Here is a draft SPEC.md with frontmatter SESSION-<id>.
        Parameters: session_id, tg_chat_id, message_id, text, private, status.
        Add capability_tags?
Pilot:  add them, and include thread_id too
Claude: Updated. Create the file?
Pilot:  yes
Claude: Created inbox/agent/sessions/SPEC.md, commit ready. Push?
Pilot:  yes
Claude: Pushed. Phase 2 checklist: ✅ SPEC.md created. Next step — extend the dispatcher.
```

The same power as in VS Code, just through Telegram.

---

### Scenario 3: Structured requests (calendar, Work Product, IWE)

**Consumer:** Pilot at lunch, several quick requests.

```
Pilot:  schedule a meeting with Andrey tomorrow at 15:00 for 1 hour, topic "WP-358 demo"
Claude: ✅ Meeting created in Google Calendar: May 28, 15:00–16:00, "WP-358 demo", attendee Andrey.

Pilot:  create a new Work Product: "Automated deployment of agent workers"
Claude: Work Product created: WP-361 "Automated deployment of agent workers", budget 8h.
        Added to REGISTRY.md and WeekPlan W22. Need a context file with phases?

Pilot:  yes, draft Phase 1
Claude: inbox/WP-361.md created with Phase 1 IntegrationGate (~2h): SC + Role + smoke test. Commit and push?
```

All 3 requests — one Session, no tool switching.

---

## Capability scope

The Service supports the following request types without leaving Telegram:

| Type | Tool | Examples |
|-----|-----------|---------|
| **Code and Work Products** | Claude Code + git | fixes, commits, file creation, Review |
| **Calendar** | Google Calendar MCP | create / update / delete events, find free slot |
| **Work Product creation** | `create-wp.sh` | new Work Product in REGISTRY + WeekPlan + inbox + Linear |
| **IWE Knowledge** | `knowledge_search` MCP | search across Pack, CLAUDE.md, memory/ |
| **Telegram** | `send_telegram_message` | send response back to the Pilot |

Extending the scope with new MCP tools does not require changing SC.162 — only updating DP.ROLE.NNN §Capability.

---

## Implementing roles and services

| Component | Role | What it does |
|-----------|------|-----------|
| Ingress Adapter (aist-bot, cloud) | DP.ROLE.NNN §Ingress | Receive message, authorize, append to SESSION thread |
| Egress Adapter (dispatcher, local) | DP.ROLE.NNN §Egress | Detect new Work turn, launch Claude Code with full thread, return response |
| Session Memory Injector | DP.SC.161 | Pre-flight for each Work turn: inject context from iwe_memory.db |
| Agent Inbox | DP.SC.135 | Adjacent service — do NOT mix (different contract) |

---

## User path (one Work turn in a multi-turn Session)

| # | Step | Who | Result |
|---|-----|-----|----------|
| 1 | Send message to @aist_pilot_bot | Pilot | — |
| 2 | Verify `tg_chat_id ∈ allowed_list` + find active Session | Ingress Adapter | ack or "not authorized" |
| 3 | Append Work turn to `SESSION-<id>-thread.md` via GitHub API | Ingress Adapter | New Work turn in thread |
| 4 | Reply "Working…" in Telegram | Ingress Adapter | Acknowledgment ≤10s |
| 5 | git pull every 15s → new Work turn in thread detected | launchd → Egress Adapter | Work turn trigger |
| 6 | Inject Session Memory, launch Claude Code with full thread | Egress Adapter | Session active |
| 7 | Claude Code performs work (code / calendar / Work Product / IWE) | Claude Code | Work turn transcript |
| 8 | Write response to thread, send to Telegram, track activity | Egress Adapter | Response to Pilot + domain event |

---

## Session finalization (§close) — WP-358 Phase 10

> **Problem this solves:** SESSION-* files remained in `inbox/agent/sessions/` after a conversation ended. The Pilot could not find the outcome a day later (only a `session_id` hash in Telegram). Root cause — asymmetry with the `sessions/YYYY-MM-DD-*.md` rule for Peer partner sessions (DP.SC.154).

### Finalization trigger

One of:
- **Explicit:** Pilot sends `/close` in the Telegram Session
- **Implicit (TTL):** Session mtime ≥ `inactivity_close_ttl` (default 60 min of silence)
- **Cron:** Day Open detector finds `status: completed` AND age ≥ 24h → finalization flag (Egress executes in background)

### Finalization steps (Egress side)

| # | Step | Artifact |
|---|-----|----------|
| 1 | Generate topic-slug from the first meaningful line of `SESSION-<id>-thread.md` (turn:1 role:pilot, ≤60 characters, kebab-case) | `<topic-slug>` |
| 2 | Create `{{IWE_GOVERNANCE_REPO}}/sessions/external/YYYY-MM/SESSION-<id>/` | directory |
| 3 | Generate `report.md`: frontmatter (`session_id`, `date`, `topic`, `outcome`, `wp`, `turns`) + 5–10 lines of summary | `report.md` |
| 4 | `git mv inbox/agent/sessions/SESSION-<id>{.md,-thread.md}` → `sessions/external/YYYY-MM/SESSION-<id>/{session.md,thread.md}` | moved source files |
| 5 | Append a row to `sessions/external/00-index.md`: date, session_id, topic, status, link to report | updated index |
| 6 | Push to git | commit |
| 7 | Telegram: send the Pilot a link to `report.md` (not `session_id`) | message |

### report.md frontmatter (minimum)

```yaml
---
session_id: SESSION-<id>
date: YYYY-MM-DD
topic: "<one-line summary>"
outcome: consensus | abandoned | escalated | utility
wp: NNN | null              # link to Work Product if mentioned in thread
turns: N
finalized_at: ISO8601
---
```

### Post-finalization invariant

- `inbox/agent/sessions/SESSION-<id>.md` does NOT exist
- `sessions/external/YYYY-MM/SESSION-<id>/{report,session,thread}.md` exist
- Script `check-open-sessions.sh` does NOT return this Session

### Failure mode and compensation

- **Pilot does not send `/close`, TTL did not fire** → Day Open detector shows a "🔴 Unclosed sessions" section in DayPlan. Pilot decides: finalize manually or continue.
- **`git mv` fail (rebase/conflict)** → leave files in place, mark `status: completed`, retry finalization on the next `/close` or manually.
- **Backfill of 52 pre-cutover files** — NOT performed. The cutover date is hardcoded in the detector (`SESSION_CUTOVER_DATE`).

### Implementation artifacts

- Detector script: `{{IWE_GOVERNANCE_REPO}}/scripts/check-open-sessions.sh`
- Day Open Hook: `~/IWE/extensions/day-open.after.md § 7c`
- Day Close Hook: `~/IWE/extensions/day-close.checks.md § Unclosed external sessions`
- Bot Telegram response: `handlers/external_session.py` (report URL construction)

---

## Mac dependency and deployment options

| Option | Where Egress runs | Suitable for | Constraint |
|---------|----------------------|-------------|------------|
| **Mac-local (MVP)** | launchd on the Pilot's machine | Pilot at the computer | Requires Mac to be on |
| **Remote server (Pilot, Post-MVP)** | systemd on the Pilot's server (always on) | Pilot traveling without Mac | `claude -p` (headless, no VS Code Local Gateway) |
| **Per-machine (community)** | launchd/systemd on the user's machine | Each IWE user | Per-machine installation |

**Note:** the remote server option loses the Local Gateway (open files, peer coordination) — headless `claude -p` only. This is acceptable for the Pilot (full Environment is on Mac). ArchGate applies when moving to the community tier.

---

## Post-MVP (Future)

- **Eager-pull:** GitHub webhook → tailscale funnel → local HTTP endpoint. Reduces git-sync latency from avg 7.5s to <1s.
- **Remote always-on Egress** for the Pilot: systemd unit instead of launchd, no dependency on the Mac being on.
- **Voice Work turns:** Telegram voice message → STT → Work turn in thread.

---

## Distinctions

- **Session request ≠ Task (DP.SC.135):** A Task has `due/template/acceptance/result_location`, SLA ≤1h, batch. A Session is real-time with no `due` or `template`, multi-turn. Test: "Does it have `due` and `acceptance`?" No → session request. Separate folder `inbox/agent/sessions/`.
- **Session: light ≠ heavy:** light ≤200 tokens, sync SLA ≤45s. heavy >200 tokens or undefined duration, async + progress notifications.
- **Work turn ≠ Session:** A Session = the full dialogue (1..N Work turns), identified by `session_id`. A Work turn = one request+response pair, identified by `(session_id, turn_n)`.
