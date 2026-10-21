#!/usr/bin/env bash
# wp-num.sh -- the one reader of WP (work product) numbers for template scripts (issue #954).
#
# Why it exists: a WP number is written in several shapes. create-wp.sh names the card
# folder with a zero-padded number (inbox/WP-044/WP-044.md) but writes the registry cell
# and the frontmatter `wp:` as the bare number; hand-kept registries carry `WP-`/`wp-`
# prefixes, leading zeros and strikethrough; older cards still live in unpadded folders
# (inbox/WP-44/WP-44.md). Every script that rebuilt "the" number its own way broke at one
# of these seams (#715, #871, #954). This file is the single place that knows the shapes.
#
# Usage: source it, do not execute it. Sourcing defines functions only (no output, no
# `set` options, no environment changes), so it is safe under `set -euo pipefail` and in
# bash 3.2 (macOS). Callers locate it from their OWN file location, never from the data
# root (IWE_WORKSPACE / IWE_ROOT / STRATEGY_DIR), which tests and fixtures legitimately
# point somewhere else -- see the lookup block at the top of wp-sync-bundle.sh.
#
#   . "$code_dir/lib/wp-num.sh"
#   n=$(wp_num_normalize "WP-044")          # -> 44    (rc 1, no output, for non-numbers)
#   p=$(wp_num_padded 44)                    # -> 044
#   re=$(wp_num_registry_cell_regex 44)      # regex of the registry "#" cell (ERE and Python re)
#   f=$(wp_num_card_path "$inbox" 44)        # -> $inbox/WP-044/WP-044.md  (the path that exists)
#   wp_num_flat_cards "$archive" 44          # -> flat WP-044*.md / WP-44*.md files, one per line
#   f=$(wp_num_find_card "$inbox" "$archive" 44)   # whole card lookup, see below
#
# Every function returns 1 (and prints nothing) when it cannot answer; callers running
# under `set -e` must guard the call (`|| true`) where "not found" is an ordinary outcome.

# wp_num_normalize <raw> -> bare decimal integer on stdout.
# Accepts 44, 044, WP-44, WP-044, wp-044, ~~WP-044~~, **WP-044** (surrounding spaces ok).
# Rejects empty input, non-numbers, trailing junk (13*, WP-44-slug), more than nine
# significant digits and input longer than 64 characters (no real spelling comes close;
# without the cap a pathological argument kept the string operations below busy for seconds).
wp_num_normalize() {
  local raw="${1-}" prev="" digits
  [ "${#raw}" -le 64 ] || return 1
  raw="${raw#"${raw%%[![:space:]]*}"}"
  raw="${raw%"${raw##*[![:space:]]}"}"
  # Peel registry-cell decoration: ~~...~~ and **...** in any nesting.
  while [ "$raw" != "$prev" ]; do
    prev="$raw"
    case "$raw" in
      '~~'*'~~') raw="${raw#'~~'}"; raw="${raw%'~~'}" ;;
      '**'*'**') raw="${raw#'**'}"; raw="${raw%'**'}" ;;
    esac
  done
  case "$raw" in
    [Ww][Pp]-*) raw="${raw#???}" ;;
  esac
  case "$raw" in
    ''|*[!0-9]*) return 1 ;;
  esac
  digits="${raw#"${raw%%[!0]*}"}"
  [ -n "$digits" ] || digits="0"
  [ "${#digits}" -le 9 ] || return 1
  printf '%s\n' "$digits"
}

# wp_num_padded <raw> -> the three-digit spelling used by card folders (044).
wp_num_padded() {
  local n
  n=$(wp_num_normalize "${1-}") || return 1
  printf '%03d\n' "$n"
}

# wp_num_registry_cell_regex <raw> -> regex for the content of a registry row's first
# ("#") cell: optional strikethrough/bold, optional `WP-`/`wp-`, leading zeros, the number,
# then an optional marker glued to it (`13★`, #716). A digit after the number is never
# allowed, so 44 matches neither 440 nor 0440. Only constructs that mean the same in ERE
# (grep -E, [[ =~ ]]) and in Python `re` are used, so shell and Python callers share one
# pattern; each caller adds its own `^\|[[:space:]]*` ... `[[:space:]]*\|` (or `\s`) around it.
wp_num_registry_cell_regex() {
  local n
  n=$(wp_num_normalize "${1-}") || return 1
  printf '%s\n' "(~~)?(\\*\\*)?(WP-|wp-)?0*${n}(\\*\\*)?(~~)?[^0-9|]*"
}

# wp_num_card_path <dir> <raw> -> path of the folder card WP-<N>/WP-<N>.md inside <dir>
# (WP-434 convention). The zero-padded spelling is canonical (what create-wp.sh writes) and
# wins; the unpadded one is the legacy spelling still found in older installs. The path
# that actually exists is returned, never one rebuilt from the number.
wp_num_card_path() {
  local dir="${1-}" n pad name
  n=$(wp_num_normalize "${2-}") || return 1
  pad=$(printf '%03d' "$n")
  for name in "WP-$pad" "WP-$n"; do
    if [ -f "$dir/$name/$name.md" ]; then
      printf '%s\n' "$dir/$name/$name.md"
      return 0
    fi
  done
  return 1
}

