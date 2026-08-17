# IWE — Intellectual Work Environment

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-0.38.4-blue.svg)](CHANGELOG.md)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20%7C%20Windows%20(Git%20Bash)-lightgrey.svg)]()

<img src="docs/assets/orz-cycle.svg" alt="Open, Work, Close — the same cycle at every scale: session, day, week" width="100%">

> The operating system for intellectual work. Your Knowledge. Your Experience. Your Environment — runs on top of any AI platform.
>
> **Repository type:** `Base/Formats` (FMT) — distribution template. After forking, it becomes your personal environment with AI agents.

---

## The Problem

AI assistants can generate text, code, and answers. But most users face the same problems:

- **Context is lost.** Every new AI session starts from scratch. Yesterday's decisions, plans, and agreements are forgotten.
- **Knowledge stays in your head.** You completed a course, read a book, solved a problem — but a month later you cannot reconstruct your reasoning.
- **AI replaces thinking instead of amplifying it.** You get an answer, but you do not become more competent. Without AI, you are back to zero.
- **No system.** Plans live in notes, tasks live in your head, knowledge lives in chat logs. Everything is disconnected.
- **Time slips away.** It is unclear what you worked on, what you accomplished, or where you are headed.

---

## The Solution: An IDE, But for Thinking

**IWE (Intellectual Work Environment)** is an intellectual work environment.

Just as an IDE unifies an editor, compiler, and debugger into one environment for a developer — IWE unifies knowledge, planning, and AI agents into one environment for thinking.

| IDE (for code) | IWE (for thinking) |
|---------------|-------------------|
| Editor → you write code | Exocortex → you capture knowledge |
| Compiler → checks syntax | Principles → verify correctness of decisions |
| Debugger → finds errors | Opening→Work→Closing (OWC) protocols → surface knowledge and context losses |
| Linter → improves quality | ArchGate → evaluates architectural decisions |
| Git → change history | Strategist → work history and planning |

> **Core principle: exoskeleton, not prosthetic.** IWE amplifies your thinking — it does not replace it. After each session you become more competent, not just better supplied with results. Details: [principles-vs-skills.md](docs/principles-vs-skills.md).

## Key IWE Terms

| Term | What it is |
|------|-----------|
| **Exocortex** | Your external memory — files containing plans, context, and conclusions that Claude reads at the start of every session |
| **Pack** | A formalized knowledge base for your Domain — the single source of truth for domain knowledge |
| **OWC** | Opening → Work → Closing — a ritual for every session and every day that prevents context loss |
| **ArchGate** | Structured Assessment of architectural decisions across 7 characteristics (instead of "I think this is fine") |
| **Strategist** | An AI agent that automatically drafts day/week plans and tracks Progress |


---

## Work Culture — A New Way to Interact With AI


### The OWC Protocol (Opening → Work → Closing)

Every session and every day passes through three stages:

- **Opening** — Claude reviews the plan, identifies the task, and aligns on the approach. You do not start from scratch — the AI already knows the context.
- **Work** — as work proceeds, Claude captures valuable knowledge (Capture-to-Pack). Insights are not lost.
- **Closing** — the result is recorded, the plan is updated, and the next session starts exactly where you left off.

Skipping Opening = unplanned work. Skipping Closing = lost results.

### Exocortex — External Memory

Your knowledge, principles, distinctions, plans, and context are stored in files that Claude reads at the start of every session. This is not a "prompt" — it is an **accumulated base** that grows alongside you.

### Knowledge Formalization (Pack)

What you learn does not stay only in your head. Valuable knowledge is formalized into a Pack — the domain passport. A Pack is the single source of truth for domain knowledge. Details: [LEARNING-PATH.md](docs/LEARNING-PATH.md).

---

## Who It Is For

Every knowledge worker drowns in information: 12+ tools (Notion, Google Docs, Slack, ChatGPT, courses…), knowledge scattered everywhere, nothing connected. AI answers questions but does not know *your* context — every conversation starts from zero.

