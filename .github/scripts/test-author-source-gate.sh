#!/usr/bin/env bash
# Behavioural test of author-source-gate.sh on a throwaway git repository.
# Each case builds a base commit and a head commit, runs the gate and checks the exit code.
set -euo pipefail

GATE="$(cd "$(dirname "$0")" && pwd)/author-source-gate.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail=0

run_case() {  # name expected_rc commit_subject pr_body list_content changed_path
    local name="$1" expect="$2" subject="$3" body="$4" list="$5" path="$6" rc
    local repo="$WORK/$name"
    mkdir -p "$repo/.github" "$repo/scripts"
    git -C "$repo" init -q -b main
    git -C "$repo" config user.email t@example.com
    git -C "$repo" config user.name t
    printf '%s' "$list" > "$repo/.github/author-sourced-paths.txt"
    echo base > "$repo/scripts/sourced.sh"; echo base > "$repo/scripts/free.sh"
    git -C "$repo" add -A && git -C "$repo" commit -q -m base
    echo changed >> "$repo/$path"
    git -C "$repo" add -A && git -C "$repo" commit -q -m "$subject"
    set +e
    (cd "$repo" && PR_BODY="$body" bash "$GATE" HEAD~1 HEAD >/dev/null 2>&1)
    rc=$?
    set -e
    if [ "$rc" -eq "$expect" ]; then echo "ok   $name (rc=$rc)"; else echo "FAIL $name: expected rc=$expect, got $rc"; fail=1; fi
}

LIST=$'scripts/sourced.sh\n'
run_case sourced-file-no-trailer      1 "fix: edit"                         ""                          "$LIST" scripts/sourced.sh
run_case sourced-file-trailer-in-body 0 "fix: edit"                         "Author-Source: author-repo#42" "$LIST" scripts/sourced.sh
run_case sourced-file-trailer-sha     0 "fix: edit"                         "Author-Source: 8a453cf525"        "$LIST" scripts/sourced.sh
run_case sourced-file-pending         0 "fix: edit"                         "Author-Source: pending #7"        "$LIST" scripts/sourced.sh
run_case sourced-file-bad-trailer     1 "fix: edit"                         "Author-Source: later"             "$LIST" scripts/sourced.sh
run_case free-file                    0 "fix: edit"                         ""                          "$LIST" scripts/free.sh
run_case sync-delivery                0 "template-sync: propagate 2026-11-03" ""                       "$LIST" scripts/sourced.sh
run_case list-missing                 0 "fix: edit"                         ""                          ""      scripts/sourced.sh

[ "$fail" -eq 0 ] && echo "all cases passed"
exit "$fail"
