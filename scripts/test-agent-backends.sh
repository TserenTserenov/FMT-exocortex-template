#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/codex" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$MOCK_ARGS"
prompt="$(cat)"
printf '%s' "$prompt" > "$MOCK_PROMPT"
while [ $# -gt 0 ]; do
  if [ "$1" = "--output-last-message" ]; then printf 'codex-result' > "$2"; break; fi
  shift
done
MOCK
cat > "$TMP/claude" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$MOCK_ARGS"
printf 'claude-result'
MOCK
chmod +x "$TMP/codex" "$TMP/claude"

export MOCK_ARGS="$TMP/args" MOCK_PROMPT="$TMP/prompt"
result="$(printf 'safe prompt' | IWE_AGENT_PROVIDER=codex IWE_CODEX_BIN="$TMP/codex" \
  IWE_AGENT_WORKDIR="$ROOT" bash "$ROOT/scripts/iwe-agent-exec.sh")"
[ "$result" = "codex-result" ]
grep -Fx -- 'exec' "$MOCK_ARGS" >/dev/null
grep -Fx -- '--sandbox' "$MOCK_ARGS" >/dev/null
grep -Fx -- 'workspace-write' "$MOCK_ARGS" >/dev/null
grep -Fx -- '--json' "$MOCK_ARGS" >/dev/null
grep -Fx -- '--output-last-message' "$MOCK_ARGS" >/dev/null
! grep -q 'dangerously\|bypass' "$MOCK_ARGS"
[ "$(cat "$MOCK_PROMPT")" = "safe prompt" ]

result="$(printf 'legacy prompt' | IWE_AGENT_PROVIDER=claude IWE_CLAUDE_BIN="$TMP/claude" \
  IWE_AGENT_MODEL=sonnet bash "$ROOT/scripts/iwe-agent-exec.sh")"
[ "$result" = "claude-result" ]
grep -Fx -- '-p' "$MOCK_ARGS" >/dev/null
grep -Fx -- '--model' "$MOCK_ARGS" >/dev/null
grep -Fx -- 'sonnet' "$MOCK_ARGS" >/dev/null

PYTHONPATH="$ROOT/scripts" IWE_AGENT_PROVIDER=codex IWE_CODEX_BIN="$TMP/codex" \
  python3 - <<'PY'
from pathlib import Path
from iwe_agent_backend import invoke, provider_model
assert provider_model("medium", "claude") == "sonnet"
assert provider_model("medium", "codex") == ""
ok, output = invoke("python prompt", "medium", Path.cwd(), provider="codex")
assert ok and output == "codex-result", (ok, output)
PY

echo "PASS: Claude/Codex headless backends"
