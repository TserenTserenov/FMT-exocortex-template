# Release Audit Log

> Log of post-release adversarial audit results. The workflow
> `.github/workflows/post-release-audit.yml` automatically creates a reminder issue
> on push of `update-manifest.json` to main with version x.y.0;
> for patch releases, it is triggered manually.
> Audit results are recorded here. Each unresolved material finding requires
> a separate open issue with a link from the audit result.
> The pre-promote guard `verify-before-promote.sh` is not implemented.

## Purpose

An adversarial audit has the reviewer search for regressions outside the current detectors,
installation checks, and `promote-checks` (`validate-fmt-scripts.sh`). The number
of checks performed is taken from the receipt of the exact verified commit.

Each material confirmed finding receives a link to an executable
detector, fixture, or environment test with a red control on the defective Artifact
and a green result on the candidate. If no such control exists, the exception must be
explicitly accepted by the product owner or the designated release approver —
not the finding author. The record must contain a permanent link to that decision
in an issue, PR, or decision record, along with the scope, rationale, and revision condition.
A proposed but unaccepted exception leaves the finding open. Each
unresolved material finding receives a separate open issue in this
Repository and a link to it in the audit result. The audit reminder may only be
closed after those issues are created; closing the reminder does not close the findings.
An individual audit record may be completed, but does not by itself close the identified defect.

## Process

```
push update-manifest.json to main, version x.y.0 → reminder issue created automatically
patch → reminder issue on manual workflow trigger
audit → record result here; unresolved material finding → open issue
```

| Field | Description |
|-------|-------------|
| `version` | Release tag (vX.Y.Z) |
| `status` | `pending` / `in-progress` / `completed` / `skipped-unverified` |
| `date` | Audit date (YYYY-MM-DD) or `—` |
| `findings` | Number of findings or `—` |
| `result` | Cross-reference: PR/commit/issue with fixes or `—` |
| `notes` | Migration source or additional info |

