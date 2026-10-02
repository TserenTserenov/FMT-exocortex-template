# Release Audit Log

> Log of post-release adversarial audit results. The workflow
> `.github/workflows/post-release-audit.yml` creates a reminder issue
> automatically on push of `update-manifest.json` to main with version x.y.0;
> for patch releases, run it manually.
> Record the audit result here. Each unresolved significant finding requires
> a separate open issue with a link from the audit result.
> The pre-promotion guard `verify-before-promote.sh` is not implemented.

## Purpose

Adversarial audit — the reviewer searches for regressions outside current detectors,
installation checks, and `promote-checks` (`validate-fmt-scripts.sh`). The number
of checks performed is taken from the receipt of the exact verified commit.

Each significant confirmed finding receives a link to an executable
detector, fixture, or environment test with a red result on the defective artifact
and a green result on the candidate. If no such control exists, the exception must be
explicitly accepted by the product owner or the designated release approver —
not the finding author. The record must contain a permanent link to that decision
in an issue, PR, or decision record, along with the scope, rationale, and revision condition.
A proposed but unaccepted exception leaves the finding open. Each
unresolved significant finding receives a separate open issue in this
repository and a link to it in the audit result. The reminder issue may only be
closed after those issues are created; closing it does not close the findings.
An individual audit record may be completed, but it does not by itself close any found defect.

## Process

```
push update-manifest.json to main, version x.y.0 → reminder issue created automatically
patch → reminder issue on manual workflow run
audit → record result here; unresolved significant finding → open issue
```

| Field | Description |
|-------|-------------|
| `version` | Release tag (vX.Y.Z) |
| `status` | `pending` / `in-progress` / `completed` / `skipped-unverified` |
| `date` | Audit date (YYYY-MM-DD) or `—` |
| `findings` | Number of findings or `—` |
| `result` | Cross-reference: PR/commit/issue with fixes or `—` |
| `notes` | Migration source or additional info |

Example of applying a confirmed finding: a false free-plan state on morning Pipeline
failure (#983) led to tests of the actual run in
`scripts/tests/test_issue_983_morning_alarm.sh` in PR #992. An independent
re-run of the test from the PR on the merge parent of #992 exited with code 1 and 64 failures
(including free prompt on Pipeline failure); on the merge commit of #992
it exited with code 0, 90 passing checks, 0 failures. The untested live
scheduler and Linux are noted separately in the PR. This receipt covers only the
free fallback plan and alarm delivery: other sub-items of #983, including
framework build without a model gateway, are not addressed by it. It does not prove coverage
of all prior findings.

## Log

| Version | Status | Date | Findings | Result | Notes |
|---------|--------|------|----------|--------|-------|
| v0.41.0 | **completed** | 2026-10-02 | 0 blockers; 2 important regressions from this release itself (1: the #991 fix for CLAUDE.md could hang again after a conflict in the healing run and the next release; 2: the strategy-session Skill did not start on installations without `origin`) + 3 important pre-existing (call forms that bypass `rm -rf` blocking in `destructive-guard.sh`; no upgrade path in `ds-publish.sh`; loss of edits outside USER-SPACE and updater self-replacement on truncation) + minor | GO with exceptions (patch 0.41.1) | issue #998; fixes: #999 (CLAUDE.md), #1000 (strategy-session), #1001 (bot broadcast: audit reminder was sent to 35 subscribers, urgent security notifications were suppressed by deduplication); remainder: #1002 (Hook), #1003 (publisher), #1004 (update.sh), #1005 (Windows), #1006 (minor). Performers: independent cold sub-agent per `setup/release-audit-prompt.md` (clean clone, sandbox, 156 calls) and adversarial peer-agent code review round; release identity (tag on merge commit, tree equals verified branch, notes equal CHANGELOG section, sha256 788 of 788); update via the actual release channel in macOS sandbox from v0.40.2, v0.40.1, v0.40.0 and fresh installs (core, full) 5 of 5. Findings reproduced by execution: F1 by auditor scenario on release `update.sh`, Hook forms on both versions (same in v0.40.2, not a regression), F2 by code reading. |
| v0.40.0 | **completed** | 2026-09-10 | 1 initial-misclassified blocker (false alarm, design intent already documented in code — see notes) + 4 confirmed important | GO (after fixes) | issue #748 (sub-agent post-release verify), fixes in PR #777 (issue-batch) + follow-up on branch fix/wp570-audit-followup. Breakdown: (1) apparent leak of YooKassa-like keys in `scripts/tests/*.py` names — false positive, `secret-bypass-lib.sh:70-84` already documents this as an intentional fail-closed decision (WP-544) for long snake_case pytest names without source context; not a secret, not an Incident; (2) `memory/MEMORY.md` (seed) — 2 dead links to files removed in v0.27 → removed; (3) `setup/detector-regex.sh` DETECTOR_07 did not catch quoted bare literal → regex extended + fixture; (4) `setup/smoke-test-fresh-install.sh` — 4 failures on NixOS (not a template regression — hardcoded `PATH=/usr/bin:/bin` did not include the Nix profile + e2e tests inherited PATH with an extraneous git-wrapper from the dev machine) → `SMOKE_CLEAN_PATH`, 49/0 after fix; (5) `.claude/skills/lesson-close/` without a paired `/lesson` → issue #778, left to the pilot (product decision, not a technical fix). |
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

During a spot-check of migrated issues (peer session 2026-06-01-18, author governance repo, session transcript not published): M-checklist #75 (M1.6) contains confirmation that **the adversarial audit of 2026-05-06 found 40 findings and all were fixed** (status: ✅ Fixed for C1-C4, H2, ...). This means one of the migrated audits was actually conducted — it is not "skipped-unverified", it is **completed with no entry in the public log**. The record has been restored in the `v0.29.x (round-2)` row.

## Ongoing Use

- Each verified release → one row in this table. The workflow issue serves as
  a reminder and does not replace the result record or separate open issues
  for unresolved significant findings.
- There is currently no automated warning when a release is published without an entry in this table:
  `verify-before-promote.sh` is absent from the template tree.
- Quarterly: review the log — any `skipped-unverified` entry older than 90 days → make a decision (run-now / accept-debt / wontfix).

## Related

- `.github/workflows/post-release-audit.yml` — reminder issue creation
- `setup/integration-contract-validator.sh` and `setup/test-detectors.sh` —
  current detectors and their fixtures
- Peer session 2026-06-01-18 (author governance repo) — migration from 22 open issues