# session-record — automatic capture of a strategic session record
# Extension: protocol-close / after
# see DP.SC.153 (conditional auto-step, non-blocking for Close)

## Auto-trigger condition

Execute ONLY when all of the following are true simultaneously:
1. Session duration **>15 min** (estimate by number of exchanges / visible work)
2. Session contains **strategic work markers** — at least one of:
   - a file in `sessions/` was mentioned or created
   - a Strategy Session was discussed
   - Work Products of type "strategy" / "planning" were addressed

If the condition is **NOT** met → **noop**, skip silently (do not announce).

## What to do when the condition is met

1. Determine the session topic from the primary Work Product or the dominant discussion theme (≤5 words, kebab-case)
2. Create the file `sessions/YYYY-MM-DD-<topic>.md` in the governance repo (DS-strategy or equivalent)
3. Fill in the structure:

```markdown
---
date: YYYY-MM-DD
session_type: strategy | work | review | planning
wp: WP-NNN  # primary Work Product (if single), otherwise remove
duration_estimate: Xh
---

# Strategy Session YYYY-MM-DD — <topic>

## Context

[Where we came from: which Work Products, which stage]

## Accomplished

[What was done / decided / created — concrete Artifacts]

## Key decisions

[If architectural or strategic decisions were made — 1-3 lines each]

## Next step

[Specific: what, where, who]
```

4. Announce: `Session-record: sessions/YYYY-MM-DD-<topic>.md`
5. Include the file in git add + commit of the current repo (if the repo is governance)
