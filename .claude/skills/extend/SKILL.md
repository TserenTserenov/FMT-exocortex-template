---
argument-hint: '[protocol name or empty for full catalog]'
browser_safe: false
description: 'IWE extensibility catalog: what can be customized, which extension points
  exist, which parameters are available, how to install a third-party extension.'
name: extend
routing:
  deterministic: false
  executor: sonnet
user_invocable: true
version: 1.0.0
---

# /extend — IWE Extensibility Catalog

> **Trigger:** `/extend`, "what can I extend?", "how to configure a protocol", "how to add a custom step".
> **Role:** R6 Encoder. **Single output:** a map of what is available + specific instructions.

## Algorithm

### 1. Identify the request scope

If an argument is provided (e.g. `/extend day-open`) → show only that protocol.
If no argument is provided → show the full catalog.

### 2. Show the current customization state

```bash
ls {{WORKSPACE_DIR}}/extensions/*.md 2>/dev/null || echo "(no extensions)"
cat {{WORKSPACE_DIR}}/params.yaml 2>/dev/null
```

Report:
- Which extensions are already installed (✅)
- Which parameters have already been changed from defaults

### 3. Output the catalog

#### Extension points (files in extensions/)

| Protocol | Hook | File to create | When it runs |
|----------|------|----------------|--------------|
| `protocol-close` | `checks` | `extensions/protocol-close.checks.md` | **BEFORE** commit+push — pre-commit gate (R4.3, WP-273) |
| `protocol-close` | `after` | `extensions/protocol-close.after.md` | After the checklist, before Verification |
| `day-open` | `before` | `extensions/day-open.before.md` | Before step 1 — morning rituals |
| `day-open` | `after` | `extensions/day-open.after.md` | After "Requires attention", before DayPlan |
| `day-close` | `checks` | `extensions/day-close.checks.md` | After governance batch, before archiving |
| `day-close` | `after` | `extensions/day-close.after.md` | After day summary, before Verification |
| `week-close` | `before` | `extensions/week-close.before.md` | Before lesson rotation |
| `week-close` | `after` | `extensions/week-close.after.md` | After memory Audit |
| `protocol-open` | `after` | `extensions/protocol-open.after.md` | After the alignment ritual |
| `protocol-open` | `sync` | `extensions/protocol-open.sync.md` | Overrides sync behavior at step 3b |
| `day-open` | `checks` | `extensions/day-open.checks.md` | Before commit, after DayPlan preparation |
| `day-close` | `before` | `extensions/day-close.before.md` | Before the first day-close steps |
| `month-close` | `before` | `extensions/month-close.before.md` | Before the first month-close steps |
| `month-close` | `after` | `extensions/month-close.after.md` | After month summary, before Verification |
| `strategy-session` | `before` | `extensions/strategy-session.before.md` | Before the strategy session starts |
| `strategy-session` | `after` | `extensions/strategy-session.after.md` | After strategy session summary |
| `iwe-update` | `before` | `extensions/iwe-update.before.md` | Before preview and application of the update |
| `iwe-update` | `checks` | `extensions/iwe-update.checks.md` | After application, before the successful final report |
| `iwe-update` | `after` | `extensions/iwe-update.after.md` | After the update final report |
| `verify` | `before` | `extensions/verify.before.md` | Before type selection and check execution |
| `verify` | `checks` | `extensions/verify.checks.md` | After the main check, before the final verdict |
| `verify` | `after` | `extensions/verify.after.md` | After the final verdict is shown |
| `archgate` | `before` | `extensions/archgate.before.md` | Before principles and the start of the architectural Assessment; blocks start on error |
| `archgate` | `checks` | `extensions/archgate.checks.md` | After DRR, before the single verdict publication; blocks publication on error |
| `archgate` | `after` | `extensions/archgate.after.md` | After publication; warns on errors and never changes the verdict |

For `archgate.before` and `archgate.checks`, the last instruction must produce
`ARCHGATE_EXTENSION: PASS` or `ARCHGATE_EXTENSION: BLOCK — <reason>`.
`BLOCK` is a normal content-level block. A loader or execution error is a separate
failure. In `archgate.after`, `ARCHGATE_EXTENSION: WARN — <reason>` is allowed;
the result of this Phase does not change the already-published verdict.
An extension must not re-invoke the archgate lifecycle via
`load-extensions.sh archgate ...`: the loader returns `BLOCK` for `before/checks`
and `WARN` for `after`. If a corrupted or recursive file is present among `archgate.after`
files, all other valid files still execute.

