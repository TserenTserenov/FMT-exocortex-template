#!/usr/bin/env bash
# Regression test for yaml_task_line() (WP-539, 2026-09-10) — session-guard
# used to write the semaphore's `task:` field with a bare `echo "task: $TASK"`.
# A real task string containing a literal ": " (2026-09-09, "РП170: R15-триаж
# ...") produced a line no strict YAML parser can read back as a mapping --
# see bug-2026-09-09-git-wrapper-blocked-by-corrupt-semaphore.md. This suite
# proves the fix quotes only when needed and the semaphore round-trips
# through a real YAML parser either way.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SG="$SCRIPT_DIR/session-guard.sh"
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

export IWE_ROOT="$TMPDIR"
# Fresh TMPDIR, not the real canonical checkout -- the write-freeze (WP-520)
# keys off the real path, so it does not apply here (same rationale as
# test-session-guard-pid-liveness.sh).
export IWE_FROZEN_CANONICAL_PATH=""

fail() { echo "FAIL: $1"; exit 1; }
pass() { echo "PASS: $1"; }

parse_task_from_semaphore() {
  # Mirrors the real failure mode this test guards against: a strict YAML
  # parser reading the whole frontmatter block, not a line-grep.
  local sem="$1"
  SEM_PATH_ENV="$sem" python3 -c '
import os, re, sys
import yaml
text = open(os.environ["SEM_PATH_ENV"], encoding="utf-8").read()
m = re.match(r"^---\n(.*?)\n---", text, re.S)
if not m:
    print("NO_FRONTMATTER", end="")
    raise SystemExit(0)
doc = yaml.safe_load(m.group(1))
sys.stdout.write(doc.get("task", ""))
'
}

# 1. A task value with a literal ": " must round-trip through a strict YAML
# parser as the exact original string -- the actual bug this fix closes.
COLON_TASK='Разбор знаний РП170: R15-триаж непроанализированных captures (peer с Codex)'
IWE_AGENT=claude-code "$SG" open --wp WP-999 --task "$COLON_TASK" --slug colon-task-test --agent claude-code >/dev/null
SEM=$(ls "$TMPDIR/.iwe-runtime/sessions/"*.open)
PARSED=$(parse_task_from_semaphore "$SEM")
[ "$PARSED" = "$COLON_TASK" ] || fail "task with ': ' did not round-trip through a strict YAML parser (got: $PARSED)"
pass "task containing ': ' round-trips through a strict YAML parser"
"$SG" close --agent claude-code >/dev/null 2>&1 || true
rm -f "$SEM"

# 2. A plain task (the overwhelmingly common case) stays byte-identical to
# the pre-fix bare format -- no quoting overhead, no behaviour change for
# every semaphore that never had this bug in the first place.
PLAIN_TASK="обычная задача без спецсимволов"
IWE_AGENT=claude-code "$SG" open --wp WP-999 --task "$PLAIN_TASK" --slug plain-task-test --agent claude-code >/dev/null
SEM2=$(ls "$TMPDIR/.iwe-runtime/sessions/"*.open)
[ "$(grep '^task: ' "$SEM2")" = "task: $PLAIN_TASK" ] || fail "plain task value was quoted/altered unnecessarily"
pass "plain task value stays bare (byte-identical to pre-fix format)"
"$SG" close --agent claude-code >/dev/null 2>&1 || true
rm -f "$SEM2"

# 3. A task value with an embedded double quote and a '#' must also
# round-trip -- other plain-scalar-breaking characters, not just ':'.
QUOTE_HASH_TASK='fix "quoting" bug #42'
IWE_AGENT=claude-code "$SG" open --wp WP-999 --task "$QUOTE_HASH_TASK" --slug quote-hash-task-test --agent claude-code >/dev/null
SEM3=$(ls "$TMPDIR/.iwe-runtime/sessions/"*.open)
PARSED3=$(parse_task_from_semaphore "$SEM3")
[ "$PARSED3" = "$QUOTE_HASH_TASK" ] || fail "task with embedded quote/# did not round-trip (got: $PARSED3)"
pass "task containing a double quote and '#' round-trips through a strict YAML parser"
"$SG" close --agent claude-code >/dev/null 2>&1 || true
rm -f "$SEM3"

# 4. A long, ordinary (multi-word, no special chars) task past PyYAML's
# default 80-column wrap must still land as ONE physical line in the
# semaphore -- cold review 2026-09-10 caught the initial fix folding such
# values onto a continuation line, which every raw `grep '^task: ' | cut`
# reader (kimi-session-watchdog.sh, session-guard's own `close` path)
# then silently truncated, reintroducing the original bug by length
# instead of by ':'. yaml.safe_load still reconstructs the value
# correctly even when folded, which is why this needs its own assertion
# distinct from the round-trip checks above.
LONG_TASK="это довольно длинное текстовое описание задачи, которое легко превышает восемьдесят символов суммарной длины строки"
IWE_AGENT=claude-code "$SG" open --wp WP-999 --task "$LONG_TASK" --slug long-task-test --agent claude-code >/dev/null
SEM4=$(ls "$TMPDIR/.iwe-runtime/sessions/"*.open)
[ "$(grep -c '^task: ' "$SEM4")" = "1" ] || fail "long task value was folded onto more than one 'task:' line"
[ "$(grep '^task: ' "$SEM4")" = "task: $LONG_TASK" ] || fail "long task value was altered or wrapped (should stay bare, single-line)"
pass "long plain-text task (>80 columns) stays on a single line"
"$SG" close --agent claude-code >/dev/null 2>&1 || true
rm -f "$SEM4"

# 5. A task value with an embedded literal newline must be collapsed to a
# single line, not folded into a YAML block/quoted-with-newline style --
# width alone (test 4) does not prevent this, PyYAML still has to represent
# the newline somehow. Semaphore free-text fields are documented as
# single-line; this fix normalizes rather than accepting multi-line input.
NEWLINE_TASK=$'line one\nline two'
IWE_AGENT=claude-code "$SG" open --wp WP-999 --task "$NEWLINE_TASK" --slug newline-task-test --agent claude-code >/dev/null
SEM5=$(ls "$TMPDIR/.iwe-runtime/sessions/"*.open)
[ "$(grep -c '^task: ' "$SEM5")" = "1" ] || fail "task value with an embedded newline was folded onto more than one 'task:' line"
[ "$(parse_task_from_semaphore "$SEM5")" = "line one line two" ] || fail "embedded newline was not collapsed to a space"
pass "task value with an embedded newline collapses to a single line"

echo "All yaml_task_line escaping tests passed"
