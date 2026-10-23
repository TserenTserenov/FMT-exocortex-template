#!/bin/bash
# Shared cron-fallback helpers for roles/{synchronizer,strategist,extractor}/install.sh.
#
# issue #454: on a Linux host without a usable systemd --user session bus (WSL2
# without systemd, most Docker containers, some headless servers) the Linux
# branch of every role's install.sh wrote systemd user units unconditionally —
# `systemctl --user enable --now` then failed, and there was no other way to
# get a running scheduler, even though `iwe_scheduler_state()`
# (scripts/lib/common.sh) already knows how to recognise a hand-rolled crontab
# entry. This fills that gap: a real installer for the path the detector
# already understood.

# iwe_systemd_user_bus_ok — same functional probe iwe_scheduler_state() uses:
# a live "list-timers" call, not just `command -v systemctl`. The binary can be
# on PATH while the session bus is gone ("Failed to connect to bus"), and that
# case must fall through to cron, not attempt a systemd install that will fail.
iwe_systemd_user_bus_ok() {
  systemctl --user list-timers --no-legend >/dev/null 2>&1
}

# iwe_timer_to_cron_lines TIMER_FILE COMMAND
# Reads OnCalendar= lines from a systemd .timer unit and prints one cron line
# per entry, running COMMAND on that schedule. Only the two calendar forms
# this template's timer files actually use are handled — a general systemd
# calendar-spec parser is unwarranted for 3 known unit files:
#   "*-*-* H:MM:SS" or "*-*-* HH:MM:SS"       -> "MM HH * * *"
#   "<Dow> *-*-* H:MM:SS" or "HH:MM:SS"       -> "MM HH * * <cron-dow>"
# Interval-based timers have no OnCalendar; callers with that shape supply
# their own literal cron schedule rather than asking this parser to guess.
iwe_timer_to_cron_lines() {
  local timer_file="$1" cmd="$2"
  local line spec dow_num hh mm hour minute cron_line
  local cron_lines=()
  [ -f "$timer_file" ] || { echo "ERROR: timer не найден: $timer_file" >&2; return 1; }
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in OnCalendar=*) spec=${line#OnCalendar=} ;; *) continue ;; esac
    if [[ "$spec" =~ ^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)\ \*-\*-\*\ ([0-9]{1,2}):([0-9]{2}):00$ ]]; then
      case "${BASH_REMATCH[1]}" in
        Sun) dow_num=0 ;; Mon) dow_num=1 ;; Tue) dow_num=2 ;; Wed) dow_num=3 ;;
        Thu) dow_num=4 ;; Fri) dow_num=5 ;; Sat) dow_num=6 ;;
      esac
      hh="${BASH_REMATCH[2]}"; mm="${BASH_REMATCH[3]}"
      hour=$((10#$hh)); minute=$((10#$mm))
      [ "$hour" -le 23 ] && [ "$minute" -le 59 ] || {
        echo "ERROR: недопустимое OnCalendar='$spec' в $timer_file" >&2; return 1;
      }
      printf -v cron_line '%s %s * * %s %s' "$minute" "$hour" "$dow_num" "$cmd"
      cron_lines+=("$cron_line")
    elif [[ "$spec" =~ ^\*-\*-\*\ ([0-9]{1,2}):([0-9]{2}):00$ ]]; then
      hh="${BASH_REMATCH[1]}"; mm="${BASH_REMATCH[2]}"
      hour=$((10#$hh)); minute=$((10#$mm))
      [ "$hour" -le 23 ] && [ "$minute" -le 59 ] || {
        echo "ERROR: недопустимое OnCalendar='$spec' в $timer_file" >&2; return 1;
      }
      printf -v cron_line '%s %s * * *  %s' "$minute" "$hour" "$cmd"
      cron_lines+=("$cron_line")
    else
      echo "ERROR: iwe_timer_to_cron_lines не понял OnCalendar='$spec' в $timer_file" >&2
      return 1
    fi
  done < "$timer_file"
  [ "${#cron_lines[@]}" -gt 0 ] || {
    echo "ERROR: нет OnCalendar в $timer_file" >&2; return 1;
  }
  printf '%s\n' "${cron_lines[@]}"
}

# iwe_cron_env_prefix — env-var assignments to prepend to a cron command line.
# systemd units set HOME/IWE_TEMPLATE/IWE_WORKSPACE/IWE_RUNTIME/PATH explicitly
# via `Environment=` (see roles/*/scripts/systemd/*.service); crontab jobs run
# with a near-empty environment and would otherwise fail the same way a bare
# shell without `source ~/.iwe-paths` does. Prefixing each command (rather than
# writing bare `VAR=` lines into the crontab) keeps every role's block
# self-contained regardless of install order.
iwe_cron_env_prefix() {
  printf 'HOME=%q IWE_TEMPLATE=%q IWE_WORKSPACE=%q IWE_RUNTIME=%q IWE_GOVERNANCE_REPO=%q PATH=%q' \
    "$HOME" "${IWE_TEMPLATE:-$HOME/IWE/FMT-exocortex-template}" "${IWE_WORKSPACE:-$HOME/IWE}" \
    "${IWE_RUNTIME:-$HOME/IWE/.iwe-runtime}" "${IWE_GOVERNANCE_REPO:-DS-strategy}" \
    "/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin"
}

# iwe_install_cron_fallback SENTINEL LINE...
# Idempotently replaces a marked block in the current user's crontab (re-running
# setup.sh updates the block instead of duplicating entries). SENTINEL must be
# unique per role so the three installers don't clobber each other's lines.
iwe_install_cron_fallback() {
  # A container built without the cron package (common on minimal Docker
  # bases — exactly the host class issue #454 targets) has no `crontab`
  # binary at all. Without this check the caller's `set -e` turns that into a
  # bare "crontab: command not found" and aborts install.sh with no hint what
  # to do, unlike every other branch in these scripts.
  if ! command -v crontab >/dev/null 2>&1; then
    echo "ERROR: crontab недоступен — установите пакет cron (apt install cron / apk add cron / dnf install cronie) и повторите установку" >&2
    return 1
  fi

  local sentinel="$1"; shift
  [ "$#" -gt 0 ] || { echo "ERROR: пустое cron-расписание для $sentinel" >&2; return 1; }
  local line
  for line in "$@"; do
    [ -n "$line" ] || { echo "ERROR: пустая cron-строка для $sentinel" >&2; return 1; }
  done
  local begin="# BEGIN IWE-$sentinel (cron fallback, issue #454)"
  local end="# END IWE-$sentinel"
  local current kept
  if ! current=$(crontab -l 2>&1); then
    case "$current" in
      *'no crontab for '*) current="" ;;
      *) echo "ERROR: не удалось прочитать crontab; расписание не изменено" >&2; return 1 ;;
    esac
  fi
  if ! printf '%s\n' "$current" | awk -v b="$begin" -v e="$end" '
    $0==b { if (inside || seen) bad=1; inside=1; seen++; next }
    $0==e { if (!inside) bad=1; inside=0; next }
    END { if (inside || bad) exit 1 }
  '; then
    echo "ERROR: повреждён или продублирован cron-блок $sentinel; расписание не изменено" >&2
    return 1
  fi
  kept="$(printf '%s\n' "$current" | awk -v b="$begin" -v e="$end" '
    $0==b {skip=1; next} $0==e {skip=0; next} skip!=1 {print}
  ')"
  {
    [ -n "$kept" ] && printf '%s\n' "$kept"
    echo "$begin"
    printf '%s\n' "$@"
    echo "$end"
  } | crontab -
}
