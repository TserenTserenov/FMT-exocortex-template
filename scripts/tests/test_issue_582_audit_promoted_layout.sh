#!/usr/bin/env bash
# test_issue_582_audit_promoted_layout.sh — regression for issue #582.
#
# iwe-audit.sh section 3b used to require promoted Day Open copies in the
# governance repo ($DS_DIR/scripts) unconditionally. On installations where
# the pipeline actually executes from $IWE_SCRIPTS (the template itself), that
# produced a false "конвейер Day Open неполный" warning and exit 1 on a healthy
# system. The fix compares against the copy that actually runs ($IWE_SCRIPTS),
# strips the seed SNAPSHOT marker line (check-seed-drift.sh convention), and
# classifies drift against the canonical template scripts/ so the recovery
# advice can never round-trip the marker into the executed copy (peer review
# rounds 1-2).
#
# Код возврата аудита в фиктивном workspace намеренно НЕ проверяется: прочие
# разделы аудита на минимальном каркасе тоже находят критичные пробелы, поэтому
# итоговый статус здесь недетерминирован. Проверяется наблюдаемый текст веток.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

MARKER="# SNAPSHOT — synced manually via script-promote.sh from FMT-exocortex-template/scripts/. Do not edit here directly."

fail=0
check() { # <desc> <expected-present> <output-file>
    local desc="$1" pattern="$2" file="$3"
    if grep -qF "$pattern" "$file"; then
        echo "PASS: $desc"
    else
        echo "FAIL: $desc — ожидалась строка: $pattern"
        fail=$((fail + 1))
    fi
}
check_absent() {
    local desc="$1" pattern="$2" file="$3"
    if grep -qF "$pattern" "$file"; then
        echo "FAIL: $desc — строки не должно быть: $pattern"
        fail=$((fail + 1))
    else
        echo "PASS: $desc"
    fi
}

# install_exec <ws> <target-dir> — исполняемые/канонические копии БЕЗ маркерной
# строки, содержимое идентично seed после вычитания маркера.
install_exec() {
    local dst="$2"
    mkdir -p "$dst/lib"
    printf '#!/usr/bin/env bash\nscaffold-v1\n' > "$dst/day-open-scaffold.sh"
    printf '#!/usr/bin/env bash\npipeline-v1\n' > "$dst/day-open-pipeline.sh"
    printf '#!/usr/bin/env bash\ncommon-v1\n'    > "$dst/lib/common.sh"
}

# build_ws <dir> — минимальный каркас установки: шаблон с аудитом, bootstrap,
# каноническими копиями в scripts/ и seed-снимками (с маркером SNAPSHOT).
build_ws() {
    local ws="$1"
    mkdir -p "$ws/FMT-exocortex-template/scripts" \
             "$ws/FMT-exocortex-template/.claude/lib" \
             "$ws/FMT-exocortex-template/seed/strategy/scripts/lib" \
             "$ws/DS-strategy"
    cp "$ROOT/scripts/iwe-audit.sh" "$ws/FMT-exocortex-template/scripts/"
    cp "$ROOT/scripts/check-seed-drift.sh" "$ws/FMT-exocortex-template/scripts/"
    cp "$ROOT/.claude/lib/iwe-env-bootstrap.sh" "$ws/FMT-exocortex-template/.claude/lib/"
    printf '#!/usr/bin/env bash\n%s\nscaffold-v1\n' "$MARKER" > "$ws/FMT-exocortex-template/seed/strategy/scripts/day-open-scaffold.sh"
    printf '#!/usr/bin/env bash\n%s\npipeline-v1\n' "$MARKER" > "$ws/FMT-exocortex-template/seed/strategy/scripts/day-open-pipeline.sh"
    printf '#!/usr/bin/env bash\n%s\ncommon-v1\n'    "$MARKER" > "$ws/FMT-exocortex-template/seed/strategy/scripts/lib/common.sh"
    install_exec "$ws" "$ws/FMT-exocortex-template/scripts"
}

run_audit() { # <ws> <out>
    local ws="$1" out="$2"
    # Чистим IWE_* из окружения теста: bootstrap берёт их как override, иначе
    # переменные боевой машины уводят проверку из фиктивного workspace в
    # настоящий шаблон.
    env -u IWE_SCRIPTS -u IWE_ROOT -u IWE_TEMPLATE -u IWE_GOVERNANCE_REPO \
        -u IWE_DS_MY_STRATEGY -u IWE_RUNTIME -u IWE_WORKSPACE \
        WORKSPACE_DIR="$ws" bash "$ws/FMT-exocortex-template/scripts/iwe-audit.sh" --root "$ws" > "$out" 2>&1 || true
}

