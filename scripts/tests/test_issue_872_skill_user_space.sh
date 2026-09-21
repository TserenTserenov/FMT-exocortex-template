#!/usr/bin/env bash
# test_issue_872_skill_user_space.sh - regression for issue #872.
#
# The PreToolUse hook .claude/hooks/extensions-gate.sh denied ANY edit of a
# platform (L1) .claude/skills/<name>/SKILL.md for non-author installs, while
# update.sh deliberately preserves the block between the lines
# "<!-- USER-SPACE -->" and "<!-- /USER-SPACE -->" of such a file (and
# scripts/add-skill-markers.sh adds that block to L1 skills). The suggested
# route (extensions/*.md) does not work for skills. The hook now allows a call
# whose ONLY effect lies strictly inside the single USER-SPACE block of an
# existing SKILL.md and keeps denying everything else.
#
# The REAL hook is fed REAL PreToolUse envelopes through a pipe inside a
# throwaway workspace; assertions look at the hook's real stdout/exit code
# (deny = {"decision": "block", ...}, allow = no such decision). Deny cases
# also assert the denial REASON, so a case cannot pass because of an
# unrelated failure (e.g. a crashed checker) instead of the invariant.
#
# Discrimination: EXTENSIONS_GATE_HOOK=<path> runs the same cases against
# another copy of the hook (e.g. the pre-fix one from git) - the positive
# cases must FAIL there. A hook without #872 support has no reason texts, so
# reason attribution is skipped for it (the plain deny still must hold).
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
HOOK_SRC="${EXTENSIONS_GATE_HOOK:-$ROOT/.claude/hooks/extensions-gate.sh}"

PYTHON=$(command -v python3 || true)
if [ -z "$PYTHON" ] || ! command -v jq >/dev/null 2>&1; then
    echo "SKIP: python3 and jq are required by the hook under test"
    exit 0
fi
if [ ! -f "$HOOK_SRC" ]; then
    echo "FAIL: hook under test not found: $HOOK_SRC"
    exit 1
fi
HAS_FEATURE=0
if grep -qF 'issue #872' "$HOOK_SRC"; then
    HAS_FEATURE=1
else
    echo "NOTE: hook under test has no #872 support - denial reasons are not asserted"
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
WS="$TMP/ws"
SKILL="$WS/.claude/skills/demo/SKILL.md"

pass=0
fail=0
ok() { echo "PASS: $1"; pass=$((pass + 1)); }
bad() { echo "FAIL: $1${2:+ -> $2}"; fail=$((fail + 1)); }

NL=$'\n'
CR=$'\r'
OPEN='<!-- USER-SPACE -->'
CLOSE='<!-- /USER-SPACE -->'
HEAD="---${NL}name: demo${NL}layer: L1${NL}---${NL}${NL}# Demo skill${NL}${NL}Platform text line 1.${NL}${NL}"
TAIL="${NL}${NL}Platform tail after block."
# Fixture documents (LF). The platform text never contains the word "rule".
GOOD="${HEAD}${OPEN}${NL}${CLOSE}${TAIL}${NL}"
FILLED="${HEAD}${OPEN}${NL}my rule${NL}second rule${NL}${CLOSE}${TAIL}${NL}"

# Denial reasons produced by the checker (substrings of the hook's text).
WHY_OUTSIDE='выходит за пределы блока USER-SPACE'
WHY_PAIR='корректной пары маркеров'
WHY_ORDER='неправильном порядке'
WHY_PATH='путь не канонический'
WHY_MISSING='не существует'

# Fresh workspace: hook copy, manifest listing the platform skills, SKILL.md content.
build_ws() {
    rm -rf "$WS"
    mkdir -p "$WS/.claude/hooks" "$WS/.claude/skills/demo" "$WS/.claude/skills/other" \
             "$WS/FMT-exocortex-template" "$WS/memory" "$WS/elsewhere"
    cp "$HOOK_SRC" "$WS/.claude/hooks/extensions-gate.sh"
    chmod +x "$WS/.claude/hooks/extensions-gate.sh"
    printf '%s\n' '{"files": [{"path": ".claude/skills/demo/SKILL.md"}, {"path": ".claude/skills/demo/helper.md"}, {"path": ".claude/skills/other/SKILL.md"}, {"path": ".claude/skills/gone/SKILL.md"}]}' \
        > "$WS/FMT-exocortex-template/update-manifest.json"
    printf '%s' "$1" > "$SKILL"
    printf '%s' "$GOOD" > "$WS/.claude/skills/other/SKILL.md"
    printf '%s\n' 'placeholder' > "$WS/memory/protocol-open.md"
}

