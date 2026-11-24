#!/usr/bin/env bash
# WP-529 Ф268: release from the release branch, main never stops.
#
# Runs the shell of the real workflow steps (extracted from the YAML, not copied) against
# throwaway repositories with a local bare "origin" and a stub `gh`; no network:
#   release.yml          — tag on the latest rc commit of release/vX.Y.Z; refusals (no rc, tip
#                          after the rc, wrong sha, no green Validate run, bad ref, manifest);
#                          "latest" only for the highest version; existing tag is a no-op;
#   release-candidate.yml — cut refuses while the previous release tag is not in main;
#   notify-update.yml    — the announcement is built from the release tag, not from main;
#   post-release-audit.yml — the prompt is read at the release tag, untagged version skipped.
# Also checks that every `${{ steps.X.outputs.Y }}` a step reads is written by step X.
set -uo pipefail
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WF="$ROOT/.github/workflows"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/iwe-f268.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

FAILS=0
ok()   { echo "  ok: $1"; }
fail() { echo "  FAIL: $1"; FAILS=$((FAILS + 1)); }

python3 -c 'import yaml' 2>/dev/null || { echo "FAIL: PyYAML is required"; exit 1; }

# extract_step <workflow> <job> <step name> <out file> [tmp dir replacing /tmp/]
extract_step() {
    python3 - "$@" <<'PY'
import sys, yaml
wf, job, name, out = sys.argv[1:5]
tmp = sys.argv[5] if len(sys.argv) > 5 else None
steps = yaml.safe_load(open(wf, encoding='utf-8'))['jobs'][job]['steps']
matches = [s for s in steps if s.get('name') == name]
if len(matches) != 1:
    sys.exit(f"step {name!r} found {len(matches)} times in {wf}")
run = matches[0]['run']
if '${{' in run:
    sys.exit(f"step {name!r} interpolates an expression into its script; pass it via env")
if tmp:
    run = run.replace('/tmp/', tmp.rstrip('/') + '/')
open(out, 'w', encoding='utf-8').write(run)
PY
}

echo "== step outputs read by later steps are written by those steps =="
if python3 - "$WF/release.yml" "$WF/release-candidate.yml" "$WF/notify-update.yml" "$WF/post-release-audit.yml" <<'PY'
import re, sys, yaml
ref = re.compile(r'\$\{\{\s*steps\.([\w-]+)\.outputs\.([\w-]+)\s*\}\}')
bad = []
for wf in sys.argv[1:]:
    doc = yaml.safe_load(open(wf, encoding='utf-8'))
    for job_name, job in doc['jobs'].items():
        steps = job.get('steps', [])
        by_id = {s['id']: s for s in steps if 'id' in s}
        for s in steps:
            texts = [str(v) for v in (s.get('env') or {}).values()] + [str(s.get('if', ''))]
            texts += [str(v) for v in (s.get('with') or {}).values()]
            for text in texts:
                for sid, out in ref.findall(text):
                    src = by_id.get(sid)
                    if src is None or not re.search(rf'\b{re.escape(out)}=', src.get('run', '')):
                        bad.append(f"{wf.split('/')[-1]}:{job_name}: steps.{sid}.outputs.{out}")
            # release.yml passes outputs as env named after them; the simulation below relies on it.
            if wf.endswith('/release.yml'):
                for key, val in (s.get('env') or {}).items():
                    m = ref.fullmatch(str(val).strip())
                    if m and key != m.group(2).upper():
                        bad.append(f"release.yml: env {key} carries output {m.group(2)}")
if bad:
    print("\n".join(bad))
    sys.exit(1)
PY
then ok "every step output read is written"; else fail "step output wiring"; fi

# ---------------------------------------------------------------- stub gh
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
case "$1" in
  api) cat "$GH_RUNS_FIXTURE" ;;
  release|workflow) exit 0 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH" GH_LOG="$TMP/gh.log" GH_RUNS_FIXTURE="$TMP/runs.json"

