# Evidence and Reporting

Use before issuing a verdict, closing an issue, or approving a release.

## Evidence Quality

Strongest to weakest:

1. installed end-to-end behavior on the exact released/candidate artifact;
2. clean disposable reproduction pinned to an immutable SHA or tag;
3. source -> manifest -> installed target -> consumer proof;
4. exact-SHA CI log with the relevant non-skipped step;
5. static source observation;
6. documentation, issue/PR body, commit message, badge, or announcement.

Lower evidence can identify a lead but cannot silently substitute for end-to-end proof.

## Result Classes

- `platform_defect`: repository-owned implementation or delivery violates its documented contract.
- `test_infrastructure_defect`: runner, fixture, workflow, or test harness misrepresents product behavior.
- `external_dependency_failure`: third-party service, network, credential, or platform availability blocks the path.
- `expected_behavior`: implementation and current explicit contract agree.
- `false_positive`: reported failure does not reproduce on the exact artifact, or a test reports success without exercising the contract.
- `cannot_verify`: evidence is unavailable, unsafe to obtain, or attached to the wrong artifact.

Use mixed classification when multiple boundaries fail. Do not force a product conclusion from an external outage or contaminated fixture.

## Severity

- `P0`: confirmed data loss/corruption, credential exposure, unauthorized destructive or externally visible action, or compromise of the release channel.
- `P1`: unsafe install/update/release path, core runtime blocker, approval/safety bypass, persistent agent lockout, or required automation reporting false success.
- `P2`: degraded but recoverable workflow, portability gap, incorrect non-critical state/metrics, or incomplete defense-in-depth.
- `P3`: documentation, diagnostics, low-impact UX, or maintenance drift without safety impact.

Severity measures impact and exploitability, not patch size.

## Confidence and Falsifier

- `high`: exact-artifact behavior reproduced or decisive source-to-consumer proof with competing explanations ruled out.
- `medium`: strong source evidence or partial reproduction, but one relevant boundary remains untested.
- `low`: plausible lead only; do not use it alone to block or approve a release.

Every material finding must state a concrete falsifier, for example: “This finding is false if the manifest-only v0.39.0 installation contains file X at path Y and entry point Z executes it successfully under `/bin/bash` 3.2.”

## Required-Gate Table

At minimum report:

| Gate | Expected evidence |
|---|---|
| Artifact identity | source SHA, manifest digest, tag/release, workflow checkout |
| Manifest integrity | deterministic generation and zero completeness/hash errors |
| Clean install | documented command and installed postconditions |
| Upgrade matrix | required predecessors, sentinels, transaction, idempotency |
| Installed projection | consumers work without source-only files |
| Platform matrix | actual supported OS/shell/Python paths |
| Agent safety | relevant abuse cases and denial/approval evidence |
| Runtime/integration | canonical entry point and user-visible postcondition |
| Supply chain | pinned actions, permissions, provenance/attestation policy |
| Negative control | known-bad or mutation is detected |

Use `PASS`, `FAIL`, `PARTIAL`, `SKIP`, or `CANNOT_VERIFY`. Only PASS contributes to GO. A required `PARTIAL`, `SKIP`, or `CANNOT_VERIFY` blocks the corresponding claim.

## Issue Receipt

```markdown
## Snapshot
- observed_at:
- bad_artifact:
- candidate_artifact:
- supported_environment:

## Contract
- expected:
- actual:
- affected_delivery_path:

## Reproduction
- disposable_fixture:
- exact_entry_point:
- exit_and_postcondition:
- secrets_or_live_data_used: no

## Regression
- bad_or_mutated_control: FAIL as expected
- candidate: PASS
- installed_projection: PASS/FAIL
- upgrade_matrix: PASS/FAIL

## Finding
- severity:
- class:
- owner:
- confidence:
- falsifier:
- release_blocking: yes/no
```

## Release Report

Lead with one sentence that answers whether publication is safe. Then list blockers before successes. Distinguish precisely:

- fixed in a working tree;
- committed;
- merged to main;
- validated on the exact final SHA;
- tagged;
- published as a release;
- delivered by documented setup/update;
- operationally proven at the consumer.

Never phrase these states as equivalent.
