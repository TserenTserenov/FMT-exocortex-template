#!/usr/bin/env bash
# shellcheck disable=SC2034  # the subshells set variables that the function sourced from update.sh reads
# WP-529 Ф270, RT5-2 of the v0.42.0-rc.5 red team: `setup.sh --core` skips the extractor feeders,
# but the first `update.sh --yes` scheduled them anyway — the install mode was not remembered.
# Contract: setup.sh records the mode in <workspace>/.iwe-install-mode; update.sh does not schedule
# the feeders when it says "core", and still does for a full install or an old install without the
# file. Drives the real function extracted from update.sh with a stub feeders script.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
UPDATE_SH="${UPDATE_SH:-$ROOT/update.sh}"
SETUP_SH="${SETUP_SH:-$ROOT/setup.sh}"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/iwe-f270-core-mode.XXXXXX")
trap 'rm -rf "${TMP:?}"' EXIT

FAILS=0
ok()   { echo "  ok: $1"; }
fail() { echo "  FAIL: $1"; FAILS=$((FAILS + 1)); }

FUNCS="$TMP/funcs.sh"
awk '$0 == "backfill_extractor_feeders() {" { found=1 } found { print } found && /^}$/ { exit }' \
  "$UPDATE_SH" > "$FUNCS"
grep -q '^backfill_extractor_feeders() {' "$FUNCS" || { echo "FATAL: backfill_extractor_feeders not found" >&2; exit 2; }

WS="$TMP/ws"
TPL="$WS/FMT-exocortex-template"
mkdir -p "$TPL/scripts" "$TMP/bin"
printf '#!/bin/bash\necho "FEEDERS SCHEDULED"\n' > "$TPL/scripts/setup-extractor-feeders.sh"
printf '#!/bin/bash\nexit 0\n' > "$TMP/bin/claude"
chmod +x "$TMP/bin/claude"

# run_backfill MODE_FILE_CONTENT (empty = no file) -> prints the function's output
run_backfill() (
  rm -f "$WS/.iwe-install-mode"
  [ -n "$1" ] && printf '%s\n' "$1" > "$WS/.iwe-install-mode"
  # shellcheck disable=SC1090
  . "$FUNCS"
  PATH="$TMP/bin:$PATH" SCRIPT_DIR="$TPL" WORKSPACE_DIR="$WS" EFFECTIVE_GOVERNANCE_REPO=DS-strategy
  HOST_GLOBAL_OWNER_CONFLICT=false
  backfill_extractor_feeders 2>&1
)

echo "== update.sh honours the recorded install mode =="
out=$(run_backfill core)
grep -q 'FEEDERS SCHEDULED' <<<"$out" && fail "core install: feeders scheduled ($out)" || ok "core install: feeders not scheduled"
grep -q 'урезанном режиме' <<<"$out" && ok "core install: the skip is explained" || fail "core install: no explanation ($out)"
out=$(run_backfill full)
grep -q 'FEEDERS SCHEDULED' <<<"$out" && ok "full install: feeders scheduled" || fail "full install: $out"
out=$(run_backfill "")
grep -q 'FEEDERS SCHEDULED' <<<"$out" && ok "old install without the file: feeders scheduled as before" || fail "no file: $out"

echo "== setup.sh records the mode =="
grep -q "printf 'core\\\\n' > \"\$WORKSPACE_DIR/.iwe-install-mode\"" "$SETUP_SH" \
  && grep -q "printf 'full\\\\n' > \"\$WORKSPACE_DIR/.iwe-install-mode\"" "$SETUP_SH" \
  && ok "setup.sh writes core/full into .iwe-install-mode" || fail "setup.sh does not record the install mode"

echo
if [ "$FAILS" -gt 0 ]; then
  echo "FAILED: $FAILS check(s)"
  exit 1
fi
echo "PASS"
