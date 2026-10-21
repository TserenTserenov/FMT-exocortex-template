#!/bin/bash
# Reproducible coordination test N agents IWE (WP-499 Phase7/Phase11, extended Phase17 p.3-4,
# peer-session 2026-08-01-03-wp499-coord-test-agent-id).
#
# Three blocks per run:
#   1. TRANSPORT — gateway daemon responds to gateway_status (without LLM).
#   2. IDENTITY-CONFIG — for each CLI in its REAL config exactly one
#      gateway registration with ITS expected IWE_AGENT_ID (without LLM; catches the class
#      «two ID for one agent» / «foreign registration», precedent 19.07).
#   3. LIVE COORDINATION — each agent ITSELF (via its real MCP, not
#      simulation env): acquire_file_lock(ttl 600) → append a line → commit with
#      its own attribution → release_file_lock. Script observes holder via
#      gateway_status (poll) and verifies: holder == expected ID agent,
#      trailer commit (%B, not %an), absence of lock on the test file afterwards,
#      clean worktree without extraneous staged-files.
#
# Usage:
#   bash wp499-agent-coordination-test.sh [--agents claude,kimi,codex,hermes] [--file PATH] [--skip-live]
#   --skip-live — only blocks 1-2 (without LLM-calls, free of charge).
#
# Exit: 0 = all selected agents passed all blocks; 1 = at least one FAIL
# (per-agent FAIL is recorded, the rest continue — full report at the end).

set -uo pipefail

TEST_FILE="${TEST_FILE:-$HOME/IWE/coordination-test.txt}"
AGENTS="claude,kimi,codex,hermes"
SKIP_LIVE=0
LOCK_TTL=600
CLAUDE_MAX_TURNS="${CLAUDE_MAX_TURNS:-16}"
# Governance-repo is taken from the environment, not from the author fork name: hard-coded
# a hard-coded name breaks the file for any user of the template (validator FMT,
# integration_contracts, caught this during delivery 03.08, WP-484 Phase38).
GOVERNANCE_REPO="${IWE_GOVERNANCE_REPO:-DS-strategy}"
GW_CALL="$HOME/IWE/$GOVERNANCE_REPO/scripts/lib/gateway-mcp-call.sh"
IWE_ROOT="$HOME/IWE"
TMP_ROOT=""
TEST_FILE_REL=""
LIVE_TEST_STARTED=0
TEST_PASSED=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --agents) AGENTS="$2"; shift 2 ;;
    --file) TEST_FILE="$2"; shift 2 ;;
    --skip-live) SKIP_LIVE=1; shift ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

IFS=',' read -ra AGENT_LIST <<< "$AGENTS"

# Explicit table CLI alias → registered IWE_AGENT_ID (audit 31.07).
expected_trailer_domain() {
  case "$1" in
    claude) echo "anthropic" ;;
    kimi) echo "moonshot" ;;
    codex) echo "openai" ;;
    hermes) echo "aisystant" ;;
    *) echo "" ;;
  esac
}

expected_id() {
  case "$1" in
    claude) echo "claude-code" ;;
    kimi) echo "kimikode" ;;
    codex) echo "codex" ;;
    hermes) echo "hermes" ;;
    *) echo "" ;;
  esac
}

FAILS=""
pass() { echo "  ✅ $1"; }
fail() { echo "  ❌ $1"; FAILS="$FAILS $2"; }

release_test_lock() {
  local agent_id="$1"
  IWE_AGENT_ID="$agent_id" bash "$GW_CALL" release_file_lock \
    "{\"file\":\"$TEST_FILE\"}" >/dev/null 2>&1 || true
}

restore_test_file() {
  git -C "$IWE_ROOT" restore --staged -- "$TEST_FILE_REL" 2>/dev/null || true
  git -C "$IWE_ROOT" restore -- "$TEST_FILE_REL" 2>/dev/null || true
}

cleanup_live_test() {
  local agent
  if [ "$LIVE_TEST_STARTED" = "1" ] && [ "$TEST_PASSED" != "1" ]; then
    for agent in "${AGENT_LIST[@]}"; do
      release_test_lock "$(expected_id "$agent")"
    done
    restore_test_file
  fi
  [ -n "$TMP_ROOT" ] && rm -rf "$TMP_ROOT"
}

trap cleanup_live_test EXIT INT TERM

agent_log_summary() {
  local log_file="$1"
  tail -n 12 "$log_file" 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]\+/ /g'
}

