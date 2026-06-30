#!/bin/bash
# verify-manifest.sh — проверяет что update-manifest.json синхронизирован с git tree.
# Использование: bash scripts/verify-manifest.sh
# Exit 0 = манифест актуален. Exit 1 = рассинхрон (показывает diff).
#
# Запускает generate-manifest.sh во временный файл и сравнивает с текущим.
# НЕ изменяет update-manifest.json (read-only, безопасен для CI).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$SCRIPT_DIR/update-manifest.json"
GENERATOR="$SCRIPT_DIR/generate-manifest.sh"

if [ ! -f "$GENERATOR" ]; then
    echo "ERROR: generate-manifest.sh не найден: $GENERATOR"
    exit 2
fi

if [ ! -f "$MANIFEST" ]; then
    echo "ERROR: update-manifest.json не найден: $MANIFEST"
    exit 2
fi

# Сохраняем текущий манифест (read-only backup)
BACKUP=$(mktemp)
trap 'rm -f "$BACKUP"' EXIT
cp "$MANIFEST" "$BACKUP"

# Сохраняем версию из текущего манифеста (generate-manifest.sh берёт из CHANGELOG)
CURRENT_VERSION=$(python3 -c "import json; print(json.load(open('$MANIFEST'))['version'])")

# Создаём временный манифест через generate-manifest.sh
TMP_MANIFEST=$(mktemp)
trap 'rm -f "$BACKUP" "$TMP_MANIFEST"' EXIT

# Генерируем новый манифест во временный файл
bash "$GENERATOR" >/dev/null 2>&1 || true

# Копируем сгенерированный манифест во временный файл
cp "$MANIFEST" "$TMP_MANIFEST"

# Восстанавливаем версию в сгенерированном (CHANGELOG может быть "Unreleased")
python3 -c "
import json
with open('$TMP_MANIFEST') as f:
    data = json.load(f)
data['version'] = '$CURRENT_VERSION'
with open('$TMP_MANIFEST', 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write('\n')
"

# Восстанавливаем оригинальный манифест (generate-manifest.sh его перезаписал)
cp "$BACKUP" "$MANIFEST"

# Сравниваем backup с сгенерированным
if diff -q "$BACKUP" "$TMP_MANIFEST" >/dev/null 2>&1; then
    echo "✅ manifest-verify: update-manifest.json синхронизирован с git tree"
    exit 0
else
    echo "❌ manifest-verify: update-manifest.json НЕ синхронизирован с git tree"
    echo ""
    echo "Diff (current vs generated):"
    diff -u "$BACKUP" "$TMP_MANIFEST" || true
    echo ""
    echo "→ Перегенерируйте манифест: bash generate-manifest.sh"
    echo "→ Проверьте diff: git diff update-manifest.json"
    echo "→ Закоммитьте изменения"
    exit 1
fi
