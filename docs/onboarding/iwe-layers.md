# IWE Architecture: Three Layers

> **Audience:** for those who have already installed IWE and want to understand "how it works internally" and what can be changed where.

---

## Layer Diagram

```
┌─────────────────────────────────────────────────────┐
│  L3 — Authoring / User                              │
│  extensions/*.md · params.yaml · memory/ (personal) │
│  ← NOT overwritten by update.sh · this is YOURS    │
├─────────────────────────────────────────────────────┤
│  L2 — Staging (trial)                               │
│  CLAUDE.md §8 · STAGING.md                          │
│  ← under test · at Week Close → L1 or rejected     │
├─────────────────────────────────────────────────────┤
│  L1 — Platform                                      │
│  .claude/skills/ · memory/protocol-*.md             │
│  CLAUDE.md §1–§7 · .claude/rules/ · .claude/hooks/ │
│  ← updated by update.sh · modify with care         │
└─────────────────────────────────────────────────────┘
```

---

## L1 — Platform (do not modify without a reason)

**What is here:** skills (`/day-open`, `/wp-new`, `/archgate`), protocols (`memory/protocol-*.md`), hooks (`.claude/hooks/`), rules (`.claude/rules/`), §1–§7 in `CLAUDE.md`.

**Who updates it:** `update.sh`. The Platform developer releases a new version → you run `/iwe-update` → L1 files update automatically.

**Analogy:** the OS kernel. You do not edit the Ubuntu kernel directly — you install packages and adjust Configuration.

**What happens if you edit L1:** the next `update.sh` run overwrites your changes. To modify behavior, use L3 instead.

---

## L3 — Authoring (your space)

**What is here:** `extensions/*.md`, `params.yaml`, `CLAUDE.md §9` (authoring).

**Who updates it:** only you. `update.sh` does not touch these files — guaranteed.

**How extensions work:**

```
extensions/day-open.before.md   ← runs BEFORE step 0 of day-open
extensions/day-open.after.md    ← runs AFTER step 6 of day-open
extensions/day-close.before.md  ← runs BEFORE day-close
```

**Example:** to make Day Open check tasks in Linear — add to `extensions/day-open.before.md`:
```
## Step 0a. Check Linear
Open Linear, review tasks with a deadline today.
```

**params.yaml** — global parameters for your setup:
```yaml
author_mode: false        # true = template author, direct L1 editing
governance_repo: DS-strategy   # name of your strategy repo
strategy_day: sunday      # day of the strategy session
```

---

## L2 — Staging (trial before promotion to L1)

**What is here:** rules under trial — `CLAUDE.md §8` + `STAGING.md`.

**When to use:** you have created a new behavior rule for Claude, tested it in practice, and want to make it a platform-level rule (promote it to L1 and into the template for all users).

**Cycle:**
1. New behavior → `CLAUDE.md §9` (authoring) + a line in `STAGING.md` (status: testing)
2. Runs stably for several weeks → `status: validated`
3. At Week Close → remove authoring constants → move to L1 → commit to FMT-exocortex-template

---

## What to put where: quick reference

| Situation | Where |
|-----------|-------|
| I want to change Day Open behavior | `extensions/day-open.before.md` (L3) |
| I want to change a protocol for all users | L2 staging → promote to L1 |
| My rule is for me only | `CLAUDE.md §9` (L3) |
| Stable knowledge about me | `memory/*.md` (L3) |
| Found a bug in a platform Skill | `/iwe-bug-report` → issue in FMT-exocortex-template |
| Need a new platform feature | `/iwe-bug-report` with the `enhancement` label |

---

## Why Syncthing is noisy during a Claude session

Claude Code continuously writes to `.claude/projects/` (session transcripts) — this generates hundreds of file events per minute. Syncthing reacts to every change and scans the file system.

**Solution:** the `.stignore` file in the IWE root excludes noisy paths:

```
.claude/projects/     // Claude Code session transcripts
.claude/state/
.claude/.cache/
logs/rule-engine/     // rule-classifier logs (updated hourly)
```

The `.stignore` file is already included in the template — it will appear automatically after `/iwe-update`.

---

*Created: 2026-04-28 | WP-5 Ф-N artifact #4 | [FMT-exocortex-template](https://github.com/TserenTserenov/FMT-exocortex-template)*