# runs_fixture <branch> <sha> <event> <conclusion> [<event> <conclusion> ...]
runs_fixture() {
    local branch=$1 sha=$2
    shift 2
    python3 - "$branch" "$sha" "$@" > "$GH_RUNS_FIXTURE" <<'PY'
import json, sys
branch, sha, rest = sys.argv[1], sys.argv[2], sys.argv[3:]
runs = [{"head_branch": branch, "head_sha": sha, "event": e, "conclusion": c}
        for e, c in zip(rest[::2], rest[1::2])]
print(json.dumps({"total_count": len(runs), "workflow_runs": runs}))
PY
}

# ---------------------------------------------------------------- fixture
FX="$TMP/fx"
W="$FX/work"
commit() { printf '%s\n' "$2" > "$W/$1"; git -C "$W" add "$1"; git -C "$W" commit -qm "$3"; }
manifest() { printf '{\n  "version": "%s"\n}\n' "$1" > "$W/update-manifest.json"; git -C "$W" add update-manifest.json; }
changelog() {  # changelog <version> <entry>: a new section on top of the existing ones
    { echo "# Changelog"; echo; echo "## [Unreleased]"; echo
      echo "## [$1] — 2026-11-20"; echo; echo "- [behavior] $2"
      sed -n '/^## \[[0-9]/,$p' "$W/CHANGELOG.md" 2>/dev/null; } > "$W/CHANGELOG.new"
    mv "$W/CHANGELOG.new" "$W/CHANGELOG.md"; git -C "$W" add CHANGELOG.md
}
old_tag() { GIT_COMMITTER_DATE="2026-01-01T00:00:00Z" git -C "$W" tag -a "$1" -m "$1" "${2:-HEAD}"; }

new_fixture() {
    rm -rf "$FX"; mkdir -p "$FX"
    git init -q --bare "$FX/origin.git"
    git init -q -b main "$W"
    git -C "$W" remote add origin "$FX/origin.git"
    mkdir -p "$W/setup"; echo "audit prompt 0.42" > "$W/setup/release-audit-prompt.md"; git -C "$W" add setup
    manifest 0.42.0; changelog 0.42.0 "old release entry"
    git -C "$W" commit -qm "release 0.42.0"
    old_tag v0.42.0
    commit m2 two "main 2"
    git -C "$W" push -q origin main v0.42.0
    # release/v0.43.0 cut from main; two candidates; main moves after the cut.
    git -C "$W" checkout -q -b release/v0.43.0
    manifest 0.43.0; changelog 0.43.0 "new thing for users"
    echo "audit prompt 0.43" > "$W/setup/release-audit-prompt.md"; git -C "$W" add setup
    git -C "$W" commit -qm "chore(release): v0.43.0"
    git -C "$W" tag -a v0.43.0-rc.1 -m rc1
    commit fix1 fix "release fix"
    git -C "$W" tag -a v0.43.0-rc.2 -m rc2
    git -C "$W" push -q origin release/v0.43.0 v0.43.0-rc.1 v0.43.0-rc.2
    git -C "$W" checkout -q main
    commit m3 three "main 3 after the cut"
    git -C "$W" push -q origin main
    RC1=$(git -C "$W" rev-parse 'v0.43.0-rc.1^{commit}')
    RC2=$(git -C "$W" rev-parse 'v0.43.0-rc.2^{commit}')
    runs_fixture release/v0.43.0 "$RC2" pull_request success push success
    : > "$GH_LOG"
}

# ---------------------------------------------------------------- release.yml simulation
RELEASE_STEPS=(
    "Check the version and the dispatch ref"
    "Check if tag already exists"
    "Check out the latest release candidate (WP-529 Ф239, Ф240, Ф268)"
    "Check that Validate Template passed on the candidate commit"
    "Extract CHANGELOG section for this version"
    "Decide the latest mark"
    "Create tag and GitHub release"
)
for i in "${!RELEASE_STEPS[@]}"; do
    extract_step "$WF/release.yml" release "${RELEASE_STEPS[$i]}" "$TMP/release-step-$i.sh" \
        || { echo "FAIL: cannot extract release.yml step '${RELEASE_STEPS[$i]}'"; exit 1; }
