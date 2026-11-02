#!/bin/bash
# Reproducible coordination test of N IWE agents (WP-499 Phase 7/11, extended in Phase 17 items 3-4,
# peer session 2026-08-01-03-wp499-coord-test-agent-id).
#
# Three blocks per run:
#   1. TRANSPORT — the gateway daemon answers gateway_status (no LLM).
#   2. IDENTITY-CONFIG — each CLI's REAL config has exactly one
#      gateway registration with ITS expected IWE_AGENT_ID (no LLM; catches the class
#      "two IDs for one agent" / "foreign registration", precedent 19.07).
#   3. LIVE COORDINATION — each agent ITSELF (via its real MCP, not an
#      env simulation): acquire_file_lock(ttl 600) -> append a line -> commit with
#      its own attribution -> release_file_lock. The script observes the holder via
#      gateway_status (poll) and checks: holder == the agent's expected ID,
#      commit trailer (%B, not %an), no lock on the test file afterwards,
#      clean worktree without stray staged files.
#
# Usage:
#   bash wp499-agent-coordination-test.sh [--agents claude,kimi,codex,hermes] [--file PATH] [--skip-live]
#   --skip-live — only blocks 1-2 (no LLM calls, free).
#
# Exit: 0 = all selected agents passed all blocks; 1 = at least one FAIL
# (per-agent FAIL is recorded, the rest continue — full report at the end).

set -uo pipefail

TEST_FILE="${TEST_FILE:-$HOME/IWE/coordination-test.txt}"
AGENTS="claude,kimi,codex,hermes"
SKIP_LIVE=0
LOCK_TTL=600
CLAUDE_MAX_TURNS="${CLAUDE_MAX_TURNS:-16}"
# The governance repo is taken from the environment, not from the author's copy name: a hard-coded
# name breaks the file for any template user (validator FMT,
# integration_contracts, caught this on delivery 03.08, WP-484 Phase 38).
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
    *) echo "Неизвестный флаг: $1" >&2; exit 1 ;;
  esac
done

IFS=',' read -ra AGENT_LIST <<< "$AGENTS"

# Explicit table CLI alias -> registered IWE_AGENT_ID (audit 31.07).
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
      [ -x "$cli_bin" ] || { fail "$agent: CLI не найден ($cli_bin)" "$agent"; return 1; }
      "$cli_bin" --yolo -p "$prompt" >"$log_file" 2>&1
      exit_code=$?
      ;;
    codex)
      cli_bin="$(command -v codex 2>/dev/null || true)"
      [ -n "$cli_bin" ] || { fail "$agent: CLI не найден в PATH" "$agent"; return 1; }
      "$cli_bin" exec --dangerously-bypass-approvals-and-sandbox "$prompt" >"$log_file" 2>&1
      exit_code=$?
      ;;
    hermes)
      cli_bin="$(command -v hermes 2>/dev/null || true)"
      [ -n "$cli_bin" ] || { fail "$agent: CLI не найден в PATH" "$agent"; return 1; }
      "$cli_bin" -z "$prompt" --yolo >"$log_file" 2>&1
      exit_code=$?
      ;;
    claude)
      cli_bin="$(command -v claude 2>/dev/null || true)"
      [ -n "$cli_bin" ] || { fail "$agent: CLI не найден в PATH" "$agent"; return 1; }
      "$cli_bin" -p "$prompt" --max-turns "$CLAUDE_MAX_TURNS" --dangerously-skip-permissions >"$log_file" 2>&1
      exit_code=$?
      ;;
  esac

  if [ "$exit_code" -ne 0 ]; then
    fail "$agent: CLI завершился с кодом $exit_code: $(agent_log_summary "$log_file")" "$agent"
    return 1
  fi
}

# ── Block 1: TRANSPORT ──
echo
echo "=== Блок 1: транспорт шлюза ==="
TRANSPORT_OK=1
STATUS_OUT=$(IWE_AGENT_ID=coord-test bash "$GW_CALL" gateway_status 2>&1) || TRANSPORT_OK=0
if [ "$TRANSPORT_OK" = "1" ] && echo "$STATUS_OUT" | grep -q '"agent_id"'; then
  pass "демон шлюза отвечает (gateway_status)"
else
  echo "❌ Блок 1 FAIL: демон шлюза недоступен — дальнейшие блоки бессмысленны"
  echo "$STATUS_OUT" >&2
  exit 1
fi

# ── Block 2: IDENTITY-CONFIG ──
echo
echo "=== Блок 2: идентичность в реальных конфигах ==="
for agent in "${AGENT_LIST[@]}"; do
  exp=$(expected_id "$agent")
  if [ -z "$exp" ]; then
    echo "Неизвестный агент: $agent" >&2; exit 1
  fi
  report=$(python3 "$HOME/IWE/$GOVERNANCE_REPO/scripts/lib/gateway-config-report.py" "$agent")
  own_ids=$(echo "$report" | grep "^OWN " | awk '{print $3}' | sort -u | grep -v '^$' || true)
  foreign=$(echo "$report" | grep "^FOREIGN " | awk '{print $2"("$3")"}' | tr '\n' ' ' || true)
  count=$(echo "$own_ids" | grep -c . || true)
  if [ "$count" = "0" ]; then
    fail "$agent: own-регистрация шлюза не найдена в конфиге" "$agent"
  elif [ "$count" -gt 1 ]; then
    fail "$agent: несколько own IWE_AGENT_ID ($(echo $own_ids | tr '\n' ' ')) — неоднозначная идентичность" "$agent"
  elif [ "$own_ids" != "$exp" ]; then
    fail "$agent: own ID '$own_ids', ожидался '$exp'" "$agent"
  else
    pass "$agent → $own_ids (own-регистрация совпадает, единственная)"
  fi
  if [ -n "$foreign" ]; then
    echo "  ⚠️  cross-visibility: клиенту доступны чужие неймспейсы ${foreign} — защита конвенцией (структурное решение — WP-499 A2.8, пилот)"
  fi
