#!/usr/bin/env bash
# shellcheck disable=SC2329  # setup_* helpers are called through long_case "$setup"
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


# Long inputs (WP-529 Ф248, 03.11.2026). grep -q in a pipeline under pipefail killed the
# writer with SIGPIPE: a trailer in a long commit body was missed (false refusal), and a long
# list of delivery subjects hid an ordinary commit (false pass). Each case checks the exit
# code and the reason line.
FILLER_LINES=3000   # ~300 KB of body, well above a pipe buffer
DELIVERIES=3000     # ~300 KB of subjects

new_repo() {
    local repo="$1"
    mkdir -p "$repo/.github" "$repo/scripts"
    git -C "$repo" init -q -b main
    git -C "$repo" config user.email t@example.com
    git -C "$repo" config user.name t
    printf 'scripts/sourced.sh\n' > "$repo/.github/author-sourced-paths.txt"
    echo base > "$repo/scripts/sourced.sh"
    git -C "$repo" add .github/author-sourced-paths.txt scripts/sourced.sh
    git -C "$repo" commit -q -m base
    git -C "$repo" tag start
}

commit_edit() {  # repo message_file
    echo changed >> "$1/scripts/sourced.sh"
    git -C "$1" add scripts/sourced.sh
    git -C "$1" commit -q -F "$2"
}

long_message() {  # file subject trailer_line
    { echo "$2"; echo; [ -z "$3" ] || { echo "$3"; echo; }
      for _ in $(seq "$FILLER_LINES"); do printf '%0100d\n' 0; done; } > "$1"
}

add_deliveries() {  # repo: empty delivery commits on top of HEAD
    local repo="$1" tree parent i
    tree=$(git -C "$repo" write-tree); parent=$(git -C "$repo" rev-parse HEAD)
    for i in $(seq "$DELIVERIES"); do
        parent=$(printf 'template-sync: propagate %05d %080d\n' "$i" 0 \
            | git -C "$repo" commit-tree "$tree" -p "$parent")
    done
    git -C "$repo" reset -q --soft "$parent"
}

setup_long_body_trailer() { long_message "$1.msg" "fix: edit" "Author-Source: author-repo#42"; commit_edit "$1" "$1.msg"; }
setup_long_body_plain()   { long_message "$1.msg" "fix: edit" ""; commit_edit "$1" "$1.msg"; }
setup_deliveries_then_ordinary() { add_deliveries "$1"; echo "fix: ordinary edit" > "$1.msg"; commit_edit "$1" "$1.msg"; }
setup_deliveries_only() { echo "template-sync: propagate 2026-11-03" > "$1.msg"; commit_edit "$1" "$1.msg"; add_deliveries "$1"; }
setup_mixed() { echo "template-sync: propagate 2026-11-03" > "$1.msg"; commit_edit "$1" "$1.msg"; echo "fix: edit" > "$1.msg"; commit_edit "$1" "$1.msg"; }

long_case() {  # name expected_rc reason pr_body base_ref setup_fn [list_path]
    local name="$1" expect="$2" reason="$3" body="$4" base="$5" setup="$6" list="${7:-}" rc out
    local repo="$WORK/$name"
    new_repo "$repo"; "$setup" "$repo"
    set +e
    out=$(cd "$repo" && PR_BODY="$body" AUTHOR_SOURCED_LIST="${list:-.github/author-sourced-paths.txt}" \
        bash "$GATE" "$base" HEAD 2>&1)
    rc=$?
    set -e
    if [ "$rc" -eq "$expect" ] && grep -qF -- "$reason" <<<"$out"; then
        echo "ok   $name (rc=$rc)"
    else
        echo "FAIL $name: expected rc=$expect with \"$reason\", got rc=$rc: $(head -1 <<<"$out")"; fail=1
    fi
}

long_case long-body-trailer-in-commit 0 "trailer found"            ""                              start setup_long_body_trailer
long_case long-body-trailer-in-pr     0 "trailer found"            "Author-Source: author-repo#42" start setup_long_body_plain
long_case deliveries-then-ordinary    1 "files that have an author source" ""                      start setup_deliveries_then_ordinary
long_case deliveries-only             0 "template-sync deliveries" ""                              start setup_deliveries_only
long_case mixed-no-trailer            1 "files that have an author source" ""                      start setup_mixed
long_case unknown-base                2 "failed"                   "Author-Source: author-repo#42" deadbeef setup_mixed
# A list that grep cannot read must stop the gate, not pass it. Root reads any file, so skip there.
setup_unreadable_list() { setup_mixed "$1"; cp "$1/.github/author-sourced-paths.txt" "$1/locked-list"; chmod 000 "$1/locked-list"; }
if [ "$(id -u)" -ne 0 ]; then
    long_case unreadable-list         2 "grep over changed files failed" "Author-Source: author-repo#42" start setup_unreadable_list locked-list
else
    echo "skip unreadable-list (running as root)"
fi

[ "$fail" -eq 0 ] && echo "all cases passed"
exit "$fail"