# Вырезка раздела 3b из полного вывода аудита — на фиктивном workspace
# предупреждения других разделов неизбежны и не относятся к делу.
sec3b() { # <output-file> <dst>
    sed -n '/^## 3b\./,/^## 4\./p' "$1" > "$2"
}

# Проверка, что все три файла раздела 3b зелёные, а не «хотя бы один».
check_all_three_ok() { # <desc> <output-file> <section-dst>
    local desc="$1" file="$2" section="$3"
    sec3b "$file" "$section"
    check "$desc: scaffold зелёный" '`day-open-scaffold.sh` совпадает с каноном шаблона' "$section"
    check "$desc: pipeline зелёный" '`day-open-pipeline.sh` совпадает с каноном шаблона' "$section"
    check "$desc: common зелёный" '`lib/common.sh` совпадает с каноном шаблона' "$section"
    check_absent "$desc: нет предупреждений 3b" '⚠️' "$section"
    check_absent "$desc: нет критичных ❌ в 3b" '❌' "$section"
}

# --- Сценарий A: раскладка «исполнение из шаблона» (дефолтный IWE_SCRIPTS) ---
# Раньше: ложный «не установлен в governance-репо — конвейер неполный».
# Маркерная строка SNAPSHOT в seed не считается дрейфом.
WS_A="$TMP/ws-a"; build_ws "$WS_A"
run_audit "$WS_A" "$TMP/out-a.txt"
check_all_three_ok "A" "$TMP/out-a.txt" "$TMP/sec-a.txt"
check_absent "A: нет ложного «конвейер неполный»" "конвейер Day Open неполный" "$TMP/out-a.txt"
check_absent "A: нет ссылки на governance-репо" "не установлен в governance-репо" "$TMP/out-a.txt"

# --- Сценарий B: промотированная раскладка, копии отсутствуют ---
# Предупреждение обязано остаться — здесь конвейер действительно неполный.
WS_B="$TMP/ws-b"; build_ws "$WS_B"
mkdir -p "$WS_B/DS-strategy/scripts"
echo 'IWE_SCRIPTS="$WORKSPACE_DIR/DS-strategy/scripts"' > "$WS_B/.exocortex.env"
run_audit "$WS_B" "$TMP/out-b.txt"
check "B: честный «конвейер неполный» в промотированной раскладке" "отсутствует в исполняемой копии" "$TMP/out-b.txt"

# --- Сценарий B2: промотированная раскладка, копии на месте и совпадают ---
install_exec "$WS_B" "$WS_B/DS-strategy/scripts"
run_audit "$WS_B" "$TMP/out-b2.txt"
check_all_three_ok "B2" "$TMP/out-b2.txt" "$TMP/sec-b2.txt"

# --- Сценарий E: промотированная копия реально отстала от канона ---
# Совет обязан вести к канону (scripts/ шаблона, без маркера) — `cp` из seed
# перенёс бы маркерную строку в исполняемую копию, и предупреждение вернулось
# бы на следующем аудите.
echo "local-hack" >> "$WS_B/DS-strategy/scripts/day-open-scaffold.sh"
run_audit "$WS_B" "$TMP/out-e.txt"
sec3b "$TMP/out-e.txt" "$TMP/sec-e.txt"
check "E: отставшая исполняемая копия названа" "отстал от канона шаблона" "$TMP/sec-e.txt"
check "E: совет ведёт к канону scripts/ шаблона" "FMT-exocortex-template/scripts/day-open-scaffold.sh" "$TMP/sec-e.txt"

# --- Сценарий F: раскладка «из шаблона», seed-снимок отстал от канона ---
# Совет — пересобрать снимок штатным сторожем, не ручным cp.
WS_F="$TMP/ws-f"; build_ws "$WS_F"
echo "canon-new-line" >> "$WS_F/FMT-exocortex-template/scripts/day-open-scaffold.sh"
run_audit "$WS_F" "$TMP/out-f.txt"
sec3b "$TMP/out-f.txt" "$TMP/sec-f.txt"
check "F: отставший снимок назван" 'seed/strategy/scripts/day-open-scaffold.sh` отстал от `scripts/day-open-scaffold.sh' "$TMP/sec-f.txt"
check "F: совет — штатный check-seed-drift --fix" "check-seed-drift.sh" "$TMP/sec-f.txt"
check_absent "F: исполняемая копия не обвиняется (она и есть канон)" "отстал от канона шаблона" "$TMP/sec-f.txt"

