# IWE Installation: Step-by-Step Guide

> This guide takes you from a clean computer to a working IWE in 30-60 minutes.
> Designed for macOS. For Linux and Windows (WSL) — see the notes in each step.
> Not sure what to change for your platform? → **[PORTABILITY.md](PORTABILITY.md)**
>
> **Source-of-truth:** `DP.IWE.002` (Pack). If this file conflicts with Pack — Pack takes Priority.
> Via Aisystant MCP: `knowledge_search("установка IWE шаблон")`.
>
> **Need a shorter version?** → [QUICK-START.md](QUICK-START.md) (15 minutes, if Git, Node.js, and CLI are already installed). This page covers a full installation from scratch.

## Where You Are Now and Where You Are Going

The Platform opens access by tiers (`DP.ARCH.002`): from T0 (no account) to T4 (Creation, IWE). You may already use the bot — that is T1-T3. This guide moves you to **T4**, where a personal workspace with AI agents becomes available.

| Tier | What Is Included | How to Access |
|------|-----------------|---------------|
| **T1: Start** | Bot @aist_me_bot: knowledge base search, marathons | `/start` in Telegram |
| **T2: Learning** | + Programs, guides, schedule | Subscribe to a program |
| **T3: Personalization** | + Personal responses, digital twin | `/twin` in the bot |
| **T4: Creation (IWE)** | + Claude Code, Strategist, Git, personal knowledge bases | **This guide** |

> Everything you accumulated at T1-T3 (Digital Twin, Profile, Progress) is preserved. T4 adds new capabilities — it does not replace the existing ones.

## What You Will Get

- **Claude Code** — an AI assistant that knows your goals, tasks, and methodology. It remembers context across Sessions
- **Strategist** (AI agent) — prepares a daily plan every morning; on Sundays, a weekly summary
- **Extractor** (AI agent, later) — extracts Knowledge from Sessions into a knowledge base
- **Synchronizer** (later) — agent scheduling, Telegram notifications
- **DS-strategy** — your personal strategic hub (private Repository on GitHub)
- **Notes via Telegram** — write a thought in the bot and it enters the planning system

### Stage Map

| Stage | What | Time | On First Installation |
|-------|------|------|-----------------------|
| **0** | Preparation (Git, Node, Claude Code) | 15-20 min | **required** |
| **1** | IWE installation | ~5 min | **required** |
| **2** | First strategic Session | ~30 min | **required** |
| **3** | Notes via Telegram | 5 min | can do later |
| **4** | WakaTime (time tracking) | 10 min | can do later |
| **5** | Google Calendar | 10 min | can do later |
| **6** | Video Integration | 5 min | can do later |
| **7** | Agent Workspace (agent data) | 10 min | when >2 agents |

> **Minimum to start:** Stages 0 → 1 → 2. Everything else can be connected at any time — tell Claude *"set up calendar"* or *"connect video recordings"*.
>
> **Kimi as a second agent:** if you want to work in IWE with Kimi Code in addition to Claude — the setup is described in [`docs/KIMI-SETUP.md`](KIMI-SETUP.md).

## How to Open a Terminal

All commands in this guide run in the **terminal** — a program where you enter text commands.

**macOS:**
- Press `Cmd + Space` (Spotlight) → type `Terminal` → press Enter
- Or: Finder → Applications → Utilities → Terminal

