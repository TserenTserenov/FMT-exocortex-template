#!/usr/bin/env bash
# Regression for issue #871: wp-sync-bundle.sh registry_status() did not
# recognise a registry row whose number column carries the "WP-" prefix
# ("| **WP-117** | ... |") and answered "_не в реестре_" - indistinguishable
# from a genuinely absent row, which silently blinded the update.sh canary and
# the card/registry reconciliation on such installations.
# The number column is matched as the row's own first cell (same approach as
# #473/#715/#716); the prefix must be accepted only right before the number.
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
| **WP-117** | **Префикс и жирный** | 🔄 | P1 |
| WP-118 | Префикс без жирного | 📦 | P2 |
| ~~WP-119~~ | ~~Префикс и зачёркнутый~~ | ↗️ | P2 |
| wp-121 | Префикс строчными | ⏸️ | P2 |
| **WP-1170** | Похожий номер, другая строка | 📦 | P3 |
| 120 | Канон: голое число | 🔄 | P1 |
| ~~130~~ | ~~Зачёркнутый, голое число~~ | ↗️ | P2 |
EOF

# Load only the two functions under test - sourcing the whole file would run
# its CLI dispatch (same isolation pattern as test_issue_713_registry_status.sh).
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

echo "--- #871: 'WP-' prefix in the number column ---"
check "'| **WP-117** |' (prefix + bold) resolves"          117 "🔄 in_progress"
check "'| WP-118 |' (prefix, no bold) resolves"              118 "📦 archived"
# A struck-through row is classified by the existing strikethrough rules; the prefix
# must not change that classification, so compare with the same row shape without it.
got_prefixed=$(registry_status 119 2>/dev/null)
got_bare=$(registry_status 130 2>/dev/null)
if [ -n "$got_prefixed" ] && [ "$got_prefixed" != "_не в реестре_" ] && [ "$got_prefixed" = "$got_bare" ]; then
  pass "'| ~~WP-119~~ |' (prefix + strikethrough) classified like the bare '~~130~~' row (got: $got_prefixed)"
else
  fail "'| ~~WP-119~~ |': expected the same verdict as the bare-number row ('$got_bare'), got '$got_prefixed'"
fi
check "'| wp-121 |' (lowercase prefix) resolves"             121 "⏸ paused"
check "the query form 'WP-117' resolves the same row"        WP-117 "🔄 in_progress"

echo "--- prefix accepted only right before the number ---"
check "WP-1170 does not answer for 117 (117 keeps its own row)" 117 "🔄 in_progress"
check "WP-1170 resolves to its own row"                         1170 "📦 archived"

echo "--- unchanged behaviour ---"
check "bare-number canonical row still resolves"             120 "🔄 in_progress"
check "absent number still reports 'not in registry'"        999 "_не в реестре_"

echo "registry_status prefix guard (#871): $pass_count checks passed"
