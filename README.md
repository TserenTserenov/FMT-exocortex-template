# IWE — Intellectual Work Environment

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Version](https://img.shields.io/badge/version-0.41.0-blue.svg)](CHANGELOG.md)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20%7C%20Windows%20(Git%20Bash)-lightgrey.svg)]()

<img src="docs/assets/orz-cycle.svg" alt="Open, Work, Close — the same cycle at every scale: session, day, week" width="100%">

> The operating system for intellectual work. Your Knowledge. Your Experience. Your Environment — runs on top of any AI platform.
>
> **Repository type:** `Base/Formats` (FMT) — distribution template. After forking, it becomes your personal environment with AI agents.

---

## The Problem

AI assistants can generate text, code, and answers. But most users face the same problems:

- **Context is lost.** Every new AI session starts from scratch. Yesterday's decisions, plans, and agreements are gone.
- **Knowledge stays in your head.** You completed a course, read a book, solved a problem — but a month later you cannot reconstruct your reasoning.
- **AI replaces thinking instead of amplifying it.** You get an answer but do not become more competent. Without AI — back to zero.
- **No system.** Plans are in notes, tasks are in your head, knowledge is scattered across chats. Everything is disconnected.
- **Time disappears.** It is unclear what you worked on, what you accomplished, and where you are headed.

---

## The Solution: An IDE, But for Thinking

**IWE (Intellectual Work Environment)** is an intellectual work environment.

Just as an IDE unites an editor, compiler, and debugger into one environment for a programmer — IWE unites knowledge, planning, and AI agents into one environment for thinking.

| IDE (for code) | IWE (for thinking) |
|---------------|-------------------|
| Editor → you write code | Exocortex → you capture knowledge |
| Compiler → checks syntax | Principles → verify the correctness of decisions |
| Debugger → finds errors | ORZ Protocols (Opening→Work→Closing) → find knowledge and context losses |
| Linter → improves quality | ArchGate → assesses architectural decisions |
| Git → change history | Strategist → work history and planning |

> **Core principle: exoskeleton, not prosthetic.** IWE amplifies your thinking — it does not replace it. After every session you become more competent, not merely more productive. More: [principles-vs-skills.md](docs/principles-vs-skills.md).

## Key IWE Terms

| Term | What it is |
|--------|---------|
| **Exocortex** | Your external Memory — files containing plans, context, and conclusions that Claude reads in every Session |
| **Pack** | A formalized Knowledge base for your Domain — the single source of truth for domain knowledge |
| **ORZ** | Opening → Work → Closing — a ritual for every Session and every day; prevents context loss |
| **ArchGate** | A structured Assessment of architectural decisions across 7 characteristics (instead of "I think this looks good") |
| **Strategist** | An AI agent that automatically drafts day/week plans and tracks Progress |
| **5 Repository Families** | The recommended structure for separating code, knowledge, and data — see below |


### 5 Repository Families

The Exocortex is not a single Repository — it is a set of Repositories with clear boundaries: code, domain knowledge, and personal data do not mix. `setup.sh` creates a minimal starting point (your own strategic Repository plus 3 base principles Repositories); the rest is added as needed.

| Family | What it stores | Example name |
|---|---|---|
| Base (`ZP`/`FPF`/`SPF`/`FMT-*`) | Platform principles and formats — delivered ready to use | `ZP`, `FPF` |
| `PACK-*` | Formalized domain knowledge (source of truth) | `PACK-my-domain` |
| `DS-*` | Code, plans, courses — derived from Pack | `DS-strategy` |
| `PD-*` | Personal user data of one type (no code) | `PD-persona`, `PD-metrics` |
| `MC-*` | Agent data (dialogues, service logs) — not read by humans day-to-day | `MC-sessions` |

Detailed data domain map and rationale: [ADR-004](docs/adr/ADR-004-data-domain-map.md).

---

## Work Culture — A New Way of Working With AI


### The ORZ Protocol (Opening → Work → Closing)

Every Session and every day passes through three stages:

- **Opening** — Claude reviews the plan, identifies the task, and agrees on the approach. You do not start from scratch — the AI knows the context.
- **Work** — as work proceeds, Claude captures valuable knowledge (Capture-to-Pack). Insights are not lost.
- **Closing** — the result is recorded, the plan is updated, and the next Session starts from where you left off.

Skipping Opening = unplanned work. Skipping Closing = lost result.

### Exocortex — External Memory

Your knowledge, principles, Distinctions, plans, and context are stored in files that Claude reads in every Session. This is not a "prompt" — it is an **accumulated base** that grows with you.

### Knowledge Formalization (Pack)

What you learn does not stay in your head. Valuable knowledge is formalized in a Pack — the passport for a Domain. Pack is the single source of truth for domain knowledge. More: [LEARNING-PATH.md](docs/LEARNING-PATH.md).

---

## Who It Is For

Every professional drowns in information: 12+ tools (Notion, Google Docs, Slack, ChatGPT, courses…), knowledge is scattered, nothing is connected. AI answers questions but does not know *your* context — every time from scratch.

IWE is for those who want to change that:

- **Entrepreneurs and managers** — you strategize, make decisions, and manage projects. IWE provides a system: from weekly planning to formalizing domain knowledge.
- **Engineers and developers** — you work with code and Architecture. IWE preserves context between Sessions; the AI knows your codebase, technical debt, and Roadmap.
- **Researchers and analysts** — you study, synthesize, and publish. IWE turns scattered notes into a structured knowledge base that grows with you.
- **Everyone who does intellectual work** — and wants **symbiosis with AI**, not dependence on it. An exoskeleton for thinking, not a prosthetic.

---

## Use Cases

### Work Projects

| Scenario | What happens | More |
|----------|---------------|-----------|
| **Product development** | Claude knows the Architecture, technical debt, and Roadmap. Every Session continues from where you left off — no starting from scratch. | [SC.013](docs/use-cases/USE-CASES.md#sc013), [SC.015](docs/use-cases/USE-CASES.md#sc015) |
| **Maintaining documentation** | Knowledge is captured in Pack during work. No need to "write docs later" — they are written as the work happens. | [SC.004](docs/use-cases/USE-CASES.md#sc004), [SC.014](docs/use-cases/USE-CASES.md#sc014) |
| **Project coordination** | WeekPlan, DayPlan, Work Product Registry — the Strategist helps plan and track Progress. | [SC.001](docs/use-cases/USE-CASES.md#sc001), [SC.002](docs/use-cases/USE-CASES.md#sc002) |
| **Review and Refactoring** | ArchGate assesses decisions across 7 characteristics. Not "I think this is good" — a structured Assessment. | [SC.015](docs/use-cases/USE-CASES.md#sc015) |

### Personal Development

| Scenario | What happens | More |
|----------|---------------|-----------|
| **Taking a course** | Claude helps capture key ideas, asks questions to verify Understanding, and connects new knowledge to what you already know. | [SC.003](docs/use-cases/USE-CASES.md#sc003) |
| **Writing articles** | A creative Pipeline: note → draft → prepared piece → publication. Every Artifact is tracked. | [SC.005](docs/use-cases/USE-CASES.md#sc005) |
| **Strategizing** | A weekly Session: Review of the past week, planning the new one, checking against goals. The Strategist prepares a draft — you make the decisions. | [SC.011](docs/use-cases/USE-CASES.md#sc011) |
| **Building a knowledge base** | Your Pack grows. After six months you have a formalized domain knowledge base, not a collection of notes. | [SC.014](docs/use-cases/USE-CASES.md#sc014) |

> Full catalog of 15 scenarios: **[USE-CASES.md](docs/use-cases/USE-CASES.md)**

---

## What This Looks Like in Practice

- In the morning — the Strategist has drafted a plan: a Telegram notification plus a DayPlan file in the Repository.
- You open VS Code → `claude` → Claude knows what is in the plan and suggests starting with the top Priority.
- You work — Claude captures knowledge along the way (Capture-to-Pack).
- You close the Session — the result is recorded, the plan is updated.
- On Monday — the Strategist prepares a draft weekly plan; you discuss it in a strategizing Session.

---

## Machine Requirements

A minimum of **4 GiB of free RAM** is required while Claude Code (or another agent) runs on top of IWE. With less memory — especially on shared servers with multiple users — file read/write tools may intermittently fail with a message such as `PreToolUse hook did not respond before its timeout`. This message indicates insufficient host-process memory, not a broken template Hook (issue [#461](https://github.com/iwesys/IWE/issues/461)) — `bash scripts/iwe-audit.sh` shows the current available memory level under the "Available memory" section.

## Getting Started

**Quick start** (Git, Node.js, and Claude Code already installed): **[QUICK-START.md](docs/QUICK-START.md)** — 15 minutes to your first Session.

**Full Installation** from a clean machine: **[SETUP-GUIDE.md](docs/SETUP-GUIDE.md)** — 30–60 minutes including all dependencies.

**Not on macOS or not using Claude Code?** See **[PORTABILITY.md](docs/PORTABILITY.md)** — instructions for Kimi Code, Hermes Agent, and others.

**Different agent or LLM?** IWE is not tied to Claude. If your agent can see files in the repo folder and edit files, it will work. How to connect → [PORTABILITY.md](docs/PORTABILITY.md).

```bash
mkdir -p ~/IWE && cd ~/IWE
gh repo fork iwesys/IWE --clone
cd FMT-exocortex-template
bash setup.sh
```

After Installation:

```bash
cd ~/IWE
claude
```

Tell Claude: **"Let's run our first strategic session"** — and it will guide you through defining goals, creating your first plan, and configuring the Environment.

---

## Customization

IWE updates like a distribution — you receive platform updates without losing your settings.

**Extensions (extensions/)** — add your own blocks to the Protocols:

```bash
# Add end-of-day reflection
echo "## Daily reflection
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


---

## Documentation

| Document | Contents |
|----------|-----------|
| **[Beginner's guide](docs/onboarding/onboarding-guide.md)** | Start here if you are new to IWE. What it is, why it exists, what it consists of — no technical jargon. |
| **[Quick start](docs/QUICK-START.md)** | 15 minutes from `git clone` to your first Session. For those who already have Git and Claude Code. |
| **[SETUP-GUIDE.md](docs/SETUP-GUIDE.md)** | Step-by-step Installation from a clean machine. Requirements, modes (core/full), verification. |
| **[LEARNING-PATH.md](docs/LEARNING-PATH.md)** | The IWE learning path: Architecture, principles, Protocols, Pack, Roles. |
| **[DATA-POLICY.md](docs/DATA-POLICY.md)** | Data policy: what is collected, where it is stored, how to delete it. |
| **[DATA-RESIDENCY.md](docs/DATA-RESIDENCY.md)** | The residency principle: data you bring into IWE from external sources (health, calendar, working hours) — where it may and may not go. |
| **[IWE-HELP.md](docs/IWE-HELP.md)** | Quick reference and FAQ. |
| **[principles-vs-skills.md](docs/principles-vs-skills.md)** | Why principles matter more than Skills: the generative hierarchy. |
| **[CHANGELOG.md](CHANGELOG.md)** | Template change history. |

> Two documents cover related topics: `DATA-POLICY.md` covers data the Platform collects about you; `DATA-RESIDENCY.md` covers data you bring into IWE from external sources.

---

## FAQ

**Q: Is an Anthropic subscription required?**
A: For a full Installation (Claude Code) — Claude Pro ($20/month) is recommended. If needed, you can upgrade to Claude Max (~$100/month) for unlimited use. For the minimal Installation (`setup.sh --core`) — works with any AI CLI. More: [SETUP-GUIDE.md](docs/SETUP-GUIDE.md).

**Q: Does it work with AI systems other than Claude?**
A: Yes, three agents are supported out of the box:
- **Claude Code** — full support: reads `CLAUDE.md`, all Skills and Hooks work.
- **Kimi Code** (VS Code) — reads `AGENTS.md` automatically when the repo is opened. Customization: `extensions/` or `AGENTS-agent-blocks.md`. Skills (`/day-open` etc.) via Claude Code.
- **Hermes Agent** — connect the aisystant MCP via Hermes settings and it will receive instructions automatically.

For other agents (Cursor, Copilot, Gemini) adaptation is required. More: [PORTABILITY.md](docs/PORTABILITY.md).
The minimal Installation (`setup.sh --core`) works without being tied to a specific agent.

**Q: Does it work on Linux/Windows?**
A: Yes. The core works on any OS. Strategist automation: macOS — launchd, Linux — systemd (user units), cloud option (OS-independent) — GitHub Actions. Windows: `setup.sh` and the core run via Git Bash (installed with Git for Windows) — WSL is not required; WSL remains a fallback for those who prefer a full Linux layer. A targeted check of the Strategist lock via Git Bash and native Python was passed in CI on `windows-latest` (#1030); full Installation and IWE update on Windows remain untested — see [SETUP-GUIDE.md](docs/SETUP-GUIDE.md) § Windows.

**Q: What if the computer is off or sleeping — will automation stop?**
A: Cloud Scheduler (GitHub Actions) runs in the cloud even when the computer is off. For local agents: Scripts automatically prevent sleep during execution (macOS: `caffeinate`, Linux: `systemd-inhibit`). For laptops, it is recommended to configure automatic wake and disable idle sleep — see [SETUP-GUIDE.md](docs/SETUP-GUIDE.md).

**Q: What is Pack?**
A: A formalized Knowledge Domain — the single source of truth for domain knowledge. More: [LEARNING-PATH.md](docs/LEARNING-PATH.md).

**Q: Is my data safe?**
A: Three protection zones: local, GitHub (private Repositories), Platform (per-user isolation). More: [DATA-POLICY.md](docs/DATA-POLICY.md).

**Q: How is IWE different from Obsidian / Notion / Logseq?**
A: Obsidian is a note store. IWE is a **work environment** with Protocols, AI agents, and knowledge formalization. For notes, you can open the governance Repository (`DS-strategy`) in Obsidian — use that specific folder as the vault. Using the IWE root (`~/IWE`) as an Obsidian vault is not supported: it may contain very large Markdown files (for example, `FPF/FPF-Spec.md`) that cause Obsidian to show a blank screen. The entire workspace can be safely viewed in VS Code.

**Q: Is programming required?**
A: No. The template is a ready-made Configuration. Installation is done via setup.sh. Work is done through Claude Code in natural language.

**Q: Can I use it without the Strategist?**
A: Yes. Claude Code + CLAUDE.md + memory/ work fully on their own. The Strategist is planning automation. Without it, you plan manually.

**Q: How do I configure the strategizing day?**
A: In `memory/day-rhythm-config.yaml`, change `strategy_day: sunday` to the desired day. More: [LEARNING-PATH.md](docs/LEARNING-PATH.md).

**Q: The clone ended up in `~` instead of `~/IWE`?**
A: All Installation commands must be run in the same terminal session. If you opened a new terminal — it starts from `~`. Delete the folder from `~` and repeat starting with `cd ~/IWE`. More: [SETUP-GUIDE.md](docs/SETUP-GUIDE.md).


---

## IWE Community

IWE is an Environment you build alone. But you develop it together.

The **IWE Community** is a closed chat for Practitioners who work with the same system: ORZ, Pack, Exocortex. A place where the conversation is not "how to prompt better" — but how to build intellectual work seriously.

### What Happens There

- **Work Product reviews** — participants share real Packs, plans, and Retrospectives. They receive feedback from people who understand what "Closing without recording a result" means.
- **IWE Installation and customization experience** — what broke, how it was fixed, which extensions proved useful.
- **Method discussions** — the ORZ fractal, ArchGate, Capture-to-Pack in practice: what works, where theory diverges from reality.
- **Links and discoveries** — tools, patterns, SOTA that fit the IWE philosophy.

### Why This Matters

Studying a system alone is possible. But most questions arise at the application stage: "How do I formalize this Knowledge Domain?", "Am I using ORZ correctly?", "Who has Experience with this tool?"

In the community, these questions get answers from people who have already been through it.

### Free Channels

- [GitHub Discussions](https://github.com/iwesys/IWE/discussions) — questions, ideas, show your setup
- [Issues](https://github.com/iwesys/IWE/issues) — bug reports and feature requests

### Closed Community (Telegram)

Deep Practice, Work Product reviews, direct support. Entry is through the **"IWE for Practitioners"** seminar (5000₽) via the bot [@aist_me_bot](https://t.me/aist_me_bot).

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) — how to help the project.

**IWE team developers (level T4+):** the single entry point is [Getting started as a developer](docs/developer/). In 10 minutes you will understand the development Pipeline (6 stations, dual output) and complete your first task.

---

## License

MIT

