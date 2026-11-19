# IWE Installation: Step-by-Step Guide

> This guide takes you from a clean computer to a working IWE in 30–60 minutes.
> Suitable for macOS and Linux. On Windows, some commands are available in Git Bash; sessions require WSL2 — see the limitations below.
> Not sure what to change for your platform? → **[PORTABILITY.md](PORTABILITY.md)**
>
> **Source-of-truth:** `DP.IWE.002` (Pack). If this file conflicts with the Pack, the Pack takes priority.
> Via Aisystant MCP: `knowledge_search("IWE installation template")`.
>
> **Need a shorter version?** → [QUICK-START.md](QUICK-START.md) (15 minutes, assuming Git, Node.js, and the CLI are already installed). This document covers a full installation from scratch.

## Where You Are Now and Where You Are Going

The platform grants access by tiers (`DP.ARCH.002`): from T0 (no account) to T4 (Creation, IWE). You may already be using the bot — that is T1–T3. This guide moves you to **T4**, where a personal workspace with AI agents becomes available.

| Tier | What it includes | How to get there |
|------|-----------------|-----------------|
| **T1: Start** | @aist_me_bot: knowledge base search, marathons | `/start` in Telegram |
| **T2: Learning** | + Programs, guides, schedule | Subscribe to a program |
| **T3: Personalization** | + Personal answers, digital twin | `/twin` in the bot |
| **T4: Creation (IWE)** | + Claude Code, Strategist, Git, personal knowledge bases | **This guide** |

> Everything you have accumulated at T1–T3 (Digital Twin, profile, progress) is preserved. T4 adds new capabilities; it does not replace the existing ones.

## What You Will Have at the End

- **Claude Code** — an AI assistant that knows your goals, tasks, and methodology. It remembers context between sessions.
- **Strategist** (AI agent) — prepares a daily plan every morning and a weekly review every Sunday.
- **Extractor** (AI agent, later) — extracts knowledge from sessions into the knowledge base.
- **Synchronizer** (later) — agent scheduling, Telegram notifications.
- **DS-strategy** — your personal strategic hub (private repository on GitHub).
- **Personal guide** — an optional development route assembled from your goals and context.
- **Telegram notes** — write a thought in the bot; it enters the planning system.

### Stage Map

| Stage | What | Time | On first installation |
|-------|------|------|-----------------------|
| **0** | Preparation (Git, Node, Claude Code) | 15–20 min | **required** |
| **1** | IWE installation | ~5 min | **required** |
| **2** | First strategic session | ~30 min | **required** |
| **2a** | Personal guide | 10–20 min | can do later |
| **3** | Telegram notes | 5 min | can do later |
| **4** | WakaTime (time tracking) | 10 min | can do later |
| **5** | Google Calendar | 10 min | can do later |
| **6** | Video integration | 5 min | can do later |
| **7** | Agent Workspace (agent data) | 10 min | when >2 agents |

> **Minimum to start:** Stages 0 → 1 → 2. Everything else can be connected at any time — tell Claude *"set up calendar"* or *"connect video recordings"*.
>
> **Kimi as a second agent:** if you want to work in IWE with Kimi Code as well as Claude, the connection is described in [`docs/KIMI-SETUP.md`](KIMI-SETUP.md).

## How to Open a Terminal

All commands in this guide are run in a **terminal** — a program where you enter text commands.

**macOS:**
- Press `Cmd + Space` (Spotlight) → type `Terminal` → press Enter.
- Or: Finder → Applications → Utilities → Terminal.

