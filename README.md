# IWE — Intellectual Work Environment

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-0.38.7-blue.svg)](CHANGELOG.md)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20%7C%20Windows%20(Git%20Bash)-lightgrey.svg)]()

<img src="docs/assets/orz-cycle.svg" alt="Open, Work, Close — the same cycle at every scale: session, day, week" width="100%">

> The operating system for intellectual work. Your Knowledge. Your Experience. Your Environment — runs on top of any AI platform.
>
> **Repository type:** `Base/Formats` (FMT) — a template distribution. After forking, it becomes your personal environment with AI agents.

---

## The Problem

AI assistants can generate text, code, and answers. But most users face the same problems:

- **Context is lost.** Every new AI session starts from scratch. Yesterday's decisions, plans, and agreements are forgotten.
- **Knowledge stays in your head.** You completed a course, read a book, solved a problem — but a month later you cannot reconstruct your reasoning.
- **AI replaces thinking instead of augmenting it.** You get an answer but do not become more competent. Without AI — back to zero.
- **No system.** Plans are in notes, tasks are in your head, knowledge is scattered across chats. Everything is disconnected.
- **Time slips away.** It is unclear what you worked on, what you accomplished, where you are heading.

---

## The Solution: An IDE, but for Thinking

**IWE (Intellectual Work Environment)** is an intellectual work environment.

Just as an IDE combines an editor, compiler, and debugger into a single environment for a developer — IWE combines Knowledge, planning, and AI agents into a single environment for thinking.

| IDE (for code) | IWE (for thinking) |
|---------------|-------------------|
| Editor → you write code | Exocortex → you capture Knowledge |
| Compiler → checks syntax | Principles → verify the correctness of decisions |
| Debugger → finds errors | Opening→Work→Closing Protocols → detect Knowledge and context loss |
| Linter → improves quality | ArchGate → assesses architectural decisions |
| Git → change history | Strategist → work history and planning |

> **Key principle: exoskeleton, not prosthetic.** IWE augments your thinking — it does not replace it. After every Session you become more competent, not just better supplied with results. See: [principles-vs-skills.md](docs/principles-vs-skills.md).

## Key IWE Terms

| Term | What it is |
|------|-----------|
| **Exocortex** | Your external Memory — files containing plans, context, and conclusions that Claude reads in every Session |
| **Pack** | A formalized Knowledge base for your Domain — the single source of truth for domain Knowledge |
| **Opening→Work→Closing** | Opening → Work → Closing — the ritual for every Session and every day; prevents context loss |
| **ArchGate** | A structured Assessment of architectural decisions across 7 characteristics (instead of "I think this looks fine") |
| **Strategist** | An AI agent that automatically drafts day/week plans and tracks Progress |


---

## Work Culture — A New Way to Interact with AI


### The Opening→Work→Closing Protocol

Every Session and every day passes through three stages:

- **Opening** — Claude reviews the plan, identifies the task, and agrees on the approach. You do not start work from scratch — the AI knows the context.
- **Work** — as work proceeds, Claude captures valuable Knowledge (Capture-to-Pack). Insights are not lost.
- **Closing** — the result is recorded, the plan is updated, and the next Session starts where you left off.

Skipping Opening = unplanned work. Skipping Closing = lost results.

### Exocortex — External Memory

Your Knowledge, principles, Distinctions, plans, and context are stored in files that Claude reads in every Session. This is not a "prompt" — it is an **accumulated base** that grows with you.

### Knowledge Formalization (Pack)

What you learn does not stay only in your head. Valuable Knowledge is formalized into a Pack — a Domain passport. Pack is the single source of truth for domain Knowledge. See: [LEARNING-PATH.md](docs/LEARNING-PATH.md).

---

## Who It Is For

Every professional drowns in information: 12+ tools (Notion, Google Docs, Slack, ChatGPT, courses...), Knowledge scattered everywhere, nothing connected. AI answers questions but does not know *your* context — it starts from zero every time.

IWE is for those who want to change that:

- **Entrepreneurs and managers** — you strategize, make decisions, manage projects. IWE provides a system: from weekly planning to Domain Knowledge formalization.
- **Engineers and developers** — you work with code and Architecture. IWE preserves context between Sessions; the AI knows your codebase, technical debt, and Roadmap.
- **Researchers and analysts** — you study, synthesize, publish. IWE transforms scattered notes into a structured Knowledge base that grows with you.
- **Everyone doing intellectual work** — who wants **symbiosis with AI**, not dependence on it. An exoskeleton for thinking, not a prosthetic.

---

## Use Cases

### Work Projects

