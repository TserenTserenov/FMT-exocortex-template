# IWE Release Process

> Who, when, and how to bump the template version. Goal: a clear "ready to release" criterion instead of a verbal agreement. Source: WP-347 Phase 3, 22 May 2026.
> **Release at the Release Owner's decision** (WP-529 Phase 251, 10.11.2026) — see "Release via Candidate" below. Weekly auto-bump (WP-5, 20.07.2026) cancelled 03.11.2026.

## What "release" means

`update.sh` uses the `release` channel by default: the update locks to the latest published GitHub Release (tag; when Python is available, the tag is additionally resolved to a commit SHA). A commit to `main` reaches users only after the next release is published. If no release can be resolved, the update halts (fail-closed) — there is no automatic fallback to `main`.
The `main` channel (`IWE_UPDATE_CHANNEL=main`) is a moving branch for the author workflow.

**Version** in `update-manifest.json["version"]` is displayed when running `bash update.sh` as "Exocortex Update (vX.Y.Z)", is downloaded on `--check` from the remote manifest for comparison with the local copy, and is compared during update when the installed copy and the release share no common commit (a fork with rewritten history): a release older than the installed version is treated as a rollback and requires explicit confirmation (`--yes` does not apply it; without `--yes` the user must type `ROLLBACK`). The format is digits only — `X.Y.Z` (up to 9 digits per part), as validated by `version_compare` in `update.sh`; otherwise a rollback cannot be detected and `--yes` halts. A version bump is the signal that "this set of changes is stabilized — time to update."

## Release via Candidate (release-candidate.yml)

The weekly scheduled release was cancelled on 03.11.2026: only content selected and verified by the Release Owner goes into a release. There is no schedule; all steps are triggered manually (Actions → **Release Candidate** → Run workflow).

