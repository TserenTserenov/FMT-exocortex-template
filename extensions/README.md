# Extensions (Custom Extensions)

> This directory is your space. `update.sh` **never** touches your custom files here: `*.after.md`, `*.before.md`, `*.checks.md`, `mcp-user.json`.
>
> Exception — this `README.md`: it is updated as a platform reference (new hook points, examples). Do not store custom content in it.

## Dry-run Contract (Blocking Rule for Extensions)

> **Full contract:** [memory/dry-run-contract.md](../memory/dry-run-contract.md). When `/audit-installation` smoke-tests a ritual, it creates the sentinel `/tmp/iwe-dry-run.flag` (a single file, not session-bound — issue #237) and expects that **no one writes**.

The PreToolUse hook `dry-run-gate.sh` blocks Write/Edit/git-write/MCP-write automatically. However, **extensions that run their own bash or call exotic tools** (binary APIs, direct psql) may bypass the hook.

### Extension Obligation

If an extension contains write logic (file creation, INSERT into a database, sending a message), a sentinel check **must appear at the top**:

```bash
if [ -f "/tmp/iwe-dry-run.flag" ]; then
    echo "[extension <name>] dry-run active, skipping write steps"
    exit 0
fi
# normal logic follows
```

**Alternative:** perform the write through standard tools (Write/Edit/Bash redirect) — the hook will intercept automatically. An explicit check is only needed if the extension wants to provide a "meaningful rehearsal" (for example, printing "DayPlan would be created here") instead of a silent block.

**Sticky-state protection:** the sentinel TTL is 10 minutes (mtime). If the sentinel is older than that, the hook ignores and removes it (CLI session failure / kill -9).

---

## How to Extend a Protocol

Create a file named:
- `<protocol>.<hook>.md` — a single extension for a hook (manifest style), or
- `<protocol>.<hook>.<suffix>.md` — a modular extension (multiple suffix files for one hook; see [Multiple Extensions for One Hook](#multiple-extensions-for-one-hook-name-conflicts))

Where:
- `<protocol>` — the name of the protocol or skill (`protocol-close`, `protocol-open`, `day-open`, `day-close`, `week-close`, `month-close`, `iwe-update`, `verify`, `archgate`)
- `<hook>` — the insertion point (`before`, `after`, `checks`)
- `<suffix>` — an arbitrary module name (for example, `health`, `linear`, `slack`)

**Native loader (since 0.29.9):** all skills/protocols call `bash .claude/scripts/load-extensions.sh <protocol> <hook>` and iterate over the output. Both manifest and suffix styles work identically. A manifest that manually delegates to suffix files is no longer needed (it will cause double execution).

### Supported Extension Points

| Protocol | Hook | When it runs |
|----------|------|--------------|
| `protocol-close` | `checks` | **Before** Step 1 (commit+push) — pre-commit gate (R4.3 fix, WP-273) |
| `protocol-close` | `after` | After the main checklist, before Verification |
| `protocol-open` | `after` | After the alignment ritual |
| `protocol-open` | `sync` | At the sync step; refines sync behavior |
| `day-open` | `before` | Before Step 1 (Yesterday) — morning rituals, preparation |
| `day-open` | `after` | After Step 6b (Needs Attention), before writing DayPlan |
| `day-open` | `checks` | After writing DayPlan, **before** git commit (Blocking rule) |

> **Two execution paths for `day-open.*.md` (WP-529 Ph11).** The interactive skill (`day-open/SKILL.md`) reads and executes the file as an agent — `load-extensions.sh` + `Read`. The autonomous Pipeline `scripts/day-open-pipeline.sh` (launchd/cron, no LLM in the loop physically) executes **the same files** via `scripts/day-open-hooks-runner.sh`: it extracts and `eval`s each ```` ```bash ```` block mechanically — the same approach already used by `checks` (`day-open-checks-runner.sh`). This gives the rule: content in `day-open.before.md`/`day-open.after.md`/`day-open.checks*.md` must be executable bash blocks, not prose for an LLM — otherwise the Pipeline will honestly fail with "0 bash blocks extracted" on an autonomous run. A failing `before`/`after`/`checks` hook blocks the entire Pipeline commit (it may mutate state before the commit — a silent WARN would risk committing a partial result).

| `day-close` | `before` | Before Step 1 |
| `day-close` | `checks` | After the governance batch, before archiving |
| `day-close` | `after` | After the day summary, before Verification |
| `week-close` | `before` | Before lesson rotation (Step 1) |
| `week-close` | `after` | After the memory Audit (Step 4), before finalization |
| `month-close` | `before` | Before data collection |
| `month-close` | `after` | After the month summary, before writing |
| `strategy-session` | `before` | Before the strategy session starts |
| `strategy-session` | `after` | After the strategy session summary |
| `iwe-update` | `before` | Before the update preview and application |
| `iwe-update` | `checks` | After application, before the successful final report |
| `iwe-update` | `after` | After the final update report |
| `verify` | `before` | Before type selection and Verification launch |
| `verify` | `checks` | After the main check, before the final verdict |
| `verify` | `after` | After the final verdict is shown |
| `archgate` | `before` | Before the principles and the start of the architectural Assessment; an error blocks the start |
| `archgate` | `checks` | After DRR, before the single verdict publication; an error blocks publication |
| `archgate` | `after` | After publication; an error only warns and does not change the verdict |

**ArchGate outcome contract:** `archgate.before` and `archgate.checks` finish with the marker `ARCHGATE_EXTENSION: PASS` or `ARCHGATE_EXTENSION: BLOCK — <reason>`. `BLOCK` is a substantive objection; a loader/execution failure is a separate error — both outcomes block continuation. For `archgate.after`, use `ARCHGATE_EXTENSION: WARN — <reason>`: this Phase only warns and does not change the published verdict. An extension must not re-launch the ArchGate lifecycle via `load-extensions.sh archgate ...`: the loader returns `BLOCK` for `before/checks` and `WARN` for `after`. With a mixed set, a broken or recursive `archgate.after` is skipped and all valid `after` files are executed.

The name always includes the hook. For example, `extensions/verify.md` is never called; use `extensions/verify.before.md`, `verify.checks.md`, or `verify.after.md`.

### Example: Day Reflection

File `extensions/day-close.after.md`:

```markdown
## Day Reflection

- What was the hardest thing today?
- What would I do differently?
- What am I proud of?
```

During Day Close the agent automatically loads this block at the corresponding point in the protocol.

### Example: Additional Checks on Session Close

File `extensions/protocol-close.checks.md`:

```markdown
- [ ] Verify that tests pass (pytest / npm test)
- [ ] Update CHANGELOG.md if there were feat commits
```

## Parameters (params.yaml)

The `params.yaml` file contains persistent parameters that affect protocol behavior.
`update.sh` **does not overwrite** params.yaml — your settings are safe.

| Parameter | Protocol | What it controls |
|-----------|----------|-----------------|
| `video_check` | Day Close | Video check for the day (Step 6e) |
| `multiplier_enabled` | Day Close | IWE multiplier calculation (Step 5) |
| `reflection_enabled` | Day Close | Reflection via `day-close.after.md` |
| `lesson_rotation` | Week Close | Lesson rotation in MEMORY.md (Step 1) |
| `auto_verify_code` | Quick Close | Haiku code auto-Verification (Step 4b) |
| `verify_quick_close` | Quick Close | Haiku checklist Verification (Step 7) |
| `telegram_notifications` | All roles | Telegram notifications from roles |
| `extensions_dir` | All protocols | Extensions directory (default: `extensions`) |

Details: [params.yaml](../params.yaml).

## Day Open Configuration (day-rhythm-config.yaml)

Day Open behavior is controlled via `memory/day-rhythm-config.yaml` (not params.yaml).

| Parameter | What it controls |
|-----------|-----------------|
| `budget_spread.enabled` | Distribute the weekly Work Product budget across days (true/false) |
| `budget_spread.threshold_h` | Minimum weekly budget to participate in the calculation (default: 4h) |
| `budget_spread.rounding` | Rounding step for daily_slot (default: 0.5h) |

**Example:** Work Product with a 6h/week budget, Wednesday (days_left=3) → daily_slot = round(6/3, 0.5) = 2h.

## Multiple Extensions for One Hook (Name Conflicts)

If you need multiple extensions at the same point, use a dot-separated suffix:

```
extensions/day-close.after.health.md      # module 1: health-check
extensions/day-close.after.linear.md      # module 2: Linear sync
extensions/day-close.after.telegram.md    # module 3: Telegram notification
```

The loader (`.claude/scripts/load-extensions.sh day-close after`) returns all matching files in **alphabetical order** — all three will execute (`health` → `linear` → `telegram`). There are no name conflicts.

> **Order when mixing manifest and suffix:** lexicographic sort gives `<protocol>.<hook>.<suffix>.md` < `<protocol>.<hook>.md` (because `.h` < `.m` in dot-prefix comparison). A manifest without a suffix always executes **last**. If order matters, use suffix names with explicit numbering (`day-close.after.01-health.md`, `day-close.after.02-linear.md`).

**A manifest without a suffix is not needed** — write content directly into suffix files. If you have a `day-close.after.md` (manifest) that loads suffix files via Read, **remove it** — the loader will pick up both the manifest and the suffix files, causing double execution.

## Installing Someone Else's Extension (Sharing)

IWE extensions are ordinary Markdown files. Installation:

```bash
cp ~/Downloads/day-close.after.health.md ~/IWE/extensions/
```

### Extension Bundle Format

```
my-extension-pack/
  README.md                    # description, author, version
  extensions/
    day-close.after.md          # extension files
  params-defaults.yaml          # recommended parameters (not applied automatically)
```

Installing a bundle:

```bash
cp my-extension-pack/extensions/* ~/IWE/extensions/
# Review params-defaults.yaml and manually add the needed parameters to ~/IWE/params.yaml
```

To see all available extension points: `/extend`

## Connecting Your Own MCP (mcp-user.json)

Add your MCP servers to `extensions/mcp-user.json`. On every `update.sh` run they are automatically merged into `.mcp.json`.

### Namespace Convention

| Prefix | Who | Examples |
|--------|-----|---------|
| no prefix | Platform (reserved) | `iwe-knowledge` (Gateway, aggregates knowledge + digital-twin) |
| `ext-*` | Vendor | `ext-google-calendar`, `ext-linear`, `ext-slack` |
| `<your-prefix>-*` | Your MCPs | `<your-prefix>-notes`, `<your-prefix>-obsidian` |

Use your own unique prefix (for example, your username) — this prevents conflicts during updates.

### Example: Add Your Own MCP

File `extensions/mcp-user.json`:

```json
{
  "mcpServers": {
    "user-my-notes": {
      "command": "npx",
      "args": ["-y", "my-notes-mcp"],
      "env": {
        "NOTES_DIR": "/path/to/my/notes"
      }
    },
    "ext-linear": {
      "command": "npx",
      "args": ["-y", "@mseep/linear-mcp"],
      "env": {
        "LINEAR_API_KEY": "lin_api_..."
      }
    }
  }
}
```

After `update.sh` these servers will appear in `.mcp.json`. Requires `jq` (`brew install jq`).

**Important:** `update.sh` does not touch `extensions/mcp-user.json` — your MCPs are safe during updates.

## Kimi Context Filtering (.agentigore)

The `.agentigore` file in the repository root controls what Kimi **does not see** as context when working through `kimi-peer-adapter.sh`. The syntax is the same as `.gitignore`.

**Important:** the file name is `.agentigore` (not `.agentignore`). This is the exact name that `kimi-peer-adapter.sh` reads.

To create the file, copy the sample:
```bash
cp extensions/agentigore.sample .agentigore
```

Three priority levels:
- **LEVEL-1** — secrets and private data (`.secrets/`, `personal/`): always ignore
- **LEVEL-2** — heavy context (`docs/`, `archive/`): ignore without a direct task
- **LEVEL-3** — included by default: do not add without a reason

The `.agentigore` file does not affect git — it only affects Kimi. `update.sh` does not touch it.

## Rules

1. File names: `<protocol>.<hook>.md` or `<protocol>.<hook>.<suffix>.md`
2. Content: Markdown — it will be inserted as a block into the protocol
4. Multiple extensions for one hook: loaded in alphabetical order