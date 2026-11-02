#!/bin/bash
# test-secret-leak-block-heredoc-in-dollar-paren.sh -- issue #760.
#
# parse_heredoc_header() (secret-bypass-analyzer.py) tracks quoting with one
# flat variable and does not know that `$(...)` opens an independent quoting
# context. A heredoc declared inside a still-open outer double quote
# (`echo "$(cat <<'EOF' ... )"`) confuses the flat tracker into producing a
# bogus heredoc declaration further down, and extract_heredocs() then fail()s
# looking for a delimiter line that will never appear -- blocking every Bash
# tool call until the command shape changes (found live closing #760 itself
# in a WP-570 peer session, 2026-09-10; root-caused and fixed in a WP-582
# peer session with Kimi, 2026-09-17).
#
# Fix: analyze_bash() degrades to a literal scan() of the raw text instead of
# letting extract_heredocs()/shell_tokens() fail() the whole call when they
# cannot make sense of the heredoc grammar -- the same "no shell model
# needed" scan already used for ordinary heredoc bodies a few lines below.
#
# This suite checks both layers: the analyzer degrades instead of raising
# (analyze()), and the end-to-end hook still allows the call and still denies
# a genuine secret (hook_decision()).
#
# Run: bash .claude/hooks/tests/test-secret-leak-block-heredoc-in-dollar-paren.sh

set -uo pipefail

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

PASS=0
FAIL=0

# analyze <command> -> "<shell_model>" (only field this suite needs -- did
# the analyzer degrade cleanly or crash trying to build the full model?)
analyze() {
  printf '%s' "$1" | python3 -c '
import json, subprocess, sys
command = sys.stdin.read()
payload = json.dumps({
    "session_id": "test-session",
    "hook_event_name": "PreToolUse",
    "tool_name": "Bash",
    "tool_input": {"command": command},
})
result = subprocess.run(
    ["bash", "-c", ". " + sys.argv[1] + "/secret-bypass-lib.sh; secret_pattern_process analyze-bash"],
    input=payload, capture_output=True, text=True,
)
if result.returncode != 0:
    print("GUARD-FAILURE")
else:
    data = json.loads(result.stdout)
    print(data["shell_model"])
' "$HOOK_DIR"
}

# hook_decision <command> -> "allow" | "deny" | "guard-failure"
hook_decision() {
  printf '%s' "$1" | python3 -c '
import json, sys
command = sys.stdin.read()
print(json.dumps({
    "session_id": "test-session",
    "hook_event_name": "PreToolUse",
    "tool_name": "Bash",
    "tool_input": {"command": command},
}))
' > "$TMP_DIR/envelope.json"
  local code
  bash "$HOOK_DIR/secret-leak-block.sh" < "$TMP_DIR/envelope.json" > "$TMP_DIR/out.json" 2>"$TMP_DIR/err.txt"
  code=$?
  if [ "$code" -ne 0 ]; then
    echo "guard-failure"
  elif grep -q '"permissionDecision": "deny"' "$TMP_DIR/out.json"; then
    echo "deny"
  else
    echo "allow"
  fi
}

check() {  # check <desc> <expected> <actual>
  local desc="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    echo "FAIL: $desc (ожидалось '$want', получено '$got')"
  fi
}

# === 1. Deep repro from the issue history (WP-570, 10.09) -- used to crash
#        analyze-bash entirely (fail() -> guard-failure); now it degrades. ===
# Assembled by concatenation so that the construct itself does not look like a heredoc for
# the script that runs this test.
DEEP_REPRO='echo "$(cat <<'"'"'EOF'"'"'
$ printf '"'"'gh x --body "$(cat <<%sBODY%s\nfoo # bar\nBODY\n)"\n'"'"' "'"'"'" "'"'"'" > /tmp/cmd.txt
EOF
)"'
check "глубокий репро больше не роняет анализатор" "unsupported" "$(analyze "$DEEP_REPRO")"
check "и вызов инструмента при этом разрешён, не заблокирован" "allow" "$(hook_decision "$DEEP_REPRO")"

# === 2. Simple repro from the issue text -- did not crash already (shlex parses
#        as a single token), stays not crashing (regression guard). ===
SIMPLE_REPRO='echo "$(cat <<'"'"'EOF'"'"'
hello
EOF
)"'
check "простой репро из issue не ломается" "allow" "$(hook_decision "$SIMPLE_REPRO")"

# === 3. Plain heredoc with # in the body, unquoted delimiter -- behavior has not
#        changed (# inside a heredoc body is not read as a shell comment). ===
check "heredoc с # в теле (unquoted delimiter) не блокируется" "allow" \
  "$(hook_decision 'cat <<EOF
foo # bar
EOF')"

# === 4. The same, but a quoted delimiter -- an explicit guard at the request of
#        the reviewer (Kimi, turn 5-6 of the session): scan() does not distinguish
#        quoted/unquoted delimiter, the behavior must be the same. ===
check "heredoc с # в теле (quoted delimiter) не блокируется" "allow" \
  "$(hook_decision "cat <<'EOF'
foo # bar
EOF")"

# === 5. Два heredoc на одной строке -- классический многострочный случай,
#        не должен задеваться деградацией. ===
check "два heredoc на одной строке не блокируются" "allow" \
  "$(hook_decision 'cat <<A <<B
bodyA
A
bodyB
B')"

# === 6. Секрет внутри heredoc-тела всё ещё детектится (деградация не
#        глушит обнаружение, только теряет shell-структурную точность). ===
# Собрано конкатенацией по той же причине, что SECRET_READ в соседнем тесте.
FAKE_KEY="AKIA""ABCDEFGHIJKLMNOP"
check "секрет внутри обычного heredoc-тела всё ещё блокируется" "deny" \
  "$(hook_decision "cat <<EOF
AWS_SECRET_ACCESS_KEY=$FAKE_KEY
EOF")"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
