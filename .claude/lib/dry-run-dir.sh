#!/bin/bash
# dry-run-dir.sh — the single resolver and safety check of the private dry-run
# state directory (issue #549 stage 2, issue #1447). Sourced by
# .claude/hooks/dry-run-gate.sh, .claude/hooks/protocol-stop-gate.sh,
# scripts/dry-run-begin.sh and scripts/dry-run-complete.sh — no component
# computes the path or judges its safety on its own, so they cannot look in
# different places or apply different criteria.
#
# Policy is the same on every platform: a directory that is not provably
# private is refused and the caller fails closed. Only the CRITERION of
# "private" depends on the platform:
# - Linux, macOS, Cygwin: owner uid + no group/other mode bits (0700).
# - Git Bash (uname -s MINGW*/MSYS*): chmod is a no-op there and the mode
#   always reads 755, so the 0700 check could never pass (issue #1447). The
#   directory is %LOCALAPPDATA%\iwe-dry-run and its NTFS ACL is checked with
#   %SYSTEMROOT%\System32\icacls.exe (absolute path, never from PATH): a
#   protected DACL whose only entries are Allow for the current user (full
#   access, inherited by files and subdirectories) and SYSTEM.
#
# API (sets globals, never exits — the caller decides how to fail):
#   dry_run_resolve_paths            → DRY_RUN_DIR, DRY_RUN_SENTINEL; rc 1 + DRY_RUN_ERR
#   dry_run_dir_check create|existing → rc 0 when private; rc 1 + DRY_RUN_ERR
#     create: a missing directory is created (on Git Bash with its ACL set up;
#     a directory we just created and could not secure is removed again).

DRY_RUN_ERR=""
DRY_RUN_DIR=""
DRY_RUN_SENTINEL=""

dry_run_is_windows() {
    case "$(uname -s 2>/dev/null)" in
        MINGW*|MSYS*) return 0 ;;
    esac
    return 1
}

