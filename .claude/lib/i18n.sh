#!/bin/bash
# i18n.sh — language catalogs for shell code (WP-610 F9 step 2).
# Source this file; it defines functions only and changes no shell options.
#
# Catalogs: <dir>/<lang>.json, a flat JSON object "key" -> "string".
# <dir> is IWE_LOCALE_DIR when set, else locale/ next to this file.
#
# Language: IWE_LANG when non-empty (must have a catalog); else the only
# catalog present; else ru when ru.json is present; anything else is an error.
#
# Key spaces: msg.* agent.* format.* are templates with positional %s and %%;
# recognition.* are raw extended regular expressions (grep -E), never formatted,
# matched against the union of all shipped catalogs.
#
# Every function returns 0 on success; a catalog or usage failure prints a
# diagnostic to stderr and returns I18N_ERROR (3), distinct from a plain
# "no match" (1) of i18n_match.

I18N_ERROR=3
_I18N_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_i18n_fail() {
  printf 'i18n: %s\n' "$*" >&2
  return "$I18N_ERROR"
}

i18n_dir() {
  printf '%s\n' "${IWE_LOCALE_DIR:-$_I18N_LIB_DIR/locale}"
}

# i18n_catalogs — the catalog files present, one path per line, sorted.
i18n_catalogs() {
  local dir found=0 f
  dir=$(i18n_dir)
  for f in "$dir"/*.json; do
    [ -f "$f" ] || continue
    printf '%s\n' "$f"
    found=1
  done
  [ "$found" = 1 ] || _i18n_fail "no catalogs in $dir"
}

i18n_lang() {
  local dir catalogs count
  dir=$(i18n_dir)
  if [ -n "${IWE_LANG:-}" ]; then
    case "$IWE_LANG" in *[!A-Za-z_-]*) _i18n_fail "IWE_LANG=$IWE_LANG is not a language code"; return ;; esac
    [ -f "$dir/$IWE_LANG.json" ] || { _i18n_fail "IWE_LANG=$IWE_LANG has no catalog in $dir"; return; }
    printf '%s\n' "$IWE_LANG"
    return 0
  fi
  catalogs=$(i18n_catalogs) || return
  count=$(printf '%s\n' "$catalogs" | wc -l | tr -d ' ')
  if [ "$count" = 1 ]; then
    basename "$catalogs" .json
  elif [ -f "$dir/ru.json" ]; then
    printf 'ru\n'
  else
    _i18n_fail "several catalogs in $dir and none is ru; set IWE_LANG"
  fi
}

# _i18n_raw <catalog> <key> — the string value, trailing newlines kept.
_i18n_raw() {
  local value
  value=$(jq -j --arg k "$2" '
    if type != "object" then error("catalog is not a JSON object")
    elif has($k) | not then error("missing key " + $k)
    elif .[$k] | type != "string" then error("key " + $k + " is not a string")
    else .[$k] end' "$1" && printf x) || { _i18n_fail "cannot read $2 from $1"; return; }
  printf '%s' "${value%x}"
}

# i18n_msg <key> [args...] — the formatted string, no newline added.
i18n_msg() {
  [ $# -ge 1 ] || { _i18n_fail "i18n_msg: key required"; return; }
  local key=$1 lang template out="" head rest
  shift
  case "$key" in recognition.*) _i18n_fail "$key is a pattern, use i18n_match"; return ;; esac
  lang=$(i18n_lang) || return
  template=$(_i18n_raw "$(i18n_dir)/$lang.json" "$key" && printf x) || return
  rest=${template%x}
  while :; do
    case "$rest" in
      *%*) ;;
      *) out=$out$rest; break ;;
    esac
    head=${rest%%\%*}
    rest=${rest#*\%}
    out=$out$head
    case "$rest" in
      %*) out=$out%; rest=${rest#%} ;;
      s*)
        [ $# -ge 1 ] || { _i18n_fail "$key: fewer arguments than %s"; return; }
        out=$out$1; shift; rest=${rest#s} ;;
      *) _i18n_fail "$key: only %s and %% are allowed"; return ;;
    esac
  done
  [ $# -eq 0 ] || { _i18n_fail "$key: more arguments than %s"; return; }
  printf '%s' "$out"
}

# i18n_pattern <recognition.key> — union of the key over all catalogs.
i18n_pattern() {
  local key=${1:-} catalogs f part union=""
  case "$key" in recognition.*) ;; *) _i18n_fail "i18n_pattern: $key is not recognition.*"; return ;; esac
  catalogs=$(i18n_catalogs) || return
  while IFS= read -r f; do
    part=$(_i18n_raw "$f" "$key") || return
    [ -n "$part" ] || { _i18n_fail "$key is empty in $f"; return; }
    union="${union:+$union|}($part)"
  done <<EOF
$catalogs
EOF
  printf '%s' "$union"
}

# i18n_match <recognition.key> <text> — 0 match, 1 no match, 3 error.
i18n_match() {
  local pattern rc
  pattern=$(i18n_pattern "${1:-}") || return
  # A here-string, not a pipe: under pipefail an early match would surface
  # printf's SIGPIPE as an error.
  grep -qE -- "$pattern" <<<"${2-}"
  rc=$?
  case $rc in
    0|1) return $rc ;;
    *) _i18n_fail "grep -E failed ($rc) on ${1:-}" ;;
  esac
}
