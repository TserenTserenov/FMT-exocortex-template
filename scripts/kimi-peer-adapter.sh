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
#   IWE_PEER_INLINE       — legacy compatibility switch; text-only mode always inlines
#                           filtered context and never exposes --add-dir to Kimi
#   IWE_PEER_HEARTBEAT_SECONDS — peer watchdog heartbeat interval (default: 120)
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
#   6 — auth failure (§0в.1, WP-516 Ф5); до 12.08.2026 код 6 означал «WP Gate блок
#       отсутствует в peer-prompt.md» — теперь этот случай возвращает 1
#   77 — session stopped by token guard (limit exceeded)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/peer-adapter-common.sh
# This file runs without `set -e` (see below), so a missing/unreadable lib
# would otherwise fall through silently and fail tens of seconds later on an
# undefined function with a confusing, unrelated-looking error (cold review,
# WP-524 peer-session 2026-08-16-01) — check explicitly instead.
if ! source "$SCRIPT_DIR/lib/peer-adapter-common.sh"; then
  echo "ERROR: cannot load $SCRIPT_DIR/lib/peer-adapter-common.sh" >&2
  exit 1
fi

# Codex's Linux sandbox disables network for non-escalated commands; the Kimi
# CLI cannot reach its API from there (WP-524, verified live 15.08 — the run
# died even earlier, on the read-only semaphore path).  Fail fast, same as
# claude-peer-adapter.sh.
peer_adapter_check_sandbox_network "Kimi CLI" 1

