#!/usr/bin/env bash
# routing: utility  deterministic=true
# check-platform-compat.sh — enforces docs/PLATFORM-COMPAT.md as a CI gate,
# not just a checklist someone has to remember to read.
#
# WP-5 Ubuntu-portability audit (2026-07-22): every concrete bug found (osascript
# with no notify-send fallback, launchctl with no command -v guard, bare shasum,
# bare stat -f) was a case the checklist ALREADY named — nothing enforced it, so
# it kept recurring. This is a heuristic, not a parser: for constructs that have
# a documented safe pattern (osascript, launchctl, date -v, sed -i '', stat -f),
# it checks the FILE also contains the guard/fallback token somewhere, not that
# the exact line is wrapped — false negatives are possible (guard elsewhere,
# unrelated use), false positives are the failure mode to watch for. For
# constructs with no safe runtime pattern at all (readlink -f, grep -P,
# mktemp -d -t), any occurrence fails — the checklist's own advice is "avoid".
#
# Использование: bash scripts/check-platform-compat.sh [DIR]
# Exit 0 = чисто. Exit 1 = найдены необёрнутые конструкции.

set -uo pipefail

# Resolved BEFORE the `cd "$ROOT"` below: if invoked as a relative path
# (e.g. `cd scripts && bash check-platform-compat.sh`, matching the usage
# comment above), `dirname "${BASH_SOURCE[0]}"` is "." — resolving it AFTER
# cd'ing to repo root would silently resolve to the wrong directory and
# break the self-exclusion below (found by review: self-matched with 3
# false positives when invoked this way).
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$ROOT" || exit 2

# guide-kit/ is a vendored byte-identical copy (WP-483) — its own upstream CI
# is responsible for its portability, not ours (mirrors the shellcheck job's
# exclusion for the same reason). This script's own file is excluded too — its
# doc-comments and pattern-string literals name every construct it checks for,
# which would otherwise flag itself.
FILES_SH=$(find . -path ./guide-kit -prune -o -path ./.git -prune -o -name "*.sh" -type f -print 2>/dev/null \
  | while read -r f; do [ "$(cd "$(dirname "$f")" && pwd)/$(basename "$f")" = "$SELF" ] || echo "$f"; done)
FILES_PY=$(find . -path ./guide-kit -prune -o -path ./.git -prune -o -name "*.py" -type f -print 2>/dev/null)

fail=0

# --- Guarded constructs: flag only if the file has the raw construct on a
# non-comment line WITHOUT the corresponding guard/fallback token anywhere
# in the same file. Comment lines are excluded so prose mentioning the tool
# name (e.g. explaining what a sourced helper does) doesn't self-trigger. ---
check_guarded() {
  local desc="$1" grep_pattern="$2" guard_pattern="$3" file
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    if grep -vE '^\s*#' "$file" 2>/dev/null | grep -qE "$grep_pattern" \
       && ! grep -qE "$guard_pattern" "$file" 2>/dev/null; then
      echo "FAIL: $file — $desc без guard/fallback"
      fail=1
    fi
  done <<< "$FILES_SH"
}

