#!/bin/bash
# kimi-peer-adapter.sh v4 — адаптер Kimi для peer-conversation.sh с PII-фильтрацией
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
#   IWE_PEER_OAUTH_LOCK_TIMEOUT_SECONDS — global OAuth-lock wait (default: 90)
#   IWE_PEER_WP           — heartbeat classification: WP-N or NO-WP (default: derive)
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

# Declared before cleanup_peer's trap is armed (below) so `set -u` can't fault
# on an unset read if the script exits early, before the lock is ever attempted.
OAUTH_LOCK_DIR="${IWE_PEER_LOCK_DIR:-/tmp/kimi-peer-locks}/kimi-oauth-refresh.lockdir"

# A pre-v4 scheduler can pause after deciding that the historical mkdir lock
# is stale and resume its unconditional `rm -rf` after a new implementation
# has published at the same path. No new writer can close that ABA race. The
# one-time cutover is therefore deliberately explicit: the operator first
# disables every legacy launcher and drains every already-running legacy
# contender, then asserts that fact here. The resulting fence is immutable;
# rollback binaries see PID -1 as permanently live and fail closed.
if [ "${1:-}" = "--cutover-oauth-lineage-v4" ]; then
  if [ "$#" -ne 1 ] || [ "${IWE_OAUTH_CUTOVER_QUIESCED:-}" != "1" ]; then
    echo "ERROR: OAuth v4 cutover requires no other arguments and IWE_OAUTH_CUTOVER_QUIESCED=1 after a proven legacy drain." >&2
    exit 1
  fi
  if ! kill -0 "-1" 2>/dev/null; then
    echo "ERROR: this shell does not preserve the deployed legacy 'kill -0 -1' fence contract." >&2
    exit 1
  fi
  python3 - "${IWE_PEER_LOCK_DIR:-/tmp/kimi-peer-locks}" "$OAUTH_LOCK_DIR" <<'PY'
import errno
import fcntl
import os
import secrets
import stat
import sys

root_directory, fence_path = sys.argv[1:]
lease_path = os.path.join(root_directory, "kimi-oauth-refresh.lease")
lineage_path = os.path.join(root_directory, "kimi-oauth-refresh.lineage-v4")
prefix = "kimi-oauth-refresh.fence-v4."
NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)
CLOEXEC = getattr(os, "O_CLOEXEC", 0)


def same_inode(left, right):
    return (left.st_dev, left.st_ino) == (right.st_dev, right.st_ino)


def path_names_inode(path, value):
    return same_inode(os.lstat(path), value)


def open_owned_regular(path, create=False):
    flags = os.O_RDWR | NOFOLLOW | CLOEXEC
    if create:
        flags |= os.O_CREAT
    descriptor = os.open(path, flags, 0o600)
    value = os.fstat(descriptor)
    if (not stat.S_ISREG(value.st_mode)
            or value.st_uid != os.getuid()
            or value.st_nlink != 1
            or not path_names_inode(path, value)):
        os.close(descriptor)
        raise RuntimeError(f"unsafe OAuth file: {path}")
    os.fchmod(descriptor, 0o600)
    return descriptor, value


def publish_owned_regular(path, payload):
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | NOFOLLOW | CLOEXEC
    descriptor = os.open(path, flags, 0o600)
    try:
        os.write(descriptor, (payload + "\n").encode("ascii"))
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def read_ascii(descriptor):
    return os.pread(descriptor, 256, 0).decode("ascii", "strict").strip()


def valid_nonce(value):
    return (len(value) == 32
            and all(character in "0123456789abcdef" for character in value))


def fsync_directory(path):
    descriptor = os.open(path, os.O_RDONLY | CLOEXEC)
    try:
        value = os.fstat(descriptor)
        if not stat.S_ISDIR(value.st_mode):
            raise RuntimeError(f"not a directory: {path}")
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def validate_fence(lease_value):
    link_value = os.lstat(fence_path)
    if not stat.S_ISLNK(link_value.st_mode) or link_value.st_uid != os.getuid():
        return False
    target = os.readlink(fence_path)
    if not target.startswith(prefix) or "/" in target:
        return False
    nonce = target[len(prefix):]
    if not valid_nonce(nonce):
        return False
    private_path = os.path.join(root_directory, target)
    private_value = os.lstat(private_path)
    if (not stat.S_ISDIR(private_value.st_mode)
            or private_value.st_uid != os.getuid()
            or stat.S_IMODE(private_value.st_mode) != 0o700
            or sorted(os.listdir(private_path)) != ["owner", "pid"]):
        return False
    pid_path = os.path.join(private_path, "pid")
    owner_path = os.path.join(private_path, "owner")
    pid_fd, pid_value = open_owned_regular(pid_path)
    owner_fd, owner_value = open_owned_regular(owner_path)
    try:
        expected_owner = (
            f"iwe-oauth-fence-v4 {lease_value.st_dev} "
            f"{lease_value.st_ino} {nonce}"
        )
        return (
            read_ascii(pid_fd) == "-1"
            and read_ascii(owner_fd) == expected_owner
            and path_names_inode(fence_path, link_value)
            and os.readlink(fence_path) == target
            and path_names_inode(private_path, private_value)
            and path_names_inode(pid_path, pid_value)
            and path_names_inode(owner_path, owner_value)
        )
    finally:
        os.close(owner_fd)
        os.close(pid_fd)


os.makedirs(root_directory, mode=0o700, exist_ok=True)
root_value = os.lstat(root_directory)
if not stat.S_ISDIR(root_value.st_mode) or root_value.st_uid != os.getuid():
    raise SystemExit("ERROR: unsafe OAuth lock root")
os.chmod(root_directory, 0o700)
lease_fd, lease_value = open_owned_regular(lease_path, create=True)
try:
    try:
        fcntl.flock(lease_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as exc:
        if exc.errno in (errno.EACCES, errno.EAGAIN):
            raise SystemExit("ERROR: OAuth lineage is active; cutover refused")
        raise
    if not path_names_inode(lease_path, lease_value):
        raise SystemExit("ERROR: OAuth lease changed during cutover")
    if os.path.lexists(fence_path):
        if validate_fence(lease_value) and not os.path.lexists(lineage_path):
            print("OAuth lineage v4 cutover already complete")
            raise SystemExit(0)
        raise SystemExit("ERROR: existing OAuth bridge is not the exact v4 fence")
    if os.path.lexists(lineage_path):
        raise SystemExit("ERROR: existing OAuth v4 lineage blocks cutover")

    nonce = secrets.token_hex(16)
    target = f"{prefix}{nonce}"
    private_path = os.path.join(root_directory, target)
    pid_path = os.path.join(private_path, "pid")
    owner_path = os.path.join(private_path, "owner")
    os.mkdir(private_path, 0o700)
    published = False
    try:
        publish_owned_regular(pid_path, "-1")
        publish_owned_regular(
            owner_path,
            f"iwe-oauth-fence-v4 {lease_value.st_dev} "
            f"{lease_value.st_ino} {nonce}",
        )
        fsync_directory(private_path)
        os.symlink(target, fence_path)
        published = True
        fsync_directory(root_directory)
        if not validate_fence(lease_value):
            raise RuntimeError("published OAuth v4 fence failed validation")
    except Exception:
        if not published:
            for path in (owner_path, pid_path):
                try:
                    os.unlink(path)
                except FileNotFoundError:
                    pass
            try:
                os.rmdir(private_path)
            except FileNotFoundError:
                pass
        raise
    print("OAuth lineage v4 cutover complete")
finally:
    os.close(lease_fd)
PY
  exit $?
fi

# Codex's Linux sandbox disables network for non-escalated commands; the Kimi
# CLI cannot reach its API from there (WP-524, verified live 15.08 — the run
# died even earlier, on the read-only semaphore path).  Fail fast, same as
# claude-peer-adapter.sh.
peer_adapter_check_sandbox_network "Kimi CLI" 1

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
# Machine identity remains the full session id; this field is only an
# operator-facing classification.  Prefer the explicit caller contract, then
# derive a WP marker from the human session label, otherwise say NO-WP instead
# of attributing every peer call to WP-7.
KIMI_WP="${IWE_PEER_WP:-}"
if [ -z "$KIMI_WP" ]; then
  if [[ "-$KIMI_TASK-" =~ [-_.][Ww][Pp]-?([1-9][0-9]*)([-_.]|$) ]]; then
    KIMI_WP="WP-${BASH_REMATCH[1]}"
  else
    KIMI_WP="NO-WP"
  fi
fi
if ! [[ "$KIMI_WP" =~ ^(WP-[1-9][0-9]*|NO-WP)$ ]]; then
  echo "ERROR: IWE_PEER_WP must be WP-N or NO-WP." >&2
  rm -rf "$TMP_ROOT"
  exit 1
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
IWE_PEER_OAUTH_LOCK_TIMEOUT_SECONDS="${IWE_PEER_OAUTH_LOCK_TIMEOUT_SECONDS:-90}"
case "$IWE_PEER_OAUTH_LOCK_TIMEOUT_SECONDS" in
  ''|*[!0-9]*|0)
    echo "ERROR: IWE_PEER_OAUTH_LOCK_TIMEOUT_SECONDS must be a positive integer." >&2
    rm -rf "$TMP_ROOT"
    exit 1
    ;;
