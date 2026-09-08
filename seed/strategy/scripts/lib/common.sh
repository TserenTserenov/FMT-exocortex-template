#!/usr/bin/env bash
# routing: library  deterministic=true
# lib/common.sh — shared shell helpers for IWE template scripts.
# Source, don't execute: `source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"`
#
# WP-5 Ubuntu-portability audit (2026-07-22, факт #5): 132 scripts, no shared
# library — IWE workspace root was resolved 5 different ways (IWE_WORKSPACE/
# IWE_ROOT/IWE_ROOT_ARG env vars, in varying precedence), governance-repo
# default duplicated with 4 variable names, and Telegram notification existed
# in 3 incompatible conventions (jq-built JSON vs hand-escaped, TG_TOKEN vs
# TELEGRAM_BOT_TOKEN directly) — some alert paths silently dropped messages
# because a caller used a convention no other caller tested. Pilot migration
# (this file) covers day-open-pipeline.sh + day-open-preflight.sh; the other
# ~40 call sites are backlog (WP-5 П4), not blind-swept in one pass.

# iwe_env_get FILE KEY — безопасно читает одно KEY=VALUE без source/eval.
# Поддерживаются только shell-подобные строки с простым ключом; внешние кавычки
# снимаются, команды и подстановки никогда не исполняются.
iwe_env_get() {
  local file="${1:-}" key="${2:-}" line value
  [ -f "$file" ] || return 1
  case "$key" in *[!A-Za-z0-9_]*|'') return 2 ;; esac
  line=$(grep -E "^[[:space:]]*${key}=" "$file" 2>/dev/null | head -1) || return 1
  [ -n "$line" ] || return 1
  value=${line#*=}
  value=${value#"${value%%[![:space:]]*}"}
  value=${value%"${value##*[![:space:]]}"}
  case "$value" in
    \"*\") value=${value#\"}; value=${value%\"} ;;
    \'*\') value=${value#\'}; value=${value%\'} ;;
  esac
  printf '%s\n' "$value"
}

# iwe_resolve_root [EXPLICIT] — canonical $IWE workspace root.
# Precedence: explicit arg > IWE_WORKSPACE > IWE_ROOT > workspace .exocortex.env
# > root derived from this installed library. No $HOME/IWE guess: a wrong root
# must fail loudly instead of letting a script succeed against another install.
# (IWE_ROOT_ARG, a third variant seen in some scripts, is intentionally NOT
# consulted here — callers that need a positional-arg override should pass
# it as EXPLICIT instead of adding a 4th env var to this precedence chain.)
iwe_resolve_root() {
  local explicit="${1:-}" library_root configured
  [ -n "$explicit" ] && { printf '%s\n' "$explicit"; return 0; }
  [ -n "${IWE_WORKSPACE:-}" ] && { printf '%s\n' "$IWE_WORKSPACE"; return 0; }
  [ -n "${IWE_ROOT:-}" ] && { printf '%s\n' "$IWE_ROOT"; return 0; }

  library_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." 2>/dev/null && pwd -P) || return 1
  if [ -f "$library_root/.exocortex.env" ]; then
    configured=$(iwe_env_get "$library_root/.exocortex.env" WORKSPACE_DIR 2>/dev/null || true)
    if [ -n "$configured" ] && [ -d "$configured" ]; then
      printf '%s\n' "$configured"
      return 0
    fi
  fi
  if [ -d "$library_root/FMT-exocortex-template" ] || [ -d "$library_root/.iwe-runtime" ]; then
    printf '%s\n' "$library_root"
    return 0
  fi
  echo "iwe_resolve_root: cannot determine workspace root; pass an explicit path or set IWE_WORKSPACE/IWE_ROOT" >&2
  return 1
}

# iwe_sha256 — sha256 of stdin, printed alone (no filename column).
# GNU-first (sha256sum, coreutils — on every Linux, absent on macOS by
# default) then shasum -a 256 (macOS default, also present on Linux only if
# perl's Digest::SHA happens to be installed — WP-5 Ubuntu-audit факт #4:
# 3 callers used bare `shasum -a 256` with no fallback, so a minimal Ubuntu
# install without it silently broke dedup/hash checks depending on it).
# lessons_stat_f_gnu_bsd_fallback_order.md: GNU-first is deliberate — the
# reverse order previously broke Linux checks the same way for `stat -f/-c`.
iwe_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

# iwe_file_mtime_date FILE — дата YYYY-MM-DD без смешивания stdout двух
# несовместимых stat-реализаций. GNU и BSD ветки выбираются явно (#300).
iwe_file_mtime_date() {
  local file="$1" epoch
  if stat --version >/dev/null 2>&1; then
    epoch=$(stat -c %Y "$file") || return 1
    date -d "@$epoch" +%Y-%m-%d
  else
    epoch=$(stat -f %m "$file") || return 1
    date -r "$epoch" +%Y-%m-%d
  fi
}

# iwe_resolve_governance_repo [EXPLICIT] — canonical governance-repo name.
iwe_resolve_governance_repo() {
  echo "${1:-${IWE_GOVERNANCE_REPO:-DS-strategy}}"
}

# iwe_sessions_dir — корень журналов сессий для ЧИТАТЕЛЕЙ (issue #545).
# Тот же контракт, что у писателя (session-guard.sh resolve_orz_sessions_dir,
# порт WP-526 Ф2): писатель переключается на MC-sessions после миграции, а
# читатели, жёстко смотрящие в legacy-путь, теряли перенос со вчера на
# мигрированной установке — и «не найдено» было неотличимо от «нечего
# находить».
#   1. IWE_SESSIONS_ROOT задан явно → он; каталог обязан существовать, иначе
#      return 1 (явный override — осознанный выбор, молчаливый обход скрыл бы
#      реальную расконфигурацию; решение о WARN/пропуске — у читателя).
#   2. Существует $IWE_ROOT/MC-sessions → он (мигрированная установка).
#   3. Иначе — legacy $IWE_ROOT/<governance-repo>/sessions. Имя репозитория:
#      GOVERNANCE_REPO (старший override, семантика day-close.sh) >
#      IWE_GOVERNANCE_REPO > DS-strategy.
# В отличие от писательского резолвера — без side-эффектов: ничего не создаёт
# и не падает, git-валидность не требует (читателю достаточно файлов).
iwe_sessions_dir() {
  local root="${IWE_ROOT:-${IWE_WORKSPACE:-}}"
  if [ -n "${IWE_SESSIONS_ROOT:-}" ]; then
    [ -d "$IWE_SESSIONS_ROOT" ] || return 1
    printf '%s\n' "$IWE_SESSIONS_ROOT"
    return 0
  fi
  # Пустой root (ни IWE_ROOT, ни IWE_WORKSPACE) — та же честная ошибка, что у
  # сломанного явного override: иначе функция вернула бы путь от корня
  # файловой системы, прочитанный как валидный.
  [ -n "$root" ] || return 1
  if [ -d "$root/MC-sessions" ]; then
    printf '%s\n' "$root/MC-sessions"
    return 0
  fi
  printf '%s\n' "$root/$(iwe_resolve_governance_repo "${GOVERNANCE_REPO:-}")/sessions"
}

# iwe_scheduler_active — is any IWE role scheduler (strategist/synchronizer/
# extractor) registered AND active with the launcher this OS actually uses?
# Returns 0 (active) / 1 (not active).
#
# WP-5 Ubuntu-audit факт #4: day-open-scaffold.sh checked `launchctl list`
# unconditionally — on Linux launchctl doesn't exist, so the check silently
# saw empty output and reported the scheduler as down (🔴) every single day
# even when the equivalent systemd --user timer was running fine. Two
# independent call sites had ALSO drifted from each other on macOS (one used
# the current per-role launchd labels post-issue-#261, the other still used
# the pre-#261 legacy iwe.scheduler/iwe.feedback labels that don't match any
# plist actually shipped) — this is now the single source of truth for both.
#
# issue #314 (third recurrence of the same class after #261/#292): the
# template ships no launcher-detection branch for cron, so a WSL install
# where the pilot hand-rolls a crontab entry (no launchd, no systemd --user
# timers there) always fell through to `return 1` → daily false Mode A +
# auto-incident even though the scheduler ran fine. Two independent signals
# added: (1) crontab, the launcher WSL installs actually use; (2) a generic
# evidence fallback — a scheduler log written in the last 2 days under
# ~/logs/synchronizer/, regardless of which launcher wrote it — so the next
# unenumerated launch mechanism doesn't reopen this same bug class again.
#
# issue #347 (fourth recurrence, this time not in detection but in interpretation):
# a plain boolean collapsed three very different situations into "not active" —
# never installed here, installed but stopped, and "the launcher query itself
# failed so nothing can be concluded". Callers painted all three red and opened a
# fresh incident file every morning on an install where the scheduler had simply
# never been deployed. iwe_scheduler_state() below reports which of the four it is;
# iwe_scheduler_active() stays as the boolean wrapper for callers that only ask
# "is it running right now".

# iwe_scheduler_deployment_evidence — did anyone ever install a scheduler here?
# Deployment artefacts outlive the scheduler being stopped, so their absence is
# what separates "never installed" from "installed and broken".
iwe_scheduler_deployment_evidence() {
  # find, not `ls A B C`: ls exits non-zero when ANY of the three globs matches
  # nothing, and roles install independently (synchronizer ships only
  # com.exocortex.scheduler.plist, extractor only its own). A partial install would
  # therefore read as "no evidence" and a real outage would silently downgrade to
  # not_deployed — disabling the very detection this function exists for.
  find "$HOME/Library/LaunchAgents" -maxdepth 1 \
    \( -name 'com.exocortex.*.plist' -o -name 'com.strategist.*.plist' -o -name 'com.extractor.*.plist' \) \
    2>/dev/null | grep -q . && return 0
  find "$HOME/.config/systemd/user" -maxdepth 1 -name 'iwe-*.timer' 2>/dev/null | grep -q . && return 0
  if command -v crontab >/dev/null 2>&1 \
    && crontab -l 2>/dev/null | grep -qE "scheduler\.sh|iwe-(exocortex-scheduler|strategist|extractor)"; then
    return 0
  fi
  # Any historical log, at any age — proof the scheduler ran here at least once.
  find "$HOME/logs/synchronizer" -maxdepth 1 -iname "*scheduler*.log" 2>/dev/null | grep -q . && return 0
  return 1
}

# iwe_scheduler_state — prints exactly one of:
#   active            — a unit is registered and live with this OS's launcher
#   deployed_inactive — artefacts exist, nothing live right now (a real outage)
#   not_deployed      — no unit, no crontab entry, no log history: never installed here
#   unknown           — a launcher is present but its query failed, so nothing is provable
iwe_scheduler_state() {
  local probe_failed=false launcher_out

  if command -v launchctl >/dev/null 2>&1; then
    if launcher_out=$(launchctl list 2>/dev/null); then
      printf '%s\n' "$launcher_out" \
        | grep -qE "com\.(exocortex\.scheduler|strategist\.morning|strategist\.weekreview|extractor\.inbox-check)" \
        && { echo active; return 0; }
    else
      probe_failed=true
    fi
  fi

  if command -v systemctl >/dev/null 2>&1; then
    # No --all: list-timers without it already restricts to loaded+active units.
    # --all would also match a disabled/stopped timer, reporting a dead scheduler
    # as 🟢. A failing call here is common and meaningful: inside WSL or a container
    # without a user session bus, `systemctl --user` errors out rather than
    # reporting "no timers" — that is `unknown`, not "not deployed".
    if launcher_out=$(systemctl --user list-timers --no-legend 2>/dev/null); then
      printf '%s\n' "$launcher_out" \
        | grep -qE "iwe-(exocortex-scheduler|strategist-morning|strategist-weekreview|extractor-inbox-check)\.timer" \
        && { echo active; return 0; }
    else
      probe_failed=true
    fi
  fi

  # `crontab -l` exits non-zero for the ordinary "no crontab for this user" case as
  # well as for a real failure, so a non-zero status here is not evidence of either.
  if command -v crontab >/dev/null 2>&1 \
    && crontab -l 2>/dev/null | grep -qE "scheduler\.sh|iwe-(exocortex-scheduler|strategist|extractor)"; then
    echo active
    return 0
  fi

  # Generic evidence fallback (issue #314): a scheduler log written in the last two
  # days counts as live regardless of which launcher wrote it.
  if find "$HOME/logs/synchronizer" -maxdepth 1 -iname "*scheduler*.log" -mtime -2 2>/dev/null | grep -q .; then
    echo active
    return 0
  fi

  # `unknown` is checked BEFORE deployment evidence, not after: on WSL the timer files
  # sit in ~/.config/systemd/user/ while `systemctl --user` cannot answer at all. With
  # the checks the other way round that host reads as deployed_inactive → red Mode A +
  # a fresh incident every morning, which is exactly the false alarm this split exists
  # to remove. A failed probe means "not provable", and that outranks any artefact.
  if [ "$probe_failed" = true ]; then
    echo unknown
    return 0
  fi

  if iwe_scheduler_deployment_evidence; then
    echo deployed_inactive
    return 0
  fi

  echo not_deployed
}

# Boolean wrapper: true only for `active`. Kept for callers that genuinely need a
# yes/no answer (day-open-smoke.sh); anything that reports status to a human should
# use iwe_scheduler_state() so "not deployed" and "cannot tell" stay distinguishable.
iwe_scheduler_active() {
  [ "$(iwe_scheduler_state)" = "active" ]
}

# tg_notify MESSAGE — best-effort Telegram alert via TELEGRAM_BOT_TOKEN/
# TELEGRAM_CHAT_ID. No-op, not an error, when either is unset — most callers
# run in contexts (CI, smoke-tests, fresh installs) that never configure them.
# jq-built payload (not hand-escaped JSON) so a message containing a quote or
# newline can't produce malformed JSON that silently drops the alert.
tg_notify() {
  local msg="$1"
  if [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ]; then
    local payload
    payload=$(jq -n --arg chat "$TELEGRAM_CHAT_ID" --arg text "$msg" \
      '{chat_id: $chat, text: $text, parse_mode: "Markdown"}')
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -H "Content-Type: application/json" -d "$payload" > /dev/null
  fi
}

# iwe_safe_pull [-C REPO] — git pull --rebase that refuses to silently DROP a
# local commit whose patch is already upstream under a different hash (the
# case a plain `git rebase` mishandles: same change, different SHA, dropped
# without warning). Returns non-zero instead of exiting the calling script —
# callers keep their own `|| abort "..."` / cleanup-trap flow.
#
# Folded in from the formerly-standalone scripts/safe-pull.sh (found with
# zero callers in the same audit, факт #5) rather than deleted: this exact
# failure mode is a live, open risk this pilot's own sessions hit twice on
# 2026-07-23 (see feedback_parallel_agents_shared_workdir_git_race.md), and
# several callers were still doing a naive `git pull --rebase`.
#
# Scope: fast-forward and "only local ahead" cases are handled fully. A true
# two-sided divergence with NO same-patch collision rebases automatically
# (no tty/confirmation gate — day-open-pipeline.sh runs unattended from two
# machines by design, and gating on tty would turn every ordinary divergence
# into a hard pipeline failure; the git-cherry pre-check above IS the safety
# gate, not a human glancing at the output). A collision (the actual unsafe
# case) always returns 2 without touching the branch, tty or not.
iwe_safe_pull() {
  local repo="."
  while [ $# -gt 0 ]; do
    case "$1" in
      -C) repo="$2"; shift 2 ;;
      *) echo "iwe_safe_pull: unknown argument: $1" >&2; return 1 ;;
    esac
  done

  ( set -eu
    cd "$repo"

    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      echo "iwe_safe_pull: not inside a git repository ($repo)" >&2
      exit 1
    fi

    branch=$(git rev-parse --abbrev-ref HEAD)
    if [ "$branch" = "HEAD" ]; then
      echo "iwe_safe_pull: detached HEAD; refusing to guess a branch" >&2
      exit 1
    fi

    if ! git diff --quiet --ignore-submodules || ! git diff --cached --quiet --ignore-submodules; then
      echo "iwe_safe_pull: working tree or index is dirty; commit or stash first" >&2
      exit 1
    fi

    upstream=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)
    if [ -z "$upstream" ]; then
      if git show-ref --verify --quiet refs/remotes/origin/main; then
        upstream=origin/main
      elif git show-ref --verify --quiet refs/remotes/origin/master; then
        upstream=origin/master
      else
        echo "iwe_safe_pull: no tracked upstream and no origin/main or origin/master" >&2
        exit 1
      fi
    fi

    remote=${upstream%%/*}
    git fetch --quiet "$remote"

    ahead=$(git rev-list --count "$upstream"..HEAD 2>/dev/null || echo 0)
    behind=$(git rev-list --count HEAD.."$upstream" 2>/dev/null || echo 0)

    if [ "$ahead" -eq 0 ] && [ "$behind" -eq 0 ]; then
      echo "iwe_safe_pull: already up to date with $upstream"
      exit 0
    fi

    if [ "$ahead" -eq 0 ] && [ "$behind" -gt 0 ]; then
      echo "iwe_safe_pull: only upstream ahead ($behind) — fast-forwarding"
      git merge --ff-only "$upstream"
      exit 0
    fi

    if [ "$behind" -eq 0 ] && [ "$ahead" -gt 0 ]; then
      echo "iwe_safe_pull: only local ahead ($ahead) — nothing to pull"
      exit 0
    fi

    # Diverged: both sides have commits.
    already_upstream=$(git cherry "$upstream" HEAD | grep -c '^-' || true)
    if [ "$already_upstream" -gt 0 ]; then
      echo "iwe_safe_pull: $already_upstream local commit(s) already have an equivalent patch in $upstream." >&2
      echo "  A plain rebase would DROP them. Review: git log --cherry-mark --oneline --right-only $upstream...HEAD" >&2
      exit 2
    fi

    orig_pids=()
    while IFS= read -r sha; do
      [ -n "$sha" ] || continue
      orig_pids+=("$(git diff-tree -p "$sha" | git patch-id --stable | awk '{print $1}')")
    done < <(git rev-list --reverse "$upstream"..HEAD)

    echo "iwe_safe_pull: diverged ($ahead local / $behind upstream). Rebasing $branch onto $upstream..."
    if ! git rebase "$upstream"; then
      echo "iwe_safe_pull: rebase stopped (conflict) — resolve manually or 'git rebase --abort'" >&2
      exit 3
    fi

    # Defense-in-depth: the pre-check above catches same-patch-different-hash
    # drops before they happen; this re-check catches any OTHER way the
    # rebase could have lost a commit (e.g. a mid-rebase --skip) rather than
    # trusting a clean `git rebase` exit code alone.
    new_pids=()
    while IFS= read -r sha; do
      [ -n "$sha" ] || continue
      new_pids+=("$(git diff-tree -p "$sha" | git patch-id --stable | awk '{print $1}')")
    done < <(git rev-list --reverse "$upstream"..HEAD)

    # Multiset diff, not membership: two distinct local commits can share a
    # patch-id (identical diff, different message) — a naive "does opid
    # exist anywhere in new_pids" membership check would mark both as
    # present after only one survived. `comm -23` on two sorted streams
    # treats each line occurrence separately, so a genuinely dropped
    # duplicate still shows up as one missing line.
    missing=$(comm -23 <(printf '%s\n' "${orig_pids[@]}" | sort) <(printf '%s\n' "${new_pids[@]}" | sort))
    if [ -n "$missing" ]; then
      echo "iwe_safe_pull: ERROR — local patch(es) lost during rebase:" >&2
      echo "$missing" | sed 's/^/  /' >&2
      echo "iwe_safe_pull: rebase dropped local commit(s). Recover: git rebase --abort, or inspect: git reflog $branch" >&2
      exit 4
    fi

    echo "iwe_safe_pull: rebase complete, ${#orig_pids[@]} local patch(es) verified preserved"
  )
}