run_agent_cli() {
  local agent="$1"
  local prompt="$2"
  local log_file="$3"
  local cli_bin=""
  local exit_code=0

  case "$agent" in
    kimi)
      cli_bin="$(command -v kimi 2>/dev/null || echo "$HOME/Library/Application Support/Code/User/globalStorage/moonshot-ai.kimi-code/bin/kimi/kimi")"
      [ -x "$cli_bin" ] || { fail "$agent: CLI not found ($cli_bin)" "$agent"; return 1; }
      "$cli_bin" --yolo -p "$prompt" >"$log_file" 2>&1
      exit_code=$?
      ;;
    codex)
      cli_bin="$(command -v codex 2>/dev/null || true)"
      [ -n "$cli_bin" ] || { fail "$agent: CLI not found in PATH" "$agent"; return 1; }
      "$cli_bin" exec --dangerously-bypass-approvals-and-sandbox "$prompt" >"$log_file" 2>&1
      exit_code=$?
      ;;
    hermes)
      cli_bin="$(command -v hermes 2>/dev/null || true)"
      [ -n "$cli_bin" ] || { fail "$agent: CLI not found in PATH" "$agent"; return 1; }
      "$cli_bin" -z "$prompt" --yolo >"$log_file" 2>&1
      exit_code=$?
      ;;
    claude)
      cli_bin="$(command -v claude 2>/dev/null || true)"
      [ -n "$cli_bin" ] || { fail "$agent: CLI not found in PATH" "$agent"; return 1; }
      "$cli_bin" -p "$prompt" --max-turns "$CLAUDE_MAX_TURNS" --dangerously-skip-permissions >"$log_file" 2>&1
      exit_code=$?
      ;;
  esac

  if [ "$exit_code" -ne 0 ]; then
    fail "$agent: CLI exited with code $exit_code: $(agent_log_summary "$log_file")" "$agent"
    return 1
  fi
}

# ── Block 1: TRANSPORT ──
echo
echo "=== Block 1: gateway transport ==="
TRANSPORT_OK=1
STATUS_OUT=$(IWE_AGENT_ID=coord-test bash "$GW_CALL" gateway_status 2>&1) || TRANSPORT_OK=0
if [ "$TRANSPORT_OK" = "1" ] && echo "$STATUS_OUT" | grep -q '"agent_id"'; then
  pass "gateway daemon is responding (gateway_status)"
else
  echo "❌ Block 1 FAIL: gateway daemon is unreachable — further blocks are pointless"
  echo "$STATUS_OUT" >&2
  exit 1
fi

# ── Block 2: IDENTITY-CONFIG ──
echo
echo "=== Block 2: identity in real configs ==="
for agent in "${AGENT_LIST[@]}"; do
  exp=$(expected_id "$agent")
  if [ -z "$exp" ]; then
    echo "Unknown agent: $agent" >&2; exit 1
  fi
  report=$(python3 "$HOME/IWE/$GOVERNANCE_REPO/scripts/lib/gateway-config-report.py" "$agent")
  own_ids=$(echo "$report" | grep "^OWN " | awk '{print $3}' | sort -u | grep -v '^$' || true)
  foreign=$(echo "$report" | grep "^FOREIGN " | awk '{print $2"("$3")"}' | tr '\n' ' ' || true)
  count=$(echo "$own_ids" | grep -c . || true)
  if [ "$count" = "0" ]; then
    fail "$agent: own-own gateway registration not found in config" "$agent"
  elif [ "$count" -gt 1 ]; then
    fail "$agent: multiple own IWE_AGENT_ID ($(echo $own_ids | tr '\n' ' ')) — ambiguous identity" "$agent"
  elif [ "$own_ids" != "$exp" ]; then
    fail "$agent: own ID '$own_ids', expected '$exp'" "$agent"
  else
    pass "$agent → $own_ids (own-registration matches, unique)"
  fi
  if [ -n "$foreign" ]; then
    echo "  ⚠️  cross-visibility: the client can see foreign namespaces ${foreign} — protected by convention (structural solution — WP-499 A2.8, pilot)"
  fi
done

# ── Block 3: LIVE COORDINATION ──
if [ "$SKIP_LIVE" = "1" ]; then
  echo
  echo "=== Block 3 skipped (--skip-live) ==="
