#!/bin/bash
# kimi-peer-adapter.sh v3 — адаптер Kimi для peer-conversation.sh с PII-фильтрацией
# see DP.SC.154 (З-Ф5), DP.ROLE.039, WP-365 Ф2-Ф3 (peer-session 2026-05-29-27)
#
# Принимает аргументы в стиле Claude (-p --model X --add-dir Y --permission-mode Z),
# применяет .agentigore filter + PII sanity-check,
# вызывает Kimi с очищенной директорией.
#
# Env overrides:
#   IWE_PEER_LOCK_DIR     — pidfile lock directory (default: /tmp/kimi-peer-locks)
#   IWE_PEER_DIFF         — enable session-state diff (git diff HEAD) (default: 0)
#   IWE_PEER_DIFF_REPOS   — CSV of repos for diff (default: auto-detect from first --add-dir)
#   IWE_PEER_DIFF_LIMIT   — soft limit for diff size in bytes (default: 61440)
#   IWE_PEER_DIFF_PARTIAL — truncated diff size in bytes (default: 30720)
#   IWE_PEER_INLINE       — inline files into prompt instead of --add-dir (default: 0)
#   IWE_HINDSIGHT_RETAIN  — enable hindsight L2 retain (default: 0)
#   KIMI_BIN              — override kimi binary path
#   KIMI_MAX_TOKENS       — hard token limit per session via guard (default: 800000)
#   KIMI_MAX_ADD_DIR_TOKENS — estimated token limit for --add-dir (default: 130000)
#
# Exit codes:
#   0 — OK
#   1 — general error (kimi not found, args)
#   2 — .agentigore filter violation (Python filter error)
#   3 — PII Hard Block (sanity-check found high-severity pattern)
#   4 — --add-dir too large (>100MB or >5000 files or >KIMI_MAX_ADD_DIR_TOKENS)
#   5 — peer session already running (pidfile lock)
#   6 — WP Gate блок отсутствует в peer-prompt.md (с 2026-06-09)
#   77 — session stopped by token guard (limit exceeded)

set -uo pipefail

# Declared before cleanup_peer's trap is armed (below) so `set -u` can't fault
# on an unset read if the script exits early, before the lock is ever attempted.
OAUTH_LOCK_DIR="${IWE_PEER_LOCK_DIR:-/tmp/kimi-peer-locks}/kimi-oauth-refresh.lockdir"
OAUTH_LOCK_HELD=false

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# KIMI_BIN auto-detect: env override → PATH → VS Code extension paths (macOS/Linux/WSL)
KIMI_BIN="${KIMI_BIN:-$(command -v kimi 2>/dev/null || true)}"
if [ -z "$KIMI_BIN" ]; then
  for candidate in \
    "$HOME/Library/Application Support/Code/User/globalStorage/moonshot-ai.kimi-code/bin/kimi/kimi" \
    "$HOME/.config/Code/User/globalStorage/moonshot-ai.kimi-code/bin/kimi/kimi" \
    "$HOME/.local/share/code-server/User/globalStorage/moonshot-ai.kimi-code/bin/kimi/kimi" \
    "$HOME/AppData/Roaming/Code/User/globalStorage/moonshot-ai.kimi-code/bin/kimi/kimi"; do
    [ -x "$candidate" ] && KIMI_BIN="$candidate" && break
  done
fi

if [ -z "$KIMI_BIN" ] || [ ! -x "$KIMI_BIN" ]; then
  echo "ERROR: kimi binary not found. Install Kimi CLI or set KIMI_BIN env var." >&2
  echo "  Looked in: PATH, ~/Library/.../moonshot-ai.kimi-code (macOS)," >&2
  echo "             ~/.config/Code/.../moonshot-ai.kimi-code (desktop VS Code, Linux)," >&2
  echo "             ~/.local/share/code-server/.../moonshot-ai.kimi-code (code-server, Linux)," >&2
  echo "             ~/AppData/Roaming/Code/.../moonshot-ai.kimi-code (Windows)" >&2
  exit 1
fi

ADD_DIRS=()
MODEL_ARG=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p)                shift ;;
    --model)           MODEL_ARG=("--model" "$2"); shift 2 ;;
    --add-dir)         ADD_DIRS+=("$2"); shift 2 ;;
    --permission-mode) shift 2 ;;
    *)                 shift ;;
  esac
done

