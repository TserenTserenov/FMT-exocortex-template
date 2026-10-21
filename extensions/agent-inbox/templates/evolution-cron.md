# Template: evolution-cron

> Weekly revision of one Pack rule (WP-272 weekly evolution pattern).

## Parameters

| Parameter | Type | Example |
|-----------|------|---------|
| `pack_repo` | str | `{{GOVERNANCE_ORG}}/PACK-agent-rules` |
| `rule_glob` | str | `rules/AR.*.md` |
| `revision_strategy` | enum | `oldest_revised` / `random` / `low_trust_score` |

## Prompt

See existing WP-272 cron prompt (`trig_01D5YUcQWcPgsYc5euzrAQvM`). This template is a wrapper for future unification; the WP-272 cron remains as-is for now.

**TODO (Phase 6 promotion to FMT):** move the WP-272 prompt here as a parameterized template; the cron schedule is set in the task file via `due` + recurring marker.

## Acceptance

- PR created in `{{pack_repo}}` with branch `weekly-evolution/AR.NNN-YYYY-MM-DD`.
- Verdict ✅/⚠️/❌ recorded in the rule frontmatter.
- `revised` updated.