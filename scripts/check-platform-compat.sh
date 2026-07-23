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

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$ROOT" || exit 2

# guide-kit/ is a vendored byte-identical copy (WP-483) — its own upstream CI
# is responsible for its portability, not ours (mirrors the shellcheck job's
# exclusion for the same reason). This script's own file is excluded too — its
# doc-comments and pattern-string literals name every construct it checks for,
# which would otherwise flag itself.
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
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

# Python equivalent of the osascript guard (subprocess.run(["osascript"...)
while IFS= read -r file; do
  [ -n "$file" ] || continue
  if grep -vE '^\s*#' "$file" 2>/dev/null | grep -qE 'osascript' \
     && ! grep -qE 'shutil\.which\("osascript"\)|which\(.osascript' "$file" 2>/dev/null; then
    echo "FAIL: $file — osascript без guard (shutil.which)"
    fail=1
  fi
done <<< "$FILES_PY"

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
check_forbidden "grep -P" 'grep -P' 'grep -E (Extended regex)'
check_forbidden "mktemp -d -t" 'mktemp -d -t' 'mktemp -d (без шаблона)'

if [ "$fail" -eq 0 ]; then
  echo "PASS: check-platform-compat — все конструкции из docs/PLATFORM-COMPAT.md обёрнуты корректно"
fi
exit $fail
