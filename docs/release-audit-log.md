# Release Audit Log

> Adversarial post-release audits. Process: after each release, an auto-issue `Post-release adversarial audit: vX.Y.Z` now migrates into this table. Trigger: `verify-before-promote.sh` warn gate fires on PASS-merge without a log entry.

## Purpose

Adversarial audit — a sub-agent or external pilot searches for regressions outside current coverage:
- 8 detectors (`integration-detectors.sh`)
- smoke 14 (`integration-smoke.sh`)
- promote-checks (`validate-fmt-scripts.sh`)

Any regression class found → new detector in `integration-detectors.sh` (if reproducible in CI) or smoke (if it requires a pilot environment).

## Process

```
release tag vX.Y.Z → auto-issue (legacy) | new practice → entry here
```

| Field | Description |
|-------|-------------|
| `version` | Release tag (vX.Y.Z) |
| `status` | `pending` / `in-progress` / `completed` / `skipped-unverified` |
| `date` | Audit date (YYYY-MM-DD) or `—` |
| `findings` | Number of findings or `—` |
| `result` | Cross-reference: PR/commit/issue with fixes or `—` |
| `notes` | Migration source or additional info |

## Log

| Version | Status | Date | Findings | Result | Notes |
|---------|--------|------|----------|--------|-------|
| v0.41.0 | **completed** | 2026-10-02 | 0 blockers; 2 important regressions in the release itself (1: fix #991 for CLAUDE.md could hang again after a conflict in a healing run and the next release; 2: skill strategy-session did not start on installations without `origin`) + 3 important pre-existing issues (call forms that bypass the `rm -rf` block in `destructive-guard.sh`; no upgrade path in `ds-publish.sh`; loss of edits outside USER-SPACE and self-replacement of the updater on trim) + minor issues | GO with caveats (patch 0.41.1) | issue #998; fixes: #999 (CLAUDE.md), #1000 (strategy-session), #1001 (bot broadcast: audit reminder sent to 35 subscribers, urgent security notifications were suppressed by deduplication); remaining: #1002 (hook), #1003 (publisher), #1004 (update.sh), #1005 (Windows), #1006 (minor). Performers: independent cold sub-agent using `setup/release-audit-prompt.md` (clean clone, sandbox, 156 calls) and adversarial peer-agent code review round; release identity verified (tag on merge commit, tree matches verified branch, notes match CHANGELOG section, sha256 788 of 788); upgrade via the actual release channel in macOS sandbox from v0.40.2, v0.40.1, v0.40.0 and fresh installs (core, full) 5 of 5. Findings reproduced by execution: F1 by auditor scenario on release `update.sh`, hook call forms on both versions (same in v0.40.2 — not a regression), F2 by code reading. |
| v0.40.0 | **completed** | 2026-09-10 | 1 initial-misclassified blocker (false alarm, design intent already documented in code — see notes) + 4 confirmed important | GO (after fixes) | issue #748 (sub-agent post-release verify), fixes in PR #777 (issue-batch) + follow-up on branch fix/wp570-audit-followup. Breakdown: (1) "leak" of YooKassa-key-like strings in `scripts/tests/*.py` names — false positive, `secret-bypass-lib.sh:70-84` already documents this as an intentional fail-closed decision (WP-544) for long snake_case pytest names without source context; not a secret, not an incident; (2) `memory/MEMORY.md` (seed) — 2 dead links to files removed in v0.27 → removed; (3) `setup/detector-regex.sh` DETECTOR_07 did not catch quoted bare literals → regex extended + fixture added; (4) `setup/smoke-test-fresh-install.sh` — 4 failures on NixOS (not a template regression — hardcoded `PATH=/usr/bin:/bin` excluded the Nix profile + e2e tests inherited PATH with a foreign git-wrapper from the dev machine) → `SMOKE_CLEAN_PATH`, 49/0 after fix; (5) `.claude/skills/lesson-close/` without a paired `/lesson` → issue #778, deferred to pilot (product decision, not a technical fix). |
| v0.39.1 | **completed** | 2026-08-30 | 0 P0/P1, 3 low-severity (pre-existing, not caused by this delta) | GO | issue #576 (self-run by implementing agent, pilot-waived); independent context-isolated re-audit of the delta (PR #585 f896701 + PR #586 10c9732, personal-guide rename) — separate GO, findings: stale `docs/skills-catalog.md` (pre-existing), `org-dev/SKILL.md` references unrelated `PACK-personal/personal-guide/` path (needs owner confirmation it's intentionally distinct), `seed/strategy/scripts/day-open-scaffold.sh` not covered by manifest B2 (pre-existing gap) |
| v0.34.1 | skipped-unverified | — | — | — | migrated from #133 |
| v0.34.0 | skipped-unverified | — | — | — | migrated from #130 |
| v0.33.x | skipped-unverified | — | — | — | migrated from #129, #127 |
| v0.32.x | skipped-unverified | — | — | — | migrated from #126, #123 |
| v0.31.x | skipped-unverified | — | — | — | migrated from #117 |
| v0.30.x | skipped-unverified | — | — | — | migrated from #55, #54 |
| v0.29.25 | skipped-unverified | — | — | — | migrated from #41 |
| v0.29.x (legacy) | skipped-unverified | — | — | — | migrated from #15, #16, #18, #21, #22, #27, #32, #43, #44, #45, #52, #53 |
| v0.29.x (round-2) | **completed** | 2026-05-06 | 40 | TESTING.md known limitations | confirmed via M1.6 #75 — 40 findings, all ✅ Fixed |

## Hidden Observation From Migrated Issues

A spot-check of migrated issues (peer-session 2026-06-01-18, author governance repo, session transcript not published) revealed: M-checklist #75 (M1.6) contains confirmation that **the adversarial audit on 2026-05-06 found 40 findings and all were fixed** (status: ✅ Fixed for C1-C4, H2, ...). This means one of the migrated audits was actually conducted — it is not "skipped-unverified", it is **completed with no entry in the public log**. The entry has been restored in the `v0.29.x (round-2)` row.

## Ongoing Use

- Each new release → one row in this table (instead of an auto-issue).
- `verify-before-promote.sh` warn-gate: if a promotion is attempted without a log entry for the previous release — warning (not a block).
- Once per quarter — review the log: `skipped-unverified` entries older than 90 days → make a decision (run-now / accept-debt / wontfix).

## Related

- `verify-before-promote.sh` — record-keeping gate
- `integration-detectors.sh` — where audit findings feed back
- `TESTING.md` — overall strategy
- Peer-session 2026-06-01-18 (author governance repo) — migration from 22 open issues