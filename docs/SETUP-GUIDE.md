# IWE Installation: Step-by-Step Guide

> This guide takes you from a clean machine to a working IWE in 30–60 minutes.
> Supported on macOS and Linux. On Windows, some commands work in Git Bash; sessions require WSL2 — see the limitations below.
> Not sure what to change for your platform? → **[PORTABILITY.md](PORTABILITY.md)**
>
> **Source of truth:** `DP.IWE.002` (Pack). If this file conflicts with the Pack, the Pack takes priority.
> Via Aisystant MCP: `knowledge_search("IWE installation template")`.
>
> **Need a shorter version?** → [QUICK-START.md](QUICK-START.md) (15 minutes, assuming Git, Node.js, and the CLI are already installed). This document covers a full installation from scratch.

## Where You Are and Where You Are Going

The platform grants access by tiers (`DP.ARCH.002`): from T0 (no account) to T4 (Creation, IWE). You may already be using the bot — that is T1–T3. This guide moves you to **T4**, where a personal workspace with AI agents becomes available.

| Tier | What it includes | How to get there |
|------|-----------------|-----------------|
| **T1: Start** | Bot @aist_me_bot: knowledge base search, marathons | `/start` in Telegram |
| **T2: Learning** | + Programs, guides, schedule | Subscribe to a program |
| **T3: Personalization** | + Personal answers, digital twin | `/twin` in the bot |
| **T4: Creation (IWE)** | + Claude Code, Strategist, Git, personal knowledge bases | **This guide** |

> Everything you have accumulated at T1–T3 (Digital Twin, profile, progress) is preserved. T4 adds new capabilities; it does not replace the existing ones.

## What You Will Have at the End

- **Claude Code** — an AI assistant that knows your goals, tasks, and methodology. It remembers context between sessions.
- **Strategist** (AI agent) — prepares a daily plan each morning and a weekly summary on Sundays.
- **Extractor** (AI agent, later) — extracts knowledge from sessions into the knowledge base.
- **Synchronizer** (later) — agent scheduling, Telegram notifications.
- **DS-strategy** — your personal strategic hub (a private GitHub repository).
- **Personal guide** — an optional development route assembled from your goals and context.
- **Telegram notes** — write a thought in the bot and it goes into the planning system.

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
| **7** | Agent Workspace (agent data storage) | 10 min | when you have more than 2 agents |

> **Minimum to get started:** Stages 0 → 1 → 2. Everything else can be connected at any time — tell Claude *"set up calendar"* or *"connect video recordings"*.
>
> **Kimi as a second agent:** if you want to work in IWE with Kimi Code as well as Claude, the connection is described in [`docs/KIMI-SETUP.md`](KIMI-SETUP.md).

## How to Open a Terminal

All commands in this guide are run in a **terminal** — a program where you enter text commands.

**macOS:**
- Press `Cmd + Space` (Spotlight) → type `Terminal` → press Enter
- Or: Finder → Applications → Utilities → Terminal

