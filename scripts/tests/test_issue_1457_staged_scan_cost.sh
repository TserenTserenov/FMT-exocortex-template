#!/usr/bin/env bash
# Issue #1457: validate-template.sh --mode=staged must export the index once
# and scan it with recursive greps, not fork `git show` per staged file and
# pattern (35+ minutes on Git Bash for ~440 staged files). Findings must stay
# the same: planted author tokens are reported with repo-relative paths,
# excluded paths stay excluded, unstaged-only content only warns.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TEST_ROOT"' EXIT
REPO="$TEST_ROOT/repo"
SHIM_DIR="$TEST_ROOT/shim"
GIT_LOG="$TEST_ROOT/git-calls.log"
SNAPSHOT_TMP="$TEST_ROOT/tmp"
TOKEN="DS-my""-strategy"
HOMEBREW="/opt""/homebrew"
BULK_DIR="extensions/issue-1457"
PLANTED="$BULK_DIR/planted file.md"

pass_count=0
pass() { echo "  PASS: $*"; pass_count=$((pass_count + 1)); }
fail() { echo "  FAIL: $*" >&2; [ -n "${output:-}" ] && echo "$output" >&2; exit 1; }

git clone --quiet --no-hardlinks "$ROOT" "$REPO"
cp "$ROOT/setup/validate-template.sh" "$REPO/setup/validate-template.sh"
git -C "$REPO" add -- setup/validate-template.sh

# ~200 staged files, one of them with a space in its name and an author token.
mkdir -p "$REPO/$BULK_DIR"
for i in $(seq 1 199); do
    printf '# bulk %s\nneutral text\n' "$i" > "$REPO/$BULK_DIR/bulk-$i.md"
done
printf 'line one\ngovernance: %s\n' "$TOKEN" > "$REPO/$PLANTED"
# Same token in a path the manifest freezes out of delivery (#547): ignored.
excluded=$(jq -r '[.excluded_paths[] | select(endswith(".md"))][0]' "$REPO/update-manifest.json")
[ -n "$excluded" ] && [ "$excluded" != null ] || fail "no excluded .md path in update-manifest.json"
mkdir -p "$REPO/$(dirname "$excluded")"
printf '\nexcluded mention: %s\n' "$TOKEN" >> "$REPO/$excluded"
git -C "$REPO" add -- "$BULK_DIR" "$excluded"
staged_total=$(git -C "$REPO" diff --cached --name-only | wc -l | tr -d ' ')
[ "$staged_total" -ge 200 ] || fail "expected >=200 staged files, got $staged_total"

# Unstaged-only token in a tracked file: a warning, never a failure.
printf '\nunstaged: %s\n' "$TOKEN" >> "$REPO/README.md"

# PATH shim that records every git invocation, then runs the real git.
REAL_GIT=$(command -v git)
mkdir -p "$SHIM_DIR" "$SNAPSHOT_TMP"
cat > "$SHIM_DIR/git" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$GIT_LOG"
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$SHIM_DIR/git"

run_staged() {
    : > "$GIT_LOG"
    rc=0
    output=$(cd "$REPO" && PATH="$SHIM_DIR:$PATH" TMPDIR="$SNAPSHOT_TMP" \
        bash setup/validate-template.sh --mode=staged . 2>&1) || rc=$?
}

start=$SECONDS
run_staged
elapsed=$((SECONDS - start))

[ "$rc" -ne 0 ] || fail "staged mode accepted a staged author token"
grep -qF "Found '$TOKEN' (global) in 1 locations:" <<<"$output" \
    || fail "planted token not counted exactly once (excluded path or unstaged file leaked in)"
grep -qF "$PLANTED:2:governance: $TOKEN" <<<"$output" \
    || fail "hit not reported as <repo-relative path>:<line>:<text>"
pass "staged token found once, with a repo-relative path containing a space"

if grep -qF "$excluded" <<<"$output"; then fail "excluded_paths hit reported in staged mode"; fi
pass "excluded_paths stay excluded in staged mode"

grep -qF 'WARN (staged mode): unstaged files contain forbidden patterns' <<<"$output" \
    || fail "unstaged-only token produced no warning"
pass "unstaged-only token warns instead of failing"

show_calls=$(grep -cE '(^| )show( |$)' "$GIT_LOG" || true)
export_calls=$(grep -c 'checkout-index' "$GIT_LOG" || true)
[ "$show_calls" -eq 0 ] || fail "git show ran $show_calls times; staged content must be exported once"
[ "$export_calls" -eq 1 ] || fail "git checkout-index ran $export_calls times, expected 1"
pass "index exported once for $staged_total staged files (git show: 0, checkout-index: 1)"

[ "$elapsed" -lt 120 ] || fail "staged scan of $staged_total files took ${elapsed}s (bound 120s)"
pass "staged scan finished in ${elapsed}s"

leftover=$(find "$SNAPSHOT_TMP" -mindepth 1 | head -1)
[ -z "$leftover" ] || fail "staged snapshot left behind: $leftover"
pass "staged snapshot removed on exit"

# Checks 2/3 read the same snapshot: a staged Homebrew path is still blocked
# and reported relative to the repo root.
git -C "$REPO" checkout --quiet -- README.md
printf 'governance: "{{GOVERNANCE_REPO}}"\n' > "$REPO/$PLANTED"
printf 'tool: %s/bin/private-tool\n' "$HOMEBREW" > "$REPO/$BULK_DIR/brew.md"
git -C "$REPO" add -- "$PLANTED" "$BULK_DIR/brew.md"
git -C "$REPO" reset --quiet -- "$excluded"
git -C "$REPO" checkout --quiet -- "$excluded"
run_staged
[ "$rc" -ne 0 ] || fail "staged Homebrew path accepted"
grep -qF "[1/5] Author-specific content... PASS" <<<"$output" || fail "author check did not pass after cleanup"
grep -qF "Hardcoded $HOMEBREW paths... FAIL (1 hits)" <<<"$output" || fail "Homebrew hit not counted"
grep -qF "$BULK_DIR/brew.md:1:tool: $HOMEBREW/bin/private-tool" <<<"$output" \
    || fail "Homebrew hit not reported with a repo-relative path"
if grep -qF "$SNAPSHOT_TMP" <<<"$output"; then fail "snapshot path leaked into the report"; fi
pass "checks 2/3 scan the staged snapshot and report repo-relative paths"

# A staged rename carries content out of an excluded path (review-01 H3):
# R100 must be scanned at its new path like an added file.
git -C "$REPO" reset --quiet --hard
cp "$ROOT/setup/validate-template.sh" "$REPO/setup/validate-template.sh"  # the version under test, unstaged
printf '\nexcluded mention: %s\n' "$TOKEN" >> "$REPO/$excluded"
git -C "$REPO" add -- "$excluded"
fixture_commit=$(git -C "$REPO" commit-tree "$(git -C "$REPO" write-tree)" -p HEAD -m "fixture: token in an excluded path")
git -C "$REPO" update-ref HEAD "$fixture_commit"
mkdir -p "$REPO/$BULK_DIR"
moved="$BULK_DIR/moved-out.md"
git -C "$REPO" mv -- "$excluded" "$moved"
git -C "$REPO" diff --cached --name-status | grep -q "^R100" || fail "fixture is not a pure rename"
run_staged
[ "$rc" -ne 0 ] || fail "staged rename out of an excluded path accepted"
grep -qF "$moved:" <<<"$output" || fail "renamed file not reported at its new path"
pass "a staged rename out of an excluded path is scanned at its new path"

echo "PASS: issue 1457 staged scan cost ($pass_count checks)"
