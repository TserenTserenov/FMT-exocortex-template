#!/bin/bash
# test_adopt_governance.sh — WP-560 Ф5-Phase-1; dry-run contract revised by #956.
#
# The browser path (create_personal_data_space → github-integration-service,
# family-catalog.ts) creates the governance repository under the same canonical
# name as setup.sh step 6. Before this phase, a user who started in the browser
# and then ran setup.sh got a second, unrelated local repo plus a swallowed
# `gh repo create` failure. Since #956 a dry run is network-free (pinned by
# test_fresh_seed_reproduction.sh), so `setup.sh --dry-run` no longer probes the
# remote to preview adoption. Invariants under test (fake gh on PATH):
#   1. dry run, remote exists and is ours → the remote is NOT queried (no
#      `gh repo view|create|clone`) and the preview names both outcomes;
#   2. dry run, remote absent → the same preview, line for line (discriminating
#      control: the output must not depend on the remote);
#   3. adopt_existing_governance_repo itself, extracted from setup.sh and run for
#      real against the fake gh: foreign owner → refused before any clone; our
#      owner → cloned and the structure markers verified;
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
# `repo clone` materialises a governance-shaped clone (the seed's marker files);
# every invocation is logged so the test can prove what ran and what never did.
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
  "repo clone")
    mkdir -p "$4"
    for m in ${FAKE_GH_MARKERS:-}; do
      mkdir -p "$4/$(dirname "$m")"
      cp "$FAKE_GH_SEED_DIR/$m" "$4/$m"
    done
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

# The step-6 section of a dry-run log (from its header up to the next step).
step6_preview() { awk '/^\[6\/6\]/{f=1} /^\[7\/7\]/{f=0} f' "$1"; }

# check <pass message> <fail message> <command...>: pass when the command succeeds.
# check_not is the mirror image: pass when the command fails.
check() {
  local ok_msg="$1" bad_msg="$2"; shift 2
  if "$@"; then pass "$ok_msg"; else fail "$bad_msg"; fi
}
check_not() {
  local ok_msg="$1" bad_msg="$2"; shift 2
  if "$@"; then fail "$bad_msg"; else pass "$ok_msg"; fi
}

PREVIEW='[DRY RUN] Проверит GitHub: примет существующий репозиторий contract-test/DS-strategy или создаст новый (private)'

echo "=== 1. Dry run, remote exists and is ours → remote never queried, both outcomes previewed ==="
rc=$(run_setup 1 contract-test)
check "setup.sh --dry-run exits 0" "exit $rc; $(tail -5 "$TMP/out.log")" [ "$rc" = "0" ]
check "preview names both outcomes (adopt the existing repo or create a new one)" \
  "preview line missing; output: $(grep -F '[6/6]' -A5 "$TMP/out.log")" \
  grep -qF "$PREVIEW" "$TMP/out.log"
check_not "no gh repo view/create/clone in dry-run" "dry run touched the remote: $(grep '^gh repo' "$GH_LOG")" \
  grep -qE "^gh repo (view|create|clone)" "$GH_LOG"
check_not "adoption is not announced without a probe" "adoption announced although the remote is never queried" \
  grep -qF "would clone it into" "$TMP/out.log"
step6_preview "$TMP/out.log" > "$TMP/preview-remote-exists.txt"

echo "=== 2. Discriminating control: remote absent → the same preview, creation path unchanged ==="
rc=$(run_setup 0 contract-test)
check "setup.sh --dry-run exits 0" "exit $rc" [ "$rc" = "0" ]
check "creation path announced" "creation path missing; output: $(grep -F '[6/6]' -A3 "$TMP/out.log")" \
  grep -qF "Would create DS-strategy from seed/strategy" "$TMP/out.log"
step6_preview "$TMP/out.log" > "$TMP/preview-remote-absent.txt"
check "step-6 preview is identical whether or not the remote exists" "step-6 preview depends on the remote state" \
  cmp -s "$TMP/preview-remote-exists.txt" "$TMP/preview-remote-absent.txt"