json_edit() { # file old new [true]
    "$PYTHON" -c '
import json, sys
a = sys.argv
ti = {"file_path": a[1], "old_string": a[2], "new_string": a[3]}
if len(a) > 4 and a[4] == "true":
    ti["replace_all"] = True
print(json.dumps({"session_id": "t", "hook_event_name": "PreToolUse", "tool_name": "Edit", "tool_input": ti}))
' "$@"
}

json_write() { # file content
    "$PYTHON" -c '
import json, sys
a = sys.argv
print(json.dumps({"session_id": "t", "hook_event_name": "PreToolUse", "tool_name": "Write",
                  "tool_input": {"file_path": a[1], "content": a[2]}}))
' "$@"
}

json_tool() { # tool_name file
    "$PYTHON" -c '
import json, sys
a = sys.argv
print(json.dumps({"session_id": "t", "hook_event_name": "PreToolUse", "tool_name": a[1],
                  "tool_input": {"file_path": a[2], "edits": [{"old_string": "x", "new_string": "y"}]}}))
' "$@"
}

# Apply an Edit envelope to a file the way the tool would (first occurrence).
apply_edit_json() { # file json
    "$PYTHON" -c '
import json, sys
path, env = sys.argv[1], json.loads(sys.argv[2])["tool_input"]
data = open(path, "rb").read()
data = data.replace(env["old_string"].encode(), env["new_string"].encode(), 1)
open(path, "wb").write(data)
' "$1" "$2"
}

run_hook() { # json -> OUT, RC
    OUT=$(printf '%s' "$1" | env -u IWE_TEMPLATE -u IWE_SCRIPTS "$WS/.claude/hooks/extensions-gate.sh" 2>&1)
    RC=$?
}

is_block() { printf '%s' "$OUT" | grep -qF '"decision": "block"'; }

allowed() { # name json
    run_hook "$2"
    if [ "$RC" -eq 0 ] && ! is_block; then ok "$1"; else bad "$1" "expected ALLOW, got rc=$RC: $OUT"; fi
}

# denied name json [reason-substring]: deny, and (for a hook with #872 support)
# the denial text must carry the given reason.
denied() {
    run_hook "$2"
    if [ "$RC" -ne 0 ] || ! is_block; then
        bad "$1" "expected DENY, got rc=$RC: $OUT"
    elif [ "$HAS_FEATURE" -eq 1 ] && [ -n "${3:-}" ] && ! printf '%s' "$OUT" | grep -qF "$3"; then
        bad "$1" "denied, but not for the expected reason '$3': $OUT"
    else
        ok "$1"
    fi
}

# Deny of a SKILL.md: the text names the USER-SPACE route and the marker tool
# and no longer recommends extensions/*.md for skills.
denied_skill_text() { # name json reason
    run_hook "$2"
    if [ "$RC" -ne 0 ] || ! is_block; then
        bad "$1" "expected DENY, got rc=$RC: $OUT"
    elif ! printf '%s' "$OUT" | grep -qF 'USER-SPACE' \
        || ! printf '%s' "$OUT" | grep -qF 'add-skill-markers.sh' \
        || printf '%s' "$OUT" | grep -qF 'Создай или обнови нужный файл в extensions/' \
        || ! printf '%s' "$OUT" | grep -qF "${3:-USER-SPACE}"; then
        bad "$1" "expected DENY with the SKILL.md USER-SPACE text, got rc=$RC: $OUT"
    else
        ok "$1"
    fi
}

# ---------------------------------------------------------------------------
# Positive: only the block changes.
# ---------------------------------------------------------------------------
build_ws "$GOOD"
allowed "Edit inserts text between the markers (markers kept in old/new)" \
    "$(json_edit "$SKILL" "${OPEN}${NL}${CLOSE}" "${OPEN}${NL}my rule${NL}${CLOSE}")"

build_ws "$FILLED"
allowed "Edit rewrites text inside a non-empty block" \
    "$(json_edit "$SKILL" "second rule" "second rule changed")"
allowed "Edit deletes block text without a trailing newline in old_string (tool newline quirk)" \
    "$(json_edit "$SKILL" "second rule" "")"
