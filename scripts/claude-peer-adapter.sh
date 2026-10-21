#!/bin/bash
# claude-peer-adapter.sh — adapter Claude for peer-conversation (partner role)
# see DP.SC.154 (symmetric counterpart kimi-peer-adapter.sh)
#
# Invoked by the WRITER agent-WRITER (Kimi or another) when Claude acts as PARTNER.
# Accepts arguments in the style of kimi-peer-adapter.sh, reads the prompt from stdin,
# passes to Claude headless (-p), returns the response to stdout.
#
# Security contract (WP-458, WP-510): the adapter accepts only a text
# projection via stdin. It does not receive working directories and does not give Claude Claude
# file or shell-tools.
# Usage:
#   bash scripts/claude-peer-adapter.sh < peer-prompt.md > peer.md 2> peer.err
# The prompt is passed via a file, not inline `echo "$peer_prompt" | ...` — otherwise the text
# of the prompt ends up on the command line and hook B7.7c falsely blocks repeated
# invocations (bug-2026-06-30-peer-adapter-b77c-block).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/peer-adapter-common.sh
source "$SCRIPT_DIR/lib/peer-adapter-common.sh"

# Claude Code can access its macOS Keychain credentials only outside Codex's
# seatbelt. Running the adapter inside that sandbox produced intermittent blank
# output that looked like success. A caller must use the approved external
# route (`sandbox_permissions=require_escalated` in Codex); do not retry this
# branch or ask the pilot to run /login.
if [ "${CODEX_SANDBOX:-}" = "seatbelt" ]; then
  echo "ERROR: Claude peer adapter must run outside the Codex sandbox to access macOS Keychain. Re-run through the approved external route; /login is not required." >&2
  exit 69
fi

peer_adapter_check_sandbox_network "Claude CLI" 69

# CLAUDE_BIN auto-detect: env override → PATH → user-local fallbacks.
# System paths (homebrew, /usr/local/bin) are usually in PATH and are picked up via command -v.
CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude 2>/dev/null || true)}"
if [ -z "$CLAUDE_BIN" ]; then
  for candidate in \
    "$HOME/.local/bin/claude" \
    "$HOME/.npm-global/bin/claude" \
    "$HOME/.nvm/versions/node/*/bin/claude"; do
    # Expand glob (for nvm-paths)
    for resolved in $candidate; do
      [ -x "$resolved" ] && CLAUDE_BIN="$resolved" && break 2
    done
  done
fi
if [ -z "$CLAUDE_BIN" ] || [ ! -x "$CLAUDE_BIN" ]; then
  echo "ERROR: claude binary not found. Install Claude CLI or set CLAUDE_BIN env var." >&2
  echo "  Install: https://docs.claude.com/en/docs/claude-code/setup" >&2
  exit 1
fi

# The model does not select the adapter: without an explicit --model Claude CLI applies its own
# configured default model. This preserves the separation between persona,
# channel and implementation.
MODEL_ARG=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p)              shift ;;
    --model)
      [ $# -ge 2 ] || { echo "ERROR: --model requires a value" >&2; exit 1; }
      MODEL_ARG=("--model" "$2"); shift 2 ;;
    --add-dir)
      echo "ERROR: --add-dir is disabled for claude-peer-adapter.sh. Put a minimal text projection in stdin instead." >&2
      exit 64
      ;;
    --permission-mode)
      echo "ERROR: permission mode is fixed to dontAsk for claude-peer-adapter.sh." >&2
      exit 64
      ;;
    # WP-516 Phase5: unknown flag — explicit error (§0in.1 whitelist: -p, --model,
    # --add-dir; for claude --add-dir and --permission-mode are forbidden separately, above).
    *)
      echo "ERROR: unknown flag '$1'. Known: -p, --model" >&2
      exit 1
      ;;
  esac
done

# The model is passed only when explicitly chosen by the calling agent. The adapter does not
# assign or substitute the implementation of the peer.

