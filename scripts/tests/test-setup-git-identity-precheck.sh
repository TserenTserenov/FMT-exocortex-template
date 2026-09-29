#!/usr/bin/env bash
# WP-5 F57 (fresh-machine check, 29.09): on a machine with no git identity,
# setup.sh used to die in step 6 with git's own "Author identity unknown" after
# most of the install was done and before the base repos (ZP, FPF, SPF) were
# cloned. It must now stop at the prerequisites check, say what to run, and
# create nothing; with an identity the check passes. CI never saw the defect
# because its smoke supplies GIT_AUTHOR_* in the environment.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# PATH with the tools setup.sh needs, without anything that would carry an identity.
TOOLS_PATH="$(dirname "$(command -v git)"):$(dirname "$(command -v jq)"):/usr/bin:/bin"
NO_CONFIG="$TMP/empty-gitconfig"; : > "$NO_CONFIG"
# git guesses a name and address from the system account on some machines (macOS
# with a resolvable host name) and cannot on others (a Linux host without a domain
# name: "unable to auto-detect email address"). useConfigOnly reproduces the second
# kind everywhere, so the test does not depend on the machine it runs on.
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=user.useConfigOnly GIT_CONFIG_VALUE_0=true

run_setup() {  # $1 = workspace, rest = extra env assignments
    local ws=$1; shift
    mkdir -p "$ws" "$TMP/home-$(basename "$ws")"
    env -i PATH="$TOOLS_PATH" HOME="$TMP/home-$(basename "$ws")" \
        GIT_CONFIG_GLOBAL="$NO_CONFIG" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=user.useConfigOnly GIT_CONFIG_VALUE_0=true \
        SETUP_CI=1 GITHUB_USER=identity-precheck WORKSPACE_DIR="$ws" "$@" \
        bash "$ROOT/setup.sh" --core 2>&1
}

# 1. No identity anywhere -> exit 1 at the prerequisites, clear remedy, nothing created.
rc=0
out=$(run_setup "$TMP/ws-none") || rc=$?
[ "$rc" -eq 1 ] || fail "case 1: expected exit 1, got $rc: $(printf '%s' "$out" | tail -3)"
grep -q 'Git identity: не задана' <<<"$out" || fail "case 1: no identity message: $out"
grep -q 'git config --global user.name' <<<"$out" || fail "case 1: no remedy: $out"
grep -q 'Prerequisites check failed' <<<"$out" || fail "case 1: did not stop at prerequisites: $out"
if grep -q 'Author identity unknown' <<<"$out"; then fail "case 1: reached the raw git failure: $out"; fi
[ ! -e "$TMP/ws-none/${GOVERNANCE_REPO:-DS-strategy}" ] || fail "case 1: install started despite the missing identity"

# 2. Identity from the environment (what CI provides) -> the check passes.
rc=0
out=$(run_setup "$TMP/ws-env" GIT_AUTHOR_NAME=T GIT_AUTHOR_EMAIL=t@example.invalid \
      GIT_COMMITTER_NAME=T GIT_COMMITTER_EMAIL=t@example.invalid) || rc=$?
grep -q 'Git identity: задана' <<<"$out" || fail "case 2: identity not recognised: $out"
if grep -q 'Prerequisites check failed' <<<"$out"; then fail "case 2: prerequisites failed: $out"; fi

# 3. Identity from the user's global git config -> the check passes.
printf '[user]\n\tname = T\n\temail = t@example.invalid\n' > "$TMP/with-identity-gitconfig"
mkdir -p "$TMP/ws-cfg" "$TMP/home-cfg"
out=$(env -i PATH="$TOOLS_PATH" HOME="$TMP/home-cfg" \
      GIT_CONFIG_GLOBAL="$TMP/with-identity-gitconfig" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=user.useConfigOnly GIT_CONFIG_VALUE_0=true \
      SETUP_CI=1 GITHUB_USER=identity-precheck WORKSPACE_DIR="$TMP/ws-cfg" \
      bash "$ROOT/setup.sh" --core 2>&1) || true
grep -q 'Git identity: задана' <<<"$out" || fail "case 3: global config identity not recognised: $out"

# 4. A dry run makes no commit, so a missing identity is only a warning.
rc=0
out=$(env -i PATH="$TOOLS_PATH" HOME="$TMP/home-dry" \
      GIT_CONFIG_GLOBAL="$NO_CONFIG" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=user.useConfigOnly GIT_CONFIG_VALUE_0=true \
      SETUP_CI=1 GITHUB_USER=identity-precheck WORKSPACE_DIR="$TMP/ws-dry" \
      bash "$ROOT/setup.sh" --core --dry-run 2>&1) || rc=$?
grep -q 'Git identity: не задана' <<<"$out" || fail "case 4: dry run did not report: $out"
if grep -q 'Prerequisites check failed' <<<"$out"; then fail "case 4: dry run blocked by the identity check: $out"; fi

echo "PASS: 4 cases"
