#!/usr/bin/env bash
# peer-fanout-smoke.sh — smoke test of scripts/peer-fanout.sh on stub adapters.
# No real vendor CLI is called. Temporary directories come from mktemp; no live data is touched.
# Compatibility: /bin/bash 3.2 (macOS).
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FANOUT="$SCRIPT_DIR/../peer-fanout.sh"
[ -f "$FANOUT" ] || { echo "FAIL: peer-fanout.sh not found at $FANOUT"; exit 1; }

PASS=0; FAIL=0
check() { # check <name> <0=ok>
  if [ "$2" -eq 0 ]; then PASS=$((PASS+1)); echo "ok - $1";
  else FAIL=$((FAIL+1)); echo "FAIL - $1"; fi
}

MOCK=$(mktemp -d "${TMPDIR:-/tmp}/fanout-mock.XXXXXX")
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fanout-test.XXXXXX")

# Hanging stubs record their own PID and their sleep child's PID here, so the
# interrupt test can check that exactly those processes are gone.
PID_DIR="$WORK/pids"
mkdir -p "$PID_DIR"
export FANOUT_STUB_PID_DIR="$PID_DIR"
cleanup() {
  for f in "$PID_DIR"/*; do [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null; done
  rm -rf "$MOCK" "$WORK"
}
trap cleanup EXIT

# --- stub adapters: behaviour chosen by a marker in the prompt (stdin) ---
for V in codex claude; do
  cat > "$MOCK/$V-peer-adapter.sh" <<'MOKEOF'
#!/usr/bin/env bash
# stub adapter: reads stdin, behaviour by marker MOCK:<mode>
input=$(cat)
echo "start $(date +%s)" >&2
case "$input" in
  *MOCK:fail*)    echo "mock failure" >&2; exit 1 ;;
  *MOCK:slow*)    sleep 3; echo "slow answer" ;;
  *MOCK:fast*)    echo "fast answer" ;;
  *MOCK:hang*)
    echo $$ > "$(mktemp "$FANOUT_STUB_PID_DIR/stub.XXXXXX")"
    sleep 30 &
    echo $! > "$(mktemp "$FANOUT_STUB_PID_DIR/child.XXXXXX")"
    wait
    echo "should never print" ;;
  *MOCK:empty*)   exit 0 ;;
  *)              sleep 1; echo "answer to: ${input:0:40}" ;;
esac
echo "end $(date +%s)" >&2
exit 0
MOKEOF
  chmod +x "$MOCK/$V-peer-adapter.sh"
done

export IWE_FANOUT_ADAPTERS_DIR="$MOCK"
export IWE_FANOUT_SKIP_CLI_CHECK=1

# 1. two tasks on two stubs -> ok, both .md non-empty, summary ok=2 total=2
printf 't1-codex\tcodex\tAssess risk A in one sentence\nt1-claude\tclaude\tAssess risk B in one sentence\n' > "$WORK/t1.tsv"
out=$(bash "$FANOUT" --tasks "$WORK/t1.tsv" --peer codex,claude --out-dir "$WORK/r1" 2>/dev/null); rc=$?
check "two tasks ok, exit 0" "$rc"
[ -s "$WORK/r1/t1-codex.md" ] && [ -s "$WORK/r1/t1-claude.md" ]; check "both results non-empty" "$?"
echo "$out" | grep -q "^ok=2 total=2 "; check "summary line ok=2 total=2" "$?"
grep -q "answer to: Assess risk B" "$WORK/r1/t1-claude.md"; check "prompt reached the adapter on stdin" "$?"

# 2. parallelism proof: start/end intervals from the stubs' .err overlap
s1=$(grep -oE 'start [0-9]+' "$WORK/r1/t1-codex.err" | awk '{print $2}')
e1=$(grep -oE 'end [0-9]+' "$WORK/r1/t1-codex.err" | awk '{print $2}')
s2=$(grep -oE 'start [0-9]+' "$WORK/r1/t1-claude.err" | awk '{print $2}')
e2=$(grep -oE 'end [0-9]+' "$WORK/r1/t1-claude.err" | awk '{print $2}')
# overlap: s1 < e2 && s2 < e1
if [ -n "$s1" ] && [ -n "$e1" ] && [ -n "$s2" ] && [ -n "$e2" ] && [ "$s1" -lt "$e2" ] && [ "$s2" -lt "$e1" ]; then
  check "intervals overlap (parallel run)" 0
else
  check "intervals overlap (parallel run) - s1=$s1 e1=$e1 s2=$s2 e2=$e2" 1
fi

# 3. failing stub -> exit 2, summary shows error:1, the neighbour result survives
printf 't3-ok\tcodex\tRegular task\nt3-bad\tclaude\tMOCK:fail break\n' > "$WORK/t3.tsv"
out=$(bash "$FANOUT" --tasks "$WORK/t3.tsv" --out-dir "$WORK/r3" 2>/dev/null); rc=$?
[ "$rc" -eq 2 ]; check "failing stub -> exit 2" "$?"
echo "$out" | grep -q "error:1"; check "summary contains error:1" "$?"
[ -s "$WORK/r3/t3-ok.md" ]; check "neighbour result intact" "$?"

# 4. timeout: hanging stub with a 1 s timeout -> status timeout, exit 2
printf 't4-hang\tcodex\tMOCK:hang\nt4-ok\tclaude\tMOCK:fast quick task\n' > "$WORK/t4.tsv"
out=$(IWE_FANOUT_TIMEOUT_SEC=1 bash "$FANOUT" --tasks "$WORK/t4.tsv" --out-dir "$WORK/r4" 2>/dev/null); rc=$?
[ "$rc" -eq 2 ]; check "timeout -> exit 2" "$?"
[ "$(cat "$WORK/r4/t4-hang.status" 2>/dev/null)" = "timeout" ]; check "explicit timeout status" "$?"
[ "$(cat "$WORK/r4/t4-ok.status" 2>/dev/null)" = "ok" ]; check "fast neighbour ok" "$?"

# 5. invalid manifests -> exit 1 before launch (no call made)
bad=0
printf 'dup\tcodex\tTask one\ndup\tclaude\tTask two\n' > "$WORK/b1.tsv"
bash "$FANOUT" --tasks "$WORK/b1.tsv" --out-dir "$WORK/bad1" >/dev/null 2>&1; [ $? -eq 1 ] || bad=1
[ ! -e "$WORK/bad1/dup.md" ] || bad=1
printf 'evil/../x\tcodex\tTask\n' > "$WORK/b2.tsv"
bash "$FANOUT" --tasks "$WORK/b2.tsv" >/dev/null 2>&1; [ $? -eq 1 ] || bad=1
printf 't1\tcodex\tTask with\ta tab\n' > "$WORK/b3.tsv"
bash "$FANOUT" --tasks "$WORK/b3.tsv" >/dev/null 2>&1; [ $? -eq 1 ] || bad=1
printf 't1\thermes\tTask\n' > "$WORK/b4.tsv"
bash "$FANOUT" --tasks "$WORK/b4.tsv" --peer codex,claude >/dev/null 2>&1; [ $? -eq 1 ] || bad=1
check "4 invalid manifests -> exit 1, no calls" "$bad"

# the watchdog must take down the vendor CLI too, not only the adapter
# (a surviving CLI keeps spending tokens after the task is reported as timed out)
alive=0; recorded=0
for f in "$PID_DIR"/*; do
  [ -f "$f" ] || continue
  recorded=$((recorded+1))
  kill -0 "$(cat "$f")" 2>/dev/null && alive=$((alive+1))
done
[ "$recorded" -eq 2 ] && [ "$alive" -eq 0 ]; check "timeout kills the adapter and its CLI child (recorded=$recorded alive=$alive)" "$?"
rm -f "$PID_DIR"/*

# 6. vendor CLI missing from PATH -> exit 1 before launch, the message names the CLI
printf 't6\tcodex\tTask\n' > "$WORK/b6.tsv"
err=$(IWE_FANOUT_SKIP_CLI_CHECK=0 PATH="/usr/bin:/bin" "$BASH" "$FANOUT" --tasks "$WORK/b6.tsv" --out-dir "$WORK/bad6" 2>&1 >/dev/null); rc=$?
if [ -x /usr/bin/codex ] || [ -x /bin/codex ]; then
  check "missing CLI check skipped (codex installed on this host)" 0
else
  [ "$rc" -eq 1 ] && echo "$err" | grep -q "CLI 'codex' not found" && [ ! -e "$WORK/bad6/t6.md" ]
  check "missing vendor CLI -> exit 1 before launch" "$?"
fi

# 7. TERM mid-run: child stubs are dead, a partial summary is written
printf 't7-a\tcodex\tMOCK:hang\nt7-b\tclaude\tMOCK:hang\n' > "$WORK/t7.tsv"
bash "$FANOUT" --tasks "$WORK/t7.tsv" --out-dir "$WORK/r7" > "$WORK/t7.out" 2>/dev/null &
fpid=$!
# wait until both stubs and both sleep children have recorded their PIDs (max 10 s)
n=0
while [ "$(ls "$PID_DIR" | wc -l | tr -d ' ')" -lt 4 ] && [ "$n" -lt 50 ]; do sleep 0.2; n=$((n+1)); done
kill -TERM $fpid
wait $fpid 2>/dev/null; rc=$?
[ "$rc" -eq 2 ]; check "TERM -> exit 2" "$?"
grep -q "fan-out summary (interrupted)" "$WORK/t7.out"; check "partial summary on interrupt" "$?"
sleep 1
alive=0; recorded=0
for f in "$PID_DIR"/*; do
  [ -f "$f" ] || continue
  recorded=$((recorded+1))
  kill -0 "$(cat "$f")" 2>/dev/null && alive=$((alive+1))
done
[ "$recorded" -eq 4 ] && [ "$alive" -eq 0 ]; check "stubs and their children killed down the tree (recorded=$recorded alive=$alive)" "$?"

# 8. user --out-dir holding results -> refused with exit 1
mkdir -p "$WORK/r8"
echo old > "$WORK/r8/t1-codex.md"
bash "$FANOUT" --tasks "$WORK/t1.tsv" --out-dir "$WORK/r8" >/dev/null 2>&1; [ $? -eq 1 ]; check "out-dir with results -> refused" "$?"
[ "$(cat "$WORK/r8/t1-codex.md")" = "old" ]; check "existing result not overwritten" "$?"

# 9. empty stub answer (exit 0, no output) -> error:empty, exit 2
printf 't9-empty\tcodex\tMOCK:empty empty answer\nt9-ok\tclaude\tNormal task\n' > "$WORK/t9.tsv"
bash "$FANOUT" --tasks "$WORK/t9.tsv" --out-dir "$WORK/r9" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ]; check "empty answer -> exit 2" "$?"
[ "$(cat "$WORK/r9/t9-empty.status" 2>/dev/null)" = "error:empty" ]; check "status error:empty" "$?"

# 10. ids that differ only where a regex dot would match -> not duplicates, both run
printf 'axb\tcodex\tMOCK:fast first\na.b\tclaude\tMOCK:fast second\n' > "$WORK/t10.tsv"
out=$(bash "$FANOUT" --tasks "$WORK/t10.tsv" --out-dir "$WORK/r10" 2>/dev/null); rc=$?
check "ids axb and a.b are distinct, exit 0" "$rc"
[ -s "$WORK/r10/axb.md" ] && [ -s "$WORK/r10/a.b.md" ] && echo "$out" | grep -q "^ok=2 total=2 "
check "both axb and a.b produced results" "$?"

echo ""
echo "=== peer-fanout smoke: PASS=$PASS FAIL=$FAIL ==="
[ "$FAIL" -eq 0 ]
