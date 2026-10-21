---
created: 2026-05-27
id: DP.ROLE.NNN
layer: L4-Platform
name: External Session Adapter
name_en: External Session Adapter
name_ru: External Session Adapter
owner_role: R14 Client (pilot) — as consumer; DP.ROLE.045 Dispatcher — as adjacent
  role in inbox
related:
  realizes: DP.SC.NNN
  see_also:
  - DP.ROLE.045
  - DP.ROLE.059
  uses:
  - DP.SC.135
  - DP.SC.161
status: draft
summary: 'Bridge between an external channel (Telegram) and a local executor (Claude
  Code). Supports multi-turn dialog: each turn is appended to the SESSION thread,
  and Egress launches Claude Code with the full context. Capability scope: code+git,
  calendar, Work Product, IWE knowledge. Two sub-responsibilities: Ingress (cloud)
  and Egress (local).'
type: role
updated: 2026-05-27
wp: WP-358
---

# [DP.ROLE.NNN] External Session Adapter

## Purpose

Bridge between an external channel (Telegram) and a local executor (Claude Code).

**Key principles:**
- Does not execute the task — only routes Session turns between channels
- Supports multi-turn: accumulates a thread and passes the full context to each turn
- Distributed Role: two deployment endpoints with separate auth boundaries
- Single logical owner — both endpoints implement the contract DP.SC.NNN

---

## Sub-responsibilities

### Ingress Adapter (cloud-side, `aist-bot`)

**Who:** a component of the Telegram bot (@aist_pilot_bot), deployed in the cloud.

**Responsibilities (first turn — Session opening):**
1. Accept the first message `/claude [--private] <text>` from an authorized chat
2. Authorize: `tg_chat_id ∈ allowed_list` (config-based, MVP)
3. Create `inbox/agent/sessions/SESSION-<id>.md` via the GitHub API with frontmatter:
   - `session_id`, `tg_chat_id`, `created_at`, `private`, `status: active`
4. Write the first turn to `SESSION-<id>-thread.md`:
   ```
   [turn:1, tg_msg_id:<N>, ts:<ISO>] Pilot: <text>
   ```
5. Send acknowledgment "Working…" to Telegram within ≤10 s

**Responsibilities (subsequent turns):**
1. Find the active Session by `tg_chat_id` in the SQLite Ingress store (or via GitHub API lookup)
2. Check idempotency: `(tg_chat_id, message_id)` — do not process the same message twice
3. Append the turn to `SESSION-<id>-thread.md` via the GitHub API
4. Send "Working…" within ≤10 s

**Responsibilities (closing):**
- `/close` from the pilot → update `SESSION-<id>.md`: `status: closed`

**Permissions:** read `allowed_list`, GitHub API read/write on `inbox/agent/sessions/`, `send_telegram_message`.

**Does NOT:** launch the Session or wait for a result.

---

### Egress Adapter (local-side, `iwe-agent-dispatcher.py --mode session`)

**Who:** an extension of `iwe-agent-dispatcher.py`, deployed on the pilot's machine (or a remote server).

**Responsibilities (on each new turn):**
1. Detect a new turn in the thread (launchd/systemd poll every 15 s via `git pull`)
2. Check: has this `turn_n` already been processed in SQLite (`~/.iwe/sessions.db`)? → skip
3. Call the Session Memory Injector (DP.SC.161) for pre-flight context enrichment
4. Launch `claude -p` with the full `SESSION-<id>-thread.md` plus capability instructions as stdin
5. Heartbeat self-check: ping SQLite every 30 s; miss >90 s → `failed` + Telegram alert
6. Receive the Claude Code response (stdout)
7. Append the response to the thread: `[turn:N+1-response, ts:<ISO>] Claude: <response>`
8. Record a Domain Event (activity tracking): `activity_log` + WakaTime heartbeat
9. Send the response to Telegram via `send_telegram_message`
10. Update `SESSION-<id>.md`: `last_turn_at`, `turn_count`, status

**Permissions:** read/write `inbox/agent/sessions/`, read/write `~/.iwe/sessions.db`, run `claude -p` CLI, use `send_telegram_message`, access to capability tools (calendar MCP, `create-wp.sh`, `knowledge_search`).

