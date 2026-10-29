#!/bin/bash
# Session Open Gate (PreToolUse, WP-561, 16.10.2026)
#
# Проблема, которую решает: session-guard.sh's own header claims "mechanical
# enforcement: git pre-commit hook checks for an active semaphore" — but the
# live .git/hooks/pre-commit only runs syntax checks, never session-guard.sh.
# A short/trivial session (explicitly exempt from the full WP Gate Ritual per
# CLAUDE.md §2.1 — "тривиальный вопрос, исправление ≤15 мин") can escalate
# into an actual file edit and `git commit` with zero open semaphore at all:
# found live 16.10.2026, a question-only session committed+pushed a CLAUDE.md
# edit directly to the frozen canonical checkout with no session-guard.sh open
# anywhere in its lifetime — Quick Close then had nothing to close.
#
# What this gate does: the same proven git-commit detection this repo already
# uses (close-runner-gate.sh) — but checks for an open semaphore carrying both
# this session's harness_session_id AND a real `wp: WP-N` field. Missing →
# block, point at `session-guard.sh open --wp WP-N`; session-guard.sh's own
# freeze guard then tells the agent to use an isolated worktree, this gate
# does not re-implement that logic.
#
# Why `--wp` only, not any `--housekeeping` reason (pilot decision 16.10.2026,
# S-68 in STAGING.md): a free-text housekeeping reason isn't tracked anywhere
# as a real work product, so every edit must carry a real WP-N -- the one the
# work actually belongs to, or a new one per the WP Entry Filter (S-47).
#
# Sessions with no WP at all (pilot decision 29.10.2026, WP-7 Ф274, option
# "entry without commits"): reading, research and reversible local checks need
# no semaphore, this gate stays silent until commit/push. A commit needs a
# session opened on a real WP. An umbrella tech-debt WP is fine only for work
# that really is tech debt, never as a stub for unbound work -- a convention
# this gate cannot check. There is deliberately no separate "read-only" mode:
# a session without a WP binding is that mode.
#
# Exception, added 21.10.2026 (community report: day/week/month close
# rejected outright, with no WP to bind to -- they are not a numbered work
# product by design). ALLOWED_HOUSEKEEPING_REASONS below is a CLOSED,
# platform-defined list, not an open door: S-68 forbids an arbitrary
# `--housekeeping <anything>` from standing in for a real WP (that is exactly
# what the first version of this fix got wrong -- it accepted any reason at
# all, reverting S-68 wholesale; caught by adversarial review before merge).
# These four names are the operational protocols that open this binding
# themselves, from their own SKILL.md, not something a session can claim for
# an arbitrary unrelated commit.
ALLOWED_HOUSEKEEPING_REASONS='^(day-open|day-close|week-close|month-close|update-delivery)$'
# Scheduled runs of non-Claude agents, whole-value match: no trim, case-sensitive,
# so `sched-1 extra`, a trailing space or a tab do not pass (WP-7 Ф274).
SCHED_HOUSEKEEPING_REASON='sched-[A-Za-z0-9._-]+'
#
# What this gate does NOT do: it does not require the semaphore to live in the
# repo being committed to — the semaphore directory is session-scoped, not
# repo-scoped, matching the rest of this hook family. It does not block
# `git commit` run as a subprocess of another tool (process-runner.py etc.) —
# PreToolUse only observes the top-level Bash tool call, same limitation
# close-runner-gate.sh documents for the same reason.
#
# Контракт PreToolUse hook (Claude Code):
# - Stdin: JSON {"tool_name", "tool_input", "session_id", ...}
# - Exit 0 = allow; exit 2 = block (stderr = причина, показывается LLM).

set -uo pipefail

IWE_ROOT="${IWE_ROOT:-$HOME/IWE}"

INPUT=$(cat)
[ -z "$INPUT" ] && exit 0

TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
# Kimi names its shell tool "Shell" (~/.kimi/config.toml matcher); Claude uses "Bash".
case "$TOOL_NAME" in Bash|Shell) ;; *) exit 0 ;; esac

COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -n "$COMMAND" ] || exit 0

