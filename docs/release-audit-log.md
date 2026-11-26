# Release Audit Log

> Log of post-release adversarial audit results. The workflow
> `.github/workflows/post-release-audit.yml` creates a reminder issue
> automatically on push of `update-manifest.json` to main with version x.y.0;
> for patch releases it is triggered manually.
> This file records the audit result. Each unresolved significant finding
> requires a separate open issue with a link from the audit result.
> The preventive `verify-before-promote.sh` is not implemented.

## Purpose

An adversarial audit — the reviewer searches for regressions outside the current detectors,
installation checks, and `promote-checks` (`validate-fmt-scripts.sh`). The number
of checks performed is taken from the receipt of the exact verified commit.

Each significant confirmed finding receives a link to an executable
detector, fixture, or environment test with a red control on the defective artifact
and a green result on the candidate. If no such control exists, the exception is
explicitly accepted by the product owner or the designated release approver,
not the finding's author. The record must contain a permanent link to that decision
in an issue, PR, or decision record, along with the scope, rationale, and revisit condition.
A proposed but unaccepted exception leaves the finding open. Each
unresolved significant finding receives a separate open issue in this
repository and a link to it in the audit result. The audit reminder may be
closed only after such issues are created; closing the reminder does not close the findings.
An individual audit record may be completed, but it does not by itself close a discovered defect.

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
| `findings` | Number of findings or `—` |
| `result` | Cross-reference: PR/commit/issue with fixes or `—` |
| `notes` | Migration source or additional info |

