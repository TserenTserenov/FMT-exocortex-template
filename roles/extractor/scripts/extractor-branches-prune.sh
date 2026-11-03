#!/usr/bin/env bash
# extractor-branches-prune.sh — report (and optionally delete) leftover
# extractor/* branches of past isolated runs (#1433 follow-up, WP-7 F288).
#
# Default: report only. A branch counts as published when every commit on it
# has a patch-equivalent in the governance branch (`git cherry`, the extractor
# publishes by cherry-pick, so the branch tip is usually NOT an ancestor) or
# when its tip is an ancestor. Branches with unpublished commits are never
# deleted, only listed: they may hold the only copy of a report. So are
# branches with merge commits (their own content is invisible to git cherry)
# and branches the check fails on.
#
#   --repo <dir>       governance repo (default: $IWE_ROOT/$IWE_GOVERNANCE_REPO)
#   --base <ref>       governance branch to compare with (default: origin/HEAD,
#                      else origin/main)
#   --apply            delete published LOCAL extractor/* branches
#   --apply-remote     delete published extractor/* branches on origin;
#                      requires --yes, otherwise prints the list and exits 2
#   --yes              confirmation for --apply-remote
set -euo pipefail

usage() { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; }

repo="${IWE_ROOT:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}"
base="" apply=0 apply_remote=0 yes=0
while [ $# -gt 0 ]; do
    case "$1" in
        --repo) repo="${2:?--repo needs a path}"; shift 2 ;;
        --base) base="${2:?--base needs a ref}"; shift 2 ;;
        --apply) apply=1; shift ;;
        --apply-remote) apply_remote=1; shift ;;
        --yes) yes=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 1 ;;
    esac
done

git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || { echo "not a git repository: $repo" >&2; exit 1; }
git -C "$repo" fetch -q --prune origin || { echo "git fetch origin failed in $repo" >&2; exit 1; }

if [ "$apply_remote" -eq 1 ] && [ "$yes" -ne 1 ]; then
    apply=0  # nothing is deleted until the whole request is confirmed
fi
[ -n "$base" ] || base=$(git -C "$repo" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/main)
git -C "$repo" rev-parse -q --verify "$base^{commit}" >/dev/null || { echo "base ref not found: $base" >&2; exit 1; }

# Prints how many commits on <ref> lack an equivalent in $base, or a reason
# to keep the branch ("merge commits", "check failed"). Fails closed.
unpublished_count() {  # <ref>
    local out
    if git -C "$repo" merge-base --is-ancestor "$1" "$base"; then
        echo 0
    elif ! out=$(git -C "$repo" rev-list --merges "$base..$1" 2>/dev/null); then
        echo "check failed"
    elif [ -n "$out" ]; then
        echo "merge commits"
    elif ! out=$(git -C "$repo" cherry "$base" "$1" 2>/dev/null); then
        echo "check failed"
    else
        printf '%s\n' "$out" | grep -c '^+' || true
    fi
}

published_local=() published_remote=() kept=0
report() {  # <namespace> <refs-prefix> <strip-prefix>
    local ns="$1" ref name n
    while IFS= read -r ref; do
        [ -n "$ref" ] || continue
        name="${ref#"$3"}"
        n=$(unpublished_count "$ref")
        if [ "$n" = 0 ]; then
            printf 'published  %-6s %s\n' "$ns" "$name"
            if [ "$ns" = local ]; then published_local+=("$name"); else published_remote+=("$name"); fi
        else
            case "$n" in
                *[!0-9]*) printf 'KEEP       %-6s %s (%s)\n' "$ns" "$name" "$n" ;;
                *) printf 'KEEP       %-6s %s (%s unpublished commit(s))\n' "$ns" "$name" "$n" ;;
            esac
            kept=$((kept + 1))
        fi
    done < <(git -C "$repo" for-each-ref --format='%(refname)' "$2")
}

echo "repo: $repo  base: $base"
report local refs/heads/extractor/ refs/heads/
report origin refs/remotes/origin/extractor/ refs/remotes/origin/
echo "published: ${#published_local[@]} local, ${#published_remote[@]} on origin; kept with unpublished commits: $kept"

status=0
if [ "$apply" -eq 1 ]; then
    for name in ${published_local[@]+"${published_local[@]}"}; do
        # -D: a cherry-picked branch is not "merged" in git's sense.
        git -C "$repo" branch -D "$name" >/dev/null 2>&1 && echo "deleted local $name" \
            || { echo "could not delete local $name (checked out in a worktree?)" >&2; status=1; }
    done
fi
if [ "$apply_remote" -eq 1 ]; then
    if [ "$yes" -ne 1 ]; then
        echo "--apply-remote would delete ${#published_remote[@]} branch(es) on origin listed above; rerun with --yes to confirm" >&2
        exit 2
    fi
    for name in ${published_remote[@]+"${published_remote[@]}"}; do
        # Lease: refuse if someone pushed to the branch after our fetch.
        git -C "$repo" push -q --force-with-lease="refs/heads/$name:$(git -C "$repo" rev-parse "refs/remotes/origin/$name")" \
            origin --delete "$name" && echo "deleted origin $name" \
            || { echo "could not delete origin $name" >&2; status=1; }
    done
fi
exit "$status"
