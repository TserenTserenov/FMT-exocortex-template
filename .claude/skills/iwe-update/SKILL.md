---
argument-hint: ''
browser_safe: false
description: Update IWE with change explanations. Agent calls update.sh, parses CHANGELOG,
  explains what changed, helps adapt updates to user customizations.
name: iwe-update
routing:
  deterministic: false
  executor: haiku
user_invocable: true
version: 1.0.0
---

# IWE Update (updater agent)

> **Role:** R6 Coder. **Single output:** updated IWE + explanation of what changed.
> **Trigger:** "update IWE", "run update", `/iwe-update`, or the agent proposes after detecting a new version.

## Algorithm

### 0. Extensions `before`

```bash
bash .claude/scripts/load-extensions.sh iwe-update before
```

Exit code `0` → read each path from the output in alphabetical order and execute instructions before the preview. Exit code `1` → no extensions, continue. Any other code or a required extension step failure → do not start the update; show the actual error cause.

### 1. Preview (--check)

Run update.sh in preview mode:

```bash
(cd "$IWE_TEMPLATE" && bash update.sh --check 2>&1)
```

Extract from the output:
- Upstream version (current vs. new)
- List of new files
- List of updated files
- Number of changed lines

If "Everything is up to date" → notify the user and exit.

### 2. CHANGELOG — what changed

`CHANGELOG.md` is no longer delivered locally (WP-401 Phase 6.1) — read via raw URL:

```bash
curl -fsSL "https://raw.githubusercontent.com/iwesys/IWE/main/CHANGELOG.md"
```

Find entries between the current and new version.

**Explain to the user in plain language:**
- What was added and why (not a list of files, but **the benefit**)
- What changed in behavior (could anything break)
- What was fixed (bugs that may have affected the user)

**Explanation format:**

```
## IWE Update: v{old} → v{new}

**What's new:**
- [1–3 items in user language, not developer language]

**What changed:**
- [behavior the user may notice]

**Fixes:**
- [if any]
```

### 3. Compatibility analysis

Before applying — check user customizations:

**3a. Extensions:**
```bash
ls extensions/*.md 2>/dev/null
```
If extension files exist → check whether new extension points conflict with existing files.

**3b. params.yaml:**
Read `params.yaml`. If the update adds new parameters → notify the user:
> "A new parameter `X` appeared (default: Y). Do you want to change it?"

**3c. CLAUDE.md:**
Check whether `.claude.md.base` exists:
- Exists → 3-way merge will run automatically.
- Does not exist → warn: "First update after migration. CLAUDE.md will be updated with the USER-SPACE section preserved. Review the result."

### 4. Applying the update

If the user approved (or `--yes`):

```bash
(cd "$IWE_TEMPLATE" && bash update.sh --yes 2>&1)
```

Extract from the output:
- How many files were updated
- Whether 3-way merge conflicts occurred
- Whether variable substitution succeeded
- Whether platform-space was updated
- Memory files: lines `NOT updated` / `NOT delivered` and the summary `Memory files not updated: N (…)` — update.sh left these files as-is (they contain edits, their integrity cannot be verified, or the backup failed); line `Memory files replaced: N (…)` — replaced files, with prior versions in the named directory.

### 5. Post-update

**5a. 3-way merge conflicts:**
If CLAUDE.md contains `<<<<<<<` markers → help resolve them:
- Show each conflict.
- Explain: "The platform changed X, and you changed Y. Which one do you want to keep?"
- Apply the user's choice.

**5b. New parameters:**
If the update introduced new parameters in the template's params.yaml → offer to add them to the user's params.yaml.

**5c. New extension points:**
If the update introduced new extension points in protocols → notify:
> "New extension points appeared: [list]. You can create extensions/X.md files to customize them."

**5d. Recommendations:**
Based on the user's customizations (their extensions/, params.yaml, Pack) — suggest how to use the new capabilities.

**5e. Extensions `checks`:**

```bash
bash .claude/scripts/load-extensions.sh iwe-update checks
```

Exit code `0` → read and execute each file before the final report. Exit code `1` → no checks. Any other code or a check failure does not roll back already-applied files, but prevents declaring the update fully successful: show "update applied, user check failed", the exact cause, the path of the failed extension, and the list of already-executed `checks` files. Remediation: fix or temporarily disable that specific extension, reload `iwe-update checks`, and re-run all checks. Until they pass, the state is called `applied_with_failed_extension_check`, not a successful update.

### 6. Report

```
## Update complete

**Version:** v{old} → v{new}
**Files updated:** N
**Conflicts:** 0 / N (resolved)
**New capabilities:** [brief list]
**Memory files not updated:** N — [list from the "Memory files not updated" summary; for each — the reason from its "NOT updated …" line]
**Memory files replaced:** N (prior versions: [directory from summary])

Restart Claude Code to apply updates from memory/.
```

Memory files left as-is will not update themselves. For each one, show the user a diff command (`diff …`) and the "accept template version …" command from its line. Execute the accept command only after the user confirms there are no local edits in the file — it replaces the file with the template version, leaving the prior copy alongside it. If a line reports a backup or copy failure — resolve the cause (permissions, disk space) first and re-run update.sh.

### 7. Extensions `after`

```bash
bash .claude/scripts/load-extensions.sh iwe-update after
```

Exit code `0` → read and execute files after the report. Exit code `1` → no extensions. An `after` error does not revert the already-applied update, but must be shown as a separate warning with the extension name and cause.

---

## Automatic update proposal

During Day Open (Step 5: overnight IWE check) — if `update.sh --check` shows available updates → add to "Requires attention":
> "IWE update v{new} is available. Run `/iwe-update` to update."
