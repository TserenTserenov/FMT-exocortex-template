# CI and Supply-Chain Review

Use for workflows, GitHub Actions, dependency or release-pipeline changes, and CI evidence.

## Workflow Threat Model

Review:

- untrusted PR content reaching privileged `pull_request_target` or `workflow_run` contexts;
- script injection through branch names, titles, paths, issue text, or generated output;
- excessive `GITHUB_TOKEN` or environment-secret permissions;
- third-party actions referenced by mutable tags instead of full commit SHA;
- cache or artifact reuse across trust boundaries;
- self-hosted runners exposed to untrusted public code;
- release jobs that can run after a skipped or failed validation job;
- workflows that silently do nothing when secrets or channel configuration are absent;
- external notifications emitted before the release actually exists.

## Required Controls

- Set top-level token permissions to read-only or none; elevate narrowly per job.
- Pin third-party actions to full-length commit SHAs and verify the SHA belongs to the intended repository.
- Never check out untrusted PR code in a privileged workflow with write tokens or secrets.
- Pass untrusted values through data/environment boundaries, not directly into executable inline scripts.
- Use GitHub-hosted ephemeral runners for public untrusted contributions unless a stronger isolated design is documented.
- Protect release workflows and manifest/security-policy paths with required review or CODEOWNERS.
- Test missing-secret and missing-channel branches. Optional notification must skip truthfully; required publication must fail closed.

## Exact Receipt Review

For every required job record:

- workflow file and revision;
- event and condition;
- actual checkout SHA;
- runner OS, architecture, shell path, and version;
- relevant dependency versions;
- step execution status and exit code;
- test names/counts and whether the intended test file ran;
- `continue-on-error`, allowed failures, retries, `SKIP`, and `XFAIL`;
- uploaded artifact digest and retention.

A green summary is insufficient when the critical step was skipped, discovered zero tests, used an unsupported shell, or read source-only files absent from delivery.

## Provenance and Attestations

For published archives, installers, manifests, or packages:

- generate provenance that binds repository, workflow, event, environment, commit SHA, and artifact digest;
- publish an SBOM when the artifact contains third-party executable dependencies;
- verify the attestation as a consumer step against the expected repository and workflow identity;
- retain the verification result in the release receipt;
- remember that provenance proves origin and build path, not safety or functional correctness.

## Required Matrix

Run actual supported environments, not compatibility emulation alone:

- stock macOS `/bin/bash` 3.2 when supported;
- current Bash on macOS and Linux;
- declared Python versions with and without optional dependencies;
- serial and production parallel download modes;
- clean checkout and manifest-only installed projection;
- fork PR path without author secrets.

Static scanners, ShellCheck, OpenSSF Scorecard, dependency review, and secret scanning complement behavior tests; none substitutes for the installed end-to-end path.
