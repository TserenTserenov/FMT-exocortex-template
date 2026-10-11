#!/usr/bin/env bash
# Issue #496: DayPlan/WeekPlan heading style is a per-installation choice
# (details, the default, vs markdown headings), read from params.yaml.
# Drives the real functions from lib/common.sh, not a reimplementation.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

FAILS=0
ok()   { echo "  ok: $1"; }
fail() { echo "  FAIL: $1"; FAILS=$((FAILS + 1)); }

# shellcheck source=../lib/common.sh
source "$ROOT/scripts/lib/common.sh"

echo "== iwe_heading_style: resolution from params.yaml =="
[ "$(iwe_heading_style "$TMP/missing.yaml")" = "details" ] \
  && ok "missing file -> details" || fail "missing file -> details"

printf 'dayplan_weekplan_heading_style: markdown\n' > "$TMP/p1.yaml"
[ "$(iwe_heading_style "$TMP/p1.yaml")" = "markdown" ] \
  && ok "explicit markdown -> markdown" || fail "explicit markdown -> markdown"

printf 'other_key: 1\n' > "$TMP/p2.yaml"
[ "$(iwe_heading_style "$TMP/p2.yaml")" = "details" ] \
  && ok "key absent -> details" || fail "key absent -> details"

printf 'dayplan_weekplan_heading_style: nonsense\n' > "$TMP/p3.yaml"
[ "$(iwe_heading_style "$TMP/p3.yaml" 2>/dev/null)" = "details" ] \
  && ok "unknown value -> details (with warning on stderr)" || fail "unknown value -> details"
iwe_heading_style "$TMP/p3.yaml" 2>&1 >/dev/null | grep -q "неизвестно" \
  && ok "unknown value warns on stderr" || fail "unknown value warns on stderr"

echo "== iwe_render_heading_style: details passes through unchanged =="
IN=$'<details>\n<summary><b>Секция</b></summary>\nтекст\n</details>'
OUT=$(printf '%s' "$IN" | iwe_render_heading_style details)
[ "$OUT" = "$IN" ] && ok "details is a no-op" || fail "details is a no-op (got: $OUT)"
OUT_DEFAULT=$(printf '%s' "$IN" | iwe_render_heading_style)
[ "$OUT_DEFAULT" = "$IN" ] && ok "no argument defaults to details" || fail "no argument defaults to details"

echo "== iwe_render_heading_style: markdown converts both summary forms =="
IN2=$'<details>\n<summary><b>Секция А</b></summary>\nтекст А\n</details>\n<details open>\n<summary><strong>CC-12</strong></summary>\nтекст Б\n</details>'
OUT2=$(printf '%s' "$IN2" | iwe_render_heading_style markdown)
EXPECTED=$'## Секция А\nтекст А\n## CC-12\nтекст Б'
[ "$OUT2" = "$EXPECTED" ] && ok "markdown strips wrappers and renders ##" || fail "markdown conversion (got: $OUT2)"

echo "== validator still accepts a markdown-style DayPlan (no format migration) =="
VALIDATOR="$ROOT/.claude/hooks/protocol-artifact-validate.sh"
GOV="$TMP/GOV"
mkdir -p "$GOV/current"
cat > "$GOV/current/DayPlan 2026-10-11.md" <<'EOF'
# Day Plan
## План на сегодня
| # | РП | h |
|---|-----|---|
| 1 | Пример | 5 |
**Бюджет дня:** ~7.5h РП всего / ~7.5h физ / мультипликатор ~1.0x
## Календарь
нет событий
строка два
строка три
## IWE за ночь
ок
## Разбор заметок
пусто
## Итоги вчера
carry-over: нет
EOF
export IWE_WORKSPACE="$TMP" IWE_GOVERNANCE_REPO="GOV"
(cd "$GOV" && git init -q)
(cd "$GOV" && git add "current/DayPlan 2026-10-11.md")
OUT3=$(jq -nc '{tool_name:"Bash",tool_input:{command:"git commit -m x"}}' | bash "$VALIDATOR")
case "$OUT3" in
  *additionalContext*) ok "markdown-headed DayPlan validates OK" ;;
  *) fail "markdown-headed DayPlan validates OK (got: $OUT3)" ;;
esac

echo
if [ "$FAILS" -eq 0 ]; then
  echo "OK: все проверки прошли."
else
  echo "FAIL: провалено проверок: $FAILS"
  exit 1
fi