allowed "Edit deletes a whole block line" \
    "$(json_edit "$SKILL" "my rule${NL}" "")"
allowed "Edit whose old_string spans the closing marker but keeps it byte-identical" \
    "$(json_edit "$SKILL" "second rule${NL}${CLOSE}" "second rule!${NL}${CLOSE}")"
allowed "Edit replace_all touching only in-block occurrences" \
    "$(json_edit "$SKILL" "rule" "RULE" true)"
allowed "Write of the full file changing only the block" \
    "$(json_write "$SKILL" "${HEAD}${OPEN}${NL}written rule${NL}${CLOSE}${TAIL}${NL}")"
allowed "Write that empties the block" \
    "$(json_write "$SKILL" "${GOOD}")"

# CRLF file: the CR belongs to the line terminators and must survive outside.
CRLF_GOOD="${GOOD//$NL/$CR$NL}"
build_ws "$CRLF_GOOD"
allowed "CRLF file: Edit inside the block with CRLF text" \
    "$(json_edit "$SKILL" "${OPEN}${CR}${NL}${CLOSE}" "${OPEN}${CR}${NL}my rule${CR}${NL}${CLOSE}")"
allowed "CRLF file: Write keeps CRLF outside the block" \
    "$(json_write "$SKILL" "${CRLF_GOOD/${OPEN}${CR}${NL}${CLOSE}/${OPEN}${CR}${NL}crlf rule${CR}${NL}${CLOSE}}")"

# ---------------------------------------------------------------------------
# Negative: edits outside the block and marker tampering.
# ---------------------------------------------------------------------------
build_ws "$GOOD"
denied_skill_text "Edit outside the block (platform text) is denied with the USER-SPACE hint" \
    "$(json_edit "$SKILL" "Platform text line 1." "Hacked.")" "$WHY_OUTSIDE"
denied "Edit of the platform tail after the block is denied" \
    "$(json_edit "$SKILL" "Platform tail after block." "Hacked tail.")" "$WHY_OUTSIDE"
denied "Edit of the front matter is denied" \
    "$(json_edit "$SKILL" "layer: L1" "layer: L3")" "$WHY_OUTSIDE"
denied "Edit that changes the opening marker is denied" \
    "$(json_edit "$SKILL" "$OPEN" "<!-- USER-SPACE  -->")" "$WHY_PAIR"
denied "Edit that changes the closing marker is denied" \
    "$(json_edit "$SKILL" "$CLOSE" "${CLOSE}x")" "$WHY_PAIR"
denied "Edit that removes the opening marker line is denied" \
    "$(json_edit "$SKILL" "${OPEN}${NL}" "")" "$WHY_PAIR"
denied "Edit that removes both markers (block dissolved) is denied" \
    "$(json_edit "$SKILL" "${OPEN}${NL}${CLOSE}${NL}" "")" "$WHY_PAIR"
denied "Edit that moves the closing marker down is denied" \
    "$(json_edit "$SKILL" "${CLOSE}${NL}${NL}Platform tail after block.${NL}" "${NL}Platform tail after block.${NL}${CLOSE}${NL}")" "$WHY_OUTSIDE"
denied "Edit that duplicates the closing marker is denied" \
    "$(json_edit "$SKILL" "$CLOSE" "${CLOSE}${NL}${CLOSE}")" "$WHY_PAIR"
denied "Edit that duplicates the opening marker is denied" \
    "$(json_edit "$SKILL" "$OPEN" "${OPEN}${NL}${OPEN}")" "$WHY_PAIR"
denied "Edit that writes a marker text inline inside the block is denied" \
    "$(json_edit "$SKILL" "${OPEN}${NL}${CLOSE}" "${OPEN}${NL}see ${CLOSE} inline${NL}${CLOSE}")" "$WHY_PAIR"
denied "Write that drops the markers is denied" \
    "$(json_write "$SKILL" "${HEAD}no block${TAIL}${NL}")" "$WHY_PAIR"
denied "Write that changes text before the block is denied" \
    "$(json_write "$SKILL" "${HEAD}HACK${NL}${OPEN}${NL}${CLOSE}${TAIL}${NL}")" "$WHY_OUTSIDE"
denied "Write that changes the tail after the block is denied" \
    "$(json_write "$SKILL" "${HEAD}${OPEN}${NL}${CLOSE}${TAIL} hacked${NL}")" "$WHY_OUTSIDE"
