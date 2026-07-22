---
name: skill-creator
description: |
  Create a new IWE skill with proper frontmatter, gates, scaffold and verification.
  Use when the pilot says: /skill-creator or «создай скилл <name>».
  The skill enforces WP Gate precondition, Routing Gate, IntegrationGate hard-check,
  collects parameters in 4 short steps, generates a scaffold SKILL.md from a template,
  shows a draft, writes files, and reminds about verify-skill.sh.
version: 0.3.2
status: experimental
layer: L1
agents: single
interaction: multi-step
gates_required: [wp]
gates_enforced: [integration, routing]
gates_rationale: "wp — создание скилла = нетривиальный артефакт (>15 мин), требует согласованного РП до начала (WP Gate precondition). integration — новый скилл-обёртка над инструментом/ролью требует существующих DP.SC.* + DP.ROLE.* до реализации (IntegrationGate hard-block). routing — размещение (Claude/Kimi, project/user, L1-L3) есть решение Routing Gate до scaffold."
triggers:
  slash:
    - /skill-creator
  phrases:
    - "создай скилл <name>"
    - "новый скилл <name>"
---

# /skill-creator — create an IWE skill

> **Scope:** create a new skill OR guide an update to an existing skill in `.agents/skills/` or `.kimi/skills/`.
> **Not in scope:** full re-scaffold without deleting the old `SKILL.md` first (delete manually, then call `/skill-creator` again); creating a WP; creating a Pack.
> **Role:** ad-hoc content-role «Инженер скиллов»; formalize in Pack if ≥3 skills/year.

## When to use

- Pilot wants a new skill for a repeated workflow.
- A new tool/agent/system needs a Service Clause + Role + SKILL.md.
- A skill needs promotion from author repo to `FMT-exocortex-template`.

## Preconditions (checked, not performed)

1. **WP Gate precondition.** The task must be attached to an agreed WP in the weekly plan or explicitly named by the pilot. `/skill-creator` does not conduct the WP Gate ritual itself.
2. **Routing Gate.** Decide target platform (Claude vs Kimi) and level (project vs user). Default: project-level `.agents/skills/` in the author repo.
3. **IntegrationGate hard-check.** `DP.SC.*` and `DP.ROLE.*` must exist in the PACK repo. If not, the skill stops and offers to create them. Bypass only by explicit pilot instruction «пропусти gate» — no code flag.

## Algorithm

### Step 1 — Check WP Gate precondition

Look up the current weekly plan (`current/WeekPlan W{N}.md`) or ask:

```
К какому РП привязано создание скилла?
```

If no WP is named and none matches the skill topic → stop:

```
Создание скилла требует согласованного РП. Сначала откройте РП через WP Gate.
```

### Step 2 — Routing Gate

Ask or infer:

| Question | Default |
|----------|---------|
| Claude или Kimi? | Claude |
| project-level или user-level? | project-level |
| governance-репо для учёта? | `${IWE_GOVERNANCE_REPO:-DS-strategy}` |

Target path:
- Claude project: `.agents/skills/<name>/`
- Kimi project: `.kimi/skills/<name>/`
- User level: `~/.agents/skills/<name>/` or `~/.kimi/skills/<name>/`

### Step 2.5 — Detect existing skill

Check whether `<target_path>/SKILL.md` already exists.

**If it exists** → switch to update mode. Do NOT re-scaffold. Show the pilot:

```
Скилл <name> уже существует (версия X.Y.Z).
Что обновить?
  [ ] description
  [ ] slash / phrase triggers
  [ ] version bump (current: X.Y.Z → new: ?)
  [ ] algorithm step (add / edit)
  [ ] bundled resource (add scripts/ references/ assets/)
  [ ] полный пересоздать → удалите SKILL.md вручную, затем запустите /skill-creator снова
  [ ] отмена → ничего не менять
```

Collect the pilot's choices. Apply changes directly to the existing `SKILL.md` via Edit.

Skip Steps 3–6 **unless** the pilot selected "bundled resource" or any change that expands the skill's scope or gates — in that case, run **Step 3 (IntegrationGate)** before applying.

For Step 7 (register + verify): run `verify-skill.sh` always. Run `generate-skills-catalog.sh` only if frontmatter changed (name, description, triggers, version).

Version bump rule: bump patch for trigger / description edits; bump minor for algorithm changes **or adding a bundled resource**; bump major for gate or scope changes.

**If it does not exist** → continue to Step 3 (normal creation flow).

### Step 3 — IntegrationGate

Check PACK repo for files matching `DP.SC.*` and `DP.ROLE.*`. If missing:

```
Service Clause (DP.SC.*) и Role (DP.ROLE.*) не найдены.
Создайте их сейчас через /pack-new или соответствующий процесс.
Для продолжения без них скажите явно: «пропусти gate».
```

Stop until the gate is satisfied or explicitly bypassed by pilot words.

### Step 4 — Collect parameters (4 short steps)

**4a. Name and description**

