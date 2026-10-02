# FMT-exocortex-template Release Process

> Who, when, and how to bump the template version. Goal: a clear "ready to release"
> criterion instead of a verbal agreement. Source: WP-347 Phase 3, 22 May 2026.
> **Weekly auto-bump** added in WP-5 (20 July 2026) — see "Regular Release" below.

## What "release" means

`update.sh` operates through the `release` channel by default: an update pins to
the latest published GitHub Release (tag; when Python is available, the tag is
additionally resolved to a commit SHA). A commit to `main` reaches users only after
the next release is published. If no release can be resolved, the update halts
(fail-closed) — there is no automatic fallback to `main`.
The `main` channel (`IWE_UPDATE_CHANNEL=main`) is a moving branch for the author workflow.

**Version** in `update-manifest.json["version"]` is displayed when running `bash update.sh`
as "Exocortex updates (vX.Y.Z)", downloaded on `--check` from the remote manifest for
comparison with the local copy, and compared during an update when the installed copy and
the release share no common commit (a fork with rewritten history): a release older than
the installed version is treated as a rollback and requires explicit confirmation
(`--yes` does not apply it; without `--yes` the user must type `ROLLBACK`).
The format is digits-only `X.Y.Z` (up to 9 digits per part), as validated by
`version_compare` in `update.sh`; otherwise a rollback cannot be detected and `--yes` halts.
A version bump is the signal that "this set of changes is stabilized and it is time to update."

## Regular Release (weekly-release.yml)

Before WP-5 (20 July 2026), version bumps were manual only — gaps between releases
reached 2–3 weeks even though commits were landing in the CHANGELOG `[Unreleased]`
section almost daily. The reason: the user notification in the bot is generated as a
summary of the CHANGELOG and sits unpublished until someone manually draws the line.

**`.github/workflows/weekly-release.yml`** runs on a schedule (Sunday 20:00 UTC)
and checks for changes in `[Unreleased]` in CHANGELOG.md. If changes are present,
the workflow increments the patch version (`X.Y.Z` → `X.Y.(Z+1)`), moves the notes
into a new section, rebuilds the manifest, and opens a PR from the branch
`release/vX.Y.Z`.
When this workflow is triggered manually, the author explicitly selects `release_type`:
`patch` or `minor` (`0.Y.Z` → `0.(Y+1).0`). The release type is not inferred from
commit messages; a major bump remains a manual task.

The workflow explicitly triggers `Validate Template` on the release branch so that
the required `release-receipt` check appears on the PR created via `GITHUB_TOKEN`.
The author reviews and merges the PR. The check on the resulting `main` commit then
triggers `release.yml`; the tag and GitHub Release are created only after that check
passes. Without merging the PR, the new version is not delivered to users.

For a sensitive patch release (updater, security, agent behavior), the author manually
triggers `post-release-audit.yml` with the published version: the automatic reminder
is created only for `X.Y.0` versions.

### Release PR merged but no tag

1. Find the release PR merge commit and confirm it is in `main`. On that commit,
   verify the version in `update-manifest.json`, the CHANGELOG section, and the
   README version badge. Do not trigger another bump.
2. Check `Validate Template` **for that commit**. If the check failed due to a stale
   manifest or badge, fix them in a new PR
   (`bash scripts/sync-version-badge.sh --fix`, `bash generate-manifest.sh`),
   merge after checks pass, and wait for a green check on the resulting commit.
3. If the resulting check is green but `release.yml` did not create a tag, manually
   trigger `release.yml` with **explicit** `version` and `sha` of the verified commit:

   ```bash
   gh workflow run release.yml --ref main -f version="<X.Y.Z>" -f sha="<full SHA of the verified commit>"
   ```

   A manual trigger bypasses the automatic check linkage. Before running it,
   confirm that `Validate Template` is green for the specified SHA and that tag
   `vX.Y.Z` does not yet exist; then verify that the tag points to that SHA and
   that the GitHub Release is published. If the tag already exists but the Release
   is absent, this workflow will not restore it: its step skips an existing tag.

---

## Version bump readiness criteria

All items must be satisfied:

- [ ] CI is green (`Validate Template` + all jobs)
- [ ] No open hotfix branches (`git branch --list 'hotfix/*'` returns empty)
- [ ] CHANGELOG.md is complete: the `[Unreleased]` section is non-empty, no "TODO" lines
- [ ] All new files are added to `update-manifest.json["files"]`
  (`git ls-files | python3 scripts/check-manifest-coverage.py update-manifest.json`)
- [ ] `deprecated_files` complies with the convention (see "deprecated_files Convention" below)
- [ ] Fix commits since the last bump ≤ 5 (if > 5 → mandatory instability review required, see "Stability Metric" section)

---

## Stability Metric

The number of fix commits since the last version bump serves as a proxy metric for
codebase stability. A threshold of ≤ 5 means accumulated instability is not yet
critical and the release can proceed without an additional review; exceeding the
threshold requires an explicit risk assessment.

