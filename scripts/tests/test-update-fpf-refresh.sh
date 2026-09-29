#!/usr/bin/env bash
# WP-5 F57: update.sh must refresh the installed FPF copy (fast-forward only),
# so users receive USING-FPF.md and newer DPF Suites; a modified or diverged copy
# must be left untouched and must not fail the update.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Guard the wiring itself, not just the function body.
if ! awk '/^run_post_apply_backfills_or_die\(\)/,/^}/' "$ROOT/update.sh" \
    | grep -q 'refresh_fpf_base_clone'; then
    echo 'post-apply chain does not call refresh_fpf_base_clone' >&2
    exit 1
fi

eval "$(awk '
  /^refresh_fpf_base_clone\(\)/ { capture=1 }
  capture { print }
  capture && /^}/ { exit }
' "$ROOT/update.sh")"
declare -F refresh_fpf_base_clone >/dev/null

# Isolate from the developer's own git configuration (pull.rebase, merge.ff, ...).
export GIT_CONFIG_GLOBAL="$TMP/gitconfig" GIT_CONFIG_NOSYSTEM=1
: > "$GIT_CONFIG_GLOBAL"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
git_q() { git -c init.defaultBranch=main "$@" >/dev/null 2>&1; }

ORIGIN="$TMP/origin.git"
UPSTREAM="$TMP/upstream"
WORKSPACE_DIR="$TMP/workspace"
mkdir -p "$WORKSPACE_DIR"
git_q init --bare "$ORIGIN"
git_q clone "$ORIGIN" "$UPSTREAM"
echo one > "$UPSTREAM/Readme.md"
git -C "$UPSTREAM" add Readme.md
git_q -C "$UPSTREAM" commit -m first
git_q -C "$UPSTREAM" push origin HEAD:main
git_q clone "$ORIGIN" "$WORKSPACE_DIR/FPF"

publish_upstream() {
    echo "$2" > "$UPSTREAM/$1"
    git -C "$UPSTREAM" add "$1"
    git_q -C "$UPSTREAM" commit -m "add $1"
    git_q -C "$UPSTREAM" push origin HEAD:main
}
fail() { echo "FAIL: $*" >&2; exit 1; }

# 1. Behind upstream, clean tree -> fast-forwarded, the new file arrives.
publish_upstream USING-FPF.md instruction
out=$(refresh_fpf_base_clone)
[ -f "$WORKSPACE_DIR/FPF/USING-FPF.md" ] || fail "case 1: USING-FPF.md did not arrive"
grep -q 'обновлена' <<<"$out" || fail "case 1: no 'обновлена' report: $out"

# 2. Already current -> reported as current, HEAD unchanged.
head_before=$(git -C "$WORKSPACE_DIR/FPF" rev-parse HEAD)
out=$(refresh_fpf_base_clone)
[ "$head_before" = "$(git -C "$WORKSPACE_DIR/FPF" rev-parse HEAD)" ] || fail "case 2: HEAD moved"
grep -q 'актуальна' <<<"$out" || fail "case 2: no 'актуальна' report: $out"

# 3. Locally modified tracked file -> untouched, warning, function still succeeds.
publish_upstream second.md two
echo local-edit >> "$WORKSPACE_DIR/FPF/Readme.md"
head_before=$(git -C "$WORKSPACE_DIR/FPF" rev-parse HEAD)
out=$(refresh_fpf_base_clone)
[ "$head_before" = "$(git -C "$WORKSPACE_DIR/FPF" rev-parse HEAD)" ] || fail "case 3: HEAD moved on a dirty copy"
grep -q 'local-edit' "$WORKSPACE_DIR/FPF/Readme.md" || fail "case 3: local edit lost"
[ ! -f "$WORKSPACE_DIR/FPF/second.md" ] || fail "case 3: upstream file arrived into a dirty copy"
grep -q 'локальные изменения' <<<"$out" || fail "case 3: no warning: $out"
git -C "$WORKSPACE_DIR/FPF" checkout -q -- Readme.md

# 4. Diverged history -> untouched, warning, function still succeeds.
echo mine > "$WORKSPACE_DIR/FPF/mine.md"
git -C "$WORKSPACE_DIR/FPF" add mine.md
git_q -C "$WORKSPACE_DIR/FPF" commit -m local-commit
head_before=$(git -C "$WORKSPACE_DIR/FPF" rev-parse HEAD)
out=$(refresh_fpf_base_clone)
[ "$head_before" = "$(git -C "$WORKSPACE_DIR/FPF" rev-parse HEAD)" ] || fail "case 4: HEAD moved on a diverged copy"
[ -f "$WORKSPACE_DIR/FPF/mine.md" ] || fail "case 4: local commit lost"
grep -q 'не обновлена' <<<"$out" || fail "case 4: no warning: $out"

# 5. No copy installed -> skipped without error.
rm -rf "$WORKSPACE_DIR/FPF"
out=$(refresh_fpf_base_clone)
grep -q 'не найдена' <<<"$out" || fail "case 5: no skip message: $out"

