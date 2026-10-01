#!/usr/bin/env bash
# test_issue_975_completion_reminder_r23.sh — regression for issue #975.
#
# .claude/hooks/protocol-completion-reminder.sh used to append "run /verify
# (Haiku R23)" unconditionally after the skills day-open, day-close,
# run-protocol, wp-new and after reading ANY path containing "protocol-"
# (protocol-stop-gate.sh included), and it never read params.yaml: with
# `verify_quick_close: false` the agent still got the opposite order.
#
# Contract after the fix:
#   * R23 is reminded only in closings: skill day-close, skill run-protocol
#     whose args name a close, reading memory/protocol-close.md or
#     memory/protocol-month-close.md (Month Close always carried it);
#   * `verify_quick_close: false` (params.yaml of the WORKSPACE root, not of
#     the cwd) silences Quick Close only (run-protocol close / close session,
#     protocol-close.md); Day, Week and Month Close do not obey the key (the
#     docs call it a Quick Close parameter: memory/protocol-close.md,
#     extend/SKILL.md);
#   * day-open, wp-new, protocol-open and the other protocol-*.md carry no R23 text;
#   * the text names the real mechanism (sub-agent Haiku, closing checklist),
#     never the /verify skill (which checks an artifact against a Pack standard);
#   * only memory/protocol-*.md is matched, not hooks like protocol-stop-gate.sh.
#
# No network, no real $HOME: every hook run gets a temporary HOME/TMPDIR.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$ROOT/.claude/hooks/protocol-completion-reminder.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home" "$TMP/tmp"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required (the hook parses stdin with it)"; exit 1; }
[ -f "$HOOK" ] || { echo "FAIL: hook not found: $HOOK"; exit 1; }

# --- fixture workspace: WS/params.yaml, a governance repository under it (non-default
# name on purpose: the hook must not depend on it), a deep subdirectory ---
WS="$TMP/ws"
GOV="$WS/my-governance"
SUB="$GOV/sessions/deep"
ELSEWHERE="$TMP/elsewhere"
mkdir -p "$SUB" "$ELSEWHERE"

# params <dir> <text with \n / \r escapes> : (re)write <dir>/params.yaml
params() { mkdir -p "$1"; printf '%b' "$2" > "$1/params.yaml"; }
no_params() { rm -f "$1/params.yaml"; }

skill_json() { # <skill> [args] — args key omitted when empty
    jq -nc --arg s "$1" --arg a "${2-}" \
        'if $a == "" then {tool_name:"Skill",tool_input:{skill:$s}}
         else {tool_name:"Skill",tool_input:{skill:$s,args:$a}} end'
}
read_json() { jq -nc --arg p "$1" '{tool_name:"Read",tool_input:{file_path:$p}}'; }

# run_hook <project_dir|""> <workspace|""> <cwd> <json> [hook-file]
# Sets HOOK_OUT (stdout) and HOOK_RC. Inherited CLAUDE_PROJECT_DIR / IWE_WORKSPACE
# are always dropped: they would turn the test into a function of the machine.
run_hook() {
    local proj="$1" ws="$2" cwd="$3" json="$4" hook="${5:-$HOOK}"
    local -a envs=("HOME=$TMP/home" "TMPDIR=$TMP/tmp")
    [ -n "$proj" ] && envs+=("CLAUDE_PROJECT_DIR=$proj")
    [ -n "$ws" ] && envs+=("IWE_WORKSPACE=$ws")
    HOOK_OUT=$(cd "$cwd" && printf '%s' "$json" \
        | env -u CLAUDE_PROJECT_DIR -u IWE_WORKSPACE "${envs[@]}" /bin/bash "$hook" 2>"$TMP/stderr")
    HOOK_RC=$?
}
# default: project dir = workspace root = cwd
run_ws() { run_hook "$WS" "" "$WS" "$1"; }

ctx() { printf '%s' "$HOOK_OUT" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null; }

