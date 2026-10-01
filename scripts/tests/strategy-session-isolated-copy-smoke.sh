#!/bin/bash
# strategy-session-isolated-copy-smoke.sh -- regression guard (WP-530 F72 wave 4).
# Text checks on SKILL.md + a behavioural run of the Step 0 block on a synthetic repo.
# WP-7 C1/C2: every command of the skill passes the destructive-guard hook (a top-level cd is
# blocked there), the rewritten blocks still do their job, and the publication command publishes
# from a session-isolate copy to origin/main with the real seed publisher.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="${STRATEGY_SKILL_UNDER_TEST:-$SCRIPT_DIR/../../.claude/skills/strategy-session/SKILL.md}"
[ -f "$SKILL" ] || { echo "FAIL: $SKILL not found"; exit 1; }
FAILURES=0
check() { if [ "$2" = ok ]; then echo "PASS: $1"; else echo "FAIL: $1"; FAILURES=$((FAILURES+1)); fi; }
has() { grep -qF -- "$1" "$SKILL"; }

# --- text checks
grep -nE '\{\{WORKSPACE_DIR\}\}/\{\{GOVERNANCE_REPO\}\}/(docs|current|inbox|Lifework|archive)' "$SKILL" >/dev/null \
  && check "no canonical literal in paths" bad || check "no canonical literal in paths" ok
has 'resolve_active_worktree' && has 'GOV_WT=' && check "resolver defines GOV_WT" ok || check "resolver defines GOV_WT" bad
has 'open --isolate' && check "isolation command" ok || check "isolation command" bad
has 'ds-publish.sh' && check "ds-publish" ok || check "ds-publish" bad
has 'GUARD_MODE=absent' && has 'mode=legacy' && check "explicit no-session-guard branch" ok || check "explicit no-session-guard branch" bad
has ': "${GOV_WT:?}"' && has 'cd -- "$GOV_WT" || exit 1' && check "GOV_WT re-check in write blocks" ok || check "GOV_WT re-check in write blocks" bad
has '--git-common-dir' && check "common-dir membership check" ok || check "common-dir membership check" bad
has 'bash "$GOV_WT/scripts/ds-publish.sh" "$GOV_WT"' && has 'source "{{WORKSPACE_DIR}}/scripts/lib/common.sh"' && check "quoted paths" ok || check "quoted paths" bad
# extensions come after the working-copy step
o1=$(grep -n '^### Шаг 0\. Рабочая копия' "$SKILL" | head -1 | cut -d: -f1)
o2=$(grep -n 'load-extensions.sh strategy-session before' "$SKILL" | head -1 | cut -d: -f1)
[ -n "$o1" ] && [ -n "$o2" ] && [ "$o1" -lt "$o2" ] && check "working copy step precedes before-extensions" ok || check "working copy step precedes before-extensions" bad
for t in docs/Strategy.md docs/Dissatisfactions.md 'current/WeekPlan W{N}.md' docs/Backlog.md; do
  has "\$GOV_WT/$t" && check "GOV_WT path: $t" ok || check "GOV_WT path: $t" bad
done