esac
_KIMI_SESSION_START_TIME="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# === Kernel-held exact lock + process-lineage lease for one peer-session id ===
# Authority is flock(2) on an owned, stable per-id regular `lease` file, not
# on mutable owner.pid metadata. Removing owner.pid cannot release that flock. A
# private FIFO writer (fixed fd 9 for macOS Bash 3.2) is inherited only by the
# command-substitution/supervisor/vendor lineage; background helpers and
# capability probes close it. A private controller process group contains the
# Python helper and its forked sentinel; both share every open-file authority.
# An explicit, immutable v4 fence keeps every deployed mkdir-based launcher
# fail-closed. New writers use a separate atomically-published runtime lineage;
# its negative holder moves from the controller group to the gated vendor
# group. Either owner surviving a single fault drains the vendor; even loss of
# both owners leaves new writers blocked by the live vendor group until FIFO
# lineage is gone.
LOCK_DIR="${IWE_PEER_LOCK_DIR:-/tmp/kimi-peer-locks}"
SESSION_LOCK_DIR="$LOCK_DIR/${KIMI_SESSION_ID}.lock"
LOCK_FILE="$SESSION_LOCK_DIR/owner.pid"
LEGACY_LOCK_FILE="$LOCK_DIR/${KIMI_SESSION_ID}.pid"
SESSION_LOCK_READY="$TMP_ROOT/session-lock.ready"
SESSION_LOCK_ARMED="$TMP_ROOT/session-lock.armed"
SESSION_LOCK_FAILURE="$TMP_ROOT/session-lock.failed"
SESSION_LIFETIME_FIFO="$TMP_ROOT/session-lifetime.fifo"
SESSION_VENDOR_PGID_FILE="$TMP_ROOT/session-vendor.pgid"
SESSION_VENDOR_ARMED="$TMP_ROOT/session-vendor.armed"
SESSION_VENDOR_EXEC_GATE="$TMP_ROOT/session-vendor.exec-gate"
SESSION_OAUTH_REQUEST="$TMP_ROOT/oauth-lock.request"
SESSION_OAUTH_READY="$TMP_ROOT/oauth-lock.ready"
SESSION_LOCK_HELPER_PID=""
SESSION_LOCK_HELD=false
SESSION_LIFETIME_FD_OPEN=false
OUR_PID="$$"

if ! mkfifo "$SESSION_LIFETIME_FIFO" || ! chmod 600 "$SESSION_LIFETIME_FIFO"; then
  echo "ERROR: cannot create private peer-session lifetime FIFO." >&2
  rm -rf "$TMP_ROOT"
  exit 1
fi
if ! exec 9<> "$SESSION_LIFETIME_FIFO"; then
  echo "ERROR: cannot open private peer-session lifetime FIFO." >&2
  rm -rf "$TMP_ROOT"
  exit 1
fi
SESSION_LIFETIME_FD_OPEN=true

release_session_lock() {
  local helper_reap_guard=""
  [ "$SESSION_LOCK_HELD" = true ] || return 0
  if [ "$SESSION_LIFETIME_FD_OPEN" = true ]; then
    exec 9>&-
    SESSION_LIFETIME_FD_OPEN=false
  fi
  # EOF is the normal release signal. Give the helper a bounded chance to
  # observe it and release both kernel locks without recording a false fault.
  if jobs -pr | grep -qx "$SESSION_LOCK_HELPER_PID"; then
    ( exec 9>&-; sleep 5; kill "$SESSION_LOCK_HELPER_PID" 2>/dev/null ) &
    helper_reap_guard=$!
  fi
  wait "$SESSION_LOCK_HELPER_PID" 2>/dev/null || true
  [ -z "$helper_reap_guard" ] || kill "$helper_reap_guard" 2>/dev/null || true
  SESSION_LOCK_HELD=false
}

acquire_session_lock() {
  local _wait status helper_rc=1 attempt=1 max_attempts=3
  mkdir -p "$LOCK_DIR" || return 1
  while [ "$attempt" -le "$max_attempts" ]; do
    rm -f "$SESSION_LOCK_READY"
    rm -f "$SESSION_LOCK_ARMED"
    helper_rc=1
    python3 - "$LOCK_DIR" "$SESSION_LOCK_DIR" "$LOCK_FILE" \
      "$LEGACY_LOCK_FILE" "$SESSION_LOCK_READY" "$SESSION_LOCK_ARMED" \
      "$SESSION_LOCK_FAILURE" "$SESSION_LIFETIME_FIFO" \
      "$SESSION_VENDOR_PGID_FILE" "$SESSION_VENDOR_ARMED" \
      "$SESSION_VENDOR_EXEC_GATE" "$OAUTH_LOCK_DIR" \
      "$SESSION_OAUTH_REQUEST" "$SESSION_OAUTH_READY" \
      "$IWE_PEER_OAUTH_LOCK_TIMEOUT_SECONDS" "$OUR_PID" 9>&- <<'PY' &
import errno
import fcntl
import json
import os
import secrets
import signal
import stat
import sys
import time

(
    root_directory,
    session_directory,
    owner_path,
    legacy_path,
    ready,
    armed,
    failure,
    lifetime_fifo,
    pgid_path,
    vendor_armed_path,
    vendor_exec_gate,
    oauth_lock_directory,
    oauth_request,
    oauth_ready,
    oauth_timeout_text,
    owner_pid_text,
) = sys.argv[1:]
owner_pid = int(owner_pid_text)
oauth_timeout = int(oauth_timeout_text)
nonce = secrets.token_hex(16)
controller_pgid = None
lock_acquired = False
lease_armed = False
stop_requested = False
oauth_wait_started = None
oauth_lease_path = os.path.join(root_directory, "kimi-oauth-refresh.lease")
oauth_lease_fd = None
oauth_lease_value = None
oauth_fence_name = None
oauth_fence_directory = None
oauth_fence_link_value = None
oauth_fence_directory_value = None
oauth_fence_pid_fd = None
oauth_fence_pid_value = None
oauth_fence_owner_fd = None
oauth_fence_owner_value = None
oauth_fence_owner_payload = None
oauth_lineage_path = os.path.join(
    root_directory, "kimi-oauth-refresh.lineage-v4",
)
oauth_bridge_name = f"kimi-oauth-refresh.lineage-v4.{nonce}"
oauth_bridge_directory = os.path.join(root_directory, oauth_bridge_name)
oauth_link_value = None
oauth_directory_created = False
oauth_directory_value = None
oauth_pid_fd = None
oauth_pid_value = None
oauth_token_fd = None
oauth_token_value = None
oauth_lock_acquired = False
oauth_holder_record = None
oauth_cleanup_holder_records = set()
oauth_owner_payload = None
oauth_cleanup_owner_payloads = set()
sentinel_pid = None
sentinel_reaped = False
vendor_handoff_pgid = None
vendor_gate_open = False
lease_path = os.path.join(session_directory, "lease")
lease_fd = None
lease_value = None
legacy_fd = None
legacy_value = None
owner_fd = None
owner_value = None
fifo_fd = None
NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)
CLOEXEC = getattr(os, "O_CLOEXEC", 0)
CREATE_FLAGS = os.O_RDWR | os.O_CREAT | NOFOLLOW | CLOEXEC
EXCLUSIVE_FLAGS = os.O_WRONLY | os.O_CREAT | os.O_EXCL | NOFOLLOW | CLOEXEC
READ_FLAGS = os.O_RDONLY | NOFOLLOW | CLOEXEC
READWRITE_FLAGS = os.O_RDWR | NOFOLLOW | CLOEXEC


def publish_status(value):
    tmp = f"{ready}.{os.getpid()}"
    out = os.open(tmp, EXCLUSIVE_FLAGS, 0o600)
    try:
        os.write(out, (value + "\n").encode("utf-8", "replace"))
        os.fsync(out)
    finally:
        os.close(out)
    os.replace(tmp, ready)


