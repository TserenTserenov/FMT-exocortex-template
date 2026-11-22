#!/usr/bin/env bash
# wp-phase-digest.sh — deterministic digest of the WP card phase state
# Contract: input WP-N (or N) → stdout `status=...` + `phase_digest=...` +
#           `phase_count=...`, exit 0/1/4 (4: not found scripts/lib/wp-num.sh —
#           installation error, not «WP not found»; see. wp-sync-bundle.sh)
#
# Purpose: peer-session WP-561 2026-09-03-19 (Kimi+Codex) — snapshot-mechanism
# "handoff_snapshot" (on close the agent writes {ref, observed_status,
# observed_phase_state}, on the next open wp-sync-bundle.sh verifies)
# requires THE SAME parser on both ends, otherwise two independent
# ways of reading one file will diverge on their own — Codex, move 1 round 1.
# This script — the sole source of the digest; the closing agent calls
# it directly (manually, to record the snapshot), wp-sync-bundle.sh calls it
# also (for verification on open).
#
# The digest — NOT a count of open phases (that count is blind to re-opening/status change
# with the same number of phases, Codex move 1) — it is a hash of the normalized
# sequence "marker+text" of all phase lines-phases in the file (closed and
# open), or (for structured-phases card indexes) "id+status" all records.
#
# Compatible: bash 3.2+ (macOS), bash 4+ (Linux)

set -euo pipefail

_WPN_ROOT_UP="../.."
_WPN_OPTIONAL=""
# >>> wp-num locate
# Find scripts/lib/wp-num.sh (issue #954) from THIS file's own location with symlinks
# resolved, never from IWE_WORKSPACE / IWE_ROOT / STRATEGY_DIR: callers point those at
# fixtures. Candidates, in order: lib/ next to the file, <root>/scripts/lib, the template
# clone next to a delivered workspace (<root>/IWE), the explicit
# IWE_TEMPLATE. <root> is _WPN_ROOT_UP above the file's directory (set by each consumer
# just above this block: the only per-file difference, checked by test_issue_954_locate.sh).
# The library is mandatory: not finding it is an installation error, not "WP not found",
# hence exit 4 and not 1 (memory/protocol-open.md reads exit 1 as "WP not found").
# A consumer that must keep working without the library (session-guard: its hypothesis gate
# warns and checks the exact card names, it never blocks a session over a missing library)
# sets _WPN_OPTIONAL=1 next to _WPN_ROOT_UP: WP_NUM_LIB then stays empty and nothing is sourced.
_wpn_src="${BASH_SOURCE[0]}"
_wpn_hops=0
while [ -L "$_wpn_src" ] && [ "$_wpn_hops" -lt 40 ]; do
  _wpn_link="$(readlink "$_wpn_src")"
  case "$_wpn_link" in
    /*) _wpn_src="$_wpn_link" ;;
    *) _wpn_src="$(dirname "$_wpn_src")/$_wpn_link" ;;
  esac
  _wpn_hops=$((_wpn_hops + 1))
done
_wpn_dir="$(cd -P "$(dirname "$_wpn_src")" && pwd)"
_wpn_root="$(cd -P "$_wpn_dir/$_WPN_ROOT_UP" && pwd)"
WP_NUM_LIB=""
for _wpn_cand in "$_wpn_dir/lib/wp-num.sh" \
                 "$_wpn_root/scripts/lib/wp-num.sh" \
                 "$_wpn_root/IWE/scripts/lib/wp-num.sh" \
                 ${IWE_TEMPLATE:+"$IWE_TEMPLATE/scripts/lib/wp-num.sh"}; do
  if [ -r "$_wpn_cand" ]; then
    WP_NUM_LIB="$_wpn_cand"
    break
  fi
done
if [ -z "$WP_NUM_LIB" ] && [ -z "${_WPN_OPTIONAL:-}" ]; then
  echo "❌ wp-num.sh not found (installation error, this is not «WP not found»): required scripts/lib/wp-num.sh. Searched: ${_wpn_dir}/lib, ${_wpn_root}/scripts/lib, ${_wpn_root}/IWE/scripts/lib, IWE_TEMPLATE=${IWE_TEMPLATE:-not set}. Update the template: bash update.sh" >&2
  exit 4
fi
if [ -n "$WP_NUM_LIB" ]; then
  # shellcheck source=/dev/null
  . "$WP_NUM_LIB"
fi
# <<< wp-num locate

IWE_WORKSPACE="${IWE_WORKSPACE:-$HOME/IWE}"
GOV_REPO="${IWE_GOVERNANCE_REPO:-governance}"
# Portability (template install): same fallback as wp-sync-bundle.sh -- any
# repo with docs/WP-REGISTRY.md when the configured/default one has none.
if [[ ! -f "$IWE_WORKSPACE/$GOV_REPO/docs/WP-REGISTRY.md" ]]; then
  for cand in "$IWE_WORKSPACE"/*/; do
    if [[ -f "${cand}docs/WP-REGISTRY.md" ]]; then GOV_REPO=$(basename "$cand"); break; fi
  done
