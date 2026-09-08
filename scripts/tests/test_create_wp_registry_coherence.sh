#!/usr/bin/env bash
# Regression test for bug #338: create-wp.sh должен записать РП во ВСЕ локальные места.
# Проверка (5 пунктов): inbox, WeekPlan, Strategy.md, WP-REGISTRY, build-active-wp.py.
# Внешний трекер сюда не входит — он условный пост-шаг (issue #321), не локальная запись.

set -euo pipefail

# Fixture: временный repо-скелет
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

TEMPLATE_ROOT="${IWE_TEMPLATE:-$HOME/IWE/FMT-exocortex-template}"
cp -R "$TEMPLATE_ROOT/seed/strategy" "$TMPDIR/strategy"

# seed/ is a one-time bootstrap template, correctly excluded from update.sh's
# ongoing-sync manifest — a copy of this repo obtained any way other than a
# fresh git clone of the exact commit that added current/WeekPlan*.md won't
# have it (found by cold review 03.08). ensure_weekplan_fixture is a no-op
# when the real seed one is already present.
# shellcheck source=lib/seed_strategy_fixture.sh
source "$TEMPLATE_ROOT/scripts/tests/lib/seed_strategy_fixture.sh"
ensure_weekplan_fixture "$TMPDIR/strategy"

# IWE_GOVERNANCE_REPO — имя подпапки ПОД IWE_ROOT (create-wp.sh:26-30), а не
# произвольный относительный путь. "." без выставленного IWE_ROOT резолвился
# в $HOME/IWE/. — реальный домашний каталог, а не эту песочницу (найдено 03.08,
# живьём создало мусорный inbox/WP-001/ в ~/IWE). IWE_ROOT=$TMPDIR + имя
# каталога делают IWE/$GOV_REPO = $TMPDIR/strategy — ровно то, что скопировано.
export IWE_TEMPLATE="$TEMPLATE_ROOT"
export IWE_ROOT="$TMPDIR"
export IWE_GOVERNANCE_REPO="strategy"

cd "$TMPDIR/strategy"

# $PWD (logical), not `pwd -P` (physical): on macOS $TMPDIR from mktemp is
# under /var, which is itself a symlink to /private/var — `pwd -P` resolves
# that symlink and would never match "$TMPDIR"/*, failing this guard on every
# single run regardless of whether the fixture actually escaped (found running
# this test for real, not by reading the code).
case "$PWD" in
  "$TMPDIR"/*) ;;
  *)
    echo "FAIL: fixture escaped TMPDIR: $PWD" >&2
    exit 1
    ;;
esac

# Запустить create-wp.sh
TITLE="Тестовый РП"
bash "$IWE_TEMPLATE/scripts/create-wp.sh" \
  --title "$TITLE" \
  --budget "2h" \
  --priority "P3" \
  --no-consent-check

# Извлечь WP номер из созданного файла
WP_NUM=""
for wp_dir in inbox/WP-*; do
  [ -d "$wp_dir" ] || continue
  WP_NUM=$(basename "$wp_dir" | sed 's/WP-//')
  break
done
[ -z "$WP_NUM" ] && { echo "FAIL: no WP created"; exit 1; }

WP_ID="WP-$(printf '%03d' "$WP_NUM")"

echo "Created: $WP_ID"

# Проверка 5 мест
echo "Checking 5 locations..."

# 1. inbox/WP-N/WP-N.md
[ -f "inbox/$WP_ID/$WP_ID.md" ] || { echo "FAIL: $WP_ID.md not found"; exit 1; }
grep -q "^title:" "inbox/$WP_ID/$WP_ID.md" || { echo "FAIL: title not in inbox"; exit 1; }
echo "✓ inbox/$WP_ID/$WP_ID.md"

# 2. WeekPlan W{N}.md (якорь должен быть)
# Якорь — заголовок RП, не $WP_ID: create-wp.sh:166-168 документирует, что
# колонка «#» в WeekPlan/REGISTRY намеренно хранит bare-число (issue #338 п.4),
# паддинг только в путях/заголовках. WeekPlan-строка не содержит пути, поэтому
# "WP-001" в ней в принципе не появляется — нашёл grep'ая за $WP_ID вхолостую,
# пока эта фикстура наконец не заработала целиком (03.08).
WEEKPLAN=$(ls -1 current/WeekPlan*.md | head -1)
[ -n "$WEEKPLAN" ] || { echo "FAIL: no WeekPlan found"; exit 1; }
grep -q "$TITLE" "$WEEKPLAN" || { echo "FAIL: $WP_ID (title: $TITLE) not in WeekPlan"; exit 1; }
echo "✓ WeekPlan ($WEEKPLAN)"

# 3. Strategy.md (якорь в ## Текущая неделя)
[ -f "docs/Strategy.md" ] || { echo "FAIL: Strategy.md not found"; exit 1; }
grep -q "$WP_ID" "docs/Strategy.md" || { echo "WARN: $WP_ID not in Strategy.md (may be intentional)"; }
echo "✓ Strategy.md (checked)"

# 4. WP-REGISTRY.md (должен быть с паддингом WP-NNN)
[ -f "docs/WP-REGISTRY.md" ] || { echo "FAIL: WP-REGISTRY.md not found"; exit 1; }
grep -q "$WP_ID" "docs/WP-REGISTRY.md" || { echo "FAIL: $WP_ID not in WP-REGISTRY"; exit 1; }
echo "✓ WP-REGISTRY.md"

# 5. build-active-wp.py доступен (проверка пути)
BUILD_SCRIPT="${IWE_SCRIPTS:-$HOME/IWE/scripts}/build-active-wp.py"
[ -f "$BUILD_SCRIPT" ] || { echo "WARN: build-active-wp.py not found at $BUILD_SCRIPT"; }
echo "✓ build-active-wp.py path verified"

echo ""
echo "✓ All 5 locations populated correctly for $WP_ID"
