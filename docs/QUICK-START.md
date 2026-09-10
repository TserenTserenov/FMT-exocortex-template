# Quick Start: From Zero to Your First Session in 15 Minutes

> **Who this is for:** you already have Git, Node.js, GitHub CLI, and Claude Code CLI installed.
> If anything is missing — complete [Stage 0 in SETUP-GUIDE](SETUP-GUIDE.md) first.
> Not on macOS or not using Claude Code? → **[PORTABILITY.md](PORTABILITY.md)**

---

## 1. Fork and Install (5 min)

> **A terminal** is a program for entering text commands.
> - **macOS:** `Cmd + Space` → type `Terminal` → Enter. Or: Finder → Applications → Utilities → Terminal.
> - **Windows:** install [WSL](https://learn.microsoft.com/en-us/windows/wsl/install) first, then Start → `Ubuntu` → Enter.

The `~/IWE` folder is your workspace. All IWE Repositories live inside it. This is the folder you will open in VS Code.

```bash
mkdir -p ~/IWE && cd ~/IWE
gh repo fork TserenTserenov/FMT-exocortex-template --clone
cd FMT-exocortex-template
bash setup.sh
```

The Script will ask:

- **GitHub username** — your GitHub username. You can see it in the top-right corner of github.com after signing in. For example: `ivan_petrov`
- **Time zone** — enter in the format `Europe/Moscow` (Moscow), `Europe/Minsk` (Minsk), `Asia/Novosibirsk` (Novosibirsk), `Asia/Yekaterinburg` (Yekaterinburg). If you do not know your time zone — ask the AI.

For all other prompts — just press Enter.

If anything is unclear — open another browser tab with claude.ai and ask.

**Verification:**
```bash
ls ~/IWE/CLAUDE.md && echo "OK: CLAUDE.md is in place"
ls ~/IWE/DS-strategy/ && echo "OK: DS-strategy created"
```

---

## 2. Open Claude Code (1 min)

**Primary option — VS Code:**

1. Install [VS Code](https://code.visualstudio.com) if you have not already
2. In VS Code: press `Cmd+Shift+X` (macOS) or `Ctrl+Shift+X` (Windows) → find the **Claude Code** extension by Anthropic → install it
3. `File → Open Folder` → select the `~/IWE` folder
4. Press `Cmd+Shift+P` (macOS) or `Ctrl+Shift+P` (Windows) → type **Claude Code: Open** → Enter

A chat panel with Claude will appear on the right side of the screen — this is your working window.

**Alternative option — terminal:**
```bash
cd ~/IWE
claude
```

---

## 3. First Session (9 min)

**Make sure VS Code is open with the ~/IWE folder:**

1. Launch VS Code
2. `File → Open Folder` → select the `~/IWE` folder (on macOS and Linux the tilde `~` means the home folder; on Windows enter `C:\Users\your-name\IWE`)
3. If the Claude Code panel is not visible — press `Cmd+Shift+P` → **Claude Code: Open** → Enter
4. A chat panel will appear at the bottom or on the right — this is the input field for communicating with Claude

In the chat input field, type:

> **Let's run the first strategy session**

(or explicitly `/strategy-session`, or any of: "let's strategize", "strategy session", "open strategy session")

If Claude asks for permission to read files — click **Allow**. This is expected: it needs to read the settings and notes in the `~/IWE` folder.

Claude will read CLAUDE.md and memory/, then guide you through 4 steps:

1. **Goals** — who do you want to be in a year? What do you want to learn?
2. **Dissatisfactions** — what is blocking you? Where is the gap?
3. **First WeekPlan** — tasks for the week with time budgets
4. **MEMORY.md update** — Work Products will appear in the table

**Result:** populated files in `DS-strategy/`:
- `docs/Strategy.md` — your strategy
- `docs/Dissatisfactions.md` — dissatisfactions
- `current/WeekPlan W{N}...md` — plan for the week

> **Developers T4+:** single entry point — `docs/developer/`. Open it and in 10 minutes you will understand the IWE development Pipeline and complete your first task.

---

## 4. Start Working

Tomorrow morning Claude (acting as Strategist) will prepare the day plan (DayPlan) on its own. Or ask right now:

> **Open the day**

Claude will gather information from all Repositories, the calendar, and notes — and propose a plan.

Every work Session follows the **Opening–Work–Closing** Protocol:

| Phase | What happens | You do |
|-------|-------------|--------|
| **Opening** | Claude checks the plan and identifies the task | Name the task — Claude aligns on the approach |
| **Work** | Claude captures valuable knowledge as you go | Work as usual |
| **Closing** | Result is recorded, plan is updated | Say "close" |

---

## 5. Continue From Your Phone (Remote Control)

A Session on your computer does not have to end when you step away from your desk.

**Connecting:**
1. In the terminal on the computer where Claude Code is already open, run `/remote-control` (or start a Session directly with the flag: `claude --remote-control`).
2. A link and QR code will appear — scan it with the Claude app on your phone or open the link in a browser.
3. If you are logged in to claude.ai with the same account — the app may offer to open the already-running Session automatically, without scanning.

**What this gives you:** your phone becomes a remote view into the same Session — the same Repositories, the same Memory, the same history. It is a mirror, not a separate copy: without the running process on the computer, there is nothing to connect to.

**When to use it:** you step away from the computer in the middle of a task and want to check Progress, confirm a Step, or point Claude in a direction — from your phone, without sitting back down.

**Important constraint:** a Claude Max subscription is required, and the computer must stay on and not go to sleep (including when the laptop lid is closed — otherwise use "always on" power mode).

**A different scenario — working from your phone without your own computer at all** (new device, computer is off, you need only one specific Repository) — this is not Remote Control, but a separate product **claude.ai/code**: works with a regular Pro subscription, but without accumulated Memory and with only one Repository per Session. Details → [BROWSER-CI-TEMPLATE.md](BROWSER-CI-TEMPLATE.md).

---

## What's Next

| When | What to do | How |
|------|-----------|-----|
| **Right away, if needed** | Continue a Session from your phone | [Section 5 above](#5-continue-from-your-phone-remote-control) — Remote Control (requires Claude Max) |
| **After a day** | Connect notes from Telegram | Bot @aist_me_bot, subscribe, send `.note text` |
| **After a week** | Connect WakaTime (time tracking) | Tell Claude: `/setup-wakatime` |
| **Once you are comfortable** | Connect background assistants: Extractor (automatically records knowledge to the base) and Synchronizer (schedule, notifications) | `bash roles/extractor/install.sh` |
| **When you want to go deeper** | Study the IWE Architecture | [LEARNING-PATH.md](LEARNING-PATH.md) |

---

> **Stuck?** Tell Claude: `/help` or check [IWE-HELP.md](IWE-HELP.md).
> **Full installation** from scratch (including Git, Node.js, VS Code): [SETUP-GUIDE.md](SETUP-GUIDE.md).
> **No VS Code, using a browser (claude.ai)?** IWE works that way too — paste the instruction Template from [BROWSER-CI-TEMPLATE.md](BROWSER-CI-TEMPLATE.md).
> **Why do you need IWE?** Ask Claude: "why do I need IWE". It will find the answer via Aisystant MCP (knowledge base search, source `DP.IWE.001`).