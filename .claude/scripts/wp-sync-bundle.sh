#!/usr/bin/env bash
# wp-sync-bundle.sh — deterministic bundler context of WP for sync-phase WP Gate
# Contract: input WP-N or N → stdout markdown bundle, exit 0/1/2/3/4
#   First machine-readable lines stdout: GIT_SYNC_STATUS / GIT_SYNC_DETAIL /
#   [GIT_SYNC_OVERRIDE] / CARD_SOURCE (worktree | origin-pinned oid=<40hex>
#   behind=N ahead=M | worktree-forced). WP-561 Phase24: when STALE/DIVERGED and
#   fresh remote-tracking ref cards are read from the snapshot of origin (exit 0).
#   exit 4: not found scripts/lib/wp-num.sh — installation error, not «WP not found»
#   (exit 1); checked first, before reading configuration and registry. The same code 4
#   is returned by the handoff_snapshot check handoff_snapshot, when it was not found by wp-phase-digest.sh.
# see WP-294
# Compatible: bash 3.2+

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

# ---------------------------------------------------------------------------
# Config (with resilience fallback — see WP-294)
# ---------------------------------------------------------------------------
IWE_WORKSPACE="${IWE_WORKSPACE:-$HOME/IWE}"
if [[ ! -d "$IWE_WORKSPACE" ]]; then
  echo "[WARN] IWE_WORKSPACE=$IWE_WORKSPACE does not exist, fallback to $HOME/IWE" >&2
  IWE_WORKSPACE="$HOME/IWE"
fi

GOV_REPO="${IWE_GOVERNANCE_REPO:-governance}"
# Resilience: if GOV_REPO set externally, but it does not contain WP-REGISTRY.md — search for any repo containing it
if [[ ! -f "$IWE_WORKSPACE/$GOV_REPO/docs/WP-REGISTRY.md" ]]; then
  found_repo=""
  for cand in "$IWE_WORKSPACE"/*/; do
    if [[ -f "${cand}docs/WP-REGISTRY.md" ]]; then
      found_repo=$(basename "$cand")
      break
    fi
  done
  if [[ -n "$found_repo" ]]; then
    echo "[WARN] IWE_GOVERNANCE_REPO=$GOV_REPO does not contain WP-REGISTRY.md, fallback to $found_repo" >&2
    GOV_REPO="$found_repo"
  fi
fi
if [[ ! -f "$IWE_WORKSPACE/$GOV_REPO/docs/WP-REGISTRY.md" ]]; then
  echo "[ERROR] Governance repo with WP-REGISTRY.md not found in $IWE_WORKSPACE" >&2
  exit 1
fi

STRATEGY_DIR="$IWE_WORKSPACE/$GOV_REPO"
INBOX_DIR="$STRATEGY_DIR/inbox"
ARCHIVE_DIR="$STRATEGY_DIR/archive/wp-contexts"
# WP-561 Phase24 (peer-session 2026-09-27-09, Claude+Kimi+Codex): where the cards
# are actually read from. Normally the working copy ($STRATEGY_DIR). When the
# working copy is STALE/DIVERGED from origin and the remote-tracking ref is
# provably fresh, the cards are read from a full snapshot of ONE pinned origin
# commit instead (see materialize_origin_tree) -- the shared canonical checkout
# on this machine is routinely behind under 20+ concurrent sessions, and
# blocking the gate (exit 3) punished the opening agent for someone else's
# unclosed session. CARD_ROOT/INBOX_DIR/ARCHIVE_DIR/REGISTRY_FILE all switch
# together; GIT_LOG_REV pins git-log lookups to the same commit so history and
# content come from the same point in time. ORIGIN_WS is the temp workspace
# that holds "$ORIGIN_WS/$GOV_REPO" (same shape as a real IWE_WORKSPACE, so
# wp-phase-digest.sh can be pointed at it unchanged).
CARD_ROOT="$STRATEGY_DIR"
CARD_SOURCE="worktree"
GIT_LOG_REV=""
ORIGIN_WS=""
DRIFT_FILE=""   # global on purpose: the EXIT trap runs after main() returned, a `local` would be out of scope (cold review 27.09: 569 leaked /tmp/wp-sync-drift.* files)

# Sibling helper — sole source of the phase digest (see. its own
# header: WP-561 2026-09-03-19, Codex "the same parser on both
# ends"). Resolved relative to the location of THIS file, not a hardcoded path.
PHASE_DIGEST_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/wp-phase-digest.sh"
REGISTRY_FILE="$STRATEGY_DIR/docs/WP-REGISTRY.md"
GIT_LOG_DAYS="${WP_SYNC_GIT_DAYS:-14}"

# WP-561 Phase20: git-vs-origin sync gate. Read-only (ls-remote, no fetch) — see
# lib header for why a full fetch is wrong on a checkout dozens of worktrees
# share. Missing lib is not fatal here (checked at call site below).
#
# Resolved from this file's own location (same pattern as PHASE_DIGEST_SCRIPT
# above), NOT from $IWE_WORKSPACE: callers legitimately override IWE_WORKSPACE
# to point bundle at a fixture/probe root (wp-sync-bundle-batch.sh,
# wp-pipeline-checks-runner.sh) while the library itself always lives in the
# real root next to this script -- resolving it via $IWE_WORKSPACE silently
# broke every fixture-based test run (caught by wp-pipeline-checks-runner.sh).
GIT_SYNC_TIMEOUT="${WP_SYNC_GIT_TIMEOUT:-15}"
FIND_PYTHON3="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/find-python3.sh"
GIT_SYNC_LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/scripts/lib/git-sync-status.sh"
# issue #1229: a custom layout where .claude/scripts/ and scripts/lib/ are not
# siblings under the same root (IWE_SCRIPTS from .iwe-paths points elsewhere)
# never finds the self-relative path above. Fallback only -- the self-relative
# lookup stays first and unconditional, so the fixture isolation above is untouched.
if [[ ! -r "$GIT_SYNC_LIB" && -n "${IWE_SCRIPTS:-}" && -f "$IWE_SCRIPTS/lib/git-sync-status.sh" ]]; then
  echo "[GIT-SYNC] self-relative git-sync-status.sh not found, trying \$IWE_SCRIPTS/lib/git-sync-status.sh" >&2
  GIT_SYNC_LIB="$IWE_SCRIPTS/lib/git-sync-status.sh"
fi
if [[ -r "$GIT_SYNC_LIB" ]]; then
  # shellcheck source=/dev/null
  source "$GIT_SYNC_LIB"
fi

# ---------------------------------------------------------------------------
# Audit log
# ---------------------------------------------------------------------------
log_sync() {
  local wp_num="${1:-unknown}"
  local result="${2:-unknown}"
  local reason="${3:-}"
  local logfile="$IWE_WORKSPACE/.claude/state/wp-sync.log"
  mkdir -p "$(dirname "$logfile")"
  echo "$(date '+%Y-%m-%d %H:%M:%S') | WP-${wp_num} | ${result} | ${reason}" >> "$logfile"
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log_warn() { echo "[WARN] $*" >&2; }
log_err()  { echo "[ERROR] $*" >&2; }
log_parse_err() { echo "[PARSE-ERROR] $*" >&2; }

# Validate that file has parseable YAML frontmatter (between two `---` markers)
validate_frontmatter() {
  local file="$1"
  local fm_count
  fm_count=$(grep -c '^---$' "$file" 2>/dev/null | head -1 || true)
  fm_count="${fm_count:-0}"
  if [[ "$fm_count" -lt 2 ]]; then
    log_parse_err "File does not have valid YAML frontmatter (requires at least 2 lines '---'): $file"
    return 1
  fi
  return 0
}

# Path relative to CARD_ROOT; falls back to the input when no python3 resolves.
# Only the standard library is needed here, so PyYAML must not be required
# (without it origin-pinned mode would log a snapshot path outside the repo).
card_relpath() {
  local py
  if py="$("$FIND_PYTHON3" --stdlib-only 2>/dev/null)"; then
    "$py" -c "import os, sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))" "$1" "$CARD_ROOT" 2>/dev/null || echo "$1"
  else
    echo "$1"
  fi
}

wp_path_label() {
  local filepath="$1"
  case "$filepath" in
    "$CARD_ROOT"/*) echo "${filepath#"$CARD_ROOT"/}" ;;
    "$STRATEGY_DIR"/*) echo "${filepath#"$STRATEGY_DIR"/}" ;;
    *) echo "$filepath" ;;
  esac
}

# materialize_origin_tree <repo> <remote_oid_from_ls_remote> -> 0 and sets
# ORIGIN_WS, or 1 (fail closed) on ANY doubt. Codex, round 1 (2026-09-27-09):
# equality of the remote-tracking ref with the ls-remote OID of the SAME check
# is the linearisation point -- an ancestor check would legalise a stale ref;
# `cat-file -e` proves the object is here but not that it is current. After
# the check everything is read by the full OID, never by the symbolic
# `origin/<branch>`, which may move underneath us (the refs-sync-broker
# advances it every minute). Never fetches: same invariant as
# scripts/lib/git-sync-status.sh (shared .git across dozens of worktrees).
# The snapshot is the FULL card universe (inbox/, archive/wp-contexts/,
# docs/WP-REGISTRY.md) at one OID -- a partial tree of "known" cards would
# make the glob/reverse-lookup paths of find_wp_file report false
# "not found" (Codex, round 1). Measured 27.09: 3.8k files / 65 MB in 0.6 s.
materialize_origin_tree() {
  local repo="$1" remote_oid="$2" branch local_ref_oid
  [[ "$remote_oid" =~ ^[0-9a-f]{40}$ ]] || return 1
  branch=$(git -C "$repo" symbolic-ref --quiet --short HEAD 2>/dev/null) || return 1
  [[ -n "$branch" ]] || return 1
  local_ref_oid=$(git -C "$repo" rev-parse --verify --quiet "refs/remotes/origin/${branch}^{commit}" 2>/dev/null) || return 1
  [[ "$local_ref_oid" == "$remote_oid" ]] || return 1
  git -C "$repo" cat-file -e "${remote_oid}^{commit}" 2>/dev/null || return 1
  ORIGIN_WS=$(mktemp -d "${TMPDIR:-/tmp}/wp-sync-origin.XXXXXX") || { ORIGIN_WS=""; return 1; }
  mkdir -p "$ORIGIN_WS/$GOV_REPO" || { rm -rf "$ORIGIN_WS"; ORIGIN_WS=""; return 1; }
  # Template installs may lack archive/ or inbox/ (fresh DS-strategy): a
  # missing pathspec makes `git archive` fail outright, so pass only paths
  # that exist in this commit. The registry stays mandatory (checked below).
  local tree_paths=() tp
  for tp in inbox archive/wp-contexts docs/WP-REGISTRY.md; do
    git -C "$repo" cat-file -e "${remote_oid}:${tp}" 2>/dev/null && tree_paths+=("$tp")
  done
  [[ ${#tree_paths[@]} -gt 0 ]] || { rm -rf "$ORIGIN_WS"; ORIGIN_WS=""; return 1; }
  if ! git -C "$repo" archive --format=tar "$remote_oid" -- "${tree_paths[@]}" 2>/dev/null \
      | tar -x -C "$ORIGIN_WS/$GOV_REPO" 2>/dev/null; then
    rm -rf "$ORIGIN_WS"; ORIGIN_WS=""
    return 1
  fi
  [[ -f "$ORIGIN_WS/$GOV_REPO/docs/WP-REGISTRY.md" ]] || { rm -rf "$ORIGIN_WS"; ORIGIN_WS=""; return 1; }
  return 0
}

cleanup_tmp() {
  [[ -n "${DRIFT_FILE:-}" ]] && rm -f "$DRIFT_FILE"
  [[ -n "${ORIGIN_WS:-}" && -d "${ORIGIN_WS:-/nonexistent}" ]] && rm -rf "$ORIGIN_WS"
  return 0
}

# Path of the WP's card ("" when there is none). The lookup itself lives in
# scripts/lib/wp-num.sh (issue #954): canonical folder cards in either spelling
# (WP-044/ and the older WP-44/, inbox then archive, WP-434/#267) before the last-resort
# `wp:` grep, which cannot tell a card from a note carrying the same field. The path
# that exists is returned as found. Always returns 0: callers run under `set -e`.
find_wp_file() {
  wp_num_find_card "$INBOX_DIR" "$ARCHIVE_DIR" "$1" || true
}

extract_fm_field() {
  local file="$1"
  local field="$2"
  awk '/^---$/{found++; next} found==1{print} found==2{exit}' "$file" 2>/dev/null \
    | grep -E "^${field}:" \
    | head -1 \
    | sed "s/^${field}:[[:space:]]*//" \
    | tr -d '"' \
    || true
}

