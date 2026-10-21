---
agents: single
browser_safe: false
description: IWE Skill — see file body
gates_enforced: []
gates_rationale: operational skill; WP Gate applicable only when creating a new WP,
  not for operational calls
gates_required: []
interaction: multi-step
layer: L1
name: platform-bottleneck
routing:
  deterministic: false
  executor: sonnet
status: active
triggers:
  phrases: []
  slash:
  - /platform-bottleneck
version: 1.0.0
---

# Skill: /platform-bottleneck

> **Alias.** Delegates to `/bottleneck-pick --layer platform`.
>
> Decision (S-46, 2026-05-21): two skills (intra + platform) merged into one via the `--layer` parameter. A separate skill is redundant. Kept as a convenience trigger.
>
> SC: DP.SC.152. Owner: DP.ROLE.054.

## When to use

IWE Skill — see file body

## Algorithm

### Step 1. Parse arguments

Extract `--horizon`, `--subsystem`, and the optional `--systems-map <path>` from the call arguments. The map path is user data and is not part of the public Template.

### Step 2. Verify the systems map

Before delegating, determine the root of the installed workspace (`WS="${IWE_WORKSPACE:-$PWD}"`) and load its `.iwe-paths`: `. "$WS/.iwe-paths"`. If the file is missing or `IWE_TEMPLATE`/`IWE_WORKSPACE` are empty — report that path setup is incomplete and **stop**. The Script lives in the nested Template, not in `workspace/scripts`: run `bash "$IWE_TEMPLATE/scripts/check-platform-systems-map.sh"`; if `--systems-map` is provided, append `--map "<path>"`. Exit code 2: pass the script's diagnostic output to the user and **stop** — do not build analysis on an incomplete map. A successful call prints the verified path from the workspace; pass exactly that path to the next step as a single argument.

### Step 3. Delegate to /bottleneck-pick

Without `--subsystem`:

```
/bottleneck-pick --target c2:platform --layer platform --systems-map "<verified_path>" [--horizon <h>]
```

With `--subsystem`:

```
/bottleneck-pick --target c2:platform --layer platform --subsystem <s> --systems-map "<verified_path>" [--horizon <h>]
```

### Step 4. Return the result

The result of `/bottleneck-pick` is passed to the pilot without modification.

## Full documentation

→ `/bottleneck-pick` SKILL.md (section `--layer=platform`)
→ DP.SC.152 (platform-specific analysis promise)

<!-- USER-SPACE -->
<!-- /USER-SPACE -->
