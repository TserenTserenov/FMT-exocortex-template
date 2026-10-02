#!/usr/bin/env bash
# issue #810 (found live during its own deploy): pre-commit-secret-scan.sh,
# once wired into a real hook, scans the *entire* staged diff for secret
# patterns -- including .claude/hooks/secret-bypass-lib.sh and its extracted
# secret-bypass-analyzer.py (issue #832), which necessarily contain the
# literal patterns they detect (a PEM header regex, self-test corpus
# fixtures for classes like yookassa). Without an exclusion, staging either
# file for the first time blocks the commit on its own rule literals -- this
# is exactly what happened committing the #832 extraction. Same class of
# self-reference already solved for check-platform-compat.sh in
# .githooks/pre-commit; this test locks in the analogous fix in
# pre-commit-secret-scan.sh itself.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail=0
ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

GOV="$TMP/repo"
git clone --quiet --no-hardlinks "$ROOT" "$GOV"
git -C "$GOV" config user.email test@test
git -C "$GOV" config user.name test

# The real hook always runs with cwd = repo root (that's how git invokes
# .githooks/pre-commit) -- pre-commit-secret-scan.sh relies on that (its own
# `git rev-parse --show-toplevel` and `git diff --cached` both use cwd, no
# explicit -C anywhere). An earlier version of this test ran the script
# without cd'ing into $GOV first: it silently scanned whatever repo this
# test process's own cwd happened to be in instead, made all three checks
# below pass or fail for the wrong reason, and was only caught because
# check 3 (the negative control) failed loudly.
run_scanner() { ( cd "$GOV" && bash scripts/pre-commit-secret-scan.sh ); }

# --- 1. Staging a real edit to secret-bypass-lib.sh must not self-block ---
printf '\n# issue-810 self-exclusion probe (no secret here)\n' >> "$GOV/.claude/hooks/secret-bypass-lib.sh"
git -C "$GOV" add .claude/hooks/secret-bypass-lib.sh
if out=$(run_scanner 2>&1); then
    ok "editing secret-bypass-lib.sh does not self-block on its own rule literals"
else
    echo "$out" >&2
    bad "editing secret-bypass-lib.sh does not self-block on its own rule literals"
fi
git -C "$GOV" reset -q -- .claude/hooks/secret-bypass-lib.sh
git -C "$GOV" checkout -q -- .claude/hooks/secret-bypass-lib.sh

# --- 2. Staging a real edit to secret-bypass-analyzer.py must not self-block ---
printf '\n# issue-810 self-exclusion probe (no secret here)\n' >> "$GOV/.claude/hooks/secret-bypass-analyzer.py"
git -C "$GOV" add .claude/hooks/secret-bypass-analyzer.py
if out=$(run_scanner 2>&1); then
    ok "editing secret-bypass-analyzer.py does not self-block on its own rule literals"
else
    echo "$out" >&2
    bad "editing secret-bypass-analyzer.py does not self-block on its own rule literals"
fi
git -C "$GOV" reset -q -- .claude/hooks/secret-bypass-analyzer.py
git -C "$GOV" checkout -q -- .claude/hooks/secret-bypass-analyzer.py

# --- 3. Negative control: exclusion is exact-path, not a blanket bypass --
# An ordinary file staged alongside a real-looking private key header must
# still be blocked -- the exclusion must not leak beyond the two named files.
# Built via concatenation, not a literal in this source file, for the same
# reason test_issue_530 does the same for its own probe strings: this file
# would otherwise trip the very self-scanning it exists to guard.
PEM_HEADER="-----BEGIN ""RSA PRIVATE KEY""-----"
printf '%s\nnot a real key, just the header shape\n' "$PEM_HEADER" > "$GOV/probe-secret.txt"
git -C "$GOV" add probe-secret.txt
if run_scanner >"$TMP/c3.out" 2>&1; then
    bad "ordinary staged file with a private-key header bypassed the scanner"
else
    ok "ordinary staged file with a private-key header still blocked (exclusion is exact-path)"
fi
git -C "$GOV" reset -q -- probe-secret.txt
rm -f "$GOV/probe-secret.txt"

if [ "$fail" -gt 0 ]; then
    echo "FAIL: $fail проверок упало"
    exit 1
fi
echo "PASS: pre-commit-secret-scan.sh self-exclusion is exact-path, not a blanket bypass (issue #810)"
