#!/usr/bin/env bash
set -euo pipefail

# issue #473 (wp-sync-bundle.sh half): registry_status() found the row via
# `grep "WP-${num}[^0-9]"` — a substring match that also fires on prose in
# OTHER rows' cells. WP-49's own status cell said "открыт как спин-офф
# WP-47", so asking for WP-47's status returned WP-49's status instead.
# Status was also read by grepping an emoji across the WHOLE line rather
# than the row's own status cell. The two functions are extracted by their
# real line markers (same technique as test_issue_434_pipeline_scaffold_only.sh)
# and driven directly, since sourcing the whole script pulls in unrelated
# wp-sync-bundle.sh setup this test does not need.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT_UNDER_TEST="${SCRIPT_UNDER_TEST:-$ROOT/.claude/scripts/wp-sync-bundle.sh}"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/docs"
cat > "$TMP/docs/WP-REGISTRY.md" <<'REGISTRY'
| # | Название | Цель | Создан | P | Репо | Бюджет | Статус |
|---|---|---|---|---|---|---|---|
| 47 | Тест Б | цель | 01.01 | P1 | repo/ | 4h | ✅ |
| 49 | Тест В ✅ | открыт как спин-офф WP-47 | 02.01 | P2 | repo2/ | 3h | ⏳ |
| 26 | Снятый | - | 01.01 | P3 | repo3/ | 1h | ⏹ |
| 25 | Спринт | - | 01.01 | P3 | repo4/ | 1h | 🔁 |
REGISTRY

START=$(grep -n '^registry_status_column()' "$SCRIPT_UNDER_TEST" | head -1 | cut -d: -f1)
END_MARKER=$(grep -n '^git_log_for_file()' "$SCRIPT_UNDER_TEST" | head -1 | cut -d: -f1)
if [[ -z "$START" || -z "$END_MARKER" ]]; then
    echo "FAIL: не нашёл границы registry_status()/registry_status_column() — маркеры сдвинулись?"
    exit 1
fi

{
    echo '#!/usr/bin/env bash'
    echo "REGISTRY_FILE=\"$TMP/docs/WP-REGISTRY.md\""
    sed -n "${START},$((END_MARKER - 2))p" "$SCRIPT_UNDER_TEST"
    echo 'echo "47:$(registry_status 47)"'
    echo 'echo "49:$(registry_status 49)"'
    echo 'echo "26:$(registry_status 26)"'
    echo 'echo "25:$(registry_status 25)"'
    echo 'echo "999:$(registry_status 999)"'
    # Codex code review (ход 3, эта же сессия): $num раньше подставлялся в
    # grep без нормализации/валидации — "WP-47" тихо не находил бы строку.
    echo 'echo "WPPREFIX:$(registry_status WP-47)"'
    echo 'echo "BOGUS:$(registry_status abc)"'
} > "$TMP/driver.sh"

OUTPUT=$(bash "$TMP/driver.sh")

check() {
    local wp="$1" expected_substr="$2"
    local got
    got=$(echo "$OUTPUT" | grep "^${wp}:")
    if [[ "$got" == *"$expected_substr"* ]]; then
        echo "PASS: WP-$wp -> $got"
    else
        echo "FAIL: WP-$wp expected to contain '$expected_substr', got '$got'"
        exit 1
    fi
}

check 47 "done"
# The core regression: WP-47's status must not leak into WP-49's lookup just
# because "WP-47" appears inside WP-49's own explanation text.
check 49 "pending"
check 26 "снят"
check 25 "спринт"
check 999 "не в реестре"
check WPPREFIX "done"
check BOGUS "некорректный номер"
