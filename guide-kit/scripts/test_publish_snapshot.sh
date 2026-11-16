#!/usr/bin/env bash
# Tests for publish-snapshot.sh (Ф9 system #16, component 3/5).
#
# `gh` is mocked with a fake executable placed first on PATH — publish-snapshot.sh
# only ever calls `gh release view`/`gh release create`, so a small dispatcher
# script that logs its own argv and returns a scripted exit code is sufficient;
# no real network call happens in any of these tests.
#
# Usage: scripts/test_publish_snapshot.sh
# Exit 0 = all checks passed. Exit 1 = first failing check named on stderr.
set -euo pipefail

step() { printf '[test] %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/publish-snapshot.sh"

FIXTURE_DIR="$(mktemp -d)"
trap 'rm -rf "$FIXTURE_DIR"' EXIT

# --- fixture curriculum: one real card so build-snapshot.py has something to package ---
CURRICULUM="$FIXTURE_DIR/curriculum"
mkdir -p "$CURRICULUM/CAT.001" "$CURRICULUM/CAT.002" "$CURRICULUM/CAT.003"
cat > "$CURRICULUM/CAT.001/M-001.md" <<'EOF'
---
id: CAT.001.M-001
name: Test
area: 1
entry_stage: 1
status: current
---

# CAT.001.M-001
EOF

# --- fake `gh` dispatcher: logs argv, honors a scripted exit code / "existing release" list ---
FAKE_BIN="$FIXTURE_DIR/bin"
mkdir -p "$FAKE_BIN"
GH_CALL_LOG="$FIXTURE_DIR/gh-calls.log"
EXISTING_RELEASES_FILE="$FIXTURE_DIR/existing-releases"
: > "$EXISTING_RELEASES_FILE"

cat > "$FAKE_BIN/gh" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$GH_CALL_LOG"
if [ "\$1" = "release" ] && [ "\$2" = "view" ]; then
    tag="\$3"
    grep -qxF "\$tag" "$EXISTING_RELEASES_FILE"
    exit \$?
fi
if [ "\$1" = "release" ] && [ "\$2" = "create" ]; then
    echo "\$3" >> "$EXISTING_RELEASES_FILE"
    exit 0
fi
echo "fake gh: unhandled invocation: \$*" >&2
exit 1
EOF
chmod +x "$FAKE_BIN/gh"

run_with_fake_gh() {
    PATH="$FAKE_BIN:$PATH" "$@"
}

# ---------------------------------------------------------------------------
step "unknown flag exits 1 without touching gh"
: > "$GH_CALL_LOG"
set +e
OUTPUT="$(run_with_fake_gh bash "$SCRIPT" --bogus-flag 2>&1)"
STATUS=$?
set -e
[ "$STATUS" -eq 1 ] || fail "expected exit 1 on unknown flag, got $STATUS"
echo "$OUTPUT" | grep -q "unknown argument" || fail "expected 'unknown argument' in output, got: $OUTPUT"
[ ! -s "$GH_CALL_LOG" ] || fail "gh should not have been invoked for an arg-parsing error"

# ---------------------------------------------------------------------------
step "missing required args exits 1 without touching gh"
: > "$GH_CALL_LOG"
set +e
OUTPUT="$(run_with_fake_gh bash "$SCRIPT" --curriculum-path "$CURRICULUM" 2>&1)"
STATUS=$?
set -e
[ "$STATUS" -eq 1 ] || fail "expected exit 1 on missing --snapshot-date, got $STATUS"
[ ! -s "$GH_CALL_LOG" ] || fail "gh should not have been invoked before required-arg validation"

# ---------------------------------------------------------------------------
step "dry-run builds the archive, calls gh release view, but never gh release create"
: > "$GH_CALL_LOG"
OUTPUT="$(run_with_fake_gh bash "$SCRIPT" --curriculum-path "$CURRICULUM" --snapshot-date 2026-07-19 --dry-run 2>&1)"
echo "$OUTPUT" | grep -q "Dry run: nothing published." || fail "expected dry-run confirmation, got: $OUTPUT"
grep -q "^release view snapshot-2026-07-19" "$GH_CALL_LOG" || fail "expected a release-existence check before building"
grep -q "^release create" "$GH_CALL_LOG" && fail "dry-run must never call 'gh release create'"

# ---------------------------------------------------------------------------
step "real run creates the release with the archive as the asset argument"
: > "$GH_CALL_LOG"
OUTPUT="$(run_with_fake_gh bash "$SCRIPT" --curriculum-path "$CURRICULUM" --snapshot-date 2026-07-20 2>&1)"
echo "$OUTPUT" | grep -q "OK: published snapshot-2026-07-20" || fail "expected publish confirmation, got: $OUTPUT"
grep -q "^release create snapshot-2026-07-20 .*guide-kit-snapshot-2026-07-20\.tar\.gz" "$GH_CALL_LOG" \
    || fail "expected 'gh release create' with the built archive path, got log: $(cat "$GH_CALL_LOG")"

# ---------------------------------------------------------------------------
step "re-running the same snapshot date refuses to overwrite"
set +e
OUTPUT="$(run_with_fake_gh bash "$SCRIPT" --curriculum-path "$CURRICULUM" --snapshot-date 2026-07-20 2>&1)"
STATUS=$?
set -e
[ "$STATUS" -eq 1 ] || fail "expected exit 1 when the release already exists, got $STATUS"
echo "$OUTPUT" | grep -q "already exists" || fail "expected an 'already exists' refusal, got: $OUTPUT"

# ---------------------------------------------------------------------------
step "missing gh binary exits 1 with a clear message"
# The PATH holds only what the script runs before its gh check (dirname).
# Keeping /usr/bin on it is not enough: GitHub-hosted runners ship a real gh
# there, which then answers "not logged in" with exit 4 instead of the
# script's "gh CLI not found" with exit 1.
EMPTY_PATH_BIN="$FIXTURE_DIR/empty-bin"
mkdir -p "$EMPTY_PATH_BIN"
ln -s "$(command -v dirname)" "$EMPTY_PATH_BIN/dirname"
BASH_BIN="$(command -v bash)"
set +e
OUTPUT="$(PATH="$EMPTY_PATH_BIN" "$BASH_BIN" "$SCRIPT" --curriculum-path "$CURRICULUM" --snapshot-date 2026-07-21 2>&1)"
STATUS=$?
set -e
[ "$STATUS" -eq 1 ] || fail "expected exit 1 when gh is absent, got $STATUS"
echo "$OUTPUT" | grep -q "gh CLI not found" || fail "expected a clear 'gh CLI not found' message, got: $OUTPUT"

step "all checks passed"