done

# release_flow <version> [dispatch ref] [expected sha]: runs the steps in order in the work
# clone, as the job does (exists=true skips the rest). Exit 0 when every step ran green.
release_flow() {
    local version=$1 ref=${2:-main} sha=${3:-} i key val
    rm -rf "$TMP/run"; mkdir -p "$TMP/run"
    : > "$TMP/flow.log"
    (
        export VERSION="$version" DISPATCH_REF="$ref" EXPECTED_SHA="$sha" REPO=owner/template
        export GITHUB_OUTPUT="$TMP/run/out" GITHUB_STEP_SUMMARY="$TMP/run/summary" RUNNER_TEMP="$TMP/run"
        cd "$W" || exit 99
        for i in "${!RELEASE_STEPS[@]}"; do
            : > "$GITHUB_OUTPUT"
            if ! bash --noprofile --norc -eo pipefail "$TMP/release-step-$i.sh" >> "$TMP/flow.log" 2>&1; then
                echo "${RELEASE_STEPS[$i]}" > "$TMP/run/failed_step"
                exit 1
            fi
            while IFS='=' read -r key val; do
                [ -n "$key" ] && export "$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')=$val"
            done < "$GITHUB_OUTPUT"
            [ "${EXISTS:-}" = true ] && exit 0
        done
        exit 0
    )
}
origin_tag_commit() { git -C "$FX/origin.git" rev-parse -q --verify "refs/tags/$1^{commit}" 2>/dev/null; }

echo "== release: the latest candidate on the branch, main moved after the cut =="
new_fixture
if release_flow 0.43.0; then ok "release flow passed"; else fail "release flow failed at: $(cat "$TMP/run/failed_step" 2>/dev/null)"; cat "$TMP/flow.log"; fi
[ "$(origin_tag_commit v0.43.0)" = "$RC2" ] && ok "v0.43.0 is on the rc.2 commit of the branch" \
  || fail "v0.43.0 must point at rc.2 ($RC2), got '$(origin_tag_commit v0.43.0)'"
grep -q -- "release create v0.43.0 .*--latest=true" "$GH_LOG" && ok "highest version gets --latest=true" \
  || fail "expected --latest=true in: $(cat "$GH_LOG")"
grep -q "new thing for users" "$TMP/run/release_body.md" && ok "release notes from the [0.43.0] section of the candidate" \
  || fail "release notes miss the candidate's section"
grep -q "head_sha=$RC2" "$GH_LOG" && ok "Validate runs are looked up for the candidate commit" \
  || fail "Validate lookup must name the rc commit"

echo "== release: tag already exists -> no-op =="
: > "$GH_LOG"
git -C "$W" fetch -q --tags origin
if release_flow 0.43.0 && ! grep -q "release create" "$GH_LOG"; then ok "existing v0.43.0 -> skipped, no new release"
else fail "existing tag must be a no-op"; fi

echo "== release: fix release of an older line -> not marked latest =="
git -C "$W" checkout -q -b release/v0.42.1 v0.42.0
manifest 0.42.1; changelog 0.42.1 "old line fix"; git -C "$W" commit -qm "chore(release): v0.42.1"
git -C "$W" tag -a v0.42.1-rc.1 -m rc
git -C "$W" push -q origin release/v0.42.1 v0.42.1-rc.1
git -C "$W" checkout -q main
runs_fixture release/v0.42.1 "$(git -C "$W" rev-parse 'v0.42.1-rc.1^{commit}')" push success
: > "$GH_LOG"
if release_flow 0.42.1 && grep -q -- "release create v0.42.1 .*--latest=false" "$GH_LOG"; then
  ok "0.42.1 after 0.43.0 -> --latest=false"
else fail "older line must get --latest=false: $(cat "$GH_LOG") / $(cat "$TMP/run/failed_step" 2>/dev/null)"; fi

