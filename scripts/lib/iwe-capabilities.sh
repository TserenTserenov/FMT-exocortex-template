#!/usr/bin/env bash
# routing: utility  deterministic=true
# iwe-capabilities.sh (library) - what THIS installation has, kept as small files.
#
# WP-7 F267 stage 1 (peer-session 2026-10-27-01-wp7-f267-capability-descriptor),
# stage 2 (peer-session 2026-10-27-08-wp7-f267-stage2-backup-contract).
# One file per capability in $IWE_RUNTIME/state/capabilities/<name>:
#     status: <word>        present|absent for programs, the gateway and telegram,
#                           configured|off|undecided for "backup"
#     value: <text>         full program path or OS name; empty for everything else
#                           (the backup target is NOT written: the audit prints it)
#     checked_at: <UTC>
#     was: <word>           the last GOOD status (present|configured); kept while the
#                           status is bad, so "it was there and is gone" can be told
#                           from "it was never there"
#     alerted: true|false   a regression was delivered; reset when the status is good
# NEVER write a URL, a token or the value of any variable into these files:
# only presence, a program path, an OS name, a backup state word.
# Source AFTER .claude/lib/iwe-env-bootstrap.sh (needs IWE_RUNTIME, IWE_OS,
# WORKSPACE_DIR, IWE_ICLOUD_BACKUP_DIR). bash 3.2 safe (macOS /bin/bash).
#
# The probes run from scripts/iwe-capabilities.sh (setup, update, by hand), not
# from the bootstrap: 49 files source the bootstrap, hooks among them.

# shellcheck disable=SC2034  # read by the scripts that source this library
CAP_NAMES="os tar restic claude_cli gateway telegram backup"

cap_dir() {
    printf '%s\n' "${IWE_RUNTIME:-${WORKSPACE_DIR:-$HOME/IWE}/.iwe-runtime}/state/capabilities"
}

cap_program_for() {  # capability name -> program name, nothing for non-program capabilities
    case "$1" in
        tar) echo tar ;;
        restic) echo restic ;;
        claude_cli) echo claude ;;
        *) return 1 ;;
    esac
}

cap_status_good() {  # <status> -> 0 for a status that means "the thing works"
    case "$1" in present|configured) return 0 ;; *) return 1 ;; esac
}

cap_write() {  # <name> <status> [value] - atomic: a reader never sees half a file
    local name="$1" status="$2" value="${3:-}" dir tmp was alerted
    value="${value//$'\n'/ }"
    dir=$(cap_dir)
    # "was" and "alerted" survive every rewrite: a probe must not erase the memory
    # that the thing used to work. A good status refreshes "was" and clears "alerted".
    if cap_status_good "$status"; then
        was="$status"
        alerted=false
    else
        was=$(cap_field "$name" was 2>/dev/null) || was=""
        alerted=$(cap_field "$name" alerted 2>/dev/null) || alerted=""
        [ "$alerted" = true ] || alerted=false
    fi
    if ! mkdir -p "$dir" 2>/dev/null; then
        echo "iwe-capabilities: cannot create $dir (is IWE_RUNTIME writable?)" >&2
        return 1
    fi
    if ! tmp=$(mktemp "$dir/.$name.XXXXXX" 2>/dev/null); then
        echo "iwe-capabilities: cannot write into $dir" >&2
        return 1
    fi
    if ! printf 'status: %s\nvalue: %s\nchecked_at: %s\nwas: %s\nalerted: %s\n' \
        "$status" "$value" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$was" "$alerted" > "$tmp"; then
        rm -f "$tmp"
        echo "iwe-capabilities: cannot write $dir/$name" >&2
        return 1
    fi
    chmod 644 "$tmp" 2>/dev/null || true
    if ! mv -f "$tmp" "$dir/$name"; then
        rm -f "$tmp"
        echo "iwe-capabilities: cannot replace $dir/$name" >&2
        return 1
    fi
}

