#!/bin/bash
# see DP.SC.154, DP.ROLE.039
# grok-peer-adapter.sh — Grok CLI (xAI, "Grok Build TUI") adapter for peer-conversation.sh.
# Sibling of codex-peer-adapter.sh (same PII/.agentigore/content-filter reuse,
# same exit-code contract) — fourth peer-agent vendor.
#
# Read-only-by-design: --sandbox read-only + --tools "" + --disable-web-search
# + --no-subagents strip file/shell/web/subagent capability. No --agent flag
# is registered for Grok in session-guard.sh — it never opens/commits sessions,
# only participates as a peer-conversation vendor (ArchGate WP-530 Ф51: pilot
# narrowed scope to read-only; broader session-guard integration deferred).
#
# Known gap (ArchGate WP-530 Ф51, accepted mitigation, not yet automated):
# callers should label Grok's replies as an "unverified critic" for its first
# sessions and pass minimal per-turn context, same as the other vendors already
# receive — this adapter enforces the transport/sandbox side of that, not the
# labeling, which is a writer-side (peer-conversation skill) concern.
#
# Not ported from codex-peer-adapter.sh in this first cut (parity gap, ok for
# now, same posture codex shipped with):
#   - Hindsight L2 retain (IWE_HINDSIGHT_RETAIN) — optional feature, default off
#   - agent-status-report.sh peer-session/idle events — optional, no working
#     example of Grok-specific status reporting yet
#
# Upstream Grok CLI limitation found live (confirmed with Docker Desktop
# actually running, `docker ps` healthy — NOT a "Docker isn't up" issue):
# `--sandbox read-only`/`strict` refuse to start with "socket deny resolution
# failed: could not resolve runtime-socket deny path /var/run/docker.sock:
# endpoint is a symlink". This is an undocumented, automatic deny-path these
# profiles add (not something set via ~/.grok/sandbox.toml, per Grok's own
# sandbox docs) whose resolver can't handle macOS Docker Desktop's
# /var/run/docker.sock → ~/.docker/run/docker.sock symlink convention. No
# documented workaround (no `deny`-list override for a profile's own
# built-in denies). Do not silently fall back to a weaker profile
# ("workspace"/"none") to route around it: fail loudly instead (see below).
#
# Second upstream limitation found live 25.10 (WP-7 Ф259, grok-4.7-build):
# if the model decides to request a tool call anyway (e.g. run_terminal_command
# to "find the branch first"), the headless session has no permission UI —
# the call is answered PermissionCancelled and the WHOLE session ends after
# the first assistant paragraph (stopReason "cancelled", one model call,
# output truncated to the preamble). Symptoms: exit 0, tiny output (one
# introductory sentence), elapsed ~5-10 s. Diagnose with --debug-file
# (look for cancellationCategory PermissionCancelled). Mitigations that
# worked: (a) prompt MUST explicitly forbid tool calls ("Tools and terminal
# are DISABLED... do NOT request any tool calls") — without it the model
# reliably reaches for the terminal on review/diagnosis tasks; (b) --model
# grok-4.6 (4.7 went into a multi-minute hang even with the forbiddance);
# (c) raise GROK_PEER_TIMEOUT_SEC for long reviews. A preamble-only reply
# under ~20 s with stopReason cancelled is this failure, not a verdict.
#
# Env overrides:
#   GROK_BIN      — override grok binary path
#   IWE_PEER_LOCK_DIR — same as codex-peer-adapter.sh
#   GROK_PEER_TIMEOUT_SEC — internal watchdog deadline in seconds (default: 270,
#     same rationale as codex-peer-adapter.sh: shorter than the peer-conversation
#     contract's documented "5 minutes" so this adapter's own timeout fires first)
#
# Exit codes (same contract as kimi/codex-peer-adapter.sh, §0в.1):
#   0 — OK
#   1 — general error (grok not found, args, timeout, empty output, sandbox refused)
#   2 — .agentigore filter violation (Python filter error)
#   3 — PII Hard Block
#   4 — --add-dir too large (>100MB or >5000 files)
#   5 — peer session already running (pidfile lock)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# === Grok binary auto-detect: env override → PATH ===
GROK_BIN="${GROK_BIN:-$(command -v grok 2>/dev/null || true)}"
if [ -z "$GROK_BIN" ] || [ ! -x "$GROK_BIN" ]; then
  echo "ERROR: grok binary not found. Install Grok CLI (xAI) or set GROK_BIN env var." >&2
  exit 1