```bash
# Count fix commits since the last version bump
# Branch A — tags exist (normal path):
LAST_TAG=$(git tag --list 'v*' --sort=-v:refname | head -1)
if [ -n "$LAST_TAG" ]; then
  COUNT=$(git log "$LAST_TAG"..HEAD --oneline | grep -cE '^[a-f0-9]+ (fix|hotfix)(\(|: )' || true)
else
  # Branch B — no tags (legacy; remove after 2 releases once tags are restored):
  LAST_MANIFEST_BUMP=$(git log -2 --format=%H -- update-manifest.json | sed -n '2p')
  if [ -z "$LAST_MANIFEST_BUMP" ]; then
    echo "No previous manifest bump found — skipping fix-metric check (first release)"
    exit 0
  fi
  COUNT=$(git log "$LAST_MANIFEST_BUMP"..HEAD --oneline | grep -cE '^[a-f0-9]+ (fix|hotfix)(\(|: )' || true)
fi
echo "fix commits: $COUNT"
if [ "$COUNT" -gt 5 ]; then
  echo "⚠️  >5 fixes — instability review required before bumping"
  exit 1
fi
```

> Fallback Branch B is removed after 2 releases once normal tagging is restored.

## Manual release steps

For `patch` or `minor`, first use a manual trigger of Weekly Release with an explicit
`release_type`. Review the created PR and the green `release-receipt`, then merge the PR;
the tag and Release are created by `release.yml` after the resulting `main` commit passes.

For `major` or when the automated PR build is not suitable:

1. Start from the current `origin/main` in a separate branch `release/vX.Y.Z`.
   Check the readiness criteria above and assign the version explicitly.
2. Update `update-manifest.json["version"]`, move `[Unreleased]` into the `[X.Y.Z]`
   section via `scripts/changelog-flush.sh --version X.Y.Z`, sync the badge
   (`scripts/sync-version-badge.sh --fix`), and rebuild the manifest
   (`generate-manifest.sh`).
3. Open a PR. Merge it only after the release branch checks pass, including
   `release-receipt`. Then confirm a green `Validate Template` on the resulting
   `main` commit, the tag, and the published GitHub Release.

---

## Release owner

The template author (`author_mode: true` in `params.yaml`). A release is a synchronous
step and cannot be delegated to agents without explicit authorization. Cadence: on
accumulation of changes, target approximately once per week when significant changes
are present.

Release signal: ≥ 1 feature or ≥ 3 fixes in `[Unreleased]`.

---

## `deprecated_files` Convention

An entry in `deprecated_files` means: **the file has ALREADY been removed from the repo
or is no longer in use**. This does NOT mean "planning to remove" or "will migrate soon."

**Rule:**

1. When you remove a file from the repo, add it to `deprecated_files` in the same commit.
2. Manually verify that no script or hook in the repo references that path:
   ```bash
   grep -r "path/to/deprecated-file" . --include="*.sh" --include="*.md" --include="*.json"
   ```
   Detector 10 in `integration-contract-validator.sh` catches this case for
   `roles/strategist/prompts/` — but only for that subset of files.
   For all other deprecated files, a manual check is mandatory.
3. Using `deprecated_files` as a TODO tracker ("we'll remove it soon") is prohibited:
   after `update.sh` the user will not receive the new file, and the old one is already
   removed from delivery.

**Why this matters:** if `deprecated_files` contains a file that the runner still uses,
the runner will fail with "file not found" after `update.sh` (precedent: `af3b15c`,
strategist roles, 22 May 2026).

---

## Checklist when adding a new file to FMT

For every `git add <new-file>`, confirm:

1. The file is added to `update-manifest.json["files"]` (otherwise users will not receive it).
   CI check: `git ls-files | python3 scripts/check-manifest-coverage.py update-manifest.json`.
2. If the file is intentionally NOT intended for delivery — add it to `excluded_paths` or
   to one of the excluded directories (`.github/`, `setup/`, `seed/`, `extensions/`, `templates/`).
3. If the file is a `.sh` script — run `bash scripts/validate-fmt-scripts.sh scripts/` to
   check for hardcoded values and unsafe arithmetic under `set -e`.

---

## Full git mirror of the template with its own CI — NOT supported (issue #850)

A full `git clone`/fork of this repository (rather than installing via `setup.sh` +
`update.sh`) receives `.github/workflows/*`, including `validate-template.yml`,
together with ALL repository contents at the time of cloning — including files from
`excluded_paths` (for example `setup/smoke-test-fresh-install.sh`), which are
intended as internal dev/CI files of the canon, not part of delivery.

If such a mirror is then updated via `update.sh --yes` (rather than `git pull` from
upstream), `update.sh` keeps only the files listed under `files`/delegated directories
current; `excluded_paths` files that were cloned once are never updated again.
Workflow files that reference `excluded_paths` tests (`validate-template.yml` calls
`smoke-test-fresh-install.sh`) continue to run in such a mirror on `push`, but over
time they compare the current workflow against a stale copy of the test — a failure in
this scenario does not mean delivery is broken.

**This configuration is not supported.** Results of `validate-template.yml` in such a
mirror are not meaningful; compare against a run on the canon
(`TserenTserenov/FMT-exocortex-template`) at the same commit/version before treating
a difference as a real defect.

---

## Related files

| File | Purpose |
|------|---------|
| `update-manifest.json` | List of delivered files + version |
| `CHANGELOG.md` | Changelog in Keep a Changelog format |
| `scripts/check-manifest-coverage.py` | CI check for manifest completeness (B2) |
| `scripts/validate-fmt-scripts.sh` | Hardcode + set-e arithmetic check (B8) |
| `setup/integration-contract-validator.sh` | Validator spec↔state (including Detector 10) |
| `docs/SCRIPT-PROMOTION.md` | Script promotion process L3→L1 |