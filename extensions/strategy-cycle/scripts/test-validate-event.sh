#!/bin/bash
# test-validate-event.sh — смоук-тест validate-event.sh на валидном и невалидном
# событии (WP-518, живая приёмка 2026-08-16).
#
# Использование: bash test-validate-event.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATOR="$SCRIPT_DIR/validate-event.sh"
FAILS=0

check() {
  # $2 пуст → вызов validate-event.sh вообще без аргумента (usage-проверка);
  # иначе — обычный вызов с фикстурой.
  local desc="$1" fixture="$2" expected_exit="$3"
  local out
  out=$(mktemp)
  if [ -z "$fixture" ]; then
    bash "$VALIDATOR" >"$out" 2>&1
  else
    bash "$VALIDATOR" "$fixture" >"$out" 2>&1
  fi
  local actual_exit=$?
  if [ "$actual_exit" -eq "$expected_exit" ]; then
    echo "PASS: $desc"
  else
    echo "FAIL: $desc (ожидался exit $expected_exit, получен $actual_exit)"
    cat "$out"
    FAILS=$((FAILS + 1))
  fi
  rm -f "$out"
}

check "usage error: без аргумента" "" 2
check "usage error: несуществующий файл" "/tmp/validate-event-test-does-not-exist-$$.md" 2

VALID_FIXTURE=$(mktemp)
cat > "$VALID_FIXTURE" << 'EOF'
event_type: hypothesis_verdict
source: strategy/current/hypotheses-log.md
period: 2026-08-16
summary: "H-270: вердикт «неприменимо»"
requires_pilot_decision: true
EOF
check "валидное событие (реальный H-270)" "$VALID_FIXTURE" 0

MISSING_FIELD_FIXTURE=$(mktemp)
cat > "$MISSING_FIELD_FIXTURE" << 'EOF'
event_type: hypothesis_verdict
source: strategy/current/hypotheses-log.md
summary: "нет поля period"
requires_pilot_decision: true
EOF
check "отсутствует поле period" "$MISSING_FIELD_FIXTURE" 1

BAD_BOOL_FIXTURE=$(mktemp)
cat > "$BAD_BOOL_FIXTURE" << 'EOF'
event_type: hypothesis_verdict
source: strategy/current/hypotheses-log.md
period: 2026-08-16
summary: "requires_pilot_decision не булево"
requires_pilot_decision: да
EOF
check "requires_pilot_decision = 'да' вместо true/false" "$BAD_BOOL_FIXTURE" 1

BAD_DATE_FIXTURE=$(mktemp)
cat > "$BAD_DATE_FIXTURE" << 'EOF'
event_type: hypothesis_verdict
source: strategy/current/hypotheses-log.md
period: 16.08.2026
summary: "period в неверном формате"
requires_pilot_decision: false
EOF
check "period в формате ДД.ММ.ГГГГ вместо ISO" "$BAD_DATE_FIXTURE" 1

RANGE_FIXTURE=$(mktemp)
cat > "$RANGE_FIXTURE" << 'EOF'
event_type: session_closed
source: strategy
period: 2026-08-10..2026-08-16
summary: "закрытие недели"
requires_pilot_decision: false
EOF
check "period как диапазон дат" "$RANGE_FIXTURE" 0

NO_EVENT_TYPE_FIXTURE=$(mktemp)
cat > "$NO_EVENT_TYPE_FIXTURE" << 'EOF'
source: strategy
period: 2026-08-16
summary: "нет поля event_type"
requires_pilot_decision: false
EOF
check "отсутствует поле event_type" "$NO_EVENT_TYPE_FIXTURE" 1

NO_SOURCE_FIXTURE=$(mktemp)
cat > "$NO_SOURCE_FIXTURE" << 'EOF'
event_type: guide_feedback
period: 2026-08-16
summary: "нет поля source"
requires_pilot_decision: false
EOF
check "отсутствует поле source" "$NO_SOURCE_FIXTURE" 1

NO_SUMMARY_FIXTURE=$(mktemp)
cat > "$NO_SUMMARY_FIXTURE" << 'EOF'
event_type: dissatisfaction_stale
source: strategy
period: 2026-08-16
requires_pilot_decision: true
EOF
check "отсутствует поле summary" "$NO_SUMMARY_FIXTURE" 1

rm -f "$VALID_FIXTURE" "$MISSING_FIELD_FIXTURE" "$BAD_BOOL_FIXTURE" "$BAD_DATE_FIXTURE" "$RANGE_FIXTURE" \
      "$NO_EVENT_TYPE_FIXTURE" "$NO_SOURCE_FIXTURE" "$NO_SUMMARY_FIXTURE"

if [ "$FAILS" -eq 0 ]; then
  echo "Все проверки пройдены."
  exit 0
fi
echo "$FAILS проверок(и) провалено."
exit 1
