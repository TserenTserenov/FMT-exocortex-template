#!/usr/bin/env bash
set -euo pipefail

# issue #463: pyyaml was never declared as a dependency. On a clean
# interpreter without it, memory-drift-scan.py died with a bare
# ModuleNotFoundError, and day-close.sh's inline `python3 -c "import
# yaml..." 2>/dev/null || echo ""` snippets silently returned empty output —
# indistinguishable from "field genuinely absent". This test shadows the
# real `yaml` module with one that always raises ImportError, to reproduce
# a machine without pyyaml, and checks both scripts now say so explicitly.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/fakelib"
cat > "$TMP/fakelib/yaml.py" <<'PY'
raise ImportError("mocked: No module named 'yaml'")
PY

if [[ ! -f "$ROOT/requirements.txt" ]] || ! grep -qi '^pyyaml' "$ROOT/requirements.txt"; then
    echo "FAIL (1/2): requirements.txt отсутствует или не декларирует pyyaml"
    exit 1
fi
echo "PASS (1/2): requirements.txt декларирует pyyaml"

set +e
OUTPUT=$(PYTHONPATH="$TMP/fakelib" python3 "$ROOT/.claude/scripts/memory-drift-scan.py" --memory /nonexistent 2>&1)
CODE=$?
set -e

if [[ "$CODE" -eq 0 ]]; then
    echo "FAIL (2/2): memory-drift-scan.py не упал без pyyaml"
    exit 1
fi
if echo "$OUTPUT" | grep -qi "pyyaml не найден"; then
    echo "PASS (2/2): memory-drift-scan.py даёт понятную диагностику без pyyaml"
else
    echo "FAIL (2/2): memory-drift-scan.py упал без понятного сообщения про pyyaml"
    echo "$OUTPUT"
    exit 1
fi
