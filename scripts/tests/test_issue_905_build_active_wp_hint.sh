#!/usr/bin/env bash
# Regression coverage for issue #905: build-active-wp.py's regenerate hint
# ("python3 scripts/build-active-wp.py") only resolves from the governance
# repo (ROOT), but on a stock install the script itself lives only inside
# FMT-exocortex-template/scripts/ (the governance repo never receives a
# copy). The hint now reports the script's own real runtime location.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
SCRIPT="$ROOT/scripts/build-active-wp.py"

fail=0
pass() { echo "  ✅ PASS: $*"; }
fail_test() { echo "  ❌ FAIL: $*" >&2; fail=1; }

PYTHON=$(command -v python3 || true)
if [ -z "$PYTHON" ]; then
    echo "SKIP: python3 required"
    exit 0
fi

python3 -c "import ast; ast.parse(open('$SCRIPT').read())" \
    && pass "build-active-wp.py still parses" \
    || fail_test "build-active-wp.py has a syntax error"

# The script's real, on-disk location (FMT-exocortex-template/scripts/...)
# must be what the hint reports when IWE_ROOT/FMT-exocortex-template covers
# it -- this is the exact broken case from the issue (running from the
# governance repo's own tree with the old hardcoded hint).
#
# IWE_ROOT is set explicitly to ROOT's own parent (cold-review finding,
# 24.09): the module's default (Path.home()/"IWE") only happens to match
# when the checkout physically sits at $HOME/IWE/FMT-exocortex-template.
# An isolated worktree copy (this repo's own peer sessions use
# .worktrees/<slug>/FMT-exocortex-template, visible in this very checkout's
# `git status`) would otherwise make the test depend on where it happens to
# run rather than on the fix itself.
HINT=$(IWE_ROOT="$(dirname "$ROOT")" python3 -c "
import importlib.util, sys
spec = importlib.util.spec_from_file_location('bawp_under_test', '$SCRIPT')
m = importlib.util.module_from_spec(spec)
sys.modules['bawp_under_test'] = m
spec.loader.exec_module(m)
print(m._script_invocation_hint())
")

if [[ "$HINT" == "python3 FMT-exocortex-template/scripts/build-active-wp.py" ]]; then
    pass "hint reports the script's real FMT-exocortex-template location: $HINT"
else
    fail_test "expected the FMT-exocortex-template-relative hint, got: $HINT"
fi

if grep -q '_script_invocation_hint()' "$SCRIPT"; then
    pass "both print sites (embedded doc line, --check stderr) route through the shared resolver"
else
    fail_test "resolver helper is not wired into the script's output"
fi

if [ "$fail" -eq 0 ]; then
    echo "✅ test_issue_905_build_active_wp_hint: all checks passed"
fi
exit "$fail"
