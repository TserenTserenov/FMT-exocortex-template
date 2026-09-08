#!/usr/bin/env bash
# Failure-injection matrix for fmt-critical-alert.sh (Ф-script-contract-gate,
# Этап 2): missing utilities and 4xx/5xx API errors must all classify as a
# critical, non-clean, bounded-diagnostic failure — never a false "0 (✅ clean)".
#
# The script's current contract collapses every gh/API failure to exit 2 (it
# does not distinguish 4xx from 5xx in its exit code or output — that would be
# a change to fmt-critical-alert.sh itself, out of scope here). This test
# verifies the collapse is at least consistent and honest across the failure
# classes the script explicitly checks for (scripts/fmt-critical-alert.sh:69-71).

set -euo pipefail

TEMPLATE_ROOT="${IWE_TEMPLATE:-$HOME/IWE/FMT-exocortex-template}"
SCRIPT="$TEMPLATE_ROOT/scripts/fmt-critical-alert.sh"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# Two distinct base PATHs, not one: real jq/curl live in /usr/bin on macOS, so
# a "missing jq" case whose fallback PATH still includes /usr/bin would find
# the real jq anyway and never exercise the absent-dependency branch at all
# (found running this test for real — it silently died under `set -e` on an
# assertion that could never pass, no diagnostic, looked like a hang). The
# "missing X" cases get MINIMAL_PATH (no jq/curl anywhere on it, verified by
# NEITHER_DIR containing neither). The 4xx/5xx cases need a working jq+curl
# (via proxy) AND python3 (fmt-critical-alert.sh URL-encodes labels with it
# before the injected gh failure fires), so they get API_PATH instead.
REAL_JQ=$(command -v jq)
REAL_CURL=$(command -v curl)
REAL_PYTHON3_DIR=$(dirname "$(command -v python3)")
MINIMAL_PATH="/bin"
API_PATH="$REAL_PYTHON3_DIR:/usr/bin:/bin"

for absent_cmd in jq curl; do
  [ ! -e "/bin/$absent_cmd" ] ||
    { echo "FAIL: MINIMAL_PATH assumption broken — /bin/$absent_cmd exists on this machine" >&2; exit 1; }
done

make_proxy() {
  local name=$1 real=$2
  cat > "$TMPDIR/$name" <<EOF
#!/usr/bin/env bash
exec "$real" "\$@"
EOF
  chmod +x "$TMPDIR/$name"
}
make_proxy jq "$REAL_JQ"
make_proxy curl "$REAL_CURL"

run_expect_2() {
  local name=$1
  shift
  set +e
  "$@" >"$TMPDIR/$name.out" 2>&1
  local rc=$?
  set -e
  [ "$rc" -eq 2 ] || {
    echo "FAIL[$name]: expected rc=2, got $rc" >&2
    cat "$TMPDIR/$name.out" >&2
    exit 1
  }
  ! grep -q "✅ clean" "$TMPDIR/$name.out" ||
    { echo "FAIL[$name]: false clean report" >&2; exit 1; }
}

# --- gh absent ---
mkdir "$TMPDIR/no-gh"
cp "$TMPDIR/jq" "$TMPDIR/curl" "$TMPDIR/no-gh/"
run_expect_2 no-gh env \
  PATH="$TMPDIR/no-gh:$MINIMAL_PATH" \
  IWE_FMT_REPO=x/y \
  bash "$SCRIPT" --no-telegram
grep -q "gh CLI not found" "$TMPDIR/no-gh.out"

# --- jq absent, gh present ---
mkdir "$TMPDIR/no-jq"
cat > "$TMPDIR/no-jq/gh" <<'EOF'
#!/usr/bin/env bash
[ "$1 $2" = "auth status" ] && exit 0
exit 97
EOF
chmod +x "$TMPDIR/no-jq/gh"
cp "$TMPDIR/curl" "$TMPDIR/no-jq/"
run_expect_2 no-jq env \
  PATH="$TMPDIR/no-jq:$MINIMAL_PATH" \
  IWE_FMT_REPO=x/y \
  bash "$SCRIPT" --no-telegram
grep -q "jq not found" "$TMPDIR/no-jq.out"

# --- curl absent, gh+jq present (needed for the Telegram leg, not the API
# leg — API failure alone must already short-circuit before curl matters,
# verified implicitly by the two cases above; this case documents that the
# dependency check at scripts/fmt-critical-alert.sh:71 fires before any API
# call) ---
mkdir "$TMPDIR/no-curl"
cat > "$TMPDIR/no-curl/gh" <<'EOF'
#!/usr/bin/env bash
[ "$1 $2" = "auth status" ] && exit 0
exit 97
EOF
chmod +x "$TMPDIR/no-curl/gh"
cp "$TMPDIR/jq" "$TMPDIR/no-curl/"
run_expect_2 no-curl env \
  PATH="$TMPDIR/no-curl:$MINIMAL_PATH" \
  IWE_FMT_REPO=x/y \
  bash "$SCRIPT" --no-telegram
grep -q "curl not found" "$TMPDIR/no-curl.out"

# --- 4xx and 5xx API errors, plus a large stderr payload from gh ---
for status in 403 500; do
  case_dir="$TMPDIR/http-$status"
  mkdir "$case_dir"
  cp "$TMPDIR/jq" "$TMPDIR/curl" "$case_dir/"

  cat > "$case_dir/gh" <<EOF
#!/usr/bin/env bash
[ "\$1 \$2" = "auth status" ] && exit 0
case "\$*" in
  *"/issues?"*)
    i=0
    while [ "\$i" -lt 4096 ]; do
      printf 'E' >&2
      i=\$((i + 1))
    done
    echo " HTTP $status injected" >&2
    exit 1
    ;;
  *"repos/x/y"*)
    echo '{"fork":false,"parent":null,"has_issues":true}'
    exit 0
    ;;
esac
exit 97
EOF
  chmod +x "$case_dir/gh"

  run_expect_2 "http-$status" env \
    PATH="$case_dir:$API_PATH" \
    IWE_FMT_REPO=x/y \
    bash "$SCRIPT" --no-telegram

  grep -q "gh api failed" "$TMPDIR/http-$status.out"
  # Bounded diagnostic: a detector that echoes gh's raw stderr straight into
  # the DayPlan/WeekClose report would flood it — script must not do that.
  [ "$(wc -c < "$TMPDIR/http-$status.out")" -lt 2048 ] ||
    { echo "FAIL[http-$status]: unbounded diagnostic (gh stderr leaked through raw)" >&2; exit 1; }
done

echo "✓ Missing gh/jq/curl and 4xx/5xx API errors all classify as bounded, non-clean critical failures"
