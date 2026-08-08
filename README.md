# IWE — Intellectual Work Environment

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-0.38.1-blue.svg)](CHANGELOG.md)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20%7C%20Windows%20(Git%20Bash)-lightgrey.svg)]()

<img src="docs/assets/orz-cycle.svg" alt="Open, Work, Close — the same cycle at every scale: session, day, week" width="100%">

> The operating system for intellectual work. Your Knowledge. Your Experience. Your Environment — runs on top of any AI platform.
>
> **Repository type:** `Base/Formats` (FMT) — a template distribution. After forking, it becomes your personal environment with AI agents.

---

## The Problem

AI assistants can generate text, code, and answers. But most users face the same problems:

- **Context is lost.** Every new AI session starts from scratch. Yesterday's decisions, plans, and agreements are forgotten.
- **Knowledge stays in your head.** You complete a course, read a book, solve a problem — but a month later you cannot reconstruct your reasoning.
- **AI replaces thinking instead of amplifying it.** You get an answer but do not become more competent. Without AI — back to zero.
- **No system.** Plans are in notes, tasks are in your head, knowledge is in chat logs. Everything is scattered.
- **Time slips away.** It is unclear what you worked on, what you accomplished, where you are headed.

---

## The Solution: An IDE, but for Thinking

**IWE (Intellectual Work Environment)** is an intellectual work environment.

Just as an IDE unites an editor, compiler, and debugger into a single environment for a programmer — IWE unites knowledge, planning, and AI agents into a single environment for thinking.

| IDE (for code) | IWE (for thinking) |
|---------------|-------------------|
| Editor → you write code | Exocortex → you capture knowledge |
| Compiler → checks syntax | Principles → verify the correctness of decisions |
| Debugger → finds errors | ORZ Protocols (Opening→Work→Closing) → find knowledge and context losses |
| Linter → improves quality | ArchGate → evaluates architectural decisions |
| Git → change history | Strategist → work history and planning |

> **Key principle: exoskeleton, not prosthetic.** IWE amplifies your thinking — it does not replace it. After each session you become more competent, not merely better supplied with results. See: [principles-vs-skills.md](docs/principles-vs-skills.md).

## Key IWE Terms

| Term | What it is |
|--------|---------|
| **Exocortex** | Your external Memory — files containing plans, context, and conclusions that Claude reads in every Session |
| **Pack** | A formalized knowledge base for your Domain — the single source of truth for domain knowledge |
| **ORZ** | Opening → Work → Closing — the ritual for every session and every day; prevents context loss |
| **ArchGate** | Structured Assessment of architectural decisions across 7 characteristics (instead of "I think this is fine") |
| **Strategist** | An AI agent that automatically drafts daily and weekly plans and tracks Progress |


---

## Work Culture — A New Way to Interact With AI


### The ORZ Protocol (Opening → Work → Closing)

Every session and every day passes through three stages:

- **Opening** — Claude reviews the plan, identifies the task, and aligns on the approach. You do not start work from scratch — the AI knows the context.
- **Work** — as work proceeds, Claude captures valuable knowledge (Capture-to-Pack). Insights are not lost.
- **Closing** — the result is recorded, the plan is updated, and the next session starts where you left off.

Skipping Opening = unplanned work. Skipping Closing = lost results.

### Exocortex — External Memory

Your knowledge, principles, distinctions, plans, and context are stored in files that Claude reads in every session. This is not a "prompt" — it is an **accumulated base** that grows with you.

### Knowledge Formalization (Pack)

What you learn does not stay in your head. Valuable knowledge is formalized into a Pack — the Domain passport. Pack is the single source of truth for domain knowledge. See: [LEARNING-PATH.md](docs/LEARNING-PATH.md).

---

## Who It Is For

Every professional drowns in information: 12+ tools (Notion, Google Docs, Slack, ChatGPT, courses...), knowledge is spread thin, nothing is connected. AI answers questions but does not know *your* context — it starts from scratch every time.

IWE is for those who want to change that:

- **Entrepreneurs and managers** — you strategize, make decisions, and run projects. IWE provides the system: from weekly planning to Domain knowledge formalization.
- **Engineers and developers** — you work with code and Architecture. IWE preserves context between sessions; the AI knows your codebase, technical debt, and Roadmap.
- **Researchers and analysts** — you study, synthesize, and publish. IWE turns scattered notes into a structured knowledge base that grows with you.
- **Everyone who does intellectual work** — and wants **symbiosis with AI**, not dependence on it. An exoskeleton for thinking, not a prosthetic.

---

## Use Cases

### Work Projects

| Scenario | What happens | Details |
|----------|---------------|-----------|
| **Product development** | Claude knows the Architecture, technical debt, and Roadmap. Every session continues from where you left off. | [SC.013](docs/use-cases/USE-CASES.md), [SC.015](docs/use-cases/USE-CASES.md) |
| **Documentation management** | Knowledge is captured in a Pack during work. No need to "write docs later" — they are written during the work itself. | [SC.004](docs/use-cases/USE-CASES.md), [SC.014](docs/use-cases/USE-CASES.md) |
| **Project coordination** | WeekPlan, DayPlan, Work Product registry — the Strategist helps with planning and Progress tracking. | [SC.001](docs/use-cases/USE-CASES.md), [SC.002](docs/use-cases/USE-CASES.md) |
| **Review and Refactoring** | ArchGate evaluates decisions across 7 characteristics. Not "I think it's fine" — a structured Assessment. | [SC.015](docs/use-cases/USE-CASES.md) |