**Windows:**
- Install [Git for Windows](https://git-scm.com/download/win) (default checkboxes are fine).
- Open **Git Bash** — Start → type `Git Bash` → press Enter. Sessions require WSL2; details → [§ 0.0 "Windows: Git Bash and WSL2"](#00-windows-git-bash-and-wsl2).

**Linux:**
- `Ctrl + Alt + T` (in most distributions).

> In the terminal you will see a prompt such as `username@computer:~$`. Type a command and press Enter.

## Stage 0: Preparation (15–20 min)

If Git, Node.js, GitHub CLI, and Claude Code CLI are already installed, go to [Stage 1](#stage-1-iwe-installation-5-min).

> **⚠ Network restrictions (Russia and similar regions).** Some downloads below (GitHub, npm, Homebrew) may not be directly accessible. Standard workarounds: VPN, system proxy, or `torify <command>` for individual calls — for example `torify curl ...` or `torify git clone ...`. For `npm`/`brew`, `torify` is often insufficient; configure the package manager's own proxy or registry instead. If a specific step below fails, check whether this is the cause before debugging the error.

### 0.0 Windows: Git Bash and WSL2

Git Bash is suitable for individual preparation commands and some scripts. `session-guard.sh` fails in native Git Bash before a session opens: its Unix lock `fcntl` is unavailable. Run IWE inside **WSL2** for session work. A full installation and update on Windows has not yet been verified end-to-end.

> **Commits in Git Bash.** If commits are blocked by the `session-open-gate.sh` hook, you can temporarily disable the check with the key `session_open_gate_skip_until: YYYY-MM-DD` in `params.yaml` (no more than 30 days ahead; details in `params.yaml.example` and `docs/PLATFORM-COMPAT.md`). The key is set by the person, not the agent. An agent with write access can extend it, so periodically compare `params.yaml` and `.iwe-runtime/session-open-gate-skip.log`.

1. **Git for Windows** — download from [git-scm.com](https://git-scm.com/download/win) and install (default checkboxes are fine). **Git Bash** is included for individual preparation commands.
2. **Native Git Bash for individual commands:** prepare tools for Windows as described below. For sessions, skip these installers and perform Stages 0 and 1 — including Node.js, GitHub CLI, Claude Code CLI installation, and running `setup.sh` — inside a Linux terminal in WSL2.
   - Node.js — installer from [nodejs.org](https://nodejs.org/) (LTS version).
   - GitHub CLI — installer from [cli.github.com](https://cli.github.com/) or `winget install --id GitHub.cli` (can be run from regular PowerShell; installs system-wide).
   - Claude Code CLI — the same command `npm install -g @anthropic-ai/claude-code` as on macOS/Linux (Git Bash can run `npm` if Node.js is on PATH).
3. **Automatic Claude Code hooks** invoke `.sh` files through the system shell. Having `bash` on `PATH` does not replace WSL2 for hooks that call `session-guard.sh`.
4. **Local automation (Strategist/Extractor without human involvement)** — Windows has no `launchd`/`systemd`; the nearest equivalent is Windows Task Scheduler (see the example in [Automatic Wake](#automatic-wake-and-sleep-prevention) below). The simpler path without local jobs is the cloud option via GitHub Actions (OS-independent; nothing needs to stay on continuously).
5. **For sessions, install WSL2** (`wsl --install` in an administrator PowerShell) and perform installation steps inside the Linux terminal in WSL2. An end-to-end run of this path on Windows has not yet been confirmed.

> **Verification boundary.** CI on `windows-latest` checks the Strategist lock in Git Bash (#1030) and early `session-guard.sh` failure without writing to canon (#1032). Full installation and update via Git Bash, as well as the full WSL2 path, have not yet been tested.

### 0.1 Homebrew (macOS only)

Homebrew is a package manager for macOS. It is needed to install the remaining tools with a single command. If it is already installed, skip this step.

In the terminal:
```bash
# Check whether Homebrew is present
brew --version

# Install (if absent)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

After installation, Homebrew may ask you to run a command to update PATH — copy and run it.

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

GitHub CLI (`gh`) is a tool for working with GitHub from the terminal. The installer uses it to create repositories and copy the template.

**GitHub account:** if you do not have one, sign up at [github.com](https://github.com/signup).

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

Now authorize with GitHub (one-time):
```bash
gh auth login
# Choose: GitHub.com → HTTPS → Login with a web browser
# A browser will open → sign in to your GitHub account
```

Verify:
```bash
gh auth status
# Should show: ✓ Logged in to github.com as <username>
```

**If browser login does not work** (`Login with a web browser`) — at the method selection step, choose `Paste an authentication token` instead. This option does not open a browser; `gh` waits for a ready token:

1. Open `https://github.com/settings/tokens` in a browser.
2. Create a token: **classic** (`Tokens (classic)` — a separate tab/link; the default page opens to fine-grained), with at least `repo` and `workflow` permissions (required so the forked template can push `.github/workflows`). Classic is simpler for this scenario — it is clear which permissions to grant. Do not restrict the token to specific repositories (`setup.sh` creates new ones).
3. Copy the token and paste it into the terminal when `gh auth login` prompts for it.
4. Verify with the same `gh auth status` command as above.

### 0.5 Claude Code CLI

Claude Code is an AI agent that runs in the terminal (or in VS Code). It reads files, executes commands, and helps with planning and writing code.

An Anthropic subscription is required. Starting with **Claude Pro** ($20/month) is recommended. Use **Claude Max** (~$100/month) if you need to work without limits.

In the terminal:
```bash
# Install
npm install -g @anthropic-ai/claude-code

# Check
claude --version
```

On first launch, Claude Code will ask you to sign in to your Anthropic account — follow the instructions in the terminal.

### 0.5b Cost Optimization: Choosing a Model

Claude Code lets you choose the model for each task. Choosing correctly saves your subscription quota.

| Model | Verification class | When to use | Cost |
|-------|--------------------|-------------|------|
| **Opus** | open-loop, problem-framing | Architecture, complex code, strategy, multi-system changes | High |
| **Sonnet** | closed-loop | Standard tasks, single-file edits, writing content | Medium |
| **Haiku** | trivial | Renaming, updating links, formatting, finding a file, cron agents | Low |

Switch the model in Claude Code: `/model` → select. For automated tasks (Strategist, Extractor), Haiku is recommended — it saves ~80% of quota compared to Opus.

> **How it works — two scenarios:**
> - **Entire session on a different model:** When a session opens, Claude determines the verification class. If the task is trivial/closed-loop and the current model is excessive, Claude will say: *"I recommend switching to [Haiku/Sonnet] via `/model`. I cannot switch automatically."* The user switches manually.
> - **Individual task within a session:** If a trivial task appears mid-session, Claude delegates it to a sub-agent on a cheaper model. The main session is not interrupted. Delegation only goes downward (Opus→Sonnet/Haiku, Sonnet→Haiku). Switching upward requires `/model`.
>
> **Tip:** On a Claude Pro subscription ($20/month), use Haiku actively for routine work (morning plans, file search, trivial edits). Use Opus only for architectural decisions and complex code.

### 0.6 VS Code (recommended)

VS Code is a code editor with a graphical interface. It makes working with Claude Code convenient: you see all your repositories, files, the terminal, and the AI assistant in one window, and you can switch between repositories of different projects in a single session. **Without VS Code** you work through the terminal only — this is possible but less visual.

- Download and install: [code.visualstudio.com](https://code.visualstudio.com/)
- Open VS Code → press `Cmd+Shift+X` (macOS) or `Ctrl+Shift+X` (Windows/Linux) → find "Claude Code" → click Install.

If you use Obsidian, open only the separate governance repository `DS-strategy` as a vault. Opening the IWE root (`~/IWE`) as an Obsidian vault is not supported: large technical Markdown files such as `FPF/FPF-Spec.md` can hang the indexer and produce a blank screen. Open the entire workspace through VS Code; do not link technical repositories into the governance vault via symbolic links.

## Stage 1: IWE Installation (~5 min)

### 1.1 Create a Working Folder

Create **one folder** on your computer for all repositories — current and future. All repositories will be cloned into it: `IWE/`, `DS-strategy/`, `PACK-{domain}/`, `DS-{projects}/`, and others. `CLAUDE.md` will also live in the root of this folder. The default is `~/IWE`:

```bash
mkdir -p ~/IWE
cd ~/IWE
```

> **Important:** The name can be anything, but all repositories must be in one place — Claude Code relies on this structure. `~/IWE` is recommended.

### 1.2 Fork the Template and Run the Installer

In the terminal:

```bash
# Make sure we are in the working folder
cd ~/IWE

# Fork the template to your GitHub and clone it
gh repo fork iwesys/IWE --clone
cd IWE

# Run the installer
bash setup.sh
```

> **Preview without executing:** `bash setup.sh --dry-run`

The script will ask:

| Question | What to enter | Example |
|----------|--------------|---------|
| GitHub username | Your GitHub login | `ivan-petrov` |
| Workspace directory | Working folder | Just press Enter (detected automatically) |
| Claude CLI path | Path to claude | Just press Enter (detected automatically) |
| Strategist launch hour (UTC) | Hour to launch the Strategist | `4` (= 7:00 MSK, 8:00 Almaty) |
| Timezone description | Time description | `7:00 MSK` |

The script performs 6 steps:
1. Substitutes your data into all files (name, paths, timezone).
2. Installs `CLAUDE.md` — rules for Claude Code.
3. Installs `memory/` — working memory for Claude Code.
4. Configures permissions (`.claude/settings.local.json`) and prints MCP connection instructions.
5. Sets up automatic Strategist launch (launchd on macOS).
6. Creates `DS-strategy/` — your private strategic repository on GitHub.

### 1.2b Fork Visibility and Personal Data

`gh repo fork` creates a **public** fork: GitHub does not allow making a fork of a public repository private. Therefore:

- The `IWE/` directory contains platform files (methodology, scripts, samples). Everything you commit and push from there is visible to anyone.
- Personal data lives **outside** that directory: `memory/` lives in Claude Code's memory (`~/.claude/projects/<slug>/memory`; in the working folder there is a symlink to it), `extensions/` and `params.yaml` live in the working folder, and strategy and memory backup live in the separate private repository `DS-strategy`.
- The directories `memory/` and `extensions/` inside the template clone are platform samples, not your data. Do not edit them for personal use and do not push personal context to the fork.

**Need a private template repository?** It cannot be a fork. Create a private duplicate and keep the original as `upstream`:

```bash
git clone --bare https://github.com/iwesys/IWE.git
cd IWE.git
gh repo create IWE --private
git push --mirror "https://github.com/<your-login>/IWE.git"
cd .. && rm -rf IWE.git
git clone "https://github.com/<your-login>/IWE.git"
cd IWE
git remote add upstream https://github.com/iwesys/IWE.git
```

What is known about the private copy (derived from code reading; a full run on a private copy has not been performed):

| Part | What happens |
|------|-------------|
| `update.sh` | Fetches updates from the hard-coded original address (`UPSTREAM-CONST`), not from your fork or copy, so switching from fork to copy does not change the update source. One exception: in the release channel, the rollback check does `git fetch origin <release commit>` in your clone; if the copy does not have that commit, auto-apply with `--yes` stops, but interactive mode works. |
| `scripts/fmt-critical-alert.sh` | The copy has no "parent", so the script checks **its own** issue list, which is empty. A response of "0 (✅ clean)" here means "nothing to check", not "no problems" (if the tracker is disabled, the script exits with "cannot check"). Set `IWE_FMT_REPO=iwesys/IWE` (environment variable or a line in `.exocortex.env`) to point it at the original's issues. |
| Template directory connection to knowledge search (MCP) | Not verified here. |

### 1.3 Verify the Installation

In the terminal:
```bash
# Must exist
ls ~/IWE/CLAUDE.md

# Must have memory files (10+)
ls ~/.claude/projects/*/memory/

# Must have the strategic hub
ls ~/IWE/DS-strategy/

# Strategist must be in the schedule (macOS)
launchctl list | grep strategist
```

If everything is present, check the MCP connection (1.3b) and proceed to Stage 2. Additional roles (1.4) can be installed later.

### 1.3b Connect MCP Servers

MCP (Model Context Protocol) gives Claude Code access to the platform knowledge base and your personal repositories. Through it, Claude sees documents, guides, the digital twin, and your own Pack repositories — domain knowledge bases you build over time.

> **Why:** Documentation and Pack entities (DP.IWE.001, DP.ARCH.001, etc.) reference source-of-truth entries in PACK-digital-platform. After connecting MCP, Claude can find these entities on request and work with your personal repositories directly. Without MCP, entities are only accessible as files on GitHub.

> Below is the path for Claude Code (via `claude.ai`). For other agents (Hermes etc.), see `AGENT-VENDOR-SETUP.md`, Step 6.

**Connection:**

1. Open https://claude.ai/settings/connectors
2. Add the MCP server (Aisystant MCP): `https://mcp.aisystant.com/mcp`
3. Restart Claude Code.

**How it works:** Claude Code connects to Aisystant MCP through claude.ai connectors. The server aggregates all backends (knowledge, digital-twin) and exposes tools (`knowledge_search`, `knowledge_get_document`, `knowledge_feedback`, `dt_read_digital_twin`, and others).

#### Verification

Open Claude Code in the exocortex folder and type `/mcp` — the servers must have status Connected. Then ask:
> Find documents about principles

Claude should use `knowledge_search("principles")` and return a list of documents from the knowledge base.

**Diagnostics:**

```bash
# Check the full installation (env, files, extensions, MCP availability)
bash IWE/setup.sh --validate
```

| Problem | Solution |
|---------|---------|
| `/mcp` — no servers | Repeat steps 1–3 (claude.ai connectors) |
| Opened the URL in a browser — "Not found" | This is normal. MCP works over POST (JSON-RPC), not GET. Check via `/mcp` in Claude Code. |
| Aisystant MCP — connection error | Check your internet connection. |
| `--validate` shows errors | Follow the hints. Fill in missing keys in `.exocortex.env`. |

> **Tip:** `setup.sh --validate` checks ALL categories at once: env config, required files, extensions, MCP availability.

### 1.3c Connect Your Repositories to Personal Search (optional)

Step 1.3b gives Claude access to the platform knowledge base. Your own repositories (notes, Pack, working projects) are not included in that search by default — they must be connected separately.

**How to connect:** tell the agent "connect my GitHub". It will call the `github_connect` tool and provide a sign-in link. If the GitHub App `aisystant-knowledge` is not yet installed, the page and the agent will then provide a second link for installation. On that GitHub page, select your account and repositories and click Install. The selected repositories connect immediately; no second sign-in or additional configuration is needed. Only what you explicitly select is indexed.

If the app has already been installed on an organization by its administrator, installation is not needed: after sign-in the agent will show the organization's repositories and you choose which to connect. You can add your own repository later in the installed app settings on GitHub (Settings → Applications → `aisystant-knowledge` → Configure): it connects automatically within a minute or two.

> **About privacy:** the content of selected repositories (including private ones) leaves your machine and GitHub and is stored on the platform server as a search index — this is required for semantic search rather than keyword search. Do not connect a repository if you are not ready for this.

After installation, indexing runs automatically: the initial pass is usually fast, but may take longer for large repositories. Subsequent pushes are reindexed automatically without any local machine involvement.

### 1.4 Installing Additional Roles (later)

Setup.sh installs only the Strategist. The Extractor and Synchronizer are installed separately, once you have mastered the basic cycle.

In the terminal:
```bash
cd ~/IWE/IWE

# Extractor — knowledge extraction from sessions, inbox check (every 3 hours)
bash roles/extractor/install.sh
# Inbox check runs without you (headless) — a one-time subscription sign-in is required:
bash roles/extractor/scripts/connect.sh

# Synchronizer — central scheduler: agent scheduling, notifications, code-scan
bash roles/synchronizer/install.sh
```

> **Recommendation:** The Extractor and Synchronizer can be installed later, once you have mastered the basic cycle with the Strategist. Details: [roles/extractor/README.md](../roles/extractor/README.md) and [roles/synchronizer/README.md](../roles/synchronizer/README.md).

> **Important:** Installing the Synchronizer replaces the individual Strategist launchd agents with a single scheduler. All roles will run on schedule from one point.

## Something Is Not Working?

**`CLAUDE.md` not found:**
```bash
cp ~/IWE/IWE/CLAUDE.md ~/IWE/CLAUDE.md
```

**Memory not found:**
```bash
# Determine the slug
echo $HOME/IWE | tr '/' '-'
# Example result: -Users-ivan-IWE

# Create the directory and copy
mkdir -p ~/.claude/projects/-Users-ivan-IWE/memory
cp ~/IWE/IWE/memory/*.md ~/.claude/projects/-Users-ivan-IWE/memory/
```

**launchd not loaded:**
```bash
cd ~/IWE/IWE/roles/strategist
bash install.sh
```

**DS-strategy not created:**
```bash
cd ~/IWE
mkdir -p DS-strategy/{current,inbox,docs,archive/wp-contexts,exocortex}
cd DS-strategy && git init && git add -A && git commit -m "Initial"
gh repo create $(gh api user -q .login)/DS-strategy --private --source=. --push
```

## Restoring on a New Device (from an exocortex backup)

If IWE is already set up on one device, there is **no need** to initialize memory from scratch on a new device. `day-close.sh --backup` and the `memory-exocortex-sync.sh` hook keep a mirror of memory in `DS-strategy/exocortex/`, and it goes to GitHub with the governance repository. `restore-from-exocortex.sh` deploys it back.

**Steps on a new device:**

```bash
# 1. Stage 0 (binaries, gh auth, claude CLI) — as usual
# 2. Working folder + clone the template and governance repo (it carries exocortex/)
mkdir -p ~/IWE && cd ~/IWE
gh repo fork iwesys/IWE --clone
git clone https://github.com/<your-login>/DS-strategy.git

# 3. Restore memory from backup (instead of initializing from scratch)
bash ~/IWE/IWE/scripts/restore-from-exocortex.sh ~/IWE/DS-strategy
#    --dry-run  — preview without changes
#    --force    — overwrite an already-populated memory/

# 4. Restart Claude Code → memory is in place
```

The script copies `exocortex/*.md|*.yaml` → auto-memory (`~/.claude/projects/<slug>-IWE/memory/`), `exocortex/CLAUDE.md` → `~/IWE/CLAUDE.md`, and creates the symlink `~/IWE/memory → auto-memory`. It does not touch a non-empty `memory/` without `--force` (protection against accidentally overwriting a working installation).

## Stage 2: First Strategic Session (~30 min)

This is the most important step — you will set your goals and create your first plan.

**Option A — via VS Code (recommended):**
1. Open VS Code.
2. `File → Open Folder` → select the `~/IWE` folder.
3. Open the Claude Code panel: `Cmd+Shift+P` (macOS) or `Ctrl+Shift+P` (Windows) → type "Claude Code: Open" → Enter.

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
3. **First WeekPlan** — Concrete tasks for the week with budgets.
4. **Registration in WP-REGISTRY.md and WeekPlan** — Work Products from the session appear in the registry and the plan.

**Result:** populated `DS-strategy/docs/Strategy.md`, `Dissatisfactions.md`, and the first `WeekPlan` in `DS-strategy/current/`.

### Personal Guide (up to 60 min, experimental and optional)

This step is not required for IWE to work. The safe choice is to skip it until you specifically need a public guide. The `/personal-guide-start` command asks no clarifying questions: its first action is to create or reuse an external **public** GitHub repository `DS-personal-guide` (`private: false`). Run it only if you deliberately accept this external effect.

Before running it, you need an active "Engineering of Intelligence" subscription, GitHub connected in Aisystant MCP, and the `create_repository` and `github_status` operations available. Populating the six files is performed by a separate command `/personal-guide-render`, which additionally requires Memory.Derived and the `personal_write` operation. If the server renderer or these operations are unavailable, the bootstrap will not complete: a public repository may already have been created on GitHub without the six ready files. This should not be treated as a completed personal guide.

If the command itself is not visible, check for `.claude/skills/personal-guide-start/SKILL.md` and restart Claude Code. If the command is visible but server operations are unavailable, do not run it again blindly — restore the GitHub/Aisystant MCP connection and the renderer first.

## Stage 3: Setting Up Telegram Notes (5 min, optional)

To send thoughts to the planning system directly from Telegram:

1. Find **@aist_me_bot** in Telegram.
2. Press `/start`.
3. Sign in with your MIM account — notes from the bot are available to MIM members (terms at https://aisystant.com).

**How to send notes:**
- Write: `.My thought about architecture` (period + text).
- Or forward/reply to any message with `.`.

A note goes into `DS-strategy/inbox/fleeting-notes.md` and waits there for your decision. Notes are not reviewed automatically in the evenings. When you are ready, review them in one of three ways: open the "Note Review" section in the daily plan (a mini-review in Day Open lists notes awaiting a decision); in a Claude Code session ask "Review notes according to the instructions in `roles/strategist/prompts/note-review.md`" (the agent will go through all steps); or run `bash ~/IWE/IWE/roles/strategist/scripts/strategist.sh note-review` in the terminal (terminal mode runs without chat: only marks `✅suggested` and proposals). The Strategist will suggest where to place each note: task → plan, knowledge → captures, idea → for discussion. It can only remove a note from the inbox and move it to the archive on your explicit instruction in a live session.

## Stage 4: WakaTime — Time Tracking (10 min, optional)

WakaTime tracks work time automatically: by project, language, and category.

In VS Code or the terminal, launch Claude Code and say:

> **/setup-wakatime**

Claude will guide you through the installation:
1. wakatime-cli
2. API key (get it at [wakatime.com/settings/api-key](https://wakatime.com/settings/api-key))
3. Hooks for Claude Code
4. Desktop App (optional)

After setup: WakaTime data is automatically included in the morning daily plan and the weekly report.

> **Privacy:** WakaTime is a SaaS service (wakatime.com, AWS servers, USA). **Metadata** about your work is sent to the server: project names, file names, languages, branches, activity time. File **contents** are **NOT** sent. The CLI is open source ([github.com/wakatime/wakatime-cli](https://github.com/wakatime/wakatime-cli)). The Desktop App is closed source and requests Accessibility permission (sees active windows). If metadata is sensitive, use the self-hosted alternative [Wakapi](https://github.com/muety/wakapi) (wakatime-cli supports a custom `api_url` in `~/.wakatime.cfg`).

## Stage 5: Google Calendar — Day Events in Day Open (10 min, optional)

Connecting Google Calendar lets you see the day's events directly in the morning plan, create events from Claude Code, and prepare for meetings.

### What You Get

- **Day Open** shows a table of the day's events and free work slots.
- **Event creation** — "schedule a call for Wednesday at 11:00" directly from Claude Code.
- **Meeting preparation** — Claude pulls in context from related Work Products.

### Setup (~1 min)

Run one command from the template root:

```bash
bash setup/optional/setup-calendar.sh
```

The script:
1. Writes OAuth credentials (Shared App IWE) to `.secrets/`.
2. Creates `.mcp.json` with Calendar MCP settings.
3. Opens a browser → sign in with your Google account → click "Allow".
4. Restart Claude Code → verify: **"show my events for today"**.

> **⚠ Google may show "This app isn't verified".** This is normal — click "Advanced" → "Go to IWE (unsafe)". This warning will disappear once the app is verified.

### Multiple Accounts

You can connect several Google accounts (work + personal):

```
Claude, connect another Google Calendar account
```

Each account gets a nickname (`personal`, `work`) for addressing.

### Privacy

Calendar data is processed through the Google Calendar API. OAuth tokens are stored locally. Event content is sent to the Claude API for daily plan generation. Confidential events (visibility=private) can be excluded from display.

## Stage 6: Video Integration — Linking Recordings to Work Products (5 min, optional)

If you record meetings (Zoom, Telemost, Google Meet), Claude can scan recording folders and link videos to Work Products.

### What You Get

- **Day Open** shows new video recordings with Work Product links.
- **Strategy Session** — a weekly review of all unprocessed videos.
- **Transcription** → automatic captures and post ideas (optional; requires whisper).

### Setup

1. Open `memory/day-rhythm-config.yaml`.
2. In the `video` section, specify your folders:

```yaml
video:
  enabled: true
  directories:
    - ~/Documents/Zoom
    - ~/Documents/Telemost
    # Add your own video recording folders
```

3. Verify: **"show my video recordings"** — Claude will run `video-scan.sh`.

### Where to Find the Folders

| Application | Typical path (macOS) |
|-------------|---------------------|
| Zoom | `~/Documents/Zoom` |
| Yandex Telemost | `~/Documents/Telemost` or `~/Video Recordings Telemost` |
| Google Meet | Recordings in Google Drive (not local) |
| OBS | Configured in OBS → Settings → Output |

### Linking to Work Products

The script links video to Work Products by file name:
- `WP-73-...mp4` → linked to WP-73.
- `2026-03-14-...mp4` → linked by date (matched with calendar).
- Others → manual linking is suggested.

### Transcription (optional)

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

## Stage 7: Agent Workspace — Separate Agent Data Storage (10 min, optional)

### Read Before Deciding

This is a **deliberate choice**, not a required step. Two questions will help you decide.

**1. Do you have autonomous agents?**

If you have just started with IWE and are using only Claude Code in interactive mode, **you do NOT need this**. All Scheduler reports will be stored in `DS-strategy/current/` and `DS-strategy/archive/` — that is sufficient.

**2. Are agents generating >10 files per week?**

When Scheduler, Scout, Extractor, and other agents work daily, they produce dozens of files: Scheduler reports, bot QA reports, findings, plan drafts. These auto-commits pollute the git history of DS-strategy, which should contain only **human decisions** (plans, approved captures).

### What Agent Workspace Provides

| Without Agent Workspace | With Agent Workspace |
|------------------------|---------------------|
| Everything in DS-strategy | Machine output is separate |
| Mixed git history | Clean decision history |
| 1 repository | 2 repositories |
| Simpler to start | Scales better |

### Setup

```bash
bash setup/optional/setup-agent-workspace.sh
```

The script creates a private GitHub repository `DS-agent-workspace` with a structure for each agent type. After creation, Scheduler scripts (`daily-report.sh` and others) will automatically write there — detected by the presence of `DS-agent-workspace/.git`.

### When to Connect

**Recommended path:**
1. Start without Agent Workspace (Stages 0–2).
2. Connect the Scheduler (launchd) — reports go to DS-strategy.
3. When auto-commits exceed 5/day → create Agent Workspace.

## Automatic Wake and Sleep Prevention

Agents run on a schedule. If the laptop is asleep, tasks wait for wake. Configure automatic wake so the plan is ready before you are.

**macOS:**

```bash
# Wake at 3:55 every day (5 min before the Strategist)
sudo pmset repeat wakeorpoweron MTWRFSU 03:55:00

# IMPORTANT: if the laptop is charging, Optimized Battery Charging may
# switch the power profile to "battery". In battery profile,
# the Mac sleeps even when the cable is connected. Solution:
sudo pmset -b sleep 0      # do not sleep in battery profile
sudo pmset -b standby 0    # do not enter deep standby

# Check: pmset -g custom (sleep=0 in both profiles)
# Cancel wake: sudo pmset repeat cancel
# Restore sleep: sudo pmset -b sleep 1 && sudo pmset -b standby 1
```

> **How it works:** The Mac wakes at 3:55, the scheduler starts at 4:00, the plan is ready by ~4:20. The scripts automatically keep the Mac awake via `caffeinate -diu` (works in battery profile too).
>
> **Charge Limit (recommended):** instead of Optimized Battery Charging, enable a fixed limit (System Settings → Battery → Charge Limit → 80%). This protects the battery without unpredictable profile switching.

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

> **General rule:** The `strategist.sh` and `scheduler.sh` scripts automatically prevent sleep during execution (macOS: `caffeinate -diu`, Linux: `systemd-inhibit`). You only need to configure **wake** and **OS-level sleep prevention** for laptops.

## What Happens Next (Automatically)

After installation, the system runs on its own:

| Time | Agent | What happens | Where the result goes |
|------|-------|--------------|----------------------|
| **Morning (Tue–Sun)** | Strategist | Collects yesterday's commits, generates daily plan | `DS-strategy/current/DayPlan YYYY-MM-DD.md` |
| **Morning (Mon)** | Strategist | Prepares weekly plan draft + session agenda | `DS-strategy/current/WeekPlan W{N}.md` |
| **Every 3 hours** | Extractor* | Checks inbox (notes, captures) → proposes knowledge to Pack | `DS-strategy/inbox/extraction-reports/` |
| **Night (00:00)** | Synchronizer* | Code-scan — review of changes in downstream repos | `DS-strategy/current/CodeScan YYYY-MM-DD.md` |
| **Night (Sun→Mon)** | Strategist | Week Review — weekly summary | `DS-strategy/current/WeekReport W{N} YYYY-MM-DD.md` |
| **Morning (06:00)** | Synchronizer* | Daily report — summary of overnight tasks | `DS-agent-workspace/scheduler/reports/` (or `DS-strategy/current/` if without Agent Workspace) |

> *Extractor and Synchronizer only run if installed (Stage 1.4).*

Reviewing Telegram notes is not in this list: it does not start automatically. You trigger it: via the "Note Review" section in the daily plan, by asking Claude Code to review notes in a session, or via the `note-review` terminal command (see Manual Launch below).

### Manual Launch (when needed)

In the terminal:
```bash
# Daily plan right now
bash ~/IWE/IWE/roles/strategist/scripts/strategist.sh day-plan

# Strategy session (interactive)
bash ~/IWE/IWE/roles/strategist/scripts/strategist.sh strategy-session

# Note review: terminal mode produces only marks and proposals; archiving and clearing only happen in a Claude Code session, on your explicit instruction
bash ~/IWE/IWE/roles/strategist/scripts/strategist.sh note-review

# Weekly review
bash ~/IWE/IWE/roles/strategist/scripts/strategist.sh week-review

# Extractor: extract knowledge from the current session (assembled runtime copy, not the raw file in FMT)
bash "$IWE_RUNTIME/roles/extractor/scripts/extractor.sh" session-close

# Extractor: check inbox
bash "$IWE_RUNTIME/roles/extractor/scripts/extractor.sh" inbox-check

# Synchronizer: status of all tasks
bash ~/IWE/IWE/roles/synchronizer/scripts/scheduler.sh status
```

## Daily Work: Three Stages (ORZ)

Each Claude Code session goes through three stages.

### Opening (automatic)
You give a task → Claude checks: is this task in the weekly plan? If not, it proposes adding it (WP Gate). It announces the role, method, and estimate.

### Work
Claude performs the task. At each milestone (subtask, pattern, decision) it captures knowledge: *"Capture: [what] → [where]"*.

### Closing
Say **"close"** → Claude commits, pushes, updates memory, and creates a backup.

## Updates

The exocortex template is updated — new protocols, improved prompts, skills, scripts, and fixes.

In the terminal:
```bash
cd ~/IWE/IWE
bash update.sh
```

The script downloads the update manifest from GitHub, compares it with your files, shows a preview (what is new, what has changed), and applies it after your confirmation. Self-update: `update.sh` updates itself on every run.

**What is updated (platform-space):**
CLAUDE.md (§1–7), memory/ (protocols, references), role prompts and scripts, hooks, skills, setup scripts. If role scripts change, launchd agents are reinstalled automatically.

**What is NOT touched (user-space):**
- CLAUDE.md — 3-way merge: your edits in any section are preserved on update.
- extensions/ — your protocol extensions.
- params.yaml — your protocol parameters.
- MEMORY.md — your working memory (Work Products, lessons).
- DS-strategy/ — plans, strategy, inbox.
- .secrets/, .mcp.json — integration keys and configuration.
- .claude/settings.local.json — personal permissions.
- personal/ — your files.


> Preview available updates without applying: `bash update.sh --check`

## Security and Privacy

> Full data policy: [DATA-POLICY.md](DATA-POLICY.md) | Canonical description: [DP.D.035](https://github.com/TserenTserenov/PACK-digital-platform/blob/main/pack/digital-platform/01-domain-contract/DP.D.035-data-policy.md)

IWE runs primarily locally. Here is what you need to know about security.

### What Stays Local

| Component | Where it is stored | Is it sent anywhere? |
|-----------|-------------------|---------------------|
| CLAUDE.md, memory/ | Local files | No (only into Claude's context during work) |
| DS-strategy | Private repository on GitHub | Only to GitHub (private) |
| Launch agents (Strategist etc.) | Local bash scripts | No |
| Git repositories | Local + GitHub | Only to GitHub |

### What Is Sent to External Servers

| Component | Where | What data |
|-----------|-------|-----------|
| **Claude Code** | Anthropic API (USA) | Prompts, content of files in context. [Privacy Policy](https://www.anthropic.com/privacy) |
| **WakaTime** (optional) | wakatime.com (USA) | Metadata: project names, file names, languages, time. File **contents** are **NOT** sent. |
| **Aisystant MCP** (knowledge base search) | Platform server (mcp.aisystant.com), OpenRouter (query embedding) | Text of the search query. Your file contents are not sent unless you connect your repositories (see §1.3c). |
| **Aisystant MCP** (if you connected your repositories, §1.3c) | Platform server (mcp.aisystant.com), OpenRouter (content embedding) | Contents of connected repositories, including private ones — sent to the server to build personal search. |
| **GitHub** | github.com (USA) | Repository contents. |

### Mac Security Recommendations

Before starting, check:

1. **Firewall** — must be enabled: `System Settings → Network → Firewall`.
2. **FileVault** — disk encryption: `System Settings → Privacy & Security → FileVault`.
3. **SIP** (System Integrity Protection) — do not disable: `csrutil status` in Terminal.
4. **.gitignore** — in every repository with code, it must exclude `.env`, `*.key`, `*.pem`, `credentials.json`.
5. **Secrets** — store API keys in `.env` (gitignored) or in a password manager, **never** in code.

### What Is NOT Recommended to Install

- Browsers from jurisdictions with mandatory data access (check the Privacy Policy).
- Closed-source extensions with broad access to the file system.
- Electron apps with unclear telemetry — check with `Little Snitch` or `LuLu` (open-source firewall).

### Self-Hosted Alternatives

If you work with sensitive data, consider:

| SaaS | Self-hosted alternative |
|------|------------------------|
| WakaTime | [Wakapi](https://github.com/muety/wakapi) — full equivalent, your own server |
| GitHub | [Gitea](https://gitea.io/) or [GitLab Self-Managed](https://about.gitlab.com/install/) |

## Frequently Asked Questions

**Is an Anthropic subscription required?**
Yes. Claude Code requires an Anthropic subscription. Starting with **Claude Pro** ($20/month) is recommended. Use **Claude Max** (~$100/month) if needed.

**Will Qwen, Perplexity, ChatGPT (chat), or other chatbots work?**
No. Chatbots and search assistants (Qwen chat, Perplexity, routerai.ru, regular ChatGPT) **do not work** — they cannot read or write files on your computer or execute terminal commands. The exocortex requires an **agentic AI assistant** — one that works with the file system, runs commands, and preserves context between sessions.

**What are the alternatives to Claude Code?**

| Alternative | What it is | Price | Models |
|---|---|---|---|
| **Cursor** | IDE with AI (VS Code replacement) | from $20/month | Claude, GPT, own |
| **GitHub Copilot** (Agent mode) | VS Code extension | from $10/month | Claude, GPT |
| **Cline / Roo Code** | VS Code extension (open source) | Free + API key | Any (Claude, GPT, Gemini) |
| **Aider** | CLI tool (open source) | Free + API key | Any |

> **Important note on models:** The exocortex requires complex agentic behavior from the model — following multi-step protocols, working with 5–10 files simultaneously, reliable editing. Recommended models: **Claude Opus/Sonnet**, **GPT-4o/o1**, **Gemini 2.5 Pro**. Weaker models (Qwen, Llama, Mistral) may lose context and skip protocol steps — they are suitable for regular coding but unreliable for exocortex management.

**Does it work on Windows?**
Partially: individual commands work in Git Bash (from [Git for Windows](https://git-scm.com/download/win)), but `session-guard.sh` and sessions require WSL2. Details → [§ 0.0 "Windows: Git Bash and WSL2"](#00-windows-git-bash-and-wsl2). The full installation and update path on Windows has not yet been verified.

**Is the Strategist required?**
No. The Strategist is automation (morning plans, reviews). Without it, Claude Code + CLAUDE.md + memory/ work fully. You plan manually.

**What is a Pack?**
A Pack is a domain knowledge base. It is created later, once you have accumulated enough captures. The first step is working with `captures.md` through the Extractor.

**How do I check MCP?**
Type `/mcp` in Claude Code — the servers must show Connected. Ask: "Find documents about principles". Not working? Run `bash IWE/setup.sh --validate` — it shows exactly what is broken. Details: see step 1.3b.

**Is my data safe?**
DS-strategy is a private repository. MEMORY.md is a local file. Nothing is published without your knowledge. For details on what is sent to external servers (Claude API, WakaTime, GitHub) — see the [Security and Privacy](#security-and-privacy) section.

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
rm -rf ~/IWE/IWE
rm -rf ~/IWE/DS-strategy
```

## Next Steps

| When | What | How |
|------|------|-----|
| After the first week | Run the strategy session (Mon) | Claude will suggest it |
| After 2 weeks | Create your first Pack (personal knowledge base) | `claude` → "Help me create my first Pack" |
| As you grow | Set up the Extractor (automatic knowledge extraction) | See [roles/extractor/README.md](../roles/extractor/README.md) |
| When ready | Connect the Synchronizer (Telegram notifications) | See [roles/synchronizer/README.md](../roles/synchronizer/README.md) |

## Additional Materials

**In this repository:**

| Document | Contents |
|----------|---------|
| [LEARNING-PATH.md](LEARNING-PATH.md) | Full IWE learning path: principles, protocols, agents, Pack, SOTA |
| [IWE-HELP.md](IWE-HELP.md) | Quick reference (FAQ, glossary) — the same knowledge the bot has |
| [principles-vs-skills.md](principles-vs-skills.md) | Why skills are not enough: principles and the generative hierarchy |

**In Pack (via Aisystant MCP `knowledge_search`):**

| Entity | Contents |
|--------|---------|
| `DP.IWE.001` | What IWE is, why it exists, 5 architectural views (systems, descriptions, roles, methods, Work Products), tiers, perimeters |
| `DP.IWE.002` | Template and installation: prerequisites, cost, roles, ORZ, FAQ, security |
| `DP.EXOCORTEX.001` | Modular Exocortex: 3 layers, template-sync, standard/personal |
| `DP.ARCH.002` | Tiers T0–T4 + TM1–TM3 + TA1–TA4 + TD1: what is available at each level |
| `DP.ROLE.001` | Full registry of AI roles (21 roles) |

> **Need help?** Ask the @aist_me_bot — it searches the platform knowledge base (Pack).
> **Technical problem?** Open an issue: [github.com/aisystant/IWE/issues](https://github.com/iwesys/IWE/issues)