# Reminder carries the R23 sub-agent text, names the checklist, never /verify.
expect_r23() { # <desc>
    local c
    c=$(ctx)
    if [ "$HOOK_RC" -eq 0 ] && [[ $c == *"R23"* && $c == *"sub-agent Haiku"* && $c == *"чеклист"* && $c != *"/verify"* ]]; then
        ok "$1"
    else
        bad "$1 (rc=$HOOK_RC) — context: ${c:-<empty>}"
    fi
}
# Reminder still fires (steps are demanded) but says nothing about R23 or /verify.
expect_steps_without_r23() { # <desc>
    local c
    c=$(ctx)
    if [ "$HOOK_RC" -eq 0 ] && [[ $c == *"ОБЯЗАТЕЛЬНО"* && $c != *"R23"* && $c != *"/verify"* && $c != *"Haiku"* ]]; then
        ok "$1"
    else
        bad "$1 (rc=$HOOK_RC) — context: ${c:-<empty>}"
    fi
}
expect_silent() { # <desc> — hook answers exactly {}
    if [ "$HOOK_RC" -eq 0 ] && [ "$HOOK_OUT" = '{}' ]; then
        ok "$1"
    else
        bad "$1 (rc=$HOOK_RC) — output: ${HOOK_OUT:-<empty>}"
    fi
}
expect_valid_json() { # <desc>
    if printf '%s' "$HOOK_OUT" | jq -e '.hookSpecificOutput.hookEventName == "PostToolUse" and (.hookSpecificOutput.additionalContext | type == "string")' >/dev/null 2>&1; then
        ok "$1"
    else
        bad "$1 — output: ${HOOK_OUT:-<empty>}"
    fi
}

PROTO_OPEN="$WS/memory/protocol-open.md"
PROTO_CLOSE="$WS/memory/protocol-close.md"

# ============================ A. skills and protocol reads ============================
params "$WS" 'verify_quick_close: false\n'
run_ws "$(skill_json day-open)"
expect_steps_without_r23 "day-open + key false: steps demanded, no R23/verify"
no_params "$WS"
run_ws "$(skill_json day-open)"
expect_steps_without_r23 "day-open + no params.yaml: no R23/verify"
params "$WS" 'verify_quick_close: true\n'
run_ws "$(skill_json day-open)"
expect_steps_without_r23 "day-open + key true: Day Open never gets R23"
expect_valid_json "day-open reminder is valid PostToolUse JSON"
run_ws "$(skill_json wp-new)"
expect_steps_without_r23 "wp-new + key true: no R23 (not a closing)"
run_ws "$(read_json "$PROTO_OPEN")"
expect_steps_without_r23 "Read memory/protocol-open.md + key true: no R23"
run_ws "$(read_json "$WS/memory/protocol-work.md")"
expect_steps_without_r23 "Read memory/protocol-work.md + key true: no R23"
run_ws "$(read_json "memory/protocol-open.md")"
expect_steps_without_r23 "Read relative memory/protocol-open.md: still matched, no R23"

run_ws "$(skill_json day-close)"
expect_r23 "day-close + key true: R23 sub-agent reminder"
expect_valid_json "day-close reminder is valid PostToolUse JSON"
params "$WS" 'verify_quick_close: false\n'
run_ws "$(skill_json day-close)"
expect_r23 "day-close + key false: Day Close does not obey the Quick Close key"

