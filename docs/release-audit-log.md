# Release Audit Log

> Adversarial post-release audits. Process: after each release, an auto-issue `Post-release adversarial audit: vX.Y.Z` now migrates into this table. Trigger: `verify-before-promote.sh` warn gate fires on PASS-merge without a log entry.

## Purpose

Adversarial audit — a sub-agent or external pilot searches for regressions outside current coverage:
- 8 detectors (`integration-detectors.sh`)
- smoke 14 (`integration-smoke.sh`)
- promote-checks (`validate-fmt-scripts.sh`)

Any discovered regression class → new detector in `integration-detectors.sh` (if reproducible in CI) or smoke (if it requires a pilot environment).

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

During a spot-check of migrated issues (peer-session 2026-06-01-18, author governance repo, session transcript not published): M-checklist #75 (M1.6) contains confirmation that **the adversarial audit on 2026-05-06 found 40 findings and all were fixed** (status: ✅ Fixed across C1-C4, H2, ...). This means one of the migrated audits was actually completed — it is not `skipped-unverified`, it is **completed with no entry in the public log**. The entry has been restored in the `v0.29.x (round-2)` row.

## Ongoing Use

- Each new release → add a row to this table (instead of creating an auto-issue).
- `verify-before-promote.sh` warn-gate: if a promotion is attempted without a log entry for the previous release — warning (not a block).
- Quarterly log review: `skipped-unverified` entries older than 90 days → make a decision (run-now / accept-debt / wontfix).

## Related

- `verify-before-promote.sh` — gate for record-keeping
- `integration-detectors.sh` — where audit findings are returned
- `TESTING.md` — overall strategy
- Peer-session 2026-06-01-18 (author governance repo) — migration from 22 open issues