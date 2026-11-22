#!/bin/bash
# Secret Leak Block Hook (B7.7a, WP-212 / WP-544 D6.3-D6.8)
# Event: PreToolUse (matcher: Bash)
#
# Blocks literal secret values, direct reads of sensitive files and known
# literal upload forms before Bash executes. The hook deliberately does not
# claim to stop a path assembled entirely at runtime, a renamed temporary file
# or an unknown uploader; those cases require filesystem/network sandboxing.
#
# Temporary global bypass:
#   CC_ALLOW_SECRETS_INPUT=1
#   CC_ALLOW_SECRETS_INPUT_UNTIL=<unix-time, no more than 900s ahead>
# Every use needs a durable private audit record and visible user alert.

set -uo pipefail
umask 077
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

security_failure() {
  # This is the guard failing, not the command being refused, and it blocks
  # EVERY Bash call in the session -- including the one that would repair it
  # (06.09: a stray quote character inside secret-bypass-lib.sh took Bash,
  # Read, Edit and MCP down at once, and the message named none of that).
  # So the text names the actual stage that failed and the way out.
  printf '%s\n' "Secret PreToolUse guard failed (${1:-no reason given}); the Bash call is blocked." >&2
  printf '%s\n' 'This is the guard itself failing, not a verdict on the command. Two known causes: .claude/hooks/secret-bypass-lib.sh does not parse (check with bash -n), or this hook and that library are from different versions. While it lasts, every tool call of this agent is blocked, so the repair has to come from a shell outside the agent.' >&2
  exit 2
}

HOOK_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
[ -r "$HOOK_DIR/secret-bypass-lib.sh" ] || security_failure "guard library is not readable"
# shellcheck source=secret-bypass-lib.sh
# shellcheck disable=SC1091
. "$HOOK_DIR/secret-bypass-lib.sh" || security_failure "guard library could not be parsed"
[ -x "$SECRET_BYPASS_JQ" ] && [ -x "$SECRET_BYPASS_PYTHON" ] || security_failure "jq or python3 are not available"

IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
LOG_FILE="$IWE_ROOT/.claude/logs/secret-leak-block.jsonl"
mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
SESSION_ID=""
COMMAND_LENGTH=0

log_decision() {
  # Data minimization: never store command text or a content-derived digest.
  local decision="$1" pattern="$2" ts bucket record
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  bucket=$(date -u +"%Y-%m-%dT%H:00:00Z")
  # The jq program references jq variables.
  # shellcheck disable=SC2016
  record=$("$SECRET_BYPASS_JQ" -nc \
    --arg ts "$ts" \
    --arg bucket "$bucket" \
    --arg sid "$SESSION_ID" \
    --arg dec "$decision" \
    --arg pat "$pattern" \
    --argjson command_length "$COMMAND_LENGTH" \
    '{ts:$ts, time_bucket:$bucket, hook:"secret-leak-block", session_id:$sid, decision:$dec, pattern:$pat, command_length:$command_length}') || return 1
  secret_bypass_audit_append "$LOG_FILE" "$record"
}

input=$(cat) || security_failure "failed to read input"
analysis=$(printf '%s' "$input" | secret_pattern_process analyze-bash 2>/dev/null) || security_failure "analyzer did not complete successfully"
# Only fields, that are present in every version of the analyzer. New fields are read
# below with a default value: a hard requirement in this check would have meant
# that, a version mismatch between the hook and the library (which happens routinely, when they are edited by
# concurrent sessions) would take down ALL agent work, not just a single check
# (WP-545, 06.09 — exactly this failure occurred twice in one day).
printf '%s' "$analysis" | "$SECRET_BYPASS_JQ" -e '
  type == "object"
  and (.applicable | type == "boolean")
  and (.session_id | type == "string")
  and (.tool_name | type == "string")
  and ((.applicable == false) or (
    (.command_length | type == "number")
    and (.pattern_ids | type == "array")
    and (.direct_sensitive_read | type == "boolean")
    and (.direct_sensitive_upload | type == "boolean")
  ))' >/dev/null 2>&1 || security_failure "analyzer response did not pass shape validation"

applicable=$(printf '%s' "$analysis" | "$SECRET_BYPASS_JQ" -r '.applicable')
[ "$applicable" = "true" ] || exit 0
SESSION_ID=$(printf '%s' "$analysis" | "$SECRET_BYPASS_JQ" -r '.session_id')
COMMAND_LENGTH=$(printf '%s' "$analysis" | "$SECRET_BYPASS_JQ" -r '.command_length')
pattern_ids=$(printf '%s' "$analysis" | "$SECRET_BYPASS_JQ" -r '.pattern_ids | join(",")')
direct_read=$(printf '%s' "$analysis" | "$SECRET_BYPASS_JQ" -r '.direct_sensitive_read')
direct_upload=$(printf '%s' "$analysis" | "$SECRET_BYPASS_JQ" -r '.direct_sensitive_upload')
bulk_enumeration=$(printf '%s' "$analysis" | "$SECRET_BYPASS_JQ" -r '.bulk_secret_enumeration // false')
shell_model=$(printf '%s' "$analysis" | "$SECRET_BYPASS_JQ" -r '.shell_model // "unreported"')

if secret_bypass_check INPUT; then
  bypass_pattern="${pattern_ids:-policy-path}"
  if secret_bypass_authorize INPUT log_decision "bypass-env-temporary" "$bypass_pattern"; then
    exit 0
  fi
  [ "$SECRET_BYPASS_STATE" = "rejected" ] || {
    SECRET_BYPASS_STATE="rejected"
    SECRET_BYPASS_REASON="authorization helper unavailable"
  }
  BYPASS_NOTICE=$(secret_bypass_rejected_message INPUT)
