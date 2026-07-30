#!/usr/bin/env bash
# session-guard.sh — единый gate open/close/audit для всех агентов (Claude, Kimi, Hermes)
# see WP-398 Ф5, AGENTS.md (WP Gate — CRITICAL), protocol-open.md
#
# Инвариант: любая сессия с изменениями файлов должна пройти open → ORZ → commit → close.
# Mechanical enforcement: git pre-commit hook проверяет наличие активного семафора.
#
# Команды:
#   open --wp WP-N [--task "..."] [--files "a,b"] [--slug "..."] [--agent claude-code|kimi|hermes]
#   open --housekeeping <reason> [--agent ...]        # фоновая housekeeping-сессия без ORZ
#   close [--wp WP-N] [--slug "..."] [--agent ...]
#   close --housekeeping <reason> [--agent ...]       # закрыть housekeeping-сессию
#   audit [--since YYYY-MM-DD]
#   pre-commit-check
#   note-file <path> [--agent ...]
#
# Exit codes:
#   0 — OK
#   1 — общая ошибка
#   2 — open без wp
#   3 — close без предшествующего open
#   4 — git pre-commit блок (семафор не найден)
#   5 — ORZ не прошёл валидацию
#   6 — scope gate block (staged файл вне активных сессий)

set -euo pipefail

IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"
# issue #266: a hardcoded personal governance-repo name broke every template
# user whose repo is named differently (the shipped default — see create-wp.sh).
GOV_REPO="${IWE_GOVERNANCE_REPO:-DS-strategy}"
SESSION_DIR="$IWE_ROOT/.iwe-runtime/sessions"
OPEN_LOG="$IWE_ROOT/$GOV_REPO/inbox/open-sessions.log"
ORZ_DIR="$IWE_ROOT/$GOV_REPO/sessions"
AGENT_STATUS_SCRIPT="$IWE_ROOT/scripts/agent-status-report.sh"
mkdir -p "$SESSION_DIR" "$(dirname "$OPEN_LOG")" "$ORZ_DIR"

CMD="${1:-}"
shift || true

# --- helpers ---
now_iso() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
now_date() { date +"%Y-%m-%d"; }
fail() { echo "session-guard: $1" >&2; exit "${2:-1}"; }
orz_agent_name() {
  case "$1" in
    kimi) echo "kimi-headless" ;;
    *)    echo "$1" ;;
  esac
}

# WP-464: pick the semaphore matching --wp/--slug among an agent's open
# semaphores. Ambiguous only when 2+ are open and none match — fails loudly
# with the candidate list instead of guessing "newest" (bug-2026-06-23,
# bug-2026-07-03-close-ignores-wp-arg, bug-2026-07-04-ptr-collision).
#
# Return codes (caller must check — this function never calls `exit`: inside
# a `$(...)` substitution `exit` only kills the subshell, not the script,
# code review a8fe9ded caught this):
#   0 — printed the selected semaphore path to stdout
#   1 — no open semaphore at all for this agent
#   2 — ambiguous or requested --wp/--slug matched nothing; candidate list
#       already printed to stderr, caller should just propagate a failure
select_semaphore() {
  local agent="$1" want_wp="$2" want_slug="$3"
  local candidates cand cand_wp cand_slug matched="" count

  candidates=$(ls -t "$SESSION_DIR/${agent}"-*.open 2>/dev/null || true)
  [ -z "$candidates" ] && return 1

  if [ -n "$want_wp" ] || [ -n "$want_slug" ]; then
    while IFS= read -r cand; do
      [ -z "$cand" ] && continue
      cand_wp=$(grep "^wp: " "$cand" | cut -d' ' -f2- || true)
      cand_slug=$(grep "^slug: " "$cand" | cut -d' ' -f2- || true)
      if { [ -n "$want_wp" ] && [ "$cand_wp" = "$want_wp" ]; } || \
         { [ -n "$want_slug" ] && [ "$cand_slug" = "$want_slug" ]; }; then
        matched="$cand"
        break
      fi
    done <<< "$candidates"

    if [ -n "$matched" ]; then
      echo "$matched"
      return 0
    fi

    # Explicit --wp/--slug was given and matched nothing — never silently
    # fall back to "the only open one", even when there's exactly one.
    # Falling back here would close/note-file the WRONG session under the
    # operator's own explicit (but mistyped/stale) --wp, defeating the
    # entire point of this fix.
    echo "session-guard: ни один открытый семафор агента '$agent' не совпал с wp='$want_wp' slug='$want_slug':" >&2
    while IFS= read -r cand; do
      [ -z "$cand" ] && continue
      cand_wp=$(grep "^wp: " "$cand" | cut -d' ' -f2- || true)
      cand_slug=$(grep "^slug: " "$cand" | cut -d' ' -f2- || true)
      echo "  $(basename "$cand")  wp=$cand_wp  slug=$cand_slug" >&2
    done <<< "$candidates"
    return 2
  fi

  count=$(echo "$candidates" | grep -c . || true)
  if [ "$count" -eq 1 ]; then
    echo "$candidates"
    return 0
  fi

  echo "session-guard: несколько открытых семафоров для агента '$agent' — укажи --wp/--slug:" >&2
  while IFS= read -r cand; do
    [ -z "$cand" ] && continue
    cand_wp=$(grep "^wp: " "$cand" | cut -d' ' -f2- || true)
    cand_slug=$(grep "^slug: " "$cand" | cut -d' ' -f2- || true)
    echo "  $(basename "$cand")  wp=$cand_wp  slug=$cand_slug" >&2
  done <<< "$candidates"
  return 2
}