if [ ${#MODEL_ARG[@]} -ge 2 ]; then
  case "${MODEL_ARG[1]-}" in
    sonnet|opus|haiku|claude-*) MODEL_ARG=() ;;
  esac
fi

# === Pre-flight: WP Gate check (peer-session 2026-06-09) ===
# Если в --add-dir есть peer-prompt.md — проверить наличие блока «Открытие (WP Gate)».
# Эффективная дата: 2026-06-09. Сессии до этой даты не проверяются (grandfathered).
WP_GATE_EFFECTIVE_DATE="20260609"
for ADD_DIR in "${ADD_DIRS[@]+"${ADD_DIRS[@]}"}"; do
  PEER_PROMPT_FILE="$ADD_DIR/peer-prompt.md"
  [ ! -f "$PEER_PROMPT_FILE" ] && continue
  # Определить дату сессии из имени директории (YYYY-MM-DD-NN-slug)
  SESSION_DATE=$(basename "$ADD_DIR" | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}' | tr -d '-' || true)
  [ -z "$SESSION_DATE" ] && SESSION_DATE="99999999"  # без даты — проверять всегда
  [[ "$SESSION_DATE" =~ ^[0-9]{8}$ ]] || SESSION_DATE="99999999"  # нечисловой формат — проверять всегда
  if [ "$SESSION_DATE" -ge "$WP_GATE_EFFECTIVE_DATE" ]; then
    if ! grep -q "Открытие (WP Gate)" "$PEER_PROMPT_FILE"; then
      echo "WP-GATE-WARN: peer-prompt.md не содержит блок «Открытие (WP Gate)»." >&2
      echo "  Файл: $PEER_PROMPT_FILE" >&2
      echo "  Добавьте секцию по шаблону ~/.tmp/peer-prompt-TEMPLATE.md" >&2
      echo "  Чтобы продолжить без блока — удалите peer-prompt.md или добавьте # WP_GATE_SKIP" >&2
      exit 6
    fi
  fi
done

# === Фильтрация --add-dir через .agentigore + PII sanity-check ===

FILTERED_DIRS=()
# `mktemp -d -t PREFIX` means different things on GNU and BSD (docs/PLATFORM-COMPAT.md).
# Passing an explicit template keeps the readable prefix and behaves the same on both —
# identical form to codex-peer-adapter.sh.
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/kimi-peer-XXXXXX")

# Merged .agentigore (union: ~/.iwe → git-root → session_dir)
MERGED_AGENTIGORE="$TMP_ROOT/.agentigore"
: > "$MERGED_AGENTIGORE"
[ -f "$HOME/.iwe/.agentigore" ] && cat "$HOME/.iwe/.agentigore" >> "$MERGED_AGENTIGORE"

# Per --add-dir: merge git-root + session-dir .agentigore (если есть)
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
    rm -rf "$TMP_ROOT"
    exit 4
  fi
done

# === Token budget pre-flight (WP-394 Ф3.2 guard, lessons_kimi_adapter_adddir_token_limit) ===
MAX_ADD_DIR_TOKENS="${KIMI_MAX_ADD_DIR_TOKENS:-130000}"
for ADD_DIR in "${ADD_DIRS[@]+"${ADD_DIRS[@]}"}"; do
  [ ! -d "$ADD_DIR" ] && continue
  # Консервативная оценка: ~2 символа на токен (русский + markdown + code)
  CHARS=$(find "$ADD_DIR" -type f -not -path '*/\.*' -exec cat {} + 2>/dev/null | wc -c | tr -d ' ')
  EST_TOKENS=$(( CHARS / 2 ))
  if [ "${EST_TOKENS:-0}" -gt "$MAX_ADD_DIR_TOKENS" ]; then
    echo "ABORT: --add-dir '$ADD_DIR' estimated at ~${EST_TOKENS} tokens (limit: ${MAX_ADD_DIR_TOKENS})." >&2
    echo "  Use specific file paths in prompt instead, or split into smaller directories." >&2
    echo "  See: lessons_kimi_adapter_adddir_token_limit.md" >&2
    rm -rf "$TMP_ROOT"
    exit 4
  fi
done

# === Фильтрация через Python fnmatch + PII sanity-check ===
for ADD_DIR in "${ADD_DIRS[@]+"${ADD_DIRS[@]}"}"; do
  [ ! -d "$ADD_DIR" ] && continue
  CLEAN_DIR="$TMP_ROOT/$(basename "$ADD_DIR")"
  mkdir -p "$CLEAN_DIR"

  AGENTIGORE_FILE="$MERGED_AGENTIGORE" SRC_DIR="$ADD_DIR" DST_DIR="$CLEAN_DIR" \
    python3 "$SCRIPT_DIR/peer-adapter-filter.py"
  RC=$?
  if [ $RC -eq 3 ]; then
    rm -rf "$TMP_ROOT"
    exit 3
  elif [ $RC -ne 0 ]; then
    echo "ABORT: filter failed with code $RC" >&2
    rm -rf "$TMP_ROOT"
    exit 2
  fi

  FILTERED_DIRS+=("--add-dir" "$CLEAN_DIR")
done

# === Content-filter guard (WP-394 Ф3.2; дизайн Kimi, реализация+правки Claude) ===
# Переформулирует слова-маркеры чувствительных данных в промпте ДО подачи в Moonshot,
# чтобы defensive content policy не давала ложный block (HTTP 400 high risk) на
# легитимных peer-сессиях про auth/secrets. См. memory/lessons_kimi_content_filter.md.
# Map optional: отсутствует/пуст → identity passthrough (zero overhead).
# Byte-exact: промпт пишется в файл (в TMP_ROOT, уже под trap) и подаётся редиректом.
# no-op режим сохраняет stdin байт-в-байт, включая trailing newlines
# (фикс регрессии $(cat), которая их срезала — cold-review Kimi, ход 3).
PROMPT_FILE="$TMP_ROOT/peer-prompt.in"
cat > "$PROMPT_FILE"

# === Session-state diff (WP-383 peer-session 2026-06-04-35; дизайн Claude, ревью Kimi) ===
# Системно закрывает statefulness-пробел: Kimi не видит правок кода, сделанных писателем
# в текущей сессии (через --add-dir идёт только markdown-журнал). Адаптер сам собирает
# git diff HEAD затронутых репо и подклеивает в начало промпта.
# Opt-in via IWE_PEER_DIFF=1 (решение пилота: opt-in = "пилот должен помнить"); size-guard 60KB soft.
# Репо: env IWE_PEER_DIFF_REPOS (CSV) ИЛИ git-root первой --add-dir; null git-root → skip.
if [ "${IWE_PEER_DIFF:-0}" = "1" ]; then
  DIFF_SOFT_LIMIT="${IWE_PEER_DIFF_LIMIT:-61440}"   # 60 KB
  DIFF_PARTIAL="${IWE_PEER_DIFF_PARTIAL:-30720}"    # 30 KB при усечении
  DIFF_REPOS=()
  if [ -n "${IWE_PEER_DIFF_REPOS:-}" ]; then
    IFS=',' read -ra DIFF_REPOS <<< "$IWE_PEER_DIFF_REPOS"
  else
    FIRST_DIR="${ADD_DIRS[0]:-}"
    if [ -n "$FIRST_DIR" ] && [ -d "$FIRST_DIR" ]; then
      AUTO_ROOT=$(git -C "$FIRST_DIR" rev-parse --show-toplevel 2>/dev/null || true)
      [ -n "$AUTO_ROOT" ] && DIFF_REPOS=("$AUTO_ROOT")
    fi
  fi

  if [ "${#DIFF_REPOS[@]}" -ge 1 ]; then
    DIFF_BLOCK="$TMP_ROOT/session-diff.txt"
    : > "$DIFF_BLOCK"
    for REPO in "${DIFF_REPOS[@]}"; do
      REPO="$(echo "$REPO" | xargs)"   # trim
      [ -z "$REPO" ] && continue
      git -C "$REPO" rev-parse --show-toplevel >/dev/null 2>&1 || continue
      RAW_DIFF=$(git -C "$REPO" diff HEAD --no-ext-diff \
        -- . \
        ':(exclude)*.DS_Store' \
        ':(exclude)*.db' \
        ':(exclude)*.sqlite' \
        ':(exclude)*.sqlite3' \
        ':(exclude)*.bin' \
        ':(exclude)*.pyc' \
        ':(exclude)*.png' \
        ':(exclude)*.jpg' \
        ':(exclude)*.jpeg' \
        ':(exclude)*.gif' \
        ':(exclude)*.ico' \
        ':(exclude)*.woff' \
        ':(exclude)*.woff2' \
        ':(exclude)*.ttf' \
        ':(exclude)*.eot' \
        2>/dev/null)
      [ -z "$RAW_DIFF" ] && continue
      {
        echo "### Репо: $(basename "$REPO")"
        echo '```diff-stat'
        git -C "$REPO" diff HEAD --stat 2>/dev/null
        echo '```'
        DIFF_BYTES=$(printf '%s' "$RAW_DIFF" | wc -c | tr -d ' ')
        echo '```diff'
        if [ "${DIFF_BYTES:-0}" -le "$DIFF_SOFT_LIMIT" ]; then
          printf '%s\n' "$RAW_DIFF"
        else
          { printf '%s' "$RAW_DIFF" | head -c "$DIFF_PARTIAL"; } || true
          echo ""
          echo "... [патч усечён: ${DIFF_BYTES} байт > ${DIFF_SOFT_LIMIT}; показано первые ${DIFF_PARTIAL}. Полный список файлов — в stat выше]"
        fi
        echo '```'
        echo ""
      } >> "$DIFF_BLOCK"
    done
    if [ -s "$DIFF_BLOCK" ]; then
      COMBINED="$TMP_ROOT/peer-prompt.combined"
      {
        echo "## Состояние сессии (правки кода писателя, git diff HEAD)"
        echo ""
        cat "$DIFF_BLOCK"
        echo "---"
        echo ""
        cat "$PROMPT_FILE"
      } > "$COMBINED"
      PROMPT_FILE="$COMBINED"
    fi
  fi
fi

CONTENT_FILTER_MAP="$SCRIPT_DIR/content-filter-map.txt"
if [ -f "$CONTENT_FILTER_MAP" ] && [ -s "$CONTENT_FILTER_MAP" ]; then
  if python3 "$SCRIPT_DIR/content-filter-apply.py" "$CONTENT_FILTER_MAP" \
       < "$PROMPT_FILE" > "$PROMPT_FILE.filtered" 2>/dev/null \
     && [ -s "$PROMPT_FILE.filtered" ]; then
    PROMPT_FILE="$PROMPT_FILE.filtered"
  fi
  # ошибка/пустой вывод Python → остаётся исходный $PROMPT_FILE (fallback)
fi

# === Sanitize surrogate characters before Kimi call (WP-395 Ф3) ===
# Lazy-check: только если файл содержит surrogates, иначе zero overhead.
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

# === Inline session files into prompt (WP-395 Ф3 performance fix) ===
# --add-dir causes Kimi CLI to index/analyze files, taking 5+ minutes.
# Instead, include file contents inline in the prompt — reduces time to ~10s.
# Opt-in via IWE_PEER_INLINE=1; default uses legacy --add-dir for backward compatibility.
if [ "${IWE_PEER_INLINE:-0}" = "1" ] && [ ${#FILTERED_DIRS[@]} -ge 2 ]; then
  INLINE_FILES="$TMP_ROOT/peer-prompt.inline"
  {
    cat "$PROMPT_FILE"
    echo ""
    echo "=== Файлы сессии (для контекста) ==="
    echo ""
    # Iterate over filtered dirs, include .md and .txt files
    for ((i=1; i<${#FILTERED_DIRS[@]}; i+=2)); do
      DIR="${FILTERED_DIRS[$i]}"
      [ -d "$DIR" ] || continue
      find "$DIR" -maxdepth 1 -type f \( -name "*.md" -o -name "*.txt" -o -name "*.yaml" -o -name "*.json" \) -print0 2>/dev/null | \
        sort -z | while IFS= read -r -d '' f; do
          fname=$(basename "$f")
          echo "--- $fname ---"
          cat "$f"
          echo ""
      done
    done
  } > "$INLINE_FILES"
  PROMPT_FILE="$INLINE_FILES"
fi

# === РП-395 Ф3 fail-safe: статус kimi=peer-session на время прогона (backgrounded, best-effort) ===
# task = имя session-dir из --add-dir (информативно в dashboard); fallback — generic
# WP-398 Ф2: session_id = имя session-dir (реальный id peer-сессии), не 'default'.
# Fallback: если --add-dir не передан, используем PPID родителя вместо generic имени,
# чтобы избежать коллизии lock'ов между независимыми вызовами без --add-dir.
KIMI_TASK="$(basename "${ADD_DIRS[0]:-}" 2>/dev/null)"
if [ -z "$KIMI_TASK" ]; then
  KIMI_TASK="kimi-peer-ppid-${PPID:-$$}"
fi
KIMI_SESSION_ID="$KIMI_TASK"

# === Peer session semaphore for watchdog visibility (WP-7 KHP2) ===
# Peer sessions are not standalone sessions, but watchdog only scans
# .iwe-runtime/sessions/kimi-*.open. Create a peer-specific semaphore and
# keep a background heartbeat so a stuck peer call is detected the same way
# as a stuck standalone session.
IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
SESSION_DIR="$IWE_ROOT/.iwe-runtime/sessions"
PEER_SEM_FILE="$SESSION_DIR/kimi-peer-${KIMI_SESSION_ID//\//_}.open"
mkdir -p "$SESSION_DIR"
_KIMI_SESSION_START_TIME="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
{
  echo "opened_at: $_KIMI_SESSION_START_TIME"
  echo "wp: WP-7"
  echo "task: $KIMI_TASK"
  echo "agent: kimi-peer"
  echo "heartbeat_at: $_KIMI_SESSION_START_TIME"
} > "$PEER_SEM_FILE"

peer_heartbeat_loop() {
  local sem="$1"
  while [ -f "$sem" ]; do
    {
      echo "heartbeat_at: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
      echo "heartbeat_pid: $$"
    } >> "$sem"
    sleep 120
  done
}
peer_heartbeat_loop "$PEER_SEM_FILE" &
PEER_HB_PID=$!

# === Pidfile lock: предотвращаем параллельные/зависшие копии одной peer-сессии ===
# Если предыдущий вызов адаптера не завершился (VS Code reconnect, SIGKILL, баг),
# новый вызов с тем же session_id обнаружит живой PID и выйдет с ошибкой.
LOCK_DIR="${IWE_PEER_LOCK_DIR:-/tmp/kimi-peer-locks}"
mkdir -p "$LOCK_DIR"
LOCK_FILE="$LOCK_DIR/${KIMI_SESSION_ID//\//_}.pid"
OUR_PID="$$"

if [ -f "$LOCK_FILE" ]; then
  OLD_PID=$(cat "$LOCK_FILE" 2>/dev/null | tr -d '[:space:]')
  if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
    echo "ABORT: peer session '$KIMI_SESSION_ID' already running (PID $OLD_PID)" >&2
    exit 5
  fi
  # stale lock — перезаписываем
fi
echo "$OUR_PID" > "$LOCK_FILE"

# agent-status-report.sh — DRY path, fail-safe if missing (e.g. standalone test)
_IWE_ARS="$HOME/IWE/scripts/agent-status-report.sh"

# Cleanup: удалить lock + перевести статус в idle при любом выходе
cleanup_peer() {
  rm -f "$LOCK_FILE"
  [ -x "$_IWE_ARS" ] && bash "$_IWE_ARS" --session-id "$KIMI_SESSION_ID" kimi idle 2>/dev/null &
  # Stop peer heartbeat and remove watchdog semaphore
  kill "$PEER_HB_PID" 2>/dev/null || true
  rm -f "$PEER_SEM_FILE"
  rm -rf "$TMP_ROOT"
  # Only release the OAuth-refresh lock if this invocation actually holds it —
  # an invocation that gave up waiting must never remove the winner's lock.
  # rm -rf, not rmdir: the lock dir holds a pid file (staleness check), not empty.
  [ "$OAUTH_LOCK_HELD" = true ] && rm -rf "$OAUTH_LOCK_DIR" 2>/dev/null
}
trap cleanup_peer EXIT INT TERM
[ -x "$_IWE_ARS" ] && bash "$_IWE_ARS" --session-id "$KIMI_SESSION_ID" kimi peer-session "$KIMI_TASK" 2>/dev/null &

# === Запуск Kimi с inline prompt + guard + 5min timeout (perl alarm) ===
GUARD_BIN="${SCRIPT_DIR}/kimi-session-guard.sh"
[ ! -x "$GUARD_BIN" ] && GUARD_BIN="${HOME}/.iwe/kimi-session-guard.sh"
GUARD_ARGS=()
if [ -x "$GUARD_BIN" ]; then
  GUARD_ARGS=("$GUARD_BIN" --max-tokens "${KIMI_MAX_TOKENS:-800000}" --)
fi

# === Kimi CLI style detect (kimi-code >=0.29 dropped --quiet and stdin prompt mode) ===
# Legacy CLI: prompt via stdin, flags --quiet --yolo.
# New CLI (kimi-code): prompt ONLY as -p argument (stdin is ignored, '-' is literal),
# -p is mutually exclusive with --yolo/--auto; response is extracted from
# --output-format stream-json, because text mode mixes reasoning bullets into stdout.
if "$KIMI_BIN" --help 2>/dev/null | grep -q -- '--quiet'; then
  KIMI_CLI_STYLE="legacy"
else
  KIMI_CLI_STYLE="prompt-arg"
fi

KIMI_STDERR="$TMP_ROOT/kimi.stderr"

if [ "$KIMI_CLI_STYLE" = "prompt-arg" ]; then
  # Single-argv limit: Linux MAX_ARG_STRLEN is 128KiB per argument; macOS ARG_MAX ~1MiB total.
  PROMPT_BYTES=$(wc -c < "$PROMPT_FILE" | tr -d ' ')
  case "$(uname -s)" in
    Linux) PROMPT_ARG_LIMIT=120000 ;;
    *)     PROMPT_ARG_LIMIT=900000 ;;
  esac
  if [ "${PROMPT_BYTES:-0}" -gt "$PROMPT_ARG_LIMIT" ]; then
    echo "ABORT: prompt ${PROMPT_BYTES}B exceeds single-argument limit ${PROMPT_ARG_LIMIT}B — kimi-code >=0.29 only accepts the prompt as a -p argument." >&2
    echo "  Reduce diff volume (IWE_PEER_DIFF_LIMIT) / inline size, or split the turn." >&2
    exit 4
  fi
  # A model alias missing from the new CLI's config.toml fails the whole call
  # (config.invalid) — drop unknown aliases and fall back to default_model.
  KIMI_CODE_CFG="$HOME/.kimi-code/config.toml"
  if [ ${#MODEL_ARG[@]} -ge 2 ]; then
    if [ -f "$KIMI_CODE_CFG" ] && ! grep -qF "[models.\"${MODEL_ARG[1]}\"]" "$KIMI_CODE_CFG"; then
      echo "WARN: model '${MODEL_ARG[1]}' is not configured in kimi-code — falling back to default_model" >&2
      MODEL_ARG=()
    fi
  fi
  # -p mode cannot take --yolo/--auto; tool auto-approval relies on
  # default_permission_mode = "yolo" in config.toml. Without it a tool-using
  # turn hangs until the 5min alarm — warn early so the cause is visible.
  if [ -f "$KIMI_CODE_CFG" ] && \
     ! grep -qE '^[[:space:]]*default_permission_mode[[:space:]]*=[[:space:]]*"(yolo|auto)"' "$KIMI_CODE_CFG"; then
    echo "WARN: default_permission_mode is not 'yolo'/'auto' in kimi-code config — tool calls in -p mode may hang until the 5min timeout" >&2
  fi
  # $(cat) strips trailing newlines — harmless at the final CLI handoff (prompt semantics
  # unchanged); byte-exactness matters only inside the filter pipeline above.
  KIMI_PROMPT_ARGS=("-p" "$(cat "$PROMPT_FILE")" "--print" "--output-format" "stream-json")
fi

# OAuth-refresh lock: all Kimi processes on this machine share one token file
# keyed by server URL (~/.kimi/mcp-oauth/), not by PID/session — Kimi CLI itself
# has no advisory lock on it (verified in peer-session 2026-07-01-31-oauth-refresh-regression).
# Concurrent kimi-peer-adapter.sh invocations racing on the same refresh_token trigger
# Ory reuse-detection, which revokes the token and forces a fresh browser login.
# We can't patch the closed Kimi binary, so we serialize our own invocations instead.
#
# Portable mkdir-based lock (peer-session 2026-08-04-08-wp7-f44-sandbox-review):
# the previous `lockf` binary is BSD/macOS-only and absent on most Linux
# distros — the old code silently skipped serialization when missing (found
# 04.08, pilot decision: eliminate the dependency rather than choose between
# fail-open and fail-closed). `mkdir` is atomic on every POSIX filesystem.
acquire_oauth_lock() {
  mkdir -p "$(dirname "$OAUTH_LOCK_DIR")" 2>/dev/null
  local waited=0
  while true; do
    if mkdir "$OAUTH_LOCK_DIR" 2>/dev/null; then
      echo "$$" > "$OAUTH_LOCK_DIR/pid" 2>/dev/null
      OAUTH_LOCK_HELD=true
      return 0
    fi
    # Stale-lock guard: liveness (kill -0 on the holder's PID), not age — a
    # legitimate Kimi call can run up to 300s (perl alarm below), well past
    # any fixed timeout, so a time-based guard would steal a live holder's
    # lock (found in cold review of peer-session
    # 2026-08-04-08-wp7-f44-sandbox-review, same pattern already used for
    # the pidfile lock above). No sleep is skipped on this branch — always
    # falls through to the shared wait below, so a holder whose pid file
    # hasn't landed yet (mkdir/pid-write isn't atomic together) just waits
    # a beat instead of racing to break a lock it can't yet identify.
    local holder_pid
    holder_pid=$(cat "$OAUTH_LOCK_DIR/pid" 2>/dev/null | tr -d '[:space:]')
    if [ -n "$holder_pid" ] && ! kill -0 "$holder_pid" 2>/dev/null; then
      rm -rf "$OAUTH_LOCK_DIR" 2>/dev/null
    fi
    [ "$waited" -ge 90 ] && return 1
    sleep 1
    waited=$((waited + 1))
  done
}
if ! acquire_oauth_lock; then
  echo "ERROR: OAuth refresh lock busy after 90s — another Kimi process is mid-refresh on $OAUTH_LOCK_DIR." >&2
  exit 1
fi

# Inline mode: prompt already contains the files, --add-dir not needed
KIMI_DIR_ARGS=()
if [ "${IWE_PEER_INLINE:-0}" != "1" ]; then
  KIMI_DIR_ARGS=(${FILTERED_DIRS[@]+"${FILTERED_DIRS[@]}"})
fi

if [ "$KIMI_CLI_STYLE" = "prompt-arg" ]; then
  KIMI_RAW=$(perl -e 'alarm 300; exec @ARGV' -- \
    "${GUARD_ARGS[@]+"${GUARD_ARGS[@]}"}" "$KIMI_BIN" \
    "${KIMI_PROMPT_ARGS[@]}" \
    ${MODEL_ARG[@]+"${MODEL_ARG[@]}"} \
    ${KIMI_DIR_ARGS[@]+"${KIMI_DIR_ARGS[@]}"} \
    < /dev/null \
    2>"$KIMI_STDERR")
else
  KIMI_RAW=$(perl -e 'alarm 300; exec @ARGV' -- \
    "${GUARD_ARGS[@]+"${GUARD_ARGS[@]}"}" "$KIMI_BIN" --quiet --yolo \
    ${MODEL_ARG[@]+"${MODEL_ARG[@]}"} \
    ${KIMI_DIR_ARGS[@]+"${KIMI_DIR_ARGS[@]}"} \
    < "$PROMPT_FILE" \
    2>"$KIMI_STDERR")
fi
# $? read directly off the assignment — no pipe inside the command substitution,
# so it can't be masked by grep's exit code the way PIPESTATUS[0] was after `fi`
# (verified empirically in peer-session 2026-07-01-31-oauth-refresh-regression).
PERL_EXIT=$?

if [ "$KIMI_CLI_STYLE" = "prompt-arg" ]; then
  # stream-json: keep only assistant text; meta lines (resume hint) drop out naturally.
  # Exit 10 = input WAS JSON but held no assistant text (e.g. CLI retry loop died
  # mid-turn with only meta/tool events) — that is "no answer", not format drift.
  KIMI_OUTPUT=$(printf '%s\n' "$KIMI_RAW" | python3 -c '
import json, sys
parts = []
saw_json = False
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        evt = json.loads(line)
    except ValueError:
        continue
    saw_json = True
    if evt.get("role") != "assistant":
        continue
    content = evt.get("content")
    if isinstance(content, str):
        parts.append(content)
    elif isinstance(content, list):
        for block in content:
            if isinstance(block, dict) and block.get("type") == "text":
                parts.append(block.get("text", ""))
text = "\n".join(p for p in parts if p)
sys.stdout.write(text)
sys.exit(10 if (saw_json and not text) else 0)
')
  PARSE_RC=$?
  # Raw pass-through only for genuine format drift (no JSON lines at all) —
  # otherwise raw meta-JSON would leak into the peer transcript (review 24.07).
  if [ "$PARSE_RC" -ne 10 ] && [ -z "$KIMI_OUTPUT" ] && [ -n "$KIMI_RAW" ]; then
    KIMI_OUTPUT=$(printf '%s\n' "$KIMI_RAW" | grep -v "^To resume this session:")
  fi
else
  KIMI_OUTPUT=$(printf '%s\n' "$KIMI_RAW" | grep -v "^To resume this session:")
fi

# lockf and Kimi can both return EX_TEMPFAIL (75). Distinguish the child's
# connection failure by its captured stderr — the only source reliably scoped
# to this invocation. A shared-logfile mtime/tail heuristic was tried and
# dropped (peer-session 2026-08-04-08-wp7-f44-sandbox-review): concurrent Kimi
# calls on this machine can write a matching pattern into the same global
# ~/.kimi/logs/kimi.log within the same second, misattributing one
# invocation's OAuth-lock timeout to another's unrelated network failure.
if [ "$PERL_EXIT" -eq 75 ]; then
  if grep -qE 'APIConnectionError|Connection error|Network is unreachable|Operation not permitted' "$KIMI_STDERR" 2>/dev/null; then
    echo "ERROR: Kimi network connection failed. Check sandbox network access and the api.kimi.com/api.moonshot.cn allowlist." >&2
  else
    echo "ERROR: Kimi peer call failed (exit 75) — cause not determined (network denial vs OAuth refresh lock on $OAUTH_LOCK_DIR); child stderr had no clear signal." >&2
  fi
  if [ -s "$KIMI_STDERR" ]; then
    echo "--- kimi stderr (tail) ---" >&2
    tail -20 "$KIMI_STDERR" >&2
  fi
  exit 1
fi

# Guard exit 77 = limit exceeded
if [ "$PERL_EXIT" -eq 77 ]; then
  echo "ERROR: Kimi session stopped by token guard (limit ${KIMI_MAX_TOKENS:-800000} exceeded)." >&2
  echo "  Tip: reduce --add-dir size, split task, or raise KIMI_MAX_TOKENS." >&2
  exit 1
fi

# Timeout guard
if [ "$PERL_EXIT" -eq 142 ]; then
  echo "ERROR: Kimi peer call timed out after 5 minutes (SIGALRM)" >&2
  echo "KIMI_TIMEOUT: peer call exceeded 5min limit — check for Unicode issues or network problems" >&2
  exit 1
fi

# Empty output guard — writer-сторона должна отличать "Kimi не ответил" от "Kimi ответил пусто"
if [ -z "$KIMI_OUTPUT" ]; then
  echo "ERROR: kimi returned empty output (network/auth/quota?)" >&2
  if [ -s "$KIMI_STDERR" ]; then
    echo "--- kimi stderr (tail) ---" >&2
    tail -5 "$KIMI_STDERR" >&2
  fi
  exit 1
fi

# === Hindsight L2 retain — writer-only per-turn (opt-in via env) ===
# Skipped silently if hindsight_trigger.py is not present (template installs without it).
HINDSIGHT_SCRIPT="$SCRIPT_DIR/hindsight_trigger.py"
if [ "${IWE_HINDSIGHT_RETAIN:-}" = "1" ] && [ -n "$KIMI_OUTPUT" ] && [ -f "$HINDSIGHT_SCRIPT" ]; then
  {
    echo "{\"action\":\"retain\",\"source\":\"kimi-peer\",\"text\":$(echo "$KIMI_OUTPUT" | head -c 4000 | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')}" \
    | python3 "$HINDSIGHT_SCRIPT" 2>/dev/null || true
  } &
fi

# === WP-454 Ф3: write to agent-sessions journal (best-effort, non-blocking) ===
# Writes one entry per adapter call. Caller groups by session_id on read.
# Security: only timestamps and duration written — no content from KIMI_OUTPUT.
{
  _KIMI_END="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  _SID="$KIMI_SESSION_ID"
  _START="$_KIMI_SESSION_START_TIME"
  _CROSS="${PEER_SESSION_ID:-}"
  mkdir -p "$HOME/.iwe"
  python3 - "$_SID" "$_START" "$_KIMI_END" "$_CROSS" <<'PYEOF'
import json, sys
from datetime import datetime, timezone

sid, start_s, end_s, cross = sys.argv[1:5]
fmt = lambda s: datetime.fromisoformat(s.replace("Z", "+00:00"))
try:
    start_dt, end_dt = fmt(start_s), fmt(end_s)
    agent_h = round((end_dt - start_dt).total_seconds() / 3600, 4)
except ValueError:
    agent_h = 0.0

rec = {
    "agent": "kimi",
    "session_id": sid,
    "date": start_s[:10],
    "start_time": start_s,
    "end_time": end_s,
    "agent_active_h": agent_h,
    "human_active_h": 0.0,
}
if cross:
    rec["cross_agent_session_id"] = cross

path = __import__("os").path.expanduser("~/.iwe/agent-sessions.jsonl")
with open(path, "a", encoding="utf-8") as f:
    f.write(json.dumps(rec, ensure_ascii=False) + "\n")
PYEOF
} 2>/dev/null &

# cleanup_peer() через trap переведёт статус в idle и удалит lock
echo "$KIMI_OUTPUT"
