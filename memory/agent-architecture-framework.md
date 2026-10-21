---
description: 'Three-layer IWE Architecture: LLM / Agent / Role; Universal vs Specialized;
  Two Catalogs'
metadata:
  domains:
  - agent-architecture
  - iwe
  - roles
  horizon: warm
  modified: 2026-07-29 02:49:31.552000+00:00
  node_type: memory
  originSessionId: ae25144c-e026-495c-b6d0-616278d5d8b7
  owner: platform
  schema_version: 1
  status: active
  type: reference
  valid_from: 2026-05-25
name: agent-architecture-framework
---

# IWE Agent Architecture: LLM / Agent / Role

> WP-350/WP-336, May 25 2026. Short distinctions → [[distinctions.md]] (AUTHOR-ONLY).

## Three Layers

| Layer | What it is | Examples |
|-------|-----------|---------|
| **LLM** | Language model — the reasoning "core." Not an agent by itself. | Claude (Haiku/Sonnet/Opus), Nous Hermes, GPT-4, Mistral |
| **Agent** | System = {LLM, Tools, Prompt, Persona (Memory), Context}. A specialization of "System" in FPF A.2.1 notation. | Claude Code, Kimi Code, session-memory-injector, overnight-reviewer |
| **Agent-in-Role** | An agent performing a specific Role in a specific context. Role = Functional Position (what to do, permissions, domain, I/O). Notation: `agent#role:context` | `claude-code#strategist:IWE`, `session-memory-injector#session-memory-injector:day-open` |

> **Link to HD #27 (DP.D.052):** Persona is the persistent part (who the agent is, its Profile), Memory is accumulated Experience, Context is the current Session. All three are part of the agent.

**Naming a specialized agent:** if an agent performs one Role and is constrained to its domain → the agent name equals the role name (`session-memory-injector`, `overnight-reviewer`). A universal agent (Claude Code, Kimi Code) plays different Roles → its name does not match any single role name.

## Two Agent Types

### Universal Agent
- Can play **many Roles** — assignment is situational
- Broad context, high trust level
- Not bound to a single domain
- Examples: **Claude Code** (Sonnet/Opus), **Kimi Code** (long context)

### Specialized Agent
- **One agent = one Role** (the binding is architectural, not situational)
- The internal LLM core is **replaceable** (Haiku → Hermes → GPT → …)
- Domain is constrained, permissions are narrow

| Agent | Role | Current LLM | Domain |
|-------|------|-------------|--------|
| session-memory-injector | Session Memory Injector (TBD DP.ROLE.NNN) | Claude Haiku | agent Memory fault profile |
| overnight-reviewer | Code Reviewer | Claude Sonnet | code quality |
| overnight-tester | QA Tester | Claude Sonnet | tests / smoke |
| overnight-critic | Critic | Claude Sonnet | Artifact Verification |
| idea-scout | Idea Researcher | Claude Sonnet | source / idea search |

## Role Types (DP.D.080)

| Type | What it does | Examples |
|------|-------------|---------|
| **Operational** | Modifies system state; idempotent; no external recipient | Strategist R1, Decomposer |
| **Control** | Observes + reports; read-only access to audited Artifacts; has an explicit recipient | Verifier R23–R26, Auditor R24 |
| **Coordination** | Routes / dispatches; knows names, not data | Router R30 (DP.ROLE.059), Dispatcher (DP.ROLE.045), Orchestrator R22 |

## Two Catalogs

### Platform Agent Catalog (WP-336, Andrey)
- **Level:** aisystant Platform (cloud)
- **Infrastructure:** HTTPS + OAuth Ory, Cloud Gateway, Parliament model
- **Consumers:** multi-tenant, Platform pilots
- **Status:** being designed as a separate initiative (WP-336)
- Includes: platform Roles — Diagnostician R28, Navigator R27, Tailor, Attestor, Verifiers R23–R26, Gamifier R34, Orchestrator R22, and others

### IWE executor-catalog (WP-350 Phase 8)
- **Level:** IWE in VS Code (pilot-developer)
- **Infrastructure:** Local Gateway (DP.IWE.005), AGENTS.md, file-lock
- **Consumers:** Router DP.ROLE.059, pilot via `/route-task`
- **Status:** not yet created → to be implemented in Phase 8 of WP-350
- File: `executor-catalog.yaml` (field `can_play_roles` per agent)
- Includes: IWE agents + Scripts + MCP tools

