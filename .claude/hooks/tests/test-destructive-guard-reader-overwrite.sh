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

# === review of #1576: the here-doc exemption only for cat/tee writing a non-empty stdin ===
expect "empty here-doc body zeroes the file" ask "cat > params.yaml <<EOF
EOF"
expect "grep with a file operand ignores the here-doc" ask "grep zzz README.md > params.yaml <<EOF
x
EOF"
expect "ls ignores a here-string" ask 'ls /nonexistent > params.yaml <<< x'
expect "head with a file ignores a here-string" ask 'head -0 F > params.yaml <<< x'
expect "git show ignores a here-string" ask 'git show HEAD:README.md > README.md <<< x'
expect "cat with a file operand ignores a here-string" ask 'cat README.md > DS-strategy/current/WeekPlan.md <<< x'
expect "empty here-string" ask "cat <<< '' > params.yaml"
expect "stderr of cat with a here-doc" ask "cat <<'EOF' 2> params.yaml
a
EOF"
expect "tee with a here-doc body" pass "tee <<'EOF' > notes.md
a
EOF"

# === review of #1576: an apostrophe in a comment or nested quotes no longer hide the next command ===
expect "apostrophe in a comment" ask "ls # don't
grep zzz README.md > params.yaml"
expect "apostrophe in a here-doc body" ask "cat <<EOF > /tmp/x
it's
EOF
grep zzz README.md > params.yaml"

# === review of #1576: the reader behind grouping, keywords and wrappers ===
expect "subshell" ask '(grep zzz README.md) > params.yaml'
expect "brace group" ask '{ grep zzz README.md; } > params.yaml'
expect "if … fi" ask 'if true; then grep zzz README.md; fi > params.yaml'
expect "while … done" ask 'while false; do :; done; for f in a; do grep zzz "$f"; done > params.yaml'
expect "negation" ask '! grep zzz README.md > params.yaml'
expect "time" ask 'time grep zzz README.md > params.yaml'
expect "env" ask 'env grep zzz README.md > params.yaml'
expect "command" ask 'command grep zzz README.md > params.yaml'
expect "zsh >!" ask 'grep zzz README.md >! params.yaml'
expect "target via command substitution" ask 'grep zzz README.md > $(echo params.yaml)'
expect "target via an unknown variable" ask 'grep zzz README.md > "$OUT"'
expect "bare redirection" ask '> params.yaml < /dev/null'
expect "exec redirection" ask 'exec > params.yaml'
expect "command name from a variable" ask '$READER zzz README.md > params.yaml'
expect "inside \$( )" ask 'x=$(grep zzz README.md > params.yaml)'
expect "unquoted > inside a word is a redirection" ask 'git log --format=%h->%s -3'
expect "unquoted => is a redirection" ask 'grep -rn foo=>bar src'

# === review of #1576: not a redirection, stays silent ===
expect "> in a comment" pass 'grep -rn foo . # old -> new'
expect "tag in a comment" pass 'ls docs # see <details> usage'
expect "quoted > in a pattern" pass 'grep -rn "=>" src | head'
expect "arithmetic" pass 'head -n $((3>2?3:2)) README.md'
expect "[[ comparison ]]" pass '[[ a > b ]] && ls'
expect "escaped >" pass 'grep -n a\>b README.md'
expect "process substitution" pass 'diff <(ls a) <(ls b)'
expect "fresh mktemp file" pass 'T=$(mktemp); git diff > "$T"'
expect "known literal temp variable" pass 'D=/tmp/x; git diff > "$D/a.diff"'
expect "> in a here-doc body of a commit message" pass "git commit -m \"\$(cat <<'EOF'
fix: a -> b
grep foo bar > out.txt
EOF
)\""

echo "reader-overwrite: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
