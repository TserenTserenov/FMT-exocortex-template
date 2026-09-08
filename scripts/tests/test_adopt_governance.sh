#!/bin/bash
# test_adopt_governance.sh — WP-560 Ф5-Phase-1.
#
# The browser path (create_personal_data_space → github-integration-service,
# family-catalog.ts) creates the governance repository under the same canonical
# name as setup.sh step 6. Before this phase, a user who started in the browser
# and then ran setup.sh got a second, unrelated local repo plus a swallowed
# `gh repo create` failure. Invariants under test (dry-run, fake gh on PATH):
#   1. remote exists + owner matches → setup.sh announces ADOPTION (clone), not
#      creation, and never calls `gh repo create`;
#   2. remote absent → the pre-existing creation path is unchanged
#      (discriminating control: the test can tell the two apart);
#   3. foreign owner → refused before any clone;
#   4. the structure markers checked after a real clone are the seed's own
#      files, so a clone of a foreign/non-governance repo cannot pass.
#
# Bash 3.2 compatible. Usage: bash scripts/tests/test_adopt_governance.sh

set -uo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_ROOT="$(cd "$SELF_DIR/../.." && pwd)"

FAIL_COUNT=0; PASS_COUNT=0
fail() { echo "  ❌ FAIL: $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }
pass() { echo "  ✅ PASS: $*"; PASS_COUNT=$((PASS_COUNT + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM
TEMPLATE_COPY="$TMP/FMT-exocortex-template"; WORKSPACE="$TMP/workspace"; FAKE_BIN="$TMP/fake-bin"; GH_LOG="$TMP/gh.log"
mkdir -p "$TEMPLATE_COPY" "$WORKSPACE" "$FAKE_BIN" "$TMP/home"
tar -C "$TEMPLATE_ROOT" --exclude='./.git' -cf - . | tar -C "$TEMPLATE_COPY" -xf -

# Fake gh: FAKE_GH_REMOTE_EXISTS=1 → `repo view` succeeds and reports FAKE_GH_OWNER;
# every invocation is logged so the test can prove `repo create`/`repo clone` never ran.
cat > "$FAKE_BIN/gh" <<'SH'
#!/bin/sh
printf '%s\n' "gh $*" >>"$FAKE_GH_LOG"
case "$1 $2" in
  "auth status") exit 0 ;;
  "repo view")
    [ "${FAKE_GH_REMOTE_EXISTS:-0}" = "1" ] || exit 1
    case "$*" in
      *"--jq .owner.login"*) printf '%s\n' "${FAKE_GH_OWNER:-nobody}" ;;
      *) printf '{"name":"DS-strategy"}\n' ;;
    esac
    exit 0 ;;
  *) exit 97 ;;
esac
SH
chmod +x "$FAKE_BIN/gh"
for c in curl wget; do printf '#!/bin/sh\nexit 97\n' > "$FAKE_BIN/$c"; chmod +x "$FAKE_BIN/$c"; done

cat > "$WORKSPACE/.exocortex.env" <<ENVEOF
GITHUB_USER="contract-test"
WORKSPACE_DIR="$WORKSPACE"
CLAUDE_PATH="claude"
CLAUDE_PROJECT_SLUG="contract-test"
TIMEZONE_HOUR="4"
TIMEZONE_DESC="4:00 UTC"
HOME_DIR="$TMP/home"
USER_NAME="contract-test"
GOVERNANCE_REPO="DS-strategy"
IWE_TEMPLATE="$TEMPLATE_COPY"
IWE_RUNTIME="$WORKSPACE/.iwe-runtime"
ENVEOF

run_setup() { # $1 = remote exists (0/1), $2 = owner reported by gh
  : >"$GH_LOG"
  # GOVERNANCE_REPO / IWE_GOVERNANCE_REPO are pinned: setup.sh honours an explicit
  # env value first, and a developer shell usually exports its own governance name.
  env HOME="$TMP/home" PATH="$FAKE_BIN:$PATH" FAKE_GH_LOG="$GH_LOG" FAKE_GH_REMOTE_EXISTS="$1" FAKE_GH_OWNER="$2" \
      SETUP_CI=1 GITHUB_USER=contract-test WORKSPACE_DIR="$WORKSPACE" \
      GOVERNANCE_REPO=DS-strategy IWE_GOVERNANCE_REPO=DS-strategy \
      bash "$TEMPLATE_COPY/setup.sh" --dry-run >"$TMP/out.log" 2>&1
  echo $?
}

echo "=== 1. Remote governance repo exists and is ours → adopt (clone), never create ==="
rc=$(run_setup 1 contract-test)
[ "$rc" = "0" ] && pass "setup.sh --dry-run exits 0" || fail "exit $rc; $(tail -5 "$TMP/out.log")"
grep -qF "Remote contract-test/DS-strategy exists → would clone it into" "$TMP/out.log" \
  && pass "announces adoption of the existing remote" || fail "no adoption line; output: $(grep -F '[6/6]' -A3 "$TMP/out.log")"
grep -qF "Would verify governance markers: REPO-TYPE.md docs/WP-REGISTRY.md" "$TMP/out.log" \
  && pass "structure markers are the seed's own files" || fail "marker list changed or missing"
grep -qF "Would create DS-strategy from seed/strategy" "$TMP/out.log" \
  && fail "creation path still announced alongside adoption" || pass "creation path not taken"
grep -qE "^gh repo (create|clone)" "$GH_LOG" && fail "gh repo create/clone invoked in dry-run" || pass "no gh repo create/clone in dry-run"

echo "=== 2. Discriminating control: remote absent → unchanged creation path ==="
rc=$(run_setup 0 contract-test)
[ "$rc" = "0" ] && pass "setup.sh --dry-run exits 0" || fail "exit $rc"
grep -qF "Would create DS-strategy from seed/strategy" "$TMP/out.log" \
  && pass "creation path announced when no remote" || fail "creation path missing; output: $(grep -F '[6/6]' -A3 "$TMP/out.log")"
grep -qF "would clone it into" "$TMP/out.log" && fail "adoption announced without a remote" || pass "no adoption without a remote"

echo "=== 3. Foreign owner → refused before any clone, even in dry-run ==="
rc=$(run_setup 1 someone-else)
[ "$rc" != "0" ] && pass "setup.sh refuses (exit $rc)" || fail "accepted a repo owned by someone-else"
grep -qF "Refusing to adopt a repository that is not yours" "$TMP/out.log" \
  && pass "refusal names the owner mismatch" || fail "no owner-mismatch message"
grep -qE "^gh repo clone" "$GH_LOG" && fail "cloned a foreign repo" || pass "nothing cloned"

echo "=== 4. Seed really ships the markers the adoption check relies on ==="
for m in REPO-TYPE.md docs/WP-REGISTRY.md; do
  [ -e "$TEMPLATE_ROOT/seed/strategy/$m" ] && pass "seed/strategy/$m present" || fail "seed/strategy/$m missing — adoption would reject a freshly seeded repo"
done

echo ""
echo "Result: $PASS_COUNT PASS, $FAIL_COUNT FAIL"
[ "$FAIL_COUNT" -eq 0 ]