# Declared before cleanup_peer's trap is armed (below) so `set -u` can't fault
# on an unset read if the script exits early, before the lock is ever attempted.
OAUTH_LOCK_DIR="${IWE_PEER_LOCK_DIR:-/tmp/kimi-peer-locks}/kimi-oauth-refresh.lockdir"
OAUTH_LOCK_HELD=false

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
# WP-524 (Codex review): resolve to an absolute path — the disposable-workdir
# `cd` further down (v2 text-only invocation) would otherwise break a relative
# KIMI_BIN override.
case "$KIMI_BIN" in
  /*) ;;
  *) KIMI_BIN="$(cd "$(dirname "$KIMI_BIN")" && pwd)/$(basename "$KIMI_BIN")" ;;
esac

ADD_DIRS=()
MODEL_ARG=()

# WP-516 Ф5: межвендорский whitelist (§0в.1) = {-p, --model, --add-dir}.
# Неизвестный флаг — явная ошибка, не молчаливый игнор: иначе запрошенный
# режим (напр. безопасности) может не примениться незаметно для вызывающего.
# --permission-mode исключён из whitelist: способен ослабить read-only
# гарантию sandbox; claude-адаптер отклоняет его всегда (exit 64).
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
      echo "ERROR: unknown flag '$1'. Known: -p, --model, --add-dir" >&2
      exit 1
      ;;
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
      # WP-516 Ф5 (§0в.1): код 6 зарезервирован под auth failure — WP-Gate
      # возвращает общий код 1 (ранее 6, конфликтовало с каноническим контрактом).
      exit 1
    fi
  fi
done

# === Фильтрация --add-dir через .agentigore + PII sanity-check ===

FILTERED_DIRS=()
TMP_ROOT=$(mktemp -d)

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
# Kimi peer calls are text-only by contract: the model receives a filtered text
# projection, never a directory it can inspect.  This also avoids the CLI's
# expensive workspace indexing.  IWE_PEER_INLINE remains accepted only for old
# callers; it can no longer disable the safe default.
if [ ${#FILTERED_DIRS[@]} -ge 2 ]; then
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
case "$KIMI_SESSION_ID" in
  [A-Za-z0-9]* )
    if ! [[ "$KIMI_SESSION_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; then
      KIMI_SESSION_ID="kimi-peer-ppid-${PPID:-$$}"
    fi
    ;;
  *) KIMI_SESSION_ID="kimi-peer-ppid-${PPID:-$$}" ;;
esac
IWE_PEER_HEARTBEAT_SECONDS="${IWE_PEER_HEARTBEAT_SECONDS:-120}"
case "$IWE_PEER_HEARTBEAT_SECONDS" in
  ''|*[!0-9]*|0)
    echo "ERROR: IWE_PEER_HEARTBEAT_SECONDS must be a positive integer." >&2
    rm -rf "$TMP_ROOT"
    exit 1
    ;;
esac
_KIMI_SESSION_START_TIME="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# === Kernel-held exact lock for one peer-session id ===
# The old check-then-overwrite pidfile let concurrent adapters both become
# owners and let one cleanup unlink the other's lock.  A tiny Python helper
# holds `flock(2)` for the adapter lifetime; owner death reparents the helper,
# which exits and lets the kernel release the lock without stale cleanup.
LOCK_DIR="${IWE_PEER_LOCK_DIR:-/tmp/kimi-peer-locks}"
LOCK_FILE="$LOCK_DIR/${KIMI_SESSION_ID}.pid"
SESSION_LOCK_READY="$TMP_ROOT/session-lock.ready"
SESSION_LOCK_HELPER_PID=""
SESSION_LOCK_HELD=false
OUR_PID="$$"

release_session_lock() {
  [ "$SESSION_LOCK_HELD" = true ] || return 0
  if jobs -pr | grep -qx "$SESSION_LOCK_HELPER_PID"; then
    kill "$SESSION_LOCK_HELPER_PID" 2>/dev/null || true
  fi
  wait "$SESSION_LOCK_HELPER_PID" 2>/dev/null || true
  SESSION_LOCK_HELD=false
}

acquire_session_lock() {
  local _wait status helper_rc=1
  mkdir -p "$LOCK_DIR" || return 1
  python3 - "$LOCK_DIR" "$LOCK_FILE" "$SESSION_LOCK_READY" "$OUR_PID" <<'PY' &
import errno
import fcntl
import os
import signal
import stat
import sys
import time

directory, path, ready, owner_pid_text = sys.argv[1:]
owner_pid = int(owner_pid_text)


def publish_status(value):
    tmp = f"{ready}.{os.getpid()}"
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    flags |= getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
    out = os.open(tmp, flags, 0o600)
    try:
        os.write(out, (value + "\n").encode("utf-8", "replace"))
        os.fsync(out)
    finally:
        os.close(out)
    os.replace(tmp, ready)


def process_alive(pid):
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


try:
    os.makedirs(directory, mode=0o700, exist_ok=True)
    directory_stat = os.lstat(directory)
    if not stat.S_ISDIR(directory_stat.st_mode) or directory_stat.st_uid != os.getuid():
        raise RuntimeError("unsafe peer lock directory")
    os.chmod(directory, 0o700)

    flags = os.O_RDWR | os.O_CREAT
    flags |= getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
    fd = os.open(path, flags, 0o600)
    value = os.fstat(fd)
    current = os.lstat(path)
    if (not stat.S_ISREG(value.st_mode)
            or value.st_uid != os.getuid()
            or value.st_nlink != 1
            or (value.st_dev, value.st_ino) != (current.st_dev, current.st_ino)):
        raise RuntimeError("unsafe peer lock file")
    os.fchmod(fd, 0o600)

    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as exc:
        if exc.errno in (errno.EACCES, errno.EAGAIN):
            publish_status("busy")
            raise SystemExit(5)
        raise

    # The previous owner may have unlinked this inode while we were between
    # open() and flock(). Never hold a private, unreachable lock while another
    # adapter owns the newly-created path.
    current = os.lstat(path)
    if (value.st_dev, value.st_ino) != (current.st_dev, current.st_ino):
        publish_status("retry-boundary")
        raise SystemExit(75)

    # Compatibility with an old live adapter that wrote this same pidfile but
    # did not yet use flock.  A dead legacy PID is stale data, not authority.
    os.lseek(fd, 0, os.SEEK_SET)
    previous = os.read(fd, 128).decode("ascii", "ignore").strip()
    if previous.isdigit() and int(previous) != owner_pid and process_alive(int(previous)):
        publish_status("busy-legacy")
        raise SystemExit(5)

    os.ftruncate(fd, 0)
    os.lseek(fd, 0, os.SEEK_SET)
    os.write(fd, f"{owner_pid}\n".encode("ascii"))
    os.fsync(fd)
    publish_status("acquired")

    def request_stop(_signum, _frame):
        nonlocal_stop[0] = True

    nonlocal_stop = [False]
    signal.signal(signal.SIGHUP, request_stop)
    signal.signal(signal.SIGINT, request_stop)
    signal.signal(signal.SIGTERM, request_stop)
    while not nonlocal_stop[0] and os.getppid() == owner_pid:
        try:
            linked = os.lstat(path)
            os.lseek(fd, 0, os.SEEK_SET)
            payload = os.read(fd, 128).decode("ascii", "ignore").strip()
            if ((linked.st_dev, linked.st_ino) != (value.st_dev, value.st_ino)
                    or payload != str(owner_pid)):
                os.kill(owner_pid, signal.SIGTERM)
                break
        except (FileNotFoundError, ProcessLookupError):
            break
        time.sleep(0.1)
except SystemExit:
    raise
except Exception as exc:
    try:
        publish_status(f"error:{type(exc).__name__}")
    except Exception:
        pass
    raise SystemExit(1)
finally:
    # Remove only the path that still names our locked inode and still carries
    # our owner PID. A replacement created by another process is preserved.
    try:
        if "fd" in locals():
            linked = os.lstat(path)
            value = os.fstat(fd)
            os.lseek(fd, 0, os.SEEK_SET)
            payload = os.read(fd, 128).decode("ascii", "ignore").strip()
            if ((linked.st_dev, linked.st_ino) == (value.st_dev, value.st_ino)
                    and payload == str(owner_pid)):
                os.unlink(path)
    except (FileNotFoundError, OSError):
        pass
PY
  SESSION_LOCK_HELPER_PID=$!

  for _wait in $(seq 1 100); do
    [ -s "$SESSION_LOCK_READY" ] && break
    kill -0 "$SESSION_LOCK_HELPER_PID" 2>/dev/null || break
    sleep 0.05
  done
  status="$(cat "$SESSION_LOCK_READY" 2>/dev/null || true)"
  case "$status" in
    acquired)
      SESSION_LOCK_HELD=true
      return 0
      ;;
    busy|busy-legacy)
      wait "$SESSION_LOCK_HELPER_PID" 2>/dev/null || helper_rc=$?
      echo "ABORT: peer session '$KIMI_SESSION_ID' already running." >&2
      [ "$helper_rc" -eq 5 ] && return 5
      return 1
      ;;
    *)
      if jobs -pr | grep -qx "$SESSION_LOCK_HELPER_PID"; then
        kill "$SESSION_LOCK_HELPER_PID" 2>/dev/null || true
      fi
      wait "$SESSION_LOCK_HELPER_PID" 2>/dev/null || helper_rc=$?
      echo "ERROR: cannot acquire exact peer-session lock for '$KIMI_SESSION_ID' (${status:-no status}, rc=$helper_rc)." >&2
      return 1
      ;;
  esac
}

acquire_session_lock
SESSION_LOCK_RC=$?
if [ "$SESSION_LOCK_RC" -ne 0 ]; then
  rm -rf "$TMP_ROOT"
  exit "$SESSION_LOCK_RC"
fi

# agent-status-report.sh — DRY path, fail-safe if missing (e.g. standalone test)
_IWE_ARS="$HOME/IWE/scripts/agent-status-report.sh"

# Peer calls need watchdog visibility, but they are not session-guard sessions.
# Keep their beacons outside the authoritative `sessions/*.open` namespace so
# a status aid can never become a malformed admission barrier.  The pid lock is
# acquired first: a rejected duplicate must not overwrite the live owner's
# beacon or leave a background heartbeat behind.
IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
PEER_HEARTBEAT_DIR="$IWE_ROOT/.iwe-runtime/peer-heartbeats"
PEER_HEARTBEAT_FILE="$PEER_HEARTBEAT_DIR/kimi-peer-${KIMI_SESSION_ID}.heartbeat"
PEER_HEARTBEAT_DEV=""
PEER_HEARTBEAT_INO=""
PEER_HB_PID=""
PEER_HEARTBEAT_READY="$TMP_ROOT/peer-heartbeat.ready"

create_peer_heartbeat() {
  local identity
  identity=$(python3 - "$PEER_HEARTBEAT_DIR" "$PEER_HEARTBEAT_FILE" "$KIMI_TASK" \
    "$OUR_PID" <<'PY'
import datetime
import os
import stat
import sys
import uuid

directory, path, task, owner_pid = sys.argv[1:]
os.makedirs(directory, mode=0o700, exist_ok=True)
directory_stat = os.lstat(directory)
if (not stat.S_ISDIR(directory_stat.st_mode)
        or directory_stat.st_uid != os.getuid()):
    raise SystemExit("unsafe peer heartbeat directory")
os.chmod(directory, 0o700)

task = task.replace("\r", " ").replace("\n", " ")
opened_at = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
flags |= getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
try:
    fd = os.open(path, flags, 0o600)
except FileExistsError:
    # The exact session lock proves there is no current owner. Preserve stale
    # evidence under a no-clobber name, then allocate a fresh inode. An orphan
    # loop holding the old dev:ino can no longer delete the new owner's beacon.
    old = os.lstat(path)
    if (not stat.S_ISREG(old.st_mode)
            or old.st_uid != os.getuid()
            or old.st_nlink != 1):
        raise RuntimeError("unsafe existing peer heartbeat file")
    stale = f"{path}.stale.{uuid.uuid4().hex}"
    os.rename(path, stale)
    fd = os.open(path, flags, 0o600)
try:
    value = os.fstat(fd)
    current = os.lstat(path)
    if (not stat.S_ISREG(value.st_mode)
            or value.st_uid != os.getuid()
            or value.st_nlink != 1
            or (value.st_dev, value.st_ino) != (current.st_dev, current.st_ino)):
        raise RuntimeError("unsafe peer heartbeat file")
    os.fchmod(fd, 0o600)
    os.ftruncate(fd, 0)
    payload = (
        f"opened_at: {opened_at}\n"
        "wp: WP-7\n"
        f"task: {task}\n"
        "agent: kimi-peer\n"
        f"owner_pid: {owner_pid}\n"
        f"heartbeat_at: {opened_at}\n"
    ).encode("utf-8")
    os.write(fd, payload)
    os.fsync(fd)
    print(f"{value.st_dev} {value.st_ino}")
finally:
    os.close(fd)
PY
  ) || return 1
  read -r PEER_HEARTBEAT_DEV PEER_HEARTBEAT_INO <<EOF
$identity
EOF
  [ -n "$PEER_HEARTBEAT_DEV" ] && [ -n "$PEER_HEARTBEAT_INO" ]
}

remove_peer_heartbeat() {
  python3 - "$PEER_HEARTBEAT_FILE" "$PEER_HEARTBEAT_DEV" "$PEER_HEARTBEAT_INO" <<'PY'
import os
import stat
import sys

path, expected_dev, expected_ino = sys.argv[1:]
try:
    value = os.lstat(path)
except FileNotFoundError:
    raise SystemExit(0)
if (not stat.S_ISREG(value.st_mode)
        or value.st_uid != os.getuid()
        or value.st_nlink != 1
        or (value.st_dev, value.st_ino) != (int(expected_dev), int(expected_ino))):
    raise SystemExit("peer heartbeat identity changed; preserving replacement")
os.unlink(path)
PY
}

start_peer_heartbeat() {
  python3 - "$PEER_HEARTBEAT_FILE" "$PEER_HEARTBEAT_DEV" "$PEER_HEARTBEAT_INO" \
    "$OUR_PID" "$IWE_PEER_HEARTBEAT_SECONDS" "$PEER_HEARTBEAT_READY" <<'PY' &
import datetime
import os
import signal
import stat
import sys
import threading
import time

path, expected_dev, expected_ino, owner_pid_text, interval_text, ready = sys.argv[1:]
expected_identity = (int(expected_dev), int(expected_ino))
owner_pid = int(owner_pid_text)
interval = int(interval_text)
stop = threading.Event()


def request_stop(_signum, _frame):
    stop.set()


for watched_signal in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
    signal.signal(watched_signal, request_stop)

flags = os.O_WRONLY | os.O_APPEND
flags |= getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
fd = os.open(path, flags)
try:
    value = os.fstat(fd)
    if (not stat.S_ISREG(value.st_mode)
            or value.st_uid != os.getuid()
            or value.st_nlink != 1
            or (value.st_dev, value.st_ino) != expected_identity):
        raise RuntimeError("peer heartbeat identity changed")

    ready_fd = os.open(
        ready,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL
        | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0),
        0o600,
    )
    try:
        os.write(ready_fd, b"ready\n")
        os.fsync(ready_fd)
    finally:
        os.close(ready_fd)

    next_write = 0.0
    while not stop.is_set() and os.getppid() == owner_pid:
        try:
            current = os.lstat(path)
        except FileNotFoundError:
            break
        if (current.st_dev, current.st_ino) != expected_identity:
            break
        now_monotonic = time.monotonic()
        if now_monotonic >= next_write:
            now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            os.write(fd, f"heartbeat_at: {now}\nheartbeat_pid: {owner_pid}\n".encode("ascii"))
            os.fsync(fd)
            next_write = now_monotonic + interval
        remaining = max(0.01, next_write - time.monotonic())
        stop.wait(min(1.0, remaining))
finally:
    os.close(fd)
    try:
        current = os.lstat(path)
        if (current.st_dev, current.st_ino) == expected_identity:
            os.unlink(path)
    except FileNotFoundError:
        pass
PY
  PEER_HB_PID=$!
  local _wait
  for _wait in $(seq 1 100); do
    [ -s "$PEER_HEARTBEAT_READY" ] && return 0
    jobs -pr | grep -qx "$PEER_HB_PID" || break
    sleep 0.05
  done
  if jobs -pr | grep -qx "$PEER_HB_PID"; then
    kill "$PEER_HB_PID" 2>/dev/null || true
  fi
  wait "$PEER_HB_PID" 2>/dev/null || true
  return 1
}

# Cleanup: удалить lock + перевести статус в idle при любом выходе
CLEANUP_PEER_STARTED=false
cleanup_peer() {
  local hb_reap_guard
  [ "$CLEANUP_PEER_STARTED" = false ] || return 0
  CLEANUP_PEER_STARTED=true
  [ -x "$_IWE_ARS" ] && bash "$_IWE_ARS" --session-id "$KIMI_SESSION_ID" kimi idle 2>/dev/null &
  # Stop and reap the direct heartbeat helper. It checks the adapter's exact
  # parent relationship itself, so SIGKILL of the adapter also makes it exit.
  # The bounded reap guard prevents an unexpected helper fault from hanging
  # this EXIT trap.
  if [ -n "$PEER_HB_PID" ]; then
    if jobs -pr | grep -qx "$PEER_HB_PID"; then
      kill "$PEER_HB_PID" 2>/dev/null || true
      ( sleep 5; kill -9 "$PEER_HB_PID" 2>/dev/null ) &
      hb_reap_guard=$!
    else
      hb_reap_guard=""
    fi
    wait "$PEER_HB_PID" 2>/dev/null || true
    [ -z "$hb_reap_guard" ] || kill "$hb_reap_guard" 2>/dev/null || true
  fi
  if [ -n "$PEER_HEARTBEAT_DEV" ] && [ -n "$PEER_HEARTBEAT_INO" ]; then
    remove_peer_heartbeat 2>/dev/null || true
  fi
  release_session_lock
  rm -rf "$TMP_ROOT"
  # Only release the OAuth-refresh lock if this invocation actually holds it —
  # an invocation that gave up waiting must never remove the winner's lock.
  # rm -rf, not rmdir: the lock dir holds a pid file (staleness check), not empty.
  [ "$OAUTH_LOCK_HELD" = true ] && rm -rf "$OAUTH_LOCK_DIR" 2>/dev/null
  return 0
}
trap cleanup_peer EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

if ! create_peer_heartbeat; then
  echo "ERROR: cannot create owned peer heartbeat in $PEER_HEARTBEAT_DIR" >&2
  exit 1
fi
if ! start_peer_heartbeat; then
  echo "ERROR: peer heartbeat helper failed to start." >&2
  exit 1
fi

[ -x "$_IWE_ARS" ] && bash "$_IWE_ARS" --session-id "$KIMI_SESSION_ID" kimi peer-session "$KIMI_TASK" 2>/dev/null &

# === Запуск Kimi with process-group deadline ===
# `perl alarm; exec` used to signal only the CLI launcher.  If Kimi had spawned
# an MCP/tool child, the child could survive and hold the writer indefinitely.
# The supervisor below starts the CLI in its own session and terminates that
# entire process group when the deadline expires (WP-516).
IWE_PEER_TIMEOUT_SECONDS="${IWE_PEER_TIMEOUT_SECONDS:-300}"
case "$IWE_PEER_TIMEOUT_SECONDS" in
  ''|*[!0-9]*|0)
    echo "ERROR: IWE_PEER_TIMEOUT_SECONDS must be a positive integer." >&2
    exit 64
    ;;
esac

# run_with_deadline() — see scripts/lib/peer-adapter-common.sh (sourced above).

GUARD_BIN="${SCRIPT_DIR}/kimi-session-guard.sh"
[ ! -x "$GUARD_BIN" ] && GUARD_BIN="${HOME}/.iwe/kimi-session-guard.sh"
GUARD_ARGS=()
if [ -x "$GUARD_BIN" ]; then
  GUARD_ARGS=("$GUARD_BIN" --max-tokens "${KIMI_MAX_TOKENS:-800000}" --)
fi

# === Kimi CLI style detect ===
# `--quiet` is no longer a reliable legacy marker: current kimi-code retains it
# as an alias while supporting the modern `--agent-file` API.  The latter is
# required for the no-tools profile below, so it is the capability probe.
# Legacy CLI: prompt via stdin, flags --quiet --yolo.  Modern CLI: `-p` plus
# `--agent-file`, stream-json, and no auto-approved tools.
KIMI_HELP_FILE="$TMP_ROOT/kimi-help.txt"
"$KIMI_BIN" --help > "$KIMI_HELP_FILE" 2>/dev/null || true
if grep -q -- '--agent-file' "$KIMI_HELP_FILE"; then
  KIMI_CLI_STYLE="prompt-arg"
else
  KIMI_CLI_STYLE="legacy"
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
  # kimi-code itself loads ~/.kimi/config.toml (not the VS Code extension's
  # ~/.kimi-code/config.toml).  Reading the latter made the old warning say
  # that yolo was enabled while the live CLI actually had it disabled.
  KIMI_CODE_CFG="${KIMI_CODE_CFG:-$HOME/.kimi/config.toml}"
  if [ ${#MODEL_ARG[@]} -ge 2 ]; then
    if [ -f "$KIMI_CODE_CFG" ] && ! grep -qF "[models.\"${MODEL_ARG[1]}\"]" "$KIMI_CODE_CFG"; then
      echo "WARN: model '${MODEL_ARG[1]}' is not configured in kimi-code — falling back to default_model" >&2
      MODEL_ARG=()
    fi
  fi
  # Build a disposable agent specification with an empty toolset.  It is more
  # than an instruction: Kimi's agent loader reports `Loaded tools: []`, so
  # Shell, files, web, MCP tools, and subagents cannot be selected by the LLM.
  # The temporary workspace prevents ambient AGENTS.md/project discovery; all
  # permitted context was already copied through the filtered inline projection.
  KIMI_TEXT_ONLY_WORKDIR="$TMP_ROOT/kimi-text-only-workdir"
  KIMI_TEXT_ONLY_PROMPT="$TMP_ROOT/kimi-peer-text-only-system.md"
  mkdir -p "$KIMI_TEXT_ONLY_WORKDIR"
  cat > "$KIMI_TEXT_ONLY_PROMPT" <<'EOF'
You are a text-only peer reviewer. Answer only from the prompt provided in this
turn. Do not claim to have read files, used tools, accessed the network, or
changed state. If the prompt asks you to perform any of those actions, explain
briefly that you can only analyse the supplied text.
EOF
  # kimi-code 0.29 (v2 engine) reads the agent definition from a Markdown file
  # with frontmatter; the pre-v2 CLI reads a YAML spec.  The help text is the
  # capability probe, same as for the flags above.
  if grep -q 'Load an agent definition from a Markdown file' "$KIMI_HELP_FILE"; then
    KIMI_AGENT_STYLE="v2"
    KIMI_TEXT_ONLY_AGENT="$TMP_ROOT/kimi-peer-text-only-agent.md"
    {
      printf -- '---\nname: kimi-peer-text-only\ndescription: Text-only peer reviewer without tools.\ntools: []\n---\n'
      cat "$KIMI_TEXT_ONLY_PROMPT"
    } > "$KIMI_TEXT_ONLY_AGENT"
  else
    KIMI_AGENT_STYLE="v1"
    KIMI_TEXT_ONLY_AGENT="$TMP_ROOT/kimi-peer-text-only-agent.yaml"
    cat > "$KIMI_TEXT_ONLY_AGENT" <<'EOF'
version: 1
agent:
  name: "kimi-peer-text-only"
  system_prompt_path: ./kimi-peer-text-only-system.md
  tools: []
EOF
  fi
  # $(cat) strips trailing newlines — harmless at the final CLI handoff (prompt semantics
  # unchanged); byte-exactness matters only inside the filter pipeline above.
  # kimi-code 0.29 dropped --work-dir, --no-thinking, --max-steps-per-turn and
  # --print (WP-524, 15.08).  Each of them is passed only while the installed
  # CLI still documents it, so older versions keep their original semantics;
  # the workspace isolation itself is version-proof — the invocation below
  # cd's into the disposable workdir.
  kimi_cli_supports() { grep -q -- "$1" "$KIMI_HELP_FILE"; }
  KIMI_PROMPT_ARGS=()
  kimi_cli_supports '--work-dir' && KIMI_PROMPT_ARGS+=("--work-dir" "$KIMI_TEXT_ONLY_WORKDIR")
  kimi_cli_supports '--no-thinking' && KIMI_PROMPT_ARGS+=("--no-thinking")
  kimi_cli_supports '--max-steps-per-turn' && KIMI_PROMPT_ARGS+=("--max-steps-per-turn" "1")
  KIMI_PROMPT_ARGS+=(
    "--agent-file" "$KIMI_TEXT_ONLY_AGENT"
    "-p" "$(cat "$PROMPT_FILE")"
    "--output-format" "stream-json"
  )
  kimi_cli_supports '--print' && KIMI_PROMPT_ARGS+=("--print")
else
  echo "ERROR: installed Kimi CLI lacks --agent-file; refusing an unsafe legacy peer invocation." >&2
  echo "  Upgrade Kimi CLI to a version that supports a no-tools agent profile." >&2
  exit 1
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

# Text-only mode always inlines the filtered context.  Passing --add-dir would
# re-expose a workspace even though the no-tools profile does not need it.
KIMI_DIR_ARGS=()

if [ "$KIMI_CLI_STYLE" = "prompt-arg" ]; then
  # kimi-code 0.29 gates --agent-file behind the v2 engine, enabled by this
  # env var.  Set it only for the v2 agent format (peer-session 2026-08-15-05,
  # Codex review): an experimental flag may change more than the gate, so a
  # pre-v2 CLI must not receive it.
  if [ "$KIMI_AGENT_STYLE" = "v2" ]; then
    export KIMI_CODE_EXPERIMENTAL_FLAG=1
  fi
  KIMI_RAW=$(cd "$KIMI_TEXT_ONLY_WORKDIR" && run_with_deadline "$IWE_PEER_TIMEOUT_SECONDS" \
    "${GUARD_ARGS[@]+"${GUARD_ARGS[@]}"}" "$KIMI_BIN" \
    "${KIMI_PROMPT_ARGS[@]}" \
    ${MODEL_ARG[@]+"${MODEL_ARG[@]}"} \
    ${KIMI_DIR_ARGS[@]+"${KIMI_DIR_ARGS[@]}"} \
    < /dev/null \
    2>"$KIMI_STDERR")
else
  KIMI_RAW=$(run_with_deadline "$IWE_PEER_TIMEOUT_SECONDS" \
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

adapter_diagnostic() {
  local cli_exit="$1"
  local stdout_bytes stderr_bytes
  stdout_bytes=$(printf '%s' "$KIMI_RAW" | wc -c | tr -d '[:space:]')
  stderr_bytes=$(wc -c < "$KIMI_STDERR" | tr -d '[:space:]')
  printf 'DIAGNOSTIC: vendor=kimi cli_exit=%s timeout_seconds=%s stdout_bytes=%s stderr_bytes=%s\n' \
    "$cli_exit" "$IWE_PEER_TIMEOUT_SECONDS" "$stdout_bytes" "$stderr_bytes" >&2
}

if [ "$KIMI_CLI_STYLE" = "prompt-arg" ]; then
  # stream-json: keep only assistant text; meta lines (resume hint) drop out naturally.
  # Exit 10 = input WAS JSON but held no assistant text (e.g. CLI retry loop died
  # mid-turn with only meta/tool events) — that is "no answer", not format drift.
  # Unparsable lines are counted and reported, never dropped in silence (WP-524
  # F6, peer-session 2026-09-05-28): the transport is NDJSON, so a corrupted
  # line costs a WHOLE assistant message, not a character — and a reply that
  # arrives short but well-formed is indistinguishable from a complete one.
  KIMI_OUTPUT=$(printf '%s\n' "$KIMI_RAW" | python3 -c '
import json, sys
parts = []
saw_json = False
corrupt = 0
noise = 0
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        evt = json.loads(line)
    except ValueError:
        # A line that starts with "{" was meant to be an NDJSON record, so it is
        # a lost message. Anything else is CLI noise (banners, node warnings) and
        # must not cry wolf, or the real warning stops being read.
        if line.startswith("{"):
            corrupt += 1
        else:
            noise += 1
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
if corrupt and text:
    # Own marker, not a bare "WARNING:" — the adapter already emits unrelated
    # WARNING lines (language check), and a caller grepping for those would cry
    # wolf on every reply that is mostly YAML.
    sys.stderr.write(
        "INTEGRITY-WARNING: %d stream-json record(s) failed to parse while the reply "
        "came back non-empty — the reply may be missing a whole message.\n" % corrupt
    )
elif corrupt or noise:
    sys.stderr.write("DIAGNOSTIC: corrupt_json_lines=%d noise_lines=%d\n" % (corrupt, noise))
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
  adapter_diagnostic "$PERL_EXIT"
  exit 1
fi

# Guard exit 77 = limit exceeded
if [ "$PERL_EXIT" -eq 77 ]; then
  echo "ERROR: Kimi session stopped by token guard (limit ${KIMI_MAX_TOKENS:-800000} exceeded)." >&2
  echo "  Tip: reduce --add-dir size, split task, or raise KIMI_MAX_TOKENS." >&2
  adapter_diagnostic "$PERL_EXIT"
  exit 1
fi

# Timeout guard
if [ "$PERL_EXIT" -eq 142 ]; then
  echo "ERROR: Kimi peer call timed out after ${IWE_PEER_TIMEOUT_SECONDS}s; its process group was terminated." >&2
  echo "KIMI_TIMEOUT: peer call exceeded configured deadline" >&2
  [ -s "$KIMI_STDERR" ] && tail -20 "$KIMI_STDERR" >&2
  adapter_diagnostic "$PERL_EXIT"
  exit 1
fi

if [ "$PERL_EXIT" -ne 0 ]; then
  echo "ERROR: Kimi peer call failed with exit code $PERL_EXIT." >&2
  [ -s "$KIMI_STDERR" ] && tail -20 "$KIMI_STDERR" >&2
  adapter_diagnostic "$PERL_EXIT"
  exit 1
fi

# Empty output guard — writer-сторона должна отличать "Kimi не ответил" от "Kimi ответил пусто"
if [ -z "$KIMI_OUTPUT" ]; then
  echo "ERROR: kimi returned empty output (network/auth/quota?)" >&2
  if [ -s "$KIMI_STDERR" ]; then
    echo "--- kimi stderr (tail) ---" >&2
    tail -5 "$KIMI_STDERR" >&2
  fi
  adapter_diagnostic "$PERL_EXIT"
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

# WP-516 Ф5 (§0в.1): stdout обязан начинаться с frontmatter; ответ без
# frontmatter = нарушение формата → exit 1 с диагностикой.
# Проверка — для peer-реплик turn-loop. Служебные вызовы писателя
# (review/verify/synth), чей вывод — НЕ peer-реплика, отключают её
# через IWE_PEER_PLAIN=1 (слой IWE-интеграции, §0в.1).
if [ "${IWE_PEER_PLAIN:-0}" != "1" ]; then
  peer_adapter_check_frontmatter "$KIMI_OUTPUT"
  peer_adapter_check_language "$KIMI_OUTPUT"
fi

# cleanup_peer() через trap переведёт статус в idle и удалит lock
echo "$KIMI_OUTPUT"