# --- behavioural run of the Step 0 block
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
python3 - "$SKILL" "$TMP/block.sh" <<'PY'
import re,sys
s=open(sys.argv[1]).read()
i=s.index("### Шаг 0. Рабочая копия")
m=re.search(r"```bash\n(.*?)```",s[i:],re.S)
open(sys.argv[2],"w").write(m.group(1))
PY
[ -s "$TMP/block.sh" ] || { check "block extracted" bad; exit 1; }
ROOT="$TMP/ws"; mkdir -p "$ROOT/scripts" "$TMP/other"
git init -q "$ROOT/GOV" && git -C "$ROOT/GOV" -c user.email=a@b -c user.name=t commit -q --allow-empty -m i
git -C "$ROOT/GOV" worktree add -q -b wt "$TMP/wt" 2>/dev/null
git init -q "$TMP/other" && git -C "$TMP/other" -c user.email=a@b -c user.name=t commit -q --allow-empty -m i
sed "s#{{WORKSPACE_DIR}}#$ROOT#g; s#{{GOVERNANCE_REPO}}#GOV#g" "$TMP/block.sh" > "$TMP/run.sh"
run() { (cd "$1" && IWE_SCRIPTS="$ROOT/none" bash "$TMP/run.sh" 2>&1); }
wtreal=$(cd "$TMP/wt" && pwd -P)
# no guard: legacy, canon and worktree both OK, unrelated repo falls back to canon
out=$(run "$ROOT/GOV"); rc=$?; [ $rc -eq 0 ] && echo "$out" | grep -q 'mode=legacy' && check "no guard, canon -> legacy ok" ok || check "no guard, canon -> legacy ok" bad
out=$(run "$TMP/other"); rc=$?; [ $rc -eq 0 ] && echo "$out" | grep -q "GOV_WT=.*/GOV mode=legacy" && check "no guard, foreign repo -> canon, not foreign" ok || check "no guard, foreign repo -> canon, not foreign" bad
# guard present
: > "$ROOT/scripts/session-guard.sh"
out=$(run "$ROOT/GOV"); rc=$?; [ $rc -eq 2 ] && echo "$out" | grep -q 'NOT ISOLATED' && check "guard, canon -> exit 2" ok || check "guard, canon -> exit 2" bad
out=$(run "$TMP/other"); rc=$?; [ $rc -eq 2 ] && check "guard, foreign repo -> exit 2 (not accepted as worktree)" ok || check "guard, foreign repo -> exit 2 (not accepted as worktree)" bad
out=$(run "$TMP"); rc=$?; [ $rc -eq 2 ] && check "guard, non-git cwd -> exit 2" ok || check "guard, non-git cwd -> exit 2" bad
out=$(run "$TMP/wt"); rc=$?; [ $rc -eq 0 ] && echo "$out" | grep -qF "GOV_WT=$wtreal mode=isolated" && check "guard, worktree -> isolated" ok || check "guard, worktree -> isolated" bad
mv "$ROOT/GOV" "$ROOT/GOV.gone"
out=$(run "$TMP/other"); rc=$?; [ $rc -eq 1 ] && check "missing canon -> exit 1" ok || check "missing canon -> exit 1" bad

# --- WP-7 C2: the skill's commands against the shipped destructive-guard hook, C1: its publication
TEMPLATE_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd -P)
HOOK="$TEMPLATE_ROOT/.claude/hooks/destructive-guard.sh"
PUB="$TEMPLATE_ROOT/seed/strategy/scripts/ds-publish.sh"
for tool in jq perl; do command -v "$tool" >/dev/null 2>&1 || { echo "FAIL: $tool not found (the hook needs it)"; exit 1; }; done
unset CC_ALLOW_DESTRUCTIVE_INPUT   # the pilot's bypass would let every command through the hook
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
detail() { echo "  detail: $*"; }

# fixture: origin with only main, the canon, and the copy that session-guard.sh --isolate makes
C2="$TMP/c2"; WS="$C2/ws"; ORIGIN="$C2/origin.git"; CANON="$WS/DS-strategy"; WT="$C2/isolated-worktrees/claude-s1"
mkdir -p "$WS/scripts" "$C2/home" "$C2/foreign/docs"
git init -q --bare -b main "$ORIGIN"
git clone -q "$ORIGIN" "$CANON" 2>/dev/null
git -C "$CANON" checkout -q -B main
mkdir -p "$CANON/docs" "$CANON/scripts"
printf '# Strategy\n' > "$CANON/docs/Strategy.md"
cp "$PUB" "$CANON/scripts/ds-publish.sh"
git -C "$CANON" add docs scripts && git -C "$CANON" commit -q -m seed && git -C "$CANON" push -q origin HEAD:main
: > "$WS/scripts/session-guard.sh"   # session-guard present = the skill's isolated mode
git -C "$CANON" worktree add -q -b session-isolate/claude-s1 "$WT" origin/main 2>/dev/null   # as session-guard.sh --isolate
CANON_REAL=$(cd -P "$CANON" && pwd -P); WT_REAL=$(cd -P "$WT" && pwd -P)

# Every ```bash block and every inline extensions call, placeholders filled with the fixture's paths.
# index.tsv: <file> <kind> <SKILL.md line> <unfilled placeholder or ->; a block's kind is told by a marker.
BLOCKS="$C2/blocks"; mkdir -p "$BLOCKS"
python3 - "$SKILL" "$BLOCKS" "$WS" "$CANON_REAL" "$WS/scripts/session-guard.sh" "$WT_REAL" > "$C2/index.tsv" <<'PY' || check "the skill's commands are read" bad
import re
import sys
import textwrap