elif [ "$SECRET_BYPASS_STATE" = "rejected" ]; then
  log_decision "bypass-env-rejected" "$SECRET_BYPASS_REASON" || true
  BYPASS_NOTICE=$(secret_bypass_rejected_message INPUT)
fi

deny_command() {
  local decision="$1" pattern="$2" reason="$3"
  log_decision "$decision" "$pattern" || true
  # The jq program references jq variables.
  # shellcheck disable=SC2016
  if ! "$SECRET_BYPASS_JQ" -n \
    --arg reason "$reason" \
    --arg message "${BYPASS_NOTICE:-}" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $reason}}
     + (if $message == "" then {} else {systemMessage:$message} end)'; then
    security_failure "failed to produce a denial response"
  fi
  exit 0
}

if [ "$direct_upload" = "true" ]; then
  deny_command "deny-bash-upload" "direct-sensitive-upload" \
    "Direct upload of a sensitive file via Bash is blocked before execution Bash blocked before execution. Hook covers only literal paths and known upload-commands; computed paths require a system sandbox. Use a service wrapper, that passes the value without the agent reading the file."
fi

if [ "$direct_read" = "true" ]; then
  # issue #1090: this used to point to scripts/with-aist-env.sh, a wrapper
  # that was never shipped anywhere in the template -- the hook named a tool
  # that does not exist. The bypass it was trying to describe already works
  # today (secret_bypass_check INPUT above exits 0 before this branch runs),
  # so point at that instead of a nonexistent wrapper.
  deny_command "deny-bash-read" "direct-sensitive-read" \
    "Reading a sensitive file via Bash is blocked before the value enters the context Bash blocked before the value enters the context. Do not name the file in the command — pass the value via \$VAR/env, the program reads them via os.environ. A one-time bypass requires CC_ALLOW_SECRETS_INPUT=1 and expiry CC_ALLOW_SECRETS_INPUT_UNTIL no more than 15 minutes. Hook block ≠ «no access» — see. lessons_blocked_probe_is_not_verification.md."
fi

if [ "$bulk_enumeration" = "true" ]; then
  # issue #1090: same dead scripts/with-aist-env.sh reference as the
  # direct_sensitive_read branch above (found by cold code review of that
  # fix -- it exists nowhere in the repo, see the comment there).
  deny_command "deny-bash-bulk-enumeration" "bulk-secret-enumeration" \
    "The command prints all secrets at once in plain text (env/printenv without a variable name or railway variables/variable) — blocked before execution, regardless of the form of the values: they are not detected by signature analysis of the output. One specific variable is needed — pass the value via \$VAR/env (the program reads them via os.environ) or printenv <VARIABLE_NAME>. A one-time bypass requires CC_ALLOW_SECRETS_INPUT=1 and expiry CC_ALLOW_SECRETS_INPUT_UNTIL no more than 15 minutes — the output will still be protected by the redacting PostToolUse-hook, but the one-time fact of printing cannot be undone."
fi

if [ -n "$pattern_ids" ]; then
  deny_command "deny" "$pattern_ids" \
    "In Bash-a possible secret was found in the command (classes: $pattern_ids). Do not pass it as an argument; use \$VAR/env or wrapper. A one-time bypass requires CC_ALLOW_SECRETS_INPUT=1 and expiry CC_ALLOW_SECRETS_INPUT_UNTIL no more than 15 minutes; output separately remains protected."
fi

# The command is valid Bash whose grammar the variable model does not cover — valid Bash, whose grammar the variable model does not cover
# (elif, unclosed if, branching inside a loop/group/function). Checks, not
# requiring parsing, already ran above on this same command; only lost is
# half of the variable path analysis, and this is a reason for a visible annotation and not, and not
# to refuse to execute the call (WP-545, 06.09: «unsupported shell conditional»
# reached the agent as «guard could not validate input» and stopped the session).
case "$shell_model" in
  complete)
    log_decision "allow" "" || true
    ;;
  unreported)
    # The library is older than this hook: the field is absent entirely. We do not block operation, but
    # we log it explicitly — otherwise a version mismatch versions goes unnoticed silently.
    log_decision "allow-shell-model-unreported" "" || true
    DEGRADED_NOTICE="Secrets guard and its library are from different versions: the library does not report completeness of command parsing. Checks completed, but they cannot be relied upon as complete."
    ;;
  *)
    log_decision "allow-shell-model-$shell_model" "" || true
    DEGRADED_NOTICE="Secrets guard did not fully parse this command (construct outside the model: elif, unclosed if, branching inside a loop, groups or functions). Checks, that do not require parsing, completed and found nothing; no variable-path analysis was performed for it."
    ;;
esac
ALLOW_NOTICE="${BYPASS_NOTICE:-}"
if [ -n "${DEGRADED_NOTICE:-}" ]; then
  if [ -n "$ALLOW_NOTICE" ]; then
    ALLOW_NOTICE="$ALLOW_NOTICE"$'\n'"$DEGRADED_NOTICE"
  else
    ALLOW_NOTICE="$DEGRADED_NOTICE"
  fi
fi
# The jq program references jq variables.
# shellcheck disable=SC2016
if [ -n "$ALLOW_NOTICE" ] \
  && ! "$SECRET_BYPASS_JQ" -n --arg message "$ALLOW_NOTICE" '{systemMessage:$message}'; then
  security_failure "failed to build notification"
fi
exit 0
