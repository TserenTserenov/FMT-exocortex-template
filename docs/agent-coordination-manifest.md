---
created: 2026-05-27
description: Agent coordination rules for preventing scheduling races and dirty repos
source: peer-session 2026-05-27-02-bot-error-analysis
title: Agent Coordination Manifest
version: 1
---

# Agent Coordination Manifest

## 1. Problem

Multiple autonomous agents (overnight-auditor, synchronizer, setup-agent, code-scanner, pull-repos) write to the same git repository working copies during the nightly window (00:00–02:00 UTC). This causes:
- Scheduling race → dirty repos → pull-repos warnings
- Template-sync rc=1 (cannot pull with rebase)
- DB pool contention → latency spike (>45 s on /feed)
- Duplicate code-scan runs (no debounce)

## 2. Principle: single lock arbiter

**Local MCP Gateway** is the single coordination point for all agents.
- MCP agents use `acquire_file_lock` / `release_file_lock` via tools.
- Shell scripts use JSON-RPC over Unix socket (`~/.iwe/gateway.sock`) via `nc -U`.
- Lock key: symbolic `repo:<canonical-name>` implemented as a file anchor `<repo-path>/.git/index`.

### 2.1 Shell helper

```bash
GATEWAY_SOCKET="${IWE_GATEWAY_SOCKET:-$HOME/.iwe/gateway.sock}"
REPO_LOCK_FILE="$HOME/IWE/<REPO>/.git/index"

_gateway_lock_acquire() {
    local file="${1:-$REPO_LOCK_FILE}"
    local ttl="${2:-300}"
    local resp
    resp=$(printf '%s' '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"acquire_file_lock","arguments":{"file":"'$file'","ttl_seconds":'$ttl'"}}}' | nc -U "$GATEWAY_SOCKET" 2>/dev/null)
    echo "$resp" | grep -q '"ok": true'
}

_gateway_lock_release() {
    local file="${1:-$REPO_LOCK_FILE}"
    printf '%s' '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"release_file_lock","arguments":{"file":"'$file'"}}}' | nc -U "$GATEWAY_SOCKET" 2>/dev/null >/dev/null
}

# Required trap
trap '_gateway_lock_release "$REPO_LOCK_FILE" 2>/dev/null || true' EXIT ERR
```

### 2.2 TTL rules

| Agent | TTL | Note |
|---|---|---|
| code-scan | 300 s | Short operation |
| template-sync | 300 s | With retry support |
| pull-repos | 300 s | Sequential per repo |
| overnight-auditor | 1800 s | Long Audit — consider splitting per repo |
| synchronizer inbox-check | 300 s | + janitor commits in batches |

**Requirement:** if a lock with TTL > 600 s is held longer than `expected_duration + 60 s`, alert the pilot.

## 3. Artifact separation

Where agents write determines git status and race risk.

| Artifact type | Location | Git | Commit policy |
|---|---|---|---|
| KE input (extraction-reports, captures) | `inbox/auto/` | tracked | Batch commit on human review (apply-captures) |
| Read-only (audit reports, dashboards) | `output/` + `.gitignore` | ignored | Not committed |
| Intermediate (stash, build, temp) | `/tmp/` or `.tmp/` | ignored | Deleted after operation |
| Agent logs | `logs/` + `.gitignore` | ignored | Rotation by size |

**janitor** is a full participant in the lock Protocol: it acquires a lock before each batch commit.

## 4. Cron spread (nightly window)

| UTC | Agent | Repo/resource |
|---|---|---|
| 00:00 | pull-repos + code-scan | All repos |
| 00:30 | template-sync | FMT-exocortex-template |
| 01:00 | overnight-auditor | Local repos (security scan) |
| 02:00 | synchronizer inbox-check | DS-agent-workspace inbox |
| 02:30 | apply-captures janitor | {{GOVERNANCE_REPO}} inbox/auto/ |

Minimum gap: 30 minutes between operations on the same repo.

## 5. Circuit breaker (bot)

For heavy commands (`/feed`, `/train`, `/setup_mode_sequential`):

```python
_HEAVY_SOFT_TIMEOUT = 3.0   # respond to user: "Updating data..."
_HEAVY_HARD_TIMEOUT = 30.0  # abort + log error
```

Implementation: `handlers/commands.py::_safe_route_heavy()`
- `asyncio.wait_for(route_coro, 3.0)` → TimeoutError → answer("Updating...")
- background task → `asyncio.wait_for(task, 27.0)` → TimeoutError → log `heavy_timeout:<command>`
- Telegram retry is suppressed: the user has received a response, no repeat request is needed.

## 6. Degraded mode

If the Gateway is unavailable (socket missing, daemon not running):
- Shell scripts: `flock -n` on the repo anchor (`<repo>/.git/index`) as fallback.
- MCP agents: `Bash(flock ...)` via tool.
- Log: `WARN: gateway unreachable, using flock fallback`.

## 7. Checklist for adding a new agent

Checklist before introducing an agent into the nightly window:
1. [ ] Agent acquires a Gateway lock before writing to a repo.
2. [ ] Agent writes only to permitted directories (§3).
3. [ ] Agent has trap/release on abnormal termination.
4. [ ] Cron time is aligned with the §4 table (no overlap on the same repo).
5. [ ] Operation duration is less than the lock TTL.

## 8. Related documents

- `memory/protocol-work.md` — general agent work rules
- `docs/SCRIPT-PROMOTION.md` — how scripts are added to the repo
- `docs/adr/` — architectural decisions on coordination

