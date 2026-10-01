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
#   3. the REAL step-6 block of setup.sh, run in real mode (DRY_RUN=false) against
#      the fake gh, together with the real contract loader that builds
#      GOVERNANCE_MARKERS:
#        remote ours      → gh repo clone, structure verified, no gh repo create;
#        remote absent    → gh repo create, no gh repo clone;
#        foreign owner    → refused before any clone or create;
#        ours, no markers → refused, listing the missing markers of the real array;
#   4. GOVERNANCE_MARKERS is the contract's requiredMarkers list and the seed ships
#      every one of them, so a clone of a foreign/non-governance repo cannot pass
#      and a freshly seeded repo is not rejected.
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
# `repo clone` materialises a clone holding the files in FAKE_GH_MARKERS (copied from
# the seed) plus FAKE_GH_EXTRA_FILE; `repo create` succeeds. Every invocation is
# logged so the test can prove what ran and what never did.
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
    if [ -n "${FAKE_GH_EXTRA_FILE:-}" ]; then printf 'unrelated\n' > "$4/$FAKE_GH_EXTRA_FILE"; fi
    exit 0 ;;
  "repo create") exit 0 ;;
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

echo "=== 3. Step 6 of the real setup.sh in real mode, against the fake gh ==="
# The harness is assembled from the real script: the contract loader (builds
# GOVERNANCE_MARKERS) and the whole step-6 block. Only generate_executor_catalog_for_governance,
# which is defined in another section and not under test, is stubbed.
check "contract loader found in setup.sh" "contract loader not found in setup.sh — extraction pattern is stale" \
  test -n "$(sed -n '/^GOVERNANCE_CONTRACT_FILE=/,/^unset _governance_markers_raw/p' "$TEMPLATE_COPY/setup.sh")"
check "step-6 block found in setup.sh" "step-6 block not found in setup.sh — extraction pattern is stale" \
  test -n "$(sed -n '/^# === 6\./,/^# === 7\./p' "$TEMPLATE_COPY/setup.sh")"

# run_step6 <case> <remote exists 0/1> <owner> <clone shape: governance|stray>
# → prints the exit code; output in $TMP/step6-<case>.log, workspace in $TMP/step6-<case>
run_step6() {
  local name="$1" exists="$2" owner="$3" shape="$4"
  local ws="$TMP/step6-$name"
  mkdir -p "$ws"
  : >"$GH_LOG"
  {
    echo 'set -e'
    echo "TEMPLATE_DIR='$TEMPLATE_COPY'; WORKSPACE_DIR='$ws'"
    echo 'GITHUB_USER=contract-test; GOVERNANCE_REPO=DS-strategy; DRY_RUN=false; CORE_ONLY=false; GOVERNANCE_REPO_PUSH_FAILED=false'
    sed -n '/^GOVERNANCE_CONTRACT_FILE=/,/^unset _governance_markers_raw/p' "$TEMPLATE_COPY/setup.sh"
    # The single-quoted lines below are harness text: they expand inside the harness.
    # shellcheck disable=SC2016
    echo 'echo "[harness] GOVERNANCE_MARKERS=${GOVERNANCE_MARKERS[*]}"'
    if [ "$shape" = "stray" ]; then
      echo 'export FAKE_GH_MARKERS=""; export FAKE_GH_EXTRA_FILE=README.md'
    else
      # shellcheck disable=SC2016
      echo 'export FAKE_GH_MARKERS="${GOVERNANCE_MARKERS[*]}"'
    fi
    echo 'generate_executor_catalog_for_governance() { :; }'
    sed -n '/^# === 6\./,/^# === 7\./p' "$TEMPLATE_COPY/setup.sh"
  } >"$TMP/step6-$name.sh"
  env HOME="$TMP/home" PATH="$FAKE_BIN:$PATH" FAKE_GH_LOG="$GH_LOG" FAKE_GH_REMOTE_EXISTS="$exists" FAKE_GH_OWNER="$owner" \
      FAKE_GH_SEED_DIR="$TEMPLATE_ROOT/seed/strategy" \
      GIT_AUTHOR_NAME=contract GIT_AUTHOR_EMAIL=contract@example.invalid \
      GIT_COMMITTER_NAME=contract GIT_COMMITTER_EMAIL=contract@example.invalid \
      GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
      bash "$TMP/step6-$name.sh" >"$TMP/step6-$name.log" 2>&1
  echo $?
}