AGENT="${IWE_AGENT:-claude-code}"
SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
# Same fallback as close-runner-gate.sh (bug-2026-08-31): payload .session_id
# has come back empty while CLAUDE_CODE_SESSION_ID was present and correct.
# Claude only: a Kimi process started from a Claude shell inherits the variable,
# and it names a Claude session that no kimi-*.open semaphore can carry.
if [ "$AGENT" = "claude-code" ] && [ -z "$SESSION_ID" ] && [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
  SESSION_ID="$CLAUDE_CODE_SESSION_ID"
fi
# Non-Claude agents (Kimi: tool "Shell", own payload id that no semaphore
# records) -> agent-keyed mode: any open semaphore of this agent counts, since
# the session that opened it cannot be told apart. WP-561 Ф51 (27.10.2026) made
# this mode fail-open except for one proven incident shape; WP-7 Ф274
# (29.10.2026, pilot decision) closes it: no WP-bound, allowed or scheduled
# semaphore of the agent -> block, the same rule as for Claude.
AGENT_KEYED=0
if [ "$AGENT" != "claude-code" ]; then
  AGENT_KEYED=1
  SESSION_ID="agent-keyed"
fi
[ -n "$SESSION_ID" ] || exit 0
case "$SESSION_ID" in
  *[!A-Za-z0-9._-]*) exit 0 ;;
esac
SESSION_ID_SAFE="$SESSION_ID"

# Same hardened git-commit/push detection as close-runner-gate.sh (Ф74а) —
# reused verbatim, not reinvented, to inherit its evasion coverage.
NORMALIZED_COMMAND=$(printf '%s' "$COMMAND" | tr '\n' ';' | tr -s '[:space:]' ' ')
GIT_GLOBAL_FLAGS_RE='(-C [^ ]+|-c [^ ]+|--(git-dir|work-tree|namespace|exec-path)(=[^ ]+| [^ ]+)|--(literal-pathspecs|glob-pathspecs|noglob-pathspecs|icase-pathspecs|no-optional-locks|no-lazy-fetch|no-replace-objects|no-pager|paginate|bare)|-P)'
echo "$NORMALIZED_COMMAND" | grep -qE "(^|[;&|(]) *(([A-Za-z_][A-Za-z0-9_]*=[^ ]+ *)*)(command |builtin |exec )?git( $GIT_GLOBAL_FLAGS_RE)* (commit|push)( |$)" || exit 0

# The agent name goes into the semaphore globs below: `*` or `[...]` would match
# other agents' semaphores (a claude-code one with `wp:`) and let the commit
# through (WP-7 Ф274). Checked after commit detection, so it blocks nothing else.
case "$AGENT" in
  *[!A-Za-z0-9._-]*)
    echo "[session-open-gate] IWE_AGENT='$AGENT' содержит недопустимые символы (разрешены A-Z a-z 0-9 . _ -) — git commit/push заблокирован. Исправьте IWE_AGENT." >&2
    exit 2 ;;
esac

SESSION_DIR="$IWE_ROOT/.iwe-runtime/sessions"
SCHED_LOG="$IWE_ROOT/.iwe-runtime/session-open-gate-sched.log"
# -x (whole-line match), not a bare -F substring search (close-runner-gate.sh
# ПП-74б/31.08 already hit this exact defect: a shorter session_id that is a
# prefix of a longer one would otherwise match it as a substring).
if [ "$AGENT_KEYED" = 1 ]; then
  SEM_MATCHES=$(ls -d "$SESSION_DIR/${AGENT}"-*.open 2>/dev/null)
else
  SEM_MATCHES=$(grep -lxF "harness_session_id: $SESSION_ID" "$SESSION_DIR/${AGENT}"-*.open 2>/dev/null)
fi
# Semaphore files are named <agent>-<id>.open, so an agent name that is a prefix
# of another one (claude / claude-code, kimi / kimi-peer) globs foreign files too.
# The owner is the single `agent:` line, the same check session-guard.sh applies.
OWN_SEMS=()
while IFS= read -r sem_file; do
  [ -f "$sem_file" ] && [ ! -L "$sem_file" ] || continue
  [ "$(grep -c '^agent: ' "$sem_file" 2>/dev/null)" = 1 ] && grep -qxF "agent: $AGENT" "$sem_file" 2>/dev/null || continue
  OWN_SEMS+=("$sem_file")
done <<< "$SEM_MATCHES"

sem_housekeeping_reason() { # $1 = semaphore file -> first housekeeping reason, verbatim
  grep -E '^housekeeping: ' "$1" 2>/dev/null | head -1 | cut -d' ' -f2-
}

# ${arr[@]+...}: an empty array under `set -u` is an error in bash 3.2 (macOS /bin/bash).
for sem_file in ${OWN_SEMS[@]+"${OWN_SEMS[@]}"}; do
  grep -qE '^wp: *[^[:space:]]' "$sem_file" 2>/dev/null && exit 0
  HK_REASON=$(sem_housekeeping_reason "$sem_file")
  [ -n "$HK_REASON" ] && printf '%s' "$HK_REASON" | grep -qE "$ALLOWED_HOUSEKEEPING_REASONS" && exit 0
done