## Adding a New Agent (Nous Hermes, Other LLM)

1. Choose a runtime Infrastructure: Ollama (local) / Together AI API / Groq API
2. Write an adapter Script modeled on `kimi-peer-adapter.sh` — headless call + AGENTS.md
3. Register in `executor-catalog.yaml` (Phase 8 WP-350)
4. The agent must support the IWE Protocol: read AGENTS.md, commit with attribution, respect file-lock

**Important:** Hermes model (Nous Research) = LLM core, not an agent. OpenClaw = a separate Platform (247k stars), not a tool inside IWE.

## IWE Core + Agent Interfaces: Shared vs Own

All agents (Claude, Kimi, Hermes, user's agent) connect to the single IWE core (aisystant MCP) and draw from it the ESSENCE — orientation, Knowledge, pilot context, authoritative Memory. One question through any Interface → one answer in essence (see "essence ≠ Interface," DP.D.156).

| What | Where it lives | Shared or own |
|------|---------------|---------------|
| Orientation, Knowledge, authoritative facts | Core (aisystant MCP) | SHARED across all agents |
| Current dialogue context | Local to each agent | OWN (normal) |
| Tools, style | Each agent | OWN |
| Built-in autonomous Memory (dialogues, Skills, self-evolution) | Hermes only (its runtime) | OWN — but not the source of truth |

**Boundary (DP.D.156):** what the core reproduces without the agent = Interface; what exists only inside the agent = a violation. Facts from Hermes's built-in Memory flow into the core through a capture-with-approval step — Hermes proposes, the extractor/pilot approves.

**Connecting a user's agent:** the core is assistant-agnostic ("Platform ≠ IWE assistant") — any agent accessing via MCP receives the essence within the user's permissions and tier.

## Switching Extension Agents Inside VS Code (WP-499 Phase 9, 29.07)

**Difference from the sections above:** those sections cover "which CLI agent writes code in the terminal" (transport: file-lock + git). This section covers "which extension to use inside the IDE itself" (transport: VS Code UI panel). These are two different transports — do not confuse them.

**Actually installed extension agents (verified via `~/.vscode/extensions/`, not from memory):**

| Extension (id) | displayName in Manifest | Default hotkey |
|---|---|---|
| `anthropic.claude-code` | Claude Code for VS Code | `cmd+escape` (focus/open) |
| `moonshot-ai.kimi-code` | Kimi Code | `ctrl+shift+k` (focus input), `alt+k` (insert file mention) |
| `openai.chatgpt` | **Codex – OpenAI's coding agent** (id is historical; displayName is now "Codex") | no default hotkey assigned for opening the panel |
| `saoudrizwan.claude-dev` | Cline | `cmd+'` (focus chat) |

**Finding — hotkey conflict:** `alt+k` is assigned simultaneously by Claude Code (`claude-vscode.insertAtMention`) and Kimi Code (`kimi.insertMention`). When both extensions are installed, VS Code resolves the conflict by its own priority rules (typically the last activated extension, or an explicit override in `keybindings.json`) — not both fire at once. This is not a blocker (every extension has a Command Palette fallback), but it is worth knowing when a pilot reports "the wrong panel opened."

**Standard switching mechanism (VS Code, nothing new required):**
1. **Command Palette** (`cmd+shift+p`) → type the agent name (`Claude Code:`, `Kimi Code:`, `Codex`, `Cline:`) → all extension commands appear unambiguously; no conflicts (unlike keybindings).
2. **Activity Bar** — each extension has its own sidebar icon; clicking it switches the panel. All three or four panels can be open simultaneously in separate tabs or side panels.
3. **VS Code Profiles** (`Profiles` in the lower-left corner) — the standard way to keep different sets of extensions active for different tasks. Not required for "one button – one agent" (all four extensions are compatible simultaneously; profile isolation is not needed by default).

**Conclusion:** the standard VS Code mechanism is sufficient; no new tooling is needed. The only practical recommendation for pilots: when confused, use the Command Palette instead of hotkeys to avoid the `alt+k` conflict.