# --- parse args ---
WP=""
TASK=""
FILES=""
SLUG=""
AGENT="${IWE_AGENT:-}"
HOUSEKEEPING=""
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --wp)     WP="$2"; shift 2 ;;
    --task)   TASK="$2"; shift 2 ;;
    --files)  FILES="$2"; shift 2 ;;
    --slug|--topic) SLUG="$2"; shift 2 ;;
    --agent)  AGENT="$2"; shift 2 ;;
    --housekeeping) HOUSEKEEPING="$2"; shift 2 ;;
    --since)  SINCE="$2"; shift 2 ;;
    --)       shift; POSITIONAL+=("$@"); break ;;
    -*)       shift ;;
    *)        POSITIONAL+=("$1"); shift ;;
  esac
done

if [ -z "$AGENT" ] && { [ "$CMD" = "open" ] || [ "$CMD" = "close" ]; }; then
  fail "--agent обязателен для open/close (или переменная IWE_AGENT)" 1
fi

# --- OPEN ---
if [ "$CMD" = "open" ]; then
  if [ -n "$HOUSEKEEPING" ]; then
    # Housekeeping session: no ORZ, no WP, one semaphore per (agent, reason).
    HK_FILE="$SESSION_DIR/${AGENT}-housekeeping-${HOUSEKEEPING}.open"
    HK_MAX_AGE=1800  # 30 minutes default TTL for housekeeping semaphores
    NOW_EPOCH=$(date +%s)
    if [ -f "$HK_FILE" ]; then
      HK_CREATED=$(grep "^created_at: " "$HK_FILE" | cut -d' ' -f2- || echo "")
      if [ -n "$HK_CREATED" ]; then
        HK_CREATED_EPOCH=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$HK_CREATED" +%s 2>/dev/null || date -d "$HK_CREATED" +%s 2>/dev/null || echo "")
        if [ -n "$HK_CREATED_EPOCH" ]; then
          HK_AGE=$(( NOW_EPOCH - HK_CREATED_EPOCH ))
          if [ "$HK_AGE" -gt "$HK_MAX_AGE" ]; then
            mv "$HK_FILE" "${HK_FILE}.stale"
            echo "WARNING: housekeeping semaphore '${HOUSEKEEPING}' stale (${HK_AGE}s), renamed to .stale" >&2
          else
            fail "open --housekeeping: уже есть активная housekeeping-сессия '${HOUSEKEEPING}' (возраст ${HK_AGE}s). Закрой её или дождись TTL ${HK_MAX_AGE}s" 1
          fi
        fi
      fi
    fi
    {
      echo "---"
      echo "agent: $AGENT"
      echo "housekeeping: $HOUSEKEEPING"
      # bug-2026-07-10 (Day Close): select_semaphore() only matches on `wp:`/`slug:`
      # lines. Without this, 2+ open housekeeping semaphores are permanently
      # ambiguous for note-file/close — --slug has nothing to match against.
      echo "slug: $HOUSEKEEPING"
      echo "created_at: $(now_iso)"
      echo "pid: $$"
      echo "---"
    } > "$HK_FILE"
    echo "Housekeeping OPEN: $HK_FILE (reason: $HOUSEKEEPING)"
    exit 0
  fi

  [ -z "$WP" ] && fail "--wp обязателен для open" 2

  # Auto-orphan stale semaphores from same agent (TTL 30 min).
  # WP-464: check EVERY open semaphore of this agent, not only the newest —
  # `head -1` used to leave older-but-still-stale siblings undetected whenever
  # a younger one existed for the same agent_id.
  while IFS= read -r STALE; do
    [ -z "$STALE" ] && continue
    [ -f "$STALE" ] || continue
    # GNU stat first: `stat -f %m` on GNU coreutils means --file-system mode
    # (ignores %m as an mtime format, prints a multi-line filesystem report
    # instead) — it exits 0 with garbage, so a BSD-first `||` order never
    # falls through to the working branch on Linux (found 2026-07-25).
    STALE_MTIME=$(stat -c %Y "$STALE" 2>/dev/null || stat -f %m "$STALE" 2>/dev/null || echo "")
    [ -z "$STALE_MTIME" ] && continue
    STALE_AGE=$(( $(date +%s) - STALE_MTIME ))
    if [ "$STALE_AGE" -gt 1800 ]; then
      STALE_WP=$(grep "^wp: " "$STALE" | cut -d' ' -f2- || echo "unknown")
      mv "$STALE" "${STALE}.orphaned-${STALE_WP}"
      echo "WARNING: orphaned semaphore ($(basename "$STALE")) переименован (WP: $STALE_WP, возраст ${STALE_AGE}s)" >&2
    fi
  done < <(ls -t "$SESSION_DIR/${AGENT}"-*.open 2>/dev/null || true)

  SESSION_ID="${IWE_SESSION_ID:-$(date +%s)}"
  SEM_FILE="$SESSION_DIR/${AGENT}-${SESSION_ID}.open"
  ORZ_BASENAME="$(now_date)-${SLUG:-$WP}.md"
  ORZ_FILE="$ORZ_DIR/$ORZ_BASENAME"
  {
    echo "---"
    echo "agent: $AGENT"
    echo "wp: $WP"
    echo "task: ${TASK:-}"
    echo "slug: ${SLUG:-$WP}"
    echo "opened_at: $(now_iso)"
    echo "session_id: $SESSION_ID"
    echo "orz_file: $ORZ_BASENAME"
    echo "---"
    # initial --files CSV → append-log entries (git-root-relative expected from caller)
    if [ -n "${FILES:-}" ]; then
      IFS=',' read -ra INITIAL_FILES <<< "$FILES"
      for init_file in "${INITIAL_FILES[@]}"; do
        init_file="$(echo "$init_file" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [ -n "$init_file" ] && echo "file: $init_file"
      done
    fi
  } > "$SEM_FILE"
  # Pointer to active semaphore for PostToolUse hooks
  PTR_FILE="$SESSION_DIR/current-${AGENT}.ptr"
  echo "$SEM_FILE" > "$PTR_FILE"
  # ORZ scaffold (paths already computed above for the semaphore)
  if [ ! -f "$ORZ_FILE" ]; then
    cat > "$ORZ_FILE" <<EOF
