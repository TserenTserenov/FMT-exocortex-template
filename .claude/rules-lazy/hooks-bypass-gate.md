# Hooks/Scripts Bypass Gate — Full Specification (S-33)

> Hot-trigger: `${IWE:-$HOME/IWE}/CLAUDE.md` § 2 Blocking rules, item 6. This file is an elaboration (WP-450 Phase4). Source: pilot, 2026-04-28.

**BLOCKING RULE.** Do not modify template scripts and do not bypass hooks by any means without explicit user permission.

**Protected paths:** `.claude/hooks/`, `.claude/scripts/`, `.iwe-runtime/`, `IWE/`.

**Prohibited bypass methods:**
- `--no-verify`
- modifying hook/script launch flags
- `git config core.fileMode false` without justification
- overriding `AI_CLI_EXTRA_FLAGS`

**If an IWE hook or script blocks an action:**
1. Do not bypass it — execute as intended.
2. Record the error in `<governance-repo>/inbox/bugs/bug-YYYY-MM-DD-<topic>.md`.
3. Notify the user what was blocked and where the bug file is located.
4. Wait for instructions.

**Exception:** the user explicitly says "bypass" / "ignore the hook" / "modify the script."

**Relationship to Extensions Gate:** Extensions Gate answers the question "where to place customizations" (platform-level vs. author-level placement); this gate answers the question "what to do when a hook is already blocking an action." The two axes are orthogonal and do not duplicate each other.
