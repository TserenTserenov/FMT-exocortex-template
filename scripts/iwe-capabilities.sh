#!/usr/bin/env bash
# routing: utility  deterministic=true
# iwe-capabilities.sh - find out what this installation has and record it.
#
# WP-7 F267 stage 1. The facts live in $IWE_RUNTIME/state/capabilities/ (see
# scripts/lib/iwe-capabilities.sh for the file format and the rules).
#
# USAGE:
#   iwe-capabilities.sh probe [--announce]   probe everything and write the files;
#                                            --announce also says once that the backup
#                                            is undecided (install and update use it)
#   iwe-capabilities.sh show                 print what is recorded
#   iwe-capabilities.sh get <name>           "<status>[ <value>]"; exit 1 when never probed
#   iwe-capabilities.sh resolve <name>       full path of a program; exit 1 when absent
#   iwe-capabilities.sh regress [--notify]   list what worked before and is gone now
#                                            (re-resolves the programs first); --notify
#                                            sends ONE Telegram message and marks the
#                                            regressions delivered only after the notifier
#                                            confirmed delivery
#
# EXIT CODES: 0 ok, 1 not found / state not written / delivery not confirmed, 2 usage error
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../.claude/lib/iwe-env-bootstrap.sh" || exit 1
source "$SCRIPT_DIR/lib/iwe-capabilities.sh" || exit 1

usage() {
    sed -n '/^# USAGE:/,/^# EXIT CODES/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

cmd="${1:-}"
[ $# -gt 0 ] && shift
case "$cmd" in
    probe)
        announce=0
        for a in "$@"; do
            case "$a" in
                --announce) announce=1 ;;
                *) echo "iwe-capabilities: unknown argument: $a" >&2; usage; exit 2 ;;
            esac
        done
        cap_probe_all
        rc=$?
        [ "$announce" -eq 1 ] && cap_announce_backup_undecided
        exit "$rc"
        ;;
    show)
        printf '%-12s %-12s %-12s %s\n' NAME STATUS WAS VALUE
        for n in $CAP_NAMES; do
            printf '%-12s %-12s %-12s %s\n' "$n" "$(cap_status "$n")" "$(cap_field "$n" was 2>/dev/null || true)" \
                "$(cap_field "$n" value 2>/dev/null || true)"
        done
        ;;
    get)
        name="${1:-}"
        [ -n "$name" ] || { usage; exit 2; }
        case " $CAP_NAMES " in
            *" $name "*) ;;
            *) echo "iwe-capabilities: unknown capability: $name" >&2; exit 2 ;;
        esac
        s=$(cap_status "$name")
        [ "$s" = unknown ] && exit 1
        v=$(cap_field "$name" value 2>/dev/null || true)
        if [ -n "$v" ]; then echo "$s $v"; else echo "$s"; fi
        ;;
    resolve)
        name="${1:-}"
        [ -n "$name" ] || { usage; exit 2; }
        cap_resolve "$name"
        exit $?
        ;;
    regress)
        notify=0
        for a in "$@"; do
            case "$a" in
                --notify) notify=1 ;;
                *) echo "iwe-capabilities: unknown argument: $a" >&2; usage; exit 2 ;;
            esac
        done
        # Programs are re-resolved: the stored path first, one fresh search, a second miss
        # is "absent". The environment-dependent facts (gateway, telegram, backup) are NOT
        # re-probed here: a scheduler does not see the pilot's shell, and a missing
        # variable there would be a false alarm. Those are refreshed by probe (install,
        # update, by hand).
        for n in tar restic claude_cli; do
            [ "$(cap_status "$n")" = unknown ] || cap_resolve "$n" >/dev/null 2>&1 || true
        done
        pending=$(cap_regressions --pending)
        [ -n "$pending" ] || exit 0
        text="IWE: пропали возможности установки, которые раньше работали:"
        while read -r rname rwas rstatus; do
            [ -n "$rname" ] || continue
            echo "Пропало: $rname (было: $rwas, сейчас: $rstatus)"
            text="$text
- $rname"
        done <<< "$pending"
        [ "$notify" -eq 1 ] || exit 0
        if [ "$(cap_status telegram)" != present ]; then
            echo "Telegram не настроен: сообщение не отправлено, строки остаются в разделе 8 аудита."
            exit 0
        fi
        notify_sh="${CAP_NOTIFY_SH:-}"
        [ -n "$notify_sh" ] || notify_sh="${IWE_TEMPLATE:-}/roles/synchronizer/scripts/notify.sh"
        [ -f "$notify_sh" ] || notify_sh="$SCRIPT_DIR/../roles/synchronizer/scripts/notify.sh"
        if [ ! -f "$notify_sh" ]; then
            echo "iwe-capabilities: notify.sh not found; regressions stay pending" >&2
            exit 1
        fi
        if IWE_CAP_ALERT_TEXT="$text" bash "$notify_sh" --require-delivery capabilities regress >/dev/null 2>&1; then
            while read -r rname _; do
                [ -n "$rname" ] && cap_mark_alerted "$rname"
            done <<< "$pending"
        else
            echo "iwe-capabilities: delivery not confirmed; regressions stay pending" >&2
            exit 1
        fi
        ;;
    *)
        usage
        exit 2
        ;;
esac
