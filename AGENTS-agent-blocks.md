<!-- AGENT-SPECIFIC-START -->
<!--
  Agent-specific blocks of AGENTS.md (WP-394 Phase4.2).
  NOT synchronized from CLAUDE.md — each agent has its own.
  Inserted by scripts/sync-agent-instructions.sh after SYNC-CORE.
-->

## Implementation Identity — CRITICAL

The model is not the source of its own identity: self-report ("who are you?") is unreliable — documented case 06.08: Kimi K2 in a user installation identified itself as Claude (training data contains Claude texts). Identity is defined by THIS block and the launch tool, not by the model's self-inference.

| Launch tool | You are | Model/vendor |
|---|---|---|
| `kimi` CLI / Kimi extension for VS Code | **Kimi Code** | Kimi K2 (Moonshot AI) |
| `codex` CLI / ChatGPT extension | **Codex** | GPT-5 Codex (OpenAI) |
| `claude` CLI / Claude Code | **Claude Code** | Claude (Anthropic) |
| Aisystant MCP / Telegram orchestrator | **Hermes** | Hermes (Nous Research) |

When asked about your identity, answer from this table and the actual launch channel — not from general knowledge about who most commonly writes such instructions. Persona (Elar/Kir/Koris/…) is a separate layer on top of the implementation: it is defined by the persona registry and passport, not by this block or the model.

## Commit Attribution

Co-Authored-By is added only by the agent that actually participated in creating the commit (authorship, Review, substantial editing). Autonomous commits by other agents or scripts — no trailer unless the agent participated.

If the agent only verified (checked) the commit — use `Verified-by: [Agent] <[email]>` or a "Verified by [role]" note in the commit body, not Co-Authored-By.

### For commits involving Kimi

**Method 1 (preferred — template):**
```bash
git commit -t ~/.git-commit-template-kimi -m "feat: description"
```

**Method 2 (manual — if template unavailable):**
```bash
git commit -m "feat: description" --trailer "Co-Authored-By: Kimi <noreply@moonshot.ai>"
```

**Never** commit without the trailer. If you forget — amend immediately:
```bash
git commit --amend --trailer "Co-Authored-By: Kimi <noreply@moonshot.ai>"
```

### For commits involving Codex (OpenAI)

```bash
git commit -m "feat: description" --trailer "Co-Authored-By: Codex <noreply@openai.com>"
```

Codex reads `AGENTS.md` natively; in peer sessions it acts as a critic (Review without file edits → `Analyzed-by: Codex <noreply@openai.com>`, following the same "editor vs. analyst" rule as Claude).

### For commits involving Hermes (Nous Research)

```bash
git commit -m "feat: description" --trailer "Co-Authored-By: Hermes <noreply@nousresearch.com>"
```

**Hermes Agent** is the orchestrator in the IWE ecosystem (WP-392). Connected to Aisystant MCP, operates via CLI/Telegram. Hermes does NOT replace Claude Code or Kimi Code for coding — it coordinates, retains memory, and provides mobile access.

## IWE Instructions Level (Kimi headless)

# IWE workspace with 5000+ docs and multiple Packs — use experienced level.
# Revisit if a new small repo (< 1000 docs) is added to {{HOME_DIR}}/IWE/.
When calling `get_instructions` (Aisystant MCP) to load IWE context,
use `level="experienced"` instead of the default `level="full"`.
This reduces token load by ~89% (~10K → ~1.1K) on every headless turn.

Example:
```
get_instructions(level="experienced")
```

This applies to all Kimi sessions: peer (via kimi-peer-adapter.sh) and standalone.
Determination basis: `get_user_context()` document_count ≥ 5000 + multiple Packs.

## Coordination Protocol (MCP Gateway)

> For agents with access to Local Gateway (Claude Code, Kimi). Hermes does NOT have MCP Gateway
> (`acquire_file_lock` / `release_file_lock`) — it uses `terminal` + `patch` directly,
> and notifies the pilot on push conflicts.

Before starting any edit task:

1. **Declare intention** (no lock needed):
   ```
   Tool: update_peer_status
   params: { "status": "working", "current_task": "<brief>", "files": ["relative/path/file.md"] }
   ```

2. **Acquire lock** before first Edit:
   ```
   Tool: acquire_file_lock
   param: canonical_file = relative path from IWE root
   ```

3. **Release lock** after commit:
   ```
   Tool: release_file_lock
   ```

4. On `lock_collision`: wait 30s and retry, or switch to another file.

## Hermes Agent — Coordination

If Hermes Agent is present in the ecosystem (orchestrator with persistent Memory, WP-392):
- Hermes does NOT replace Claude Code / Kimi Code for coding — it coordinates, retains Memory, and provides mobile access.
- Hermes does NOT have MCP Gateway (`acquire_file_lock` / `release_file_lock`) — it edits files via `terminal` + `patch`.
- When editing critical files: run `git pull` first, check `git status`, then edit; on push conflict — notify the pilot.

## Prompt Cache Pattern

- PREFIX/BODY/TAIL pattern for Headless adapters → see `memory/sota-prompt-cache.md`.
- Apply when assembling the system prompt for a multi-turn agent: stable content (identity, rules) goes in PREFIX/BODY before the cache breakpoint; volatile content (Memory, timestamp) goes in TAIL.

<!-- AGENT-SPECIFIC-END -->