---
date: $(now_date)
type: work
wp: ${WP}
duration_h: ~
agent: $(orz_agent_name "$AGENT")
artifacts: []
---

# Сессия $(now_date) — ${TASK:-$WP}

## Главный инсайт

## Контекст

## Достигнуто

| Артефакт | Описание |
|----------|----------|

## Ключевые решения

## Следующий шаг

EOF
    echo "ORZ scaffold создан: $ORZ_FILE"
  fi
  # open-sessions.log
  printf "%s | %s | %s | %s\n" "$(date '+%Y-%m-%d %H:%M')" "$WP" "$AGENT" "${TASK:-standalone}" >> "$OPEN_LOG"
  # agent status (fail-safe)
  if [ -x "$AGENT_STATUS_SCRIPT" ]; then
    "$AGENT_STATUS_SCRIPT" "$AGENT" working "${WP}: ${TASK:-standalone}" "${FILES:-}" 2>/dev/null || true
  fi
  echo "Session OPEN: $SEM_FILE (WP: $WP, agent: $AGENT, slug: ${SLUG:-$WP})"
  exit 0
fi

# --- helpers for ORZ validation ---
validate_orz() {
  local orz="$1"
  local agent="$2"
  local errors=0

  # 1. file exists
  if [ ! -f "$orz" ]; then
    echo "  ❌ ORZ-файл не найден: $orz" >&2
    return 1
  fi

  # 2. frontmatter keys
  local keys=("date:" "type:" "wp:" "duration_h:" "artifacts:" "agent:")
  for key in "${keys[@]}"; do
    if ! grep -qE "^${key}" "$orz"; then
      echo "  ❌ в frontmatter отсутствует ключ '$key'" >&2
      errors=$((errors + 1))
    fi
  done

  # 3. agent value
  local orz_agent
  orz_agent=$(grep -E "^agent:" "$orz" | sed 's/^agent: *//' | head -1 || true)
  if [ -n "$orz_agent" ]; then
    if [ "$orz_agent" != "$agent" ] && \
       ! { [ "$agent" = "kimi" ] && [ "$orz_agent" = "kimi-headless" ]; }; then
      echo "  ❌ agent в ORZ ('$orz_agent') не совпадает с агентом сессии ('$agent')" >&2
      errors=$((errors + 1))
    fi
  fi

  # 4. required sections
  local sections=("## Главный инсайт" "## Контекст" "## Достигнуто" "## Ключевые решения")
  for sec in "${sections[@]}"; do
    if ! grep -qF "$sec" "$orz"; then
      echo "  ❌ отсутствует секция '$sec'" >&2
      errors=$((errors + 1))
    fi
  done

  # 5. git tracked
  local rel
  rel="$(basename "$orz")"
  if ! git -C "$ORZ_DIR" ls-files --error-unmatch "$rel" >/dev/null 2>&1; then
    echo "  ❌ ORZ-файл не добавлен в git index (git add $rel)" >&2
    errors=$((errors + 1))
  fi

  return $errors
}

