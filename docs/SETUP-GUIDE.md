# IWE Installation: Step-by-Step Guide

> This guide takes you from a clean computer to a working IWE in 30–60 minutes.
> Supports macOS, Linux, and Windows (via Git Bash — WSL is not required) — see notes in each step.
> Not sure what to change for your platform? → **[PORTABILITY.md](PORTABILITY.md)**
>
> **Source-of-truth:** `DP.IWE.002` (Pack). If this file conflicts with Pack, Pack takes Priority.
> Via Aisystant MCP: `knowledge_search("установка IWE шаблон")`.
>
> **Need a shorter version?** → [QUICK-START.md](QUICK-START.md) (15 minutes, if Git, Node.js, and CLI are already installed). This document covers full installation from scratch.

## Where You Are and Where You Are Going

The Platform opens access by tiers (`DP.ARCH.002`): from T0 (no account) to T4 (Creation, IWE). You may already be using the bot — that is T1–T3. This guide moves you to **T4**, where a personal workspace with AI agents becomes available.

| Tier | What is included | How to access |
|------|-----------------|---------------|
| **T1: Start** | Bot @aist_me_bot: knowledge base search, marathons | `/start` in Telegram |
| **T2: Learning** | + Programs, guides, schedule | Subscribe to a program |
| **T3: Personalization** | + Personal responses, digital twin | `/twin` in the bot |
| **T4: Creation (IWE)** | + Claude Code, Strategist, Git, personal knowledge bases | **This guide** |

> Everything you accumulated at T1–T3 (Digital Twin, Profile, Progress) is preserved. T4 adds new capabilities — it does not replace the existing ones.

## What You Will Get

- **Claude Code** — an AI assistant that knows your goals, tasks, and methodology. Remembers context between Sessions
- **Strategist** (AI agent) — prepares a daily plan each morning; delivers weekly summaries on Sundays
- **Extractor** (AI agent, later) — extracts Knowledge from Sessions into the knowledge base
- **Synchronizer** (later) — agent scheduler, Telegram notifications
- **DS-strategy** — your personal strategic hub (private Repository on GitHub)
- **Notes via Telegram** — write a thought in the bot and it enters the planning system

### Stage Map

| Stage | What | Time | On first install |
|-------|------|------|-----------------|
| **0** | Preparation (Git, Node, Claude Code) | 15–20 min | **required** |
| **1** | IWE Installation | ~5 min | **required** |
| **2** | First strategic Session | ~30 min | **required** |
| **3** | Notes via Telegram | 5 min | can do later |
| **4** | WakaTime (time tracking) | 10 min | can do later |
| **5** | Google Calendar | 10 min | can do later |
| **6** | Video Integration | 5 min | can do later |
| **7** | Agent Workspace (agent data) | 10 min | when >2 agents |

> **Minimum to start:** Stages 0 → 1 → 2. Everything else can be connected at any time — tell Claude *"set up calendar"* or *"connect video recordings"*.
>
> **Kimi as a second agent:** if you want to work in IWE with Kimi Code in addition to Claude, see the setup instructions in [`docs/KIMI-SETUP.md`](KIMI-SETUP.md).

## How to Open a Terminal

All commands in this guide run in a **terminal** — a program where you enter text commands.

**macOS:**
- Press `Cmd + Space` (Spotlight) → type `Terminal` → press Enter
- Or: Finder → Applications → Utilities → Terminal

