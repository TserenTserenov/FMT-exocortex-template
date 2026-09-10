# IWE: Bot Reference

> Quick reference for Intellectual Work Environment (IWE) — for bot search and responses.
> Full installation guide: [SETUP-GUIDE.md](SETUP-GUIDE.md)
> Not on macOS or not using Claude Code? → **[PORTABILITY.md](PORTABILITY.md)**
>
> **Source-of-truth:** Platform Pack entities (available via Gateway `iwe-knowledge`):
> - `DP.IWE.001` — what IWE is, why it exists, Architecture
> - `DP.IWE.002` — Template and installation, prerequisites, FAQ, security
> - `DP.EXOCORTEX.001` — exocortex Architecture (3 layers, Modules)
> - `DP.ARCH.002` — tiers T0-T4 + TM1-TM3 + TA1-TA4 + TD1
> - `DP.ROLE.001` — AI Role Registry

---

## What IWE Is

IWE (Intellectual Work Environment) is an intellectual work Environment. It is described through five views (FPF A.7: **Role → Method → Work Product**):

| View | What | Examples |
|------|------|---------|
| **Systems** | Programs with 4D boundaries | Claude Code, Telegram bot, MCP servers, WakaTime, Git, exocortex (files), Neon DB |
| **Descriptions** | Knowledge loaded into systems | FPF/SPF/ZP, Pack entities, Role prompts, exocortex contents |
| **Roles** | Function, not Performer | Strategist (R1) ← Claude, Extractor (R2), Synchronizer (R8), User ← Human |
| **Methods** | "How to do it" procedures | OWC Protocol, Capture-to-Pack, ArchGate, KE, Note-Review |
| **Work Products** | What gets produced | DS-strategy, Pack documents, DS-projects, digital twin events |

Full architectural model: [LEARNING-PATH.md § 1.2](LEARNING-PATH.md). Source-of-truth: `DP.IWE.001` (via Gateway: `knowledge_search("IWE architecture")`).

---

## Installation Requirements