1. **Cut.** The Release Owner names a commit on the main branch — the snapshot. Run with `mode=cut`, `snapshot_sha=<full SHA>`, `release_type=patch|minor`. The workflow verifies that the commit is on `main` and that `[Unreleased]` is non-empty at that commit; it bumps the version, moves the notes into a new CHANGELOG section, updates the badge and manifest, creates a `release/vX.Y.Z` branch, places the candidate tag `vX.Y.Z-rc.1` on it, and opens a PR into `main`. If a branch with that version already exists, the workflow fails.
2. **Selection.** Anything the Release Owner defers is removed by revert (`git revert`) on the release branch, not on `main`. A fix found during review also goes onto the release branch. Do not advance the main branch until the PR is merged.
3. **Next candidate.** After each change to the release branch, run with `mode=next-rc`, `version=X.Y.Z`: this places tag `vX.Y.Z-rc.N` on the tip of the branch and adds a comment to the PR. If the content matches the last candidate, the workflow fails.
4. **Verification.** Testers install the candidate: `IWE_UPDATE_CHANNEL=rc bash update.sh`.
5. **Merge and release.** The PR created via `GITHUB_TOKEN` waits for approval to run `pull_request` checks: the owner selects **Approve workflows to run** and waits for a successful `Validate Template` with a mandatory `release-receipt` for the current PR commit. A separate `workflow_dispatch` on the release branch [does not count as a required PR check](https://docs.github.com/en/pull-requests/how-tos/merge-and-close-pull-requests/troubleshooting-required-status-checks#checks-from-some-workflow-jobs-are-not-evaluated). After merge, the check on the `main` commit triggers `release.yml`: it places tag `vX.Y.Z` and creates a GitHub Release only if the content matches the last candidate; otherwise the release halts.

The candidate tag is placed by `scripts/tag-release-candidate.sh` (the number is derived from tags on the server; a parallel-run race is resolved by retrying with a new number); the test is `scripts/tests/test_tag_release_candidate.sh`.

For a sensitive patch release (updater, security, agent behavior) the author manually triggers `post-release-audit.yml` with the published version: an automatic reminder is created only for `X.Y.0` versions.

### Release PR merged, but no tag

1. Find the merge commit of the release PR and confirm it is on `main`. On that commit, verify the version in `update-manifest.json`, the CHANGELOG section, and the README version badge. Do not trigger another bump.
2. Check `Validate Template` **for that commit**. If the check failed due to a stale manifest or badge, fix them in a new PR (`bash scripts/sync-version-badge.sh --fix`, `bash generate-manifest.sh`), merge after checks pass, and wait for a green check on the final commit.
3. If the final check is green but `release.yml` did not create a tag, manually trigger `release.yml` with **explicit** `version` and `sha` for the verified commit:

   ```bash
   gh workflow run release.yml --ref main -f version="<X.Y.Z>" -f sha="<full SHA of verified commit>"
   ```

   A manual trigger bypasses the automatic check linkage. Before running it, confirm that `Validate Template` is green for the specified SHA and that tag `vX.Y.Z` does not yet exist; then confirm that the tag points to that SHA and that the GitHub Release is published. If the tag already exists but the Release is missing, this workflow will not restore it: its step skips existing tags.

---

## Version bump readiness criteria

All items must be satisfied:

- [ ] CI is green (`Validate Template` + all jobs)
- [ ] No open hotfix branches (`git branch --list 'hotfix/*'` — empty)
- [ ] CHANGELOG.md is complete: the `[Unreleased]` section is non-empty and contains no "TODO" lines
- [ ] All new files are added to `update-manifest.json["files"]`
  (`git ls-files | python3 scripts/check-manifest-coverage.py update-manifest.json`)
- [ ] `deprecated_files` complies with the convention (see "deprecated_files convention" below)
- [ ] Fix commits since the last bump ≤ 5 (if > 5 → mandatory instability review required, see "Stability metric" section)

---

## Stability metric

The number of fix commits since the last version bump serves as a proxy metric for codebase stability. A threshold of ≤ 5 means accumulated instability is not yet critical and the release can proceed without an additional review; exceeding the threshold requires an explicit risk assessment.

```bash
# Count fix commits since the last version bump
# Branch A — tags exist (normal path):
LAST_TAG=$(git tag --list 'v*' --sort=-v:refname | head -1)
if [ -n "$LAST_TAG" ]; then
  COUNT=$(git log "$LAST_TAG"..HEAD --oneline | grep -cE '^[a-f0-9]+ (fix|hotfix)(\(|: )' || true)
else
  # Branch B — no tags (legacy; remove two releases after tags are restored):
  LAST_MANIFEST_BUMP=$(git log -2 --format=%H -- update-manifest.json | sed -n '2p')
  if [ -z "$LAST_MANIFEST_BUMP" ]; then
    echo "No previous manifest bump — skipping fix-metric check (first release)"
    exit 0
  fi
  COUNT=$(git log "$LAST_MANIFEST_BUMP"..HEAD --oneline | grep -cE '^[a-f0-9]+ (fix|hotfix)(\(|: )' || true)
fi
echo "fix commits: $COUNT"
if [ "$COUNT" -gt 5 ]; then
  echo "⚠️  >5 fixes — instability review required before bump"
  exit 1
fi
```

> Fallback branch B is removed two releases after normal tagging is restored.

## Manual release steps

For `patch` or `minor`, use the Release Candidate process described in "Release via Candidate" above.

For `major`, or when the automated PR build is not suitable:

1. Start from the current `origin/main` in a separate `release/vX.Y.Z` branch. Verify the readiness criteria above and assign the version explicitly.
2. Update `update-manifest.json["version"]`, move `[Unreleased]` into the `[X.Y.Z]` section via `scripts/changelog-flush.sh --version X.Y.Z`, sync the badge (`scripts/sync-version-badge.sh --fix`), and regenerate the manifest (`generate-manifest.sh`).
3. Open a PR. Merge it only after the release branch passes verification, including `release-receipt`. Then confirm a green `Validate Template` on the final `main` commit, the tag, and the published GitHub Release.

---

## Release Owner

The template author (`author_mode: true` in `params.yaml`). A release is a synchronous step and cannot be delegated to agents without explicit permission. Cadence: as changes accumulate — target approximately once per week when significant changes are present.

Release signal: ≥ 1 feature or ≥ 3 fixes in `[Unreleased]`.

---

## `deprecated_files` convention

An entry in `deprecated_files` means: **the file has ALREADY been removed from the repository or is no longer in use.** This is NOT "planning to remove" or "migrating soon."

**Rule:**

1. When you delete a file from the repository, add it to `deprecated_files` in the same commit.
2. Manually verify that no script or hook in the repository references that path:
   ```bash
   grep -r "path/to/deprecated-file" . --include="*.sh" --include="*.md" --include="*.json"
   ```
   Detector 10 in `integration-contract-validator.sh` catches this case for `roles/strategist/prompts/` — but only for that file subset. For all other deprecated files, manual verification is required.
3. Using `deprecated_files` as a TODO tracker ("we'll remove this soon") is prohibited: after `update.sh`, the user will not receive the new file, and the old one is already removed from delivery.

**Why this matters:** if `deprecated_files` contains a file that a runner still uses, the runner will fail with "file not found" after `update.sh` (precedent: `af3b15c`, strategist roles, 22 May 2026).

---

## Checklist when adding a new file to FMT

For every `git add <new-file>`, verify:

1. The file is added to `update-manifest.json["files"]` (otherwise users will not receive it).
   CI check: `git ls-files | python3 scripts/check-manifest-coverage.py update-manifest.json`.
2. If the file is intentionally NOT meant for delivery — add it to `excluded_paths` or to one of the excluded directories (`.github/`, `setup/`, `seed/`, `extensions/`, `templates/`).
3. If the file is a `.sh` script — run `bash scripts/validate-fmt-scripts.sh scripts/` to check for hardcoded values and unsafe arithmetic under `set -e`.

---

## Full git mirror of the template with its own CI — NOT supported (issue #850)

A full `git clone`/fork of this repository (rather than installation via `setup.sh` + `update.sh`) receives `.github/workflows/*`, including `validate-template.yml`, together with ALL repository contents at the time of cloning — including files from `excluded_paths` (for example `setup/smoke-test-fresh-install.sh`), which are intended as internal dev/CI files of the canon, not part of delivery.

If such a mirror is then updated via `update.sh --yes` (rather than `git pull` from upstream) — `update.sh` keeps only the files in `files`/delegated directories current; `excluded_paths` files, once cloned, are never updated again. Workflow files that reference `excluded_paths` tests (`validate-template.yml` calls `smoke-test-fresh-install.sh`) continue to run in such a mirror on `push`, but over time they compare the current workflow against a stale copy of the test — a failure in this scenario does not mean delivery is broken.

**This configuration is not supported.** Results of `validate-template.yml` in such a mirror are not meaningful; compare against a run on the canon (`iwesys/IWE`) at the same commit/version before treating a difference as a real defect.

---

## Related files

| File | Purpose |
|------|---------|
| `update-manifest.json` | List of delivered files + version |
| `CHANGELOG.md` | Changelog in Keep a Changelog format |
| `scripts/check-manifest-coverage.py` | CI manifest completeness check (B2) |
| `scripts/validate-fmt-scripts.sh` | Hardcode + set-e arithmetic check (B8) |
| `setup/integration-contract-validator.sh` | Validator spec↔state (including Detector 10) |
| `docs/SCRIPT-PROMOTION.md` | Script promotion process L3→L1 |