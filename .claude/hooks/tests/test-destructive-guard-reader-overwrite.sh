#!/bin/bash
# test-destructive-guard-reader-overwrite.sh — issue #1568, F2 of the v0.42.0 red team: readers
# pre-approved in settings.json (grep, ls, head, tail, diff …) with an empty output emptied a
# working file through `>` without a prompt; only `cat /dev/null > f` and `head -c0 > f` were
# known. The class: a truncating redirection after a pre-approved reader into anything outside a
# temporary directory asks the person (permissionDecision "ask"), whatever the reader is.
#
# Fixture command strings are fed as JSON `tool_input.command`, never run.
#
# Run: bash .claude/hooks/tests/test-destructive-guard-reader-overwrite.sh

set -uo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/destructive-guard.sh"
WORKSPACE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TMP_DIR=$(mktemp -d)
PASS=0
FAIL=0
trap 'rm -rf "$TMP_DIR"' EXIT

# expect $1=desc $2=want(block|ask|pass) $3=command_text
expect() {
  local desc="$1" want="$2" cmd="$3" input got_exit got decision out_file="$TMP_DIR/out" err_file="$TMP_DIR/err"
  input=$(python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]},"cwd":sys.argv[2]}))' \
    "$cmd" "$WORKSPACE_ROOT")
  printf '%s' "$input" | bash "$HOOK" >"$out_file" 2>"$err_file"
  got_exit=$?
  decision=$(jq -r '.hookSpecificOutput.permissionDecision // empty' "$out_file" 2>/dev/null)
  if [ "$got_exit" -eq 2 ]; then got="block"
  elif [ "$got_exit" -eq 0 ] && [ "$decision" = "ask" ]; then got="ask"
  elif [ "$got_exit" -eq 0 ] && [ -z "$decision" ]; then got="pass"
  else got="unexpected(exit=$got_exit, decision=$decision)"; fi
  if [ "$got" = "$want" ]; then
    PASS=$((PASS+1))
  else
    FAIL=$((FAIL+1))
    echo "FAIL: $desc (ожидалось $want, получено $got)"
    echo "  stderr: $(cat "$err_file")"
  fi
}

# === the forms the red team ran ===
expect "grep without a match" ask 'grep zzzqqq README.md > params.yaml'
expect "ls of a missing path" ask 'ls /nonexistent > params.yaml'
expect "head -0" ask 'head -0 F > params.yaml'
expect "tail past the end" ask 'tail -n +999999 F > params.yaml'
expect "diff of a file with itself" ask 'diff F F > params.yaml'

# === the same class with other readers and redirections ===
expect "cat copies over a plan" ask 'cat README.md > DS-strategy/current/WeekPlan.md'
expect "wc" ask 'wc -l README.md > params.yaml'
expect "rg" ask 'rg zzzqqq > params.yaml'
expect "find" ask 'find . -name nothing > params.yaml'
expect "git log" ask 'git log -1 > params.yaml'
expect "git show" ask 'git show HEAD:README.md > README.md'
expect "clobber" ask 'grep zzzqqq README.md >| params.yaml'
expect "stderr into a file" ask 'ls /nonexistent 2> params.yaml'
expect "both streams" ask 'ls /nonexistent &> params.yaml'
expect "no blank" ask 'grep zzzqqq README.md>params.yaml'
expect "after a pipe" ask 'cat README.md | grep zzzqqq > params.yaml'
expect "after &&" ask 'true && grep zzzqqq README.md > params.yaml'
expect "absolute path" ask 'grep zzzqqq README.md > "$HOME/IWE/params.yaml"'
expect "escape from tmp with .." ask 'ls > /tmp/../home/x/params.yaml'

# === the older blocks keep blocking ===
expect "cat /dev/null still blocked" block 'cat /dev/null > params.yaml'
expect "protective file still blocked" block 'grep x README.md > .claude/hooks/destructive-guard.sh'

# === allowed without a prompt ===
expect "into /tmp" pass 'grep x README.md > /tmp/out.txt'
expect "into TMPDIR" pass 'git diff > "$TMPDIR/x.diff"'
expect "into /dev/null" pass 'grep -q x README.md > /dev/null'
expect "stderr to /dev/null" pass 'cat README.md 2>/dev/null | head -5'
expect "descriptor copy" pass 'ls 2>&1 | head'
expect "append" pass 'cat README.md >> notes.md'
expect "plain read" pass 'grep -rn x .claude/hooks'
expect "input redirection" pass 'grep x < params.yaml'
expect "not a reader" pass 'python3 x.py > out.json'
expect "heredoc body is data" pass "grep x <<'EOF'
a > params.yaml
EOF"

# === input given in the call: here-doc / here-string is not an empty-output reader ===
expect "cat > file <<'EOF'" pass "cat > notes.md <<'EOF'
a line
EOF"
expect "cat <<-EOF > file" pass "cat <<-EOF > notes.md
	a line
	EOF"