check_guarded "osascript" 'osascript' 'command -v osascript|which osascript|\|\| notify-send'
# Actual invocation only (launchctl list/load/unload/start/stop) — a bare
# mention of the word in a diagnostic/log string (e.g. "launchctl missing or
# skipped") isn't a call site that needs a guard.
check_guarded "launchctl" 'launchctl (list|load|unload|start|stop)' 'command -v launchctl|which launchctl|PLATFORM.*Darwin|uname -s.*Darwin'
check_guarded "date -v (BSD)" 'date -v-?[0-9\$]' 'date -d '
check_guarded "sed -i '' (BSD)" "sed -i ''" 'sed --version|sed_inplace'
# `date -r FILE` (mtime as date) is portable on both BSD and GNU date, so it
# counts as a valid fallback for `stat -f`/`stat -c` too, not just stat -c itself.
check_guarded "stat -f (BSD)" 'stat -f' 'stat -c|date -r '
# Issue #1108: four more GNU/Homebrew-only constructs with no polyfill found by
# two independent post-release audits — same "checklist already named it,
# nothing enforced it" pattern as the five checks above.
# `(^|[^-'"'"'])` excludes two shapes that read like an invocation but
# aren't one: a flag name ending in "-timeout" (curl's --connect-timeout/
# --max-time), and a single-quoted string a test feeds to something else as
# DATA — a fixture `command_text`, or a Python string inside a bash heredoc
# (`'timeout "$X"'`) — never actually run by the file that contains it.
check_guarded "timeout (GNU/Homebrew-only)" '(^|[^-'"'"'])\btimeout ["$0-9]' 'command -v timeout|which timeout|iwe_timeout'
check_guarded "sha256sum (GNU-only, no shasum/macOS fallback)" '\bsha256sum\b' 'command -v sha256sum|which sha256sum|shasum|iwe_sha256'
check_guarded "md5sum (GNU-only, no md5/macOS fallback)" '\bmd5sum\b' 'command -v md5sum|which md5sum|\bmd5\b|iwe_md5'
# fcntl.flock(...) (Python) is a different, already cross-platform call — the
# grep pattern requires a CLI flag ("flock -x"/"-n"/"-s") right after the
# word, which a Python method call never has, so it doesn't need excluding.
check_guarded "flock (util-linux, absent on stock macOS)" '\bflock -[a-zA-Z]' 'command -v flock|which flock'

# Python equivalent of the osascript guard (subprocess.run(["osascript"...)
while IFS= read -r file; do
  [ -n "$file" ] || continue
  if grep -vE '^\s*#' "$file" 2>/dev/null | grep -qE 'osascript' \
     && ! grep -qE 'shutil\.which\("osascript"\)|which\(.osascript' "$file" 2>/dev/null; then
    echo "FAIL: $file — osascript без guard (shutil.which)"
    fail=1
  fi
done <<< "$FILES_PY"

# Issue #1108: ${var,,}/${var^^} (bash 4+ case-conversion parameter expansion)
# is a "bad substitution" syntax error on bash 3.2 — stock macOS's /bin/bash,
# last GPLv2 release, no coreutils/Homebrew needed to hit this one. No safe
# runtime guard exists for it (unlike the constructs above): the fix is to
# not use it (portable `tr '[:upper:]' '[:lower:]'`, already the idiom
# elsewhere in this repo — e.g. update.sh, .claude/hooks/sql-pii-guard.sh).
# Only checked under a shebang that doesn't itself guarantee bash 4+ — a
# script pinned to an explicit newer-bash interpreter path is exempt.
while IFS= read -r file; do
  [ -n "$file" ] || continue
  case "$(head -1 "$file" 2>/dev/null)" in
    '#!/bin/bash'|'#!/usr/bin/env bash')
      if grep -vE '^\s*#' "$file" 2>/dev/null | grep -qE '\$\{[A-Za-z_][A-Za-z0-9_]*(,,?|\^\^?)\}'; then
        echo "FAIL: $file — \${var,,}/\${var^^} (bash 4+, bad substitution on stock macOS bash 3.2) без обёртки"
        fail=1
      fi
      ;;
  esac
done <<< "$FILES_SH"

# --- Unguardable constructs: no documented safe runtime pattern, checklist
# says avoid entirely — any non-comment occurrence fails ---
check_forbidden() {
  local desc="$1" grep_pattern="$2" replacement="$3" file hits
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    hits=$(grep -vE '^\s*#' "$file" 2>/dev/null | grep -nE "$grep_pattern" || true)
    if [ -n "$hits" ]; then
      echo "FAIL: $file — $desc (нет безопасной обёртки, см. docs/PLATFORM-COMPAT.md)"
      echo "$hits" | head -3 | sed 's/^/    /'
      echo "  Замена: $replacement"
      fail=1
    fi
  done <<< "$FILES_SH"
}

check_forbidden "readlink -f" 'readlink -f' 'cd "$(dirname "$0")" && pwd'
check_forbidden "grep -P" '(^|[^a-zA-Z])grep -P' 'grep -E (Extended regex)'
check_forbidden "mktemp -d -t" 'mktemp -d -t' 'mktemp -d (без шаблона)'

if [ "$fail" -eq 0 ]; then
  echo "PASS: check-platform-compat — все конструкции из docs/PLATFORM-COMPAT.md обёрнуты корректно"
fi
exit $fail
