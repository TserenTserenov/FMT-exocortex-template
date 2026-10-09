# Release Audit Log

> Log of post-release adversarial audit results. The workflow
> `.github/workflows/post-release-audit.yml` creates a reminder issue
> automatically on push of `update-manifest.json` to main with version x.y.0;
> for patch releases, trigger it manually.
> Record audit results here. Each unresolved material finding requires a
> separate open issue with a link from the audit result.
> The preventive `verify-before-promote.sh` is not implemented.

## Purpose

Adversarial audit — the reviewer searches for regressions outside existing detectors,
installation checks, and `promote-checks` (`validate-fmt-scripts.sh`). The number
of checks performed is taken from the receipt of the exact verified commit.

Each material confirmed finding receives a link to an executable
detector, fixture, or environment test with a red control on the defective artifact
and a green result on the candidate. If no such control exists, the product owner or
designated release approver — not the finding author — explicitly accepts the waiver.
The record must contain a permanent link to that decision in an issue, PR, or decision
record, along with the scope, rationale, and revision condition.
A proposed but unaccepted waiver leaves the finding open. Each
unresolved material finding receives a separate open issue in this
repository and a link to it in the audit result. The audit reminder may only be
closed after those issues are created; closing the reminder does not close the findings.
An individual audit record may be completed, but it does not by itself close the
identified defect.

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
| `findings` | Finding count or `—` |
| `result` | Cross-reference: PR/commit/issue with fixes or `—` |
| `notes` | Migration source or additional info |