def publish_failure(value):
    try:
        out = os.open(failure, EXCLUSIVE_FLAGS, 0o600)
    except FileExistsError:
        return
    try:
        os.write(out, (value + "\n").encode("utf-8", "replace"))
        os.fsync(out)
    finally:
        os.close(out)


def publish_exclusive(path, value):
    out = os.open(path, EXCLUSIVE_FLAGS, 0o600)
    try:
        os.write(out, (value + "\n").encode("utf-8", "replace"))
        os.fsync(out)
    finally:
        os.close(out)


def publish_atomic(path, value):
    tmp = f"{path}.{os.getpid()}.{secrets.token_hex(8)}.tmp"
    out = os.open(tmp, EXCLUSIVE_FLAGS, 0o600)
    try:
        os.write(out, (value + "\n").encode("ascii"))
        os.fsync(out)
    finally:
        os.close(out)
    try:
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        raise


def fsync_directory(path):
    directory_fd = os.open(path, os.O_RDONLY | CLOEXEC)
    try:
        value = os.fstat(directory_fd)
        if not stat.S_ISDIR(value.st_mode):
            raise RuntimeError(f"not a directory: {path}")
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)


def same_inode(left, right):
    return (left.st_dev, left.st_ino) == (right.st_dev, right.st_ino)


def path_names_inode(path, value):
    return same_inode(value, os.lstat(path))


def ensure_owned_directory(path):
    os.makedirs(path, mode=0o700, exist_ok=True)
    value = os.lstat(path)
    if not stat.S_ISDIR(value.st_mode) or value.st_uid != os.getuid():
        raise RuntimeError(f"unsafe peer lock directory: {path}")
    os.chmod(path, 0o700)


def open_owned_regular(path):
    fd = os.open(path, CREATE_FLAGS, 0o600)
    value = os.fstat(fd)
    if (not stat.S_ISREG(value.st_mode)
            or value.st_uid != os.getuid()
            or value.st_nlink != 1
            or not path_names_inode(path, value)):
        os.close(fd)
        raise RuntimeError(f"unsafe peer lock file: {path}")
    os.fchmod(fd, 0o600)
    return fd, value


def open_existing_owned_regular(path, writable=False):
    fd = os.open(path, READWRITE_FLAGS if writable else READ_FLAGS)
    value = os.fstat(fd)
    if (not stat.S_ISREG(value.st_mode)
            or value.st_uid != os.getuid()
            or value.st_nlink != 1
            or not path_names_inode(path, value)):
        os.close(fd)
        raise RuntimeError(f"unsafe peer lock file: {path}")
    return fd, value


def read_ascii(fd, limit=256):
    # Helper and sentinel inherit the same open-file descriptions. pread keeps
    # their concurrent metadata checks from racing on a shared seek offset.
    return os.pread(fd, limit, 0).decode("ascii", "strict").strip()


def overwrite_ascii(fd, value):
    os.ftruncate(fd, 0)
    os.pwrite(fd, (value + "\n").encode("ascii"), 0)
    os.fsync(fd)


def oauth_owner_record():
    if oauth_lease_value is None:
        raise RuntimeError("OAuth lease identity unavailable")
    return (
        f"iwe-oauth-lineage-v4 {oauth_lease_value.st_dev} "
        f"{oauth_lease_value.st_ino} {nonce}"
    )


def identity_fault(path, value, changed, missing):
    try:
        return None if path_names_inode(path, value) else changed
    except FileNotFoundError:
        return missing


def metadata_fault(path, value, fd, expected, changed, missing):
    fault = identity_fault(path, value, changed, missing)
    if fault:
        return fault
    return None if read_ascii(fd) == expected else changed


def process_alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def fifo_eof(fd):
    try:
        return os.read(fd, 1) == b""
    except (BlockingIOError, OSError):
        return False


def read_vendor_pgid():
    try:
        marker_fd = os.open(pgid_path, READ_FLAGS)
    except FileNotFoundError:
        return None
    try:
        value = os.fstat(marker_fd)
        if (not stat.S_ISREG(value.st_mode)
                or value.st_uid != os.getuid()
                or value.st_nlink != 1):
            raise RuntimeError("unsafe vendor PGID marker")
        payload = os.read(marker_fd, 1024).decode("utf-8")
    finally:
        os.close(marker_fd)
    record = json.loads(payload)
    pid = record.get("pid")
    pgid = record.get("pgid")
    if (record.get("nonce") != nonce
            or not isinstance(pid, int)
            or not isinstance(pgid, int)
            or pid <= 1
            or pid != pgid
            or pgid == os.getpgrp()):
        raise RuntimeError("invalid vendor PGID marker")
    try:
        if os.getpgid(pid) != pgid:
            raise RuntimeError("vendor PGID identity changed")
    except ProcessLookupError:
        # The setsid leader may already be reaped while a grandchild remains
        # in the published group and still owns the lifetime FIFO. Keep using
        # that PGID until the kernel reports the whole group gone.
        return pgid if group_alive(pgid) else 0
    return pgid