# _wp_num_spellings <n> -> the distinct spellings of <n>, padded first, one per line.
_wp_num_spellings() {
  local pad
  pad=$(printf '%03d' "$1")
  printf '%s\n' "$pad"
  [ "$pad" = "$1" ] || printf '%s\n' "$1"
}

# _wp_num_grep_card <dir> <n> -> first file under <dir> whose frontmatter says `wp: <n>`
# (zeros tolerated). Last-resort lookup: it cannot tell a card from a note that carries the
# same field, so it only runs after every canonical path missed.
_wp_num_grep_card() {
  local found
  found=$(grep -rl "^wp: 0*${2}$" "$1" 2>/dev/null | head -1 || true)
  [ -n "$found" ] || return 1
  printf '%s\n' "$found"
}

# wp_num_flat_cards <dir> <raw> -> flat legacy files WP-<N>.md and WP-<N>-<slug>.md in <dir>
# (the zero-padded spelling first in sort order), one per line. The hyphen is the ID
# boundary: WP-46-*.md never matches WP-469-*. Used for contexts and cards written flat
# (close-wp.sh writes archive/wp-contexts/WP-044-<slug>.md).
wp_num_flat_cards() {
  local dir="${1-}" n spelling
  n=$(wp_num_normalize "${2-}") || return 1
  while IFS= read -r spelling; do
    find "$dir" -maxdepth 1 \( -name "WP-${spelling}.md" -o -name "WP-${spelling}-*.md" \) 2>/dev/null
  done < <(_wp_num_spellings "$n") | sort -u
}

# _wp_num_inbox_flat <dir> <n> -> a flat legacy card in inbox: the exact WP-<N>.md first;
# otherwise, among WP-<N>-<slug>.md, the file that says `wp: <N>`, else the shortest name.
_wp_num_inbox_flat() {
  local dir="$1" n="$2" spelling cand candidates
  while IFS= read -r spelling; do
    if [ -f "$dir/WP-${spelling}.md" ]; then
      printf '%s\n' "$dir/WP-${spelling}.md"
      return 0
    fi
  done < <(_wp_num_spellings "$n")
  candidates=$(
    while IFS= read -r spelling; do
      find "$dir" -maxdepth 1 -name "WP-${spelling}-*.md" 2>/dev/null
    done < <(_wp_num_spellings "$n") | sort -u | head -5
  )
  [ -n "$candidates" ] || return 1
  while IFS= read -r cand; do
    if [ -f "$cand" ] && grep -q "^wp: 0*${n}$" "$cand" 2>/dev/null; then
      printf '%s\n' "$cand"
      return 0
    fi
  done <<< "$candidates"
  printf '%s\n' "$candidates" | awk '{print length, $0}' | sort -n | head -1 | cut -d' ' -f2-
}

# wp_num_find_card <inbox_dir> <archive_dir> <raw> -> path of the WP's card file.
# Order (the first hit wins; either directory may be missing):
#   1. inbox: folder card WP-<N>/WP-<N>.md (zero-padded, then legacy unpadded), then a flat
#      WP-<N>.md / WP-<N>-<slug>.md in either spelling
#   2. archive: folder card, then a flat WP-<N>.md / WP-<N>-<slug>.md
#   3. last resort, inbox then archive: a file whose frontmatter says `wp: <N>`
# Inbox is the live contour and always outranks the archive (a legacy card still in inbox
# beats an archive stub of the same WP). The `wp:` grep goes last on purpose: it returns the
# first file that carries the field -- often a note about the WP, not its card (#954).
wp_num_find_card() {
  local inbox="${1-}" archive="${2-}" n found=""
  n=$(wp_num_normalize "${3-}") || return 1

  if [ -d "$inbox" ]; then
    found=$(wp_num_card_path "$inbox" "$n" || true)
    [ -n "$found" ] || found=$(_wp_num_inbox_flat "$inbox" "$n" || true)
  fi
  if [ -z "$found" ] && [ -d "$archive" ]; then
    found=$(wp_num_card_path "$archive" "$n" || true)
    [ -n "$found" ] || found=$(wp_num_flat_cards "$archive" "$n" | head -1 || true)
  fi
  if [ -z "$found" ] && [ -d "$inbox" ]; then
    found=$(_wp_num_grep_card "$inbox" "$n" || true)
  fi
  if [ -z "$found" ] && [ -d "$archive" ]; then
    found=$(_wp_num_grep_card "$archive" "$n" || true)
  fi

  [ -n "$found" ] || return 1
  printf '%s\n' "$found"
}
