# Release Audit Log

> Log of post-release adversarial audit results. The workflow
> `.github/workflows/post-release-audit.yml` creates a reminder issue
> automatically on push of `update-manifest.json` to main with version x.y.0;
> for patch releases, it is triggered manually.
> The audit result is recorded here. Each unresolved material finding requires
> a separate open issue with a link from the audit result.
> The pre-promotion guard `verify-before-promote.sh` is not implemented.

## Purpose

An adversarial audit — the reviewer searches for regressions outside the current detectors,
installation checks, and `promote-checks` (`validate-fmt-scripts.sh`). The count of
completed checks is taken from the receipt of the exact verified commit.

Each material confirmed finding receives a link to an executable
detector, fixture, or environment test with a red control on the defective artifact
and a green result on the candidate. If no such control exists, the exception must be
explicitly accepted by the product owner or the designated release approver —
not the finding author. The record must contain a permanent link to that decision
in an issue, PR, or decision record, along with the scope, reason, and condition for revision.
A proposed but unaccepted exception leaves the finding open. Each
unresolved material finding receives a separate open issue in this
repository and a link to it in the audit result. The audit reminder may only be
closed after those issues are created; closing the reminder does not close the findings.
An individual audit record may be completed, but it does not close the found defect on its own.

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

Example application to a confirmed finding: a false free plan on morning Pipeline failure (#983) led to tests of the actual run
`scripts/tests/test_issue_983_morning_alarm.sh` in PR #992. Independent
re-run of the test from the PR on the merge parent of #992 exited with code 1 and 64 failures
(including free prompt on Pipeline failure); on the merge commit of #992
it exited with code 0, 90 passing checks, 0 failures. The untested live
scheduler and Linux are noted separately in the PR. This receipt covers only
the free fallback plan and alarm delivery: other sub-items of #983, including
scaffold build without a model gateway, are not implied by it. It does not prove
coverage of all prior findings.

## Log

| Version | Status | Date | Findings | Result | Notes |
|---------|--------|------|----------|--------|-------|
| v0.41.3 | **completed** | 2026-10-03 | 1 material audit-boundary defect [#1072](https://github.com/TserenTserenov/FMT-exocortex-template/issues/1072); 0 new confirmed behavioral defects of #1067 | [Layer 5: 0 new material](https://github.com/TserenTserenov/FMT-exocortex-template/issues/1071#issuecomment-5973120428); [Layer 6: BLOCKED](https://github.com/TserenTserenov/FMT-exocortex-template/issues/1071#issuecomment-5973157100) | On published tag 774b0898, the #1067 fix passed on the delivered copy; the v0.41.2→v0.41.3 update via the real release channel preserved synthetic user files. The single-use audit boundary wrapper missed host-global `launchctl` calls; host service modification is not proven. #1071 remains open until #1072 is fixed and safely re-verified. Prior #1002/#1005/#1006/#1032 remain open. |
| v0.41.2 | **completed** | 2026-10-03 | 1 new material P1 [#1067](https://github.com/TserenTserenov/FMT-exocortex-template/issues/1067) | [Layer 5: BLOCKED](https://github.com/TserenTserenov/FMT-exocortex-template/issues/1066#issuecomment-5972449899); [Layer 6: BLOCKED](https://github.com/TserenTserenov/FMT-exocortex-template/issues/1066#issuecomment-5972436902) | On published tag 77fe2f2d, after two week-review failures, the delivered DayPlan shows a false green status even though the report was not delivered. The CI receipt is green but did not cover this case. #1066 remains open until the fix and independent re-verification; prior #1006 also remains open. |
| v0.41.1 | **completed** | 2026-10-03 | 2 material: P1 #1060, P2 #1061 | [Layer 6: BLOCKED](https://github.com/TserenTserenov/FMT-exocortex-template/issues/1059#issuecomment-5971646785) | [Layer 5: 2 classes found](https://github.com/TserenTserenov/FMT-exocortex-template/issues/1059#issuecomment-5971645767) on tag faccdf3c: the release receipt is green, but the installed Day Open falsely colors a scheduler failure green, and a required map was not delivered to the platform Skill. Both issues are open; #1059 is not closed. |
| v0.41.0 | **completed** | 2026-10-02 | 0 blockers; 2 important release regressions, prior findings, and notification defects | "No blockers" per [pilot run comment](https://github.com/TserenTserenov/FMT-exocortex-template/issues/998#issuecomment-5949272475) | Pilot run #998: two regressions fixed in #999 and #1000; notifications — #1001 with limited verification; prior findings — open #1002–#1006. Release and updates verified in sandbox as noted in #998; these checks do not close the individual findings. |
| v0.41.0 | **completed** | 2026-10-02 | 0 blockers; 4 important and 3 nice-to-have (reported separately) | "Not STABLE" per external reviewer; independent re-run not recorded | [Separate fork user comment](https://github.com/TserenTserenov/FMT-exocortex-template/issues/998#issuecomment-5949629589): WSL2, update 0.40.2→0.41.0, `core.fileMode=false`. Migration path outside the Manifest, loss of `+x`, Python literals, and Linux systemd; do not add counts to the pilot run or treat these items as closed by its resolution. |
| v0.40.0 | **completed** | 2026-09-10 | 0 blockers, 0 important, 5 nice-to-have (F1–F5) | STABLE per [first run](https://github.com/TserenTserenov/FMT-exocortex-template/issues/748#issuecomment-5613470222) | F1 — detector gap, F2 — two dead links, F3 — stale names and counters, F4 — 7 of 24 `substituted` entries without `{{}}`, F5 — reference to a non-existent warn gate. This is a separate early assessment, without the YooKassa false alarm or NixOS. |
| v0.40.0 | **completed** | 2026-09-10 | 1 initial false alarm and 4 confirmed items | STABLE after technical follow-up per [late pilot run](https://github.com/TserenTserenov/FMT-exocortex-template/issues/748#issuecomment-5619310904) | The YooKassa "leak" was documented fail-closed behavior. #779 removed dead links, expanded DETECTOR_07, and fixed the smoke test on NixOS (was 23 PASS/4 FAIL, became 49/0). The fourth item, `/lesson-close` without `/lesson`, was tracked in #778 and resolved by the pilot later in #845, not in #779. |
| v0.39.0 | **completed** | 2026-08-30 | 1 blocking regression #559 | BLOCKED, release superseded by v0.39.1 | [Run #576](https://github.com/TserenTserenov/FMT-exocortex-template/issues/576#issuecomment-5467737058): `RC_STEP_SKIPPED` was not rendered in `main()` Day Close; an optional skip produced exit code 1. Fixed in #575. |
| v0.39.1 | **completed** | 2026-08-30 | 0 new P0/P1 in verified fix | GO per [run #576](https://github.com/TserenTserenov/FMT-exocortex-template/issues/576#issuecomment-5467737058) | Released as #577 after #575; the audit was performed by the fix author with pilot permission; independent re-run is recommended only. #588 separately recorded an assessment of the personal-guide delta #585/#586, but no executable receipt is available for the 3 prior minor observations noted there; do not treat this as an independent release re-run. |
| v0.34.1 | skipped-unverified | — | — | — | migrated from #133 |
| v0.34.0 | skipped-unverified | — | — | — | migrated from #130 |
| v0.33.x | skipped-unverified | — | — | — | migrated from #129, #127 |
| v0.32.x | skipped-unverified | — | — | — | migrated from #126, #123 |
| v0.31.x | skipped-unverified | — | — | — | migrated from #117 |
| v0.30.x | skipped-unverified | — | — | — | migrated from #55, #54 |
| v0.29.25 | skipped-unverified | — | — | — | migrated from #41 |
| v0.29.x (legacy) | skipped-unverified | — | — | — | migrated from #15, #16, #18, #21, #22, #27, #32, #43, #44, #45, #52, #53 |
| v0.29.x (round-2) | **completed** | 2026-05-06 | 40 reported findings | #75 captures only a subset of statuses | [M1.6 #75](https://github.com/TserenTserenov/FMT-exocortex-template/issues/75) lists 6 `Fixed` (C1–C4, H2–H3) and 3 `To verify` (H1, H4–H5). The full list of 40 and an executable receipt closing them are not present in the available record; `TESTING.md` and the audit report referenced in #75 are not currently delivered. |

Receipts and scope boundaries for these historical records:

- For v0.41.3, the published annotated tag points to `774b08988bbd2dfb16a023d3e1bc2e83f87fd3cf`: [final CI](https://github.com/TserenTserenov/FMT-exocortex-template/actions/runs/37149861369) returned `publishable=true`, [Release](https://github.com/TserenTserenov/FMT-exocortex-template/actions/runs/37150528108) passed. Independent Layer 5 verified calibration 9/9, validator 11/11, clean install 53/53, 792/792 hashes, and ten classes; prior #1060/#1061 and #1067 on the exact tag produced green controls, and the prior detector bypass remains tracked in #1006. Layer 6 updated a single-use v0.41.2 installation to v0.41.3 via the real release channel: 792/792 files and four synthetic user markers preserved the required hashes, bytes, and modes; re-run with service-manager stubs was unchanged (797 files/markers). On the delivered Projection, the #1067 test produced 59 passes against 33 expected failures on v0.41.2. During the first update, the `boundary-guard.sh` wrapper did not intercept host-global `launchctl`; a safe red control with a stub confirms the channel but not modification of an existing service. Layer 6 therefore returned BLOCKED; a separate issue #1072 is open. macOS smoke with real `launchctl`, live WSL/systemd, and a personal installation were not tested. #1071 remains open; a STABLE status for the full release has not been assigned.
- For v0.41.2, the published annotated tag `77fe2f2d7d26743f1dd73c1ae0f5ee47b6f7da9b` was verified — not a PR candidate: a new independent reviewer completed all 10 classes of the post-release prompt, boundary wrapper calibration 9/9, validator 11/11, and clean-install smoke 53/53; two delivery Projections matched 792/792 manifest SHAs. A separate reviewer updated a single-use core installation from v0.41.1 to v0.41.2 via the real release channel: 7 files changed, 1 deleted, three synthetic user markers preserved content, size, and permissions; a re-run made no updates and again confirmed 792 SHAs. Prior red controls for #1060/#1061 on the delivered files turned green. However, a new red control for #1067 detected a false-green Scheduler/triage status after `FAILED`/`GAVE UP` on the weekly review and `dispatch completed`; a clean log also shows green, and adding `WARN` makes the defective log red. The [main CI receipt](https://github.com/TserenTserenov/FMT-exocortex-template/actions/runs/37144719175/job/111268303582) reports `publishable=true` for the exact SHA but does not cover this path. Both layers therefore returned BLOCKED; no exception was accepted; a separate issue #1067 is open. The temporary core fixture did not invoke host-global launchd, a real LLM, live WSL/systemd, or a full Windows installation; the optional extractor backfill warned about a missing LaunchAgents directory inside the fixture HOME. The Layer 6 reviewer had previously reviewed the release PR but did not write its code.
- For v0.41.1, the published tag faccdf3c7fa1429145de4d9bd43c65ed78788b95 was verified: boundary wrapper calibration, 11/11 integration checks, 53/53 clean-install checks, and 3/3 detector fixtures; all 791 manifest hashes matched. A single-use v0.41.0 installation updated successfully via the real release channel: 75 changes, 1 deletion, three user markers preserved; a second run reported no updates. The [exact CI receipt](https://github.com/TserenTserenov/FMT-exocortex-template/actions/runs/37139099577) considers the release tree publishable but does not cover the discovered cases: #1060 received a red control (a v0.41.0 error log shows white status; v0.41.1 shows green), and #1061 received a red control for a required file absent from a manifest-only installation. No fixed green candidate or owner-accepted exception exists for either, so the result is BLOCKED; closure of #1059 is deferred. On the final push, the macOS job was normally skipped, but two macOS jobs passed on the [PR tree matching the tag](https://github.com/TserenTserenov/FMT-exocortex-template/actions/runs/37137661479). Windows/Git Bash was verified only by targeted CI jobs; WSL2 and live Linux systemd were not tested; no separate signed attestation is provided by this audit.
- For F1 from the early v0.40.0 run, #779 added
  `setup/detector-fixtures/detector_07/positive_quoted_literal.md`: the prior
  regex did not catch the sample; the current `setup/test-detectors.sh` passes 3 of 3
  fixtures. F2 — link removal with no separate executable check. F3 —
  correction of current descriptions in #1024; the old reminder text in #748 remains
  historical. F4 requires per-file justification for `substituted` or a control:
  the contract itself permits a file without `{{}}` if it is intended to live in the workspace.
  F5 — the false warn gate promise was removed in #1024; the gate itself does not exist. The decision
  to remove `/lesson-close` was accepted and delivered in #845; no separate red and green
  control for this finding was recorded.
- For v0.41.0, #999 reproduced exit code 49 on the old `update.sh`, then ran
  `scripts/tests/test_issue_541_workspace_base.sh` (142 checks and 7 red
  mutants). #1000 verified `strategy-session` with the test
  `scripts/tests/test_issue_969_strategy_session_isolated_copy.sh`
  (3 red mutants, green candidate); a full test of the old release is not proven by this. #1001 verified YAML and code but not live bot delivery or
  deduplication. #1002–#1006 remain open — not as accepted exceptions.
- The four important findings from the v0.41.0 external run received separate issues:
  migration path #1036, `core.fileMode=false` #1037, Python literals #1038,
  Linux systemd #1039. Migration #1036 was fixed in main via #1041 with verification against an old installation; Python paths #1038 were fixed in main via #1040 and closed:
  these are author scripts outside the user Manifest. #1037 was fixed in main
  via #1042 after red reproduction and end-to-end verification; #1039 remains open.
  These fixes in main have not yet been delivered in a new release. None of the items received
  an accepted exception or a completed installation verification here.
- For #559, the v0.39.0 defect was confirmed by code review in #576; v0.39.1 passed
  a manual test after #575. A regression test for `RC_STEP_SKIPPED` and the lesson-link counter was added to main via #1035; an independent release re-run is not recorded.

## Hidden observation from migrated issues

A spot-check of migrated issues confirmed the adversarial audit of 2026-05-06 itself
with 40 reported findings (#75), so its status here is `completed`.
However, #75 does not prove that all 40 were fixed: it lists six `Fixed`
and three `To verify`. The full finding registry and executable receipts closing them
are not delivered in the current tree; the prior claim "all fixed" is retracted.

## Future use

- Each verified release → one row in this table. The workflow issue serves as
  a reminder and does not replace the result record or the separate open issues
  for unresolved material findings.
- There is currently no automated warning when a release is made without a record in this table:
  `verify-before-promote.sh` is absent from the template tree.
- Quarterly — review the log: any `skipped-unverified` entry older than 90 days → make a decision (run-now / accept-debt / wontfix).

## Related

- `.github/workflows/post-release-audit.yml` — reminder issue creation
- `setup/integration-contract-validator.sh` and `setup/test-detectors.sh` —
  current detectors and their fixtures
- Peer-session 2026-06-01-18 (author governance repo) — migration from 22 open issues