def group_alive(pgid):
    try:
        os.killpg(pgid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        # Permission-unknown is not proof of death: retain the admission lock.
        return True
    return True


def terminate_vendor_group(pgid):
    if not pgid or not group_alive(pgid):
        return True
    try:
        os.killpg(pgid, signal.SIGTERM)
    except ProcessLookupError:
        return True
    except PermissionError:
        return False
    deadline = time.monotonic() + 2.0
    while time.monotonic() < deadline:
        if not group_alive(pgid):
            return True
        time.sleep(0.05)
    try:
        os.killpg(pgid, signal.SIGKILL)
    except ProcessLookupError:
        return True
    except PermissionError:
        return False
    deadline = time.monotonic() + 3.0
    while time.monotonic() < deadline and group_alive(pgid):
        time.sleep(0.05)
    return not group_alive(pgid)


def drain_lineage():
    terminated_pgid = None
    marker_error_reported = False
    while True:
        if fifo_eof(fifo_fd):
            return
        try:
            pgid = read_vendor_pgid()
            if (pgid is not None
                    and pgid != terminated_pgid
                    and terminate_vendor_group(pgid)):
                terminated_pgid = pgid
        except (OSError, RuntimeError, TypeError, ValueError) as exc:
            # A malformed/replaced marker or permission-unknown group cannot
            # justify unlocking. Keep the kernel locks until FIFO EOF proves
            # that every inheriting process has exited.
            if not marker_error_reported:
                sys.stderr.write(f"WARN: untrusted vendor PGID marker: {exc}\n")
                marker_error_reported = True
        # No PGID with a live FIFO writer is the fork-before-publish boundary.
        # Never timeout-unlock: the child will either publish or close the FIFO.
        time.sleep(0.05)


def oauth_pid_path():
    return os.path.join(oauth_bridge_directory, "pid")


def oauth_owner_path():
    return os.path.join(oauth_bridge_directory, "owner")


def adopt_vendor_pid_if_published():
    """Adopt the sentinel's atomic controller-PGID to vendor-PGID handoff."""
    global oauth_pid_fd, oauth_pid_value, oauth_holder_record
    global vendor_handoff_pgid
    if oauth_pid_fd is None:
        return False
    try:
        if (path_names_inode(oauth_pid_path(), oauth_pid_value)
                and read_ascii(oauth_pid_fd) == oauth_holder_record):
            return True
    except FileNotFoundError:
        pass

    pgid = read_vendor_pgid()
    if not pgid:
        return False
    candidate_fd, candidate_value = open_existing_owned_regular(
        oauth_pid_path(), writable=True,
    )
    expected = f"-{pgid}"
    try:
        if read_ascii(candidate_fd) != expected:
            return False
        if not path_names_inode(oauth_pid_path(), candidate_value):
            return False
        if not group_alive(pgid):
            return False
        previous_fd = oauth_pid_fd
        oauth_pid_fd = candidate_fd
        candidate_fd = None
        oauth_pid_value = candidate_value
        oauth_holder_record = expected
        oauth_cleanup_holder_records.add(expected)
        vendor_handoff_pgid = pgid
        os.close(previous_fd)
        return True
    finally:
        if candidate_fd is not None:
            os.close(candidate_fd)


def oauth_link_fault():
    if oauth_link_value is None:
        return "oauth-link-unavailable"
    fault = identity_fault(
        oauth_lineage_path, oauth_link_value,
        "oauth-lineage-identity-changed", "oauth-lineage-missing",
    )
    if fault:
        return fault
    if (not stat.S_ISLNK(oauth_link_value.st_mode)
            or os.readlink(oauth_lineage_path) != oauth_bridge_name):
        return "oauth-lineage-target-changed"
    return None


def current_authority_fault():
    fault = identity_fault(
        lease_path, lease_value,
        "lock-lease-identity-changed", "lock-lease-missing",
    )
    fault = fault or metadata_fault(
        legacy_path, legacy_value, legacy_fd, str(owner_pid),
        "legacy-lock-identity-changed", "legacy-lock-missing",
    )
    fault = fault or metadata_fault(
        owner_path, owner_value, owner_fd, f"{owner_pid} {nonce}",
        "lock-owner-metadata-changed", "lock-owner-metadata-missing",
    )
    if not fault and oauth_lease_fd is not None:
        fault = identity_fault(
            oauth_lease_path, oauth_lease_value,
            "oauth-lease-identity-changed", "oauth-lease-missing",
        )
        fault = fault or oauth_fence_fault()
    if not fault and oauth_directory_created:
        fault = oauth_link_fault()
        fault = fault or identity_fault(
            oauth_bridge_directory, oauth_directory_value,
            "oauth-bridge-identity-changed", "oauth-bridge-missing",
        )
    if not fault and oauth_pid_fd is not None:
        adopt_vendor_pid_if_published()
        fault = metadata_fault(
            oauth_pid_path(), oauth_pid_value, oauth_pid_fd,
            oauth_holder_record,
            "oauth-pid-changed", "oauth-pid-missing",
        )
    if not fault and oauth_token_fd is not None:
        fault = metadata_fault(
            oauth_owner_path(),
            oauth_token_value, oauth_token_fd, oauth_owner_payload,
            "oauth-owner-changed", "oauth-owner-missing",
        )
    return fault


def reap_sentinel(block=False):
    global sentinel_reaped
    if sentinel_pid is None or sentinel_reaped:
        return sentinel_reaped
    options = 0 if block else os.WNOHANG
    try:
        child, _status = os.waitpid(sentinel_pid, options)
    except ChildProcessError:
        sentinel_reaped = True
        return True
    if child == sentinel_pid:
        sentinel_reaped = True
    return sentinel_reaped


def current_session_fault():
    if stop_requested:
        return "lock-helper-stop-requested"
    if os.getppid() != owner_pid:
        return "owner-process-gone"
    fault = current_authority_fault()
    if not fault and sentinel_pid is not None and reap_sentinel():
        # Normal EOF may let the sentinel exit between the loop's first EOF
        # check and this liveness check. Only a dead sentinel with a live
        # writer is a fault; the helper still owns every authority in that
        # single-fault case and will drain the lineage itself.
        if not fifo_eof(fifo_fd):
            fault = "lock-sentinel-process-gone"
    return fault


def read_oauth_request():
    try:
        request_fd, _request_value = open_existing_owned_regular(oauth_request)
    except FileNotFoundError:
        return False
    try:
        return read_ascii(request_fd) == nonce
    finally:
        os.close(request_fd)


def valid_nonce(value):
    return (len(value) == 32
            and all(char in "0123456789abcdef" for char in value))


def load_exact_oauth_fence():
    """Adopt the immutable legacy fence created by explicit v4 cutover."""
    global oauth_fence_name, oauth_fence_directory
    global oauth_fence_link_value, oauth_fence_directory_value
    global oauth_fence_pid_fd, oauth_fence_pid_value
    global oauth_fence_owner_fd, oauth_fence_owner_value
    global oauth_fence_owner_payload
    prefix = "kimi-oauth-refresh.fence-v4."
    local_pid_fd = None
    local_owner_fd = None
    try:
        link_value = os.lstat(oauth_lock_directory)
        if (not stat.S_ISLNK(link_value.st_mode)
                or link_value.st_uid != os.getuid()):
            return False
        fence_name = os.readlink(oauth_lock_directory)
        if (not fence_name.startswith(prefix)
                or "/" in fence_name
                or not valid_nonce(fence_name[len(prefix):])):
            return False
        fence_nonce = fence_name[len(prefix):]
        fence_directory = os.path.join(root_directory, fence_name)
        directory_value = os.lstat(fence_directory)
        if (not stat.S_ISDIR(directory_value.st_mode)
                or directory_value.st_uid != os.getuid()
                or stat.S_IMODE(directory_value.st_mode) != 0o700
                or sorted(os.listdir(fence_directory)) != ["owner", "pid"]):
            return False
        pid_path = os.path.join(fence_directory, "pid")
        owner_path_v4 = os.path.join(fence_directory, "owner")
        local_pid_fd, pid_value = open_existing_owned_regular(pid_path)
        local_owner_fd, owner_value = open_existing_owned_regular(owner_path_v4)
        owner_payload = (
            f"iwe-oauth-fence-v4 {oauth_lease_value.st_dev} "
            f"{oauth_lease_value.st_ino} {fence_nonce}"
        )
        if (read_ascii(local_pid_fd) != "-1"
                or not process_alive(-1)
                or read_ascii(local_owner_fd) != owner_payload
                or not path_names_inode(oauth_lock_directory, link_value)
                or os.readlink(oauth_lock_directory) != fence_name
                or not path_names_inode(fence_directory, directory_value)
                or not path_names_inode(pid_path, pid_value)
                or not path_names_inode(owner_path_v4, owner_value)):
            return False
        oauth_fence_name = fence_name
        oauth_fence_directory = fence_directory
        oauth_fence_link_value = link_value
        oauth_fence_directory_value = directory_value
        oauth_fence_pid_fd, oauth_fence_pid_value = local_pid_fd, pid_value
        oauth_fence_owner_fd, oauth_fence_owner_value = (
            local_owner_fd, owner_value
        )
        oauth_fence_owner_payload = owner_payload
        local_pid_fd = None
        local_owner_fd = None
        return True
    except FileNotFoundError:
        return False
    finally:
        if local_owner_fd is not None:
            os.close(local_owner_fd)
        if local_pid_fd is not None:
            os.close(local_pid_fd)


def oauth_fence_fault():
    if oauth_fence_link_value is None:
        return "oauth-v4-cutover-required"
    fault = identity_fault(
        oauth_lock_directory, oauth_fence_link_value,
        "oauth-fence-identity-changed", "oauth-fence-missing",
    )
    if fault:
        return fault
    if (not stat.S_ISLNK(oauth_fence_link_value.st_mode)
            or os.readlink(oauth_lock_directory) != oauth_fence_name):
        return "oauth-fence-target-changed"
    fault = identity_fault(
        oauth_fence_directory, oauth_fence_directory_value,
        "oauth-fence-private-changed", "oauth-fence-private-missing",
    )
    if fault:
        return fault
    if sorted(os.listdir(oauth_fence_directory)) != ["owner", "pid"]:
        return "oauth-fence-contents-changed"
    fault = metadata_fault(
        os.path.join(oauth_fence_directory, "pid"),
        oauth_fence_pid_value, oauth_fence_pid_fd, "-1",
        "oauth-fence-pid-changed", "oauth-fence-pid-missing",
    )
    return fault or metadata_fault(
        os.path.join(oauth_fence_directory, "owner"),
        oauth_fence_owner_value, oauth_fence_owner_fd,
        oauth_fence_owner_payload,
        "oauth-fence-owner-changed", "oauth-fence-owner-missing",
    )


def remove_stale_v4_oauth_lineage(link_value):
    """Remove only an exact dead new-only v4 lineage symlink."""
    prefix = "kimi-oauth-refresh.lineage-v4."

    def unlink_exact_link(bridge_name):
        try:
            current = os.lstat(oauth_lineage_path)
            if (not same_inode(current, link_value)
                    or not stat.S_ISLNK(current.st_mode)
                    or os.readlink(oauth_lineage_path) != bridge_name):
                return False
        except FileNotFoundError:
            return True
        barrier = os.environ.get("IWE_PEER_TEST_OAUTH_PRE_UNLINK_BARRIER")
        if barrier:
            publish_exclusive(f"{barrier}.ready", str(os.getpid()))
            while not os.path.exists(f"{barrier}.release"):
                if os.getppid() != owner_pid:
                    raise RuntimeError("owner gone at OAuth unlink barrier")
                time.sleep(0.02)
        try:
            # The runtime name is new-only and serialized by the stable lease.
            # unlink(2) still gives replacement-type safety if local tampering
            # races this exact recheck.
            os.unlink(oauth_lineage_path)
        except FileNotFoundError:
            return True
        except (IsADirectoryError, PermissionError):
            return False
        return True

    try:
        if (not stat.S_ISLNK(link_value.st_mode)
                or link_value.st_uid != os.getuid()):
            return False
        bridge_name = os.readlink(oauth_lineage_path)
        if (not bridge_name.startswith(prefix)
                or "/" in bridge_name
                or not valid_nonce(bridge_name[len(prefix):])):
            return False
        bridge_nonce = bridge_name[len(prefix):]
        bridge_directory = os.path.join(root_directory, bridge_name)
        try:
            directory_value = os.lstat(bridge_directory)
        except FileNotFoundError:
            return unlink_exact_link(bridge_name)
        if (not stat.S_ISDIR(directory_value.st_mode)
                or directory_value.st_uid != os.getuid()
                or stat.S_IMODE(directory_value.st_mode) != 0o700):
            return False
        pid_path = os.path.join(bridge_directory, "pid")
        owner_path_v4 = os.path.join(bridge_directory, "owner")
        try:
            pid_fd, pid_value = open_existing_owned_regular(pid_path)
        except FileNotFoundError:
            return unlink_exact_link(bridge_name)
        try:
            holder = read_ascii(pid_fd)
            if (not holder.startswith("-")
                    or not holder[1:].isdigit()
                    or int(holder[1:]) <= 1):
                return False
            if group_alive(int(holder[1:])):
                return False
            try:
                owner_fd_v4, owner_value_v4 = open_existing_owned_regular(
                    owner_path_v4,
                )
            except FileNotFoundError:
                return unlink_exact_link(bridge_name)
            try:
                owner_record = read_ascii(owner_fd_v4)
                expected_owner = (
                    f"iwe-oauth-lineage-v4 {oauth_lease_value.st_dev} "
                    f"{oauth_lease_value.st_ino} {bridge_nonce}"
                )
                if owner_record != expected_owner:
                    return False
                if (not path_names_inode(oauth_lineage_path, link_value)
                        or os.readlink(oauth_lineage_path) != bridge_name
                        or not path_names_inode(
                            bridge_directory, directory_value,
                        )
                        or not path_names_inode(pid_path, pid_value)
                        or not path_names_inode(owner_path_v4, owner_value_v4)
                        or read_ascii(pid_fd) != holder
                        or read_ascii(owner_fd_v4) != owner_record
                        or not path_names_inode(
                            oauth_lease_path, oauth_lease_value,
                        )):
                    return False

                if not unlink_exact_link(bridge_name):
                    return False
                if (not path_names_inode(bridge_directory, directory_value)
                        or not path_names_inode(pid_path, pid_value)
                        or not path_names_inode(owner_path_v4, owner_value_v4)
                        or read_ascii(pid_fd) != holder
                        or read_ascii(owner_fd_v4) != owner_record):
                    return True
                os.unlink(owner_path_v4)
                os.unlink(pid_path)
                os.rmdir(bridge_directory)
                return True
            finally:
                os.close(owner_fd_v4)
        finally:
            os.close(pid_fd)
    except FileNotFoundError:
        return not os.path.lexists(oauth_lineage_path)


def remove_stale_oauth_bridge():
    """Recover only the new-only runtime lineage namespace."""
    try:
        value = os.lstat(oauth_lineage_path)
    except FileNotFoundError:
        return True
    if stat.S_ISLNK(value.st_mode):
        return remove_stale_v4_oauth_lineage(value)
    # Compliant v4 writers publish only a relative symlink. Unknown objects at
    # the new-only name indicate tampering and remain fail-closed.
    return False


def cleanup_unpublished_bridge(directory_value, pid_fd_local, pid_value_local,
                               owner_fd_local, owner_value_local):
    """Best-effort cleanup for a private bridge never named by canonical."""
    try:
        if owner_fd_local is not None and path_names_inode(
                oauth_owner_path(), owner_value_local):
            os.unlink(oauth_owner_path())
        if pid_fd_local is not None and path_names_inode(
                oauth_pid_path(), pid_value_local):
            os.unlink(oauth_pid_path())
        if path_names_inode(oauth_bridge_directory, directory_value):
            os.rmdir(oauth_bridge_directory)
    except (FileNotFoundError, OSError):
        pass


def acquire_oauth_once():
    """One nonblocking acquisition step, owned entirely by this helper."""
    global oauth_lease_fd, oauth_lease_value
    global oauth_link_value, oauth_directory_created, oauth_directory_value
    global oauth_lock_acquired, oauth_holder_record
    global oauth_pid_fd, oauth_pid_value, oauth_token_fd, oauth_token_value
    global oauth_owner_payload, oauth_cleanup_owner_payloads
    global oauth_cleanup_holder_records

    if oauth_lease_fd is None:
        candidate_fd, candidate_value = open_owned_regular(oauth_lease_path)
        try:
            fcntl.flock(candidate_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as exc:
            os.close(candidate_fd)
            if exc.errno in (errno.EACCES, errno.EAGAIN):
                return False
            raise
        if not path_names_inode(oauth_lease_path, candidate_value):
            os.close(candidate_fd)
            raise RuntimeError("global OAuth lease identity changed")
        oauth_lease_fd = candidate_fd
        oauth_lease_value = candidate_value
        if not load_exact_oauth_fence():
            publish_failure("oauth-v4-cutover-required")
            raise RuntimeError(
                "OAuth v4 cutover fence missing or invalid; explicit "
                "--cutover-oauth-lineage-v4 required after legacy drain"
            )

    if oauth_lock_acquired:
        return True
    if os.path.lexists(oauth_lineage_path):
        if not remove_stale_oauth_bridge():
            return False

    local_pid_fd = None
    local_pid_value = None
    local_owner_fd = None
    local_owner_value = None
    try:
        os.mkdir(oauth_bridge_directory, 0o700)
    except FileExistsError:
        raise RuntimeError("OAuth bridge nonce collision")
    directory_value = os.lstat(oauth_bridge_directory)
    if (not stat.S_ISDIR(directory_value.st_mode)
            or directory_value.st_uid != os.getuid()
            or stat.S_IMODE(directory_value.st_mode) != 0o700):
        raise RuntimeError("unsafe created OAuth private bridge")

    try:
        mkdir_barrier = os.environ.get("IWE_PEER_TEST_OAUTH_POST_MKDIR_BARRIER")
        if mkdir_barrier:
            publish_exclusive(f"{mkdir_barrier}.ready", str(os.getpid()))
            while not os.path.exists(f"{mkdir_barrier}.release"):
                fault = current_session_fault()
                if fault:
                    raise RuntimeError(f"OAuth post-mkdir barrier: {fault}")
                time.sleep(0.02)

        controller_holder = f"-{controller_pgid}"
        publish_exclusive(oauth_pid_path(), controller_holder)
        local_pid_fd, local_pid_value = open_existing_owned_regular(
            oauth_pid_path(), writable=True,
        )
        barrier = os.environ.get("IWE_PEER_TEST_OAUTH_PRE_OWNER_BARRIER")
        if barrier:
            publish_exclusive(f"{barrier}.ready", str(os.getpid()))
            while not os.path.exists(f"{barrier}.release"):
                fault = current_session_fault()
                if fault:
                    raise RuntimeError(f"OAuth pre-owner barrier: {fault}")
                time.sleep(0.02)

        owner_record = oauth_owner_record()
        publish_exclusive(oauth_owner_path(), owner_record)
        local_owner_fd, local_owner_value = open_existing_owned_regular(
            oauth_owner_path(), writable=True,
        )
        fsync_directory(oauth_bridge_directory)
        try:
            os.symlink(oauth_bridge_name, oauth_lineage_path)
        except FileExistsError:
            cleanup_unpublished_bridge(
                directory_value, local_pid_fd, local_pid_value,
                local_owner_fd, local_owner_value,
            )
            os.close(local_owner_fd)
            os.close(local_pid_fd)
            return False
        link_value = os.lstat(oauth_lineage_path)
        if (not stat.S_ISLNK(link_value.st_mode)
                or link_value.st_uid != os.getuid()
                or os.readlink(oauth_lineage_path) != oauth_bridge_name):
            raise RuntimeError("unsafe published OAuth v4 lineage link")
        fsync_directory(root_directory)
    except Exception:
        if os.path.lexists(oauth_lineage_path):
            try:
                link = os.lstat(oauth_lineage_path)
                if (stat.S_ISLNK(link.st_mode)
                        and os.readlink(oauth_lineage_path) == oauth_bridge_name):
                    os.unlink(oauth_lineage_path)
            except (FileNotFoundError, OSError):
                pass
        cleanup_unpublished_bridge(
            directory_value, local_pid_fd, local_pid_value,
            local_owner_fd, local_owner_value,
        )
        raise

    oauth_link_value = link_value
    oauth_directory_created = True
    oauth_directory_value = directory_value
    oauth_pid_fd, oauth_pid_value = local_pid_fd, local_pid_value
    oauth_token_fd, oauth_token_value = local_owner_fd, local_owner_value
    oauth_holder_record = controller_holder
    oauth_cleanup_holder_records.add(controller_holder)
    oauth_owner_payload = owner_record
    oauth_cleanup_owner_payloads.add(owner_record)
    sentinel_barrier = os.environ.get("IWE_PEER_TEST_OAUTH_PRE_SENTINEL_BARRIER")
    if sentinel_barrier:
        publish_exclusive(f"{sentinel_barrier}.ready", str(os.getpid()))
        while not os.path.exists(f"{sentinel_barrier}.release"):
            fault = current_session_fault()
            if fault:
                raise RuntimeError(f"OAuth pre-sentinel barrier: {fault}")
            time.sleep(0.02)
    oauth_lock_acquired = True
    return True


def release_owned_oauth_lock():
    """Remove only this exact runtime symlink and its private lineage."""
    if not oauth_directory_created or oauth_directory_value is None:
        return
    pid_path = oauth_pid_path()
    token_path = oauth_owner_path()
    try:
        if oauth_link_fault():
            return
        if not path_names_inode(oauth_bridge_directory, oauth_directory_value):
            return
        if oauth_pid_fd is not None:
            holder = read_ascii(oauth_pid_fd)
            if (holder not in oauth_cleanup_holder_records
                    or not path_names_inode(pid_path, oauth_pid_value)):
                return
        if oauth_token_fd is not None and (
                read_ascii(oauth_token_fd) not in oauth_cleanup_owner_payloads
                or not path_names_inode(token_path, oauth_token_value)):
            return
        # The permanent compatibility fence is never touched. Remove only the
        # new-only runtime name; every remaining unlink is nonce-private.
        os.unlink(oauth_lineage_path)
        if oauth_token_fd is not None:
            os.unlink(token_path)
        if oauth_pid_fd is not None:
            if not path_names_inode(pid_path, oauth_pid_value):
                return
            os.unlink(pid_path)
        if path_names_inode(oauth_bridge_directory, oauth_directory_value):
            os.rmdir(oauth_bridge_directory)
    except FileNotFoundError:
        return
    except (OSError, RuntimeError) as exc:
        sys.stderr.write(f"WARN: cannot clean owned OAuth lock: {exc}\n")


def sentinel_arm_vendor_if_published():
    """Atomically move the legacy holder from controller PG to vendor PG."""
    global oauth_pid_fd, oauth_pid_value, oauth_holder_record
    global vendor_handoff_pgid
    if vendor_handoff_pgid is not None:
        return True
    pgid = read_vendor_pgid()
    if pgid is None:
        return False
    if not pgid or not group_alive(pgid):
        raise RuntimeError("published vendor process group is gone")

    tmp_path = (
        f"{oauth_pid_path()}.{os.getpid()}.{secrets.token_hex(8)}.tmp"
    )
    out = os.open(tmp_path, EXCLUSIVE_FLAGS, 0o600)
    try:
        os.write(out, f"-{pgid}\n".encode("ascii"))
        os.fsync(out)
    finally:
        os.close(out)
    os.replace(tmp_path, oauth_pid_path())
    fsync_directory(oauth_bridge_directory)
    candidate_fd, candidate_value = open_existing_owned_regular(
        oauth_pid_path(), writable=True,
    )
    expected = f"-{pgid}"
    if (read_ascii(candidate_fd) != expected
            or not path_names_inode(oauth_pid_path(), candidate_value)):
        os.close(candidate_fd)
        raise RuntimeError("vendor holder publication changed")
    previous_fd = oauth_pid_fd
    oauth_pid_fd = candidate_fd
    oauth_pid_value = candidate_value
    oauth_holder_record = expected
    oauth_cleanup_holder_records.add(expected)
    vendor_handoff_pgid = pgid
    os.close(previous_fd)
    publish_atomic(vendor_armed_path, f"{nonce} {pgid}")
    return True


def helper_open_vendor_exec_gate():
    """Open exec only after sentinel published and retained the vendor PGID."""
    global vendor_gate_open
    if vendor_gate_open or sentinel_pid is None:
        return vendor_gate_open
    try:
        armed_fd, _armed_value = open_existing_owned_regular(vendor_armed_path)
    except FileNotFoundError:
        return False
    try:
        record = read_ascii(armed_fd)
    finally:
        os.close(armed_fd)
    fields = record.split(" ")
    if (len(fields) != 2 or fields[0] != nonce
            or not fields[1].isdigit() or int(fields[1]) <= 1):
        raise RuntimeError("invalid vendor armed acknowledgement")
    pgid = int(fields[1])
    if read_vendor_pgid() != pgid or not adopt_vendor_pid_if_published():
        raise RuntimeError("vendor armed acknowledgement lost authority")
    if reap_sentinel() or current_authority_fault():
        raise RuntimeError("sentinel lost before vendor exec gate")
    publish_atomic(vendor_exec_gate, f"{nonce} {pgid}")
    vendor_gate_open = True
    return True


def cleanup_authorities():
    """Release metadata only after this process has proved lineage EOF."""
    # OAuth first: while either helper or sentinel remains alive, the shared
    # permanent flock still excludes new adapters. Exact inode+nonce checks
    # prevent this invocation from removing a replacement bridge.
    release_owned_oauth_lock()
    try:
        if (owner_fd is not None
                and not metadata_fault(
                    owner_path, owner_value, owner_fd, f"{owner_pid} {nonce}",
                    "changed", "missing",
                )):
            os.unlink(owner_path)
    except (FileNotFoundError, OSError) as exc:
        sys.stderr.write(f"WARN: cannot clean owner metadata: {exc}\n")
    try:
        if (legacy_fd is not None
                and not metadata_fault(
                    legacy_path, legacy_value, legacy_fd, str(owner_pid),
                    "changed", "missing",
                )):
            os.ftruncate(legacy_fd, 0)
            os.fsync(legacy_fd)
    except (FileNotFoundError, OSError) as exc:
        sys.stderr.write(f"WARN: cannot clean legacy lock metadata: {exc}\n")


def run_oauth_sentinel(helper_pid, ack_fd):
    """Keep every admission authority alive if the Python helper is killed."""
    global stop_requested
    sentinel_self = os.getpid()
    sentinel_armed = False
    cleanup_on_exit = False
    failure_reason = None
    exit_code = 1
    try:
        # The bridge already points at the controller process group. This
        # sentinel is a second member of that group, so deployed Bash readers
        # keep seeing `kill -0 -PGID` succeed if either controller dies.
        fault = current_authority_fault()
        if fault:
            raise RuntimeError(f"sentinel authority handoff: {fault}")
        sentinel_armed = True
        try:
            os.write(
                ack_fd,
                f"armed:{sentinel_self}:{nonce}\n".encode("ascii"),
            )
        except BrokenPipeError:
            # Parent death is exactly the fault this process exists to cover.
            pass

        while True:
            sentinel_arm_vendor_if_published()
            if fifo_eof(fifo_fd):
                if os.getppid() == helper_pid:
                    # Normal release belongs to the still-live controller.
                    # It reaps us before cleaning metadata, so we never race
                    # its authority checks by truncating a shared inode.
                    exit_code = 0
                else:
                    failure_reason = "lock-helper-process-gone"
                    cleanup_on_exit = True
                    publish_failure(failure_reason)
                break
            if stop_requested:
                failure_reason = "lock-sentinel-stop-requested"
            elif os.getppid() != helper_pid:
                failure_reason = "lock-helper-process-gone"
            else:
                failure_reason = current_authority_fault()
            if failure_reason:
                publish_failure(failure_reason)
                drain_lineage()
                cleanup_on_exit = True
                break
            time.sleep(0.05)
    except Exception as exc:
        if sentinel_armed:
            failure_reason = f"lock-sentinel-error:{type(exc).__name__}"
            try:
                publish_failure(failure_reason)
            except Exception as report_exc:
                sys.stderr.write(
                    f"WARN: cannot publish lock-sentinel failure: {report_exc}\n"
                )
            drain_lineage()
            cleanup_on_exit = True
        else:
            try:
                os.write(
                    ack_fd,
                    f"error:{type(exc).__name__}\n".encode("ascii"),
                )
            except (BrokenPipeError, OSError):
                pass
    finally:
        try:
            os.close(ack_fd)
        except OSError:
            pass
        if sentinel_armed and cleanup_on_exit:
            cleanup_authorities()
    os._exit(exit_code if failure_reason is None else 1)


def start_oauth_sentinel():
    """Fork and verify the second owner before vendor admission is opened."""
    global sentinel_pid
    ack_read, ack_write = os.pipe()
    helper_pid = os.getpid()
    child_pid = os.fork()
    if child_pid == 0:
        os.close(ack_read)
        run_oauth_sentinel(helper_pid, ack_write)
    os.close(ack_write)
    sentinel_pid = child_pid

    flags = fcntl.fcntl(ack_read, fcntl.F_GETFL)
    fcntl.fcntl(ack_read, fcntl.F_SETFL, flags | os.O_NONBLOCK)
    expected = f"armed:{child_pid}:{nonce}"
    payload = b""
    deadline = time.monotonic() + 5.0
    try:
        while time.monotonic() < deadline:
            if os.getppid() != owner_pid:
                raise RuntimeError("owner process gone during sentinel handoff")
            try:
                chunk = os.read(ack_read, 256)
            except BlockingIOError:
                chunk = None
            if chunk == b"":
                break
            if chunk:
                payload += chunk
                if b"\n" in payload:
                    break
            if reap_sentinel():
                break
            time.sleep(0.02)
    finally:
        os.close(ack_read)

    status = payload.split(b"\n", 1)[0].decode("ascii", "replace")
    if status != expected:
        raise RuntimeError(f"OAuth sentinel failed to arm: {status or 'no status'}")
    fault = current_authority_fault()
    if fault:
        raise RuntimeError(f"OAuth sentinel handoff lost authority: {fault}")
    sentinel_barrier = os.environ.get("IWE_PEER_TEST_OAUTH_PRE_SENTINEL_BARRIER")
    if sentinel_barrier:
        publish_exclusive(f"{sentinel_barrier}.sentinel", str(child_pid))


try:
    os.setsid()
    controller_pgid = os.getpgrp()
    if controller_pgid != os.getpid():
        raise RuntimeError("lock helper did not establish a private process group")
    ensure_owned_directory(root_directory)
    ensure_owned_directory(session_directory)

    lease_fd, lease_value = open_owned_regular(lease_path)

    try:
        fcntl.flock(lease_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as exc:
        if exc.errno in (errno.EACCES, errno.EAGAIN):
            publish_status("busy")
            raise SystemExit(5)
        raise

    # Stable lease is never removed by normal cleanup. Detect an unexpected
    # replacement across open/flock and retry before any vendor can start.
    if not path_names_inode(lease_path, lease_value):
        publish_status("retry-boundary")
        raise SystemExit(75)

    # Rollout compatibility: lock the historical <id>.pid inode too. A live
    # old adapter therefore blocks the new one, and an old adapter starting
    # while this invocation runs sees its familiar flock as busy.
    legacy_fd, legacy_value = open_owned_regular(legacy_path)
    try:
        fcntl.flock(legacy_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as exc:
        if exc.errno in (errno.EACCES, errno.EAGAIN):
            publish_status("busy-legacy")
            raise SystemExit(5)
        raise
    if not path_names_inode(legacy_path, legacy_value):
        publish_status("retry-boundary")
        raise SystemExit(75)
    previous = read_ascii(legacy_fd, 128)
    if (previous.isdigit()
            and int(previous) != owner_pid
            and process_alive(int(previous))):
        publish_status("busy-legacy")
        raise SystemExit(5)
    overwrite_ascii(legacy_fd, str(owner_pid))

    owner_fd, owner_value = open_owned_regular(owner_path)
    overwrite_ascii(owner_fd, f"{owner_pid} {nonce}")

    fifo_flags = os.O_RDONLY | os.O_NONBLOCK
    fifo_flags |= NOFOLLOW | CLOEXEC
    fifo_fd = os.open(lifetime_fifo, fifo_flags)
    fifo_value = os.fstat(fifo_fd)
    if not stat.S_ISFIFO(fifo_value.st_mode) or fifo_value.st_uid != os.getuid():
        raise RuntimeError("unsafe peer lifetime FIFO")

    publish_status(f"acquired:{nonce}")
    lock_acquired = True

    token = b""
    while b"\n" not in token:
        if os.getppid() != owner_pid:
            raise SystemExit(0)
        try:
            chunk = os.read(fifo_fd, 256)
        except BlockingIOError:
            chunk = None
        if chunk == b"":
            raise SystemExit(0)
        if chunk:
            token += chunk
        else:
            time.sleep(0.02)
    if token.split(b"\n", 1)[0].decode("ascii", "strict") != nonce:
        raise RuntimeError("peer lifetime nonce mismatch")
    publish_exclusive(armed, nonce)
    lease_armed = True

    def request_stop(_signum, _frame):
        global stop_requested
        stop_requested = True

    signal.signal(signal.SIGHUP, request_stop)
    signal.signal(signal.SIGINT, request_stop)
    signal.signal(signal.SIGTERM, request_stop)
    failure_reason = None
    while True:
        if fifo_eof(fifo_fd):
            break
        failure_reason = current_session_fault()
        if not failure_reason and read_oauth_request():
            if oauth_wait_started is None:
                oauth_wait_started = time.monotonic()
            if acquire_oauth_once():
                if sentinel_pid is None:
                    start_oauth_sentinel()
                if not os.path.exists(oauth_ready):
                    publish_exclusive(oauth_ready, nonce)
            elif time.monotonic() - oauth_wait_started >= oauth_timeout:
                failure_reason = "oauth-lock-timeout"
        if not failure_reason and sentinel_pid is not None:
            helper_open_vendor_exec_gate()
        if failure_reason:
            publish_failure(failure_reason)
            drain_lineage()
            break
        time.sleep(0.1)
except SystemExit:
    raise
except Exception as exc:
    if lock_acquired and lease_armed:
        try:
            publish_failure(f"lock-helper-error:{type(exc).__name__}")
        except Exception as report_exc:
            sys.stderr.write(f"WARN: cannot publish lock-helper failure: {report_exc}\n")
        drain_lineage()
    else:
        try:
            publish_status(f"error:{type(exc).__name__}")
        except Exception as report_exc:
            sys.stderr.write(f"WARN: cannot publish lock-helper status: {report_exc}\n")
    raise SystemExit(1)
finally:
    # This exact helper/sentinel pair is one dual-owner lock state machine.
    # Both inherit the same open-file descriptions, so either process
    # surviving a single fault retains every kernel flock; splitting further
    # would break that lifetime invariant.
    if sentinel_pid is not None and not sentinel_reaped:
        reap_sentinel(block=True)
    cleanup_authorities()
PY
    SESSION_LOCK_HELPER_PID=$!

    for _wait in $(seq 1 100); do
      [ -s "$SESSION_LOCK_READY" ] && break
      kill -0 "$SESSION_LOCK_HELPER_PID" 2>/dev/null || break
      sleep 0.05
    done
    status="$(cat "$SESSION_LOCK_READY" 2>/dev/null || true)"
    case "$status" in
      acquired:*)
        SESSION_LOCK_NONCE="${status#acquired:}"
        if ! printf '%s\n' "$SESSION_LOCK_NONCE" >&9; then
          status="arm-write-failed"
        else
          for _wait in $(seq 1 100); do
            [ -s "$SESSION_LOCK_ARMED" ] && break
            kill -0 "$SESSION_LOCK_HELPER_PID" 2>/dev/null || break
            sleep 0.02
          done
          if [ "$(cat "$SESSION_LOCK_ARMED" 2>/dev/null || true)" = "$SESSION_LOCK_NONCE" ]; then
            SESSION_LOCK_HELD=true
            return 0
          fi
          status="arm-failed"
        fi
        ;;
      retry-boundary)
        wait "$SESSION_LOCK_HELPER_PID" 2>/dev/null || helper_rc=$?
        if [ "$helper_rc" -eq 75 ] && [ "$attempt" -lt "$max_attempts" ]; then
          echo "WARN: peer-session lock path changed during acquisition; retrying ($attempt/$max_attempts)." >&2
          attempt=$((attempt + 1))
          continue
        fi
        ;;
      busy|busy-legacy)
        wait "$SESSION_LOCK_HELPER_PID" 2>/dev/null || helper_rc=$?
        echo "ABORT: peer session '$KIMI_SESSION_ID' already running." >&2
        [ "$helper_rc" -eq 5 ] && return 5
        return 1
        ;;
    esac
    # If acquisition reached the armed state but its acknowledgement was lost,
    # TERM makes the helper drain its FIFO. Close our only possible writer
    # first; no vendor is allowed to start before acquire_session_lock returns.
    if [ "$SESSION_LIFETIME_FD_OPEN" = true ]; then
      exec 9>&-
      SESSION_LIFETIME_FD_OPEN=false
    fi
    if jobs -pr | grep -qx "$SESSION_LOCK_HELPER_PID"; then
      kill "$SESSION_LOCK_HELPER_PID" 2>/dev/null || true
    fi
    wait "$SESSION_LOCK_HELPER_PID" 2>/dev/null || helper_rc=$?
    echo "ERROR: cannot acquire exact peer-session lock for '$KIMI_SESSION_ID' (${status:-no status}, rc=$helper_rc)." >&2
    return 1
  done
  return 1
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
    "$KIMI_WP" "$OUR_PID" <<'PY'
import datetime
import os
import stat
import sys
import uuid

directory, path, task, wp, owner_pid = sys.argv[1:]
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
        f"wp: {wp}\n"
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
    "$OUR_PID" "$IWE_PEER_HEARTBEAT_SECONDS" "$PEER_HEARTBEAT_READY" 9>&- <<'PY' &
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
  [ -x "$_IWE_ARS" ] && bash "$_IWE_ARS" --session-id "$KIMI_SESSION_ID" kimi idle 9>&- 2>/dev/null &
  # Stop and reap the direct heartbeat helper. It checks the adapter's exact
  # parent relationship itself, so SIGKILL of the adapter also makes it exit.
  # The bounded reap guard prevents an unexpected helper fault from hanging
  # this EXIT trap.
  if [ -n "$PEER_HB_PID" ]; then
    if jobs -pr | grep -qx "$PEER_HB_PID"; then
      kill "$PEER_HB_PID" 2>/dev/null || true
      ( exec 9>&-; sleep 5; kill -9 "$PEER_HB_PID" 2>/dev/null ) &
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
  # The helper/sentinel authority pair releases OAuth by exact versioned
  # lease+PID+nonce after FIFO EOF. The top adapter never removes that bridge.
  rm -rf "$TMP_ROOT"
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

[ -x "$_IWE_ARS" ] && bash "$_IWE_ARS" --session-id "$KIMI_SESSION_ID" kimi peer-session "$KIMI_TASK" 9>&- 2>/dev/null &

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
"$KIMI_BIN" --help 9>&- > "$KIMI_HELP_FILE" 2>/dev/null || true
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
# After an explicit quiescent cutover, deployed schedulers remain blocked on an
# immutable legacy fence. New adapters serialize on a permanent regular-file
# flock shared by a lineage helper and its fault-isolated sentinel, plus a
# separate new-only runtime symlink. A mandatory pre-exec gate transfers the
# runtime holder from the helper/sentinel group to the vendor group before code
# runs. The top shell only sends a private request, so its SIGKILL cannot
# interrupt publication or release admission while a vendor survives.
acquire_oauth_lock() {
  local request_tmp="${SESSION_OAUTH_REQUEST}.$$" status _wait
  rm -f "$SESSION_OAUTH_READY" "$request_tmp"
  if ! printf '%s\n' "$SESSION_LOCK_NONCE" > "$request_tmp" \
     || ! mv "$request_tmp" "$SESSION_OAUTH_REQUEST" 9>&-; then
    rm -f "$request_tmp"
    return 1
  fi
  for _wait in $(seq 1 $((IWE_PEER_OAUTH_LOCK_TIMEOUT_SECONDS * 20 + 40))); do
    status=$(cat "$SESSION_OAUTH_READY" 2>/dev/null || true)
    if [ "$status" = "$SESSION_LOCK_NONCE" ]; then
      return 0
    fi
    [ -s "$SESSION_LOCK_FAILURE" ] && return 1
    kill -0 "$SESSION_LOCK_HELPER_PID" 2>/dev/null || return 1
    sleep 0.05
  done
  return 1
}
if ! acquire_oauth_lock; then
  if [ "$(cat "$SESSION_LOCK_FAILURE" 2>/dev/null || true)" = "oauth-v4-cutover-required" ]; then
    echo "ERROR: OAuth lineage v4 cutover is required. Disable and drain every legacy Kimi launcher, then run with --cutover-oauth-lineage-v4 and IWE_OAUTH_CUTOVER_QUIESCED=1." >&2
  else
    echo "ERROR: OAuth refresh lock busy after ${IWE_PEER_OAUTH_LOCK_TIMEOUT_SECONDS}s — another Kimi process is mid-refresh on $OAUTH_LOCK_DIR." >&2
  fi
  exit 1
fi

# Text-only mode always inlines the filtered context.  Passing --add-dir would
# re-expose a workspace even though the no-tools profile does not need it.
KIMI_DIR_ARGS=()
KIMI_LINEAGE_ARGS=(
  --pgid-file "$SESSION_VENDOR_PGID_FILE"
  --lineage-nonce "$SESSION_LOCK_NONCE"
  --exec-gate-file "$SESSION_VENDOR_EXEC_GATE"
)
# Deterministic process-boundary seams used only by the adapter regression
# suite. They are inert unless an explicit test path is supplied.
if [ -n "${IWE_PEER_TEST_PRE_SETSID_BARRIER:-}" ]; then
  KIMI_LINEAGE_ARGS+=(--pre-setsid-barrier "$IWE_PEER_TEST_PRE_SETSID_BARRIER")
fi
if [ -n "${IWE_PEER_TEST_PRE_EXEC_BARRIER:-}" ]; then
  KIMI_LINEAGE_ARGS+=(--pre-exec-barrier "$IWE_PEER_TEST_PRE_EXEC_BARRIER")
fi

if [ "$KIMI_CLI_STYLE" = "prompt-arg" ]; then
  # kimi-code 0.29 gates --agent-file behind the v2 engine, enabled by this
  # env var.  Set it only for the v2 agent format (peer-session 2026-08-15-05,
  # Codex review): an experimental flag may change more than the gate, so a
  # pre-v2 CLI must not receive it.
  if [ "$KIMI_AGENT_STYLE" = "v2" ]; then
    export KIMI_CODE_EXPERIMENTAL_FLAG=1
  fi
  KIMI_RAW=$(cd "$KIMI_TEXT_ONLY_WORKDIR" && run_with_deadline "$IWE_PEER_TIMEOUT_SECONDS" \
    "${KIMI_LINEAGE_ARGS[@]}" \
    "${GUARD_ARGS[@]+"${GUARD_ARGS[@]}"}" "$KIMI_BIN" \
    "${KIMI_PROMPT_ARGS[@]}" \
    ${MODEL_ARG[@]+"${MODEL_ARG[@]}"} \
    ${KIMI_DIR_ARGS[@]+"${KIMI_DIR_ARGS[@]}"} \
    < /dev/null \
    2>"$KIMI_STDERR")
else
  KIMI_RAW=$(run_with_deadline "$IWE_PEER_TIMEOUT_SECONDS" \
    "${KIMI_LINEAGE_ARGS[@]}" \
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

# Exact peer-session ownership was revoked while the vendor process was live.
# The lifetime helper has terminated the published CLI process group and held
# both admission flocks until every FIFO-owning descendant exited.
if [ -s "$SESSION_LOCK_FAILURE" ]; then
  LOCK_FAILURE_REASON="$(cat "$SESSION_LOCK_FAILURE" 2>/dev/null || echo unknown)"
  echo "ERROR: exact peer-session lock lost ($LOCK_FAILURE_REASON); Kimi process group was terminated." >&2
  adapter_diagnostic "$PERL_EXIT"
  exit 1
fi

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
    exec 9>&-
    echo "{\"action\":\"retain\",\"source\":\"kimi-peer\",\"text\":$(echo "$KIMI_OUTPUT" | head -c 4000 | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')}" \
    | python3 "$HINDSIGHT_SCRIPT" 2>/dev/null || true
  } &
fi

# === WP-454 Ф3: write to agent-sessions journal (best-effort, non-blocking) ===
# Writes one entry per adapter call. Caller groups by session_id on read.
# Security: only timestamps and duration written — no content from KIMI_OUTPUT.
{
  exec 9>&-
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