### Personal Development

| Scenario | What happens | Details |
|----------|---------------|-----------|
| **Taking a course** | Claude helps capture key ideas, asks questions to check Understanding, and connects new material to what you already know. | [SC.003](docs/use-cases/USE-CASES.md) |
| **Writing articles** | A creative Pipeline: note → draft → prepared piece → publication. Every Artifact is tracked. | [SC.005](docs/use-cases/USE-CASES.md) |
| **Strategizing** | A weekly session: Review of last week, planning the new week, checking against goals. The Strategist prepares a draft — you make the decisions. | [SC.011](docs/use-cases/USE-CASES.md) |
| **Building a knowledge base** | Your Pack grows. After six months you have a formalized Domain knowledge base, not a collection of notes. | [SC.014](docs/use-cases/USE-CASES.md) |

> Full catalog of 15 scenarios: **[USE-CASES.md](docs/use-cases/USE-CASES.md)**

---

## What It Looks Like in Practice

- In the morning — the Strategist has drafted a plan: a Telegram notification + a DayPlan file in the Repository.
- You open VS Code → `claude` → Claude knows what is in the plan and suggests starting with the top Priority.
- You work — Claude captures knowledge as you go (Capture-to-Pack).
- You close the session — the result is recorded, the plan is updated.
- On Monday — the Strategist prepares a draft weekly plan; you discuss it in the strategizing session.

---

## Getting Started

**Quick start** (Git, Node.js, Claude Code already installed): **[QUICK-START.md](docs/QUICK-START.md)** — 15 minutes to your first session.

**Full setup** from a clean machine: **[SETUP-GUIDE.md](docs/SETUP-GUIDE.md)** — 30–60 minutes, including all dependency installation.

**Not on macOS or not using Claude Code?** Read **[PORTABILITY.md](docs/PORTABILITY.md)** — instructions for Kimi Code, Hermes Agent, and others.

**Different agent or LLM?** IWE is not tied to Claude. If your agent can see files in the repo folder and edit files, it will work. How to connect → [PORTABILITY.md](docs/PORTABILITY.md).

```bash
mkdir -p ~/IWE && cd ~/IWE
gh repo fork iwesys/IWE --clone
cd FMT-exocortex-template
bash setup.sh
```

After setup:

```bash
cd ~/IWE
claude
```

Tell Claude: **"Let's run the first strategic session"** — and it will guide you through defining goals, creating the first plan, and configuring the Environment.

---

## Customization

IWE updates like a distribution — you receive Platform updates without losing your settings.

**Extensions (extensions/)** — add your own blocks to protocols:

```bash
# Add end-of-day reflection
echo "## Daily Reflection
- What was difficult?
- What would I do differently?
- What deserves praise?" > extensions/day-close.after.md
```

**Parameters (params.yaml)** — enable or disable Protocol steps:

```yaml
reflection_enabled: true    # Enable reflection
video_check: false          # Disable video check
multiplier_enabled: true    # IWE multiplier
```

**Updates** — `bash update.sh` updates the Platform while preserving your extensions/, params.yaml, and edits in CLAUDE.md (3-way merge).


---

## Documentation