expect_refusal() {  # expect_refusal <label> <expected step> <message fragment> <version> [ref] [sha]
    local label=$1 step=$2 msg=$3
    shift 3
    if release_flow "$@"; then fail "$label: expected a refusal"; return; fi
    if [ "$(cat "$TMP/run/failed_step")" = "$step" ] && grep -q -- "$msg" "$TMP/flow.log"; then
        ok "$label"
    else
        fail "$label: failed at '$(cat "$TMP/run/failed_step")', log: $(tail -3 "$TMP/flow.log")"
    fi
    [ -z "$(origin_tag_commit "v$1")" ] || fail "$label: tag v$1 must not exist"
}
RC_STEP="${RELEASE_STEPS[2]}"

echo "== release refusals =="
new_fixture
git -C "$W" checkout -q release/v0.43.0
commit late unchecked "commit after the last candidate"
git -C "$W" push -q origin release/v0.43.0
git -C "$W" checkout -q main
expect_refusal "branch tip after the last rc -> refused" "$RC_STEP" "непроверенные коммиты" 0.43.0

new_fixture
expect_refusal "explicit sha of an older rc -> refused" "$RC_STEP" "не последний кандидат" 0.43.0 main "$RC1"

new_fixture
git -C "$W" push -q origin :refs/tags/v0.43.0-rc.1 :refs/tags/v0.43.0-rc.2
git -C "$W" tag -d v0.43.0-rc.1 v0.43.0-rc.2 >/dev/null
expect_refusal "no candidate at all -> refused (Ф240)" "$RC_STEP" "нет кандидата" 0.43.0

new_fixture
runs_fixture release/v0.43.0 "$RC2" pull_request success push failure
expect_refusal "only a pull_request run is green -> refused" "${RELEASE_STEPS[3]}" "нет успешной проверки" 0.43.0
runs_fixture main "$RC2" push success
expect_refusal "green run on another branch -> refused" "${RELEASE_STEPS[3]}" "нет успешной проверки" 0.43.0

new_fixture
expect_refusal "dispatch from a feature branch -> refused" "${RELEASE_STEPS[0]}" "Выпуск запускается с main" 0.43.0 feature
expect_refusal "bad version -> refused" "${RELEASE_STEPS[0]}" "вида X.Y.Z" 0.43
expect_refusal "no release branch -> refused" "$RC_STEP" "Ветки release/v0.44.0 нет" 0.44.0

new_fixture
git -C "$W" checkout -q -b release/v0.44.0 main
commit x x "branch without its bump"
git -C "$W" tag -a v0.44.0-rc.1 -m rc
git -C "$W" push -q origin release/v0.44.0 v0.44.0-rc.1
git -C "$W" checkout -q main
expect_refusal "manifest of another version on the candidate -> refused" "$RC_STEP" "версия '0.42.0'" 0.44.0

# ---------------------------------------------------------------- cut precondition
echo "== cut: the previous release must be in main =="
extract_step "$WF/release-candidate.yml" cut "Check that the previous release came back to main" "$TMP/cut-prev.sh" \
  || { echo "FAIL: cannot extract the cut step"; exit 1; }
cut_check() { (cd "$W" && git fetch -q origin && GITHUB_OUTPUT=/dev/null bash --noprofile --norc -eo pipefail "$TMP/cut-prev.sh") > "$TMP/cut.log" 2>&1; }
new_fixture
release_flow 0.43.0 || fail "setup: release 0.43.0 failed"
git -C "$W" fetch -q --tags origin
if cut_check; then fail "cut must refuse while v0.43.0 is not in main"
elif grep -q "v0.43.0 ещё не влит" "$TMP/cut.log"; then ok "v0.43.0 released, PR not merged -> cut refused"
else fail "cut refusal must name v0.43.0: $(cat "$TMP/cut.log")"; fi
git -C "$W" checkout -q main
git -C "$W" merge -q --no-edit release/v0.43.0
git -C "$W" push -q origin main
if cut_check; then ok "release PR merged back -> cut allowed"; else fail "cut after the back-merge: $(cat "$TMP/cut.log")"; fi

