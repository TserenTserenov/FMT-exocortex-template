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
#
# EXIT CODES: 0 ok, 1 not found / state not written, 2 usage error
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
        printf '%-12s %-12s %s\n' NAME STATUS VALUE
        for n in $CAP_NAMES; do
            printf '%-12s %-12s %s\n' "$n" "$(cap_status "$n")" "$(cap_field "$n" value 2>/dev/null || true)"
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
    *)
        usage
        exit 2
        ;;
esac
