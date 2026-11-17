# IWE 0.42: What Is New and How to Use It

**Summary.** You can now try IWE on your own task in a single conversation: no account and no MIM subscription required. A trial skill is available that matches a method to your difficulty. Fixed causes that blocked updates and trial runs in Git Bash on Windows. IWE now stops an agent command that searches for files and immediately deletes them. Many fixes in day and session closing, knowledge review, and the English version.

**How to update.** Tell your Claude "update my exocortex" (the assistant's name for your IWE folder) or run `bash update.sh` in the terminal. Most changes take effect immediately after the update. If you need to make changes yourself, see the last section.

### Try IWE in a Single Conversation

**What you can do now.** A new person can try IWE on their own task in a single conversation. The assistant will work through it using a suitable method from the library on your computer and will compile a "before → after" summary from your own words at the end. No account and no MIM subscription are required for this introduction; progress storage and add-on services are separate. References to subscriptions and pricing have been removed from the introduction pages; a "try a method on your own task" step has been added to the quick start.

**How to use.** Open a new conversation with Claude in the IWE folder and type `/onboarding` — or simply ask "where do I start?" and describe what is slowing you down right now.

**Example prompt.** "/onboarding — I keep missing project deadlines and want to understand why."

### Match a Method to Your Difficulty (Trial Version)

**What you can do now.** The `/find-method` skill searches for an approach that fits your situation in the libraries on your computer — in the principles body and in your own knowledge bases. It shows matching methods with a quote from the source and walks you through the steps of the chosen method. Steps are shown verbatim, in the source language (often English); a Russian explanation follows the quote. If no method exists or the source contains only a description without step-by-step instructions, the skill says so. For search it uses only the libraries on your computer and does not access the network or paid tools.

**How to use.** Type `/find-method` and describe your difficulty in your own words.

**Examples.**
- "/find-method do I need research to answer my question, or is what I already know enough" — the skill will suggest a research method and, after selection, show all eight steps.
- "/find-method how to start a sourdough starter for bread" — on the standard libraries the skill will respond that no method is available.

### Update

- **Git Bash on Windows:** fixed the cause that stopped the update after the first file written (not verified on a live Windows machine; see "What Has Not Been Verified").
- **Rollback.** A confirmed rollback (`ROLLBACK`) restores the installation to the previous release and preserves your edits; files delivered only by the newer release that you did not modify are moved to a backup. Without confirmation the update changes nothing.
- The update no longer replaces itself with an older version on an installation that is newer than the release, and stops with a clear message if the server returns a different `update.sh` again immediately after a restart.
- Update from 0.36: the initial basket check connects once instead of twice, and dozens of memory files are no longer labelled "your edit." An installation made with version 0.38.3 or older restores normal edit mode for the agent: it again asks for confirmation before changing files.
- An edit made directly in a memory file inside the template folder is saved to a backup before the file is replaced.
- A minimal installation (`setup.sh --core`) remembers its mode, and the update does not install the background notes processor for it; the update will tell you how to enable it manually.
- If the update could not safely update your `CLAUDE.md`, it no longer reports it as updated — verify it using the update prompt.
- The knowledge-candidate review skill (`apply-captures`) no longer fails at steps 1 and 6, and runs duplicate checks against your own knowledge base.
- You can opt out of automatically adding a new Work Product to the week plan: set `wp_new_add_to_weekplan: false` in the `params.yaml` settings file. The default behaviour is unchanged.

### Installation Check and Trial Run

- **Git Bash on Windows:** fixed the cause that prevented a trial run from starting (not verified on a live Windows machine).
- The installation check (`/audit-installation`) no longer requires you to type the path manually, and shows a GitHub check without a subscription as a pause rather than an error.
- Day closing in the trial run no longer stops during the memory count.
- The memory count is faster on large memory, and files without a date are no longer silently skipped — they are listed in the report.
- The repository freshness check no longer fails on a standard installation.
- The trial run more strictly blocks launching scripts by path and writing through IWE tools and Google Calendar in Kimi Code.
- On macOS, morning and weekly planning no longer launch a second time alongside the general scheduler after an update.

### Security

- **Reduced risk of losing files.** Previously, an agent could find files and immediately delete them in a single command (for example, `find … -delete` or `find … -exec rm`), and IWE did not stop it. Such a command is now stopped before execution, and the agent receives an explanation. Normal file search works as before.
- **What this looks like.** You ask "clean up temporary files in the project folder," the agent tries to find and immediately delete them in a single command — IWE does not execute that command and tells the agent why. The files remain in place.
- The agent can no longer write a file in a single command via `git diff --output`, `find -fprint`, and similar forms, rewrite a branch binding (`git branch -u`), or modify the remote repository list (`git remote add/remove`) without your request.
- If the security rules list cannot be read, the agent receives a refusal with a reason rather than silently working without checks.

### Sessions and Work Products

- **"Push" no longer closes a session:** the agent saves and sends changes, and closes on "close" or "push and close." The word in quotation marks ("I did not write 'close'") is not treated as a command.
- Session closing no longer fails if its changes were already sent earlier.
- Day opening and closing mark only their own checkpoint and do not touch the checkpoint of a parallel session.
- When a Work Product is opened, incoming records are verified against the server, not against a stale local copy.

### Knowledge Review

- Fixed a bug that caused two simultaneous knowledge reviews to interfere with each other.
- If the publication verification file is not present on the installation, the review result is saved locally and a notification asks you to update. After the update, the next run will send the saved result or re-process the notes.

### Telegram Notifications

- All template messages in Telegram are now sent with a single command. On a standard installation they still arrive directly in Telegram.

### Linux and WSL2

- The installation again sets up background roles by itself (for example, morning planning): they select systemd or cron. If no scheduler is available, the installation does not abort but names the command to set up the role later.

### WakaTime

- WakaTime stopped accepting the plugin key for summaries. The script retrieves today's time via a different request; for previous days without a personal token it shows the reason instead of a number.
- **How to restore time for previous days:** obtain a personal token at https://wakatime.com/oauth and set it in the `WAKATIME_OAUTH_TOKEN` environment variable. You can tell your Claude `/setup-wakatime` — the skill will walk you through the steps. Do not send the token itself in the chat.

### English Version

- Template translation to English again reaches publication. Terms are taken from the shared glossary, and the translator lists any new English terms that have not been approved in the report.
- `IWE_LANG=en` enables English messages for session-closing checks and translated day-plan elements; the check also recognises English closing phrases.

### What Has Not Been Verified

The release passed automated checks on Linux and macOS and an independent security review (verdict: approved; no medium or high findings). We have not verified on a live machine:

- **Windows** — no guarantee: Git Bash fixes are included, but no Windows tester was available.
- **Update from 0.36** — passed the automated check and a re-update without changes, but no byte-level file comparison after the re-update.
- **Day opening and closing** — no live run on this build; verified by tests.
- **Protective checks in Kimi Code** — logic verified, but not the launching of hooks by Kimi itself (known limitation #1124); ritual "rehearsals" are reliable only in Claude Code.
- **Nine improvements from the section above** — confirmed by code tests, but not by live conversations.
- **Access modes in Claude Desktop and ChatGPT**, half of the IWE introduction in ChatGPT — not verified.

If any of this breaks for you, please report it — this will help improve 0.42.1.

### What You Need to Change Yourself

- **WakaTime time for previous days** — set a personal token (see the "WakaTime" section).
- **Russian links in the IWE introduction** — add `region: ru` to `params.yaml`; without it aisystant.com links are used.
- **Your own language catalog** (if you created one) — add the keys `recognition.push_only` and `agent.close_gate.push`; otherwise the closing check will not load it.
- **`CLAUDE.md` that the update did not touch** — verify manually using the update prompt.
- **Linux and WSL2, if roles were not installed earlier** — run the role installation command named by the installer.

All release notes are in the template changelog, section 0.42.0.

## How to Roll Back to 0.41.11

An update that restores the installation to an older release calls this a rollback and waits for you to enter `ROLLBACK`. With the `--yes` flag the rollback is never executed. After confirmation:

- the installation matches 0.41.11;
- files that existed only in 0.42 and that you did not modify are moved to `.backups/deprecated/`;
- files you modified remain in place, and the output names them.

## Known Limitations

- **The agent can read your secrets without asking.** Read commands are allowed without confirmation: `cat`, `git show`, and others. The agent can therefore read a file containing keys, such as `.env`, inside the IWE folder. Store keys outside the IWE folder, for example in `~/.secrets/`, and do not ask the agent to display them. This was present in 0.41.11 as well; a fix is being prepared separately.
- **The dangerous-command check sees only the command text.** A path hidden in a variable is not recognised. This is a last line of defense, not a substitute for your own attention to what the agent proposes to run.
- **macOS and Windows.** The build was verified by automated checks on GitHub servers (macOS, Windows, Linux), manually on Linux, and by an independent review on Linux. No manual verification on macOS or Windows was performed on this build: Windows is not guaranteed by the release, and on macOS there may be findings that automated checks did not catch. If anything is found, it will appear here.

