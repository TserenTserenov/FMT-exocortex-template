#!/usr/bin/env bash
# Fresh seed-template smoke test / reproduction-gate (Ф-script-contract-gate,
# Этап 2). Two independent checks against an isolated tmpdir — nothing carried
# over from the real installation:
#   1. seed/strategy + create-wp.sh work end-to-end (WP Gate is usable).
#   2. setup.sh --dry-run runs the real install flow to completion, touching
#      no network beyond `gh auth status` and writing nothing to disk.
#
# Part 2 was missing until code review 03.08 caught the earlier version
# overclaiming "install-flow reproduction covered" while only checking
# `[ -f setup.sh ]`. Added with Codex (peer-session 2026-08-03-06): setup.sh
# resolves TEMPLATE_DIR from `dirname "$0"`, so running a copy of it IS
# running the real script against a real (if disposable) template tree — no
# path-faking needed. What DOES need care: `gh auth status` (scripts/
# fmt-critical-alert.sh:69-71's sibling check inside setup.sh, lines ~241-249)
# fires whenever `gh` is on PATH, `SETUP_CI` only prevents a failed auth from
# being fatal, not the call itself — verified by reading setup.sh AND its two
# delegates (setup/build-runtime.sh, setup/install-iwe-paths.sh) for any
# curl/wget/git-clone/git-push outside a `$DRY_RUN` guard, then confirmed
# empirically with tripwire binaries below rather than trusted from the read.

set -euo pipefail

TEMPLATE_ROOT="${IWE_TEMPLATE:-$HOME/IWE/FMT-exocortex-template}"

# --- Part 1: seed/strategy + create-wp.sh ---

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

[ -d "$TEMPLATE_ROOT/seed/strategy" ] ||
  { echo "FAIL: seed/strategy missing from template" >&2; exit 1; }

cp -R "$TEMPLATE_ROOT/seed/strategy" "$TMPDIR/strategy"

required=(
  CLAUDE.md
  REPO-TYPE.md
  docs/WP-REGISTRY.md
  docs/Strategy.md
  inbox
  archive/wp-contexts
  current
)
for path in "${required[@]}"; do
  [ -e "$TMPDIR/strategy/$path" ] ||
    { echo "FAIL: fresh seed missing required path: $path" >&2; exit 1; }
done
echo "✓ Fresh seed/strategy checkout has all paths WP Gate depends on"

export IWE_TEMPLATE="$TEMPLATE_ROOT"
export IWE_ROOT="$TMPDIR"
export IWE_GOVERNANCE_REPO="strategy"

(
  cd "$TMPDIR"
  bash "$TEMPLATE_ROOT/scripts/create-wp.sh" \
    --title "Fresh Seed Smoke" \
    --budget 1h \
    --priority P4 \
    --no-consent-check
) >"$TMPDIR/create.out" 2>&1 || {
  echo "FAIL: create-wp.sh failed against a freshly copied seed" >&2
  cat "$TMPDIR/create.out" >&2
  exit 1
}

WP_FILE=$(find "$TMPDIR/strategy/inbox" -type f -path '*/WP-*/WP-*.md' | head -1)
[ -n "$WP_FILE" ] ||
  { echo "FAIL: fresh seed produced no first WP" >&2; exit 1; }

WP_ID=$(basename "$WP_FILE" .md)
grep -q "$WP_ID" "$TMPDIR/strategy/docs/WP-REGISTRY.md" ||
  { echo "FAIL: fresh-seed WP missing from WP-REGISTRY.md" >&2; exit 1; }

echo "✓ create-wp.sh works end-to-end against a fresh seed checkout ($WP_ID)"

# issue #364: both shipped registries expose the writer's six-column schema,
# and an existing four-column install is migrated without dropping Активация.
for registry in \
  "$TEMPLATE_ROOT/seed/strategy/docs/WP-REGISTRY.md" \
  "$TEMPLATE_ROOT/templates/strategy-skeleton/docs/WP-REGISTRY.md"; do
  grep -qE '^\| # \| P \| Название \| Ст \| Репо \| Бюджет \|' "$registry" ||
    { echo "FAIL: non-canonical shipped registry schema: $registry" >&2; exit 1; }
