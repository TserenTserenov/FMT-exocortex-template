# IWE Installation: Step-by-Step Guide

> This guide takes you from a clean computer to a working IWE in 30–60 minutes.
> Supports macOS, Linux, and Windows (via Git Bash — WSL is not required) — see notes in each step.
> Not sure what to change for your platform? → **[PORTABILITY.md](PORTABILITY.md)**
>
> **Source-of-truth:** `DP.IWE.002` (Pack). If this file conflicts with Pack, Pack takes Priority.
> Via Aisystant MCP: `knowledge_search("IWE installation template")`.
>
> **Need a shorter version?** → [QUICK-START.md](QUICK-START.md) (15 minutes, if Git, Node.js, and the CLI are already installed). This page covers full installation from scratch.

## Where You Are and Where You Are Going

The Platform opens access by tier (`DP.ARCH.002`): from T0 (no account) to T4 (Creation, IWE). You may already be using the bot — that is T1–T3. This guide moves you to **T4**, where a personal workspace with AI agents becomes available.

| Tier | What is included | How to access |
|------|-----------------|---------------|
| **T1: Start** | Bot @aist_me_bot: knowledge base search, marathons | `/start` in Telegram |
| **T2: Learning** | + Programs, guides, schedule | Subscribe to a program |
| **T3: Personalization** | + Personal responses, digital twin | `/twin` in the bot |
| **T4: Creation (IWE)** | + Claude Code, Strategist, Git, personal knowledge bases | **This guide** |

> Everything you have built at T1–T3 (Digital Twin, Profile, Progress) is preserved. T4 adds new capabilities; it does not replace existing ones.

## What You Will Have at the End

- **Claude Code** — an AI assistant that knows your goals, tasks, and methodology. Retains context between Sessions
- **Strategist** (AI agent) — prepares a daily plan each morning; on Sundays, a weekly summary
- **Extractor** (AI agent, later) — pulls Knowledge from Sessions into the knowledge base
- **Synchronizer** (later) — agent scheduler, Telegram notifications
- **DS-strategy** — your personal strategic hub (private Repository on GitHub)
- **Personal guide** — an optional Development Trajectory built from your goals and context
- **Telegram notes** — write a thought in the bot and it enters the planning system

### Stage Map

| Stage | What | Time | On first install |
|-------|------|------|-----------------|
| **0** | Preparation (Git, Node, Claude Code) | 15–20 min | **required** |
| **1** | IWE installation | ~5 min | **required** |
| **2** | First strategic Session | ~30 min | **required** |
| **2a** | Personal guide | 10–20 min | can do later |
| **3** | Telegram notes | 5 min | can do later |
| **4** | WakaTime (time tracking) | 10 min | can do later |
| **5** | Google Calendar | 10 min | can do later |
| **6** | Video Integration | 5 min | can do later |
| **7** | Agent Workspace (agent data) | 10 min | when >2 agents |

> **Minimum to start:** Stages 0 → 1 → 2. Everything else can be connected at any time — tell Claude *"set up calendar"* or *"connect video recordings"*.
>
> **Kimi as a second agent:** if you want to work in IWE with Kimi Code as well as Claude, see [`docs/KIMI-SETUP.md`](KIMI-SETUP.md).

## How to Open a Terminal

All commands in this guide run in a **terminal** — a program where you enter text commands.

**macOS:**
- Press `Cmd + Space` (Spotlight) → type `Terminal` → press Enter
- Or: Finder → Applications → Utilities → Terminal

