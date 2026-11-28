# Live Connection Check for Other Authors' Knowledge Bases

Connecting another author's knowledge base (the `/pack-subscribe` skill) is included in release 0.43 only after a person who is **not** the template author verifies it on their own installation. If that verification does not happen before the release, the skill moves to 0.44.

The check takes about ten minutes. It downloads one open knowledge base (a Pack of rhetorical techniques) into your IWE folder and makes no changes to it.

## What You Need Beforehand

- IWE version 0.43 (release candidate) installed on macOS or Linux.
- VS Code with the Claude Code extension.
- Internet access: the Pack is downloaded from GitHub.

## Step 1. Open the IWE Folder in VS Code

On macOS, press Cmd+Space, type `Visual Studio Code`, and press Enter. On Linux, open VS Code from the application menu.

Look at the Explorer panel on the left: the name of the open folder is shown at the top. If it is not `IWE`, go to the top menu, choose File → Open Folder…, navigate to the `IWE` folder in your home directory, select it, and click Open.

## Step 2. Start a Conversation with the Agent

Click the Claude icon (the orange star) on the VS Code sidebar or at the top right above the open file. The chat panel opens. If a conversation is already in progress, click New Chat (the plus button at the top of the panel).

## Step 3. Browse the Catalog

Type the following into the input field at the bottom of the panel and press Enter:

```text
what packs are available
```

The agent displays a table of available knowledge bases: four rows, including PACK-rhetoric (rhetorical techniques). The agent downloads nothing at this step.

## Step 4. Connect the Rhetoric Pack

Type the following into the same input field and press Enter:

```text
connect pack PACK-rhetoric
```

If the agent asks permission to run a command, click Yes (allow). Within a few seconds the agent reports in a single line that the Pack is connected and how many seconds it took. Write down that number.

## Step 5. Open the Terminal

In the VS Code top menu, choose Terminal → New Terminal. A panel with a blinking cursor opens at the bottom of the window.

## Step 6. Confirm the Pack Is Present

Paste this command into the terminal and press Enter:

```bash
ls "${IWE_WORKSPACE:-$HOME/IWE}/PACK-rhetoric"
```

The terminal shows a list of the Pack's files and folders, including `README.md`. If the output is `No such file or directory`, the connection failed: stop and report it (see the Reporting Results section).

## Step 7. Confirm the Subscription Is Recorded in Your File

Paste this command into the terminal and press Enter:

```bash
grep -n "PACK-rhetoric" "${IWE_WORKSPACE:-$HOME/IWE}/extensions/protocol-open.after.pack-subscriptions.md"
```

The terminal shows a line containing `PACK-rhetoric` and the connection date. This file belongs to you: a template update does not touch it. If the terminal prints nothing, the subscription was not recorded — note this in your report.

## Step 8. Confirm the Pack Cannot Be Modified Accidentally

Paste this command into the terminal and press Enter:

```bash
git -C "${IWE_WORKSPACE:-$HOME/IWE}/PACK-rhetoric" commit --allow-empty -m "check"; echo "exit=$?"
```

The terminal prints a rejection: the Pack is connected as read-only. The last line must be `exit=` followed by a number **other than** zero, for example `exit=1`. If the last line is `exit=0`, the protection did not work — note this in your report.

## Step 9. Find an Answer in the Connected Pack

Return to the agent chat panel, type the following, and press Enter:

```text
find in the connected packs a rhetorical technique that explains a complex idea through comparison, and name the file it came from
```

The agent must respond with a technique from the rhetoric Pack and name the file inside the `PACK-rhetoric` folder.

## Step 10 (Optional). Disconnect the Pack

Type the following into the agent chat and press Enter:

```text
disconnect pack PACK-rhetoric
```

The agent asks for confirmation. Reply yes, and it removes the Pack copy and the subscription line.

## The Check Passes When All of the Following Are True

1. In Step 3, the catalog shows exactly four Packs, including PACK-rhetoric.
2. In Step 4, the connection completed in under one minute.
3. Steps 6 and 7 showed the Pack and the subscription line.
4. In Step 8, the last line is not `exit=0`.
5. In Step 9, the agent named a technique and a file from the `PACK-rhetoric` folder.

## Reporting Results

Add a comment to the pull request for this skill (or to the 0.43 release discussion). Include the IWE version, the operating system (macOS or Linux), the number of seconds from Step 4, the agent's answer from Step 9, and whether the check passed on all five points.