Example of application to a confirmed finding: a false free plan on morning Pipeline failure (#983) led to real-run checks in `scripts/tests/test_issue_983_morning_alarm.sh` in PR #992. An independent replay of the test from the PR on the merge parent of #992 exited with code 1 and 64 failures (including a free prompt on Pipeline failure); on the merge commit of #992 it exited with code 0, 90 passing checks, 0 failures. The live scheduler and Linux, not verified, are noted separately in the PR. This receipt covers only the free fallback plan and alarm delivery: other sub-items of #983, including framework build without a model gateway, are not covered. It does not prove coverage of all prior findings.

## Log

| Version | Status | Date | Findings | Result | Notes |
|---------|--------|------|----------|--------|-------|
| v0.41.0 | **completed** | 2026-10-02 | 0 blocker; 2 important release regressions, prior findings, and notification defects | "No blockers" per [pilot run comment](https://github.com/TserenTserenov/FMT-exocortex-template/issues/998#issuecomment-5949272475) | Pilot run #998: two regressions fixed in #999 and #1000; notifications — #1001 with limited verification; prior findings — open #1002–#1006. Release and updates verified in sandbox as noted in #998; those checks do not close the individual findings. |
| v0.41.0 | **completed** | 2026-10-02 | 0 blocker; 4 important and 3 nice-to-have (reported separately) | "Not STABLE" per external reviewer; independent replay not recorded | [Separate fork-user comment](https://github.com/TserenTserenov/FMT-exocortex-template/issues/998#issuecomment-5949629589): WSL2, upgrade 0.40.2→0.41.0, `core.fileMode=false`. Migration path outside manifest, `+x` loss, Python literals, and Linux systemd; do not add numbers to the pilot run and do not treat these items as closed by its resolution. |
| v0.40.0 | **completed** | 2026-09-10 | 0 blocker, 0 important, 5 nice-to-have (F1–F5) | STABLE per [first run](https://github.com/TserenTserenov/FMT-exocortex-template/issues/748#issuecomment-5613470222) | F1 — detector gap, F2 — two dead links, F3 — stale names and counters, F4 — 7 of 24 `substituted` without `{{}}`, F5 — reference to non-existent warn gate. This is a separate early assessment, without the YooKassa and NixOS false alarm. |
| v0.40.0 | **completed** | 2026-09-10 | 1 initial false alarm and 4 confirmed items | STABLE after technical follow-up per [late pilot run](https://github.com/TserenTserenov/FMT-exocortex-template/issues/748#issuecomment-5619310904) | False YooKassa "leak" — documented fail-closed behavior. #779 removed dead links, expanded DETECTOR_07, and fixed smoke on NixOS (was 23 PASS/4 FAIL, became 49/0). The fourth item, `/lesson-close` without `/lesson`, was tracked in #778 and resolved by the pilot later in #845, not in #779. |
| v0.39.0 | **completed** | 2026-08-30 | 1 blocking regression #559 | BLOCKED, release replaced by v0.39.1 | [Run #576](https://github.com/TserenTserenov/FMT-exocortex-template/issues/576#issuecomment-5467737058): `RC_STEP_SKIPPED` was not displayed in `main()` Day Close; an optional skip produced exit code 1. Fix #575. |
| v0.39.1 | **completed** | 2026-08-30 | 0 new P0/P1 in verified fix | GO per [run #576](https://github.com/TserenTserenov/FMT-exocortex-template/issues/576#issuecomment-5467737058) | Release #577 after #575; audit performed by the fix author with pilot approval; independent replay recommended only. #588 separately recorded a delta assessment of personal-guide #585/#586, but no executable receipt is available for the 3 minor prior observations claimed there; do not treat this as an independent release replay. |
| v0.34.1 | skipped-unverified | — | — | — | migrated from #133 |
| v0.34.0 | skipped-unverified | — | — | — | migrated from #130 |
| v0.33.x | skipped-unverified | — | — | — | migrated from #129, #127 |
| v0.32.x | skipped-unverified | — | — | — | migrated from #126, #123 |
| v0.31.x | skipped-unverified | — | — | — | migrated from #117 |
| v0.30.x | skipped-unverified | — | — | — | migrated from #55, #54 |
| v0.29.25 | skipped-unverified | — | — | — | migrated from #41 |
| v0.29.x (legacy) | skipped-unverified | — | — | — | migrated from #15, #16, #18, #21, #22, #27, #32, #43, #44, #45, #52, #53 |
| v0.29.x (round-2) | **completed** | 2026-05-06 | 40 claimed findings | #75 records only a subset of statuses | [M1.6 #75](https://github.com/TserenTserenov/FMT-exocortex-template/issues/75) lists 6 `Fixed` (C1–C4, H2–H3) and 3 `To verify` (H1, H4–H5). The full list of 40 and a receipt for their closure are absent from the available record; `TESTING.md` and the audit report referenced in #75 are not currently delivered. |

Receipts and boundaries for these historical records:

- For F1 from the early v0.40.0 run, #779 added
  `setup/detector-fixtures/detector_07/positive_quoted_literal.md`: the previous
  regex did not catch the sample; the current `setup/test-detectors.sh` passes 3 of 3
  fixtures. F2 — link removal with no separate executable check; F3 —
  correction of current descriptions in #1024; the old reminder text in #748 remains
  historical. F4 requires per-file justification of `substituted` or a control check:
  the contract itself allows a file without `{{}}` if it is meant to live in the workspace.
  F5 — the false warn-gate promise was removed in #1024; the gate itself does not exist. The decision
  to remove `/lesson-close` was accepted and delivered in #845; no separate red and green
  check for this finding is recorded.
- For v0.41.0, #999 reproduced exit code 49 on the old `update.sh`, then ran
  `scripts/tests/test_issue_541_workspace_base.sh` (142 checks and 7 red
  mutants). #1000 verified `strategy-session` with test
  `scripts/tests/test_issue_969_strategy_session_isolated_copy.sh`
  (3 red mutants, green candidate); a full test of the old release is not proven by this. #1001 verified YAML and code, but not live bot delivery or
  deduplication. #1002–#1006 remain open and are not accepted exceptions.
- The four material findings from the external v0.41.0 run received separate issues:
  migration path #1036, `core.fileMode=false` #1037, Python literals #1038,
  Linux systemd #1039. Migration #1036 was fixed in main via #1041 with verification against the old installation; Python paths #1038 were fixed in main via #1040 and closed:
  these are author scripts outside the user manifest. #1037 was fixed in main
  via #1042 after red reproduction and end-to-end verification; #1039 remains open.
  The fixes from main have not yet been delivered in a new release. None of the items has received
  an accepted exception or a completed installed-release verification here.
- For #559, the v0.39.0 defect was confirmed by code review in #576; v0.39.1 passed
  a manual trial after #575. A regression test for `RC_STEP_SKIPPED` and the lesson-link counter was added to main via #1035; an independent release replay is not recorded.

## Hidden Observation From Migrated Issues

A spot-check of migrated issues confirmed the adversarial audit of 2026-05-06
with 40 claimed findings (#75); its status here is therefore `completed`.
However, #75 does not prove all 40 were fixed: it lists six `Fixed`
and three `To verify`. The full findings registry and executable receipts are not
delivered in the current tree; the prior claim that "all are fixed" is retracted.

## Further Use

- Each verified release → one row in this table. The workflow issue serves as
  a reminder and does not replace a result record or separate open issues
  for unresolved material findings.
- There is currently no automated warning when a release has no entry in this table: `verify-before-promote.sh` is absent from the template tree.
- Quarterly — review log: `skipped-unverified` entries older than 90 days → make a decision (run-now / accept-debt / wontfix).

## Related

- `.github/workflows/post-release-audit.yml` — reminder issue creation
- `setup/integration-contract-validator.sh` and `setup/test-detectors.sh` —
  current detectors and their fixtures
- Peer-session 2026-06-01-18 (author governance repo) — Migration from 22 open issues