IWE is for those who want to change that:

- **Entrepreneurs and executives** — you strategize, make decisions, and manage projects. IWE provides a system: from weekly planning to domain knowledge formalization.
- **Engineers and developers** — you work with code and Architecture. IWE preserves context between sessions; the AI knows your codebase, technical debt, and Roadmap.
- **Researchers and analysts** — you study, synthesize, and publish. IWE turns scattered notes into a structured knowledge base that grows with you.
- **Anyone doing intellectual work** — and who wants **symbiosis with AI**, not dependence on it. An exoskeleton for thinking, not a prosthetic.

---

## Use Cases

### Work Projects

| Scenario | What happens | Details |
|----------|-------------|---------|
| **Product development** | Claude knows the Architecture, technical debt, and Roadmap. Every session is a continuation, not a restart | [SC.013](docs/use-cases/USE-CASES.md#sc013-work-session-with-claude-code), [SC.015](docs/use-cases/USE-CASES.md#sc015-system-development-ds) |
| **Documentation management** | Knowledge is captured into a Pack during work. There is no need to "write docs later" — they are written as work happens | [SC.004](docs/use-cases/USE-CASES.md#sc004-knowledge-capture-and-extraction), [SC.014](docs/use-cases/USE-CASES.md#sc014-knowledge-formalization-pack) |
| **Project coordination** | WeekPlan, DayPlan, Work Product registry — the Strategist helps plan and track Progress | [SC.001](docs/use-cases/USE-CASES.md#sc001-day-planning), [SC.002](docs/use-cases/USE-CASES.md#sc002-week-planning-and-review) |
| **Review and Refactoring** | ArchGate evaluates decisions across 7 characteristics. Not "seems fine," but a structured Assessment | [SC.015](docs/use-cases/USE-CASES.md#sc015-system-development-ds) |

### Personal Development

| Scenario | What happens | Details |
|----------|-------------|---------|
| **Taking a course** | Claude helps capture key ideas, asks comprehension questions, and connects new material to what you already know | [SC.003](docs/use-cases/USE-CASES.md#sc003-learning-and-development) |
| **Writing articles** | Creative Pipeline: note → draft → prepared piece → publication. Every Artifact is tracked | [SC.005](docs/use-cases/USE-CASES.md#sc005-content-publication) |
| **Strategizing** | Weekly session: Review of the past week, planning the new one, alignment with goals. The Strategist prepares a draft — you make the decisions | [SC.011](docs/use-cases/USE-CASES.md#sc011-strategizing) |
| **Building a knowledge base** | Your Pack grows. After six months you have a formalized domain knowledge base, not a collection of notes | [SC.014](docs/use-cases/USE-CASES.md#sc014-knowledge-formalization-pack) |

> Full catalog of 15 use cases: **[USE-CASES.md](docs/use-cases/USE-CASES.md)**

---

## What This Looks Like in Practice

- In the morning — the Strategist has drafted a plan: a Telegram notification and a DayPlan file in the Repository.
- You open VS Code → `claude` → Claude knows what is in the plan and suggests starting with the highest Priority item.
- You work — Claude captures knowledge as you go (Capture-to-Pack).
- You close the session — the result is recorded and the plan is updated.
- On Monday — the Strategist prepares a draft weekly plan, and you discuss it in a strategizing session.

---

## Getting Started

**Quick start** (Git, Node.js, and Claude Code already installed): **[QUICK-START.md](docs/QUICK-START.md)** — 15 minutes to your first session.

**Full installation** from a clean machine: **[SETUP-GUIDE.md](docs/SETUP-GUIDE.md)** — 30–60 minutes including all dependencies.

**Not on macOS or not using Claude Code?** See **[PORTABILITY.md](docs/PORTABILITY.md)** — instructions for Kimi Code, Hermes Agent, and others.

**Different agent or LLM?** IWE is not tied to Claude. If your agent can see files in the repo folder and edit files, it will work. How to connect → [PORTABILITY.md](docs/PORTABILITY.md).

```bash
mkdir -p ~/IWE && cd ~/IWE
gh repo fork iwesys/IWE --clone
cd FMT-exocortex-template
bash setup.sh
```

After installation:

```bash
cd ~/IWE
claude
```

Tell Claude: **"Let's run the first strategic session"** — and it will guide you through defining goals, creating an initial plan, and configuring the environment.

---

## Customization

IWE updates like a distribution — you receive platform updates without losing your personal settings.

**Extensions (extensions/)** — add your own blocks to protocols:

```bash
# Add end-of-day reflection
echo "## Daily Reflection
- What was challenging?
- What would I do differently?
- What deserves praise?" > extensions/day-close.after.md
```

**Parameters (params.yaml)** — enable or disable protocol steps:

```yaml
reflection_enabled: true    # Enable reflection
video_check: false          # Disable video check
multiplier_enabled: true    # IWE multiplier
```

**Updates** — `bash update.sh` updates the platform while preserving your extensions/, params.yaml, and edits in CLAUDE.md (3-way merge).


---

## Documentation

| Document | Contents |
|----------|---------|
| **[Beginner's guide](docs/onboarding/onboarding-guide.md)** | Start here if you are new to IWE. What it is, why it exists, what it consists of — no technical jargon |
| **[Quick start](docs/QUICK-START.md)** | 15 minutes from `git clone` to your first session. For those who already have Git and Claude Code |
| **[SETUP-GUIDE.md](docs/SETUP-GUIDE.md)** | Step-by-step installation from a clean machine. Requirements, modes (core/full), verification |
| **[LEARNING-PATH.md](docs/LEARNING-PATH.md)** | IWE learning path: Architecture, principles, protocols, Pack, Roles |
| **[DATA-POLICY.md](docs/DATA-POLICY.md)** | Data policy: what is collected, where it is stored, how to delete it |
| **[DATA-RESIDENCY.md](docs/DATA-RESIDENCY.md)** | Residency principle: data you bring into IWE from external sources (health, calendar, work hours) — where it may and may not go |
| **[IWE-HELP.md](docs/IWE-HELP.md)** | Quick reference and FAQ |
| **[principles-vs-skills.md](docs/principles-vs-skills.md)** | Why principles matter more than skills: the generative hierarchy |
| **[CHANGELOG.md](CHANGELOG.md)** | Template change history |

> Two documents cover adjacent topics: `DATA-POLICY.md` covers data the platform collects about you; `DATA-RESIDENCY.md` covers data you bring into IWE from external sources.

---

## FAQ

**Q: Is an Anthropic subscription required?**
A: For the full installation (Claude Code) — Claude Pro ($20/month) is recommended. If needed, you can upgrade to Claude Max (~$100/month) for unrestricted use. For the minimal install (`setup.sh --core`) — works with any AI CLI. Details: [SETUP-GUIDE.md](docs/SETUP-GUIDE.md).

**Q: Does it work with other AI systems (not Claude)?**
A: Yes, three agents are supported out of the box:
- **Claude Code** — full support: reads `CLAUDE.md`, all skills and hooks work.
- **Kimi Code** (VS Code) — reads `AGENTS.md` automatically when the repo is opened. Customization: `extensions/` or `AGENTS-agent-blocks.md`. Skills (`/day-open` etc.) via Claude Code.
- **Hermes Agent** — connect the Aisystant MCP through Hermes settings and it will receive instructions automatically.

For other agents (Cursor, Copilot, Gemini), adaptation is required. Details: [PORTABILITY.md](docs/PORTABILITY.md).
The minimal installation (`setup.sh --core`) works without being tied to any specific agent.

**Q: Does it work on Linux/Windows?**
A: Yes. The core runs on any OS. Strategist automation: macOS — launchd, Linux — systemd (user units), cloud variant (OS-independent) — GitHub Actions. Windows: `setup.sh` and the core run via Git Bash (installed with Git for Windows) — WSL is not required; WSL remains a fallback for those who prefer a full Linux layer. Not verified on a real Windows machine (no Windows runner in CI) — details and honest caveats: [SETUP-GUIDE.md](docs/SETUP-GUIDE.md) § Windows.

**Q: What if the computer is off or asleep — will automation stop?**
A: Cloud Scheduler (GitHub Actions) runs in the cloud even when the computer is off. For local agents: scripts automatically prevent sleep during execution (macOS: `caffeinate`, Linux: `systemd-inhibit`). For laptops, it is recommended to configure automatic wake and disable idle sleep — see [SETUP-GUIDE.md](docs/SETUP-GUIDE.md).

**Q: What is a Pack?**
A: A formalized Knowledge Domain — the single source of truth for domain knowledge. Details: [LEARNING-PATH.md](docs/LEARNING-PATH.md).

**Q: Is my data safe?**
A: Three protection zones: local, GitHub (private repos), and platform (per-user isolation). Details: [DATA-POLICY.md](docs/DATA-POLICY.md).

**Q: How is IWE different from Obsidian / Notion / Logseq?**
A: Obsidian is a note store. IWE is a **work environment** with protocols, AI agents, and knowledge formalization. You can use Obsidian inside IWE for notes, but IWE provides structure, planning, and Competency accumulation.

**Q: Is programming required?**
A: No. The template is a ready-made Configuration. Installation is via setup.sh. Work happens through Claude Code in natural language.

**Q: Can it be used without the Strategist?**
A: Yes. Claude Code + CLAUDE.md + memory/ work fully on their own. The Strategist automates planning. Without it, you plan manually.

**Q: How do I configure the strategizing day?**
A: In `memory/day-rhythm-config.yaml`, change `strategy_day: sunday` to the desired day. Details: [LEARNING-PATH.md](docs/LEARNING-PATH.md).

**Q: The clone ended up in `~` instead of `~/IWE`?**
A: All installation commands must be run in the same terminal window. Opening a new terminal resets the working directory to `~`. Delete the folder from `~` and repeat starting with `cd ~/IWE`. Details: [SETUP-GUIDE.md](docs/SETUP-GUIDE.md).


---

## IWE Community

IWE is an environment you build alone. But you develop it together.

The **IWE Community** is a closed chat of Practitioners working within the same system: OWC, Pack, Exocortex. A place where people discuss not "how to prompt better," but how to build serious intellectual work.

### What Happens There

- **Work Product reviews** — participants share real Packs, plans, and Retrospectives. They receive feedback from people who understand what "closing without capturing results" actually means.
- **IWE installation and customization Experience** — what broke, how it was fixed, which extensions proved useful.
- **Method discussions** — the OWC fractal, ArchGate, and Capture-to-Pack in practice: what works and where theory diverges from reality.
- **Links and discoveries** — tools, patterns, and SOTA that fit the IWE philosophy.

### Why This Matters

Learning the system alone is possible. But most questions arise during application: "How do I formalize this Knowledge Domain?", "Am I using OWC correctly?", "Who has Experience with this tool?"

In the community, these questions get answers from people who have already been through it.

### Free Channels

- [GitHub Discussions](https://github.com/iwesys/IWE/discussions) — questions, ideas, share your setup
- [Issues](https://github.com/iwesys/IWE/issues) — bug reports and feature requests

### Closed Community (Telegram)

Deep Practice, Work Product reviews, direct support. Entry is through the **"IWE for Practitioners"** seminar (5000₽) via the bot [@aist_me_bot](https://t.me/aist_me_bot).

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) — how to contribute to the project.

**IWE team developers (level T4+):** the single entry point is [Getting started as a developer](docs/developer/). In 10 minutes you will understand the development Pipeline (6 stations, dual output) and complete your first task.

---

## License

MIT

