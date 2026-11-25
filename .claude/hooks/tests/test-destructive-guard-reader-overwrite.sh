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

# A block the hook gives because its own clock ran out (40 s for the whole check, 35 s for each
# released guard it runs alongside) says nothing about the command. On the loaded Mac delivery
# gate (load ~20, 2026-11-20) 15 of these cases hit it although the whole file takes 43 s alone,
# so such a case is run again; one that times out on every attempt still fails, as "timeout".
TIMEOUT_ATTEMPTS=3
timed_out() {
  grep -qE 'не уложилась|итог «timeout»' "$1"
}

# expect $1=desc $2=want(block|ask|pass) $3=command_text
expect() {
  local desc="$1" want="$2" cmd="$3" input got_exit got decision out_file="$TMP_DIR/out" err_file="$TMP_DIR/err"
  input=$(python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]},"cwd":sys.argv[2]}))' \
    "$cmd" "$WORKSPACE_ROOT")
  for _ in $(seq 1 "$TIMEOUT_ATTEMPTS"); do
    printf '%s' "$input" | bash "$HOOK" >"$out_file" 2>"$err_file"
    got_exit=$?
    if [ "$got_exit" -ne 2 ] || ! timed_out "$err_file"; then break; fi
  done
  decision=$(jq -r '.hookSpecificOutput.permissionDecision // empty' "$out_file" 2>/dev/null)
  if [ "$got_exit" -eq 2 ] && timed_out "$err_file"; then got="timeout($TIMEOUT_ATTEMPTS attempts)"
  elif [ "$got_exit" -eq 2 ]; then got="block"
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
# answer_verdict $1=seconds $2=python expression building the command: prints "ok" when the hook
# answers (exit 0 or 2) within the limit. Python builds the text so a 200 KB command needs no shell
# variable.
answer_verdict() {
  python3 - "$HOOK" "$WORKSPACE_ROOT" "$1" "$2" <<'PYEOF'
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
}
count_verdict() {
  if [ "$2" = "ok" ]; then PASS=$((PASS+1)); else FAIL=$((FAIL+1)); echo "FAIL: $1 ($2)"; fi
}
# finishes $1=desc $2=seconds $3=python expression: the hook must answer within an absolute limit.
finishes() {
  count_verdict "$1" "$(answer_verdict "$2" "$3")"
}
# Short commands: the limit is the time of a plain `ls` on this machine plus a margin (rc.14 red
# team, F20: a hook call alone takes close to a second on a slow runner, so an absolute 1 s limit
# fired without any slow parsing). The plain call is timed right before each attempt: on the loaded
# Mac delivery gate (2026-11-20) one taken at the start of the file was stale by the time of the
# case ("pipe then redirect" took 15.47 s). A case gets two attempts; slow parsing fails both.
baseline() {
  python3 - "$HOOK" "$WORKSPACE_ROOT" <<'PYEOF'
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
}
# finishes_near_baseline $1=desc $2=margin seconds over the plain call $3=python expression
finishes_near_baseline() {
  local desc="$1" margin="$2" expr="$3" limit verdict
  for _ in 1 2; do
    limit=$(awk -v b="$(baseline)" -v m="$margin" 'BEGIN { printf "%.2f", b + m }')
    verdict=$(answer_verdict "$limit" "$expr")
    [ "$verdict" = "ok" ] && break
  done
  count_verdict "$desc" "$verdict"
}
finishes_near_baseline "semicolon then redirect" 1.0 '"ls ;> params.yaml"'
finishes_near_baseline "pipe then redirect" 1.0 '"ls |> params.yaml"'
finishes_near_baseline "chained odd operators" 1.0 '"ls ;>;>;> |>|> >|>| params.yaml"'
finishes_near_baseline "odd operators in a comment" 1.0 '"ls # ;> |> << \x27 \"\nls ;> |> x"'
# 200 KB: the hook as a whole is not linear in every older pass (main takes a few seconds on
# such text), so the limit here is a termination bound, not the 1.0 s budget of perf_cases.py.
finishes "200 KB here-doc body with quotes and >" 30 '"cat > notes.md <<\x27EOF\x27\n" + ("a > b it\x27s # c\n" * 13000)[:200000] + "\nEOF"'
finishes "200 KB of ;> |> after a quoted comment" 30 '"ls # don\x27t\n" + ("x ;> |> # a\x27 <<E " * 12000)[:200000]'