dry_run_resolve_paths() {
    DRY_RUN_ERR=""
    DRY_RUN_DIR=""
    DRY_RUN_SENTINEL="/tmp/iwe-dry-run.flag"
    # Env overrides — explicit test mode only (Codex r1): the marker must be
    # inside the override directory; ambient IWE_DRY_RUN_DIR/IWE_DRY_RUN_SENTINEL
    # from a launch configuration do not move the production paths.
    if [ -n "${IWE_DRY_RUN_DIR:-}" ] && [ -f "$IWE_DRY_RUN_DIR/.iwe-dry-run-test-mode" ]; then
        DRY_RUN_DIR="$IWE_DRY_RUN_DIR"
        DRY_RUN_SENTINEL="${IWE_DRY_RUN_SENTINEL:-/tmp/iwe-dry-run.flag}"
        return 0
    fi
    if dry_run_is_windows; then
        local base
        if [ -z "${LOCALAPPDATA:-}" ]; then
            DRY_RUN_ERR="переменная LOCALAPPDATA не задана — каталог репетиции на Windows (Git Bash) находится в %LOCALAPPDATA%\\iwe-dry-run; запустите агента из обычной сессии пользователя Windows"
            return 1
        fi
        base=$(cygpath -u "$LOCALAPPDATA" 2>/dev/null) || base=""
        case "$base" in
            /*) ;;
            *)
                DRY_RUN_ERR="не удалось перевести LOCALAPPDATA ($LOCALAPPDATA) в путь Git Bash (cygpath -u)"
                return 1
                ;;
        esac
        DRY_RUN_DIR="${base%/}/iwe-dry-run"
        return 0
    fi
    DRY_RUN_DIR="/tmp/iwe-dry-run-$(id -u)"
}

_dry_run_stat() { # <uid|mode> <path>
    local fmt
    case "$(uname):$1" in
        Darwin:uid)  fmt="-f %u" ;;
        Darwin:mode) fmt="-f %Lp" ;;
        *:uid)       fmt="-c %u" ;;
        *)           fmt="-c %a" ;;
    esac
    # shellcheck disable=SC2086  # fmt is two words by design
    stat $fmt "$2" 2>/dev/null
}

dry_run_dir_check() { # <create|existing>
    local mode="${1:-existing}" dir="$DRY_RUN_DIR" created=0 owner perms
    DRY_RUN_ERR=""
    if [ -z "$dir" ]; then
        DRY_RUN_ERR="dry-run dir not resolved"
        return 1
    fi
    if [ -L "$dir" ]; then
        DRY_RUN_ERR="dry-run dir $dir is a symlink — refusing (possible attack)"
        return 1
    fi
    if [ ! -d "$dir" ]; then
        if [ "$mode" != "create" ]; then
            DRY_RUN_ERR="no dry-run dir $dir"
            return 1
        fi
        mkdir -m 0700 "$dir" 2>/dev/null || { DRY_RUN_ERR="cannot create $dir with 0700"; return 1; }
        created=1
    fi
    owner=$(_dry_run_stat uid "$dir")
    if [ "$owner" != "$(id -u)" ]; then
        DRY_RUN_ERR="dry-run dir $dir owned by uid ${owner:-unknown}, expected $(id -u)"
        [ "$created" = 1 ] && rmdir "$dir" 2>/dev/null
        return 1
    fi
    if dry_run_is_windows; then
        _dry_run_win_acl "$dir" "$created" && return 0
        # Only a directory this call created, and only while empty (rmdir
        # refuses otherwise); an existing directory is refused, never deleted.
        [ "$created" = 1 ] && rmdir "$dir" 2>/dev/null
        return 1
    fi
    perms=$(_dry_run_stat mode "$dir")
    case "$perms" in
        ''|*[!0-7]*)
            DRY_RUN_ERR="cannot stat permissions of $dir"
            return 1
            ;;
    esac
    if [ $(( 8#$perms & 077 )) -ne 0 ]; then
        DRY_RUN_ERR="dry-run dir $dir has group/other write permissions ($perms)"
        return 1
    fi
    return 0
}

# --- Git Bash (MINGW/MSYS) ACL check -------------------------------------

# One trimmed line of a tool's stderr for the error text.
_dry_run_trim() { tr -d '\r' < "$1" 2>/dev/null | tr '\n' ' ' | sed -e 's/  */ /g' -e 's/^ //' -e 's/ $//' | cut -c1-200; }

# Run a System32 tool by absolute path without MSYS argument conversion
# (otherwise /grant:r and similar switches are rewritten as POSIX paths).
_dry_run_win_exec() { # <errfile> <tool> <args...>
    local errf="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        MSYS2_ARG_CONV_EXCL='*' MSYS_NO_PATHCONV=1 timeout 30 "$@" 2>"$errf"
    else
        MSYS2_ARG_CONV_EXCL='*' MSYS_NO_PATHCONV=1 "$@" 2>"$errf"
    fi
}

_dry_run_manual_hint() { # <dir> <icacls path>
    printf 'Что сделать вручную: почините запуск %s (проверка без него не выполняется) или удалите каталог %s — dry-run-begin.sh создаст его заново с правильными правами.' "$2" "$1"
}

# The SDDL allow-list: protected DACL (P), Allow ACEs only, only for the
# current user SID and SYSTEM (SY / S-1-5-18), each with OICI inheritance and
# full access (FA); at least one such ACE for the user. Anything else —
# foreign or well-known SIDs (WD, BU, AU, BA, CO, AN, AC, S-1-15-2-*, another
# S-1-5-21-*), Deny or object ACEs, inherited (ID) or inherit-only (IO)
# entries, an unparsable string — fails.
_dry_run_sddl_private() { # <sddl> <user_sid>
    local sddl="$1" sid="$2" flags rest ace user_ok=0 type aflags rights og iog asid
    [[ "$sddl" =~ ^D:([A-Z]*)(\(.*\))$ ]] || return 1
    flags="${BASH_REMATCH[1]}"
    rest="${BASH_REMATCH[2]}"
    [[ "$flags" =~ ^(P|AI|AR)+$ ]] || return 1
    [[ "$flags" == *P* ]] || return 1
    while [ -n "$rest" ]; do
        [[ "$rest" =~ ^\(([^()]*)\)(.*)$ ]] || return 1
        ace="${BASH_REMATCH[1]}"
        rest="${BASH_REMATCH[2]}"
        [[ "$ace" =~ ^([^;]*)\;([^;]*)\;([^;]*)\;([^;]*)\;([^;]*)\;([^;]*)$ ]] || return 1
        type="${BASH_REMATCH[1]}"; aflags="${BASH_REMATCH[2]}"; rights="${BASH_REMATCH[3]}"
        og="${BASH_REMATCH[4]}"; iog="${BASH_REMATCH[5]}"; asid="${BASH_REMATCH[6]}"
        [ "$type" = "A" ] || return 1
        [ -z "$og" ] && [ -z "$iog" ] || return 1
        case "$aflags" in OICI|CIOI) ;; *) return 1 ;; esac
        [ "$rights" = "FA" ] || return 1
        if [ "$asid" = "$sid" ]; then
            user_ok=1
        elif [ "$asid" != "SY" ] && [ "$asid" != "S-1-5-18" ]; then
            return 1
        fi
    done
    [ "$user_ok" = 1 ]
}

_dry_run_win_acl() { # <dir> <created 0|1>
    local tmpd rc
    tmpd=$(mktemp -d 2>/dev/null) || { DRY_RUN_ERR="каталог репетиции $1: не удалось создать временный каталог для проверки прав"; return 1; }
    _dry_run_win_acl_in "$1" "$2" "$tmpd"
    rc=$?
    rm -rf "$tmpd" 2>/dev/null
    return $rc
}

