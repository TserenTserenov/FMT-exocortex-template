#!/usr/bin/env bash
# issue #1572: update.sh keeps its records (.claude.md.delivered, .memory-deployed.tsv,
# .claude.md.base) in the workspace root. When the root is itself a git repo, those
# untracked files made `session-guard.sh open --isolate` refuse with "uncommitted
# changes". This runs the real script against a throwaway workspace-root repo.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SG="$ROOT/scripts/session-guard.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

SANDBOX=$(mktemp -d)
trap 'cd /; rm -rf "$SANDBOX"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=t@test GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=t@test

ORIGIN_DIR="$SANDBOX/origin.git"
git init -q --bare --initial-branch=main "$ORIGIN_DIR"

IWE_ROOT="$SANDBOX/iwe-root"
mkdir -p "$IWE_ROOT"
git init -q --initial-branch=main "$IWE_ROOT"
printf '.iwe-runtime/\nMC-sessions/\nDS-strategy/\n' > "$IWE_ROOT/.gitignore"
echo "root" > "$IWE_ROOT/README.md"
git -C "$IWE_ROOT" add .gitignore README.md
git -C "$IWE_ROOT" commit -q -m seed
git -C "$IWE_ROOT" remote add origin "$ORIGIN_DIR"
git -C "$IWE_ROOT" push -q -u origin main 2>/dev/null

mkdir -p "$IWE_ROOT/.iwe-runtime/sessions" "$IWE_ROOT/MC-sessions" "$IWE_ROOT/DS-strategy"
git -C "$IWE_ROOT/MC-sessions" init -q
echo "# sessions" > "$IWE_ROOT/MC-sessions/README.md"
git -C "$IWE_ROOT/MC-sessions" add README.md
git -C "$IWE_ROOT/MC-sessions" commit -q -m "seed sessions"

# The records update.sh writes into the workspace root.
printf 'deadbeef\n' > "$IWE_ROOT/.claude.md.delivered"
printf 'memory/a.md\tdeadbeef\n' > "$IWE_ROOT/.memory-deployed.tsv"
printf 'base\n' > "$IWE_ROOT/.claude.md.base"

export IWE_ROOT
export IWE_GOVERNANCE_REPO=DS-strategy
export IWE_FROZEN_CANONICAL_PATH=""
export IWE_SESSIONS_ROOT="$IWE_ROOT/MC-sessions"
AGENT=claude-code
export IWE_AGENT="$AGENT"

run_open() {
  local sid="$1"
  export IWE_SESSION_ID="$sid"
  (cd "$IWE_ROOT" && bash "$SG" open --wp WP-1572 --agent "$AGENT" --task "isolate with update records" --slug "$sid" --isolate) 2>&1
}

SID1="t1572a-$$"
if ! OUT=$(run_open "$SID1"); then
  fail "open --isolate refused with only update.sh records untracked in the root: $OUT"
fi
printf '%s\n' "$OUT" | grep -q '"worktree_path"' || fail "open --isolate printed no worktree_path: $OUT"
[ -d "$IWE_ROOT/.iwe-runtime/isolated-worktrees/${AGENT}-${SID1}" ] || fail "isolated worktree was not created"
[ -f "$IWE_ROOT/.claude.md.delivered" ] || fail "the update record was removed"
pass "open --isolate succeeds with .claude.md.delivered/.memory-deployed.tsv/.claude.md.base untracked in the root"

# Control: any other untracked file in the root still blocks --isolate.
echo "work" > "$IWE_ROOT/notes.md"
SID2="t1572b-$$"
if OUT2=$(run_open "$SID2"); then
  fail "open --isolate accepted a root with real uncommitted work (notes.md): $OUT2"
fi
printf '%s\n' "$OUT2" | grep -q 'незакоммиченные изменения' || fail "unexpected refusal text: $OUT2"
pass "an unrelated untracked file in the root still blocks --isolate"