# ---------------------------------------------------------------- notify-update.yml
echo "== notify-update: the announcement comes from the release tag =="
mkdir -p "$TMP/nt"
extract_step "$WF/notify-update.yml" build "Find releases to announce" "$TMP/nt-find.sh" "$TMP/nt" \
  && extract_step "$WF/notify-update.yml" build "Extract changelog entries at the release tags" "$TMP/nt-extract.sh" "$TMP/nt" \
  || { echo "FAIL: cannot extract notify-update steps"; exit 1; }
notify() {  # notify [force version]
    rm -f "$TMP/nt/"*; : > "$TMP/nt/out"
    (cd "$W" && export GITHUB_OUTPUT="$TMP/nt/out" FORCE_VERSION="${1:-}" \
        && bash --noprofile --norc -eo pipefail "$TMP/nt-find.sh" \
        && { ! grep -q has_changes=true "$GITHUB_OUTPUT" || bash --noprofile --norc -eo pipefail "$TMP/nt-extract.sh"; }) \
        > "$TMP/nt.log" 2>&1
}
new_fixture
if notify && grep -q has_changes=false "$TMP/nt/out"; then ok "no release tag in 24 h (rc tags only) -> nothing to announce"
else fail "rc tags must not be announced: $(cat "$TMP/nt.log")"; fi
release_flow 0.43.0 || fail "setup: release 0.43.0 failed"
git -C "$W" fetch -q --tags origin
# The scheduled run checks out main, which still has no [0.43.0] section and the old audit
# prompt: the release PR is not merged.
git -C "$W" checkout -q main
if notify && grep -q has_changelog=true "$TMP/nt/out" && grep -q "new thing for users" "$TMP/nt/changelog_entry.txt" \
   && grep -q '^\[0.43.0\]' "$TMP/nt/changelog_version.txt"; then
  ok "v0.43.0 announced from its tag before the release PR reaches main"
else fail "announcement from the tag: $(cat "$TMP/nt.log")"; fi
grep -qx fix1 "$TMP/nt/changed_files.txt" && ! grep -qx m3 "$TMP/nt/changed_files.txt" \
  && ok "changed files: v0.42.0..v0.43.0, main-only commits excluded" \
  || fail "changed files: $(tr '\n' ' ' < "$TMP/nt/changed_files.txt")"
if notify 0.42.0 && grep -q "old release entry" "$TMP/nt/changelog_entry.txt" \
   && ! grep -q "new thing" "$TMP/nt/changelog_entry.txt"; then
  ok "explicit version 0.42.0 -> its own section only"
else fail "forced version: $(cat "$TMP/nt.log")"; fi
if notify 0.45.0; then fail "untagged forced version must fail"; else ok "untagged forced version -> refused"; fi

# ---------------------------------------------------------------- post-release-audit.yml
echo "== post-release-audit: prompt read at the release tag =="
extract_step "$WF/post-release-audit.yml" create-audit-issue "Read the audit prompt at the release tag" "$TMP/pra.sh" \
  || { echo "FAIL: cannot extract the audit step"; exit 1; }
pra() { rm -rf "$TMP/pra"; mkdir -p "$TMP/pra"; : > "$TMP/pra/out"
    (cd "$W" && GITHUB_OUTPUT="$TMP/pra/out" RUNNER_TEMP="$TMP/pra" VERSION="$1" \
        bash --noprofile --norc -eo pipefail "$TMP/pra.sh") > /dev/null 2>&1; }
if pra 0.43.0 && grep -q released=true "$TMP/pra/out" && grep -q "audit prompt 0.43" "$TMP/pra/release-audit-prompt.md"; then
  ok "released version -> prompt from the tag (main still has the old prompt)"
else fail "audit prompt at the tag"; fi
if pra 0.44.0 && grep -q released=false "$TMP/pra/out"; then ok "untagged version -> no reminder"
else fail "untagged version must be skipped"; fi

echo
if [ "$FAILS" -gt 0 ]; then
  echo "FAILED: $FAILS check(s)"
  exit 1
fi
echo "PASS"