# ---- run-protocol: the closing is read from args ----
params "$WS" 'verify_quick_close: true\n'
run_ws "$(skill_json run-protocol close)"
expect_r23 "run-protocol close + key true: R23 (Quick Close)"
run_ws "$(skill_json run-protocol 'close session')"
expect_r23 "run-protocol 'close session' + key true: R23"
run_ws "$(skill_json run-protocol Close)"
expect_r23 "run-protocol Close (capital) + key true: R23"
run_ws "$(skill_json run-protocol)"
expect_steps_without_r23 "run-protocol without args: closing unknown, no R23"
run_ws '{"tool_name":"Skill","tool_input":{"skill":"run-protocol","args":""}}'
expect_steps_without_r23 "run-protocol with empty args: no R23"
run_ws "$(skill_json run-protocol 'open day')"
expect_steps_without_r23 "run-protocol 'open day': no R23"
run_ws "$(skill_json run-protocol day-open)"
expect_steps_without_r23 "run-protocol day-open: no R23"
run_ws "$(skill_json run-protocol 'open session')"
expect_steps_without_r23 "run-protocol 'open session': no R23"
run_ws "$(skill_json run-protocol 'fix the close button styling')"
expect_steps_without_r23 "run-protocol with a task text mentioning close: not a closing"

params "$WS" 'verify_quick_close: false\n'
run_ws "$(skill_json run-protocol close)"
expect_steps_without_r23 "run-protocol close + key false: Quick Close reminder silenced"
run_ws "$(skill_json run-protocol 'close session')"
expect_steps_without_r23 "run-protocol 'close session' + key false: silenced"
run_ws "$(skill_json run-protocol 'close day')"
expect_r23 "run-protocol 'close day' + key false: Day Close ignores the key"
run_ws "$(skill_json run-protocol day-close)"
expect_r23 "run-protocol day-close + key false: Day Close ignores the key"
run_ws "$(skill_json run-protocol week-close)"
expect_r23 "run-protocol week-close + key false: Week Close has its own R23 step, key is Quick Close only"
run_ws "$(skill_json run-protocol month-close)"
expect_r23 "run-protocol month-close + key false: Month Close keeps R23 (not a Quick Close)"

# default is ON: no file, or a file without the key
no_params "$WS"
run_ws "$(skill_json run-protocol close)"
expect_r23 "run-protocol close + no params.yaml: default enabled"
params "$WS" 'author_mode: false\n'
run_ws "$(skill_json run-protocol close)"
expect_r23 "run-protocol close + params.yaml without the key: default enabled"

# ---- reading the closing protocol itself ----
params "$WS" 'verify_quick_close: true\n'
run_ws "$(read_json "$PROTO_CLOSE")"
expect_r23 "Read protocol-close.md + key true: R23"
params "$WS" 'verify_quick_close: false\n'
run_ws "$(read_json "$PROTO_CLOSE")"
expect_steps_without_r23 "Read protocol-close.md + key false: no R23"
params "$WS" 'author_mode: false\n'
run_ws "$(read_json "$PROTO_CLOSE")"
expect_r23 "Read protocol-close.md + no key: R23 (default enabled)"
no_params "$WS"
run_ws "$(read_json "$PROTO_CLOSE")"
expect_r23 "Read protocol-close.md + no params.yaml: R23"
# Month Close always carried R23 on reading its protocol; the Quick Close key does not apply.
run_ws "$(read_json "$WS/memory/protocol-month-close.md")"
expect_r23 "Read protocol-month-close.md + no params.yaml: R23 stays"
params "$WS" 'verify_quick_close: false\n'
run_ws "$(read_json "$WS/memory/protocol-month-close.md")"
expect_r23 "Read protocol-month-close.md + key false: Month Close ignores the Quick Close key"
run_ws "$(read_json "$WS/memory/protocol-dt-integration.md")"
expect_steps_without_r23 "Read protocol-dt-integration.md: not a closing, no R23"

# ---- matcher: memory/protocol-*.md only ----
params "$WS" 'verify_quick_close: true\n'
run_ws "$(read_json "$WS/.claude/hooks/protocol-stop-gate.sh")"
expect_silent "Read hooks/protocol-stop-gate.sh: not a protocol, hook silent"
run_ws "$(read_json "$WS/.claude/hooks/protocol-artifact-validate.sh")"
expect_silent "Read hooks/protocol-artifact-validate.sh: hook silent"
run_ws "$(read_json "$WS/docs/protocol-overview.md")"
expect_silent "Read docs/protocol-overview.md (outside memory/): hook silent"
run_ws "$(skill_json think)"
expect_silent "unrelated skill: hook silent"
run_ws "$(read_json "$WS/README.md")"
expect_silent "unrelated Read: hook silent"
run_ws 'not json at all'
expect_silent "malformed stdin: hook still answers {} and exits 0"