# Scheduled runs without a WP (`--housekeeping sched-<id>`, Kimi queue runner)
# are a launcher, not an agent's choice. The hook cannot tell a real queue id
# from a self-chosen `sched-research`: a self-certified loophole, accepted by
# the pilot; every pass is logged for the weekly review (docs/PLATFORM-COMPAT.md).
# Checked only after no WP-bound semaphore was found, so the log holds real sched passes.
if [ "$AGENT_KEYED" = 1 ]; then
  for sem_file in ${OWN_SEMS[@]+"${OWN_SEMS[@]}"}; do
    HK_REASON=$(sem_housekeeping_reason "$sem_file")
    printf '%s' "$HK_REASON" | grep -qxE "$SCHED_HOUSEKEEPING_REASON" || continue
    { mkdir -p "$(dirname "$SCHED_LOG")" && printf '%s agent=%s reason=%s\n' "$(command date -u +%Y-%m-%dT%H:%M:%SZ)" "$AGENT" "$HK_REASON" >> "$SCHED_LOG"; } 2>/dev/null \
      || echo "[session-open-gate] не удалось записать $SCHED_LOG — плановый запуск всё равно пропущен" >&2
    exit 0
  done
fi

# Opt-in skip for Windows / Git Bash (WP-7 Ф271, issue #1281). session-guard.sh
# cannot open a `--wp` semaphore there (no fcntl), so without a way out every
# commit is blocked although PLATFORM-COMPAT.md calls Git Bash "best-effort".
# The gate stays mandatory by default: the skip needs an explicit, dated key in
# $IWE_ROOT/params.yaml, works only where bash reports OSTYPE msys/cygwin, and
# every use is announced on stderr and logged. Any doubt (missing/duplicate/garbled
# key, impossible date, date in the past or more than 30 days ahead) keeps the gate on.
#   session_open_gate_skip_until: 2026-11-05   # optional trailing comment
# Platform is read from $OSTYPE, not from `uname`: uname is looked up through PATH,
# which holds user-writable directories, so a fake `uname` would turn the skip on
# under Linux/macOS with one command (found by the cold review of Ф271).
# Residual risks, accepted in the peer session (Kimi dissented on the first):
# (1) an agent that can write params.yaml can set or renew the key itself;
# (2) an `env` entry in settings.local.json can set OSTYPE for the next session.
# Visibility (warning with the end date, log) is the only control, see
# docs/PLATFORM-COMPAT.md.
SKIP_MAX_DAYS=30
SKIP_LOG="$IWE_ROOT/.iwe-runtime/session-open-gate-skip.log"

gate_day_num() { # $1 = offset in days from today -> YYYYMMDD; empty on failure
  local ts
  # printf %(..)T needs bash >= 4.2 (Git Bash has it); older bash falls back to date
  if ts=$(printf '%(%s)T' -1 2>/dev/null) && [ -n "$ts" ]; then
    printf '%(%Y%m%d)T' $((ts + $1 * 86400))
    return
  fi
  command date -d "$1 days" +%Y%m%d 2>/dev/null || command date -v+"$1"d +%Y%m%d 2>/dev/null
}