# === WP-529 F275, rc.1 red team F1: 2^40 brace words — the cap answers at once ===
finishes_near_baseline "40 brace groups after a protected write" 2.0 '"cat README.md > .claude/hooks/destructive-guard.sh || ls > x" + "{a,b}" * 40'
finishes_near_baseline "40 brace groups into /tmp" 2.0 '"ls > /tmp/x" + "{a,b}" * 40'
finishes_near_baseline "40 brace groups after tee" 2.0 '"echo a | tee x" + "{a,b}" * 40'
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

# === WP-7 F316 (22.11): a variable assigned a temporary path in the same call is temporary ===
expect "mktemp variable (pilot screenshot 22.11)" pass 'I=/home/user/IWE; R=$I/DS-governance; F=$(mktemp); git -C $R show origin/main:a.yaml > $F; sed -n 1,5p $F'
expect "scratchpad variable with a sub-path (pilot screenshot 21.11)" pass 'S=/tmp/claude-1000/x/scratchpad; R=/home/user/IWE/DS-governance; git -C $R show origin/main:inbox/a.md > $S/w.md'
expect "braced variable" pass 'F=$(mktemp); git show HEAD:a > ${F}'
expect "mktemp -d directory" pass 'D=$(mktemp -d); grep x a > $D/o.txt'
expect "variable built on a temporary variable" pass 'T=$(mktemp -d); S=$T/sub; git show HEAD:a > $S/o'
expect "TMPDIR based variable" pass 'F=$TMPDIR/o.txt; git show HEAD:a > $F'
expect "variable in a working path still asks" ask 'R=/home/user/IWE/DS-governance; git show HEAD:a > $R/WeekPlan.md'
expect "variable with a relative name still asks" ask 'F=params.yaml; grep zzzqqq README.md > $F'
expect "variable without an assignment still asks" ask 'grep zzzqqq README.md > $F'
expect "mktemp with a template in the working tree still asks" ask 'F=$(mktemp params.XXXX); grep zzzqqq README.md > $F'
expect "mktemp -p into a working directory still asks" ask 'F=$(mktemp -p /home/user/IWE/DS-governance); grep zzzqqq README.md > $F'
expect "reassigned to a working file still asks" ask 'F=$(mktemp); F=params.yaml; grep zzzqqq README.md > $F'
expect "appended to a working path still asks" ask 'F=$(mktemp); F+=/../params.yaml; grep zzzqqq README.md > $F'
expect "read rebinds the variable, still asks" ask 'F=$(mktemp); read F < x; grep zzzqqq README.md > $F'
expect "for loop rebinds the variable, still asks" ask 'F=$(mktemp); for F in params.yaml; do echo; done; grep zzzqqq README.md > $F'
expect "parent-directory escape under a temporary variable still asks" ask 'F=$(mktemp -d); grep zzzqqq README.md > $F/../../params.yaml'
expect "eval hides assignments, still asks" ask 'F=$(mktemp); eval "F=params.yaml"; grep zzzqqq README.md > $F'
expect "temporary variable still cannot reach a protected file" block 'F=$(mktemp); ls > .claude/hooks/destructive-guard.sh'