Example of applying a confirmed finding: a false free plan on morning pipeline failure (#983) led to real-run checks in `scripts/tests/test_issue_983_morning_alarm.sh` via PR #992. An independent re-run of the test from the PR on the merge parent of #992 exited with code 1 and 64 failures (including free prompt on pipeline failure); on the merge commit of #992 it exited with code 0, 90 checks passing, 0 failures. The live scheduler and Linux, which were not verified, are noted separately in the PR. This receipt covers only the free fallback plan and alarm delivery: other sub-items of #983, including scaffold build without a model gateway, do not follow from it. It does not prove coverage of all prior findings.

## Log

| Version | Status | Date | Findings | Result | Notes |
|---------|--------|------|----------|--------|-------|
| unreleased@893bf1cd | **completed** | 2026-10-09 | 1 new low (F1) [#1171](https://github.com/TserenTserenov/FMT-exocortex-template/issues/1171); v0.41.6 debt (#1104, #1106–#1108) resolved | Layer 6: CAUTION | Unplanned audit at pilot request (not an x.y.0 reminder): 56 commits after v0.41.6/v0.41.7, 18 fix commits — above the ≤5 threshold (`docs/RELEASE-PROCESS.md`). Mandatory gates, both validators (11/11, 55/55), manifest 803/803, calibration 21/21, all prior audit debt — clean and confirmed by tests on commit `893bf1cd`. F1 (new) — migration #1132 (`inbox/WP-425/` → `.cache/`) does not clean up the old file on already-affected installations; reproduced in code (`_resolve_snapshot_path()` leaves the old path untouched), visual clutter with no impact on functionality or security, [#1171](https://github.com/TserenTserenov/FMT-exocortex-template/issues/1171). The smoldering (not new) F2 class from the v0.40.0 audit was noted again — 8/25 `substituted` files without `{{X}}`; the contract has already accepted this as permissible. |
| v0.41.6 | **completed** | 2026-10-05 | 5 material findings: F1 high (process), F2–F3 medium, F4 medium-low, F5 low-medium — [#1104](https://github.com/TserenTserenov/FMT-exocortex-template/issues/1104), [#1105](https://github.com/TserenTserenov/FMT-exocortex-template/issues/1105), [#1106](https://github.com/TserenTserenov/FMT-exocortex-template/issues/1106), [#1107](https://github.com/TserenTserenov/FMT-exocortex-template/issues/1107), [#1108](https://github.com/TserenTserenov/FMT-exocortex-template/issues/1108) | [Layer 6: CAUTION](https://github.com/TserenTserenov/FMT-exocortex-template/issues/1087#issuecomment-5993311098) | On tag 4ee4fef4: manifest/tag/release consistent (793/0/0), clean install and upgrade 0.41.5→0.41.6 green, no product P0/P1. F1 — fixture `test_issues_919_920_929_day_open.sh` without `strategy_day` hits the `monday` default and marks the mandatory `validate`/`release-receipt` red specifically on Mondays (regardless of product); fix (`DAY_OPEN_FORCE_STRATEGY_DAY=1`) applied and confirmed green in #1103 the same day, revision condition — scheduled main run on 2026-10-06. F2 — fresh install does not receive `memory/reference/agent-core.md`. F3 — detector 7 false-green on 5 governance-repo hardcode mutations. F4 — author constants (`tsekh-1`, `DS-Knowledge-Index`) bypass the author scan. F5 — bare `timeout` without a check on standard macOS. No finding accepted as a waiver; all five remain open pending their fixes. |
| v0.41.5 | **completed** | 2026-10-05 | 7 findings F1–F7, 1 already resolved, 3 new issues, 3 added as evidence to v0.41.6 findings | [Layer 6: CAUTION](https://github.com/TserenTserenov/FMT-exocortex-template/issues/1083#issuecomment-5993362888) | On tag 60341824 (26f0f585): all mandatory gates green, manifest 792/792, fresh install and extension points proven, no P0/P1. F1 — false warning from `update.sh` on large `.iwe-runtime/` directories, already fixed in v0.41.6 (#1084, closed). F2 — `pack-creator-spf-guard.sh` is not registered in any hook loader; the claimed PreToolUse block for SPF/FPF is fail-open, new [#1109](https://github.com/TserenTserenov/FMT-exocortex-template/issues/1109). F3/F4/F5 — same class as the v0.41.6 findings for detector 7 and platform portability, with additional evidence (live hardcode `dt-collect.sh:37`, additional author constants, `flock`/bash-4 without shim) added as comments to [#1106](https://github.com/TserenTserenov/FMT-exocortex-template/issues/1106)/[#1107](https://github.com/TserenTserenov/FMT-exocortex-template/issues/1107)/[#1108](https://github.com/TserenTserenov/FMT-exocortex-template/issues/1108), not duplicated as separate issues. F6 — broken links in delivered skills/memory (setup-wakatime step 3 and others), independently noted by both audits on different tags, new [#1110](https://github.com/TserenTserenov/FMT-exocortex-template/issues/1110). F7 — `{{IWE_ROOT}}`/`{{MEMORY_DIR}}` without a legend in week-close/SKILL.md, new [#1111](https://github.com/TserenTserenov/FMT-exocortex-template/issues/1111). |
| v0.41.4 | **completed** | 2026-10-04 | 0 new material classes; fix [#1072](https://github.com/TserenTserenov/FMT-exocortex-template/issues/1072) confirmed | [Layer 5: STABLE](https://github.com/TserenTserenov/FMT-exocortex-template/issues/1077#issuecomment-5973802411); [Layer 6: CAUTION](https://github.com/TserenTserenov/FMT-exocortex-template/issues/1077#issuecomment-5973803726) | Published tag 41da1331 matched main CI and receipt publishable=true. Calibration 21/21; red/green control #1072 12/12. One-shot install v0.41.3→v0.41.4 via real release channel: 8 files updated, 1 deleted, 792/792 hashes and modes matched, 5 synthetic personalizations preserved, re-run with no updates. No service manager calls made. The shell wrapper does not replace a VM for an absolute service manager call or PATH substitution; personal acceptance note Ph96 is open. |
| v0.41.3 | **completed** | 2026-10-03 | 1 material audit-boundary defect [#1072](https://github.com/TserenTserenov/FMT-exocortex-template/issues/1072); 0 new confirmed behavioral defects for #1067 | [Layer 5: 0 new material](https://github.com/TserenTserenov/FMT-exocortex-template/issues/1071#issuecomment-5973120428); [Layer 6: BLOCKED](https://github.com/TserenTserenov/FMT-exocortex-template/issues/1071#issuecomment-5973157100) | On published tag 774b0898, fix #1067 passed on the delivered copy; upgrade v0.41.2→v0.41.3 via real release channel preserved synthetic user files. The one-shot audit wrapper missed host-global `launchctl` calls; host service modification was not proven. #1071 retains its historical BLOCKED status; fix #1072 and safe re-run recorded for v0.41.4. Legacy #1002/#1005/#1006/#1032 remain open. |
| v0.41.2 | **completed** | 2026-10-03 | 1 new material P1 [#1067](https://github.com/TserenTserenov/FMT-exocortex-template/issues/1067) | [Layer 5: BLOCKED](https://github.com/TserenTserenov/FMT-exocortex-template/issues/1066#issuecomment-5972449899); [Layer 6: BLOCKED](https://github.com/TserenTserenov/FMT-exocortex-template/issues/1066#issuecomment-5972436902) | On published tag 77fe2f2d, after two week-review failures, the delivered DayPlan shows a false green status even though the report was not delivered. CI receipt is green but did not cover this case. #1066 remains open until the fix and independent re-verification; prior #1006 is also open. |
| v0.41.1 | **completed** | 2026-10-03 | 2 material findings: P1 #1060, P2 #1061 | [Layer 6: BLOCKED](https://github.com/TserenTserenov/FMT-exocortex-template/issues/1059#issuecomment-5971646785) | [Layer 5: 2 classes found](https://github.com/TserenTserenov/FMT-exocortex-template/issues/1059#issuecomment-5971645767) on tag faccdf3c: release receipt green, but the installed Day Open falsely marks a scheduler failure as green and a required map was not delivered to the platform skill. Both issues open; #1059 not closed. |
| v0.41.0 | **completed** | 2026-10-02 | 0 blockers; 2 important release regressions, prior findings and notification defects | "No blockers" per [pilot run](https://github.com/TserenTserenov/FMT-exocortex-template/issues/998#issuecomment-5949272475) | Pilot run #998: two regressions fixed by #999 and #1000; notifications — #1001 with limited verification; prior findings — open #1002–#1006. Release and upgrades verified in sandbox as noted in #998; these checks do not close the individual findings. |
| v0.41.0 | **completed** | 2026-10-02 | 0 blockers; 4 important and 3 nice-to-have (reported separately) | "Not STABLE" per external reviewer; independent re-run not recorded | [Separate fork user comment](https://github.com/TserenTserenov/FMT-exocortex-template/issues/998#issuecomment-5949629589): WSL2, upgrade 0.40.2→0.41.0, `core.fileMode=false`. Migration path outside manifest, loss of `+x`, Python literals, and Linux systemd; do not aggregate numbers with the pilot run or treat these items as closed by that decision. |
| v0.40.0 | **completed** | 2026-09-10 | 0 blockers, 0 important, 5 nice-to-have (F1–F5) | STABLE per [first run](https://github.com/TserenTserenov/FMT-exocortex-template/issues/748#issuecomment-5613470222) | F1 — detector gap, F2 — two dead links, F3 — stale names and counters, F4 — 7 of 24 `substituted` files without `{{}}`, F5 — reference to a non-existent warn gate. This is a separate early assessment, without the YooKassa false alarm and NixOS. |
| v0.40.0 | **completed** | 2026-09-10 | 1 initial false alarm and 4 confirmed items | STABLE after technical follow-up per [late pilot run](https://github.com/TserenTserenov/FMT-exocortex-template/issues/748#issuecomment-5619310904) | YooKassa false "leak" — documented fail-closed behavior. #779 removed dead links, expanded DETECTOR_07, and fixed smoke on NixOS (was 23 PASS/4 FAIL, now 49/0). The fourth item, `/lesson-close` without `/lesson`, moved to #778 and resolved by the pilot later in #845, not in #779. |
| v0.39.0 | **completed** | 2026-08-30 | 1 blocking regression #559 | BLOCKED, release replaced by v0.39.1 | [Run #576](https://github.com/TserenTserenov/FMT-exocortex-template/issues/576#issuecomment-5467737058): `RC_STEP_SKIPPED` was not displayed in `main()` Day Close; an optional skip returned code 1. Fix #575. |
| v0.39.1 | **completed** | 2026-08-30 | 0 new P0/P1 in the verified fix | GO per [run #576](https://github.com/TserenTserenov/FMT-exocortex-template/issues/576#issuecomment-5467737058) | Release #577 after #575; audit performed by the fix author with pilot permission, independent re-run recommended only. #588 separately recorded the delta assessment for personal-guide #585/#586, but no executable receipt is available for the 3 prior minor observations noted there; do not treat this as an independent release re-run. |
| v0.34.1 | skipped-unverified | — | — | — | migrated from #133 |
| v0.34.0 | skipped-unverified | — | — | — | migrated from #130 |
| v0.33.x | skipped-unverified | — | — | — | migrated from #129, #127 |
| v0.32.x | skipped-unverified | — | — | — | migrated from #126, #123 |
| v0.31.x | skipped-unverified | — | — | — | migrated from #117 |
| v0.30.x | skipped-unverified | — | — | — | migrated from #55, #54 |
| v0.29.25 | skipped-unverified | — | — | — | migrated from #41 |
| v0.29.x (legacy) | skipped-unverified | — | — | — | migrated from #15, #16, #18, #21, #22, #27, #32, #43, #44, #45, #52, #53 |
| v0.29.x (round-2) | **completed** | 2026-05-06 | 40 claimed findings | #75 records only a subset of statuses | [M1.6 #75](https://github.com/TserenTserenov/FMT-exocortex-template/issues/75) lists 6 `Fixed` (C1–C4, H2–H3) and 3 `To verify` (H1, H4–H5). The full list of 40 and an executable receipt for their closure are not present in the available record; `TESTING.md` and the audit report referenced in #75 are not currently delivered. |

Receipts and boundaries for these historical records:

- For v0.41.3 the published annotated tag points to `774b08988bbd2dfb16a023d3e1bc2e83f87fd3cf`: the [final CI](https://github.com/TserenTserenov/FMT-exocortex-template/actions/runs/37149861369) returned `publishable=true` and the [Release](https://github.com/TserenTserenov/FMT-exocortex-template/actions/runs/37150528108) passed. The independent layer 5 verified calibration 9/9, validator 11/11, clean install 53/53, 792/792 hashes, and ten classes; prior red controls for #1060/#1061 and #1067 on the exact tag turned green, and the prior detector bypass remains in #1006. Layer 6 performed a one-shot upgrade of v0.41.2 to v0.41.3 via the real release channel: 792/792 files and four synthetic user markers retained the expected hashes, bytes, and modes; a re-run with service manager stubs produced no changes (797 files/markers). On the delivered projection, test #1067 produced 59 passes against 33 expected failures on v0.41.2. During the first upgrade the `boundary-guard.sh` wrapper did not intercept host-global `launchctl`; a safe red control with a stub confirms the channel but not modification of an existing service. Layer 6 therefore returned BLOCKED; separate issue #1072 is open. macOS smoke with real `launchctl`, live WSL/systemd, and a personal install were not verified. #1071 remains open; STABLE status has not been assigned to this release.
- For v0.41.2 the published annotated tag `77fe2f2d7d26743f1dd73c1ae0f5ee47b6f7da9b` was verified — not the PR candidate: a new independent reviewer passed all 10 classes of the post-release prompt, wrapper calibration 9/9, validator 11/11, and clean install smoke 53/53; two delivery projections matched 792/792 manifest SHA values. A separate reviewer upgraded a one-shot core install of v0.41.1 to v0.41.2 via the real release channel: 7 files changed, 1 deleted, three synthetic user markers retained their content, size, and permissions; a re-run updated nothing and confirmed 792 SHA values again. Prior red controls for #1060/#1061 on delivered files turned green. However, a new red control for #1067 identified a false-green Scheduler/triage status after `FAILED`/`GAVE UP` on the weekly review and `dispatch completed`; a clean log also returns green, and adding `WARN` makes the defective log red. The [main CI receipt](https://github.com/TserenTserenov/FMT-exocortex-template/actions/runs/37144719175/job/111268303582) reports `publishable=true` for the exact SHA but does not cover this path. Both layers therefore returned BLOCKED; no waiver was accepted; separate issue #1067 is open. The temporary core fixture did not invoke host-global launchd, a real LLM, live WSL/systemd, or a full Windows install; the optional extractor backfill warned about a missing LaunchAgents directory inside the fixture HOME. The layer 6 reviewer previously reviewed the release PR but did not write its code.
- For v0.41.1 the published tag faccdf3c7fa1429145de4d9bd43c65ed78788b95 was verified: wrapper calibration, 11/11 integration checks, 53/53 clean install checks, and 3/3 detector fixtures; all 791 manifest hashes matched. A one-shot install of v0.41.0 upgraded successfully via the real release channel: 75 changes, 1 deletion, three user markers preserved; a second run reported no updates. The [exact CI receipt](https://github.com/TserenTserenov/FMT-exocortex-template/actions/runs/37139099577) considers the release tree publishable but does not cover the discovered cases: #1060 received a red control (v0.41.0 shows white status on an error log, v0.41.1 shows green), and #1061 received a red control for a required file in a manifest-only install. No fixed green candidate or owner-accepted waiver exists for these findings, so the result is BLOCKED; closing #1059 is deferred. On the final push the macOS job was skipped normally, but two macOS jobs passed on the [PR tree matching the tag](https://github.com/TserenTserenov/FMT-exocortex-template/actions/runs/37137661479). Windows/Git Bash was verified only through point CI jobs; WSL2 and live Linux systemd were not verified; no separate signed attestation is provided by this audit.
- For F1 from the early v0.40.0 run, #779 added
  `setup/detector-fixtures/detector_07/positive_quoted_literal.md`: the prior
  regex did not catch the sample; the current `setup/test-detectors.sh` passes 3 of 3
  fixtures. F2 — link removal without a separate executable check; F3 —
  current descriptions corrected in #1024, the old reminder text in #748 remains
  historical. F4 requires per-file justification of `substituted` or a control:
  the contract itself permits a file without `{{}}` if it is meant to live in the workspace.
  F5 — the false warn gate promise was removed in #1024; the gate itself does not exist. The decision
  to remove `/lesson-close` was accepted and delivered in #845; no separate red and green
  check was recorded for this finding.
- For v0.41.0, #999 reproduced exit code 49 on the old `update.sh`, then ran
  `scripts/tests/test_issue_541_workspace_base.sh` (142 checks and 7 red
  mutants). #1000 verified `strategy-session` with test
  `scripts/tests/test_issue_969_strategy_session_isolated_copy.sh`
  (3 red mutants, green candidate); full testing of the old release is not proven by this. #1001 verified YAML and code, but not live bot delivery or
  deduplication. #1002–#1006 remain open, not accepted as waivers.
- The four important findings from the external v0.41.0 run received separate issues:
  migration path #1036, `core.fileMode=false` #1037, Python literals #1038,
  Linux systemd #1039. Migration #1036 was fixed in main via #1041 with verification on an old install; Python paths #1038 were fixed in main via #1040 and closed:
  these are author scripts outside the user manifest. #1037 was fixed in main
  via #1042 after red reproduction and end-to-end verification; #1039 remains open.
  The fixes from main have not yet been delivered in a new release. None of these items received
  an accepted waiver or completed install-release verification here.
- For #559 the v0.39.0 defect was confirmed by code review in #576; v0.39.1 passed
  a manual smoke test after #575. A regression test for `RC_STEP_SKIPPED` and the lesson-reference counter was added to main via #1035; an independent release re-run was not recorded.

## Hidden Observation From Migrated Issues

A spot-check of migrated issues confirmed the adversarial audit itself from 2026-05-06
with 40 claimed findings (#75), so its status here is `completed`.
However, #75 does not prove that all 40 were fixed: it lists six `Fixed`
and three `To verify`. The full finding registry and their executable receipts are not
delivered in the current tree; the prior claim that "all were fixed" is retracted.

## Further Use

- Each verified release → one row in this table. The workflow issue serves as
  a reminder and does not replace the result record or the separate open issues
  for unresolved material findings.
- There is currently no automated warning when a release is published without a record in this table: `verify-before-promote.sh` is not present in the template tree.
- Quarterly — review log: `skipped-unverified` entries older than 90 days → make a decision (run-now / accept-debt / wontfix).

## Related

- `.github/workflows/post-release-audit.yml` — reminder issue creation
- `setup/integration-contract-validator.sh` and `setup/test-detectors.sh` —
  current detectors and their fixtures
- Peer-session 2026-06-01-18 (author governance repo) — migration from 22 open issues