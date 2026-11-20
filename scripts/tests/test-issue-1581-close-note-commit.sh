#!/usr/bin/env bash
# issue #1581: memory/protocol-close.md (Quick Close 1b) tells the agent to run
# `session-guard.sh note-commit` after every commit, but the delivered
# session-guard.sh has no such command ("Unknown command: note-commit"), and the
# step had no skip rule, unlike the other close steps on undelivered scripts
# (#1542). This asks the delivered session-guard.sh itself; when it refuses the
# command, the protocol must say to skip that step and quote the same refusal.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SG="$ROOT/scripts/session-guard.sh"
PROTO="$ROOT/memory/protocol-close.md"
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/iwe/.iwe-runtime/sessions"

grep -q 'session-guard.sh" note-commit' "$PROTO" || { pass "protocol-close.md no longer calls note-commit"; exit 0; }

out=$(cd "$SANDBOX" && IWE_ROOT="$SANDBOX/iwe" IWE_SESSIONS_ROOT="$SANDBOX/iwe/sessions" \
  bash "$SG" note-commit 0000000000000000000000000000000000000000 2>&1 || true)

case "$out" in
  *"Unknown command: note-commit"*)
    grep -qF 'отвечает `Unknown command: note-commit`' "$PROTO" \
      || fail "the delivered session-guard.sh refuses note-commit, but protocol-close.md has no skip rule for it"
    grep -qF 'пункт (2) пропустить' "$PROTO" \
      || fail "protocol-close.md does not say which part of step 1b to skip without note-commit"
    pass "delivered session-guard.sh has no note-commit and protocol-close.md says to skip that step"
    ;;
  *)
    grep -qE '^[[:space:]]*note-commit\)' "$SG" \
      || fail "could not tell whether session-guard.sh supports note-commit: $out"
    pass "delivered session-guard.sh knows note-commit; the protocol step applies as written"
    ;;
esac