**Does NOT:** choose the response content — that is Claude Code's responsibility.

---

## Capability scope

Egress grants Claude Code access to the following tools:

| Capability | Tool | Example requests |
|-----------|------|-----------------|
| Code + git | Claude Code native | fixes, commits, file creation |
| Calendar | Google Calendar MCP | "schedule a meeting with Andrew tomorrow at 15:00" |
| Work Product creation | `create-wp.sh` | "create a new Work Product: ..." |
| IWE knowledge | `knowledge_search` MCP | "find information in IWE about ..." |
| Telegram | `send_telegram_message` | return response to the pilot |

To extend the scope: add the capability to this section and pass the tool to the `--mode session` dispatcher Configuration.

---

## Deployment options for Egress

| Option | Where | Trigger | Constraint |
|--------|-------|---------|-----------|
| **Mac-local (MVP)** | Pilot's machine | launchd plist | Requires Mac to be on + VS Code running |
| **Remote server (pilot, Post-MVP)** | Pilot's Linux server (always on) | systemd unit | Headless `claude -p`, no Local Gateway |
| **Per-machine (community)** | User's machine | launchd/systemd | Per-machine installation |

Note: the remote server loses the Local Gateway (open files, peer coordination) — only `claude -p` is available. For the pilot, this is a trade-off for "on the road without a Mac." ArchGate applies when the community tier is introduced.

---

## Role invariants

1. **Idempotency via composite key.** `(tg_chat_id, message_id)` is checked before writing a turn (Ingress) and before starting processing (Egress). A repeated request with the same key is a no-op and returns the current status.

2. **Atomicity of acknowledgment.** Ingress does NOT return a response before the turn is written to the thread. If the GitHub API is down → the user receives "Could not accept turn", not an acknowledgment.

3. **Heartbeat ≠ session signal.** The Egress heartbeat is a dispatcher self-healthcheck (SQLite ping), not a signal from an active Session. A long-running heavy request must not falsely trigger `failed` due to the absence of activity.

4. **Private audit trail.** For `--private` Sessions: the thread file is stored ONLY in `~/.iwe/sessions.db` (never in git). The SESSION file contains only metadata.

5. **Graceful degradation.** If VS Code or `claude -p` fails to start → Egress records a timeout → Telegram "Environment not running." Silent failure is prohibited.

6. **Activity tracking.** Each processed turn writes a Domain Event `external_session_turn` to `activity_log` and a WakaTime heartbeat. Skipping tracking is a violation of this invariant.

---

## Scaling (Multi-pilot future, Q4 WP-358)

| Component | MVP | Multi-pilot |
|-----------|-----|------------|
| Ingress Adapter | single instance (one pilot) | horizontal scaling (cloud stateless) |
| Egress Adapter | bound to the pilot's machine | per-pilot instance (Mac/Linux) |
| SESSION files | single Repository | per-pilot namespace or multi-tenant repo |
| Authorization | tg_chat_id allowlist | Ory OAuth2 (post-MVP, ArchGate) |

---

## Distinction from DP.ROLE.045 (Dispatcher)

| Aspect | DP.ROLE.045 Dispatcher | DP.ROLE.NNN Adapter |
|--------|----------------------|---------------------|
| Entry contract | Task with `due/template/acceptance` | Session thread (real-time, multi-turn) |
| Folder | `inbox/agent/tasks/` | `inbox/agent/sessions/` |
| SLA | ≤1 h (batch) | acknowledgment ≤10 s per turn |
| Capability | executes task from a Template | full capability scope (calendar, Work Product, IWE) |
| Failure mode | retry with exponential backoff | Telegram alert + graceful fail |
| Trigger | cron/systemd | launchd/systemd poll every 15 s |
| Deployment | headless, no VS Code | primary: VS Code; fallback: headless on remote server |

---

## Kind and Owner

- **Kind:** Bridge Role (connects two runtimes — cloud and local; accumulates multi-turn state)
- **Owner Role in the Supersystem:** Customer (R14) as the Service consumer; Infrastructure as operator
