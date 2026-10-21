---
created: 2026-05-18
name: Pack CI guard
purpose: Template GitHub Action for new Pack-repositories — detector ID-collisions
source_wp: WP-5 F-pack-ci-guard
---

# Pack CI Guard — Template

The contents of this folder are copied into the root of a new Pack repository to activate ID collision protection via GitHub Actions.

## What It Provides

Every base ID in a Pack repo (DP.M.NNN, DP.D.NNN, DP.SC.NNN, AR.NNN, etc.) must be unique. If two files share the same basename ID, the CI fails on push/PR.

Unlike a local pre-commit hook, the CI guard:
- Protects against **all** contributors (not only those with a local hook configured)
- Requires no bootstrap after `git clone`
- Does not depend on hardcoded paths to sibling repos

The local hook remains an optional speed-up (fast feedback before push).

## Installation Into a New Pack Repo

```bash
cp -r IWE/pack-templates/.github/ <new-pack-repo>/
cd <new-pack-repo>
git add .github/
git commit -m "feat(ci): pack-lint R4 — ID collision detector"
git push
```

After the push, the first workflow run appears in the Actions tab.

## Contents

| File | Purpose |
|------|---------|
| `workflows/pack-lint.yml` | GitHub Action workflow (push/PR) |
| `scripts/check-pack-collisions.sh` | Standalone bash detector script |

The script is self-contained — no dependencies beyond `bash + git + grep + awk + sort + uniq + xargs + basename` (standard Unix utilities available in `ubuntu-latest`).

## What To Do on CI Fail

The CI prints the paths of the duplicate files:

```
❌ pack-lint [R4]: ID collisions detected:
  [DP.M.038]:
    pack/.../DP.M.038-personal-guide-onboarding.md
    pack/.../DP.M.038-idempotent-skill-distribution.md
```

Resolution:
1. Identify which file is "new" (created later / referenced less) — that file moves.
2. Rename it to the next available ID of the same type.
3. Update the `id:` field inside the file and all slug references to it across IWE.
4. Re-push.

## Origin

This template was created in Phase WP-5 F-pack-ci-guard (18 May 2026), as a continuation of Phase WP-7 F-PACK-COLLISIONS (where 14 collisions were resolved manually; the CI guard prevents regression).

See also:
- `knowledge-mcp/scripts/pack-lint.sh` — extended local linter (R1-R4)
- WP-5 F-pack-ci-guard — Phase context in the governance repo
- WP-7 F-PACK-COLLISIONS — source of the rule (14 collisions resolved manually)
