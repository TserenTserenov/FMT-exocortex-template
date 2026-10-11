#!/usr/bin/env bash
# test_issue_1147_memory_migrate.sh — regression for issue #1147:
# memory-migrate.sh must (1) not push HOT over the 150-line budget
# (memory-lifecycle-spec.md §4) — the whole --all run stops before ANY write
# when the projection exceeds the limit; (2) derive valid_from from the fact's
# own date (metadata.modified → file mtime → today), not from the migration
# run date; (3) see a columnar YAML list under `metadata:` via frontmatter.sh
# instead of appending a flat duplicate the validator still rejects.
#
# Layers: temp MEMORY_DIR via the script's --dir flag; no network, no writes
# outside the sandbox.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MIGRATE="$ROOT/scripts/memory-migrate.sh"
VALIDATE="$ROOT/scripts/memory-validate.sh"
FRONTMATTER="$ROOT/.claude/lib/frontmatter.sh"

SB="$(cd -P "$(mktemp -d "${TMPDIR:-/tmp}/iwe-issue-1147.XXXXXX")" && pwd -P)"
trap '[ "${KEEP:-0}" = "1" ] || rm -rf "$SB"' EXIT INT TERM
MEM="$SB/memory"
mkdir -p "$MEM"

FAIL_COUNT=0
PASS_COUNT=0
fail() { echo "  ❌ FAIL: $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }
pass() { echo "  ✅ PASS: $*"; PASS_COUNT=$((PASS_COUNT + 1)); }
check() {  # <description> <expected> <actual>
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}

# sha256: shasum (macOS) первым, sha256sum (GNU) запасным — pattern из
# canon-reconcile-published-smoke.sh (check-platform-compat.sh требует).
sha256() {
    if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$@"; else sha256sum "$@"; fi
}

append_body() {  # <file> <n-lines>
    local f="$1" n="$2" i
    for i in $(seq 1 "$n"); do echo "body line $i" >> "$f"; done
}

# Fixture: полный frontmatter, НЕ хватает только domains; domains лежит
# столбиком внутри metadata: (диалект автопамяти Claude Code, issue #281).
cat > "$MEM/reference_dialogs.md" <<'EOF'
---
metadata:
  type: reference
  horizon: warm
  status: active
  valid_from: 2026-08-01
  owner: user
  schema_version: 1
  name: "Справочник: диалоги"
  description: "Ссылочная информация"
  domains:
    - meetings
    - skill-track
---

Тело.
EOF

echo "== 1. columnar domains внутри metadata: не порождает плоского дубля"
out=$(bash "$MIGRATE" --dir "$MEM" "$MEM/reference_dialogs.md" 2>&1)
check "файл без изменений (OK, не DONE)" "0" "$(grep -c 'domains: \[' "$MEM/reference_dialogs.md")"
echo "$out" | grep -q "OK" && pass "миграция сообщила OK (все поля видны)" || fail "ожидался OK, вывод: $out"
domains_val=$(bash -c "source '$FRONTMATTER'; get_field '$MEM/reference_dialogs.md' domains")
check "get_field читает столбик как inline" "[meetings, skill-track]" "$domains_val"
bash "$VALIDATE" --dir "$MEM" "$MEM/reference_dialogs.md" >/dev/null 2>&1 \
    && pass "валидатор принимает файл" || fail "валидатор всё ещё ругается на domains"

# Конфликт форм: плоское значение И столбик — предупреждение, побеждает плоская.
cat > "$MEM/lesson_conflict.md" <<'EOF'
---
metadata:
  domains:
    - meetings
domains: [reference]
---

Тело.
EOF
conflict_val=$(bash -c "source '$FRONTMATTER'; get_field '$MEM/lesson_conflict.md' domains" 2>"$SB/conflict.err")
check "конфликт: возвращается плоское значение" "[reference]" "$conflict_val"
grep -qi "conflict\|both" "$SB/conflict.err" && pass "конфликт форм — предупреждение в stderr" || fail "конфликт форм прошёл молча"
rm -f "$MEM/lesson_conflict.md"

echo "== 2. valid_from из metadata.modified"
cat > "$MEM/project_alpha.md" <<'EOF'
---
metadata:
  modified: 2026-08-03T10:24:00Z
---

Проект альфа.
EOF
bash "$MIGRATE" --dir "$MEM" "$MEM/project_alpha.md" >/dev/null 2>&1
check "valid_from = дата modified, не сегодня" "valid_from: 2026-08-03" "$(grep '^valid_from:' "$MEM/project_alpha.md")"

echo "== 3. valid_from из mtime, когда modified нет"
cat > "$MEM/project_beta.md" <<'EOF'
---
type: project
---

Проект бета.
EOF
touch -t 202607050000 "$MEM/project_beta.md" 2>/dev/null || touch -d "2026-07-05" "$MEM/project_beta.md"
bash "$MIGRATE" --dir "$MEM" "$MEM/project_beta.md" >/dev/null 2>&1
check "valid_from = mtime файла" "valid_from: 2026-07-05" "$(grep '^valid_from:' "$MEM/project_beta.md")"

echo "== 4. --all: превышение бюджета HOT — стоп до любой записи"
MEM2="$SB/memory-hot"
mkdir -p "$MEM2"
# существующий hot-файл на 140 строк тела
cat > "$MEM2/user_main.md" <<'EOF'
---
type: user
horizon: hot
domains: [user-profile]
status: active
valid_from: 2026-01-01
owner: user
schema_version: 1
name: "Профиль"
description: "Профиль пользователя"
---
EOF
append_body "$MEM2/user_main.md" 140
# кандидат без horizon: user_* → infer hot, тело 20 строк (140+20=160 > 150)
cat > "$MEM2/user_extra.md" <<'EOF'
---
type: user
domains: [user-profile]
status: active
valid_from: 2026-01-01
owner: user
schema_version: 1
name: "Доп профиль"
description: "Дополнение"
---
EOF
append_body "$MEM2/user_extra.md" 20
sum_before=$(cat "$MEM2"/*.md | sha256 | awk '{print $1}')
out=$(bash "$MIGRATE" --dir "$MEM2" --all 2>&1)
rc=$?
check "exit code ненулевой при превышении" "1" "$([ $rc -ne 0 ] && echo 1 || echo 0)"
echo "$out" | grep -q "user_extra.md" && pass "в stderr перечислен кандидат" || fail "кандидат не перечислен: $out"
sum_after=$(cat "$MEM2"/*.md | sha256 | awk '{print $1}')
check "ни один файл не изменён" "$sum_before" "$sum_after"

echo "== 5. --all: в пределах бюджета — hot присваивается"
MEM3="$SB/memory-ok"
mkdir -p "$MEM3"
cat > "$MEM3/user_small.md" <<'EOF'
---
type: user
domains: [user-profile]
status: active
valid_from: 2026-01-01
owner: user
schema_version: 1
name: "Малый профиль"
description: "Малый"
---
EOF
append_body "$MEM3/user_small.md" 10
bash "$MIGRATE" --dir "$MEM3" --all >/dev/null 2>&1
check "horizon: hot присвоен" "horizon: hot" "$(grep '^horizon:' "$MEM3/user_small.md")"

echo "== 6. одиночный файл сверх бюджета — отказ без записи"
MEM4="$SB/memory-single"
mkdir -p "$MEM4"
cp "$MEM2/user_main.md" "$MEM4/user_main.md"
cp "$MEM2/user_extra.md" "$MEM4/user_extra.md"
sum_before=$(sha256 "$MEM4/user_extra.md" | awk '{print $1}')
out=$(bash "$MIGRATE" --dir "$MEM4" "$MEM4/user_extra.md" 2>&1)
rc=$?
check "exit code ненулевой" "1" "$([ $rc -ne 0 ] && echo 1 || echo 0)"
echo "$out" | grep -q "REFUSE" && pass "диагностика REFUSE" || fail "нет REFUSE: $out"
check "файл не изменён" "$sum_before" "$(sha256 "$MEM4/user_extra.md" | awk '{print $1}')"

echo "== 7. замок: второй параллельный запуск отклонён без записи"
MEM5="$SB/memory-lock"
mkdir -p "$MEM5"
cat > "$MEM5/user_small.md" <<'EOF'
---
type: user
domains: [user-profile]
status: active
valid_from: 2026-01-01
owner: user
schema_version: 1
name: "Профиль"
description: "Профиль"
---
Тело.
EOF
sleep 30 &
HOLDER_PID=$!
mkdir -p "$MEM5/.migrate.lock"
echo "$HOLDER_PID" > "$MEM5/.migrate.lock/pid"
sum_before=$(sha256 "$MEM5/user_small.md" | awk '{print $1}')
out=$(bash "$MIGRATE" --dir "$MEM5" --all 2>&1)
rc=$?
kill "$HOLDER_PID" 2>/dev/null || true
wait "$HOLDER_PID" 2>/dev/null || true
check "второй запуск отклонён" "1" "$([ $rc -ne 0 ] && echo 1 || echo 0)"
echo "$out" | grep -q "ОТКАЗ" && pass "диагностика замка" || fail "нет ОТКАЗ: $out"
check "файл не изменён" "$sum_before" "$(sha256 "$MEM5/user_small.md" | awk '{print $1}')"
rm -rf "$MEM5/.migrate.lock"

echo ""
echo "PASS=$PASS_COUNT FAIL=$FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