**Windows:**
- Install [Git for Windows](https://git-scm.com/download/win) (default checkboxes are fine)
- Open **Git Bash** — Start → type `Git Bash` → press Enter. WSL is not required; see [§ 0.0 "Windows: without WSL"](#00-windows-without-wsl) for details

**Linux:**
- `Ctrl + Alt + T` (on most distributions)

> In the terminal you will see a prompt like `username@computer:~$`. Just type your command and press Enter.

## Stage 0: Preparation (15–20 min)

If Git, Node.js, GitHub CLI, and Claude Code CLI are already installed — go to [Stage 1](#stage-1-iwe-installation-5-min).

### 0.0 Windows: without WSL

WSL is **not required**. The IWE core consists of standard bash scripts (`setup.sh` and others). Bash on Windows comes with **Git for Windows** — installing WSL just for this is unnecessary.

1. **Git for Windows** — download from [git-scm.com](https://git-scm.com/download/win) and install (default checkboxes are fine). This also installs **Git Bash** — a terminal with bash where all commands in this guide work.
2. **All steps in Stage 0 and Stage 1** (Node.js, GitHub CLI, Claude Code CLI, `setup.sh`) must be run **from Git Bash**, not from PowerShell/cmd — commands like `curl`, `xcode-select`, and similar do not work in PowerShell.
   - Node.js — use the installer from [nodejs.org](https://nodejs.org/) (LTS version).
   - GitHub CLI — use the installer from [cli.github.com](https://cli.github.com/) or run `winget install --id GitHub.cli` (can be run from regular PowerShell; installs system-wide).
   - Claude Code CLI — same command `npm install -g @anthropic-ai/claude-code` as on macOS/Linux (Git Bash supports `npm` if Node.js is on PATH).
3. **Automatic Claude Code hooks** (pre/post-commit, etc.) call `.sh` files via the system shell — on Windows this works only if `bash` (from Git for Windows) is in the system `PATH`. The Git for Windows installer usually adds it automatically; if hooks do not fire, check `where bash` in cmd.
4. **Local automation (Strategist/Extractor without human interaction)** — Windows has no `launchd`/`systemd`; the closest equivalent is Windows Task Scheduler (see example in the [Automatic Wake section](#automatic-wake-and-sleep-prevention) below). A simpler path without local tasks is the cloud option via GitHub Actions (OS-independent; nothing needs to stay powered on).
5. **If you still want a full Linux Environment** — WSL remains a working fallback (`wsl --install` in an administrator PowerShell); it is simply no longer a required condition for installing IWE.

> **An honest disclaimer.** Neither Git Bash nor WSL as an IWE installation path has been tested live by this team on real Windows hardware (the template CI matrix runs only `ubuntu-latest`/`macos-latest`; there is no Windows runner). If you hit a specific, reproducible breakage in Git Bash — open an [issue in FMT-exocortex-template](https://github.com/TserenTserenov/FMT-exocortex-template/issues). That is more useful than guessing in advance.

### 0.1 Homebrew (macOS only)

Homebrew is a package manager for macOS. It lets you install other tools with a single command. Skip this if it is already installed.

In the terminal:
```bash
# Check whether Homebrew is installed
brew --version

# Install (if not present)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

After installation, Homebrew may ask you to run a PATH command — copy and run it.

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

Node.js is a JavaScript runtime. It is required to install Claude Code CLI. npm is the Node.js package manager (installed together with Node.js).

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

**GitHub account:** if you do not have one — register at [github.com](https://github.com/signup).

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

Now authenticate with GitHub (one time):
```bash
gh auth login
# Select: GitHub.com → HTTPS → Login with a web browser
# A browser will open → sign in to your GitHub account
```

Verify:
```bash
gh auth status
# Should show: ✓ Logged in to github.com as <username>
```

### 0.5 Claude Code CLI

Claude Code is an AI agent that runs in the terminal (or in VS Code). It reads files, runs commands, and helps with planning and writing code.

Requires an Anthropic subscription. Start with **Claude Pro** ($20/month). Use **Claude Max** (~$100/month) if you need to work without limits.

In the terminal:
```bash
# Install
npm install -g @anthropic-ai/claude-code

# Check
claude --version
```

On first launch, Claude Code will ask you to sign in to your Anthropic account — follow the instructions in the terminal.

### 0.5b Cost Optimization: Choosing a Model

Claude Code lets you choose a model for each task. Choosing correctly saves subscription quota:

| Model | Verification class | When to use | Cost |
|-------|--------------------|-------------|------|
| **Opus** | open-loop, problem-framing | Architecture, complex code, strategy, multi-system changes | High |
| **Sonnet** | closed-loop | Standard tasks, single-file edits, writing content | Medium |
| **Haiku** | trivial | Renaming, updating links, Formatting, finding files, cron agents | Low |

To switch models in Claude Code: `/model` → select. For automated tasks (Strategist, Extractor), Haiku is recommended — saves ~80% of quota compared to Opus.

> **How it works — two scenarios:**
> - **Entire Session on a different model:** When a Session opens, Claude determines the verification class. If the task is trivial/closed-loop and the current model is excessive, Claude will say: *"I recommend switching to [Haiku/Sonnet] via `/model`. I cannot switch automatically."* The user switches manually.
> - **A single task within a Session:** If a trivial task appears mid-session, Claude delegates it to a sub-agent on a cheaper model. The main Session is not interrupted. Delegation only goes downward (Opus→Sonnet/Haiku, Sonnet→Haiku). Switching upward requires `/model`.
>
> **Tip:** On a Claude Pro subscription ($20/month), use Haiku for routine work (morning plans, file search, trivial edits). Use Opus only for architectural decisions and complex code.

### 0.6 VS Code (recommended)

VS Code is a code editor with a graphical interface. It makes working with Claude Code more convenient: you see all your repos, files, the terminal, and the AI assistant in one window, and you can switch between repos of different projects in a single Session. **Without VS Code** you work only via the terminal — this is possible, but less convenient.

- Download and install: [code.visualstudio.com](https://code.visualstudio.com/)
- Open VS Code → press `Cmd+Shift+X` (macOS) or `Ctrl+Shift+X` (Windows/Linux) → search for "Claude Code" → click Install

## Stage 1: IWE Installation (~5 min)

### 1.1 Create a Working Folder

Create **one folder** on your computer for all Repositories — current and future. All Repositories will be cloned into it: `FMT-exocortex-template/`, `DS-strategy/`, `PACK-{domain}/`, `DS-{projects}/`, and others. `CLAUDE.md` will also live in the root of this folder. The default location is `~/IWE`:

```bash
mkdir -p ~/IWE
cd ~/IWE
```

> **Important:** The name can be anything, but all repos must be in one place — Claude Code relies on this structure. We recommend `~/IWE`.

### 1.2 Fork the Template and Run the Installer

In the terminal:

```bash
# Make sure we are in the working folder
cd ~/IWE

# Fork the template to your GitHub and clone it
gh repo fork TserenTserenov/FMT-exocortex-template --clone
cd FMT-exocortex-template

# Run the installer
bash setup.sh
```

> **Preview without executing:** `bash setup.sh --dry-run`

The Script will ask:

| Question | What to enter | Example |
|----------|--------------|---------|
| GitHub username | Your GitHub login | `ivan-petrov` |
| Workspace directory | Working folder | Just press Enter (detected automatically) |
| Claude CLI path | Path to claude | Just press Enter (detected automatically) |
| Strategist launch hour (UTC) | Strategist launch hour | `4` (= 7:00 MSK, 8:00 Almaty) |
| Timezone description | Time description | `7:00 MSK` |

The Script performs 6 steps:
1. Substitutes your data into all files (name, paths, timezone)
2. Installs `CLAUDE.md` — rules for Claude Code
3. Installs `memory/` — working memory for Claude Code
4. Configures permissions (`.claude/settings.local.json`) and displays MCP connection instructions
5. Sets up automatic Strategist launch (launchd on macOS)
6. Creates `DS-strategy/` — your private strategic Repository on GitHub

### 1.3 Verify the Installation

In the terminal:
```bash
# Should exist
ls ~/IWE/CLAUDE.md

# Should contain memory files (10+)
ls ~/.claude/projects/*/memory/

# Should exist
ls ~/IWE/DS-strategy/

# Strategist should be scheduled (macOS)
launchctl list | grep strategist
```

If everything is present — verify the MCP connection (1.3b) and proceed to Stage 2. Additional Roles (1.4) can be installed later.

### 1.3b Connect MCP Servers

MCP (Model Context Protocol) gives Claude Code access to the Platform knowledge base and your personal Repositories. Through it, Claude sees documents, guides, the digital twin, and your own Pack repos — domain knowledge bases you build over time.

> **Why:** Documentation and Pack entities (DP.IWE.001, DP.ARCH.001, etc.) reference the source-of-truth in PACK-digital-platform. After connecting MCP, Claude can find these entities on request and work with your personal repos directly. Without MCP, entities are accessible only as files on GitHub.

**Connection:**

1. Open https://claude.ai/settings/connectors
2. Add the MCP server (Aisystant MCP): `https://mcp.aisystant.com/mcp`
3. Restart Claude Code

**How it works:** Claude Code connects to Aisystant MCP via claude.ai connectors. The server aggregates all backends (knowledge, digital-twin) and provides tools (`knowledge_search`, `knowledge_get_document`, `knowledge_feedback`, `dt_read_digital_twin`, etc.).

#### Verification

Open Claude Code in the exocortex folder and type `/mcp` — servers should show status Connected. Then ask:
> Find documents about principles

Claude should use `knowledge_search("принципы")` and return a list of documents from the knowledge base.

**Diagnostics:**

```bash
# Check the full installation (env, files, extensions, MCP availability)
bash FMT-exocortex-template/setup.sh --validate
```

| Problem | Solution |
|---------|---------|
| `/mcp` — no servers listed | Repeat steps 1–3 (claude.ai connectors) |
| Opened URL in browser — "Not found" | This is normal. MCP works via POST (JSON-RPC), not GET. Check via `/mcp` in Claude Code |
| Aisystant MCP — connection error | Check your internet connection |
| `--validate` shows errors | Follow the hints. For missing keys — fill them in `.exocortex.env` |

> **Tip:** `setup.sh --validate` checks ALL categories at once: env config, required files, extensions, MCP availability.

### 1.4 Install Additional Roles (later)

`setup.sh` installs only the Strategist. The Extractor and Synchronizer are installed separately, once you are comfortable with the basic cycle:

In the terminal:
```bash
cd ~/IWE/FMT-exocortex-template

# Extractor — knowledge extraction from Sessions, inbox check (every 3 hours)
bash roles/extractor/install.sh

# Synchronizer — central scheduler: agent schedule, notifications, code-scan
bash roles/synchronizer/install.sh
```

> **Recommendation:** The Extractor and Synchronizer can be installed later, once you are comfortable with the basic cycle with the Strategist. See [roles/extractor/README.md](../roles/extractor/README.md) and [roles/synchronizer/README.md](../roles/synchronizer/README.md).

> **Important:** If you install the Synchronizer, it replaces the separate Strategist launchd agents with a single scheduler. All Roles will run on a schedule from one place.

## Something Not Working?

**`CLAUDE.md` not found:**
```bash
cp ~/IWE/FMT-exocortex-template/CLAUDE.md ~/IWE/CLAUDE.md
```

**Memory not found:**
```bash
# Determine slug
echo $HOME/IWE | tr '/' '-'
# Example result: -Users-ivan-IWE

# Create directory and copy files
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

## Restoring on a New Device (from exocortex backup)

If IWE is already set up on one device, you do **not** need to initialize memory from scratch on a new one. `day-close.sh --backup` and the `memory-exocortex-sync.sh` hook keep a mirror of memory in `DS-strategy/exocortex/`, which is pushed to GitHub together with the governance repo. `restore-from-exocortex.sh` restores it back.

**Steps on the new device:**

```bash
# 1. Stage 0 (binaries, gh auth, claude CLI) — as usual
# 2. Working folder + clone the template and governance repo (it carries exocortex/)
mkdir -p ~/IWE && cd ~/IWE
gh repo fork TserenTserenov/FMT-exocortex-template --clone
git clone https://github.com/<your-login>/DS-strategy.git

# 3. Restore memory from backup (instead of initializing from scratch)
bash ~/IWE/FMT-exocortex-template/scripts/restore-from-exocortex.sh ~/IWE/DS-strategy
#    --dry-run  — preview without changes
#    --force    — overwrite an already-populated memory/

# 4. Restart Claude Code → memory is in place
```

The Script: copies `exocortex/*.md|*.yaml` → auto-memory (`~/.claude/projects/<slug>-IWE/memory/`), `exocortex/CLAUDE.md` → `~/IWE/CLAUDE.md`, creates a symlink `~/IWE/memory → auto-memory`. Does not touch a non-empty `memory/` without `--force` (protects against accidentally overwriting a working installation).

## Stage 2: First Strategic Session (~30 min)

This is the most important step — you will define your goals and create your first plan.

**Option A — via VS Code (recommended):**
1. Open VS Code
2. `File → Open Folder` → select folder `~/IWE`
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
2. **Dissatisfactions** — What is in the way? Where is the gap between current and desired?
3. **First WeekPlan** — Specific tasks for the week with time budgets
4. **Registration in WP-REGISTRY.md and WeekPlan** — Work Products from the Session will appear in the Registry and the plan

**Result:** populated `DS-strategy/docs/Strategy.md`, `Dissatisfactions.md`, and the first `WeekPlan` in `DS-strategy/current/`.

## Stage 3: Setting Up Notes via Telegram (5 min, optional)

To send thoughts into the planning system directly from Telegram:

1. Find bot **@aist_me_bot** in Telegram
2. Press `/start`
3. Subscribe (if you have not yet)

**How to send notes:**
- Write: `.My thought about architecture` (dot + text)
- Or forward/reply to any message with `.`

The note lands in `DS-strategy/inbox/fleeting-notes.md`. The Strategist processes it in the evening (Note-Review, 23:00) and classifies it: task → plan, Knowledge → captures, idea → for discussion.

## Stage 4: WakaTime — Time Tracking (10 min, optional)

WakaTime tracks working time automatically: by projects, languages, and categories.

In VS Code or the terminal, launch Claude Code and say:

> **/setup-wakatime**

Claude will guide you through the setup:
1. wakatime-cli
2. API key (get it at [wakatime.com/settings/api-key](https://wakatime.com/settings/api-key))
3. Hooks for Claude Code
4. Desktop App (optional)

After setup: WakaTime data is automatically included in the morning day plan and weekly report.

> **Privacy:** WakaTime is a SaaS service (wakatime.com, AWS servers, USA). The server receives **metadata** about your work: project names, file names, languages, branches, activity time. File **contents** are NOT sent. The CLI is open source ([github.com/wakatime/wakatime-cli](https://github.com/wakatime/wakatime-cli)). The Desktop App is closed source and requests Accessibility permission (sees active windows). If metadata is sensitive for you — use the self-hosted alternative [Wakapi](https://github.com/muety/wakapi) (wakatime-cli supports a custom `api_url` in `~/.wakatime.cfg`).

## Stage 5: Google Calendar — Day Events in Day Open (10 min, optional)

Connecting Google Calendar lets you see the day's events directly in the morning plan, create events from Claude Code, and prepare for meetings.

### What You Get

- **Day Open** will show a table of the day's events + free slots for work
- **Creating events** — "schedule a call for Wednesday 11:00" directly from Claude Code
- **Meeting preparation** — Claude pulls context from related Work Products

### Setup (~1 min)

Run one command from the template root:

```bash
bash setup/optional/setup-calendar.sh
```

The Script:
1. Writes OAuth credentials (Shared App IWE) to `.secrets/`
2. Creates `.mcp.json` with Calendar MCP settings
3. Opens a browser → sign in with your Google account → click "Allow"
4. Restart Claude Code → verify: **"show my events for today"**

> **⚠ Google may show "This app isn't verified".** This is normal — click "Advanced" → "Go to IWE (unsafe)". This warning will disappear after the app is verified.

### Multiple Accounts

You can connect multiple Google accounts (work + personal):

```
Claude, connect another Google Calendar account
```

Each account gets a nickname (`personal`, `work`) for addressing.

### Privacy

Calendar data is processed via the Google Calendar API. OAuth tokens are stored locally. Event content is sent to the Claude API for day plan generation. Confidential events (visibility=private) can be excluded from display.

## Stage 6: Video Integration — Linking Recordings to Work Products (5 min, optional)

If you record meetings (Zoom, Telemost, Google Meet), Claude can scan folders with recordings and link videos to Work Products.

### What You Get

- **Day Open** will show new video recordings with Work Product links
- **Strategy Session** — weekly review of all unprocessed videos
- **Transcription** → automatic captures and post ideas (optional, requires whisper)

### Setup

1. Open `memory/day-rhythm-config.yaml`
2. In the `video` section, specify your folders:

```yaml
video:
  enabled: true
  directories:
    - ~/Documents/Zoom
    - ~/Documents/Телемост
    # Add your own video recording folders
```

3. Verify: **"show my video recordings"** — Claude will run `video-scan.sh`

### Where to Find Folders

| Application | Typical path (macOS) |
|-------------|---------------------|
| Zoom | `~/Documents/Zoom` |
| Yandex Telemost | `~/Documents/Телемост` or `~/Видеозаписи Телемост` |
| Google Meet | Recordings in Google Drive (not local) |
| OBS | Configured in OBS → Settings → Output |

### Linking to Work Products

The Script links videos to Work Products by filename:
- `WP-73-...mp4` → linked to WP-73
- `2026-03-14-...mp4` → linked by date (matched against calendar)
- Others → manual linking is suggested

### Transcription (optional)

To enable automatic transcription, install [whisper](https://github.com/openai/whisper):

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

If you just started with IWE and use only Claude Code in interactive mode — **you do not need this**. All scheduler reports will be stored in `DS-strategy/current/` and `DS-strategy/archive/` — that is sufficient.

**2. Do agents generate >10 files per week?**

When Scheduler, Scout, Extractor, and other agents run daily, they produce dozens of files: scheduler reports, bot QA reports, findings, plan drafts. These auto-commits pollute the DS-strategy git history, which should contain only **human decisions** (plans, approved captures).

### What Agent Workspace Provides

| Without Agent Workspace | With Agent Workspace |
|------------------------|---------------------|
| Everything in DS-strategy | Machine output is separate |
| Git history is mixed | Clean decision history |
| 1 repository | 2 repositories |
| Simpler to start | Scales better |

### Setup

```bash
bash setup/optional/setup-agent-workspace.sh
```

The Script creates a private GitHub repo `DS-agent-workspace` with a structure for each agent type. After creation, scheduler Scripts (`daily-report.sh`, etc.) automatically write there — checked by the presence of `DS-agent-workspace/.git`.

### When to Connect

**Recommended path:**
1. Start without Agent Workspace (Stages 0–2)
2. Connect Scheduler (launchd) — reports go to DS-strategy
3. When auto-commits exceed 5/day → create Agent Workspace

## Automatic Wake and Sleep Prevention

Agents run on a schedule. If the laptop is sleeping, tasks wait until it wakes. Configure automatic wake so the plan is ready before you wake up.

**macOS:**

```bash
# Wake at 3:55 every day (5 min before Strategist)
sudo pmset repeat wakeorpoweron MTWRFSU 03:55:00

# IMPORTANT: if the laptop is on charge, Optimized Battery Charging may
# switch the power profile to "battery". On the battery profile,
# a Mac sleeps even with the cable connected. Fix:
sudo pmset -b sleep 0      # do not sleep on battery profile
sudo pmset -b standby 0    # do not enter deep standby

# Verify: pmset -g custom (sleep=0 in both profiles)
# Cancel wake: sudo pmset repeat cancel
# Restore sleep: sudo pmset -b sleep 1 && sudo pmset -b standby 1
```

> **How it works:** The Mac wakes at 3:55, the scheduler starts at 4:00, the plan is ready by ~4:20. Scripts automatically keep the Mac awake via `caffeinate -diu` (works on the battery profile too).
>
> **Charge Limit (recommended):** instead of Optimized Battery Charging, enable a fixed limit (System Settings → Battery → Charge Limit → 80%). Protects the battery without unpredictable profile switches.

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

> **General rule:** the `strategist.sh` and `scheduler.sh` Scripts automatically prevent sleep during execution (macOS: `caffeinate -diu`, Linux: `systemd-inhibit`). You only need to configure **wake** and **OS-level sleep prevention** for laptops.

## What Happens Next (automatically)

After installation the system runs on its own:

| Time | Agent | What happens | Where the result goes |
|------|-------|-------------|----------------------|
| **Morning (Tue–Sun)** | Strategist | Collects yesterday's commits, generates day plan | `DS-strategy/current/DayPlan YYYY-MM-DD.md` |
| **Morning (Mon)** | Strategist | Prepares a weekly plan draft + session agenda | `DS-strategy/current/WeekPlan W{N}.md` |
| **Every 3 hours** | Extractor* | Checks inbox (notes, captures) → proposes Knowledge to Pack | `DS-strategy/inbox/extraction-reports/` |
| **Evening (23:00)** | Strategist | Note-Review classifies notes from Telegram | Target documents in DS-strategy |
| **Night (00:00)** | Synchronizer* | Code-scan — review of changes in downstream repos | `DS-strategy/current/CodeScan YYYY-MM-DD.md` |
| **Night (Sun→Mon)** | Strategist | Week Review — weekly summary | `DS-strategy/current/WeekReport W{N} YYYY-MM-DD.md` |
| **Morning (06:00)** | Synchronizer* | Daily report — summary of overnight tasks | `DS-agent-workspace/scheduler/reports/` (or `DS-strategy/current/` without Agent Workspace) |

> *Extractor and Synchronizer only run if installed (Stage 1.4).*

### Manual Launch (if needed)

In the terminal:
```bash
# Day plan right now
bash ~/IWE/FMT-exocortex-template/roles/strategist/scripts/strategist.sh day-plan

# Strategy session (interactive)
bash ~/IWE/FMT-exocortex-template/roles/strategist/scripts/strategist.sh strategy-session

# Note review
bash ~/IWE/FMT-exocortex-template/roles/strategist/scripts/strategist.sh note-review

# Week review
bash ~/IWE/FMT-exocortex-template/roles/strategist/scripts/strategist.sh week-review

# Extractor: extract knowledge from current session (assembled runtime copy, not the raw file in FMT)
bash "$IWE_RUNTIME/roles/extractor/scripts/extractor.sh" session-close

# Extractor: check inbox
bash "$IWE_RUNTIME/roles/extractor/scripts/extractor.sh" inbox-check

# Synchronizer: status of all tasks
bash ~/IWE/FMT-exocortex-template/roles/synchronizer/scripts/scheduler.sh status
```

## Daily Work: Three Stages (Opening–Work–Closing)

Each Session in Claude Code goes through three stages:

### Opening (automatic)
You give a task → Claude checks: is this task in the week plan? If not — Claude proposes adding it (WP Gate). Claude declares the Role, Method, and estimate.

### Work
Claude performs the task. At each Work milestone (subtask, pattern, decision) — Claude captures Knowledge: *"Capture: [what] → [where]"*.

### Closing
Say **"close"** → Claude commits, pushes, updates memory, and creates a Backup.

## Updates

The exocortex Template is updated with new Protocols, improved prompts, Skills, Scripts, and fixes.

In the terminal:
```bash
cd ~/IWE/FMT-exocortex-template
bash update.sh
```

The Script downloads the update Manifest from GitHub, compares it with your files, shows a preview (what is new, what changed), and applies after your confirmation. Self-update: `update.sh` updates itself on every run.

**What is updated (platform-space):**
CLAUDE.md (§1–7), memory/ (Protocols, references), Role prompts and Scripts, hooks, Skills, setup Scripts. If Role Scripts changed — launchd agents are automatically reinstalled.

**What is NOT touched (user-space):**
- CLAUDE.md — 3-way merge: your edits in any section are preserved on update
- extensions/ — your Protocol extensions
- params.yaml — your Protocol parameters
- MEMORY.md — your working memory (Work Products, lessons)
- DS-strategy/ — plans, strategy, inbox
- .secrets/, .mcp.json — Integration keys and Configuration
- .claude/settings.local.json — personal permissions
- personal/ — your files


> Preview available updates without applying: `bash update.sh --check`

## Security and Privacy

> Full data policy: [DATA-POLICY.md](DATA-POLICY.md) | Canonical description: [DP.D.035](https://github.com/TserenTserenov/PACK-digital-platform/blob/main/pack/digital-platform/01-domain-contract/DP.D.035-data-policy.md)

IWE operates primarily locally. Here is what you need to know about security.

### What Stays Local

| Component | Where it is stored | Is it sent anywhere |
|-----------|-------------------|---------------------|
| CLAUDE.md, memory/ | Local files | No (only passed into Claude's context during work) |
| DS-strategy | Private repo on GitHub | Only to GitHub (private) |
| Launch agents (Strategist, etc.) | Local bash Scripts | No |
| Git repositories | Local + GitHub | Only to GitHub |

### What Is Sent to External Servers

| Component | Where | What data |
|-----------|-------|----------|
| **Claude Code** | Anthropic API (USA) | Prompts, file contents from context. [Privacy Policy](https://www.anthropic.com/privacy) |
| **WakaTime** (opt.) | wakatime.com (USA) | Metadata: project names, file names, languages, time. **NOT** file contents |
| **Aisystant MCP** | Platform server (mcp.aisystant.com) | Search queries. User data is not sent |
| **GitHub** | github.com (USA) | Repository contents |

### Mac Security Recommendations

Check the following before starting:

1. **Firewall** — must be enabled: `System Settings → Network → Firewall`
2. **FileVault** — disk Encryption: `System Settings → Privacy & Security → FileVault`
3. **SIP** (System Integrity Protection) — do not disable: `csrutil status` in Terminal
4. **.gitignore** — every repo with code must exclude `.env`, `*.key`, `*.pem`, `credentials.json`
5. **Secrets** — store API keys in `.env` (gitignored) or in a password manager, **never** in code

### What Is NOT Recommended to Install

- Browsers from jurisdictions with mandatory data access (check Privacy Policy)
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

**Will Qwen, Perplexity, ChatGPT (chat), or other chatbots work?**
No. Chatbots and search assistants (Qwen-chat, Perplexity, routerai.ru, standard ChatGPT) **do not work** — they cannot read/write files on your computer or run commands in the terminal. The exocortex requires an **agentic AI assistant** — one that works with the file system, runs commands, and preserves context between Sessions.

**What are the alternatives to Claude Code?**

| Alternative | What it is | Price | Models |
|---|---|---|---|
| **Cursor** | AI-native IDE (VS Code replacement) | from $20/month | Claude, GPT, own |
| **GitHub Copilot** (Agent mode) | VS Code extension | from $10/month | Claude, GPT |
| **Cline / Roo Code** | VS Code extension (open source) | Free + API key | Any (Claude, GPT, Gemini) |
| **Aider** | CLI tool (open source) | Free + API key | Any |

> **Important note on models:** The exocortex requires complex agentic behavior from the model — following multi-step Protocols, working with 5–10 files simultaneously, reliable editing. Recommended models: **Claude Opus/Sonnet**, **GPT-4o/o1**, **Gemini 2.5 Pro**. Weaker models (Qwen, Llama, Mistral) may lose context and skip Protocol steps — they are fine for standard coding but unreliable for managing the exocortex.

**Does it work on Windows?**
Yes, via Git Bash (installed with [Git for Windows](https://git-scm.com/download/win)) — WSL is not required; see [§ 0.0 "Windows: without WSL"](#00-windows-without-wsl). WSL remains an option if you need local cron-like automation or prefer a familiar Linux Environment — in that case, follow the Linux instructions inside WSL (launchd does not work there either; use `systemd`/cron).

**Can I use IWE without the Strategist?**
Yes. The Strategist is automation (morning plans, Review). Without it, Claude Code + CLAUDE.md + memory/ work fully. You plan manually.

**What is a Pack?**
A Pack is a domain knowledge base. It is created later, once you have accumulated enough captures. The first step is working with `captures.md` via the Extractor.

**How do I verify MCP?**
Type `/mcp` in Claude Code — servers should show Connected. Ask: "Find documents about principles." Not working? Run `bash FMT-exocortex-template/setup.sh --validate` — it will show exactly what is broken. See step 1.3b for details.

**Are my data safe?**
DS-strategy is a private repo. MEMORY.md is a local file. Nothing is published without your knowledge. For details on what is sent to external servers (Claude API, WakaTime, GitHub) — see the [Security and Privacy](#security-and-privacy) section.

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
| After the first week | Run a strategy Session (Mon) | Claude will prompt you |
| After 2 weeks | Create your first Pack (personal knowledge base) | `claude` → "Help me create my first Pack" |
| As you grow | Set up the Extractor (automatic knowledge extraction) | See [roles/extractor/README.md](../roles/extractor/README.md) |
| When ready | Connect the Synchronizer (Telegram notifications) | See [roles/synchronizer/README.md](../roles/synchronizer/README.md) |

## Additional Resources

**In this repo:**

| Document | Contents |
|----------|---------|
| [LEARNING-PATH.md](LEARNING-PATH.md) | Full IWE learning path: principles, Protocols, agents, Pack, SOTA |
| [IWE-HELP.md](IWE-HELP.md) | Quick reference (FAQ, glossary) — same as the bot knows |
| [principles-vs-skills.md](principles-vs-skills.md) | Why Skills are not enough: principles and the generative hierarchy |

**In Pack (via Aisystant MCP `knowledge_search`):**

| Entity | Contents |
|--------|---------|
| `DP.IWE.001` | What IWE is, why it exists, 5 architectural views (systems, descriptions, Roles, Methods, Work Products), tiers, perimeters |
| `DP.IWE.002` | Template and installation: prerequisites, cost, Roles, Opening–Work–Closing, FAQ, security |
| `DP.EXOCORTEX.001` | Modular exocortex: 3 layers, template-sync, standard/personal |
| `DP.ARCH.002` | Tiers T0–T4 + TM1–TM3 + TA1–TA4 + TD1: what is available at each level |
| `DP.ROLE.001` | Full Registry of AI Roles (21 Roles) |

> **Need help?** Ask bot @aist_me_bot — it searches the Platform knowledge base (Pack).
> **Technical issue?** Open an issue: [github.com/aisystant/FMT-exocortex-template/issues](https://github.com/TserenTserenov/FMT-exocortex-template/issues)