**Windows:**
- First install [WSL](https://learn.microsoft.com/en-us/windows/wsl/install) (Windows Subsystem for Linux)
- Then open: Start → type `Ubuntu` → press Enter

**Linux:**
- `Ctrl + Alt + T` (in most distributions)

> In the terminal you will see a line like `username@computer:~$` — this is the input prompt. Just type your command and press Enter.

## Stage 0: Preparation (15-20 min)

If Git, Node.js, GitHub CLI, and Claude Code CLI are already installed — skip to [Stage 1](#stage-1-iwe-installation-5-min).

### 0.1 Homebrew (macOS only)

Homebrew is a package manager for macOS. It is required to install the other tools with a single command. If it is already installed — skip this step.

In the terminal:
```bash
# Check whether Homebrew is installed
brew --version

# Install (if not present)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

After installation, Homebrew may ask you to run a command to update PATH — copy it and run it.

### 0.2 Git

Git is a version control system. It stores the history of file changes and lets you synchronize work through GitHub.

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

GitHub CLI (`gh`) is a tool for working with GitHub from the terminal. The installer uses it to create repositories and copy the Template.

**GitHub account:** if you do not have one — register at [github.com](https://github.com/signup).

In the terminal:
```bash
# Check
gh --version

# Install
# macOS:
brew install gh
# Linux:
# https://cli.github.com/ — installation instructions
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

Claude Code is an AI agent that runs in the terminal (or in VS Code). It reads files, executes commands, and helps with planning and writing code.

It requires an Anthropic subscription. Start with **Claude Pro** ($20/month). If needed — **Claude Max** (~$100/month) for unrestricted use.

In the terminal:
```bash
# Install
npm install -g @anthropic-ai/claude-code

# Check
claude --version
```

On first launch, Claude Code will ask you to sign in to your Anthropic account — follow the instructions in the terminal.

### 0.5b Cost Optimization: Model Selection

Claude Code lets you choose a model for each task. The right choice preserves your subscription limit:

| Model | Verification Class | When to Use | Cost |
|-------|--------------------|-------------|------|
| **Opus** | open-loop, problem-framing | Architecture, complex code, strategy, multi-system changes | High |
| **Sonnet** | closed-loop | Routine tasks, single-file edits, writing content | Medium |
| **Haiku** | trivial | Renaming, updating links, Formatting, finding a file, cron agents | Low |

To switch the model in Claude Code: `/model` → select. For automated tasks (Strategist, Extractor) Haiku is recommended — it saves ~80% of the limit compared to Opus.

> **How it works — two scenarios:**
> - **Entire Session on a different model:** When opened, Claude determines the verification class. If the task is trivial/closed-loop and the current model is excessive, Claude will say: *"I recommend switching to [Haiku/Sonnet] via `/model`. I cannot switch automatically."* The user switches manually.
> - **A single task within a Session:** If a trivial task appears mid-session, Claude delegates it to a sub-agent on a cheaper model. The main Session is not interrupted. Delegation goes only downward (Opus→Sonnet/Haiku, Sonnet→Haiku). Switching upward requires `/model`.
>
> **Tip:** On a Claude Pro subscription ($20/month), actively use Haiku for routine work (morning plans, file search, trivial edits). Use Opus only for architectural decisions and complex code.

### 0.6 VS Code (Recommended)

VS Code is a code editor with a graphical interface. It makes working with Claude Code convenient: you see all your repos, files, terminal, and AI assistant in one window, and can switch between repos of different projects within a single Session. **Without VS Code** you must work through the terminal only — this is possible, but less convenient.

- Download and install: [code.visualstudio.com](https://code.visualstudio.com/)
- Open VS Code → press `Cmd+Shift+X` (macOS) or `Ctrl+Shift+X` (Windows/Linux) → search for "Claude Code" → click Install

## Stage 1: IWE Installation (~5 min)

### 1.1 Create a Workspace Folder

Create **one folder** on your computer for all repositories — current and future. All repositories will be cloned into it: `FMT-exocortex-template/`, `DS-strategy/`, `PACK-{domain}/`, `DS-{projects}/`, and others. `CLAUDE.md` will also be located at the root of this folder. The default path is `~/IWE`:

```bash
mkdir -p ~/IWE
cd ~/IWE
```

> **Important:** The name can be anything, but all repos must be in one place — Claude Code relies on this structure. We recommend `~/IWE`.

### 1.2 Fork the Template and Run the Installer

In the terminal:

```bash
# Make sure we are in the workspace folder
cd ~/IWE

# Fork the template to your GitHub and clone it
gh repo fork TserenTserenov/FMT-exocortex-template --clone
cd FMT-exocortex-template

# Run the installer
bash setup.sh
```

> **Preview without executing:** `bash setup.sh --dry-run`

The Script will ask:

| Question | What to Enter | Example |
|----------|--------------|---------|
| GitHub username | Your GitHub login | `ivan-petrov` |
| Workspace directory | Workspace folder | Just press Enter (detected automatically) |
| Claude CLI path | Path to claude | Just press Enter (detected automatically) |
| Strategist launch hour (UTC) | Strategist launch hour | `4` (= 7:00 MSK, 8:00 Almaty) |
| Timezone description | Time description | `7:00 MSK` |

The Script performs 6 steps:
1. Substitutes your data into all files (name, paths, timezone)
2. Installs `CLAUDE.md` — rules for Claude Code
3. Installs `memory/` — working Memory for Claude Code
4. Configures permissions (`.claude/settings.local.json`) and displays MCP connection instructions
5. Sets up automatic Strategist launch (launchd on macOS)
6. Creates `DS-strategy/` — your private strategic Repository on GitHub

### 1.3 Verify the Installation

In the terminal:
```bash
# Must exist
ls ~/IWE/CLAUDE.md

# Must contain memory files (10+)
ls ~/.claude/projects/*/memory/

# Strategic hub must exist
ls ~/IWE/DS-strategy/

# Strategist must be in the schedule (macOS)
launchctl list | grep strategist
```

If everything is present — check the MCP connection (1.3b) and proceed to Stage 2. Additional roles (1.4) can be installed later.

### 1.3b Connect MCP Servers

MCP (Model Context Protocol) gives Claude Code access to the Platform knowledge base and your personal repositories. Through it, Claude sees documents, guides, the digital twin, and your own Pack repos — subject-matter knowledge bases you build over time.

> **Why:** Documentation and Pack entities (DP.IWE.001, DP.ARCH.001, etc.) reference source-of-truth in PACK-digital-platform. After connecting MCP, Claude can find these entities on request and work with your personal repos directly. Without MCP — entities are only accessible as files on GitHub.

**Connecting:**

1. Open https://claude.ai/settings/connectors
2. Add the MCP server (Aisystant MCP): `https://mcp.aisystant.com/mcp`
3. Restart Claude Code

**How it works:** Claude Code connects to Aisystant MCP via claude.ai connectors. The server aggregates all backends (knowledge, digital-twin) and provides tools (`knowledge_search`, `knowledge_get_document`, `knowledge_feedback`, `dt_read_digital_twin`, etc.).

#### Verification

Open Claude Code in the exocortex folder and type `/mcp` — servers must have Connected status. Then ask:
> Find documents about principles

Claude must use `knowledge_search("принципы")` and return a list of documents from the knowledge base.

**Diagnostics:**

```bash
# Check the full installation (env, files, extensions, MCP availability)
bash FMT-exocortex-template/setup.sh --validate
```

| Problem | Solution |
|---------|----------|
| `/mcp` — no servers | Repeat steps 1-3 (claude.ai connectors) |
| Opened the URL in a browser — "Not found" | This is normal. MCP works via POST (JSON-RPC), not GET. Check via `/mcp` in Claude Code |
| Aisystant MCP — connection error | Check your internet connection |
| `--validate` shows errors | Follow the hints. Missing keys — fill them in `.exocortex.env` |

> **Tip:** `setup.sh --validate` checks ALL categories at once: env config, required files, extensions, MCP availability.

### 1.4 Installing Additional Roles (Later)

Setup.sh installs only the Strategist. The Extractor and Synchronizer are installed separately, once you have mastered the basic cycle:

In the terminal:
```bash
cd ~/IWE/FMT-exocortex-template

# Extractor — extracts knowledge from sessions, checks inbox (every 3 hours)
bash roles/extractor/install.sh

# Synchronizer — central scheduler: agent scheduling, notifications, code-scan
bash roles/synchronizer/install.sh
```

> **Recommendation:** The Extractor and Synchronizer can be installed later, once you have mastered the basic cycle with the Strategist. For details: [roles/extractor/README.md](../roles/extractor/README.md) and [roles/synchronizer/README.md](../roles/synchronizer/README.md).

> **Important:** If you install the Synchronizer, it replaces the individual launchd agents of the Strategist with a unified scheduler. All roles will be launched on schedule from a single point.

## Something Is Not Working?

**`CLAUDE.md` not found:**
```bash
cp ~/IWE/FMT-exocortex-template/CLAUDE.md ~/IWE/CLAUDE.md
```

**Memory not found:**
```bash
# Determine the slug
echo $HOME/IWE | tr '/' '-'
# Example output: -Users-ivan-IWE

# Create the directory and copy
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

If IWE is already configured on one device, you do **not** need to initialize Memory from scratch on a new one. `day-close.sh --backup` and the `memory-exocortex-sync.sh` hook keep a mirror of Memory in `DS-strategy/exocortex/`, and it is pushed to GitHub together with the governance repo. `restore-from-exocortex.sh` restores it.

**Steps on a new device:**

```bash
# 1. Stage 0 (binaries, gh auth, claude CLI) — as usual
# 2. Workspace folder + clone the template and governance repo (it carries exocortex/)
mkdir -p ~/IWE && cd ~/IWE
gh repo fork TserenTserenov/FMT-exocortex-template --clone
git clone https://github.com/<your-login>/DS-strategy.git

# 3. Restore Memory from backup (instead of initializing from scratch)
bash ~/IWE/FMT-exocortex-template/scripts/restore-from-exocortex.sh ~/IWE/DS-strategy
#    --dry-run  — preview without changes
#    --force    — overwrite an already-populated memory/

# 4. Restart Claude Code → Memory is in place
```

The Script: copies `exocortex/*.md|*.yaml` → auto-memory (`~/.claude/projects/<slug>-IWE/memory/`), `exocortex/CLAUDE.md` → `~/IWE/CLAUDE.md`, creates a symlink `~/IWE/memory → auto-memory`. A non-empty `memory/` is not touched without `--force` (protects against accidental overwrite of a working installation).

## Stage 2: First Strategic Session (~30 min)

This is the most important step — you will configure your goals and first plan.

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

> **"Let's run the first strategic Session"**

Claude will read CLAUDE.md and memory/ and guide you through:

1. **Defining goals** — Who do you want to be in a year? What do you want to learn?
2. **Dissatisfactions** — What is blocking you? Where is the gap between current and desired state?
3. **First WeekPlan** — Specific tasks for the week with budgets
4. **Registration in WP-REGISTRY.md and WeekPlan** — Work Products from the Session will appear in the registry and the plan

**Result:** populated `DS-strategy/docs/Strategy.md`, `Dissatisfactions.md`, and the first `WeekPlan` in `DS-strategy/current/`.

## Stage 3: Setting Up Notes via Telegram (5 min, optional)

To send thoughts into the planning system directly from Telegram:

1. Find the bot **@aist_me_bot** in Telegram
2. Press `/start`
3. Subscribe (if you have not yet)

**How to send notes:**
- Write: `.My thought about architecture` (dot + text)
- Or forward/reply to any message with `.`

The note goes to `DS-strategy/inbox/fleeting-notes.md`. The Strategist will process it in the evening (Note-Review, 23:00) and classify it: task → plan, Knowledge → captures, idea → for discussion.

## Stage 4: WakaTime — Time Tracking (10 min, optional)

WakaTime tracks work time automatically: by project, language, and category.

In VS Code or the terminal, launch Claude Code and say:

> **/setup-wakatime**

Claude will guide you through the installation:
1. wakatime-cli
2. API key (get it at [wakatime.com/settings/api-key](https://wakatime.com/settings/api-key))
3. Hooks for Claude Code
4. Desktop App (optional)

After setup: WakaTime data is automatically included in the morning daily plan and weekly report.

> **Privacy:** WakaTime is a SaaS service (wakatime.com, AWS servers, USA). The server receives **metadata** about your work: project names, file names, languages, branches, activity time. File contents are **NOT** sent. The CLI is open source ([github.com/wakatime/wakatime-cli](https://github.com/wakatime/wakatime-cli)). The Desktop App is closed source and requests Accessibility permission (sees active windows). If metadata is sensitive — use the self-hosted alternative [Wakapi](https://github.com/muety/wakapi) (wakatime-cli supports a custom `api_url` in `~/.wakatime.cfg`).

## Stage 5: Google Calendar — Day Events in Day Open (10 min, optional)

Connecting Google Calendar lets you see the day's events directly in the morning plan, create events from Claude Code, and prepare for meetings.

### What You Get

- **Day Open** will show a table of the day's events + free slots for work
- **Event creation** — "schedule a call for Wednesday 11:00" directly from Claude Code
- **Meeting preparation** — Claude will pull in context from related Work Products

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

> **⚠ Google may show "This app isn't verified".** This is normal — click "Advanced" → "Go to IWE (unsafe)". This warning will disappear after app verification.

### Multiple Accounts

You can connect multiple Google accounts (work + personal):

```
Claude, connect another Google Calendar account
```

Each account receives a nickname (`personal`, `work`) for addressing.

### Privacy

Calendar data is processed through the Google Calendar API. OAuth tokens are stored locally. Event contents are sent to the Claude API to generate the daily plan. Confidential events (visibility=private) can be excluded from display.

## Stage 6: Video Integration — Linking Recordings to Work Products (5 min, optional)

If you record meetings (Zoom, Telemost, Google Meet), Claude can scan folders with recordings and link videos to Work Products.

### What You Get

- **Day Open** will show new video recordings linked to Work Products
- **Strategy Session** — a weekly review of all unprocessed videos
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

### Finding Your Folders

| Application | Typical Path (macOS) |
|-------------|----------------------|
| Zoom | `~/Documents/Zoom` |
| Yandex.Telemost | `~/Documents/Телемост` or `~/Видеозаписи Телемост` |
| Google Meet | Recordings in Google Drive (not local) |
| OBS | Configured in OBS → Settings → Output |

### Linking to Work Products

The Script links videos to Work Products by file name:
- `WP-73-...mp4` → linked to WP-73
- `2026-03-14-...mp4` → linked by date (matched against the calendar)
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

This is a **conscious choice**, not a required step. Two questions will help you decide:

**1. Do you have autonomous agents?**

If you have just started working with IWE and only use Claude Code in interactive mode — **you do not need this**. All scheduler reports will be stored in `DS-strategy/current/` and `DS-strategy/archive/` — that is sufficient.

**2. Are agents generating >10 files per week?**

When Scheduler, Scout, Extractor, and other agents run daily, they create dozens of files: scheduler reports, bot QA reports, findings, plan drafts. These auto-commits pollute the git history of DS-strategy, which should contain only **human decisions** (plans, approved captures).

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

The Script creates a private GitHub repo `DS-agent-workspace` with a structure for each agent type. After creation, the scheduler Scripts (`daily-report.sh` and others) will automatically write there — checked by the presence of `DS-agent-workspace/.git`.

### When to Connect

**Recommended path:**
1. Start without Agent Workspace (Stages 0-2)
2. Connect Scheduler (launchd) — reports go to DS-strategy
3. When auto-commits exceed 5/day → create Agent Workspace

## Automatic Wake and Sleep Prevention

Agents run on a schedule. If the laptop is sleeping — tasks wait for it to wake. Configure automatic wake so the plan is ready before you wake up.

**macOS:**

```bash
# Wake at 3:55 every day (5 min before the Strategist)
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

> **How it works:** The Mac wakes at 3:55, the scheduler starts at 4:00, the plan is ready by ~4:20. Scripts automatically keep the Mac awake via `caffeinate -diu` (works on battery profile too).
>
> **Charge Limit (recommended):** instead of Optimized Battery Charging, enable a fixed limit (System Settings → Battery → Charge Limit → 80%). Protects the battery without unpredictable profile switching.

**Linux:**

```bash
# Wake via rtcwake (one-time, usually in cron)
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

## What Happens Next (Automatically)

After installation, the system runs on its own:

| Time | Agent | What Happens | Where the Result Goes |
|------|-------|-------------|----------------------|
| **Morning (Tue-Sun)** | Strategist | Collects yesterday's commits, generates daily plan | `DS-strategy/current/DayPlan YYYY-MM-DD.md` |
| **Morning (Mon)** | Strategist | Prepares a draft weekly plan + Session agenda | `DS-strategy/current/WeekPlan W{N}.md` |
| **Every 3 hours** | Extractor* | Checks inbox (notes, captures) → proposes Knowledge for Pack | `DS-strategy/inbox/extraction-reports/` |
| **Evening (23:00)** | Strategist | Note-Review classifies notes from Telegram | Target documents in DS-strategy |
| **Night (00:00)** | Synchronizer* | Code-scan — review of changes in downstream repos | `DS-strategy/current/CodeScan YYYY-MM-DD.md` |
| **Night (Sun→Mon)** | Strategist | Week Review — weekly summary | `DS-strategy/current/WeekReport W{N} YYYY-MM-DD.md` |
| **Morning (06:00)** | Synchronizer* | Daily report — summary of overnight tasks | `DS-agent-workspace/scheduler/reports/` (or `DS-strategy/current/` without Agent Workspace) |

> *Extractor and Synchronizer run only if installed (Stage 1.4).*

### Manual Launch (When Needed)

In the terminal:
```bash
# Daily plan right now
bash ~/IWE/FMT-exocortex-template/roles/strategist/scripts/strategist.sh day-plan

# Strategy Session (interactive)
bash ~/IWE/FMT-exocortex-template/roles/strategist/scripts/strategist.sh strategy-session

# Note review
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

## Daily Work: Three Stages (Opening-Work-Closing)

Each Session in Claude Code passes through three stages:

### Opening (Automatic)
You give a task → Claude checks: is this task in the weekly plan? If not — it proposes adding it (WP Gate). It announces the Role, Method, and Assessment.

### Work
Claude executes the task. At each Work milestone (subtask, pattern, decision) — it captures Knowledge: *"Capture: [what] → [where]"*.

### Closing
Say **"close"** → Claude commits, pushes, updates Memory, and creates a Backup.

## Updates

The exocortex Template is updated — new Protocols, improved prompts, Skills, Scripts, and fixes.

In the terminal:
```bash
cd ~/IWE/FMT-exocortex-template
bash update.sh
```

The Script downloads the update Manifest from GitHub, compares it with your files, shows a preview (what is new, what changed), and applies changes after your confirmation. Self-update: `update.sh` updates itself on every run.

**What is updated (platform-space):**
CLAUDE.md (§1-7), memory/ (Protocols, references), role prompts and Scripts, Hooks, Skills, setup Scripts. If role Scripts changed — launchd agents are reinstalled automatically.

**What is NOT touched (user-space):**
- CLAUDE.md — 3-way merge