echo "--- remote exists and is ours → adopted (clone), never created ---"
rc=$(run_step6 ours 1 contract-test governance)
check "step 6 succeeds (exit $rc)" "exit $rc; $(tail -5 "$TMP/step6-ours.log")" [ "$rc" = "0" ]
check "our repository is cloned" "no gh repo clone of our repository; log: $(cat "$GH_LOG")" \
  grep -qE "^gh repo clone contract-test/DS-strategy " "$GH_LOG"
check_not "no gh repo create for an existing repository" "gh repo create ran although the repository exists" \
  grep -qE "^gh repo create" "$GH_LOG"
check "owner and structure verified" "adoption not confirmed; output: $(cat "$TMP/step6-ours.log")" \
  grep -qF "adopted: owner and structure verified" "$TMP/step6-ours.log"

echo "--- remote absent → created (gh repo create), nothing cloned ---"
rc=$(run_step6 absent 0 contract-test governance)
check "step 6 succeeds (exit $rc)" "exit $rc; $(tail -5 "$TMP/step6-absent.log")" [ "$rc" = "0" ]
check "gh repo create is called for the new repository" "no gh repo create; log: $(cat "$GH_LOG")" \
  grep -qE "^gh repo create contract-test/DS-strategy " "$GH_LOG"
check_not "no gh repo clone when the remote is absent" "gh repo clone ran although the remote is absent" \
  grep -qE "^gh repo clone" "$GH_LOG"
check "the local governance repo is initialised" "no local git repo in the workspace" \
  test -d "$TMP/step6-absent/DS-strategy/.git"

echo "--- foreign owner → refused before any clone or create ---"
rc=$(run_step6 foreign 1 someone-else governance)
check "foreign owner refused (exit $rc)" "accepted a repo owned by someone-else" [ "$rc" != "0" ]
check "refusal names the owner mismatch" "no owner-mismatch message; output: $(cat "$TMP/step6-foreign.log")" \
  grep -qF "Refusing to adopt a repository that is not yours" "$TMP/step6-foreign.log"
check_not "nothing cloned or created" "a foreign repo was cloned or a new one created: $(grep '^gh repo' "$GH_LOG")" \
  grep -qE "^gh repo (clone|create)" "$GH_LOG"

echo "--- ours, but the clone has none of the markers → refused, missing markers listed ---"
rc=$(run_step6 stray 1 contract-test stray)
check "a clone without markers is refused (exit $rc)" "a clone without governance markers was adopted" [ "$rc" != "0" ]
check "refusal says it is not a governance repo" "no 'does not look like' message; output: $(cat "$TMP/step6-stray.log")" \
  grep -qF "does not look like an IWE governance repo" "$TMP/step6-stray.log"
check_not "nothing is reported as adopted" "a clone without markers was reported as adopted" \
  grep -qF "adopted: owner and structure verified" "$TMP/step6-stray.log"
REAL_MARKERS=$(sed -n 's/^\[harness\] GOVERNANCE_MARKERS=//p' "$TMP/step6-stray.log")
for m in $REAL_MARKERS; do
  check "missing marker $m is listed" "marker $m of the real array is not listed as missing" \
    grep -qF -- "    - $m" "$TMP/step6-stray.log"
done

echo "=== 4. GOVERNANCE_MARKERS is the contract's list and the seed ships every marker ==="
CONTRACT_MARKERS=$(jq -r '.requiredMarkers[]' "$TEMPLATE_ROOT/scripts/governance-repo-contract.json" | tr '\n' ' ')
check "the real loader yields the contract's requiredMarkers" "loader gave '$REAL_MARKERS', contract says '$CONTRACT_MARKERS'" \
  [ "$REAL_MARKERS " = "$CONTRACT_MARKERS" ]
for m in $REAL_MARKERS; do
  [ -e "$TEMPLATE_ROOT/seed/strategy/$m" ] && pass "seed/strategy/$m present" || fail "seed/strategy/$m missing — adoption would reject a freshly seeded repo"
done

echo ""
echo "Result: $PASS_COUNT PASS, $FAIL_COUNT FAIL"
[ "$FAIL_COUNT" -eq 0 ]