# --- CLOSE ---
if [ "$CMD" = "close" ]; then
  if [ -n "$HOUSEKEEPING" ]; then
    HK_FILE="$SESSION_DIR/${AGENT}-housekeeping-${HOUSEKEEPING}.open"
    if [ ! -f "$HK_FILE" ]; then
      fail "close --housekeeping: нет активной housekeeping-сессии '${HOUSEKEEPING}' для $AGENT" 3
    fi
    mv "$HK_FILE" "${HK_FILE}.closed" 2>/dev/null || rm -f "$HK_FILE"
    echo "Housekeeping CLOSE: ${HOUSEKEEPING} ✅"
    exit 0
  fi

  SEM_FILE=$(select_semaphore "$AGENT" "${WP:-}" "${SLUG:-}") && SG_RC=0 || SG_RC=$?
  [ "$SG_RC" -eq 2 ] && exit 3
  if [ "$SG_RC" -ne 0 ] || [ -z "$SEM_FILE" ] || [ ! -f "$SEM_FILE" ]; then
    fail "close без open: семафор не найден для $AGENT. Сначала session-guard.sh open --wp WP-N" 3
  fi
  WP_FROM_SEM=$(grep "^wp: " "$SEM_FILE" | cut -d' ' -f2- || true)
  WP="${WP:-$WP_FROM_SEM}"
  SLUG_FROM_SEM=$(grep "^slug: " "$SEM_FILE" | cut -d' ' -f2- || true)
  SLUG="${SLUG:-$SLUG_FROM_SEM}"
  TASK_FROM_SEM=$(grep "^task: " "$SEM_FILE" | cut -d' ' -f2- || true)
  TASK="${TASK:-$TASK_FROM_SEM}"
  SESSION_ID=$(grep "^session_id: " "$SEM_FILE" | cut -d' ' -f2- || echo "unknown")

  ORZ_BASENAME=$(grep "^orz_file: " "$SEM_FILE" | cut -d' ' -f2- || true)
  if [ -z "$ORZ_BASENAME" ]; then
    # Fallback для старых семафоров без поля orz_file
    OPENED_DATE=$(grep "^opened_at: " "$SEM_FILE" | cut -d' ' -f2- | cut -dT -f1 || true)
    ORZ_BASENAME="${OPENED_DATE:-$(now_date)}-${SLUG:-$WP}.md"
  fi
  ORZ_FILE="$ORZ_DIR/$ORZ_BASENAME"

  echo "Session CLOSE: проверяю ORZ $ORZ_FILE ..."
  if ! validate_orz "$ORZ_FILE" "$AGENT"; then
    fail "ORZ не прошёл валидацию. Исправь замечания выше и повтори close. Семафор остаётся активным." 5
  fi

  # agent status idle
  if [ -x "$AGENT_STATUS_SCRIPT" ]; then
    "$AGENT_STATUS_SCRIPT" "$AGENT" idle "" "" 2>/dev/null || true
  fi
  mv "$SEM_FILE" "$SEM_FILE.closed" 2>/dev/null || rm -f "$SEM_FILE"
  # Remove agent pointer
  rm -f "$SESSION_DIR/current-${AGENT}.ptr"
  echo "Session CLOSE: $WP → $ORZ_FILE ✅"

  # Warn if local commits are not pushed in repos touched by this session
  _warn_unpushed() {
    local repo="$1"
    local ahead
    ahead=$(git -C "$repo" rev-list --left-only --count HEAD...origin/main 2>/dev/null || echo "")
    if [ -n "$ahead" ] && [ "$ahead" -gt 0 ]; then
      echo "⚠️  $ahead незапушенных коммита в $(basename "$repo"). Выполни: git -C $repo push" >&2
    fi
  }
  # Always check the ORZ repo (governance repo, $GOV_REPO)
  _warn_unpushed "$ORZ_DIR"
  # Also check repos inferred from file: entries in the semaphore
  # Семафор к этому моменту уже переименован в .closed (выше) — читаем его;
  # fallback на исходное имя, если mv не сработал и файл был удалён.
  _sem_read="$SEM_FILE.closed"
  [ -f "$_sem_read" ] || _sem_read="$SEM_FILE"
  _seen_repos="$ORZ_DIR"
  while IFS= read -r _line; do
    [[ "$_line" =~ ^file:\ (.*) ]] || continue
    _repo=$(git -C "$IWE_ROOT/$(dirname "${BASH_REMATCH[1]}")" rev-parse --show-toplevel 2>/dev/null || true)
    [ -z "$_repo" ] && continue
    echo "$_seen_repos" | grep -qxF "$_repo" && continue
    _seen_repos="$_seen_repos
