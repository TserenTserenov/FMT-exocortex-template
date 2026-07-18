#!/usr/bin/env bash
# Contract tests for the Codex-to-IWE lifecycle hook adapter.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ADAPTER="$ROOT/.codex/hooks/iwe-hook-adapter.py"
HOOKS_JSON="$ROOT/.codex/hooks.json"
PASS=0

ok() { PASS=$((PASS + 1)); printf 'ok %d - %s\n' "$PASS" "$1"; }
fail() { printf 'not ok %d - %s\n' "$((PASS + 1))" "$1" >&2; exit 1; }

python3 -m json.tool "$HOOKS_JSON" >/dev/null && ok "hooks.json is valid JSON"

python3 - "$HOOKS_JSON" <<'PY' || fail "all required lifecycle events are configured"
import json, sys
events = set(json.load(open(sys.argv[1]))["hooks"])
required = {"SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PreCompact", "Stop"}
assert events == required, (required - events, events - required)
PY
ok "all supported Claude lifecycle equivalents are configured"

OUT=$(printf '%s' '{"hook_event_name":"PreToolUse","session_id":"test","cwd":"'"$ROOT"'","tool_name":"Bash","tool_input":{"command":"git reset --hard HEAD"}}' | python3 "$ADAPTER" PreToolUse)
python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["decision"]=="block" and d["reason"]' <<<"$OUT" \
  && ok "Bash destructive operation is blocked with Codex JSON semantics" \
  || fail "Bash destructive operation is blocked with Codex JSON semantics"

OUT=$(printf '%s' '{"hook_event_name":"UserPromptSubmit","session_id":"test","cwd":"'"$ROOT"'","prompt":"обычная новая задача"}' | python3 "$ADAPTER" UserPromptSubmit)
python3 -c 'import json,sys; d=json.load(sys.stdin); o=d["hookSpecificOutput"]; assert o["hookEventName"]=="UserPromptSubmit" and "WP GATE" in o["additionalContext"]' <<<"$OUT" \
  && ok "Claude additionalContext is wrapped in Codex hookSpecificOutput" \
  || fail "Claude additionalContext is wrapped in Codex hookSpecificOutput"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/hooks"
cat >"$TMP/hooks/extensions-gate.sh" <<'SH'
#!/usr/bin/env bash
P=$(jq -r '.tool_input.file_path // empty')
case "$P" in */memory/protocol-test.md) echo '{"decision":"block","reason":"normalized-path"}' ;; *) echo '{}' ;; esac
SH
OUT=$(printf '%s' '{"hook_event_name":"PreToolUse","session_id":"test","cwd":"'"$ROOT"'","tool_name":"apply_patch","tool_input":{"command":"*** Begin Patch\n*** Update File: memory/protocol-test.md\n@@\n-x\n+y\n*** End Patch"}}' \
  | IWE_CLAUDE_HOOKS="$TMP/hooks" python3 "$ADAPTER" PreToolUse)
python3 -c 'import json,sys; d=json.load(sys.stdin); assert d=={"decision":"block","reason":"normalized-path"}' <<<"$OUT" \
  && ok "apply_patch path is normalized to Claude Write/file_path" \
  || fail "apply_patch path is normalized to Claude Write/file_path"

OUT=$(printf '%s' '{"hook_event_name":"Stop","session_id":"test","cwd":"'"$ROOT"'","stop_hook_active":false,"last_assistant_message":"done"}' \
  | IWE_CLAUDE_HOOKS="$TMP/empty" python3 "$ADAPTER" Stop)
python3 -c 'import json,sys; assert json.load(sys.stdin)=={}' <<<"$OUT" \
  && ok "Stop always emits valid JSON when no continuation is needed" \
  || fail "Stop always emits valid JSON when no continuation is needed"

MEM_ROOT=$(mktemp -d)
mkdir -p "$MEM_ROOT/.codex/iwe-memory"
printf '# Shared marker\nMEMORY-BRIDGE-OK\n' > "$MEM_ROOT/.codex/iwe-memory/MEMORY.md"
OUT=$(printf '%s' '{"hook_event_name":"SessionStart","session_id":"test","cwd":"'"$MEM_ROOT"'"}' \
  | CODEX_PROJECT_DIR="$MEM_ROOT" IWE_CLAUDE_HOOKS="$TMP/empty" python3 "$ADAPTER" SessionStart)
python3 -c 'import json,sys; d=json.load(sys.stdin); assert "MEMORY-BRIDGE-OK" in d["hookSpecificOutput"]["additionalContext"]' <<<"$OUT" \
  && ok "SessionStart injects shared Claude/IWE memory" \
  || fail "SessionStart injects shared Claude/IWE memory"
rm -rf "$MEM_ROOT"

printf '1..%d\n' "$PASS"
