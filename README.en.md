# IWE — Intellectual Work Environment

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-0.22.0-blue.svg)](CHANGELOG.md)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20%7C%20Windows%20(WSL)-lightgrey.svg)]()

> An operating system for intellectual work. Your knowledge. Your experience. Your environment — runs on top of any AI platform.
>
> **Repository type:** `Base/Formats` (FMT) — template distribution. After forking, it becomes your personal environment with AI agents.

**[Русская версия (Russian)](README.md)**

---

## The Problem

AI assistants can generate text, code, and answers. But most users face the same problems:

- **Context is lost.** Every new AI session starts from scratch. Yesterday's decisions, plans, agreements — forgotten.
- **Knowledge stays in your head.** You took a course, read a book, solved a problem — but a month later you can't reproduce your reasoning.
- **AI replaces thinking instead of amplifying it.** You get an answer but don't become more competent. Without AI — back to zero.
- **No system.** Plans in notes, tasks in your head, knowledge in chats. Everything is fragmented.
- **Time slips away.** Unclear what you worked on, what you accomplished, where you're heading.

---

## The Solution: IDE, but for Thinking

**IWE (Intellectual Work Environment)** — an intellectual work environment.

Just as an IDE combines editor, compiler, and debugger into one environment for a programmer — IWE combines knowledge, planning, and AI agents into one environment for thinking.

| IDE (for code) | IWE (for thinking) |
|---------------|-------------------|
| Editor → write code | Exocortex → capture knowledge |
| Compiler → checks syntax | Principles → verify decision correctness |
| Debugger → finds errors | OWC protocols (Open→Work→Close) → find knowledge and context losses |
| Linter → improves quality | ArchGate → evaluates architectural decisions |
| Git → change history | Strategist → history and work planning |

> **Key principle: exoskeleton, not prosthesis.** IWE amplifies your thinking, not replaces it. After each session you become more competent, not just get a result. More: [principles-vs-skills.md](docs/principles-vs-skills.md).

<details>
<summary>Key IWE Terms</summary>

| Term | What it is |
|------|-----------|
| **Exocortex** | Your external memory — files with plans, context, conclusions that Claude reads in every session |
| **Pack** | Formalized knowledge base for your domain — the single source-of-truth for domain knowledge |
| **OWC** | Open → Work → Close — a ritual for every session and every day, prevents context loss |
| **ArchGate** | Structured evaluation of architectural decisions across 7 characteristics (instead of "I think it's fine") |
| **Strategist** | AI agent that automatically creates daily/weekly plans and tracks progress |

Full glossary: [ONTOLOGY.md](ONTOLOGY.md)

</details>

---

## Work Culture — a New Style of AI Interaction

IWE is not a collection of prompts. It's a **work culture**: 14 elements (protocols, skills, formats) that turn chaotic AI interaction into a managed process.

### OWC Protocol (Open → Work → Close)

Every session and every day goes through three stages:

- **Open** — Claude checks the plan, identifies the task, agrees on approach. You don't start from scratch — the AI knows the context.
- **Work** — as you work, Claude captures valuable knowledge (Capture-to-Pack). Insights are never lost.
- **Close** — results are recorded, plan is updated, next session picks up where you left off.

Skipping Open = unplanned work. Skipping Close = lost results.

### Exocortex — External Memory

Your knowledge, principles, distinctions, plans, and context are stored in files that Claude reads every session. This isn't a "prompt" — it's an **accumulated base** that grows with you.

### Knowledge Formalization (Pack)

What you learn doesn't stay in your head. Valuable knowledge is formalized into Pack — a domain knowledge passport. Pack is the single source-of-truth for domain knowledge. More: [LEARNING-PATH.md](docs/LEARNING-PATH.md).

---

## Who It's For

Every professional drowns in information: 12+ tools (Notion, Google Docs, Slack, ChatGPT, courses...), knowledge scattered, nothing connected. AI answers questions but doesn't know *your* context — every time from scratch.

IWE is for those who want to change this:

- **Entrepreneurs and executives** — strategizing, making decisions, managing projects. IWE provides a system: from weekly planning to domain knowledge formalization
- **Engineers and developers** — working with code and architecture. IWE preserves context between sessions, AI knows your codebase, tech debt, roadmap
- **Researchers and analysts** — studying, synthesizing, publishing. IWE turns scattered notes into a structured knowledge base that grows with you
- **Anyone doing intellectual work** — who wants **symbiosis with AI**, not dependence on it. An exoskeleton for thinking, not a prosthesis

---

## Use Cases

### Work Projects

| Scenario | What Happens |
|----------|-------------|
| **Product development** | Claude knows the architecture, tech debt, roadmap. Each session is a continuation, not a fresh start |
| **Documentation** | Knowledge is captured in Pack as you work. No need to "write docs later" — they're written during work |
| **Project coordination** | WeekPlan, DayPlan, work product registry — Strategist helps plan and track progress |
| **Review and refactoring** | ArchGate evaluates decisions across 7 characteristics. Not "I think it's good" — structured evaluation |

### Personal Development

| Scenario | What Happens |
|----------|-------------|
| **Taking a course** | Claude helps capture key ideas, asks comprehension questions, connects new material with what you already know |
| **Writing articles** | Creative pipeline: note → draft → template → publication. Every artifact is tracked |
| **Strategy sessions** | Weekly session: review last week, plan next week, align with goals. Strategist prepares a draft — you make decisions |
| **Building a knowledge base** | Your Pack grows. In six months you have a formalized domain knowledge base, not a collection of notes |

> Full catalog of 15 scenarios: **[USE-CASES.md](docs/use-cases/USE-CASES.md)**

---

## What It Looks Like in Practice