# WP-510 Phase17: text-only must be fail-closed. `plan` plus a deny-list did not
# provide that boundary: Claude could still call Agent, whose child discovered
# ToolSearch and MCP, then the parent timed out without stdout. `--safe-mode`
# removes project customizations/hooks/MCP (verified live 12.08: no mcp__*
# entries in the init event under safe-mode), while `--tools ""` disables the
# built-in tool set entirely (including future tools not known today).
#
# WP-7 Phase66 (12.08, claude 2.1.226): `--allowedTools ""` used to stand in for
# that availability switch, but it is only a permission allow-list — in
# 2.1.226 the session started with all 30 built-in tools live, the model
# explored the filesystem on substantive prompts and burned every turn
# ("Reached max turns (N)") before answering. The documented availability
# switch is `--tools` ("" = disable all tools); verified live: init tools=[],
# zero tool_use, substantive peer reply in 1 turn.
#
# Without tools the model may still *print* a simulated tool call as text
# (observed live), which then fails the frontmatter check below.  A minimal,
# task-independent system-prompt hint forbids simulating tool calls; it is
# part of the text-only transport contract, not peer steering.
TEXT_ONLY_HINT="All tools are disabled for this call by the caller. Do not attempt, simulate, or print tool calls; answer only from the text given in the prompt."
#
# `--no-session-persistence` prevents this ephemeral reviewer from leaving a
# resumable conversation. --add-dir remains forbidden above.
#
# This is still a Claude Code policy boundary, not an OS sandbox. Sensitive
# material requires a separately isolated runner and explicit pilot approval.
#
# Deadline protects the *whole* CLI process group, not only the launcher.  The
# old `perl alarm; exec` delivered SIGALRM solely to the launcher: a forked
# Claude child could outlive it and leave the writer waiting forever (WP-516).
# `run_with_deadline` creates a separate session for the CLI and terminates its
# complete process group on timeout.  Exit 142 is an internal marker converted
# to the transport's general failure (1) below.
IWE_PEER_TIMEOUT_SECONDS="${IWE_PEER_TIMEOUT_SECONDS:-300}"
case "$IWE_PEER_TIMEOUT_SECONDS" in
  ''|*[!0-9]*|0)
    echo "ERROR: IWE_PEER_TIMEOUT_SECONDS must be a positive integer." >&2
    exit 64
    ;;
esac

# run_with_deadline() — see scripts/lib/peer-adapter-common.sh (sourced above).
#
# WP-7 Phase64 (12.08, six independent reproductions across sessions, root-caused
# live in WP-524 Phase3): the old default of 2 assumed one turn for internal
# planning + one for delivery is always enough — DISPROVEN by direct bisection
# against the exact failing prompt from sessions/2026-08/12/.../wp520-witness-
# race-index-null/00-writer.md (recovered via git history, original session
# files since archived): --max-turns 2 → "Reached max turns (2)"; --max-turns
# 15 → still "Reached max turns (15)" after 77s; --max-turns 25 → succeeds in
# ~54s with a full, on-topic multi-part answer. Also ruled out by the same
# bisection: disabling all tools is NOT the cause (removing the flag entirely
# reproduces the identical failure) — the original "empty toolset confuses the
# model" hypothesis (WP-7 Phase64 "Hypothesis") does not hold. The real bottleneck is
# turn budget on multi-part diagnostic/structured prompts, not tool access or
# content policy. Trivial prompts still exit in 1-2 turns (verified earlier in
# Phase64) — raising the ceiling costs nothing on the easy path.
CLAUDE_PEER_MAX_TURNS="${CLAUDE_PEER_MAX_TURNS:-40}"
case "$CLAUDE_PEER_MAX_TURNS" in
  ''|*[!0-9]*)
    echo "ERROR: CLAUDE_PEER_MAX_TURNS must be a positive integer." >&2
    exit 64
    ;;
esac
[ "$CLAUDE_PEER_MAX_TURNS" -ge 2 ] || {
  echo "ERROR: CLAUDE_PEER_MAX_TURNS must be at least 2 to reserve a response turn." >&2
  exit 64
}

CLAUDE_STDERR="$(mktemp)"
trap 'rm -f "$CLAUDE_STDERR"' EXIT

# WP-524 (Codex, Phase66 review): log the CLI version in every diagnostic — the
# 2.1.226 semantics break above was silent precisely because failures carried
# no version marker. Cheap local call, no network. `</dev/null`: the probe
# must not eat the prompt from the adapter's stdin; `|| true`: a fake/odd
# binary failing --version must not kill the adapter under set -e + pipefail.
CLAUDE_VERSION="$("$CLAUDE_BIN" --version </dev/null 2>/dev/null | head -1 || true)"

adapter_diagnostic() {
  local cli_exit="$1"
  local stdout_bytes stderr_bytes
  stdout_bytes=$(printf '%s' "$CLAUDE_OUTPUT" | wc -c | tr -d '[:space:]')
  stderr_bytes=$(wc -c < "$CLAUDE_STDERR" | tr -d '[:space:]')
  printf 'DIAGNOSTIC: vendor=claude cli_exit=%s timeout_seconds=%s stdout_bytes=%s stderr_bytes=%s cli_version=%s\n' \
    "$cli_exit" "$IWE_PEER_TIMEOUT_SECONDS" "$stdout_bytes" "$stderr_bytes" "$CLAUDE_VERSION" >&2
}

