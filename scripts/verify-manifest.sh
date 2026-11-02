#!/bin/bash
# verify-manifest.sh — checks that update-manifest.json is in sync with the git tree.
# Usage: bash scripts/verify-manifest.sh
# Exit 0 = manifest is current. Exit 1 = out of sync (shows diff).
#
# Runs generate-manifest.sh into a temporary file and compares with the current one.
# Does NOT modify update-manifest.json (read-only, safe for CI).

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

# Save the current manifest (read-only backup)
BACKUP=$(mktemp)
trap 'rm -f "$BACKUP"' EXIT
cp "$MANIFEST" "$BACKUP"

# Save the version from the current manifest (generate-manifest.sh takes it from CHANGELOG)
CURRENT_VERSION=$(python3 -c "import json; print(json.load(open('$MANIFEST'))['version'])")

# Create a temporary manifest via generate-manifest.sh
TMP_MANIFEST=$(mktemp)
trap 'rm -f "$BACKUP" "$TMP_MANIFEST"' EXIT

# Generate a new manifest into a temporary file.
# 2026-08-22 (Codex peer-review): it used to be `|| true` — a generator failure
# was swallowed, and the comparison below could pass against the OLD manifest (fail-open in
# a check declared fail-closed). Now any generator failure = check error;
# the original manifest is restored before exit.
if ! bash "$GENERATOR" >/dev/null 2>&1; then
    cp "$BACKUP" "$MANIFEST"
    echo "❌ manifest-verify: generate-manifest.sh завершился с ошибкой — проверка невозможна (fail-closed)"
    exit 1
fi

# Copy the generated manifest to a temporary file
cp "$MANIFEST" "$TMP_MANIFEST"

# Restore the version in the generated one (CHANGELOG may say "Unreleased")
python3 -c "
import json
with open('$TMP_MANIFEST') as f:
    data = json.load(f)
data['version'] = '$CURRENT_VERSION'
with open('$TMP_MANIFEST', 'w') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write('\n')
"

# Restore the original manifest (generate-manifest.sh overwrote it)
cp "$BACKUP" "$MANIFEST"

# 2026-08-22 (external report, live 10-file deletion): deprecated_files must
# never intersect the delivered set OR the git-tracked tree — update.sh would
# delete files the canon still ships with every fresh clone. generate-manifest
# filters this at write time; this check fails closed on a bad committed one.
DEP_CONFLICTS=$(python3 - "$MANIFEST" "$SCRIPT_DIR" <<'PYCHECK'
import json, subprocess, sys
m = json.load(open(sys.argv[1]))
repo_root = sys.argv[2]
delivered = {e['path'] for e in m.get('files', [])}
excluded = set(m.get('excluded_paths', []))
# 2026-08-22 (Codex peer-review): git ls-files без проверки кода возврата —
# при сбое git множество tracked молча становилось пустым, и проверка
# «deprecated ∩ дерево» деградировала fail-open. Теперь сбой git = сбой проверки.
# 2026-08-28: git ls-files without cwd=repo_root ran against the invoker's
# ambient working directory — a caller invoking this script by absolute path
# from outside the repo silently got a wrong (often empty or foreign) tracked
# set, turning "deprecated ∩ tree" into either a false pass or a false conflict.
r = subprocess.run(['git', 'ls-files'], capture_output=True, text=True, cwd=repo_root)
if r.returncode != 0:
    sys.exit('git ls-files failed: ' + r.stderr.strip())
tracked = set(r.stdout.splitlines())
# WP-7 Ф92: mirrors generate-manifest.sh — a files[] → excluded_paths[] move
# stays deprecated (cleanup for pilots who got it while still delivered) only
# when the entry itself is marked excluded_confirmed, not just by being tracked.
bad = [
    e['path'] for e in m.get('deprecated_files', [])
    if e.get('path') in delivered
    or (e.get('path') in tracked and not (e.get('excluded_confirmed') and e.get('path') in excluded))
]
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

# 2026-08-23 (v0.38.7 matrix, finding 4): a watchdog that is delivered without
# its required data file fails on an install from the manifest — CI
# did not see this, because it runs in a full checkout. Paired deliveries
# are declared explicitly; each pair is delivered either entirely or not at all.
PAIRED_DELIVERY="scripts/check-python-resolver-contract.sh=scripts/tests/fixtures/python-resolver-baseline.txt"
for pair in $PAIRED_DELIVERY; do
    tool="${pair%%=*}"; datafile="${pair#*=}"
    # Both sides of the pair are counted by files[] (what is delivered), not by the whole JSON:
    # a tool deliberately taken out of delivery makes the pair vacuous,
    # not falsely violated.
    t=$(python3 - "$MANIFEST" "$tool" <<'PYCHK'
import json, sys
m = json.load(open(sys.argv[1]))
print(sum(1 for e in m.get('files', []) if e['path'] == sys.argv[2]))
PYCHK
)
    d=$(python3 - "$MANIFEST" "$datafile" <<'PYCHK'
import json, sys
m = json.load(open(sys.argv[1]))
print(sum(1 for e in m.get('files', []) if e['path'] == sys.argv[2]))
PYCHK
)
    if [ "$t" -ge 1 ] && [ "$d" -eq 0 ]; then
        echo "❌ manifest-verify: $tool доставляется без обязательного $datafile (парная поставка нарушена)"
        exit 1
    fi
done

# Compare the backup with the generated one
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
