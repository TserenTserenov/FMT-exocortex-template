# FMT-exocortex-template Release Process

> Who, when, and how to bump the template version. Goal: a clear "ready to release" criterion
> instead of a verbal agreement. Source: WP-347 Phase 3, 22 May 2026.
> **Weekly auto-bump** added by WP-5 (20 July 2026) — see "Regular Release" below.

## What "release" means

`update.sh` operates through the `release` channel by default: an update locks to the
latest published GitHub Release (a tag; when Python is available, the tag is additionally
resolved to a commit SHA). A commit to `main` reaches users only after the next release is
published. If no release can be resolved, the update stops (fail-closed) — there is no
automatic fallback to `main`.
The `main` channel (`IWE_UPDATE_CHANNEL=main`) is a moving branch for the author workflow.

**Version** in `update-manifest.json["version"]` is displayed when running `bash update.sh`
as "Exocortex updates (vX.Y.Z)", downloaded during `--check` from the remote manifest for
comparison with the local version, and compared during an update when the installed copy and
the release share no common commit (a fork with rewritten history): a release older than the
installed version is treated as a rollback and requires explicit confirmation (`--yes` does not
apply it; without `--yes`, the user must type `ROLLBACK`). The format is digits-only `X.Y.Z`
(up to 9 digits per part), as validated by `version_compare` in `update.sh`; otherwise a
rollback cannot be detected and `--yes` stops. A version bump is a signal: "this set of changes
is stabilized — time to update."

## Regular release (weekly-release.yml)

Before WP-5 (20 July 2026), version bumps were manual only — gaps between releases reached
2–3 weeks, even though commits to the `[Unreleased]` section of CHANGELOG landed almost daily.
The reason: the bot notification for users is generated as a summary of the CHANGELOG and remains
pending until someone manually draws the line.

**`.github/workflows/weekly-release.yml`** — runs on a schedule (Sunday 20:00 UTC) and checks:
is the `[Unreleased]` section in CHANGELOG.md non-empty? If yes, it bumps the patch version
(`X.Y.Z` → `X.Y.(Z+1)`) in `update-manifest.json`, flushes `[Unreleased]` via
`scripts/changelog-flush.sh`, and commits. The commit triggers `release.yml` — the tag and
GitHub Release are created automatically.

**Manual bumps are still possible** for minor/major versions (new feature, breaking change)
or for an out-of-cycle release — the readiness criteria and steps below remain in effect; the
auto-bump simply applies them automatically at the patch level once a week instead of waiting
for a manual decision.

---

## Version bump readiness criteria

All items must be complete:

- [ ] CI is green (`Validate Template` + all jobs)
- [ ] No open hotfix branches (`git branch --list 'hotfix/*'` returns empty)
- [ ] CHANGELOG.md is filled in: the `[Unreleased]` section is not empty, no "TODO" lines
- [ ] All new files are added to `update-manifest.json["files"]`
  (`git ls-files | python3 scripts/check-manifest-coverage.py update-manifest.json`)
- [ ] `deprecated_files` follows the convention (see "deprecated_files Convention" below)
- [ ] Fix commits since the last bump ≤ 5 (if > 5 → mandatory instability review is required, see "Stability Metric" section)

---

## Stability metric

The number of fix commits since the last version bump serves as a proxy metric for codebase
stability. A threshold of ≤ 5 means that accumulated instability is not yet critical and the
release can proceed without an additional review; exceeding the threshold requires an explicit
risk assessment.

```bash
# Count fix commits since the last version bump
# Branch A — tags exist (normal path):
LAST_TAG=$(git tag --list 'v*' --sort=-v:refname | head -1)
if [ -n "$LAST_TAG" ]; then
  COUNT=$(git log "$LAST_TAG"..HEAD --oneline | grep -cE '^[a-f0-9]+ (fix|hotfix)(\(|: )' || true)
else
  # Branch B — no tags (legacy, remove 2 releases after tags are restored):
  LAST_MANIFEST_BUMP=$(git log -2 --format=%H -- update-manifest.json | sed -n '2p')
  if [ -z "$LAST_MANIFEST_BUMP" ]; then
    echo "ℹ️  No previous manifest bump — skipping fix-metric check (first release)"
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

> Fallback branch B is removed 2 releases after normal tagging is restored.

## Version bump steps

```bash
# 1. Confirm CI is green, pull latest changes
git pull --rebase

# 2. Determine the new version (semver: patch = fixes, minor = new skill/feature)
NEW_VERSION="0.35.0"

