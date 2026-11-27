# Quick Start: From Zero to First Session in 15 Minutes

> **Who this is for:** you already have Git, Node.js, GitHub CLI, and Claude Code CLI installed.
> If anything is missing — first complete [Stage 0 from SETUP-GUIDE](SETUP-GUIDE.md).
> Not on macOS, or not using Claude Code? → **[PORTABILITY.md](PORTABILITY.md)**

---

## 1. Fork and Install (5 min)

> **Terminal** is a program for entering text commands.
> - **macOS:** `Cmd + Space` → type `Terminal` → Enter. Or: Finder → Applications → Utilities → Terminal.
> - **Windows:** first install [WSL](https://learn.microsoft.com/en-us/windows/wsl/install), then Start → `Ubuntu` → Enter.

The `~/IWE` folder is your workspace. All IWE repositories will live inside it. This is the folder you will open in VS Code.

```bash
mkdir -p ~/IWE && cd ~/IWE
gh repo fork iwesys/IWE --clone
cd IWE
bash setup.sh
```

The script will ask:

- **GitHub username** — your GitHub handle. You can see it in the top-right corner of github.com after signing in. For example: `ivan_petrov`
- **Time zone** — enter in the format `Europe/London` (London), `America/New_York` (New York), `America/Chicago` (Chicago), `America/Los_Angeles` (Los Angeles). If you are unsure of your zone — ask an AI.

For all other prompts — just press Enter.

If anything is unclear — open another browser window at claude.ai and ask.

**Verification:**
```bash
ls ~/IWE/CLAUDE.md && echo "OK: CLAUDE.md is in place"
ls ~/IWE/DS-strategy/ && echo "OK: DS-strategy created"
```

---

## 2. Open Claude Code (1 min)

**Primary option — VS Code:**

1. Install [VS Code](https://code.visualstudio.com) if you do not have it yet
2. In VS Code: press `Cmd+Shift+X` (macOS) or `Ctrl+Shift+X` (Windows) → find the **Claude Code** extension by Anthropic → install it
3. `File → Open Folder` → select the `~/IWE` folder
4. Press `Cmd+Shift+P` (macOS) or `Ctrl+Shift+P` (Windows) → type **Claude Code: Open** → Enter

A chat panel with Claude will appear on the right side of the screen — this is your main working window.

**Alternative option — terminal:**
```bash
cd ~/IWE
claude
```

---

## 3. First Session (10–30 min)

**Make sure VS Code is open with the ~/IWE folder:**

1. Launch VS Code
2. `File → Open Folder` → select the `~/IWE` folder (on macOS and Linux the tilde `~` means the home folder; on Windows enter `C:\Users\your-name\IWE`)
3. If the Claude Code panel is not visible — press `Cmd+Shift+P` → **Claude Code: Open** → Enter
4. A chat panel will appear at the bottom or on the right — this is the input field for communicating with Claude

In the chat input field, type:

> **Let's run the first strategy session**

(or explicitly `/strategy-session`, or any of: "let's strategize", "strategy session", "open strategy session")

If Claude asks for permission to read files — click **Allow**. This is expected: it needs to read the settings and notes in the `~/IWE` folder.

Claude will read CLAUDE.md and memory/, then guide you through the stages, pausing after each one:

1. **Mapping what you already have** — if you have placed your projects and notes, Claude will display them in groups and ask whether it understood correctly (if there are no records — this stage takes one line)
2. **Goals** — who do you want to be in a year? What do you want to learn?
3. **Dissatisfactions** — what is in the way? Where is the gap?
4. **First WeekPlan** — tasks for the week with time budgets, starting from commitments already made
5. **Updating MEMORY.md** — Work Products will appear in the table
6. **Closing** — session record saved

The more of your own material there is, the longer the first stage takes; if there is a lot, Claude will offer to map it in a separate conversation.

**Result:** filled files in `DS-strategy/`:
- `docs/Strategy.md` — your strategy
- `docs/Dissatisfactions.md` — Dissatisfactions
- `current/WeekPlan W{N}...md` — weekly plan

> **Developers at T4+:** single entry point — `docs/developer/`. Open it, and in 10 minutes you will understand the IWE development pipeline and complete your first task.

---

## 4. Start Working

Tomorrow morning Claude (in the Strategist role) will prepare a DayPlan on its own. Or ask right now:

> **Open the day**

Claude will gather information from all repositories, the calendar, and notes — and propose a plan.

Every work session follows the **ORZ** protocol:

| Stage | What happens | You do |
|-------|-------------|--------|
| **Opening** | Claude checks the plan and identifies the task | You name the task — Claude agrees on the approach |
| **Work** | Claude captures valuable knowledge along the way | You work as usual |
| **Closing** | Result is recorded, plan is updated | You say "close" |

---

## 5. Continue from Your Phone (Remote Control)

A session on your computer does not have to end when you get up from your desk.

**Connection:**
1. In the terminal on the computer where Claude Code is already open, run `/remote-control` (or start a session with the flag directly: `claude --remote-control`).
2. A link and QR code will appear — scan it with the Claude app on your phone or open the link in a browser.
3. If you are signed in to claude.ai with the same account — the app may offer to open the already-running session automatically, without scanning.

**What this gives you:** your phone becomes a remote view of the same session — the same repositories, the same Memory, the same history. It is a mirror, not a separate copy: without a running process on the computer there is nothing to connect to.

**When to use it:** you step away from your computer mid-task and want to check progress, confirm a step, or point Claude in a direction — from your phone, without sitting back down at your desk.

**Important limitation:** a Claude Max subscription is required, and the computer must remain on and must not go to sleep (including when the laptop lid is closed — otherwise use the "always on" power mode).

**A different scenario — working from your phone without your own computer at all** (new device, computer is off, you only need one specific repository) — this is not Remote Control, but a separate product **claude.ai/code**: it works on a standard Pro subscription, but without accumulated Memory and with only one repository per session. Details → [BROWSER-CI-TEMPLATE.md](BROWSER-CI-TEMPLATE.md).

---

## What's Next

| When | What to do | How |
|------|-----------|-----|
| **Right away** | Try a method on your own task | Type `/onboarding` or "where do I start?" to Claude — in one conversation: task analysis using a method from the library and a "before → after" summary |
| **Right away, if needed** | Continue the session from your phone | [Section 5 above](#5-continue-from-your-phone-remote-control) — Remote Control (requires Claude Max) |
| **After a day** | Connect notes from Telegram | Bot @aist_me_bot (requires a MIM account), send `.note text` |
| **After a week** | Connect WakaTime (time tracking) | Tell Claude: `/setup-wakatime` |
| **Once you are comfortable** | Connect background assistants: the Extractor (records knowledge to the base automatically) and the Synchronizer (schedule, notifications) | `bash roles/extractor/install.sh` |
| **When you want to go deeper** | Study the IWE Architecture | [LEARNING-PATH.md](LEARNING-PATH.md) |

---

> **Stuck?** Tell Claude: `/help` or check [IWE-HELP.md](IWE-HELP.md).
> **Full installation** from scratch (including Git, Node.js, VS Code): [SETUP-GUIDE.md](SETUP-GUIDE.md).
> **No VS Code, using the browser (claude.ai)?** IWE works that way too — paste the instructions template from [BROWSER-CI-TEMPLATE.md](BROWSER-CI-TEMPLATE.md).
> **Why do I need IWE?** Ask Claude: "why do I need IWE".