CLAUDE_OUTPUT=$(run_with_deadline "$IWE_PEER_TIMEOUT_SECONDS" \
  "$CLAUDE_BIN" -p \
  --safe-mode \
  --tools "" \
  --permission-mode dontAsk \
  --max-turns "$CLAUDE_PEER_MAX_TURNS" \
  --no-session-persistence \
  --append-system-prompt "$TEXT_ONLY_HINT" \
  ${MODEL_ARG[@]+"${MODEL_ARG[@]}"} \
  "$@" 2>"$CLAUDE_STDERR") && CLAUDE_EXIT=0 || CLAUDE_EXIT=$?

# Auth-failure detection (peer-session 2026-08-04-08-wp7-f44-sandbox-review):
# macOS Keychain can be unreachable from a sandboxed child process (e.g. a
# Codex workspace-write sandbox) even when the pilot's own Claude Code login
# is valid — that surfaces as literal "Not logged in" text, not necessarily a
# non-zero exit. stderr is checked unconditionally (diagnostic channel);
# stdout only when the process itself also exited non-zero, so a genuine
# reply that happens to discuss login/auth text isn't misclassified as a
# failure (this environment discusses login issues often).
AUTH_PATTERN='Not logged in|Please run.*login'
if grep -qE "$AUTH_PATTERN" "$CLAUDE_STDERR" 2>/dev/null || \
   { [ "$CLAUDE_EXIT" -ne 0 ] && printf '%s' "$CLAUDE_OUTPUT" | grep -qE "$AUTH_PATTERN"; }; then
  echo "ERROR: Claude peer call looks unauthenticated (Not logged in). Common sandbox/Keychain artifact, not necessarily lost login — verify from a trusted terminal before re-running /login." >&2
  if [ -s "$CLAUDE_STDERR" ]; then
    echo "--- claude stderr (tail) ---" >&2
    tail -20 "$CLAUDE_STDERR" >&2
  fi
  adapter_diagnostic "$CLAUDE_EXIT"
  # WP-516 Phase5: canonical code 6 = auth failure (§0in.1); previously was 4,
  # which conflicted with the actual «add-dir error» in kimi/codex-adapters.
  exit 6
fi

if [ "$CLAUDE_EXIT" -eq 142 ]; then
  echo "ERROR: Claude peer call timed out after ${IWE_PEER_TIMEOUT_SECONDS}s; its process group was terminated." >&2
  echo "CLAUDE_TIMEOUT: peer call exceeded configured deadline" >&2
  [ -s "$CLAUDE_STDERR" ] && tail -20 "$CLAUDE_STDERR" >&2
  adapter_diagnostic "$CLAUDE_EXIT"
  exit 1
fi

if [ "$CLAUDE_EXIT" -ne 0 ]; then
  echo "ERROR: Claude peer call failed with exit code $CLAUDE_EXIT." >&2
  [ -s "$CLAUDE_STDERR" ] && tail -20 "$CLAUDE_STDERR" >&2
  # Probe-on-failure only (peer-session 2026-08-15-05, Codex review): a CLI
  # failure with no reachable API is an environment problem, not a Claude one —
  # say so.  The healthy path pays no network-probe latency.
  if command -v curl >/dev/null 2>&1 && \
     ! curl -sI --max-time 3 https://api.anthropic.com >/dev/null 2>&1; then
    echo "HINT: api.anthropic.com is unreachable from this environment — likely a sandboxed/offline context, not a Claude failure." >&2
  fi
  adapter_diagnostic "$CLAUDE_EXIT"
  # Child exit codes are vendor-specific.  Never leak 2-7 here: callers may
  # otherwise mistake them for canonical adapter classifications.
  exit 1
fi

if ! printf '%s' "$CLAUDE_OUTPUT" | grep -q '[[:alnum:]]'; then
  echo "ERROR: Claude peer call returned no substantive response." >&2
  [ -s "$CLAUDE_STDERR" ] && tail -20 "$CLAUDE_STDERR" >&2
  adapter_diagnostic "$CLAUDE_EXIT"
  # WP-516 Phase5: canonical code 7 = empty response after trimming (§0in.1);
  # previously was 5, which overrode the canonical «pidfile lock».
  exit 7
fi

# WP-516 Phase5 (§0v.1): stdout must start with frontmatter; response without
# frontmatter = format violation → exit 1 with diagnostics.
# Validation — for peer-replies turn-loop. Utility calls of the writer
# (review/verify/synth), whose output — NOT peer-reply, disable it
# via IWE_PEER_PLAIN=1 (layer IWE-integration, §0v.1).
if [ "${IWE_PEER_PLAIN:-0}" != "1" ]; then
  peer_adapter_check_frontmatter "$CLAUDE_OUTPUT"
  peer_adapter_check_language "$CLAUDE_OUTPUT"
fi

printf '%s\n' "$CLAUDE_OUTPUT"