**Windows:**
- Install [Git for Windows](https://git-scm.com/download/win) (default checkboxes are fine)
- Open **Git Bash** — Start → type `Git Bash` → press Enter. WSL is not required; details → [§ 0.0 "Windows: without WSL"](#00-windows-without-wsl)

**Linux:**
- `Ctrl + Alt + T` (in most distributions)

> In the terminal you will see a line like `username@computer:~$` — that is the prompt. Type a command and press Enter.

## Stage 0: Preparation (15–20 min)

If Git, Node.js, GitHub CLI, and Claude Code CLI are already installed, skip to [Stage 1](#stage-1-iwe-installation-5-min).

> **⚠ Network restrictions (Russia and similar regions).** Some downloads below (GitHub, npm, Homebrew) may be blocked directly. Standard workarounds: VPN, system proxy, or `torify <command>` for individual calls — for example `torify curl ...` or `torify git clone ...` (`torify` is often insufficient for `npm`/`brew`; those usually require their own proxy/registry configuration). If a specific step below fails, check whether this is the cause before debugging the error.

### 0.0 Windows: Without WSL

WSL is **not required**. The IWE core consists of standard bash scripts (`setup.sh` and others), and bash on Windows comes with **Git for Windows** — installing WSL just for this is unnecessary.

1. **Git for Windows** — download from [git-scm.com](https://git-scm.com/download/win) and install (default checkboxes are fine). It includes **Git Bash** — a terminal with bash where all commands in this guide work.
2. **Run all steps in Stage 0 and Stage 1** (Node.js, GitHub CLI, Claude Code CLI, `setup.sh`) **from Git Bash**, not from PowerShell/cmd — commands using `curl`, `xcode-select`, etc. will not work in PowerShell.
   - Node.js — installer from [nodejs.org](https://nodejs.org/) (LTS version).
   - GitHub CLI — installer from [cli.github.com](https://cli.github.com/) or `winget install --id GitHub.cli` (can be run from regular PowerShell; installs system-wide).
   - Claude Code CLI — the same command `npm install -g @anthropic-ai/claude-code` as on macOS/Linux (Git Bash can use `npm` if Node.js is on PATH).
3. **Automatic Claude Code hooks** (pre/post-commit, etc.) call `.sh` files via the system shell — on Windows this works only if `bash` (from Git for Windows) is in the system `PATH`. The Git for Windows installer usually adds it automatically; if hooks do not fire, check `where bash` in cmd.
4. **Local automation (Strategist/Extractor without human involvement)** — Windows has no `launchd`/`systemd`; the closest equivalent is Windows Task Scheduler (see the example in the [Auto-wake](#automatic-wake-and-sleep-prevention) section below). A simpler path without local jobs is the cloud option via GitHub Actions (OS-independent; nothing needs to stay on).
5. **If you still want a full Linux environment** — WSL remains a working fallback (`wsl --install` in an administrator PowerShell); it is simply no longer a required condition for installing IWE.

> **Honest caveat.** In CI on `windows-latest` via Git Bash and native Python, only the Strategist lock race check (HD #1030) has been verified. Full IWE installation and updates on Windows via Git Bash, and the WSL path, have not been tested end-to-end. If you hit a specific, reproducible failure in Git Bash, open an [issue in FMT-exocortex-template](https://github.com/TserenTserenov/FMT-exocortex-template/issues) — that is more useful than guessing in advance.

### 0.1 Homebrew (macOS only)

Homebrew is the package manager for macOS. It lets you install the remaining tools with a single command. If it is already installed, skip this step.

In the terminal:
```bash
# Check whether Homebrew is installed
brew --version

# Install (if not present)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

After installation, Homebrew may ask you to run a command to update PATH — copy and run it.

### 0.2 Git

Git is a version control system. It stores the history of file changes and lets you sync work via GitHub.

In the terminal:
```bash
# Check
git --version

# Install
# macOS:
xcode-select --install
# Linux:
# sudo apt install git
```

### 0.3 Node.js and npm

Node.js is a JavaScript runtime. It is required to install the Claude Code CLI. npm is the Node.js package manager (installed together with Node.js).

In the terminal:
```bash
# Check
node --version    # must be v18+
npm --version

# Install
# macOS:
brew install node
# Linux:
# curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash - && sudo apt install -y nodejs
```

### 0.4 GitHub CLI and Account

GitHub CLI (`gh`) is a tool for working with GitHub from the terminal. The installer uses it to create Repositories and copy the Template.

**GitHub account:** if you do not have one, register at [github.com](https://github.com/signup).

In the terminal:
```bash
# Check
gh --version

# Install
# macOS:
brew install gh
# Linux:
# https://cli.github.com/ — see installation instructions
```

Now authenticate with GitHub (one time only):
```bash
gh auth login
# Choose: GitHub.com → HTTPS → Login with a web browser
# A browser window opens → sign in to your GitHub account
```

Verify:
```bash
gh auth status
# Should show: ✓ Logged in to github.com as <username>
```

**If browser login fails** (`Login with a web browser`) — at the authentication method prompt, choose `Paste an authentication token` instead. This option does not open a browser; `gh` waits for a token you supply:

1. Open `https://github.com/settings/tokens` in your browser.
2. Create a token: **classic** (`Tokens (classic)` — a separate tab/link; the default page opens on fine-grained), with at least `repo` and `workflow` scopes (needed so the forked template can push `.github/workflows`). Classic is simpler for this scenario — the required scopes are clear; do not restrict the token to specific Repositories (`setup.sh` creates new ones).
3. Copy the token and paste it into the terminal when `gh auth login` prompts for it.
4. Verify with the same `gh auth status` command above.

### 0.5 Claude Code CLI

Claude Code is an AI agent that runs in the terminal (or in VS Code). It reads files, executes commands, and helps with planning and writing code.

Requires an Anthropic subscription. Start with **Claude Pro** ($20/month). Use **Claude Max** (~$100/month) if you need to work without usage limits.

In the terminal:
```bash
# Install
npm install -g @anthropic-ai/claude-code

# Check
claude --version
```

On first launch, Claude Code will ask you to sign in to your Anthropic account — follow the instructions in the terminal.

### 0.5b Cost Optimization: Choosing a Model

Claude Code lets you choose a model for each task. Choosing correctly conserves your subscription limit:

| Model | Verification class | When to use | Cost |
|-------|--------------------|-------------|------|
| **Opus** | open-loop, problem-framing | Architecture, complex code, strategy, multi-system changes | High |
| **Sonnet** | closed-loop | Routine tasks, single-file edits, writing content | Medium |
| **Haiku** | trivial | Renaming, updating links, Formatting, finding a file, cron agents | Low |

To switch models in Claude Code: `/model` → select. For automated tasks (Strategist, Extractor), Haiku is recommended — it saves ~80% of your limit compared to Opus.

> **How it works — two scenarios:**
> - **Entire session on a different model:** When Claude Code opens, Claude identifies the verification class. If the task is trivial/closed-loop and the current model is excessive, Claude will say: *"I recommend switching to [Haiku/Sonnet] via `/model`. I cannot switch automatically."* The user switches manually.
> - **Individual task within a session:** If a trivial task appears mid-session, Claude delegates it to a sub-agent on a cheaper model. The main session is not interrupted. Delegation goes down only (Opus→Sonnet/Haiku, Sonnet→Haiku). Switching up requires `/model`.
>
> **Tip:** On a Claude Pro subscription ($20/month), use Haiku actively for routine work (morning plans, file searches, trivial edits). Use Opus only for architectural decisions and complex code.

### 0.6 VS Code (recommended)

VS Code is a code editor with a graphical interface. It provides a convenient environment for Claude Code: you see all your repos, files, a terminal, and the AI assistant in one window, and you can switch between repos of different projects within one session. **Without VS Code** you work through the terminal only — this is possible, but less convenient.

- Download and install: [code.visualstudio.com](https://code.visualstudio.com/)
- Open VS Code → press `Cmd+Shift+X` (macOS) or `Ctrl+Shift+X` (Windows/Linux) → search for "Claude Code" → click Install

If you use Obsidian, open only the governance Repository `DS-strategy` as a vault. Opening the IWE root (`~/IWE`) as an Obsidian vault is not supported: large technical Markdown files such as `FPF/FPF-Spec.md` can hang the indexer and leave a blank screen. Open the full workspace in VS Code; do not link technical Repositories into the governance vault via symbolic links.

## Stage 1: IWE Installation (~5 min)

### 1.1 Create a Working Folder

Create **one folder** on your computer for all Repositories — current and future. All Repositories will be cloned into it: `FMT-exocortex-template/`, `DS-strategy/`, `PACK-{domain}/`, `DS-{projects}/`, and others. `CLAUDE.md` will also live at the root of this folder. The default is `~/IWE`:

```bash
mkdir -p ~/IWE
cd ~/IWE
```

> **Important:** The folder name can be anything, but all repos must be in one place — Claude Code relies on this structure. `~/IWE` is recommended.

### 1.2 Fork the Template and Run Setup

In the terminal:

```bash
# Make sure we are in the working folder
cd ~/IWE

# Fork the template to your GitHub and clone it
gh repo fork TserenTserenov/FMT-exocortex-template --clone
cd FMT-exocortex-template

# Run setup
bash setup.sh
```

> **Preview without running:** `bash setup.sh --dry-run`

The Script will ask:

| Question | What to enter | Example |
|----------|--------------|---------|
| GitHub username | Your GitHub login | `ivan-petrov` |
| Workspace directory | Working folder | Just press Enter (detected automatically) |
| Claude CLI path | Path to claude | Just press Enter (detected automatically) |
| Strategist launch hour (UTC) | Strategist start hour | `4` (= 7:00 MSK, 8:00 Almaty) |
| Timezone description | Time description | `7:00 MSK` |

The Script performs 6 steps:
1. Substitutes your data into all files (name, paths, timezone)
2. Installs `CLAUDE.md` — rules for Claude Code
3. Installs `memory/` — working Memory for Claude Code
4. Configures permissions (`.claude/settings.local.json`) and outputs instructions for connecting MCP
5. Sets up automatic Strategist launch (launchd on macOS)
6. Creates `DS-strategy/` — your private strategic Repository on GitHub

### 1.2b Fork Visibility and Personal Data

`gh repo fork` creates a **public** fork: GitHub does not allow making a fork of a public Repository private. Therefore:

- The `FMT-exocortex-template/` directory contains Platform files (methodology, scripts, samples). Everything you commit and push from there is visible to anyone.
- Personal data is stored **outside** this directory: `memory/` lives in Claude Code's Memory (`~/.claude/projects/<slug>/memory`; in the working folder this is a symlink to it), `extensions/` and `params.yaml` are in the working folder, and strategy and Memory backup are in the separate private Repository `DS-strategy`.
- The `memory/` and `extensions/` directories inside the template clone are Platform samples, not your data. Do not edit them for personal use and do not push personal context into the fork.

**Need a private template Repository?** It cannot be a fork. Make a private duplicate and keep the original as `upstream`:

```bash
git clone --bare https://github.com/TserenTserenov/FMT-exocortex-template.git
cd FMT-exocortex-template.git
gh repo create FMT-exocortex-template --private
git push --mirror "https://github.com/<your-login>/FMT-exocortex-template.git"
cd .. && rm -rf FMT-exocortex-template.git
git clone "https://github.com/<your-login>/FMT-exocortex-template.git"
cd FMT-exocortex-template
git remote add upstream https://github.com/TserenTserenov/FMT-exocortex-template.git
```

Known behavior of the private copy (derived from reading the code; a full run on a private copy has not been performed):

| Part | What happens |
|------|-------------|
| `update.sh` | Fetches updates from the hardcoded original address (`UPSTREAM-CONST`), not from your fork or copy — switching from a fork to a copy does not change the update source. One exception: in the release channel, the rollback check runs `git fetch origin <release commit>` in your clone; if the copy does not have that commit, auto-apply with `--yes` stops, but interactive mode works. |
| `scripts/fmt-critical-alert.sh` | A copy has no "parent", so the script checks **its own** issue list — which is empty. A result of "0 (✅ clean)" means "nothing to check", not "no problems" (if the tracker is disabled, the script exits with "cannot check"). Set `IWE_FMT_REPO=TserenTserenov/FMT-exocortex-template` (environment variable or a line in `.exocortex.env`) to make it check the original's issues. |
| Connecting the template directory to knowledge search (MCP) | Not tested in this scenario. |

### 1.3 Verify Installation

In the terminal:
```bash
# Should exist
ls ~/IWE/CLAUDE.md

# Should contain memory files (10+)
ls ~/.claude/projects/*/memory/

# Strategic hub should exist
ls ~/IWE/DS-strategy/

# Strategist should be scheduled (macOS)
launchctl list | grep strategist
```

If everything is present, verify the MCP connection (1.3b) and proceed to Stage 2. Additional Roles (1.4) can be installed later.

### 1.3b Connect MCP Servers

MCP (Model Context Protocol) gives Claude Code access to the Platform knowledge base and your personal Repositories. Through it, Claude can see documents, guides, the digital twin, and your own Pack repos — subject-area knowledge bases you build over time.

> **Why:** Documentation and Pack entities (DP.IWE.001, DP.ARCH.001, etc.) reference the source-of-truth in PACK-digital-platform. After connecting MCP, Claude can find these entities on request and work with your personal repos directly. Without MCP, entities are accessible only as files on GitHub.

> The steps below cover Claude Code (via `claude.ai`). For other agents (Hermes, etc.) see `AGENT-VENDOR-SETUP.md`, Step 6.

**Connection:**

1. Open https://claude.ai/settings/connectors
2. Add an MCP server (Aisystant MCP): `https://mcp.aisystant.com/mcp`
3. Restart Claude Code

**How it works:** Claude Code connects to Aisystant MCP via claude.ai connectors. The server aggregates all backends (knowledge, digital-twin) and provides tools (`knowledge_search`, `knowledge_get_document`, `knowledge_feedback`, `dt_read_digital_twin`, and others).

#### Verification

Open Claude Code in the exocortex folder and type `/mcp` — servers should show as Connected. Then ask:
> Find documents about principles

Claude should use `knowledge_search("principles")` and return a list of documents from the knowledge base.

**Diagnostics:**

```bash
# Check the full installation (env, files, extensions, MCP availability)
bash FMT-exocortex-template/setup.sh --validate
```

| Problem | Solution |
|---------|---------|
| `/mcp` — no servers | Repeat steps 1–3 (claude.ai connectors) |
| Opened URL in browser — "Not found" | Normal. MCP operates via POST (JSON-RPC), not GET. Check via `/mcp` in Claude Code. |
| Aisystant MCP — connection error | Check your internet connection |
| `--validate` shows errors | Follow the hints. Fill in missing keys in `.exocortex.env` |

> **Tip:** `setup.sh --validate` checks ALL categories at once: env config, required files, extensions, MCP availability.

### 1.3c Connect Your Repositories to Personal Search (Optional)

Step 1.3b gives Claude access to the Platform knowledge base. Your own Repositories (notes, Pack, work projects) are not included in that search by default — they must be connected separately.

**How to connect:** tell the agent "connect my GitHub". It will call the `github_connect` tool and provide a link to install the `aisystant-knowledge` GitHub App. On that GitHub page you select which Repositories to open and click Install — no additional configuration is needed. Only what you explicitly select is indexed.

> **On privacy:** the content of selected Repositories (including private ones) leaves your machine and GitHub and is stored on the Platform server as a search index — this is necessary for semantic search rather than keyword matching. Do not connect a Repository if you are not comfortable with this.

After installation, indexing runs automatically: the initial pass is usually fast, but may take longer for large Repositories. After that, every push triggers automatic re-indexing without any local involvement.

### 1.4 Installing Additional Roles (Later)

`setup.sh` installs only the Strategist. The Extractor and Synchronizer are installed separately, once you are comfortable with the basic cycle:

In the terminal:
```bash
cd ~/IWE/FMT-exocortex-template

# Extractor — extracts knowledge from sessions, checks inbox (every 3 hours)
bash roles/extractor/install.sh
# Inbox check runs without you (headless) — a one-time sign-in to the subscription is needed:
bash roles/extractor/scripts/connect.sh

# Synchronizer — central scheduler: agent scheduling, notifications, code-scan
bash roles/synchronizer/install.sh
```

> **Recommendation:** The Extractor and Synchronizer can be installed later, once you are comfortable with the basic Strategist cycle. Details: [roles/extractor/README.md](../roles/extractor/README.md) and [roles/synchronizer/README.md](../roles/synchronizer/README.md).

> **Important:** If you install the Synchronizer, it replaces the individual Strategist launchd agents with a single unified scheduler. All Roles run on schedule from one place.

## Something Is Not Working?

**`CLAUDE.md` not found:**
```bash
cp ~/IWE/FMT-exocortex-template/CLAUDE.md ~/IWE/CLAUDE.md
```

**Memory not found:**
```bash
# Determine slug
echo $HOME/IWE | tr '/' '-'
# Example output: -Users-ivan-IWE

# Create directory and copy
mkdir -p ~/.claude/projects/-Users-ivan-IWE/memory
cp ~/IWE/FMT-exocortex-template/memory/*.md ~/.claude/projects/-Users-ivan-IWE/memory/
```

**launchd not loaded:**
```bash
cd ~/IWE/FMT-exocortex-template/roles/strategist
bash install.sh
```

**DS-strategy not created:**
```bash
cd ~/IWE
mkdir -p DS-strategy/{current,inbox,docs,archive/wp-contexts,exocortex}
cd DS-strategy && git init && git add -A && git commit -m "Initial"
gh repo create $(gh api user -q .login)/DS-strategy --private --source=. --push
```

## Restoring on a New Device (From an Exocortex Backup)

If IWE is already configured on one device, you do **not** need to initialize Memory from scratch on a new one. `day-close.sh --backup` and the `memory-exocortex-sync.sh` hook maintain a mirror of Memory in `DS-strategy/exocortex/`, which is pushed to GitHub together with the governance repo. `restore-from-exocortex.sh` restores it.

**Steps on a new device:**

```bash
# 1. Stage 0 (binaries, gh auth, claude CLI) — as usual
# 2. Working folder + clone the template and governance repo (it carries exocortex/)
mkdir -p ~/IWE && cd ~/IWE
gh repo fork TserenTserenov/FMT-exocortex-template --clone
git clone https://github.com/<your-login>/DS-strategy.git

# 3. Restore Memory from backup (instead of initializing from scratch)
bash ~/IWE/FMT-exocortex-template/scripts/restore-from-exocortex.sh ~/IWE/DS-strategy
#    --dry-run  — preview without changes
#    --force    — overwrite an already-populated memory/

# 4. Restart Claude Code → Memory is in place
```

The Script: copies `exocortex/*.md|*.yaml` → auto-memory (`~/.claude/projects/<slug>-IWE/memory/`), `exocortex/CLAUDE.md` → `~/IWE/CLAUDE.md`, creates a symlink `~/IWE/memory → auto-memory`. A non-empty `memory/` is not touched without `--force` (protection against accidentally overwriting a working installation).

## Stage 2: First Strategic Session (~30 min)

This is the most important step — you configure your goals and create the first plan.

**Option A — via VS Code (recommended):**
1. Open VS Code
2. `File → Open Folder` → select the `~/IWE` folder
3. Open the Claude Code panel: `Cmd+Shift+P` (macOS) or `Ctrl+Shift+P` (Windows) → type "Claude Code: Open" → Enter

**Option B — via terminal:**
```bash
cd ~/IWE
claude
```

Tell Claude:

> **"Let's run the first strategic session"**

Claude will read CLAUDE.md and memory/ and guide you through:

1. **Defining goals** — Who do you want to be in a year? What do you want to learn?
2. **Dissatisfactions** — What is getting in the way? Where is the gap between current and desired state?
3. **First WeekPlan** — Concrete tasks for the week with time budgets
4. **Registration in WP-REGISTRY.md and WeekPlan** — Work Products from the Session appear in the registry and the plan

**Result:** populated `DS-strategy/docs/Strategy.md`, `Dissatisfactions.md`, and a first `WeekPlan` in `DS-strategy/current/`.

### Personal Guide (up to 60 min, experimental and optional)

This step is not required for IWE to work. The safe choice is to skip it until you specifically need a public guide. The `/personal-guide-start` command does not ask clarifying questions: its first action is to create or reuse an external **public** GitHub Repository `DS-personal-guide` (`private: false`). Run it only if you intentionally accept this external effect.

Before running, you need an active "Engineering of Intelligence" subscription, GitHub connected in Aisystant MCP, and the `create_repository` and `github_status` operations available. Populating the six files is handled by a separate command `/personal-guide-render`; it additionally requires Memory.Derived and the `personal_write` operation. If the server-side renderer or these operations are unavailable, the bootstrap will not complete: a created public Repository may already exist on GitHub without the six completed files. Do not treat this state as a finished personal guide.

If the command itself is not visible, check for `.claude/skills/personal-guide-start/SKILL.md` and restart Claude Code. If the command is visible but the server-side operations are unavailable, do not run it again blindly — restore the GitHub/Aisystant MCP connection and the renderer first.

## Stage 3: Setting Up Telegram Notes (5 min, optional)

To send thoughts into the planning system directly from Telegram:

1. Find the bot **@aist_me_bot** in Telegram
2. Press `/start`
3. Subscribe (if you have not already)

**How to send notes:**
- Write: `.My thought about architecture` (dot + text)
- Or forward/reply to any message with `.`

The note will land in `DS-strategy/inbox/fleeting-notes.md` and wait there for your decision. Notes are not processed automatically in the evenings. When you are ready, process them in one of three ways: open the "Note review" section in the daily plan (a mini-review in Day Open, which lists notes awaiting a decision); in a Claude Code session, ask: "Review notes according to the instructions in `roles/strategist/prompts/note-review.md`" (the agent will go through all steps); or run in the terminal `bash ~/IWE/FMT-exocortex-template/roles/strategist/scripts/strategist.sh note-review` (terminal mode produces only annotations and suggestions, with no chat). The Strategist will suggest where to route each note: task → plan, knowledge → captures, idea → for discussion. Moving a note out of the inbox and into the archive requires your explicit confirmation in a live Session.

## Stage 4: WakaTime — Time Tracking (10 min, optional)

WakaTime tracks work time automatically: by project, language, and category.

In VS Code or the terminal, start Claude Code and say:

> **/setup-wakatime**

Claude will guide you through the installation:
1. wakatime-cli
2. API key (get it at [wakatime.com/settings/api-key](https://wakatime.com/settings/api-key))
3. Hooks for Claude Code
4. Desktop App (optional)

After setup: WakaTime data is automatically included in the morning daily plan and the weekly report.

> **Privacy:** WakaTime is a SaaS service (wakatime.com, AWS servers, USA). The server receives **metadata** about your work: project names, file names, languages, branches, active time. File **contents** are **not** sent. The CLI is open source ([github.com/wakatime/wakatime-cli](https://github.com/wakatime/wakatime-cli)). The Desktop App is closed source and requests Accessibility permission (can see active windows). If metadata is sensitive, use the self-hosted alternative [Wakapi](https://github.com/muety/wakapi) (wakatime-cli supports a custom `api_url` in `~/.wakatime.cfg`).

## Stage 5: Google Calendar — Day Events in Day Open (10 min, optional)

Connecting Google Calendar lets you see the day's events directly in the morning plan, create events from Claude Code, and prepare for meetings.

### What You Get

- **Day Open** shows a table of the day's events plus free slots for work
- **Event creation** — "schedule a call on Wednesday at 11:00" directly from Claude Code
- **Meeting preparation** — Claude pulls in context from related Work Products

### Setup (~1 min)

From the template root, run one command:

```bash
bash setup/optional/setup-calendar.sh
```

The Script:
1. Writes OAuth credentials (Shared App IWE) to `.secrets/`
2. Creates `.mcp.json` with Calendar MCP settings
3. Opens a browser → sign in with your Google account → click "Allow"
4. Restart Claude Code → verify: **"show my events for today"**

> **⚠ Google may show "This app isn't verified".** This is normal — click "Advanced" → "Go to IWE (unsafe)". This warning disappears after the app is verified.

### Multiple Accounts

You can connect multiple Google accounts (work + personal):

```
Claude, connect another Google Calendar account
```

Each account receives a nickname (`personal`, `work`) for addressing.

### Privacy

Calendar data is processed via the Google Calendar API. OAuth tokens are stored locally. Event content is sent to the Claude API to generate the daily plan. Confidential events (`visibility=private`) can be excluded from display.

## Stage 6: Video Integration — Linking Recordings to Work Products (5 min, optional)

If you record meetings (Zoom, Telemost, Google Meet), Claude can scan folders with recordings and link videos to Work Products.

### What You Get

- **Day Open** shows new video recordings linked to Work Products
- **Strategy Session** — a weekly Review of all unprocessed videos
- **Transcription** → automatic captures and ideas for posts (optional, requires whisper)

### Setup

1. Open `memory/day-rhythm-config.yaml`
2. In the `video` section, specify your folders:

```yaml
video:
  enabled: true
  directories:
    - ~/Documents/Zoom
    - ~/Documents/Telemost
    # Add your own video recording folders
```

3. Verify: **"show my video recordings"** — Claude will run `video-scan.sh`

### Where to Find Folders

| Application | Typical path (macOS) |
|------------|---------------------|
| Zoom | `~/Documents/Zoom` |
| Yandex Telemost | `~/Documents/Telemost` or `~/Video Recordings Telemost` |
| Google Meet | Recordings in Google Drive (not local) |
| OBS | Configured in OBS → Settings → Output |

### Linking to Work Products

The Script links videos to Work Products by file name:
- `WP-73-...mp4` → linked to WP-73
- `2026-03-14-...mp4` → linked by date (matched against the calendar)
- Others → manual linking is suggested

### Transcription (Optional)

For automatic transcription, install [whisper](https://github.com/openai/whisper):

```bash
pip install openai-whisper
```

Then enable it in the config:

```yaml
video:
  auto_transcribe:
    enabled: true
```

## Stage 7: Agent Workspace — Separate Storage for Agent Data (10 min, optional)

### Read Before Deciding

This is a **deliberate choice**, not a required step. Two questions will help you decide:

**1. Do you have autonomous agents?**

If you have just started working with IWE and are only using Claude Code interactively, **you do not need this**. All scheduler reports will be stored in `DS-strategy/current/` and `DS-strategy/archive/` — that is sufficient.

**2. Are agents generating >10 files per week?**

When the Scheduler, Scout, Extractor, and other agents run daily, they produce dozens of files: scheduler reports, bot QA reports, findings, draft plans. These auto-commits pollute the git history of DS-strategy, which should contain only **human decisions** (plans, approved captures).

### What Agent Workspace Provides

| Without Agent Workspace | With Agent Workspace |
|------------------------|---------------------|
| Everything in DS-strategy | Machine output is separate |
| Git history is mixed | Clean history of decisions |
| 1 Repository | 2 Repositories |
| Simpler to start | Scales better |

### Setup

```bash
bash setup/optional/setup-agent-workspace.sh
```

The Script creates a private GitHub repo `DS-agent-workspace` with a structure for each agent type. After creation, the scheduler scripts (`daily-report.sh`, etc.) automatically start writing there — detection is based on the presence of `DS-agent-workspace/.git`.

### When to Connect

**Recommended path:**
1. Start without Agent Workspace (Stages 0–2)
2. Connect the Scheduler (launchd) — reports go to DS-strategy
3. When auto-commits exceed 5/day → create Agent Workspace

## Automatic Wake and Sleep Prevention

Agents run on a schedule. If the laptop is asleep, tasks wait until it wakes. Configure automatic wake so the plan is ready before you get up.

**macOS:**

```bash
# Wake at 3:55 daily (5 min before the Strategist)
sudo pmset repeat wakeorpoweron MTWRFSU 03:55:00

# IMPORTANT: if the laptop is charging, Optimized Battery Charging may
# switch the power profile to "battery". On the battery profile,
# the Mac sleeps even with the cable connected. Solution:
sudo pmset -b sleep 0      # do not sleep on battery profile
sudo pmset -b standby 0    # do not enter deep standby

# Check: pmset -g custom (sleep=0 in both profiles)
# Cancel wake: sudo pmset repeat cancel
# Restore sleep: sudo pmset -b sleep 1 && sudo pmset -b standby 1
```

> **How it works:** The Mac wakes at 3:55, the scheduler starts at 4:00, and the plan is ready by ~4:20. The scripts keep the Mac awake automatically via `caffeinate -diu` (works on the battery profile too).
>
> **Charge Limit (recommended):** instead of Optimized Battery Charging, enable a fixed limit (System Settings → Battery → Charge Limit → 80%). Protects the battery without unpredictable profile switching.

**Linux:**

```bash
# Wake via rtcwake (one-time, typically in cron)
sudo rtcwake -m no -t $(date -d "tomorrow 03:55" +%s)

# Or systemd timer (permanent schedule)
# /etc/systemd/system/exocortex-wake.timer
# [Timer]
# OnCalendar=*-*-* 03:55:00
# WakeSystem=true
# Persistent=true

# Sleep prevention (scripts do this automatically via systemd-inhibit)
# Manual check: systemd-inhibit --list
```

**Windows (WSL):**

```powershell
# Wake via Task Scheduler
schtasks /create /tn "ExocortexWake" /tr "wsl ~/IWE/scripts/scheduler.sh dispatch" /sc daily /st 04:00
# Sleep prevention: powercfg /change standby-timeout-ac 0
```

> **General rule:** the `strategist.sh` and `scheduler.sh` scripts automatically prevent sleep while running (macOS: `caffeinate -diu`, Linux: `systemd-inhibit`). You only need to configure **wake** and **OS-level sleep prevention** for laptops.

## What Happens Next (Automatically)

After installation the system runs on its own:

| Time | Agent | What happens | Where the result goes |
|------|-------|-------------|----------------------|
| **Morning (Tue–Sun)** | Strategist | Collects yesterday's commits, generates a daily plan | `DS-strategy/current/DayPlan YYYY-MM-DD.md` |
| **Morning (Mon)** | Strategist | Prepares a draft weekly plan + session agenda | `DS-strategy/current/WeekPlan W{N}.md` |
| **Every 3 hours** | Extractor* | Checks inbox (notes, captures) → suggests Knowledge for Pack | `DS-strategy/inbox/extraction-reports/` |
| **Night (00:00)** | Synchronizer* | Code-scan — Review of changes in downstream repos | `DS-strategy/current/CodeScan YYYY-MM-DD.md` |
| **Night (Sun→Mon)** | Strategist | Week Review — weekly summary | `DS-strategy/current/WeekReport W{N} YYYY-MM-DD.md` |
| **Morning (06:00)** | Synchronizer* | Daily report — summary of overnight tasks | `DS-agent-workspace/scheduler/reports/` (or `DS-strategy/current/` without Agent Workspace) |

> *Extractor and Synchronizer run only if installed (Stage 1.4).*

Note review from Telegram is not included in this schedule: it does not run automatically. You trigger it yourself: via the "Note review" section in the daily plan, by asking Claude Code to review notes in a Session, or via the `note-review` terminal command (see "Manual run" below).

### Manual Run (If Needed)

In the terminal:
```bash
# Daily plan right now
bash ~/IWE/FMT-exocortex-template/roles/strategist/scripts/strategist.sh day-plan

# Strategy session (interactive)
bash ~/IWE/FMT-exocortex-template/roles/strategist/scripts/strategist.sh strategy-session

# Note review: terminal mode produces only annotations and suggestions; archiving and cleanup require a live Claude Code session at your direction
bash ~/IWE/FMT-exocortex-template/roles/strategist/scripts/strategist.sh note-review

# Weekly summary
bash ~/IWE/FMT-exocortex-template/roles/strategist/scripts/strategist.sh week-review

# Extractor: extract knowledge from the current session (assembled runtime copy, not the raw file in FMT)
bash "$IWE_RUNTIME/roles/extractor/scripts/extractor.sh" session-close

# Extractor: check inbox
bash "$IWE_RUNTIME/roles/extractor/scripts/extractor.sh" inbox-check

# Synchronizer: status of all tasks
bash ~/IWE/FMT-exocortex-template/roles/synchronizer/scripts/scheduler.sh status
```

## Daily Work: Three Phases (Opening–Work–Closing)

Each Session in Claude Code moves through three phases:

### Opening (automatic)
You give an assignment → Claude checks: is this task in the weekly plan? If not, it offers to add it (WP Gate). It announces the Role, Method, and Assessment.

### Work
Claude performs the task. At each Work milestone (subtask, pattern, decision), it records Knowledge: *"Capture: [what] → [where]"*.

### Closing
Say **"close out"** → Claude commits, pushes, updates Memory, and creates a backup.

## Updates

The exocortex template is updated regularly — new protocols, improved prompts, Skills, scripts, and fixes.

In the terminal:
```bash
cd ~/IWE/FMT-exocortex-template
bash update.sh
```

The Script downloads the update Manifest from GitHub, compares it with your files, shows a preview (what is new, what changed), and applies changes after your confirmation. Self-update: `update.sh` updates itself on every run.

**What is updated (platform-space):**
CLAUDE.md (§1–7), memory/ (protocols, reference files), Role prompts and scripts, hooks, Skills, setup scripts. If Role scripts have changed, launchd agents are reinstalled automatically.

**What is not touched (user-space):**
- CLAUDE.md — 3-way merge: your edits in any section are preserved during an update
- extensions/ — your protocol extensions
- params.yaml — your protocol parameters
- MEMORY.md — your working Memory (Work Products, lessons)
- DS-strategy/ — plans, strategy, inbox
- .secrets/, .mcp.json — keys and Integration Configuration
- .claude/settings.local.json — personal permissions
- personal/ — your files


> Preview available updates without applying them: `bash update.sh --check`

## Security and Privacy

> Full data policy: [DATA-POLICY.md](DATA-POLICY.md) | Canonical description: [DP.D.035](https://github.com/TserenTserenov/PACK-digital-platform/blob/main/pack/digital-platform/01-domain-contract/DP.D.035-data-policy.md)

IWE operates primarily locally. Here is what you need to know about security.

### What Stays Local

| Component | Where it is stored | Is it sent anywhere? |
|-----------|--------------------|---------------------|
| CLAUDE.md, memory/ | Local files | No (only passed to Claude as context during work) |
| DS-strategy | Private repo on GitHub | GitHub only (private) |
| Launch agents (Strategist, etc.) | Local bash scripts | No |
| Git Repositories | Local + GitHub | GitHub only |

### What Is Sent to External Servers

| Component | Where | What data |
|-----------|-------|-----------|
| **Claude Code** | Anthropic API (USA) | Prompts, file contents from context. [Privacy Policy](https://www.anthropic.com/privacy) |
| **WakaTime** (optional) | wakatime.com (USA) | Metadata: project names, file names, languages, time. File **contents** are **not** sent |
| **Aisystant MCP** (knowledge base search) | Platform server (mcp.aisystant.com), OpenRouter (query embedding) | Text of the search query. Your file contents are not sent unless you connect your own Repositories (see §1.3c) |
| **Aisystant MCP** (if you connected your own Repositories, §1.3c) | Platform server (mcp.aisystant.com), OpenRouter (content embedding) | Contents of connected Repositories, including private ones — sent to the server to build personal search |
| **GitHub** | github.com (USA) | Repository contents |

### Mac Security Recommendations

Check the following before you start:

1. **Firewall** — must be enabled: `System Settings → Network → Firewall`
2. **FileVault** — disk Encryption: `System Settings → Privacy & Security → FileVault`
3. **SIP** (System Integrity Protection) — do not disable: `csrutil status` in Terminal
4. **.gitignore** — every repo with code must exclude `.env`, `*.key`, `*.pem`, `credentials.json`
5. **Secrets** — store API keys in `.env` (gitignored) or in a password manager; **never** in code

### What Is Not Recommended

- Browsers from jurisdictions with mandatory data access (check the Privacy Policy)
- Closed-source extensions with broad file system access
- Electron apps with unclear telemetry — check via `Little Snitch` or `LuLu` (open-source firewall)

### Self-Hosted Alternatives

If you work with sensitive data, consider:

| SaaS | Self-hosted alternative |
|------|------------------------|
| WakaTime | [Wakapi](https://github.com/muety/wakapi) — full equivalent, your own server |
| GitHub | [Gitea](https://gitea.io/) or [GitLab Self-Managed](https://about.gitlab.com/install/) |

## Frequently Asked Questions

**Is an Anthropic subscription required?**
Yes, Claude Code requires an Anthropic subscription. Start with **Claude Pro** ($20/month). Use **Claude Max** (~$100/month) if needed.

**Can I use Qwen, Perplexity, ChatGPT (chat), or other chatbots?**
No. Chatbots and search assistants **do not work** — they cannot read or write files on your computer or execute terminal commands. The exocortex requires an **agentic AI assistant** — one that works with the file system, runs commands, and retains context between Sessions.

**What are the alternatives to Claude Code?**

| Alternative | What it is | Price | Models |
|-------------|-----------|-------|--------|
| **Cursor** | IDE with AI (VS Code replacement) | from $20/month | Claude, GPT, others |
| **GitHub Copilot** (Agent mode) | VS Code extension | from $10/month | Claude, GPT |
| **Cline / Roo Code** | VS Code extension (open source) | Free + API key | Any (Claude, GPT, Gemini) |
| **Aider** | CLI tool (open source) | Free + API key | Any |

> **Note on model:** The exocortex requires complex agentic behavior from the model — following multi-step protocols, working with 5–10 files simultaneously, reliable editing. Recommended models: **Claude Opus/Sonnet**, **GPT-4o/o1**, **Gemini 2.5 Pro**. Weaker models (Qwen, Llama, Mistral) may lose context and skip protocol steps — they are fine for regular coding, but unreliable for managing the exocortex.

**Does it work on Windows?**
Yes, via Git Bash (installed with [Git for Windows](https://git-scm.com/download/win)) — WSL is not required; details → [§ 0.0 "Windows: without WSL"](#00-windows-without-wsl). WSL remains an option if you need local cron-like automation or a familiar Linux Environment — in that case follow the Linux instructions inside WSL (launchd does not work there either; use `systemd`/cron).

**Can I use it without the Strategist?**
Yes. The Strategist is automation (morning plans, reviews). Without it, Claude Code + CLAUDE.md + memory/ work fully. You plan manually.

**What is a Pack?**
A Pack is a subject-area knowledge base. You create one later, once you have accumulated enough captures. The first step is working with `captures.md` via the Extractor.

**How do I verify MCP?**
Type `/mcp` in Claude Code — servers should show as Connected. Ask: "Find documents about principles." Not working? Run `bash FMT-exocortex-template/setup.sh --validate` — it shows exactly what is broken. Details: see step 1.3b.

**Is my data safe?**
DS-strategy is a private repo. MEMORY.md is a local file. Nothing is published without your knowledge. For details about what is sent to external servers (Claude API, WakaTime, GitHub) — see the [Security and Privacy](#security-and-privacy) section.

**How do I uninstall?**
```bash
# Remove launchd agents
launchctl unload ~/Library/LaunchAgents/com.strategist.morning.plist 2>/dev/null
launchctl unload ~/Library/LaunchAgents/com.strategist.weekreview.plist 2>/dev/null
launchctl unload ~/Library/LaunchAgents/com.extractor.inbox-check.plist 2>/dev/null
launchctl unload ~/Library/LaunchAgents/com.exocortex.scheduler.plist 2>/dev/null
rm ~/Library/LaunchAgents/com.strategist.*.plist 2>/dev/null
rm ~/Library/LaunchAgents/com.extractor.*.plist 2>/dev/null
rm ~/Library/LaunchAgents/com.exocortex.*.plist 2>/dev/null

# Remove files
rm ~/IWE/CLAUDE.md
rm -rf ~/.claude/projects/*/memory/
rm -rf ~/.local/state/exocortex/

# Repositories (optional)
rm -rf ~/IWE/FMT-exocortex-template
rm -rf ~/IWE/DS-strategy
```

## Next Steps

| When | What | How |
|------|------|-----|
| After the first week | Run a strategy session (Mon) | Claude will prompt you |
| After 2 weeks | Create your first Pack (personal knowledge base) | `claude` → "Help me create my first Pack" |
| As you grow | Set up the Extractor (automatic knowledge extraction) | See [roles/extractor/README.md](../roles/extractor/README.md) |
| When ready | Connect the Synchronizer (Telegram notifications) | See [roles/synchronizer/README.md](../roles/synchronizer/README.md) |

## Additional Resources

**In this repo:**

| Document | Contents |
|----------|---------|
| [LEARNING-PATH.md](LEARNING-PATH.md) | Full IWE learning path: principles, protocols, agents, Pack, SOTA |
| [IWE-HELP.md](IWE-HELP.md) | Quick reference (FAQ, glossary) — the same content the bot knows |
| [principles-vs-skills.md](principles-vs-skills.md) | Why Skills are not enough: principles and generative hierarchy |

**In Pack (via Aisystant MCP `knowledge_search`):**

| Entity | Contents |
|--------|---------|
| `DP.IWE.001` | What IWE is, why it exists, 5 architectural views (systems, descriptions, roles, methods, work products), tiers, perimeters |
| `DP.IWE.002` | Template and installation: prerequisites, cost, roles, Opening–Work–Closing, FAQ, security |
| `DP.EXOCORTEX.001` | Modular exocortex: 3 layers, template-sync, standard/personal |
| `DP.ARCH.002` | Tiers T0–T4 + TM1–TM3 + TA1–TA4 + TD1: what is available at each level |
| `DP.ROLE.001` | Full registry of AI Roles (21 roles) |

> **Need help?** Ask the bot @aist_me_bot — it searches the Platform knowledge base (Pack).
> **Technical issue?** Open an issue: [github.com/aisystant/FMT-exocortex-template/issues](https://github.com/TserenTserenov/FMT-exocortex-template/issues)