cap_field() {  # <name> <field> -> prints the field; return 1 when there is no state file
    local f
    f="$(cap_dir)/$1"
    [ -f "$f" ] || return 1
    sed -n "s/^$2: \{0,1\}//p" "$f" | head -1
}

cap_status() {  # <name> -> the status word, "unknown" when never probed
    local s
    s=$(cap_field "$1" status 2>/dev/null) || s=""
    printf '%s\n' "${s:-unknown}"
}

cap_find_program() {  # <program> -> absolute path of an executable, return 1 when none
    local prog="$1" p d
    p=$(command -v "$prog" 2>/dev/null || true)
    case "$p" in
        /*) if [ -x "$p" ] && [ ! -d "$p" ]; then printf '%s\n' "$p"; return 0; fi ;;
    esac
    # A scheduler hands jobs a short PATH (launchd: /usr/bin:/bin:/usr/sbin:/sbin). The
    # real defence is the full path stored at install/update time from an interactive
    # shell (cap_resolve); this search only widens the net. HOMEBREW_PREFIX is set by
    # `brew shellenv` in an interactive shell. CAP_EXTRA_DIRS (colon-separated) goes
    # first - a test seam.
    local IFS=:
    for d in ${CAP_EXTRA_DIRS:-} "${HOMEBREW_PREFIX:-/nonexistent}/bin" /usr/local/bin /usr/bin /bin /snap/bin \
             "${HOME:-/nonexistent}/.local/bin" "${HOME:-/nonexistent}/.npm-global/bin"; do
        [ -n "$d" ] || continue
        if [ -x "$d/$prog" ] && [ ! -d "$d/$prog" ]; then printf '%s\n' "$d/$prog"; return 0; fi
    done
    return 1
}

cap_probe_program() {  # <name>: find the program, record present+path or absent
    local name="$1" prog path
    prog=$(cap_program_for "$name") || return 2
    path=$(cap_find_program "$prog") || path=""
    if [ -n "$path" ]; then
        cap_write "$name" present "$path"
    else
        cap_write "$name" absent ""
    fi
}

cap_resolve() {  # <name> -> prints the program path; return 1 when absent.
    # The stored path is trusted only while it still runs. Otherwise ONE fresh search
    # (and the file is refreshed); a second miss means absent. Works even when the state
    # directory cannot be written: the answer comes from the search, the file is a cache.
    local name="$1" prog stored path
    prog=$(cap_program_for "$name") || return 2
    stored=$(cap_field "$name" value 2>/dev/null) || stored=""
    if [ "$(cap_status "$name")" = present ] && [ -n "$stored" ] && [ -x "$stored" ] && [ ! -d "$stored" ]; then
        printf '%s\n' "$stored"
        return 0
    fi
    path=$(cap_find_program "$prog") || path=""
    if [ -n "$path" ]; then
        cap_write "$name" present "$path" || true
        printf '%s\n' "$path"
        return 0
    fi
    cap_write "$name" absent "" || true
    return 1
}

cap_probe_os() {
    local os="${IWE_OS:-}"
    [ -n "$os" ] || case "$(uname -s 2>/dev/null)" in Darwin) os=macos ;; Linux) os=linux ;; *) os=unknown ;; esac
    cap_write os present "$os"
}

# Gateway: same resolution order as scripts/day-open-pipeline.sh (issue #877):
# explicit LLM_PROXY_URL, else PLATFORM_LLM_PROXY_URL from the environment or from
# the workspace .exocortex.env; the legacy placeholder older setup.sh wrote is
# ignored. Only the FACT is recorded - the address stays where it is.
cap_probe_gateway() {
    local url="${LLM_PROXY_URL:-}" envf helper
    if [ -z "$url" ]; then
        url="${PLATFORM_LLM_PROXY_URL:-}"
        envf="${WORKSPACE_DIR:-}/.exocortex.env"
        helper="$(dirname "${BASH_SOURCE[0]}")/common.sh"
        if [ -z "$url" ] && [ -f "$envf" ] && [ -f "$helper" ]; then
            # shellcheck source=common.sh
            url=$( . "$helper" && iwe_env_get "$envf" PLATFORM_LLM_PROXY_URL 2>/dev/null ) || url=""
        fi
        url="${url%/}"
        url="${url%/v1}"
        [ "$url" = "https://llm.aisystant.com" ] && url=""
    else
        # An explicit address is trimmed the same way: "/" or "/v1" alone leaves the
        # pipeline with an empty address, so the fact must be "absent" here too.
        url="${url%/}"
        url="${url%/v1}"
    fi
    if [ -n "$url" ]; then cap_write gateway present ""; else cap_write gateway absent ""; fi
}

# Backup state is derived from the sources that already exist - no new setting:
#   off         backup_enabled: false in params.yaml (the pilot said so)
#   configured  a target exists (backup_dir, or the macOS iCloud default), as before
#   undecided   no target and no explicit "off": no alarm, one message at install/update
# The key is matched exactly like week-close step 7 matches it. params.yaml.example
# ships backup_enabled: true, so "true" is a default, not a decision.
cap_backup_off() {
    grep -qE '^backup_enabled:[[:space:]]*false([[:space:]]*(#.*)?)?$' "${WORKSPACE_DIR:-}/params.yaml" 2>/dev/null
}

cap_probe_backup() {
    local target="${IWE_ICLOUD_BACKUP_DIR:-}"
    if cap_backup_off; then
        cap_write backup off ""
    elif [ -n "$target" ] || { cap_backup_engine_explicit && [ "$(cap_backup_engine)" = restic ]; }; then
        # An explicit restic engine is a decision on its own: restic writes to its fixed
        # protected store and needs no backup_dir. The target path stays out of the record (it can be any caller-exported value);
        # the audit prints it from the bootstrap it already sources.
        cap_write backup configured ""
    else
        cap_write backup undecided ""
    fi
}

# Telegram: the notifier (roles/synchronizer/scripts/notify.sh) reads the bot token
# and the chat id from ~/.config/aist/env. Only the FACT that both are set is
# recorded. CAP_NOTIFY_ENV is a test seam.
cap_probe_telegram() {
    local envf="${CAP_NOTIFY_ENV:-$HOME/.config/aist/env}" token="" chat=""
    if [ -f "$envf" ]; then
        # notify.sh sources this file, so `export NAME=value` is valid there as well.
        token=$(sed -n 's/^\(export[[:space:]]\{1,\}\)\{0,1\}TELEGRAM_BOT_TOKEN=//p' "$envf" | head -1)
        chat=$(sed -n 's/^\(export[[:space:]]\{1,\}\)\{0,1\}TELEGRAM_CHAT_ID=//p' "$envf" | head -1)
        token="${token//[\"\' ]/}"
        chat="${chat//[\"\' ]/}"
    fi
    if [ -n "$token" ] && [ -n "$chat" ]; then cap_write telegram present ""; else cap_write telegram absent ""; fi
}

# The backup contract: WHAT is copied is the engine's own business (tar archives the
# whole IWE directory, restic reads iwe-backup-sources.yaml), WHERE is backup_dir for
# tar and the fixed protected store for restic, WITH WHAT is backup_engine. The engine
# is read live from params.yaml, never cached: an edit takes effect on the next run.
cap_backup_engine_raw() {
    sed -n 's/^backup_engine:[[:space:]]*//p' "${WORKSPACE_DIR:-}/params.yaml" 2>/dev/null | head -1 \
        | sed -E 's/[[:space:]]+#.*$//; s/[[:space:]]+$//; s/^["'"'"']//; s/["'"'"']$//'
}