# ============================ B. how the key is written ============================
# Quick Close is the probe (run-protocol close): R23 present = key NOT off, absent = key off.
probe_off() { # <desc> <params text>
    params "$WS" "$2"
    run_ws "$(skill_json run-protocol close)"
    expect_steps_without_r23 "key off: $1"
}
probe_on() { # <desc> <params text>
    params "$WS" "$2"
    run_ws "$(skill_json run-protocol close)"
    expect_r23 "key stays on: $1"
}
probe_off 'quoted value with trailing comment' 'verify_quick_close: "false"   # weekly only\n'
probe_off "single-quoted, capitalised 'False'" "verify_quick_close: 'False'\n"
probe_off 'upper case FALSE' 'verify_quick_close: FALSE\n'
probe_off 'extra spaces around the value' 'verify_quick_close:    false   \n'
probe_off 'plain trailing comment' 'verify_quick_close: false # manual weekly R23\n'
probe_off 'CRLF line ending' 'verify_quick_close: false\r\n'
probe_off 'key among other keys' 'author_mode: false\nverify_quick_close: false\nauto_verify_code: true\n'
probe_on 'commented-out key' '# verify_quick_close: false\n'
probe_on 'true with a comment mentioning false' 'verify_quick_close: true  # not false\n'
probe_on 'only a literal false switches it off (no = still on)' 'verify_quick_close: no\n'
probe_on 'empty value' 'verify_quick_close:\n'
probe_on 'another key sharing the prefix' 'verify_quick_close_extra: false\n'
probe_on 'false glued to a comment sign is not YAML false' 'verify_quick_close: false#x\n'

# ============================ C. where params.yaml is looked up ============================
# Session started in a governance repository: the key lives in the workspace root.
params "$WS" 'verify_quick_close: false\n'
no_params "$GOV"
run_hook "$GOV" "" "$SUB" "$(skill_json run-protocol close)"
expect_steps_without_r23 "project dir = governance repo, params.yaml one level up (false): silenced"
params "$WS" 'verify_quick_close: true\n'
run_hook "$GOV" "" "$SUB" "$(skill_json run-protocol close)"
expect_r23 "project dir = governance repo, params.yaml one level up (true): R23"
# nearest params.yaml wins
params "$GOV" 'verify_quick_close: true\n'
params "$WS" 'verify_quick_close: false\n'
run_hook "$GOV" "" "$SUB" "$(skill_json run-protocol close)"
expect_r23 "nearest params.yaml (true) beats a farther one (false)"
params "$GOV" 'verify_quick_close: false\n'
params "$WS" 'verify_quick_close: true\n'
run_hook "$GOV" "" "$SUB" "$(skill_json run-protocol close)"
expect_steps_without_r23 "nearest params.yaml (false) beats a farther one (true)"
no_params "$GOV"

# The lookup starts from the project directory, never from the cwd of the call.
params "$WS" 'verify_quick_close: false\n'
run_hook "$WS" "" "$ELSEWHERE" "$(skill_json run-protocol close)"
expect_steps_without_r23 "cwd outside the workspace, project dir = workspace (false): found via the project dir"
run_hook "$ELSEWHERE" "" "$WS" "$(skill_json run-protocol close)"
expect_r23 "cwd inside a workspace with false, project dir elsewhere: cwd is not consulted, default on"

