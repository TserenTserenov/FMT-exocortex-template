# Template: _template (skeleton)

> Copy this file, rename it to `<kind>.md`, fill in the parameters and acceptance.

## Frontmatter for a task file

```yaml
---
id: TASK-YYYY-MM-DD-<slug>
kind: <kind>                         # one of: analyze | scout | evolution | soak | retro | research | publish
status: pending
priority: P2                         # P0=critical, P1=high, P2=medium, P3=low
agent: ccr-opus                      # ccr-opus | ccr-sonnet | remote-systemd | local-launchd
template: <name>                     # filename in templates/ without .md
created: YYYY-MM-DDTHH:MM:SS+03:00
due: YYYY-MM-DDTHH:MM:SS+03:00
wp: NNN                              # optional — link to Work Product
result_location:
  repo: <repo-name>
  branch: main
  path: <path/to/artifact.md>
acceptance:
  - <condition 1>
  - <condition 2>
params:
  <key>: <value>
---
```

## Prompt (passed to the agent)

```
{{header}}

## Task
{{task_description}}

## Context
{{context}}

## Steps
1. {{step1}}
2. {{step2}}
...

## Acceptance
- Save result: `{{result_location.repo}}/{{result_location.branch}}/{{result_location.path}}`
- All items in task.acceptance must be completed.

## Failure modes (NOT silent succeed)
- If `{{step_critical}}` failed → `status: failed`, explain the reason in chat
- If push to `{{result_location.branch}}` failed → `status: failed`, **do not fall back to another branch/PR**
- If acceptance is partially completed → `status: partial`, list what was done / not done
```

## Acceptance template

```yaml
acceptance:
  - "File exists at `{{result_location}}`"
  - "Frontmatter is valid (yq parse passes)"
  - "All task items marked ✓/✗ with justification"
```