fi

for FILTER_FILE in peer-adapter-filter.py content-filter-apply.py content-filter-map.txt; do
  if [ ! -s "$SCRIPT_DIR/$FILTER_FILE" ]; then
    echo "ABORT: required local peer filter missing or empty: $SCRIPT_DIR/$FILTER_FILE" >&2
    exit 2
  fi
done

ADD_DIRS=()
MODEL_ARG=()

# WP-516 Ф5 (§0в.1): межвендорский whitelist = {-p, --model, --add-dir}.
# Неизвестный флаг — явная ошибка, не молчаливый игнор.
# --permission-mode исключён намеренно: grok has no such flag anyway, but
# even its closest equivalents (--sandbox, --tools) are NOT accepted from the
# caller here — this adapter hardcodes the read-only posture below, the same
# way claude-peer-adapter.sh refuses --permission-mode.
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p)                shift ;;
    --model)
      [ $# -ge 2 ] || { echo "ERROR: --model requires a value" >&2; exit 1; }
      MODEL_ARG=("--model" "$2"); shift 2 ;;
    --add-dir)
      [ $# -ge 2 ] || { echo "ERROR: --add-dir requires a value" >&2; exit 1; }
      ADD_DIRS+=("$2"); shift 2 ;;
    *)
      echo "ERROR: flag '$1' is not supported by grok adapter (see vendor table §0в)." >&2
      exit 1
      ;;
  esac
done

# === Фильтрация --add-dir через .agentigore + PII sanity-check (соседние копии) ===

FILTERED_DIRS=()
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/grok-peer-XXXXXX")

MERGED_AGENTIGORE="$TMP_ROOT/.agentigore"
: > "$MERGED_AGENTIGORE"
[ -f "$HOME/.iwe/.agentigore" ] && cat "$HOME/.iwe/.agentigore" >> "$MERGED_AGENTIGORE"

for ADD_DIR in "${ADD_DIRS[@]+"${ADD_DIRS[@]}"}"; do
  [ ! -d "$ADD_DIR" ] && continue
  GIT_ROOT=$(git -C "$ADD_DIR" rev-parse --show-toplevel 2>/dev/null || true)
  [ -n "$GIT_ROOT" ] && [ -f "$GIT_ROOT/.agentigore" ] && cat "$GIT_ROOT/.agentigore" >> "$MERGED_AGENTIGORE"
  [ -f "$ADD_DIR/.agentigore" ] && cat "$ADD_DIR/.agentigore" >> "$MERGED_AGENTIGORE"
done