done

LEGACY_STRATEGY="$TMPDIR/legacy-strategy"
cp -R "$TEMPLATE_ROOT/seed/strategy" "$LEGACY_STRATEGY"
cat > "$LEGACY_STRATEGY/docs/WP-REGISTRY.md" <<'EOF'
# Legacy registry

| # | Название | Статус | Активация |
|---|----------|--------|-----------|
| 7 | **Старый РП** | 🔄 | 2026-07-01: начат |
EOF
IWE_GOVERNANCE_REPO=legacy-strategy bash "$TEMPLATE_ROOT/scripts/create-wp.sh" \
  --title "Legacy Migration Smoke" --budget 1h --priority P4 --no-consent-check \
  >"$TMPDIR/legacy-create.out" 2>&1 || {
    cat "$TMPDIR/legacy-create.out" >&2
    echo "FAIL: create-wp.sh did not migrate a legacy registry" >&2
    exit 1
  }
grep -qE '^\| # \| Название \| Статус \| Активация \| P \| Репо \| Бюджет \|' \
  "$LEGACY_STRATEGY/docs/WP-REGISTRY.md" ||
  { echo "FAIL: legacy registry did not gain canonical columns" >&2; exit 1; }
grep -q '2026-07-01: начат' "$LEGACY_STRATEGY/docs/WP-REGISTRY.md" ||
  { echo "FAIL: legacy Активация value was lost" >&2; exit 1; }
echo "✓ Shipped registries are canonical; legacy schema migrates without data loss"

# --- Part 2: setup.sh --dry-run against a full disposable copy of the template ---

SETUP_TMP=$(mktemp -d)
trap 'rm -rf "$TMPDIR" "$SETUP_TMP"' EXIT

TEMPLATE_COPY="$SETUP_TMP/FMT-exocortex-template"
WORKSPACE="$SETUP_TMP/workspace"
FAKE_BIN="$SETUP_TMP/fake-bin"
NETWORK_LOG="$SETUP_TMP/network.log"
mkdir -p "$TEMPLATE_COPY" "$WORKSPACE" "$FAKE_BIN" "$SETUP_TMP/home"

# tar, not cp -R: streams straight into the copy, no intermediate archive on
# disk, and --exclude keeps .git (history, hooks) out of a throwaway fixture.
tar -C "$TEMPLATE_ROOT" --exclude='./.git' -cf - . | tar -C "$TEMPLATE_COPY" -xf -

make_tripwire() {
  local command_name="$1"
  cat > "$FAKE_BIN/$command_name" <<'SH'
#!/bin/sh
printf '%s\n' "$(basename "$0") $*" >>"$NETWORK_TRIPWIRE_LOG"
exit 97
SH
  chmod +x "$FAKE_BIN/$command_name"
}
make_tripwire gh
make_tripwire curl
make_tripwire wget

# Pre-seed .exocortex.env: setup.sh --dry-run on a truly first-ever run (no
# prior .exocortex.env anywhere) currently makes build-runtime.sh --dry-run
# fail with a real, correctly-surfaced error (found 03.08 fixing the swallowed-
# exit-code bug at setup.sh's build-runtime.sh call site — the error was always
# there, `set -e` without `pipefail` just hid it). Whether first-run dry-run
# should work without ever having run setup.sh for real is a separate product
# question, not decided here. This test instead covers the primary real-world
# case dry-run exists for — an EXISTING install previewing what an update
# would change — which is what most users actually do with --dry-run.
mkdir -p "$WORKSPACE"
cat > "$WORKSPACE/.exocortex.env" <<ENVEOF
GITHUB_USER="contract-test"
WORKSPACE_DIR="$WORKSPACE"
CLAUDE_PATH="claude"
CLAUDE_PROJECT_SLUG="contract-test"
TIMEZONE_HOUR="4"
TIMEZONE_DESC="4:00 UTC"
HOME_DIR="$SETUP_TMP/home"
USER_NAME="contract-test"
GOVERNANCE_REPO="DS-strategy"
IWE_TEMPLATE="$TEMPLATE_COPY"
IWE_RUNTIME="$WORKSPACE/.iwe-runtime"
ENVEOF
cp "$WORKSPACE/.exocortex.env" "$SETUP_TMP/exocortex-env.pristine"

