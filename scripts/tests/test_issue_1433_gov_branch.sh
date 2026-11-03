#!/usr/bin/env bash
# test_issue_1433_gov_branch.sh — an isolated extractor worktree must publish to
# the governance branch even when the repo has no origin/HEAD (created via
# `git init` + `gh repo create --push`), and the publish gate must come from the
# canonical governance repo, not from the worktree checked out of origin/main
# (issue #1433). Functions are extracted from the real extractor.sh.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/roles/extractor/scripts/extractor.sh"

FAIL=0
pass() { echo "  ✅ PASS: $*"; }
fail() { echo "  ❌ FAIL: $*"; FAIL=$((FAIL + 1)); }

for fn in resolve_governance_branch resolve_publish_gate; do
    src=$(awk "/^${fn}\\(\\) \\{/,/^}/" "$SCRIPT")
    [ -n "$src" ] || { echo "FAIL: $fn() not found in $SCRIPT"; exit 1; }
    eval "$src"
done

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
unset IWE_GOVERNANCE_BRANCH

# Governance repo the documented way: init + push, so origin/HEAD is absent.
git init -q --bare "$TMP/origin.git"
git init -q -b main "$TMP/gov"
git -C "$TMP/gov" commit -q --allow-empty -m init
git -C "$TMP/gov" remote add origin "$TMP/origin.git"
git -C "$TMP/gov" push -q -u origin main
git -C "$TMP/gov" rev-parse -q --verify refs/remotes/origin/HEAD >/dev/null \
    && fail "setup: origin/HEAD unexpectedly present"

# Isolated worktree on a throwaway branch tracking origin/main.
git -C "$TMP/gov" worktree add -q -b extractor/inbox-check-T "$TMP/iso" origin/main
git -C "$TMP/iso" branch -q --set-upstream-to=origin/main
got=$(resolve_governance_branch "$TMP/iso")
[ "$got" = "main" ] && pass "worktree without origin/HEAD resolves to its upstream" \
    || fail "worktree without origin/HEAD resolved to '$got', expected main"

# Same worktree without an upstream: still never the throwaway branch.
git -C "$TMP/iso" branch -q --unset-upstream
got=$(resolve_governance_branch "$TMP/iso")
[ "$got" = "main" ] && pass "throwaway extractor/* branch is never returned" \
    || fail "resolved to '$got' without upstream, expected main"

# A remote whose name contains "/" (cold review): the branch, not "fork/main".
git -C "$TMP/gov" remote add my/fork "$TMP/origin.git"
git -C "$TMP/gov" fetch -q my/fork
git -C "$TMP/gov" worktree add -q -b extractor/feed-T "$TMP/iso2" my/fork/main
git -C "$TMP/iso2" branch -q --set-upstream-to=my/fork/main
got=$(resolve_governance_branch "$TMP/iso2")
[ "$got" = "main" ] && pass "remote name with a slash still yields the branch" \
    || fail "slash remote resolved to '$got', expected main"

# The canonical repo on a non-main governance branch keeps it.
git -C "$TMP/gov" checkout -q -b trunk
got=$(resolve_governance_branch "$TMP/gov")
[ "$got" = "trunk" ] && pass "ordinary current branch still honoured" \
    || fail "canonical repo resolved to '$got', expected trunk"

# Publish gate: canonical copy wins over the worktree's older copy.
WS="$TMP/ws"
mkdir -p "$WS/DS-strategy/scripts/lib" "$TMP/iso/scripts/lib"
printf '# canonical\n' > "$WS/DS-strategy/scripts/lib/publish-gate.sh"
printf '# worktree\n' > "$TMP/iso/scripts/lib/publish-gate.sh"
got=$(IWE_ROOT="$WS" IWE_GOVERNANCE_REPO=DS-strategy resolve_publish_gate "$TMP/iso")
[ "$got" = "$WS/DS-strategy/scripts/lib/publish-gate.sh" ] && pass "canonical publish gate is preferred" \
    || fail "gate resolved to '$got'"
rm "$WS/DS-strategy/scripts/lib/publish-gate.sh"
got=$(IWE_ROOT="$WS" IWE_GOVERNANCE_REPO=DS-strategy resolve_publish_gate "$TMP/iso")
[ "$got" = "$TMP/iso/scripts/lib/publish-gate.sh" ] && pass "worktree gate is the fallback" \
    || fail "fallback gate resolved to '$got'"
rm "$TMP/iso/scripts/lib/publish-gate.sh"
got=$(IWE_ROOT="$WS" IWE_GOVERNANCE_REPO=DS-strategy resolve_publish_gate "$TMP/iso")
[ -z "$got" ] && pass "no gate anywhere yields empty (caller falls back to the governance branch)" \
    || fail "missing gate resolved to '$got'"
[ "$FAIL" -eq 0 ] && echo "PASS: issue #1433 governance branch and publish gate" || { echo "FAIL: issue #1433 has $FAIL violation(s)"; exit 1; }