expect "here-string" pass 'cat <<< "x" > f'
expect "input from /dev/null still asks" ask 'cat > params.yaml < /dev/null'
expect "plain reader still asks" ask 'grep zzz README.md > params.yaml'
expect "here-doc in another segment does not exempt" ask "cat <<'EOF' > /tmp/x
a
EOF
grep zzz README.md > params.yaml"
expect "here-doc onto a protective file still blocked" block "cat > .claude//hooks/x.sh <<'EOF'
a
EOF"
expect "here-string onto settings still blocked" block 'cat <<< "{}" > ./.claude/./settings.json'

# === WP-529 F275: the exemption is only for `cat` without a file operand and a non-empty body ===
expect "empty here-doc body empties the file" ask "cat > params.yaml <<EOF
EOF"
expect "blank-only here-doc body" ask "cat > params.yaml <<'EOF'

EOF"
expect "empty here-string" ask 'cat > params.yaml <<< ""'
expect "unterminated here-doc" ask 'cat > params.yaml <<EOF'
expect "grep ignores its here-doc" ask "grep zzz README.md > params.yaml <<EOF
a line
EOF"
expect "ls ignores a here-string" ask 'ls /nonexistent > params.yaml <<< x'
expect "head -0 with a here-string" ask 'head -0 F > params.yaml <<< x'
expect "git show with a here-string" ask 'git show HEAD:README.md > README.md <<< x'
expect "cat with a file operand and a here-string" ask 'cat README.md > DS-strategy/current/WeekPlan.md <<< x'
expect "here-string from a variable may be empty" ask 'cat > params.yaml <<< "$EMPTY"'
expect "an empty body elsewhere in the call" ask "cat > /tmp/a <<EOF
EOF
cat > params.yaml <<'EOF'
a line
EOF"
expect "cat - reads only stdin" pass "cat - > notes.md <<'EOF'
a line
EOF"
expect "tee writes its non-empty here-doc" pass "tee notes.md <<'EOF' >/dev/null
a line
EOF"

# === WP-529 F275, rc.1 red team F2: only the last stdin redirection, on fd 0, may be the here-doc ===
expect "here-doc on fd 3 is not cat's input" ask "cat > params.yaml 3<<EOF
x
EOF"
expect "here-string on fd 3 is not cat's input" ask 'cat 3<<< x > params.yaml'
expect "stdin closed after the here-doc" ask "cat <<EOF > params.yaml <&-
x
EOF"
expect "stdin from /dev/null after the here-string" ask 'cat <<< x > params.yaml < /dev/null'
expect "stdin from a file after the here-string" ask 'cat <<< x > params.yaml 0< README.md'
expect "empty here-string after a here-doc" ask "cat <<EOF <<< '' > params.yaml
x
EOF"
expect "here-string on fd 0 explicitly" pass 'cat 0<<< x > notes.md'

# === WP-529 F275: a quote or << inside a # comment must not hide the next lines ===
expect "apostrophe in a comment, then a write" ask "ls # don't
grep zzz README.md > params.yaml"
expect "comment, then append into a plan" ask "ls # don't
echo x >> DS-strategy/current/WeekPlan.md"
expect "even quotes in a comment stay quiet" pass "ls # it is 'fine'
grep x README.md > /tmp/out.txt"
expect "comment with a quote, then /tmp" pass "ls # don't
grep x README.md > /tmp/out.txt"
expect "markdown heading with a quote inside a here-doc body" pass "cat > notes.md <<'EOF'
# Don't panic
> a quote
EOF"

# === WP-529 F275, rc.1 red team F3: readers after a comment with a quote, all redirection forms ===
expect "comment, then reader >" ask "ls # don't
grep zzzqqq README.md > params.yaml"
expect "comment, then reader &>" ask "ls # don't
grep zzzqqq README.md &> params.yaml"
expect "comment, then reader >&" ask "ls # don't
grep zzzqqq README.md >& params.yaml"
expect "quote nested in a substitution, then a workspace file" ask 'cat README.md "$(echo "'"'"'")" > params.yaml'
expect "substitution without quotes stays quiet" pass 'echo "$(date)" > /tmp/x'
expect "pr body from a cat here-doc with markdown quotes" pass "gh pr create --title t --body \"\$(cat <<'EOF'
> a quote
> another -> one
EOF
)\""

# === WP-529 F275, rc.2 red team A: line continuations are joined before any pass ===
expect "comment quote, reader target after a continuation" ask "ls # don't
grep zz README.md > \\
params.yaml"
expect "comment opener after the continued target" ask "grep zz README.md > \\
params.yaml # <<EOF"
expect "continuation before the operator" ask "ls # don't
grep zz README.md \\
> params.yaml"
expect "continuation in a comment ends with the line" pass "ls # note \\
git log --oneline -3"
expect "multi-line git log with continuations" pass "git log \\
  --oneline \\
  -5 2>/dev/null"
expect "continuation inside a quoted here-doc body stays data" pass "cat > /tmp/notes.md <<'EOF'
line one \\
> quoted
EOF"

