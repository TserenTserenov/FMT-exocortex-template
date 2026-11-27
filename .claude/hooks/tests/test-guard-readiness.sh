#!/bin/bash
# test-guard-readiness.sh — the readiness check of the destructive-command guard (WP-592 F6):
# the receipt destructive-guard.sh leaves when it blocks a probe, and the four outcomes of
# .claude/scripts/guard-readiness.sh verify. The agent's two tool calls are played here by
# running the allowed command directly and feeding the forbidden one to the hook as JSON.
#
# Run: bash .claude/hooks/tests/test-guard-readiness.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$(cd "$HERE/../../.." && pwd)"
HOOK="$TEMPLATE/.claude/hooks/destructive-guard.sh"
CHECK="$TEMPLATE/.claude/scripts/guard-readiness.sh"
SITE=$(mktemp -d)
PASS=0
FAIL=0
trap 'chmod -R u+w "$SITE" 2>/dev/null; find "$SITE" -depth -delete 2>/dev/null' EXIT
git -C "$SITE" init -q
SITE=$(cd "$SITE" && pwd -P)

ok() { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
expect_eq() { if [ "$2" = "$3" ]; then ok; else bad "$1 (ожидалось «$3», получено «$2»)"; fi; }

# begin_probe — prints the probe id; the full begin output goes to $SITE/begin.out
begin_probe() {
  (cd "$SITE" && bash "$CHECK" begin) >"$SITE/begin.out" || { bad "begin упал"; return 1; }
  sed -n 's/^guard-readiness: probe //p' "$SITE/begin.out"
}
probe_cmd() { sed -n "s/^  $1\\. //p" "$SITE/begin.out"; }
# hook_run COMMAND [CWD] — the hook's exit code
hook_run() {
  jq -nc --arg c "$1" --arg d "${2:-$SITE}" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}' \
    | bash "$HOOK" >/dev/null 2>"$SITE/hook.err"
  echo $?
}
verify_probe() {
  (cd "$SITE" && bash "$CHECK" verify "$1") >"$SITE/verify.out" 2>&1
  echo "$? $(head -1 "$SITE/verify.out")"
}

# 1. ready: the allowed command runs, the hook blocks the forbidden one and leaves a receipt.
id=$(begin_probe)
dir="$SITE/.iwe-runtime/guard-readiness/$id"
expect_eq "begin: формат номера пробы" "$([[ "$id" =~ ^[0-9a-f]{24}$ ]] && echo yes)" yes
expect_eq "begin: первая команда" "$(probe_cmd 1)" "touch $dir/allowed"
expect_eq "begin: вторая команда" "$(probe_cmd 2)" "rm -rf $dir/fixture"
(cd "$SITE" && eval "$(probe_cmd 1)")
expect_eq "сторож запрещает удаление пробы" "$(hook_run "$(probe_cmd 2)")" 2
expect_eq "квитанция сторожа" "$(cat "$dir/guard-blocked" 2>/dev/null)" "blocked $id"
expect_eq "verify: ready" "$(verify_probe "$id")" "0 guard-readiness: ready"
expect_eq "ready убирает папку пробы" "$([ -e "$dir" ] && echo left || echo removed)" removed

# 2. not-protected: no guard, the forbidden command really ran.
id=$(begin_probe); dir="$SITE/.iwe-runtime/guard-readiness/$id"
touch "$dir/allowed"; rm -f "$dir/fixture/data.txt"; rmdir "$dir/fixture"
expect_eq "verify: not-protected" "$(verify_probe "$id")" "1 guard-readiness: not-protected"

# 3. not-confirmed: someone else refused the command (no receipt, fixture intact).
id=$(begin_probe); dir="$SITE/.iwe-runtime/guard-readiness/$id"
touch "$dir/allowed"
expect_eq "verify: not-confirmed без квитанции" "$(verify_probe "$id")" "1 guard-readiness: not-confirmed"
expect_eq "не ready — папка оставлена" "$([ -d "$dir" ] && echo left)" left

# 4. not-confirmed: the guard blocked, then the fixture went another way.
printf 'blocked %s\n' "$id" >"$dir/guard-blocked"; rm -f "$dir/fixture/data.txt"
expect_eq "verify: квитанция есть, папки нет" "$(verify_probe "$id")" "1 guard-readiness: not-confirmed"

# 5. blocks-all: the allowed command did not run.
id=$(begin_probe); dir="$SITE/.iwe-runtime/guard-readiness/$id"
hook_run "$(probe_cmd 2)" >/dev/null
expect_eq "verify: blocks-all" "$(verify_probe "$id")" "1 guard-readiness: blocks-all"

# 6. A relative path is read from the hook's cwd; a subfolder cwd misses it and writes nothing.
id=$(begin_probe); dir="$SITE/.iwe-runtime/guard-readiness/$id"
expect_eq "относительный путь: запрет" "$(hook_run "rm -rf .iwe-runtime/guard-readiness/$id/fixture")" 2
expect_eq "относительный путь: квитанция" "$(cat "$dir/guard-blocked" 2>/dev/null)" "blocked $id"
rm -f "$dir/guard-blocked"; mkdir -p "$SITE/sub"
expect_eq "другая папка: запрет" "$(hook_run "rm -rf .iwe-runtime/guard-readiness/$id/fixture" "$SITE/sub")" 2
expect_eq "другая папка: квитанции нет" "$([ -e "$dir/guard-blocked" ] && echo written || echo none)" none
expect_eq "квитанция не создаёт папок" "$([ -e "$SITE/sub/.iwe-runtime" ] && echo created || echo none)" none

# 7. No receipt into a folder the check did not make (no probe.id, or another id inside).
fake="$SITE/.iwe-runtime/guard-readiness/0123456789abcdef01234567"
mkdir -p "$fake/fixture"
expect_eq "чужая папка: запрет" "$(hook_run "rm -rf $fake/fixture")" 2
expect_eq "чужая папка: квитанции нет" "$([ -e "$fake/guard-blocked" ] && echo written || echo none)" none
echo ffffffffffffffffffffffff >"$fake/probe.id"
hook_run "rm -rf $fake/fixture" >/dev/null
expect_eq "другой номер: квитанции нет" "$([ -e "$fake/guard-blocked" ] && echo written || echo none)" none

# 8. A failed receipt write keeps the block.
id=$(begin_probe); dir="$SITE/.iwe-runtime/guard-readiness/$id"
chmod a-w "$dir"
expect_eq "папка только для чтения: запрет остаётся" "$(hook_run "$(probe_cmd 2)")" 2
chmod u+w "$dir"

# 9. The allowed command of the probe passes the hook.
expect_eq "безобидная команда проходит" "$(hook_run "$(probe_cmd 1)")" 0

# 10. Usage errors.
(cd "$SITE" && bash "$CHECK" verify 0123) >/dev/null 2>&1
expect_eq "неверный номер" $? 2
(cd "$SITE" && bash "$CHECK" verify abcdefabcdefabcdefabcdef) >/dev/null 2>&1
expect_eq "нет такой пробы" $? 2

echo "guard-readiness: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
