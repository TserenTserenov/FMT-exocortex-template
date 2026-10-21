# New-files guard: current/ and docs/ — full specification

> Hot-trigger: `${IWE_GOVERNANCE_REPO:-DS-strategy}/CLAUDE.md` § New-files guard. This file is an elaboration (WP-450 Phase1). Source: peer-audit Claude + Kimi, `sessions/2026-06/2026-06-04-current-docs-audit/report.md`.

**BLOCKING RULE.** The commit-msg hook blocks a commit when new files (Added or Renamed-into) appear in `current/` or `docs/`.

**Criterion for .gitignore:** any file with `generated_at:` in its frontmatter or `AUTO-GENERATED` in its first lines must be listed in `.gitignore` and must not be committed.

**Bypass:** add the tag `[allow:current]` or `[allow:docs]` to the commit message.

**After cloning:** run `bash scripts/install-hooks.sh` — otherwise the guard is inactive.