Example of application to a confirmed finding: a false free plan on morning pipeline failure (#983) led to checks of an actual run in
`scripts/tests/test_issue_983_morning_alarm.sh` in PR #992. An independent
re-run of the test from the PR on the merge parent of #992 exited with code 1 and 64 failures
(including a free prompt on pipeline failure); on the merge commit of #992
it exited with code 0, 90 successful checks, 0 failures. The untested live
scheduler and Linux are noted separately in the PR. This receipt covers only
the free fallback plan and alarm delivery: other sub-items of #983, including
framework assembly without a model gateway, are not implied by it. It does not prove coverage
of all prior findings.

## Log

| Version | Status | Date | Findings | Result | Notes |
|---------|--------|------|----------|--------|-------|
| v0.42.2 | **completed** | 2026-11-26 | 0 blocking; 2 significant: update silently replaces the user's `core.hooksPath` in the management repository (F1) [#1688](https://github.com/iwesys/IWE/issues/1688), editing a platform skill outside USER-SPACE is lost without a backup (F2) [#1689](https://github.com/iwesys/IWE/issues/1689); low: gaps in secret-read-protection allowlists (F3), logged to the release backlog | Attack on the released version (product only, `iwe-platform-redteam`): **CAUTION** | Tag 78ada137 (tree 99f59854 = rc.4). Verified: manifest 895/895, no secrets, checks on the tag commit are green, live update 0.42.1 → v0.42.2 via the release channel on a disposable installation (user extensions, own skills and hooks, Memory, `settings.local.json`, entries in `settings.json`, line in CLAUDE.md, symlink in Memory preserved; modified platform hook saved to `.backups/hooks-pre-update`; re-run changes nothing), new `session-open-gate` exception (11 bypass variants not found), `memory-write-permission`. Accepted exceptions H3, H5, H7, H8, H10 were not revisited. Not verified: Linux, Windows, full installation mode (only `--core`), versions older than 0.42.1, live Claude Code and Kimi, schedulers and Day Open/Day Close in progress, interrupted update and rollback, instruction injection via Memory. F1 and F2 are present in 0.42.1 as well (the code path was not changed) |
| v0.42.1 | **completed** | 2026-11-20 | 0 blocking; 3 medium: #1487 not included in the release (issue open), DeepSeek Harness bridge — installation check by label and leftover after rollback [#1623](https://github.com/iwesys/IWE/issues/1623); low: #1585 entry in CHANGELOG duplicated, announcement sent manually | Attack on dangerous-command check rc.15: **GO** (6 799 commands × 9 versions, 0 executable bypasses softer than before); pre-merge check rc.16: **CAUTION**, exceptions accepted by the Release Owner on 2026-11-20 — [decision form](https://github.com/MimEcoSys/DS-iwe-releases/blob/main/releases/0.N/0.42.1/decisions.md), [rc.16 marks](https://github.com/MimEcoSys/DS-iwe-releases/tree/main/releases/0.N/0.42.1/tests/rc.16) | Tag 492aeaee (tree 8ffebee2 = rc.16). Pre-release checks — independent AI agents (Fable — attack and verification; Codex — code audit; Hermes — review), not code authors. The full iwe-platform-redteam method (rollback to 0.42.0, attack on agent permissions) was not run on rc.16 — accepted exception. Verdict recorded after release as a separate request, as the protocol requires |
| v0.42.0 | **completed** | 2026-11-17 | 4 significant: F1 [#1567](https://github.com/iwesys/IWE/issues/1567), F2 [#1568](https://github.com/iwesys/IWE/issues/1568), F3 [#1569](https://github.com/iwesys/IWE/issues/1569), F4 [#1570](https://github.com/iwesys/IWE/issues/1570); 2 low F5–F6 | [Layer 5: 6 classes found; Layer 6: CAUTION](https://github.com/iwesys/IWE/issues/1556#issuecomment-6940617093) | Tag d14a5ad3 (tree = rc.15): calibration, validators 11/11, manifest 878/878, CI 15/15, upgrade-from-release 4/4, own full-mode 0.41.11→0.42.0 on macOS with 6 synthetic personalizations preserved. F1 — writing to protected files bypassing the check via equivalent paths (`.claude//hooks`); F2 — zeroing a file with a read command bypassing the deny list; F3 — author name in the delivered `scripts/iwe-notify`, the check does not inspect files without an extension; F4 — a pre-authorized onboarding reset removes the WP Gate reminder. F1–F4 reproduced again on the tag. Not verified: Windows, live service activation, host permissions for redirects. Translate Sync fixed in #1564; the security announcement on the tag was not sent. |
| unreleased@2841a0e7 | **completed** | 2026-10-17 | 1 new P1 (dry-run-gate.sh cd-bypass incomplete) [#1258](https://github.com/iwesys/IWE/issues/1258) | Layer 6: **BLOCKED** (on this finding) | Independent audit WP-529 F20 (peer session Claude+Kimi+Codex, the author served as reviewer instead of external reviewer by direct pilot instruction), range v0.41.6→main (219 commits, 13 days of sensitive hook changes). `iwe-platform-redteam` calibration 9/9. Verified: dry-run-gate.sh (#1238 fix) — live `bash -c` confirmed that `\cd`/`"cd"`/`\pushd` physically change the directory and bypass regex detection (ALLOWED with an active sentinel), while the literal form `cd` (the documented PoC from #1238) is correctly blocked and a trusted chain without changes is correctly permitted — no false regression/false positive, the finding is new and independent. destructive-guard.sh (`rm -rf`) — the same techniques (`\rm`, `"rm"`, `\\rm`, `'rm'`, `command rm`) are all correctly blocked (the Perl tokenizer is resilient to this class). pull-on-touch.sh (ff-only without autostash, #1245/#1249) — own smoke test (`pull-on-touch-ff-only-smoke.sh`) passed completely. T50 (WP-529 F96, PR #1255) and `changelog-entry` as a mandatory check (WP-529 F95) — part of the same range, no findings. |
| unreleased@893bf1cd | **completed** | 2026-10-09 | 1 new low (F1) [#1171](https://github.com/iwesys/IWE/issues/1171); v0.41.6 debt (#1104, #1106–#1108) cleared | Layer 6: CAUTION | Unplanned audit at pilot request (not an x.y.0 reminder): 56 commits after v0.41.6/v0.41.7, 18 fix commits — above the threshold of ≤5 (`docs/RELEASE-PROCESS.md`). Mandatory gates, both validators (11/11, 55/55), manifest 803/803, calibration 21/21, all prior audit debt — clean and confirmed by tests on commit `893bf1cd`. F1 (new) — migration #1132 (`inbox/WP-425/` → `.cache/`) does not clean up the old file on already-affected installations; reproduced in code (`_resolve_snapshot_path()` leaves the old path untouched), visual clutter with no functional or security impact, [#1171](https://github.com/iwesys/IWE/issues/1171). The smoldering (not new) F2 class from the v0.40.0 audit was noticed again — 8/25 `substituted` files without `{{X}}`, the contract already accepted this as permissible. |
| v0.41.6 | **completed** | 2026-10-05 | 5 significant: F1 high (process), F2–F3 medium, F4 medium-low, F5 low-medium — [#1104](https://github.com/iwesys/IWE/issues/1104), [#1105](https://github.com/iwesys/IWE/issues/1105), [#1106](https://github.com/iwesys/IWE/issues/1106), [#1107](https://github.com/iwesys/IWE/issues/1107), [#1108](https://github.com/iwesys/IWE/issues/1108) | [Layer 6: CAUTION](https://github.com/iwesys/IWE/issues/1087#issuecomment-5993311098) | On tag 4ee4fef4: manifest/tag/release are consistent (793/0/0), clean installation and update 0.41.5→0.41.6 green, no product P0/P1. F1 — fixture `test_issues_919_920_929_day_open.sh` without `strategy_day` defaults to `monday` and marks the mandatory `validate`/`release-receipt` as failures specifically on Mondays (product-independent); fix (`DAY_OPEN_FORCE_STRATEGY_DAY=1`) applied and confirmed green in #1103 the same day, revisit condition — scheduled main run on 2026-10-06. F2 — fresh installation does not receive `memory/reference/agent-core.md`. F3 — detector 7 false-green on 5 governance-repo hardcode mutations. F4 — author constants (`tsekh-1`, `DS-Knowledge-Index`) bypass the author scan. F5 — bare `timeout` without check on standard macOS. No finding was accepted as an exception; all five remain open until their fixes. |
| v0.41.5 | **completed** | 2026-10-05 | 7 findings F1–F7, 1 already resolved, 3 new issues, 3 added as evidence to v0.41.6 findings | [Layer 6: CAUTION](https://github.com/iwesys/IWE/issues/1083#issuecomment-5993362888) | On tag 60341824 (26f0f585): all mandatory gates green, manifest 792/792, fresh installation and extension points proven, no P0/P1. F1 — false warning from `update.sh` on large `.iwe-runtime/`, already fixed in v0.41.6 (#1084, closed). F2 — `pack-creator-spf-guard.sh` is not registered in any hook loader, the declared PreToolUse block for SPF/FPF is fail-open, new [#1109](https://github.com/iwesys/IWE/issues/1109). F3/F4/F5 — same class as the v0.41.6 findings on detector 7 and platform portability, with additional evidence (live hardcode `dt-collect.sh:37`, additional author constants, `flock`/bash-4 without shim) added as a comment to [#1106](https://github.com/iwesys/IWE/issues/1106)/[#1107](https://github.com/iwesys/IWE/issues/1107)/[#1108](https://github.com/iwesys/IWE/issues/1108), not duplicated as separate issues. F6 — broken links in delivered skills/Memory (setup-wakatime step 3 and others), independently observed by both audits on different tags, new [#1110](https://github.com/iwesys/IWE/issues/1110). F7 — `{{IWE_ROOT}}`/`{{MEMORY_DIR}}` without a legend in week-close/SKILL.md, new [#1111](https://github.com/iwesys/IWE/issues/1111). |
| v0.41.4 | **completed** | 2026-10-04 | 0 new significant classes; fix [#1072](https://github.com/iwesys/IWE/issues/1072) confirmed | [Layer 5: STABLE](https://github.com/iwesys/IWE/issues/1077#issuecomment-5973802411); [Layer 6: CAUTION](https://github.com/iwesys/IWE/issues/1077#issuecomment-5973803726) | Published tag 41da1331 matched main CI and `publishable=true` receipt. Calibration 21/21; red/green control for #1072 12/12. Disposable installation v0.41.3→v0.41.4 via the actual release channel: 8 files updated, 1 deleted, 792/792 hashes and modes matched, 5 synthetic personalizations preserved, re-run with no updates. No service manager calls were made. A shell wrapper does not replace a VM for absolute service-manager invocation or PATH substitution; personal acceptance F96 is open. |
| v0.41.3 | **completed** | 2026-10-03 | 1 significant audit-boundary defect [#1072](https://github.com/iwesys/IWE/issues/1072); 0 new confirmed behavioral defects for #1067 | [Layer 5: 0 new significant](https://github.com/iwesys/IWE/issues/1071#issuecomment-5973120428); [Layer 6: BLOCKED](https://github.com/iwesys/IWE/issues/1071#issuecomment-5973157100) | On published tag 774b0898 the fix for #1067 passed on the delivered copy; update v0.41.2→v0.41.3 via the actual release channel preserved synthetic user files. The disposable audit sandbox wrapper did not block host-global `launchctl` calls; a host service change was not proven. #1071 retains the historical BLOCKED status; the fix for #1072 and safe re-run are recorded for v0.41.4. Prior issues #1002/#1005/#1006/#1032 remain open. |
| v0.41.2 | **completed** | 2026-10-03 | 1 new significant P1 [#1067](https://github.com/iwesys/IWE/issues/1067) | [Layer 5: BLOCKED](https://github.com/iwesys/IWE/issues/1066#issuecomment-5972449899); [Layer 6: BLOCKED](https://github.com/iwesys/IWE/issues/1066#issuecomment-5972436902) | On published tag 77fe2f2d, after two week-review failures the delivered DayPlan shows a false green status even though the report was not delivered. The CI receipt is green but did not cover this case. #1066 remains open until the fix and an independent re-check; prior #1006 is also open. |
| v0.41.1 | **completed** | 2026-10-03 | 2 significant: P1 #1060, P2 #1061 | [Layer 6: BLOCKED](https://github.com/iwesys/IWE/issues/1059#issuecomment-5971646785) | [Layer 5: 2 classes found](https://github.com/iwesys/IWE/issues/1059#issuecomment-5971645767) on tag faccdf3c: the release receipt is green, but the installed Day Open falsely marks a scheduler failure as green and the mandatory map was not delivered to the platform skill. Both issues are open; #1059 is not closed. |
| v0.41.0 | **completed** | 2026-10-02 | 0 blockers; 2 important release regressions, prior findings and notification defects | "No blockers" per [pilot comment](https://github.com/iwesys/IWE/issues/998#issuecomment-5949272475) | Pilot run #998: two regressions fixed in #999 and #1000; notifications — #1001 with limited verification; prior findings — open #1002–#1006. Release and updates verified in a sandbox as indicated in #998; those checks do not close the individual findings. |
| v0.41.0 | **completed** | 2026-10-02 | 0 blockers; 4 important and 3 nice-to-have (reported separately) | "Not STABLE" per external reviewer; independent re-run not recorded | [Separate fork-user comment](https://github.com/iwesys/IWE/issues/998#issuecomment-5949629589): WSL2, update 0.40.2→0.41.0, `core.fileMode=false`. Migration path outside the manifest, lost `+x`, Python literals and Linux systemd; do not add these counts to the pilot run or treat these items as closed by its decision. |
| v0.40.0 | **completed** | 2026-09-10 | 0 blockers, 0 important, 5 nice-to-have (F1–F5) | STABLE per [first run](https://github.com/iwesys/IWE/issues/748#issuecomment-5613470222) | F1 — detector gap, F2 — two dead links, F3 — stale names and counters, F4 — 7 of 24 `substituted` without `{{}}`, F5 — link to a non-existent warn gate. This is a separate early assessment, without the YooKassa false alarm and NixOS. |
| v0.40.0 | **completed** | 2026-09-10 | 1 initial false alarm and 4 confirmed items | STABLE after technical follow-up per [pilot's late run](https://github.com/iwesys/IWE/issues/748#issuecomment-5619310904) | The YooKassa "leak" was documented fail-closed behavior. #779 removed dead links, expanded DETECTOR_07, and fixed the smoke test on NixOS (was 23 PASS/4 FAIL, became 49/0). The fourth item, `/lesson-close` without `/lesson`, was filed as #778 and resolved by the pilot later in #845, not in #779. |
| v0.39.0 | **completed** | 2026-08-30 | 1 blocking regression #559 | BLOCKED, release replaced by v0.39.1 | [Run #576](https://github.com/iwesys/IWE/issues/576#issuecomment-5467737058): `RC_STEP_SKIPPED` was not displayed in `main()` Day Close; an optional skip yielded exit code 1. Fix #575. |
| v0.39.1 | **completed** | 2026-08-30 | 0 new P0/P1 in the verified fix | GO per [run #576](https://github.com/iwesys/IWE/issues/576#issuecomment-5467737058) | Release #577 after #575; audit performed by the fix author under pilot authorization, independent re-run only recommended. #588 separately recorded an assessment of the personal-guide delta #585/#586, but no executable receipt is available for the 3 prior minor observations stated there; do not treat this as an independent release re-run. |
| v0.34.1 | skipped-unverified | — | — | — | migrated from #133 |
| v0.34.0 | skipped-unverified | — | — | — | migrated from #130 |
| v0.33.x | skipped-unverified | — | — | — | migrated from #129, #127 |
| v0.32.x | skipped-unverified | — | — | — | migrated from #126, #123 |
| v0.31.x | skipped-unverified | — | — | — | migrated from #117 |
| v0.30.x | skipped-unverified | — | — | — | migrated from #55, #54 |
| v0.29.25 | skipped-unverified | — | — | — | migrated from #41 |
| v0.29.x (legacy) | skipped-unverified | — | — | — | migrated from #15, #16, #18, #21, #22, #27, #32, #43, #44, #45, #52, #53 |
| v0.29.x (round-2) | **completed** | 2026-05-06 | 40 declared findings | #75 records only a subset of statuses | [M1.6 #75](https://github.com/iwesys/IWE/issues/75) lists 6 `Fixed` (C1–C4, H2–H3) and 3 `To verify` (H1, H4–H5). The complete list of 40 and their closure receipts are absent from the available record; `TESTING.md` and the audit report referenced in #75 are not currently delivered. |

Receipts and boundaries for these historical records:

- For v0.41.3 the published annotated tag points to `774b08988bbd2dfb16a023d3e1bc2e83f87fd3cf`: [final CI](https://github.com/iwesys/IWE/actions/runs/37149861369) yielded `publishable=true`, [Release](https://github.com/iwesys/IWE/actions/runs/37150528108) passed. Independent layer 5 verified calibration 9/9, validator 11/11, clean installation 53/53, 792/792 hashes, and ten classes; prior #1060/#1061 and #1067 on the exact tag passed green controls, the prior detector bypass remains in #1006. Layer 6 updated a disposable installation from v0.41.2 to v0.41.3 via the actual release channel: 792/792 files and four synthetic user markers retained the required hashes, bytes, and modes; re-run with service-manager stubs produced no changes (797 files/markers). On the delivered projection, the #1067 test yielded 59 passes versus the 33 expected failures on v0.41.2. On the first update, the `boundary-guard.sh` wrapper did not block host-global `launchctl`; a safe red control with a stub confirms the channel but not a change to an existing service. Layer 6 therefore returned BLOCKED; separate issue #1072 is open; macOS smoke with real `launchctl`, live WSL/systemd, and a personal installation were not verified. #1071 remains open; STABLE status was not assigned to the release.
- For v0.41.2 the published annotated tag `77fe2f2d7d26743f1dd73c1ae0f5ee47b6f7da9b` was verified, not the PR candidate: a new independent reviewer completed all 10 classes of the post-release prompt, sandbox wrapper calibration 9/9, validator 11/11, and clean-installation smoke 53/53; two delivery projections matched 792/792 SHA entries in the manifest. A separate reviewer updated a disposable core installation from v0.41.1 to v0.41.2 via the actual release channel: 7 files changed, 1 deleted, three synthetic user markers retained content, size, and permissions; a re-run did not update anything and again confirmed 792 SHA entries. Prior red controls for #1060/#1061 on the delivered files turned green. However, a new red control for #1067 detected a false-green Scheduler/triage after `FAILED`/`GAVE UP` on the weekly review and `dispatch completed`; a clean log is also green, adding `WARN` makes the defective log red. The [main CI receipt](https://github.com/iwesys/IWE/actions/runs/37144719175/job/111268303582) reports `publishable=true` for the exact SHA but does not cover this path. Both layers therefore returned BLOCKED; no exception was accepted; separate issue #1067 is open. The temporary core fixture did not invoke host-global launchd, a real LLM, live WSL/systemd, or a full Windows installation; the optional extractor backfill warned about a missing LaunchAgents directory inside the fixture HOME. The layer 6 reviewer had previously reviewed the release PR but did not write its code.
- For v0.41.1 the published tag faccdf3c7fa1429145de4d9bd43c65ed78788b95 was verified: sandbox wrapper calibration, 11/11 integration checks, 53/53 clean-installation checks, and 3/3 detector fixtures; all 791 manifest hashes matched. A disposable installation of v0.41.0 was successfully updated via the real release channel: 75 changes, 1 deletion, three user markers preserved; a second run reported no updates. The [exact CI receipt](https://github.com/iwesys/IWE/actions/runs/37139099577) considers the tree releasable but does not cover the discovered cases: #1060 received a red control (on a v0.41.0 error log the status is white; on v0.41.1 it is green), #1061 received a red control for the mandatory file missing from a manifest-only installation. No fixed green candidate or owner-accepted exception exists for them yet, so the result is BLOCKED; closing of #1059 is deferred. On the final push the macOS job was skipped normally, but two macOS jobs passed on the [PR tree matching the tag](https://github.com/iwesys/IWE/actions/runs/37137661479). Windows/Git Bash was verified only by targeted CI jobs; WSL2 and live Linux systemd were not verified; no separate signed attestation was provided by this audit.
- For F1 from the early v0.40.0 run, #779 added
  `setup/detector-fixtures/detector_07/positive_quoted_literal.md`: the prior
  regex did not catch the sample, the current `setup/test-detectors.sh` passes 3 of 3
  fixtures. F2 — link removal with no separate executable check; F3 —
  update of current descriptions in #1024, the old reminder text in #748 remains
  historical. F4 requires a per-file justification for `substituted` or a control:
  the contract itself allows a file without `{{}}` if it is meant to live in the workspace.
  F5 — the false warn-gate promise was removed in #1024; the gate itself does not exist. The decision
  to remove `/lesson-close` was accepted and delivered in #845; no separate red and green
  check was recorded for this finding.
- For v0.41.0, #999 reproduced exit code 49 on the old `update.sh`, then ran
  `scripts/tests/test_issue_541_workspace_base.sh` (142 checks and 7 red
  mutants). #1000 verified `strategy-session` with
  `scripts/tests/test_issue_969_strategy_session_isolated_copy.sh`
  (3 red mutants, green candidate); a full test of the old release is not proven by this.
  #1001 verified YAML and code but not live bot delivery or deduplication. #1002–#1006 remain open, not accepted as exceptions.
- The four important findings from the external v0.41.0 run received separate issues:
  migration path #1036, `core.fileMode=false` #1037, Python literals #1038,
  Linux systemd #1039. Migration #1036 was fixed in main via #1041 with a check on the old installation; Python paths #1038 were fixed in main via #1040 and closed:
  these are author scripts outside the user manifest. #1037 was fixed in main
  via #1042 after a red reproduction and end-to-end check; #1039 remains open.
  The fixes from main have not yet been delivered in a new release. None of these items received
  an accepted exception or a completed installation verification here.
- For #559, the v0.39.0 defect was confirmed by code reading in #576; v0.39.1 passed
  a manual test after #575. A regression test for `RC_STEP_SKIPPED` and the lesson-link counter was added to main via #1035; an independent release re-run was not recorded.

## Observation from Migrated Issues

A spot-check of migrated issues confirmed the adversarial audit of 2026-05-06
with its 40 declared findings (#75); its status here is therefore `completed`.
However, #75 does not prove all 40 were fixed: it lists six `Fixed`
and three `To verify`. The full finding registry and their executable receipts are not
delivered in the current tree; the prior claim "all fixed" is retracted.

## Further Use

- Each verified release → one row in this table. The workflow issue serves as a
  reminder and does not replace the result record or the separate open issues
  for unresolved significant findings.
- There is currently no automated warning when a release is made without a record in this table: `verify-before-promote.sh` is absent from the template tree.
- Quarterly: review the log — entries with `skipped-unverified` older than 90 days → make a decision (run-now / accept-debt / wontfix).

## Related

- `.github/workflows/post-release-audit.yml` — reminder issue creation
- `setup/integration-contract-validator.sh` and `setup/test-detectors.sh` —
  current detectors and their fixtures
- Peer session 2026-06-01-18 (author governance repository) — migration from 22 open issues

