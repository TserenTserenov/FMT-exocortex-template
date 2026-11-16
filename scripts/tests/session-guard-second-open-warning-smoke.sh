#!/usr/bin/env bash
# WP-484 Ф301: `open` warns about another live semaphore of the same agent and WP
# in the same conversation. Exercises warn_sibling_semaphores() extracted from the
# real script, under the script's own `set -euo pipefail`, so a sibling it cannot
# parse (housekeeping without wp:, no slug:) must be skipped, never abort open.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SG="$ROOT/scripts/session-guard.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# Pull the two functions out of the script as written, without running its main.
extract() { awk -v name="$1" '$0 ~ "^"name"\\(\\) \\{" {p=1} p {print} p && /^}$/ {exit}' "$SG"; }
FUNCS="$TMP/funcs.sh"
{ extract _wp_key; extract warn_sibling_semaphores; } > "$FUNCS"
grep -q '^warn_sibling_semaphores() {' "$FUNCS" || fail "warn_sibling_semaphores not found in session-guard.sh"
grep -q 'warn_sibling_semaphores "\$AGENT" "\$WP"' "$SG" || fail "open does not call warn_sibling_semaphores"

SESSION_DIR="$TMP/sessions"
mkdir -p "$SESSION_DIR"
sem() { # <file> <conversation id or empty> <wp or empty> <slug or empty>
  { echo "---"; echo "agent: claude-code"
    [ -n "$3" ] && echo "wp: $3"
    [ -n "$4" ] && echo "slug: $4"
    [ -n "$2" ] && echo "harness_session_id: $2"
    echo "---"; } > "$SESSION_DIR/$1"
}
# Runs the function the way open does: strict mode, then a marker line that
# proves execution continued past it.
run() { # <conversation id or empty>
  env -u CLAUDE_CODE_SESSION_ID ${1:+CLAUDE_CODE_SESSION_ID="$1"} bash -c '
    set -euo pipefail
    . "$1/scripts/lib/wp-num.sh"
    type wp_num_normalize >/dev/null 2>&1 || { echo "no wp_num_normalize"; exit 3; }
    . "$2"
    SESSION_DIR="$3"
    warn_sibling_semaphores claude-code WP-529 new-slug "$3/claude-code-own.open"
    echo REACHED-AFTER-WARN' _ "$ROOT" "$FUNCS" "$SESSION_DIR" 2>&1
}

sem claude-code-own.open conv-1 WP-529 new-slug
sem claude-code-a.open conv-1 529 old-slug                 # live sibling, other spelling of the WP
sem claude-code-hk.open conv-1 "" day-close                # housekeeping: no wp: line
sem claude-code-noslug.open conv-1 WP-529 ""               # no slug: line
sem claude-code-b.open conv-2 WP-529 foreign-slug          # other conversation
sem claude-code-c.open conv-1 WP-7 other-wp-slug           # other WP
sem claude-code-d.open.closed conv-1 WP-529 closed-slug    # closed sibling
sem claude-code-same.open conv-1 WP-529 new-slug           # another file with our own slug
sem kimi-e.open conv-1 WP-529 kimi-slug                    # other agent, same conversation and WP

out=$(run conv-1) || fail "warning aborted open under set -euo pipefail: $out"
printf '%s\n' "$out" | grep -qx 'REACHED-AFTER-WARN' || fail "execution did not continue past the warning: $out"
printf '%s\n' "$out" | grep -q "'old-slug'" || fail "same conversation/WP sibling ('529' vs 'WP-529') not named: $out"
printf '%s\n' "$out" | grep -q "close --agent claude-code --slug old-slug" || fail "warning does not name the exit: $out"
for other in foreign-slug other-wp-slug closed-slug "'new-slug'" kimi-slug day-close; do
  if printf '%s\n' "$out" | grep -q -- "$other"; then fail "warned about unrelated or own semaphore $other: $out"; fi
done
[ "$(printf '%s\n' "$out" | grep -c 'ПРЕДУПРЕЖДЕНИЕ')" -eq 1 ] || fail "expected exactly one warning: $out"

# Two live siblings -> one line each.
sem claude-code-f.open conv-1 WP-529 third-slug
out=$(run conv-1) || fail "second run aborted: $out"
[ "$(printf '%s\n' "$out" | grep -c 'ПРЕДУПРЕЖДЕНИЕ')" -eq 2 ] || fail "expected two warnings for two siblings: $out"

# No conversation id: same conversation cannot be established, nothing is said.
out=$(run "") || fail "run without conversation id aborted: $out"
[ "$out" = "REACHED-AFTER-WARN" ] || fail "warned without a conversation id: $out"

echo "PASS: second-open warning names only live siblings of the same agent, conversation and WP, and never aborts open"
