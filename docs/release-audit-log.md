# Release Audit Log

> Log of post-release adversarial audit results. The workflow
> `.github/workflows/post-release-audit.yml` creates a reminder issue
> automatically on push of `update-manifest.json` to main with version x.y.0;
> for patch releases, it runs manually.
> Record the audit result here. Each unresolved significant finding requires
> a separate open issue with a link from the audit result.
> The warning `verify-before-promote.sh` is not implemented.

## Purpose

Adversarial audit — the reviewer searches for regressions outside the current detectors,
install checks, and `promote-checks` (`validate-fmt-scripts.sh`). The number of
checks performed comes from the receipt of the exact verified commit.

Each significant confirmed finding gets a link to an executable
detector, fixture, or environment test with a red control on the defective artifact
and a green result on the candidate. If no such control exists, the product owner or
the designated release approver — not the finding's author — explicitly accepts the
exception. The record must contain a permanent link to that decision
in an issue, PR, or decision record, along with the scope, rationale, and revision condition.
A proposed but unaccepted exception leaves the finding open. Each
unresolved significant finding gets a separate open issue in this
repository and a link to it in the audit result. The audit reminder may only be
closed after those issues are created; closing it does not close the findings.
An individual audit record may be completed, but does not itself close the found defect.

## Process

```
push update-manifest.json to main, version x.y.0 → reminder issue created automatically
patch → reminder issue on manual workflow trigger
audit → record result here; unresolved significant finding → open issue
```

| Field | Description |
|-------|-------------|
| `version` | Release tag (vX.Y.Z) |
| `status` | `pending` / `in-progress` / `completed` / `skipped-unverified` |
| `date` | Audit date (YYYY-MM-DD) or `—` |
| `findings` | Finding count or `—` |
| `result` | Cross-reference: PR/commit/issue with fixes or `—` |
| `notes` | Migration source or additional info |