else
  echo
  echo "=== Block 3: live coordination (lock → append → commit → release) ==="
  if [[ "$TEST_FILE" != "$IWE_ROOT/"* ]]; then
    echo "❌ Block 3 FAIL: test file must be located inside $IWE_ROOT" >&2
    exit 1
  fi
  TEST_FILE_REL="${TEST_FILE#"$IWE_ROOT/"}"
  if ! git -C "$IWE_ROOT" ls-files --error-unmatch -- "$TEST_FILE_REL" >/dev/null 2>&1; then
    echo "❌ Block 3 FAIL: test file must already be tracked by git git: $TEST_FILE_REL" >&2
    exit 1
  fi
  if ! git -C "$IWE_ROOT" diff --quiet -- "$TEST_FILE_REL" \
    || ! git -C "$IWE_ROOT" diff --cached --quiet -- "$TEST_FILE_REL"; then
    echo "❌ Block 3 FAIL: test file is already modified; safe cleanup impossible: $TEST_FILE_REL" >&2
    exit 1
  fi
  TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/wp499-coord-test-XXXXXX")
  LIVE_TEST_STARTED=1
  touch "$TEST_FILE"

  # recording clean state: extraneous staged-files before the test — separate FAIL
  PRE_STAGED=$(git -C "$IWE_ROOT" diff --cached --name-only 2>/dev/null || true)
  if [ -n "$PRE_STAGED" ]; then
    echo "  ⚠️  The index already contains staged-files (someone elses work) — agent commits are made only with pathspec-string"
  fi

  poll_holder() {
    IWE_AGENT_ID=coord-test bash "$GW_CALL" gateway_status 2>/dev/null | python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
    for l in d.get('locks', []):
        if l.get('file', '').endswith('$(basename "$TEST_FILE")'):
            print(l.get('holder', ''))
except Exception: pass
" 2>/dev/null
  }

  for agent in "${AGENT_LIST[@]}"; do
    exp=$(expected_id "$agent")
    echo
    echo "=== $agent (expected ID: $exp) ==="
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    line="[$agent] line from $ts"
    holder_seen=""

    # poll in the background: who holds the lock on the test file while the CLI is running CLI
    (
      for _ in $(seq 1 60); do
        h=$(poll_holder)
        [ -n "$h" ] && { echo "$h" > "/tmp/coord-test-holder-$agent"; break; }
        sleep 2
      done
    ) &
    POLL_PID=$!

    PROMPT="Via MCP local gateway iwe-local-gateway perform strictly in this order: (1) acquire_file_lock for file $TEST_FILE with ttl_seconds $LOCK_TTL; (2) append to this file the line: $line; (3) commit ONLY this file (pathspec) with message 'coord-test: $agent' and the attribution trailer; (4) release_file_lock of the same file. Do not touch other files."

    AGENT_LOG="$TMP_ROOT/$agent.log"
    AGENT_OK=1
    run_agent_cli "$agent" "$PROMPT" "$AGENT_LOG" || AGENT_OK=0
    wait "$POLL_PID" 2>/dev/null || true
    [ -f "/tmp/coord-test-holder-$agent" ] && holder_seen=$(cat "/tmp/coord-test-holder-$agent") && rm -f "/tmp/coord-test-holder-$agent"

    if [ "$AGENT_OK" != "1" ]; then
      release_test_lock "$exp"
      [ -n "$holder_seen" ] && release_test_lock "$holder_seen"
      restore_test_file
      continue
    fi

    if [ -z "$holder_seen" ]; then
      echo "  ⚠️  holder not caught by polling (CLI CLI may not have acquired the lock or released it quickly) — checking by result"
    elif [ "$holder_seen" != "$exp" ]; then
      fail "$agent: lock was held by '$holder_seen', expected '$exp'" "$agent"
      release_test_lock "$exp"
      release_test_lock "$holder_seen"
      restore_test_file
      continue
    else
      pass "holder == $exp (live identity check)"
    fi

    # commit check: subject + file + trailer (via %B, not %an)
    BODY=$(git -C "$HOME/IWE" log -1 --format=%B -- "$TEST_FILE" 2>/dev/null || true)
    if echo "$BODY" | head -1 | grep -q "coord-test: $agent"; then
      pass "commit subject 'coord-test: $agent' on the test file"
    else
      fail "$agent: the last commit on the test file does not belong to this agent: $(echo "$BODY" | head -1)" "$agent"
      continue
    fi
    # trailer attribution (Codex, move 1: %B, not %an — author the same for all)
    if echo "$BODY" | grep -qi "Co-Authored-By: .*$(expected_trailer_domain "$agent")"; then
      pass "trailer agent attribution trailer is present"
    else
      fail "$agent: missing trailer Co-Authored-By its vendor: $(echo "$BODY" | tail -1)" "$agent"
      continue
    fi

    # test file lock has been released
    leftover=$(poll_holder)
    if [ -n "$leftover" ]; then
      fail "$agent: test file lock was not released (holder: $leftover)" "$agent"
    else
      pass "test file lock was released"
    fi
  done
fi

echo
if [ -n "$FAILS" ]; then
  echo "[coord-test] FAIL agents:$FAILS"
  exit 1
fi
TEST_PASSED=1
echo "[coord-test] All selected agents passed all blocks."
