# IWE — Intellectual Work Environment

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-0.41.0-blue.svg)](CHANGELOG.md)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20%7C%20Windows%20(partial)-lightgrey.svg)]()

<img src="docs/assets/orz-cycle.svg" alt="Open, Work, Close — the same cycle at every scale: session, day, week" width="100%">

> The operating system for intellectual work. Your Knowledge. Your Experience. Your Environment — runs on top of any AI platform.
>
> **Repository type:** `Base/Formats` (FMT) — distribution template. After forking, it becomes your personal environment with AI agents.

---

## The Problem

AI assistants can generate text, code, and answers. But most users share the same pain points:

- **Context is lost.** Every new AI Session starts from scratch. Yesterday's decisions, plans, and agreements are forgotten.
- **Knowledge stays in your head.** You finish a course, read a book, solve a problem — but a month later you cannot reconstruct your reasoning.
- **AI replaces thinking instead of amplifying it.** You get an answer but do not become more competent. Without AI — back to zero.
- **No system.** Plans live in notes, tasks live in your head, Knowledge lives in chat threads. Everything is scattered.
- **Time disappears.** It is unclear what you worked on, what you accomplished, and where you are headed.

---

## The Solution: an IDE, but for Thinking

**IWE (Intellectual Work Environment)** is an intellectual work environment.

Just as an IDE unifies an editor, compiler, and debugger into one environment for a programmer — IWE unifies Knowledge, planning, and AI agents into one environment for thinking.

| IDE (for code) | IWE (for thinking) |
|---------------|-------------------|
| Editor → you write code | Exocortex → you capture Knowledge |
| Compiler → checks syntax | Principles → check the correctness of decisions |
| Debugger → finds errors | Opening→Work→Closing Protocols → find Knowledge and context losses |
| Linter → improves quality | ArchGate → assesses architectural decisions |
| Git → change history | Strategist → work history and planning |

> **Core principle: exoskeleton, not prosthetic.** IWE amplifies your thinking; it does not replace it. After every Session you become more competent — not just better informed. Details: [principles-vs-skills.md](docs/principles-vs-skills.md).

## Key IWE Terms

| Term | What it is |
|--------|---------|
| **Exocortex** | Your external Memory — files containing plans, context, and conclusions that Claude reads in every Session |
| **Pack** | A formalized Knowledge base for your Domain — the single source of truth for domain Knowledge |
| **Opening→Work→Closing** | A ritual for every Session and every day that prevents context loss |
| **ArchGate** | A structured Assessment of architectural decisions across 7 characteristics (instead of "I think this is fine") |
| **Strategist** | An AI agent that automatically drafts day/week plans and tracks Progress |
| **5 repository families** | The recommended structure for separating code, Knowledge, and data — see below |


### 5 Repository Families

The Exocortex is not a single Repository — it is a set of Repositories with clear boundaries: code, domain Knowledge, and personal data do not mix. `setup.sh` creates a minimal starting point (your own strategic Repository plus 3 base principles Repositories); additional Repositories are added as needed.

| Family | What it stores | Example name |
|---|---|---|
| Base (`ZP`/`FPF`/`SPF`/`FMT-*`) | Platform principles and formats — delivered ready to use | `ZP`, `FPF` |
| `PACK-*` | Formalized domain Knowledge (source of truth) | `PACK-my-domain` |
| `DS-*` | Code, plans, courses — derived from the Pack | `DS-strategy` |
| `PD-*` | Personal user data of a single type (no code) | `PD-persona`, `PD-metrics` |
| `MC-*` | Data for agents (dialogues, service logs) — not read by humans day-to-day | `MC-sessions` |

Detailed data domain map and rationale: [ADR-004](docs/adr/ADR-004-data-domain-map.md).

---

## Work Culture — a New Way of Interacting With AI


### The Opening→Work→Closing Protocol

Every Session and every day passes through three stages:

- **Opening** — Claude reviews the plan, identifies the task, and aligns on the approach. You do not start work from scratch — the AI knows the context.
- **Work** — as work proceeds, Claude captures valuable Knowledge (Capture-to-Pack). Insights are not lost.
- **Closing** — the result is recorded, the plan is updated, and the next Session picks up exactly where you left off.