**Windows:**
- Install [Git for Windows](https://git-scm.com/download/win) (default checkboxes are fine)
- Open **Git Bash** — Start → type `Git Bash` → press Enter. For sessions you will need WSL2; details → [§ 0.0 "Windows: Git Bash and WSL2"](#00-windows-git-bash-and-wsl2)

**Linux:**
- `Ctrl + Alt + T` (in most distributions)

> In the terminal you will see a prompt such as `username@computer:~$`. Type a command and press Enter.

## Stage 0: Preparation (15–20 min)

If Git, Node.js, GitHub CLI, and Claude Code CLI are already installed, skip to [Stage 1](#stage-1-iwe-installation-5-min).

> **⚠ Network restrictions (Russia and similar regions).** Some downloads below (GitHub, npm, Homebrew) may not be directly accessible. Standard workarounds: VPN, a system proxy, or `torify <command>` for individual calls — for example `torify curl ...` or `torify git clone ...`. For `npm`/`brew`, `torify` is often not enough; you usually need to configure the package manager's own proxy or registry settings. If a specific step below fails, check whether this is the cause before investigating the error.

### 0.0 Windows: Git Bash and WSL2

Git Bash works for individual preparation commands and some scripts. `session-guard.sh` fails in native Git Bash before a session is opened: its Unix lock `fcntl` is unavailable. To work with sessions, run IWE inside **WSL2**. A full installation and update on Windows has not yet been verified end-to-end.

> **Commits in Git Bash.** If commits are blocked by the `session-open-gate.sh` hook, you can temporarily disable the check with the key `session_open_gate_skip_until: YYYY-MM-DD` in `params.yaml` (no more than 30 days ahead; details in `params.yaml.example` and `docs/PLATFORM-COMPAT.md`). This key is set by a person, not an agent. Because an agent with write access can extend it, review `params.yaml` and `.iwe-runtime/session-open-gate-skip.log` periodically.

1. **Git for Windows** — download from [git-scm.com](https://git-scm.com/download/win) and install (default checkboxes are fine). **Git Bash** for individual preparation commands is included.
2. **Native Git Bash for individual commands:** prepare tools for Windows as described below. For sessions, skip these installers and perform Stages 0 and 1 — including the installation of Node.js, GitHub CLI, Claude Code CLI, and the execution of `setup.sh` — inside a Linux terminal in WSL2.
   - Node.js — installer from [nodejs.org](https://nodejs.org/) (LTS version).
   - GitHub CLI — installer from [cli.github.com](https://cli.github.com/) or `winget install --id GitHub.cli` (can be run from a regular PowerShell; installs system-wide).
   - Claude Code CLI — the same command `npm install -g @anthropic-ai/claude-code` as on macOS/Linux (Git Bash can run `npm` if Node.js is on PATH).
3. **Claude Code automatic hooks** call `.sh` files through the system shell. Having `bash` on `PATH` does not replace WSL2 for hooks that call `session-guard.sh`.
4. **Local automation (Strategist/Extractor without human involvement)** — Windows has no `launchd`/`systemd`; the closest equivalent is Windows Task Scheduler (see the example in the [Automatic Wake section](#automatic-wake-and-sleep-prevention) below). The simpler path without local scheduled tasks is the cloud variant via GitHub Actions (platform-independent; nothing needs to stay powered on).
5. **For sessions, install WSL2** (`wsl --install` in an administrator PowerShell) and perform the installation steps inside a WSL2 Linux terminal. An end-to-end run of this path on Windows has not yet been confirmed.

> **Verification boundary.** CI on `windows-latest` checks the Strategist lock in Git Bash (#1030) and the early failure of `session-guard.sh` without writing to the canon (#1032). Full installation and update via Git Bash, as well as an end-to-end WSL2 path, have not yet been verified.

### 0.1 Homebrew (macOS only)

Homebrew is the package manager for macOS. It is needed to install the remaining tools with a single command. If it is already installed, skip this section.

In the terminal:
```bash
# Check whether Homebrew is installed
brew --version

# Install (if not present)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

After installation Homebrew may ask you to run a command for PATH — copy it and run it.

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

Now authorize with GitHub (one time):
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

**If you cannot sign in through the browser** (`Login with a web browser`) — when prompted to choose a method, select `Paste an authentication token` instead. This option does not open a browser; `gh` waits for a ready token:

1. Open `https://github.com/settings/tokens` in a browser.
2. Create a token: **classic** (`Tokens (classic)` — a separate tab/link; the default page opens to fine-grained tokens), with at least `repo` and `workflow` scopes (required so the forked template can push `.github/workflows`). Classic is simpler for this scenario — it is clear which permissions to grant. Do not restrict the token to specific repositories (`setup.sh` creates new ones).
3. Copy the token and paste it into the terminal when `gh auth login` prompts for it.
4. Verify with the same `gh auth status` command shown above.

### 0.5 Claude Code CLI

Claude Code is an AI agent that runs in the terminal (or in VS Code). It reads files, executes commands, and helps with planning and writing code.

A subscription to Anthropic is required. Starting with **Claude Pro** ($20/month) is recommended. Use **Claude Max** (~$100/month) if you need to work without limits.

In the terminal:
```bash
# Install
npm install -g @anthropic-ai/claude-code

# Check
claude --version
```

On first launch Claude Code will ask you to sign in to your Anthropic account — follow the instructions in the terminal.

### 0.5b Cost Optimization: Choosing a Model

Claude Code lets you choose a model for each task. The right choice preserves your subscription limit:

| Model | Verification class | When to use | Cost |
|-------|--------------------|-------------|------|
| **Opus** | open-loop, problem-framing | Architecture, complex code, strategy, multi-system changes | High |
| **Sonnet** | closed-loop | Standard tasks, single-file edits, writing content | Medium |
| **Haiku** | trivial | Renaming, updating links, formatting, finding a file, cron agents | Low |

To switch models in Claude Code: `/model` → select. For automated tasks (Strategist, Extractor), Haiku is recommended — it saves approximately 80% of the limit compared with Opus.

> **How it works — two scenarios:**
> - **Entire session on a different model:** When a session opens, Claude determines the verification class. If the task is trivial or closed-loop and the current model is excessive, Claude will say: *"I recommend switching to [Haiku/Sonnet] via `/model`. I cannot switch automatically."* The user switches manually.
> - **Individual task within a session:** If a trivial task appears mid-session, Claude delegates it to a sub-agent on a cheaper model. The main session is not interrupted. Delegation only goes downward (Opus→Sonnet/Haiku, Sonnet→Haiku). Switching upward requires `/model`.
>
> **Tip:** On a Claude Pro subscription ($20/month), use Haiku actively for routine work (morning plans, file search, trivial edits). Use Opus only for architectural decisions and complex code.

### 0.6 VS Code (recommended)

VS Code is a code editor with a graphical interface. It makes working with Claude Code convenient: you can see all your repositories, files, the terminal, and the AI assistant in one window, and you can switch between repositories of different projects within a single session. **Without VS Code** you will need to work through the terminal only — this is possible, but less convenient.

- Download and install: [code.visualstudio.com](https://code.visualstudio.com/)
- Open VS Code → press `Cmd+Shift+X` (macOS) or `Ctrl+Shift+X` (Windows/Linux) → find "Claude Code" → click Install

If you use Obsidian, open only the separate governance repository `DS-strategy` as a vault. Using the IWE root (`~/IWE`) as an Obsidian vault is not supported: large technical Markdown files such as `FPF/FPF-Spec.md` can hang the indexer and leave a blank screen. Open the full workspace in VS Code. Do not link technical repositories into the governance vault via symbolic links.

## Stage 1: IWE Installation (~5 min)

### 1.1 Create a Workspace Folder

Create **one folder** on your machine for all repositories — current and future. All repositories will be cloned into it: `IWE/`, `DS-strategy/`, `PACK-{domain}/`, `DS-{projects}/`, and others. `CLAUDE.md` will also live in the root of this folder. The default location is `~/IWE`:

```bash
mkdir -p ~/IWE
cd ~/IWE
```

> **Important:** The name can be anything, but all repositories must be in one place — Claude Code relies on this structure. `~/IWE` is recommended.

### 1.2 Fork the Template and Run Setup

In the terminal:

```bash
# Make sure we are in the workspace folder
cd ~/IWE

# Fork the template to your GitHub account and clone it
gh repo fork iwesys/IWE --clone
cd IWE

# Run setup
bash setup.sh
```

> **Preview without executing:** `bash setup.sh --dry-run`

The script will ask:

| Question | What to enter | Example |
|----------|--------------|---------|
| GitHub username | Your GitHub login | `ivan-petrov` |
| Workspace directory | Workspace folder | Just press Enter (detected automatically) |
| Claude CLI path | Path to claude | Just press Enter (detected automatically) |
| Strategist launch hour (UTC) | Strategist start hour | `4` (= 7:00 MSK, 8:00 Almaty) |
| Timezone description | Time description | `7:00 MSK` |

The script performs 6 steps:
1. Substitutes your data into all files (name, paths, timezone)
2. Installs `CLAUDE.md` — rules for Claude Code
3. Installs `memory/` — working memory for Claude Code
4. Configures permissions (`.claude/settings.local.json`) and outputs MCP connection instructions
5. Sets up automatic Strategist launch (launchd on macOS)
6. Creates `DS-strategy/` — your private strategic repository on GitHub

### 1.2b Fork Visibility and Personal Data

`gh repo fork` creates a **public** fork: GitHub does not allow making a fork of a public repository private. Therefore:

- The `IWE/` directory contains platform files (methodology, scripts, samples). Everything you commit and push from there is visible to anyone.
- Personal data lives **outside** that directory: `memory/` lives in Claude Code memory (`~/.claude/projects/<slug>/memory`; in the workspace folder this is a symlink to it), `extensions/` and `params.yaml` live in the workspace folder, and your strategy and memory backup live in the separate private repository `DS-strategy`.
- The directories named `memory/` and `extensions/` inside the template clone are platform samples, not your data. Do not edit them for personal use and do not push personal context into the fork.

**Need a private template repository?** It cannot be a fork. Make a private duplicate and keep the original as `upstream`:

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

What is known about a private copy (derived from reading the code; a full run on a private copy has not been performed):

| Part | What happens |
|------|-------------|
| `update.sh` | Pulls updates from the hardcoded original address (`UPSTREAM-CONST`), not from your fork or copy, so switching from a fork to a copy does not change the update source. One exception: in the release channel, the rollback check does `git fetch origin <release commit>` in your clone; if the copy does not have that commit, auto-apply with `--yes` stops, but an interactive run works. |
| `scripts/fmt-critical-alert.sh` | A copy has no "parent", so the script checks **its own** issue list, which is empty. A response of "0 (✅ clean)" in this case means "nothing to check", not "no problems". (If the tracker is disabled, the script exits with "cannot check".) Set `IWE_FMT_REPO=iwesys/IWE` (as an environment variable or a line in `.exocortex.env`) to point it at the original's issues. |
| Template directory connection to knowledge search (MCP) | Not verified here. |

### 1.3 Verify the Installation

In the terminal:
```bash
# This must exist
ls ~/IWE/CLAUDE.md

# Memory files must be present (10+)
ls ~/.claude/projects/*/memory/

# Strategic hub must be present
ls ~/IWE/DS-strategy/

# Strategist must be in the schedule (macOS)
launchctl list | grep strategist
```

If everything is present, verify the MCP connection (1.3b) and proceed to Stage 2. Additional roles (1.4) can be installed later.

### 1.3b Connect MCP Servers

MCP (Model Context Protocol) gives Claude Code access to the platform knowledge base and your personal repositories. Through it Claude can see documents, guides, the digital twin, and your own Pack repositories — domain knowledge bases you build over time.

> **Why:** Documentation and Pack entities (DP.IWE.001, DP.ARCH.001, etc.) reference source-of-truth entries in PACK-digital-platform. After connecting MCP, Claude can find these entities on demand and work with your personal repositories directly. Without MCP, entities are only accessible as files on GitHub.

> The instructions below are for Claude Code (via `claude.ai`). For other agents (Hermes, etc.) see `AGENT-VENDOR-SETUP.md`, Step 6.

**Connection:**

1. Open https://claude.ai/settings/connectors
2. Add an MCP server (Aisystant MCP): `https://mcp.aisystant.com/mcp`
3. Restart Claude Code

**How it works:** Claude Code connects to Aisystant MCP through claude.ai connectors. The server aggregates all backends (knowledge, digital-twin) and provides tools (`knowledge_search`, `knowledge_get_document`, `knowledge_feedback`, `dt_read_digital_twin`, and others).

#### Verification

Open Claude Code in the exocortex folder and type `/mcp` — the servers should show a Connected status. Then ask:
> Find documents about principles

Claude should use `knowledge_search("principles")` and return a list of documents from the knowledge base.

**Diagnostics:**

```bash
# Verify the full installation (env, files, extensions, MCP availability)
bash IWE/setup.sh --validate
```

| Problem | Solution |
|---------|---------|
| `/mcp` — no servers | Repeat steps 1–3 (claude.ai connectors) |
| Opened the URL in a browser — "Not found" | This is normal. MCP works over POST (JSON-RPC), not GET. Check via `/mcp` in Claude Code. |
| Aisystant MCP — connection error | Check your internet connection. |
| `--validate` shows errors | Follow the prompts. Missing keys — fill them in in `.exocortex.env`. |

> **Tip:** `setup.sh --validate` checks ALL categories at once: env config, required files, extensions, MCP availability.

### 1.3c Connect Your Repositories to Personal Search (optional)

Step 1.3b gives Claude access to the platform knowledge base. Your own repositories (notes, Packs, work projects) are not included in that search by default — they must be connected separately.

**How to connect:** tell the agent "connect my GitHub". It will call the `github_connect` tool and provide a sign-in link. If the GitHub App `aisystant-knowledge` is not yet installed for you, the page and the agent will then provide a second link for installation. On that GitHub page you select your account and repositories and click Install. The selected repositories connect immediately; no second sign-in or additional configuration is needed. Only what you explicitly select is indexed.

If the app has already been installed on an organization by its administrator, no installation is needed: after signing in the agent will show the organization's repositories and you choose which ones to connect. To add a repository later, go to the installed app settings on GitHub (Settings → Applications → `aisystant-knowledge` → Configure): it will connect within a minute or two.

> **About privacy:** the content of selected repositories (including private ones) leaves your machine and GitHub and is stored on the platform server as a search index — this is required to enable semantic search rather than simple keyword matching. Do not connect a repository if you are not ready for this.

After installation, indexing runs automatically: the initial index is usually fast, but large repositories may take longer. After that, every push re-indexes automatically without involving the local machine.

### 1.4 Install Additional Roles (later)

`setup.sh` installs only the Strategist. The Extractor and Synchronizer are installed separately, once you are comfortable with the basic cycle:

In the terminal:
```bash
cd ~/IWE/IWE

# Extractor — extracts knowledge from sessions, checks the inbox (every 3 hours)
bash roles/extractor/install.sh
# Inbox checking runs without you (headless) — a one-time subscription sign-in is required:
bash roles/extractor/scripts/connect.sh

# Synchronizer — central scheduler: agent scheduling, notifications, code scan
bash roles/synchronizer/install.sh
```

> **Recommendation:** The Extractor and Synchronizer can be installed later, once you are comfortable with the basic cycle with the Strategist. Details: [roles/extractor/README.md](../roles/extractor/README.md) and [roles/synchronizer/README.md](../roles/synchronizer/README.md).

> **Important:** If you install the Synchronizer, it replaces the separate launchd agents for the Strategist with a single scheduler. All roles will be launched on schedule from one point.

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

If IWE is already set up on one device, you do **not** need to initialize memory from scratch on a new one. `day-close.sh --backup` and the `memory-exocortex-sync.sh` hook keep a mirror of memory in `DS-strategy/exocortex/`, and it is pushed to GitHub together with the governance repository. `restore-from-exocortex.sh` restores it.

**Steps on a new device:**

```bash
# 1. Stage 0 (binaries, gh auth, claude CLI) — as usual
# 2. Workspace folder + clone template and governance repo (it carries exocortex/)
mkdir -p ~/IWE && cd ~/IWE
gh repo fork iwesys/IWE --clone
git clone https://github.com/<your-login>/DS-strategy.git

# 3. Restore memory from backup (instead of initializing from scratch)
bash ~/IWE/IWE/scripts/restore-from-exocortex.sh ~/IWE/DS-strategy
#    --dry-run  — preview without changes
#    --force    — overwrite an already populated memory/

# 4. Restart Claude Code → memory is in place
```

The script copies `exocortex/*.md|*.yaml` → auto-memory (`~/.claude/projects/<slug>-IWE/memory/`), `exocortex/CLAUDE.md` → `~/IWE/CLAUDE.md`, and creates a symlink `~/IWE/memory → auto-memory`. It does not touch a non-empty `memory/` without `--force` (protection against accidentally overwriting a working installation).

## Stage 2: First Strategic Session (~30 min)

This is the most important step — you will set up your goals and your first plan.

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

1. **Mapping what you already have** — your projects, notes, and agreements from other Claude chats will be shown in groups and confirmed with you; without existing material this step is short, with a large amount it may take a separate conversation.
2. **Defining goals** — Who do you want to be in a year? What do you want to learn?
3. **Dissatisfactions** — What is in the way? Where is the gap between current and desired state?
4. **First WeekPlan** — Specific tasks for the week with time budgets, starting from already-made commitments.
5. **Registration in WP-REGISTRY.md and WeekPlan** — Work Products from the session will appear in the registry and the plan.

**Result:** completed `DS-strategy/docs/Strategy.md`, `Dissatisfactions.md`, and a first `WeekPlan` in `DS-strategy/current/`.

### Personal Guide (up to 60 min, experimental and optional)

This step is not required for IWE to work. The safe choice is to skip it until you specifically need a public guide. The `/personal-guide-start` command asks no clarifying questions: its first action is to create or reuse an external **public** GitHub repository `DS-personal-guide` (`private: false`). Run it only if you deliberately accept this external effect.

Before running it you need an active "Intelligence Engineering" subscription, GitHub connected in Aisystant MCP, and the `create_repository` and `github_status` operations available. Populating the six files is done by a separate command `/personal-guide-render`, which additionally requires Memory.Derived and the `personal_write` operation. If the server renderer or these operations are unavailable, the bootstrap will not complete: a public repository may already have been created on GitHub without the six files ready. This should not be treated as a completed personal guide.

If the command itself is not visible, check for the presence of `.claude/skills/personal-guide-start/SKILL.md` and restart Claude Code. If the command is visible but server operations are unavailable, do not re-run it blindly — first restore the GitHub/Aisystant MCP connection and the renderer.

## Stage 3: Setting Up Telegram Notes (5 min, optional)

To send thoughts into the planning system directly from Telegram:

1. Find the bot **@aist_me_bot** in Telegram
2. Press `/start`
3. Sign in with your MIM account — notes from the bot are available to MIM members (terms at https://aisystant.com)

**How to send notes:**
- Write: `.My thought about architecture` (a period followed by text)
- Or forward/reply to any message with `.`

The note goes to `DS-strategy/inbox/fleeting-notes.md` and waits there for your decision. Notes are not processed automatically in the evenings. When you are ready, process them in one of three ways: open the "Process notes" section in the Day Plan (a mini-review in Day Opening, where notes awaiting a decision are listed); in a Claude Code session ask "Process notes using the instructions in `roles/strategist/prompts/note-review.md`" (the agent goes through all steps); or run `bash ~/IWE/IWE/roles/strategist/scripts/strategist.sh note-review` in the terminal (this runs without a chat: only marks `✅suggested` and proposals are written). The Strategist will suggest where to put each note: task → plan, knowledge → captures, idea → for discussion. It can only remove a note from the inbox and move it to the archive on your explicit instruction in a live session.

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

> **Privacy:** WakaTime is a SaaS service (wakatime.com, AWS servers, USA). **Metadata** about your work is sent to the server: project names, file names, languages, branches, activity time. File contents are **NOT** sent. The CLI is open source ([github.com/wakatime/wakatime-cli](https://github.com/wakatime/wakatime-cli)). The Desktop App is closed source and requests Accessibility permission (sees active windows). If metadata is sensitive, use the self-hosted alternative [Wakapi](https://github.com/muety/wakapi) (wakatime-cli supports a custom `api_url` in `~/.wakatime.cfg`).

## Stage 5: Google Calendar — Day Events in Day Open (10 min, optional)

Connecting Google Calendar lets you see the day's events directly in the morning plan, create events from Claude Code, and prepare for meetings.

### What You Get

- **Day Open** will show a table of the day's events and free slots for work
- **Creating events** — "schedule a call for Wednesday 11:00" directly from Claude Code
- **Meeting preparation** — Claude will pull context from related Work Products

### Setup (~1 min)

From the template root, run one command:

```bash
bash setup/optional/setup-calendar.sh
```

The script:
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

Calendar data is processed through the Google Calendar API. OAuth tokens are stored locally. Event contents are sent to the Claude API to generate the daily plan. Confidential events (visibility=private) can be excluded from display.

## Stage 6: Video Integration — Linking Recordings to Work Products (5 min, optional)

If you record meetings (Zoom, Telemost, Google Meet), Claude can scan folders with recordings and link videos to Work Products.

### What You Get

- **Day Open** will show new video recordings linked to Work Products
- **Strategy Session** — a weekly review of all unprocessed videos
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
    # Add your video recording folders
```

3. Verify: **"show my video recordings"** — Claude will run `video-scan.sh`

### Where to Find Folders

| Application | Typical path (macOS) |
|-------------|---------------------|
| Zoom | `~/Documents/Zoom` |
| Yandex Telemost | `~/Documents/Telemost` or `~/Video Recordings Telemost` |
| Google Meet | Recordings in Google Drive (not local) |
| OBS | Configured in OBS → Settings → Output |

### Linking to Work Products

The script links videos to Work Products by file name:
- `WP-73-...mp4` → linked to WP-73
- `2026-03-14-...mp4` → linked by date (matched against the calendar)
- Others → manual linking is suggested

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

## Stage 7: Agent Workspace — Separate Storage for Agent Data (10 min, optional)

### Read Before Deciding

This is a **deliberate choice**, not a required step. Two questions will help you decide:

**1. Do you have autonomous agents?**

If you have just started working with IWE and are only using Claude Code in interactive mode — **you do not need this**. All scheduler reports will be stored in `DS-strategy/current/` and `DS-strategy/archive/` — that is sufficient.

**2. Are your agents generating more than 10 files per week?**

When Scheduler, Scout, Extractor, and other agents work daily, they create dozens of files: scheduler reports, bot QA reports, findings, plan drafts. These auto-commits pollute the git history of DS-strategy, which should contain only **human decisions** (plans, confirmed captures).

### What Agent Workspace Provides

| Without Agent Workspace | With Agent Workspace |
|-------------------------|----------------------|
| Everything in DS-strategy | Machine output is separate |
| Mixed git history | Clean decision history |
| 1 repository | 2 repositories |
| Simpler to start | Scales better |

### Setup

```bash
bash setup/optional/setup-agent-workspace.sh
```

The script will create a private GitHub repository `DS-agent-workspace` with a structure for each agent type. After creation, the scheduler scripts (`daily-report.sh` and others) will automatically start writing there — the check is based on the presence of `DS-agent-workspace/.git`.

### When to Connect

**Recommended path:**
1. Start without Agent Workspace (Stages 0–2)
2. Connect Scheduler (launchd) — reports go to DS-strategy
3. When auto-commits exceed 5/day → create Agent Workspace

## Automatic Wake and Sleep Prevention

Agents run on a schedule. If the laptop is asleep, tasks wait for a wake event. Configure automatic wake so the plan is ready before you wake up.

**macOS:**

```bash
# Wake at 3:55 every day (5 minutes before the Strategist)
sudo pmset repeat wakeorpoweron MTWRFSU 03:55:00

# IMPORTANT: if the laptop is on charge, Optimized Battery Charging may
# switch the power profile to "battery". On the battery profile
# the Mac sleeps even with the cable connected. Solution:
sudo pmset -b sleep 0      # do not sleep on battery profile
sudo pmset -b standby 0    # do not enter deep standby

# Check: pmset -g custom (sleep=0 in both profiles)
# Cancel wake: sudo pmset repeat cancel
# Restore sleep: sudo pmset -b sleep 1 && sudo pmset -b standby 1
```

> **How it works:** The Mac wakes at 3:55, the scheduler starts at 4:00, the plan is ready by approximately 4:20. The scripts automatically keep the Mac awake via `caffeinate -diu` (works on the battery profile as well).
>
> **Charge Limit (recommended):** instead of Optimized Battery Charging, enable a fixed limit (System Settings → Battery → Charge Limit → 80%). This protects the battery without unpredictable profile switches.

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
| **Morning (Tue–Sun)** | Strategist | Collects yesterday's commits, generates daily plan | `DS-strategy/current/DayPlan YYYY-MM-DD.md` |
| **Morning (Mon)** | Strategist | Prepares a draft weekly plan + session agenda | `DS-strategy/current/WeekPlan W{N}.md` |
| **Every 3 hours** | Extractor* | Checks inbox (notes, captures) → proposes knowledge for Pack | `DS-strategy/inbox/extraction-reports/` |
| **Night (00:00)** | Synchronizer* | Code scan — review of changes in downstream repositories | `DS-strategy/current/CodeScan YYYY-MM-DD.md` |
| **Night (Sun→Mon)** | Strategist | Week Review — weekly summary | `DS-strategy/current/WeekReport W{N} YYYY-MM-DD.md` |
| **Morning (06:00)** | Synchronizer* | Daily report — summary of overnight tasks | `DS-agent-workspace/scheduler/reports/` (or `DS-strategy/current/` if Agent Workspace is not set up) |

> *The Extractor and Synchronizer only run if installed (Stage 1.4).*

Note processing from Telegram is not in this list: it does not run automatically. You trigger it: via the "Process notes" section in the Day Plan, by asking Claude Code to process notes in a session, or by running the `note-review` command from the terminal (see "Manual Launch" below).

### Manual Launch (when needed)

In the terminal:
```bash
# Daily plan right now
bash ~/IWE/IWE/roles/strategist/scripts/strategist.sh day-plan

# Strategy session (interactive)
bash ~/IWE/IWE/roles/strategist/scripts/strategist.sh strategy-session

# Note review: from the terminal, only marks and proposals are written; archiving and clearing happen only in a Claude Code session, on your explicit instruction
bash ~/IWE/IWE/roles/strategist/scripts/strategist.sh note-review

# Weekly summary
bash ~/IWE/IWE/roles/strategist/scripts/strategist.sh week-review

# Extractor: extract knowledge from the current session (assembled runtime copy, not the raw file in FMT)
bash "$IWE_RUNTIME/roles/extractor/scripts/extractor.sh" session-close

# Extractor: check inbox
bash "$IWE_RUNTIME/roles/extractor/scripts/extractor.sh" inbox-check

# Synchronizer: status of all tasks
bash ~/IWE/IWE/roles/synchronizer/scripts/scheduler.sh status
```

## Daily Work: Three Stages (ORZ)

Each Claude Code session goes through three stages:

### Opening (automatic)
You give a task → Claude checks: is this task in the weekly plan? If not, it proposes adding it (WP Gate). It announces the role, method, and estimate.

### Work
Claude performs the task. At each Work milestone (subtask, pattern, decision) it records knowledge: *"Capture: [what] → [where]"*.

### Closing
Say **"close"** → Claude commits, pushes, updates memory, and makes a backup.

## Updates

The exocortex template is updated — new protocols, improved prompts, skills, scripts, and fixes.

In the terminal:
```bash
cd ~/IWE/IWE
bash update.sh
```

The script downloads the update manifest from GitHub, compares it with your files, shows a preview (what is new, what has changed), and applies it after your confirmation. Self-update: `update.sh` updates itself on every run.

**What is updated (platform-space):**
CLAUDE.md (§1–7), memory/ (protocols, reference materials), role prompts and scripts, hooks, skills, setup scripts. If role scripts have changed, launchd agents are reinstalled automatically.

**What is NOT touched (user-space):**
- CLAUDE.md — 3-way merge: your edits in any section are preserved during updates
- extensions/ — your protocol extensions
- params.yaml — your protocol parameters
- MEMORY.md — your working memory (Work Products, lessons)
- DS-strategy/ — plans, strategy, inbox
- .secrets/, .mcp.json — keys and integration configuration
- .claude/settings.local.json — personal permissions
- personal/ — your files


> To see available updates without applying them: `bash update.sh --check`

## Security and Privacy

> Full data policy: [DATA-POLICY.md](DATA-POLICY.md) | Canonical description: [DP.D.035](https://github.com/TserenTserenov/PACK-digital-platform/blob/main/pack/digital-platform/01-domain-contract/DP.D.035-data-policy.md)

IWE runs primarily locally. Here is what you need to know about security.

### What Stays Local

| Component | Where it is stored | Is it sent anywhere |
|-----------|--------------------|---------------------|
| CLAUDE.md, memory/ | Local files | No (only into Claude's context during work) |
| DS-strategy | Private repo on GitHub | Only to GitHub (private) |
| Launch agents (Strategist etc.) | Local bash scripts | No |
| Git repositories | Local + GitHub | Only to GitHub |

### What Is Sent to External Servers

| Component | Where | What data |
|-----------|-------|-----------|
| **Claude Code** | Anthropic API (USA) | Prompts, contents of files from context. [Privacy Policy](https://www.anthropic.com/privacy) |
| **WakaTime** (optional) | wakatime.com (USA) | Metadata: project names, file names, languages, time. File contents are **NOT** sent. |
| **Aisystant MCP** (knowledge base search) | Platform server (mcp.aisystant.com), OpenRouter (query embedding) | The text of the search query. Contents of your files are not sent unless you connect your own repositories (see §1.3c). |
| **Aisystant MCP** (if you connected your own repositories, §1.3c) | Platform server (mcp.aisystant.com), OpenRouter (content embedding) | Contents of connected repositories, including private ones — sent to the server to build a personal search index. |
| **GitHub** | github.com (USA) | Repository contents |

### macOS Security Recommendations

Before starting, verify:

1. **Firewall** — must be enabled: `System Settings → Network → Firewall`
2. **FileVault** — disk encryption: `System Settings → Privacy & Security → FileVault`
3. **SIP** (System Integrity Protection) — do not disable: `csrutil status` in Terminal
4. **.gitignore** — in every repository with code, it must exclude `.env`, `*.key`, `*.pem`, `credentials.json`
5. **Secrets** — store API keys in `.env` (gitignored) or in a password manager, **never** in code

### What Is NOT Recommended to Install

- Browsers from jurisdictions with mandatory data access (check the Privacy Policy)
- Closed-source extensions with broad access to the file system
- Electron applications with unclear telemetry — check with `Little Snitch` or `LuLu` (open-source firewall)

### Self-Hosted Alternatives

If you work with sensitive data, consider:

| SaaS | Self-hosted alternative |
|------|------------------------|
| WakaTime | [Wakapi](https://github.com/muety/wakapi) — a full equivalent on your own server |
| GitHub | [Gitea](https://gitea.io/) or [GitLab Self-Managed](https://about.gitlab.com/install/) |

## Frequently Asked Questions

**Is an Anthropic subscription required?**
Yes, Claude Code requires an Anthropic subscription. Starting with **Claude Pro** ($20/month) is recommended. Use **Claude Max** (~$100/month) if needed.

**Will Qwen, Perplexity, ChatGPT (chat), or other chat bots work?**
No. Chat bots and search assistants (Qwen chat, Perplexity, routerai.ru, regular ChatGPT) **are not suitable** — they cannot read or write files on your machine or run terminal commands. The exocortex requires an **agentic AI assistant** — one that works with the file system, runs commands, and maintains context between sessions.

**What are the alternatives to Claude Code?**

| Alternative | What it is | Price | Models |
|-------------|-----------|-------|--------|
| **Cursor** | AI-powered IDE (replaces VS Code) | from $20/month | Claude, GPT, own |
| **GitHub Copilot** (Agent mode) | VS Code extension | from $10/month | Claude, GPT |
| **Cline / Roo Code** | VS Code extension (open source) | Free + API key | Any (Claude, GPT, Gemini) |
| **Aider** | CLI tool (open source) | Free + API key | Any |

> **Important note on the model:** The exocortex requires complex agentic behavior from the model — following multi-step protocols, working with 5–10 files simultaneously, reliable editing. Recommended models: **Claude Opus/Sonnet**, **GPT-4o/o1**, **Gemini 2.5 Pro**. Weaker models (Qwen, Llama, Mistral) may lose context and skip protocol steps — they are suitable for ordinary coding but are unreliable for managing the exocortex.

**Does it work on Windows?**
Partially: individual commands work in Git Bash (from [Git for Windows](https://git-scm.com/download/win)), but `session-guard.sh` and sessions require WSL2. Details → [§ 0.0 "Windows: Git Bash and WSL2"](#00-windows-git-bash-and-wsl2). The full installation and update path on Windows has not yet been verified.

**Is the Strategist required?**
No. The Strategist is automation (morning plans, reviews). Without it, Claude Code + CLAUDE.md + memory/ work fully. You plan manually.

**What is a Pack?**
A Pack is a domain knowledge base. It is created later, once you have accumulated enough captures. The first step is working with `captures.md` through the Extractor.

**How do I verify MCP?**
Type `/mcp` in Claude Code — servers should show Connected. Ask: "Find documents about principles". Not working? Run `bash IWE/setup.sh --validate` — it will show what exactly is broken. Details — see step 1.3b.

**Are my data safe?**
DS-strategy is a private repository. MEMORY.md is a local file. Nothing is published without your knowledge. For details about what is sent to external servers (Claude API, WakaTime, GitHub) — see the [Security and Privacy](#security-and-privacy) section.

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

**In the Pack (via Aisystant MCP `knowledge_search`):**

| Entity | Contents |
|--------|---------|
| `DP.IWE.001` | What IWE is, why it exists, 5 architectural views (systems, descriptions, roles, methods, Work Products), tiers, perimeters |
| `DP.IWE.002` | Template and installation: prerequisites, cost, roles, ORZ, FAQ, security |
| `DP.EXOCORTEX.001` | Modular Exocortex: 3 layers, template-sync, standard/personal |
| `DP.ARCH.002` | Tiers T0–T4 + TM1–TM3 + TA1–TA4 + TD1: what is available at each level |
| `DP.ROLE.001` | Full registry of AI roles (21 roles) |

> **Need help?** Ask the bot @aist_me_bot — it searches the platform knowledge base (Pack).
> **Technical issue?** Open an issue: [github.com/aisystant/IWE/issues](https://github.com/iwesys/IWE/issues)

