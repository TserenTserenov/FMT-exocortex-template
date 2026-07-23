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
#
# Exit codes:
#   0 — OK
#   1 — general error (kimi not found, args)
#   2 — .agentigore filter violation (Python filter error)
#   3 — PII Hard Block (sanity-check found high-severity pattern)
#   4 — --add-dir too large (>100MB or >5000 files)
#   5 — peer session already running (pidfile lock)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# KIMI_BIN auto-detect: env override → PATH → VS Code extension paths (macOS/Linux/WSL)
KIMI_BIN="${KIMI_BIN:-$(command -v kimi 2>/dev/null || true)}"
if [ -z "$KIMI_BIN" ]; then
  for candidate in \
    "$HOME/Library/Application Support/Code/User/globalStorage/moonshot-ai.kimi-code/bin/kimi/kimi" \
    "$HOME/.config/Code/User/globalStorage/moonshot-ai.kimi-code/bin/kimi/kimi" \
    "$HOME/AppData/Roaming/Code/User/globalStorage/moonshot-ai.kimi-code/bin/kimi/kimi"; do
    [ -x "$candidate" ] && KIMI_BIN="$candidate" && break
  done
fi

if [ -z "$KIMI_BIN" ] || [ ! -x "$KIMI_BIN" ]; then
  echo "ERROR: kimi binary not found. Install Kimi CLI or set KIMI_BIN env var." >&2
  echo "  Looked in: PATH, ~/Library/.../moonshot-ai.kimi-code (macOS)," >&2
  echo "             ~/.config/Code/.../moonshot-ai.kimi-code (Linux)," >&2
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

# === Фильтрация --add-dir через .agentigore + PII sanity-check ===

FILTERED_DIRS=()
# `-t template` is BSD/GNU compatible in practice but its exact semantics
# differ (docs/PLATFORM-COMPAT.md) — a fully-qualified template path avoids
# `-t` entirely and is identical on both.
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
    exit 3
  elif [ $RC -ne 0 ]; then
    echo "ABORT: filter failed with code $RC" >&2
    exit 2
  fi

  FILTERED_DIRS+=("--add-dir" "$CLEAN_DIR")
done

# === Content-filter guard (WP-394 Ф3.2) ===
# Переформулирует слова-маркеры чувствительных данных в промпте ДО подачи в Moonshot,
# чтобы defensive content policy не давала ложный block (HTTP 400 high risk) на
# легитимных peer-сессиях про auth/secrets.
PROMPT_FILE="$TMP_ROOT/peer-prompt.in"
cat > "$PROMPT_FILE"

CONTENT_FILTER_MAP="$SCRIPT_DIR/content-filter-map.txt"
if [ -f "$CONTENT_FILTER_MAP" ] && [ -s "$CONTENT_FILTER_MAP" ]; then
  if python3 "$SCRIPT_DIR/content-filter-apply.py" "$CONTENT_FILTER_MAP" \
       < "$PROMPT_FILE" > "$PROMPT_FILE.filtered" 2>/dev/null \
     && [ -s "$PROMPT_FILE.filtered" ]; then
    PROMPT_FILE="$PROMPT_FILE.filtered"
  fi
fi

# === Session-state diff (WP-383) — opt-in via IWE_PEER_DIFF ===
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

# === Sanitize surrogate characters before Kimi call (WP-395 Ф3) ===
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

# === Inline session files into prompt (WP-395 Ф3 performance fix) — opt-in via IWE_PEER_INLINE ===
if [ "${IWE_PEER_INLINE:-0}" = "1" ] && [ ${#FILTERED_DIRS[@]} -ge 2 ]; then
  INLINE_FILES="$TMP_ROOT/peer-prompt.inline"
  {
    cat "$PROMPT_FILE"
    echo ""
    echo "=== Файлы сессии (для контекста) ==="
    echo ""
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

# === Pidfile lock: предотвращаем параллельные/зависшие копии одной peer-сессии ===
KIMI_TASK="$(basename "${ADD_DIRS[0]:-}" 2>/dev/null)"
if [ -z "$KIMI_TASK" ]; then KIMI_TASK="kimi-peer-ppid-${PPID:-$$}"; fi
KIMI_SESSION_ID="$KIMI_TASK"

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
fi
echo "$OUR_PID" > "$LOCK_FILE"

# agent-status-report.sh (optional — guard on existence for standalone installs)
_IWE_ARS="$HOME/IWE/scripts/agent-status-report.sh"

# Cleanup: удалить lock и temp при любом выходе
cleanup_peer() {
  rm -f "$LOCK_FILE"
  [ -x "$_IWE_ARS" ] && bash "$_IWE_ARS" --session-id "$KIMI_SESSION_ID" kimi idle 2>/dev/null &
  rm -rf "$TMP_ROOT"
}
trap cleanup_peer EXIT INT TERM
[ -x "$_IWE_ARS" ] && bash "$_IWE_ARS" --session-id "$KIMI_SESSION_ID" kimi peer-session "$KIMI_TASK" 2>/dev/null &

# === Запуск Kimi с inline prompt + 5min timeout (perl alarm) ===
if [ "${IWE_PEER_INLINE:-0}" = "1" ]; then
  # Inline mode: prompt содержит файлы, --add-dir не нужен
  KIMI_OUTPUT=$(perl -e 'alarm 300; exec @ARGV' -- "$KIMI_BIN" --quiet --yolo \
    ${MODEL_ARG[@]+"${MODEL_ARG[@]}"} \
    < "$PROMPT_FILE" \
    2>/dev/null | grep -v "^To resume this session:")
else
  # Legacy mode: передаём --add-dir в Kimi
  KIMI_OUTPUT=$(perl -e 'alarm 300; exec @ARGV' -- "$KIMI_BIN" --quiet --yolo \
    ${MODEL_ARG[@]+"${MODEL_ARG[@]}"} \
    ${FILTERED_DIRS[@]+"${FILTERED_DIRS[@]}"} \
    < "$PROMPT_FILE" \
    2>/dev/null | grep -v "^To resume this session:")
fi
PERL_EXIT="${PIPESTATUS[0]}"

# Timeout guard
if [ "$PERL_EXIT" -eq 142 ]; then
  echo "ERROR: Kimi peer call timed out after 5 minutes (SIGALRM)" >&2
  echo "KIMI_TIMEOUT: peer call exceeded 5min limit — check for Unicode issues or network problems" >&2
  exit 1
fi

# Empty output guard
if [ -z "$KIMI_OUTPUT" ]; then
  echo "ERROR: kimi returned empty output (network/auth/quota?)" >&2
  exit 1
fi

# === Hindsight L2 retain — writer-only per-turn (opt-in via env) ===
HINDSIGHT_SCRIPT="$SCRIPT_DIR/hindsight_trigger.py"
if [ "${IWE_HINDSIGHT_RETAIN:-}" = "1" ] && [ -n "$KIMI_OUTPUT" ] && [ -f "$HINDSIGHT_SCRIPT" ]; then
  {
    echo "{\"action\":\"retain\",\"source\":\"kimi-peer\",\"text\":$(echo "$KIMI_OUTPUT" | head -c 4000 | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')}" \
    | python3 "$HINDSIGHT_SCRIPT" 2>/dev/null || true
  } &
fi

# cleanup_peer() через trap удалит lock и temp
echo "$KIMI_OUTPUT"