cap_backup_dir_param() {  # backup_dir exactly as the pilot wrote it in params.yaml, empty when unset
    sed -n 's/^backup_dir:[[:space:]]*//p' "${WORKSPACE_DIR:-}/params.yaml" 2>/dev/null | head -1 \
        | sed -E 's/[[:space:]]+#.*$//; s/[[:space:]]+$//; s/^["'"'"']//; s/["'"'"']$//'
}

cap_backup_engine_explicit() {  # 0 when the pilot set backup_engine in params.yaml
    [ -n "$(cap_backup_engine_raw)" ]
}

cap_backup_engine() {  # -> tar|restic|invalid; an unset key is tar, never a silent switch
    case "$(cap_backup_engine_raw)" in
        ""|tar) echo tar ;;
        restic) echo restic ;;
        *) echo invalid ;;
    esac
}

# A regression is "it worked, now it does not": was is good and the status is bad.
# Not a regression: never probed (was empty), "off" (the pilot said so), and a program
# the contract does not need (tar under restic, restic under tar). Prints
# "<name> <was> <status>" per line; --pending hides the ones already delivered.
cap_regressions() {  # [--pending]
    local only_pending=0 name was status alerted engine backup
    [ "${1:-}" = "--pending" ] && only_pending=1
    engine=$(cap_backup_engine)
    backup=$(cap_status backup)
    for name in $CAP_NAMES; do
        [ "$name" = os ] && continue
        was=$(cap_field "$name" was 2>/dev/null) || was=""
        cap_status_good "$was" || continue
        status=$(cap_status "$name")
        case "$status" in absent|undecided) ;; *) continue ;; esac
        case "$name" in
            tar) [ "$backup" = configured ] && [ "$engine" = tar ] || continue ;;
            restic) [ "$backup" = configured ] && [ "$engine" = restic ] || continue ;;
        esac
        alerted=$(cap_field "$name" alerted 2>/dev/null) || alerted=""
        [ "$only_pending" -eq 1 ] && [ "$alerted" = true ] && continue
        printf '%s %s %s\n' "$name" "$was" "$status"
    done
}