denied "Write that swaps the markers is denied" \
    "$(json_write "$SKILL" "${HEAD}${CLOSE}${NL}${OPEN}${TAIL}${NL}")" "$WHY_ORDER"
denied "Edit with no matching old_string (0 occurrences) is denied" \
    "$(json_edit "$SKILL" "text that is not in the file" "x")" "old_string не найден"
denied "Edit with an empty old_string is denied" \
    "$(json_edit "$SKILL" "" "x")" "пустой old_string"
denied "Non-Edit/Write tool (MultiEdit) is denied" \
    "$(json_tool MultiEdit "$SKILL")" "только для Edit и Write"

# Ambiguous old_string: one occurrence outside, one inside the block.
TOKEN_DOC="${HEAD}token outside${NL}${OPEN}${NL}token inside${NL}${CLOSE}${TAIL}${NL}"
build_ws "$TOKEN_DOC"
denied "Edit with old_string found more than once (no replace_all) is denied" \
    "$(json_edit "$SKILL" "token" "T")" "больше одного раза"
denied "Edit replace_all touching text outside the block is denied" \
    "$(json_edit "$SKILL" "token" "T" true)" "$WHY_OUTSIDE"
allowed "Edit with a unique in-block old_string is still allowed in the same file" \
    "$(json_edit "$SKILL" "token inside" "token changed")"

# ---------------------------------------------------------------------------
# Negative: the ORIGINAL file must carry exactly one well-formed pair.
# ---------------------------------------------------------------------------
build_ws "${HEAD}${TAIL}${NL}"
denied_skill_text "Original without markers: no exception" \
    "$(json_edit "$SKILL" "Platform tail after block." "Added")" "$WHY_PAIR"
build_ws "${HEAD}${OPEN}${NL}${TAIL}${NL}"
denied "Original with only the opening marker: no exception" \
    "$(json_edit "$SKILL" "Platform tail after block." "Added")" "$WHY_PAIR"
DUP_PAIRS="${HEAD}${OPEN}${NL}${CLOSE}${NL}mid text${NL}${OPEN}${NL}${CLOSE}${TAIL}${NL}"
build_ws "$DUP_PAIRS"
denied "Original with duplicated marker pairs: no exception (edit inside first block)" \
    "$(json_edit "$SKILL" "${OPEN}${NL}${CLOSE}${NL}mid" "${OPEN}${NL}added${NL}${CLOSE}${NL}mid")" "$WHY_PAIR"
NESTED="${HEAD}${OPEN}${NL}${OPEN}${NL}${CLOSE}${NL}${CLOSE}${TAIL}${NL}"
build_ws "$NESTED"
denied "Original with nested markers: no exception" \
    "$(json_edit "$SKILL" "${OPEN}${NL}${OPEN}" "${OPEN}${NL}added${NL}${OPEN}")" "$WHY_PAIR"
REORDERED="${HEAD}${CLOSE}${NL}${OPEN}${TAIL}${NL}"
build_ws "$REORDERED"
denied "Original with reordered markers (closing first): no exception" \
    "$(json_edit "$SKILL" "${CLOSE}${NL}${OPEN}" "${CLOSE}${NL}added${NL}${OPEN}")" "$WHY_ORDER"
INLINE="${HEAD}see ${OPEN} for details${NL}${OPEN}${NL}${CLOSE}${TAIL}${NL}"
build_ws "$INLINE"
denied "Original mentioning a marker text elsewhere on a non-marker line: no exception" \
    "$(json_edit "$SKILL" "${OPEN}${NL}${CLOSE}" "${OPEN}${NL}added${NL}${CLOSE}")" "$WHY_PAIR"
build_ws "$GOOD"
printf '\xff\xfe%s' "$GOOD" > "$SKILL"
denied "Original that is not valid UTF-8: no exception (fail closed on a parse error)" \
    "$(json_edit "$SKILL" "${OPEN}${NL}${CLOSE}" "${OPEN}${NL}added${NL}${CLOSE}")" "не удалось разобрать"

# ---------------------------------------------------------------------------
# Negative: path shape, symlinks, hard links, traversal, case, new files.
# ---------------------------------------------------------------------------
build_ws "$GOOD"
IN_BLOCK_EDIT_NEW="${OPEN}${NL}my rule${NL}${CLOSE}"
IN_BLOCK_EDIT_OLD="${OPEN}${NL}${CLOSE}"