# --- Сценарий G: промотированная раскладка, канон ушёл вперёд вместе с
# исполняемой копией, отстал только seed (воспроизведение P1 ревью раунда 2) ---
WS_G="$TMP/ws-g"; build_ws "$WS_G"
install_exec "$WS_G" "$WS_G/DS-strategy/scripts"
echo 'IWE_SCRIPTS="$WORKSPACE_DIR/DS-strategy/scripts"' > "$WS_G/.exocortex.env"
echo "canon-new-line" >> "$WS_G/FMT-exocortex-template/scripts/day-open-scaffold.sh"
echo "canon-new-line" >> "$WS_G/DS-strategy/scripts/day-open-scaffold.sh"
run_audit "$WS_G" "$TMP/out-g.txt"
sec3b "$TMP/out-g.txt" "$TMP/sec-g.txt"
check "G: отставший seed назван" 'seed/strategy/scripts/day-open-scaffold.sh` отстал' "$TMP/sec-g.txt"
check "G: совет — check-seed-drift --fix" "check-seed-drift.sh" "$TMP/sec-g.txt"
check_absent "G: исполняемая копия НЕ обвиняется — она совпадает с каноном" "отстал от канона шаблона" "$TMP/sec-g.txt"

# --- Сценарий H: канон недоступен, снимок и исполняемая копия разошлись ---
WS_H="$TMP/ws-h"; build_ws "$WS_H"
install_exec "$WS_H" "$WS_H/DS-strategy/scripts"
echo 'IWE_SCRIPTS="$WORKSPACE_DIR/DS-strategy/scripts"' > "$WS_H/.exocortex.env"
rm "$WS_H/FMT-exocortex-template/scripts/day-open-pipeline.sh"
echo "local-hack" >> "$WS_H/DS-strategy/scripts/day-open-pipeline.sh"
run_audit "$WS_H" "$TMP/out-h.txt"
sec3b "$TMP/out-h.txt" "$TMP/sec-h.txt"
check "H: расхождение без канона — ручная сверка" '`day-open-pipeline.sh` в исполняемой копии разошёлся с seed шаблона, канонический `scripts/day-open-pipeline.sh` не найден — сверить вручную' "$TMP/sec-h.txt"
check "H: отсутствие канона само названо регрессией" 'канонический `scripts/day-open-pipeline.sh` отсутствует в шаблоне — регрессия доставки' "$TMP/sec-h.txt"

# --- Сценарий I: seed отсутствует И исполняемая копия отстала — обе
# диагностики обязаны прозвучать (независимая классификация, ревью раунд 3) ---
WS_I="$TMP/ws-i"; build_ws "$WS_I"
install_exec "$WS_I" "$WS_I/DS-strategy/scripts"
echo 'IWE_SCRIPTS="$WORKSPACE_DIR/DS-strategy/scripts"' > "$WS_I/.exocortex.env"
rm "$WS_I/FMT-exocortex-template/seed/strategy/scripts/day-open-scaffold.sh"
echo "local-hack" >> "$WS_I/DS-strategy/scripts/day-open-scaffold.sh"
run_audit "$WS_I" "$TMP/out-i.txt"
sec3b "$TMP/out-i.txt" "$TMP/sec-i.txt"
check "I: отсутствие seed названо" 'seed/strategy/scripts/day-open-scaffold.sh` отсутствует в шаблоне' "$TMP/sec-i.txt"
check "I: отставшая исполняемая копия тоже названа" '`day-open-scaffold.sh` в исполняемой копии отстал от канона' "$TMP/sec-i.txt"

# --- Сценарий C: IWE_SCRIPTS указывает на несуществующий каталог ---
WS_C="$TMP/ws-c"; build_ws "$WS_C"
echo 'IWE_SCRIPTS="$WORKSPACE_DIR/DS-strategy/scripts"' > "$WS_C/.exocortex.env"
run_audit "$WS_C" "$TMP/out-c.txt"
check "C: несуществующий каталог исполнения назван критичным" "❌ каталог \`IWE_SCRIPTS=" "$TMP/out-c.txt"
check "C: текст честно говорит «не запустится»" "не запустится" "$TMP/out-c.txt"
check_absent "C: нет ложного «неполный» про отсутствующий каталог" "конвейер Day Open неполный" "$TMP/out-c.txt"

# --- Сценарий D: исполнение прямо из seed — отдельной копии нет ---
WS_D="$TMP/ws-d"; build_ws "$WS_D"
echo 'IWE_SCRIPTS="$WORKSPACE_DIR/FMT-exocortex-template/seed/strategy/scripts"' > "$WS_D/.exocortex.env"
run_audit "$WS_D" "$TMP/out-d.txt"
check "D: исполнение из seed → N/A" "отдельной копии нет" "$TMP/out-d.txt"
check_absent "D: нет предупреждений" "конвейер Day Open неполный" "$TMP/out-d.txt"

if [ "$fail" -gt 0 ]; then
    echo "FAIL: $fail проверок упало"
    exit 1
fi
echo "PASS: iwe-audit section 3b follows the actual \$IWE_SCRIPTS execution layout (issue #582)"