check "step-6 preview is not empty" "step-6 section missing from the dry-run output" [ -s "$TMP/preview-remote-absent.txt" ]

echo "=== 3. adopt_existing_governance_repo (extracted from setup.sh, run for real against the fake gh) ==="
MARKERS=$(jq -r '.requiredMarkers[]' "$TEMPLATE_ROOT/scripts/governance-repo-contract.json" | tr '\n' ' ')
extract_fn() { sed -n "/^$1() {/,/^}/p" "$TEMPLATE_COPY/setup.sh"; }
check "adopt_existing_governance_repo found in setup.sh" "function not found in setup.sh — extraction pattern is stale" \
  test -n "$(extract_fn adopt_existing_governance_repo)"
check "governance_markers_missing found in setup.sh" "function not found in setup.sh — extraction pattern is stale" \
  test -n "$(extract_fn governance_markers_missing)"

run_adopt() { # $1 = owner reported by gh → prints the exit code; output in $TMP/adopt.log
  local adopt_dir="$TMP/adopt-$1/DS-strategy"   # one clone target per owner: runs never share state
  : >"$GH_LOG"
  {
    echo 'set -e'
    echo 'GITHUB_USER=contract-test; GOVERNANCE_REPO=DS-strategy; DRY_RUN=false; CORE_ONLY=false'
    echo "MY_STRATEGY_DIR='$adopt_dir'; STRATEGY_TEMPLATE='$TEMPLATE_ROOT/seed/strategy'"
    echo "GOVERNANCE_MARKERS=($MARKERS)"
    echo 'generate_executor_catalog_for_governance() { :; }'
    extract_fn governance_markers_missing
    extract_fn adopt_existing_governance_repo
    echo 'adopt_existing_governance_repo'
  } >"$TMP/adopt-harness.sh"
  env HOME="$TMP/home" PATH="$FAKE_BIN:$PATH" FAKE_GH_LOG="$GH_LOG" FAKE_GH_REMOTE_EXISTS=1 FAKE_GH_OWNER="$1" \
      FAKE_GH_SEED_DIR="$TEMPLATE_ROOT/seed/strategy" FAKE_GH_MARKERS="$MARKERS" \
      bash "$TMP/adopt-harness.sh" >"$TMP/adopt.log" 2>&1
  echo $?
}

rc=$(run_adopt someone-else)
check "foreign owner refused (exit $rc)" "accepted a repo owned by someone-else" [ "$rc" != "0" ]
check "refusal names the owner mismatch" "no owner-mismatch message; output: $(cat "$TMP/adopt.log")" \
  grep -qF "Refusing to adopt a repository that is not yours" "$TMP/adopt.log"
check_not "nothing cloned" "cloned a foreign repo" grep -qE "^gh repo clone" "$GH_LOG"

rc=$(run_adopt contract-test)
check "our own repository is adopted" "exit $rc; $(tail -5 "$TMP/adopt.log")" [ "$rc" = "0" ]
check "our repository is cloned" "no gh repo clone of our repository; log: $(cat "$GH_LOG")" \
  grep -qE "^gh repo clone contract-test/DS-strategy " "$GH_LOG"
check "owner and structure verified" "adoption not confirmed; output: $(cat "$TMP/adopt.log")" \
  grep -qF "adopted: owner and structure verified" "$TMP/adopt.log"

echo "=== 4. Seed really ships the markers the adoption check relies on ==="
for m in REPO-TYPE.md docs/WP-REGISTRY.md; do
  [ -e "$TEMPLATE_ROOT/seed/strategy/$m" ] && pass "seed/strategy/$m present" || fail "seed/strategy/$m missing — adoption would reject a freshly seeded repo"
done

echo ""
echo "Result: $PASS_COUNT PASS, $FAIL_COUNT FAIL"
[ "$FAIL_COUNT" -eq 0 ]