| Scenario | What happens | More |
|----------|-------------|------|
| **Product development** | Claude knows the Architecture, technical debt, and Roadmap. Every Session continues from where you left off — not from scratch | [SC.013](docs/use-cases/USE-CASES.md#sc013), [SC.015](docs/use-cases/USE-CASES.md#sc015) |
| **Documentation** | Knowledge is captured in Pack as work proceeds. No need to "write docs later" — they are written during the work | [SC.004](docs/use-cases/USE-CASES.md#sc004), [SC.014](docs/use-cases/USE-CASES.md#sc014) |
| **Project coordination** | WeekPlan, DayPlan, Work Product registry — the Strategist helps plan and track Progress | [SC.001](docs/use-cases/USE-CASES.md#sc001), [SC.002](docs/use-cases/USE-CASES.md#sc002) |
| **Review and Refactoring** | ArchGate assesses decisions across 7 characteristics. Not "I think this looks fine" — a structured Assessment | [SC.015](docs/use-cases/USE-CASES.md#sc015) |

### Personal Development

| Scenario | What happens | More |
|----------|-------------|------|
| **Taking a course** | Claude helps capture key ideas, asks questions to check Understanding, and connects new material to what you already know | [SC.003](docs/use-cases/USE-CASES.md#sc003) |
| **Writing articles** | A creative Pipeline: note → draft → prepared piece → publication. Every Artifact is tracked | [SC.005](docs/use-cases/USE-CASES.md#sc005) |
| **Strategizing** | A weekly Session: Review of the past week, planning the new one, alignment with goals. The Strategist prepares a draft — you make the decisions | [SC.011](docs/use-cases/USE-CASES.md#sc011) |
| **Building a Knowledge base** | Your Pack grows. After six months you have a formalized Domain Knowledge base, not a collection of notes | [SC.014](docs/use-cases/USE-CASES.md#sc014) |

> Full catalog of 15 use cases: **[USE-CASES.md](docs/use-cases/USE-CASES.md)**

---

## What It Looks Like in Practice

- In the morning — the Strategist has drafted a plan: a Telegram notification and a DayPlan file in the Repository.
- You open VS Code → `claude` → Claude knows the plan and suggests starting with the top Priority.
- You work — Claude captures Knowledge along the way (Capture-to-Pack).
- You close the Session — the result is recorded, the plan is updated.
- On Monday — the Strategist prepares a draft weekly plan; you discuss it in the strategizing Session.

---

## Machine Requirements

A minimum of **4 GiB of free RAM** is required while Claude Code (or another agent) runs on top of IWE. With less available memory — especially on shared servers with multiple users — file read/write tools may intermittently fail with a message such as `PreToolUse hook did not respond before its timeout`. This message indicates insufficient host-process memory, not a broken template Hook (issue [#461](https://github.com/iwesys/IWE/issues/461)). Run `bash scripts/iwe-audit.sh` to see the current available memory level in the "Available Memory" section.

## Getting Started

**Quick start** (Git, Node.js, and Claude Code already installed): **[QUICK-START.md](docs/QUICK-START.md)** — 15 minutes to your first Session.

**Full installation** from a clean machine: **[SETUP-GUIDE.md](docs/SETUP-GUIDE.md)** — 30–60 minutes including all dependencies.

**Not on macOS, or not using Claude Code?** See **[PORTABILITY.md](docs/PORTABILITY.md)** — instructions for Kimi Code, Hermes Agent, and others.

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

Tell Claude: **"Let's run our first strategic session"** — and it will walk you through defining goals, creating your first plan, and configuring the Environment.

---

## Customization

IWE updates like a distribution — you receive platform updates without losing your personal settings.

**Extensions (extensions/)** — add your own blocks to Protocols:

```bash
# Add end-of-day reflection
echo "## Day Reflection
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

**Updates** — `bash update.sh` updates the platform while preserving your extensions/, params.yaml, and edits in CLAUDE.md (3-way merge).


---

## Documentation

| Document | Contents |
|----------|---------|
| **[Beginner's guide](docs/onboarding/onboarding-guide.md)** | Start here if you are new to IWE. What it is, why it exists, what it consists of — no technical jargon |
| **[Quick start](docs/QUICK-START.md)** | 15 minutes from `git clone` to your first Session. For those who already have Git and Claude Code |
| **[SETUP-GUIDE.md](docs/SETUP-GUIDE.md)** | Step-by-step installation from a clean machine. Requirements, modes (core/full), verification |
| **[LEARNING-PATH.md](docs/LEARNING-PATH.md)** | The IWE learning path: Architecture, principles, Protocols, Pack, Roles |
| **[DATA-POLICY.md](docs/DATA-POLICY.md)** | Data policy: what is collected, where it is stored, how to delete it |
| **[DATA-RESIDENCY.md](docs/DATA-RESIDENCY.md)** | The residency principle: data you bring into IWE from external sources (health, calendar, working hours) — where it may and may not go |
| **[IWE-HELP.md](docs/IWE-HELP.md)** | Quick reference and FAQ |
| **[principles-vs-skills.md](docs/principles-vs-skills.md)** | Why principles matter more than Skills: the generative hierarchy |
| **[CHANGELOG.md](CHANGELOG.md)** | Template change history |

> Two documents cover adjacent topics: `DATA-POLICY.md` covers data the platform collects about you; `DATA-RESIDENCY.md` covers data you bring into IWE from external sources.

---

## FAQ

**Q: Is an Anthropic subscription required?**
A: For the full installation (Claude Code) — Claude Pro ($20/month) is recommended. If needed, you can upgrade to Claude Max (~$100/month) for unrestricted use. For the minimal setup (`setup.sh --core`) — works with any AI CLI. See: [SETUP-GUIDE.md](docs/SETUP-GUIDE.md).

**Q: Does it work with other AI systems (not Claude)?**
A: Yes, three agents are supported out of the box:
- **Claude Code** — full support: reads `CLAUDE.md`, all Skills and Hooks work.
- **Kimi Code** (VS Code) — reads `AGENTS.md` automatically when the repo is opened. Customization: `extensions/` or `AGENTS-agent-blocks.md`. Skills (`/day-open` etc.) via Claude Code.
- **Hermes Agent** — connect Aisystant MCP through Hermes settings and it receives instructions automatically.

For other agents (Cursor, Copilot, Gemini) adaptation is required. See: [PORTABILITY.md](docs/PORTABILITY.md).
The minimal installation (`setup.sh --core`) works without being tied to any specific agent.

**Q: Does it work on Linux/Windows?**
A: Yes. The core runs on any OS. Strategist automation: macOS — launchd, Linux — systemd (user units), cloud option (OS-independent) — GitHub Actions. Windows: `setup.sh` and the core run via Git Bash (installed with Git for Windows) — WSL is not required; WSL remains a fallback for those who prefer a full Linux layer. Not tested live on real Windows (no Windows runner in CI) — details and honest caveat: [SETUP-GUIDE.md](docs/SETUP-GUIDE.md) § Windows.

**Q: What if the computer is off or sleeping — does automation stop?**
A: Cloud Scheduler (GitHub Actions) runs in the cloud even when your computer is off. For local agents: scripts automatically prevent sleep while running (macOS: `caffeinate`, Linux: `systemd-inhibit`). For laptops, it is recommended to configure automatic wake and disable idle sleep — see [SETUP-GUIDE.md](docs/SETUP-GUIDE.md).

**Q: What is a Pack?**
A: A formalized Knowledge Domain — the single source of truth for domain Knowledge. See: [LEARNING-PATH.md](docs/LEARNING-PATH.md).

**Q: Is my data safe?**
A: Three protection zones: local, GitHub (private repositories), and platform (per-user isolation). See: [DATA-POLICY.md](docs/DATA-POLICY.md).

**Q: How is IWE different from Obsidian / Notion / Logseq?**
A: Obsidian is a note storage tool. IWE is a **work environment** with Protocols, AI agents, and Knowledge formalization. You can use Obsidian inside IWE for notes, but IWE provides structure, planning, and Competency accumulation.

**Q: Is programming required?**
A: No. The template is a ready-made Configuration. Installation is done via setup.sh. Work is done through Claude Code in natural language.

**Q: Can I use it without the Strategist?**
A: Yes. Claude Code + CLAUDE.md + memory/ work fully on their own. The Strategist automates planning. Without it, you plan manually.

**Q: How do I configure the strategizing day?**
A: In `memory/day-rhythm-config.yaml`, change `strategy_day: sunday` to the day you need. See: [LEARNING-PATH.md](docs/LEARNING-PATH.md).

**Q: The clone landed in `~` instead of `~/IWE`?**
A: All installation commands must be run in the same terminal. Opening a new terminal starts from `~`. Delete the folder from `~` and repeat starting with `cd ~/IWE`. See: [SETUP-GUIDE.md](docs/SETUP-GUIDE.md).


---

## IWE Community

IWE is an environment you build alone. But you develop it together.

The **IWE Community** is a closed chat for Practitioners who work within the same system: Opening→Work→Closing, Pack, Exocortex. A place where people discuss not "how to prompt better," but how to build intellectual work seriously.

### What Happens There

- **Work Product reviews** — participants share real Packs, plans, and Retrospectives. They receive feedback from people who understand what "Closing without recording the result" means.
- **IWE installation and customization Experience** — what broke, how it was fixed, which extensions proved useful.
- **Method discussions** — the Opening→Work→Closing fractal, ArchGate, Capture-to-Pack in practice: what works, where theory diverges from reality.
- **Links and discoveries** — tools, patterns, SOTA that fit the IWE philosophy.

### Why This Matters

You can study the system alone. But most questions arise at the application stage: "How do I formalize this Knowledge Domain?", "Am I using Opening→Work→Closing correctly?", "Who has Experience with this tool?"

In the community, these questions get answers from people who have already been through it.

### Free Channels

- [GitHub Discussions](https://github.com/iwesys/IWE/discussions) — questions, ideas, show your setup
- [Issues](https://github.com/iwesys/IWE/issues) — bug reports and feature requests

### Closed Community (Telegram)

Deep Practice, Work Product reviews, direct support. Entry — via the **"IWE for Practitioners"** seminar (5000₽) through the [@aist_me_bot](https://t.me/aist_me_bot) bot.

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) — how to contribute to the project.

**IWE team developers (level T4+):** the single entry point is [Getting Started for Developers](docs/developer/). In 10 minutes you will understand the development Pipeline (6 stations, dual output) and complete your first task.

---

## License

MIT