**Multiple files for the same Hook** — loaded in alphabetical order.
Example: `day-close.after.md` + `day-close.after.health.md` — both will execute.

A file without a Hook name, such as `extensions/verify.md`, is not an extension
point. Use one of the explicitly listed variants: `before`, `checks`, or `after`.

#### Parameters (params.yaml)

| Parameter | Protocol | Default | Description |
|-----------|----------|---------|-------------|
| `video_check` | Day Open | `true` | Check video from the previous day |
| `multiplier_enabled` | Day Close | `true` | Calculate the IWE multiplier (requires WakaTime) |
| `reflection_enabled` | Day Close | `false` | Day reflection via `day-close.after.md` |
| `lesson_rotation` | Week Close | `true` | Lesson rotation in MEMORY.md |
| `auto_verify_code` | Quick Close | `true` | Auto-verify code via sub-agent Haiku |
| `verify_quick_close` | Quick Close | `true` | Verify checklist via sub-agent Haiku |
| `telegram_notifications` | All roles | `true` | Telegram notifications |
| `extensions_dir` | All protocols | `extensions` | Extensions directory |

#### Day Open (memory/day-rhythm-config.yaml)

| Parameter | Description |
|-----------|-------------|
| `budget_spread.enabled` | Distribute the Work Product budget across days |
| `budget_spread.threshold_h` | Minimum budget for calculation (default: 4h) |
| `budget_spread.rounding` | daily_slot rounding step (default: 0.5h) |
| `strategy_day` | Strategy day (session-prep instead of day-plan) |

#### Custom Skills (.claude/skills/)

Create `.claude/skills/<name>/SKILL.md` — the Skill will be available as `/<name>`.
Frontmatter: `name`, `description`, `user_invocable: true`.
`update.sh` does not touch user-defined Skills (they are not in the Manifest).

**Preservation.** There is no built-in preservation mechanism for custom Skills: the `.claude/skills/<name>/` directory is typically not under git (the workspace root is not a Repository), the Day Close (`day-close.sh`, "Backup" step) copies Memory, instructions, and agent rules — but not Skills. `update.sh` does not delete a Skill, but does not migrate it either, and `/iwe-restore` will not restore it. Until the template owner defines a Backup model, keep a copy of your Skills in a git Repository under your own control (for example, in a private `{{GOVERNANCE_REPO}}`) — otherwise moving to a new machine or reinstalling IWE will silently lose them.

### 4. Suggest the next step

Based on what is already configured, suggest what to add next.

**No extensions at all:**
> "A good starting point is day reflection. Create `extensions/day-close.after.md` with 3 questions?"

**Extensions exist, no morning ritual:**
> "Next step — `extensions/day-open.before.md` for morning preparation."

### 5. Create an extension (if requested)

If the user says "create" or "add" after viewing the catalog:
1. Clarify the content (or offer a Template)
2. Create the file in `extensions/`
3. Remind: the extension activates on the **next** protocol invocation

---

## Sharing — Installing Someone Else's Extension

IWE extensions are plain Markdown files. To install:

```bash
cp ~/Downloads/day-close.after.health.md ${IWE_WORKSPACE:-$HOME/IWE}/extensions/
```

**Name conflict** (two files for the same Hook):
Rename with a suffix: `day-close.after.md` + `day-close.after.health.md`.
Both load in alphabetical order — no conflict.

**Extension bundle format:**
```
my-extension-pack/
  README.md                  # description, author, version
  extensions/
    day-close.after.md        # extension files
  params-defaults.yaml        # recommended parameters (not applied automatically)
```

Installing a bundle:
```bash
cp my-extension-pack/extensions/* ${IWE_WORKSPACE:-$HOME/IWE}/extensions/
# Review params-defaults.yaml and manually add the needed parameters to ${IWE_WORKSPACE:-$HOME/IWE}/params.yaml
```
