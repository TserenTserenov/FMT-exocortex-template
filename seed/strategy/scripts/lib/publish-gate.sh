#!/bin/bash
# publish-gate.sh -- shared predicate + routing primitives for publishing a
# commit into a repo that may or may not need the ds-publish.sh coordination
# gate (flock queue + isolate-push.sh fetch/cherry-pick/push/retry).
#
# issue #1102: extractor.sh has looked for this file at
# scripts/lib/publish-gate.sh since WP-5 F48, but it never shipped with the
# template -- only the author's own IWE had a copy. Every install silently
# fell back to a raw `git push` with no retry on a stale origin/main, and
# extractor.sh's own fallback branch logs exactly that. Ported here from the
# author's checkout, parameterized on IWE_GOVERNANCE_REPO instead of the
# hardcoded governance repo name it used internally.
#
# Functions:
#   normalize_remote_url <url>                           -- pure string transform
#   is_ds_repo_by_origin <repo-dir>                       -- pure predicate
#   publish_commit <repo-dir> <sha> <priority> <reason>   -- routes via ds-publish.sh
#   push_branch <repo-dir>                                -- plain `git push`
#
# Each caller decides which repos need `publish_commit` (identity check) vs.
# `push_branch` (no check) -- this library does not decide priority or reason
# text, only mechanics. IWE_ROOT and IWE_GOVERNANCE_REPO must be set by the
# caller before sourcing (default to $HOME/IWE and DS-strategy if unset).

IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"

# normalize_remote_url <url> -- strips protocol/creds/.git so
# "git@github.com:org/repo.git" and "https://x:tok@github.com/org/repo.git"
# compare equal. Scheme and optional user@ stripped in separate substitutions
# (a combined pattern silently ate the hostname on creds-less https URLs --
# found in code review 2026-08-12).
normalize_remote_url() {
    sed -E 's#^[a-zA-Z][a-zA-Z0-9+.-]*://##; s#^[^@/]*@##; s#:#/#; s#\.git$##' <<<"$1"
}

# is_ds_repo_by_origin <repo-dir> -- true iff <repo-dir>'s origin matches the
# governance repo's origin, compared by normalized URL, not by path (an
# isolated worktree of the governance repo has a different path but the same
# origin, and must route through the gate the same as the canonical
# checkout).
GOVERNANCE_ORIGIN_NORMALIZED=""
is_ds_repo_by_origin() {  # <repo-dir>
    local repo="$1" repo_remote gov_repo="${IWE_GOVERNANCE_REPO:-DS-strategy}"
    if [[ -z "$GOVERNANCE_ORIGIN_NORMALIZED" ]]; then
        local canonical_remote
        canonical_remote=$(git -C "$IWE_ROOT/$gov_repo" remote get-url origin 2>/dev/null) || return 1
        GOVERNANCE_ORIGIN_NORMALIZED=$(normalize_remote_url "$canonical_remote")
    fi
    repo_remote=$(git -C "$repo" remote get-url origin 2>/dev/null) || return 1
    [[ "$(normalize_remote_url "$repo_remote")" == "$GOVERNANCE_ORIGIN_NORMALIZED" ]]
}

# publish_commit <repo-dir> <sha> <priority> <reason> -- publishes <sha> from
# <repo-dir> through the shared ds-publish.sh gate. Always runs the CANONICAL
# ds-publish.sh ($IWE_ROOT/<governance repo>/scripts/ds-publish.sh), regardless
# of which checkout the caller itself lives in -- warns, doesn't block, if the
# caller's own copy has drifted from canonical (a false block would be worse
# than a stale-copy warning on this critical path).
publish_commit() {  # <repo-dir> <sha> <priority> <reason> [branch]
    local repo="$1" sha="$2" priority="$3" reason="$4" branch="${5:-}"
    local gov_repo="${IWE_GOVERNANCE_REPO:-DS-strategy}"
    local canonical_publish="$IWE_ROOT/$gov_repo/scripts/ds-publish.sh"
    local self_publish="$(dirname "${BASH_SOURCE[0]}")/../ds-publish.sh"
    if [[ -f "$self_publish" && -f "$canonical_publish" ]] && \
       ! cmp -s "$self_publish" "$canonical_publish"; then
        echo "WARNING: canonical ds-publish.sh ($canonical_publish) differs from this checkout's own copy ($self_publish) -- canonical may be behind a recent fix; proceeding with canonical anyway" >&2
    fi
    # isolate-push.sh's record_publication_receipts() only passes
    # --session-id to note-publication when IWE_PUBLICATION_SESSION_ID is
    # set; without it, note-publication falls back to select_semaphore with
    # no selector, which correctly refuses to guess among two or more open
    # semaphores for the same agent -- the system's normal state, not an edge
    # case. Caller sets it; this function only surfaces the gap, it never
    # guesses a session_id itself.
    [[ -n "${IWE_PUBLICATION_SESSION_ID:-}" ]] \
        || echo "WARNING: IWE_PUBLICATION_SESSION_ID not set -- publication receipt v2 will fall back to legacy proof if another session is open for this agent; export your own session_id before calling publish_commit" >&2
    # DS_PUBLISH_RUN_ID (if the caller exports one) rides into ds-publish.sh
    # as a structured --run-id, so the notification queue/digest can
    # correlate messages of one run without parsing a reason-text tail.
    local run_id_args=()
    [[ -n "${DS_PUBLISH_RUN_ID:-}" ]] && run_id_args=(--run-id "$DS_PUBLISH_RUN_ID")
    # Without an explicit branch, ds-publish.sh targets $repo's OWN current
    # branch -- fine for an ordinary checkout, but a caller publishing from a
    # throwaway isolated worktree (e.g. extractor.sh's isolated-feed, checked
    # out on extractor/feed-<time>-<pid>) must say so, or ds-publish.sh tries
    # to fetch/push a branch that only ever exists in that worktree (#1289).
    local branch_args=()
    [[ -n "$branch" ]] && branch_args=(--branch "$branch")
    bash "$canonical_publish" "$repo" "$priority" --reason "$reason" \
        ${run_id_args[@]+"${run_id_args[@]}"} \
        ${branch_args[@]+"${branch_args[@]}"} \
        --from-commit "$sha" \
        --exact-commit "$sha"
}

# push_branch <repo-dir> -- plain `git push` of the current branch, setting
# upstream if missing. For repos that don't share the governance repo's write
# contention and don't need the coordination gate.
push_branch() {  # <repo-dir>
    local repo="$1" remote branch
    remote=$(git -C "$repo" remote | head -1)
    branch=$(git -C "$repo" branch --show-current)
    [[ -n "$remote" && -n "$branch" ]] || {
        echo "cannot publish: remote or current branch is missing" >&2
        return 1
    }
    git -C "$repo" push --set-upstream "$remote" "$branch"
}