skill, out_dir, ws, canon, guard, wt = sys.argv[1:7]
text = open(skill, encoding="utf-8").read()
fences = []
for m in re.finditer(r"^([ \t]*)```bash[ \t]*\n(.*?)^\1```[ \t]*$", text, re.S | re.M):
    fences.append((text.count("\n", 0, m.start()) + 1, textwrap.dedent(m.group(2))))
MARKERS = [("step0", "GUARD_MODE=required"), ("retry", "<блок шага 0 без изменений>"),
           ("open", "open --isolate --wp"), ("write", "<команды записи>"),
           ("publish", "ds-publish.sh"), ("search", "grep -rl")]
step0 = next((body for _, body in fences if MARKERS[0][1] in body), "")
SUBST = [("{{WORKSPACE_DIR}}", ws), ("{{GOVERNANCE_REPO}}", "DS-strategy"), ("<CANON_C>", canon),
         ("<GUARD>", guard), ("<WP-N>", "WP-1"), ("<worktree_path>", wt),
         ("<команды записи>", "printf '%s\\n' '- [ ] цель недели' >> docs/Strategy.md")]
PATH_PLACEHOLDERS = ("<записанный абсолютный путь>", "<записанный путь>")


def fill(body, path=wt):
    body = body.replace("<блок шага 0 без изменений>", step0.rstrip("\n"))
    for key, value in SUBST:
        body = body.replace(key, value)
    for key in PATH_PLACEHOLDERS:
        body = body.replace(key, path)
    return body


def leftover(body):
    # an unfilled placeholder outside quotes would reach the hook as a redirection, not as a path
    unquoted = re.sub(r"'[^']*'|\"(?:\\.|[^\"\\])*\"", " Q ", body)
    found = re.search(r"<[A-Za-zА-Яа-яЁё][^<>\n]*[^\s<>]>", unquoted)
    return found.group(0) if found else "-"


def emit(name, kind, line, body):
    with open(f"{out_dir}/{name}", "w", encoding="utf-8") as fh:
        fh.write(body)
    print(f"{name}\t{kind}\t{line}\t{leftover(body)}")


for n, (line, body) in enumerate(fences):
    kind = next((k for k, marker in MARKERS if marker in body), "other")
    emit(f"{n:02d}.sh", kind, line, fill(body))
    if kind == "write":  # the same block with an empty and with a missing path: it must stop
        emit(f"{n:02d}.empty.sh", "write-empty", line, fill(body, ""))
        emit(f"{n:02d}.missing.sh", "write-missing", line, fill(body, wt + "-missing"))
for n, m in enumerate(re.finditer(r"`([^`\n]*load-extensions\.sh[^`\n]*)`", text)):
    emit(f"ext{n:02d}.sh", "extensions", text.count("\n", 0, m.start()) + 1, fill(m.group(1)))
PY
block_of() {  # KIND -> file name of the first block of that kind, empty if none
  awk -F'\t' -v k="$1" '$2 == k { print $1; exit }' "$C2/index.tsv"
}
hook_rc() {  # FILE -> exit code of the hook for the file's text sent as one Bash call from the workspace root
  jq -n --arg c "$(cat "$1")" --arg cwd "$TEMPLATE_ROOT" \
    '{session_id: "test", hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: $c, description: "test"}, cwd: $cwd}' \
    | HOME="$C2/home" bash "$HOOK" >/dev/null 2>"$C2/hook.err"
  echo $?
}
run_block() {  # FILE -> runs it from an unrelated directory; sets OUT and RC
  OUT=$(cd "$C2/foreign" && IWE_SCRIPTS="$C2/none" bash "$1" 2>&1); RC=$?
}

# C2.1: every command passes the hook; the controls keep this from passing with a disabled hook
printf 'cd %s\n' "$WT_REAL" > "$C2/control-cd.sh"
[ "$(hook_rc "$C2/control-cd.sh")" = 2 ] && check "hook control: a top-level cd is blocked (the hook is live)" ok \
  || check "hook control: a top-level cd is blocked (the hook is live)" bad
# shellcheck disable=SC2016  # the literal text of the former write-block prefix, not an expansion
printf 'GOV_WT="%s"; : "${GOV_WT:?}"; cd -- "$GOV_WT" || exit 1\n' "$WT_REAL" > "$C2/control-old.sh"
[ "$(hook_rc "$C2/control-old.sh")" = 2 ] && check "hook control: the former write-block prefix (top-level cd) is blocked" ok \
  || check "hook control: the former write-block prefix (top-level cd) is blocked" bad