rm -f "$SKILL"
ln -s "$WS/.claude/skills/other/SKILL.md" "$SKILL"
denied "Symlinked SKILL.md pointing at another platform SKILL.md is denied" \
    "$(json_edit "$SKILL" "$IN_BLOCK_EDIT_OLD" "$IN_BLOCK_EDIT_NEW")" "$WHY_PATH"
rm -f "$SKILL"
printf '%s' "${HEAD}${OPEN}${NL}${CLOSE}${TAIL}${NL}" > "$WS/memory/protocol-linked.md"
ln -s "$WS/memory/protocol-linked.md" "$SKILL"
denied "Symlinked SKILL.md pointing at memory/protocol-*.md (even with a pair) is denied" \
    "$(json_write "$SKILL" "${HEAD}${OPEN}${NL}my rule${NL}${CLOSE}${TAIL}${NL}")"

build_ws "$GOOD"
ln -s demo "$WS/.claude/skills/linked"
denied "Symlinked skill directory pointing at a platform skill is denied" \
    "$(json_edit "$WS/.claude/skills/linked/SKILL.md" "$IN_BLOCK_EDIT_OLD" "$IN_BLOCK_EDIT_NEW")" "$WHY_PATH"

build_ws "$GOOD"
ln "$SKILL" "$WS/elsewhere/hardlink.md"
denied "Hard-linked SKILL.md is denied" \
    "$(json_edit "$SKILL" "$IN_BLOCK_EDIT_OLD" "$IN_BLOCK_EDIT_NEW")" "жёсткие ссылки"

build_ws "$GOOD"
denied "Path with .. is denied even when it resolves to the same SKILL.md" \
    "$(json_edit "$WS/.claude/skills/other/../demo/SKILL.md" "$IN_BLOCK_EDIT_OLD" "$IN_BLOCK_EDIT_NEW")" "«..»"

build_ws "$GOOD"
denied "file_path with a trailing newline (shell would strip it) is denied, not judged as SKILL.md" \
    "$(json_write "${SKILL}${NL}" "${HEAD}${OPEN}${NL}my rule${NL}${CLOSE}${TAIL}${NL}")" "не совпадает"

# Only the file NAME is judged here: the gate matches ".claude/skills/*" literally, so a
# lower-case "skill.md" is not the exception's shape and stays blocked. A case-variant
# spelling of the DIRECTORIES is a separate, pre-existing gap in the gate's path
# classification and is deliberately not changed by this fix.
if [ -e "$WS/.claude/skills/demo/skill.md" ]; then
    denied "Case-variant file name (skill.md) is never eligible for the exception" \
        "$(json_edit "$WS/.claude/skills/demo/skill.md" "$IN_BLOCK_EDIT_OLD" "$IN_BLOCK_EDIT_NEW")"
else
    echo "SKIP: case-variant file name case (file system is case-sensitive: the variant names another file)"
fi

# Creating a SKILL.md through the exception is denied (skill "gone" is in the
# manifest, so the #311 own-skill rule does not apply).
build_ws "$GOOD"
mkdir -p "$WS/.claude/skills/gone"
denied "Creating a NEW SKILL.md of a platform skill via Write is denied" \
    "$(json_write "$WS/.claude/skills/gone/SKILL.md" "${GOOD}")" "$WHY_MISSING"
rm -f "$SKILL"
denied "Recreating a deleted platform SKILL.md via Write is denied" \
    "$(json_write "$SKILL" "${GOOD}")" "$WHY_MISSING"

# Other files keep the previous behaviour unconditionally, markers or not.
build_ws "$GOOD"
printf '%s' "$GOOD" > "$WS/.claude/skills/demo/helper.md"
denied "Sibling helper file inside a platform skill with a pair is denied" \
    "$(json_edit "$WS/.claude/skills/demo/helper.md" "$IN_BLOCK_EDIT_OLD" "$IN_BLOCK_EDIT_NEW")" "extensions/"
mkdir -p "$WS/.claude/skills/demo/sub"
printf '%s' "$GOOD" > "$WS/.claude/skills/demo/sub/SKILL.md"
denied "SKILL.md nested one level deeper than .claude/skills/<name>/ is denied" \
    "$(json_edit "$WS/.claude/skills/demo/sub/SKILL.md" "$IN_BLOCK_EDIT_OLD" "$IN_BLOCK_EDIT_NEW")" "extensions/"