- Morning — Strategist created a plan: Telegram notification + DayPlan file in the repository
- Open VS Code → `claude` → Claude knows what's in the plan and suggests starting with the priority item
- Work — Claude captures knowledge along the way (Capture-to-Pack)
- Close session — results recorded, plan updated
- Monday — Strategist prepares a draft weekly plan, you discuss it in a strategy session

---

## Getting Started

**Quick start** (Git, Node.js, Claude Code already installed): **[QUICK-START.md](docs/QUICK-START.md)** — 15 minutes to your first session.

**Full installation** from a clean computer: **[SETUP-GUIDE.md](docs/SETUP-GUIDE.md)** — 30-60 minutes with all dependencies.

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

Tell Claude: **"Let's run our first strategy session"** — and it will guide you through setting goals, creating your first plan, and configuring the environment.

---

## Customization

IWE updates like a distribution — you receive platform updates without losing your settings.

**Extensions (extensions/)** — add your own blocks to protocols:

```bash
# Add end-of-day reflection
echo "## Daily Reflection
- What was challenging?
- What would I do differently?
- What went well?" > extensions/day-close.after.md
```

**Parameters (params.yaml)** — toggle protocol steps:

```yaml
reflection_enabled: true    # Enable reflection
video_check: false          # Disable video check
multiplier_enabled: true    # IWE multiplier
```

**Updates** — `bash update.sh` updates the platform while preserving your extensions/, params.yaml, and CLAUDE.md edits (3-way merge).

More: [extensions/README.md](extensions/README.md)

---

## Documentation

| Document | Contents |
|----------|---------|
| **[Beginner's Guide](docs/onboarding/onboarding-guide.md)** | Start here if you're new to IWE. What it is, why, what it consists of — no technical jargon |
| **[Quick Start](docs/QUICK-START.md)** | 15 minutes from `git clone` to first session. For those who already have Git and Claude Code |
| **[SETUP-GUIDE.md](docs/SETUP-GUIDE.md)** | Step-by-step installation from a clean computer. Requirements, modes (core/full), verification |
| **[LEARNING-PATH.md](docs/LEARNING-PATH.md)** | IWE learning path: architecture, principles, protocols, Pack, roles |
| **[DATA-POLICY.md](docs/DATA-POLICY.md)** | Data policy: what's collected, where it's stored, how to delete |
| **[IWE-HELP.md](docs/IWE-HELP.md)** | Quick reference and FAQ |
| **[principles-vs-skills.md](docs/principles-vs-skills.md)** | Why principles matter more than skills: generative hierarchy |
| **[ONTOLOGY.md](ONTOLOGY.md)** | Ontology: all IWE terms and abbreviations |
| **[CHANGELOG.md](CHANGELOG.md)** | Template change history |

---

## FAQ

**Q: Do I need an Anthropic subscription?**
A: For full installation (Claude Code) — Claude Pro ($20/mo) is recommended. You can upgrade to Claude Max (~$100/mo) for unlimited usage. For minimal installation (`setup.sh --core`) — works with any AI CLI. More: [SETUP-GUIDE.md](docs/SETUP-GUIDE.md).

**Q: Does it work with other AIs (not Claude)?**
A: Partially. All knowledge is stored in open formats (Markdown, YAML, Git) — it will survive any vendor switch. But automation (OWC protocols, skills, hooks, roles) is built for Claude Code CLI. For Codex (OpenAI), Aider, or other AI CLIs, you'll need to adapt `.claude/` and role scripts. Minimal installation (`setup.sh --core`) works without vendor lock-in.

**Q: Does it work on Linux/Windows?**
A: Yes. The core works on any OS. Strategist automation: macOS — launchd, Linux — cron, Windows — WSL. More: [SETUP-GUIDE.md](docs/SETUP-GUIDE.md).

**Q: What if my computer is off or sleeping — will automation stop?**
A: Cloud Scheduler (GitHub Actions) runs in the cloud even when your computer is off. For local agents: scripts automatically prevent sleep during execution (macOS: `caffeinate`, Linux: `systemd-inhibit`). For laptops, it's recommended to set up automatic wake and disable idle sleep — see [SETUP-GUIDE.md](docs/SETUP-GUIDE.md).

**Q: What is Pack?**
A: A formalized knowledge domain — the single source-of-truth for domain knowledge. More: [LEARNING-PATH.md](docs/LEARNING-PATH.md).

**Q: Is my data safe?**
A: Three protection zones: local, GitHub (private repos), platform (per-user isolation). More: [DATA-POLICY.md](docs/DATA-POLICY.md).

**Q: How is IWE different from Obsidian / Notion / Logseq?**
A: Obsidian is a note storage. IWE is a **work environment** with protocols, AI agents, and knowledge formalization. You can use Obsidian inside IWE for notes, but IWE provides structure, planning, and competence accumulation.

**Q: Do I need to code?**
A: No. The template is a ready-made configuration. Installation via setup.sh. Work — through Claude Code in natural language.

**Q: Can I use it without the Strategist?**
A: Yes. Claude Code + CLAUDE.md + memory/ work fully on their own. Strategist is planning automation. Without it, you plan manually.

---

## Community

IWE is an environment you build alone. But you grow it — together.

**IWE Community** — a practitioners' group working with the same system: OWC, Pack, exocortex. A place to discuss not "how to prompt better" but how to build intellectual work seriously.

**Free channels:**
- [GitHub Discussions](https://github.com/TserenTserenov/FMT-exocortex-template/discussions) — questions, ideas, show your setup
- [Issues](https://github.com/TserenTserenov/FMT-exocortex-template/issues) — bug reports and feature requests

**Premium community** (Telegram, Russian-speaking) — deep practice, work product reviews, direct support. Entry via the [@aist_me_bot](https://t.me/aist_me_bot) bot.

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines on how to contribute.

---

## License

MIT