Example of applying to a confirmed finding: a false free plan on morning Pipeline failure (#983) led to real-run checks in `scripts/tests/test_issue_983_morning_alarm.sh` in PR #992. An independent replay of the test from PR on the merge parent of #992 exited with code 1 and 64 failures (including a free prompt on Pipeline failure); on the merge commit of #992 it exited with code 0, 90 successful checks, 0 failures. The live scheduler and Linux, not verified, are noted separately in the PR. This receipt covers only the free fallback plan and alarm delivery: other sub-items of #983, including scaffold build without a model gateway, are not implied by it. It does not prove coverage of all prior findings.

## Log

| Version | Status | Date | Findings | Result | Notes |
|---------|--------|------|----------|--------|-------|
| v0.41.6 | **completed** | 2026-10-05 | 5 significant: F1 high (process), F2–F3 medium, F4 medium-low, F5 low-medium — [#1104](https://github.com/TserenTserenov/FMT-exocortex-template/issues/1104), [#1105](https://github.com/TserenTserenov/FMT-exocortex-template/issues/1105), [#1106](https://github.com/TserenTserenov/FMT-exocortex-template/issues/1106), [#1107](https://github.com/TserenTserenov/FMT-exocortex-template/issues/1107), [#1108](https://github.com/TserenTserenov/FMT-exocortex-template/issues/1108) | [Layer 6: CAUTION](https://github.com/TserenTserenov/FMT-exocortex-template/issues/1087#issuecomment-5993311098) | On tag 4ee4fef4: manifest/tag/release are consistent (793/0/0), clean install and upgrade 0.41.5→0.41.6 are green, no product P0/P1. F1 — fixture `test_issues_919_920_929_day_open.sh` without `strategy_day` hits the `monday` default and marks the required `validate`/`release-receipt` red specifically on Mondays (regardless of product); fix (`DAY_OPEN_FORCE_STRATEGY_DAY=1`) applied and confirmed green in #1103 the same day, revision condition — scheduled main run on 06.10. F2 — fresh install does not receive `memory/reference/agent-core.md`. F3 — detector 7 is false-green on 5 hardcode governance-repo mutations. F4 — author constants (`tsekh-1`, `DS-Knowledge-Index`) bypass author-scan. F5 — bare `timeout` without a check on standard macOS. No finding is accepted as an exception; all five remain open until their respective fixes. |
| v0.41.5 | **completed** | 2026-10-05 | 7 findings F1–F7, 1 already resolved, 3 new issues, 3 added as evidence to v0.41.6 findings | [Layer 6: CAUTION](https://github.com/TserenTserenov/FMT-exocortex-template/issues/1083#issuecomment-5993362888) | On tag 60341824 (26f0f585): all required gates are green, manifest 792/792, fresh install and extension points verified, no P0/P1. F1 — false warning from `update.sh` on large `.iwe-runtime/`, already fixed in v0.41.6 (#1084, closed). F2 — `pack-creator-spf-guard.sh` is not registered in any hook loader, the claimed PreToolUse block is SPF/FPF fail-open, new [#1109](https://github.com/TserenTserenov/FMT-exocortex-template/issues/1109). F3/F4/F5 — same class as v0.41.6 findings on detector 7 and platform portability, with additional evidence (live hardcode `dt-collect.sh:37`, additional author constants, `flock`/bash-4 without shim) added as comments to [#1106](https://github.com/TserenTserenov/FMT-exocortex-template/issues/1106)/[#1107](https://github.com/TserenTserenov/FMT-exocortex-template/issues/1107)/[#1108](https://github.com/TserenTserenov/FMT-exocortex-template/issues/1108), not duplicated as separate issues. F6 — broken links in delivered skills/memory (setup-wakatime step 3 and others), independently noted by both audits on different tags, new [#1110](https://github.com/TserenTserenov/FMT-exocortex-template/issues/1110). F7 — `{{IWE_ROOT}}`/`{{MEMORY_DIR}}` without a legend in week-close/SKILL.md, new [#1111](https://github.com/TserenTserenov/FMT-exocortex-template/issues/1111). |
| v0.41.4 | **completed** | 2026-10-04 | 0 new significant classes; fix for [#1072](https://github.com/TserenTserenov/FMT-exocortex-template/issues/1072) confirmed | [Layer 5: STABLE](https://github.com/TserenTserenov/FMT-exocortex-template/issues/1077#issuecomment-5973802411); [layer 6: CAUTION](https://github.com/TserenTserenov/FMT-exocortex-template/issues/1077#issuecomment-5973803726) | Published tag 41da1331 matched main CI and publishable=true receipt. Calibration 21/21; red/green control for #1072 12/12. One-shot install v0.41.3→v0.41.4 via real release channel: 8 files updated, 1 deleted, 792/792 hashes and modes matched, 5 synthetic personalizations preserved, re-run with no updates. No service manager calls. The shell wrapper does not replace a VM for absolute service manager invocation or PATH substitution; personal acceptance of F96 is open. |
| v0.41.3 | **completed** | 2026-10-03 | 1 significant audit boundary defect [#1072](https://github.com/TserenTserenov/FMT-exocortex-template/issues/1072); 0 new confirmed behavioral defects #1067 | [Layer 5: 0 new significant](https://github.com/TserenTserenov/FMT-exocortex-template/issues/1071#issuecomment-5973120428); [layer 6: BLOCKED](https://github.com/TserenTserenov/FMT-exocortex-template/issues/1071#issuecomment-5973157100) | On published tag 774b0898, the fix for #1067 passed on the delivered copy; upgrade v0.41.2→v0.41.3 via real release channel preserved synthetic user files. The one-shot audit boundary wrapper missed host-global `launchctl` calls; host service modification is not proven. #1071 retains the historical BLOCKED status; fix for #1072 and safe replay are recorded for v0.41.4. Old #1002/#1005/#1006/#1032 remain open. |
| v0.41.2 | **completed** | 2026-10-03 | 1 new significant P1 [#1067](https://github.com/TserenTserenov/FMT-exocortex-template/issues/1067) | [Layer 5: BLOCKED](https://github.com/TserenTserenov/FMT-exocortex-template/issues/1066#issuecomment-5972449899); [layer 6: BLOCKED](https://github.com/TserenTserenov/FMT-exocortex-template/issues/1066#issuecomment-5972436902) | On published tag 77fe2f2d, after two week-review failures the delivered DayPlan shows a false green status even though the report was not delivered. CI receipt is green but did not cover this case. #1066 remains open until the fix and independent re-control; prior #1006 is also open. |
| v0.41.1 | **completed** | 2026-10-03 | 2 significant: P1 #1060, P2 #1061 | [Layer 6: BLOCKED](https://github.com/TserenTserenov/FMT-exocortex-template/issues/1059#issuecomment-5971646785) | [Layer 5: 2 classes found](https://github.com/TserenTserenov/FMT-exocortex-template/issues/1059#issuecomment-5971645767) on tag faccdf3c: release receipt is green, but the installed Day Open falsely marks a scheduler failure as green, and the required map is not delivered to the platform skill. Both issues are open; #1059 is not closed. |
| v0.41.0 | **completed** | 2026-10-02 | 0 blockers; 2 important release regressions, prior findings, and notification defects | "No blockers" per [pilot run comment](https://github.com/TserenTserenov/FMT-exocortex-template/issues/998#issuecomment-5949272475) | Pilot run #998: two regressions fixed in #999 and #1000; notifications — #1001 with limited verification; prior findings — open #1002–#1006. Release and upgrades verified in sandbox as noted in #998; those checks do not close the individual findings. |
| v0.41.0 | **completed** | 2026-10-02 | 0 blockers; 4 important and 3 nice-to-have (reported separately) | "Not STABLE" per external reviewer; independent replay not recorded | [Separate fork user comment](https://github.com/TserenTserenov/FMT-exocortex-template/issues/998#issuecomment-5949629589): WSL2, upgrade 0.40.2→0.41.0, `core.fileMode=false`. Migration path outside the manifest, loss of `+x`, Python literals, and Linux systemd; do not combine numbers with the pilot run or treat these items as closed by that decision. |
| v0.40.0 | **completed** | 2026-09-10 | 0 blockers, 0 important, 5 nice-to-have (F1–F5) | STABLE per [first run](https://github.com/TserenTserenov/FMT-exocortex-template/issues/748#issuecomment-5613470222) | F1 — detector gap, F2 — two dead links, F3 — stale names and counters, F4 — 7 of 24 `substituted` without `{{}}`, F5 — reference to a non-existent warn gate. This is a separate early Assessment, without the YooKassa and NixOS false alarm. |
| v0.40.0 | **completed** | 2026-09-10 | 1 initial false alarm and 4 confirmed items | STABLE after technical follow-up per [late pilot run](https://github.com/TserenTserenov/FMT-exocortex-template/issues/748#issuecomment-5619310904) | The YooKassa "leak" was a documented fail-closed behavior. #779 removed dead links, expanded DETECTOR_07, and fixed smoke on NixOS (was 23 PASS/4 FAIL, now 49/0). The fourth item, `/lesson-close` without `/lesson`, was filed as #778 and resolved by the pilot later in #845, not in #779. |
| v0.39.0 | **completed** | 2026-08-30 | 1 blocking regression #559 | BLOCKED, release replaced by v0.39.1 | [Run #576](https://github.com/TserenTserenov/FMT-exocortex-template/issues/576#issuecomment-5467737058): `RC_STEP_SKIPPED` was not displayed in `main()` Day Close; an optional skip produced exit code 1. Fix #575. |
| v0.39.1 | **completed** | 2026-08-30 | 0 new P0/P1 in verified fix | GO per [run #576](https://github.com/TserenTserenov/FMT-exocortex-template/issues/576#issuecomment-5467737058) | Release #577 after #575; audit performed by the fix author with pilot permission, independent replay only recommended. #588 separately recorded the delta Assessment for personal-guide #585/#586, but no executable receipt is available for the 3 prior minor observations stated there; do not treat this as an independent release replay. |
| v0.34.1 | skipped-unverified | — | — | — | migrated from #133 |
| v0.34.0 | skipped-unverified | — | — | — | migrated from #130 |
| v0.33.x | skipped-unverified | — | — | — | migrated from #129, #127 |
| v0.32.x | skipped-unverified | — | — | — | migrated from #126, #123 |
| v0.31.x | skipped-unverified | — | — | — | migrated from #117 |
| v0.30.x | skipped-unverified | — | — | — | migrated from #55, #54 |
| v0.29.25 | skipped-unverified | — | — | — | migrated from #41 |
| v0.29.x (legacy) | skipped-unverified | — | — | — | migrated from #15, #16, #18, #21, #22, #27, #32, #43, #44, #45, #52, #53 |
| v0.29.x (round-2) | **completed** | 2026-05-06 | 40 claimed findings | #75 records only a subset of statuses | [M1.6 #75](https://github.com/TserenTserenov/FMT-exocortex-template/issues/75) lists 6 `Fixed` (C1–C4, H2–H3) and 3 `To verify` (H1, H4–H5). The full list of 40 and executable receipts for their closure are not present in the current tree; the prior claim "all fixed" is retracted. |

Receipts and boundaries for these historical records:

- For v0.41.3 the published annotated tag points to `774b08988bbd2dfb16a023d3e1bc2e83f87fd3cf`: [final CI](https://github.com/TserenTserenov/FMT-exocortex-template/actions/runs/37149861369) returned `publishable=true`, [Release](https://github.com/TserenTserenov/FMT-exocortex-template/actions/runs/37150528108) passed. Independent layer 5 verified calibration 9/9, validator 11/11, clean install 53/53, 792/792 hashes, and ten classes; prior red controls for #1060/#1061 and #1067 on the exact tag turned green, the prior detector bypass remains in #1006. Layer 6 upgraded a one-shot install of v0.41.2 via real release channel to v0.41.3: 792/792 files and four synthetic user markers retained the required hashes, bytes, and modes; replay with service manager stubs was unchanged (797 files/markers). On the delivered projection, the test for #1067 yielded 59 passes against 33 expected failures on v0.41.2. On the first upgrade the `boundary-guard.sh` wrapper did not intercept host-global `launchctl`; a safe red control with a stub confirms the channel but not modification of an existing service. Layer 6 therefore returned BLOCKED, no exception was accepted, and separate issue #1072 was opened; macOS smoke with real `launchctl`, live WSL/systemd, and a personal install were not verified. #1071 remains open; STABLE status for the full release was not assigned.
- For v0.41.2 the published annotated tag `77fe2f2d7d26743f1dd73c1ae0f5ee47b6f7da9b` was verified, not the PR candidate: a new independent reviewer passed all 10 classes of the post-release prompt, boundary wrapper calibration 9/9, validator 11/11, and clean install smoke 53/53; two delivery projections matched 792/792 SHA entries in the manifest. A separate reviewer upgraded a one-shot core install of v0.41.1 via real release channel to v0.41.2: 7 files changed, 1 deleted, three synthetic user markers preserved content, size, and permissions; a re-run made no updates and confirmed 792 SHAs again. Prior red controls for #1060/#1061 on delivered files turned green. However, a new red control for #1067 revealed a false-green Scheduler/triage state after `FAILED`/`GAVE UP` in a weekly review and `dispatch completed`; a clean log is also green, and adding `WARN` makes the defective log red. The [main CI receipt](https://github.com/TserenTserenov/FMT-exocortex-template/actions/runs/37144719175/job/111268303582) reports `publishable=true` for the exact SHA but does not cover this path. Both layers therefore returned BLOCKED, no exception was accepted, and separate issue #1067 was opened. The temporary core fixture did not invoke host-global launchd, a real LLM, live WSL/systemd, or a full Windows install; the optional extractor backfill warned about a missing LaunchAgents directory inside the fixture HOME. The layer 6 reviewer had previously reviewed the release PR but did not write its code.
- For v0.41.1 the published tag faccdf3c7fa1429145de4d9bd43c65ed78788b95 was verified: boundary wrapper calibration, 11/11 integration checks, 53/53 clean install checks, and 3/3 detector fixtures; all 791 manifest hashes matched. A one-shot install of v0.41.0 successfully upgraded via the real release channel: 75 changes, 1 deletion, three user markers preserved; the second run reported no updates. The [exact CI receipt](https://github.com/TserenTserenov/FMT-exocortex-template/actions/runs/37139099577) considers the tree releasable but does not cover the discovered cases: #1060 received a red control (the v0.41.0 error log shows white status, v0.41.1 shows green), #1061 — a red control for the required file in a manifest-only install. No fixed green candidate or owner-accepted exception exists for either, so the result is BLOCKED; closing of #1059 is deferred. On the final push the macOS job was skipped as expected, but two macOS jobs passed on the [PR tree matching the tag](https://github.com/TserenTserenov/FMT-exocortex-template/actions/runs/37137661479). Windows/Git Bash was verified only by spot-check CI jobs; WSL2 and live Linux systemd were not verified; no separate signed attestation is provided by this audit.
- For F1 from the early v0.40.0 run, #779 added
  `setup/detector-fixtures/detector_07/positive_quoted_literal.md`: the prior
  regex did not catch the sample, the current `setup/test-detectors.sh` passes 3 of 3
  fixtures. F2 — link removal with no separate executable check; F3 —
  correction of current descriptions in #1024, the old reminder text in #748 remains
  historical. F4 requires per-file justification for `substituted` or a control:
  the contract itself allows a file without `{{}}` if it is meant to live in the workspace.
  F5 — the false warn gate promise was removed in #1024, the gate itself does not exist. The decision
  to remove `/lesson-close` was accepted and delivered in #845; no separate red and green
  control for this finding was recorded.
- For v0.41.0 #999 reproduced exit code 49 on the old `update.sh`, then ran
  `scripts/tests/test_issue_541_workspace_base.sh` (142 checks and 7 red mutants). #1000 verified `strategy-session` with the test
  `scripts/tests/test_issue_969_strategy_session_isolated_copy.sh`
  (3 red mutants, green candidate); this does not prove a full test of the old release. #1001 verified YAML and code but not live bot delivery and
  deduplication. #1002–#1006 remain open, not accepted as exceptions.
- The four important findings from the external v0.41.0 run received separate issues:
  migration path #1036, `core.fileMode=false` #1037, Python literals #1038,
  Linux systemd #1039. Migration #1036 was fixed in main via #1041 with verification on the old install; Python paths #1038 were fixed in main via #1040 and closed:
  these are author scripts outside the user manifest. #1037 was fixed in main
  via #1042 after red reproduction and end-to-end verification; #1039 remains open.
  The fixes from main have not yet been delivered in a new release. None of the items received
  an accepted exception or a completed installed-release verification here.
- For #559 the v0.39.0 defect was confirmed by code review in #576; v0.39.1 passed
  a manual trial after #575. A regression test for `RC_STEP_SKIPPED` and the lesson reference counter was added to main via #1035; independent release replay is not recorded.

## Hidden Observation From Migrated Issues

A spot-check of migrated issues confirmed the adversarial audit itself from 2026-05-06
with 40 claimed findings (#75), so its status here is `completed`.
However, #75 does not prove all 40 were fixed: it lists six `Fixed`
and three `To verify`. The full finding registry and their executable receipts are not
present in the current tree; the prior claim "all fixed" is retracted.

## Further Use

- Each verified release → one row in this table. The workflow issue serves as
  a reminder and does not replace the result record or separate open issues
  for unresolved significant findings.
- There is currently no automated warning when a release is published without a record in this table: `verify-before-promote.sh` is absent from the template tree.
- Quarterly — review the log: `skipped-unverified` entries older than 90 days → make a decision (run-now / accept-debt / wontfix).

## Related

- `.github/workflows/post-release-audit.yml` — reminder issue creation
- `setup/integration-contract-validator.sh` and `setup/test-detectors.sh` —
  current detectors and their fixtures
- Peer-session 2026-06-01-18 (author governance repo) — Migration from 22 open issues