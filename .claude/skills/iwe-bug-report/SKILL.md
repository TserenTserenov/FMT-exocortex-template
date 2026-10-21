---
agents: none
argument-hint: '[problem description]'
browser_safe: false
description: Report a bug or platform issue in IWE. Creates a GitHub issue in IWE.
gates_enforced: []
gates_rationale: operational skill; WP Gate applicable only when creating a new WP,
  not for operational calls
gates_required: []
interaction: one-shot
layer: L1
name: iwe-bug-report
routing:
  deterministic: false
  executor: agent
  model: sonnet
status: active
triggers:
  phrases: []
  slash:
  - /iwe-bug-report
version: 1.0.0
---

# IWE Platform Bug Report

Issue: $ARGUMENTS

## When to use

Report a bug or platform issue in IWE. Creates a GitHub issue in IWE.

## Algorithm

## Step 0. Check for a help request (issue #274)

If `$ARGUMENTS` is empty, missing, or equals `--help`/`-h`/`help` — do NOT create an issue. Instead, output:

> "`/iwe-bug-report [issue description]` — reports an IWE platform bug and creates a GitHub issue in IWE. Describe what happened and what was expected, for example: `/iwe-bug-report day-close does not archive DayPlan`."

Stop execution.

## Step 1. Categorization

Determine the category based on the content of $ARGUMENTS:

| Label | When |
|-------|-------|
| `bug` | A Skill / Protocol / Script does not behave as intended |
| `documentation` | An inaccuracy or gap in documentation / memory / SKILL.md |
| `enhancement` | Improvement to existing behavior (not new functionality) |
| `question` | Behavior is unclear; clarification is needed |

## Step 2. Collect details

Extract from $ARGUMENTS and the Session context:
- **What happened:** the specific observable behavior
- **What was expected:** the correct behavior per the Protocol
- **Steps to reproduce:** command / Skill / trigger (if applicable)
- **Location:** path to the Skill / Protocol / Script or file name

If any element is not specified, omit the corresponding section from the issue (do not leave empty headings).

## Step 3. Get the IWE version

Run:
```bash
git -C "${IWE_WORKSPACE:-$HOME/IWE}/IWE" log -1 --format="%h %ad" --date=short 2>/dev/null || echo "unknown"
```

## Step 4. Verify the gh CLI

Run:
```bash
gh auth status 2>&1 | head -3
```

If `gh` is not authorized or not installed, output:
> "`gh` CLI not found or not authorized. Install it (macOS: `brew install gh`; Linux: `apt install gh` or https://cli.github.com/), then run `gh auth login`. Issue not created."
> Stop execution.

## Step 5. Create the issue

Assemble the variables:
- `TITLE`: up to 80 characters, format `[TYPE] Brief description`
- `CATEGORY`: label from Step 1
- `DATE`: today's date (YYYY-MM-DD)
- `IWE_VERSION`: from Step 3

The labels in `iwesys/IWE` are a copy of an external Repository and may diverge from the table in Step 1 (issue #457: `docs` was renamed to `documentation`; in that case `gh issue create --label` fails and the issue is not created at all).
Verify the label before use:
```bash
gh label list --repo iwesys/IWE --json name -q '.[].name' | grep -qx "CATEGORY"
```
Label found → use `--label "CATEGORY"` below as normal. Label not found → create the issue WITHOUT the `--label` flag (do not block creation due to label mismatch) and append the following line to the end of `## Context`: `- Label not created: "CATEGORY" not found in the Repository (check the current list via gh label list)`.

Run (substituting real values):
```bash
gh issue create \
  --repo iwesys/IWE \
  --title "TITLE" \
  --label "CATEGORY" \
  --body "$(cat <<'BODY'
## What happened

[description]

## What was expected

[expected behavior]

## Steps to reproduce

[steps or "not applicable"]

## Context

- File / Skill: [path or name]
- Date: DATE
- IWE commit: IWE_VERSION
BODY
)"
```

## Step 6. Report

Output a single line:
> *"Issue created: [URL]"*

If `gh` returned an error, output the full error text.

<!-- USER-SPACE -->
<!-- /USER-SPACE -->