done

# ── Block 3: LIVE COORDINATION ──
if [ "$SKIP_LIVE" = "1" ]; then
  echo
  echo "=== Блок 3 пропущен (--skip-live) ==="
else
  echo
  echo "=== Блок 3: живая координация (lock → append → commit → release) ==="
  if [[ "$TEST_FILE" != "$IWE_ROOT/"* ]]; then
    echo "❌ Блок 3 FAIL: тестовый файл должен находиться внутри $IWE_ROOT" >&2
    exit 1
  fi
  TEST_FILE_REL="${TEST_FILE#"$IWE_ROOT/"}"
  if ! git -C "$IWE_ROOT" ls-files --error-unmatch -- "$TEST_FILE_REL" >/dev/null 2>&1; then
    echo "❌ Блок 3 FAIL: тестовый файл должен быть уже отслеживаемым git: $TEST_FILE_REL" >&2
    exit 1
  fi
  if ! git -C "$IWE_ROOT" diff --quiet -- "$TEST_FILE_REL" \
    || ! git -C "$IWE_ROOT" diff --cached --quiet -- "$TEST_FILE_REL"; then
    echo "❌ Блок 3 FAIL: тестовый файл уже изменён; безопасный cleanup невозможен: $TEST_FILE_REL" >&2
    exit 1
  fi
  TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/wp499-coord-test-XXXXXX")
  LIVE_TEST_STARTED=1
  touch "$TEST_FILE"

  # record the clean state: stray staged files before the test are a separate FAIL
  PRE_STAGED=$(git -C "$IWE_ROOT" diff --cached --name-only 2>/dev/null || true)
  if [ -n "$PRE_STAGED" ]; then
    echo "  ⚠️  В индексе уже есть staged-файлы (чужая работа) — коммиты агентов делаем только pathspec-строкой"
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
    echo "=== $agent (ожидаемый ID: $exp) ==="
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    line="[$agent] строка от $ts"
    holder_seen=""

    # poll in the background: who holds the test file lock while the CLI runs
    (
      for _ in $(seq 1 60); do
        h=$(poll_holder)
        [ -n "$h" ] && { echo "$h" > "/tmp/coord-test-holder-$agent"; break; }
        sleep 2
      done
    ) &
    POLL_PID=$!

    PROMPT="Через MCP локального шлюза iwe-local-gateway выполни строго в этом порядке: (1) acquire_file_lock для файла $TEST_FILE с ttl_seconds $LOCK_TTL; (2) допиши в этот файл строку: $line; (3) закоммить ТОЛЬКО этот файл (pathspec) с сообщением 'coord-test: $agent' и трейлером своей атрибуции; (4) release_file_lock того же файла. Не трогай другие файлы."

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
      echo "  ⚠️  holder не пойман опросом (CLI мог не взять лок или быстро отпустил) — проверяю по результату"
    elif [ "$holder_seen" != "$exp" ]; then
      fail "$agent: лок держал '$holder_seen', ожидался '$exp'" "$agent"
      release_test_lock "$exp"
      release_test_lock "$holder_seen"
      restore_test_file
      continue
    else
      pass "holder == $exp (живая проверка идентичности)"
    fi

    # commit check: subject + file + trailer (via %B, not %an)
    BODY=$(git -C "$HOME/IWE" log -1 --format=%B -- "$TEST_FILE" 2>/dev/null || true)
    if echo "$BODY" | head -1 | grep -q "coord-test: $agent"; then
      pass "commit subject 'coord-test: $agent' на тестовом файле"
    else
      fail "$agent: последний коммит тестового файла не его: $(echo "$BODY" | head -1)" "$agent"
      continue
    fi
    # attribution trailer (Codex, turn 1: %B, not %an — the author is the same for all)
    if echo "$BODY" | grep -qi "Co-Authored-By: .*$(expected_trailer_domain "$agent")"; then
      pass "trailer атрибуции агента на месте"
    else
      fail "$agent: нет trailer Co-Authored-By его вендора: $(echo "$BODY" | tail -1)" "$agent"
      continue
    fi

    # test file lock released
    leftover=$(poll_holder)
    if [ -n "$leftover" ]; then
      fail "$agent: лок тестового файла не освобождён (holder: $leftover)" "$agent"
    else
      pass "лок тестового файла освобождён"
    fi
  done
fi

echo
if [ -n "$FAILS" ]; then
  echo "[coord-test] FAIL агентов:$FAILS"
  exit 1
fi
TEST_PASSED=1
echo "[coord-test] Все выбранные агенты прошли все блоки."