for kind in step0 open retry write publish search extensions; do
  [ -n "$(block_of "$kind")" ] && check "SKILL.md has its $kind command" ok || check "SKILL.md has its $kind command" bad
done
while IFS="$(printf '\t')" read -r file kind line left; do
  case "$kind" in write-empty|write-missing) continue ;; esac
  [ "$left" = "-" ] || { detail "placeholder $left"; check "SKILL.md:$line ($kind): every placeholder is filled by this test" bad; }
  rc=$(hook_rc "$BLOCKS/$file")
  [ "$rc" = 0 ] || detail "hook exit $rc: $(head -c 300 "$C2/hook.err")"
  [ "$rc" = 0 ] && check "SKILL.md:$line ($kind) passes the hook" ok || check "SKILL.md:$line ($kind) passes the hook" bad
done < "$C2/index.tsv"

# C2.2: the rewritten blocks still do their job
f=$(block_of step0)
if [ -n "$f" ]; then
  run_block "$BLOCKS/$f"
  [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'NOT ISOLATED' && check "step 0 outside the copy: NOT ISOLATED (exit 2)" ok \
    || { detail "rc=$RC out=$OUT"; check "step 0 outside the copy: NOT ISOLATED (exit 2)" bad; }
fi
f=$(block_of retry)
if [ -n "$f" ]; then
  run_block "$BLOCKS/$f"
  [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -qF "GOV_WT=$WT_REAL mode=isolated" && check "the retry block, run from elsewhere, finds the isolated copy" ok \
    || { detail "rc=$RC out=$OUT"; check "the retry block, run from elsewhere, finds the isolated copy" bad; }
fi
f=$(block_of write)
if [ -n "$f" ]; then
  run_block "$BLOCKS/$f"
  [ "$RC" -eq 0 ] && grep -qF -- '- [ ] цель недели' "$WT/docs/Strategy.md" && [ ! -e "$C2/foreign/docs/Strategy.md" ] \
    && ! grep -qF 'цель недели' "$CANON/docs/Strategy.md" && check "a write block writes into the copy only (not the caller's directory, not the canon)" ok \
    || { detail "rc=$RC out=$OUT"; check "a write block writes into the copy only (not the caller's directory, not the canon)" bad; }
  for variant in empty missing; do
    run_block "$BLOCKS/${f%.sh}.$variant.sh"
    [ "$RC" -ne 0 ] && [ ! -e "$C2/foreign/docs/Strategy.md" ] && [ ! -e "$WT-missing" ] && check "a write block with a $variant GOV_WT stops before writing" ok \
      || { detail "rc=$RC out=$OUT"; check "a write block with a $variant GOV_WT stops before writing" bad; }
  done
fi
f=$(block_of search)
if [ -n "$f" ]; then
  month=$(date +%Y-%m); mkdir -p "$WT/sessions"; printf '# Strategy Session\n' > "$WT/sessions/$month-01.md"
  run_block "$BLOCKS/$f"   # grep's exit code is not the contract here (a missing month folder is an error for it); its output is
  printf '%s\n' "$OUT" | grep -qxF "$WT_REAL/sessions/$month-01.md" && check "the session search finds this month's session file" ok \
    || { detail "rc=$RC out=$OUT"; check "the session search finds this month's session file" bad; }
fi

# C1: the publication block, from the session-isolate copy, with the seed publisher, origin has only main
f=$(block_of publish)
if [ -n "$f" ]; then
  mkdir -p "$WT/current"; printf 'plan\n' > "$WT/current/WeekPlan W40.md"
  git -C "$WT" add "current/WeekPlan W40.md" && git -C "$WT" commit -q -m "strategy-session: week plan"
  run_block "$BLOCKS/$f"
  [ "$RC" -eq 0 ] && [ "$(git --git-dir="$ORIGIN" log -1 --format=%s main)" = "strategy-session: week plan" ] && check "publication: origin/main got the copy's commit" ok \
    || { detail "rc=$RC out=$OUT"; check "publication: origin/main got the copy's commit" bad; }
  [ "$(git --git-dir="$ORIGIN" for-each-ref --format='%(refname:short)' refs/heads)" = main ] && check "publication: only main on origin" ok \
    || check "publication: only main on origin" bad
fi

[ "$FAILURES" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$FAILURES FAILED"; exit 1; }
