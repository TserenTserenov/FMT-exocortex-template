---
name: {{name}}
description: |
  {{description}}
version: {{version}}
status: {{status}}
layer: {{layer}}
agents: {{agents}}
interaction: {{interaction}}
gates_required: {{gates_required}}
gates_enforced: {{gates_enforced}}
gates_rationale: "{{gates_rationale}}"
triggers:
  slash:
{{slash_triggers}}
  phrases:
{{phrase_triggers}}
---

# /{{name}}

> **Scope:** <one-sentence scope>
> **Not in scope:** <what this skill does NOT do>
> **Role:** <content-role that uses this skill>

## When to use

- <trigger situation 1>
- <trigger situation 2>
- <trigger situation 3>

## Preconditions

1. **WP Gate precondition.** The task must be attached to an agreed WP in the weekly plan.
2. <additional gate or precondition>

## Algorithm

<!-- Each step: Input (what must be ready), Action (what the agent does), Output (artifact or state produced).
     For multi-step skills, run /vdv audit on this section before finalizing. -->

### Step 1 — <action>

Input: <what must be ready at this step>
Action: <what the agent does>
Output: <artifact or state produced>

### Step 2 — <action>

Input: <output of step 1 + anything else>
Action: <what the agent does>
Output: <artifact or state produced>

### Step 3 — <action>

Input: <output of step 2 + anything else>
Action: <what the agent does>
Output: <artifact or state produced>

## Bundled resources

- `scripts/` — <what scripts do>
- `assets/` — <what assets contain>

## Anti-patterns

- <anti-pattern 1>
- <anti-pattern 2>
- <anti-pattern 3>

## Verification

<how to verify the skill works; reference verify-skill.sh if applicable>
