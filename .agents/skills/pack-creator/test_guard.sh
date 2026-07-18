#!/usr/bin/env bash
# Smoke test: убедиться что hook блокирует write в SPF, но пропускает в PACK-X
set -euo pipefail

GUARD="$HOME/IWE/.claude/hooks/pack-creator-spf-guard.sh"

# 1. Pass-through когда PACK_CREATOR_ACTIVE не установлен
echo '{"tool_name":"Write","file_path":"'"$HOME"'/IWE/SPF/process/00-process-overview.md"}' | \
    bash "$GUARD"
rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL: pass-through нарушен (rc=$rc)"; exit 1; }
echo "✅ Pass-through OK (без PACK_CREATOR_ACTIVE)"

# 2. Block при попытке write в SPF/
set +e
echo '{"tool_name":"Write","file_path":"'"$HOME"'/IWE/SPF/process/00-process-overview.md"}' | \
    PACK_CREATOR_ACTIVE=1 bash "$GUARD" 2>/dev/null
rc=$?
set -e
[ "$rc" -eq 2 ] || { echo "FAIL: SPF write не заблокирован (rc=$rc)"; exit 1; }
echo "✅ SPF write blocked OK"

# 3. Block при попытке write в FPF/
set +e
echo '{"tool_name":"Edit","file_path":"'"$HOME"'/IWE/FPF/FPF-Spec.md"}' | \
    PACK_CREATOR_ACTIVE=1 bash "$GUARD" 2>/dev/null
rc=$?
set -e
[ "$rc" -eq 2 ] || { echo "FAIL: FPF write не заблокирован (rc=$rc)"; exit 1; }
echo "✅ FPF write blocked OK"

# 4. Pass-through для write в PACK-X
echo '{"tool_name":"Write","file_path":"'"$HOME"'/IWE/PACK-test/pack/test/03-methods/TEST.M.001.md"}' | \
    PACK_CREATOR_ACTIVE=1 bash "$GUARD"
rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL: PACK-X write заблокирован (rc=$rc)"; exit 1; }
echo "✅ PACK-X write OK"

echo ""
echo "=== ALL TESTS PASSED ==="
