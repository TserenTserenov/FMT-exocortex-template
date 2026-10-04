#!/bin/bash
# update-sh-integrity: end-marker-required
# Exocortex Update — загрузка обновлений платформы из FMT-exocortex-template
#
# Использование:
#   bash update.sh              # Превью + применение (с подтверждением)
#   bash update.sh --check      # Только превью (без изменений)
#   bash update.sh --yes        # Применить без подтверждения
#   bash update.sh --dry-run    # Alias для --check
#
# Работает с template repos (created via "Use this template") —
# не требует общей git-истории с upstream.
#
set -e

# Named exit codes (issue #31): improve diagnostics for non-obvious failures.
EXIT_OK=0
EXIT_USAGE=1
EXIT_NETWORK=2
EXIT_RUNTIME=3   # build-runtime.sh failed — transaction left open (WP-529 F6)
EXIT_TAINTED=4   # peer-session 2026-08-21-09: grep-fallback manifest parsing ran
                 # (no Python), so file integrity was never verified by sha256 —
                 # only file names were compared. Overrides EXIT_OK specifically;
                 # a real operational error (network/conflict/runtime) still
                 # takes priority over this code, it never masks one.
EXIT_CONFLICT=49
EXIT_CANARY_FAILED=5   # issue #718: --check's registry-sync canary (see run_sync_canary)
                       # found the WP-Registry unreadable/unparseable for a real WP —
                       # a silently lost fix in that path would look identical to a
                       # healthy one without this check.
EXIT_GENERAL=1
GITHUB_API_AUTH_FAILURE=90
GITHUB_API_INVALID_TOKEN=91
GITHUB_API_UNSAFE_CURL_OPTIONS=92

trap 'echo "ОШИБКА: update.sh прервался на строке ${LINENO}: ${BASH_COMMAND}" >&2' ERR

VERSION="2.4.1"  # fix (WP-401): deprecated-file removal now checks is_protected_user_file() — a protected file (e.g. sessions/00-index.md) listed in deprecated_files by mistake could previously be deleted despite the "Не затрагиваются" report claiming otherwise; fix #229 (superseded by #965/#967: the owner: marker no longer decides; a memory file is refreshed when proven untouched and kept when edited); fix #228: hot-budget validator warns when memory/*.md horizon:hot lines exceed threshold
REPO="TserenTserenov/FMT-exocortex-template" # UPSTREAM-CONST: do not substitute
BRANCH="main"
# Delivery channel (WP-529 F7, pilot decision 2026-08-21, prompted by an
# external user's report): "release" (default) pins the delivery to the last
# published release tag — users must not receive unreleased, possibly red,
# main. IWE_UPDATE_CHANNEL=main is the ONLY way onto the moving branch
# (author/dev workflow) — a failed release lookup aborts fail-closed (#501),
# it never falls back to main automatically.
UPDATE_CHANNEL="${IWE_UPDATE_CHANNEL:-release}"
# WP-529 F26: an unknown channel used to fall through to the main branch
# silently — a typo (IWE_UPDATE_CHANNEL=realese) delivered unreleased main to a
# user who explicitly asked for the pinned release. Fail closed and name the
# accepted values instead of guessing which one was meant.
case "$UPDATE_CHANNEL" in
    release|main) ;;
    *)
        echo "✗ Неизвестный канал обновления: IWE_UPDATE_CHANNEL='$UPDATE_CHANNEL'" >&2
        echo "  Допустимые значения:" >&2
        echo "    release — последний опубликованный выпуск (по умолчанию)" >&2
        echo "    main    — движущаяся ветка разработки (только для автора)" >&2
        echo "  Обновление остановлено: неизвестное значение раньше молча уводило на main." >&2
        exit "$EXIT_USAGE"
        ;;
esac
RAW_BASE="https://raw.githubusercontent.com/$REPO/$BRANCH"
API_BASE="https://api.github.com/repos/$REPO"

# issue #863: release commit SHA, set by resolve_delivery_ref for rollback detection.
RELEASE_SHA=""

CHECK_ONLY=false
AUTO_YES=false
FAST_CHECK=false
# Stage B opt-ins (WP-7 F71, поведение settings-merge скорректировано issue
# #738): по умолчанию (без флагов, интерактивный запуск) оба выключены —
# конвейер только наблюдает (stage A) и ничего не пишет в пользовательские
# файлы. --yes включает settings-merge автоматически (см. ниже, после разбора
# аргументов) — доказанно аддитивное слияние не рискованнее остального,
# что --yes уже применяет без подтверждения.
APPLY_SETTINGS_MERGE=false
NO_SETTINGS_MERGE=false
REFRESH_STALE=false

# #533: governance compatibility entrypoints are upgraded as one ownership
# unit.  The updater may write them only after every target passes the same
# provenance/import-consumer preflight; no member is migrated independently.
AGENT_FAULT_LEGACY_SHIMS=(
    "scripts/iwe_checklist_memory.py"
    "scripts/sync_feedback_to_memory.py"
    "scripts/agent_fault_remind.py"
    "scripts/agent_fault_remind.sh"
)
AGENT_FAULT_SHIM_PREFLIGHT_PATHS=()
AGENT_FAULT_SHIM_TARGET_SNAPSHOTS=()
AGENT_FAULT_SHIM_GIT_READY=()
AGENT_FAULT_SHIM_GIT_PATHSPECS=()
AGENT_FAULT_SHIM_TRACKED_SNAPSHOTS=()
AGENT_FAULT_SHIM_STATUS_SNAPSHOTS=()

# Allow extra curl flags via env var (e.g. CURL_OPTS="--insecure" for Windows corporate firewall).
# --max-time 20: without it a stalled/slow connection hangs update.sh forever with no
# output (found 2026-07-22, WP-5 Ubuntu-audit — an interactive run produced zero output
# and had to be killed). CURL_OPTS overrides the whole string, so a caller who needs a
# different timeout can still set it explicitly.
# shellcheck disable=SC2086  # $CURL_BASE_OPTS intentionally unquoted (multi-token flag)
CURL_BASE_OPTS="${CURL_OPTS:---max-time 20}"

# Windows (msys/cygwin) schannel backend may fail with CRYPT_E_NO_REVOCATION_CHECK.
# Detect the best available SSL revocation flag without making a network call.
_CURL_SSL_OPT=""
case "${OSTYPE:-}" in
  msys*|cygwin*)
    if curl --help 2>&1 | grep -q "ssl-revoke-best-effort"; then
      _CURL_SSL_OPT="--ssl-revoke-best-effort"
    elif curl --help 2>&1 | grep -q "ssl-no-revoke"; then
      _CURL_SSL_OPT="--ssl-no-revoke"
    fi
    ;;
esac

# curl_failure_note RC ERRFILE — the cause of a failed curl call, as one line: its exit code
# plus the last line of its stderr (issue #980). `2>/dev/null` used to hide the cause, so
# every failure read as "check your internet" even when the network was fine and the write
# to a temp path failed. Callers send curl's stderr to ERRFILE (curl -sS keeps the error
# message and drops the progress meter) and print this note only when the call failed.
curl_failure_note() {
    local rc="$1" errf="$2" err_line=""
    if [ -s "$errf" ]; then
        # tr -d '\r': a native Windows curl ends its stderr lines with CRLF.
        err_line=$(tail -n 1 "$errf" | tr -d '\r' | cut -c1-200)
    fi
    printf 'curl код %s%s' "$rc" "${err_line:+; $err_line}"
}

# fetch_update_manifest URL DEST — download the update manifest (issue #943).
# curl's stderr used to go to /dev/null, so every failure looked like "check the
# internet"; a Windows user could not tell a timeout from a write error. Now: up to
# 3 attempts; each failed attempt prints curl's exit code, the HTTP status and the
# last stderr line. Only transient failures are retried (network exit codes, HTTP
# 5xx/429); a 4xx or a certificate error stops at once. After a write failure (curl
# exit 23, or success with an empty file) the next attempt writes through a shell
# redirect instead of curl -o: a labelled diagnostic experiment for "the file curl
# opens itself is blocked", it does not change TLS. The file is moved into place only
# when complete and JSON-shaped. On failure FETCH_MANIFEST_DIAG holds the last cause.
FETCH_MANIFEST_DIAG=""
fetch_update_manifest() {
    local url="$1" dest="$2"
    local part="$dest.part" errf="$dest.err"
    local max_attempts=3 attempt=1 mode="file" rc http err_line transient write_failure
    while [ "$attempt" -le "$max_attempts" ]; do
        rc=0; http="n/a"
        if [ "$mode" = "file" ]; then
            # shellcheck disable=SC2086  # CURL_BASE_OPTS/_CURL_SSL_OPT intentionally unquoted (multi-token flags)
            http=$(curl $CURL_BASE_OPTS $_CURL_SSL_OPT -sSfL -w '%{http_code}' -o "$part" "$url" 2>"$errf") || rc=$?
        else
            # shellcheck disable=SC2086
            curl $CURL_BASE_OPTS $_CURL_SSL_OPT -sSfL "$url" >"$part" 2>"$errf" || rc=$?
        fi
        err_line=$(tail -n 1 "$errf" 2>/dev/null | cut -c1-200)
        if [ "$rc" -eq 0 ] && [ ! -s "$part" ]; then
            err_line="curl завершился без ошибки, но файл пуст"
        elif [ "$rc" -eq 0 ] && [ "$(tr -d ' \t\r\n' < "$part" | head -c 1)" != "{" ]; then
            FETCH_MANIFEST_DIAG="ответ не похож на JSON (прокси или страница входа в сеть?), HTTP $http"
            echo "  ⚠ Попытка $attempt из $max_attempts: $FETCH_MANIFEST_DIAG"
            rm -f "$part" "$errf"
            return 1
        elif [ "$rc" -eq 0 ]; then
            if ! mv -f "$part" "$dest" 2>"$errf"; then
                FETCH_MANIFEST_DIAG="манифест скачан, но не записан на место: $(tail -n 1 "$errf" | cut -c1-200)"
                echo "  ⚠ Попытка $attempt из $max_attempts: $FETCH_MANIFEST_DIAG"
                rm -f "$part" "$errf"
                return 1
            fi
            rm -f "$errf"
            return 0
        fi
        FETCH_MANIFEST_DIAG="curl код $rc, HTTP $http, запись: $mode${err_line:+; $err_line}"
        echo "  ⚠ Попытка $attempt из $max_attempts: $FETCH_MANIFEST_DIAG"

        transient=false; write_failure=false
        case "$rc" in
            5|6|7|18|28|35|52|55|56) transient=true ;;
            # The redirect mode cannot report the HTTP status ("n/a"): a 22 there may be a 503
            # as well as a 404, so it is retried once more rather than given up.
            22) case "$http" in 5??|429|n/a) transient=true ;; esac ;;
            23) write_failure=true ;;
            0) write_failure=true ;;   # success with an empty file
        esac
        if $write_failure && [ "$mode" = "file" ]; then
            mode="stdout"
            echo "  … диагностика: повтор с записью через перенаправление вместо curl -o"
        elif $transient; then
            sleep "${IWE_FETCH_RETRY_SLEEP:-2}"
        else
            break
        fi
        attempt=$((attempt + 1))
    done
    rm -f "$part" "$errf"
    return 1
}

for arg in "$@"; do
    case "$arg" in
        --check|--dry-run)  CHECK_ONLY=true ;;
        --fast)             FAST_CHECK=true ;;
        --yes)              AUTO_YES=true ;;
        --apply-settings-merge) APPLY_SETTINGS_MERGE=true ;;
        --no-settings-merge)    NO_SETTINGS_MERGE=true ;;
        --refresh-stale)    REFRESH_STALE=true ;;
        --version)          echo "exocortex-update v$VERSION"; exit 0 ;;
        --help|-h)
            echo "Usage: update.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --check     Показать доступные обновления без применения"
            echo "  --fast      С --check: сравнить только версию манифеста (без скачивания 300+ файлов, issue #230)"
            echo "  --yes       Применить обновления без подтверждения (включает settings.json merge, см. --no-settings-merge)"
            echo "  --apply-settings-merge  Применить слияние settings.json отдельно от --yes (бэкап + пост-валидация; без флага и без --yes — только предпросмотр)"
            echo "  --no-settings-merge     С --yes: НЕ применять слияние settings.json (оставить только предпросмотр, старое поведение --yes)"
            echo "  --refresh-stale         author_mode: обновить файлы «отстал от шаблона, правок нет» (бэкап; блок при «неизвестно» > 0)"
            echo "  --version   Версия скрипта"
            echo "  --help      Эта справка"
            exit 0
            ;;
    esac
done

# issue #738: --apply-settings-merge оставался opt-in даже под --yes, поэтому
# автоматический `update.sh --yes` доставлял новые файлы хуков в .claude/hooks/,
# но не регистрировал их в settings.json — блокирующие защитные хуки
# (destructive-guard.sh, pull-on-touch.sh) молча оставались выключены.
# Слияние доказанно только аддитивное (settings-merge-preview.py: union по
# hooks/permissions, при конфликте побеждает значение пользователя, ничего
# существующего не перезаписывается и не удаляется) — не более рискованно,
# чем остальное, что --yes уже применяет без подтверждения. Явный
# --apply-settings-merge остаётся отдельной ручкой для запуска слияния без
# остального --yes-конвейера (например, повторный прогон после --check).
# --no-settings-merge — явный opt-out для тех, кто сознательно держал
# settings.json под ручным контролем и гонял --yes только ради остального
# конвейера (Codex, ревью этого фикса, ход 3): сохраняет старое поведение
# --yes точечно, без отказа от автоприменения остальных обновлений.
if [ "$AUTO_YES" = "true" ] && [ "$NO_SETTINGS_MERGE" != "true" ]; then
    APPLY_SETTINGS_MERGE=true
fi

# === Cross-platform sed -i ===
if sed --version >/dev/null 2>&1; then
    sed_inplace() { sed -i "$@"; }
else
    sed_inplace() { sed -i '' "$@"; }
fi

# issue #755: `A 2>/dev/null | cut ... || B` never ran B on a missing `shasum`
# (Alpine/busybox and similar minimal images have neither `shasum` nor
# `perl`) -- `cut`'s own exit code (0, even on empty stdin) is what `||`
# checked, not shasum's. hash_file() silently returned "" for every file, both
# sides of every comparison in this script came out equal ("" = ""), and the
# whole run finished EXIT=0 having verified nothing (754 files reported as
# "unchanged" on one real report, 100% false). Fail loudly here, once, up
# front, instead of at each of the dozens of call sites below.
if ! command -v shasum >/dev/null 2>&1 && ! command -v sha256sum >/dev/null 2>&1; then
    echo "ОШИБКА: ни shasum, ни sha256sum не найдены — проверка целостности файлов невозможна." >&2
    echo "  Установите coreutils (sha256sum) или perl (даёт shasum) и повторите." >&2
    exit "$EXIT_RUNTIME"
fi

# === Cross-platform hash ===
# KEEP IN SYNC with setup.sh — the same function body (setup.sh writes the first record of installed
# memory versions with it); setup/test-update-edge-cases.sh (T47) fails when the copies diverge.
hash_file() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | cut -d' ' -f1
    else
        sha256sum "$1" | cut -d' ' -f1
    fi
}

# === Cross-platform Python resolution (issue #402) ===
# On Windows Git Bash, `command -v python3` finds the Microsoft Store App
# Execution Alias stub (prints "Python was not found..." and exits non-zero)
# even when a real interpreter is installed and reachable as `python`
# (Windows python.org installer does not ship a `python3` shim). A presence
# check alone is not enough — probe that the candidate actually runs code.
PY_BIN=""
for _py_candidate in python3 python; do
    if command -v "$_py_candidate" >/dev/null 2>&1 && "$_py_candidate" -c 'pass' >/dev/null 2>&1; then
        PY_BIN="$_py_candidate"
        break
    fi
done
if [ -z "$PY_BIN" ] && command -v py >/dev/null 2>&1 && py -3 -c 'pass' >/dev/null 2>&1; then
    PY_BIN="py -3"
fi
unset _py_candidate
py_available() { [ -n "$PY_BIN" ]; }

# sed_escape_replacement STR — экранирует &, | и \ для безопасной подстановки
# STR как replacement в `sed s|...|STR|` (issue #269 verify-фикс). Без этого
# значение из .exocortex.env, содержащее & (sed: «весь мэтч») или | (наш
# разделитель) тихо портит подстановку вместо явной ошибки.
sed_escape_replacement() {
    printf '%s' "$1" | sed -e 's/[\&|]/\\&/g'
}

# substitute_claude_placeholders SRC DST — создаёт только workspace-копию.
# Template repo и его merge-base всегда остаются raw с {{PLACEHOLDER}} (#381).
substitute_claude_placeholders() {
    local src="$1" dst="$2"
    local env_file=""
    [ -f "$WORKSPACE_DIR/.exocortex.env" ] && env_file="$WORKSPACE_DIR/.exocortex.env"
    [ -z "$env_file" ] && [ -f "$SCRIPT_DIR/.exocortex.env" ] && env_file="$SCRIPT_DIR/.exocortex.env"

    cp "$src" "$dst"
    [ -z "$env_file" ] && return 0
    grep -qE '^\s*(source|eval|exec|\.|`|;|\$\()' "$env_file" 2>/dev/null && return 0

    local key value
    while IFS= read -r line; do
        case "$line" in \#*|"") continue ;; esac
        key="${line%%=*}"; value="${line#*=}"
        key=$(echo "$key" | tr -d '[:space:]')
        # issue #316-fix2: значения в .exocortex.env процитированы с #223 —
        # этот парсер читает файл строкой, не через `source`, поэтому кавычки
        # остаются частью значения буквально (не синтаксис, а данные) и
        # подставились бы в CLAUDE.md как есть, напр. {{TIMEZONE_DESC}} → "4:00 UTC".
        # Тот же паттерн снятия кавычек, что уже применён к этому файлу в другом
        # non-source парсере (см. ENV_WS/ENV_GOV ниже по файлу).
        value=$(echo "$value" | tr -d '"' | tr -d "'")
        [ -z "$key" ] && continue
        declare "SUBST_$key=$value"
    done < "$env_file"

    sed_inplace \
        -e "s|{{GITHUB_USER}}|$(sed_escape_replacement "${SUBST_GITHUB_USER:-}")|g" \
        -e "s|{{WORKSPACE_DIR}}|$(sed_escape_replacement "${SUBST_WORKSPACE_DIR:-$WORKSPACE_DIR}")|g" \
        -e "s|{{CLAUDE_PATH}}|$(sed_escape_replacement "${SUBST_CLAUDE_PATH:-}")|g" \
        -e "s|{{CLAUDE_PROJECT_SLUG}}|$(sed_escape_replacement "${SUBST_CLAUDE_PROJECT_SLUG:-$CLAUDE_PROJECT_SLUG}")|g" \
        -e "s|{{TIMEZONE_HOUR}}|$(sed_escape_replacement "${SUBST_TIMEZONE_HOUR:-}")|g" \
        -e "s|{{TIMEZONE_DESC}}|$(sed_escape_replacement "${SUBST_TIMEZONE_DESC:-}")|g" \
        -e "s|{{HOME_DIR}}|$(sed_escape_replacement "${SUBST_HOME_DIR:-$HOME}")|g" \
        -e "s|{{GOVERNANCE_REPO}}|$(sed_escape_replacement "${SUBST_GOVERNANCE_REPO:-}")|g" \
        -e "s|{{IWE_TEMPLATE}}|$(sed_escape_replacement "${SUBST_IWE_TEMPLATE:-$SCRIPT_DIR}")|g" \
        -e "s|{{IWE_RUNTIME}}|$(sed_escape_replacement "${SUBST_IWE_RUNTIME:-}")|g" \
        "$dst"
}

# restore_claude_placeholders SRC DST — миграция форков, которые старый setup
# загрязнил install-values. Обратная замена точечная: только значения из текущего
# .exocortex.env, поэтому пользовательская дельта вокруг них сохраняется.
restore_claude_placeholders() {
    local src="$1" dst="$2" env_file="" key value escaped
    [ -f "$WORKSPACE_DIR/.exocortex.env" ] && env_file="$WORKSPACE_DIR/.exocortex.env"
    [ -z "$env_file" ] && [ -f "$SCRIPT_DIR/.exocortex.env" ] && env_file="$SCRIPT_DIR/.exocortex.env"
    cp "$src" "$dst"
    [ -n "$env_file" ] || return 0
    for key in WORKSPACE_DIR HOME_DIR CLAUDE_PATH IWE_TEMPLATE IWE_RUNTIME; do
        value=$(grep -E "^${key}=" "$env_file" 2>/dev/null | head -1 | cut -d= -f2- | sed -E 's/^"//; s/"$//; s/^'"'"'//; s/'"'"'$//')
        [ -n "$value" ] || continue
        escaped=$(printf '%s' "$value" | sed -e 's/[\&|]/\\&/g')
        sed_inplace "s|${escaped}|{{${key}}}|g" "$dst"
    done
}

# detect_claude_silent_loss BASE PRE_MERGE_CURRENT MERGED — issue #555: a
# "clean" `git merge-file` exit (no <<<<<<< markers) can still make a pilot's
# customized line vanish from the result — reported live with a stale
# `.claude.md.base` where diff3 resolved a genuine conflict in the platform's
# favor without ever surfacing markers. This does not try to explain WHY
# (diff3's line-alignment heuristic is opaque and was not reliably
# reproducible in isolation) — it verifies the OUTCOME instead: every line
# the pilot added or changed relative to BASE must still be present
# somewhere in MERGED. Prints one warning line per lost line to stderr,
# echoes the lost-line count to stdout for the caller to branch on.
detect_claude_silent_loss() {
    local base="$1" before="$2" merged="$3" lost=0 line
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        grep -qF -- "$line" "$merged" || {
            echo "    ⚠ пользовательская строка пропала при слиянии без маркеров конфликта: $line" >&2
            lost=$((lost + 1))
        }
    done < <(LC_ALL=C comm -13 <(LC_ALL=C sort -u "$base") <(LC_ALL=C sort -u "$before"))
    echo "$lost"
}

# Protected user files (issue #154): once seeded, these hold user-authored content
# (permissions, memory, peer-session journal) — update.sh must never touch them again,
# neither overwrite (download loop) nor delete (deprecated-file cleanup). Single source
# of truth for both checks — a file listed here but not the other used to silently lose
# its delete-protection (bug found 2026-07-23, sessions/00-index.md deleted despite being
# in the "Не затрагиваются" report section — see WP-401 Ф6.1 write-up).
is_protected_user_file() {
    case "$1" in
        params.yaml|memory/MEMORY.md|.claude/settings.local.json|sessions/00-index.md) return 0 ;;
        *) return 1 ;;
    esac
}

# A template directory can also be a Git mirror of the canonical repository.
# In that role, removing a path that upstream still tracks makes the mirror dirty
# on every update and prevents its next fast-forward sync.  A conventional
# `upstream` remote is an explicit signal of that role, so leave deprecated-file
# cleanup to the canonical history instead of changing the mirror locally.
is_upstream_git_mirror() {
    git -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
    git -C "$SCRIPT_DIR" remote get-url upstream >/dev/null 2>&1
}

# Личные L4-конфиги в memory/: update.sh сеет их при ОТСУТСТВИИ (новая инсталляция),
# но НИКОГДА не перезаписывает поверх существующего — там персональные правки
# пользователя (напр. calendar_ids, slot-настройки в day-rhythm-config.yaml).
# Файл сам объявляет себя «L4 Personal. Override defaults from IWE Template».
# MEMORY.md защищён отдельной проверкой ниже. См. issue про clobber day-rhythm-config.
is_personal_config() {
    case "$1" in
        day-rhythm-config.yaml) return 0 ;;
        *) return 1 ;;
    esac
}

# is_author_mode — true когда WORKSPACE_DIR/params.yaml объявляет author_mode: true.
# Автор правит L1 напрямую до промоции в шаблон — расхождение хэша тут не staleness.
# См. inbox/bugs/bug-2026-07-11-update-sh-author-mode-blind-clobber.md.
is_author_mode() {
    local params_file="$WORKSPACE_DIR/params.yaml"
    [ -f "$params_file" ] || return 1
    grep -qE '^author_mode:[[:space:]]*true' "$params_file"
}

# === Memory policy (issues #965/#967) ===
# One rule decides every memory/* file the manifest ships, in Step 6 and in repair_pass() alike:
# a deployed copy the pilot has not changed is refreshed from the template after a backup; a
# changed copy, or one nothing proves unchanged, is left alone with one line that says why, a diff
# to compare and a ready command to accept the template version. The owner: marker in the copy no
# longer decides: an untouched owner:user file used to stay behind release after release (#965),
# and an edited owner:platform one used to be replaced (#967). The one-time owner:user ->
# owner:platform migration of the platform files old releases shipped as owner:user (#354/#384)
# is the same rule, not a second overwrite path: an untouched copy is replaced (its marker changes
# with the file), an edited one stays (navigation.md keeps the installation's addresses).
# MEMORY.md, personal configs and author_mode never reach the rule: the callers keep their own
# branches for them.
#
# "Not changed" is proven by any of:
#   (a) the record MEMORY_DEPLOYED_RECORD ($WORKSPACE_DIR/.memory-deployed.tsv) keeps, per file,
#       the hash of what setup.sh or update.sh last put into memory or found equal to the
#       template, and the deployed copy still has it. The record outlives a run: it proves a copy
#       that a broken-off run left behind (code 49 or Ctrl-C between Step 5 and Step 6) and a
#       copy several releases behind, which the clone's history does not know when update.sh
#       brought them (it never commits what it applies). A copy gets its line the moment it
#       becomes true - not at the end of the run - and never while it is kept: an edited copy
#       stays provably edited, and one the pilot turns back by hand is untouched again.
#   (b) OLD_HASH: the hash the file had in the template clone before this run replaced it (Step 2
#       records it in this run's temporary directory; only Step 6 has it). Before Step 5 it is also
#       copied into the record for every copy it proves, so a run broken off before Step 6 does not
#       take it along (remember_untouched_memory_before_apply).
#   (c) the shipped classifier says uptodate or stale: the copy equals a version in the history of
#       the clone's current branch.
# Each proof can also match the pilot's own edit made in the template clone (#963): an accepted
# residual risk, covered by the backup taken before every replacement, which the line and the
# closing summary name. An installation without the record gets it file by file, as its copies
# are refreshed or found equal to the template; until then (b) and (c) decide.
MEMORY_POLICY_SEEN=""      # paths decided in this run, each followed by a newline
MEMORY_REPLACED=()         # replaced in this run (report_memory_policy_summary)
MEMORY_KEPT=()             # left as they were although they differ from the template
MEMORY_RECORD_WARNED=false # the record could not be written: said once per run

# memory_record_put FILE KEY HASH — FILE holds one "key<TAB>sha256" line per memory file (bash
# 3.2 has no associative arrays); afterwards its line for KEY says HASH. FILE is rewritten through
# a temporary file next to it and mv, so a broken-off run leaves the old record or the new one,
# never half of one; lines that do not parse are dropped. A FILE that is a symbolic link, is no
# regular file or cannot be read is left as it is: rewriting it would drop every other file's line
# or replace the link. Returns non-zero, without a word, when HASH is not a sha256 or FILE is not
# written: the caller decides how to say so.
# KEEP IN SYNC with setup.sh — the same function body; setup/test-update-edge-cases.sh (T47) fails
# when the copies diverge.
memory_record_put() {
    local file="$1" key="$2" hash="$3" tmp line value tab
    tab=$(printf '\t')
    case "$hash" in *[!0-9a-f]*|'') return 1 ;; esac
    [ "${#hash}" -eq 64 ] || return 1
    if [ -L "$file" ] || { [ -e "$file" ] && { [ ! -f "$file" ] || [ ! -r "$file" ]; }; }; then
        return 1
    fi
    tmp=$(mktemp "$file.XXXXXX" 2>/dev/null) || return 1
    if [ -f "$file" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in *"$tab"*) ;; *) continue ;; esac
            value="${line##*"$tab"}"
            case "$value" in *[!0-9a-f]*|'') continue ;; esac
            [ "${#value}" -eq 64 ] || continue
            [ "${line%"$tab"*}" = "$key" ] || printf '%s\n' "$line"
        done < "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
    fi
    if printf '%s\t%s\n' "$key" "$hash" >> "$tmp" && mv -f "$tmp" "$file"; then
        return 0
    fi
    rm -f "$tmp"
    return 1
}

# memory_record_get FILE KEY — the sha256 that FILE keeps for KEY, or nothing: no FILE, a symbolic
# link (memory_record_put never writes through one, and a link to a file somebody else filled
# would "prove" a pilot's edit untouched: red team of the 0.41.1 candidate), an unreadable or
# malformed one, no line for KEY. The hash follows the last tab of its line, so a tab inside a path
# cannot shift it. Reading never fails the caller.
memory_record_get() {
    local file="$1" key="$2" line value tab found=""
    tab=$(printf '\t')
    [ ! -L "$file" ] && [ -f "$file" ] && [ -r "$file" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in *"$tab"*) ;; *) continue ;; esac
        [ "${line%"$tab"*}" = "$key" ] || continue
        value="${line##*"$tab"}"
        case "$value" in *[!0-9a-f]*|'') continue ;; esac
        [ "${#value}" -eq 64 ] && found="$value"
    done < "$file"
    [ -z "$found" ] || printf '%s\n' "$found"
    return 0
}

# record_memory_old_hash FPATH HASH — Step 2: FPATH's hash in the template clone before this run
# replaces it (proof b), kept in this run's temporary MEMORY_OLD_HASHES. A failed write costs the
# file only this proof.
record_memory_old_hash() {
    [ -n "${MEMORY_OLD_HASHES:-}" ] || return 0
    memory_record_put "$MEMORY_OLD_HASHES" "$1" "$2" \
        || echo "  ⚠ $1 — не удалось запомнить прежнюю версию шаблона; решат другие доказательства" >&2
}

# memory_old_hash FPATH — the hash record_memory_old_hash() kept for FPATH, or nothing.
memory_old_hash() {
    memory_record_get "${MEMORY_OLD_HASHES:-}" "$1"
}

# remember_memory_deployed FPATH HASH — proof (a) for the next runs: the deployed copy of FPATH now
# holds HASH. Nothing is written when the record already says so. A record that cannot be written
# is reported once per run, and the update goes on: only proof (a) is lost.
remember_memory_deployed() {
    [ -n "${MEMORY_DEPLOYED_RECORD:-}" ] || return 0
    [ "$(memory_record_get "$MEMORY_DEPLOYED_RECORD" "$1")" = "$2" ] && return 0
    memory_record_put "$MEMORY_DEPLOYED_RECORD" "$1" "$2" && return 0
    if [ "$MEMORY_RECORD_WARNED" != true ]; then
        echo "  ⚠ не удалось записать $MEMORY_DEPLOYED_RECORD — обновление идёт дальше; без этой записи часть нетронутых файлов памяти позже не удастся отличить от изменённых" >&2
        MEMORY_RECORD_WARNED=true
    fi
    return 0
}

# remember_untouched_memory_before_apply — review-12 of #965/#967, С1: before Step 5 replaces the
# template clone, every memory copy that still equals the version this run is about to replace
# (proof b) gets its record line. Proof (b) lives in this run's temporary directory: a run broken off
# between Step 5 and Step 6 (code 49, Ctrl-C) used to lose it, and on an installation without the
# record yet the next run could not tell such a copy from an edited one. An edited copy, MEMORY.md
# and the personal configs get no line; author_mode records nothing.
remember_untouched_memory_before_apply() {
    local f fname dst old_hash
    [ -d "$CLAUDE_MEMORY_DIR" ] || return 0
    is_author_mode && return 0
    for f in ${UPDATED_FILES[@]+"${UPDATED_FILES[@]}"}; do
        case "$f" in memory/*.md|memory/*.yaml|memory/*.yml) ;; *) continue ;; esac
        fname=$(basename "$f")
        if [ "$fname" = "MEMORY.md" ] || is_personal_config "$fname"; then
            continue
        fi
        dst="$CLAUDE_MEMORY_DIR/${f#memory/}"
        old_hash=$(memory_old_hash "$f")
        if [ -n "$old_hash" ] && [ -f "$dst" ] && [ "$(hash_file "$dst")" = "$old_hash" ]; then
            remember_memory_deployed "$f" "$old_hash"
        fi
    done
    return 0
}

# memory_decided_once FPATH — true the first time FPATH comes up in this run, false after it: Step 6
# and the repair pass after it walk the same paths, and a file gets one decision and one line per run.
memory_decided_once() {
    local nl='
'
    case "$nl$MEMORY_POLICY_SEEN" in *"$nl$1$nl"*) return 1 ;; esac
    MEMORY_POLICY_SEEN="$MEMORY_POLICY_SEEN$1$nl"
}

# memory_reason_text CODE — the classifier's "unknown" reason (see classify-workspace-copy.sh) in
# the user's words: the line it goes into is Russian.
memory_reason_text() {
    case "$1" in
        shallow) echo "клон шаблона сделан с --depth, его истории нет" ;;
        no-git) echo "каталог шаблона — не git-клон" ;;
        no-history) echo "в истории клона шаблона нет этого файла" ;;
        history_truncated) echo "у файла больше 200 версий в истории клона, они не просмотрены" ;;
        git-error) echo "git не смог прочитать историю клона" ;;
        no-classifier) echo "нет классификатора истории" ;;
        '') echo "классификатор не дал ответа" ;;
        *) echo "причина: $1" ;;
    esac
}

# memory_copy_verdict FPATH DST DST_HASH OLD_HASH — may the deployed copy DST of template file FPATH
# (hash DST_HASH, which differs from the template) be replaced? Prints "untouched <proof>" when
# one of the proofs (a)-(c) holds, "keep <reason>" otherwise. The classifier's verdict is only as
# strong as the history of the clone's CURRENT branch (git rev-list HEAD for this path), so the
# texts promise no more: "authored" names both causes it can have - the pilot's edits, or a
# release update.sh applied without committing it (and without the record, on an older install).
memory_copy_verdict() {
    local fpath="$1" dst="$2" dst_hash="$3" old_hash="$4" recorded
    local classifier="$SCRIPT_DIR/.claude/scripts/classify-workspace-copy.sh" classify_out="" verdict="" reason="no-classifier"
    # This run's own proof (b) first: remember_untouched_memory_before_apply() copies it into the
    # record, and the line should name the version the copy is checked against in this run.
    if [ -n "$old_hash" ] && [ "$old_hash" = "$dst_hash" ]; then
        echo "untouched равен прошлой версии шаблона"
        return 0
    fi
    recorded=$(memory_record_get "${MEMORY_DEPLOYED_RECORD:-}" "$fpath")
    if [ -n "$recorded" ] && [ "$recorded" = "$dst_hash" ]; then
        echo "untouched равен версии, установленной в прошлый раз"
        return 0
    fi
    if [ -f "$classifier" ]; then
        # </dev/null: repair_pass() feeds its loop from stdin; nothing else may take it.
        classify_out=$(bash "$classifier" "$SCRIPT_DIR" "$fpath" "$dst" </dev/null 2>/dev/null || true)
        verdict="${classify_out%% *}"
        reason="${classify_out#* }"
    fi
    case "$verdict" in
        uptodate|stale) echo "untouched равен версии из истории клона шаблона" ;;
        authored) echo "keep не совпадает ни с одной версией в истории текущей ветки клона (ваши правки или уже применённый прошлый релиз)" ;;
        *) echo "keep не удалось проверить, менялся ли файл ($(memory_reason_text "$reason"))" ;;
    esac
}

# replace_memory_copy SRC DST — put SRC's content at DST without ever leaving DST cut short: write
# a temporary file next to DST (with DST's mode, or a plain copy's mode for a new file), then mv it
# over DST, which is atomic within one directory. A symbolic link is written through, as before:
# the pilot pointed it elsewhere on purpose.
replace_memory_copy() {
    local src="$1" dst="$2" tmp
    if [ -L "$dst" ]; then
        cp "$src" "$dst"
        return
    fi
    tmp=$(mktemp "$dst.update-XXXXXX") || return 1
    if [ -e "$dst" ]; then
        cp -p "$dst" "$tmp" || { rm -f "$tmp"; return 1; }
    else
        rm -f "$tmp"
    fi
    if cp "$src" "$tmp" && mv -f "$tmp" "$dst"; then
        return 0
    fi
    rm -f "$tmp"
    return 1
}

# saving_cp_command SOURCE TARGET — the command line the reports offer for refreshing TARGET
# from SOURCE: first save TARGET next to itself, then replace it. The user's shell runs it, so
# each path goes through printf %q: the shell receives exactly these paths whatever they hold
# (spaces, quotes, $, backticks, backslashes) and expands nothing inside them. The saved copy's
# name comes from mktemp (TARGET.before-update-XXXXXX), which creates the file under a name no
# other run has, atomically: two runs, even within one second and with the same random seed, can
# never write into one copy, so the second run cannot replace the only copy of the user's edits
# with the refreshed file (issue #967). Only "$bak" is left for the user's shell to expand.
saving_cp_command() {
    local source_q target_q
    printf -v source_q '%q' "$1"
    printf -v target_q '%q' "$2"
    # shellcheck disable=SC2016  # "$bak" is meant for the user's shell, which runs this command
    printf 'bak=$(mktemp %s.before-update-XXXXXX) && cp -p %s "$bak" && cp %s %s' "$target_q" "$target_q" "$source_q" "$target_q"
}

# apply_memory_policy FPATH DST [OLD_HASH] — the memory policy above for one file: DST is the
# deployed copy of template file FPATH, OLD_HASH its proof (b) when the caller has one. A missing
# DST is copied, an identical one left alone; both are then recorded (proof a). Returns 0 when DST
# was written, 1 otherwise (identical, kept, backup or copy failed, or decided earlier in this run).
apply_memory_policy() {
    local fpath="$1" mem_dst="$2" old_hash="${3:-}" src src_hash dst_hash verdict src_q dst_q
    memory_decided_once "$fpath" || return 1
    src="$SCRIPT_DIR/$fpath"
    src_hash=$(hash_file "$src")
    if [ -z "$src_hash" ]; then
        echo "  ⚠ $fpath — НЕ обновлён: не удалось прочитать шаблонный файл $src; проверьте клон шаблона и повторите update.sh"
        MEMORY_KEPT+=("$fpath")
        return 1
    fi

    if [ ! -f "$mem_dst" ]; then
        if mkdir -p "$(dirname "$mem_dst")" && replace_memory_copy "$src" "$mem_dst"; then
            echo "  ⟲ $fpath → memory/ (файла не было, скопирован)"
            remember_memory_deployed "$fpath" "$src_hash"
            return 0
        fi
        echo "  ⚠ $fpath — НЕ доставлен: не удалось скопировать в $mem_dst; поправьте права или освободите место и повторите update.sh"
        MEMORY_KEPT+=("$fpath")
        return 1
    fi
    dst_hash=$(hash_file "$mem_dst")
    if [ "$dst_hash" = "$src_hash" ]; then
        remember_memory_deployed "$fpath" "$src_hash"
        return 1
    fi

    verdict=$(memory_copy_verdict "$fpath" "$mem_dst" "$dst_hash" "$old_hash")
    case "$verdict" in
        untouched\ *) ;;
        *)
            # The file will not refresh itself: nothing will prove it untouched later either (a kept
            # copy never gets a record line). So the line says so, gives the diff first and the
            # command second, conditional on there being no edits (an agent must not run it blind).
            printf -v src_q '%q' "$src"
            printf -v dst_q '%q' "$mem_dst"
            echo "  ⚠ $fpath — НЕ обновлён: ${verdict#keep }. Сам он не обновится. Сверьте: diff $src_q $dst_q. Если ваших правок там нет, примите версию шаблона (прежняя копия останется рядом): $(saving_cp_command "$src" "$mem_dst")"
            MEMORY_KEPT+=("$fpath")
            return 1
            ;;
    esac
    if ! backup_memory_file_before_overwrite "$fpath" "$mem_dst"; then
        echo "  ⚠ $fpath — НЕ обновлён: не удалось сохранить прежнюю версию (${MEMORY_BACKUP_FILE:-путь не определён}), замена отменена; поправьте права или освободите место и повторите update.sh"
        MEMORY_KEPT+=("$fpath")
        return 1
    fi
    if ! replace_memory_copy "$src" "$mem_dst"; then
        echo "  ⚠ $fpath — НЕ обновлён: копирование не удалось (прежняя версия сохранена в $MEMORY_BACKUP_FILE); повторите update.sh"
        MEMORY_KEPT+=("$fpath")
        return 1
    fi
    echo "  ⟲ $fpath → memory/ — обновлён (не менялся: ${verdict#untouched }; если в клоне шаблона была ваша правка, она в прежней версии); прежняя версия: $MEMORY_BACKUP_FILE"
    MEMORY_REPLACED+=("$fpath")
    remember_memory_deployed "$fpath" "$src_hash"
    return 0
}

# report_memory_policy_summary — the closing lines of the memory pass: every file this run
# replaced with the backup directory, and every file it left as it was. repair_pass() prints them:
# it runs after Step 6 on every path that writes memory, so the lists are complete there.
report_memory_policy_summary() {
    local f replaced="" kept=""
    for f in ${MEMORY_REPLACED[@]+"${MEMORY_REPLACED[@]}"}; do replaced="${replaced:+$replaced, }$f"; done
    for f in ${MEMORY_KEPT[@]+"${MEMORY_KEPT[@]}"}; do kept="${kept:+$kept, }$f"; done
    if [ -n "$replaced" ]; then
        echo "  ⚠ Заменено файлов памяти: ${#MEMORY_REPLACED[@]} ($replaced); прежние версии сохранены в $MEMORY_BACKUP_RUN"
    fi
    if [ -n "$kept" ]; then
        echo "  ⚠ Не обновлено файлов памяти: ${#MEMORY_KEPT[@]} ($kept); почему и что сделать — в строке каждого файла выше"
    fi
    return 0
}

# is_user_owned_memory DST — the deployed copy declares owner: user. Only author_mode's report reads
# it (report_author_user_memory); the update itself never does.
is_user_owned_memory() {
    [ "$(get_field "$1" owner)" = "user" ]
}

# report_author_user_memory FPATH DST — author_mode writes no memory copy. For an owner: user copy it
# keeps the report the template had before #965/#967: one line when the copy differs from the
# template, and none of report_author_skip()'s counters, so the copy neither swells the author_mode
# summary nor blocks --refresh-stale. One line per run (Step 6 and the repair pass both get here).
report_author_user_memory() {
    local fpath="$1" dst="$2" src_q dst_q
    memory_decided_once "$fpath" || return 0
    [ "$(hash_file "$SCRIPT_DIR/$fpath")" = "$(hash_file "$dst")" ] && return 0
    printf -v src_q '%q' "$SCRIPT_DIR/$fpath"
    printf -v dst_q '%q' "$dst"
    echo "  ⚠ $fpath — author_mode, owner: user: рабочая копия не тронута, отличается от шаблона. Сверь: diff $src_q $dst_q"
}

# author_diverged FPATH — author_mode: SCRIPT_DIR — git-клон этого самого шаблона,
# из которого качается upstream. Git — точный арбитр «locally stale vs автор доработал»,
# не список защищённых путей (issue #238, тот же класс бага, что стёр 66 файлов —
# guard 86cf080 защитил только .claude/*, а манифест несёт roles/docs/pack-templates/
# и другие каталоги вне списка). Диверженс = (1) файл dirty/untracked, ИЛИ (2) закоммичен
# локально, но не в origin/$BRANCH (ещё не запромотирован). Fail-closed: не git-репо
# или fetch не удался → защищаем (считаем diverged), чтобы не потерять данные молча.
_AUTHOR_FETCH_DONE=false
author_diverged() {
    local fpath="$1"
    is_author_mode || return 1
    git -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
    if [ "$_AUTHOR_FETCH_DONE" = false ]; then
        git -C "$SCRIPT_DIR" fetch --quiet origin "$BRANCH" 2>/dev/null || true
        _AUTHOR_FETCH_DONE=true
    fi
    [ -n "$(git -C "$SCRIPT_DIR" status --porcelain --untracked-files=all -- "$fpath" 2>/dev/null)" ] && return 0
    [ -n "$(git -C "$SCRIPT_DIR" log --oneline "origin/$BRANCH..HEAD" -- "$fpath" 2>/dev/null)" ] && return 0
    return 1
}

# author_release_regression FPATH PAYLOAD — bug-2026-09-17-tsekh1-release-
# regression: author_diverged() above only catches commits НЕ ЕЩЁ дошедшие до
# origin/$BRANCH — if the author's fix is already merged into main, that
# check reports "no divergence" even though the release channel is about to
# overwrite the file with an OLDER release snapshot (release_tag can trail
# main by any number of unreleased commits). Live incident: an author's fix
# landed on origin/main, update.sh (release channel, default) applied the
# release payload anyway and silently reverted it — noticed only by manually
# re-reading the file, not by any warning.
#
# The check needs no reference to whichever ref the release payload actually
# came from: PAYLOAD is already the downloaded release content
# ($TMPDIR_UPDATE/files/$f), so comparing it directly against origin/$BRANCH
# HEAD answers the only question that matters — "does applying this payload
# move the file away from what main already has?". Fires only when the local
# file already equals origin/$BRANCH HEAD (author_diverged already covers
# "has local edits") but the payload does not match that same HEAD. Reuses
# the fetch done by author_diverged() via $_AUTHOR_FETCH_DONE — no extra
# network round-trip.
author_release_regression() {
    local fpath="$1" payload="$2" head_sha local_sha payload_sha
    [ "$UPDATE_CHANNEL" = "release" ] || return 1
    is_author_mode || return 1
    git -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
    if [ "$_AUTHOR_FETCH_DONE" = false ]; then
        git -C "$SCRIPT_DIR" fetch --quiet origin "$BRANCH" 2>/dev/null || true
        _AUTHOR_FETCH_DONE=true
    fi
    head_sha=$(git -C "$SCRIPT_DIR" rev-parse "origin/$BRANCH:$fpath" 2>/dev/null) || return 1
    local_sha=$(git -C "$SCRIPT_DIR" hash-object "$SCRIPT_DIR/$fpath" 2>/dev/null) || return 1
    [ "$local_sha" = "$head_sha" ] || return 1
    payload_sha=$(git -C "$SCRIPT_DIR" hash-object "$payload" 2>/dev/null) || return 1
    [ "$payload_sha" != "$head_sha" ]
}

# manifest_version FILE — the first "version" value of an update-manifest.json (empty when
# there is none). One reader for every place that needs it: the upstream manifest (Step 1),
# the installed one for --check --fast, and the installed one when histories cannot be
# ordered by git (rollback_by_version, #963).
manifest_version() {
    grep '"version"' "$1" | head -1 | sed 's/.*"version"[[:space:]]*:[[:space:]]*"//;s/".*//'
}

# manifest_sha256_of MANIFEST PATH — the sha256 MANIFEST lists for PATH (one reader for the
# upstream manifest in the install-path guard and for the installed one in
# claude_template_copy_is_pristine). Prints nothing and returns 1 when there is no such entry,
# the entries disagree or the manifest cannot be read.
manifest_sha256_of() {
    local manifest="$1" want="$2"
    if py_available; then
        "$PY_BIN" - "$manifest" "$want" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1], encoding='utf-8') as f:
        data = json.load(f)
except Exception:
    sys.exit(1)
matches = [e.get('sha256') for e in data.get('files', []) if e.get('path') == sys.argv[2]]
uniq = set(m for m in matches if m)
if len(uniq) != 1:
    sys.exit(1)
print(uniq.pop())
PYEOF
        return $?
    fi
    # Shell-фоллбек (нет python3/python): не общий JSON-парсер — опирается
    # на фиксированный layout нашего же generate-manifest.sh
    # (json.dump(indent=2), "path" непосредственно перед "sha256" в одном
    # объекте, один ключ на строку). Если формат манифеста когда-нибудь
    # разъедется с этим предположением — E2E-тест на no-python окружение
    # это поймает (WP-529 Ф16, В3 codex).
    awk -v want="$want" '
        /"path"[[:space:]]*:/ {
            line = $0
            sub(/^[^"]*"path"[[:space:]]*:[[:space:]]*"/, "", line)
            sub(/".*$/, "", line)
            cur_path = line
            next
        }
        /"sha256"[[:space:]]*:/ && cur_path == want {
            line = $0
            sub(/^[^"]*"sha256"[[:space:]]*:[[:space:]]*"/, "", line)
            sub(/".*$/, "", line)
            if (found && line != found_val) { ambiguous = 1 }
            found = 1
            found_val = line
        }
        END {
            if (found && !ambiguous) { print found_val; exit 0 }
            exit 1
        }
    ' "$manifest"
}

# issue #1037: a fork with core.fileMode=false records new executables as
# 100644 after plain git add, even when the working copy has +x. Print exact
# repair commands for manifest files without staging the user's fork.
report_executable_index_mismatches() {
    local source="${1:-applied}" repo_prefix file mode unmerged index_entries staged_delete reported=0
    local -a candidates=()
    command -v git >/dev/null 2>&1 || return 0
    [ "$(git -C "$SCRIPT_DIR" config --bool core.fileMode 2>/dev/null)" = false ] || return 0
    repo_prefix=$(git -C "$SCRIPT_DIR" rev-parse --show-prefix 2>/dev/null) || return 0
    [ -z "$repo_prefix" ] || return 0

    if [ "$source" = manifest ]; then
        [ -f "${MANIFEST_PARSED:-}" ] || return 0
        while IFS='|' read -r file _; do
            candidates+=("$file")
        done < "$MANIFEST_PARSED"
    else
        candidates=("${APPLIED_PATHS[@]}")
    fi

    for file in "${candidates[@]}"; do
        case "$file" in
            *.sh|.githooks/*|.claude/bin/*|scripts/wp-list.py|scripts/check-claude-md-links.py) ;;
            *) continue ;;
        esac
        [ -f "$SCRIPT_DIR/$file" ] && [ -x "$SCRIPT_DIR/$file" ] || continue
        if ! unmerged=$(git -C "$SCRIPT_DIR" ls-files -u -- ":(top,literal)$file" 2>/dev/null); then
            printf '  ⚠ %s: не удалось проверить индекс Git; команды не предлагаются.\n' "$file"
            continue
        fi
        if [ -n "$unmerged" ]; then
            printf '  ⚠ %s: в индексе неразрешённый конфликт; сначала разрешите его вручную. Команды добавления файла не предлагаются.\n' "$file"
            continue
        fi
        if ! index_entries=$(git -C "$SCRIPT_DIR" ls-files --stage -- ":(top,literal)$file" 2>/dev/null); then
            printf '  ⚠ %s: не удалось проверить режим в индексе Git; команды не предлагаются.\n' "$file"
            continue
        fi
        mode=$(printf '%s\n' "$index_entries" | awk '$3 == 0 { print $1; exit }')
        [ "$mode" = 100755 ] && continue
        if [ -z "$mode" ]; then
            if ! staged_delete=$(git -C "$SCRIPT_DIR" diff --cached --diff-filter=D --name-only -- ":(top,literal)$file" 2>/dev/null); then
                printf '  ⚠ %s: не удалось проверить подготовленное удаление; команды не предлагаются.\n' "$file"
                continue
            fi
            if [ -n "$staged_delete" ]; then
                printf '  ⚠ %s: удаление уже подготовлено в Git; команда добавления файла не предлагается.\n' "$file"
                continue
            fi
        fi
        if [ "$reported" -eq 0 ]; then
            echo "  ⚠ Git этого форка игнорирует права файла (core.fileMode=false)."
            echo "    Для следующих исполняемых файлов шаблона нужен режим 100755 в индексе:"
            reported=1
        fi
        printf '    %s (сейчас: %s)\n' "$file" "${mode:-ещё не добавлен}"
        if [ -z "$mode" ]; then
            printf '    git -C %q add -- %q\n' "$SCRIPT_DIR" ":(top,literal)$file"
        fi
        printf '    git -C %q update-index --chmod=+x -- %q\n' "$SCRIPT_DIR" "$file"
    done
    [ "$reported" -eq 0 ] || echo "    Выполните команды после проверки файлов; порядок важен. Затем проверьте: git ls-files --stage."
    return 0
}

# version_compare A B — compare two plain X.Y.Z versions numerically. Prints -1, 0 or 1 (A is
# older than, equal to, newer than B) and returns 0; returns 2 and prints nothing when either
# argument is not digits-only X.Y.Z (at most 9 digits per part, so the arithmetic cannot
# overflow). "0.9.0" is older than "0.10.0": a string comparison says the opposite.
version_compare() {
    local a="$1" b="$2" part_a part_b re='^[0-9]{1,9}\.[0-9]{1,9}\.[0-9]{1,9}$'
    [[ $a =~ $re ]] && [[ $b =~ $re ]] || return 2
    while [ -n "$a" ]; do
        part_a=${a%%.*}
        part_b=${b%%.*}
        # 10#: a part such as "08" is the decimal 8, not an invalid octal literal.
        if [ $((10#$part_a)) -lt $((10#$part_b)) ]; then echo -1; return 0; fi
        if [ $((10#$part_a)) -gt $((10#$part_b)) ]; then echo 1; return 0; fi
        case "$a" in
            *.*) a=${a#*.}; b=${b#*.} ;;
            *) a="" ;;
        esac
    done
    echo 0
}

# rollback_by_version — issue #963: when the installed copy and the release share no commit
# (a fork whose history was rewritten, e.g. a different root commit), git merge-base cannot
# order them; order them by manifest version instead: the installed update-manifest.json
# against UPSTREAM_VERSION (set in Step 1, before the rollback check runs).
# Exit codes (the same contract as detect_release_rollback):
#   0 - the release is strictly older than the installed version: a rollback
#   1 - the release is newer or equal (equal versions do not prove a rollback)
#   2 - cannot tell: a shallow clone (a real ancestor may be cut off), no installed manifest,
#       or a version that is not plain X.Y.Z
rollback_by_version() {
    local installed cmp
    # A shallow clone reports "no common ancestor" also for histories that do share one.
    [ "$(git -C "$SCRIPT_DIR" rev-parse --is-shallow-repository 2>/dev/null)" = "false" ] || return 2
    [ -f "$SCRIPT_DIR/update-manifest.json" ] || return 2
    installed=$(manifest_version "$SCRIPT_DIR/update-manifest.json")
    cmp=$(version_compare "${UPSTREAM_VERSION:-}" "$installed") || return 2
    [ "$cmp" = "-1" ]
}

# issue #863: detect when the default release channel would roll back an install
# that is already newer than the latest published release. Fires in release
# channel when SCRIPT_DIR is a git repo and local HEAD contains commits that are
# not present in the release (i.e. the release is strictly behind local). When the
# two histories share no commit at all (#963) the versions in the manifests decide.
#
# Exit codes:
#   0 - rollback detected: the release is a strict ancestor of local HEAD, or (no common
#       ancestor) its manifest version is older than the installed one
#   1 - no rollback (release is HEAD, ahead, or, with no common ancestor, not older by version)
#   2 - cannot determine (network/history missing, unreadable versions, a shallow clone with
#       no visible common ancestor) -> caller must block --yes
detect_release_rollback() {
    [ "$UPDATE_CHANNEL" = "release" ] || return 1
    [ -n "$RELEASE_SHA" ] || return 1
    git -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
    local local_sha release_sha merge_base commit_json
    local_sha=$(git -C "$SCRIPT_DIR" rev-parse HEAD 2>/dev/null) || return 1
    [ -n "$local_sha" ] || return 1

    release_sha="$RELEASE_SHA"
    # Resolve a tag/branch ref to the actual commit SHA via the delivery API.
    # A full SHA is already resolved; local resolution is not enough because
    # the install's `origin` may point to a different fork or the local tag may
    # differ from the published one.
    if ! printf '%s' "$release_sha" | grep -qxE '[0-9a-f]{40}'; then
        commit_json=$(github_api_get "$API_BASE/commits/$release_sha") || return 2
        # Prefer JSON parsing; fall back to sed only when Python is unavailable.
        # Guard the assignment with || return 2: under set -e a bare failing
        # command-substitution aborts the whole script when this function is
        # not invoked from an if/|| context (WP-529 review of #863).
        if py_available; then
            release_sha=$(printf '%s\n' "$commit_json" | "$PY_BIN" -c '
import json, re, sys
try:
    doc = json.load(sys.stdin)
except json.JSONDecodeError:
    raise SystemExit(1)
sha = doc.get("sha", "") if isinstance(doc, dict) else ""
if not re.fullmatch(r"[0-9a-f]{40}", sha):
    raise SystemExit(1)
print(sha)') || return 2
        else
            # Non-greedy: take the first 40-hex sha field only (head -1).
            release_sha=$(printf '%s\n' "$commit_json" | \
                sed -n 's/.*"sha"[[:space:]]*:[[:space:]]*"\([0-9a-f]\{40\}\)".*/\1/p' | head -1) || return 2
        fi
        [ -n "$release_sha" ] || return 2
    fi

    # Ensure the release commit object is available locally for merge-base.
    if ! git -C "$SCRIPT_DIR" cat-file -e "$release_sha" 2>/dev/null; then
        if ! git -C "$SCRIPT_DIR" fetch --quiet origin "$release_sha" 2>/dev/null; then
            return 2
        fi
    fi

    # git merge-base: 0 = found, 1 = no common ancestor, anything else (128...) = an error.
    local merge_base_rc=0
    merge_base=$(git -C "$SCRIPT_DIR" merge-base "$local_sha" "$release_sha" 2>/dev/null) || merge_base_rc=$?
    case "$merge_base_rc" in
        0) ;;
        1) rollback_by_version; return $? ;;
        *) return 2 ;;
    esac
    [ -n "$merge_base" ] || return 2

    # Rollback if the release commit is an ancestor of local HEAD but not equal
    # to it (local has additional commits after the release).
    if [ "$merge_base" = "$release_sha" ] && [ "$local_sha" != "$release_sha" ]; then
        return 0
    fi
    return 1
}

# author_mode skip classification (WP-7 F71 stage A, peer-session 2026-08-14-05):
# tell the author WHY each file was skipped (authored edits vs merely stale vs
# undecidable) instead of one generic warning per file — Konstantin's live
# 0.36.1→0.38.3 report: 43 skipped files triaged by hand for an hour.
# Delegates to the shipped classifier; a missing classifier degrades loudly
# (one warning per run), never silently.
AUTHOR_SKIP_AUTHORED=0
AUTHOR_SKIP_STALE=0
AUTHOR_SKIP_UNKNOWN=0
AUTHOR_STALE_PAIRS=()   # "fpath|dst" — collected for --refresh-stale (stage B)
CLASSIFIER_DEGRADED_WARNED=false
report_author_skip() {
    local fpath="$1" dst="$2" mode="${3:-raw}"
    local classifier="$SCRIPT_DIR/.claude/scripts/classify-workspace-copy.sh"
    local verdict="" reason=""
    if [ ! -x "$classifier" ]; then
        if [ "$CLASSIFIER_DEGRADED_WARNED" = false ]; then
            echo "  ⚠ классификатор пропусков недоступен ($classifier) — деградация до общего сообщения"
            CLASSIFIER_DEGRADED_WARNED=true
        fi
        echo "  ⚠ $fpath — author_mode: рабочая копия не тронута. Сверь: diff \"$SCRIPT_DIR/$fpath\" \"$dst\""
        AUTHOR_SKIP_UNKNOWN=$((AUTHOR_SKIP_UNKNOWN + 1))
        return 0
    fi
    local classify_out
    if [ "$mode" = "templated" ]; then
        classify_out=$(bash "$classifier" --templated "$SCRIPT_DIR" "$fpath" "$dst" 2>/dev/null || true)
    else
        classify_out=$(bash "$classifier" "$SCRIPT_DIR" "$fpath" "$dst" 2>/dev/null || true)
    fi
    verdict="${classify_out%% *}"
    reason="${classify_out#* }"
    case "$verdict" in
        uptodate)
            # Byte-identical to the template — not a real skip, no warning needed.
            ;;
        stale)
            # The same saving command as apply_memory_policy() offers for a kept copy: a bare cp loses
            # the copy when the verdict misleads, and a fixed backup name is overwritten by a rerun.
            echo "  ⚠ $fpath — author_mode: отстал от шаблона, авторских правок нет. Обновить: $(saving_cp_command "$SCRIPT_DIR/$fpath" "$dst")"
            AUTHOR_SKIP_STALE=$((AUTHOR_SKIP_STALE + 1))
            AUTHOR_STALE_PAIRS+=("$fpath|$dst")
            ;;
        authored)
            echo "  ⚠ $fpath — author_mode: есть авторские правки, не тронут. Сверь: diff \"$SCRIPT_DIR/$fpath\" \"$dst\""
            AUTHOR_SKIP_AUTHORED=$((AUTHOR_SKIP_AUTHORED + 1))
            ;;
        *)
            echo "  ⚠ $fpath — author_mode: происхождение копии не установлено (${reason:-нет вердикта}), не тронут. Сверь: diff \"$SCRIPT_DIR/$fpath\" \"$dst\""
            AUTHOR_SKIP_UNKNOWN=$((AUTHOR_SKIP_UNKNOWN + 1))
            ;;
    esac
    return 0
}

report_author_skip_summary() {
    local total=$((AUTHOR_SKIP_AUTHORED + AUTHOR_SKIP_STALE + AUTHOR_SKIP_UNKNOWN))
    [ "$total" -gt 0 ] || return 0
    echo ""
    echo "  author_mode: пропущено $total файл(ов) — авторских $AUTHOR_SKIP_AUTHORED, отставших $AUTHOR_SKIP_STALE, неизвестно $AUTHOR_SKIP_UNKNOWN"
    if [ "$AUTHOR_SKIP_STALE" -gt 0 ] && [ "$REFRESH_STALE" != "true" ]; then
        echo "  Отставшие можно обновить автоматически (с бэкапом): bash update.sh --refresh-stale"
    fi
    apply_refresh_stale
}

# --refresh-stale (stage B, WP-7 F71): применяется ПОСЛЕ полной классификации —
# предохранитель консенсуса 14.08 «блокировка при неизвестно > 0» требует знать
# все вердикты до первой записи, поэтому применение живёт на сводке, не в цикле.
apply_refresh_stale() {
    [ "$REFRESH_STALE" = "true" ] || return 0
    if [ "$AUTHOR_SKIP_UNKNOWN" -gt 0 ]; then
        echo "  ✗ --refresh-stale отклонён: $AUTHOR_SKIP_UNKNOWN файл(ов) с неустановленным происхождением — сначала разбери их вручную (diff выше) и повтори"
        return 0
    fi
    if [ ${#AUTHOR_STALE_PAIRS[@]} -eq 0 ]; then
        echo "  --refresh-stale: отставших файлов нет, обновлять нечего"
        return 0
    fi
    local ts backup_root pair fpath dst refreshed=0
    ts=$(date -u +%Y%m%dT%H%M%SZ)
    backup_root="$WORKSPACE_DIR/.backups/refresh-stale/$ts"
    for pair in ${AUTHOR_STALE_PAIRS[@]+"${AUTHOR_STALE_PAIRS[@]}"}; do
        fpath="${pair%%|*}"
        dst="${pair#*|}"
        mkdir -p "$backup_root/$(dirname "$fpath")"
        if ! cp "$dst" "$backup_root/$fpath"; then
            echo "  ⚠ $fpath — бэкап не записался, файл НЕ обновлён"
            continue
        fi
        if cp "$SCRIPT_DIR/$fpath" "$dst"; then
            case "$fpath" in *.sh) chmod +x "$dst" ;; esac
            echo "  ⟲ $fpath — обновлён из шаблона (refresh-stale)"
            refreshed=$((refreshed + 1))
        else
            echo "  ⚠ $fpath — копирование не удалось, прежняя копия цела"
        fi
    done
    echo "  --refresh-stale: обновлено $refreshed из ${#AUTHOR_STALE_PAIRS[@]}, бэкап: $backup_root"
}

# --apply-settings-merge (stage B): применяется независимо от того, менялся ли
# settings.json шаблона в ЭТОМ прогоне — живой e2e-прогон 14.08 показал, что
# пользовательский путь «увидел предпросмотр → перезапустил с флагом» иначе
# делает ничего (шаблон уже обновлён прошлым прогоном, файл не в UPDATED).
apply_settings_merge_if_requested() {
    [ "$APPLY_SETTINGS_MERGE" = "true" ] || return 0
    local src="$SCRIPT_DIR/.claude/settings.json"
    local dst="$WORKSPACE_DIR/.claude/settings.json"
    local applier="$SCRIPT_DIR/.claude/scripts/settings-merge-apply.sh"
    if [ ! -f "$src" ] || [ ! -f "$dst" ]; then
        echo "  ⚠ --apply-settings-merge: нет одной из копий settings.json, применять нечего"
        return 0
    fi
    if cmp -s "$src" "$dst"; then
        echo "  --apply-settings-merge: settings.json уже совпадает с шаблоном, слияние не требуется"
        return 0
    fi
    if ! py_available || [ ! -f "$applier" ]; then
        echo "  ⚠ --apply-settings-merge: python3 или $applier недоступны — слияние не применено"
        return 0
    fi
    local apply_rc=0 apply_out
    apply_out=$(bash "$applier" "$src" "$dst" "$PY_BIN" 2>&1) || apply_rc=$?
    printf '%s\n' "$apply_out" | sed 's/^/    /'
    if [ "$apply_rc" -eq 0 ]; then
        echo "  ✓ .claude/settings.json — обновлён слиянием (--apply-settings-merge)"
    else
        echo "  ⚠ .claude/settings.json — слияние не применено (см. причину выше), workspace-копия цела"
        report_settings_merge_preview "$src" "$dst"
    fi
    return 0
}

# settings.json merge PREVIEW (WP-7 F71 stage A): generate a merged candidate
# next to the real file and report the differences. The real settings.json is
# intentionally left untouched (bug-2026-07-11 clobber guard stays in force);
# auto-apply is a separate flag-gated stage B.
report_settings_merge_preview() {
    local src="$1" dst="$2"
    local merger="$SCRIPT_DIR/.claude/scripts/settings-merge-preview.py"
    py_available && [ -f "$merger" ] || return 0
    local preview="$WORKSPACE_DIR/.claude/settings.merged.preview.json"
    local report_file="$TMPDIR_UPDATE/settings-merge-report.json"
    if ! "$PY_BIN" "$merger" "$src" "$dst" "$preview" > "$report_file" 2>/dev/null; then
        echo "    ⚠ предпросмотр слияния не построен (битый JSON в одном из файлов)"
        return 0
    fi
    "$PY_BIN" - "$report_file" <<'PY' 2>/dev/null || true
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    r = json.load(handle)
print(f"    → предпросмотр слияния: {r['preview']}")
print(f"    + из шаблона: ключей {r['keys_added_from_template']}, hook-записей {r['hooks_added_from_template']}, permissions {r['permissions_added_from_template']}")
if r["conflicts"]:
    print(f"    ⚠ конфликты (оставлено ваше значение): {', '.join(r['conflicts'])}")
PY
    return 0
}

# The settings merge warning must compare the template with the workspace, not
# depend on this run having downloaded a changed template file.  Forks normally
# fast-forward their template mirror before update.sh, which otherwise leaves
# UPDATED_FILES empty and hides this actionable drift forever.
report_settings_merge_drift() {
    [ "$APPLY_SETTINGS_MERGE" = "true" ] && return 0
    local src="$SCRIPT_DIR/.claude/settings.json"
    local dst="$WORKSPACE_DIR/.claude/settings.json"
    [ -f "$src" ] && [ -f "$dst" ] || return 0
    cmp -s "$src" "$dst" && return 0

    echo "  ⚠ .claude/settings.json — платформа обновила hooks/permissions, workspace-копия НЕ тронута (несёт пользовательские хуки)."
    if $CHECK_ONLY; then
        echo "    Режим --check: предпросмотр не записан. Запустите update.sh без --check, чтобы получить безопасный план слияния."
        return 0
    fi
    report_settings_merge_preview "$src" "$dst"
}

# === Detect directories ===
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# issue #229: shared frontmatter reader (get_field), sourced by SCRIPT_DIR-relative
# path. Soft here (no || exit 1): an install upgrading from a pre-2.4.0 version
# won't have this file locally yet on its very first run — Step 0 self-update
# replaces update.sh itself and re-execs it before any file propagation happens,
# so this line runs before the file can exist on disk. Step 5 Apply delivers it
# (it's now in the manifest) and re-sources it below, right after copying files —
# that call is the hard-required one, by which point the file is guaranteed present.
[ -f "$SCRIPT_DIR/.claude/lib/frontmatter.sh" ] && source "$SCRIPT_DIR/.claude/lib/frontmatter.sh"

if [ ! -f "$SCRIPT_DIR/CLAUDE.md" ]; then
    echo "ОШИБКА: Запускайте из корня экзокортекс-репо."
    echo "  cd /path/to/your-exocortex && bash update.sh"
    exit 1
fi

WORKSPACE_DIR="$(dirname "$SCRIPT_DIR")"
RULES_BACKUP_RUN=""
RULES_SAFE_TO_UPDATE="|"
MEMORY_BACKUP_RUN=""
# The record of installed memory versions, proof (a) of the memory policy (issues #965/#967).
# The workspace is not a git repository: the record stays local to this installation.
MEMORY_DEPLOYED_RECORD="$WORKSPACE_DIR/.memory-deployed.tsv"
UPDATE_INCOMPLETE_MARKER="$SCRIPT_DIR/.update-incomplete"
UPDATE_TRANSACTION_STARTED=false

# issue #768: a full update.sh run, launched from a disposable copy of the
# workspace, silently retargeted the REAL ~/Library/LaunchAgents and
# ~/.zshenv onto the copy — WORKSPACE_DIR correctly points at the copy, but
# nothing checks whether host-global resources (a real per-user shell rc
# file, real launchd jobs) already belong to a DIFFERENT, already-configured
# workspace before rewriting them. Absence of evidence is not evidence of
# being the primary install — this only detects a conflict with a workspace
# already on record; a virgin machine still lets the first run claim
# ownership (peer-session 2026-09-10-09-fmt-issues-triage, Kimi+Codex).
HOST_GLOBAL_OWNER_CONFLICT=false
HOST_GLOBAL_OWNER_CONFLICT_REASON=""

canonical_workspace_path() {
    if [ -d "$1" ]; then
        (cd "$1" 2>/dev/null && pwd -P)
    else
        printf '%s\n' "${1%/}"
    fi
}

mark_host_global_conflict() {
    if [ -n "$HOST_GLOBAL_OWNER_CONFLICT_REASON" ]; then
        HOST_GLOBAL_OWNER_CONFLICT_REASON="$HOST_GLOBAL_OWNER_CONFLICT_REASON; $1"
    else
        HOST_GLOBAL_OWNER_CONFLICT_REASON="$1"
    fi
    HOST_GLOBAL_OWNER_CONFLICT=true
}

detect_host_global_owner_conflict() {
    local current_root existing_root plist plist_root zsh_roots
    current_root="$(canonical_workspace_path "$WORKSPACE_DIR")"

    if [ -f "$HOME/.zshenv" ]; then
        zsh_roots=$(awk '
          /^# IWE environment \(WP-219, DP.FM.009\):/ { managed=1; next }
          managed && /^_IWE_ROOT="/ {
              value=$0
              sub(/^_IWE_ROOT="/, "", value)
              sub(/"$/, "", value)
              print value
          }
          managed && /^unset _IWE_ROOT$/ { managed=0 }
        ' "$HOME/.zshenv")

        while IFS= read -r existing_root; do
            [ -n "$existing_root" ] || continue
            if [ "$(canonical_workspace_path "$existing_root")" != "$current_root" ]; then
                mark_host_global_conflict "~/.zshenv points to $existing_root"
            fi
        done <<EOF
$zsh_roots
EOF
    fi

    # Only IWE-owned launchd job names — an unrelated ~/Library/LaunchAgents
    # entry with a similar prefix from another tool is not this contract.
    for plist in \
        "$HOME/Library/LaunchAgents"/com.exocortex.*.plist \
        "$HOME/Library/LaunchAgents"/com.strategist.*.plist \
        "$HOME/Library/LaunchAgents"/com.extractor.*.plist
    do
        [ -f "$plist" ] || continue

        if [ -x /usr/libexec/PlistBuddy ]; then
            plist_root=$(/usr/libexec/PlistBuddy \
                -c 'Print :EnvironmentVariables:IWE_WORKSPACE' \
                "$plist" 2>/dev/null || true)
        elif command -v plutil >/dev/null 2>&1; then
            plist_root=$(plutil -extract EnvironmentVariables.IWE_WORKSPACE raw -o - \
                "$plist" 2>/dev/null || true)
        else
            plist_root=""
        fi

        if [ -z "$plist_root" ]; then
            # Neither parser available, or the key isn't there — cannot prove
            # this plist belongs to the current workspace. Fail closed: treat
            # as a conflict rather than silently assume ownership.
            mark_host_global_conflict "$(basename "$plist"): владелец не определён"
        elif [ "$(canonical_workspace_path "$plist_root")" != "$current_root" ]; then
            mark_host_global_conflict "$(basename "$plist") points to $plist_root"
        fi
    done
}

if [ "${IWE_ALLOW_FOREIGN_WORKSPACE:-0}" != "1" ]; then
    detect_host_global_owner_conflict
fi
if $HOST_GLOBAL_OWNER_CONFLICT; then
    echo "⚠ Host-global ресурсы IWE (~/.zshenv, launchd) принадлежат другому или неопределённому workspace:"
    echo "  $HOST_GLOBAL_OWNER_CONFLICT_REASON"
    echo "  ~/.zshenv и планировщики задач НЕ будут изменены этим прогоном."
    echo "  Если это осознанный перенос основной установки: IWE_ALLOW_FOREIGN_WORKSPACE=1 bash update.sh"
fi

# WP-529 F6 (peer-session 2026-08-19-01, Evgenii post-update defect #5):
# build-runtime is part of the update transaction. Its failure used to be
# fully swallowed — the status flowed through `| sed`, so even the old warning
# branch checked sed's exit code, not build-runtime's — and the TOTAL_CHANGES=0
# recovery branch never invoked it at all. Contract now: failure keeps
# .update-incomplete, prints remediation and exits EXIT_RUNTIME; rerunning
# update.sh after fixing the cause converges (same contract as issue #459).
run_build_runtime_or_die() {
    [ -f "$SCRIPT_DIR/setup/build-runtime.sh" ] || return 0
    echo ""
    echo "Generated runtime (.iwe-runtime/)..."
    local brt_out brt_status
    if brt_out=$(bash "$SCRIPT_DIR/setup/build-runtime.sh" \
        --workspace "$WORKSPACE_DIR" \
        --env-file "${WORKSPACE_DIR}/.exocortex.env" \
        --quiet 2>&1); then
        brt_status=0
    else
        brt_status=$?
    fi
    [ -n "$brt_out" ] && printf '%s\n' "$brt_out" | sed 's/^/  /'
    if [ "$brt_status" -ne 0 ]; then
        # Cold review 2026-08-19 (High): the marker line must not lie — on a
        # no-op run no transaction was opened and there is no marker to keep.
        if [ -f "$UPDATE_INCOMPLETE_MARKER" ]; then
            echo "✗ build-runtime.sh завершился с ошибкой (код $brt_status). Обновление НЕ завершено: маркер .update-incomplete сохранён." >&2
        else
            echo "✗ build-runtime.sh завершился с ошибкой (код $brt_status)." >&2
        fi
        echo "  Проверьте .exocortex.env (значения placeholders) и повторите: bash $SCRIPT_DIR/update.sh." >&2
        echo "  Если .exocortex.env ещё не создавался — сначала: bash $SCRIPT_DIR/setup.sh" >&2
        exit "$EXIT_RUNTIME"
    fi
}

begin_update_transaction() {
    if [ ! -f "$UPDATE_INCOMPLETE_MARKER" ]; then
        {
            echo "started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
            echo "local_version=${LOCAL_VERSION:-unknown}"
            echo "upstream_version=${UPSTREAM_VERSION:-unknown}"
            echo "state=applying"
        } > "$UPDATE_INCOMPLETE_MARKER"
    fi
    UPDATE_TRANSACTION_STARTED=true
}

# #1028: a missing configuration used to be generated in Step 5b, after the
# template and workspace CLAUDE.md had already changed. Stop before any apply
# or repair-pass write, and leave a private draft for the operator to complete.
require_env_before_update() {
    if [ -L "$WORKSPACE_DIR/.exocortex.env" ]; then
        echo "ОШИБКА: .exocortex.env является символической ссылкой: $WORKSPACE_DIR/.exocortex.env" >&2
        exit "$EXIT_RUNTIME"
    fi
    if [ -e "$WORKSPACE_DIR/.exocortex.env" ]; then
        if [ -f "$WORKSPACE_DIR/.exocortex.env" ]; then
            return 0
        fi
        echo "ОШИБКА: .exocortex.env существует, но не является обычным файлом: $WORKSPACE_DIR/.exocortex.env" >&2
        exit "$EXIT_RUNTIME"
    fi
    if [ -L "$SCRIPT_DIR/.exocortex.env" ]; then
        echo "ОШИБКА: legacy .exocortex.env является символической ссылкой: $SCRIPT_DIR/.exocortex.env" >&2
        exit "$EXIT_RUNTIME"
    fi
    [ -f "$SCRIPT_DIR/.exocortex.env" ] && return 0  # legacy migration

    # setup.sh and some consumers source this file as shell. Their other
    # readers treat values as raw text, so shell escaping would corrupt paths.
    # Decline automatic generation when a detected value cannot round-trip in
    # plain double quotes; the operator can supply a safe config explicitly.
    local draft claude_path user_name value
    claude_path=$(command -v claude 2>/dev/null || echo 'claude')
    user_name=$(id -un 2>/dev/null || true)
    for value in "$WORKSPACE_DIR" "$HOME" "$claude_path" "$user_name"; do
        case "$value" in
            *'$'*|*'`'*|*'"'*|*'\'*|*$'\n'*|*$'\r'*)
                echo "ОШИБКА: путь или имя содержит символы, опасные для автосоздания .exocortex.env; обновление не начато." >&2
                echo "  Создайте $WORKSPACE_DIR/.exocortex.env вручную с безопасно записанными значениями и повторите обновление." >&2
                exit "$EXIT_RUNTIME"
                ;;
        esac
    done
    draft=$(mktemp "$WORKSPACE_DIR/.exocortex.env.tmp.XXXXXX") || {
        echo "ОШИБКА: не удалось подготовить черновик .exocortex.env; обновление не начато." >&2
        exit "$EXIT_RUNTIME"
    }
    if ! chmod 600 "$draft"; then
        rm -f "$draft"
        echo "ОШИБКА: не удалось защитить черновик .exocortex.env; обновление не начато." >&2
        exit "$EXIT_RUNTIME"
    fi
    if ! cat > "$draft" <<ENVEOF
# Exocortex configuration (draft generated before update.sh applies files)
# Check GITHUB_USER and other values, then rerun update.sh. Do not commit.
GITHUB_USER="your-username"
WORKSPACE_DIR="$WORKSPACE_DIR"
CLAUDE_PATH="$claude_path"
CLAUDE_PROJECT_SLUG="$(iwe_claude_project_slug "$WORKSPACE_DIR")"
TIMEZONE_HOUR="4"
TIMEZONE_DESC="4:00 (местное время)"
HOME_DIR="$HOME"
USER_NAME="$user_name"
L4_BACKEND=
L4_DATABASE_URL=
ENVEOF
    then
        rm -f "$draft"
        echo "ОШИБКА: не удалось записать черновик .exocortex.env; обновление не начато." >&2
        exit "$EXIT_RUNTIME"
    fi
    # Same-directory hard link publishes the complete 0600 draft only when the
    # destination is still absent; a concurrent creator wins without overwrite.
    if ! ln "$draft" "$WORKSPACE_DIR/.exocortex.env" 2>/dev/null; then
        rm -f "$draft"
        echo "ОШИБКА: не удалось создать .exocortex.env без перезаписи; обновление не начато." >&2
        exit "$EXIT_RUNTIME"
    fi
    rm -f "$draft"
    echo "ОШИБКА: отсутствует .exocortex.env; обновление не начато, остальные файлы установки не менялись." >&2
    echo "  Черновик создан с правами 600: $WORKSPACE_DIR/.exocortex.env" >&2
    echo "  Укажите свой GITHUB_USER и проверьте пути/время в этом файле." >&2
    printf '  Затем повторите тот же канал: IWE_UPDATE_CHANNEL=%s bash %q --yes\n' \
        "$UPDATE_CHANNEL" "$SCRIPT_DIR/update.sh" >&2
    exit "$EXIT_RUNTIME"
}

finish_update_transaction() {
    if [ -f "$UPDATE_INCOMPLETE_MARKER" ]; then
        rm -f "$UPDATE_INCOMPLETE_MARKER"
        echo "  ✓ Маркер незавершённого обновления снят."
    fi
    UPDATE_TRANSACTION_STARTED=false
}

effective_governance_repo() {
    local configured="${ENV_GOVERNANCE_REPO:-}"
    local env_file

    # Normal installs keep the file in the workspace root. Older installs can
    # still have it inside the template repository, so a zero-diff recovery
    # must honour the same fallback as the main update path. Parse only the one
    # data line; never source either file.
    for env_file in "$WORKSPACE_DIR/.exocortex.env" "$SCRIPT_DIR/.exocortex.env"; do
        [ -z "$configured" ] || break
        [ -f "$env_file" ] || continue
        configured=$(grep -E '^GOVERNANCE_REPO=' "$env_file" 2>/dev/null \
            | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'")
    done
    configured="${configured:-${IWE_GOVERNANCE_REPO:-DS-strategy}}"
    case "$configured" in
        ""|.|..|.*|*/*|*[!A-Za-z0-9._-]*)
            echo "ОШИБКА: GOVERNANCE_REPO должен быть именем каталога, не путём: $configured" >&2
            return 1
            ;;
    esac
    if [ -L "$WORKSPACE_DIR/$configured" ]; then
        echo "ОШИБКА: governance repo является symlink; backfill запрещён: $WORKSPACE_DIR/$configured" >&2
        return 1
    fi
    if [ -d "$WORKSPACE_DIR/$configured" ] && [ -d "$SCRIPT_DIR" ]; then
        local governance_real script_real
        governance_real=$(cd -P "$WORKSPACE_DIR/$configured" 2>/dev/null && pwd -P) || return 1
        script_real=$(cd -P "$SCRIPT_DIR" 2>/dev/null && pwd -P) || return 1
        if [ "$governance_real" = "$script_real" ]; then
            echo "ОШИБКА: GOVERNANCE_REPO указывает на template repo; backfill запрещён: $configured" >&2
            return 1
        fi
    fi
    printf '%s\n' "$configured"
}

atomic_copy_executable() {
    if [ "$#" -ne 2 ]; then
        echo "ОШИБКА: atomic_copy_executable требует <source> <target>" >&2
        return 1
    fi
    local source_path="$1" target_path="$2" target_dir temporary_path
    target_dir=$(dirname "$target_path")
    if [ -L "$target_dir" ]; then
        echo "ОШИБКА: каталог назначения является symlink: $target_dir" >&2
        return 1
    fi
    if ! mkdir -p "$target_dir"; then
        echo "ОШИБКА: не удалось создать каталог $target_dir" >&2
        return 1
    fi
    if ! temporary_path=$(mktemp "$target_dir/.iwe-update-copy.XXXXXX"); then
        echo "ОШИБКА: не удалось создать временный файл рядом с $target_path" >&2
        return 1
    fi
    if ! cp "$source_path" "$temporary_path" || \
       ! chmod +x "$temporary_path" || \
       ! mv -f "$temporary_path" "$target_path"; then
        rm -f "$temporary_path"
        echo "ОШИБКА: атомарная доставка $target_path не завершена" >&2
        return 1
    fi
}

agent_fault_git() {
    if [ "$#" -lt 2 ]; then
        echo "ОШИБКА: agent_fault_git требует <repo> <git-args...>" >&2
        return 1
    fi
    local repository="$1"
    shift
    env -u GIT_INDEX_FILE -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR \
        -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES \
        -u GIT_CEILING_DIRECTORIES \
        GIT_OPTIONAL_LOCKS=0 \
        GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
        git -C "$repository" "$@"
}

agent_fault_target_snapshot() {
    if [ "$#" -ne 1 ] || [ -z "${PY_BIN:-}" ]; then
        echo "agent-fault target snapshot requires Python 3 and one path" >&2
        return 2
    fi
    # PY_BIN can intentionally be the two-word Windows launcher `py -3`.
    # shellcheck disable=SC2086
    $PY_BIN -c '
import hashlib
import json
import os
import stat
import sys

path = sys.argv[1]
try:
    before = os.lstat(path)
except FileNotFoundError:
    print("missing")
    raise SystemExit(0)
if not stat.S_ISREG(before.st_mode):
    print(json.dumps(["non-regular", before.st_dev, before.st_ino, before.st_mode]))
    raise SystemExit(0)
# O_BINARY exists on Windows only: without it the descriptor is in text mode (\r\n translation, Ctrl-Z ends
# the file) and the hash below would not be the hash of the actual bytes.
flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_BINARY", 0)
descriptor = os.open(path, flags)
try:
    opened = os.fstat(descriptor)
    identity = (
        before.st_dev, before.st_ino, before.st_mode, before.st_size,
        before.st_mtime_ns, before.st_ctime_ns,
    )
    # Since CPython 3.12 on Windows lstat() reports the creation time as st_ctime and fstat() the metadata
    # change time, so the two can disagree for a file modified after it was created (issue #989): the
    # cross-API comparison is POSIX only. The lstat taken after the read below, compared with the one above,
    # still catches a swap that is in place by then.
    if os.name != "nt" and (
        opened.st_dev, opened.st_ino, opened.st_mode, opened.st_size,
        opened.st_mtime_ns, opened.st_ctime_ns,
    ) != identity:
        raise RuntimeError("target identity changed before snapshot")
    digest = hashlib.sha256()
    while True:
        chunk = os.read(descriptor, 1024 * 1024)
        if not chunk:
            break
        digest.update(chunk)
finally:
    os.close(descriptor)
after = os.lstat(path)
after_identity = (
    after.st_dev, after.st_ino, after.st_mode, after.st_size,
    after.st_mtime_ns, after.st_ctime_ns,
)
if after_identity != identity:
    raise RuntimeError("target identity changed during snapshot")
print(json.dumps(["file", *identity, digest.hexdigest()], separators=(",", ":")))
' "$1"
}

agent_fault_legacy_hash_is_blessed() {
    if [ "$#" -ne 2 ]; then
        return 1
    fi
    local relative_path="$1" digest="$2"
    # Exact bytes formerly shipped by FMT.  Keep provenance per path: a digest
    # valid for one legacy command never authorizes replacement of another.
    # c180e6a (v0.33.0): Python reminder + feedback importer + shell reminder.
    # ceca611: shell reminder gained its platform routing header.
    case "$relative_path:$digest" in
        scripts/agent_fault_remind.py:9e4e354e3829c558fa4c35659084fdc6b024d3fb1dd69ff1640e9c58d7c98b60|\
        scripts/sync_feedback_to_memory.py:776a18c30c45ba164e21376e17872b5070274aab72a911d5ad1363773c48ad67|\
        scripts/agent_fault_remind.sh:913779508fc0144cfae0f345ec9e733b95d64333c74b42d17c84ed5d9ce0f03d|\
        scripts/agent_fault_remind.sh:632ef75c7d1ed5d3bbb5546c279edf58b730a15706ee8e47ee5240bbe4b17cc3)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

scan_legacy_agent_fault_import_consumers() {
    if [ "$#" -ne 2 ] || [ -z "${PY_BIN:-}" ]; then
        echo "agent-fault consumer scan requires Python 3" >&2
        return 2
    fi
    local scripts_dir="$1" workspace_dir="$2"
    [ -d "$scripts_dir" ] || return 0
    # PY_BIN can intentionally be the two-word Windows launcher `py -3`.
    # shellcheck disable=SC2086
    $PY_BIN -c '
import ast
import os
import sys
from pathlib import Path

root = Path(sys.argv[1])
# issue #661: a FILE symlink whose target resolves INSIDE the workspace
# (e.g. a script shared between two sibling governance repos) is not the
# escape hazard this scan guards against — only a symlink whose target
# resolves outside the workspace can expose content the scan was never
# meant to read. Boundary is the workspace root, not scripts_dir itself: a
# legitimate shared script commonly lives in a sibling repo under the same
# workspace, not under this scripts_dir.
#
# Directory symlinks stay unconditionally refused, in- or out-of-workspace
# (cold-context review finding): os.walk(followlinks=False) never descends
# into a symlinked directory regardless of this boundary check, so
# "allowing" one would silently skip scanning its contents — a legacy
# `iwe_checklist_memory` import hiding behind such a directory would slip
# past with no warning instead of forcing a human to look. Refusing keeps
# the previous, safer behavior for directories; only individual file
# symlinks (whose content os.walk DOES read either way) get the new
# workspace-boundary leniency.
workspace_real = os.path.realpath(sys.argv[2])
matches = []

def is_legacy_module(name):
    return name == "iwe_checklist_memory" or name.endswith(".iwe_checklist_memory")

def resolves_inside_workspace(path):
    real = os.path.realpath(path)
    return real == workspace_real or real.startswith(workspace_real + os.sep)

try:
    for directory, names, files in os.walk(root, followlinks=False):
        for name in names:
            candidate_directory = Path(directory, name)
            if candidate_directory.is_symlink():
                print(
                    f"consumer scan refused symlinked directory: {candidate_directory}",
                    file=sys.stderr,
                )
                raise SystemExit(2)
        for name in files:
            if not name.endswith(".py"):
                continue
            candidate = Path(directory, name)
            if candidate.is_symlink() and not resolves_inside_workspace(candidate):
                print(
                    f"consumer scan refused symlinked Python file escaping workspace: {candidate}",
                    file=sys.stderr,
                )
                raise SystemExit(2)
            text = candidate.read_text(encoding="utf-8", errors="replace")
            try:
                tree = ast.parse(text, filename=str(candidate))
            except (SyntaxError, ValueError) as exc:
                line = getattr(exc, "lineno", None) or 1
                message = getattr(exc, "msg", type(exc).__name__)
                print(
                    f"consumer scan failed to parse {candidate}:{line}: {message}",
                    file=sys.stderr,
                )
                raise SystemExit(2)
            for node in ast.walk(tree):
                if isinstance(node, ast.Import):
                    found = any(is_legacy_module(alias.name) for alias in node.names)
                elif isinstance(node, ast.ImportFrom):
                    found = bool(node.module and is_legacy_module(node.module)) or any(
                        is_legacy_module(alias.name) for alias in node.names
                    )
                else:
                    found = False
                if found:
                    matches.append(f"{candidate}:{node.lineno}")
except OSError as exc:
    print(f"consumer scan failed: {exc}", file=sys.stderr)
    raise SystemExit(2)
print("\n".join(matches))
' "$scripts_dir" "$workspace_dir"
}

print_legacy_agent_fault_manual_remediation() {
    if [ "$#" -ne 1 ]; then
        return 1
    fi
    local governance_dir="$1" relative_path source_path target_path backup_path
    echo "  Manual remediation prerequisites (do not run copy commands yet):" >&2
    echo "    1. Migrate every listed legacy import consumer to canonical immutable read_faults(...)." >&2
    echo "    2. Review each source/target diff and keep a backup." >&2
    echo "  Only after both reviews, run the applicable command:" >&2
    for relative_path in "${AGENT_FAULT_LEGACY_SHIMS[@]}"; do
        source_path="$SCRIPT_DIR/seed/strategy/$relative_path"
        target_path="$governance_dir/$relative_path"
        backup_path="$target_path.before-fmt-533"
        if [ -f "$target_path" ] && [ ! -L "$target_path" ]; then
            printf '    mkdir -p %q && cp -p %q %q && cp %q %q && chmod +x %q\n' \
                "$(dirname "$backup_path")" "$target_path" "$backup_path" \
                "$source_path" "$target_path" "$target_path" >&2
        else
            printf '    mkdir -p %q && cp %q %q && chmod +x %q\n' \
                "$(dirname "$target_path")" "$source_path" "$target_path" \
                "$target_path" >&2
        fi
    done
}

preflight_legacy_agent_fault_shims() {
    if [ "$#" -ne 1 ]; then
        echo "ОШИБКА: preflight_legacy_agent_fault_shims требует <governance-dir>" >&2
        return 1
    fi
    local governance_dir="$1" relative_path source_path target_path digest
    local target_snapshot
    local git_prefix git_relative_path git_pathspec tracked_paths
    local git_ready=false tracked=false status_output consumer_matches
    local blocked=0
    AGENT_FAULT_SHIMS_TO_APPLY=()
    AGENT_FAULT_SHIM_PREFLIGHT_PATHS=()
    AGENT_FAULT_SHIM_TARGET_SNAPSHOTS=()
    AGENT_FAULT_SHIM_GIT_READY=()
    AGENT_FAULT_SHIM_GIT_PATHSPECS=()
    AGENT_FAULT_SHIM_TRACKED_SNAPSHOTS=()
    AGENT_FAULT_SHIM_STATUS_SNAPSHOTS=()

    if [ -L "$governance_dir" ] || [ ! -d "$governance_dir" ]; then
        echo "  ✗ governance must be an existing real directory; legacy shim migration refused." >&2
        print_legacy_agent_fault_manual_remediation "$governance_dir"
        return 1
    fi
    if [ -L "$governance_dir/scripts" ] || \
       { [ -e "$governance_dir/scripts" ] && [ ! -d "$governance_dir/scripts" ]; }; then
        echo "  ✗ governance/scripts must be a real directory; legacy shim migration refused." >&2
        print_legacy_agent_fault_manual_remediation "$governance_dir"
        return 1
    fi
    if agent_fault_git "$governance_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        git_ready=true
        if ! git_prefix=$(agent_fault_git "$governance_dir" rev-parse --show-prefix); then
            echo "  ✗ cannot resolve governance path inside Git; legacy shim migration refused." >&2
            print_legacy_agent_fault_manual_remediation "$governance_dir"
            return 1
        fi
    fi

    for relative_path in "${AGENT_FAULT_LEGACY_SHIMS[@]}"; do
        source_path="$SCRIPT_DIR/seed/strategy/$relative_path"
        target_path="$governance_dir/$relative_path"
        if [ -L "$source_path" ] || [ ! -f "$source_path" ]; then
            echo "  ✗ release payload is missing a real $relative_path shim." >&2
            blocked=1
            continue
        fi
        if [ -L "$target_path" ]; then
            echo "  ✗ $relative_path is a symlink; automatic migration refused." >&2
            blocked=1
            continue
        fi
        if [ -e "$target_path" ] && [ ! -f "$target_path" ]; then
            echo "  ✗ $relative_path is not a regular file; automatic migration refused." >&2
            blocked=1
            continue
        fi
        if ! target_snapshot=$(agent_fault_target_snapshot "$target_path"); then
            echo "  ✗ cannot snapshot $relative_path before migration." >&2
            blocked=1
            continue
        fi
        tracked=false
        tracked_paths=""
        status_output=""
        git_pathspec=""
        if $git_ready; then
            git_relative_path="${git_prefix}${relative_path}"
            git_pathspec=":(top,icase,literal)${git_relative_path}"
            if ! tracked_paths=$(agent_fault_git "$governance_dir" ls-files -- "$git_pathspec"); then
                echo "  ✗ cannot inspect tracked paths for $relative_path; automatic migration refused." >&2
                blocked=1
                continue
            fi
            if [ -n "$tracked_paths" ]; then
                tracked=true
                if [ "$tracked_paths" != "$git_relative_path" ]; then
                    echo "  ✗ $relative_path has a case-insensitive tracked alias; automatic migration refused." >&2
                    blocked=1
                    continue
                fi
            fi
            if ! status_output=$(agent_fault_git "$governance_dir" \
                status --porcelain=v1 --untracked-files=all -- "$git_pathspec"); then
                echo "  ✗ cannot inspect Git state for $relative_path; automatic migration refused." >&2
                blocked=1
                continue
            fi
        fi
        AGENT_FAULT_SHIM_PREFLIGHT_PATHS+=("$relative_path")
        AGENT_FAULT_SHIM_TARGET_SNAPSHOTS+=("$target_snapshot")
        if $git_ready; then
            AGENT_FAULT_SHIM_GIT_READY+=("1")
        else
            AGENT_FAULT_SHIM_GIT_READY+=("0")
        fi
        AGENT_FAULT_SHIM_GIT_PATHSPECS+=("$git_pathspec")
        AGENT_FAULT_SHIM_TRACKED_SNAPSHOTS+=("$tracked_paths")
        AGENT_FAULT_SHIM_STATUS_SNAPSHOTS+=("$status_output")
        if [ -f "$target_path" ] && cmp -s "$source_path" "$target_path"; then
            if [ ! -x "$target_path" ]; then
                AGENT_FAULT_SHIMS_TO_APPLY+=("$relative_path")
            fi
            continue
        fi
        if ! $git_ready; then
            echo "  ✗ $relative_path needs migration but governance is non-Git; provenance cannot be proven." >&2
            blocked=1
            continue
        fi
        if [ ! -e "$target_path" ]; then
            if $tracked; then
                echo "  ✗ $relative_path is a tracked deletion; automatic resurrection refused." >&2
                blocked=1
                continue
            fi
            if [ -n "$status_output" ]; then
                echo "  ✗ $relative_path has a case-insensitive untracked or staged alias; automatic migration refused." >&2
                blocked=1
            else
                AGENT_FAULT_SHIMS_TO_APPLY+=("$relative_path")
            fi
            continue
        fi
        digest=$(hash_file "$target_path") || {
            echo "  ✗ cannot hash $relative_path; automatic migration refused." >&2
            blocked=1
            continue
        }
        if agent_fault_legacy_hash_is_blessed "$relative_path" "$digest" && \
           $tracked && [ -z "$status_output" ]; then
            AGENT_FAULT_SHIMS_TO_APPLY+=("$relative_path")
            continue
        fi
        if [ -n "$status_output" ]; then
            echo "  ✗ $relative_path is dirty, staged, or untracked; automatic migration refused." >&2
        elif $tracked; then
            echo "  ✗ $relative_path is clean but has unknown bytes; it is not an FMT-owned version." >&2
        else
            echo "  ✗ $relative_path is an unknown untracked file; automatic migration refused." >&2
        fi
        blocked=1
    done

    if ! consumer_matches=$(scan_legacy_agent_fault_import_consumers "$governance_dir/scripts" "$WORKSPACE_DIR"); then
        echo "  ✗ legacy import consumer scan failed; no compatibility shim was changed." >&2
        blocked=1
    elif [ -n "$consumer_matches" ]; then
        echo "  ✗ legacy import consumer(s) still require init_db/DB_PATH-style facade removal:" >&2
        printf '%s\n' "$consumer_matches" | sed 's/^/    /' >&2
        echo "  Migrate them to the canonical immutable read_faults(...) API, then rerun update.sh." >&2
        blocked=1
    fi
    if [ "$blocked" -ne 0 ]; then
        AGENT_FAULT_SHIMS_TO_APPLY=()
        print_legacy_agent_fault_manual_remediation "$governance_dir"
        return 1
    fi
    if [ "${#AGENT_FAULT_SHIM_PREFLIGHT_PATHS[@]}" -ne \
         "${#AGENT_FAULT_LEGACY_SHIMS[@]}" ]; then
        echo "  ✗ incomplete legacy shim snapshot; automatic migration refused." >&2
        AGENT_FAULT_SHIMS_TO_APPLY=()
        return 1
    fi
}

agent_fault_revalidate_shim_snapshot() {
    if [ "$#" -ne 2 ]; then
        return 1
    fi
    local governance_dir="$1" relative_path="$2" target_path
    local expected_index=-1 index=0 snapshot_path
    local current_snapshot current_tracked current_status
    for snapshot_path in "${AGENT_FAULT_SHIM_PREFLIGHT_PATHS[@]}"; do
        if [ "$snapshot_path" = "$relative_path" ]; then
            expected_index=$index
            break
        fi
        index=$((index + 1))
    done
    if [ "$expected_index" -lt 0 ]; then
        echo "  ✗ no preflight snapshot for $relative_path; apply refused." >&2
        return 1
    fi
    target_path="$governance_dir/$relative_path"
    if ! current_snapshot=$(agent_fault_target_snapshot "$target_path") || \
       [ "$current_snapshot" != \
         "${AGENT_FAULT_SHIM_TARGET_SNAPSHOTS[$expected_index]}" ]; then
        echo "  ✗ $relative_path changed after preflight; apply refused." >&2
        return 1
    fi
    if [ "${AGENT_FAULT_SHIM_GIT_READY[$expected_index]}" = "1" ]; then
        if ! current_tracked=$(agent_fault_git "$governance_dir" ls-files -- \
                "${AGENT_FAULT_SHIM_GIT_PATHSPECS[$expected_index]}") || \
           ! current_status=$(agent_fault_git "$governance_dir" \
                status --porcelain=v1 --untracked-files=all -- \
                "${AGENT_FAULT_SHIM_GIT_PATHSPECS[$expected_index]}"); then
            echo "  ✗ Git state for $relative_path cannot be revalidated." >&2
            return 1
        fi
        if [ "$current_tracked" != \
             "${AGENT_FAULT_SHIM_TRACKED_SNAPSHOTS[$expected_index]}" ] || \
           [ "$current_status" != \
             "${AGENT_FAULT_SHIM_STATUS_SNAPSHOTS[$expected_index]}" ]; then
            echo "  ✗ Git state for $relative_path changed after preflight; apply refused." >&2
            return 1
        fi
    elif agent_fault_git "$governance_dir" \
        rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        echo "  ✗ $relative_path entered a Git worktree after preflight; apply refused." >&2
        return 1
    fi
}

apply_legacy_agent_fault_shims() {
    if [ "$#" -ne 1 ]; then
        echo "ОШИБКА: apply_legacy_agent_fault_shims требует <governance-dir>" >&2
        return 1
    fi
    local governance_dir="$1" backup_root relative_path source_path target_path
    local backup_path restore_temp index=0 applied_count=0 rollback_failed=0
    local transaction_active=false transaction_signal="" transaction_code=1
    local saved_exit saved_hup saved_int saved_term
    local -a originals

    if [ "${#AGENT_FAULT_SHIMS_TO_APPLY[@]}" -eq 0 ]; then
        echo "  ✓ legacy agent-fault shims already match the release payload."
        return 0
    fi
    if ! backup_root=$(mktemp -d "${TMPDIR_UPDATE:-${TMPDIR:-/tmp}}/iwe-agent-fault-shims.XXXXXX"); then
        echo "  ✗ cannot create rollback storage for legacy shims." >&2
        return 1
    fi

    saved_exit=$(trap -p EXIT)
    saved_hup=$(trap -p HUP)
    saved_int=$(trap -p INT)
    saved_term=$(trap -p TERM)

    agent_fault_restore_transaction_traps() {
        trap - EXIT HUP INT TERM
        [ -z "$saved_exit" ] || eval "$saved_exit"
        [ -z "$saved_hup" ] || eval "$saved_hup"
        [ -z "$saved_int" ] || eval "$saved_int"
        [ -z "$saved_term" ] || eval "$saved_term"
    }

    agent_fault_rollback_applied_prefix() {
        local rollback_index=0 rollback_relative rollback_target
        local rollback_backup rollback_temp
        rollback_failed=0
        while [ "$rollback_index" -lt "$applied_count" ]; do
            rollback_relative="${AGENT_FAULT_SHIMS_TO_APPLY[$rollback_index]}"
            rollback_target="$governance_dir/$rollback_relative"
            rollback_backup="$backup_root/$rollback_index"
            if [ "${originals[$rollback_index]}" = "file" ]; then
                rollback_temp="$rollback_target.iwe-rollback.$$.$rollback_index"
                if ! cp -p "$rollback_backup" "$rollback_temp" || \
                   ! mv -f "$rollback_temp" "$rollback_target"; then
                    rm -f "$rollback_temp"
                    rollback_failed=1
                fi
            elif ! rm -f "$rollback_target"; then
                rollback_failed=1
            fi
            rollback_index=$((rollback_index + 1))
        done
        rm -rf "$backup_root"
    }

    agent_fault_transaction_exit() {
        local exit_code=$?
        if $transaction_active; then
            transaction_active=false
            agent_fault_rollback_applied_prefix
        fi
        agent_fault_restore_transaction_traps
        exit "$exit_code"
    }

    agent_fault_transaction_signal() {
        transaction_signal="$1"
        transaction_code="$2"
        if $transaction_active; then
            transaction_active=false
            agent_fault_rollback_applied_prefix
        fi
        agent_fault_restore_transaction_traps
        kill -s "$transaction_signal" "$$"
        return "$transaction_code"
    }

    transaction_active=true
    trap 'agent_fault_transaction_exit' EXIT
    trap 'agent_fault_transaction_signal HUP 129' HUP
    trap 'agent_fault_transaction_signal INT 130' INT
    trap 'agent_fault_transaction_signal TERM 143' TERM

    originals=()
    for relative_path in "${AGENT_FAULT_SHIMS_TO_APPLY[@]}"; do
        target_path="$governance_dir/$relative_path"
        backup_path="$backup_root/$index"
        if [ -f "$target_path" ]; then
            if ! cp -p "$target_path" "$backup_path"; then
                echo "  ✗ cannot snapshot $relative_path before migration." >&2
                transaction_active=false
                rm -rf "$backup_root"
                agent_fault_restore_transaction_traps
                unset -f agent_fault_restore_transaction_traps \
                    agent_fault_rollback_applied_prefix \
                    agent_fault_transaction_exit agent_fault_transaction_signal
                return 1
            fi
            originals+=("file")
        else
            originals+=("missing")
        fi
        index=$((index + 1))
    done

    index=0
    for relative_path in "${AGENT_FAULT_SHIMS_TO_APPLY[@]}"; do
        source_path="$SCRIPT_DIR/seed/strategy/$relative_path"
        target_path="$governance_dir/$relative_path"
        if ! agent_fault_revalidate_shim_snapshot "$governance_dir" "$relative_path"; then
            echo "  ✗ apply precondition drift at $relative_path; rolling back applied legacy shims." >&2
            break
        fi
        # Include the in-flight target in rollback: TERM may arrive after its
        # atomic rename but before this loop regains control.
        applied_count=$((index + 1))
        if ! atomic_copy_executable "$source_path" "$target_path"; then
            echo "  ✗ apply failed at $relative_path; rolling back applied legacy shims." >&2
            break
        fi
        index=$((index + 1))
    done

    if [ "$index" -ne "${#AGENT_FAULT_SHIMS_TO_APPLY[@]}" ]; then
        transaction_active=false
        agent_fault_rollback_applied_prefix
        agent_fault_restore_transaction_traps
        if [ "$rollback_failed" -ne 0 ]; then
            echo "  ✗ legacy shim rollback was incomplete; inspect all four paths manually." >&2
        else
            echo "  ✓ legacy shim apply failure rolled back without index changes." >&2
        fi
        unset -f agent_fault_restore_transaction_traps \
            agent_fault_rollback_applied_prefix \
            agent_fault_transaction_exit agent_fault_transaction_signal
        return 1
    fi

    transaction_active=false
    rm -rf "$backup_root"
    agent_fault_restore_transaction_traps
    unset -f agent_fault_restore_transaction_traps \
        agent_fault_rollback_applied_prefix \
        agent_fault_transaction_exit agent_fault_transaction_signal
    echo "  ✓ four legacy agent-fault names now delegate to the canonical CLI."
}

backfill_legacy_agent_fault_shims() {
    local governance_repo="${EFFECTIVE_GOVERNANCE_REPO:-}"
    local governance_dir
    if [ -z "$governance_repo" ]; then
        governance_repo=$(effective_governance_repo) || return 1
    fi
    governance_dir="$WORKSPACE_DIR/$governance_repo"
    if [ ! -e "$governance_dir" ] && [ ! -L "$governance_dir" ]; then
        echo "  ○ $governance_repo: governance repo не найден, legacy agent-fault migration пропущена."
        return 0
    fi
    preflight_legacy_agent_fault_shims "$governance_dir" || return 1
    # The consumer scan may take long enough for a user/agent to create or
    # stage one of the targets. Re-run the full read-only preflight so apply
    # receives a snapshot taken after that scan, not before it.
    preflight_legacy_agent_fault_shims "$governance_dir" || return 1
    apply_legacy_agent_fault_shims "$governance_dir"
}

backfill_platform_hooks() {
    local governance_repo="${EFFECTIVE_GOVERNANCE_REPO:-$(effective_governance_repo)}"
    local governance_dir="$WORKSPACE_DIR/$governance_repo"
    local source_installer="$SCRIPT_DIR/seed/strategy/scripts/install-hooks.sh"
    local target_installer="$governance_dir/scripts/install-hooks.sh"
    local backup_dir="$governance_dir/.git/hook-backups"
    local backup backup_index

    if [ -L "$governance_dir" ] || [ -L "$governance_dir/.git" ] || [ -L "$backup_dir" ]; then
        echo "  ✗ $governance_repo: governance/.git/hook-backups symlink запрещён; platform hooks не изменены." >&2
        return 1
    fi
    if [ -f "$governance_dir/.git" ]; then
        echo "  ⚠ $governance_repo: обнаружен Git worktree (.git — файл); platform hooks не установлены. Используйте обычный clone или установите hooks вручную после проверки общего core.hooksPath." >&2
        return 0
    fi
    if [ ! -d "$governance_dir/.git" ]; then
        echo "  ○ $governance_repo: git-репозиторий не найден, миграция hooks пропущена."
        return 0
    fi
    if [ -L "$governance_dir/scripts" ] || [ -L "$governance_dir/.githooks" ]; then
        echo "  ✗ Каталоги scripts/.githooks в $governance_repo не должны быть symlink; platform hooks не изменены." >&2
        return 1
    fi

    for source_path in \
        "$source_installer" \
        "$SCRIPT_DIR/seed/strategy/.githooks/pre-commit" \
        "$SCRIPT_DIR/seed/strategy/.githooks/pre-push"
    do
        if [ -L "$source_path" ] || [ ! -f "$source_path" ]; then
            echo "  ✗ Канонический platform-hook не доставлен: ${source_path#"$SCRIPT_DIR"/}" >&2
            return 1
        fi
    done
    if [ -L "$target_installer" ]; then
        echo "  ✗ scripts/install-hooks.sh является symlink; автоматическая перезапись запрещена." >&2
        return 1
    fi

    if ! mkdir -p "$governance_dir/scripts" "$backup_dir"; then
        echo "  ✗ Не удалось подготовить каталоги platform hooks." >&2
        return 1
    fi
    if [ -f "$target_installer" ] && ! cmp -s "$source_installer" "$target_installer"; then
        backup="$backup_dir/install-hooks.sh.backup.$(date +%s)"
        backup_index=0
        while [ -e "$backup" ]; do
            backup_index=$((backup_index + 1))
            backup="$backup_dir/install-hooks.sh.backup.$(date +%s).$backup_index"
        done
        if ! cp "$target_installer" "$backup"; then
            echo "  ✗ Не удалось сохранить backup существующего install-hooks.sh." >&2
            return 1
        fi
        echo "  📝 Existing install-hooks.sh backed up to: $backup"
    fi
    if [ ! -f "$target_installer" ] || ! cmp -s "$source_installer" "$target_installer"; then
        atomic_copy_executable "$source_installer" "$target_installer" || return 1
    elif ! chmod +x "$target_installer"; then
        echo "  ✗ Не удалось восстановить executable bit у install-hooks.sh." >&2
        return 1
    fi

    if ! IWE_TEMPLATE="$SCRIPT_DIR" IWE_ROOT="$WORKSPACE_DIR" \
        bash "$target_installer" "$governance_dir"; then
        return 1
    fi
}

backfill_executor_catalog() {
    local governance_repo="${EFFECTIVE_GOVERNANCE_REPO:-$(effective_governance_repo)}"
    local governance_dir="$WORKSPACE_DIR/$governance_repo"
    local skills_dir="$WORKSPACE_DIR/.claude/skills"
    local output_path="$governance_dir/scripts/executor-catalog.yaml"
    local resolved_python catalog_output

    if [ -L "$governance_dir" ]; then
        echo "  ✗ executor-catalog.yaml не обновлён: governance repo является symlink." >&2
        return 1
    fi
    if [ ! -d "$governance_dir" ] || [ ! -d "$skills_dir" ]; then
        echo "  ○ executor-catalog.yaml: governance repo или skills не найдены, backfill пропущен."
        return 0
    fi
    if [ -L "$governance_dir/scripts" ] || [ -L "$output_path" ]; then
        echo "  ✗ executor-catalog.yaml не обновлён: scripts или сам target является symlink." >&2
        return 1
    fi
    if ! resolved_python=$("$SCRIPT_DIR/scripts/lib/find-python3.sh" 2>/dev/null); then
        echo "  ⚠ executor-catalog.yaml не сгенерирован: нет python3 с PyYAML." >&2
        return 1
    fi

    if catalog_output=$(IWE_ROOT="$WORKSPACE_DIR" IWE_GOVERNANCE_REPO="$governance_repo" \
        "$resolved_python" "$SCRIPT_DIR/scripts/generate-executor-catalog.py" \
        --skills-dir "$skills_dir" --output "$output_path" 2>&1); then
        [ -n "$catalog_output" ] && printf '%s\n' "$catalog_output" | sed 's/^/  /'
        return 0
    fi

    [ -n "$catalog_output" ] && printf '%s\n' "$catalog_output" | sed 's/^/  /' >&2
    echo "  ⚠ executor-catalog.yaml не сгенерирован: повторите после исправления ошибки выше." >&2
    return 1
}

backfill_governance_seed_script() {
    if [ "$#" -ne 1 ]; then
        echo "ОШИБКА: backfill_governance_seed_script требует <relative-path>" >&2
        return 1
    fi
    local governance_repo="${EFFECTIVE_GOVERNANCE_REPO:-$(effective_governance_repo)}"
    local governance_dir="$WORKSPACE_DIR/$governance_repo"
    local relative_path="$1"
    local source_path="$SCRIPT_DIR/seed/strategy/$relative_path"
    local target_path="$governance_dir/$relative_path"
    local git_prefix git_relative_path git_pathspec tracked_paths status_output tracked_status

    if [ -L "$governance_dir" ]; then
        echo "  ✗ $relative_path не обновлён: governance repo является symlink." >&2
        return 1
    fi
    if [ ! -d "$governance_dir" ]; then
        echo "  ○ $governance_repo: governance repo не найден, backfill $relative_path пропущен."
        return 0
    fi
    if [ -L "$source_path" ] || [ ! -f "$source_path" ]; then
        echo "  ✗ $relative_path не доставлен в целевом release payload." >&2
        return 1
    fi
    if [ -L "$governance_dir/scripts" ]; then
        echo "  ✗ $relative_path не обновлён: governance scripts является symlink." >&2
        return 1
    fi
    if [ -L "$target_path" ]; then
        echo "  ✗ $relative_path является symlink; автоматическая перезапись запрещена." >&2
        return 1
    fi

    # Fresh installs receive the seed copy, including its provenance header.
    # Existing installations may be upgraded only when their platform snapshot
    # is either absent or a clean tracked file. A local deletion is a worktree
    # change too: never silently resurrect it over the user's Git state.
    if [ ! -f "$target_path" ] || ! cmp -s "$source_path" "$target_path"; then
        if agent_fault_git "$governance_dir" \
            rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            if ! git_prefix=$(agent_fault_git "$governance_dir" rev-parse --show-prefix); then
                echo "  ✗ $relative_path: не удалось определить Git prefix; backfill запрещён." >&2
                return 1
            fi
            git_relative_path="${git_prefix}${relative_path}"
            git_pathspec=":(top,icase,literal)${git_relative_path}"
            if ! tracked_paths=$(agent_fault_git "$governance_dir" \
                    ls-files -- "$git_pathspec") || \
               ! status_output=$(agent_fault_git "$governance_dir" \
                    status --porcelain=v1 --untracked-files=all -- "$git_pathspec") || \
               ! tracked_status=$(agent_fault_git "$governance_dir" \
                    status --porcelain=v1 --untracked-files=no -- "$git_pathspec"); then
                echo "  ✗ $relative_path: Git state не прочитан; backfill запрещён." >&2
                return 1
            fi
            if [ -n "$tracked_paths" ] && \
               [ "$tracked_paths" != "$git_relative_path" ]; then
                echo "  ✗ $relative_path имеет case-insensitive tracked alias; backfill запрещён." >&2
                return 1
            fi
            # status_output mixes the tracked file's own state with any
            # untracked case-variant sibling matched by the icase pathspec;
            # tracked_status (--untracked-files=no) isolates the former so
            # each branch below names the actual cause, not a catch-all.
            if [ -n "$tracked_status" ]; then
                echo "  ✗ $relative_path содержит локальные изменения/удаление; сначала разберите Git state." >&2
                return 1
            fi
            if [ -n "$status_output" ]; then
                if [ -n "$tracked_paths" ]; then
                    echo "  ✗ $relative_path: рядом обнаружен untracked-файл с другим регистром имени (case alias); backfill запрещён." >&2
                elif [ -e "$target_path" ]; then
                    echo "  ✗ $relative_path существует как пользовательский untracked-файл; автоматическая перезапись запрещена. Если это платформенный файл, который забыли закоммитить — выполните git add/git commit и повторите обновление." >&2
                else
                    echo "  ✗ $relative_path: рядом обнаружен файл с другим регистром имени (untracked case alias); backfill запрещён." >&2
                fi
                return 1
            fi
        elif [ -e "$target_path" ]; then
            echo "  ✗ $relative_path отличается, а governance directory не является git-репозиторием; автоматическая перезапись запрещена." >&2
            return 1
        fi
    fi

    if [ ! -f "$target_path" ] || ! cmp -s "$source_path" "$target_path"; then
        atomic_copy_executable "$source_path" "$target_path" || return 1
        echo "  ⟳ $relative_path обновлён в $governance_repo."
    else
        echo "  ✓ $relative_path уже совпадает с release payload."
    fi
}

backfill_derived_snapshot_updater() {
    backfill_governance_seed_script "scripts/update-derived-snapshot.py"
}

backfill_day_open_fault_reader() {
    backfill_governance_seed_script "scripts/day-open-llm-fill.py"
}

backfill_executor_catalog_generator() {
    backfill_governance_seed_script "scripts/generate-executor-catalog.py"
}

# ds-publish.sh (issue #941): strategist.sh publishes its commits through
# $governance/scripts/ds-publish.sh, which the template never shipped. Delivered only
# when the governance repo has no such file: an existing one is not ours to replace
# (an installation may keep its own, larger publisher at the same path).
backfill_ds_publish() {
    local governance_repo="${EFFECTIVE_GOVERNANCE_REPO:-$(effective_governance_repo)}"
    local target_path="$WORKSPACE_DIR/$governance_repo/scripts/ds-publish.sh"
    # Issue #1003: a copy that THIS template shipped earlier (sha256 on the list) is
    # not user content: it is replaced even though it lies untracked in the governance
    # repo (the generic backfill refuses untracked files). Any other file stays.
    local known_old_publishers="dd9a0e7a3116281763b26a351904f5e21de8d730559a1a77dd2a248f2a986730"
    local source_path="$SCRIPT_DIR/seed/strategy/scripts/ds-publish.sh" target_hash
    if [ -f "$target_path" ] && [ ! -L "$target_path" ] && [ ! -L "$(dirname "$target_path")" ] \
       && [ -f "$source_path" ] && [ ! -L "$source_path" ]; then
        target_hash=$(hash_file "$target_path" 2>/dev/null) || target_hash=""
        case " $known_old_publishers " in
            *" $target_hash "*)
                if [ -n "$target_hash" ]; then
                    # The file is usually untracked (git has no copy): keep one before replacing.
                    local backup_dir="$WORKSPACE_DIR/.backups/ds-publish-pre-update/$(date -u +%Y%m%dT%H%M%SZ)-$$"
                    if [ -L "$WORKSPACE_DIR/.backups" ] || ! mkdir -p "$backup_dir" \
                       || ! cp -p "$target_path" "$backup_dir/ds-publish.sh"; then
                        echo "  ✗ scripts/ds-publish.sh: не удалось сделать резервную копию, прежняя копия остаётся." >&2
                        return 1
                    fi
                    echo "  ↳ backup: $target_path → $backup_dir/ds-publish.sh"
                    atomic_copy_executable "$source_path" "$target_path" || return 1
                    echo "  ⟳ scripts/ds-publish.sh: прежняя копия шаблона заменена на текущую в $governance_repo."
                    return 0
                fi ;;
        esac
    fi
    if [ -e "$target_path" ] || [ -L "$target_path" ]; then
        echo "  ✓ scripts/ds-publish.sh уже есть в $governance_repo, не заменяю."
        return 0
    fi
    backfill_governance_seed_script "scripts/ds-publish.sh"
}

# #533: update is the one reliable point at which an existing private fault
# profile can be brought onto the current schema and permission contract.  The
# canonical CLI's no-create observational `stats` command is used here: it
# deliberately migrates and hardens an existing untracked DB, but create=False
# means a user who never enabled the profile gets no profile/.gitignore/DB as
# update debris.
# A tracked private DB remains fail-closed.  Surface that refusal as a warning
# without ever running `git rm --cached` or otherwise mutating the user's index.
harden_agent_fault_profile_after_update() {
    local governance_repo="${EFFECTIVE_GOVERNANCE_REPO:-}"
    local cli="$SCRIPT_DIR/scripts/agent-fault/iwe_checklist_memory.py"
    local harden_output harden_status

    if [ -z "$governance_repo" ] && \
       ! governance_repo=$(effective_governance_repo); then
        echo "  ⚠ agent-fault profile не проверен: governance repo не определён." >&2
        return 0
    fi
    if [ ! -f "$cli" ]; then
        echo "  ⚠ agent-fault profile не проверен: canonical CLI не доставлен." >&2
        return 0
    fi
    if ! py_available; then
        echo "  ⚠ agent-fault profile не проверен: Python 3 недоступен." >&2
        return 0
    fi

    if harden_output=$(IWE_WORKSPACE="$WORKSPACE_DIR" \
        IWE_GOVERNANCE_REPO="$governance_repo" \
        "$PY_BIN" "$cli" stats 2>&1 >/dev/null); then
        return 0
    else
        harden_status=$?
    fi
    printf '  ⚠ agent-fault profile оставлен без изменений (код %s): %s\n' \
        "$harden_status" "$harden_output" >&2
    return 0
}

run_post_apply_backfills_or_die() {
    $CHECK_ONLY && return 0
    if ! EFFECTIVE_GOVERNANCE_REPO=$(effective_governance_repo); then
        return 1
    fi

    local install_paths_args=(
        --workspace "$WORKSPACE_DIR"
        --governance "$EFFECTIVE_GOVERNANCE_REPO"
        --quiet
    )
    # issue #768: a foreign/unowned host-global state must not have its real
    # ~/.zshenv rewritten to point at this WORKSPACE_DIR.
    $HOST_GLOBAL_OWNER_CONFLICT && install_paths_args+=(--skip-zshenv)
    bash "$SCRIPT_DIR/setup/install-iwe-paths.sh" \
        "${install_paths_args[@]}" 2>&1 | sed 's/^/  /'
    local install_paths_status="${PIPESTATUS[0]}"
    if [ "$install_paths_status" -ne 0 ]; then
        echo "  ⚠ install-iwe-paths.sh завершился с ошибкой (exit $install_paths_status). Запустите вручную: bash $SCRIPT_DIR/setup/install-iwe-paths.sh --workspace $WORKSPACE_DIR --governance $EFFECTIVE_GOVERNANCE_REPO"
    fi

    echo ""
    echo "Day Open fault reader (upgrade backfill)..."
    if ! backfill_day_open_fault_reader; then
        echo "  ОШИБКА: governance Day Open reader не обновлён; обновление оставлено незавершённым." >&2
        return 1
    fi

    echo ""
    echo "Agent fault profile (safe update hardening)..."
    harden_agent_fault_profile_after_update

    echo ""
    echo "Agent fault legacy entrypoints (all-or-none upgrade)..."
    if ! backfill_legacy_agent_fault_shims; then
        echo "  ОШИБКА: legacy agent-fault entrypoints не мигрированы; canonical profile hardening уже выполнен независимо." >&2
        return 1
    fi

    echo ""
    echo "Platform hooks (upgrade backfill)..."
    if ! backfill_platform_hooks; then
        echo "  ОШИБКА: platform hooks не мигрированы; обновление оставлено незавершённым." >&2
        return 1
    fi

    echo ""
    echo "Derived snapshot updater (upgrade backfill)..."
    if ! backfill_derived_snapshot_updater; then
        echo "  ОШИБКА: governance snapshot updater не обновлён; обновление оставлено незавершённым." >&2
        return 1
    fi

    echo ""
    echo "Executor catalog generator (upgrade backfill)..."
    if ! backfill_executor_catalog_generator; then
        echo "  ОШИБКА: generator executor catalog не обновлён; обновление оставлено незавершённым." >&2
        return 1
    fi

    echo ""
    echo "Публикатор коммитов ds-publish.sh (upgrade backfill)..."
    backfill_ds_publish || echo "  ⚠ scripts/ds-publish.sh не доставлен: ночные роли оставят коммиты локальными, пока его нет (issue #941)." >&2

    echo ""
    echo "Executor catalog (upgrade backfill)..."
    backfill_executor_catalog || true

    echo ""
    echo "Knowledge Extractor feeders (upgrade backfill)..."
    backfill_extractor_feeders || true

    echo ""
    echo "FPF base copy (upgrade refresh)..."
    refresh_fpf_base_clone || true
}

# WP-5 F55 (High finding of F54, 03.09): setup.sh got the extractor feeders
# step, update.sh did not -- so every already-configured machine (the ones
# where the gap actually showed up) kept getting updates with the capture
# pipeline still not scheduled, forever. Runs from the post-apply chain, which
# also fires in the TOTAL_CHANGES=0 recovery branches, so an install that is
# otherwise up to date still gets its feeders. Re-running is safe: the feeders
# script skips an unchanged, already-loaded launchd job instead of unload/load
# (which would kill a run in flight at exactly 06:00/21:00).
backfill_extractor_feeders() {
    local feeders="$SCRIPT_DIR/scripts/setup-extractor-feeders.sh"
    local governance_repo="${EFFECTIVE_GOVERNANCE_REPO:-}"
    local feeders_output

    # Two steps, not one: `local x="$(f)"` would swallow a failing f, and an
    # empty repo name silently becomes the wrong default one level down.
    if [ -z "$governance_repo" ] && ! governance_repo=$(effective_governance_repo); then
        echo "  ○ Экстрактор: governance-репозиторий не определён, backfill пропущен."
        return 0
    fi

    if [ "${IWE_SKIP_EXTRACTOR_FEEDERS:-0}" = "1" ]; then
        echo "  ○ Экстрактор: пропущен (IWE_SKIP_EXTRACTOR_FEEDERS=1)."
        return 0
    fi
    # issue #768: the feeders script schedules a real launchd job under the
    # current user's real $HOME — a foreign/unowned host-global state must
    # not have that job's workspace pointer rewritten onto this copy.
    if $HOST_GLOBAL_OWNER_CONFLICT; then
        echo "  ○ Экстрактор: host-global расписание не изменено — $HOST_GLOBAL_OWNER_CONFLICT_REASON"
        return 0
    fi
    if [ ! -f "$feeders" ]; then
        echo "  ○ Экстрактор: scripts/setup-extractor-feeders.sh не найден, backfill пропущен."
        return 0
    fi
    # The feeders script exits 1 without the CLI; on update that is a normal
    # state (CLI not installed yet), not an update failure -- say what to run
    # later instead of printing its error.
    if ! command -v claude >/dev/null 2>&1; then
        echo "  ○ Экстрактор: claude CLI не установлен — расписание не заводим."
        echo "    После установки CLI: bash $feeders"
        return 0
    fi

    # --schedule-only, not install: an update may add the periodic job, but must
    # not redo the install-time decisions (the global git hook template, the
    # init.templateDir pointer, seeding fleeting-notes) on every single run.
    # IWE_WORKSPACE now passed (issue #768 fix) — the feeders script used to
    # hardcode $HOME/IWE regardless, which is exactly what let it silently
    # retarget a real host-global launchd job onto a disposable copy.
    if feeders_output=$(
        IWE_WORKSPACE="$WORKSPACE_DIR" \
        IWE_GOVERNANCE_REPO="$governance_repo" \
        IWE_RUNTIME="$WORKSPACE_DIR/.iwe-runtime" \
        bash "$feeders" --schedule-only 2>&1); then
        printf '%s\n' "$feeders_output" | sed 's/^/  /'
        return 0
    fi

    printf '%s\n' "$feeders_output" | sed 's/^/  /' >&2
    echo "  ⚠ Экстрактор не запустится автоматически — повторите вручную: bash $feeders" >&2
    return 1
}

# WP-5 F57: setup.sh clones ailev/FPF once and nothing refreshed it afterwards,
# so already-installed machines never received USING-FPF.md (the author's usage
# instruction) or the newer DPF Suites. Fast-forward only, tracked-clean copies
# only, never fatal: a modified, ahead or diverged copy is reported and left
# exactly as it was.
refresh_fpf_base_clone() {
    local fpf_dir="$WORKSPACE_DIR/FPF"
    local before after upstream head_oid fetch_status
    local fetch_limit="${IWE_FPF_FETCH_TIMEOUT:-90}"

    if [ "${IWE_SKIP_FPF_REFRESH:-0}" = "1" ]; then
        echo "  ○ FPF: пропущен (IWE_SKIP_FPF_REFRESH=1)."
        return 0
    fi
    # .git is a file, not a directory, in a linked worktree or a submodule.
    if [ ! -e "$fpf_dir/.git" ]; then
        echo "  ○ FPF: копия не найдена ($fpf_dir), обновление пропущено."
        return 0
    fi
    if [ -n "$(git -C "$fpf_dir" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
        echo "  ⚠ FPF: в копии есть локальные изменения — не обновляю, копия может быть устаревшей."
        return 0
    fi
    if ! before=$(git -C "$fpf_dir" rev-parse --short HEAD 2>/dev/null); then
        echo "  ⚠ FPF: не удалось прочитать состояние копии, обновление пропущено."
        return 0
    fi

    # The Sync Gate timeout wrapper launches git under one process-tree
    # supervisor and gives Windows a native PID. Git Bash's $! /proc winpid
    # can refer to a Bash shim whose native children are no longer in its
    # Windows ancestry; taskkill /T then reports success while fetch survives.
    case "$fetch_limit" in
        0|*[!0-9]*)
            echo "  ⚠ FPF: некорректный лимит IWE_FPF_FETCH_TIMEOUT — обновление копии пропущено."
            return 0
            ;;
    esac
    if [ ! -r "$SCRIPT_DIR/scripts/lib/git-sync-status.sh" ]; then
        echo "  ⚠ FPF: контроллер таймаута недоступен — обновление копии пропущено."
        return 0
    fi
    # shellcheck source=scripts/lib/git-sync-status.sh
    . "$SCRIPT_DIR/scripts/lib/git-sync-status.sh"
    fetch_status=0
    if GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=true \
        GIT_SSH_COMMAND='ssh -o BatchMode=yes -o ConnectTimeout=10' \
        _git_sync_run_with_timeout "$fetch_limit" \
        git -C "$fpf_dir" -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=30 \
        fetch --quiet >/dev/null 2>&1; then
        :
    else
        fetch_status=$?
    fi
    case "$fetch_status" in
        0) ;;
        124)
            echo "  ⚠ FPF: сервер не ответил за ${fetch_limit} с — копия остаётся как была и может быть устаревшей."
            return 0
            ;;
        125)
            echo "  ⚠ FPF: остановка дерева git не подтверждена; проверьте дочерние процессы. Копия может быть устаревшей."
            return 0
            ;;
        *)
            echo "  ⚠ FPF: не удалось получить обновления (ошибка Git или контроллера таймаута) — копия остаётся как была и может быть устаревшей."
            return 0
            ;;
    esac

    # Classify HEAD against the tracked upstream instead of trusting the exit
    # code of a merge: "already up to date" is also what a copy that is AHEAD
    # of the server reports, and an untracked-file collision fails the merge
    # for a reason that has nothing to do with history.
    if ! upstream=$(git -C "$fpf_dir" rev-parse --verify --quiet '@{u}' 2>/dev/null); then
        echo "  ⚠ FPF: у копии нет ветки слежения (отсоединённый HEAD или другая настройка) — не обновляю, копия может быть устаревшей."
        return 0
    fi
    if ! head_oid=$(git -C "$fpf_dir" rev-parse HEAD 2>/dev/null); then
        echo "  ⚠ FPF: не удалось прочитать состояние копии, обновление пропущено."
        return 0
    fi
    if [ "$head_oid" = "$upstream" ]; then
        echo "  ✓ FPF: копия уже актуальна ($before)."
        return 0
    fi
    if git -C "$fpf_dir" merge-base --is-ancestor "$upstream" "$head_oid" 2>/dev/null; then
        echo "  ⚠ FPF: в копии есть свои коммиты, которых нет на сервере — не трогаю."
        return 0
    fi
    if ! git -C "$fpf_dir" merge-base --is-ancestor "$head_oid" "$upstream" 2>/dev/null; then
        echo "  ⚠ FPF: история копии разошлась с сервером — не трогаю, копия может быть устаревшей."
        return 0
    fi
    if ! git -C "$fpf_dir" merge --ff-only --quiet "$upstream" 2>/dev/null; then
        echo "  ⚠ FPF: обновить не удалось (возможно, мешают неотслеживаемые файлы в копии) — копия остаётся как была."
        return 0
    fi
    if ! after=$(git -C "$fpf_dir" rev-parse --short HEAD 2>/dev/null); then
        echo "  ⚠ FPF: копия обновлена, но новое состояние прочитать не удалось."
        return 0
    fi
    echo "  ✓ FPF: копия обновлена $before → $after."
    return 0
}

record_rule_workspace_state() {
    local fpath="$1" src dst
    case "$fpath" in .claude/rules/*) ;; *) return 0 ;; esac
    src="$SCRIPT_DIR/$fpath"
    dst="$WORKSPACE_DIR/$fpath"
    if [ ! -f "$dst" ] || { [ -f "$src" ] && [ "$(hash_file "$src")" = "$(hash_file "$dst")" ]; }; then
        RULES_SAFE_TO_UPDATE="${RULES_SAFE_TO_UPDATE}${fpath}|"
    fi
}

rule_was_safe_to_update() {
    case "$RULES_SAFE_TO_UPDATE" in *"|$1|"*) return 0 ;; *) return 1 ;; esac
}

backup_rule_before_overwrite() {
    local fpath="$1" dst="$2" backup
    case "$fpath" in .claude/rules/*) ;; *) return 0 ;; esac
    [ -f "$dst" ] || return 0
    if [ -z "$RULES_BACKUP_RUN" ]; then
        RULES_BACKUP_RUN="$WORKSPACE_DIR/.backups/rules-pre-update/$(date -u +%Y%m%dT%H%M%SZ)-$$"
    fi
    backup="$RULES_BACKUP_RUN/${fpath#.claude/rules/}"
    mkdir -p "$(dirname "$backup")"
    cp "$dst" "$backup"
    echo "  ↳ backup: $dst → $backup"
}

# issue #847: memory/* stale-repair (see repair_pass() below) used to overwrite
# a workspace-local memory file with the template's version whenever hashes
# differed, with no backup — unlike .claude/rules/* above, which already has
# this via backup_rule_before_overwrite(). apply_memory_policy() now replaces only
# a copy it proved untouched, and saves it here first under its own backup dir.
# MEMORY_BACKUP_FILE names the saved copy; it is set before the attempt, so a
# warning can name it too. Returns non-zero when the copy could not be saved
# (mkdir and cp say why on stderr): the caller must then leave DST alone. The
# function used to end with an echo, so a failed cp read as success (#967 review).
backup_memory_file_before_overwrite() {
    local fpath="$1" dst="$2"
    MEMORY_BACKUP_FILE=""
    case "$fpath" in memory/*.md|memory/*.yaml|memory/*.yml) ;; *) return 0 ;; esac
    [ -f "$dst" ] || return 0
    if [ -z "$MEMORY_BACKUP_RUN" ]; then
        MEMORY_BACKUP_RUN="$WORKSPACE_DIR/.backups/memory-pre-update/$(date -u +%Y%m%dT%H%M%SZ)-$$"
    fi
    MEMORY_BACKUP_FILE="$MEMORY_BACKUP_RUN/${fpath#memory/}"
    mkdir -p "$(dirname "$MEMORY_BACKUP_FILE")" && cp "$dst" "$MEMORY_BACKUP_FILE"
}

copy_platform_file_preserving_user_space() {
    local src="$1" dst="$2" fpath="$3" user_section=""
    if [ -f "$dst" ]; then
        case "$fpath" in
            .claude/rules/*)
                user_section=$(sed -n '/^<!-- USER-SPACE -->/,/^<!-- \/USER-SPACE -->/p' "$dst" 2>/dev/null || true)
                if [ "$(hash_file "$src")" != "$(hash_file "$dst")" ] && ! rule_was_safe_to_update "$fpath"; then
                    backup_rule_before_overwrite "$fpath" "$dst"
                    echo "  ⚠ $fpath — рабочая копия отличается от прежнего шаблона; пользовательская правка сохранена."
                    echo "    Сверьте: diff \"$src\" \"$dst\""
                    return 1
                fi
                ;;
            .claude/skills/*/SKILL.md)
                # #1010 F3: the regular update path keeps the USER-SPACE block of a skill spec
                # (Step 5, SKILL.md branch); the repair/stale-repair path did not and dropped it.
                user_section=$(sed -n '/^<!-- USER-SPACE -->/,/^<!-- \/USER-SPACE -->/p' "$dst" 2>/dev/null || true)
                ;;
        esac
        backup_rule_before_overwrite "$fpath" "$dst"
    fi
    cp "$src" "$dst"
    if [ -n "$user_section" ]; then
        perl -i -0pe 's/^<!-- USER-SPACE -->.*?^<!-- \/USER-SPACE -->//ms' "$dst"
        perl -i -0pe 's/\n+$/\n/' "$dst"
        printf '\n%s\n' "$user_section" >> "$dst"
    fi
}

# iwe_claude_project_slug PATH — the directory name Claude Code uses under
# ~/.claude/projects for PATH: every character that is not an ASCII letter or
# digit becomes "-" (so "/", ".", "_" and " " all do): /Users/alice/IWE → -Users-alice-IWE.
# issue #869: three scripts used three different rules ("tr /", "tr /_.",
# "tr /_ "), and none converted a Git Bash path ("/f/notes") to the native form
# Claude Code actually sees ("F:\notes"). On Windows the native path comes from
# cygpath; the drive-letter case does not matter there, the file system is
# case-insensitive. A non-ASCII character becomes one dash (python3 counts characters
# whatever the locale - launchd and cron run with none; the sed fallback does the same
# only under a UTF-8 locale). Not verified against Claude Code for non-ASCII paths.
# KEEP IN SYNC with setup.sh and scripts/day-close.sh — the same function body;
# scripts/tests/test_issue_869_claude_slug.sh fails when the copies diverge.
iwe_claude_project_slug() {
    local path="$1" native=""
    if command -v cygpath >/dev/null 2>&1; then
        native=$(cygpath -w "$path" 2>/dev/null) || native=""
        [ -n "$native" ] && path="$native"
    fi
    if command -v python3 >/dev/null 2>&1 \
       && python3 -c 'import os, re, sys; sys.stdout.write(re.sub("[^A-Za-z0-9]", "-", os.fsencode(sys.argv[1]).decode("utf-8", "replace")))' "$path" 2>/dev/null; then
        return 0
    fi
    printf '%s' "$path" | sed 's/[^A-Za-z0-9]/-/g'
}

resolve_workspace_memory_dir() {
    local workspace="$1" physical="" computed slug legacy_slug legacy_dir
    slug=$(iwe_claude_project_slug "$workspace")
    computed="$HOME/.claude/projects/$slug/memory"
    if [ -d "$workspace/memory" ]; then
        physical=$(cd -P "$workspace/memory" 2>/dev/null && pwd -P) || return 1
    fi
    if [ -n "$physical" ] && [ -d "$computed" ]; then
        computed=$(cd -P "$computed" 2>/dev/null && pwd -P) || return 1
        if [ "$physical" != "$computed" ]; then
            # issue #869: installs made before the single slug rule pointed workspace/memory at
            # a directory named by an older rule ("tr /", "tr /_.", "tr /_ "). For a path with a
            # space or other punctuation that is not the directory Claude Code uses. The physical
            # link stays authoritative: accept it with a note instead of stopping the updater.
            for legacy_slug in "$(printf '%s' "$workspace" | tr '/' '-')" \
                               "$(printf '%s' "$workspace" | tr '/_.' '-')" \
                               "$(printf '%s' "$workspace" | tr '/_ ' '-')"; do
                legacy_dir="$HOME/.claude/projects/$legacy_slug/memory"
                if [ -d "$legacy_dir" ] && [ "$(cd -P "$legacy_dir" 2>/dev/null && pwd -P)" = "$physical" ]; then
                    echo "ВНИМАНИЕ: workspace/memory ведёт в $physical (каталог назван по прежнему правилу), а Claude Code читает $computed. Обновление продолжается с физической memory/." >&2
                    printf '%s\n' "$physical"
                    return 0
                fi
            done
            echo "ОШИБКА: memory target неоднозначен: workspace/memory → $physical, slug target → $computed" >&2
            return 1
        fi
    fi
    printf '%s\n' "${physical:-$computed}"
}

# Physical workspace/memory is authoritative; computed Claude slug is only a
# fallback for a first install without the link (#368).
CLAUDE_MEMORY_DIR=$(resolve_workspace_memory_dir "$WORKSPACE_DIR") || exit 1

# issue #350: the file lists printed further down cover only the template's own files.
# A normal run writes to several more places that never appeared in any preview, and
# users found out by losing an edit. Called from every branch that shows a preview,
# including the "no changes" one — there a repair-pass still writes to all of these.
print_extra_write_targets() {
    local governance_repo governance_dir
    if governance_repo=$(effective_governance_repo 2>/dev/null); then
        governance_dir="$WORKSPACE_DIR/$governance_repo"
    else
        governance_dir="$WORKSPACE_DIR/<invalid-GOVERNANCE_REPO>"
    fi
    echo "Кроме перечисленного, обычный запуск (без --check) также пишет — это зоны возможной перезаписи, пофайлового прогноза для них превью не строит (issue #350):"
    echo "  • $WORKSPACE_DIR/.claude/ — рабочие копии скиллов, хуков, правил"
    echo "  • $CLAUDE_MEMORY_DIR — рабочие копии memory-файлов"
    echo "  • $WORKSPACE_DIR/.iwe-runtime/ — пересобирается целиком из шаблона"
    echo "  • $WORKSPACE_DIR/.exocortex.env, $SCRIPT_DIR/.claude.md.base, $SCRIPT_DIR/update-manifest.json"
    echo "  • $WORKSPACE_DIR/.claude.md.base и $WORKSPACE_DIR/.claude.md.delivered — база слияния CLAUDE.md и запись хешей доставленной копии"
    echo "  • $WORKSPACE_DIR/.memory-deployed.tsv — запись версий памяти, которые установлены и не менялись (по ней update.sh отличает нетронутую копию от изменённой)"
    echo "  • $WORKSPACE_DIR/.iwe-paths и $HOME/.zshenv — пересоздаваемое окружение путей"
    echo "  • local core.hooksPath в git-репозиториях с .githooks под $WORKSPACE_DIR"
    echo "  • $governance_dir/scripts/install-hooks.sh — установщик platform hooks"
    echo "  • $governance_dir/.githooks/pre-commit и pre-push — platform hooks"
    echo "  • $governance_dir/scripts/day-open-llm-fill.py — platform reader профиля ошибок для Day Open"
    echo "  • $governance_dir/scripts/update-derived-snapshot.py — обновлятор derived snapshot"
    echo "  • $governance_dir/scripts/generate-executor-catalog.py — генератор каталога исполнителей"
    echo "  • $governance_dir/scripts/executor-catalog.yaml — каталог исполнителей"
    echo "  • $governance_dir/scripts/ds-publish.sh — публикатор коммитов ночных ролей (кладётся только если файла нет, существующий не трогается)"
    echo "  • $governance_dir/exocortex/agent-fault-profile/ — только миграция/права существующей приватной БД; отсутствующий профиль не создаётся"
    echo "    Symlink-пути блокируют backfill. Отличающиеся installer/hooks сохраняются в .git/hook-backups/ и заменяются."
    echo "    Локально изменённые Day Open reader/snapshot updater/executor-catalog generator блокируют обновление; executor-catalog.yaml — генерируемый файл и заменяется при смысловом расхождении."
    echo "  Расхождение рабочей копии с шаблоном чинится независимо от списков выше."
    echo ""
}

# fix #205: --check must not mutate update.sh itself. Shared by every --check exit so
# an added early return cannot quietly skip the guard.
assert_self_unmutated() {
    local self_hash_after
    self_hash_after=$(hash_file "$SCRIPT_DIR/update.sh")
    if [ "$SELF_HASH_BEFORE" != "$self_hash_after" ]; then
        echo "ОШИБКА: update.sh мутировал в режиме --check — это баг!" >&2
        exit 1
    fi
}

# run_sync_canary — issue #718: a mechanism that fails open (delivers a
# plausible-looking result instead of a loud error) can silently lose a fix
# for weeks before anyone notices, e.g. #717. wp-sync-bundle.sh --self-test
# already exercises the exact code path every WP Gate sync relies on
# (registry lookup + status-cell resolution); running it here catches a
# broken/unreadable registry the same day an update runs, not weeks later.
# No governance repo configured, or wp-sync-bundle.sh missing — SKIP, not
# FAIL: those are separate, already-diagnosed conditions elsewhere in
# update.sh, not a canary regression.
run_sync_canary() {
    local governance_repo
    governance_repo=$(effective_governance_repo) || { echo "  ℹ Canary (реестр РП): SKIP (governance repo не определён)"; return 0; }

    # effective_governance_repo() always returns a name (default DS-strategy)
    # even when that directory doesn't exist yet — a fresh install before the
    # pilot's first governance repo is set up. wp-sync-bundle.sh hard-exits 1
    # in that case ("Governance repo с WP-REGISTRY.md не найден"), which
    # run_sync_canary would otherwise report as a canary FAILURE rather than
    # the "not configured yet" SKIP it actually is.
    if [ ! -f "$WORKSPACE_DIR/$governance_repo/docs/WP-REGISTRY.md" ]; then
        echo "  ℹ Canary (реестр РП): SKIP ($governance_repo/docs/WP-REGISTRY.md ещё не существует)"
        return 0
    fi

    local sync_bundle="$WORKSPACE_DIR/$governance_repo/.claude/scripts/wp-sync-bundle.sh"
    if [ ! -x "$sync_bundle" ]; then
        sync_bundle="$SCRIPT_DIR/.claude/scripts/wp-sync-bundle.sh"
    fi
    if [ ! -x "$sync_bundle" ]; then
        echo "  ℹ Canary (реестр РП): SKIP (wp-sync-bundle.sh не найден)"
        return 0
    fi

    # IWE_TEMPLATE: a copy of the bundle kept in the governance repo has no scripts/lib next
    # to it, and the shared WP-number library (wp-num.sh, issue #954) lives in the template
    # clone -- tell the bundle where it is instead of failing the canary on a missing file.
    local canary_output canary_status
    canary_output=$(IWE_WORKSPACE="$WORKSPACE_DIR" IWE_GOVERNANCE_REPO="$governance_repo" \
        IWE_TEMPLATE="$SCRIPT_DIR" bash "$sync_bundle" --self-test 2>&1)
    canary_status=$?
    if [ "$canary_status" -eq 0 ]; then
        echo "  ✓ Canary (реестр РП): OK"
        return 0
    fi
    echo "  ✗ Canary (реестр РП) FAILED — реестр WP-Registry нечитаем или статус не резолвится:" >&2
    echo "$canary_output" | sed 's/^/    /' >&2
    return "$EXIT_CANARY_FAILED"
}

# exit_clean — the shared exit for every "this run completed with no
# operational error" path (peer-session 2026-08-21-09, Codex review
# consensus). Overrides EXIT_OK with EXIT_TAINTED when INTEGRITY_TAINTED is
# set — i.e. the grep-fallback ran (no Python), so file content was never
# verified by sha256, only file names were compared. It does not intercept
# any operational-error exit (EXIT_NETWORK/EXIT_RUNTIME/EXIT_CONFLICT) —
# those return directly and never reach this function, so a real failure
# is never masked by a tainted-but-otherwise-clean verdict.
exit_clean() {
    if $INTEGRITY_TAINTED; then
        echo "⚠ Завершено с непроверенной целостностью: Python недоступен, содержимое файлов не сверялось по контрольной сумме." >&2
        exit "$EXIT_TAINTED"
    fi
    exit "$EXIT_OK"
}

# Resolve main once before fetching the manifest.  Every subsequent download uses
# that immutable commit, so a push between manifest and file requests cannot mix
# hashes from one revision with content from another (issue #398).
github_api_get() {
    if [ "$#" -ne 1 ]; then
        echo "ОШИБКА: github_api_get требует один GitHub API URL" >&2
        return 1
    fi
    local trace_was_enabled=false
    case "$-" in
        *x*) trace_was_enabled=true; set +x ;;
    esac
    local api_url="$1" token="" auth_source="anonymous" endpoint result=0
    local curl_option numeric_value expecting_numeric="" unsafe_curl_options=false
    local glob_was_disabled=false
    local -a authenticated_curl_options=()
    case "$api_url" in
        https://api.github.com/*) ;;
        *)
            echo "ОШИБКА: github_api_get отклонил URL вне api.github.com" >&2
            $trace_was_enabled && set -x
            return 1
            ;;
    esac

    if [ -n "${GH_TOKEN:-}" ]; then
        token="$GH_TOKEN"
        auth_source="GH_TOKEN"
    elif [ -n "${GITHUB_TOKEN:-}" ]; then
        token="$GITHUB_TOKEN"
        auth_source="GITHUB_TOKEN"
    fi
    if [ -n "$token" ]; then
        if [ "${#token}" -gt 512 ]; then
            echo "ОШИБКА: $auth_source содержит недопустимый GitHub token." >&2
            $trace_was_enabled && set -x
            return "$GITHUB_API_INVALID_TOKEN"
        fi
        case "$token" in
            *[!A-Za-z0-9_]*)
                echo "ОШИБКА: $auth_source содержит недопустимый GitHub token." >&2
                $trace_was_enabled && set -x
                return "$GITHUB_API_INVALID_TOKEN"
                ;;
        esac
        # CURL_OPTS is intentionally flexible for anonymous downloads, but an
        # authenticated request must never inherit tracing, config, headers or
        # output flags that could persist the Authorization header. Parse a
        # small transport-only allowlist without eval (Bash 3.2 compatible).
        case "$-" in *f*) glob_was_disabled=true ;; *) set -f ;; esac
        for curl_option in ${CURL_BASE_OPTS:-}; do
            if [ -n "$expecting_numeric" ]; then
                numeric_value="$curl_option"
                case "$numeric_value" in
                    *[!0-9.]*|*.*.*|"") unsafe_curl_options=true ;;
                    *[0-9]*) authenticated_curl_options+=("$numeric_value") ;;
                    *) unsafe_curl_options=true ;;
                esac
                expecting_numeric=""
                $unsafe_curl_options && break
                continue
            fi
            case "$curl_option" in
                --insecure)
                    authenticated_curl_options+=("$curl_option")
                    ;;
                --max-time|--connect-timeout|--retry|--retry-delay|--retry-max-time)
                    authenticated_curl_options+=("$curl_option")
                    expecting_numeric="$curl_option"
                    ;;
                --max-time=*|--connect-timeout=*|--retry=*|--retry-delay=*|--retry-max-time=*)
                    numeric_value="${curl_option#*=}"
                    case "$numeric_value" in
                        *[!0-9.]*|*.*.*|"") unsafe_curl_options=true ;;
                        *[0-9]*) authenticated_curl_options+=("$curl_option") ;;
                        *) unsafe_curl_options=true ;;
                    esac
                    ;;
                *)
                    unsafe_curl_options=true
                    ;;
            esac
            $unsafe_curl_options && break
        done
        [ -z "$expecting_numeric" ] || unsafe_curl_options=true
        $glob_was_disabled || set +f
        if $unsafe_curl_options; then
            echo "ОШИБКА: authenticated GitHub API отклонил небезопасные CURL_OPTS; разрешены только transport timeout/retry и --insecure." >&2
            token=""
            $trace_was_enabled && set -x
            return "$GITHUB_API_UNSAFE_CURL_OPTIONS"
        fi
        if [ -n "${_CURL_SSL_OPT:-}" ]; then
            authenticated_curl_options+=("$_CURL_SSL_OPT")
        fi
        # Never put a credential in argv or xtrace. curl reads the one header
        # from stdin as configuration; -q must be argv[1] so curl cannot load
        # a user curlrc that enables tracing before it reads that header.
        if [ -n "${authenticated_curl_options[*]-}" ]; then
            printf 'header = "Authorization: Bearer %s"\n' "$token" | \
                curl -q "${authenticated_curl_options[@]}" -sSfL -K - "$api_url"
        else
            # Bash 3.2 with `set -u` treats an explicitly declared empty array
            # as unbound when expanded with "${array[@]}". Keep the zero-option
            # path expansion-free while preserving curl -q as argv[1].
            printf 'header = "Authorization: Bearer %s"\n' "$token" | \
                curl -q -sSfL -K - "$api_url"
        fi
        result=${PIPESTATUS[1]}
        if [ "$result" -ne 0 ]; then
            echo "ОШИБКА: authenticated GitHub API request via $auth_source failed; fallback disabled." >&2
            result="$GITHUB_API_AUTH_FAILURE"
        fi
        token=""
        $trace_was_enabled && set -x
        return "$result"
    fi

    if command -v gh >/dev/null 2>&1 && \
       GH_DEBUG='' DEBUG='' GH_PROMPT_DISABLED=1 \
           gh auth status --hostname github.com >/dev/null 2>&1; then
        # No leading slash (issue #980): Git Bash (MSYS) rewrites an argument that starts
        # with "/" into a Windows path ("C:/Program Files/Git/repos/...") before gh sees
        # it, and gh rejects that endpoint. gh accepts "repos/..." everywhere.
        endpoint="${api_url#https://api.github.com/}"
        if ! GH_DEBUG='' DEBUG='' GH_PROMPT_DISABLED=1 \
             gh api --hostname github.com --method GET "$endpoint"; then
            echo "ОШИБКА: authenticated GitHub API request via gh failed; fallback disabled." >&2
            result="$GITHUB_API_AUTH_FAILURE"
        fi
        $trace_was_enabled && set -x
        return "$result"
    fi

    # No explicit credential and no authenticated gh session: preserve the
    # public anonymous request path and its native curl status.
    # shellcheck disable=SC2086
    curl ${CURL_BASE_OPTS:-} ${_CURL_SSL_OPT:-} -sSfL "$api_url"
    result=$?
    $trace_was_enabled && set -x
    return "$result"
}

resolve_delivery_ref() {
    local resolved_ref release_tag release_json commit_json api_status
    if [ "$UPDATE_CHANNEL" = "release" ]; then
        # sed, not python: the tag must be resolvable even on installs where
        # py_available fails — a release tag is already an immutable-enough
        # pin, unlike the moving branch the no-python path degrades to below.
        release_json=""
        if release_json=$(github_api_get "$API_BASE/releases/latest"); then
            release_tag=$(printf '%s\n' "$release_json" | \
                sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
        else
            api_status=$?
            release_tag=""
        fi
        if [ -n "$release_tag" ]; then
            if py_available; then
                commit_json=""
                if commit_json=$(github_api_get "$API_BASE/commits/$release_tag"); then
                    api_status=0
                else
                    api_status=$?
                fi
            else
                api_status=0
                commit_json=""
            fi
            if [ "$api_status" -eq "$GITHUB_API_AUTH_FAILURE" ] || \
               [ "$api_status" -eq "$GITHUB_API_INVALID_TOKEN" ] || \
               [ "$api_status" -eq "$GITHUB_API_UNSAFE_CURL_OPTIONS" ]; then
                echo "ОШИБКА: authenticated release commit lookup failed; refusing fallback to tag." >&2
                exit "$EXIT_NETWORK"
            fi
            if py_available && [ -n "$commit_json" ] && \
               resolved_ref=$(printf '%s\n' "$commit_json" | "$PY_BIN" -c '
import json, re, sys
sha = json.load(sys.stdin).get("sha", "")
if not re.fullmatch(r"[0-9a-f]{40}", sha):
    raise SystemExit(1)
print(sha)'); then
                RAW_BASE="https://raw.githubusercontent.com/$REPO/$resolved_ref"
                echo "  Канал поставки: релиз $release_tag (снимок ${resolved_ref:0:12})"
                # issue #863: remember the release commit SHA for rollback detection.
                RELEASE_SHA="$resolved_ref"
            else
                RAW_BASE="https://raw.githubusercontent.com/$REPO/$release_tag"
                echo "  Канал поставки: релиз $release_tag (закреплён по тегу)"
                # Fallback: tag itself is the best SHA proxy we have.
                RELEASE_SHA="$release_tag"
            fi
            return 0
        fi
        # #501 (fail-closed, матрица внешнего пользователя по v0.38.7): молчаливый
        # откат на подвижную ветку превращал сбой резолва релиза в тихую доставку
        # непроверенного main — ровно то, от чего release-канал защищает. Явный
        # main-канал остаётся единственной дорогой к подвижной ветке.
        echo "ОШИБКА: не удалось определить последний релиз (нет релизов или API недоступен)." >&2
        echo "  Release-канал работает только от опубликованного релиза (fail-closed, #501)." >&2
        echo "  Повторите позже, либо осознанно выберите подвижную ветку:" >&2
        echo "    IWE_UPDATE_CHANNEL=main bash update.sh" >&2
        exit "$EXIT_NETWORK"
    fi
    if ! py_available; then
        echo "  ⚠ Нет python3: поставка проверяется по подвижной ветке $BRANCH."
        return 0
    fi
    # shellcheck disable=SC2086  # CURL_BASE_OPTS intentionally contains multiple flags.
    commit_json=""
    if commit_json=$(github_api_get "$API_BASE/commits/$BRANCH"); then
        api_status=0
    else
        api_status=$?
    fi
    if [ "$api_status" -eq "$GITHUB_API_AUTH_FAILURE" ] || \
       [ "$api_status" -eq "$GITHUB_API_INVALID_TOKEN" ] || \
       [ "$api_status" -eq "$GITHUB_API_UNSAFE_CURL_OPTIONS" ]; then
        echo "ОШИБКА: authenticated branch lookup failed; refusing anonymous or moving-branch fallback." >&2
        exit "$EXIT_NETWORK"
    fi
    if [ -n "$commit_json" ] && \
       resolved_ref=$(printf '%s\n' "$commit_json" | "$PY_BIN" -c '
import json, re, sys
sha = json.load(sys.stdin).get("sha", "")
if not re.fullmatch(r"[0-9a-f]{40}", sha):
    raise SystemExit(1)
print(sha)'); then
        RAW_BASE="https://raw.githubusercontent.com/$REPO/$resolved_ref"
        echo "  Снимок поставки: ${resolved_ref:0:12}"
    else
        echo "  ⚠ Не удалось закрепить $BRANCH по commit SHA; используется подвижная ветка."
    fi
}

# === Temp directory ===
TMPDIR_UPDATE=$(mktemp -d 2>/dev/null || { mkdir -p "/tmp/exocortex-update-$$"; echo "/tmp/exocortex-update-$$"; })
# issues #965/#967: Step 2 records here the version of each changed memory file that this run
# is about to replace (record_memory_old_hash); Step 6 reads it (apply_memory_policy, proof 1).
MEMORY_OLD_HASHES="$TMPDIR_UPDATE/memory-old-hashes.tsv"
cleanup_update() {
    local status=$?
    rm -rf "$TMPDIR_UPDATE"
    if [ "$UPDATE_TRANSACTION_STARTED" = true ] && [ "$status" -ne 0 ] && [ -f "$UPDATE_INCOMPLETE_MARKER" ]; then
        echo "⚠ Обновление завершилось не полностью; маркер сохранён: $UPDATE_INCOMPLETE_MARKER" >&2
        echo "  Применено файлов шаблона: ${APPLIED:-0} из ${TOTAL_CHANGES:-неизвестно}; рабочие копии могли обновиться частично." >&2
        echo "  Исправьте причину и перезапустите update.sh." >&2
    fi
    return "$status"
}
trap cleanup_update EXIT

echo "=========================================="
echo "  Exocortex Update v$VERSION"
echo "=========================================="
echo "  Репо: $SCRIPT_DIR"
echo ""
if [ -f "$UPDATE_INCOMPLETE_MARKER" ]; then
    echo "⚠ Найден маркер незавершённого обновления: $UPDATE_INCOMPLETE_MARKER"
    echo "  Предыдущий запуск мог применить только часть файлов; успешный повторный запуск снимет маркер."
    echo ""
fi

# Step 0 can replace this running updater and exec an older release before any
# later preflight runs. Missing configuration must stop every applying run here,
# before even the self-update; --check remains read-only.
if ! $CHECK_ONLY; then
    require_env_before_update
fi

# step0_integrity_check FILE — 0 when the downloaded update.sh FILE may replace the running one.
# No manifest, no network, no version parsing (#1004): the file says about itself whether it must
# end with the marker. An update.sh of this generation carries UPDATE_SH_INTEGRITY_TAG on its own
# line in the first 40 lines; such a file must END with UPDATE_SH_END_MARKER (last non-empty
# line), so a copy that kept its header but lost its tail, or has the marker in the middle, is
# refused. A file without the tag belongs to an older release (rollback, pin): the checks done
# before this function (non-empty, "#!", bash -n) plus a minimum length of UPDATE_SH_MIN_LINES. Sets STEP0_REJECT_REASON.
UPDATE_SH_INTEGRITY_TAG="# update-sh-integrity: end-marker-required"
UPDATE_SH_END_MARKER="# --- end of update.sh ---"
UPDATE_SH_MIN_LINES=100
step0_integrity_check() {
    local file="$1" last_line
    STEP0_REJECT_REASON=""
    # Trailing blanks and CR (a CRLF copy) do not change what a line says.
    if ! head -n 40 "$file" | sed 's/[[:space:]]*$//' | grep -qxF "$UPDATE_SH_INTEGRITY_TAG"; then
        # An older release has no tag; a real one is thousands of lines, so a few comment lines
        # after a shebang are a truncated answer, not an old updater.
        if [ "$(wc -l < "$file" | tr -d ' ')" -lt "$UPDATE_SH_MIN_LINES" ]; then
            STEP0_REJECT_REASON="ответ неполон (слишком короткий файл)"
            return 1
        fi
        return 0
    fi
    last_line=$(awk '{ sub(/[[:space:]]+$/, "") } NF { l = $0 } END { print l }' "$file")
    if [ "$last_line" != "$UPDATE_SH_END_MARKER" ]; then
        STEP0_REJECT_REASON="ответ неполон (последняя строка не конечный маркер)"
        return 1
    fi
    return 0
}

# === Step 0: Self-update (bootstrap) ===
# issue #505 root, part 1: the channel must be resolved BEFORE self-update.
# Step 0 used to fetch update.sh from the DEFAULT moving main while Step 1
# then pinned the delivery to the release snapshot — so the local update.sh
# ping-ponged between the main and release versions on every run, and Step 5
# always saw update.sh as "updated" (see part 2 at the apply loop).
resolve_delivery_ref
echo "[0] Проверка update.sh..."
# Capture hash before any network activity — used for --check integrity guard below (fix #205)
SELF_HASH_BEFORE=$(hash_file "$SCRIPT_DIR/update.sh")
REMOTE_UPDATE="$TMPDIR_UPDATE/update.sh.new"
STEP0_ERR="$TMPDIR_UPDATE/update.sh.err"
STEP0_RC=0
# shellcheck disable=SC2086  # CURL_BASE_OPTS/_CURL_SSL_OPT intentionally unquoted (multi-token flags)
curl $CURL_BASE_OPTS $_CURL_SSL_OPT -sSfL "$RAW_BASE/update.sh" -o "$REMOTE_UPDATE" 2>"$STEP0_ERR" || STEP0_RC=$?
if [ "$STEP0_RC" -ne 0 ]; then
    # issues #955/#980: "could not check" is not "checked, up to date". The failure used
    # to fall through to the "актуален" line below, with curl's cause thrown away.
    echo "  ⚠ не удалось проверить update.sh: $(curl_failure_note "$STEP0_RC" "$STEP0_ERR")"
elif [ ! -s "$REMOTE_UPDATE" ]; then
    # curl exit 0 with an empty body (a proxy or a login page that returns nothing) is a
    # failed check as well: the empty file differs from the local one, so it used to pass
    # for a newer update.sh and a normal run replaced the updater with a 0-byte file.
    echo "  ⚠ не удалось проверить update.sh: пустой ответ"
elif [ "$(head -c 2 "$REMOTE_UPDATE")" != "#!" ]; then
    # Same for an answer that is no script: HTTP 200 with the HTML of a Wi-Fi login page or a
    # proxy. update.sh starts with a "#!" line (any interpreter path, /bin/bash or
    # /usr/bin/env bash alike); anything else must not replace the running updater.
    echo "  ⚠ не удалось проверить update.sh: ответ не похож на скрипт"
elif ! bash -n "$REMOTE_UPDATE" 2>/dev/null; then
    # "#!" alone proves nothing about integrity: a script cut off in the middle (an incomplete
    # body served as a finished HTTP 200) starts with it too. A syntax check is the one test
    # that needs no reference hash, which Step 0 does not have yet (the manifest comes later),
    # and it runs with the same `bash` that the replacement is re-executed with.
    echo "  ⚠ не удалось проверить update.sh: ответ не похож на рабочий скрипт"
elif ! step0_integrity_check "$REMOTE_UPDATE"; then
    # Issue #1004: a syntactically whole stub (a shebang and comments) passes `bash -n` and
    # used to replace the updater, which then "succeeded" doing nothing. An update.sh that carries
    # UPDATE_SH_INTEGRITY_TAG must END with the marker; one without the tag is an older release
    # (rollback, pin) and keeps the checks above.
    echo "  ⚠ не удалось проверить update.sh: $STEP0_REJECT_REASON"
else
    LOCAL_HASH=$(hash_file "$SCRIPT_DIR/update.sh")
    REMOTE_HASH=$(hash_file "$REMOTE_UPDATE")
    if [ "$LOCAL_HASH" = "$REMOTE_HASH" ]; then
        echo "  update.sh актуален."
    elif $CHECK_ONLY; then
        # In --check mode: report available update without touching the file
        echo "  ⚠ Новая версия update.sh доступна. Запустите без --check для обновления."
    else
        echo "  Найдена новая версия update.sh — обновляю..."
        # issue #505 class (residual, found in the same sweep): replace
        # the RUNNING script via sibling tmp + mv — rename swaps the
        # directory entry and this process keeps its old inode; a plain cp
        # truncates the very file bash is executing. Historically survived
        # only because the few remaining commands sat in bash's read
        # buffer.
        _boot_staged="$SCRIPT_DIR/.update.sh.staged.$$"
        cp "$REMOTE_UPDATE" "$_boot_staged"
        chmod +x "$_boot_staged"
        mv -f "$_boot_staged" "$SCRIPT_DIR/update.sh"
        echo "  Перезапуск..."
        # #1010 F17: exec replaces the process, so the EXIT trap never runs and the temp
        # directory (update.sh.new, update.sh.err) would stay behind: remove it first.
        rm -rf "$TMPDIR_UPDATE"
        exec bash "$SCRIPT_DIR/update.sh" "$@"
    fi
fi
echo ""

# === Step 1: Fetch manifest ===
echo "[1] Загрузка манифеста..."
MANIFEST_URL="$RAW_BASE/update-manifest.json"
MANIFEST="$TMPDIR_UPDATE/manifest.json"

if ! fetch_update_manifest "$MANIFEST_URL" "$MANIFEST"; then
    echo "ОШИБКА: Не удалось загрузить манифест обновлений."
    echo "  URL: $MANIFEST_URL"
    echo "  Последний отказ: $FETCH_MANIFEST_DIAG"
    echo "  Проверьте подключение к интернету. Значение кода curl объясняет раздел EXIT CODES в man curl."
    echo "  Если такая же команда curl вручную работает, а здесь нет, приложите этот вывод к обращению (issue #943)."
    exit 1
fi

# schema v2 binds every delivered path to its content.  This makes --check --fast
# notice content-only releases and prevents a proxy/CDN mismatch from installing a
# file that does not belong to the downloaded manifest.
if py_available; then
    if ! $PY_BIN - "$MANIFEST" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    manifest = json.load(handle)
schema = manifest.get("schema_version", 1)
if schema >= 2:
    invalid = [
        entry.get("path", "<missing path>")
        for entry in manifest.get("files", [])
        if not re.fullmatch(r"[0-9a-f]{64}", entry.get("sha256", ""))
    ]
    if invalid:
        raise SystemExit("schema v2: missing/invalid sha256: " + ", ".join(invalid[:5]))
PY
    then
        echo "ОШИБКА: Манифест обновлений повреждён: schema v2 требует sha256 для каждого файла."
        exit 1
    fi
fi

# Parse version from manifest
UPSTREAM_VERSION=$(manifest_version "$MANIFEST")
echo "  Версия upstream: $UPSTREAM_VERSION"
echo ""

# === Fast check (issue #230): manifest-content comparison, skips the ~330-file download loop ===
# Достаточно для светофора Day Open (шаг 5) — полный список изменений всё ещё
# доступен через `--check` без `--fast`.
#
# issue #288: version-only сравнение молчало, когда files[] менялся (файлы
# добавлены/удалены/переименованы) без бампа версии — «✓ обновлений нет»,
# хотя доступны новые файлы. Манифест уже скачан выше (Step 1), поэтому
# сравнение хэша files[] той же стоимости, что версии, но ловит состав, не
# только номер. python3 недоступен → откат на version-only с явной пометкой
# (не тихий даунгрейд гарантии).
if $CHECK_ONLY && $FAST_CHECK; then
    LOCAL_MANIFEST="$SCRIPT_DIR/update-manifest.json"
    LOCAL_VERSION=""
    [ -f "$LOCAL_MANIFEST" ] && LOCAL_VERSION=$(manifest_version "$LOCAL_MANIFEST")

    if py_available && [ -f "$LOCAL_MANIFEST" ]; then
        # issue #402: paths passed via argv, not interpolated into the -c string —
        # MSYS only rewrites path-shaped argv values to Windows form, not text
        # baked into the script source, so an interpolated path silently fails
        # to open on native Windows Python.
        FILES_MATCH=$($PY_BIN -c "
import json, sys
def files_key(path):
    try:
        with open(path) as f:
            data = json.load(f)
    except Exception:
        return None
    return sorted(json.dumps(f, sort_keys=True) for f in data.get('files', []))
local_files = files_key(sys.argv[1])
upstream_files = files_key(sys.argv[2])
if local_files is None or upstream_files is None:
    print('unknown')
else:
    print('match' if local_files == upstream_files else 'differ')
" "$LOCAL_MANIFEST" "$MANIFEST" 2>/dev/null)
        VERSIONS_MATCH=false
        [ -n "$LOCAL_VERSION" ] && [ "$LOCAL_VERSION" = "$UPSTREAM_VERSION" ] && VERSIONS_MATCH=true
        # issue #288 review fix: FILES_MATCH="unknown" (manifest JSON unparseable
        # on either side) used to fall into the generic "версия отличается" branch
        # even when the two version STRINGS were in fact identical — printed the
        # same version number twice while claiming a mismatch. Four distinct cases
        # now, not three collapsed into one catch-all.
        if [ "$FILES_MATCH" = "match" ] && $VERSIONS_MATCH; then
            echo "✓ Версия и состав манифеста совпадают с upstream (v$UPSTREAM_VERSION). Обновлений нет."
        elif [ "$FILES_MATCH" = "differ" ]; then
            echo "⚠ Состав манифеста изменился (файлы добавлены/удалены/обновлены)."
            echo "  Для полного списка изменений: bash update.sh --check (без --fast)."
        elif $VERSIONS_MATCH; then
            echo "⚠ Версия совпадает (v$UPSTREAM_VERSION), но не удалось сверить состав манифеста (не распарсился JSON)."
            echo "  Для полного списка изменений: bash update.sh --check (без --fast)."
        else
            echo "⚠ Версия отличается: локально v${LOCAL_VERSION:-неизвестно}, upstream v$UPSTREAM_VERSION."
            echo "  Для полного списка изменений: bash update.sh --check (без --fast)."
        fi
    elif [ -n "$LOCAL_VERSION" ] && [ "$LOCAL_VERSION" = "$UPSTREAM_VERSION" ]; then
        echo "✓ Версия совпадает с upstream (v$UPSTREAM_VERSION). python3 не найден — состав манифеста не сверен."
    else
        echo "⚠ Версия отличается: локально v${LOCAL_VERSION:-неизвестно}, upstream v$UPSTREAM_VERSION."
        echo "  Для полного списка изменений: bash update.sh --check (без --fast)."
    fi
    exit 0
fi

# === Repair-pass для critical runtime files (issue #226) ===
# Закрывает два gap-а:
#   (1) «UNCHANGED ⇒ файл отсутствует» — ручное удаление / сбой предыдущего update.
#   (2) «UNCHANGED ⇒ файл stale» — файл есть, но hash расходится с FMT source
#       (возникает при частичном применении update, dirty workspace, или если workspace
#       не перезаписывал существующий файл при прошлом update).
# Функция (не инлайн), потому что нужна ДО раннего "TOTAL_CHANGES=0 ⇒ exit 0"
# (иначе repair недостижим ровно тогда, когда он нужнее всего — SCRIPT_DIR уже
# на актуальной версии от предыдущего запуска, а workspace остался stale) И
# после обычной propagation (Step 6) — чтобы не дублировать работу NEW/UPDATED_FILES.
# REPAIRED — глобальный счётчик, читается вызывающим кодом после возврата.
sync_workspace_agents() {
    [ -f "$SCRIPT_DIR/AGENTS.md" ] || return 0
    local ws_agents_new="$TMPDIR_UPDATE/ws-agents-new-substituted.md"
    local destination="$WORKSPACE_DIR/AGENTS.md"
    local destination_temp=""
    if [ -L "$destination" ]; then
        echo "  ✗ $destination — symbolic link is forbidden" >&2
        return 1
    fi
    if [ -e "$destination" ] && [ ! -f "$destination" ]; then
        echo "  ✗ $destination — existing target is not a regular file" >&2
        return 1
    fi
    substitute_claude_placeholders "$SCRIPT_DIR/AGENTS.md" "$ws_agents_new" || return 1
    if [ ! -f "$destination" ] || ! cmp -s "$destination" "$ws_agents_new"; then
        destination_temp=$(mktemp "$WORKSPACE_DIR/.AGENTS.md.update.XXXXXX") || {
            echo "  ✗ $destination — не удалось создать временный файл" >&2
            return 1
        }
        if ! cp "$ws_agents_new" "$destination_temp" || \
           ! mv -f "$destination_temp" "$destination"; then
            rm -f "$destination_temp"
            echo "  ✗ $destination не синхронизирован" >&2
            return 1
        fi
        echo "  ✓ $destination обновлён (generated, substituted)"
    fi
    return 0
}

repair_pass() {
    REPAIRED=0
    # Generated workspace instructions are part of repair, not only delivery:
    # both TOTAL_CHANGES=0 recovery branches must restore a missing/stale copy.
    sync_workspace_agents || return 1
    # Bash 3.2 (macOS) parses the apostrophe in the comment below before it
    # recognizes the closing `)` of a process substitution.  Keep the manifest
    # reader in ordinary temporary files: its diagnostics stay visible and the
    # repair pass remains available on the oldest supported shell.
    local repair_paths repair_errors
    # Every return below closes the memory pass with its summary: Step 6, before this pass,
    # may already have replaced or kept memory files in this run.
    repair_paths=$(mktemp "${TMPDIR:-/tmp}/iwe-repair-paths.XXXXXX") || {
        echo "  ⚠ repair_pass: не удалось создать временный список" >&2
        report_memory_policy_summary
        return 0
    }
    repair_errors=$(mktemp "${TMPDIR:-/tmp}/iwe-repair-errors.XXXXXX") || {
        rm -f "$repair_paths"
        echo "  ⚠ repair_pass: не удалось создать файл диагностики" >&2
        report_memory_policy_summary
        return 0
    }

    if py_available; then
        if ! $PY_BIN -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
for entry in data.get('files', []):
    print(entry['path'] + '|')
" "$MANIFEST" > "$repair_paths" 2> "$repair_errors"; then
            sed 's/^/  ⚠ repair_pass: /' "$repair_errors" >&2
            rm -f "$repair_paths" "$repair_errors"
            report_memory_policy_summary
            return 0
        fi
    else
        echo "  ⚠ repair_pass: python недоступен — сверка runtime-файлов пропущена" >&2
    fi

    [ -s "$repair_errors" ] && sed 's/^/  ⚠ repair_pass: /' "$repair_errors" >&2

    while IFS='|' read -r fpath _; do
        [ -z "$fpath" ] && continue
        [ ! -f "$SCRIPT_DIR/$fpath" ] && continue

        case "$fpath" in
            memory/*.md|memory/*.yaml|memory/*.yml)
                fname=$(basename "$fpath")
                [ "$fname" = "MEMORY.md" ] && continue
                if [ -d "$CLAUDE_MEMORY_DIR" ]; then
                    # Относительный путь от memory/ сохраняет вложенность (issue #287/#294) —
                    # basename ронял memory/reference/agent-core.md на плоский memory/agent-core.md,
                    # и 9 ссылок на него в CLAUDE.md указывали в никуда.
                    rel="${fpath#memory/}"
                    mem_dst="$CLAUDE_MEMORY_DIR/$rel"
                    mkdir -p "$(dirname "$mem_dst")"
                    if [ -f "$mem_dst" ] && is_personal_config "$fname"; then
                        : # личный L4-конфиг без frontmatter (day-rhythm-config.yaml) — НЕ stale-repair
                    elif [ -f "$mem_dst" ] && is_author_mode; then
                        # issue #238: та же дыра, что уже закрыта для .claude/*-веток ниже —
                        # автор мог доработать live-копию memory-файла напрямую, stale-repair
                        # молча затирал бы её версией из SCRIPT_DIR. An owner: user copy keeps
                        # its quiet report (report_author_user_memory), as before #965/#967.
                        if is_user_owned_memory "$mem_dst"; then
                            report_author_user_memory "$fpath" "$mem_dst"
                        else
                            echo "  ⚠ $fpath — author_mode: memory/ рабочая копия не тронута. Сверь: diff \"$SCRIPT_DIR/$fpath\" \"$mem_dst\""
                        fi
                    elif apply_memory_policy "$fpath" "$mem_dst"; then
                        # issues #965/#967: a missing copy is restored, an untouched stale one
                        # refreshed after a backup, an edited one kept (apply_memory_policy).
                        # No OLD_HASH here: the repair pass replaced nothing in its own run.
                        REPAIRED=$((REPAIRED + 1))
                    fi
                fi
                ;;
            # issue #891: the .claude/*.yaml|.claude/*.yml|.claude/*.example arm
            # covers loose top-level .claude/ files (rules-registry.yaml among
            # them). repair_pass() iterates the WHOLE manifest (every declared
            # path, not just subdirectories), so a missing/stale loose file needs
            # the same repair arm as the subdir ones, or it is silently skipped.
            .claude/skills/*|.claude/hooks/*|.claude/rules/*|.claude/rules-lazy/*|.claude/lib/*|.claude/bin/*|.claude/config/*|.claude/detectors/*|.claude/scripts/*|.claude/agents/*|.claude/styles/*|.claude/templates/*|.claude/*.yaml|.claude/*.yml|.claude/*.example)
                dst="$WORKSPACE_DIR/$fpath"
                if [ ! -f "$dst" ]; then
                    mkdir -p "$(dirname "$dst")"
                    if copy_platform_file_preserving_user_space "$SCRIPT_DIR/$fpath" "$dst" "$fpath"; then
                        case "$fpath" in *.sh|.claude/bin/*) chmod +x "$dst" ;; esac
                        echo "  ⟲ $fpath → workspace (repair)"
                        REPAIRED=$((REPAIRED + 1))
                    fi
                elif [ -r "$dst" ] && is_author_mode && [ "$(hash_file "$SCRIPT_DIR/$fpath")" != "$(hash_file "$dst")" ]; then
                    report_author_skip "$fpath" "$dst"
                elif [ -r "$dst" ] && [ "$(hash_file "$SCRIPT_DIR/$fpath")" != "$(hash_file "$dst")" ]; then
                    if copy_platform_file_preserving_user_space "$SCRIPT_DIR/$fpath" "$dst" "$fpath"; then
                        case "$fpath" in *.sh|.claude/bin/*) chmod +x "$dst" ;; esac
                        echo "  ⟲ $fpath → workspace (stale repair)"
                        REPAIRED=$((REPAIRED + 1))
                    fi
                fi
                ;;
            .claude/settings.json)
                # bug-2026-07-11: settings.json mixes L1 platform defaults with L4 user
                # hooks/permissions (custom security hooks, additionalDirectories, allow-list).
                # Treating it like a pure-L1 path (skills/hooks/rules/...) made every "hash
                # differs from template" stale-repair silently clobber the user's own hooks
                # back to the generic template — a live regression found and fixed live in
                # this file (see inbox/bugs/bug-2026-07-11-update-sh-settings-json-clobber.md).
                # Only seed on first install; never overwrite an existing file here.
                dst="$WORKSPACE_DIR/$fpath"
                if [ ! -f "$dst" ]; then
                    mkdir -p "$(dirname "$dst")"
                    cp "$SCRIPT_DIR/$fpath" "$dst"
                    echo "  ⟲ $fpath → workspace (repair, new install)"
                    REPAIRED=$((REPAIRED + 1))
                fi
                ;;
        esac
    done < "$repair_paths"
    rm -f "$repair_paths" "$repair_errors"
    if [ "$REPAIRED" -gt 0 ]; then
        echo "  ✓ $REPAIRED runtime-файлов восстановлено"
    fi
    report_memory_policy_summary
    # An explicit success: as a function (unlike the old inline block), this is
    # a plain top-level command at the call site, and its own exit status
    # (not exempted by the && short-circuit rule that saved the old inline code)
    # is what set -e sees.
    return 0
}

# issue #541 hvost 2 (Evgenii Red Team v0.38.11, #540): this used to be plain
# inline Step 6 code, reachable ONLY from the main apply-path below. Both
# TOTAL_CHANGES=0 early-exit branches (Step 2) call `repair_pass()` and then
# print success/no-op WITHOUT ever reaching Step 6 — so a workspace whose
# CLAUDE.md/.claude.md.base had drifted (while the FMT template copy itself
# was already fully up to date, hence TOTAL_CHANGES=0) had this exact
# reconciliation silently skipped and got told "Всё актуально" anyway.
# Wrapped in a function so both the early-exit paths and Step 6 can call it.
sync_workspace_claude_md() {
    CLAUDE_UPDATED=false
    # issue #289: раньше это было гейтом по членству "CLAUDE.md" в NEW_FILES/
    # UPDATED_FILES этого прогона — если Step 5 упал на конфликте, пилот разрешил
    # маркеры вручную и перезапустил update.sh, FMT-копия во втором прогоне уже ==
    # upstream → в UPDATED_FILES ничего не попадает → Step 6 молча пропускался,
    # workspace-копия и её .claude.md.base замирали навсегда без предупреждения.
    # Теперь триггер — реальное расхождение база/FMT-копия, а не факт правки в
    # ЭТОМ прогоне: закрывает и обрыв-и-перезапуск, и любой другой пропуск Step 5.
    NEEDS_WS_CLAUDE_SYNC=false
    if [ -f "$SCRIPT_DIR/CLAUDE.md" ]; then
        WS_NEW="$TMPDIR_UPDATE/ws-claude-new-substituted.md"
        substitute_claude_placeholders "$SCRIPT_DIR/CLAUDE.md" "$WS_NEW"
        if [ ! -f "$WORKSPACE_DIR/.claude.md.base" ] || ! diff -q "$WORKSPACE_DIR/.claude.md.base" "$WS_NEW" >/dev/null 2>&1; then
            NEEDS_WS_CLAUDE_SYNC=true
        fi
    fi
    if [ "$NEEDS_WS_CLAUDE_SYNC" = "true" ]; then
        # 3-way merge for workspace CLAUDE.md (same logic as repo copy)
        WS_BASE="$WORKSPACE_DIR/.claude.md.base"
        WS_CURRENT="$WORKSPACE_DIR/CLAUDE.md"
        # issue #846: records the WS_NEW content at the moment a conflict was
        # last written to $WS_CURRENT. $WS_BASE is deliberately never advanced
        # on conflict (issue #711), so once the pilot removes the markers by
        # hand, the branches below used to re-run the exact same 3-way merge
        # against the still-stale base and reproduce the exact same conflict
        # on every run. This sidecar lets that specific case be recognized
        # and the pilot's resolution accepted, instead of merged again.
        WS_CONFLICT_PENDING="$WORKSPACE_DIR/.claude.md.conflict-pending"

        # issue #711: a previous run left unresolved <<<<<<< markers in
        # $WS_CURRENT (pilot hasn't touched the file yet). Running
        # `git merge-file` again would 3-way-merge a file that already
        # contains literal marker lines as if they were real content —
        # confusing nested markers at best. Re-surface the same warning
        # without attempting a new merge; base stays untouched either way.
        if [ -f "$WS_CURRENT" ] && grep -q '^<<<<<<<' "$WS_CURRENT" 2>/dev/null; then
            echo "  ~ $WS_CURRENT (неразрешённый конфликт с прошлого запуска — сначала разрешите маркеры вручную)"
            CLAUDE_CONFLICT_DETECTED=true
            CLAUDE_CONFLICT_FILES+=("$WS_CURRENT")
        elif [ -f "$WS_CONFLICT_PENDING" ] && [ -f "$WS_BASE" ] && diff -q "$WS_CONFLICT_PENDING" "$WS_NEW" >/dev/null 2>&1; then
            # Markers are gone and the upstream CLAUDE.md hasn't moved since
            # the conflict that produced them — the pilot resolved it by hand.
            # Accept their file as the new ground truth instead of re-merging
            # it against the stale base (which is exactly what reproduced the
            # same conflict every run).
            cp "$WS_BASE" "$WS_BASE.bak-$(date -u +%Y%m%dT%H%M%SZ)"
            cp "$WS_NEW" "$WS_BASE"
            rm -f "$WS_CONFLICT_PENDING"
            echo "  ✓ $WS_CURRENT принят как разрешённый вручную (база обновлена, прежняя сохранена рядом)"
        elif [ -f "$WS_BASE" ] && [ -f "$WS_CURRENT" ] && command -v git >/dev/null 2>&1; then
            # Either the upstream template moved on since any earlier conflict
            # (a stale pending record no longer applies), or this is the very
            # first merge attempt — either way, a fresh merge decides next.
            rm -f "$WS_CONFLICT_PENDING"
            WS_MERGE_TMP="$TMPDIR_UPDATE/ws-claude-merge.md"
            cp "$WS_CURRENT" "$WS_MERGE_TMP"
            if git merge-file -p "$WS_MERGE_TMP" "$WS_BASE" "$WS_NEW" > "$TMPDIR_UPDATE/ws-claude-merged.md" 2>/dev/null; then
                WS_SILENT_LOSS=$(detect_claude_silent_loss "$WS_BASE" "$WS_CURRENT" "$TMPDIR_UPDATE/ws-claude-merged.md")
                if [ "$WS_SILENT_LOSS" -gt 0 ]; then
                    CLAUDE_SILENT_LOSS_FILES+=("$WS_CURRENT")
                    echo "  ⚠ $WS_CURRENT НЕ тронут — слияние потеряло бы $WS_SILENT_LOSS строк(и) без маркеров конфликта."
                    echo "    Сверьте вручную: diff \"$WS_CURRENT\" \"$WS_NEW\""
                else
                    cp "$TMPDIR_UPDATE/ws-claude-merged.md" "$WS_CURRENT"
                    cp "$WS_NEW" "$WS_BASE"
                    echo "  ✓ $WS_CURRENT обновлён (3-way merge)"
                fi
            else
                WS_CONFLICTS=$(grep -c '^<<<<<<<' "$TMPDIR_UPDATE/ws-claude-merged.md" 2>/dev/null || true); WS_CONFLICTS=${WS_CONFLICTS:-0}
                if [ "$WS_CONFLICTS" -eq 0 ]; then
                    # Non-zero without a single marker is not a conflict: git did not merge.
                    # Its (empty) output must not replace the pilot's file.
                    claude_merge_failed "$WS_CURRENT" "$WS_NEW"
                else
                    cp "$TMPDIR_UPDATE/ws-claude-merged.md" "$WS_CURRENT"
                    CLAUDE_CONFLICTS=$((CLAUDE_CONFLICTS + WS_CONFLICTS))
                    # issue #226: don't abort here — a CLAUDE.md conflict is an isolated
                    # artifact, not a reason to skip the rest of the delivery (memory/hooks/
                    # skills propagation, repair-pass, commit). Warn now, fail at the end.
                    # issue #711: do NOT advance $WS_BASE here (unlike the clean-merge
                    # branch above) — advancing it made the next run's `diff -q
                    # "$WORKSPACE_DIR/.claude.md.base" "$WS_NEW"` gate at the top of this
                    # function succeed even though $WS_CURRENT still had unresolved
                    # <<<<<<< markers, so update.sh reported "Всё актуально" on a corrupt
                    # file. Base now advances only once the markers are gone (see the
                    # pre-check above, which takes over on the next run).
                    # issue #846: record $WS_NEW so a future run whose markers are gone
                    # but whose $WS_NEW is unchanged can recognize a hand-resolved file
                    # (see $WS_CONFLICT_PENDING branch above) instead of re-merging it.
                    cp "$WS_NEW" "$WS_CONFLICT_PENDING"
                    echo "  ~ $WS_CURRENT ($WS_CONFLICTS конфликтов — разрешите вручную)"
                    echo "    Конфликты обозначены <<<<<<< / ======= / >>>>>>>"
                    CLAUDE_CONFLICT_DETECTED=true
                    CLAUDE_CONFLICT_FILES+=("$WS_CURRENT")
                fi
            fi
        elif [ ! -f "$WS_CURRENT" ]; then
            # No workspace CLAUDE.md yet — first install, nothing of the pilot's to lose.
            cp "$WS_NEW" "$WS_CURRENT"
            cp "$WS_NEW" "$WS_BASE"
            echo "  ✓ $WS_CURRENT создан"
        else
            # issue #336: WS_CURRENT already exists but .claude.md.base is missing/lost
            # (e.g. re-clone, migration gap) — a blind `cp $WS_NEW $WS_CURRENT` silently
            # discarded any pilot edit to §8/§9 that wasn't wrapped in explicit
            # <!-- USER-SPACE --> markers (those markers don't exist in the real §8/§9
            # format). Without a real base there is no safe 3-way merge — leave the
            # pilot's file untouched and surface it the same way an unresolved merge
            # conflict is surfaced, instead of guessing.
            WS_USER_SECTION=$(sed -n '/^<!-- USER-SPACE/,/^<!-- \/USER-SPACE/p' "$WS_CURRENT")
            if [ -n "$WS_USER_SECTION" ] && ! WS_BACKUP_DIR=$(claude_backup_before_replace "$WS_CURRENT"); then
                # #1004: no backup, no replacement.
                CLAUDE_BASE_MISSING_FILES+=("$WS_CURRENT")
                echo "  ⚠ $WS_CURRENT НЕ тронут — не удалось сделать резервную копию перед заменой."
                echo "    Сверьте свои правки вручную с шаблонной версией: diff \"$WS_CURRENT\" \"$WS_NEW\""
            elif [ -n "$WS_USER_SECTION" ]; then
                echo "  ⚠ $WS_CURRENT: правки вне блока USER-SPACE будут заменены версией шаблона; резервная копия: $WS_BACKUP_DIR"
                cp "$WS_NEW" "$WS_CURRENT"
                sed_inplace '/^<!-- USER-SPACE/,/^<!-- \/USER-SPACE/d' "$WS_CURRENT"
                echo "" >> "$WS_CURRENT"
                printf '%s\n' "$WS_USER_SECTION" >> "$WS_CURRENT"
                cp "$WS_NEW" "$WS_BASE"
                echo "  ✓ $WS_CURRENT обновлён (USER-SPACE сохранён, базовый файл создан)"
            else
                # issue #541 hvost 2 (Evgenii Red Team v0.38.11): same false-ancestry
                # bug as the FMT-copy branch above — writing WS_BASE = WS_NEW here
                # while leaving WS_CURRENT untouched would let the next run's 3-way
                # merge treat the still-stale WS_CURRENT as an intentional pilot
                # edit and clear .update-incomplete without ever really syncing it.
                # Leave the base absent so the drift keeps surfacing until resolved.
                CLAUDE_BASE_MISSING_FILES+=("$WS_CURRENT")
                echo "  ⚠ $WS_CURRENT НЕ тронут — базовый файл для слияния отсутствовал."
                echo "    Сверьте свои правки §8/§9 вручную с шаблонной версией: diff \"$WS_CURRENT\" \"$WS_NEW\""
            fi
        fi
        CLAUDE_UPDATED=true
    fi
}

# claude_backup_before_replace FILE — issue #1004: the no-base USER-SPACE branch replaces FILE with
# the template version and keeps only the marked block; everything the pilot wrote outside it
# (§8/§9 have no markers in the real format) is gone. Copy FILE into
# $WORKSPACE_DIR/.backups/claude-md-pre-update/<run>/ first and print where it went; non-zero
# (and nothing printed) when the copy failed: the caller must then leave FILE untouched.
claude_backup_before_replace() {
    local src="$1" dir
    dir="${WORKSPACE_DIR:-$SCRIPT_DIR}/.backups/claude-md-pre-update/$(date -u +%Y%m%dT%H%M%SZ)-$$"
    [ -L "${WORKSPACE_DIR:-$SCRIPT_DIR}/.backups" ] && return 1
    mkdir -p "$dir" || return 1
    cp -p "$src" "$dir/$(basename "$(dirname "$src")")-$(basename "$src")" || return 1
    printf '%s\n' "$dir"
}

# claude_template_copy_is_replaceable FILE — B1 (WP-7 F193): setup.sh (since v0.38.10) keeps the
# CLAUDE.md merge base only in the workspace root, never in the template repo, so Step 5 found no
# $SCRIPT_DIR/.claude.md.base on such installs and kept the #541 refusal on every run (exit 49,
# CLAUDE.md never updated, .update-incomplete forever). FILE is the delivered copy in the template
# repo: when a workspace base exists (the modern layout) and FILE was never edited
# (claude_template_copy_is_pristine), there is nothing to merge in it and upstream goes in as is;
# the pilot's own edits live in the workspace copy, merged against the workspace base in Step 6.
# Equality of FILE with the workspace base is NOT required: an unresolved workspace conflict keeps
# the base on the old release while the copy has already moved on (audit of v0.41.0, finding 1).
claude_template_copy_is_replaceable() {
    [ -n "${WORKSPACE_DIR:-}" ] && [ -f "$WORKSPACE_DIR/.claude.md.base" ] || return 1
    # An empty copy is a broken file, not an unedited one.
    [ -s "$1" ] || return 1
    claude_template_copy_is_pristine "$1"
}

# claude_record_usable FILE — the delivered record is trusted only when it looks exactly like what
# claude_record_delivered writes: a small regular file (not a symlink, FIFO or directory) made of lowercase hex
# digits and newlines. Anything else would hang the read (an endless source), flood it, vouch with text nobody
# here wrote or be bent by the shell on the way in (NUL bytes are dropped, a CR sticks to the line), so it counts
# as absent: the other two tests still apply and the next replacement writes a fresh record in its place (red
# team round 32: a FIFO in its place hung update.sh). A well-formed file can not be told apart from one this
# script wrote: whoever can write the workspace can edit the copy too.
claude_record_usable() {
    local size stray
    [ -f "$1" ] && [ ! -L "$1" ] || return 1
    size=$(wc -c < "$1" 2>/dev/null) || return 1
    size=${size//[[:space:]]/}
    case "$size" in '' | *[!0-9]*) return 1 ;; esac
    [ "$size" -le 1024 ] || return 1
    # pipefail inside the substitution: a failing tr must not be hidden by the wc after it (update.sh runs without pipefail)
    stray=$(set -o pipefail; LC_ALL=C tr -d '0-9a-f\n' < "$1" 2>/dev/null | wc -c) || return 1
    [ "${stray//[[:space:]]/}" = 0 ]
}

# claude_template_copy_is_pristine FILE — proof that FILE was never edited. Equality with the
# workspace base is no proof: the #541 refusal leaves an edited copy in place,
# sync_workspace_claude_md() then advances the base to that edited copy, and on the next run
# "copy == base" holds for it too (found by the round-16 peer review). So FILE must be, byte for byte,
#   - the file the installed update-manifest.json lists: the release this
#     install last updated to (Step 6e replaces the manifest only after Step 5,
#     so it is still the old one here), or
#   - the file committed at the clone's HEAD: an install that never took a
#     CLAUDE.md update, the stuck state this fix heals (update.sh commits
#     nothing, so on its own this holds only until the first update), or
#   - the file update.sh itself wrote into the template repo last time (claude_record_delivered):
#     a run that replaced the copy and then stopped before Step 6e replaced the manifest (a later
#     step failed, an interrupt) leaves the manifest on the OLD release, and update.sh commits nothing,
#     so HEAD stays old too; the next release would find the copy vouched for by neither (the record
#     is read only when claude_record_usable accepts it).
# A copy edited and then committed by hand passes the second test; its text stays in the history.
claude_template_copy_is_pristine() {
    local copy="$1" delivered committed copy_hash record
    CLAUDE_PROVEN_COPY_HASH=""
    # One read: the hash the proof is about is the one the record keeps (the copy must not be edited while
    # update.sh runs; an editor saving between two reads is outside what this can promise).
    copy_hash=$(hash_file "$copy" 2>/dev/null) || copy_hash=""
    [ -n "$copy_hash" ] || return 1
    delivered=$(manifest_sha256_of "$SCRIPT_DIR/update-manifest.json" "CLAUDE.md" 2>/dev/null) || delivered=""
    if [ -n "$delivered" ] && [ "$copy_hash" = "$delivered" ]; then
        CLAUDE_PROVEN_COPY_HASH="$copy_hash"
        return 0
    fi
    record="${WORKSPACE_DIR:-/nonexistent}/.claude.md.delivered"
    if claude_record_usable "$record" && grep -qxF -- "$copy_hash" <<< "$(head -c 1024 -- "$record" 2>/dev/null)"; then
        CLAUDE_PROVEN_COPY_HASH="$copy_hash"
        return 0
    fi
    command -v git >/dev/null 2>&1 || return 1
    committed=$(git -C "$SCRIPT_DIR" rev-parse --verify -q "HEAD:CLAUDE.md" 2>/dev/null) || return 1
    [ "$(git -C "$SCRIPT_DIR" hash-object -- "$copy" 2>/dev/null)" = "$committed" ] || return 1
    CLAUDE_PROVEN_COPY_HASH="$copy_hash"
}

# claude_record_delivered NEWFILE — remember two sha256 values: the template copy about to be replaced, as
# claude_template_copy_is_pristine just proved it (CLAUDE_PROVEN_COPY_HASH: the very hash that was proved,
# not a second read of a file an editor could have saved in between), and the upstream CLAUDE.md update.sh is
# about to write into the template repo (hashed from the SOURCE, so an edit saved in the meantime cannot
# become "delivered"). The record lives next to the workspace merge base: the template repo never receives
# either. The hashes are ADDED before the copy and the file keeps the last four lines: if the copy then
# fails or the run is interrupted before it changes, the copy still in place is vouched for by its own
# line, which every attempt writes again (a line that only the first attempt wrote would be pushed out by
# four failed ones), and a copy that was written is vouched for by the new line (round-25, 26 and 27 peer
# reviews). Only the shortcut calls this, so an edited copy never matches. Atomic (temp file, mv) and best
# effort: no failure here stops the update, and without the record the other two tests still apply. Not
# promised: two update.sh at once (the script has no lock anywhere), an editor saving the template copy
# while update.sh runs, a kill in the middle of cp itself (a half-written copy matches nothing and is refused).
# The earlier lines are carried over only from a record claude_record_usable accepts; whatever else stands there
# (a symlink, a FIFO, junk, CRLF text) is replaced, a directory is left alone.
claude_record_delivered() {
    [ -n "${WORKSPACE_DIR:-}" ] && [ -d "$WORKSPACE_DIR" ] || return 0
    local record="$WORKSPACE_DIR/.claude.md.delivered" tmp hash hashes="" kept="" line
    # mv would move the temp file INTO a directory standing at that path: leave such a path alone
    [ ! -d "$record" ] || return 0
    [ -z "${CLAUDE_PROVEN_COPY_HASH:-}" ] || hashes="$CLAUDE_PROVEN_COPY_HASH"$'\n'
    hash=$(hash_file "$1" 2>/dev/null) || hash=""
    [ -z "$hash" ] || hashes="$hashes$hash"$'\n'
    [ -n "$hashes" ] || return 0
    if claude_record_usable "$record"; then
        # earlier lines (a sha256 each, and not one this run writes again); a hex line of another length is dropped
        while IFS= read -r line || [ -n "$line" ]; do
            [ "${#line}" -eq 64 ] || continue
            case $'\n'"$hashes" in *$'\n'"$line"$'\n'*) continue ;; esac
            kept="$kept$line"$'\n'
        done < <(head -c 1024 -- "$record" 2>/dev/null)
    fi
    tmp=$(mktemp "$record.tmp.XXXXXX" 2>/dev/null) || return 0
    if printf '%s%s' "$kept" "$hashes" | tail -n 4 > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$record" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
    else
        rm -f "$tmp" 2>/dev/null || true
    fi
    return 0
}

# claude_merge_failed FILE NEW — `git merge-file` failed without a conflict to show (no
# markers in its output): there is no merge result, so FILE is left exactly as it is, the
# merge base is not advanced and the run ends in EXIT_CONFLICT with a pointer to git.
claude_merge_failed() {
    CLAUDE_MERGE_FAILED_FILES+=("$1")
    echo "  ⚠ $1 НЕ тронут — git merge-file не выдал слияния (git не работает или файл нечитаем?)."
    echo "    Проверьте: git --version. Сверить вручную: diff \"$1\" \"$2\""
}

# issue #541 cold-review (P2, DP.SC.172): the CLAUDE.md conflict/missing-base
# check-then-exit-49 idiom now has 3 call sites (the two new early-exit gates
# below, plus the pre-existing final gate at the end of the script) — third
# repetition, extract instead of copy-pasting a fourth time.
claude_conflict_gate() {
    if $CLAUDE_CONFLICT_DETECTED || [ "${#CLAUDE_BASE_MISSING_FILES[@]}" -gt 0 ] || [ "${#CLAUDE_SILENT_LOSS_FILES[@]}" -gt 0 ] \
        || [ "${#CLAUDE_MERGE_FAILED_FILES[@]}" -gt 0 ]; then
        echo "  ⚠ Workspace-копия CLAUDE.md требует ручной сверки (см. предупреждения выше)."
        exit "$EXIT_CONFLICT"
    fi
}

# === Step 2: Download and compare files ===
echo "[2] Сравнение файлов..."

NEW_FILES=()
NEW_DESCS=()
UPDATED_FILES=()
UPDATED_LINES=()
SKIPPED_DOWNLOAD=()   # issue #350: manifest files whose fetch failed — status unknown, not "unchanged"
UNCHANGED=0
CLAUDE_CONFLICTS=0  # unresolved CLAUDE.md merge conflict counter (WP-7)
# issue #226: a CLAUDE.md conflict must not abort delivery of the rest of the
# update (memory/hooks/skills, repair-pass, commit) — it's an isolated artifact.
# Collect it here and fail at the very end instead of exiting mid-script.
CLAUDE_CONFLICT_DETECTED=false
CLAUDE_CONFLICT_FILES=()
# issue #336: a missing .claude.md.base (no real 3-way merge possible) is a
# different failure than an actual merge conflict — no <<<<<<< markers, the
# file was simply left untouched. Tracked separately so the final summary
# doesn't tell the pilot to look for markers that were never written.
CLAUDE_BASE_MISSING_FILES=()
# issue #555: a THIRD failure class, distinct from both of the above — a real
# base existed, `git merge-file` reported success, no markers, but a pilot's
# customized line still vanished from the result. Also left untouched and
# reported separately (detect_claude_silent_loss above), so the summary
# points at the right cause instead of "no base file" or "look for markers".
CLAUDE_SILENT_LOSS_FILES=()
# WP-7 F193 (round-16 cold review): a FOURTH class — git itself failed. `git merge-file`
# exited non-zero without a single conflict marker and without a merge result (a macOS
# whose Command Line Tools went missing prints an xcrun error and exits 1 for every git
# command). The empty output used to be copied over CLAUDE.md as a "clean" merge.
CLAUDE_MERGE_FAILED_FILES=()

# WP-546 (peer-session 2026-08-20-11, WP-546 Ф2 consensus with Codex): the
# manifest loop used to run one `curl` per file, sequentially — 632 files at
# ~0.65s/file (measured) means ~7min on an ordinary network, and users on
# slower/higher-latency connections reported 40+ minutes. Split into two
# phases: (1) a network-free pass builds a download worklist (three parallel
# indexed arrays, not `declare -A` — that needs bash 4.0+, but this script's
# #!/bin/bash shebang resolves to the system bash on macOS, which is 3.2;
# same reasoning as download_batch's positional-args choice below), skipping
# protected files and files whose local sha256 already matches the manifest
# (no network call for either); (2) a single `curl --parallel` call downloads
# the worklist, followed by one retry pass (network failures AND integrity
# failures — GitHub's raw CDN edges can briefly disagree after a fresh push,
# so a retry can succeed where the first attempt didn't). Per-file
# classification (NEW/UPDATED/UNCHANGED, the issue #254 merge-base detector)
# runs unchanged after download, just reading from $TMPDIR_UPDATE/files/
# instead of a variable populated file-by-file.
DOWNLOAD_QUEUE=()
DOWNLOAD_DESCS=()
DOWNLOAD_HASHES=()
# INTEGRITY_TAINTED (peer-session 2026-08-21-09, WP-546 review follow-up,
# consensus with Codex): true when the fallback path (grep, no sha256 in
# the manifest lines it emits) is in use — a real parser failure below
# aborts the script outright instead (cold-context review, same
# peer-session: an earlier version of this comment claimed the flag also
# covered that case, which was never reachable — exit happens before this
# flag would be set). The old fallback comment claimed integrity was
# "already documented via SKIPPED_DOWNLOAD, not silently trusted" — false:
# an empty expected_hash makes verify_batch_integrity() skip the file
# (`[ -n "$expected_hash" ] || continue`), so a corrupted or substituted
# download was silently accepted as good. This flag makes that condition
# visible in the final verdict instead of printing an ordinary success.
INTEGRITY_TAINTED=false

# Parse the manifest into a plain temp file first, not directly via process
# substitution into the while-loop below (peer-session 2026-08-21-09: the
# original code piped the parser straight into `while read`, so a Python
# crash mid-parse — bad JSON, missing field, encoding error — just produced
# a short or empty stream that `while read` silently accepted as "few/no
# files to update," indistinguishable from a real empty manifest). Written
# under $TMPDIR_UPDATE, which cleanup_update()'s EXIT trap already removes.
MANIFEST_PARSED="$TMPDIR_UPDATE/manifest-parsed.txt"
if py_available; then
    # Path via argv (issue #402, defect 2), not interpolated into the -c
    # string — see FILES_MATCH above. stderr is NOT redirected here (was
    # `2>/dev/null`): a parse failure on our own manifest should be rare, and
    # silencing it left nothing to diagnose why the run below fell back to
    # "no changes."
    if ! $PY_BIN -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
for entry in data.get('files', []):
    print(entry['path'] + '|' + entry.get('desc', '') + '|' + entry.get('sha256', ''))
" "$MANIFEST" > "$MANIFEST_PARSED"; then
        echo "✗ Не удалось разобрать манифест обновлений ($MANIFEST) — Python вернул ошибку (см. вывод выше)." >&2
        echo "  Обновление остановлено: продолжать со сбойным разбором значило бы рискнуть тихо решить, что обновлять нечего." >&2
        exit "$EXIT_RUNTIME"
    fi
else
    # Fallback: basic grep parsing if no working python interpreter. No
    # sha256 in this path — integrity verification is skipped entirely, so
    # every file below counts as unverified (INTEGRITY_TAINTED, not merely
    # "checked composition only" as the old comment claimed).
    INTEGRITY_TAINTED=true
    # WP-529 F26: одна строка в общем потоке вывода терялась между десятками
    # других — пользователь узнавал о работе без проверки целостности только по
    # коду возврата 4, если вообще на него смотрел. Рамка и явные последствия
    # делают деградацию заметной в момент, когда она происходит.
    echo "" >&2
    echo "┌──────────────────────────────────────────────────────────────────┐" >&2
    echo "│ ⚠  ОБНОВЛЕНИЕ БЕЗ ПРОВЕРКИ ЦЕЛОСТНОСТИ                           │" >&2
    echo "└──────────────────────────────────────────────────────────────────┘" >&2
    echo "  Python недоступен, поэтому контрольные суммы SHA-256 не проверяются." >&2
    echo "  Сверяется только состав файлов: подменённое или повреждённое" >&2
    echo "  содержимое в этом режиме обнаружено НЕ будет." >&2
    echo "  Обновление завершится с кодом $EXIT_TAINTED вместо 0 — это не ошибка," >&2
    echo "  а отметка, что проверка целостности не выполнялась." >&2
    echo "  Как вернуть полную проверку: установите python3 и повторите запуск." >&2
    echo "" >&2

    # High 2 fail-closed guard (peer-session 2026-08-21-12, Codex, revised
    # after cold-context review found the first version tautological — the
    # extracted-count and found-count were both built from the same grep, so
    # they were always equal even when sed extracted garbage). The fallback
    # assumes one "path" key per line — a compact/minified manifest (several
    # entries on one line) silently breaks that assumption, and the old code
    # just extracted the FIRST match per line instead of failing, losing
    # every other entry with no signal. A line-count heuristic
    # (`wc -l == 1`) was considered and rejected: a trailing-newline-less
    # minified file gives 0, and a compact multi-line manifest can still
    # pack several "path" keys onto one physical line. Check the actual
    # assumption — how many "path" occurrences share a line — not a proxy
    # for it.
    #
    # Scope decision (same peer-session, second round): this fallback
    # supports ONLY the line-per-field layout this repo's own manifest
    # generator produces — "path" preceded solely by whitespace on its
    # line, per PATH_LINE_RE below. A compact single-file manifest like
    # {"files":[{"path":"x.md"}]} is valid JSON but NOT supported here and
    # correctly hits EXIT_RUNTIME (test-update-issue-226.sh Scenario H) —
    # a looser prefix (^.*"path") was considered and rejected: it would
    # let arbitrary text ahead of the real key mask corruption or a "path"
    # match inside an unrelated string value, undermining the whole-line
    # grammar match's actual guarantee.
    #
    # Every grep below has an explicit 0/1/>1 status check (peer-session
    # 2026-08-21-12, High 2): this script has `set -e` but not `pipefail`,
    # so a grep failing inside a pipe or process substitution would
    # otherwise be silently absorbed by the next command in the chain —
    # exactly the "fail-open under error" this guard exists to prevent.
    # grep_or_die PATTERN FILE DEST-VAR — runs "grep -c PATTERN FILE",
    # writes stdout to DEST-VAR (a file path), returns 0. Aborts the script
    # on any grep exit status other than 0 (matches found) or 1 (no
    # matches) — status >1 means grep itself failed to read/execute.
    grep_or_die() {
        local pattern="$1" file="$2" dest="$3" rc=0
        grep -c -- "$pattern" "$file" > "$dest" 2>/dev/null || rc=$?
        if [ "$rc" -gt 1 ]; then
            echo "✗ Не удалось прочитать манифест обновлений для резервного разбора (grep вернул код ${rc})." >&2
            exit "$EXIT_RUNTIME"
        fi
        return 0
    }

    # -c counts MATCHING LINES; that's exactly what both guards need — the
    # multi-path check cares whether ANY line has 2+ occurrences (a line
    # either qualifies as a violation or doesn't), and once that guard has
    # passed, "at most one path per line" makes line-count and
    # occurrence-count the same number for the total.
    MULTI_PATH_COUNT_FILE=$(mktemp)
    grep_or_die '"path".*"path"' "$MANIFEST" "$MULTI_PATH_COUNT_FILE"
    MULTI_PATH_LINES=$(cat "$MULTI_PATH_COUNT_FILE")
    rm -f "$MULTI_PATH_COUNT_FILE"
    if [ "$MULTI_PATH_LINES" -gt 0 ]; then
        echo "✗ Манифест обновлений в компактном/минифицированном формате (несколько записей на одной строке) — резервный разбор без Python это не поддерживает." >&2
        echo "  Обновление остановлено: обычная извлечённая запись отбросила бы соседние записи на той же строке без предупреждения." >&2
        exit "$EXIT_RUNTIME"
    fi

    PATH_KEY_COUNT_FILE=$(mktemp)
    grep_or_die '"path"' "$MANIFEST" "$PATH_KEY_COUNT_FILE"
    PATH_KEY_TOTAL=$(cat "$PATH_KEY_COUNT_FILE")
    rm -f "$PATH_KEY_COUNT_FILE"

    # grep_or_die's -c count above already confirms whether "path" occurs;
    # the actual matching lines still need a second, non-counting pass
    # (grep without -c) to feed the per-line grammar check below. Same
    # explicit-status contract as grep_or_die: status 1 (no matches) can't
    # happen here (PATH_KEY_TOTAL already proved matches exist above), so
    # >0 is unconditionally a read error, not "no matches." The `|| grep_rc=$?`
    # form (not a bare `grep ...; grep_rc=$?`, found by cold-context review)
    # matters under `set -e`: a plain non-zero exit from an unguarded
    # command aborts the script on that line — the following `grep_rc=$?`
    # would never run, so a failing grep would kill the script with a raw
    # exit 1/2 instead of this guard's own EXIT_RUNTIME.
    PATH_LINES_FILE=$(mktemp)
    grep_rc=0
    grep -- '"path"' "$MANIFEST" > "$PATH_LINES_FILE" 2>/dev/null || grep_rc=$?
    if [ "$grep_rc" -gt 0 ]; then
        echo "✗ Не удалось прочитать манифест обновлений для резервного разбора (grep вернул код ${grep_rc})." >&2
        exit "$EXIT_RUNTIME"
    fi

    # Whole-line grammar match (peer-session 2026-08-21-12, Codex: validate
    # the full line belongs to the supported form BEFORE extracting, not
    # just eyeball what sed happened to return). Supported form only:
    # optional leading whitespace, "path", optional whitespace, colon,
    # optional whitespace, a double-quoted value with no embedded '"' or
    # '\' (this fallback cannot decode JSON escapes), then anything after
    # the closing quote (comma, more keys) is accepted without further
    # constraint since it isn't part of the path value itself.
    PATH_LINE_RE='^[[:space:]]*"path"[[:space:]]*:[[:space:]]*"[^"\\]+".*$'
    PATH_ENTRIES_FOUND=0
    : > "$MANIFEST_PARSED"
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        case "$line" in
            *'"path"'*)
                if ! printf '%s\n' "$line" | grep -Eq -- "$PATH_LINE_RE"; then
                    echo "✗ Резервный разбор манифеста: строка с ключом \"path\" не в поддерживаемой форме (строка $((PATH_ENTRIES_FOUND + 1)) среди найденных совпадений)." >&2
                    echo "  Поддерживается только: \"path\": \"значение_без_кавычек_и_обратных_слэшей\" на одной строке." >&2
                    exit "$EXIT_RUNTIME"
                fi
                fpath=$(printf '%s\n' "$line" | sed -E 's/^[[:space:]]*"path"[[:space:]]*:[[:space:]]*"([^"\\]+)".*$/\1/')
                if [ -z "$fpath" ]; then
                    echo "✗ Резервный разбор манифеста: строка совпала с формой, но извлечённое значение пути пустое." >&2
                    exit "$EXIT_RUNTIME"
                fi
                PATH_ENTRIES_FOUND=$((PATH_ENTRIES_FOUND + 1))
                echo "$fpath|" >> "$MANIFEST_PARSED"
                ;;
        esac
    done < "$PATH_LINES_FILE"
    rm -f "$PATH_LINES_FILE"

    if [ "$PATH_ENTRIES_FOUND" -ne "$PATH_KEY_TOTAL" ]; then
        echo "✗ Резервный разбор манифеста нашёл ${PATH_KEY_TOTAL} ключ(ей) \"path\", но подтверждённо извлёк только ${PATH_ENTRIES_FOUND} запись(ей) — формат манифеста не полностью соответствует ожиданиям этого разбора." >&2
        exit "$EXIT_RUNTIME"
    fi
fi

# Duplicate-path check (peer-session 2026-08-21-09, Codex: must run on every
# parsed manifest path BEFORE the skip/protected-file filtering below, not
# after — a duplicate can disappear from DOWNLOAD_QUEUE if one copy gets
# skip-if-hash-matches while the other doesn't, hiding the very condition
# this check exists to catch). Two manifest entries writing the same
# destination race inside download_batch()'s parallel transfer and each
# other's --remove-on-error cleanup; this is corrupt manifest data, not a
# transient network condition, so the run stops instead of continuing with
# an unspecified winner.
DUPLICATE_PATHS=$(cut -d'|' -f1 "$MANIFEST_PARSED" | LC_ALL=C sort | LC_ALL=C uniq -d)
if [ -n "$DUPLICATE_PATHS" ]; then
    echo "✗ Манифест обновлений содержит повторяющиеся пути файлов:" >&2
    echo "$DUPLICATE_PATHS" | sed 's/^/  /' >&2
    echo "  Обновление остановлено — параллельная докачка гарантированно верна только для уникальных путей." >&2
    exit "$EXIT_RUNTIME"
fi

# issue #660: update-manifest.local.json's excluded_paths was previously read
# ONLY by the orphan detector (Step 6f below) — a fork declaring a path there
# got no effect on delivery itself, so update.sh kept silently overwriting
# the very file the fork asked to keep, with no distinct signal in the
# preview (the line looked like an ordinary update, not a revert). Loading
# the same list here, before the file classification loop, lets a
# fork-owned path skip application — reported separately below, not folded
# into an unremarkable "unchanged".
FORK_OWNED_PATHS_FILE="$TMPDIR_UPDATE/fork-owned-paths.txt"
: > "$FORK_OWNED_PATHS_FILE"
if py_available && [ -f "$SCRIPT_DIR/update-manifest.local.json" ]; then
    # Cold-context review finding: this ran unguarded under `set -e` — a
    # malformed local manifest (top-level list instead of object; an
    # excluded_paths entry missing "path") raised an uncaught Python
    # exception and killed the ENTIRE update, not just this feature. The
    # narrow except below only ever covered "file unreadable", not "file
    # readable but wrong shape". `if ! ... ; then` + a broad except make this
    # match the orphan detector's already-established fail-soft pattern
    # (Step 6f below): a malformed local manifest degrades to "no fork-owned
    # paths declared", it does not abort the run.
    if ! $PY_BIN -c "
import json, sys

path = sys.argv[1]
try:
    with open(path) as f:
        data = json.load(f)
    for entry in data.get('excluded_paths', []):
        print(entry['path'] if isinstance(entry, dict) else entry)
except (json.JSONDecodeError, OSError, AttributeError, KeyError, TypeError) as exc:
    print(f'  [warn] update-manifest.local.json unreadable, ignored: {exc}', file=sys.stderr)
" "$SCRIPT_DIR/update-manifest.local.json" > "$FORK_OWNED_PATHS_FILE"; then
        echo "  ⚠ update-manifest.local.json: не удалось разобрать excluded_paths — fork-owned защита для этого запуска пропущена." >&2
        : > "$FORK_OWNED_PATHS_FILE"
    fi
fi
FORK_OWNED_PATHS=()
while IFS= read -r fork_owned_entry; do
    [ -n "$fork_owned_entry" ] && FORK_OWNED_PATHS+=("$fork_owned_entry")
done < "$FORK_OWNED_PATHS_FILE"
FORK_PROTECTED_SKIPPED=()

# is_fork_owned_path REL — true when REL equals a declared excluded_paths
# entry or sits under one as a directory prefix. Same semantics as Step 6f's
# Python _locally_excluded() below — kept in bash here since this runs inside
# the per-file classification loop, not the Python orphan scan.
is_fork_owned_path() {
    local rel="$1" entry
    for entry in "${FORK_OWNED_PATHS[@]}"; do
        entry="${entry%/}"
        if [ "$rel" = "$entry" ] || [ "${rel#"$entry"/}" != "$rel" ]; then
            return 0
        fi
    done
    return 1
}

while IFS='|' read -r fpath fdesc expected_hash; do
    [ -z "$fpath" ] && continue
    # issue #402 (defect 3): native Windows Python prints \r\n even inside a
    # pipe read by Git Bash — the trailing \r rides along in the LAST field
    # (expected_hash) and makes every sha256 comparison below fail forever,
    # silently skipping all 593 manifest files. Strip unconditionally; a no-op
    # on real Unix output.
    expected_hash="${expected_hash%$'\r'}"
    # Protected user files (issue #154): never overwrite if they already exist locally.
    # The "Не затрагиваются" list below is cosmetic; is_protected_user_file() is the
    # actual skip-if-exists guard (shared with the deprecated-file removal loop below).
    if is_protected_user_file "$fpath" && [ -f "$SCRIPT_DIR/$fpath" ]; then
        UNCHANGED=$((UNCHANGED + 1))
        continue
    fi
    # Fork-declared ownership (issue #660): only meaningful once the file
    # actually diverges from upstream — a declared-but-unchanged path is
    # nothing to report, so it counts as an ordinary unchanged file.
    if is_fork_owned_path "$fpath" && [ -f "$SCRIPT_DIR/$fpath" ]; then
        if [ -n "$expected_hash" ] && [ "$(hash_file "$SCRIPT_DIR/$fpath")" != "$expected_hash" ]; then
            FORK_PROTECTED_SKIPPED+=("$fpath")
        else
            UNCHANGED=$((UNCHANGED + 1))
        fi
        continue
    fi
    # skip-if-hash-matches (WP-546 Ф2): a manifest sha256 that already matches
    # the local file needs no network round-trip at all — this is the other
    # half of the speedup alongside parallel download, since a typical update
    # leaves most files unchanged.
    if [ -n "$expected_hash" ] && [ -f "$SCRIPT_DIR/$fpath" ] && [ "$(hash_file "$SCRIPT_DIR/$fpath")" = "$expected_hash" ]; then
        UNCHANGED=$((UNCHANGED + 1))
        continue
    fi
    DOWNLOAD_QUEUE+=("$fpath")
    DOWNLOAD_DESCS+=("$fdesc")
    DOWNLOAD_HASHES+=("$expected_hash")
done < "$MANIFEST_PARSED"

# curl_supports_parallel_batch — one-time capability probe (peer-session
# 2026-08-21-09, consensus with Codex): --parallel/--parallel-max shipped
# together in curl 7.66.0, --remove-on-error only in 7.83.0, so a curl with
# the first two but not the third is a real, not hypothetical, combination.
# `curl --help all` lists every option this curl build understands regardless
# of network access — checked once here, not per-batch, since download_batch()
# below runs multiple times (initial pass + retry).
curl_supports_parallel_batch() {
    local help_output
    help_output=$(curl --help all 2>&1) || return 1
    echo "$help_output" | grep -q -- '--parallel[^-]' || return 1
    echo "$help_output" | grep -q -- '--parallel-max' || return 1
    echo "$help_output" | grep -q -- '--remove-on-error' || return 1
}
USE_PARALLEL_DOWNLOAD=true
if ! curl_supports_parallel_batch; then
    USE_PARALLEL_DOWNLOAD=false
    echo "⚠ Установленный curl не поддерживает параллельное скачивание (--parallel/--parallel-max/--remove-on-error) — используется более медленный последовательный режим." >&2
fi

# download_batch FPATH... — downloads the given fpaths to
# $TMPDIR_UPDATE/files/$fpath, either as one curl --parallel call (fast path)
# or one curl invocation per file (sequential fallback, only when
# USE_PARALLEL_DOWNLOAD=false). Positional args, not a nameref: `local -n`
# needs bash 4.3+, but this script's #!/bin/bash shebang resolves to the
# system bash on macOS, which is 3.2 — a nameref there fails "local: -n:
# invalid option" and silently no-ops the whole download instead of
# erroring, since `local`'s exit status doesn't trip `set -e` (found live
# testing this exact function).
#
# -f makes curl treat an HTTP error page (404) as a failure instead of
# writing it to disk as if it were the real file — without it a missing
# manifest entry silently "downloads" successfully. Existence of the
# destination file (not its size — a legitimate zero-length file is a valid
# transfer, peer-session 2026-08-21-08/09) is the "did this file actually
# arrive" signal downstream, which is why both paths below guarantee a
# failed transfer leaves no file behind: the parallel path via
# --remove-on-error, the sequential path via a .part-then-rename so a
# curl exit status other than 0 never leaves a destination file at all.
download_batch() {
    [ $# -eq 0 ] && return 0
    local p dst
    if $USE_PARALLEL_DOWNLOAD; then
        local cfg batch_err batch_rc=0
        # Under $TMPDIR_UPDATE, not a bare mktemp (cold-context review,
        # peer-session 2026-08-21-09): cleanup_update()'s EXIT trap removes
        # $TMPDIR_UPDATE wholesale, so a signal or crash between this mktemp
        # and the `rm -f "$cfg"` below no longer leaks a temp file — the old
        # bare mktemp location was outside that trap's reach.
        cfg=$(mktemp "$TMPDIR_UPDATE/curl-batch.XXXXXX")
        batch_err="$cfg.err"
        for p in "$@"; do
            dst="$TMPDIR_UPDATE/files/$p"
            mkdir -p "$(dirname "$dst")"
            printf 'url = "%s/%s"\noutput = "%s"\n' "$RAW_BASE" "$p" "$dst" >> "$cfg"
        done
        # shellcheck disable=SC2086  # CURL_BASE_OPTS/_CURL_SSL_OPT intentionally unquoted (multi-token flags)
        # `|| batch_rc=$?`: a batch failing outright (e.g. every URL in it
        # unreachable) must not trip `set -e` and abort the whole update —
        # the per-file presence check right after this call is what
        # actually decides success per file, same as the old code's
        # per-file `if curl ...` (Ф2 peer-session review; all found live
        # testing this exact function).
        # -sS (not the default progress meter): stderr goes to a file whose last
        # line names the cause, shown below only when the batch failed (#980).
        curl $CURL_BASE_OPTS $_CURL_SSL_OPT -sS -f --remove-on-error --parallel --parallel-max 8 -K "$cfg" 2>"$batch_err" || batch_rc=$?
        if [ "$batch_rc" -ne 0 ]; then
            echo "  ⚠ пакетная загрузка: $(curl_failure_note "$batch_rc" "$batch_err")" >&2
        fi
        rm -f "$cfg" "$batch_err"
    else
        # Sequential fallback (peer-session 2026-08-21-09): one curl call
        # per file, same CURL_BASE_OPTS/-f as the parallel path. No
        # --remove-on-error here (that's the capability we're missing) —
        # curl writes to a temp sibling and it's renamed into place only on
        # exit status 0, so a failed transfer never leaves a destination
        # file, matching the parallel path's guarantee.
        #
        # A predictable "$dst.part" suffix (cold-context review found this,
        # peer-session 2026-08-21-09) can collide with a manifest entry that
        # is itself literally that name — e.g. paths "a" and "a.part" both
        # present: downloading "a" would overwrite "a.part"'s own live temp
        # file mid-transfer, or clobber it after "a.part" already landed.
        # mktemp in the same destination directory makes the temp name
        # unpredictable and immune to any manifest content.
        #
        # A failed call names its file and curl's cause (#980); the first 5 per
        # call are shown, the rest are counted, so a dead network cannot flood
        # the output with one line per manifest entry.
        local dst_tmp seq_err="$TMPDIR_UPDATE/curl-single.err" seq_rc failed=0
        for p in "$@"; do
            dst="$TMPDIR_UPDATE/files/$p"
            mkdir -p "$(dirname "$dst")"
            dst_tmp=$(mktemp "$dst.XXXXXX")
            # shellcheck disable=SC2086
            if curl $CURL_BASE_OPTS $_CURL_SSL_OPT -sS -f -o "$dst_tmp" "$RAW_BASE/$p" 2>"$seq_err"; then
                mv "$dst_tmp" "$dst"
            else
                seq_rc=$?
                rm -f "$dst_tmp"
                failed=$((failed + 1))
                if [ "$failed" -le 5 ]; then
                    echo "  ⚠ $p: $(curl_failure_note "$seq_rc" "$seq_err")" >&2
                fi
            fi
        done
        if [ "$failed" -gt 5 ]; then
            echo "  ⚠ ещё $((failed - 5)) сбоев загрузки не показано (первые 5 выше)" >&2
        fi
        rm -f "$seq_err"
    fi
}

# verify_batch_integrity — removes any downloaded file whose sha256 doesn't
# match its manifest hash, so it reads as "missing" to whatever retry logic
# runs next. Index-based (not a linear scan for each fpath against
# DOWNLOAD_QUEUE — that's O(n²) over a 600+ file manifest and was called
# twice): DOWNLOAD_QUEUE/DOWNLOAD_DESCS/DOWNLOAD_HASHES are parallel arrays,
# so the caller's index into DOWNLOAD_QUEUE is also the index into
# DOWNLOAD_HASHES, no lookup needed.
verify_batch_integrity() {
    local i fpath expected_hash remote_file
    for i in "${!DOWNLOAD_QUEUE[@]}"; do
        fpath="${DOWNLOAD_QUEUE[$i]}"
        expected_hash="${DOWNLOAD_HASHES[$i]}"
        [ -n "$expected_hash" ] || continue
        remote_file="$TMPDIR_UPDATE/files/$fpath"
        # -f, not -s (peer-session 2026-08-21-08/09): a legitimate
        # zero-length file is a valid transfer, not a failed one. Both
        # download_batch() paths guarantee a failed transfer leaves no
        # destination file at all (--remove-on-error / .part-then-rename),
        # so existence alone is now a reliable "did this arrive" signal.
        [ -f "$remote_file" ] || continue
        if [ "$(hash_file "$remote_file")" != "$expected_hash" ]; then
            # A retry can still recover this file from a different CDN edge
            # (see the retry-pass comment below), so this isn't necessarily
            # its final fate — but the specific reason (integrity, not a
            # network failure) matters for diagnosis and was silently lost
            # when this check moved out of the old per-file loop, which did
            # print it (setup/test-update-issue-226.sh Scenario C caught the
            # regression).
            echo "  ⚠ $fpath: sha256 не совпадает с манифестом" >&2
            rm -f "$remote_file"
        fi
    done
}

if [ ${#DOWNLOAD_QUEUE[@]} -gt 0 ]; then
    if $USE_PARALLEL_DOWNLOAD; then
        printf "  Скачиваю %s файлов (до 8 параллельно)...\n" "${#DOWNLOAD_QUEUE[@]}"
    else
        printf "  Скачиваю %s файлов (последовательно)...\n" "${#DOWNLOAD_QUEUE[@]}"
    fi
    download_batch "${DOWNLOAD_QUEUE[@]}"

    # Integrity check BEFORE building the retry queue (Ф2 peer-session
    # review: the original version checked integrity only in the final loop,
    # after retry — so a hash mismatch could never actually get retried
    # despite the comment below promising it).
    verify_batch_integrity

    # Retry pass: anything not present now — network failure on the first
    # attempt, or an integrity mismatch just removed above — gets one more
    # attempt. Integrity failures are retried too (not just network
    # failures): a stale CDN edge can disagree with the manifest briefly
    # after a fresh push, and a second attempt can land on a different edge
    # that already has the current content.
    RETRY_QUEUE=()
    for fpath in "${DOWNLOAD_QUEUE[@]}"; do
        # -f, not -s — see verify_batch_integrity() above for why existence
        # alone is now the correct "did this arrive" signal.
        [ -f "$TMPDIR_UPDATE/files/$fpath" ] || RETRY_QUEUE+=("$fpath")
    done
    if [ ${#RETRY_QUEUE[@]} -gt 0 ]; then
        download_batch "${RETRY_QUEUE[@]}"
        verify_batch_integrity
    fi
fi

DOWNLOAD_IDX=0
for _dq_i in "${!DOWNLOAD_QUEUE[@]}"; do
    fpath="${DOWNLOAD_QUEUE[$_dq_i]}"
    fdesc="${DOWNLOAD_DESCS[$_dq_i]}"
    DOWNLOAD_IDX=$((DOWNLOAD_IDX + 1))
    printf "  (%s/%s) %s\r" "$DOWNLOAD_IDX" "${#DOWNLOAD_QUEUE[@]}" "$fpath"

    REMOTE_FILE="$TMPDIR_UPDATE/files/$fpath"

    # issue #350: a failed download used to `continue` silently — the file landed in
    # no list at all, not even the UNCHANGED counter, so the preview said nothing about
    # it while a later run (network back) applied it. "Could not check" is not "up to
    # date"; it now gets its own list and taints the verdict below. Integrity
    # failures already removed the file above (both passes), so a missing
    # file here covers both causes — the category split (network vs.
    # integrity) that the old per-file loop reported is no longer knowable
    # after two retry rounds have run, so both land in the same list.
    # -f, not -s — see verify_batch_integrity() above for why existence
    # alone is now the correct "did this arrive" signal.
    if [ ! -f "$REMOTE_FILE" ]; then
        SKIPPED_DOWNLOAD+=("$fpath")
        continue
    fi

    if [ ! -f "$SCRIPT_DIR/$fpath" ]; then
        # New file
        NEW_FILES+=("$fpath")
        NEW_DESCS+=("$fdesc")
    else
        # Existing file — compare hashes
        LOCAL_HASH=$(hash_file "$SCRIPT_DIR/$fpath")
        REMOTE_HASH=$(hash_file "$REMOTE_FILE")
        # issue #254: merge-managed файл (3-way merge, напр. CLAUDE.md) законно
        # расходится с upstream локальными кастомизациями → local≠remote всегда.
        # Для таких файлов детектор сравнивает base↔remote: upstream не двигался
        # с последнего merge — «без изменений». Детект по наличию .base-файла.
        MERGE_BASE="$(dirname "$fpath")/.$(basename "$fpath" | tr '[:upper:]' '[:lower:]').base"
        if [ -f "$SCRIPT_DIR/$MERGE_BASE" ]; then
            BASE_HASH=$(hash_file "$SCRIPT_DIR/$MERGE_BASE")
            if [ "$BASE_HASH" = "$REMOTE_HASH" ]; then
                UNCHANGED=$((UNCHANGED + 1))
                continue
            fi
        fi
        if [ "$LOCAL_HASH" != "$REMOTE_HASH" ]; then
            DIFF_COUNT=$(diff "$SCRIPT_DIR/$fpath" "$REMOTE_FILE" 2>/dev/null | grep -c '^[<>]' || true); DIFF_COUNT=${DIFF_COUNT:-?}
            UPDATED_FILES+=("$fpath")
            UPDATED_LINES+=("$DIFF_COUNT")
            # issues #965/#967: the version update.sh installed last time, before Step 5 replaces
            # it — Step 6 tells an untouched memory copy from an edited one by it.
            case "$fpath" in
                memory/*.md|memory/*.yaml|memory/*.yml) record_memory_old_hash "$fpath" "$LOCAL_HASH" ;;
            esac
        else
            UNCHANGED=$((UNCHANGED + 1))
        fi
    fi
done
printf "\n"

# === Step 2b: Deprecated files (устаревшие L1-файлы к удалению) ===
DEPRECATED_FOUND=()
DEPRECATED_REASONS=()

if is_upstream_git_mirror; then
    echo "  ⚠ Каталог шаблона — git-зеркало с remote upstream: удаление устаревших файлов пропущено. Их должен удалить сам канон."
else
while IFS='|' read -r fpath freason; do
    [ -z "$fpath" ] && continue
    # Same guard as the download loop above: a protected user file must never be
    # deleted either, even if a future manifest lists it as deprecated by mistake
    # (bug found 2026-07-23 — sessions/00-index.md was listed, protection didn't apply).
    is_protected_user_file "$fpath" && continue
    # issue #660 (cold-context review finding): without this, a fork-declared
    # excluded_paths entry protected a file from being silently OVERWRITTEN
    # but not from being silently DELETED if a future upstream manifest
    # listed the same path under deprecated_files — defeating the guarantee
    # this whole feature exists to give.
    is_fork_owned_path "$fpath" && continue
    if [ -f "$SCRIPT_DIR/$fpath" ]; then
        DEPRECATED_FOUND+=("$fpath")
        DEPRECATED_REASONS+=("${freason:-устарел}")
    fi
done < <(
    if py_available; then
        $PY_BIN -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
# 2026-08-22 (external report): a path present in BOTH the delivered files
# set and deprecated_files is a generator inconsistency — removal deleted 10
# files HEAD still ships, right after a clean no-change update. Delivery wins;
# the conflict is reported, never acted on. generate-manifest.sh now filters
# this at the source; this guard protects against a bad published manifest.
delivered = {e.get('path') for e in data.get('files', [])}
for entry in data.get('deprecated_files', []):
    path = entry.get('path','')
    if path in delivered:
        print('  ⚠ %s: и в поставке, и в deprecated_files — удаление пропущено (несогласованный манифест)' % path, file=sys.stderr)
        continue
    print(path + '|' + entry.get('reason',''))
" "$MANIFEST" || true
    fi)
fi

TOTAL_CHANGES=$(( ${#NEW_FILES[@]} + ${#UPDATED_FILES[@]} + ${#DEPRECATED_FOUND[@]} ))

# === Step 3: Display results ===
echo ""
echo "=========================================="
echo "  Обновления экзокортекса (v$UPSTREAM_VERSION)"
echo "=========================================="
echo ""

# issue #350: files whose download failed are reported before any verdict — a partial
# comparison must never render as "everything is current".
if [ ${#SKIPPED_DOWNLOAD[@]} -gt 0 ]; then
    echo "Не удалось проверить (${#SKIPPED_DOWNLOAD[@]}):"
    for f in "${SKIPPED_DOWNLOAD[@]}"; do
        printf "  ? %s — файл не скачался, состояние неизвестно\n" "$f"
    done
    echo "  Эти файлы могут отличаться от upstream и быть перезаписаны при обычном запуске."
    echo ""
fi

# issue #660: a fork-owned path (declared in update-manifest.local.json's
# excluded_paths) that actually diverges from upstream needs its own line —
# folding it into an ordinary "updated" entry is exactly the silent-revert
# report that made the fork lose the same local edit twice in one day.
if [ ${#FORK_PROTECTED_SKIPPED[@]} -gt 0 ]; then
    echo "Защищены форк-локальной правкой, не применены (${#FORK_PROTECTED_SKIPPED[@]}):"
    for f in "${FORK_PROTECTED_SKIPPED[@]}"; do
        printf "  ~ %s — локальная версия отличается от upstream, оставлена как есть (excluded_paths)\n" "$f"
    done
    echo ""
fi

# Same principle as SKIPPED_DOWNLOAD above, for a different failure mode
# (peer-session 2026-08-21-09): the fallback manifest parser has no sha256,
# so "no differences found" here means "no differences among what we could
# verify by name only" — the verdict below must say so, not read as an
# ordinary clean success.
if $INTEGRITY_TAINTED; then
    echo "⚠ Проверка целостности не выполнялась (Python недоступен) — сравнивался только состав файлов, не их содержимое."
    echo ""
fi

# WP-529 Ф2: TOTAL_CHANGES=0 branch below already refuses to apply anything and
# leaves the local manifest version untouched when a download/integrity check
# failed. But when OTHER files genuinely changed (TOTAL_CHANGES>0), nothing
# used to stop Step 5 from applying those and then Step 6e replacing the local
# manifest wholesale — stamping the run as "updated to vX" while the files in
# SKIPPED_DOWNLOAD silently stayed on the old version. Abort here, before Step 4
# confirmation/Step 5 apply, so a partial fetch never produces a partial write.
if [ "$TOTAL_CHANGES" -gt 0 ] && [ ${#SKIPPED_DOWNLOAD[@]} -gt 0 ] && ! $CHECK_ONLY; then
    echo "✗ Обновление остановлено: ${#SKIPPED_DOWNLOAD[@]} файл(ов) не скачались или не прошли проверку целостности (список выше)."
    echo "  Применение остальных ${TOTAL_CHANGES} изменений отменено — иначе локальный манифест пометил бы обновление как завершённое, а эти файлы остались бы старыми."
    echo "  Ничего не изменено. Повторите запуск, когда сеть будет доступна."
    exit "$EXIT_NETWORK"
fi

if [ "$TOTAL_CHANGES" -eq 0 ] && [ ${#SKIPPED_DOWNLOAD[@]} -gt 0 ]; then
    # Not "up to date" — merely "no differences among the files we managed to fetch".
    # The local manifest version is deliberately NOT synced here: bumping it would make
    # the next `--check --fast` (version-only comparison) report green on the strength
    # of a comparison that never completed. The repair-pass still runs, though — it is
    # what fixes a stale workspace (issue #226), and a download hiccup is no reason to
    # skip it in a real run.
    print_extra_write_targets
    echo "⚠ Проверка неполная: различий среди проверенных файлов нет, но ${#SKIPPED_DOWNLOAD[@]} файл(ов) скачать не удалось."
    echo "  Повторите запуск, когда сеть будет доступна. Версия манифеста намеренно не синхронизирована."
    if $CHECK_ONLY; then
        assert_self_unmutated
    else
        # Evgenii Red Team review 2026-08-19 (defect #3 continued, found on the
        # sibling branch below): the TOTAL_CHANGES=0 branch two if-blocks down
        # got the transaction/build-runtime fail-closed contract in this same
        # F6 commit — this branch, with the identical TOTAL_CHANGES=0 condition
        # plus a download hiccup, was left with the pre-fix behavior: repair_pass
        # writes to disk with no open transaction, so a build-runtime failure
        # here would exit EXIT_RUNTIME with no .update-incomplete marker at all.
        # Same three calls, same order, as the branch below.
        require_env_before_update
        begin_update_transaction
        repair_pass
        # issue #541 hvost 2 (#540): Step 6 (main apply-path) never runs from
        # this early-exit branch, so the workspace CLAUDE.md/.claude.md.base
        # reconciliation has to happen here too, before we can honestly claim
        # success.
        sync_workspace_claude_md
        run_build_runtime_or_die
        if ! run_post_apply_backfills_or_die; then
            exit "$EXIT_RUNTIME"
        fi
        # #1010 F7: the conflict gate exits BEFORE the marker is cleared: an unresolved CLAUDE.md
        # conflict (exit 49) must leave .update-incomplete in place.
        claude_conflict_gate
        finish_update_transaction
        report_settings_merge_drift
    fi
    exit 0
fi

if [ "$TOTAL_CHANGES" -eq 0 ]; then
    # issue #226: TOTAL_CHANGES=0 значит SCRIPT_DIR уже совпадает с upstream — но
    # workspace мог остаться stale (прерванный предыдущий запуск). Чиним прямо тут,
    # иначе repair-pass ниже никогда не выполнится (недостижим после этого exit).
    # bug-2026-07-11-update-sh-author-mode-blind-clobber: repair_pass() пишет файлы
    # на диск — под --check (без --fast) это ложное «превью без изменений».
    # issue #350: это самая частая ветка, и именно в ней превью раньше говорило
    # «всё актуально» и выходило, а обычный запуск тут же чинил рабочую копию —
    # писал в .claude/, память и .iwe-runtime/. Перечень адресатов печатается и здесь.
    print_extra_write_targets
    if $CHECK_ONLY; then
        echo "  ℹ Режим --check: repair-pass пропущен (может чинить workspace, запусти без --check)."
        assert_self_unmutated
    else
        # Evgenii Red Team review 2026-08-19 (defect #3): repair_pass() below
        # writes files to disk and run_build_runtime_or_die() can fail — but
        # this branch never called begin_update_transaction(), so a build
        # failure here exited EXIT_RUNTIME with NO marker on disk at all.
        # Same fail-closed contract this F6 commit already gives Step 6d
        # (message text: "no transaction was opened" was true only because
        # nothing ever opened one here — the actual bug was the missing open,
        # not the message).
        require_env_before_update
        begin_update_transaction
        repair_pass
        # issue #541 hvost 2 (#540): Step 6 (main apply-path) never runs from
        # this early-exit branch, so the workspace CLAUDE.md/.claude.md.base
        # reconciliation has to happen here too, before we can honestly claim
        # "Всё актуально".
        sync_workspace_claude_md
        # issue #279: TOTAL_CHANGES=0 сравнивает только содержимое файлов, не
        # версию в update-manifest.json — без этого локальный манифест навсегда
        # остаётся на старой версии, и --check --fast (сравнивающий только версию)
        # ложно сообщает об обновлении на каждом следующем прогоне.
        if [ -f "$MANIFEST" ]; then
            LOCAL_HASH_BEFORE=$(hash_file "$SCRIPT_DIR/update-manifest.json" 2>/dev/null || true)
            REMOTE_HASH=$(hash_file "$MANIFEST" 2>/dev/null || true)
            if [ "$LOCAL_HASH_BEFORE" != "$REMOTE_HASH" ]; then
                cp "$MANIFEST" "$SCRIPT_DIR/update-manifest.json" \
                    && echo "  • update-manifest.json: версия синхронизирована (v$UPSTREAM_VERSION)"
            fi
        fi
        # WP-529 F6 (Evgenii defect #5, 18.08): repair_pass may have refreshed
        # workspace copies, and this branch used to close the transaction
        # without ever rebuilding .iwe-runtime/ — recovery ended with a removed
        # marker but stale substitutions. Same fail-closed contract as Step 6d.
        run_build_runtime_or_die
        if ! run_post_apply_backfills_or_die; then
            exit "$EXIT_RUNTIME"
        fi
        # Cold review 2026-08-19 (Critical): finish must stay OUT of --check —
        # the preview used to clear a live .update-incomplete from a previous
        # failed run without repair or build-runtime, disarming the contract
        # this marker now carries (runtime freshness + role-runner guard).
        # issue #541 hvost 2 (#540): a stale workspace CLAUDE.md caught by
        # sync_workspace_claude_md above must not be reported as "Всё актуально" —
        # that was exactly the false success Evgenii's retry test found. Same
        # placement as the sibling branch above: inside the non-$CHECK_ONLY
        # else, since sync_workspace_claude_md (like repair_pass) never ran
        # under --check and the tracking vars would otherwise still be at
        # their initial empty/false state here regardless.
        # #1010 F7: the gate first, so a conflict exit keeps the marker.
        claude_conflict_gate
        finish_update_transaction
    fi
    # Флаги stage B осмысленны и когда обновлений нет: workspace-копии могли
    # отстать от уже актуального шаблона (repair_pass выше их классифицировал).
    apply_settings_merge_if_requested
    report_author_skip_summary
    report_executable_index_mismatches manifest
    echo "✓ Всё актуально. Обновлений нет. ($UNCHANGED файлов проверено)"
    exit_clean
fi

# issue #863: rollback warning must appear before the file list, not hidden inside it.
ROLLBACK_DETECTED=false
ROLLBACK_UNCERTAIN=false
_rollback_code=1
if detect_release_rollback; then
    _rollback_code=0
else
    _last_rc=$?
    if [ "$_last_rc" -eq 2 ]; then
        _rollback_code=2
    fi
fi
if [ "$_rollback_code" -eq 0 ]; then
    ROLLBACK_DETECTED=true
    echo "🔴 ВНИМАНИЕ: локальная установка новее последнего релиза."
    echo "   Применение обновления release-каналом ОТКАТИТ установку на более старый снимок."
    echo "   Чтобы получить актуальную main, запустите: IWE_UPDATE_CHANNEL=main bash update.sh"
    echo ""
elif [ "$_rollback_code" -eq 2 ]; then
    ROLLBACK_UNCERTAIN=true
    echo "⚠️ ВНИМАНИЕ: не удалось проверить историю релиза; автоматическое применение с --yes заблокировано."
    echo "   Чтобы получить актуальную main, запустите: IWE_UPDATE_CHANNEL=main bash update.sh"
    echo ""
fi

if [ ${#NEW_FILES[@]} -gt 0 ]; then
    echo "Новые файлы (${#NEW_FILES[@]}):"
    for i in "${!NEW_FILES[@]}"; do
        f="${NEW_FILES[$i]}"
        d="${NEW_DESCS[$i]}"
        if [ -n "$d" ]; then
            printf "  + %-45s — %s\n" "$f" "$d"
        else
            printf "  + %s\n" "$f"
        fi
    done
    echo ""
fi

if [ ${#UPDATED_FILES[@]} -gt 0 ]; then
    echo "Обновлённые файлы (${#UPDATED_FILES[@]}):"
    for i in "${!UPDATED_FILES[@]}"; do
        f="${UPDATED_FILES[$i]}"
        lines="${UPDATED_LINES[$i]}"
        printf "  ~ %-45s — %s строк изменено\n" "$f" "$lines"
    done
    echo ""
fi

if [ ${#DEPRECATED_FOUND[@]} -gt 0 ]; then
    echo "Устаревшие файлы к удалению (${#DEPRECATED_FOUND[@]}):"
    for i in "${!DEPRECATED_FOUND[@]}"; do
        f="${DEPRECATED_FOUND[$i]}"
        r="${DEPRECATED_REASONS[$i]}"
        printf "  - %-45s — %s\n" "$f" "$r"
    done
    echo ""
fi

echo "Не затрагиваются:"
echo "  ✓ memory/MEMORY.md (личная оперативная память)"
echo "  ✓ CLAUDE.md (3-way merge: ваши правки сохраняются)"
echo "  ✓ extensions/ (ваши расширения протоколов)"
# issue #348: params.yaml защищён только когда файл уже существует — на установке,
# где его нет, он засевается из шаблона. Обещание «не затрагивается» без этой оговорки
# читалось как «мою правку не тронут», хотя гард проверяет именно наличие файла.
echo "  ✓ params.yaml (ваши параметры — существующий файл не перезаписывается; отсутствующий засевается из шаблона)"
echo "  ✓ .secrets/ (ключи)"
echo "  ✓ .claude/settings.local.json (permissions)"
echo "  ✓ sessions/00-index.md (журнал peer-сессий)"
echo "  ✓ personal/ (ваши файлы)"
echo ""

print_extra_write_targets

if [ "$UNCHANGED" -gt 0 ]; then
    echo "Без изменений: $UNCHANGED файлов"
    echo ""
fi

# === Check-only mode ===
if $CHECK_ONLY; then
    echo "Режим --check: изменения не применяются."
    echo "Для применения: bash update.sh"
    assert_self_unmutated
    if ! run_sync_canary; then
        exit "$EXIT_CANARY_FAILED"
    fi
    exit_clean
fi

# === Step 4: Confirmation ===
if [ "$ROLLBACK_DETECTED" = true ]; then
    # issue #863: automatic/scheduled runs must not silently roll back a newer install.
    if $AUTO_YES; then
        echo "🔴 Остановлено: обнаружен откат на более старый релиз, а --yes запрещает интерактивное подтверждение." >&2
        echo "   Для явного отката запустите без --yes и введите ROLLBACK на запрос подтверждения." >&2
        echo "   Чтобы получить актуальную main, запустите: IWE_UPDATE_CHANNEL=main bash update.sh" >&2
        exit "$EXIT_USAGE"
    fi
    echo "🔴 Это ОТКАТ на более старый релиз. Чтобы продолжить, введите ROLLBACK явно."
    read -p "Применить ОТКАТ? (введите ROLLBACK для подтверждения / anything else для отмены) " -r
    echo ""
    if [ "$REPLY" != "ROLLBACK" ]; then
        echo "Отменено."
        exit 0
    fi
elif [ "$ROLLBACK_UNCERTAIN" = true ]; then
    # issue #863: history could not be verified; require explicit manual approval.
    if $AUTO_YES; then
        echo "🔴 Остановлено: не удалось проверить историю релиза, а --yes запрещает интерактивное подтверждение." >&2
        echo "   Запустите без --yes и подтвердите обновление вручную, либо используйте IWE_UPDATE_CHANNEL=main." >&2
        exit "$EXIT_USAGE"
    fi
    read -p "Продолжить, несмотря на невозможность проверить откат? (y/n) " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Отменено."
        exit 0
    fi
elif ! $AUTO_YES; then
    read -p "Применить обновления? (y/n) " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Отменено."
        exit 0
    fi
fi

# === Step 5: Apply updates ===
echo ""
echo "Применяю обновления..."
require_env_before_update
begin_update_transaction
remember_untouched_memory_before_apply

APPLIED=0
REMOVED=0
AUTHOR_SKIPPED=0
APPLIED_PATHS=()

for f in "${NEW_FILES[@]}"; do
    record_rule_workspace_state "$f"
    if author_diverged "$f"; then
        echo "  ⚠ $f — author_mode: локально изменён/удалён, не восстанавливаю. Сверь: git -C \"$SCRIPT_DIR\" status -- \"$f\""
        AUTHOR_SKIPPED=$((AUTHOR_SKIPPED + 1))
        continue
    fi
    mkdir -p "$SCRIPT_DIR/$(dirname "$f")"
    cp "$TMPDIR_UPDATE/files/$f" "$SCRIPT_DIR/$f"
    APPLIED_PATHS+=("$f")
    # Make scripts executable — files arrive via raw `curl -o` (no file-mode
    # metadata survives), so the +x bit must be reapplied explicitly here.
    # issue #308: .githooks/* is not cosmetic (git silently skips a non-executable
    # hook); wp-list.py/check-claude-md-links.py are git-tracked 755 upstream.
    case "$f" in *.sh|.githooks/*|.claude/bin/*|scripts/wp-list.py|scripts/check-claude-md-links.py) chmod +x "$SCRIPT_DIR/$f" ;; esac
    echo "  + $f"
    APPLIED=$((APPLIED + 1))
done

for f in "${UPDATED_FILES[@]}"; do
    record_rule_workspace_state "$f"
    # issue #238: author_mode-guard ДО всех спецкейсов ниже (CLAUDE.md 3-way merge,
    # SKILL.md USER-SPACE preserve, generic cp) — иначе несмёрженная авторская правка
    # в любом из них та же участь, что уже стёрла 66 файлов (86cf080 закрыл только
    # .claude/*-ветку в repair_pass()/Step 6, не эту, более раннюю точку входа).
    if author_diverged "$f"; then
        echo "  ⚠ $f — author_mode: несмёрженные правки, файл не тронут."
        echo "    Сверь: diff \"$TMPDIR_UPDATE/files/$f\" \"$SCRIPT_DIR/$f\""
        AUTHOR_SKIPPED=$((AUTHOR_SKIPPED + 1))
        continue
    elif author_release_regression "$f" "$TMPDIR_UPDATE/files/$f"; then
        echo "  ⚠ $f — author_mode: локальная копия уже равна main, но release-канал старее (фикс влит, релиза под него ещё не было) — файл не тронут."
        echo "    Хотите намеренно синхронизироваться с релизом — запустите: IWE_UPDATE_CHANNEL=main bash update.sh"
        AUTHOR_SKIPPED=$((AUTHOR_SKIPPED + 1))
        continue
    fi
    # issue #505 root, part 2: update.sh is delivered ONLY by Step 0's
    # self-update (fetch, compare, replace, re-exec). Applying it here did two
    # kinds of damage at once: `cp` truncated the very inode bash was still
    # reading (execution continued into garbage — "line 1875: command not
    # found", rc=127, stale .update-incomplete), and the placeholder
    # substitution pass below then baked the install's real paths into the
    # freshly applied copy's own {{KEY}} sed templates — after which the local
    # hash never matches upstream again and every run re-applies it. A
    # residual diff here (e.g. an already-baked local copy) is healed by the
    # next run's Step 0, which fetches the clean snapshot copy.
    if [ "$f" = "update.sh" ]; then
        echo "  ~ $f — пропущен: доставляется только самообновлением Шага 0 (issue #505)"
        continue
    fi
    APPLIED_PATHS+=("$f")
    # Special handling for CLAUDE.md: 3-way merge preserving user customizations
    if [ "$f" = "CLAUDE.md" ] && [ -f "$SCRIPT_DIR/$f" ]; then
        BASE_FILE="$SCRIPT_DIR/.claude.md.base"
        NEW_FILE="$TMPDIR_UPDATE/files/$f"
        CURRENT_FILE="$SCRIPT_DIR/$f"

        if [ -f "$BASE_FILE" ] && command -v git >/dev/null 2>&1; then
            # Migrate any legacy substituted base/current to raw placeholders before
            # merging. Both persisted template files remain safe for public forks.
            RAW_BASE_FILE="$TMPDIR_UPDATE/claude-base-raw.md"
            RAW_CURRENT_FILE="$TMPDIR_UPDATE/claude-current-raw.md"
            restore_claude_placeholders "$BASE_FILE" "$RAW_BASE_FILE"
            restore_claude_placeholders "$CURRENT_FILE" "$RAW_CURRENT_FILE"
            # git merge-file modifies the first argument in place
            MERGE_TMP="$TMPDIR_UPDATE/claude-merge.md"
            cp "$RAW_CURRENT_FILE" "$MERGE_TMP"

            if git merge-file -p "$MERGE_TMP" "$RAW_BASE_FILE" "$NEW_FILE" > "$TMPDIR_UPDATE/claude-merged.md" 2>/dev/null; then
                # Clean merge — no conflict markers. Still verify no pilot line
                # silently vanished (issue #555) before trusting "clean".
                SILENT_LOSS=$(detect_claude_silent_loss "$RAW_BASE_FILE" "$RAW_CURRENT_FILE" "$TMPDIR_UPDATE/claude-merged.md")
                if [ "$SILENT_LOSS" -gt 0 ]; then
                    CLAUDE_SILENT_LOSS_FILES+=("$CURRENT_FILE")
                    echo "  ⚠ $f НЕ тронут — слияние потеряло бы $SILENT_LOSS строк(и) без маркеров конфликта."
                    echo "    Сверьте вручную: diff \"$CURRENT_FILE\" \"$NEW_FILE\""
                else
                    cp "$TMPDIR_UPDATE/claude-merged.md" "$CURRENT_FILE"
                    cp "$NEW_FILE" "$BASE_FILE"
                    echo "  ~ $f (3-way merge, чисто)"
                fi
            else
                CONFLICT_COUNT=$(grep -c '^<<<<<<<' "$TMPDIR_UPDATE/claude-merged.md" 2>/dev/null || true); CONFLICT_COUNT=${CONFLICT_COUNT:-0}
                if [ "$CONFLICT_COUNT" -gt 0 ]; then
                    # Conflicts detected — save merged file with markers
                    cp "$TMPDIR_UPDATE/claude-merged.md" "$CURRENT_FILE"
                    cp "$NEW_FILE" "$BASE_FILE"
                    CLAUDE_CONFLICTS=$((CLAUDE_CONFLICTS + CONFLICT_COUNT))
                    echo "  ~ $f (3-way merge, $CONFLICT_COUNT конфликтов — разрешите вручную)"
                    echo "    Конфликты обозначены <<<<<<< / ======= / >>>>>>>"
                else
                    # Non-zero without a single marker is not a conflict: git did not merge.
                    # This branch used to "treat it as success" and copy the (empty) output
                    # over the file.
                    claude_merge_failed "$CURRENT_FILE" "$NEW_FILE"
                fi
            fi
        elif [ ! -f "$BASE_FILE" ] && claude_template_copy_is_replaceable "$CURRENT_FILE"; then
            # B1: nothing to merge in an unedited template copy, upstream goes in
            # as is. No base is written here (setup.sh: the template repo never
            # receives one); sync_workspace_claude_md() in Step 6 merges the
            # workspace copy against the workspace base, keeping the pilot's edits.
            # The record first, from the source: nothing can change what it hashes, and an interrupt
            # after the copy finds the record already in place. cp stays a plain statement: as the left
            # side of && a failure would not stop the run under set -e and "обновлён" would be a lie.
            claude_record_delivered "$NEW_FILE"
            cp "$NEW_FILE" "$CURRENT_FILE"
            echo "  ~ $f обновлён (копия в каталоге шаблона совпадает с доставленной ранее или с закоммиченной в клоне; ваша правка, закоммиченная в клоне, остаётся в его истории git)"
        else
            # issue #336: no base file (first migration or lost .claude.md.base) — a
            # blind `cp $NEW_FILE $CURRENT_FILE` silently discarded any pilot edit to
            # §8/§9 that wasn't wrapped in explicit <!-- USER-SPACE --> markers (those
            # markers don't exist in the real §8/§9 format). Without a real base there
            # is no safe 3-way merge — leave the pilot's file untouched and surface it
            # the same way an unresolved merge conflict is surfaced, instead of guessing.
            USER_SECTION=$(sed -n '/^<!-- USER-SPACE/,/^<!-- \/USER-SPACE/p' "$CURRENT_FILE")
            if [ -n "$USER_SECTION" ] && ! CLAUDE_BACKUP_DIR=$(claude_backup_before_replace "$CURRENT_FILE"); then
                # #1004: no backup, no replacement.
                CLAUDE_BASE_MISSING_FILES+=("$CURRENT_FILE")
                echo "  ⚠ $f НЕ тронут — не удалось сделать резервную копию перед заменой."
            elif [ -n "$USER_SECTION" ]; then
                echo "  ⚠ $f: правки вне блока USER-SPACE будут заменены версией шаблона; резервная копия: $CLAUDE_BACKUP_DIR"
                cp "$NEW_FILE" "$CURRENT_FILE"
                sed_inplace '/^<!-- USER-SPACE/,/^<!-- \/USER-SPACE/d' "$CURRENT_FILE"
                echo "" >> "$CURRENT_FILE"
                printf '%s\n' "$USER_SECTION" >> "$CURRENT_FILE"
                cp "$NEW_FILE" "$SCRIPT_DIR/.claude.md.base"
                echo "  ~ $f (USER-SPACE сохранён, базовый файл создан)"
            else
                # issue #541 hvost 2 (Evgenii Red Team v0.38.11): a retry right
                # after this exact run used to silently "succeed". Writing
                # .claude.md.base = NEW_FILE here while leaving CURRENT_FILE
                # untouched creates a false ancestry — the next run's 3-way
                # merge sees base == upstream and treats the untouched, still-
                # stale CURRENT_FILE as an intentional pilot customization,
                # merging cleanly and clearing .update-incomplete without
                # CLAUDE.md ever actually catching up. Leave the base absent
                # too, so every retry keeps re-detecting the same missing-base
                # state honestly until the pilot resolves it by hand.
                CLAUDE_BASE_MISSING_FILES+=("$CURRENT_FILE")
                echo "  ⚠ $f НЕ тронут — базовый файл для слияния отсутствовал."
                echo "    Сверьте свои правки §8/§9 вручную с шаблонной версией: diff \"$CURRENT_FILE\" \"$NEW_FILE\""
                if [ -f "${WORKSPACE_DIR:-}/.claude.md.base" ]; then
                    echo "    База в рабочей папке есть, но копия в каталоге шаблона не совпадает ни с файлом прошлого обновления (update-manifest.json), ни с закоммиченным в клоне, ни с записанным при последней замене: похоже, её правили вручную."
                fi
            fi
        fi
    elif [[ "$f" == .claude/skills/*/SKILL.md ]]; then
        # USER-SPACE preserve for L1 skill spec files (no install_constants in SCRIPT_DIR — already {{KEY}})
        CURR_SKILL_FILE="$SCRIPT_DIR/$f"
        if [ -f "$CURR_SKILL_FILE" ]; then
            USER_SECTION=$(sed -n '/^<!-- USER-SPACE -->/,/^<!-- \/USER-SPACE -->/p' "$CURR_SKILL_FILE")
        else
            USER_SECTION=""
        fi
        cp "$TMPDIR_UPDATE/files/$f" "$SCRIPT_DIR/$f"
        if [ -n "$USER_SECTION" ]; then
            perl -i -0pe 's/^<!-- USER-SPACE -->.*?^<!-- \/USER-SPACE -->//ms' "$SCRIPT_DIR/$f"
            perl -i -0pe 's/\n+$/\n/' "$SCRIPT_DIR/$f"
            printf '\n%s\n' "$USER_SECTION" >> "$SCRIPT_DIR/$f"
            echo "  ~ $f (USER-SPACE preserved)"
        else
            echo "  ~ $f"
        fi
    else
        cp "$TMPDIR_UPDATE/files/$f" "$SCRIPT_DIR/$f"
        # issue #308: same +x reapply as the NEW_FILES loop above (curl fetch drops file mode).
        case "$f" in *.sh|.githooks/*|.claude/bin/*|scripts/wp-list.py|scripts/check-claude-md-links.py) chmod +x "$SCRIPT_DIR/$f" ;; esac
        echo "  ~ $f"
    fi
    APPLIED=$((APPLIED + 1))
done

# issue #229: hard-require frontmatter.sh now — NEW_FILES/UPDATED_FILES above have
# just delivered it to disk if this is the first run after upgrading from a
# pre-2.4.0 install (the soft source near SCRIPT_DIR could not find it yet then).
# Everything below this point (repair_pass, Step 6 memory copy, hot-budget
# validator) calls get_field(), so a missing file here is a real delivery bug
# (manifest/git tracking), not a bootstrap-ordering race — fail loudly.
source "$SCRIPT_DIR/.claude/lib/frontmatter.sh" || {
    echo "ОШИБКА: .claude/lib/frontmatter.sh отсутствует после применения обновлений." >&2
    exit 1
}

# Detect pre-existing nested conflict markers before we propagate merged files.
# This prevents stacking new 3-way merges on top of unresolved ones (issue #31).
conflict_marker_files=()
for cf in "$SCRIPT_DIR/CLAUDE.md" "$WORKSPACE_DIR/CLAUDE.md"; do
    [ -f "$cf" ] && grep -q '^<<<<<<<' "$cf" && conflict_marker_files+=("$cf")
done
if [ "${#conflict_marker_files[@]}" -gt 0 ]; then
    echo ""
    echo "ОШИБКА: обнаружены неразрешённые конфликты слияния (вложенные маркеры):"
    for cf in "${conflict_marker_files[@]}"; do echo "  - $cf"; done
    echo "  Разрешите их вручную и перезапустите update.sh."
    exit "$EXIT_CONFLICT"
fi

# CLAUDE.md conflict (issue #226): warn and remember, but keep going — propagation
# and commit of everything else must not be blocked by one unresolved merge.
if [ "$CLAUDE_CONFLICTS" -gt 0 ]; then
    echo ""
    echo "ОШИБКА: CLAUDE.md содержит неразрешённые конфликты слияния."
    echo "  Конфликты обозначены <<<<<<< / ======= / >>>>>>>"
    echo "  Разрешите их вручную в $SCRIPT_DIR/CLAUDE.md после завершения обновления."
    CLAUDE_CONFLICT_DETECTED=true
    CLAUDE_CONFLICT_FILES+=("$SCRIPT_DIR/CLAUDE.md")
fi

# Remove deprecated files
for i in "${!DEPRECATED_FOUND[@]}"; do
    f="${DEPRECATED_FOUND[$i]}"
    fpath="$SCRIPT_DIR/$f"
    if [ -f "$fpath" ]; then
        rm "$fpath"
        echo "  - $f (удалён: устарел)"
        REMOVED=$((REMOVED + 1))
        # Also remove from workspace .claude/ (propagated L1 files)
        case "$f" in .claude/*)
            ws_path="$WORKSPACE_DIR/$f"
            [ -f "$ws_path" ] && rm "$ws_path" && echo "    (также из workspace)"
            ;;
        esac
        # Also remove from Claude memory dir (memory/* files) — relative path from
        # memory/ (not basename), symmetric with repair_pass() delivery (issue #287).
        case "$f" in memory/*.md|memory/*.yaml|memory/*.yml)
            mem_path="$CLAUDE_MEMORY_DIR/${f#memory/}"
            [ -f "$mem_path" ] && rm "$mem_path" && echo "    (также из memory/)"
            ;;
        esac
    fi
done
# Clean up empty deprecated directories
for i in "${!DEPRECATED_FOUND[@]}"; do
    f="${DEPRECATED_FOUND[$i]}"
    dir="$SCRIPT_DIR/$(dirname "$f")"
    [ "$dir" = "$SCRIPT_DIR/." ] && continue
    [ -d "$dir" ] && [ -z "$(ls -A "$dir" 2>/dev/null)" ] && rmdir "$dir" 2>/dev/null && echo "  - $(dirname "$f")/ (пустая директория удалена)"
done

# === Step 5b: Re-substitute placeholders + ensure .exocortex.env in workspace ===
# WP-273 Этап 2: substituted-файлы живут в $WORKSPACE_DIR/.iwe-runtime/, не в FMT.
# Substitution в FMT-файлах больше НЕ выполняется. CLAUDE.md substitute отдельно (3-way merge).
# Поиск .exocortex.env: workspace (Variant F) → FMT (legacy ≤0.28.x).
echo ""
echo "Подстановка переменных..."

# Recheck the path just before Step 5b writes to it. A file switched to a
# symlink/non-file after the early preflight must not be edited through here.
if [ -L "$WORKSPACE_DIR/.exocortex.env" ] || \
   { [ -e "$WORKSPACE_DIR/.exocortex.env" ] && [ ! -f "$WORKSPACE_DIR/.exocortex.env" ]; }; then
    echo "ОШИБКА: .exocortex.env больше не является обычным файлом; маркер .update-incomplete сохранён." >&2
    exit "$EXIT_RUNTIME"
fi
if [ ! -f "$WORKSPACE_DIR/.exocortex.env" ] && [ -L "$SCRIPT_DIR/.exocortex.env" ]; then
    echo "ОШИБКА: legacy .exocortex.env является символической ссылкой; маркер .update-incomplete сохранён." >&2
    exit "$EXIT_RUNTIME"
fi

if [ -f "$WORKSPACE_DIR/.exocortex.env" ]; then
    ENV_FILE="$WORKSPACE_DIR/.exocortex.env"
elif [ -f "$SCRIPT_DIR/.exocortex.env" ]; then
    ENV_FILE="$SCRIPT_DIR/.exocortex.env"
    echo "  ⚠ .exocortex.env найден в FMT (legacy). Будет мигрирован в \$WORKSPACE_DIR/ при первом setup ≥0.7.0."
else
    ENV_FILE="$WORKSPACE_DIR/.exocortex.env"  # для дальнейшего автогенерирования (миграция С5)
fi

if [ -f "$ENV_FILE" ]; then
    # Validate: only KEY=VALUE lines allowed (no shell commands)
    if grep -qE '^\s*(source|eval|exec|\.|`|;|\$\()' "$ENV_FILE" 2>/dev/null; then
        echo "  ОШИБКА: .exocortex.env содержит недопустимые конструкции. Пропускаю подстановку."
        echo "  Пересоздайте: bash setup.sh"
    else
        # Read variables safely (only simple KEY=VALUE)
        # Use read -r line + split on first '=' to handle values containing '=' (e.g. URLs, tokens)
        while IFS= read -r line; do
            # Skip comments and empty lines
            case "$line" in \#*|"") continue ;; esac
            # Split on first '=' only
            key="${line%%=*}"
            value="${line#*=}"
            # Trim whitespace from key
            key=$(echo "$key" | tr -d '[:space:]')
            # issue #316-fix2: см. тот же комментарий в substitute_claude_placeholders() —
            # non-source парсер, кавычки из процитированных (#223) значений остаются
            # буквально в строке и ломают DETECT_WS/[ -d ... ] ниже без снятия.
            value=$(echo "$value" | tr -d '"' | tr -d "'")
            [ -z "$key" ] && continue
            # Export for use below (secrets: L4_DATABASE_URL etc. are loaded but not substituted into files)
            declare "ENV_$key=$value"
        done < "$ENV_FILE"

        # WP-273 Этап 2: substitution в FMT-файлах больше НЕ выполняется.
        # Substituted значения генерируются build-runtime.sh в .iwe-runtime/ (Step 6d ниже, ПЕРЕД roles reinstall).
        # Это закрывает R4.6 (self-heal): build-runtime идемпотентен, повторный запуск
        # update.sh пересоздаёт runtime даже если предыдущий прервался.
        :  # placeholder substitution NO-OP в FMT

        # === Preserve secrets: L4_BACKEND, L4_DATABASE_URL ===
        # These are NOT substituted into template files.
        # If they exist in .exocortex.env, they must NOT be overwritten by update.sh.

        # === Auto-add GOVERNANCE_REPO + IWE_TEMPLATE to legacy .exocortex.env (0.28.5+) ===
        # Если .exocortex.env создан до 0.28.5 — этих ключей нет; дописать.
        if ! grep -q '^GOVERNANCE_REPO=' "$ENV_FILE" 2>/dev/null; then
            # Resolve workspace: ENV_WORKSPACE_DIR (если есть) → fallback dirname $SCRIPT_DIR
            DETECT_WS="${ENV_WORKSPACE_DIR:-$(dirname "$SCRIPT_DIR")}"
            DETECTED_GOV=""
            if [ -d "${DETECT_WS}/${IWE_GOVERNANCE_REPO:-DS-strategy}" ]; then
                DETECTED_GOV="${IWE_GOVERNANCE_REPO:-DS-strategy}"
            else
                for d in "${DETECT_WS}"/DS-*; do
                    case "${d##*/}" in
                        DS-*strategy*) DETECTED_GOV="${d##*/}"; break ;;
                    esac
                done
            fi
            if [ -z "$DETECTED_GOV" ]; then
                DETECTED_GOV="${IWE_GOVERNANCE_REPO:-DS-strategy}"
                echo "  ⚠ Governance repo не найден в $DETECT_WS — fallback ${IWE_GOVERNANCE_REPO:-DS-strategy}. Проверьте .exocortex.env вручную."
            fi
            echo "GOVERNANCE_REPO=\"$DETECTED_GOV\"" >> "$ENV_FILE"
            echo "  ✓ Добавлено GOVERNANCE_REPO=$DETECTED_GOV в .exocortex.env (миграция 0.28.5)"
            ENV_GOVERNANCE_REPO="$DETECTED_GOV"
        fi
        if ! grep -q '^IWE_TEMPLATE=' "$ENV_FILE" 2>/dev/null; then
            echo "IWE_TEMPLATE=\"$SCRIPT_DIR\"" >> "$ENV_FILE"
            echo "  ✓ Добавлено IWE_TEMPLATE=$SCRIPT_DIR в .exocortex.env (миграция 0.28.5)"
            ENV_IWE_TEMPLATE="$SCRIPT_DIR"
        fi

        # === Auto-add IWE_SCRIPTS (peer-session 2026-09-08-32, Evgenii's Day
        # Open report) === Was never in placeholders: before this fix, so no
        # generated plist could ever carry it — the launchd jobs silently ran
        # without it (strategist.sh:357-366 fell back to the free-form prompt).
        if ! grep -q '^IWE_SCRIPTS=' "$ENV_FILE" 2>/dev/null; then
            echo "IWE_SCRIPTS=\"$SCRIPT_DIR/scripts\"" >> "$ENV_FILE"
            echo "  ✓ Добавлено IWE_SCRIPTS=$SCRIPT_DIR/scripts в .exocortex.env (WP-529 Ф94)"
            ENV_IWE_SCRIPTS="$SCRIPT_DIR/scripts"
        fi

        # === WP-273 Этап 2: IWE_RUNTIME для Generated runtime architecture (F) ===
        if ! grep -q '^IWE_RUNTIME=' "$ENV_FILE" 2>/dev/null; then
            DETECT_WS_RT="${ENV_WORKSPACE_DIR:-$WORKSPACE_DIR}"
            echo "IWE_RUNTIME=\"$DETECT_WS_RT/.iwe-runtime\"" >> "$ENV_FILE"
            echo "  ✓ Добавлено IWE_RUNTIME=$DETECT_WS_RT/.iwe-runtime (миграция WP-273 → 0.29.0)"
            ENV_IWE_RUNTIME="$DETECT_WS_RT/.iwe-runtime"
        fi

        # WP-5 Ф43: launchd does not reliably export USER/LOGNAME.  Keep the
        # Unix login name as explicit runtime input so generated plist files
        # never infer it from their own minimal environment.
        if ! grep -q '^USER_NAME=' "$ENV_FILE" 2>/dev/null; then
            DETECTED_USER_NAME=$(id -un 2>/dev/null || true)
            if [ -z "$DETECTED_USER_NAME" ]; then
                echo "  ОШИБКА: не удалось определить Unix login для USER_NAME; добавьте его в .exocortex.env вручную."
            else
                echo "USER_NAME=$DETECTED_USER_NAME" >> "$ENV_FILE"
                echo "  ✓ Добавлено USER_NAME=$DETECTED_USER_NAME в .exocortex.env (WP-5 Ф43)"
            fi
        fi

        # === Re-quote unquoted values in existing .exocortex.env (issue #781) ===
        # #223/#316 приучили setup.sh/update.sh писать значения в кавычках, но
        # ни один путь не чинил уже существующий файл, созданный до фикса —
        # `TIMEZONE_DESC=4:00 UTC` без кавычек ломает любой `source
        # .exocortex.env` (bash трактует хвост после пробела как команду,
        # `UTC: command not found`, rc 127). Чиним только значения, где
        # реально нет пробела в написанном виде разбор строкой (line-parser
        # выше) уже подтвердил валидный KEY — просто дописываем кавычки туда,
        # где их ещё нет. Список расширен ревью после первого фикса (#786):
        # GOVERNANCE_REPO/IWE_TEMPLATE/IWE_SCRIPTS/IWE_RUNTIME писались этим
        # же update.sh без кавычек чуть ниже по файлу (миграции 0.28.5/WP-273/
        # WP-529) — тот же класс дефекта на путях с пробелом.
        for _key in TIMEZONE_DESC GITHUB_USER WORKSPACE_DIR CLAUDE_PATH \
                    CLAUDE_PROJECT_SLUG HOME_DIR USER_NAME \
                    GOVERNANCE_REPO IWE_TEMPLATE IWE_SCRIPTS IWE_RUNTIME; do
            _raw_line=$(grep -E "^${_key}=" "$ENV_FILE" 2>/dev/null | head -1)
            [ -z "$_raw_line" ] && continue
            _raw_value="${_raw_line#*=}"
            case "$_raw_value" in
                \"*\"|\'*\') continue ;;  # уже в двойных или одинарных кавычках
                *[[:space:]]*)
                    _quoted=$(sed_escape_replacement "$_raw_value")
                    sed_inplace "s|^${_key}=.*|${_key}=\"${_quoted}\"|" "$ENV_FILE"
                    echo "  ✓ $_key взят в кавычки в .exocortex.env (issue #781, значение содержало пробел)"
                    ;;
            esac
        done

        # === Migrate .exocortex.env from FMT to workspace (WP-273 Этап 2) ===
        # Если .exocortex.env живёт в FMT (legacy ≤0.28.x), копируем в workspace.
        # FMT остаётся read-only. Workspace = source-of-truth user state.
        if [ "$ENV_FILE" = "$SCRIPT_DIR/.exocortex.env" ] && [ ! -f "$WORKSPACE_DIR/.exocortex.env" ]; then
            cp "$ENV_FILE" "$WORKSPACE_DIR/.exocortex.env"
            chmod 600 "$WORKSPACE_DIR/.exocortex.env"
            echo "  ✓ .exocortex.env скопирован в $WORKSPACE_DIR/ (миграция WP-273 → 0.29.0)"
            echo "    Старая копия в FMT остаётся для backward compat; уберите вручную после проверки."
        fi

        # === Migrate ~/.iwe-env if present (Ф8 migration scenario) ===
        IWE_ENV_GLOBAL="$HOME/.iwe-env"
        if [ -f "$IWE_ENV_GLOBAL" ]; then
            MIGRATED_KEYS=0
            # Check which keys are missing from .exocortex.env
            for migrate_key in L4_BACKEND L4_DATABASE_URL; do
                eval "existing=\${ENV_${migrate_key}:-}"
                if [ -z "$existing" ]; then
                    # Extract from ~/.iwe-env
                    migrated_val=$(grep "^${migrate_key}=" "$IWE_ENV_GLOBAL" 2>/dev/null | head -1)
                    migrated_val="${migrated_val#*=}"
                    if [ -n "$migrated_val" ]; then
                        echo "" >> "$ENV_FILE"
                        echo "${migrate_key}=${migrated_val}" >> "$ENV_FILE"
                        MIGRATED_KEYS=$((MIGRATED_KEYS + 1))
                    fi
                fi
            done
            if [ "$MIGRATED_KEYS" -gt 0 ]; then
                echo "  ✓ Мигрировано $MIGRATED_KEYS ключей из ~/.iwe-env → .exocortex.env"
                echo "  ~/.iwe-env больше не нужен. Удалить вручную: rm $IWE_ENV_GLOBAL"
            fi
        fi
    fi
else
    # The preflight above covered the normal missing-file case. A file removed
    # concurrently during apply must fail closed rather than inventing config
    # after CLAUDE.md and other template files have already been copied.
    echo "ОШИБКА: .exocortex.env исчез во время обновления; маркер .update-incomplete сохранён." >&2
    echo "  Восстановите $WORKSPACE_DIR/.exocortex.env и повторите обновление." >&2
    printf '  Команда: IWE_UPDATE_CHANNEL=%s bash %q --yes\n' \
        "$UPDATE_CHANNEL" "$SCRIPT_DIR/update.sh" >&2
    exit "$EXIT_RUNTIME"
fi

# Check only files produced by build-runtime. The directory also preserves
# session state and isolated worktrees; scanning it recursively reported
# placeholders in old source copies as defects of the current installation
# and took minutes on a long-lived workspace (issue #1084).
RUNTIME_CHECK_DIR="${WORKSPACE_DIR}/.iwe-runtime"
if [ -d "$RUNTIME_CHECK_DIR" ]; then
    if REMAINING=$(bash "$SCRIPT_DIR/scripts/lib/runtime-placeholder-count.sh" \
        "$SCRIPT_DIR/.claude/runtime-overlay.yaml" "$RUNTIME_CHECK_DIR"); then
        if [ "$REMAINING" -gt 0 ]; then
            echo "  ⚠ $REMAINING собранных runtime-файлов содержат незаменённые переменные."
            echo "  Проверьте .exocortex.env (значения placeholders) и перезапустите: bash $SCRIPT_DIR/setup/build-runtime.sh"
        fi
    else
        echo "  ⚠ Проверка переменных собранного runtime не завершилась; проверьте runtime-overlay.yaml и повторите build-runtime.sh." >&2
    fi
fi

# === Step 6: Reinstall platform-space ===
echo ""
echo "Обновление platform-space..."

# Copy CLAUDE.md to workspace root
sync_workspace_claude_md

# Copy memory files to Claude projects directory
if [ -d "$CLAUDE_MEMORY_DIR" ]; then
    MEM_UPDATED=0
    for f in "${NEW_FILES[@]}" "${UPDATED_FILES[@]}"; do
        case "$f" in
            memory/*.md|memory/*.yaml|memory/*.yml)
                fname=$(basename "$f")
                # Относительный путь от memory/, не basename — сохраняет вложенность
                # (memory/reference/agent-core.md), симметрично repair_pass() (issue #287).
                dst="$CLAUDE_MEMORY_DIR/${f#memory/}"
                mkdir -p "$(dirname "$dst")"
                if [ "$fname" != "MEMORY.md" ]; then
                    if is_personal_config "$fname" && [ -f "$dst" ]; then
                        echo "  ✓ $fname — личный L4-конфиг, не перезаписан"
                    elif is_author_mode && [ -f "$dst" ]; then
                        # issue #238: тот же класс, что уже закрыт для .claude/*-веток —
                        # эта ветка тоже слепо копировала SCRIPT_DIR поверх live-копии.
                        # An owner: user copy stays out of the author_mode counters
                        # (report_author_user_memory), as before #965/#967.
                        if is_user_owned_memory "$dst"; then
                            report_author_user_memory "$f" "$dst"
                        else
                            report_author_skip "$f" "$dst"
                        fi
                    elif apply_memory_policy "$f" "$dst" "$(memory_old_hash "$f")"; then
                        # issues #965/#967: whatever its owner: marker, a copy equal to the
                        # version installed last time (or to one in the clone's history) is
                        # refreshed after a backup; an edited one is kept with a command.
                        # The replaced and kept files are summed up at the end of repair_pass().
                        MEM_UPDATED=$((MEM_UPDATED + 1))
                    fi
                fi
                ;;
        esac
    done
    if [ "$MEM_UPDATED" -gt 0 ]; then
        echo "  ✓ $MEM_UPDATED memory-файлов обновлено в $CLAUDE_MEMORY_DIR"
    fi
    echo "  ✓ memory/MEMORY.md — не тронут"
fi

# Propagate skills, hooks, rules, lib, config, detectors to workspace if changed.
# lib/config/detectors — runtime dependencies капчер-шины (capture-bus.sh) и детекторов.
for f in "${NEW_FILES[@]}" "${UPDATED_FILES[@]}"; do
    case "$f" in
        .claude/skills/*/SKILL.md)
            src="$SCRIPT_DIR/$f"
            dst="$WORKSPACE_DIR/$f"
            if is_author_mode && [ -f "$dst" ]; then
                # --templated: deployed SKILL.md carries substituted install_constants,
                # a raw blob can never match template history — "authored" would lie.
                report_author_skip "$f" "$dst" templated
                continue
            fi
            mkdir -p "$(dirname "$dst")"
            # 1. Extract USER_SECTION from workspace before overwriting
            if [ -f "$dst" ]; then
                USER_SECTION=$(sed -n '/^<!-- USER-SPACE -->/,/^<!-- \/USER-SPACE -->/p' "$dst" 2>/dev/null || true)
            else
                USER_SECTION=""
            fi
            # 2. Extract install_constants values from workspace frontmatter
            if [ -f "$dst" ]; then
                IC_BLOCK=$(awk '/^install_constants:/{found=1} found && /^[a-z][^:]+:/ && !/^install_constants:/{exit} found{print}' "$dst" 2>/dev/null || true)
            else
                IC_BLOCK=""
            fi
            # 3. Copy src (with {{KEY}} placeholders) → dst
            cp "$src" "$dst"
            # 4. Substitute install_constants: {{KEY}} → VALUE
            if [ -n "$IC_BLOCK" ]; then
                while IFS=': ' read -r key val; do
                    key="${key#"${key%%[! ]*}"}"
                    val="${val#"${val%%[! ]*}"}"
                    [[ "$key" =~ ^[A-Z_]+$ ]] && [ -n "$val" ] || continue
                    sed_inplace "s|{{${key}}}|${val}|g" "$dst"
                done <<< "$IC_BLOCK"
            fi
            # 5. Reinject USER_SECTION
            if [ -n "$USER_SECTION" ]; then
                perl -i -0pe 's/^<!-- USER-SPACE -->.*?^<!-- \/USER-SPACE -->//ms' "$dst"
                perl -i -0pe 's/\n+$/\n/' "$dst"
                printf '\n%s\n' "$USER_SECTION" >> "$dst"
                echo "  ✓ $f → workspace (USER-SPACE preserved)"
            else
                echo "  ✓ $f → workspace"
            fi
            ;;
        # issue #891: the .claude/*.yaml|.claude/*.yml|.claude/*.example arm
        # covers loose top-level .claude/ files (rules-registry.yaml among
        # them -- sql-pii-guard.sh's AR.112/AR.113 source). They were
        # manifest-checksummed but matched no branch here before, so a fresh
        # NEW_FILES entry for one silently fell through this loop and never
        # reached disk. None of them carry a USER-SPACE block, so the same
        # helper as the subdir arms is enough.
        .claude/skills/*|.claude/hooks/*|.claude/rules/*|.claude/rules-lazy/*|.claude/lib/*|.claude/bin/*|.claude/config/*|.claude/detectors/*|.claude/scripts/*|.claude/agents/*|.claude/styles/*|.claude/templates/*|.claude/*.yaml|.claude/*.yml|.claude/*.example)
            src="$SCRIPT_DIR/$f"
            dst="$WORKSPACE_DIR/$f"
            if is_author_mode && [ -f "$dst" ]; then
                report_author_skip "$f" "$dst"
                continue
            fi
            mkdir -p "$(dirname "$dst")"
            if copy_platform_file_preserving_user_space "$src" "$dst" "$f"; then
                # .claude/bin holds extension-less executables (guarded-rm, issue #940)
                case "$f" in .claude/bin/*) chmod +x "$dst" ;; esac
                echo "  ✓ $f → workspace"
            fi
            ;;
        .claude/settings.json)
            # See repair_pass() comment above (bug-2026-07-11) — never blind-overwrite,
            # workspace copy carries user hooks/permissions the template doesn't have.
            dst="$WORKSPACE_DIR/$f"
            if [ ! -f "$dst" ]; then
                mkdir -p "$(dirname "$dst")"
                cp "$SCRIPT_DIR/$f" "$dst"
                echo "  ✓ $f → workspace (new install)"
            elif [ "$APPLY_SETTINGS_MERGE" = "true" ]; then
                # Stage B применяется единым блоком ПОСЛЕ propagation-цикла
                # (apply_settings_merge_if_requested) — здесь только тишина,
                # чтобы не задваивать вывод для файла, попавшего в UPDATED.
                :
            fi
            ;;
    esac
done

# Stage B: слияние настроек по явному флагу — вне propagation-цикла, чтобы
# работать и на повторном прогоне, когда settings.json шаблона уже не в UPDATED.
apply_settings_merge_if_requested
report_settings_merge_drift

# === Step 5d: Repair-pass для critical runtime files ===
# Выполняется ПОСЛЕ propagation, чтобы repair не дублировал работу NEW_FILES/UPDATED_FILES.
# Определение функции — см. repair_pass() перед Step 2 (нужна там же для early-exit ветки).
repair_pass

# === Step 5e: Hot-budget validator (issue #228) ===
# Политика CLAUDE.md §4: суммарно ≤150 строк в memory/*.md с horizon: hot.
# Warning-only (не hard-fail) — превышение не должно блокировать доставку остального
# (тот же принцип, что и CLAUDE.md conflict handling, issue #226).
HOT_BUDGET_LIMIT=150
if [ -d "$CLAUDE_MEMORY_DIR" ]; then
    HOT_LINES=0
    HOT_FILES=()
    for mem_file in "$CLAUDE_MEMORY_DIR"/*.md; do
        [ -f "$mem_file" ] || continue
        if [ "$(get_field "$mem_file" horizon)" = "hot" ]; then
            # awk NR (not wc -l) — wc -l counts newlines and undercounts by 1
            # for files without a trailing newline, silently hiding an overrun.
            n=$(awk 'END{print NR}' "$mem_file")
            HOT_LINES=$((HOT_LINES + n))
            HOT_FILES+=("$(basename "$mem_file"): $n")
        fi
    done
    if [ "$HOT_LINES" -gt "$HOT_BUDGET_LIMIT" ]; then
        echo ""
        echo "  ⚠ HOT-бюджет превышен: $HOT_LINES строк (лимит $HOT_BUDGET_LIMIT) в $CLAUDE_MEMORY_DIR"
        for entry in "${HOT_FILES[@]}"; do echo "      - $entry"; done
        echo "    Понизьте horizon: hot → warm для части файлов или сократите содержимое."
    fi
fi

# (Step 6b removed — repo rename no longer supported, no link migration needed)

# === Step 6b2: Self-heal missing extensions/ (WP-7 Ф133) ===
# setup.sh never created $WORKSPACE_DIR/extensions/ before this fix (only
# read from it — MCP_USER below, day-open-hooks-runner.sh step 0), so every
# install that ran setup.sh before this fix landed and will never re-run
# setup.sh is stuck without it. day-open-hooks.sh's fail-closed contract
# ("every install ships extensions/") then aborts the canonical Day Open
# pipeline on every single run — confirmed live (Ruslan, 2026-09-09).
# Idempotent no-op once the directory exists, same as any other self-heal.
if ! $CHECK_ONLY; then
    mkdir -p "$WORKSPACE_DIR/extensions"
fi

MCP_TEMPLATE="$SCRIPT_DIR/.mcp.json"
MCP_WORKSPACE="$WORKSPACE_DIR/.mcp.json"
MCP_USER="$WORKSPACE_DIR/extensions/mcp-user.json"

# === Step 6c: Migrate workspace .mcp.json to Gateway ===
# Strategy: migrate in-place first (preserving user servers), then fallback to template copy.
# This preserves any user-added MCP servers that are NOT in extensions/mcp-user.json.

if [ -f "$MCP_WORKSPACE" ] && py_available; then
    # issue #402 (defect 2): path via argv, not interpolated — see FILES_MATCH above.
    $PY_BIN -c "
import json, sys

with open(sys.argv[1]) as f:
    data = json.load(f)

servers = data.get('mcpServers', {})
old_keys = [k for k in servers if k in ('knowledge-mcp', 'digital-twin-mcp', 'personal-knowledge-mcp')]
changed = False

if old_keys:
    # Remove old stdio servers
    for k in old_keys:
        del servers[k]
    changed = True

if 'iwe-knowledge' not in servers:
    # Add new remote Gateway
    servers['iwe-knowledge'] = {'type': 'http', 'url': 'https://mcp.aisystant.com/mcp'}
    changed = True

if changed:
    # Move iwe-knowledge to the front, keep all other servers
    ordered = {'iwe-knowledge': servers.pop('iwe-knowledge')}
    ordered.update(servers)
    data['mcpServers'] = ordered
    with open(sys.argv[1], 'w') as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write('\n')
    removed = ', '.join(old_keys) if old_keys else ''
    msg = '  ✓ .mcp.json мигрирован'
    if removed:
        msg += ': ' + removed + ' → iwe-knowledge (Gateway)'
    else:
        msg += ': добавлен iwe-knowledge (Gateway)'
    print(msg)
" "$MCP_WORKSPACE" 2>/dev/null
elif [ ! -f "$MCP_WORKSPACE" ] && [ -f "$MCP_TEMPLATE" ]; then
    # No workspace .mcp.json — copy from template.
    # issue #786: голый cp оставлял {{HOME_DIR}} буквально — ext-railway не
    # стартовал. Та же процедура подстановки, что уже применяется к CLAUDE.md.
    if substitute_claude_placeholders "$MCP_TEMPLATE" "$MCP_WORKSPACE"; then
        echo "  ✓ .mcp.json создан из шаблона (Gateway)"
    else
        echo "  ✗ не удалось создать $MCP_WORKSPACE из шаблона"
    fi
elif [ -f "$MCP_WORKSPACE" ] && ! py_available; then
    # No python3 — check if already migrated, otherwise warn
    if grep -q 'iwe-knowledge' "$MCP_WORKSPACE" 2>/dev/null; then
        echo "  ✓ .mcp.json уже содержит iwe-knowledge"
    else
        echo "  ⚠ .mcp.json: python3 не найден, автомиграция пропущена."
        echo "    Замените knowledge-mcp/digital-twin-mcp на iwe-knowledge вручную."
        echo "    Образец: $MCP_TEMPLATE"
    fi
fi

# issue #786 (гэп, найденный ревью после первого фикса): три ветки выше чинят
# только «файла ещё нет» или «сервер устарел». Автор issue сообщал о файле,
# ПОБАЙТНО ИДЕНТИЧНОМ шаблону — python-миграция такой файл не трогает
# (changed остаётся false, нет устаревших ключей), а без python3 ветка просто
# предупреждает. {{HOME_DIR}} в уже существующем workspace-файле не лечился
# ни одним путём. Проверяем и чиним отдельно, независимо от того, что
# случилось выше.
if [ -f "$MCP_WORKSPACE" ] && grep -qF '{{HOME_DIR}}' "$MCP_WORKSPACE" 2>/dev/null; then
    if sed_inplace "s|{{HOME_DIR}}|$(sed_escape_replacement "${ENV_HOME_DIR:-$HOME}")|g" "$MCP_WORKSPACE"; then
        echo "  ✓ .mcp.json: {{HOME_DIR}} подставлен в уже существующем файле (issue #786)"
    else
        echo "  ✗ .mcp.json: не удалось подставить {{HOME_DIR}} в уже существующий файл"
    fi
fi

# Merge extensions/mcp-user.json into workspace .mcp.json (always, if both exist)
if [ -f "$MCP_WORKSPACE" ] && [ -f "$MCP_USER" ]; then
    if command -v jq >/dev/null 2>&1; then
        USER_COUNT=$(jq '.mcpServers | length' "$MCP_USER" 2>/dev/null || echo "0")
        if [ "$USER_COUNT" -gt 0 ]; then
            MCP_MERGED=$(jq -s '.[0].mcpServers * .[1].mcpServers | {mcpServers: .}' "$MCP_WORKSPACE" "$MCP_USER" 2>/dev/null)
            if [ -n "$MCP_MERGED" ]; then
                echo "$MCP_MERGED" > "$MCP_WORKSPACE"
                echo "  ✓ .mcp.json — $USER_COUNT пользовательских MCP из extensions/mcp-user.json добавлены"
            fi
        fi
    else
        echo "  ○ .mcp.json — jq не установлен, мёрж extensions/mcp-user.json пропущен"
        echo "    Установите jq: brew install jq"
    fi
fi

# === Step 6d: Rebuild generated runtime ПЕРЕД roles reinstall (WP-273 R5 fix) ===
# Round 5 Евгения обнаружил порядковую проблему: roles reinstall вызывался ДО build-runtime,
# из-за чего install.sh брал плисты из устаревшего .iwe-runtime/ или legacy FMT с placeholder'ами.
# Правильный порядок: сначала пересобрать .iwe-runtime/ из актуального FMT + .exocortex.env,
# потом install.sh каждой роли (чтение из свежего runtime).
run_build_runtime_or_die

# Linux scheduler ownership is checked immediately before touching the user's
# systemd units or crontab. A secondary workspace must never claim the primary
# installation's schedule, and a missing schedule is not proof of ownership.
linux_systemd_strategist_owned() {
    local unit root count current_root service timer expected_command
    current_root="$(canonical_workspace_path "$WORKSPACE_DIR")"
    for unit in iwe-strategist-morning iwe-strategist-weekreview; do
        service="$HOME/.config/systemd/user/$unit.service"
        timer="$HOME/.config/systemd/user/$unit.timer"
        [ -f "$service" ] && [ -f "$timer" ] || return 1
        [ ! -L "$service" ] && [ ! -L "$timer" ] || return 1
        [ ! -e "$service.d" ] && [ ! -e "$timer.d" ] || return 1
        ! grep -q '^EnvironmentFile=' "$service" || return 1
        count=$(grep -c '^Environment=IWE_WORKSPACE=' "$service" || true)
        [ "$count" -eq 1 ] || return 1
        root=$(sed -n 's/^Environment=IWE_WORKSPACE=//p' "$service")
        [ "$(canonical_workspace_path "$root")" = "$current_root" ] || return 1
        count=$(grep -c '^Unit=' "$timer" || true)
        [ "$count" -eq 1 ] && grep -Fxq "Unit=$unit.service" "$timer" || return 1
        expected_command="$WORKSPACE_DIR/.iwe-runtime/roles/strategist/scripts/strategist.sh"
        count=$(grep -c '^ExecStart=' "$service" || true)
        [ "$count" -eq 1 ] || return 1
        case "$unit" in
            iwe-strategist-morning) grep -Fxq "ExecStart=$expected_command morning" "$service" || return 1 ;;
            iwe-strategist-weekreview) grep -Fxq "ExecStart=$expected_command week-review" "$service" || return 1 ;;
        esac
    done
}

linux_cron_strategist_owned() {
    local cron_text expected_prefix expected_command begin end line
    local minute hour day month weekday command
    local inside=false begins=0 ends=0 morning=0 weekreview=0
    command -v crontab >/dev/null 2>&1 || return 1
    cron_text=$(crontab -l 2>/dev/null) || return 1
    [ -f "$SCRIPT_DIR/roles/lib/scheduler-cron.sh" ] || return 1
    # This helper defines the exact prefix written by the role installer.
    # A partially edited block is left untouched for manual reconciliation.
    . "$SCRIPT_DIR/roles/lib/scheduler-cron.sh"
    expected_prefix=$(IWE_TEMPLATE="$SCRIPT_DIR" \
        IWE_WORKSPACE="$WORKSPACE_DIR" \
        IWE_RUNTIME="$WORKSPACE_DIR/.iwe-runtime" \
        IWE_GOVERNANCE_REPO="${EFFECTIVE_GOVERNANCE_REPO:-$(effective_governance_repo)}" \
        iwe_cron_env_prefix)
    expected_command="$WORKSPACE_DIR/.iwe-runtime/roles/strategist/scripts/strategist.sh"
    begin='# BEGIN IWE-strategist (cron fallback, issue #454)'
    end='# END IWE-strategist'
    while IFS= read -r line; do
        case "$line" in
            "$begin")
                if $inside || [ "$begins" -ne 0 ]; then return 1; fi
                inside=true
                begins=$((begins + 1))
                ;;
            "$end")
                if ! $inside; then return 1; fi
                inside=false
                ends=$((ends + 1))
                ;;
            *)
                if $inside; then
                    case "$line" in *'#'*|'') return 1 ;; esac
                    read -r minute hour day month weekday command <<EOF
$line
EOF
                    [ -n "$command" ] || return 1
                    case "$command" in
                        "$expected_prefix $expected_command morning >> $HOME/logs/strategist/cron-morning.log 2>&1")
                            morning=$((morning + 1)) ;;
                        "$expected_prefix $expected_command week-review >> $HOME/logs/strategist/cron-weekreview.log 2>&1")
                            weekreview=$((weekreview + 1)) ;;
                        *) return 1 ;;
                    esac
                else
                    case "$line" in
                        \#*|'') ;;
                        *strategist.sh*) return 1 ;;
                    esac
                fi
                ;;
        esac
    done <<EOF
$cron_text
EOF
    ! $inside && [ "$begins" -eq 1 ] && [ "$ends" -eq 1 ] &&
        [ "$morning" -eq 1 ] && [ "$weekreview" -eq 1 ]
}

reinstall_linux_strategist() {
    local systemd_dir="$HOME/.config/systemd/user" cron_text="" systemd_found=false cron_found=false
    local role_dir="$SCRIPT_DIR/roles/strategist" unit state active_units=()
    local cron_backup_dir cron_backup

    for unit in iwe-strategist-morning iwe-strategist-weekreview; do
        if [ -e "$systemd_dir/$unit.service" ] || [ -L "$systemd_dir/$unit.service" ] ||
           [ -e "$systemd_dir/$unit.timer" ] || [ -L "$systemd_dir/$unit.timer" ]; then
            systemd_found=true
        fi
    done
    if ! command -v crontab >/dev/null 2>&1; then
        echo "  ○ Linux-расписание Стратега не изменено: crontab недоступен, отсутствие второго расписания не подтверждено"
        return 0
    fi
    if ! cron_text=$(crontab -l 2>&1); then
        case "$cron_text" in
            *'no crontab for '*) cron_text="" ;;
            *)
                echo "  ○ Linux-расписание Стратега не изменено: не удалось прочитать crontab"
                return 0
                ;;
        esac
    fi
    if printf '%s\n' "$cron_text" | grep -Eq '^# (BEGIN|END) IWE-strategist( |$)|^[[:space:]]*[^#[:space:]].*strategist\.sh'; then
        cron_found=true
    fi

    if $HOST_GLOBAL_OWNER_CONFLICT; then
        echo "  ○ Linux-расписание Стратега не изменено: $HOST_GLOBAL_OWNER_CONFLICT_REASON"
        return 0
    fi
    if $systemd_found && $cron_found; then
        echo "  ○ Linux-расписание Стратега не изменено: найдены и systemd, и cron; выберите один вручную"
        return 0
    fi
    if $systemd_found; then
        if ! command -v systemctl >/dev/null 2>&1 ||
           ! systemctl --user list-timers --no-legend >/dev/null 2>&1; then
            echo "  ○ Linux-расписание Стратега не изменено: нет пользовательской шины systemd; переход на cron требует ручного решения"
            return 0
        fi
        if ! linux_systemd_strategist_owned; then
            echo "  ○ Linux-расписание Стратега не изменено: владелец systemd units не подтверждён"
            return 0
        fi
        for unit in iwe-strategist-morning iwe-strategist-weekreview; do
            state=$(systemctl --user is-enabled "$unit.timer" 2>/dev/null || true)
            case "$state" in
                disabled|masked|masked-runtime) continue ;;
                enabled) ;;
                *)
                    echo "  ○ Linux-расписание Стратега не изменено: неизвестное состояние $unit.timer ($state)"
                    return 0
                    ;;
            esac
            if [ "$(systemctl --user is-active "$unit.timer" 2>/dev/null || true)" != active ]; then
                echo "  ○ Linux-расписание Стратега не изменено: $unit.timer включён, но остановлен; запуск требует ручного решения"
                return 0
            fi
            active_units+=("$unit.timer")
        done
        if [ "${#active_units[@]}" -eq 0 ]; then
            echo "  ○ Linux-расписание Стратега отключено пользователем; автоматическая переустановка пропущена"
            return 0
        fi
    elif $cron_found; then
        if command -v systemctl >/dev/null 2>&1 &&
           systemctl --user list-timers --no-legend >/dev/null 2>&1; then
            echo "  ○ Linux-расписание Стратега не изменено: cron установлен при доступном systemd; переход требует ручного решения"
            return 0
        fi
        if ! linux_cron_strategist_owned; then
            echo "  ○ Linux-расписание Стратега не изменено: владелец cron-блока не подтверждён или задание отключено"
            return 0
        fi
        cron_backup_dir="$HOME/.local/state/iwe/cron-backups"
        mkdir -p -m 700 "$cron_backup_dir"
        chmod 700 "$cron_backup_dir"
        if ! cron_backup=$(mktemp "$cron_backup_dir/strategist.XXXXXXXX"); then
            echo "  ⚠ Стратег: не удалось создать резервную копию crontab" >&2
            return 1
        fi
        chmod 600 "$cron_backup"
        if ! crontab -l > "$cron_backup"; then
            rm -f "$cron_backup"
            echo "  ⚠ Стратег: не удалось сохранить crontab перед обновлением" >&2
            return 1
        fi
        echo "  • Предыдущее расписание cron сохранено: $cron_backup"
    else
        echo "  ○ Linux-расписание Стратега не найдено; автоматическая установка без доказательства владения пропущена"
        return 0
    fi

    if ! IWE_WORKSPACE="$WORKSPACE_DIR" \
         IWE_TEMPLATE="$SCRIPT_DIR" \
         IWE_SCRIPTS="$SCRIPT_DIR/scripts" \
         IWE_RUNTIME="$WORKSPACE_DIR/.iwe-runtime" \
         IWE_GOVERNANCE_REPO="${EFFECTIVE_GOVERNANCE_REPO:-$(effective_governance_repo)}" \
         bash "$role_dir/install.sh"; then
        echo "  ⚠ Стратег: переустановка расписания не завершена; проверьте её вручную"
        return 1
    fi
    if $systemd_found; then
        for unit in "${active_units[@]}"; do
            if ! systemctl --user restart "$unit"; then
                echo "  ⚠ $unit: новое время не применено; перезапустите таймер вручную"
                return 1
            fi
        done
    fi
    echo "  ✓ Стратег: Linux-расписание обновлено"
}

print_optional_linux_role_instruction() {
    local role="$1" display="$2"
    printf '  ○ %s: если расписание установлено вручную, обновите его: ' "$display"
    printf 'IWE_WORKSPACE=%q IWE_TEMPLATE=%q IWE_RUNTIME=%q IWE_SCRIPTS=%q IWE_GOVERNANCE_REPO=%q bash %q\n' \
        "$WORKSPACE_DIR" "$SCRIPT_DIR" "$WORKSPACE_DIR/.iwe-runtime" \
        "$SCRIPT_DIR/scripts" "${EFFECTIVE_GOVERNANCE_REPO:-$(effective_governance_repo)}" \
        "$SCRIPT_DIR/roles/$role/install.sh"
}

# Reinstall roles if changed (ПОСЛЕ build-runtime — install читает из свежего .iwe-runtime/)
ROLES_CHANGED=false
STRATEGIST_CHANGED=false
SYNCHRONIZER_CHANGED=false
EXTRACTOR_CHANGED=false
for f in "${NEW_FILES[@]}" "${UPDATED_FILES[@]}"; do
    case "$f" in roles/*)
        ROLES_CHANGED=true
        ;;
    esac
    case "$f" in roles/strategist/*|roles/lib/*)
        STRATEGIST_CHANGED=true
        ;;
    esac
    case "$f" in roles/synchronizer/*|roles/lib/*)
        SYNCHRONIZER_CHANGED=true
        ;;
    esac
    case "$f" in roles/extractor/*|roles/lib/*)
        EXTRACTOR_CHANGED=true
        ;;
    esac
done

if $ROLES_CHANGED && [ "$(uname -s)" != Linux ] && command -v launchctl >/dev/null 2>&1; then
    # issue #768: role installers register real launchd jobs under the
    # current user's real $HOME — a foreign/unowned host-global state must
    # not have those jobs reloaded pointing at this copy.
    if $HOST_GLOBAL_OWNER_CONFLICT; then
        echo ""
        echo "  ○ Переустановка launchd-ролей пропущена: $HOST_GLOBAL_OWNER_CONFLICT_REASON"
    else
    echo ""
    echo "Роли обновлены. Переустановка..."
    # WP-529 Ф94 (peer-session 2026-09-08-32): $HOME/.iwe-paths is a legacy
    # path install-iwe-paths.sh stopped writing — sourcing it here silently
    # no-op'd (`[ -f ... ] && .` is not an error if the file is absent), so
    # role installers ran without IWE_RUNTIME/IWE_TEMPLATE/IWE_SCRIPTS in
    # their environment. update.sh already knows all of these; pass them
    # explicitly instead of relying on a file that may not exist.
    ROLE_REINSTALL_GOV="${EFFECTIVE_GOVERNANCE_REPO:-$(effective_governance_repo)}"
    for role_dir in "$SCRIPT_DIR"/roles/*/; do
        [ -f "$role_dir/install.sh" ] && [ -f "$role_dir/role.yaml" ] || continue
        if grep -q 'auto:.*true' "$role_dir/role.yaml" 2>/dev/null; then
            IWE_WORKSPACE="$WORKSPACE_DIR" \
            IWE_TEMPLATE="$SCRIPT_DIR" \
            IWE_SCRIPTS="$SCRIPT_DIR/scripts" \
            IWE_RUNTIME="$WORKSPACE_DIR/.iwe-runtime" \
            IWE_GOVERNANCE_REPO="$ROLE_REINSTALL_GOV" \
            bash "$role_dir/install.sh" 2>/dev/null && \
                echo "  ✓ $(basename "$role_dir") переустановлен" || \
                echo "  ○ $(basename "$role_dir"): переустановите вручную"
        fi
    done
    fi
fi

if [ "$(uname -s)" = Linux ] && ! $CHECK_ONLY && [ -z "${SETUP_CI:-}" ]; then
    if $STRATEGIST_CHANGED; then
        echo ""
        echo "Роли обновлены. Проверка Linux-расписания..."
        reinstall_linux_strategist
    fi
    # These roles have auto:false. Updating their files must not silently
    # activate an optional scheduler that the user installed only by choice.
    if $SYNCHRONIZER_CHANGED; then
        print_optional_linux_role_instruction synchronizer Синхронизатор
    fi
    if $EXTRACTOR_CHANGED; then
        print_optional_linux_role_instruction extractor Экстрактор
    fi
fi

# === Step 6d2: Regenerate hot-files.list (issue #294/#291) ===
# Keep the shipped scripts/hot-files.list neutral. The generator writes the
# install-specific governance path under .iwe-runtime (#388).
if [ -f "$SCRIPT_DIR/scripts/generate-hot-files-list.sh" ]; then
    if $CHECK_ONLY; then
        echo "  [CHECK] Would regenerate .iwe-runtime/hot-files.list (bash $SCRIPT_DIR/scripts/generate-hot-files-list.sh)"
    else
        HOTFILES_OUTPUT=$(IWE_ROOT="$WORKSPACE_DIR" bash "$SCRIPT_DIR/scripts/generate-hot-files-list.sh" 2>&1) && \
            echo "$HOTFILES_OUTPUT" | sed 's/^/  /' || \
            { echo "$HOTFILES_OUTPUT" | sed 's/^/  /'; echo "  ⚠ .iwe-runtime/hot-files.list не пересобран — запусти вручную: bash $SCRIPT_DIR/scripts/generate-hot-files-list.sh"; }
    fi
fi

# === Step 6e: Replace local manifest with downloaded remote manifest ===
# Replaces entire manifest (files + deprecated_files + version), not just version field.
# This ensures validators (D1/D9/D10) and future updates see the correct file list.
# Fork-local exclusions live in update-manifest.local.json (issue #247) —
# never written by this script, merged by check-manifest-coverage.py and 6f below.
if [ -f "$MANIFEST" ]; then
    cp "$MANIFEST" "$SCRIPT_DIR/update-manifest.json" \
        && echo "  • update-manifest.json: заменён remote manifest (v$UPSTREAM_VERSION)"
    APPLIED_PATHS+=("update-manifest.json")
fi

# === Step 6f: Orphan detection — L1 files not in manifest ===
# Warn about files present on disk in L1 directories that are not listed in
# update-manifest.json (neither in files[] nor deprecated_files[]).
# These may be stale user customisations or files left over from a renamed skill.
# Never auto-deletes; always informational only.
if py_available && [ -f "$SCRIPT_DIR/update-manifest.json" ]; then
    ORPHAN_OUTPUT=""
    if ! ORPHAN_OUTPUT=$($PY_BIN - "$SCRIPT_DIR" 2>&1 <<'PYEOF'
import json, os, sys

script_dir = os.path.realpath(sys.argv[1])
manifest_path = os.path.join(script_dir, "update-manifest.json")

with open(manifest_path) as f:
    manifest = json.load(f)

def _path(e): return e["path"] if isinstance(e, dict) else e
known = {_path(e) for e in manifest.get("files", [])}
deprecated = {_path(e) for e in manifest.get("deprecated_files", [])}
all_known = known | deprecated

# Fork-local exclusions (issue #247): files the user deliberately keeps in L1
# directories are not orphans. Same schema as manifest excluded_paths.
local_manifest_path = os.path.join(script_dir, "update-manifest.local.json")
local_excluded = []
if os.path.isfile(local_manifest_path):
    try:
        with open(local_manifest_path) as f:
            local_excluded = [_path(e) for e in json.load(f).get("excluded_paths", [])]
    except (json.JSONDecodeError, TypeError) as exc:
        print(f"  [warn] update-manifest.local.json unreadable, ignored: {exc}")

def _locally_excluded(rel):
    return any(rel == e.rstrip("/") or rel.startswith(e.rstrip("/") + "/")
               for e in local_excluded)

L1_DIRS = [".claude/hooks", ".claude/rules", ".claude/skills"]
L1_PREFIXES = ["memory/protocol-"]

orphans = []
for base in L1_DIRS:
    full_base = os.path.join(script_dir, base)
    if not os.path.isdir(full_base):
        continue
    for root, dirs, files in os.walk(full_base):
        for fname in files:
            full = os.path.join(root, fname)
            # issue #680: manifest paths always use "/" (JSON convention);
            # os.path.relpath returns "\" on Windows, so every file compared
            # false-orphan there without this normalization.
            rel = os.path.relpath(full, script_dir).replace(os.sep, "/")
            if rel not in all_known and not _locally_excluded(rel):
                tag = "[maybe-L3]" if "extensions/" in rel else "[orphan]"
                orphans.append((tag, rel))

for tag, rel in sorted(orphans):
    print(f"  {tag} {rel}")
PYEOF
    ); then
        echo "  ⚠ Проверка orphan-файлов не выполнена; обновление уже применено и остаётся успешным."
        echo "$ORPHAN_OUTPUT" | sed 's/^/    /'
        ORPHAN_OUTPUT=""
    fi
    if [ -n "$ORPHAN_OUTPUT" ]; then
        echo ""
        echo "⚠  Файлы в L1-директориях не найдены в манифесте (не удалять автоматически):"
        echo "$ORPHAN_OUTPUT"
        echo "   [orphan]   — возможно устаревший платформенный файл; удалите вручную или"
        echo "               добавьте в deprecated_files если это намеренно удалённый артефакт."
        echo "   [maybe-L3] — возможно пользовательское расширение (extensions/)."
    fi
fi

# === Step 7: Validate applied changes ===
echo ""
echo "Проверка применённых изменений..."

validate_no_install_values_in_applied_additions() {
    local env_file="$WORKSPACE_DIR/.exocortex.env"
    local key value fpath applied_additions added_line target_file target_sha256
    local applied_line_count target_line_count
    local i failed=0
    local -a install_keys=() install_values=()

    [ -f "$env_file" ] || return 0
    [ "${#APPLIED_PATHS[@]}" -gt 0 ] || return 0

    for key in WORKSPACE_DIR HOME_DIR CLAUDE_PATH IWE_TEMPLATE IWE_RUNTIME; do
        value=$(grep -E "^${key}=" "$env_file" 2>/dev/null |
            head -1 | cut -d= -f2- |
            sed -E 's/^"//; s/"$//; s/^'"'"'//; s/'"'"'$//')
        [ -n "$value" ] || continue
        # issue #397: guard ищет значение как ПОДСТРОКУ во всех добавленных строках.
        # Для путей (WORKSPACE_DIR и т.п.) это осмысленно — случайное совпадение с
        # абсолютным личным путём маловероятно. Но CLAUDE_PATH по умолчанию из setup —
        # голое имя команды (`claude`), а не путь: подстрока "claude" совпадает почти в
        # любом добавленном файле шаблона (comments, имена claude-peer-adapter.sh и т.д.)
        # и превращает guard в постоянный ложный блок. Guard значимого текста-пути без
        # "/" не несёт — только настоящие абсолютные пути отличают личную инсталляцию.
        case "$value" in
            */*) ;;
            *) continue ;;
        esac
        install_keys+=("$key")
        install_values+=("$value")
    done

    # issue #524: provenance belongs to the exact target release, not the old
    # installation fork's history. First accept a whole file whose bytes match
    # its unique target-manifest hash. This also works in the deliberately
    # tainted no-Python mode, which exits 4 after applying the update.
    #
    # A legitimate 3-way merge cannot match the whole-file hash. For that case,
    # fall through to the already integrity-verified downloaded target payload:
    # each install-valued line must exist in that exact same target file and may
    # occur no more often than in the target. Cross-file matches, unverified
    # payloads and locally duplicated canonical lines remain fail-closed.
    #
    # Детерминированно в обоих окружениях (peer-review Codex, 2026-08-24-07):
    # python-путь и shell-фоллбек дают одинаковый результат на одном манифесте
    # — P0 не остаётся воспроизводимым только в окружениях без python3/python.
    # Upstream manifest of this run; the reader itself is manifest_sha256_of (top level).
    manifest_sha256_for_path() {
        manifest_sha256_of "$MANIFEST" "$1"
    }

    for fpath in "${APPLIED_PATHS[@]}"; do
        if [ -f "$SCRIPT_DIR/$fpath" ] && target_sha256=$(manifest_sha256_for_path "$fpath") \
           && [ "$(hash_file "$SCRIPT_DIR/$fpath")" = "$target_sha256" ]; then
            echo "  install-path guard: $fpath exempt (byte-identical to target manifest sha256)" >&2
            continue
        fi
        echo "  install-path guard: $fpath -- no manifest hash match, falling back to verified target-line provenance" >&2
        # Полное текущее содержимое файла на диске, не git-diff working
        # tree против HEAD. Cold-context review нашёл живую дыру: если файл
        # уже ЗАКОММИЧЕН до этого прогона (второй прогон update.sh после
        # ручного коммита, пре-commit хук и т.п.) — git diff между working
        # tree и HEAD пуст для этого файла (разницы нет), applied_additions
        # становится пустой строкой, "[ -n ... ] || continue" молча
        # пропускает файл ЦЕЛИКОМ из проверки — реальная утечка проходит
        # незамеченной. Файл в APPLIED_PATHS означает "этот прогон его
        # затронул", независимо от git-статуса — сканировать нужно то, что
        # реально лежит на диске сейчас.
        if [ -f "$SCRIPT_DIR/$fpath" ]; then
            applied_additions=$(sed -n 'p' "$SCRIPT_DIR/$fpath")
        else
            continue
        fi
        [ -n "$applied_additions" ] || continue

        target_file="${TMPDIR_UPDATE:-}/files/$fpath"

        while IFS= read -r added_line || [ -n "$added_line" ]; do
            for i in "${!install_keys[@]}"; do
                [[ "$added_line" == *"${install_values[$i]}"* ]] || continue

                # The exception is scoped to the identical target file and to
                # the target's exact multiplicity of this full line. A local
                # duplicate of an otherwise canonical line has no provenance.
                # Cross-file text and unverified payloads never establish it.
                if [ "${INTEGRITY_TAINTED:-true}" != false ] || \
                   [ ! -f "$target_file" ] || \
                   ! grep -Fqx -- "$added_line" "$target_file"; then
                    echo "  ✗ install-value ${install_keys[$i]} найден в новой строке обновления:" >&2
                    printf '    %s\n' "$fpath" >&2
                    failed=1
                    continue
                fi
                applied_line_count=$(grep -Fxc -- "$added_line" "$SCRIPT_DIR/$fpath" || true)
                target_line_count=$(grep -Fxc -- "$added_line" "$target_file" || true)
                if [ "$applied_line_count" -gt "$target_line_count" ]; then
                    echo "  ✗ install-value ${install_keys[$i]} продублирован сверх проверенного target payload:" >&2
                    printf '    %s\n' "$fpath" >&2
                    failed=1
                fi
            done
        done <<<"$applied_additions"
    done

    [ "$failed" -eq 0 ]
}

if ! validate_no_install_values_in_applied_additions; then
    echo "  ОШИБКА: обновление остановлено, чтобы не оставить install paths в шаблоне." >&2
    exit 1
fi

if [ "${#APPLIED_PATHS[@]}" -gt 0 ]; then
    echo "  ✓ Установочные пути не попали в применённые строки."
    echo "  ℹ Изменения оставлены незакоммиченными: проверьте их и синхронизируйте форк через git."
    report_executable_index_mismatches manifest
else
    echo "  Нет изменений шаблона для проверки."
fi

# === Step 7.5: Migration hint — initial-marker для old clones (0.28.5+) ===
# Если у пользователя есть Strategy.md без маркера IWE-INITIAL-NEEDED — намекнуть.
# Это для пользователей, склонировавших до 0.28.5 (skeleton-marker появился в 0.28.5).
# WP-273 0.29.4 R6.4 fix: после WP-273 .exocortex.env живёт в workspace, не в FMT.
# Раньше использовали $SCRIPT_DIR (FMT) → файла там нет → hint никогда не показывался.
ENV_FILE="${WORKSPACE_DIR}/.exocortex.env"
if [ -f "$ENV_FILE" ]; then
    ENV_WS=$(grep -E '^WORKSPACE_DIR=' "$ENV_FILE" | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'")
    ENV_GOV=$(grep -E '^GOVERNANCE_REPO=' "$ENV_FILE" | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'")
    USER_STRATEGY="${ENV_WS:-}/${ENV_GOV:-DS-strategy}/docs/Strategy.md"
    if [ -f "$USER_STRATEGY" ] && ! grep -qF 'IWE-INITIAL-NEEDED' "$USER_STRATEGY"; then
        if grep -qE '^created: YYYY-MM-DD$|^updated: YYYY-MM-DD$' "$USER_STRATEGY" 2>/dev/null; then
            echo ""
            echo "⚠ Strategy.md выглядит как seed-скелет, но без маркера IWE-INITIAL-NEEDED (0.28.5+)."
            echo "  Чтобы /strategy-session корректно ушёл в initial flow, добавьте маркер:"
            echo "    bash $SCRIPT_DIR/scripts/migrate-initial-marker.sh"
        fi
    fi
fi

# === Step 7.6–7.9: post-apply governance backfills ===
# The same helper also runs in TOTAL_CHANGES=0 recovery branches. Otherwise a
# failed first backfill could leave .update-incomplete, while a zero-diff retry
# skipped the failing action and incorrectly cleared the marker.
if ! run_post_apply_backfills_or_die; then
    exit "$EXIT_RUNTIME"
fi

# === Done ===
echo ""
echo "=========================================="
SUMMARY_MSG="  Обновление завершено ($APPLIED файлов"
[ "$REMOVED" -gt 0 ] && SUMMARY_MSG="$SUMMARY_MSG, $REMOVED удалено"
SUMMARY_MSG="$SUMMARY_MSG)"
echo "$SUMMARY_MSG"
if [ "${AUTHOR_SKIPPED:-0}" -gt 0 ]; then
    echo "  ⚠ author_mode: $AUTHOR_SKIPPED файлов пропущено (несмёрженные локальные правки)."
    echo "    Синхронизация — через promote-скрипты, либо вручную после git push."
fi
report_author_skip_summary
echo "=========================================="
echo ""
echo "Перезапустите Claude Code для применения обновлений в memory/."

# issue #226: остальная доставка (memory/hooks/skills, repair-pass, коммит) уже
# выполнена выше независимо от конфликта — теперь сообщаем и выходим с ошибкой,
# чтобы CI/скрипты-обёртки увидели неуспех, а пилот — список файлов на разрешение.
if $CLAUDE_CONFLICT_DETECTED; then
    echo ""
    echo "⚠ CLAUDE.md содержит неразрешённые конфликты слияния в:"
    for cf in "${CLAUDE_CONFLICT_FILES[@]}"; do echo "  - $cf"; done
    echo "  Разрешите их вручную (маркеры <<<<<<< / ======= / >>>>>>>) и закоммитьте отдельно."
fi

# issue #336: отдельный случай — не конфликт (нет маркеров), файл не тронут
# из-за отсутствующего базового файла для слияния. Разное сообщение не путает
# пилота поиском несуществующих <<<<<<< маркеров.
if [ "${#CLAUDE_BASE_MISSING_FILES[@]}" -gt 0 ]; then
    echo ""
    echo "⚠ CLAUDE.md не тронут (нет базового файла для слияния) в:"
    for cf in "${CLAUDE_BASE_MISSING_FILES[@]}"; do echo "  - $cf"; done
    echo "  Сверьте свои правки §8/§9 вручную (см. diff-команду в выводе выше) и закоммитьте отдельно."
fi

# issue #555: separate from both blocks above — base existed, merge reported
# clean, but a pilot line still vanished (see detect_claude_silent_loss).
if [ "${#CLAUDE_SILENT_LOSS_FILES[@]}" -gt 0 ]; then
    echo ""
    echo "⚠ CLAUDE.md не тронут (слияние потеряло бы вашу правку без предупреждения) в:"
    for cf in "${CLAUDE_SILENT_LOSS_FILES[@]}"; do echo "  - $cf"; done
    echo "  Пропавшие строки — в предупреждениях выше. Сверьте вручную и закоммитьте отдельно."
fi

# WP-7 F193: git failed, no merge was made (see claude_merge_failed).
if [ "${#CLAUDE_MERGE_FAILED_FILES[@]}" -gt 0 ]; then
    echo ""
    echo "⚠ CLAUDE.md не тронут (git не выдал слияния) в:"
    for cf in "${CLAUDE_MERGE_FAILED_FILES[@]}"; do echo "  - $cf"; done
    echo "  Проверьте, что git работает (git --version), и перезапустите update.sh: файл не менялся, повтор безопасен."
fi

if $CLAUDE_CONFLICT_DETECTED || [ "${#CLAUDE_BASE_MISSING_FILES[@]}" -gt 0 ] || [ "${#CLAUDE_SILENT_LOSS_FILES[@]}" -gt 0 ] \
    || [ "${#CLAUDE_MERGE_FAILED_FILES[@]}" -gt 0 ]; then
    exit "$EXIT_CONFLICT"
fi

finish_update_transaction
exit_clean

# --- end of update.sh ---