printf '%s' "$GOOD" > "$WS/.claude/skills/SKILL.md"
denied "SKILL.md directly in .claude/skills/ is denied" \
    "$(json_edit "$WS/.claude/skills/SKILL.md" "$IN_BLOCK_EDIT_OLD" "$IN_BLOCK_EDIT_NEW")" "extensions/"
printf '%s' "$GOOD" > "$WS/memory/protocol-open.md"
denied "memory/protocol-*.md with a pair is denied" \
    "$(json_edit "$WS/memory/protocol-open.md" "$IN_BLOCK_EDIT_OLD" "$IN_BLOCK_EDIT_NEW")" "extensions/"
printf '%s' "$GOOD" > "$WS/FMT-exocortex-template/update-manifest.json"
denied "update-manifest.json with a pair is denied" \
    "$(json_edit "$WS/FMT-exocortex-template/update-manifest.json" "$IN_BLOCK_EDIT_OLD" "$IN_BLOCK_EDIT_NEW")" "generate-manifest.sh"
# The hook has never gated .claude/hooks/*: the exception must not change that
# (the file is neither newly denied nor newly special-cased).
printf '%s\n%s\n%s\n' "# hook body" ": <<'X'" "${OPEN}" > "$WS/.claude/hooks/other-hook.sh"
printf '%s\n%s\n' "${CLOSE}" "X" >> "$WS/.claude/hooks/other-hook.sh"
allowed "Other hook file: behaviour unchanged (this gate never covered .claude/hooks/*)" \
    "$(json_edit "$WS/.claude/hooks/other-hook.sh" "$OPEN" "${OPEN}${NL}added")"

# Relative path is never eligible for the exception.
build_ws "$GOOD"
OUT=$(cd "$WS" && printf '%s' "$(json_edit ".claude/skills/demo/SKILL.md" "$IN_BLOCK_EDIT_OLD" "$IN_BLOCK_EDIT_NEW")" \
    | env -u IWE_TEMPLATE -u IWE_SCRIPTS "$WS/.claude/hooks/extensions-gate.sh" 2>&1)
RC=$?
if [ "$RC" -eq 0 ] && is_block && { [ "$HAS_FEATURE" -eq 0 ] || printf '%s' "$OUT" | grep -qF 'абсолютным'; }; then
    ok "Relative file_path is denied"
else
    bad "Relative file_path is denied" "rc=$RC: $OUT"
fi

# ---------------------------------------------------------------------------
# CRLF: a CRLF turned into LF outside the block is a change outside the block.
# ---------------------------------------------------------------------------
build_ws "$CRLF_GOOD"
denied "CRLF file: Write that normalises CRLF to LF outside the block is denied" \
    "$(json_write "$SKILL" "${GOOD/${OPEN}${NL}${CLOSE}/${OPEN}${NL}lf rule${NL}${CLOSE}}")" "$WHY_OUTSIDE"
denied "CRLF file: Edit turning one CRLF into LF outside the block is denied" \
    "$(json_edit "$SKILL" "Platform text line 1.${CR}${NL}" "Platform text line 1.${NL}")" "$WHY_OUTSIDE"
denied "CRLF file: Edit with LF-only old_string matching nothing is denied" \
    "$(json_edit "$SKILL" "${OPEN}${NL}${CLOSE}" "${OPEN}${NL}my rule${NL}${CLOSE}")" "old_string не найден"

# ---------------------------------------------------------------------------
# Multi-step: every call is judged against the CURRENT file, so two calls
# cannot accumulate a change outside the block.
# ---------------------------------------------------------------------------
build_ws "$GOOD"
STEP1=$(json_edit "$SKILL" "${OPEN}${NL}${CLOSE}" "${OPEN}${NL}third rule${NL}${CLOSE}")
allowed "Multi-step: first call adds a rule inside the block" "$STEP1"
apply_edit_json "$SKILL" "$STEP1"
denied "Multi-step: second call moves the closing marker down to widen the block" \
    "$(json_edit "$SKILL" "${CLOSE}${NL}${NL}Platform tail after block.${NL}" "${NL}Platform tail after block.${NL}${CLOSE}${NL}")" "$WHY_OUTSIDE"
denied "Multi-step: second call moves the closing marker up (block text becomes suffix)" \
    "$(json_edit "$SKILL" "third rule${NL}${CLOSE}${NL}" "${CLOSE}${NL}third rule${NL}")" "$WHY_OUTSIDE"