Skipping Opening = unplanned work. Skipping Closing = lost result.

### Exocortex — External Memory

Your Knowledge, principles, Distinctions, plans, and context are stored in files that Claude reads in every Session. This is not a "prompt" — it is an **accumulated base** that grows with you.

### Knowledge Formalization (Pack)

What you learn does not stay only in your head. Valuable Knowledge is formalized into a Pack — the Domain passport. The Pack is the single source of truth for domain Knowledge. Details: [LEARNING-PATH.md](docs/LEARNING-PATH.md).

---

## Who It Is For

Every professional drowns in information: 12+ tools (Notion, Google Docs, Slack, ChatGPT, courses…), Knowledge is scattered, nothing is connected. AI answers questions but does not know *your* context — starting from scratch every time.

IWE is for those who want to change that:

- **Entrepreneurs and managers** — you strategize, make decisions, and run projects. IWE gives you a system: from weekly planning to formalizing domain Knowledge.
- **Engineers and developers** — you work with code and Architecture. IWE preserves context between Sessions; the AI knows your codebase, technical debt, and Roadmap.
- **Researchers and analysts** — you study, synthesize, and publish. IWE transforms scattered notes into a structured Knowledge base that grows with you.
- **Everyone who does intellectual work** — and wants **symbiosis with AI**, not dependence on it. An exoskeleton for thinking, not a prosthetic.

---

## Use Cases

### Work Projects

