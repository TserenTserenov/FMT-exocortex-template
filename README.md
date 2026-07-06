<body>
# IWE — Intellectual Work Environment

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-0.35.5-blue.svg)](CHANGELOG.md)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20%7C%20Windows%20(WSL)-lightgrey.svg)]()
[![EN sync](https://img.shields.io/endpoint?url=https://raw.githubusercontent.com/TserenTserenov/FMT-exocortex-template/en-draft/badge-data.json)](https://github.com/TserenTserenov/FMT-exocortex-template/tree/en-draft)

> The operating system for intellectual work. Your Knowledge. Your Experience. Your Environment — runs on top of any AI platform.
>
> **Repository type:** `Base/Formats` (FMT) — distribution template. After forking, it becomes your personal environment with AI agents.

**[English version](README.en.md)**

---

## The Problem

AI assistants can generate text, code, and answers. But most users face the same issues:

- **Context is lost.** Every new AI Session starts from scratch. Yesterday's decisions, plans, and agreements are forgotten.
- **Knowledge stays in your head.** You complete a course, read a book, solve a problem — but a month later you cannot reproduce the reasoning.
- **AI replaces thinking instead of amplifying it.** You get an answer but do not become more competent. Without AI, you are back to zero.
- **No system exists.** Plans are in notes, tasks are in your head, Knowledge is in chat logs. Everything is fragmented.
- **Time slips away.** It is unclear what you worked on, what you accomplished, or where you are headed.

---

## The Solution: An IDE, but for Thinking

**IWE (Intellectual Work Environment)** is an intellectual working environment.

Just as an IDE combines an editor, compiler, and debugger into one environment for a programmer — IWE combines Knowledge, planning, and AI agents into one environment for thinking.

| IDE (for code) | IWE (for thinking) |
|---------------|-------------------|
| Editor → write code | Exocortex → capture Knowledge |
| Compiler → checks syntax | Principles → verify correctness of decisions |
| Debugger → finds errors | Opening→Work→Closing (OWC) Protocols → find Knowledge and context losses |
| Linter → improves quality | ArchGate → assesses architectural decisions |
| Git → change history | Strategist → work history and planning |

> **Key principle: exoskeleton, not prosthetic.** IWE amplifies your thinking — it does not replace it. After each Session you become more competent, not merely equipped with a result. Read more: [principles-vs-skills.md](docs/principles-vs-skills.md).

## Key IWE Terms

| Term | What it is |
|--------|---------|
| **Exocortex** | Your external Memory — files containing plans, context, and conclusions that Claude reads in every Session |
| **Pack** | A formalized Knowledge base for your Domain — the single source of truth for domain Knowledge |
| **OWC** | Opening → Work → Closing — a ritual for every Session and every day that prevents context loss |
| **ArchGate** | A structured Assessment of architectural decisions across 7 characteristics (instead of "seems good to me") |
| **Strategist** | An AI agent that automatically drafts day/week plans and tracks Progress |

Full glossary: [ONTOLOGY.md](ONTOLOGY.md)

---

## Work Culture — A New Style of AI Interaction

IWE is not a set of prompts. It is a **work culture**: 14 elements (Protocols, Skills, formats) that transform chaotic AI interaction into a managed Process. Read more: [DP.M.008 — IWE Operating Rules](https://github.com/TserenTserenov/PACK-digital-platform/blob/main/pack/digital-platform/03-methods/DP.M.008-iwe-operating-rules.md).

### The OWC Protocol (Opening → Work → Closing)

Every Session and every day passes through three stages:

- **Opening** — Claude reviews the plan, identifies the task, and aligns on the approach. You do not start work "from scratch" — the AI knows the context.
- **Work** — as work proceeds, Claude captures valuable Knowledge (Capture-to-Pack). Insights are not lost.
- **Closing** — the result is captured, the plan is updated, and the next Session begins where you left off.

Skipping Opening = unplanned work. Skipping Closing = lost result.

### Exocortex — External Memory

Your Knowledge, principles, Distinctions, plans, and context are stored in files that Claude reads in every Session. This is not a "prompt" — it is an **accumulated base** that grows with you.

### Knowledge Formalization (Pack)

What you learn does not stay only in your head. Valuable Knowledge is formalized into a Pack — a Domain passport. The Pack is the single source of truth for domain Knowledge. Read more: [LEARNING-PATH.md](docs/LEARNING-PATH.md).

---

## Who It Is For

Every professional drowns in information: 12+ tools (Notion, Google Docs, Slack, ChatGPT, courses…), Knowledge is scattered, nothing is connected. AI answers questions but does not know *your* context — it starts from zero every time.

IWE is for those who want to change that:

- **Entrepreneurs and managers** — you strategize, make decisions, and manage projects. IWE provides a system: from weekly planning to formalizing domain Knowledge.
- **Engineers and developers** — you work with code and Architecture. IWE preserves context between Sessions; the AI knows your codebase, technical debt, and Roadmap.
- **Researchers and analysts** — you study, synthesize, and publish. IWE turns scattered notes into a structured Knowledge base that grows with you.
- **Anyone doing intellectual work** — and wanting **symbiosis with AI**, not dependence on it. An exoskeleton for thinking, not a prosthetic.

---

## Use Cases

### Work Projects

| Scenario | What happens | Details |
|----------|---------------|-----------|
| **Product development** | Claude knows the Architecture, technical debt, and Roadmap. Every Session is a continuation, not a fresh start. | [SC.013](docs/use-cases/USE-CASES.md#sc013-рабочая-сессия-с-claude-code), [SC.015](docs/use-cases/USE-CASES.md#sc015-развитие-системы-ds) |
| **Documentation management** | Knowledge is captured in the Pack during work. No need to "write docs later" — they are written as you work. | [SC.004](docs/use-cases/USE-CASES.md#sc004-фиксация-и-экстракция-знаний), [SC.014](docs/use-cases/USE-CASES.md#sc014-формализация-знаний-pack) |
| **Project coordination** | WeekPlan, DayPlan, Work Product registry — the Strategist helps plan and track Progress. | [SC.001](docs/use-cases/USE-CASES.md#sc001-планирование-дня), [SC.002](docs/use-cases/USE-CASES.md#sc002-планирование-и-ревью-недели) |
| **Review and Refactoring** | ArchGate assesses decisions across 7 characteristics. Structured Assessment, not "seems fine." | [SC.015](docs/use-cases/USE-CASES.md#sc015-развитие-системы-ds) |

### Personal Development

| Scenario | What happens | Details |
|----------|---------------|-----------|
| **Taking a course** | Claude helps capture key ideas, asks questions to verify Understanding, and connects new material to what you already know. | [SC.003](docs/use-cases/USE-CASES.md#sc003-обучение-и-развитие) |
| **Writing articles** | A creative Pipeline: note → draft → outline → publication. Every Artifact is tracked. | [SC.005](docs/use-cases/USE-CASES.md#sc005-публикация-контента) |
| **Strategizing** | Weekly Session: Review of the past week, planning the next, alignment with goals. The Strategist drafts the plan — you make the decisions. | [SC.011](docs/use-cases/USE-CASES.md#sc011-стратегирование) |
| **Building a Knowledge base** | Your Pack grows. After six months you have a formalized domain Knowledge base, not just a collection of notes. | [SC.014](docs/use-cases/USE-CASES.md#sc014-формализация-знаний-pack) |

> Full catalog of 15 scenarios: **[USE-CASES.md](docs/use-cases/USE-CASES.md)**

---

## What This Looks Like in Practice

- In the morning — the Strategist has prepared a plan: a Telegram notification + a DayPlan file in the Repository.
- You open VS Code → `claude` → Claude knows what is in the plan and suggests starting with the top Priority.
- You work — Claude captures Knowledge along the way (Capture-to-Pack).
- You close the Session — the result is captured, the plan is updated.
- On Monday — the Strategist drafts the weekly plan; you discuss it in a strategizing Session.

---

## Getting Started

**Quick start** (Git, Node.js, and Claude Code already installed): **[QUICK-START.md](docs/QUICK-START.md)** — 15 minutes to your first Session.

**Full setup** from a clean machine: **[SETUP-GUIDE.md](docs/SETUP-GUIDE.md)** — 30–60 minutes, including all dependencies.

**Not on macOS or not using Claude Code?** See **[PORTABILITY.md](docs/PORTABILITY.md)** — instructions for Kimi Code, Hermes Agent, and others.

**Different agent or LLM?** IWE is not tied to Claude. If your agent can see files in the repo folder and edit files, it will work. How to connect → [PORTABILITY.md](docs/PORTABILITY.md).

```bash
mkdir -p ~/IWE && cd ~/IWE
gh repo fork TserenTserenov/FMT-exocortex-template --clone
cd FMT-exocortex-template
bash setup.sh
```

After installation:

```bash
cd ~/IWE
claude
```

Tell Claude: **"Let's run our first strategic Session"** — and it will walk you through defining goals, creating your first plan, and configuring your Environment.

---

## Customization

IWE updates like a distribution — you receive Platform updates without losing your settings.

**Extensions (extensions/)** — add your own blocks to Protocols:

```bash
# Add end-of-day reflection
echo "## Day Reflection
- What was difficult?
- What would I do differently?
- What deserves recognition?" > extensions/day-close.after.md
```

**Parameters (params.yaml)** — enable or disable Protocol steps:

```yaml
reflection_enabled: true    # Enable reflection
video_check: false          # Disable video check
multiplier_enabled: true    # IWE multiplier
```

**Updates** — `bash update.sh` updates the Platform while preserving your extensions/, params.yaml, and edits in CLAUDE.md (3-way merge).

Read more: [extensions/README.md](extensions/README.md)

---

## Documentation

| Document | Contents |
|----------|-----------|
| **[Beginner's Guide](docs/onboarding/onboarding-guide.md)** | Start here if you are new to IWE. What it is, why it exists, and what it consists of — no technical jargon. |
| **[Quick Start](docs/QUICK-START.md)** | 15 minutes from `git clone` to your first Session. For those who already have Git and Claude Code. |
| **[SETUP-GUIDE.md](docs/SETUP-GUIDE.md)** | Step-by-step installation from a clean machine. Requirements, modes (core/full), and verification. |
| **[LEARNING-PATH.md](docs/LEARNING-PATH.md)** | The IWE learning path: Architecture, principles, Protocols, Pack, Roles. |
| **[DATA-POLICY.md](docs/DATA-POLICY.md)** | Data policy: what is collected, where it is stored, how to delete it. |
| **[IWE-HELP.md](docs/IWE-HELP.md)** | Quick reference and FAQ. |
| **[principles-vs-skills.md](docs/principles-vs-skills.md)** | Why principles matter more than Skills: the generative hierarchy. |
| **[ONTOLOGY.md](ONTOLOGY.md)** | Ontology: all IWE terms and abbreviations. |
| **[CHANGELOG.md](CHANGELOG.md)** | Template change history. |

---

## FAQ

**Q: Is an Anthropic subscription required?**
A: For the full installation (Claude Code) — Claude Pro ($20/month) is recommended. If needed, you can upgrade to Claude Max (~$100/month) for unlimited work. For the minimal setup (`setup.sh --core`) — works with any AI CLI. Read more: [SETUP-GUIDE.md](docs/SETUP-GUIDE.md).

**Q: Does it work with other AI systems (not Claude)?**
A: Yes, three agents are supported out of the box:
- **Claude Code** — full support: reads `CLAUDE.md`, all Skills and Hooks work.
- **Kimi Code** (VS Code) — reads `AGENTS.md` automatically when the repo is opened. Customization: `extensions/` or `AGENTS-agent-blocks.md`. Skills (`/day-open` etc.) via Claude Code.
- **Hermes Agent** — connect Aisystant MCP through Hermes settings and it receives instructions automatically.

For other agents (Cursor, Copilot, Gemini), adaptation is required. Read more: [PORTABILITY.md](docs/PORTABILITY.md).
The minimal installation (`setup.sh --core`) works without binding to a specific agent.

**Q: Does it work on Linux/Windows?**
A: Yes. The core runs on any OS. Strategist automation: macOS — launchd, Linux — cron, Windows — WSL. Read more: [SETUP-GUIDE.md](docs/SETUP-GUIDE.md).

**Q: What if the computer is off or asleep — will automation stop?**
A: Cloud Scheduler (GitHub Actions) runs in the cloud even when your computer is off. For local agents: scripts automatically prevent sleep during operation (macOS: `caffeinate`, Linux: `systemd-inhibit`). For laptops, it is recommended to configure automatic wake and disable idle sleep — see [SETUP-GUIDE.md](docs/SETUP-GUIDE.md).

**Q: What is a Pack?**
A: A formalized Knowledge Domain — the single source of truth for domain Knowledge. Read more: [LEARNING-PATH.md](docs/LEARNING-PATH.md).

**Q: Is my data secure?**
A: Three protection zones: local, GitHub (private repositories), and Platform (per-user isolation). Read more: [DATA-POLICY.md](docs/DATA-POLICY.md).

**Q: How is IWE different from Obsidian / Notion / Logseq?**
A: Obsidian is a note storage tool. IWE is a **working environment** with Protocols, AI agents, and Knowledge formalization. You can use Obsidian inside IWE for notes, but IWE provides structure, planning, and Competency accumulation.

**Q: Is programming required?**
A: No. The template is a ready-made Configuration. Installation is via setup.sh. Work is done through Claude Code in natural language.

**Q: Can I use IWE without the Strategist?**
A: Yes. Claude Code + CLAUDE.md + memory/ work fully on their own. The Strategist automates planning. Without it, you plan manually.

**Q: How do I configure the strategizing day?**
A: In `memory/day-rhythm-config.yaml`, change `strategy_day: sunday` to the desired day. Read more: [LEARNING-PATH.md](docs/LEARNING-PATH.md).

**Q: The clone ended up in `~` instead of `~/IWE`?**
A: All installation commands must be run in the same terminal. If you open a new terminal, it starts from `~`. Delete the folder from `~` and repeat starting with `cd ~/IWE`. Read more: [SETUP-GUIDE.md](docs/SETUP-GUIDE.md).

> Full FAQ with detailed answers: [DP.IWE.002 §11](https://github.com/TserenTserenov/PACK-digital-platform/blob/main/pack/digital-platform/02-domain-entities/DP.IWE.002-iwe-template-and-setup.md#11-частые-вопросы-faq). Practical reference: [LEARNING-PATH §11](docs/LEARNING-PATH.md#11-быстрый-справочник).

---

## The IWE Community

IWE is an Environment you build alone. But you develop it together.

The **IWE Community** is a closed chat for Practitioners who work within the same system: OWC, Pack, Exocortex. A place where discussions focus not on "how to prompt better," but on how to build intellectual work seriously.

### What Happens There

- **Work Product breakdowns** — participants share real Packs, plans, and Retrospectives. They receive feedback from people who understand what "Closing without capturing the result" means.
- **IWE installation and customization Experience** — what broke, how it was fixed, which extensions proved useful.
- **Method discussions** — OWC fractal, ArchGate, Capture-to-Pack in Practice: what works, where theory diverges from reality.
- **Links and discoveries** — tools, patterns, SOTA that fit the IWE philosophy.

### Why This Matters

You can learn the system alone. But most questions arise at the application stage: "How do I formalize this Knowledge Domain?", "Am I using OWC correctly?", "Who has Experience with this tool?"

In the community, those questions get answered by people who have already been through it.

### Free Channels

- [GitHub Discussions](https://github.com/TserenTserenov/FMT-exocortex-template/discussions) — questions, ideas, show your setup.
- [Issues](https://github.com/TserenTserenov/FMT-exocortex-template/issues) — bug reports and feature requests.

### Closed Community (Telegram)

Deep Practice, Work Product breakdowns, direct support. Entry is through the **"IWE for Practitioners"** seminar (5000₽) via the bot [@aist_me_bot](https://t.me/aist_me_bot).

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) — how to contribute to the project.

**IWE team developers (level T4+):** the single entry point is [Where to Start as a Developer](docs/developer/). In 10 minutes you will understand the development Pipeline (6 stations, dual output) and complete your first task.

---

## License

MIT
</body>