# Extract both an inline field value and its indented continuation from YAML
# frontmatter. This is intentionally a narrow reader for reference sections,
# not a general YAML parser: callers recognize WP-N references and legacy
# numeric list scalars explicitly.
extract_fm_section() {
  local file="$1"
  local field="$2"
  awk -v field="$field" '
    /^---$/ { fm_count++; if (fm_count == 2) exit; next }
    fm_count != 1 { next }
    $0 ~ ("^" field ":[[:space:]]*") {
      value=$0
      sub("^[^:]+:[[:space:]]*", "", value)
      sub(/^[[:space:]]*#.*/, "", value)
      sub(/[[:space:]]+#.*/, "", value)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      if (value != "") {
        print value
        exit
      }
      in_field=1
      next
    }
    in_field && /^[A-Za-z_][A-Za-z0-9_-]*:[[:space:]]*/ { exit }
    in_field {
      value=$0
      sub(/^[[:space:]]*#.*/, "", value)
      sub(/[[:space:]]+#.*/, "", value)
      if (value != "") print value
    }
  ' "$file" 2>/dev/null || true
}

extract_wp_display_name() {
  local file="$1"
  local value
  value=$(extract_fm_field "$file" "name")
  [[ -n "$value" ]] || value=$(extract_fm_field "$file" "title")
  echo "$value"
}

# Extract WP numbers from either an inline or block related field.
extract_related_wps() {
  local file="$1"
  extract_fm_section "$file" "related" \
    | awk '
      function trim(value) {
        sub(/^[[:space:]]+/, "", value)
        sub(/[[:space:]]+$/, "", value)
        gsub(/^"|"$/, "", value)
        return value
      }
      function emit_bare(value) {
        value=trim(value)
        if (value ~ /^[0-9]+$/) print "WP-" value
      }
      function emit_flow(line, content, count, item, i) {
        line=trim(line)
        if (line ~ /^[A-Za-z_][A-Za-z0-9_-]*:[[:space:]]*\[.*\]$/) {
          sub(/^[^:]+:[[:space:]]*/, "", line)
        } else if (line ~ /^-[[:space:]]*\[.*\]$/) {
          sub(/^-[[:space:]]*/, "", line)
        } else if (line !~ /^\[.*\]$/) {
          return
        }
        content=line
        sub(/^\[/, "", content)
        sub(/\]$/, "", content)
        count=split(content, item, ",")
        for (i=1; i<=count; i++) emit_bare(item[i])
      }
      {
        line=$0
        while (match(line, /WP-[0-9]+/)) {
          print substr(line, RSTART, RLENGTH)
          line=substr(line, 1, RSTART - 1) "X" substr(line, RSTART + RLENGTH)
        }
        emit_flow($0)
        scalar=trim($0)
        if (scalar ~ /^[0-9]+$/) {
          emit_bare(scalar)
        } else if (scalar ~ /^-[[:space:]]*[0-9]+[[:space:]]*$/) {
          sub(/^-[[:space:]]*/, "", scalar)
          emit_bare(scalar)
        } else if (scalar ~ /^[A-Za-z_][A-Za-z0-9_-]*:[[:space:]]*[0-9]+[[:space:]]*$/) {
          sub(/^[^:]+:[[:space:]]*/, "", scalar)
          emit_bare(scalar)
        }
      }
    ' \
    || true
}

# Extract WP numbers from blockers: block in frontmatter (symmetric to
# extract_related_wps — see WP-503 Phase6 peer-session 2026-07-28: blockers:
# schema is not standardized (5/~100 cards, 3 different shapes), but any
# shape that embeds a WP-NNN reference is caught by the same regex).
extract_blocker_wps() {
  local file="$1"
  extract_fm_section "$file" "blockers" \
    | grep -oE 'WP-[0-9]+' \
    || true
}

# Dependency snapshot, written by the closing agent into frontmatter current
# card (WP-561 A/B: `wp-context-update` writes it on close for each
# `depends_on`). Format:
#   handoff_snapshot:
#     - ref: WP-484
#       observed_status: in_progress
#       observed_phase_digest: 64d50a10e003
# Output: one line per record, "ref|observed_status|observed_phase_digest".
extract_handoff_snapshot() {
  local file="$1"
  awk '
    function trim(v) {
      sub(/[[:space:]]+#.*/, "", v)   # inline # comment, same as extract_all_structured_phases
      gsub(/"/, "", v)                # quoted scalars ("WP-484"), same as extract_fm_field
      sub(/^[[:space:]]+/, "", v); sub(/[[:space:]]+$/, "", v)
      return v
    }
    function emit() { if (ref != "") print ref "|" ostatus "|" odigest }
    /^---$/ { fm++; if (fm == 2) exit; next }
    fm != 1 { next }
    /^handoff_snapshot:[[:space:]]*$/ { in_block=1; next }
    in_block && /^[A-Za-z_][A-Za-z0-9_-]*:/ { emit(); in_block=0; ref=""; ostatus=""; odigest=""; next }
    !in_block { next }
    /^[[:space:]]*-[[:space:]]*ref:[[:space:]]*/ {
      emit(); ref=$0; sub(/^[[:space:]]*-[[:space:]]*ref:[[:space:]]*/, "", ref); ref=trim(ref)
      ostatus=""; odigest=""; next
    }
    /^[[:space:]]+observed_status:[[:space:]]*/ {
      ostatus=$0; sub(/^[[:space:]]+observed_status:[[:space:]]*/, "", ostatus); ostatus=trim(ostatus); next
    }
    /^[[:space:]]+observed_phase_digest:[[:space:]]*/ {
      odigest=$0; sub(/^[[:space:]]+observed_phase_digest:[[:space:]]*/, "", odigest); odigest=trim(odigest); next
    }
    END { emit() }
  ' "$file" 2>/dev/null || true
}

# Get relation type for a given WP number from current file's frontmatter
get_rel_type() {
  local file="$1"
  local target_num="$2"
  local matching_line relation_type
  matching_line=$(extract_fm_section "$file" "related" \
    | awk -v target="$target_num" '
        function trim(value) {
          sub(/^[[:space:]]+/, "", value)
          sub(/[[:space:]]+$/, "", value)
          gsub(/^"|"$/, "", value)
          return value
        }
        function has_bare(line, content, count, item, i, scalar) {
          line=trim(line)
          if (line ~ /^[A-Za-z_][A-Za-z0-9_-]*:[[:space:]]*\[.*\]$/) {
            sub(/^[^:]+:[[:space:]]*/, "", line)
          } else if (line ~ /^-[[:space:]]*\[.*\]$/) {
            sub(/^-[[:space:]]*/, "", line)
          } else if (line ~ /^\[.*\]$/) {
            # already a flow sequence
          } else {
            scalar=line
            if (scalar ~ /^-[[:space:]]*[0-9]+[[:space:]]*$/) {
              sub(/^-[[:space:]]*/, "", scalar)
            } else if (scalar ~ /^[A-Za-z_][A-Za-z0-9_-]*:[[:space:]]*[0-9]+[[:space:]]*$/) {
              sub(/^[^:]+:[[:space:]]*/, "", scalar)
            }
            return trim(scalar) == target
          }
          content=line
          sub(/^\[/, "", content)
          sub(/\]$/, "", content)
          count=split(content, item, ",")
          for (i=1; i<=count; i++) {
            if (trim(item[i]) == target) return 1
          }
          return 0
        }
        {
          raw=$0
          if (raw ~ ("WP-" target "([^0-9]|$)")) { print raw; exit }
          if (has_bare(raw)) { print raw; exit }
        }
      ' \
    || true)
  if [[ -z "$matching_line" ]]; then
    echo "body_ref"
    return
  fi
  relation_type=$(printf '%s\n' "$matching_line" \
    | grep -oE '(depends_on|references|complementary|parent|child)' \
    | head -1 \
    || true)
  if [[ -n "$relation_type" ]]; then
    echo "$relation_type"
  else
    echo "related"
  fi
}

grep_body_wps() {
  local file="$1"
  awk '/^---$/{fm++; next} fm<2{next} {print}' "$file" 2>/dev/null \
    | grep -oE 'WP-[0-9]+' \
    | grep -oE '[0-9]+' \
    | sort -u \
    || true
}

# issue #473: registry status column — by the header row `| # | ... |`, not by
# fixed position (matches in spirit with find_header_columns() in find_header_columns() in
# scripts/build-active-wp.py: different registries name/reorder columns).
registry_status_column() {
  local header
  header=$(grep -E '^\|[[:space:]]*#[[:space:]]*\|' "$REGISTRY_FILE" 2>/dev/null | head -1)
  [[ -z "$header" ]] && return 1
  # issue #717 follow-up (found during regression-regression tests on this same phase, the
  # same bug class, different failure): under certain locales (e.g.. en_US.UTF-8
  # on macOS/awk-BWK 20200816) `==` in awk between two DIFFERENT Cyrillic
  # strings returned true true — not a case issue, but corruption of the comparison itself for
  # multibyte strings at the level of locale-aware collation locale-aware collation. `tolower()` for
  # Cyrillic in this case is also locale-dependent (under bare `C` does not fold
  # case at all). The solution — do not rely on either `tolower()`, or on
  # locale-aware `==`: enumerate both cases as literals AND count bytes under
  # `LC_ALL=C`, where `==` — plain byte-by-byte comparison without collation.
  LC_ALL=C awk -F'|' -v h="$header" 'BEGIN {
    n = split(h, cells, "|")
    for (i = 1; i <= n; i++) {
      c = cells[i]; gsub(/^[ \t]+|[ \t]+$/, "", c)
      if (c == "Status" || c == "status" || c == "STATUS" || c == "St" || c == "st") { print i; exit }
    }
  }'
}

registry_status() {
  local num="$1" prev="" malformed="_invalid WP number: ${1}_"
  # Found in peer session with-session with Codex (turn 3): the sole caller (line ~514)
  # currently always passes a bare number (the same invariant is verified by
  # the adjacent `grep -cE '^[0-9]+$'` at line ~608), but a public function must not
  # be required to rely on caller discipline — "WP-47" would silently not be found.
  #
  # issue #954: the number is read by the SAME rules as wp_num_normalize (scripts/lib/wp-num.sh),
  # which this function must not call (the #473/#713/#871 tests cut it out by name and run it
  # alone), so the rules are repeated here step for step and test_issue_954_wp_number_forms.sh
  # compares the two on a table of inputs: at most 64 characters in all (a prefix counts),
  # surrounding spaces and ~~ / ** wrappers peeled, a WP- prefix in any case, digits only, at most
  # 9 of them after the leading zeros. It used to take 1-4 digits and only "WP-" / "wp-", so
  # "00044" -- and "wP-044" -- came back as "invalid number" and failed the canary although
  # the library, the card lookup and close-wp.sh all read them as 44.
  [[ "${#num}" -le 64 ]] || { echo "$malformed"; return; }
  num="${num#"${num%%[![:space:]]*}"}"
  num="${num%"${num##*[![:space:]]}"}"
  while [[ "$num" != "$prev" ]]; do
    prev="$num"
    case "$num" in
      '~~'*'~~') num="${num#'~~'}"; num="${num%'~~'}" ;;
      '**'*'**') num="${num#'**'}"; num="${num%'**'}" ;;
    esac
  done
  case "$num" in
    [Ww][Pp]-*) num="${num#???}" ;;
  esac
  [[ "$num" =~ ^[0-9]+$ ]] || { echo "$malformed"; return; }
  # issue #715: leading zeros (WP-038) did not match the bare "38" in the registry —
  # normalize BEFORE building regex row search regex. Zeros are stripped by text manipulation, not arithmetic:
  # `10#` forces base 10 (otherwise bash interprets "038" as an invalid octal literal),
  # but a long digit string would silently overflow 64-bit integer silently.
  num="${num#"${num%%[!0]*}"}"
  [[ -n "$num" ]] || num=0
  [[ "${#num}" -le 9 ]] || { echo "$malformed"; return; }
  num=$((10#$num))
  if [[ ! -f "$REGISTRY_FILE" ]]; then
    echo "_REGISTRY file not found REGISTRY_"
    return
  fi
  # issue #473: issue #473: previously the row was searched via `grep "WP-${num}[^0-9]"` —
  # a substring, which also matches prose in OTHER rows (for example,
  # "opened as spin-off WP-47" in the status of WP-49 returned the status of WP-49 when
  # querying WP-47). A row is identified by ITS OWN first cell (WP number), WP-47). The row is identified by ITS OWN first cell (WP number),
  # using the same technique, as ROW_RE in build-active-wp.py.
  # issue #716: a marker next to the number ("13★") did not match the previous pattern
  # (required a space/pipe immediately after the number) — the search would skip to another
  # row with the same number (for example a struck-through previous iteration).
  # `[^0-9|]*` allows an arbitrary suffix between the number and the delimiter
  # column, but not a digit — otherwise "13" would also match "138".
  # issue #871: the number column is also written with a prefix ("| **WP-117** |") — the canonical form
  # (create-wp.sh) stores a bare number, but the registry — a journal file, which is also maintained
  # by hand. Without `(WP-|wp-)?` such a row would silently produce «not in registry», indistinguishable
  # from a genuine absence. The prefix is allowed only immediately before the number, therefore
  # "WP-1170" still-does not match 117.
  # issue #954: the same cell is also written with leading zeros ("| WP-044 |", as named by
  # the WP card folder create-wp.sh) — `0*` between the prefix and the number. The query has already been
  # normalized above (44), so "440" and "0440" still-do not match 44:
  # a digit after the number is forbidden by `[^0-9|]*`. The same pattern is returned by
  # wp_num_registry_cell_regex (scripts/lib/wp-num.sh) for close-wp.sh; the function
  # intentionally does not call the library -- tests #473/#713/#871 strip it out by name and — tests #473/#713/#871 strip it out by name and
  # run separately from the rest of the file.
  local regex="^\|[[:space:]]*(~~)?(\*\*)?(WP-|wp-)?0*${num}(\*\*)?(~~)?[^0-9|]*[[:space:]]*\|"
  local match_count
  match_count=$(grep -cE "$regex" "$REGISTRY_FILE" 2>/dev/null || true)
  match_count=${match_count:-0}
  if [[ "$match_count" -eq 0 ]]; then
    echo "_not in registry_"
    return
  fi
  if [[ "$match_count" -gt 1 ]]; then
    # issue #716: previously silent `head -1` could silently return
    # OPPOSITE of the actual status — now the ambiguity is at least
    # visible in stderr, instead of a silent confident error on the first line.
    echo "ambiguous: $match_count matches for number ${num} in registry, first line taken" >&2
  fi
  local line
  line=$(grep -E "$regex" "$REGISTRY_FILE" 2>/dev/null | head -1)
  local status_col status_cell
  status_col=$(registry_status_column)
  if [[ -z "$status_col" ]]; then
    echo "_status column not found in registry header_"
    return
  fi
  # Status is taken from ITS OWN cell, not by grepping emoji across the whole line —
  # an emoji in a neighboring column description could previously override the verdict (issue #473).
  status_cell=$(echo "$line" | awk -F'|' -v col="$status_col" '{ v=$col; gsub(/^[ \t]+|[ \t]+$/, "", v); print v }')
  # issue #717: plain `grep -q 'EMOJI'` depends on locale/build grep — on
  # some machines (e.g.. GNU grep 3.0 + en_US.UTF-8) multibyte literal
  # silently did not match, even though the bytes matched, and the entire status axis went blind silently.
  # `LC_ALL=C grep -F` compares as a byte-level fixed-string, does not parse emoji
  # as regex-regex character class — does not depend on the build locale. Scope
  # — only these calls, not the entire script (global `export LC_ALL=C` risks
  # breaking sorting/slicing of multibyte strings in other parts of the file, not
  # related to this function).
  local resolved=""
  if   LC_ALL=C grep -qF '✅' <<<"$status_cell"; then resolved="✅ done"
  elif LC_ALL=C grep -qF '🔄' <<<"$status_cell"; then resolved="🔄 in_progress"
  elif LC_ALL=C grep -qF '⏳' <<<"$status_cell"; then resolved="⏳ pending"
  elif LC_ALL=C grep -qF '📦' <<<"$status_cell"; then resolved="📦 archived"
  elif LC_ALL=C grep -qF '⏸' <<<"$status_cell"; then resolved="⏸ paused"
  elif LC_ALL=C grep -qF '⏹' <<<"$status_cell"; then resolved="⏹ cancelled"
  elif LC_ALL=C grep -qF '🔁' <<<"$status_cell"; then resolved="🔁 rolled into sprint"
  # issue #964: "↗️ merged into another WP" is in the registry legend the template ships
  # (seed/strategy/docs/WP-REGISTRY.md) and is a terminal status like ✅ and 📦, yet the
  # resolver did not know it. Matched by its base character, like ⏸ above (the ️ variation
  # selector is optional in registries). Last on purpose: it never outranks a status
  # emoji that sits in the same cell. "frozen" is deliberately NOT here: the platform's
  # status vocabulary is the pilot's decision.
  elif LC_ALL=C grep -qF '↗' <<<"$status_cell"; then resolved="↗️ merged"
  fi
  if [[ -n "$resolved" ]]; then
    echo "$resolved"
    return
  fi
  local text_status
  text_status=$(echo "$status_cell" | grep -oE '(done|in_progress|pending|paused|archived|closed|open)' | head -1 || true)
  if [[ -n "$text_status" ]]; then
    echo "$text_status"
    return
  fi
  # issue #714: strikethrough — fallback AFTER, the dedicated status column did not
  # return an answer, not a check across the whole line before reading the column. Previously, not checking across the whole line before reading the column. Previously
  # strikethrough NAME with an active status in the column (for example 📦) produced
  # false "~~done~~" — the dedicated column now always takes precedence over row formatting.
  # issue #713: pipeline exit code `grep | head` was taken from `head`,
  # which always exits successfully even on empty input — `||` was
  # unreachable, and an empty result leaked out as-is. An intermediate
  # variable (text_status above) — the only reliable way to distinguish
  # "found" from "not found" on empty grep output grep.
  if echo "$line" | grep -qE '~~'; then
    echo "~~done~~ (strikethrough)"
  else
    echo "_status unknown_"
  fi
}

git_log_for_file() {
  local filepath="$1"
  local git_root strategy_root
  git_root=$(git -C "$STRATEGY_DIR" rev-parse --show-toplevel 2>/dev/null || true)
  [[ -z "$git_root" ]] || git_root=$(cd "$git_root" 2>/dev/null && pwd -P || true)
  strategy_root=$(cd "$STRATEGY_DIR" 2>/dev/null && pwd -P || true)
  if [[ -z "$git_root" || -z "$strategy_root" || "$git_root" != "$strategy_root" ]]; then
    echo "_git unavailable_"
    return
  fi
  local relpath
  relpath=$(card_relpath "$filepath")
  local commits
  # GIT_LOG_REV (origin-pinned mode) keeps history and content on the same commit.
  commits=$(
    cd "$STRATEGY_DIR" && \
    git log -5 --oneline --since="${GIT_LOG_DAYS} days ago" ${GIT_LOG_REV:+"$GIT_LOG_REV"} -- "$relpath" 2>/dev/null || true
  )
  if [[ -z "$commits" ]]; then
    echo "_no commits in the last ${GIT_LOG_DAYS}d_"
  else
    echo "$commits"
  fi
}

extract_open_phases() {
  local file="$1"
  if has_structured_phases "$file"; then
    extract_structured_open_phases "$file" | head -20
  else
    awk '/^---$/{fm++; next} fm<2{next} {print}' "$file" 2>/dev/null \
      | grep -E '^\s*- \[ \]' \
      | sed 's/^\s*- \[ \] //' \
      | head -20 \
      || true
  fi
}

count_open_phases() {
  local file="$1"
  local cnt
  if has_structured_phases "$file"; then
    cnt=$(extract_structured_open_phases "$file" | wc -l | tr -d ' ')
  else
    cnt=$(awk '/^---$/{fm++; next} fm<2{next} /- \[ \]/{count++} END{print count+0}' "$file" 2>/dev/null || echo "0")
  fi
  echo "$cnt"
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

extract_structured_open_phases() {
  local file="$1"
  awk '
    function emit() {
      if (id != "" && (status == "pending" || status == "in_progress" || status == "blocked")) {
        print id " (" status ")"
      }
    }
    /^---$/ { fm++; if (fm == 2) exit; next }
    fm != 1 { next }
    /^phases:[[:space:]]*$/ { in_phases=1; next }
    in_phases && /^[A-Za-z_][A-Za-z0-9_-]*:/ {
      emit(); in_phases=0; id=""; status=""; next
    }
    !in_phases { next }
    /^- id:[[:space:]]*/ {
      emit()
      id=$0
      sub(/^- id:[[:space:]]*/, "", id)
      status=""
      next
    }
    /^  status:[[:space:]]*/ {
      status=$0
      sub(/^  status:[[:space:]]*/, "", status)
      sub(/[[:space:]]+#.*/, "", status)
      sub(/^[[:space:]]+/, "", status)
      sub(/[[:space:]]+$/, "", status)
      next
    }
    END { emit() }
  ' "$file" 2>/dev/null
}

# True when registry_status() answered with one of its "could not resolve" markers
# (no such row, status cell outside the vocabulary, no status column, no registry file,
# malformed number) instead of a real status.
registry_status_unresolved() {
  case "$1" in
    _not\ in\ registry_|_status\ unknown_|_column\ status\ not\ found*|_no\ file\ REGISTRY_|_invalid\ number\ WP*) return 0 ;;
  esac
  return 1
}

# Numbers of the inbox cards in the order the canary tries them: folder cards (WP-434)
# first, then flat legacy files, each group in sort order.
canary_card_numbers() {
  local card
  while IFS= read -r card; do
    basename "$(dirname "$card")" | grep -oE '[0-9]+' | head -1 || true
  done < <(find "$INBOX_DIR" -maxdepth 2 -path "*/WP-*/WP-*.md" 2>/dev/null | sort)
  while IFS= read -r card; do
    basename "$card" | grep -oE '^WP-[0-9]+' | grep -oE '[0-9]+' | head -1 || true
  done < <(find "$INBOX_DIR" -maxdepth 1 -name "WP-*.md" 2>/dev/null | sort)
}

# Choose the card the canary checks (issue #964). The first inbox card used to be taken
# whatever its status, so a user's own "❄️ frozen" failed `update.sh --check` (exit 5).
# Only a card whose registry row IS found but whose status is unknown ("_status unknown_")
# is passed over. Any other answer ends the search on that card: a recognised status, or a
# "cannot resolve" answer -- above all "_not in registry_" -- on which the canary then fails
# as before: skipping such cards would blind it to a row format the reader cannot parse
# (#717/#718; #954 A was caught exactly so). Every card unknown: the FIRST one is chosen
# and refused. Sets CANARY_PICK ("" when inbox holds no cards) and, for cards passed over
# before the pick, CANARY_SKIPPED_COUNT / CANARY_SKIPPED_LIST (first three, with status).
pick_canary_wp() {
  local num status first=""
  CANARY_PICK=""
  CANARY_SKIPPED_COUNT=0
  CANARY_SKIPPED_LIST=""
  while IFS= read -r num; do
    [[ -n "$num" ]] || continue
    [[ -n "$first" ]] || first="$num"
    status=$(registry_status "$num" 2>/dev/null || true)
    if [[ "$status" != "_status unknown_" ]]; then
      CANARY_PICK="$num"
      return 0
    fi
    CANARY_SKIPPED_COUNT=$((CANARY_SKIPPED_COUNT + 1))
    if [[ "$CANARY_SKIPPED_COUNT" -le 3 ]]; then
      CANARY_SKIPPED_LIST="${CANARY_SKIPPED_LIST:+${CANARY_SKIPPED_LIST}, }WP-${num} ${status}"
    fi
  done < <(canary_card_numbers)
  CANARY_PICK="$first"
  CANARY_SKIPPED_COUNT=0
  CANARY_SKIPPED_LIST=""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  # --force-sync can appear anywhere in argv; strip it before the existing
  # positional-arg logic (including --self-test) sees argv at all.
  local force_sync=false
  local positional=()
  local arg
  for arg in "$@"; do
    if [[ "$arg" == "--force-sync" ]]; then
      force_sync=true
    else
      positional+=("$arg")
    fi
  done
  set -- "${positional[@]}"

  if [[ $# -lt 1 ]]; then
    log_err "Usage: wp-sync-bundle.sh WP-N (or simply N) [--self-test] [--force-sync]"
    exit 1
  fi

  local input="$1"

  # Self-test / canary mode (diagnostic — see WP-294 Phase7; extended issue #718:
  # a canary that only checks file lookup passes even when the registry
  # itself is unreadable or the WP's status cell can't be resolved — exactly
  # the class of "plausible result instead of a loud failure" the issue
  # describes. An explicit WP-N argument makes this usable as an
  # update.sh --check canary against a known-good WP, not just a diagnostic.)
  if [[ "$input" == "--self-test" ]]; then
    echo "=== WP Sync Bundle Self-Test ==="
    echo "IWE_WORKSPACE: $IWE_WORKSPACE"
    echo "GOV_REPO: $GOV_REPO"
    echo "STRATEGY_DIR: $STRATEGY_DIR"
    if [[ -f "$REGISTRY_FILE" ]]; then
      echo "REGISTRY_FILE: OK"
    else
      echo "REGISTRY_FILE: MISSING"
      exit 1
    fi

    local test_num=""
    if [[ $# -ge 2 && -n "${2:-}" ]]; then
      # The one reader of WP numbers (issue #954); a refusal is handled here, because under
      # `set -e` a failing assignment would end the script without a word.
      if ! test_num=$(wp_num_normalize "$2"); then
        log_err "Invalid format canary WP: '$2'. Expected WP-N or N."
        exit 2
      fi
    fi
    # No explicit WP given — find a real, resolvable WP for the canary.
    # WP-434: canonical folder cards win over legacy flat files; closed WPs
    # (archived/done) are avoided because the canary should test the active
    # governance contour, not a stale baseline (issue #861). The card is the first one that
    # is not passed over: only a card whose registry row exists but whose status is unknown
    # (a user's own "❄️") is skipped; any other unresolved answer stops the search and
    # fails the canary (issue #964, see pick_canary_wp).
    if [[ -z "$test_num" && -d "$INBOX_DIR" ]]; then
      pick_canary_wp
      test_num="$CANARY_PICK"
      if [[ "$CANARY_SKIPPED_COUNT" -gt 0 ]]; then
        echo "Canary: cards skipped due to unrecognized status: ${CANARY_SKIPPED_COUNT} (${CANARY_SKIPPED_LIST}); checking WP-${test_num}"
      fi
    fi
    if [[ -z "$test_num" && -f "$REGISTRY_FILE" ]]; then
      local reg_num seen=""
      while IFS= read -r reg_num; do
        reg_num=$(echo "$reg_num" | grep -oE '[0-9]+' || true)
        [[ -z "$reg_num" ]] && continue
        [[ "$seen" == *" ${reg_num} "* ]] && continue
        seen="${seen} ${reg_num} "
        local candidate_file candidate_status
        candidate_file=$(find_wp_file "$reg_num")
        [[ -z "$candidate_file" ]] && continue
        candidate_status=$(registry_status "$reg_num")
        # Prefer active WPs; archived/closed/done are acceptable only as a last
        # resort (handled below after the loop).
        if [[ "$candidate_status" == "🔄 in_progress"* || "$candidate_status" == "⏳ pending"* ]]; then
          test_num="$reg_num"
          break
        fi
      done <<< "$(grep -oE 'WP-[0-9]+' "$REGISTRY_FILE" 2>/dev/null || true)"
      # Last resort: any resolvable WP, even archived, so the file-lookup part
      # of the canary still runs on a bare installation.
      if [[ -z "$test_num" ]]; then
        reg_num=$(grep -oE 'WP-[0-9]+' "$REGISTRY_FILE" 2>/dev/null | head -1 | grep -oE '[0-9]+' || true)
        if [[ -n "$reg_num" ]] && [[ -n "$(find_wp_file "$reg_num")" ]]; then
          test_num="$reg_num"
        fi
      fi
    fi
    if [[ -z "$test_num" ]]; then
      echo "WP lookup: SKIP (no WP files found in inbox or registry)"
      exit 0
    fi

    local test_file
    test_file=$(find_wp_file "$test_num")
    if [[ -n "$test_file" ]]; then
      echo "WP-${test_num} lookup: OK ($test_file)"
    else
      echo "WP-${test_num} lookup: FAIL"
      exit 1
    fi

    # registry_status() is the part update.sh's silent-drift class of bug
    # (issue #718) actually cares about — a WP file can exist while the
    # registry row it's supposed to have is empty, stale, or unparseable.
    local status
    status=$(registry_status "$test_num")
    echo "WP-${test_num} registry_status: $status"
    if registry_status_unresolved "$status"; then
      echo "Canary FAILED: registry status unresolved for WP-${test_num}: $status" >&2
      exit 1
    fi
    exit 0
  fi

  # The one reader of WP numbers (issue #954): 44, 044, WP-44, WP-044, wp-044 and WP-00044
  # all mean 44 and give one bundle. A refusal is handled here, because under `set -e` a
  # failing assignment would end the script without a word.
  local wp_num
  if ! wp_num=$(wp_num_normalize "$input"); then
    log_err "Invalid format: '$input'. Expected WP-N or N."
    exit 1
  fi

  log_sync "$wp_num" "START" ""

  # WP-561 Phase20: classify STRATEGY_DIR against its own origin before reading
  # anything from it — a shared checkout under 20+ concurrent sessions is
  # routinely behind, and every consumer of this bundle (protocol-open.md,
  # wp-sync-actualizer, the nightly batch/secretary runners) needs to know
  # that up front, not discover it later as an unexplained false "0 drift".
  if declare -F check_git_sync_status >/dev/null 2>&1; then
    check_git_sync_status "$STRATEGY_DIR" "" "$GIT_SYNC_TIMEOUT"
  else
    GIT_SYNC_STATUS="checker_unavailable"
    GIT_SYNC_DETAIL="reason=library_missing"
    GIT_SYNC_REMOTE_OID=""
    GIT_SYNC_HEAD_OID=""
  fi
  local git_sync_blocking=false git_sync_degraded=false
  case "$GIT_SYNC_STATUS" in
    STALE|DIVERGED|fetch_failed) git_sync_blocking=true ;;
    # Portability: a template install without scripts/lib/git-sync-status.sh
    # cannot be checked at all -- warn instead of blocking the whole gate. Any
    # other checker_unavailable (broken integration) stays fail-closed.
    checker_unavailable)
      if [[ "$GIT_SYNC_DETAIL" == "reason=library_missing" ]]; then
        git_sync_degraded=true
      else
        git_sync_blocking=true
      fi
      ;;
  esac
  local git_sync_checked_at
  git_sync_checked_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # WP-561 Phase24: STALE/DIVERGED working copy + provably fresh remote-tracking
  # ref -> read the cards from a snapshot of that ONE origin commit and stop
  # blocking. fetch_failed/lagging ref/broken checker stay fail-closed
  # (exit 3). --force-sync keeps its old meaning: read the working copy
  # regardless of the status, and say so in CARD_SOURCE.
  if [[ "$git_sync_blocking" == "true" && "$force_sync" != "true" ]]; then
    case "$GIT_SYNC_STATUS" in
      STALE|DIVERGED)
        if materialize_origin_tree "$STRATEGY_DIR" "${GIT_SYNC_REMOTE_OID:-}"; then
          CARD_ROOT="$ORIGIN_WS/$GOV_REPO"
          INBOX_DIR="$CARD_ROOT/inbox"
          ARCHIVE_DIR="$CARD_ROOT/archive/wp-contexts"
          REGISTRY_FILE="$CARD_ROOT/docs/WP-REGISTRY.md"
          GIT_LOG_REV="$GIT_SYNC_REMOTE_OID"
          CARD_SOURCE="origin-pinned"
          git_sync_blocking=false
        fi
        ;;
    esac
  elif [[ "$git_sync_blocking" == "true" && "$force_sync" == "true" ]]; then
    CARD_SOURCE="worktree-forced"
  fi

  echo "GIT_SYNC_STATUS: ${GIT_SYNC_STATUS}"
  echo "GIT_SYNC_DETAIL: ${GIT_SYNC_DETAIL} remote=${GIT_SYNC_REMOTE_OID:0:10} head=${GIT_SYNC_HEAD_OID:0:10} checked_at=${git_sync_checked_at}"
  if [[ "$force_sync" == "true" ]]; then
    echo "GIT_SYNC_OVERRIDE: true"
  fi
  if [[ "$CARD_SOURCE" == "origin-pinned" ]]; then
    echo "CARD_SOURCE: origin-pinned oid=${GIT_SYNC_REMOTE_OID} behind=${GIT_SYNC_BEHIND:-?} ahead=${GIT_SYNC_AHEAD:-?}"
  else
    echo "CARD_SOURCE: ${CARD_SOURCE}"
  fi
  if [[ "$git_sync_degraded" == "true" ]]; then
    echo "GIT_SYNC_GATE: degraded (checker_unavailable, not blocking)"
    echo "[GIT-SYNC] WARNING: scripts/lib/git-sync-status.sh not found — sync state ${STRATEGY_DIR} with origin not verified, Sync Gate skipped (exit 0)." >&2
  fi
  if [[ "$CARD_SOURCE" == "origin-pinned" ]]; then
    {
      echo "[GIT-SYNC] WARNING: cards read from origin/main@${GIT_SYNC_REMOTE_OID:0:12} (up to date)."
      echo "[GIT-SYNC] Working copy ${STRATEGY_DIR} is behind by ${GIT_SYNC_BEHIND:-?} commits (${GIT_SYNC_STATUS}) — ALL files in it are potentially stale, not only this card."
      echo "[GIT-SYNC] Any writes — only via isolated copy + wp-reopen-gate actualize. Reading other files in the working copy — at your own risk of stale context."
    } >&2
  elif [[ "$git_sync_blocking" == "true" || "$force_sync" == "true" ]]; then
    {
      echo "[GIT-SYNC] working copy ${STRATEGY_DIR}: ${GIT_SYNC_STATUS} (${GIT_SYNC_DETAIL})"
      if [[ "$force_sync" == "true" ]]; then
        echo "[GIT-SYNC] --force-sync passed — bundle continues, but the status above remains ${GIT_SYNC_STATUS}"
      else
        echo "[GIT-SYNC] Sync Gate blocked (exit 3): reading from origin not possible (remote-tracking ref is behind origin, network unavailable). Isolated session → retry on your own worktree. Canon → session-guard open --isolate, or --force-sync with an explicit message to the pilot."
      fi
    } >&2
  fi

  local wp_file
  wp_file=$(find_wp_file "$wp_num")

  if [[ -z "$wp_file" ]]; then
    log_err "WP-${wp_num}: file not found in inbox/ or archive/wp-contexts/ (source: ${CARD_SOURCE})"
    log_sync "$wp_num" "FAIL" "file_not_found card_source=${CARD_SOURCE}"
    cleanup_tmp
    exit 1
  fi

  # Exit 2: parsing error (frontmatter is not valid)
  if ! validate_frontmatter "$wp_file"; then
    log_sync "$wp_num" "FAIL" "parse_error card_source=${CARD_SOURCE}"
    cleanup_tmp
    exit 2
  fi

  local wp_path
  wp_path=$(wp_path_label "$wp_file")

  local status name spawned updated created last_session
  status=$(extract_fm_field "$wp_file" "status")
  name=$(extract_wp_display_name "$wp_file")
  spawned=$(extract_fm_field "$wp_file" "spawned")
  updated=$(extract_fm_field "$wp_file" "updated")
  # F19 (REVIEW-ARCHITECTURE.md, WP-503 Phase6.6 plan): cards without `updated:` in
  # frontmatter (created manually, not auto-touched) silently disabled drift-detector
  # №2 ("completion commits after ref_date") — the ref_date remained empty for
  # them, including WP-503. `created`/`last_session` extend the chain without changing
  # priority of already used fields (updated still-still first — the most recent
  # indicator of real card activity).
  created=$(extract_fm_field "$wp_file" "created")
  last_session=$(extract_fm_field "$wp_file" "last_session")

  [[ -z "$status" ]] && status="_not specified_"
  [[ -z "$name" ]] && name="_not specified_"
  [[ -z "$spawned" ]] && spawned="_not specified_"

  local open_phases_count
  open_phases_count=$(count_open_phases "$wp_file")

  # Collect related WPs
  local related_from_fm
  related_from_fm=$(extract_related_wps "$wp_file" | grep -oE '[0-9]+' || true)
  local related_from_blockers
  related_from_blockers=$(extract_blocker_wps "$wp_file" | grep -oE '[0-9]+' || true)
  local related_from_body
  related_from_body=$(grep_body_wps "$wp_file")

  # Merge, deduplicate, exclude self, limit to 30. Self is excluded by NUMBER (issue #954):
  # the card says "WP-044" in its heading while the caller typed 44 (or the other way
  # round), and a string compare listed the WP as related to itself.
  local all_related
  all_related=$(
    { echo "$related_from_fm"; echo "$related_from_blockers"; echo "$related_from_body"; } \
    | grep -E '^[0-9]+$' \
    | awk -v self="$wp_num" '$0 + 0 != self + 0' \
    | sort -nu \
    | head -30 \
    || true
  )

  # Drift accumulator (use temp file for bash 3.2 compatibility)
  DRIFT_FILE=$(mktemp /tmp/wp-sync-drift.XXXXXX)
  local drift_file="$DRIFT_FILE"
  trap cleanup_tmp EXIT

  local ref_date="${updated:-${last_session:-${spawned:-$created}}}"

  # WP-561 C: dependency snapshot, recorded by the previous close close (see.
  # extract_handoff_snapshot() above) — read once, compared inside
  # loop over related WPs below.
  local handoff_snapshot
  handoff_snapshot=$(extract_handoff_snapshot "$wp_file")

  # ---------------------------------------------------------------------------
  # Output header
  # ---------------------------------------------------------------------------
  echo "# WP Sync Bundle for WP-${wp_num}"
  echo ""
  echo "## Current WP"
  echo "- File: \`${wp_path}\`"
  echo "- Name: ${name}"
  echo "- Status: ${status}"
  echo "- Spawned: ${spawned}"
  [[ -n "${updated:-}" ]] && echo "- Updated: ${updated}"
  echo "- Open phases: ${open_phases_count}"
  echo ""

  echo "## Git-sync working copy"
  echo "- Status: ${GIT_SYNC_STATUS} (${GIT_SYNC_DETAIL})"
  if [[ "$CARD_SOURCE" == "origin-pinned" ]]; then
    echo "- Card source: origin-pinned oid=${GIT_SYNC_REMOTE_OID} — working copy is behind by ${GIT_SYNC_BEHIND:-?} commits and is NOT the source of truth (ALL its files are potentially outdated); cards below were read from origin."
  else
    echo "- Card source: ${CARD_SOURCE}"
  fi
  if [[ "$git_sync_blocking" == "true" && "$force_sync" != "true" ]]; then
    echo "- ⚠️ Bundle Bundle assembled from an unsynced/unverified copy — the remaining content below may be outdated."
  elif [[ "$force_sync" == "true" ]]; then
    echo "- Override via --force-sync: data below was read despite the status above."
  fi
  echo ""

  if [[ "$open_phases_count" -gt 0 ]]; then
    echo "## Open phases"
    local phases_list
    phases_list=$(extract_open_phases "$wp_file")
    if [[ -n "$phases_list" ]]; then
      while IFS= read -r phase_line; do
        [[ -n "$phase_line" ]] && echo "- ${phase_line}"
      done <<< "$phases_list"
    fi
    echo ""
  fi

  # ---------------------------------------------------------------------------
  # Related WPs
  # ---------------------------------------------------------------------------
  echo "## Related WPs"
  echo ""

  if [[ -z "$all_related" ]]; then
    echo "_No related WPs found_"
    echo ""
  else
    while IFS= read -r rnum; do
      [[ -z "$rnum" ]] && continue

      # Get relation type
      local rtype
      rtype=$(get_rel_type "$wp_file" "$rnum")

      local rfile
      rfile=$(find_wp_file "$rnum")

      echo "### WP-${rnum} (${rtype})"

      local reg_status
      reg_status=$(registry_status "$rnum")

      if [[ -z "$rfile" ]]; then
        echo "- File: _not found_"
        echo "- Status (frontmatter): _n/a_"
        echo "- Status (REGISTRY): ${reg_status}"
        echo "- Recent commits (${GIT_LOG_DAYS}d): _file not found, skip_"
      else
        local rpath rstatus rname
        rpath=$(wp_path_label "$rfile")
        rstatus=$(extract_fm_field "$rfile" "status")
        rname=$(extract_wp_display_name "$rfile")
        [[ -z "$rstatus" ]] && rstatus="_not specified_"
        [[ -z "$rname" ]] && rname="_not specified_"

        echo "- File: \`${rpath}\`"
        echo "- Name: ${rname}"
        echo "- Status (frontmatter): ${rstatus}"
        echo "- Status (REGISTRY): ${reg_status}"

        echo "- Recent commits (${GIT_LOG_DAYS}d):"
        local commits
        commits=$(git_log_for_file "$rfile")
        while IFS= read -r cline; do
          [[ -n "$cline" ]] && echo "  - ${cline}"
        done <<< "$commits"

        # Drift: related is closed, but open phase references it
        local is_closed=0
        # "↗️ merged" (issue #964) is as terminal as ✅: before the resolver knew ↗️ a
        # struck-through merged row came back as "~~done~~ (struck through)" and matched here.
        if echo "$reg_status" | grep -qiE '✅|done|closed|merged|~~'; then
          is_closed=1
        fi
        if echo "$rstatus" | grep -qiE '^(closed|done|complete)$'; then
          is_closed=1
        fi

        if [[ $is_closed -eq 1 && "$open_phases_count" -gt 0 ]]; then
          local open_phase_with_ref
          open_phase_with_ref=$(
            awk '/^---$/{fm++; next} fm<2{next} /- \[ \]/{print}' "$wp_file" 2>/dev/null \
            | grep -E "WP-${rnum}([^0-9]|$)" || true
          )
          if [[ -n "$open_phase_with_ref" ]]; then
            echo "DRIFT: WP-${rnum} closed (${reg_status}), but the current WP has an open phase referencing it" >> "$drift_file"
          fi
        fi

        # Drift: significant commits after ref_date
        if [[ -n "$ref_date" ]] && echo "$ref_date" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
          local relpath_r
          relpath_r=$(card_relpath "$rfile")
          local sig_commits
          sig_commits=$(
            cd "$STRATEGY_DIR" 2>/dev/null && \
            git log --oneline --after="${ref_date}" ${GIT_LOG_REV:+"$GIT_LOG_REV"} -- "$relpath_r" 2>/dev/null \
            | grep -iE '\b(LIVE|deployed|merged|DROPPED|done|complete|closed)\b' \
            | head -1 \
            || true
          )
          if [[ -n "$sig_commits" ]]; then
            echo "DRIFT: WP-${rnum} has a commit after ${ref_date} with a completion keyword: \"${sig_commits}\"" >> "$drift_file"
          fi
        fi

        # Drift: stale_handoff (WP-561 C) — previous close recorded a snapshot
        # {status, phase_digest} for this WP-N in depends_on; if now
        # (using the same script wp-phase-digest.sh, that wrote the snapshot) digest
        # or status differ — plan "what_next" may have become stale. Warn, not gate:
        # a divergence often means "the world simply changed", not an agent error.
        if [[ -n "$handoff_snapshot" ]] && [[ -x "$PHASE_DIGEST_SCRIPT" ]]; then
          local snap_line
          snap_line=$(printf '%s\n' "$handoff_snapshot" | grep "^WP-${rnum}|" || true)
          if [[ -n "$snap_line" ]]; then
            local snap_status snap_digest current_digest_out current_status current_digest
            local digest_rc=0 digest_template digest_line digest_missing
            snap_status=$(echo "$snap_line" | cut -d'|' -f2)
            snap_digest=$(echo "$snap_line" | cut -d'|' -f3)
            # issue #954: the helper's exit code is decided here, not swallowed. It used to be
            # hidden (`|| true`, stderr to /dev/null) and the `grep` on its empty output then
            # ended the bundle with a bare exit 1 under `set -e` -- for exit 4 (no wp-num.sh:
            # an installation error) that is "WP not found" to memory/protocol-open.md. Now 4
            # stays 4 with the helper's own message; any other failure still ends the bundle
            # with exit 1, as it always did, but says what failed. IWE_TEMPLATE points the
            # helper at the library THIS bundle loaded (what update.sh passes for the canary),
            # so a helper reached through a link into another tree finds it too.
            digest_template="${IWE_TEMPLATE:-${WP_NUM_LIB%/scripts/lib/wp-num.sh}}"
            if [[ -n "$ORIGIN_WS" ]]; then
              current_digest_out=$(IWE_WORKSPACE="$ORIGIN_WS" IWE_GOVERNANCE_REPO="$GOV_REPO" IWE_TEMPLATE="$digest_template" bash "$PHASE_DIGEST_SCRIPT" "$rnum" 2>&1) || digest_rc=$?
            else
              current_digest_out=$(IWE_GOVERNANCE_REPO="$GOV_REPO" IWE_TEMPLATE="$digest_template" bash "$PHASE_DIGEST_SCRIPT" "$rnum" 2>&1) || digest_rc=$?
            fi
            if [[ "$digest_rc" -ne 0 ]]; then
              printf '%s\n' "$current_digest_out" >&2
              log_sync "$wp_num" "FAIL" "phase_digest_exit=${digest_rc} card_source=${CARD_SOURCE}"
              cleanup_tmp
              if [[ "$digest_rc" -eq 4 ]]; then
                log_err "wp-phase-digest.sh (WP-${rnum}) exited with code 4: library not found wp-num.sh — installation error, this is not «WP not found». Update the template: bash update.sh"
                exit 4
              fi
              log_err "wp-phase-digest.sh (WP-${rnum}) exited with code ${digest_rc}: dependency snapshot comparison is not possible, bundle aborted (exit 1)"
              exit 1
            fi
            # The helper's contract: on exit 0 it prints a status= and a phase_digest= line, neither
            # ever empty (it writes "unknown" / "nodigest" for none). An answer without either is not
            # "nothing to compare": the comparison would be skipped in silence and the bundle would
            # stand for "no drift" with nothing checked. It is a broken helper: exit 1, what a
            # missing line always ended the bundle with on main, but now with a message. A read
            # loop parses the answer, not grep: grep on a missing line ends the script under
            # `set -e` + pipefail without a word.
            current_status=""
            current_digest=""
            while IFS= read -r digest_line; do
              case "$digest_line" in
                status=*) [[ -n "$current_status" ]] || current_status="${digest_line#status=}" ;;
                phase_digest=*) [[ -n "$current_digest" ]] || current_digest="${digest_line#phase_digest=}" ;;
              esac
            done <<< "$current_digest_out"
            if [[ -z "$current_status" || -z "$current_digest" ]]; then
              digest_missing=""
              [[ -n "$current_status" ]] || digest_missing="status="
              [[ -n "$current_digest" ]] || digest_missing="${digest_missing:+${digest_missing}, }phase_digest="
              [[ -z "$current_digest_out" ]] || printf '%s\n' "$current_digest_out" >&2
              log_sync "$wp_num" "FAIL" "phase_digest_contract missing=${digest_missing} card_source=${CARD_SOURCE}"
              cleanup_tmp
              log_err "wp-phase-digest.sh (WP-${rnum}) exited with code 0, but did not output ${digest_missing}: helper contract violated helper, dependency snapshot comparison is not possible, bundle aborted (exit 1)"
              exit 1
            fi
            if [[ "$current_status" != "$snap_status" ]] || [[ "$current_digest" != "$snap_digest" ]]; then
              echo "DRIFT: stale_handoff — snapshot WP-${rnum} at the time of the previous close (status=${snap_status}, digest=${snap_digest}) diverged from the current (status=${current_status}, digest=${current_digest}); plan \"what_next\" should be reviewed" >> "$drift_file"
            fi
          fi
        fi
      fi
      echo ""
    done <<< "$all_related"
  fi

  # ---------------------------------------------------------------------------
  # Drift summary
  # ---------------------------------------------------------------------------
  local drift_count=0
  if [[ -s "$drift_file" ]]; then
    drift_count=$(wc -l < "$drift_file" | tr -d ' ')
  fi

  echo "## Drift-signals"
  if [[ $drift_count -eq 0 ]]; then
    echo "- Count-: 0"
    echo "- List: _none_"
  else
    echo "- Count-: ${drift_count}"
    echo "- List:"
    while IFS= read -r sig; do
      [[ -n "$sig" ]] && echo "  - ${sig}"
    done < "$drift_file"
  fi
  echo ""

  # ---------------------------------------------------------------------------
  # Recommendation
  # ---------------------------------------------------------------------------
  local related_count=0
  if [[ -n "$all_related" ]]; then
    related_count=$(echo "$all_related" | grep -cE '^[0-9]+$' || true)
  fi

  echo "## Recommendation (for the main agent)"
  if [[ "$related_count" -le 1 && $drift_count -eq 0 ]]; then
    echo "- **Simple case** (${related_count} related, no drift) → main agent applies diff itself"
  else
    echo "- **Non-trivial case** (${related_count} related, ${drift_count} drift-signals) → Task tool → sub-agent wp-sync-actualizer (Sonnet)"
    if [[ $drift_count -gt 0 ]]; then
      echo "- ⚠️ There are drift-signals — require manual review before applying"
    fi
  fi

  if [[ "$git_sync_blocking" == "true" && "$force_sync" != "true" ]]; then
    log_sync "$wp_num" "BLOCKED" "git_sync=${GIT_SYNC_STATUS} related=${related_count} drift=${drift_count} card_source=${CARD_SOURCE}"
    exit 3
  fi

  log_sync "$wp_num" "SUCCESS" "related=${related_count} drift=${drift_count} git_sync=${GIT_SYNC_STATUS} card_source=${CARD_SOURCE}"
}

main "$@"