gate_is_calendar_date() { # $1 = YYYY-MM-DD, already shape-checked
  local y=${1:0:4} m=$((10#${1:5:2})) d=$((10#${1:8:2})) dim
  dim=(0 31 28 31 30 31 30 31 31 30 31 30 31)
  if [ $((10#$y % 4)) = 0 ] && { [ $((10#$y % 100)) != 0 ] || [ $((10#$y % 400)) = 0 ]; }; then dim[2]=29; fi
  [ "$m" -ge 1 ] && [ "$m" -le 12 ] && [ "$d" -ge 1 ] && [ "$d" -le "${dim[$m]}" ]
}

gate_skip_check() { # prints the end date and returns 0 only when the skip is valid today
  local params lines val today_num val_num max_num
  params="$IWE_ROOT/params.yaml"
  [ -f "$params" ] || return 1
  lines=$(tr -d '\r' < "$params" | grep -E '^session_open_gate_skip_until:')
  [ -n "$lines" ] || return 1
  case "${OSTYPE:-}" in
    msys*|cygwin*) ;;
    *) echo "[session-open-gate] session_open_gate_skip_until в params.yaml не действует на этой платформе (${OSTYPE:-?}): пропуск только для Git Bash" >&2; return 1 ;;
  esac
  [ "$(printf '%s\n' "$lines" | wc -l | tr -d ' ')" = 1 ] || { echo "[session-open-gate] ключ session_open_gate_skip_until повторён — пропуск не действует" >&2; return 1; }
  printf '%s' "$lines" | grep -qE '^session_open_gate_skip_until:[[:space:]]+[0-9]{4}-[0-9]{2}-[0-9]{2}([[:space:]]+#.*|[[:space:]]*)$' \
    || { echo "[session-open-gate] ключ session_open_gate_skip_until записан не как ГГГГ-ММ-ДД — пропуск не действует" >&2; return 1; }
  val=$(printf '%s' "$lines" | sed -E 's/^session_open_gate_skip_until:[[:space:]]+([0-9]{4}-[0-9]{2}-[0-9]{2}).*$/\1/')
  gate_is_calendar_date "$val" || { echo "[session-open-gate] session_open_gate_skip_until=$val не календарная дата — пропуск не действует" >&2; return 1; }
  today_num=$(gate_day_num 0)
  max_num=$(gate_day_num "$SKIP_MAX_DAYS")
  val_num="${val//-/}"
  case "$today_num$max_num" in *[!0-9]*|'') return 1 ;; esac
  if [ "${#today_num}" != 8 ] || [ "${#max_num}" != 8 ]; then return 1; fi
  if [ "$val_num" -lt "$today_num" ]; then echo "[session-open-gate] срок session_open_gate_skip_until=$val истёк — гейт снова обязателен" >&2; return 1; fi
  if [ "$val_num" -gt "$max_num" ]; then echo "[session-open-gate] session_open_gate_skip_until=$val дальше $SKIP_MAX_DAYS дней — пропуск не действует" >&2; return 1; fi
  printf '%s' "$val"
}

if SKIP_UNTIL=$(gate_skip_check); then
  echo "[session-open-gate] ВНИМАНИЕ: проверка сессии отключена по params.yaml (session_open_gate_skip_until=$SKIP_UNTIL), git commit/push пропущен без семафора. Ключ ставит человек; если ты его не ставил, удали строку. Сверяй params.yaml и .iwe-runtime/session-open-gate-skip.log." >&2
  # Best-effort audit: a failed write must not change the decision.
  # uname_s comes from the default system PATH (command -p), not from the user's PATH
  # or from $OSTYPE: an `env` entry can fake OSTYPE, so the logged ostype alone proves
  # nothing; ostype=msys next to uname_s=Linux shows the faked platform.
  GATE_UNAME_S=$(command -p uname -s 2>/dev/null) || GATE_UNAME_S=UNKNOWN
  { mkdir -p "$(dirname "$SKIP_LOG")" && printf '%s agent=%s until=%s ostype=%s uname_s=%s\n' "$(command date -u +%Y-%m-%dT%H:%M:%SZ)" "$AGENT" "$SKIP_UNTIL" "${OSTYPE:-?}" "${GATE_UNAME_S:-UNKNOWN}" >> "$SKIP_LOG"; } 2>/dev/null \
    || echo "[session-open-gate] не удалось записать $SKIP_LOG — пропуск всё равно действует" >&2
  exit 0
fi

if [ "$AGENT_KEYED" = 1 ]; then
  echo "[session-open-gate] agent=$AGENT no open ${SESSION_DIR}/${AGENT}-*.open semaphore with exactly one matching agent: line and a wp:, an allowed housekeeping or a sched-<id> reason — blocking direct git commit/push" >&2
else
  echo "[session-open-gate] session=$SESSION_ID_SAFE no semaphore with both harness_session_id: $SESSION_ID and a wp: field or an allowed housekeeping reason (${SESSION_DIR}/${AGENT}-*.open) — blocking direct git commit/push" >&2
fi

cat >&2 <<EOF
🚫 Session Open Gate (WP-561/S-68): прямой git commit/push без привязки к РП заблокирован.

Сессия без РП работает только на чтение: читать, исследовать и проверять
локально можно, коммитить и пушить нельзя (WP-7 Ф274). Чтобы закоммитить,
откройте сессию на РП, к которому относится работа:

  bash scripts/session-guard.sh open --wp WP-N --task "..." --agent ${AGENT}

WP-N — РП, который уже обсуждался в этой сессии, или новый РП по фильтру
входа (S-47). Зонтичный РП техдолга — только для работы, которая и есть
техдолг, не как заглушка для работы без своего РП.

Исключения без своего номера: закрытый список операционных протоколов
(day-open, day-close, week-close, month-close, update-delivery) — их SKILL.md
открывают open --housekeeping REASON сами — и плановые запуски не-Claude
агентов (housekeeping sched-<id>, каждый пропуск пишется в журнал).

Канонический чекаут может быть заморожен (WP-520/WP-484) — session-guard.sh в
этом случае сам укажет, как перейти в изолированную копию (EnterWorktree /
git worktree add); следовать этой инструкции, не обходить её другим путём.
EOF
exit 2