$_repo"
    _warn_unpushed "$_repo"
  done < <(cat "$_sem_read" 2>/dev/null || true)
  exit 0
fi

# --- NOTE-FILE (manual scope registration for Bash-created/deleted files) ---
if [ "$CMD" = "note-file" ]; then
  FILE_PATH="${POSITIONAL[0]:-}"
  [ -z "$FILE_PATH" ] && fail "note-file: missing path argument" 1
  NOTE_AGENT="${AGENT:-${IWE_AGENT:-claude-code}}"
  # WP-464: resolve via select_semaphore, not the singleton current-<agent>.ptr —
  # the ptr gets clobbered by a second concurrent `open` of the same agent
  # (bug-2026-07-04-ptr-collision), silently writing scope into the wrong session.
  SEM_FILE=$(select_semaphore "$NOTE_AGENT" "${WP:-}" "${SLUG:-}") && SG_RC=0 || SG_RC=$?
  [ "$SG_RC" -eq 2 ] && exit 1
  if [ "$SG_RC" -ne 0 ] || [ -z "$SEM_FILE" ] || [ ! -f "$SEM_FILE" ]; then
    fail "note-file: нет открытой сессии для агента '$NOTE_AGENT'. Для разовой операции открой housekeeping-сессию:\n  session-guard.sh open --housekeeping note-file --agent $NOTE_AGENT\n  session-guard.sh note-file <path> --agent $NOTE_AGENT\n  session-guard.sh close --housekeeping note-file --agent $NOTE_AGENT" 1
  fi
  # Normalize to git-root-relative (resolve symlinks/macOS /tmp vs /private/tmp)
  if [ -f "$FILE_PATH" ] || [ -d "$FILE_PATH" ]; then
    REPO_ROOT=$(git -C "$(dirname "$FILE_PATH")" rev-parse --show-toplevel 2>/dev/null || true)
  else
    REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
  fi
  if [ -n "$REPO_ROOT" ]; then
    REL_PATH=$(python3 -c "
import os,sys
f = os.path.realpath(sys.argv[2])
r = os.path.realpath(sys.argv[3])
print(os.path.relpath(f, r))
" -- "$FILE_PATH" "$REPO_ROOT")
  else
    REL_PATH="$FILE_PATH"
  fi
  [ -n "$REL_PATH" ] || fail "note-file: cannot determine relative path for '$FILE_PATH'" 1
  # Avoid duplicate consecutive entries
  LAST=$(tail -1 "$SEM_FILE" 2>/dev/null || true)
  if [ "$LAST" != "file: $REL_PATH" ]; then
    echo "file: $REL_PATH" >> "$SEM_FILE"
  fi
  echo "Noted in scope: $REL_PATH"
  exit 0
fi

# --- AUDIT ---
if [ "$CMD" = "audit" ]; then
  SINCE="${SINCE:-$(date -v-7d +%Y-%m-%d 2>/dev/null || date -d '7 days ago' +%Y-%m-%d)}"
  echo "=== Session Guard Audit (since $SINCE) ==="
  echo

  # 1. Активные семафоры (open без close)
  ACTIVE=$(find "$SESSION_DIR" -name "*.open" -type f 2>/dev/null)
  if [ -n "$ACTIVE" ]; then
    echo "⚠️ Активные сессии без close:"
    for f in $ACTIVE; do
      echo "  $(basename "$f")"
      sed 's/^/    /' "$f"
    done
    echo
  fi

  # 2. Сессии в open-sessions.log без ORZ-файла
  if [ -f "$OPEN_LOG" ]; then
    echo "Сессии в open-sessions.log без ORZ (после $SINCE):"
    awk -v since="$SINCE" '
      $1 >= since {
        wp=$3; gsub(/\|/,"",wp); print $1, wp
      }
    ' "$OPEN_LOG" | sort -u | while read -r dt wp; do
      ORZ=$(ls "$ORZ_DIR/$dt"-*"$wp"*.md 2>/dev/null | head -1 || true)
      if [ -z "$ORZ" ]; then
        echo "  $dt | $wp | ORZ отсутствует"
      fi
    done
    echo
  fi

  # 3. ORZ-файлы с невалидным frontmatter/секциями
  echo "ORZ-файлы с дефектами (после $SINCE):"
  find "$ORZ_DIR" -maxdepth 1 -name '*.md' -type f ! -name '00-index.md' -newermt "$SINCE" 2>/dev/null | while read -r orz; do
    tmp_errors=$(mktemp)
    orz_agent=$(grep -E "^agent:" "$orz" | sed 's/^agent: *//' | head -1 || true)
    if ! validate_orz "$orz" "${orz_agent:-unknown}" >"$tmp_errors" 2>&1 && [ -s "$tmp_errors" ]; then
      echo "  $(basename "$orz"):"
      sed 's/^/    /' "$tmp_errors"
    fi
    rm -f "$tmp_errors"
  done
  echo

  # 4. Untracked ORZ-файлы
  echo "Незакоммиченные ORZ-файлы:"
  git -C "$ORZ_DIR" status --short . 2>/dev/null | grep '^??' || echo "  (нет)"
  echo

  # 5. Stale семафоры старше 7 дней
  echo "Stale-семафоры старше 7 дней:"
  find "$SESSION_DIR" -name "*.open" -type f -mtime +7 2>/dev/null | while read -r f; do
    echo "  $(basename "$f")"
  done

  echo "=== Audit done ==="
  exit 0
fi

# --- GIT PRE-COMMIT CHECK ---
if [ "$CMD" = "pre-commit-check" ]; then
  ACTIVE=$(find "$SESSION_DIR" -name "*.open" -type f 2>/dev/null)
  if [ -z "$ACTIVE" ]; then
    cat >&2 <<'EOF'
🚫 SESSION-GUARD: коммит заблокирован.

Сессия не открыта по протоколу. Перед работой с файлами:
  bash ~/IWE/scripts/session-guard.sh open --wp WP-N --task "..."

Или, если это emergency-фикс без РП:
  GIT_OPTIONAL_LOCKS=0 git commit --no-verify -m "..."
EOF
    exit 4
  fi

  # Scope gate: every staged file must be touched in at least one active session.
  # Existing/new files: mtime > semaphore mtime.
  # Deleted files: path must be listed in at least one semaphore append-log.
  BLOCKED=0
  SEMAPHORE_MTIMES=()
  for sem in $ACTIVE; do
    SEMAPHORE_MTIMES+=("$(python3 -c "import sys,os; print(os.stat(sys.argv[2]).st_mtime_ns)" -- "$sem")")
  done

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    status="${line%%$'\t'*}"
    f="${line##*$'\t'}"
    status_char="${status:0:1}"

    if [ "$status_char" = "D" ]; then
      # Deleted file: check append-log across all active semaphores
      FOUND=0
      for sem in $ACTIVE; do
        if grep -qF "file: $f" "$sem"; then
          FOUND=1
          break
        fi
      done
      if [ "$FOUND" -eq 0 ]; then
        echo "🚫 BLOCK: $f удалён, но не числится в scope активных сессий" >&2
        BLOCKED=1
      fi
      continue
    fi

    if [ "$status_char" = "A" ] || [ "$status_char" = "R" ] || [ "$status_char" = "C" ]; then
      # New path (added/renamed/copied): no mtime bypass. A semaphore's mtime
      # is refreshed by every heartbeat, so a long-open session (bug-2026-07-07:
      # Kimi session open 42h) makes "mtime > semaphore" pass for ANY file any
      # OTHER agent happens to touch near commit time — mtime says nothing
      # about whether the file is actually this session's work. New paths must
      # be explicitly declared via note-file.
      FOUND=0
      for sem in $ACTIVE; do
        if grep -qF "file: $f" "$sem"; then
          FOUND=1
          break
        fi
      done
      if [ "$FOUND" -eq 0 ]; then
        echo "🚫 BLOCK: $f — новый файл вне scope активных сессий (нужен note-file, mtime не засчитывается)" >&2
        BLOCKED=1
      fi
      continue
    fi

    # Modified existing (already-tracked) file: mtime > semaphore, or explicit
    # note-file append-log entry (needed for files edited before `open` was
    # called — e.g. peer-conversation-skill sessions whose own meta.yaml/
    # report.md already document the session).
    FILE_MTIME=$(python3 -c "import sys,os; print(os.stat(sys.argv[2]).st_mtime_ns)" -- "$f")
    PASS=0
    for sem_mtime in "${SEMAPHORE_MTIMES[@]}"; do
      if [ "$FILE_MTIME" -gt "$sem_mtime" ]; then
        PASS=1
        break
      fi
    done
    if [ "$PASS" -eq 0 ]; then
      for sem in $ACTIVE; do
        if grep -qF "file: $f" "$sem"; then
          PASS=1
          break
        fi
      done
    fi
    if [ "$PASS" -eq 0 ]; then
      echo "🚫 BLOCK: $f не тронут в активных сессиях (mtime <= всех семафоров, нет в note-file)" >&2
      BLOCKED=1
    fi
  done < <(git -c core.quotepath=false diff --cached --name-status)

  if [ "$BLOCKED" -ne 0 ]; then
    echo "" >&2
    echo "Scope gate: staged-файлы вне текущих сессий." >&2
    echo "Если файл относится к сессии, добавь его вручную:" >&2
    echo "  bash ~/IWE/scripts/session-guard.sh note-file <path>" >&2
    echo "Или убери из staged:" >&2
    echo "  git restore --staged <file>" >&2
    # Emit AR.216 warn to rule-engine session warn log
    _SESSION_ID="${CLAUDE_SESSION_ID:-default}"
    _WARN_LOG="$HOME/.claude/state/session-${_SESSION_ID}-warns.jsonl"
    mkdir -p "$(dirname "$_WARN_LOG")" 2>/dev/null || true
    printf '{"ts":"%s","event":"pre-commit","rule":"AR.216","verdict":"warn","reason":"Scope gate: staged files outside active session — use git add <specific-path>"}\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$_WARN_LOG" 2>/dev/null || true
    exit 6
  fi

  exit 0
fi

fail "Unknown command: $CMD (use: open, close, audit, note-file, pre-commit-check)"
