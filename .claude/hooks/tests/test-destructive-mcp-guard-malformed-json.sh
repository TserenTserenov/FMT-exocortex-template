#!/bin/bash
# test-destructive-mcp-guard-malformed-json.sh — regression corpus for the
# WP-544 Д22 fail-closed fix (08.09, peer session
# 2026-09-08-25-wp544-continue-f7, Codex): a malformed/schema-invalid MCP
# call envelope must deny, not exit 0.
#
# The live fail-open this closes: `jq -r '.tool_name // empty' 2>/dev/null`
# turned any jq parse error into an empty $tool_name, which then missed the
# `mcp__*` case and fell through to `exit 0` — a truncated payload naming
# e.g. `mcp__railway__remove_service` inside broken JSON passed silently.
#
# Запуск: bash .claude/hooks/tests/test-destructive-mcp-guard-malformed-json.sh

set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/destructive-mcp-guard.sh"
TMP_DIR=$(mktemp -d)
PASS=0
FAIL=0

cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT

# expect $1=desc $2=want(deny|pass) $3=raw_stdin_string
expect() {
  local desc="$1" want="$2" raw="$3"
  local out got
  out=$(printf '%s' "$raw" | IWE_ROOT="$TMP_DIR/iwe-root" bash "$HOOK" 2>"$TMP_DIR/err.$$")
  if printf '%s' "$out" | grep -q '"permissionDecision": *"deny"'; then
    got="deny"
  else
    got="pass"
  fi
  if [ "$got" = "$want" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    echo "FAIL: $desc (ожидалось $want, получено $got)"
    echo "  stdout: $out"
    echo "  stderr: $(cat "$TMP_DIR/err.$$" 2>/dev/null)"
  fi
}

# === malformed / schema-invalid envelopes must deny ===
expect "усечённый JSON с mcp__railway__remove_service внутри блокируется" deny \
  '{"tool_name":"mcp__railway__remove_service'

expect "произвольный malformed JSON блокируется" deny \
  '{not even json'

expect "пустой stdin блокируется" deny \
  ''

expect "top-level null блокируется" deny \
  'null'

expect "top-level массив блокируется" deny \
  '[{"tool_name":"mcp__railway__remove_service"}]'

expect "tool_name отсутствует блокируется" deny \
  '{"cwd":"/tmp"}'

expect "tool_name не строка (число) блокируется" deny \
  '{"tool_name":123}'

expect "tool_name пустая строка блокируется" deny \
  '{"tool_name":""}'

# === well-formed envelopes keep working exactly as before ===
expect "валидный неразрушительный MCP-вызов НЕ блокируется" pass \
  '{"tool_name":"mcp__railway__list_services"}'

expect "валидный разрушительный MCP-вызов блокируется" deny \
  '{"tool_name":"mcp__railway__remove_service"}'

expect "не-MCP tool_name НЕ блокируется (матчер вне scope этого хука)" pass \
  '{"tool_name":"Bash"}'

# === отсутствие jq — тоже fail-closed (deny), не fail-open. This script hard-
# codes PATH to standard system dirs on its own (line 15) specifically to
# resist a hijacked PATH — so a PATH edit alone cannot hide jq if it lives in
# one of those dirs. A bash function named `jq`, exported into the child bash
# process, wins command lookup over any PATH entry regardless of that
# hard-coding (functions resolve before external binaries).
jq() { return 127; }
export -f jq
out=$(printf '%s' '{"tool_name":"mcp__railway__list_services"}' \
  | IWE_ROOT="$TMP_DIR/iwe-root-nojq" bash "$HOOK" 2>"$TMP_DIR/err.nojq")
unset -f jq
if printf '%s' "$out" | grep -q '"permissionDecision": *"deny"'; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  echo "FAIL: отсутствие jq на PATH блокирует, а не пропускает"
  echo "  stdout: $out"
  echo "  stderr: $(cat "$TMP_DIR/err.nojq")"
fi

# === сырой payload не попадает в диагностику stderr (может содержать секреты) ===
SECRET_PAYLOAD='{"tool_name":"mcp__x__remove_service","secret":"sk-ant-super-secret-token-do-not-leak"'
printf '%s' "$SECRET_PAYLOAD" | IWE_ROOT="$TMP_DIR/iwe-root" bash "$HOOK" >/dev/null 2>"$TMP_DIR/err.secret" || true
if grep -q "sk-ant-super-secret-token-do-not-leak" "$TMP_DIR/err.secret" 2>/dev/null; then
  FAIL=$((FAIL+1))
  echo "FAIL: сырой payload (секрет) утёк в диагностику stderr"
else
  PASS=$((PASS+1))
fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
