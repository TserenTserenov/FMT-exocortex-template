# IWE Portability

> Read this file if: you are not on macOS, you are not using Claude Code,
> or you want to understand whether you need to change a specific section of the instructions.

---

## Quick Answer: Look at the Layer

IWE is divided into three layers. The layer determines how tightly a rule is bound to a platform:

| Layer | Where | Platform Dependency |
|-------|-------|---------------------|
| **L1** — Platform | CLAUDE.md §1–7, `.claude/hooks/`, `.claude/skills/` | **Bound to Claude Code and macOS** |
| **L2** — Staging | CLAUDE.md §8 | Partially specific |
| **L3** — Personal | `extensions/`, `params.yaml`, CLAUDE.md §9 | **Universal — your logic** |

**Rule:** when you encounter an instruction, check which layer it lives in. L3 does not require changes. L1 requires changes when you switch platforms.

---

## Kimi Code (VS Code)

**Works out of the box — no additional configuration required.**

1. Install the Kimi Code extension in VS Code.
2. Open the forked repository — Kimi automatically picks up `AGENTS.md` from the root.
3. Work as usual: Kimi reads all instructions from `AGENTS.md`.

**Customization for Kimi:** place your instructions in `extensions/` or in `AGENTS-agent-blocks.md`. They will appear in `AGENTS.md` after running `bash scripts/sync-agent-instructions.sh`. Do not edit `AGENTS.md` manually — it will be overwritten.

**What does not work through Kimi:** Skills (`/day-open`, `/ke`, `/archgate`) and Hooks — these are Claude Code CLI mechanisms. Claude Code is required for them.

---

## Hermes Agent

Two ways to connect Aisystant MCP — choose whichever is convenient:

**Option A — via Interface:**
1. Settings → MCP Servers → Add → Aisystant.
2. Sign in through Ory (a browser window will open).

**Option B — via CLI:**
```bash
hermes mcp login aisystant
```
If an OAuth error appears, run `hermes mcp update aisystant` or check `hermes --help mcp`.

After connecting, Hermes automatically receives instructions through the `get_instructions` tool.

**Important:** Hermes does not read Repository files directly (unlike Claude Code and Kimi Code). It receives all instructions through MCP, not from `CLAUDE.md` or `AGENTS.md`.

---

## What Depends on Claude Code

If you use Cursor, Copilot, Gemini, or another assistant (not Kimi and not Hermes) — the following L1 Components require replacement or adaptation:

- **CLAUDE.md format** — read by Claude Code at startup. Kimi reads `AGENTS.md` (already in the Template). Other assistants use different formats (`.cursorrules`, system prompt, etc.)
- **`.claude/hooks/`** — events (pre-commit, post-tool) — Claude Code CLI mechanism
- **Skills and slash commands** (`/day-open`, `/ke`, `/archgate`) — work only inside Claude Code
- **MCP servers** — Hermes supports them. Other assistants — depends on implementation.
- **Model selection** (Opus / Sonnet / Haiku) — Anthropic API specific

**What transfers without changes:** Opening/Work/Closing Protocols as Concepts, Pack/DS/Base Architecture, memory and capture logic, everything in `extensions/` and `params.yaml`.

---

## What Depends on macOS

If you are on Linux or Windows (WSL) — the following L1 Components require replacement:

| Component | macOS | Linux / WSL |
|-----------|-------|-------------|
| Automation timers | `launchd` + `.plist` | `systemd` timer or `cron` |
| Laptop wake | `pmset repeat wakeorpoweron` | `rtcwake` / `WakeSystem=true` |
| `/transcribe` transcription | MLX Whisper (Apple Silicon) | Model replacement required |
| Paths | `~/Library/LaunchAgents`, Homebrew paths | Standard Linux paths |

`setup.sh` detects the OS automatically and skips macOS steps on Linux. Technical details for contributors: [PLATFORM-COMPAT.md](PLATFORM-COMPAT.md).

---

## What Is Universal (Do Not Change)

Regardless of platform and AI assistant — the following works without changes:

- **Opening/Work/Closing fractal** (Opening → Work → Closing) — a Principle, not a tool
- **Pack / DS / Base Architecture** — Knowledge organization in files
- **Memory and Capture** — Knowledge capture logic
- **Protocols** (Day Open, Week Close, Strategy Session) — as Concepts
- **All of L3:** `extensions/`, `params.yaml`, personal Distinctions

---

## How to Adapt to Another Platform

1. Transfer L3 (`extensions/`, `params.yaml`) without changes — this is your logic
2. Rewrite L1 for the new assistant's format (system prompt, `.cursorrules`, etc.)
3. Protocol Concepts (Opening/Work/Closing, Pack, capture) — describe them in the new format: they are platform-neutral

---

## Adding Support for a New Agent

> For developers who want to integrate an agent not yet listed here.

IWE is not bound to a specific LLM or agent. Any agent that satisfies the minimum Host contract will work with IWE without changes to Pack, Protocols, or L3.

### Minimum Host Contract

| Requirement | Why | Level |
|---|---|---|
| Reads an instructions file from the project | CLAUDE.md / AGENTS.md / system prompt | **Required** |
| Tool use: edits files, runs commands | code edits, Protocol scripts | **Required** |
| MCP support | Aisystant cloud: Knowledge, Persona, Digital Twin | Optional |
| Headless / CLI mode | automations (cron, Hooks) | Optional |

Without MCP, the agent operates autonomously — only the cloud Knowledge layer is lost.
Without headless mode — manual launch instead of a schedule.

### How to Add an Adapter

1. **Create an instructions file** — an adapter for the agent to read. Examples:
   - Claude Code reads `CLAUDE.md`
   - Kimi Code reads `AGENTS.md` (generated from CLAUDE.md by the `sync-agent-instructions.sh` Script)
   - Hermes receives instructions through MCP `get_instructions`
   - Cursor — `.cursorrules`, Copilot — system prompt via `.github/copilot-instructions.md`

2. **Add the agent to `setup.sh`** — include the CLI command name in `AI_CLI_CANDIDATES` (via env or hardcoded in the Script).

3. **Document it** — add a section to this file (PORTABILITY.md) following the pattern of the Kimi Code and Hermes Agent sections above.

4. **Pull requests are welcome** — if you want to add an agent for all IWE users.

---

*Last updated: 2026-06-04*