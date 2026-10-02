#!/bin/bash
# test_issue_969_strategy_session_isolated_copy.sh -- regression guard for #969 (WP-530 F72 wave 4).
# Text checks on SKILL.md + a behavioural run of the Step 0 block on a synthetic repo.
# WP-7 C1/C2: every command of the skill passes the destructive-guard hook (a top-level cd is
# blocked there), the rewritten blocks still do their job, and the publication command publishes
# from a session-isolate copy to origin/main with real publishers (C1 compat: --branch only to a
# publisher that knows it, judged by the file's text (a heuristic); C3: every commit of the copy,
# oldest first; a failed git rev-list is an error, not "nothing to publish").
# scripts/tests/run-issue-tests.sh picks up test_issue_*.sh by existence, with no registration, so an
# install without this dev-only (undelivered) file is not reported as missing it.
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
has 'PUB="$GOV_WT/scripts/ds-publish.sh"' && has 'bash "$PUB" "$GOV_WT" normal' && has 'source "{{WORKSPACE_DIR}}/scripts/lib/common.sh"' && check "quoted paths" ok || check "quoted paths" bad
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
# guard present, but the canon has no origin (an install without GitHub): `open --isolate` without --base-sha fetches
# origin main for its base and there is nowhere to publish -> legacy, as before 0.41.0 (audit of v0.41.0: the skill used to stop here with NOT ISOLATED)
: > "$ROOT/scripts/session-guard.sh"
out=$(run "$ROOT/GOV"); rc=$?; [ $rc -eq 0 ] && echo "$out" | grep -q 'mode=legacy' && echo "$out" | grep -q 'нет origin' && check "guard, canon without origin -> legacy" ok || check "guard, canon without origin -> legacy" bad
out=$(run "$TMP/wt"); rc=$?; [ $rc -eq 0 ] && echo "$out" | grep -q 'mode=legacy' && check "guard, worktree without origin -> legacy" ok || check "guard, worktree without origin -> legacy" bad
# guard present and the canon has an origin (a connected install): isolation is required
git -C "$ROOT/GOV" remote add origin "$TMP/origin.git"
out=$(run "$ROOT/GOV"); rc=$?; [ $rc -eq 2 ] && echo "$out" | grep -q 'NOT ISOLATED' && check "guard, canon -> exit 2" ok || check "guard, canon -> exit 2" bad
out=$(run "$TMP/other"); rc=$?; [ $rc -eq 2 ] && check "guard, foreign repo -> exit 2 (not accepted as worktree)" ok || check "guard, foreign repo -> exit 2 (not accepted as worktree)" bad
out=$(run "$TMP"); rc=$?; [ $rc -eq 2 ] && check "guard, non-git cwd -> exit 2" ok || check "guard, non-git cwd -> exit 2" bad
out=$(run "$TMP/wt"); rc=$?; [ $rc -eq 0 ] && echo "$out" | grep -qF "GOV_WT=$wtreal mode=isolated" && check "guard, worktree -> isolated" ok || check "guard, worktree -> isolated" bad
# the freeze switched off by an empty IWE_FROZEN_CANONICAL_PATH (the way session-guard.sh reads it) -> legacy even with an origin
out=$(cd "$ROOT/GOV" && IWE_FROZEN_CANONICAL_PATH="" IWE_SCRIPTS="$ROOT/none" bash "$TMP/run.sh" 2>&1); rc=$?
[ $rc -eq 0 ] && echo "$out" | grep -q 'mode=legacy' && echo "$out" | grep -q 'заморозка выключена' && check "guard, empty IWE_FROZEN_CANONICAL_PATH -> legacy" ok || check "guard, empty IWE_FROZEN_CANONICAL_PATH -> legacy" bad
# a non-empty value does not switch isolation off
out=$(cd "$ROOT/GOV" && IWE_FROZEN_CANONICAL_PATH="$ROOT/GOV" IWE_SCRIPTS="$ROOT/none" bash "$TMP/run.sh" 2>&1); rc=$?
[ $rc -eq 2 ] && echo "$out" | grep -q 'NOT ISOLATED' && check "guard, non-empty IWE_FROZEN_CANONICAL_PATH keeps isolation" ok || check "guard, non-empty IWE_FROZEN_CANONICAL_PATH keeps isolation" bad
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
run_block() {  # FILE [interpreter words, default: bash] -> runs it from an unrelated directory; sets OUT and RC
  local file="$1"; shift
  [ "$#" -gt 0 ] || set -- bash
  OUT=$(cd "$C2/foreign" && IWE_SCRIPTS="$C2/none" "$@" "$file" 2>&1); RC=$?
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

# C1: the publication block, from a session-isolate copy, with real publishers, origin has only main.
f=$(block_of publish)
if [ -n "$f" ]; then
  new_copy() {  # NAME -> COPY: a session-isolate copy of origin/main, as session-guard.sh --isolate makes it
    COPY="$C2/isolated-worktrees/$1"
    git -C "$CANON" fetch -q origin main 2>/dev/null
    git -C "$CANON" worktree add -q -b "session-isolate/$1" "$COPY" origin/main 2>/dev/null
  }
  commit_in_copy() {  # FILE MESSAGE -> one commit in $COPY that adds the message as a line of FILE
    mkdir -p "$(dirname "$COPY/$1")"; printf '%s\n' "$2" >> "$COPY/$1"
    git -C "$COPY" add "$1" && git -C "$COPY" commit -q -m "$2"
  }
  publish_copy() {  # [interpreter words] -> the publication block run against $COPY; sets OUT and RC
    sed "s#$WT_REAL#$(cd -P "$COPY" && pwd -P)#g" "$BLOCKS/$f" > "$C2/publish-copy.sh"
    run_block "$C2/publish-copy.sh" "$@"
  }
  origin_top() { git --git-dir="$ORIGIN" log -1 --format=%s main; }
  only_main() { [ "$(git --git-dir="$ORIGIN" for-each-ref --format='%(refname:short)' refs/heads)" = main ]; }
  publisher_on_origin() {  # FILE -> the canon commits it as scripts/ds-publish.sh, so every new copy carries it
    git -C "$CANON" checkout -q -- scripts/ds-publish.sh 2>/dev/null
    git -C "$CANON" pull -q --ff-only origin main 2>/dev/null
    cp "$1" "$CANON/scripts/ds-publish.sh"
    git -C "$CANON" commit -q -am "publisher: $(basename "$1")" && git -C "$CANON" push -q origin HEAD:main
  }

  # Fresh install: the publisher is committed, so the copy has its own; the canon's file must not run.
  printf '#!/bin/bash\ntouch "%s"\nexit 1\n' "$C2/canon-publisher-ran" > "$CANON/scripts/ds-publish.sh"
  COPY="$WT"; commit_in_copy "current/WeekPlan W40.md" "strategy-session: week plan"
  publish_copy
  [ "$RC" -eq 0 ] && [ "$(origin_top)" = "strategy-session: week plan" ] && check "publication: origin/main got the copy's commit" ok \
    || { detail "rc=$RC out=$OUT"; check "publication: origin/main got the copy's commit" bad; }
  only_main && check "publication: only main on origin" ok || check "publication: only main on origin" bad
  [ ! -e "$C2/canon-publisher-ran" ] && check "publication, fresh install: the copy's own publisher wins over the canon's file" ok \
    || check "publication, fresh install: the copy's own publisher wins over the canon's file" bad

  # C3: the publisher carries one commit per call, so the block publishes every commit of the copy that
  # origin/main lacks, oldest first; a repeated run changes nothing; a copy with nothing new says so.
  for sh in bash zsh; do
    command -v "$sh" >/dev/null 2>&1 || { echo "SKIP: $sh not found, the publication block is not run in it"; continue; }
    new_copy "claude-two-$sh"
    commit_in_copy "current/WeekPlan W44.md" "strategy-session: week plan, $sh"
    commit_in_copy "inbox/fleeting-notes.md" "strategy-session: inbox, $sh"
    if [ "$sh" = zsh ]; then publish_copy zsh -f; else publish_copy; fi
    [ "$RC" -eq 0 ] && [ "$(git --git-dir="$ORIGIN" log -2 --reverse --format=%s main | tr '\n' '|')" = "strategy-session: week plan, $sh|strategy-session: inbox, $sh|" ] && only_main \
      && check "publication ($sh), two commits in the copy: both on origin/main, oldest first" ok \
      || { detail "rc=$RC out=$OUT"; check "publication ($sh), two commits in the copy: both on origin/main, oldest first" bad; }
  done
  before=$(git --git-dir="$ORIGIN" rev-parse main)
  publish_copy
  [ "$RC" -eq 0 ] && [ "$(git --git-dir="$ORIGIN" rev-parse main)" = "$before" ] \
    && check "publication, repeated: exit 0, origin/main unchanged" ok \
    || { detail "rc=$RC out=$OUT"; check "publication, repeated: exit 0, origin/main unchanged" bad; }
  new_copy "claude-nothing"
  publish_copy
  [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'Публиковать нечего' && ! printf '%s' "$OUT" | grep -q 'published as' \
    && [ "$(git --git-dir="$ORIGIN" rev-parse main)" = "$before" ] \
    && check "publication, nothing new in the copy: exit 0, one line says so, no claim of a publication" ok \
    || { detail "rc=$RC out=$OUT"; check "publication, nothing new in the copy: exit 0, one line says so, no claim of a publication" bad; }
  # A failing git rev-list is an error, not "nothing to publish": an empty list from a failed command must
  # not read as success. The git double fails rev-list only and runs the real git for every other call.
  # A git wrapper earlier on PATH would find this shim when it looks for the real git,
  # causing wrapper -> shim recursion. Resolve the native binary before adding the shim.
  REAL_GIT=""
  while IFS= read -r candidate; do
    case "$(file -b -L "$candidate" 2>/dev/null)" in
      *"ELF "*|*"Mach-O "*) REAL_GIT="$candidate"; break ;;
    esac
  done < <(type -ap git)
  [ -n "$REAL_GIT" ] || { echo "FAIL: native git binary not found on PATH"; exit 1; }
  SHIM="$C2/shim-revlist"; mkdir -p "$SHIM"
  cat > "$SHIM/git" <<EOF
#!/bin/sh
for a in "\$@"; do [ "\$a" = rev-list ] && { echo "fatal: rev-list failed (test double)" >&2; exit 1; }; done
exec "$REAL_GIT" "\$@"
EOF
  chmod +x "$SHIM/git"
  new_copy "claude-revlist-fails"; commit_in_copy "current/WeekPlan W45.md" "strategy-session: rev-list fails"
  for sh in bash zsh; do
    command -v "$sh" >/dev/null 2>&1 || { echo "SKIP: $sh not found, the publication block is not run in it"; continue; }
    if [ "$sh" = zsh ]; then publish_copy env "PATH=$SHIM:$PATH" zsh -f; else publish_copy env "PATH=$SHIM:$PATH" bash; fi
    [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -q 'не удалось получить список коммитов' && ! printf '%s' "$OUT" | grep -q 'Публиковать нечего' \
      && [ "$(git --git-dir="$ORIGIN" rev-parse main)" = "$before" ] \
      && check "publication ($sh), git rev-list fails: exit 1 with the reason, not 'nothing to publish'" ok \
      || { detail "rc=$RC out=$OUT"; check "publication ($sh), git rev-list fails: exit 1 with the reason, not 'nothing to publish'" bad; }
  done
  # Uncommitted changes are not published: the block says so in one line, its exit code stays the same.
  new_copy "claude-uncommitted"; printf 'draft\n' >> "$COPY/docs/Strategy.md"
  publish_copy
  [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'ВНИМАНИЕ: в копии есть незакоммиченные изменения, они не опубликованы' \
    && printf '%s' "$OUT" | grep -q 'Публиковать нечего' && [ "$(git --git-dir="$ORIGIN" rev-parse main)" = "$before" ] \
    && check "publication, uncommitted changes and no commit: one warning line, 'nothing to publish', exit 0" ok \
    || { detail "rc=$RC out=$OUT"; check "publication, uncommitted changes and no commit: one warning line, 'nothing to publish', exit 0" bad; }
  # The block stops on the first refusal: the first of two commits conflicts with origin (exit 3 of the
  # publisher), the second one is not sent. Both copies are made before a racer lands the conflicting files.
  for sh in bash zsh; do
    command -v "$sh" >/dev/null 2>&1 || continue
    new_copy "claude-stop-$sh"
    commit_in_copy "docs/race-$sh.md" "strategy-session: first, conflicts ($sh)"
    commit_in_copy "docs/after-$sh.md" "strategy-session: second, not sent ($sh)"
  done
  RACER="$C2/racer"; git clone -q "$ORIGIN" "$RACER" 2>/dev/null
  printf 'theirs\n' > "$RACER/docs/race-bash.md"; printf 'theirs\n' > "$RACER/docs/race-zsh.md"
  git -C "$RACER" add docs && git -C "$RACER" commit -q -m "racer" && git -C "$RACER" push -q origin HEAD:main
  for sh in bash zsh; do
    command -v "$sh" >/dev/null 2>&1 || { echo "SKIP: $sh not found, the publication block is not run in it"; continue; }
    COPY="$C2/isolated-worktrees/claude-stop-$sh"; before=$(git --git-dir="$ORIGIN" rev-parse main)
    if [ "$sh" = zsh ]; then publish_copy zsh -f; else publish_copy; fi
    [ "$RC" -eq 3 ] && [ "$(git --git-dir="$ORIGIN" rev-parse main)" = "$before" ] && ! git --git-dir="$ORIGIN" cat-file -e "main:docs/after-$sh.md" 2>/dev/null \
      && check "publication ($sh), the first of two commits is refused: the block stops with its code (3), the second is not sent" ok \
      || { detail "rc=$RC out=$OUT"; check "publication ($sh), the first of two commits is refused: the block stops with its code (3), the second is not sent" bad; }
  done

  # C1 compat: update.sh never replaces an existing scripts/ds-publish.sh, so an install may keep one that
  # does not know --branch and answers it with usage, exit 1: its own one with a fixed target branch (made
  # here from the seed copy delivered before --branch existed: main always, the same strict argument
  # parser) or that seed copy itself (the fixture, byte for byte). --branch goes only to one that knows it,
  # judged by the file's text (a heuristic): an argument-parsing branch for it, not the word. The own one
  # names --branch in a comment, in git status / git log calls and in its usage text, and parses none.
  OLD_PUB="$TEMPLATE_ROOT/scripts/tests/fixtures/ds-publish-637a526.sh"
  OWN_PUB="$C2/own-ds-publish.sh"
  # shellcheck disable=SC2016  # literal publisher lines (${BRANCH:-main}, ${SHA:0:12}), not expansions
  sed -e 's/^BRANCH="\${BRANCH:-main}"$/BRANCH="main"  # this installation always publishes to main/' \
      -e '2a\
# no --branch support: this installation always publishes to main' \
      -e 's/^echo "ds-publish: \${SHA:0:12}/git -C "$REPO" status --porcelain --branch >\/dev\/null 2>\&1; git -C "$REPO" log --branches -1 >\/dev\/null 2>\&1; &/' \
      -e 's/\[--from-commit SHA\]" >&2$/[--from-commit SHA] [--branch NAME]" >\&2/' \
      "$OLD_PUB" > "$OWN_PUB"
  [ -f "$OLD_PUB" ] && ! grep -qF -e '--branch' "$OLD_PUB" && grep -q '^BRANCH="main"  # this installation' "$OWN_PUB" \
    && [ "$(grep -c -e '--branch' "$OWN_PUB")" -ge 3 ] \
    && check "compat fixtures: the old seed copy never names --branch, the own publisher (main always) names it without parsing it" ok \
    || check "compat fixtures: the old seed copy never names --branch, the own publisher (main always) names it without parsing it" bad
  # The block's knows_branch on one-line publishers, in bash and zsh, and the same expression as pick_publisher.
  KB_FN=$(grep -m1 '^knows_branch() {' "$BLOCKS/$f")
  KB_DIR="$C2/knows-branch"; mkdir -p "$KB_DIR"
  kb_line() { printf '#!/bin/bash\n%s\n' "$2" > "$KB_DIR/$1.sh"; }
  # shellcheck disable=SC2016  # publisher lines written as text, not expanded here
  {
    kb_line yes-plain '    --branch) TARGET_BRANCH="$2"; shift 2 ;;'
    kb_line yes-alt-first '    -b|--branch) TARGET_BRANCH="$2"; shift 2 ;;'
    kb_line yes-alt-last '    --branch|-b) TARGET_BRANCH="$2"; shift 2 ;;'
    kb_line yes-equals '    --branch=*) TARGET_BRANCH="${1#--branch=}"; shift ;;'
    kb_line no-comment '# no --branch support: this publisher always publishes to main'
    kb_line no-status '    git -C "$REPO" status --porcelain --branch >/dev/null 2>&1'
    kb_line no-log '    git -C "$REPO" log --branches -1 >/dev/null 2>&1'
    kb_line no-usage '    echo "usage: ds-publish.sh <repo-dir> <priority> [--from-commit SHA] [--branch NAME]" >&2'
  }
  kb_expected="yes-plain=yes yes-alt-first=yes yes-alt-last=yes yes-equals=yes no-comment=no no-status=no no-log=no no-usage=no "
  # shellcheck disable=SC2016  # the script runs in the child shell
  kb_script='eval "$KB_FN"; for n in yes-plain yes-alt-first yes-alt-last yes-equals no-comment no-status no-log no-usage; do if knows_branch "$KB_DIR/$n.sh"; then printf "%s=yes " "$n"; else printf "%s=no " "$n"; fi; done'
  for sh in bash zsh; do
    command -v "$sh" >/dev/null 2>&1 || { echo "SKIP: $sh not found, knows_branch is not run in it"; continue; }
    if [ "$sh" = zsh ]; then kb_got=$(KB_FN="$KB_FN" KB_DIR="$KB_DIR" zsh -f -c "$kb_script" 2>&1); else kb_got=$(KB_FN="$KB_FN" KB_DIR="$KB_DIR" bash -c "$kb_script" 2>&1); fi
    [ "$kb_got" = "$kb_expected" ] && check "knows_branch ($sh): parse branches count, a comment / git status --branch / git log --branches / usage text do not" ok \
      || { detail "got: $kb_got"; check "knows_branch ($sh): parse branches count, a comment / git status --branch / git log --branches / usage text do not" bad; }
  done
  kb_ere_skill=$(printf '%s\n' "$KB_FN" | sed -n "s/.*grep -qE -e '\([^']*\)'.*/\1/p")
  kb_ere_runner=$(sed -n "/^pick_publisher() {/,/^}/s/.*grep -qE -e '\([^']*\)'.*/\1/p" "$TEMPLATE_ROOT/roles/strategist/scripts/strategist.sh")
  [ -n "$kb_ere_skill" ] && [ "$kb_ere_skill" = "$kb_ere_runner" ] \
    && check "knows_branch: the skill and pick_publisher in strategist.sh use the same expression" ok \
    || { detail "skill: $kb_ere_skill | strategist.sh: $kb_ere_runner"; check "knows_branch: the skill and pick_publisher in strategist.sh use the same expression" bad; }
  publisher_on_origin "$OWN_PUB"
  for sh in bash zsh; do
    command -v "$sh" >/dev/null 2>&1 || { echo "SKIP: $sh not found, the publication block is not run in it"; continue; }
    new_copy "claude-own-$sh"; commit_in_copy "current/WeekPlan W42.md" "strategy-session: own publisher, $sh"
    if [ "$sh" = zsh ]; then publish_copy zsh -f; else publish_copy; fi
    [ "$RC" -eq 0 ] && [ "$(origin_top)" = "strategy-session: own publisher, $sh" ] && only_main && ! printf '%s' "$OUT" | grep -q 'usage:' \
      && check "publication ($sh), own publisher naming --branch without a parse branch (main always): called without it, origin/main got the commit" ok \
      || { detail "rc=$RC out=$OUT"; check "publication ($sh), own publisher naming --branch without a parse branch (main always): called without it, origin/main got the commit" bad; }
  done
  publisher_on_origin "$OLD_PUB"
  cp "$PUB" "$CANON/scripts/ds-publish.sh"   # the current version in the canon's working tree only
  new_copy "claude-oldcopy"; commit_in_copy "current/WeekPlan W43.md" "strategy-session: old copy, current canon"
  publish_copy
  [ "$RC" -eq 0 ] && [ "$(origin_top)" = "strategy-session: old copy, current canon" ] && only_main \
    && check "publication, the copy's publisher without --branch, the canon's with it: the canon's publishes" ok \
    || { detail "rc=$RC out=$OUT"; check "publication, the copy's publisher without --branch, the canon's with it: the canon's publishes" bad; }
  git -C "$CANON" checkout -q -- scripts/ds-publish.sh

  # Upgraded install: origin/main has no publisher, the canon holds it untracked (update.sh copies it in
  # without a commit), so a copy made from origin/main has none: the canon's file publishes the copy.
  git -C "$CANON" pull -q --ff-only origin main 2>/dev/null   # the canon is behind the publications above
  git -C "$CANON" rm -q -f scripts/ds-publish.sh && git -C "$CANON" commit -q -m "no publisher on origin" && git -C "$CANON" push -q origin HEAD:main
  mkdir -p "$CANON/scripts" && cp "$PUB" "$CANON/scripts/ds-publish.sh"   # git rm took the emptied folder away
  [ -f "$CANON/scripts/ds-publish.sh" ] && [ -z "$(git -C "$CANON" ls-files scripts/ds-publish.sh)" ] \
    && check "upgraded fixture: the canon has the publisher untracked" ok || check "upgraded fixture: the canon has the publisher untracked" bad
  new_copy "claude-s2"
  [ -e "$COPY/scripts/ds-publish.sh" ] && check "upgraded fixture: the copy has no publisher" bad || check "upgraded fixture: the copy has no publisher" ok
  commit_in_copy "current/WeekPlan W41.md" "strategy-session: next week plan"
  publish_copy
  [ "$RC" -eq 0 ] && [ "$(origin_top)" = "strategy-session: next week plan" ] \
    && check "publication, upgraded install: the canon's publisher publishes the copy's commit" ok \
    || { detail "rc=$RC out=$OUT"; check "publication, upgraded install: the canon's publisher publishes the copy's commit" bad; }
  # The copy has no publisher and the canon's does not know --branch (the installation's own, untracked):
  # the canon's still runs, called without --branch.
  cp "$OWN_PUB" "$CANON/scripts/ds-publish.sh"
  new_copy "claude-own-canon-only"; commit_in_copy "current/WeekPlan W46.md" "strategy-session: own publisher in the canon only"
  publish_copy
  [ "$RC" -eq 0 ] && [ "$(origin_top)" = "strategy-session: own publisher in the canon only" ] && ! printf '%s' "$OUT" | grep -q 'usage:' \
    && check "publication, no publisher in the copy, the canon's without --branch: the canon's runs without it and publishes" ok \
    || { detail "rc=$RC out=$OUT"; check "publication, no publisher in the copy, the canon's without --branch: the canon's runs without it and publishes" bad; }

  # No publisher anywhere: a non-zero exit that names update.sh, nothing published
  rm "$CANON/scripts/ds-publish.sh"
  commit_in_copy "current/WeekPlan W41.md" "strategy-session: not published"
  before=$(git --git-dir="$ORIGIN" rev-parse main)
  publish_copy
  [ "$RC" -ne 0 ] && printf '%s' "$OUT" | grep -q 'update.sh' && [ "$(git --git-dir="$ORIGIN" rev-parse main)" = "$before" ] \
    && check "publication, no publisher anywhere: non-zero exit, update.sh named, nothing published" ok \
    || { detail "rc=$RC out=$OUT"; check "publication, no publisher anywhere: non-zero exit, update.sh named, nothing published" bad; }
fi

[ "$FAILURES" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$FAILURES FAILED"; exit 1; }