fi
STRATEGY_DIR="$IWE_WORKSPACE/$GOV_REPO"
INBOX_DIR="$STRATEGY_DIR/inbox"
ARCHIVE_DIR="$STRATEGY_DIR/archive/wp-contexts"

log_err() { echo "[ERROR] $*" >&2; }

# The same search, as find_wp_file() in wp-sync-bundle.sh (WP-434: folder convention
# is primary): both call wp_num_find_card — one parser on both ends of the snapshot. Previously
# a trimmed copy of the function lived here, and the search diverged (#954): without leading zeros in the name
# folders, without flat files with slug. Always returns 0 (set -e for callers).
find_wp_file() {
  wp_num_find_card "$INBOX_DIR" "$ARCHIVE_DIR" "$1" || true
}

extract_fm_field() {
  local file="$1" field="$2"
  awk '/^---$/{found++; next} found==1{print} found==2{exit}' "$file" 2>/dev/null \
    | grep -E "^${field}:" | head -1 | sed "s/^${field}:[[:space:]]*//" | tr -d '"' || true
}

has_structured_phases() {
  local file="$1"
  awk '
    /^---$/ { fm++; if (fm == 2) exit; next }
    fm != 1 { next }
    /^phases:[[:space:]]*$/ { in_phases=1; next }
    in_phases && /^- id:[[:space:]]*/ { found=1; exit }
    END { exit(found ? 0 : 1) }
  ' "$file" 2>/dev/null
}

# All records structured-phases (id+status), not only open ones — unlike
# from extract_structured_open_phases() in wp-sync-bundle.sh, which by
# design filters on pending/in_progress/blocked for display.
extract_all_structured_phases() {
  local file="$1"
  awk '
    function emit() { if (id != "") print id "|" status }
    /^---$/ { fm++; if (fm == 2) exit; next }
    fm != 1 { next }
    /^phases:[[:space:]]*$/ { in_phases=1; next }
    in_phases && /^[A-Za-z_][A-Za-z0-9_-]*:/ { emit(); in_phases=0; id=""; status=""; next }
    !in_phases { next }
    /^- id:[[:space:]]*/ {
      emit(); id=$0; sub(/^- id:[[:space:]]*/, "", id); status=""; next
    }
    /^  status:[[:space:]]*/ {
      status=$0; sub(/^  status:[[:space:]]*/, "", status)
      sub(/[[:space:]]+#.*/, "", status); sub(/^[[:space:]]+/, "", status); sub(/[[:space:]]+$/, "", status)
      next
    }
    END { emit() }
  ' "$file" 2>/dev/null || true
}

# All lines-checkbox lines of the card body (after the closing --- front matter),
# normalized to "marker|text" — [x]/[ ]/[→] and strikethrough ~~[x]~~
# (see. .claude/rules/formatting.md) are reduced to the single marker 'x'.
extract_all_checkbox_lines() {
  local file="$1"
  awk '/^---$/{fm++; next} fm<2{next} {print}' "$file" 2>/dev/null \
    | grep -E '^\s*-\s*(~~)?\[.\](~~)?\s' \
    | sed -E 's/^\s*-\s*~~\s*\[(.)\]\s*(.*)~~\s*$/\1|\2/; s/^\s*-\s*\[(.)\]\s*/\1|/' \
    | sed -E 's/[[:space:]]+/ /g; s/^[[:space:]]+//; s/[[:space:]]+$//' \
    || true
}

digest_of() {
  # sha256 in 12 hex-characters — sufficient for detect-changed, not for
  # security-invariant; shasum is available on macOS and Linux by default.
  shasum -a 256 2>/dev/null | cut -c1-12 || echo "nodigest"
}

main() {
  if [[ $# -lt 1 ]]; then
    log_err "Usage: wp-phase-digest.sh WP-N (or simply N)"
    exit 1
  fi
  local input="$1"
  local num="${input#WP-}"
  num="${num#wp-}"

  local wp_file
  wp_file=$(find_wp_file "$num")
  if [[ -z "$wp_file" ]]; then
    log_err "WP-${num} not found (neither inbox, nor archive)"
    exit 1
  fi

  local status
  status=$(extract_fm_field "$wp_file" "status")
  [[ -z "$status" ]] && status="unknown"

  local phase_lines phase_count phase_digest
  if has_structured_phases "$wp_file"; then
    phase_lines=$(extract_all_structured_phases "$wp_file")
  else
    phase_lines=$(extract_all_checkbox_lines "$wp_file")
  fi
  phase_count=$(printf '%s\n' "$phase_lines" | grep -c . || true)
  phase_digest=$(printf '%s\n' "$phase_lines" | digest_of)

  echo "status=${status}"
  echo "phase_digest=${phase_digest}"
  echo "phase_count=${phase_count}"
}

main "$@"