# === WP-7 F316 (22.11): after a quoted substitution, the `>` of a regex class is not a redirection ===
expect "regex class [<>] in a quoted substitution (pilot screenshot 22.11)" pass 'git show HEAD:a > /tmp/s/cmp.txt 2>/dev/null; echo "x: $(echo a | grep -c '"'"'^[<>]'"'"')"'
expect "same with a temporary variable path" pass 'T=/tmp/s; for r in a b; do git show HEAD:$r > $T/cmp.txt 2>/dev/null; echo "$r: $(diff $T/a $T/cmp.txt | grep -c '"'"'^[<>]'"'"')"; done'
expect "regex class [^>]" pass 'echo "x: $(echo a | grep -c '"'"'[^>]x'"'"')"'
expect "real redirect after a quoted substitution still asks" ask 'echo "$(echo '"'"'a'"'"')"; echo hi > params.yaml'
expect "variable without a temporary assignment after a quoted substitution still asks" ask 'echo "$(echo '"'"'a'"'"')"; echo hi > $F'
expect "redirect into a variable of a working path after a quoted substitution still asks" ask 'R=/home/user/IWE/DS-governance; echo "$(echo '"'"'a'"'"')"; echo hi > $R/WeekPlan.md'
expect "temporary variable after a quoted substitution" pass 'F=$(mktemp); echo "$(echo '"'"'a'"'"')"; echo hi > $F'
expect "plain >] after a quoted substitution still asks" ask 'echo "$(echo '"'"'a'"'"')"; echo hi >]'

# === WP-7 F316 (23.11): after a quoted substitution, a lone ` => ` / ` -> ` arrow is message text ===
expect "arrow => in a message after a quoted substitution (pilot screenshot 23.11)" pass 'for m in a b; do r=$(echo "ok" | codex exec -m $m - 2>&1 | grep -E "x|y" | head -1); echo "$m => ${r:-OK?}"; done'
expect "arrow -> in a message after a quoted substitution" pass 'r=$(echo "ok" | grep -E "x|y" | head -1); echo "a -> $r"'
expect "real redirect next to an arrow message still asks" ask 'r=$(echo "ok" | grep -E "x|y"); echo "a => $r"; echo hi > params.yaml'
expect "arrow glued to the word is a real redirect and still asks" ask 'r=$(echo "ok" | grep -E "x|y"); echo a=>params.yaml'
expect "arrow without a space after it is a real redirect and still asks" ask 'r=$(echo "ok" | grep -E "x|y"); echo a =>params.yaml'
expect "arrow message cannot reach a protective file" block 'r=$(echo "ok" | grep -E "x|y"); echo "a => $r"; echo hi > .claude/hooks/destructive-guard.sh'

# === WP-7 F316 (25.11): variable inside the file name, `>=` comparison, <name@host> address ===
expect "temporary variable with a second variable inside the file name" pass 'P=/tmp/s; for a in x y; do echo "$(echo '"'"'q'"'"')"; echo hi > $P/p2b-$a.md; done'
expect "second variable as a whole path component still asks" ask 'P=/tmp/s; echo "$(echo '"'"'q'"'"')"; echo hi > $P/$a/y.md'
expect "command substitution inside the file name still asks" ask 'P=/tmp/s; echo "$(echo '"'"'q'"'"')"; echo hi > $P/a$(echo b).md'
expect "awk >= comparison after a quoted substitution" pass 'echo "$(echo '"'"'q'"'"')"; awk '"'"'$1>="2026-10-26"'"'"' F'
expect "shell n>=2 comparison inside awk" pass 'echo "$(echo '"'"'q'"'"')"; awk '"'"'BEGIN{n=0} /^---$/{n++; next} n>=2'"'"' F'
expect "address <name@host> closes a commit message" pass 'echo "$(echo '"'"'q'"'"')"; echo '"'"'{"m":"x <n@a.com>"}]}'"'"''
expect "real redirect after an address still asks" ask 'echo "$(echo '"'"'q'"'"')"; echo "<n@a.com>" ; echo hi > params.yaml'

echo "reader-overwrite: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
