# WP-REGISTRY drift guard — full specification

> Hot-trigger: `${IWE_GOVERNANCE_REPO:-DS-strategy}/CLAUDE.md` § WP-REGISTRY drift guard. This file is an elaboration (WP-450 Phase 1). Source: peer-session 2026-06-01-21, `sessions/2026-06/2026-06-01-21-wp-registry-drift-guard/report.md`.

**BLOCKING RULE.** The commit-msg Hook blocks a commit when inbox ↔ docs/WP-REGISTRY.md are out of sync.

**Block triggers:**
- Forward: `inbox/WP-*.md` or `archive/wp-contexts/WP-*` changed without updating `docs/WP-REGISTRY.md` → commit-msg block.
- Backward: `docs/WP-REGISTRY.md` changed without updating `inbox/WP-*.md` or `archive/wp-contexts/WP-*` → commit-msg block.

**Standard flow when closing a Work Product:**
1. Update `inbox/WP-NNN/WP-NNN.md` (`status: done`, `closed_date`).
2. Update the row in `docs/WP-REGISTRY.md` (status `✅`, strikethrough).
   - **Strikethrough format:** `| ~~430~~ | ~~P2~~ | ~~title~~ | ✅ | ~~repo~~ | ~~budget~~ |`
   - Apply strikethrough to: number, project, repo, budget. **Do not apply strikethrough to:** title (`~~` already wraps it), status ✅.
   - Auto-check: `python3 scripts/check-wp-format.py docs/WP-REGISTRY.md`
   - Bulk fix: `python3 scripts/check-wp-format.py docs/WP-REGISTRY.md --fix-t2`
3. Regenerate `current/active-wp.md` — the Script lives in `IWE/scripts/build-active-wp.py` (no copy in the governance repo, issue #905). Run it from there or via the two-location resolver in `scripts/create-wp.sh` (checks `${IWE_GOVERNANCE_REPO:-DS-strategy}/scripts/` first, then `IWE/scripts/`).
4. `git add` all three files + commit.

**Exemption tag `[no-registry-touch]`** — a legitimate escape hatch for the following cases:
- Typo or formatting fix in an inbox file with no status change.
- Frontmatter tag update (for example, `priority` without a status change).
- A subfile inside `inbox/WP-NNN/` (e.g. `inbox/WP-7/phase-2-notes.md`) when WP-7.md itself is unchanged.
- Structural change in the Registry (header, footer, changelog link).

Include in the commit message: `feat(wp-NNN): fixup typo [no-registry-touch]`.

**Exemption tag Audit** — Week Close counts uses over 7 days. More than 2 per week → flag for investigation (bypass incentive). See `${IWE:-$HOME/IWE}/extensions/week-close.after.md`.

**Periodic reconciliation:**
- Day Open: `--deep-check` (orphan detection) — informational, does not block.
- Week Close: `--semantic-check` (status vs placement) — informational, generates Backlog items.