# IWE_WORKSPACE, when set, is THE workspace: nothing is climbed.
params "$WS" 'verify_quick_close: false\n'
run_hook "$ELSEWHERE" "$WS" "$ELSEWHERE" "$(skill_json run-protocol close)"
expect_steps_without_r23 "IWE_WORKSPACE points at the params.yaml (false) while the project dir is elsewhere"
mkdir -p "$TMP/other-ws"
run_hook "$WS" "$TMP/other-ws" "$WS" "$(skill_json run-protocol close)"
expect_r23 "IWE_WORKSPACE without params.yaml wins over a climbed params.yaml (false): default on"

# Climb limit: the start directory plus at most 4 levels up.
LIM="$TMP/lim"
mkdir -p "$LIM/a/b/c/d/e"
params "$LIM" 'verify_quick_close: false\n'
run_hook "$LIM/a/b/c/d" "" "$LIM/a/b/c/d" "$(skill_json run-protocol close)"
expect_steps_without_r23 "params.yaml exactly 4 levels above the project dir: found"
run_hook "$LIM/a/b/c/d/e" "" "$LIM/a/b/c/d/e" "$(skill_json run-protocol close)"
expect_r23 "params.yaml 5 levels above the project dir: not looked for, default on"

# CLAUDE_PROJECT_DIR unset: the workspace is taken from the hook's own location.
WS2="$TMP/ws2"
mkdir -p "$WS2/.claude/hooks" "$WS2/somewhere/else"
cp "$HOOK" "$WS2/.claude/hooks/protocol-completion-reminder.sh"
params "$WS2" 'verify_quick_close: false\n'
run_hook "" "" "$WS2/somewhere/else" "$(skill_json run-protocol close)" "$WS2/.claude/hooks/protocol-completion-reminder.sh"
expect_steps_without_r23 "CLAUDE_PROJECT_DIR unset: workspace derived from the hook location (false)"

# ============================ D. the run-protocol skill text ============================
# The skill is loaded together with this reminder, so it must not demand a verification
# step on every protocol (open included) or name the /verify skill while the hook says
# otherwise: the check is a Haiku sub-agent (R23), closings only, Quick Close by the key.
SKILL_MD="$ROOT/.claude/skills/run-protocol/SKILL.md"
section() { awk -v n="$1" '$0 ~ "^## " n {f=1; next} /^## /{f=0} f' "$SKILL_MD"; }
STEP2=$(section 'Шаг 2')
STEP4=$(section 'Шаг 4')

if grep -q '/verify' "$SKILL_MD"; then
    bad "run-protocol skill still names the /verify skill"
else
    ok "run-protocol skill: the /verify skill is not named (the closing check is a Haiku sub-agent)"
fi
if grep -q 'Последняя задача ВСЕГДА' "$SKILL_MD"; then
    bad "run-protocol skill still ends every protocol with an unconditional verification task"
else
    ok "run-protocol skill: no unconditional 'last task is always the verification'"
fi
if [[ $STEP2 == *"только для close-протоколов"* ]]; then
    ok "run-protocol skill step 2: the verification task is for close protocols only"
else
    bad "run-protocol skill step 2 does not restrict the verification task to close protocols"
fi
missing=""
for token in 'Quick Close' 'Day Close' 'Week Close' 'Month Close' 'verify_quick_close'; do
    [[ $STEP4 == *"$token"* ]] || missing="$missing [$token]"
done
if [ -z "$missing" ]; then
    ok "run-protocol skill step 4: closings only, Quick Close by verify_quick_close, the other closings ignore it"
else
    bad "run-protocol skill step 4 lacks:$missing"
fi
missing=""
for token in 'sub-agent Haiku' 'R23' 'чеклист'; do
    [[ $STEP4 == *"$token"* ]] || missing="$missing [$token]"
done
if [ -z "$missing" ]; then
    ok "run-protocol skill step 4: names the Haiku sub-agent (R23) checking the closing checklist"
else
    bad "run-protocol skill step 4 does not name the real mechanism, lacks:$missing"
fi

echo "---"
echo "issue #975: passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
