#!/usr/bin/env bash
# Regression coverage for the wp-sync-bundle.sh registry_status() cluster
# found in the FMT-exocortex-template issue backlog (WP-7 F116, peer-session
# with Kimi + Codex):
#   #713 - "paused" status (⏸) fell through to an unreachable fallback and
#          printed an empty line instead of a real status or "unknown".
#   #714 - a strikethrough anywhere in the row overrode an active status
#          column value (e.g. a struck-through title with a still-active 🔄
#          status cell was reported as "done").
#   #715 - a leading zero in the WP number (WP-038) failed to match the bare
#          "38" stored in the registry.
#   #716 - a marker glued to the number (e.g. "13★") fell outside the row
#          regex and the lookup silently matched a different row sharing the
#          same bare number.
#   #717 - the status emoji comparison depended on the runtime locale; under
#          some locale/awk combinations even the *column lookup* itself
#          (registry_status_column, unrelated tolower()-based match) picked
#          the wrong column entirely (found while regression-testing #717,
#          not in the original report).
# Each check below reproduces one issue's fixture from a single small
# registry file and asserts the exact expected status string.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT

pass_count=0
pass() { echo "  ✅ PASS: $*"; pass_count=$((pass_count + 1)); }
fail() { echo "  ❌ FAIL: $*" >&2; exit 1; }

REGISTRY_FILE="$TMP/registry.md"
cat >"$REGISTRY_FILE" <<'EOF'
| # | Название | Статус | Приоритет |
|---|----------|--------|-----------|
| 57 | Приостановленный | ⏸️ | P1 |
| 39 | ~~Свёрнутый в архив~~ | 📦 | P2 |
| 38 | **Резидентура МИМ R1 - R4** | 🔄 | P2 |
| 13★ | Итерация 6 account_bot | 🔄 ждёт ответа | — |
| ~~13~~ | ~~Итерация 5 account_bot~~ | ↗️ | — |
| 100 | Обычный | 🔄 | P1 |
EOF

# Load only the two functions under test — sourcing the whole file would run
# its CLI dispatch (same isolation pattern used by the update.sh issue tests).
eval "$(awk '
  /^registry_status_column\(\)/ { capture=1 }
  capture { print }
  capture && /^}/ { print ""; capture=0 }
' "$ROOT/.claude/scripts/wp-sync-bundle.sh")"
eval "$(awk '
  /^registry_status\(\)/ { capture=1 }
  capture { print }
  capture && /^}/ { exit }
' "$ROOT/.claude/scripts/wp-sync-bundle.sh")"
declare -F registry_status >/dev/null

check() {
  local desc="$1" num="$2" expected="$3" got
  got=$(registry_status "$num" 2>/dev/null)
  if [ "$got" = "$expected" ]; then
    pass "$desc (got: $got)"
  else
    fail "$desc: expected '$expected', got '$got'"
  fi
}

echo "--- #713: paused status resolves instead of an empty line ---"
check "WP-57 (⏸️) reports paused, not empty" 57 "⏸ paused"

echo "--- #714: own status column outranks a strikethrough elsewhere in the row ---"
check "WP-39 (struck-through title, active 📦 cell) reports archived, not done" 39 "📦 archived"

echo "--- #715: leading zero in the query number is normalized ---"
check "WP-038 matches the bare '38' row" 038 "🔄 in_progress"
check "WP-38 sanity (same row, no leading zero)" 38 "🔄 in_progress"

echo "--- #716: a marker glued to the number does not divert to a different row ---"
out=$(registry_status 13 2>"$TMP/warn.txt")
if [ "$out" = "🔄 in_progress" ]; then
  pass "WP-13★ resolves to the active row, not the struck-through '~~13~~' row"
else
  fail "WP-13 ambiguity resolution regressed: expected the active row, got '$out'"
fi
if grep -qi "неоднозначно" "$TMP/warn.txt"; then
  pass "ambiguous match (13★ + ~~13~~) is flagged on stderr instead of failing silently"
else
  fail "expected an ambiguity warning on stderr for the duplicate-number fixture"
fi

echo "--- #717: locale-independent status classification ---"
for loc in "" C C.UTF-8 en_US.UTF-8 ru_RU.UTF-8; do
  got=$(LC_ALL="$loc" registry_status 100 2>/dev/null)
  if [ "$got" = "🔄 in_progress" ]; then
    pass "LC_ALL='${loc:-<ambient>}': status resolves correctly"
  else
    fail "LC_ALL='${loc:-<ambient>}': expected '🔄 in_progress', got '$got'"
  fi
done

echo "--- sanity: unknown number still reports 'not in registry' ---"
check "WP-999 (absent) reports not-in-registry" 999 "_не в реестре_"

echo "wp-sync-bundle registry_status guard: $pass_count checks passed"