```
Имя скилла (hyphen-case): <name>
Краткое описание — что делает и когда использовать:
```

**4b. Agents and interaction axes**

```
agents: single | multi
interaction: one-shot | multi-step
```

**4c. Triggers**

```
slash-команды (через запятую):
фразовые триггеры (через запятую):
```

Keep phrase triggers narrow: include a skill name placeholder to avoid accidental activation.

**4d. Bundled resources**

```
Какие bundled resources нужны?
[ ] scripts/
[ ] references/
[ ] assets/
```

Default: `assets/` for scaffold template, `scripts/` for verify script.

### Step 5 — Generate scaffold

Choose scaffold template based on skill complexity:
- **Minimal** (`assets/skill-scaffold-minimal.md`): single-step skills without external gates
- **Full** (`assets/skill-scaffold-full.md`): multi-step skills with Preconditions and Bundled resources

Copy chosen template to target path and substitute:
- `{{name}}`, `{{description}}`, `{{version}}` (default `0.1.0`), `{{status}}` (default `experimental`)
- `{{agents}}`, `{{interaction}}`, `{{layer}}`
- `{{slash_triggers}}`, `{{phrase_triggers}}`
- `{{gates_rationale}}` — required when `gates_required` and `gates_enforced` are both empty

Create selected bundled resource directories with placeholder files.

### Step 6 — Show draft

Print generated `SKILL.md` and file list to stdout. No P5 question. Pilot can cancel with:

```
/skill-creator undo
```

Undo works only before next commit or within 15 minutes.

### Step 7 — Write files, register, verify

Write files to target path. Then regenerate the catalog and run verify:

```bash
bash scripts/generate-skills-catalog.sh   # register in skills-catalog.yaml
bash scripts/verify-skill.sh <name>       # 33-point structural check
```

Both commands must pass before the skill is considered created.

For skills with `interaction: multi-step`: run `/vdv audit` on the Algorithm section.
Not a gate — does not block creation — but catches steps with missing Input/Output linkage
before the skill is used in practice.

## Bundled resources

- `assets/skill-scaffold-minimal.md` — scaffold for single-step skills without external gates
- `assets/skill-scaffold-full.md` — scaffold for multi-step skills with Preconditions and Bundled resources
- `scripts/verify-skill.sh` — validates frontmatter, gates fields, bundled resource existence, L1 location

## Known schema gaps

Fields used by some existing skills but not yet in the standard frontmatter schema:

- `argument-hint` — CLI-style hint for script-executor skills (e.g. agent-fault, apply-captures). Encodes the argument contract. Keep until schema is extended or absorbed into `description`.
- `routing.executor` — indicates whether the skill runs via `script`, `sonnet`, or another executor. Useful for the dispatcher but not validated by `verify-skill.sh`. Candidate for standardization.

Until standardized: leave these fields as-is in existing skills; do not remove during Step 2.5 updates.

## Known tool gaps

- **`verify-skill.sh` L1 location check for `.kimi/skills/`**: `check_l1_location` only checks `FMT-exocortex-template/.agents/skills/`. For skills placed at `.kimi/skills/` (platform:kimi), the L1 location check is skipped when `layer: L2`, or produces a spurious FAIL when `layer: L1`. Until verify-skill.sh is extended with a `--platform kimi` flag, use `layer: L2` for `.kimi/skills/` test skills, and document any intentional L1 Kimi skills separately.
- **`content-audit.sh` coverage (Ф9)**: audit script checks 5 structural criteria (gates_rationale, Algorithm section, step headings ≥3, step content ≥2 lines, When-to-use section). 7 YELLOW skills (single C3 issue) are simple alias/mode skills without numbered step headings. This is structural noise, not content error — these skills are functionally correct. See `scripts/content-audit.sh` for full output.

## Anti-patterns

- Do not create a skill without a linked WP.
- Do not bypass IntegrationGate with a code flag.
- Do not put wide phrase triggers like «надо сделать скилл».
- Run `generate-skills-catalog.sh` after writing files (Step 7) — not before, not manually.
- Do not make the skill verify itself; use `scripts/verify-skill.sh`.
- Do not skip `verify-skill.sh` after editing an existing skill — always run it after any update.
- Do not re-scaffold for minor updates (triggers, description, version bump, algorithm); use Step 2.5 update mode instead. Exception: platform or layer change (e.g. Claude→Kimi, L1→L3) requires a new path and a fresh scaffold — delete old SKILL.md first.
- Do not forget version bump when changing gates, scope, or algorithm steps (bump minor or major).

## Verification

After creation, run:

```bash
bash scripts/verify-skill.sh <skill-name>
```

Expected result: PASS with checks for: valid YAML frontmatter, non-empty description, recognized triggers, `gates_required`/`gates_enforced` fields with valid enum values, bundled resource files exist, scaffold templates valid, L1 skills present in FMT.

<!-- USER-SPACE -->
<!-- /USER-SPACE -->
