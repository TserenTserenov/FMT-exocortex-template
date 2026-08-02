#!/usr/bin/env bash
# Regression test for bug #340: fmt-critical-alert.sh должен отличить отключённый трекер от "нет задач".
# Проверка: форк с отключённым issue tracker возвращает exit 2 (ошибка), не exit 0 (успех).

set -euo pipefail

# Мок gh API для форка
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

cat > "$TMPDIR/mock-gh.sh" <<'EOF'
#!/bin/bash
# Минимальный мок gh для теста
if [[ "$*" == *"repos/"* ]]; then
  if [[ "$*" == *".has_issues"* ]]; then
    # Форк: has_issues=false (отключён)
    echo '{"has_issues": false}'
  elif [[ "$*" == *".parent"* ]]; then
    # Форк с upstream
    echo '{"parent": {"full_name": "upstream/repo"}}'
  elif [[ "$*" == *"issues"* ]]; then
    # Нет задач (но это не должно быть обработано без проверки has_issues)
    echo '[]'
  fi
else
  echo "ERROR: unexpected gh call: $*" >&2
  exit 2
fi
EOF
chmod +x "$TMPDIR/mock-gh.sh"

# Получить исходный скрипт fmt-critical-alert.sh
ALERT_SCRIPT="${IWE_TEMPLATE:-$HOME/IWE/FMT-exocortex-template}/scripts/fmt-critical-alert.sh"
if [ ! -f "$ALERT_SCRIPT" ]; then
  echo "ERROR: fmt-critical-alert.sh not found" >&2
  exit 1
fi

# Запустить скрипт с мок gh (форк с отключённым трекером)
export REPO="myusername/my-fork"
export PATH="$TMPDIR:$PATH"  # Мок gh будет найден первым
export GH_PAGER=""  # Отключить pager

# Ожидаемое: exit 2 (ошибка: трекер отключён), не exit 0 (успех)
bash "$ALERT_SCRIPT" > "$TMPDIR/output.txt" 2>&1 || EXIT_CODE=$?
EXIT_CODE=${EXIT_CODE:-0}

cat "$TMPDIR/output.txt"

if [ $EXIT_CODE -eq 2 ]; then
  echo ""
  echo "✓ Correctly returned exit 2 for disabled tracker"
elif [ $EXIT_CODE -eq 0 ]; then
  echo ""
  echo "FAIL: Returned exit 0 for disabled tracker (bug #340)" >&2
  exit 1
else
  echo ""
  echo "WARN: Unexpected exit code $EXIT_CODE (expected 0 or 2)" >&2
fi