SETUP_OUTPUT="$SETUP_TMP/setup-output.log"
if ! env \
  HOME="$SETUP_TMP/home" \
  PATH="$FAKE_BIN:$PATH" \
  NETWORK_TRIPWIRE_LOG="$NETWORK_LOG" \
  SETUP_CI=1 \
  GITHUB_USER=contract-test \
  WORKSPACE_DIR="$WORKSPACE" \
  bash "$TEMPLATE_COPY/setup.sh" --dry-run >"$SETUP_OUTPUT" 2>&1
then
  echo "FAIL: setup.sh --dry-run exited non-zero" >&2
  cat "$SETUP_OUTPUT" >&2
  exit 1
fi

for anchor in \
  '[1/6] Building generated runtime...' \
  '[4d] Installing IWE environment variables...' \
  '[6/6] Setting up DS-strategy...' \
  '[7/7] Installing Base repos' \
  '[DRY RUN] No changes made.'
do
  grep -qF "$anchor" "$SETUP_OUTPUT" ||
    { echo "FAIL: setup.sh --dry-run output missing expected step: $anchor" >&2; cat "$SETUP_OUTPUT" >&2; exit 1; }
done

# Only expected network-capable call is the local `gh auth status` probe
# (setup.sh checks it unconditionally when `gh` is on PATH — SETUP_CI only
# stops a failed auth from being fatal, it doesn't skip the call). Anything
# else reaching gh/curl/wget is a regression: a dry run must not touch the
# network.
if [ -s "$NETWORK_LOG" ] && grep -qvE '^gh auth status$' "$NETWORK_LOG"; then
  echo "FAIL: dry-run invoked an unexpected network-capable command:" >&2
  cat "$NETWORK_LOG" >&2
  exit 1
fi

# .exocortex.env is pre-seeded above (it must exist for build-runtime.sh to
# have anything to preview) — dry-run must leave its content byte-identical
# to the pristine copy taken right after seeding, not merely "still exist".
cmp -s "$WORKSPACE/.exocortex.env" "$SETUP_TMP/exocortex-env.pristine" ||
  { echo "FAIL: setup.sh --dry-run modified the pre-existing .exocortex.env" >&2; exit 1; }

# Dry run must not create any install artifacts. Every path below is a real
# write target named in setup.sh's own [DRY RUN] echo lines (grepped for
# "Would copy/create/write/generate/install/clone" against $WORKSPACE_DIR/
# and $HOME/ before writing this list — not guessed).
for artifact in \
  "$WORKSPACE/.iwe-runtime" \
  "$WORKSPACE/CLAUDE.md" \
  "$WORKSPACE/memory" \
  "$WORKSPACE/.claude" \
  "$WORKSPACE/.mcp.json" \
  "$WORKSPACE/.iwe-paths" \
  "$WORKSPACE/DS-strategy" \
  "$WORKSPACE/ZP" \
  "$WORKSPACE/FPF" \
  "$WORKSPACE/SPF" \
  "$SETUP_TMP/home/.claude"
do
  [ ! -e "$artifact" ] ||
    { echo "FAIL: setup.sh --dry-run created $artifact" >&2; exit 1; }
done

echo "✓ setup.sh --dry-run runs the real install flow end-to-end, no network beyond gh auth status, no artifacts written"