# 6. Explicit opt-out is honoured.
git_q clone "$ORIGIN" "$WORKSPACE_DIR/FPF"
git_q -C "$WORKSPACE_DIR/FPF" reset --hard HEAD~1
head_before=$(git -C "$WORKSPACE_DIR/FPF" rev-parse HEAD)
out=$(IWE_SKIP_FPF_REFRESH=1 refresh_fpf_base_clone)
[ "$head_before" = "$(git -C "$WORKSPACE_DIR/FPF" rev-parse HEAD)" ] || fail "case 6: HEAD moved despite opt-out"
grep -q 'IWE_SKIP_FPF_REFRESH' <<<"$out" || fail "case 6: no opt-out message: $out"

fresh_copy() {  # $1 = extra clone args
    rm -rf "$WORKSPACE_DIR/FPF"
    # shellcheck disable=SC2086
    git_q clone $1 "file://$ORIGIN" "$WORKSPACE_DIR/FPF"
}
assert_untouched() {  # $1 = case label, $2 = HEAD before
    [ "$2" = "$(git -C "$WORKSPACE_DIR/FPF" rev-parse HEAD)" ] || fail "$1: HEAD moved"
}

# 7. Diverged copy with the user's own pull.rebase=true -> still untouched (the
#    function must not depend on pull.* settings).
fresh_copy ""
echo mine > "$WORKSPACE_DIR/FPF/mine2.md"
git -C "$WORKSPACE_DIR/FPF" add mine2.md
git_q -C "$WORKSPACE_DIR/FPF" commit -m local-commit-2
publish_upstream third.md three
head_before=$(git -C "$WORKSPACE_DIR/FPF" rev-parse HEAD)
printf '[pull]\n\trebase = true\n' > "$GIT_CONFIG_GLOBAL"
out=$(refresh_fpf_base_clone)
: > "$GIT_CONFIG_GLOBAL"
assert_untouched "case 7" "$head_before"
[ -f "$WORKSPACE_DIR/FPF/mine2.md" ] || fail "case 7: local commit lost"
grep -q 'не обновлена' <<<"$out" || fail "case 7: no warning: $out"

# 8. Shallow clone (what a size-limited install would have) behind upstream by
#    two commits -> fast-forwarded.
fresh_copy "--depth=1"
publish_upstream fourth.md four
publish_upstream fifth.md five
out=$(refresh_fpf_base_clone)
[ -f "$WORKSPACE_DIR/FPF/fifth.md" ] || fail "case 8: shallow copy not updated: $out"

# 9. Detached HEAD (no tracked upstream) -> untouched, no failure.
fresh_copy ""
git_q -C "$WORKSPACE_DIR/FPF" checkout --detach HEAD~1
publish_upstream sixth.md six
head_before=$(git -C "$WORKSPACE_DIR/FPF" rev-parse HEAD)
out=$(refresh_fpf_base_clone)
assert_untouched "case 9" "$head_before"
grep -q 'не обновлена' <<<"$out" || fail "case 9: no warning: $out"

# 10. Untracked local file that collides with an incoming file -> untouched, kept.
fresh_copy ""
git_q -C "$WORKSPACE_DIR/FPF" reset --hard HEAD~1
head_before=$(git -C "$WORKSPACE_DIR/FPF" rev-parse HEAD)
echo precious > "$WORKSPACE_DIR/FPF/sixth.md"
out=$(refresh_fpf_base_clone)
assert_untouched "case 10" "$head_before"
grep -q precious "$WORKSPACE_DIR/FPF/sixth.md" || fail "case 10: untracked file overwritten"
rm -f "$WORKSPACE_DIR/FPF/sixth.md"

# 11. Staged (not yet committed) edit counts as a local change -> untouched.
fresh_copy ""
git_q -C "$WORKSPACE_DIR/FPF" reset --hard HEAD~1
echo staged >> "$WORKSPACE_DIR/FPF/Readme.md"
git -C "$WORKSPACE_DIR/FPF" add Readme.md
head_before=$(git -C "$WORKSPACE_DIR/FPF" rev-parse HEAD)
out=$(refresh_fpf_base_clone)
assert_untouched "case 11" "$head_before"
grep -q 'локальные изменения' <<<"$out" || fail "case 11: no warning: $out"

# 12. Unreachable origin -> warning, copy untouched, function still succeeds.
fresh_copy ""
git_q -C "$WORKSPACE_DIR/FPF" reset --hard HEAD~1
git -C "$WORKSPACE_DIR/FPF" remote set-url origin "file://$TMP/does-not-exist.git"
head_before=$(git -C "$WORKSPACE_DIR/FPF" rev-parse HEAD)
out=$(refresh_fpf_base_clone) || fail "case 12: function returned non-zero"
assert_untouched "case 12" "$head_before"
grep -q 'не удалось получить' <<<"$out" || fail "case 12: no warning: $out"

# 13. The call site is `refresh_fpf_base_clone || true` under `set -e`: a failing
#     step must never abort the update.
( set -e; refresh_fpf_base_clone >/dev/null || true; echo survived ) | grep -q survived \
    || fail "case 13: update aborted"

echo "PASS: 13 cases"