_dry_run_win_acl_in() { # <dir> <created> <tmpdir>
    local dir="$1" created="$2" tmpd="$3" sysroot icacls whoami winpath out rc sids sid lines sddl
    if [ -z "${SYSTEMROOT:-}" ]; then
        DRY_RUN_ERR="каталог репетиции $dir: переменная SYSTEMROOT не задана — нельзя найти System32\\icacls.exe, права каталога не проверены"
        return 1
    fi
    sysroot=$(cygpath -u "$SYSTEMROOT" 2>/dev/null) || sysroot=""
    case "$sysroot" in
        /*) ;;
        *) DRY_RUN_ERR="каталог репетиции $dir: не удалось перевести SYSTEMROOT ($SYSTEMROOT) в путь Git Bash"; return 1 ;;
    esac
    icacls="${sysroot%/}/System32/icacls.exe"
    whoami="${sysroot%/}/System32/whoami.exe"
    if [ ! -f "$icacls" ] || [ ! -f "$whoami" ]; then
        DRY_RUN_ERR="каталог репетиции $dir: не найден $icacls или $whoami — права каталога не проверены. $(_dry_run_manual_hint "$dir" "$icacls")"
        return 1
    fi
    winpath=$(cygpath -w "$dir" 2>/dev/null) || winpath=""
    if [ -z "$winpath" ]; then
        DRY_RUN_ERR="каталог репетиции $dir: не удалось получить путь Windows (cygpath -w)"
        return 1
    fi

    out=$(_dry_run_win_exec "$tmpd/whoami.err" "$whoami" /user)
    rc=$?
    if [ "$rc" -ne 0 ]; then
        DRY_RUN_ERR="каталог репетиции $dir: whoami.exe /user завершился с кодом $rc: $(_dry_run_trim "$tmpd/whoami.err"). $(_dry_run_manual_hint "$dir" "$icacls")"
        return 1
    fi
    sids=$(printf '%s\n' "$out" | tr -d '\r' | grep -oE 'S-1-5-21(-[0-9]+)+' | sort -u)
    if [ -z "$sids" ] || [ "$(printf '%s\n' "$sids" | wc -l | tr -d ' ')" != 1 ]; then
        DRY_RUN_ERR="каталог репетиции $dir: не удалось определить SID текущего пользователя из вывода whoami.exe /user"
        return 1
    fi
    sid="$sids"

    if [ "$created" = 1 ]; then
        _dry_run_win_exec "$tmpd/setup.err" "$icacls" "$winpath" /inheritance:r \
            /grant:r "*$sid:(OI)(CI)F" /grant:r "*S-1-5-18:(OI)(CI)F" >/dev/null
        rc=$?
        if [ "$rc" -ne 0 ]; then
            DRY_RUN_ERR="каталог репетиции $dir: icacls.exe не смог закрыть доступ (код $rc: $(_dry_run_trim "$tmpd/setup.err")). $(_dry_run_manual_hint "$dir" "$icacls")"
            return 1
        fi
    fi

    _dry_run_win_exec "$tmpd/save.err" "$icacls" "$winpath" /save "$(cygpath -w "$tmpd/acl.save" 2>/dev/null)" >/dev/null
    rc=$?
    if [ "$rc" -ne 0 ] || [ ! -s "$tmpd/acl.save" ]; then
        [ "$rc" -eq 124 ] && rc="124 (превышено время ожидания)"
        DRY_RUN_ERR="каталог репетиции $dir: icacls.exe /save не вернул права (код $rc: $(_dry_run_trim "$tmpd/save.err")). $(_dry_run_manual_hint "$dir" "$icacls")"
        return 1
    fi
    # icacls /save writes UTF-16LE: line 1 is the name, line 2 the DACL in SDDL.
    if command -v iconv >/dev/null 2>&1; then
        lines=$(iconv -f UTF-16LE -t UTF-8 "$tmpd/acl.save" 2>/dev/null) || lines=""
    elif command -v python3 >/dev/null 2>&1; then
        lines=$(python3 -c 'import sys; sys.stdout.write(open(sys.argv[1], "rb").read().decode("utf-16-le"))' "$tmpd/acl.save" 2>/dev/null) || lines=""
    else
        lines=""
    fi
    lines=$(printf '%s\n' "$lines" | sed -e 's/^\xEF\xBB\xBF//' | tr -d '\r' | sed '/^[[:space:]]*$/d')
    sddl=""
    if [ "$(printf '%s\n' "$lines" | wc -l | tr -d ' ')" = 2 ]; then
        sddl=$(printf '%s\n' "$lines" | sed -n '2p')
    fi
    if [ -z "$sddl" ] || ! _dry_run_sddl_private "$sddl" "$sid"; then
        DRY_RUN_ERR="каталог репетиции $dir: права доступа не закрыты для других пользователей (ожидается защищённый список только из текущего пользователя $sid и SYSTEM; получено: ${sddl:-нечитаемый вывод icacls /save}). Удалите каталог $dir — dry-run-begin.sh создаст его заново с правильными правами."
        return 1
    fi
    return 0
}
