#!/usr/bin/env bash
# Regression coverage for the residual of issue #1149 (day-open-scaffold.sh):
#   1. day-rhythm-config.yaml is opened with encoding='utf-8' (Windows Python
#      defaults to cp1251 and chokes on Cyrillic comments);
#   2. extract_day_close_carry_over takes the LAST heading-like
#      "Завтра начать с" section, not the first mention anywhere in the file;
#   3. the section stops before the closing footer (*Закрыто: ...* / *Создан: ...*).
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
SCRIPT="$ROOT/scripts/day-open-scaffold.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail=0
pass() { echo "  ✅ PASS: $*"; }
fail_test() { echo "  ❌ FAIL: $*" >&2; fail=1; }

# --- 1. Both config reads carry an explicit encoding.
opens=$(grep -c "open('\$CONFIG_PY', encoding='utf-8')" "$SCRIPT")
bare=$(grep -c "open('\$CONFIG_PY')" "$SCRIPT")
if [ "$opens" = "2" ] && [ "$bare" = "0" ]; then
    pass "both config opens use encoding='utf-8'"
else
    fail_test "config opens: utf-8=$opens bare=$bare (expected 2 and 0)"
fi

# --- 2./3. Run the real function against a throw-away DayPlan archive.
IWE_ROOT_FIXTURE="$TMP/iwe"
YDAY="2026-10-11"
PLAN_DIR="$IWE_ROOT_FIXTURE/DS-strategy/archive/day-plans"
mkdir -p "$PLAN_DIR" "$TMP/sessions"
cat > "$PLAN_DIR/DayPlan $YDAY.md" <<'EOF'
# DayPlan

Заметка в теле: Завтра начать с чего-то другого — это не список.

<details open><summary><b>Итоги дня</b></summary>

**Завтра начать с:**
- РП-1: дописать тест
- РП-2: слить ветку

</details>

*Закрыто: 2026-10-11 23:50*
*Создан: 2026-10-11 07:00*
EOF

run_extract() {
    IWE="$IWE_ROOT_FIXTURE" IWE_GOVERNANCE_REPO="DS-strategy" bash -c '
        iwe_sessions_dir() { echo "$1"; }
        iwe_resolve_governance_repo() { echo "${1:-DS-strategy}"; }
        '"$(sed -n '/^extract_day_close_carry_over() {/,/^}/p' "$SCRIPT")"'
        extract_day_close_carry_over "$2"
    ' _ "$TMP/sessions" "$YDAY"
}

out=$(run_extract)
if printf '%s\n' "$out" | grep -qF "РП-1: дописать тест" && printf '%s\n' "$out" | grep -qF "РП-2: слить ветку"; then
    pass "handoff list is taken from the heading-like section"
else
    fail_test "handoff list missing: $out"
fi
if printf '%s\n' "$out" | grep -qF "в теле"; then
    fail_test "first mention in the body leaked into the list: $out"
else
    pass "earlier mention in the body is ignored"
fi
if printf '%s\n' "$out" | grep -qE 'Закрыто|Создан'; then
    fail_test "closing footer leaked into the list: $out"
else
    pass "closing footer is not part of the list"
fi

# --- 4. Plain (unmarked) heading line still wins over a later prose mention.
cat > "$PLAN_DIR/DayPlan $YDAY.md" <<'EOF'
Завтра начать с:
- РП-3: проверить релиз

Позже в тексте снова: Завтра начать с отдыха.
EOF
out=$(run_extract)
if printf '%s\n' "$out" | grep -qF "РП-3: проверить релиз"; then
    pass "unmarked heading line is used before a prose mention"
else
    fail_test "unmarked heading not used: $out"
fi

# --- 5. Of several heading-like sections the LAST one wins, whatever its form.
cat > "$PLAN_DIR/DayPlan $YDAY.md" <<'EOF'
**Завтра начать с:**
- РП-4: устаревший список

Завтра начать с:
- РП-5: актуальный список
EOF
out=$(run_extract)
if printf '%s\n' "$out" | grep -qF "РП-5: актуальный список" && ! printf '%s\n' "$out" | grep -qF "РП-4"; then
    pass "the latest heading-like section wins across forms"
else
    fail_test "wrong section chosen: $out"
fi

exit $fail