| Document | Contents |
|----------|-----------|
| **[Beginner's Guide](docs/onboarding/onboarding-guide.md)** | Start here if you are new to IWE. What it is, why it exists, and what it consists of — no technical jargon. |
| **[Quick Start](docs/QUICK-START.md)** | 15 minutes from `git clone` to your first session. For those who already have Git and Claude Code. |
| **[SETUP-GUIDE.md](docs/SETUP-GUIDE.md)** | Step-by-step setup from a clean machine. Requirements, modes (core/full), Verification. |
| **[LEARNING-PATH.md](docs/LEARNING-PATH.md)** | The IWE learning path: Architecture, principles, protocols, Pack, Roles. |
| **[DATA-POLICY.md](docs/DATA-POLICY.md)** | Data policy: what is collected, where it is stored, how to delete it. |
| **[DATA-RESIDENCY.md](docs/DATA-RESIDENCY.md)** | The residency principle: data you bring into IWE from outside (health, calendar, working hours) — where it may and may not go. |
| **[IWE-HELP.md](docs/IWE-HELP.md)** | Quick reference and FAQ. |
| **[principles-vs-skills.md](docs/principles-vs-skills.md)** | Why principles matter more than skills: the generative hierarchy. |
| **[CHANGELOG.md](CHANGELOG.md)** | Template change history. |

> Two documents cover related topics: `DATA-POLICY.md` covers data the Platform collects about you; `DATA-RESIDENCY.md` covers data you bring into IWE from outside.

---

## FAQ

**Q: Is an Anthropic subscription required?**
A: For full setup (Claude Code) — Claude Pro ($20/month) is recommended. If needed, you can upgrade to Claude Max (~$100/month) for unlimited work. For minimal setup (`setup.sh --core`) — works with any AI CLI. See: [SETUP-GUIDE.md](docs/SETUP-GUIDE.md).

**Q: Does it work with AI systems other than Claude?**
A: Yes, three agents are supported out of the box:
- **Claude Code** — full support: reads `CLAUDE.md`, all skills and hooks work.
- **Kimi Code** (VS Code) — reads `AGENTS.md` automatically when the repo is opened. Customization: `extensions/` or `AGENTS-agent-blocks.md`. Skills (`/day-open` etc.) via Claude Code.
- **Hermes Agent** — connect Aisystant MCP through Hermes settings and it receives instructions automatically.

For other agents (Cursor, Copilot, Gemini) adaptation is required. See: [PORTABILITY.md](docs/PORTABILITY.md).
Minimal setup (`setup.sh --core`) works without being tied to a specific agent.

**Q: Does it work on Linux/Windows?**
A: Yes. The core works on any OS. Strategist automation: macOS — launchd, Linux — systemd (user units), cloud option (OS-independent) — GitHub Actions. Windows: `setup.sh` and the core run via Git Bash (installed with Git for Windows) — WSL is not required; WSL remains a fallback for those who prefer a full Linux layer. Not verified on real Windows hardware (no Windows runner in CI) — see the full details and honest caveat: [SETUP-GUIDE.md](docs/SETUP-GUIDE.md) § Windows.

**Q: What if the computer is off or sleeping — will automation stop?**
A: Cloud Scheduler (GitHub Actions) runs in the cloud even when the computer is off. For local agents: scripts automatically prevent sleep during operation (macOS: `caffeinate`, Linux: `systemd-inhibit`). For laptops, configuring automatic wake and disabling idle sleep is recommended — see [SETUP-GUIDE.md](docs/SETUP-GUIDE.md).

**Q: What is a Pack?**
A: A formalized Knowledge Domain — the single source of truth for domain knowledge. See: [LEARNING-PATH.md](docs/LEARNING-PATH.md).

**Q: Is my data safe?**
A: Three protection zones: local, GitHub (private repositories), Platform (per-user isolation). See: [DATA-POLICY.md](docs/DATA-POLICY.md).

**Q: How does IWE differ from Obsidian / Notion / Logseq?**
A: Obsidian is a note store. IWE is a **work environment** with protocols, AI agents, and knowledge formalization. You can use Obsidian inside IWE for notes, but IWE provides structure, planning, and Competency accumulation.

**Q: Is programming required?**
A: No. The template is a ready-made Configuration. Installation is via setup.sh. Work is done through Claude Code in natural language.

**Q: Can IWE be used without the Strategist?**
A: Yes. Claude Code + CLAUDE.md + memory/ work fully without it. The Strategist is a planning automation layer. Without it, you plan manually.

**Q: How do I configure the strategizing day?**
A: In `memory/day-rhythm-config.yaml`, change `strategy_day: sunday` to the desired day. See: [LEARNING-PATH.md](docs/LEARNING-PATH.md).

**Q: The clone ended up in `~` instead of `~/IWE`?**
A: All setup commands must be run in the same terminal. Opening a new terminal starts it from `~`. Delete the folder from `~` and repeat from `cd ~/IWE`. See: [SETUP-GUIDE.md](docs/SETUP-GUIDE.md).


---

## The IWE Community

IWE is an environment you build alone. But you develop it together.

**The IWE community** is a closed chat for Practitioners working within the same system: ORZ, Pack, exocortex. A place where the discussion is not "how to write better prompts" but how to build intellectual work seriously.

### What happens there

- **Work Product breakdowns** — members share real Packs, plans, and Retrospectives. They receive feedback from people who understand what "closing without recording a result" means.
- **IWE installation and customization experience** — what broke, how it was fixed, which extensions proved useful.
- **Method discussion** — the ORZ fractal, ArchGate, Capture-to-Pack in practice: what works, where theory diverges from reality.
- **Links and discoveries** — tools, patterns, SOTA that fit the IWE philosophy.

### Why this matters

You can study the system alone. But most questions arise at the application stage: "How do I formalize this Knowledge Domain?", "Am I using ORZ correctly?", "Who has experience with this tool?"

In the community, those questions get answers from people who have already been through it.

### Free channels

- [GitHub Discussions](https://github.com/iwesys/IWE/discussions) — questions, ideas, show your setup.
- [Issues](https://github.com/iwesys/IWE/issues) — bug reports and feature requests.

### Closed community (Telegram)

Deep practice, Work Product breakdowns, direct support. Entry is through the **"IWE for Practitioners"** seminar (5000₽) via the bot [@aist_me_bot](https://t.me/aist_me_bot).

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) — how to contribute to the project.

**IWE team developers (T4+ level):** the single entry point is [Getting Started for Developers](docs/developer/). In 10 minutes you will understand the development Pipeline (6 stations, dual output) and complete your first task.

---

## License

MIT