# === Fail-fast на размер ===
for ADD_DIR in "${ADD_DIRS[@]+"${ADD_DIRS[@]}"}"; do
  [ ! -d "$ADD_DIR" ] && continue
  SIZE_MB=$(du -sm "$ADD_DIR" 2>/dev/null | awk '{print $1}')
  FILES=$(find "$ADD_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')
  if [ "${SIZE_MB:-0}" -gt 100 ] || [ "${FILES:-0}" -gt 5000 ]; then
    echo "ABORT: --add-dir $ADD_DIR too large (${SIZE_MB}MB / ${FILES} files; limit 100MB/5000)" >&2
    exit 4
  fi
done

# === Фильтрация через Python fnmatch + PII sanity-check (локальный peer-adapter-filter.py) ===
for ADD_DIR in "${ADD_DIRS[@]+"${ADD_DIRS[@]}"}"; do
  [ ! -d "$ADD_DIR" ] && continue
  CLEAN_DIR="$TMP_ROOT/$(basename "$ADD_DIR")"
  mkdir -p "$CLEAN_DIR"

  AGENTIGORE_FILE="$MERGED_AGENTIGORE" SRC_DIR="$ADD_DIR" DST_DIR="$CLEAN_DIR" \
    python3 "$SCRIPT_DIR/peer-adapter-filter.py"
  RC=$?
  if [ $RC -eq 3 ]; then
    exit 3
  elif [ $RC -ne 0 ]; then
    echo "ABORT: filter failed with code $RC" >&2
    exit 2
  fi

  FILTERED_DIRS+=("--add-dir" "$CLEAN_DIR")
done

# === Content-filter guard (локальная копия content-filter-map.txt) ===
PROMPT_FILE="$TMP_ROOT/peer-prompt.in"
cat > "$PROMPT_FILE"

CONTENT_FILTER_MAP="$SCRIPT_DIR/content-filter-map.txt"
if python3 "$SCRIPT_DIR/content-filter-apply.py" "$CONTENT_FILTER_MAP" \
     --strict-map < "$PROMPT_FILE" > "$PROMPT_FILE.filtered" 2>/dev/null \
   && [ -s "$PROMPT_FILE.filtered" ]; then
  PROMPT_FILE="$PROMPT_FILE.filtered"
else
  echo "ABORT: local peer content filter failed or returned an empty prompt" >&2
  exit 2
fi

# === Sanitize surrogate characters before Grok call ===
if python3 - "$PROMPT_FILE" << 'PYEOF'
import sys
try:
    with open(sys.argv[1], 'r', encoding='utf-8') as f:
        f.read()
    sys.exit(0)
except (UnicodeDecodeError, UnicodeError):
    sys.exit(1)
PYEOF
then
    :
else
    python3 - "$PROMPT_FILE" "$PROMPT_FILE.clean" << 'PYEOF'
import codecs, sys
reader = codecs.getreader('utf-8')(open(sys.argv[1], 'rb'), errors='surrogateescape')
text = reader.read()
sanitized = text.encode('utf-8', errors='replace').decode('utf-8')
with open(sys.argv[2], 'w', encoding='utf-8') as f:
    f.write(sanitized)
PYEOF
    PROMPT_FILE="$PROMPT_FILE.clean"
fi

# === Pidfile lock: предотвращаем параллельные/зависшие копии одной peer-сессии ===
GROK_TASK="$(basename "${ADD_DIRS[0]:-}" 2>/dev/null)"
if [ -z "$GROK_TASK" ]; then GROK_TASK="grok-peer-ppid-${PPID:-$$}"; fi
GROK_SESSION_ID="$GROK_TASK"

LOCK_DIR="${IWE_PEER_LOCK_DIR:-/tmp/grok-peer-locks}"
mkdir -p "$LOCK_DIR"
LOCK_FILE="$LOCK_DIR/${GROK_SESSION_ID//\//_}.pid"
OUR_PID="$$"

if [ -f "$LOCK_FILE" ]; then
  OLD_PID=$(cat "$LOCK_FILE" 2>/dev/null | tr -d '[:space:]')
  if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
    echo "ABORT: peer session '$GROK_SESSION_ID' already running (PID $OLD_PID)" >&2
    exit 5
  fi
fi
echo "$OUR_PID" > "$LOCK_FILE"

cleanup_peer() {
  rm -f "$LOCK_FILE"
  rm -rf "$TMP_ROOT"
}
trap cleanup_peer EXIT INT TERM

# === Запуск Grok headless: `-p`/`--prompt-file`, read-only sandbox, tools stripped ===
#
# --sandbox read-only: filesystem enforcement (not just an instruction to the
# model) — same posture as codex's `-s read-only`. Refusal (e.g. this host's
# docker.sock symlink issue, see header) is a config problem, not something
# to weaken around: propagate as exit 1, do not retry with a laxer profile.
# --tools "" / --disable-web-search / --no-subagents: no file/shell/web/
# subagent capability, same posture as claude-peer-adapter.sh's "text-only,
# no tools" contract for Grok's "read-only commentator" role (WP-530 Ф51).
# --cwd: sandbox root. Without --add-dir this is an empty temp dir (no
# implicit exposure of the writer's working tree) — same invariant as codex.
if [ ${#FILTERED_DIRS[@]} -ge 2 ]; then
  PRIMARY_DIR="${FILTERED_DIRS[1]}"
else
  PRIMARY_DIR="$TMP_ROOT/empty-root"
  mkdir -p "$PRIMARY_DIR"
fi

GROK_ARGS=(--prompt-file "$PROMPT_FILE" --output-format plain --cwd "$PRIMARY_DIR" \
  --sandbox read-only --tools "" --disable-web-search --no-subagents)
if [ ${#MODEL_ARG[@]} -ge 2 ]; then
  GROK_ARGS+=("-m" "${MODEL_ARG[1]}")
fi

kill_tree() {
  local pid="$1" child
  for child in $(pgrep -P "$pid" 2>/dev/null || true); do
    kill_tree "$child"
  done
  kill -TERM "$pid" 2>/dev/null || true
}

GROK_TIMEOUT_SEC="${GROK_PEER_TIMEOUT_SEC:-270}"
GROK_CALL_START=$(date -u +%s)
GROK_TIMEOUT_MARKER="$TMP_ROOT/.watchdog-fired"
OUT_FILE="$TMP_ROOT/grok-output.txt"
ERR_FILE="$TMP_ROOT/grok-stderr.txt"
(
  exec "$GROK_BIN" "${GROK_ARGS[@]}" >"$OUT_FILE" 2>"$ERR_FILE"
) &
GROK_JOB_PID=$!
GROK_TIMED_OUT=false
(
  sleep "$GROK_TIMEOUT_SEC"
  kill -0 "$GROK_JOB_PID" 2>/dev/null || exit 0
  touch "$GROK_TIMEOUT_MARKER" 2>/dev/null || true
  kill_tree "$GROK_JOB_PID"
  sleep 0.3
  kill -0 "$GROK_JOB_PID" 2>/dev/null && kill_tree "$GROK_JOB_PID"
) &
GROK_WATCHDOG_PID=$!
wait "$GROK_JOB_PID"
GROK_EXIT=$?
kill_tree "$GROK_WATCHDOG_PID"
wait "$GROK_WATCHDOG_PID" 2>/dev/null
GROK_CALL_ELAPSED=$(( $(date -u +%s) - GROK_CALL_START ))

[ -f "$GROK_TIMEOUT_MARKER" ] && GROK_TIMED_OUT=true

if [ "$GROK_TIMED_OUT" = true ]; then
  PROMPT_BYTES=$(wc -c < "$PROMPT_FILE" 2>/dev/null | tr -d ' ')
  echo "ERROR: Grok peer call timed out after ${GROK_CALL_ELAPSED}s (internal watchdog, limit ${GROK_TIMEOUT_SEC}s)" >&2
  echo "GROK_TIMEOUT: prompt_bytes=$PROMPT_BYTES add_dirs=$(( ${#FILTERED_DIRS[@]} / 2 )) elapsed_s=$GROK_CALL_ELAPSED" >&2
  exit 1
fi

if [ "$GROK_EXIT" -ne 0 ]; then
  echo "ERROR: Grok peer call failed with exit code $GROK_EXIT (elapsed_s=$GROK_CALL_ELAPSED)" >&2
  [ -s "$ERR_FILE" ] && head -c 2000 "$ERR_FILE" >&2
  exit 1
fi

if [ ! -s "$OUT_FILE" ]; then
  echo "ERROR: grok returned empty output (network/auth/quota?)" >&2
  [ -s "$ERR_FILE" ] && head -c 2000 "$ERR_FILE" >&2
  exit 1
fi

GROK_OUTPUT=$(cat "$OUT_FILE")

# WP-516 Ф5 (§0в.1): stdout обязан начинаться с frontmatter; ответ без
# frontmatter = нарушение формата → exit 1 с диагностикой. Служебные вызовы
# писателя (не peer-реплика) отключают проверку через IWE_PEER_PLAIN=1.
if [ "${IWE_PEER_PLAIN:-0}" != "1" ]; then
  _FIRST_LINE=$(printf '%s\n' "$GROK_OUTPUT" | awk 'length { print; exit }')
  _FM_FENCES=$(printf '%s\n' "$GROK_OUTPUT" | grep -c '^---$' || true)
  if [ "$_FIRST_LINE" != "---" ] || [ "${_FM_FENCES:-0}" -lt 2 ]; then
    echo "ERROR: peer response missing frontmatter (first non-empty line must be '---' with a closing '---')." >&2
    exit 1
  fi

  # WP-484 Ф89: alert-only self-check — доля кириллицы в ответе. Никогда не
  # блокирует вывод, только предупреждает в stderr.
  _LANG_CHECK="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/language-check.py"
  if [ -f "$_LANG_CHECK" ]; then
    _LANG_RESULT=$(printf '%s' "$GROK_OUTPUT" | python3 "$_LANG_CHECK" 2>/dev/null || true)
    if printf '%s' "$_LANG_RESULT" | grep -q '"alert": true'; then
      echo "WARNING: peer response may not be in Russian (language-check alert) — $_LANG_RESULT" >&2
    fi
  fi
fi

# cleanup_peer() через trap удалит lock и temp
echo "$GROK_OUTPUT"