| Scenario | What happens | Details |
|----------|---------------|-----------|
| **Product development** | Claude knows the Architecture, technical debt, and Roadmap. Every Session continues where the last one ended — never from scratch. | [SC.013](docs/use-cases/USE-CASES.md#sc013), [SC.015](docs/use-cases/USE-CASES.md#sc015) |
| **Documentation** | Knowledge is captured into the Pack during work. No need to "write docs later" — they are written as you work. | [SC.004](docs/use-cases/USE-CASES.md#sc004), [SC.014](docs/use-cases/USE-CASES.md#sc014) |
| **Project coordination** | WeekPlan, DayPlan, Work Product Registry — the Strategist helps plan and track Progress. | [SC.001](docs/use-cases/USE-CASES.md#sc001), [SC.002](docs/use-cases/USE-CASES.md#sc002) |
| **Review and Refactoring** | ArchGate assesses decisions across 7 characteristics. Not "I think it looks good" — a structured Assessment. | [SC.015](docs/use-cases/USE-CASES.md#sc015) |

### Personal Development

| Scenario | What happens | Details |
|----------|---------------|-----------|
| **Taking a course** | Claude helps capture key ideas, asks questions to verify Understanding, and connects new material to what you already know. | [SC.003](docs/use-cases/USE-CASES.md#sc003) |
| **Writing articles** | Creative Pipeline: note → draft → prepared piece → publication. Every Artifact is tracked. | [SC.005](docs/use-cases/USE-CASES.md#sc005) |
| **Strategizing** | A weekly Session: Review of the past week, planning the new one, alignment with goals. The Strategist prepares a draft — you make the decisions. | [SC.011](docs/use-cases/USE-CASES.md#sc011) |
| **Building a Knowledge base** | Your Pack grows. After six months you have a formalized domain Knowledge base — not a collection of notes. | [SC.014](docs/use-cases/USE-CASES.md#sc014) |

> Full catalog of 15 scenarios: **[USE-CASES.md](docs/use-cases/USE-CASES.md)**

---

## What It Looks Like in Practice

- In the morning — the Strategist has drafted a plan: a Telegram notification plus a DayPlan file in the Repository.
- You open VS Code → `claude` → Claude knows what is in the plan and suggests starting with the top Priority.
- You work — Claude captures Knowledge along the way (Capture-to-Pack).
- You close the Session — the result is recorded, the plan is updated.
- On Monday — the Strategist prepares a draft weekly plan; you discuss it in a strategizing Session.

---

## Machine Requirements

A minimum of **4 GiB of free RAM** is required while Claude Code (or another agent) runs on top of IWE. With less memory — especially on shared servers with multiple users — file read/write tools may intermittently fail with a message such as `PreToolUse hook did not respond before its timeout`. This message indicates insufficient host-process memory, not a broken template Hook (issue [#461](https://github.com/iwesys/IWE/issues/461)) — `bash scripts/iwe-audit.sh` shows the current available memory level in the "Available memory" section.

## Getting Started

**Quick start** (Git, Node.js, and Claude Code already installed): **[QUICK-START.md](docs/QUICK-START.md)** — 15 minutes to your first Session.

**Full installation** from a clean machine: **[SETUP-GUIDE.md](docs/SETUP-GUIDE.md)** — 30–60 minutes including all dependencies.

**Not on macOS or not using Claude Code?** Read **[PORTABILITY.md](docs/PORTABILITY.md)** — instructions for Kimi Code, Hermes Agent, and others.

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

Tell Claude: **"Let's run the first strategic session"** — and it will guide you through defining goals, creating your first plan, and configuring the Environment.

---

## Customization

IWE updates like a distribution — you receive platform updates without losing your settings.

**Extensions (extensions/)** — add your own blocks to Protocols:

```bash
# Add end-of-day reflection
echo "## Daily reflection
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
|----------|-----------|
| **[Beginner's guide](docs/onboarding/onboarding-guide.md)** | Start here if you are new to IWE. What it is, why it exists, and what it consists of — no technical jargon. |
| **[Quick start](docs/QUICK-START.md)** | 15 minutes from `git clone` to your first Session. For those who already have Git and Claude Code. |
| **[SETUP-GUIDE.md](docs/SETUP-GUIDE.md)** | Step-by-step installation from a clean machine. Requirements, modes (core/full), verification. |
| **[LEARNING-PATH.md](docs/LEARNING-PATH.md)** | The IWE learning path: Architecture, principles, Protocols, Pack, Roles. |
| **[DATA-POLICY.md](docs/DATA-POLICY.md)** | Data policy: what is collected, where it is stored, how to delete it. |
| **[DATA-RESIDENCY.md](docs/DATA-RESIDENCY.md)** | Residency principle: data you bring into IWE from outside (health, calendar, working hours) — where it may and may not go. |
| **[IWE-HELP.md](docs/IWE-HELP.md)** | Quick reference and FAQ. |
| **[principles-vs-skills.md](docs/principles-vs-skills.md)** | Why principles matter more than Skills: the generative hierarchy. |
| **[CHANGELOG.md](CHANGELOG.md)** | Template change history. |

> Two documents cover related topics: `DATA-POLICY.md` covers data the platform collects about you; `DATA-RESIDENCY.md` covers data you bring into IWE from external sources.

---

## FAQ

**Q: Is an Anthropic subscription required?**
A: For the full installation (Claude Code) — Claude Pro ($20/month) is recommended. If needed, you can upgrade to Claude Max (~$100/month) for unlimited usage. For the minimal installation (`setup.sh --core`) — works with any AI CLI. Details: [SETUP-GUIDE.md](docs/SETUP-GUIDE.md).

**Q: Does it work with other AI systems (not Claude)?**
A: Yes, three agents are supported out of the box:
- **Claude Code** — full support: reads `CLAUDE.md`, all Skills and Hooks work.
- **Kimi Code** (VS Code) — reads `AGENTS.md` automatically when the repo is opened. Customization: `extensions/` or `AGENTS-agent-blocks.md`. Skills (`/day-open` etc.) via Claude Code.
- **Hermes Agent** — connect aisystant MCP via Hermes settings and it receives instructions automatically.

Other agents (Cursor, Copilot, Gemini) require adaptation. Details: [PORTABILITY.md](docs/PORTABILITY.md).
The minimal installation (`setup.sh --core`) works without binding to a specific agent.

**Q: Does it work on Linux/Windows?**
A: On macOS and Linux, standard workflows operate normally; Strategist automation uses launchd and systemd respectively, with GitHub Actions as the cloud option. On Windows, certain parts have been tested via Git Bash with native Python (Strategist lock, #1030), but `session-guard.sh` and Session opening require WSL2: in native Git Bash they fail upfront due to the Unix `fcntl` lock (#1032). Full IWE installation and updates on Windows remain untested — details: [SETUP-GUIDE.md](docs/SETUP-GUIDE.md) § Windows.

**Q: What if the computer is off or asleep — will automation stop?**
A: The Cloud Scheduler (GitHub Actions) runs in the cloud even when your computer is off. For local agents: Scripts automatically prevent sleep during operation (macOS: `caffeinate`, Linux: `systemd-inhibit`). For laptops, configuring automatic wake and disabling idle sleep is recommended — see [SETUP-GUIDE.md](docs/SETUP-GUIDE.md).

**Q: What is a Pack?**
A: A formalized Knowledge Domain — the single source of truth for domain Knowledge. Details: [LEARNING-PATH.md](docs/LEARNING-PATH.md).

**Q: Is my data secure?**
A: Three protection zones: local, GitHub (private repositories), and platform (per-user isolation). Details: [DATA-POLICY.md](docs/DATA-POLICY.md).

**Q: How is IWE different from Obsidian / Notion / Logseq?**
A: Obsidian is a note store. IWE is a **work environment** with Protocols, AI agents, and Knowledge formalization. For notes, you can open the governance Repository (`DS-strategy`) in Obsidian as a vault — that specific folder only. Opening the IWE root (`~/IWE`) as an Obsidian vault is not supported: it may contain very large Markdown files (for example, `FPF/FPF-Spec.md`) that cause Obsidian to show a blank screen. The entire workspace can be safely browsed in VS Code.

**Q: Is programming required?**
A: No. The template is a ready-made Configuration. Installation is via setup.sh. Work is done through Claude Code using natural language.

**Q: Can I use it without the Strategist?**
A: Yes. Claude Code + CLAUDE.md + memory/ work fully without it. The Strategist automates planning. Without it, you plan manually.

**Q: How do I configure the strategizing day?**
A: In `memory/day-rhythm-config.yaml`, change `strategy_day: sunday` to the day you want. Details: [LEARNING-PATH.md](docs/LEARNING-PATH.md).

**Q: The clone landed in `~` instead of `~/IWE`?**
A: All installation commands must be run in the same terminal Session. If you open a new one, it starts from `~`. Delete the folder from `~` and repeat from `cd ~/IWE`. Details: [SETUP-GUIDE.md](docs/SETUP-GUIDE.md).


---

## IWE Community

IWE is an Environment you build alone. But you develop it together.

The **IWE Community** is a closed chat for Practitioners who work within the same system: Opening→Work→Closing, Pack, Exocortex. A place where the conversation is not about "how to prompt better" — it is about building serious intellectual work.

### What Happens There

- **Work Product Reviews** — members share real Packs, plans, and Retrospectives. They receive feedback from people who understand what "Closing without capturing the result" means.
- **IWE installation and customization Experience** — what broke, how it was fixed, which extensions proved useful.
- **Methods discussion** — the Opening→Work→Closing fractal, ArchGate, Capture-to-Pack in Practice: what works and where theory diverges from reality.
- **Links and finds** — tools, patterns, SOTA that fit the IWE philosophy.

### Why This Matters

You can study the system alone. But most questions arise at the application stage: "How do I formalize this Knowledge Domain?", "Am I using Opening→Work→Closing correctly?", "Who has Experience with this tool?"

In the community, those questions get answers from people who have already been through it.

### Free Channels

- [GitHub Discussions](https://github.com/iwesys/IWE/discussions) — questions, ideas, show your setup.
- [Issues](https://github.com/iwesys/IWE/issues) — bug reports and feature requests.

### Closed Community (Telegram)

Deep Practice, Work Product Reviews, direct support. Entry is through the **"IWE for Practitioners"** seminar (5000₽) via the bot [@aist_me_bot](https://t.me/aist_me_bot).

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) — how to help the project.

**IWE team developers (level T4+):** the single entry point is [Getting started as a developer](docs/developer/). In 10 minutes you will understand the development Pipeline (6 stations, dual output) and complete your first task.

---

## License

MIT