denied "Multi-step: second call moves the opening marker down" \
    "$(json_edit "$SKILL" "${OPEN}${NL}third rule${NL}" "third rule${NL}${OPEN}${NL}")" "$WHY_OUTSIDE"
denied "Multi-step: second call moves the opening marker up over platform text" \
    "$(json_edit "$SKILL" "Platform text line 1.${NL}${NL}${OPEN}" "${OPEN}${NL}Platform text line 1.${NL}")" "$WHY_OUTSIDE"
denied "Multi-step: after the block grew, platform text outside it is still protected" \
    "$(json_edit "$SKILL" "Platform tail after block." "Hacked tail.")" "$WHY_OUTSIDE"
allowed "Multi-step: another in-block edit against the new on-disk file is allowed" \
    "$(json_edit "$SKILL" "third rule" "third rule, revised")"

# ---------------------------------------------------------------------------
# Unchanged behaviour of the other branches of the hook.
# ---------------------------------------------------------------------------
build_ws "$GOOD"
printf '%s\n' 'author_mode: true' > "$WS/params.yaml"
allowed "author_mode: true - an edit outside the block stays allowed" \
    "$(json_edit "$SKILL" "Platform text line 1." "Author edit.")"
printf '%s\n' 'author_mode: false' > "$WS/params.yaml"
denied "author_mode: false - an edit outside the block stays denied" \
    "$(json_edit "$SKILL" "Platform text line 1." "User edit.")" "$WHY_OUTSIDE"
rm -f "$WS/params.yaml"

mkdir -p "$WS/.claude/skills/mine"
printf '%s' "no markers here" > "$WS/.claude/skills/mine/SKILL.md"
allowed "Own skill absent from the manifest (issue #311) stays editable" \
    "$(json_edit "$WS/.claude/skills/mine/SKILL.md" "no markers" "still no markers")"
allowed "Ordinary file outside gated paths stays editable" \
    "$(json_write "$WS/README.md" "hello")"

echo "---"
# ---------------------------------------------------------------------------
# Strict tool_name: an envelope without a usable tool_name is a malformed call,
# not something to guess from the shape of tool_input.
# ---------------------------------------------------------------------------
build_ws "$GOOD"
NO_TOOL_ENV=$("$PYTHON" -c '
import json, sys
print(json.dumps({"session_id": "t", "hook_event_name": "PreToolUse",
                  "tool_input": {"file_path": sys.argv[1], "old_string": sys.argv[2], "new_string": sys.argv[3]}}))
' "$SKILL" "${OPEN}${NL}${CLOSE}" "${OPEN}${NL}my rule${NL}${CLOSE}")
denied "Envelope without tool_name is denied (no guessing Edit vs Write)" "$NO_TOOL_ENV" "только для Edit и Write"
NULL_TOOL_ENV=$("$PYTHON" -c '
import json, sys
print(json.dumps({"session_id": "t", "hook_event_name": "PreToolUse", "tool_name": None,
                  "tool_input": {"file_path": sys.argv[1], "content": sys.argv[2]}}))
' "$SKILL" "$GOOD")
denied "Envelope with tool_name null is denied" "$NULL_TOOL_ENV" "только для Edit и Write"

# ---------------------------------------------------------------------------
# Deletion in a CRLF file. The real Edit tool (probed live) deletes the newline that
# follows old_string too, and in a CRLF file that is the pair CR LF - the model must
# judge that reading as well, at the block boundaries above all.
# ---------------------------------------------------------------------------
CRLF_WITH_LINES="${HEAD//$NL/$CR$NL}${OPEN}${CR}${NL}first line${CR}${NL}last line${CR}${NL}${CLOSE}${CR}${NL}${TAIL//$NL/$CR$NL}${NL}"
build_ws "$CRLF_WITH_LINES"
allowed "CRLF file: deleting the LAST line of the block (also its CR LF) stays inside the block" \
    "$(json_edit "$SKILL" "last line" "")"
denied "CRLF file: deleting the text right before the opening marker (its CR LF is prefix) is denied" \
    "$(json_edit "$SKILL" "Platform text line 1." "")" "выходит за пределы"

echo "issue-872: PASS=$pass FAIL=$fail (hook: $HOOK_SRC)"
[ "$fail" -eq 0 ]