### Required
- macOS, Linux, or Windows (via Git Bash — WSL is not required; not verified on real Windows hardware, see [SETUP-GUIDE.md § Windows](SETUP-GUIDE.md#00-windows-without-wsl))
- Git + GitHub account + GitHub CLI (`gh`)
- Node.js v18+ and npm
- Claude Code CLI (`npm install -g @anthropic-ai/claude-code`)
- Anthropic subscription: **Claude Pro** ($20/month) — recommended to start. If needed — **Claude Max** (~$100/month) for unlimited message usage.

### Optional
- VS Code (recommended) or any other editor with a terminal. Claude Code is a CLI tool and works in any terminal (Terminal.app, iTerm2, etc.). VS Code is convenient: editor + terminal + Claude Code extension in one window.
- Telegram (@aist_me_bot) — for notes
- WakaTime — work time tracking

---

## How to Install IWE

**Installation time: 30–60 minutes** (depends on terminal Experience).

Full step-by-step guide (including how to open a terminal, install all dependencies, and what to do when something goes wrong): **[SETUP-GUIDE.md](SETUP-GUIDE.md)**

Installation results:
- A fork of the exocortex Template in your GitHub
- CLAUDE.md and memory/ — configured for you
- Strategist (AI agent) — running on automatic schedule
- DS-strategy — private Repository for planning

---

## Knowledge Access (MCP)

MCP (Model Context Protocol) is the Protocol through which Claude Code connects to the Platform knowledge base. A single Gateway server aggregates all backends:

| Server | What it provides | Tools |
|--------|-----------------|-------|
| **iwe-knowledge** (Gateway: `mcp.aisystant.com/mcp`) | Search across Pack repos, guides, DS (~5400 documents) + digital twin | `knowledge_search`, `knowledge_get_document`, `knowledge_list_sources`, `dt_read_digital_twin`, `dt_write_digital_twin`, `dt_describe_by_path` |

> Search guides: `knowledge_search("query", source_type="guides")`.

MCP connects via https://claude.ai/settings/connectors (see SETUP-GUIDE §1.3b). To verify: run `/mcp` in Claude Code → servers show Connected. Ask "Find documents about principles" — Claude will use `knowledge_search`.

---

## Three Roles in IWE

> The exocortex Template includes **3 Roles** available immediately: Strategist, Extractor, Synchronizer. The Platform supports 21 Roles — they are activated as the system develops.
> Full Role Registry: `DP.ROLE.001` (via Gateway: `knowledge_search("agent role registry")`).

### Strategist (R1)
Planning and reflection. Every morning (Tue–Sun) it generates a day plan from yesterday's commits. Monday is preparation for the weekly Session. In the evening (23:00) it processes notes from Telegram.

Manual launch (in a terminal or the VS Code integrated terminal):
```bash
bash ~/IWE/FMT-exocortex-template/roles/strategist/scripts/strategist.sh day-plan
```

### Extractor (R2)
Knowledge extraction into Pack Repositories. Four scenarios: session-close (when closing a Session), on-demand (on request), inbox-check (every 3 hours), knowledge-audit (completeness Audit).

Always proposes, never writes without approval (human-in-the-loop).

Installation (in a terminal): `bash ~/IWE/FMT-exocortex-template/roles/extractor/install.sh`

### Synchronizer (R8)
Central dispatcher (bash, not AI). Manages the schedule for all Roles, sends Telegram notifications, performs a nightly code review.

Installation (in a terminal): `bash ~/IWE/FMT-exocortex-template/roles/synchronizer/install.sh`

---

## OWC Protocol (Daily Work)

Every Session in Claude Code has three stages:

**Opening.** You give a task → Claude checks WP Gate (is it in the week plan?). If not — it proposes adding it. It announces the Role, Method, and estimate.

**Work.** Claude executes the task. At Work milestones it captures Knowledge: "Capture: [what] → [where]".

**Closing.** Say "close" → Claude commits, pushes, updates Memory, creates a Backup.

---

## Memory (3 Layers)

| Layer | File | When loaded |
|-------|------|-------------|
| Working | `memory/MEMORY.md` | Always (auto-context) |
| Rules | `CLAUDE.md` | Always (auto-context) |
| Reference | `memory/*.md` | On request |

MEMORY.md — personal (current tasks, weekly Work Products). Edited every Session.
`DS-strategy/docs/WP-REGISTRY.md` — full Registry of all Work Products from most recent to first (DP.WP.015). Updated on Close when status changes.
All other memory/*.md files — Platform files. Updated from upstream via `update.sh`.

---

## Updating IWE

```bash
cd ~/IWE/FMT-exocortex-template
bash update.sh          # update
bash update.sh --check  # check without applying
```

For GitHub requests, the updater first uses a non-empty `GH_TOKEN`, then `GITHUB_TOKEN`, then an authorized `gh`, and only falls back to anonymous `curl` when no explicit authorization is present. An error from an explicit token or `gh` stops the update without falling back to anonymous access; the token value is not passed as a process argument and is not printed in the trace. For token-based requests, `CURL_OPTS` accepts only `--insecure` and numeric timeout/retry parameters; verbose tracing, additional headers, Configuration files, and output files are blocked before the network request; the user's `.curlrc` is disabled for such requests.

Updated: CLAUDE.md, memory/ (except MEMORY.md), Role prompts, Scripts.
NOT touched: MEMORY.md, DS-strategy/, routing.md, personal settings.

---

## Telegram Notes

The @aist_me_bot bot accepts notes:
- `.Note text` (period + text)
- `.` + reply to or forward of a message

Notes go to `DS-strategy/inbox/fleeting-notes.md`. The Strategist processes them in the evening (Note-Review).

---

## Common Issues

**Claude Code does not start** — check your Anthropic subscription and run `claude --version`. You can start with the Pro plan ($20/month). If needed — Max (~$100/month).

**Strategist does not generate a plan** — macOS: `launchctl list | grep strategist`. Linux: `systemctl --user list-timers | grep strategist`. If absent — run `bash roles/strategist/install.sh`.

**MEMORY.md does not load** — check the path: `~/.claude/projects/-Users-<username>-IWE/memory/MEMORY.md`. The directory name equals the workspace path with hyphens.

**DS-strategy not created** — create manually: `mkdir -p ~/IWE/DS-strategy/{current,inbox,docs,archive} && cd ~/IWE/DS-strategy && git init`.

**Notes are not arriving from Telegram** — check your subscription in @aist_me_bot. Format: period + text (`.My note`).

**MCP is not working (Claude does not search the knowledge base)** — check the connection: `/mcp` in Claude Code. Servers must show Connected. If they are missing — add them via https://claude.ai/settings/connectors (see SETUP-GUIDE §1.3b).

**How to configure Telegram notifications** — create `~/.config/aist/env`:
```bash
export TELEGRAM_BOT_TOKEN="your-token"
export TELEGRAM_CHAT_ID="your-id"
```

---

## Glossary

| Term | Meaning |
|------|---------|
| IWE | Intellectual Work Environment |
| Exocortex | IWE Memory Subsystem (CLAUDE.md + MEMORY.md + memory/) |
| Pack | Domain knowledge base (source-of-truth for a Domain) |
| DS-strategy | Personal strategic hub (private Repository) |
| WP Gate | Check: is the task in the week plan? |
| OWC | Opening → Work → Closing (three Session stages) |
| Capture | Capturing Knowledge during work |
| Platform-space | Standard files, updated from upstream |
| User-space | Personal files, never overwritten |
| Routing | Knowledge routing table (where to put captures) |
| Marp | Tool for creating slides from Markdown. Workflow: `.md` → preview (VS Code) → PDF/HTML (`marp --pdf`). Used for slide documents. |
| MCP | Model Context Protocol — Claude Code access to external knowledge bases |
| iwe-knowledge | Gateway MCP server (`mcp.aisystant.com/mcp`): search across Pack, guides, DS + digital twin |

---

---

## Creating a Pack (Domain Knowledge Base)

A Pack is a Repository with formalized Domain knowledge. It is the source-of-truth: everything Claude needs to know about the Domain lives here.

**When you need a Pack:**
- You work regularly in one area
- You want Claude to know the terms and patterns of your area
- You are tired of repeating context in every Session

**How to create one:** type `/pack-new` in Claude Code.

The Skill will guide you through: Domain selection → Pack name → structure → content Roadmap.

**After creating a Pack,** populate it via `/ke` (Knowledge Extraction) — capture Knowledge as you work.

Details: [PACK-CREATION.md](PACK-CREATION.md)

---

## Additional Resources

**In this repo:**
- [SETUP-GUIDE.md](SETUP-GUIDE.md) — step-by-step installation (from zero to a working IWE)
- [LEARNING-PATH.md](LEARNING-PATH.md) — full learning path: principles, Protocols, agents, Pack, SOTA
- [PACK-CREATION.md](PACK-CREATION.md) — creating a Pack: Domain, name, structure, content
- [principles-vs-skills.md](principles-vs-skills.md) — why Skills are not enough: principles and generative hierarchy

**In Pack (via Gateway `knowledge_search`):**
- `DP.IWE.001` — what IWE is, why it exists, 5 architectural views, comparisons (vs exocortex, vs agents, vs second brain)
- `DP.IWE.002` — Template and installation: prerequisites, cost, Roles, OWC, FAQ, security
- `DP.EXOCORTEX.001` — modular exocortex: 3 layers, template-sync, standard/personal
- `DP.ARCH.002` — tiers T0-T4 + TM1-TM3 + TA1-TA4 + TD1: what is available at each level
- `DP.ROLE.001` — full AI Role Registry (21 Roles)