# === WP-529 F275, rc.2 red team C: a later fd 0 redirection or an empty delimiter cancels the exemption ===
expect "here-string, then fd 0 closed" ask 'cat <<< x > params.yaml 0>&-'
expect "here-string, then fd 0 onto /dev/null" ask 'cat <<< x > params.yaml 0>/dev/null'
expect "here-string, then fd 0 moved away" ask 'cat <<< x > params.yaml 3<&0-'
expect "here-doc, then fd 0 moved by >&" ask "cat <<EOF > params.yaml 4>&0-
text
EOF"
expect "empty delimiter here-doc" ask "cat <<'' > params.yaml

"
expect "fd 0 closed before the here-string keeps the exemption" pass 'cat 0>&- <<< x > params.yaml'
expect "here-string with stderr to /dev/null keeps the exemption" pass 'cat <<< x > notes.md 2>/dev/null'

# === every input terminates: the new passes walk each line once ===
# finishes $1=desc $2=seconds $3=python expression building the command: the hook must answer
# (exit 0 or 2) within the limit. Python builds the text so a 200 KB command needs no shell variable.
finishes() {
  local desc="$1" limit="$2" expr="$3" verdict
  verdict=$(python3 - "$HOOK" "$WORKSPACE_ROOT" "$limit" "$expr" <<'PYEOF'
import json, subprocess, sys, time
hook, root, limit, expr = sys.argv[1], sys.argv[2], float(sys.argv[3]), sys.argv[4]
payload = json.dumps({"tool_input": {"command": eval(expr)}, "cwd": root})
started = time.monotonic()
try:
    proc = subprocess.run(["bash", hook], input=payload, capture_output=True, text=True, timeout=limit)
except subprocess.TimeoutExpired:
    print(f"timeout after {limit} s"); sys.exit()
took = time.monotonic() - started
print("ok" if proc.returncode in (0, 2) else f"exit {proc.returncode} after {took:.2f} s")
PYEOF
)
  if [ "$verdict" = "ok" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $desc ($verdict)"; fi
}
# Short commands: the limit is the time of a plain `ls` on this machine plus 1 s (rc.14 red team,
# F20: a hook call alone takes close to a second on a slow runner, so an absolute 1 s limit fired
# without any slow parsing).
BASELINE=$(python3 - "$HOOK" "$WORKSPACE_ROOT" <<'PYEOF'
import json, subprocess, sys, time
hook, root = sys.argv[1], sys.argv[2]
best = None
for _ in range(2):
    started = time.monotonic()
    subprocess.run(["bash", hook], input=json.dumps({"tool_input": {"command": "ls"}, "cwd": root}), capture_output=True, text=True)
    took = time.monotonic() - started
    best = took if best is None else min(best, took)
print(f"{best:.2f}")
PYEOF
)
SHORT_LIMIT=$(awk -v b="$BASELINE" 'BEGIN { printf "%.2f", b + 1.0 }')
BRACE_LIMIT=$(awk -v b="$BASELINE" 'BEGIN { printf "%.2f", b + 2.0 }')
finishes "semicolon then redirect" "$SHORT_LIMIT" '"ls ;> params.yaml"'
finishes "pipe then redirect" "$SHORT_LIMIT" '"ls |> params.yaml"'
finishes "chained odd operators" "$SHORT_LIMIT" '"ls ;>;>;> |>|> >|>| params.yaml"'
finishes "odd operators in a comment" "$SHORT_LIMIT" '"ls # ;> |> << \x27 \"\nls ;> |> x"'
# 200 KB: the hook as a whole is not linear in every older pass (main takes a few seconds on
# such text), so the limit here is a termination bound, not the 1.0 s budget of perf_cases.py.
finishes "200 KB here-doc body with quotes and >" 30 '"cat > notes.md <<\x27EOF\x27\n" + ("a > b it\x27s # c\n" * 13000)[:200000] + "\nEOF"'
finishes "200 KB of ;> |> after a quoted comment" 30 '"ls # don\x27t\n" + ("x ;> |> # a\x27 <<E " * 12000)[:200000]'

# === WP-529 F275, rc.1 red team F1: 2^40 brace words — the cap answers at once ===
finishes "40 brace groups after a protected write" "$BRACE_LIMIT" '"cat README.md > .claude/hooks/destructive-guard.sh || ls > x" + "{a,b}" * 40'
finishes "40 brace groups into /tmp" "$BRACE_LIMIT" '"ls > /tmp/x" + "{a,b}" * 40'
finishes "40 brace groups after tee" "$BRACE_LIMIT" '"echo a | tee x" + "{a,b}" * 40'
B40=$(printf '{a,b}%.0s' $(seq 40))
expect "40 brace groups into /tmp ask (unresolvable)" ask "ls > /tmp/x$B40"
expect "40 brace groups after tee ask (unresolvable)" ask "echo a | tee x$B40"
expect "bad bracket class asks, not a raw perl error" ask 'cat README.md > a[[:alpha:]]/b'

# === WP-529 F275, rc.6 red team F4: `<<` inside an expansion is not a here-doc ===
expect "shift inside \$((…)) does not hide the next line" ask 'ls $((1<<ls))
grep zzzqqq README.md > params.yaml
ls'
expect "<< inside \${…} gives cat no here-doc input" ask 'cat ${x:-<<ls} > params.yaml
x
ls'

echo "reader-overwrite: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