cap_mark_alerted() {  # <name> - a regression was delivered; atomic, keeps the other fields
    local name="$1" dir tmp seen
    dir=$(cap_dir)
    [ -f "$dir/$name" ] || return 1
    seen=$(cap_status "$name")
    tmp=$(mktemp "$dir/.$name.XXXXXX" 2>/dev/null) || return 1
    if ! sed 's/^alerted: .*/alerted: true/' "$dir/$name" > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    # A probe that ran meanwhile wrote a newer status: its file wins, we do not put the old
    # content back. (A short window remains between this check and the move; the effect is
    # one stale line in audit section 8, never a lost or repeated alarm.)
    if [ "$(cap_status "$name")" != "$seen" ]; then
        rm -f "$tmp"
        return 1
    fi
    chmod 644 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$dir/$name" || { rm -f "$tmp"; return 1; }
}

cap_probe_all() {  # returns 1 when any state file could not be written
    local rc=0
    cap_probe_os || rc=1
    cap_probe_program tar || rc=1
    cap_probe_program restic || rc=1
    cap_probe_program claude_cli || rc=1
    cap_probe_gateway || rc=1
    cap_probe_telegram || rc=1
    cap_probe_backup || rc=1
    return $rc
}

# One message, once: shown while the backup is undecided and no marker exists.
# The marker goes away when the backup becomes configured or off, so a later return
# to "undecided" speaks again.
cap_announce_backup_undecided() {
    local flag
    flag="$(dirname "$(cap_dir)")/backup-undecided.notified"
    case "$(cap_status backup)" in
        undecided)
            [ -e "$flag" ] && return 0
            echo "ℹ Бэкап IWE не настроен: в params.yaml нет backup_dir, а iCloud по умолчанию есть только на macOS."
            echo "  Это не ошибка, тревоги не будет. Включить: укажите backup_dir в params.yaml."
            echo "  Отказаться явно: backup_enabled: false. Это сообщение показывается один раз."
            : > "$flag" 2>/dev/null || true
            ;;
        configured|off)
            rm -f "$flag" 2>/dev/null || true
            ;;
    esac
    return 0
}
