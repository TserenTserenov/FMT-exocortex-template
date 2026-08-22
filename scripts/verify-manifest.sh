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

# 2026-08-22 (external report, live 10-file deletion): deprecated_files must
# never intersect the delivered set OR the git-tracked tree — update.sh would
# delete files the canon still ships with every fresh clone. generate-manifest
# filters this at write time; this check fails closed on a bad committed one.
DEP_CONFLICTS=$(python3 - "$MANIFEST" <<'PYCHECK'
import json, subprocess, sys
m = json.load(open(sys.argv[1]))
delivered = {e['path'] for e in m.get('files', [])}
tracked = set(subprocess.run(['git', 'ls-files'], capture_output=True, text=True).stdout.splitlines())
bad = [e['path'] for e in m.get('deprecated_files', []) if e.get('path') in delivered or e.get('path') in tracked]
print('\n'.join(bad))
PYCHECK
)
if [ -n "$DEP_CONFLICTS" ]; then
    echo "❌ manifest-verify: deprecated_files пересекается с поставкой/деревом git:"
    printf '  %s
' $DEP_CONFLICTS
    echo "→ Либо файл больше не deprecated (убери запись), либо удали его из дерева (git rm)"
    exit 1
fi

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
