#!/usr/bin/env bash
# Smoke test: make sure the hook blocks writes into SPF but allows them into PACK-X
set -euo pipefail

GUARD="$HOME/IWE/.claude/hooks/pack-creator-spf-guard.sh"

# 1. Pass-through when PACK_CREATOR_ACTIVE is not set
echo '{"tool_name":"Write","file_path":"'"$HOME"'/IWE/SPF/process/00-process-overview.md"}' | \
    bash "$GUARD"
rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL: pass-through нарушен (rc=$rc)"; exit 1; }
echo "✅ Pass-through OK (без PACK_CREATOR_ACTIVE)"

# 2. Block on an attempted write into SPF/
set +e
echo '{"tool_name":"Write","file_path":"'"$HOME"'/IWE/SPF/process/00-process-overview.md"}' | \
    PACK_CREATOR_ACTIVE=1 bash "$GUARD" 2>/dev/null
rc=$?
set -e
[ "$rc" -eq 2 ] || { echo "FAIL: SPF write не заблокирован (rc=$rc)"; exit 1; }
echo "✅ SPF write blocked OK"

# 3. Block on an attempted write into FPF/
set +e
echo '{"tool_name":"Edit","file_path":"'"$HOME"'/IWE/FPF/FPF-Spec.md"}' | \
    PACK_CREATOR_ACTIVE=1 bash "$GUARD" 2>/dev/null
rc=$?
set -e
[ "$rc" -eq 2 ] || { echo "FAIL: FPF write не заблокирован (rc=$rc)"; exit 1; }
echo "✅ FPF write blocked OK"

# 4. Pass-through for a write into PACK-X
echo '{"tool_name":"Write","file_path":"'"$HOME"'/IWE/PACK-test/pack/test/03-methods/TEST.M.001.md"}' | \
    PACK_CREATOR_ACTIVE=1 bash "$GUARD"
rc=$?
[ "$rc" -eq 0 ] || { echo "FAIL: PACK-X write заблокирован (rc=$rc)"; exit 1; }
echo "✅ PACK-X write OK"

# 5. Block on NotebookEdit — the real payload key is "notebook_path", not
# "file_path" (found by adversarial review, 2026-10-06: without this the guard
# silently let every NotebookEdit through, although it itself lists it among
# the protected tools two lines below).
set +e
echo '{"tool_name":"NotebookEdit","notebook_path":"'"$HOME"'/IWE/SPF/process/notebook.ipynb"}' | \
    PACK_CREATOR_ACTIVE=1 bash "$GUARD" 2>/dev/null
rc=$?
set -e
[ "$rc" -eq 2 ] || { echo "FAIL: NotebookEdit в SPF не заблокирован (rc=$rc)"; exit 1; }
echo "✅ NotebookEdit SPF write blocked OK"

# 6. \$CLAUDE_PROJECT_DIR, not \$HOME/IWE — the block must resolve
# the workspace from there when the variable is set (found by the same
# review: a hard-coded \$HOME/IWE is the same class of bug that issue
# #1094 fixes in this same template for route-task.sh).
ALT_ROOT=$(mktemp -d)
mkdir -p "$ALT_ROOT/SPF/process"
set +e
echo '{"tool_name":"Write","file_path":"'"$ALT_ROOT"'/SPF/process/00-process-overview.md"}' | \
    CLAUDE_PROJECT_DIR="$ALT_ROOT" PACK_CREATOR_ACTIVE=1 bash "$GUARD" 2>/dev/null
rc=$?
set -e
rm -rf "$ALT_ROOT"
[ "$rc" -eq 2 ] || { echo "FAIL: CLAUDE_PROJECT_DIR workspace SPF write не заблокирован (rc=$rc)"; exit 1; }
echo "✅ CLAUDE_PROJECT_DIR-resolved SPF write blocked OK"

echo ""
echo "=== ALL TESTS PASSED ==="