# 3. Bump the version in the manifest
python3 - "$NEW_VERSION" <<'EOF'
import json, sys
with open('update-manifest.json', encoding='utf-8') as f:
    m = json.load(f)
m['version'] = sys.argv[1]
with open('update-manifest.json', 'w', encoding='utf-8') as f:
    json.dump(m, f, ensure_ascii=False, indent=2)
    f.write('\n')
print(f"version bumped to {sys.argv[1]}")
EOF

# 4. Update CHANGELOG.md: rename [Unreleased] → [X.Y.Z] and add a new [Unreleased] section
# Template:
# ## [X.Y.Z] — YYYY-MM-DD
# ### What's new
# - brief description
# ## [Unreleased]

# 5. Commit + push
git add update-manifest.json CHANGELOG.md
git commit -m "chore: release $NEW_VERSION"
git push
```

---

## Release owner

The template author (`author_mode: true` in `params.yaml`). A release is a synchronous step
and cannot be delegated to agents without explicit authorization. Cadence: as changes accumulate,
with a target of approximately once per week when significant changes are present.

Release signal: ≥ 1 feature or ≥ 3 fixes in `[Unreleased]`.

---

## `deprecated_files` Convention

An entry in `deprecated_files` means: **the file has ALREADY been removed from the repository or is no longer in use.**
This does NOT mean "planning to remove" or "migrating soon."

**Rule:**

1. Remove a file from the repository → add it to `deprecated_files` in the same commit.
2. Manually verify that no script or hook in the repository references that path:
   ```bash
   grep -r "path/to/deprecated-file" . --include="*.sh" --include="*.md" --include="*.json"
   ```
   Detector 10 in `integration-contract-validator.sh` catches this case for
   `roles/strategist/prompts/` — but only for that subset of files.
   For all other deprecated files, manual verification is mandatory.
3. Using `deprecated_files` as a TODO tracker ("we'll remove it soon") is prohibited:
   after `update.sh` runs, the user will not receive the new file, and the old one is already
   removed from delivery.

**Why this matters:** if `deprecated_files` contains a file that the runner still uses,
the runner will fail with "file not found" after `update.sh` (precedent: `af3b15c`, strategist
roles, 22 May 2026).

---

## Checklist when adding a new file to FMT

For every `git add <new-file>`, verify:

1. The file is added to `update-manifest.json["files"]` (otherwise users will not receive it).
   CI check: `git ls-files | python3 scripts/check-manifest-coverage.py update-manifest.json`.
2. If the file is intentionally NOT meant for delivery — add it to `excluded_paths` or to one
   of the excluded directories (`.github/`, `setup/`, `seed/`, `extensions/`, `templates/`).
3. If the file is a `.sh` script — run `bash scripts/validate-fmt-scripts.sh scripts/` to check
   for hardcoded values and unsafe arithmetic under `set -e`.

---

## Full git mirror of the template with its own CI — NOT supported (issue #850)

A full `git clone`/fork of this repository (as opposed to installing via `setup.sh` +
`update.sh`) pulls in `.github/workflows/*`, including `validate-template.yml`, together
with ALL repository content at the time of cloning — including files from `excluded_paths`
(for example `setup/smoke-test-fresh-install.sh`) that are intended as internal dev/CI files
of the canon, not part of delivery.

If such a mirror is then updated via `update.sh --yes` (rather than `git pull` from upstream)
— `update.sh` keeps only the files listed in `files`/delegated directories current;
`excluded_paths` files, once cloned, are never updated again. Workflow files that reference
`excluded_paths` tests (`validate-template.yml` calls `smoke-test-fresh-install.sh`) continue
to run in such a mirror on `push`, but over time they compare the current workflow against a
stale copy of the test — a failure in this scenario does not mean that delivery is broken.

**This configuration is not supported.** Results of `validate-template.yml` in such a mirror
are not meaningful; compare against a run on the canon
(`TserenTserenov/FMT-exocortex-template`) at the same commit/version before treating a
difference as a real defect.

---

## Related files

| File | Purpose |
|------|---------|
| `update-manifest.json` | List of delivered files + version |
| `CHANGELOG.md` | Changelog in Keep a Changelog format |
| `scripts/check-manifest-coverage.py` | CI manifest coverage check (B2) |
| `scripts/validate-fmt-scripts.sh` | Hardcode + set-e arithmetic check (B8) |
| `setup/integration-contract-validator.sh` | Validator spec↔state (including Detector 10) |
| `docs/SCRIPT-PROMOTION.md` | Script promotion process L3→L1 |