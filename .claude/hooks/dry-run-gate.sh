#!/bin/bash
# Dry-run Gate Hook (PreToolUse)
# Контракт: memory/dry-run-contract.md
# WP-265 Ф5.2 (ArchGate v3 — вариант F3 sentinel-only). v2: WP-7/BUGTRIAGE2 (issue #237).
#
# Назначение: блокировать write-tools при наличии валидного sentinel-файла.
# Sentinel: единый файл /tmp/iwe-dry-run.flag (не session-bound).
# Причина единого имени: CLAUDE_SESSION_ID не пробрасывается в окружение
# субагентов, поэтому session-bound имя было ненадёжно в самом частом пути
# smoke-теста — sentinel создавал главный агент, subagent Stop-хук снимал
# по своему (пустому) SID, чужой sentinel оставался и залипал на весь TTL.
# Единый файл убирает рассинхрон создания/очистки одним ходом (issue #237 п.2).
# TTL: 2400 секунд (40 минут) от mtime — измеренный `close day` занимает ~26
# минут (issue #460), запас держит легитимную репетицию живой без heartbeat.
#
# Принципы:
# - jq отсутствует / owner-файл сиротеет без sentinel / TTL истёк → fail-CLOSED,
#   не skip/allow (memory/dry-run-contract.md §Fail-safe; issue #460 paths 1-3:
#   a gate that can't see its own state has no basis to allow).
# - exit 0 = allow (sentinel отсутствует и никакой репетиции не объявлено)
# - exit 2 = block (с диагностикой в stderr; включает jq missing,
#   sentinel_missing-with-owner и TTL-expired)

set -uo pipefail
export PATH="/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

SENTINEL="${IWE_DRY_RUN_SENTINEL:-/tmp/iwe-dry-run.flag}"
TTL_SECONDS=2400
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IWE_ROOT_GUESS="$(cd "$HOOK_DIR/../.." 2>/dev/null && pwd -P)"
GATE_LOG="$IWE_ROOT_GUESS/.claude/logs/gate_log.jsonl"

# issue #549 stage 2: каноническая запись состояния репетиции (redesign).
# Sentinel остаётся маркером активного режима (на него завязана whitelist-
# машинерия ниже), но решение о блокировке принимается по state-файлу.
# Каталог приватный (только этот uid): symlink/чужой владелец/групповая
# запись = попытка подмены → fail-closed.
DRY_DIR="${IWE_DRY_RUN_DIR:-/tmp/iwe-dry-run-$(id -u)}"
# Env-оверрайды путей — только явный тестовый режим (Codex r1: ambient
# IWE_DRY_RUN_DIR/IWE_DRY_RUN_SENTINEL из конфигурации запуска не должны
# отключать production-защиту). Маркер создаётся тестом внутри override-
# каталога; без него действуют production-пути.
if [ -n "${IWE_DRY_RUN_DIR:-}" ] || [ -n "${IWE_DRY_RUN_SENTINEL:-}" ]; then
    if [ ! -f "${IWE_DRY_RUN_DIR:-/nonexistent}/.iwe-dry-run-test-mode" ]; then
        DRY_DIR="/tmp/iwe-dry-run-$(id -u)"
        SENTINEL="/tmp/iwe-dry-run.flag"
    fi
fi
LOCK_DIR="$DRY_DIR/transaction.lock"

fail_closed() { # <message...> — единая точка вечной блокировки с диагностикой
    {
        echo "[dry-run-gate] BLOCKED: $*"
        echo "Reason: dry-run state machine fail-closed (см. memory/dry-run-contract.md)"
    } >&2
    exit 2
}

gate_log_event() { # <event> <detail>
    mkdir -p "$(dirname "$GATE_LOG")" 2>/dev/null || true
    printf '{"ts":"%s","gate":"dry-run-gate","event":"%s","detail":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >> "$GATE_LOG" 2>/dev/null || true
}

# lstat-проверка приватного каталога (Codex design review: /tmp без защищённого
# каталога допускает подмену и symlink-атаки). Вызывается лениво — только когда
# dry-run реально задействован, чтобы не создавать каталог на каждый tool-call.
dry_dir_ensure() {
    if [ -L "$DRY_DIR" ]; then
        fail_closed "dry-run dir $DRY_DIR is a symlink — refusing (possible attack)"
    fi
    if [ ! -d "$DRY_DIR" ]; then
        mkdir -m 0700 "$DRY_DIR" 2>/dev/null || fail_closed "cannot create $DRY_DIR with 0700"
    fi
    local owner
    case "$(uname)" in
        Darwin) owner=$(stat -f %u "$DRY_DIR" 2>/dev/null) ;;
        *)      owner=$(stat -c %u "$DRY_DIR" 2>/dev/null) ;;
    esac
    [ "$owner" = "$(id -u)" ] || fail_closed "dry-run dir $DRY_DIR owned by uid $owner, expected $(id -u)"
    # group/other write запрещены (lstat-форма без следования symlink — каталог уже проверен выше)
    local perms
    case "$(uname)" in
        Darwin) perms=$(stat -f %Lp "$DRY_DIR" 2>/dev/null) ;;
        *)      perms=$(stat -c %a "$DRY_DIR" 2>/dev/null) ;;
    esac
    [ -n "$perms" ] || fail_closed "cannot stat permissions of $DRY_DIR"
    # perms — строка восьмеричных цифр ("700"); интерпретируем как octal.
    # bash 3.2: ${var:-default} внутри $(( )) не парсится — default выше отдельно.
    [ $(( 8#$perms & 077 )) -eq 0 ] || fail_closed "dry-run dir $DRY_DIR has group/other write permissions ($perms)"
}

# Транзакционный замок через mkdir (переносимо; flock(1) на macOS отсутствует).
# Замок несёт владельца (pid + lstart): доказуемо осиротевший замок (владелец
# мёртв) снимается; живой владелец после исчерпания попыток → fail-closed
# (Codex: голый mkdir-lock вечен после аварии внутри транзакции).
# ABA-защита (Codex r1): устаревший замок уносится уникальным именем и
# удаляется именно он, не потенциально новый замок другого процесса;
# замок несёт owner (pid + nonce); освобождение — только по своему nonce.
LOCK_NONCE=""
lock_acquire() {
    local tries=0
    while ! mkdir "$LOCK_DIR" 2>/dev/null; do
        tries=$((tries + 1))
        if [ "$tries" -gt 20 ]; then
            # Последний шанс: владелец замка доказуемо мёртв (pid не жив ИЛИ
            # его старт не совпадает с записанным — pid reuse)?
            local lock_pid lock_start cur_start
            lock_pid=$(sed -n '1p' "$LOCK_DIR/pid" 2>/dev/null || true)
            lock_start=$(sed -n '3p' "$LOCK_DIR/pid" 2>/dev/null || true)
            cur_start=$(ps -o lstart= -p "$lock_pid" 2>/dev/null || true)
            if [ -n "$lock_pid" ] && { ! kill -0 "$lock_pid" 2>/dev/null || { [ -n "$lock_start" ] && [ -n "$cur_start" ] && [ "$lock_start" != "$cur_start" ]; }; }; then
                mv "$LOCK_DIR" "$DRY_DIR/.stale-lock-$$-$(date +%s)" 2>/dev/null || true
                rm -rf "$DRY_DIR"/.stale-lock-* 2>/dev/null || true
                gate_log_event "lock_orphan_swept" "pid=$lock_pid"
                mkdir "$LOCK_DIR" 2>/dev/null && break
            fi
            return 1
        fi
        sleep 0.1 2>/dev/null || sleep 1
    done
    LOCK_NONCE=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
    # Owner: pid + nonce + lstart (stale-детект по смерти pid ИЛИ несовпадению
    # старта — pid reuse). Ошибка записи owner-файла = замок не захвачен
    # (Codex r2: подавленная ошибка записи делала замок вечным).
    if ! { echo "$$"; echo "$LOCK_NONCE"; ps -o lstart= -p $$ 2>/dev/null || echo "unknown"; } > "$LOCK_DIR/pid" 2>/dev/null; then
        rm -rf "$LOCK_DIR" 2>/dev/null || true
        return 1
    fi
    return 0
}
lock_release() {
    [ -n "$LOCK_NONCE" ] || return 0
    if [ "$(sed -n '2p' "$LOCK_DIR/pid" 2>/dev/null)" = "$LOCK_NONCE" ]; then
        rm -rf "$LOCK_DIR" 2>/dev/null || true
    fi
    LOCK_NONCE=""
}

state_path() { printf '%s/gate-%s.state' "$DRY_DIR" "$1"; }
state_field() { jq -r ".$2 // empty" "$1" 2>/dev/null || true; }

# Строгая валидация state-файла (Codex r1: битый JSON / чужая версия /
# mismatch имени и .gate_id / неизвестное состояние — corruption, fail-closed,
# а не «не active»). Печатает gate_id валидного active-файла.
validate_state_file() { # <path> → rc 0 ok, 2 corruption; stdout: "state gate_id"
    local sf="$1" st gid ver
    jq -e . "$sf" >/dev/null 2>&1 || return 2
    ver=$(jq -r '.version // empty' "$sf" 2>/dev/null || true)
    [ "$ver" = "2" ] || return 2
    gid=$(jq -r '.gate_id // empty' "$sf" 2>/dev/null || true)
    [ -n "$gid" ] || return 2
    [ "gate-$gid.state" = "$(basename "$sf")" ] || return 2
    st=$(jq -r '.state // empty' "$sf" 2>/dev/null || true)
    case "$st" in
        active|completed) printf '%s %s\n' "$st" "$gid" ;;
        *) return 2 ;;
    esac
}

# Атомарный переход active→completed (tmp+mv в том же каталоге, монотонно,
# идемпотентно: повторное завершение не перетирает исходные metadata).
complete_gate() { # <gate_id> <reason>
    local gate_id="$1" reason="$2" sp tmp
    sp=$(state_path "$gate_id")
    [ -f "$sp" ] || return 1
    [ "$(state_field "$sp" state)" = "active" ] || return 0
    tmp=$(mktemp "$DRY_DIR/.complete.XXXXXX") || return 1
    jq --arg completed "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg reason "$reason" \
        '.state="completed" | .completed_at=$completed | .completion_reason=$reason' \
        "$sp" > "$tmp" 2>/dev/null && mv -f "$tmp" "$sp" || { rm -f "$tmp"; return 1; }
    gate_log_event "gate_completed" "gate_id=$gate_id reason=$reason"
    return 0
}

# Скан всех state-файлов со строгой валидацией. stdout: пары "state gate_id".
# Любая corruption → rc 2 (НЕ «тихо пропустить файл»); вызывающий обязан
# проверить код — через process substitution rc subshell теряется (Codex r1:
# fail_closed внутри <( ) завершает только подпроцесс, гейт продолжал и
# разрешал операцию).
scan_states() {
    local sf entry
    shopt -s nullglob
    for sf in "$DRY_DIR"/gate-*.state; do
        entry=$(validate_state_file "$sf") || return 2
        printf '%s\n' "$entry"
    done
    shopt -u nullglob
}

# Доказуемое сиротство (оба условия, fail-closed при любой неоднозначности):
# 1. owner_pid мёртв ИЛИ его lstart не совпадает с записанным (pid reuse);
# 2. ни одного живого процесса с owner_pgid (погибло всё дерево репетиции).
# Числовая валидация аргументов (Codex r1: pgid=0/foo — не доказано).
# Ошибка ps / пустой вывод / нечисловые поля → return 2 (не доказано ≠ сиротство).
# Известный остаток (документировано в контракте): если рантайм помещает сам
# гейт в process group владельца, скан pgid всегда видит «живых» → вечный
# fail-closed (безопасное направление), sweep не сработает.
orphan_proven() { # <pid> <pid_start> <pgid>
    local pid="$1" pid_start="$2" pgid="$3" cur_start snapshot
    case "$pid" in ''|*[!0-9]*|0) return 2 ;; esac
    case "$pgid" in ''|*[!0-9]*|0) return 2 ;; esac
    if kill -0 "$pid" 2>/dev/null; then
        cur_start=$(ps -o lstart= -p "$pid" 2>/dev/null) || return 2
        [ -n "$cur_start" ] || return 2
        # Жив и старт совпадает — владелец жив, сиротства нет.
        [ "$cur_start" = "$pid_start" ] && return 1
        # Жив, но старт другой — pid reuse: исходный владелец мёртв.
    fi
    snapshot=$(ps -eo pid=,pgid= 2>/dev/null) || return 2
    [ -n "$snapshot" ] || return 2
    if printf '%s\n' "$snapshot" | awk -v pg="$pgid" '$1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $2 == pg {f=1} END{exit f?0:1}'; then
        return 1  # дерево репетиции ещё живо — не сирот
    fi
    return 0
}

# jq нужен для разбора payload. Per contract (memory/dry-run-contract.md
# §Fail-safe): a broken gate must fail-CLOSED, not open — a gate that can't
# see its own state has no basis to allow (issue #460 path 1; this used to
# exit 0, contradicting the fail-CLOSED example already documented in the
# contract).
if ! command -v jq >/dev/null 2>&1; then
    echo "[dry-run-gate] FAIL-CLOSED: jq missing, blocking by default (install jq to restore normal operation)" >&2
    exit 2
fi

# Sentinel-симлинк — попытка подмены, а не состояние (lstat-проверка,
# Codex design review: битый symlink дал бы ложное «sentinel отсутствует»).
if [ -L "$SENTINEL" ]; then
    fail_closed "sentinel $SENTINEL is a symlink — refusing"
fi

# Sentinel отсутствует — dry-run неактивен. Если capability-файл владельца
# остался, защита исчезла неожиданно или была снята явно до Stop: раньше
# это только писалось в лог и всё равно allow'илось (#369) — тот же класс
# fail-open, что путь 1 выше (issue #460 path 2). Owner-файл — прямое
# доказательство, что репетиция ещё объявлена активной; блокируем вместо
# молчаливого прохода записи мимо потерянной защиты.
if [ ! -f "$SENTINEL" ]; then
    # issue #549 stage 2: сначала канонические state-файлы (см. шапку).
    # Доказуемое сиротство снимает вечную блокировку; недоказанное — нет.
    if [ -d "$DRY_DIR" ] && [ ! -L "$DRY_DIR" ]; then
        dry_dir_ensure
        # Строгий скан под транзакционным замком (Codex r1: без замка —
        # TOCTOU с созданием новой репетиции; битый/чужой state — corruption,
        # не «не active»).
        if ! lock_acquire; then
            fail_closed "transaction lock held by a live process — dry-run state busy, retry later"
        fi
        ACTIVE_GIDS=()
        STATES_OUT=""
        if ! STATES_OUT=$(scan_states); then
            lock_release
            fail_closed "corrupted dry-run state file in $DRY_DIR"
        fi
        while IFS= read -r entry; do
            [ -n "$entry" ] || continue
            case "${entry%% *}" in
                active) ACTIVE_GIDS+=("${entry#* }") ;;
            esac
        done <<< "$STATES_OUT"
        if [ "${#ACTIVE_GIDS[@]}" -gt 1 ]; then
            lock_release
            fail_closed "multiple active dry-run states — corruption (exclusivity invariant broken): ${ACTIVE_GIDS[*]}"
        fi
        if [ "${#ACTIVE_GIDS[@]}" -eq 1 ]; then
            gate_id="${ACTIVE_GIDS[0]}"
            sf=$(state_path "$gate_id")
            owner_pid=$(state_field "$sf" owner_pid)
            owner_start=$(state_field "$sf" owner_pid_start)
            owner_pgid=$(state_field "$sf" owner_pgid)
            if orphan_proven "$owner_pid" "$owner_start" "$owner_pgid"; then
                # Ошибка перехода ≠ разрешение (Codex r1): complete_gate
                # провалился — fail-closed, state остаётся active.
                if ! complete_gate "$gate_id" "orphan-sweep"; then
                    lock_release
                    fail_closed "orphan proven for gate_id=$gate_id but atomic completion failed — refusing to open"
                fi
                lock_release
                exit 0
            fi
            lock_release
            {
                echo "[dry-run-gate] BLOCKED: dry-run sentinel missing while state gate_id=$gate_id is still active"
                echo "Reason: owner alive or orphanhood not proven — fail-closed per contract"
                printf 'Recovery (pilot terminal only, after confirming no dry-run is actually active):\n  bash %q %s manual-recovery\n' \
                    "$IWE_ROOT_GUESS/FMT-exocortex-template/scripts/dry-run-complete.sh" "$gate_id"
            } >&2
            exit 2
        fi
        lock_release
    fi
    # Legacy-ветка старого формата (owner-*.token без state-файла) — без
    # изменений: вечный fail-closed с точной командой восстановления.
    OWNER_FILE=$(find -L /tmp -maxdepth 1 -name 'iwe-dry-run-owner-*.token' -type f -print -quit 2>/dev/null || true)
    if [ -n "$OWNER_FILE" ]; then
        gate_log_event "sentinel_missing" "owner_file=$(basename "$OWNER_FILE")"
        {
            echo "[dry-run-gate] BLOCKED: dry-run sentinel missing while owner file $(basename "$OWNER_FILE") still present"
            echo "Reason: protection lost mid-rehearsal (TTL/crash/race) — fail-closed per contract"
            # issue #549 stage 1: this branch is fail-closed FOREVER by design
            # (no TTL — elapsed time proves nothing about completion), and the
            # gate blocks the agent's own rm before the whitelist is reached,
            # so recovery is only possible from the pilot's own terminal.
            # Name the exact command instead of leaving the user to guess.
            printf 'Recovery (pilot terminal only, after confirming no dry-run is actually active):\n  rm -f %q\n' "$OWNER_FILE"
        } >&2
        exit 2
    fi
    exit 0
fi

# issue #549 stage 2: sentinel с gate_id — решение по каноническому state,
# не только по TTL ниже. Sentinel старого формата (без gate_id) идёт по
# прежнему пути TTL+whitelist без изменений.
# lstat-инварианты sentinel (Codex r1): обычный файл того же владельца.
case "$(uname)" in
    Darwin) S_UID=$(stat -f %u "$SENTINEL" 2>/dev/null || true) ;;
    *)      S_UID=$(stat -c %u "$SENTINEL" 2>/dev/null || true) ;;
esac
[ -n "$S_UID" ] && [ "$S_UID" = "$(id -u)" ] || fail_closed "sentinel $SENTINEL owned by uid ${S_UID:-unknown}, expected $(id -u)"
SENTINEL_GID=$(jq -r '.gate_id // empty' "$SENTINEL" 2>/dev/null || true)
if [ -n "$SENTINEL_GID" ]; then
    dry_dir_ensure
    SP=$(state_path "$SENTINEL_GID")
    [ -f "$SP" ] || fail_closed "sentinel references unknown gate_id=$SENTINEL_GID — corruption or manual edit"
    # Валидация state-файла, на который ссылается sentinel (тот же строгий
    # контракт, что у сканера: mismatch имени/.gate_id — corruption).
    validate_state_file "$SP" >/dev/null || fail_closed "state for gate_id=$SENTINEL_GID failed validation — corruption"
    ST=$(state_field "$SP" state)
    case "$ST" in
        completed)
            # Самолечение ПОД ЗАМКОМ (Codex r1: без замка гонка — между чтением
            # и rm новая репетиция может записать новый sentinel, и мы удалим
            # чужой). Повторное чтение sentinel под замком: удаляем, только
            # если он всё ещё про ЗАВЕРШЁННЫЙ gate_id и нет нового active.
            if ! lock_acquire; then
                fail_closed "transaction lock busy during stale-sentinel sweep (gate_id=$SENTINEL_GID)"
            fi
            CUR_GID=$(jq -r '.gate_id // empty' "$SENTINEL" 2>/dev/null || true)
            NEW_ACTIVE=0
            STATES_OUT=""
            if ! STATES_OUT=$(scan_states); then
                lock_release
                fail_closed "corrupted dry-run state file in $DRY_DIR"
            fi
            while IFS= read -r entry; do
                [ -n "$entry" ] || continue
                [ "${entry%% *}" = "active" ] && NEW_ACTIVE=1
            done <<< "$STATES_OUT"
            if [ "$CUR_GID" = "$SENTINEL_GID" ] && [ "$NEW_ACTIVE" = "0" ]; then
                rm -f "$SENTINEL"
                gate_log_event "stale_sentinel_swept" "gate_id=$SENTINEL_GID"
                lock_release
                exit 0
            fi
            lock_release
            # Sentinel под замком сменился (новая репетиция / чужая запись) —
            # не трогаем чужое и не открываем: fail-closed с диагностикой.
            fail_closed "sentinel changed during stale sweep (was gate_id=$SENTINEL_GID, now '${CUR_GID:-none}', active_present=$NEW_ACTIVE) — refusing to remove чужой sentinel"
            ;;
        active)
            ;; # штатный dry-run режим — дальше TTL + whitelist
        *)
            fail_closed "gate state for gate_id=$SENTINEL_GID is '$ST' — corruption"
            ;;
    esac
fi

case "$(uname)" in
    Darwin) MTIME=$(stat -f %m "$SENTINEL" 2>/dev/null) ;;
    *)      MTIME=$(stat -c %Y "$SENTINEL" 2>/dev/null) ;;
esac

if [ -z "$MTIME" ]; then
    # Файл исчез между test и stat (race с параллельной очисткой) — allow.
    exit 0
fi

NOW=$(date +%s)
if [ $((NOW - MTIME)) -gt $TTL_SECONDS ]; then
    # issue #460 path 3: used to `rm -f` and allow — a gate deleting its own
    # protection then trusting the write is the same fail-open shape as
    # paths 1-2. A stale sentinel means the owner crashed or forgot cleanup,
    # not that the rehearsal ended safely; block and require an explicit
    # `rm -f "$SENTINEL"` once that's confirmed.
    {
        echo "[dry-run-gate] BLOCKED: sentinel stale (older than ${TTL_SECONDS}s, mtime $MTIME)"
        echo "Reason: TTL expired without cleanup — owner likely crashed, protection kept fail-closed"
        echo "If the rehearsal really ended: rm -f $SENTINEL"
    } >&2
    exit 2
fi

# Прочитать tool_name и tool_input из stdin
INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // ""')
[ -z "$TOOL_NAME" ] && exit 0

# Метаданные sentinel (для диагностики)
SENTINEL_META=$(cat "$SENTINEL" 2>/dev/null || echo '{}')
SENTINEL_INITIATOR=$(echo "$SENTINEL_META" | jq -r '.initiator // "unknown"' 2>/dev/null || echo "unknown")
SENTINEL_CREATED=$(echo "$SENTINEL_META" | jq -r '.created_at // "unknown"' 2>/dev/null || echo "unknown")

block() {
    local target="$1"
    {
        echo "[dry-run-gate] BLOCKED: $TOOL_NAME on $target"
        echo "Reason: dry-run mode active (sentinel created at $SENTINEL_CREATED, by $SENTINEL_INITIATOR)"
        echo "Expected: tool blocked by contract, this is rehearsal failure point"
    } >&2
    exit 2
}

# === Прямые write-tools: Write, Edit, MultiEdit, NotebookEdit ===
case "$TOOL_NAME" in
    Write|Edit|MultiEdit|NotebookEdit)
        FP=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // ""')
        block "${FP:-<no path>}"
        ;;
esac

# === MCP-write whitelist (точные совпадения tool_name) ===
case "$TOOL_NAME" in
    mcp__claude_ai_IWE__personal_write|\
    mcp__claude_ai_IWE__personal_delete|\
    mcp__claude_ai_IWE__personal_create_pack|\
    mcp__claude_ai_IWE__personal_propose_capture|\
    mcp__claude_ai_IWE__personal_reindex_source|\
    mcp__claude_ai_IWE__personal_scaffold_notes|\
    mcp__claude_ai_IWE__dt_write_digital_twin|\
    mcp__claude_ai_IWE__create_repository|\
    mcp__claude_ai_IWE__github_connect|\
    mcp__claude_ai_IWE__github_disconnect|\
    mcp__claude_ai_IWE__knowledge_feedback|\
    mcp__claude_ai_Gmail__create_draft|\
    mcp__claude_ai_Gmail__create_label|\
    mcp__claude_ai_Gmail__label_message|\
    mcp__claude_ai_Gmail__label_thread|\
    mcp__claude_ai_Gmail__unlabel_message|\
    mcp__claude_ai_Gmail__unlabel_thread|\
    mcp__claude_ai_Google_Calendar__create_event|\
    mcp__claude_ai_Google_Calendar__delete_event|\
    mcp__claude_ai_Google_Calendar__update_event|\
    mcp__claude_ai_Google_Calendar__respond_to_event|\
    mcp__claude_ai_Google_Drive__create_file|\
    mcp__ext-google-calendar__create-event|\
    mcp__ext-google-calendar__create-events|\
    mcp__ext-google-calendar__delete-event|\
    mcp__ext-google-calendar__update-event|\
    mcp__ext-google-calendar__respond-to-event|\
    mcp__ext-google-drive__copy_file|\
    mcp__ext-google-drive__create_file|\
    mcp__ext-google-drive__create_folder|\
    mcp__ext-google-drive__delete_file|\
    mcp__ext-google-drive__move_file|\
    mcp__ext-google-drive__update_file|\
    mcp__ext-google-drive__share_file|\
    mcp__ext-linear__create_issue|\
    mcp__ext-linear__update_issue|\
    mcp__ext-railway__create-environment|\
    mcp__ext-railway__create-project-and-link|\
    mcp__ext-railway__deploy|\
    mcp__ext-railway__deploy-template|\
    mcp__ext-railway__generate-domain|\
    mcp__ext-railway__link-environment|\
    mcp__ext-railway__link-service|\
    mcp__ext-railway__set-variables)
        block "$TOOL_NAME"
        ;;
esac

# === Bash matchers ===
#
# v2 (issue #237): вместо grep по всей строке команды — три прохода:
#  1) вырезать кавычные спаны (текст внутри '...'/"..." не может изображать
#     команду — раньше `echo "see: git commit"` ложно матчился, issue #237 п.4);
#  2) разбить нормализованную строку на простые команды по разделителям
#     ; & | && || ( ) { } $( ` — раньше `(git commit -am x)` в скобках
#     проходил незамеченным, issue #237 п.1;
#  3) классифицировать каждый фрагмент по первому слову (после пропуска
#     VAR=val/command/env/nohup/time/sudo), а не искать подстроку где попало.
#
# Единственное исключение из шага 1 — psql: SQL живёт внутри кавычек, поэтому
# SQL-write матчится по НЕнормализованной команде, но только когда первое
# слово фрагмента — psql (иначе `grep "psql -c INSERT" file` снова ложно бьёт).
if [ "$TOOL_NAME" = "Bash" ]; then
    CMD=$(echo "$INPUT" | jq -r '.tool_input.command // ""')
    [ -z "$CMD" ] && exit 0

    # Шаг 1: убрать кавычные спаны и безвредные redirect-в-null.
    # issue #315-fix2: единственная реальная (документированная в day-close/SKILL.md,
    # day-close-details.md) форма вызова day-close-prepare.sh — quoted var-expansion
    # bash "$IWE_SCRIPTS/day-close-prepare.sh". Это ЛИТЕРАЛЬНАЯ строка (переменная
    # ещё не раскрыта на момент PreToolUse — раскрытие делает bash при реальном
    # исполнении, уже после гейта), но она попадает под общий s/"[^"]*"/ QSTR /g
    # ниже и превращается в неотличимый от любой другой строки токен QSTR —
    # whitelist-case ниже никогда не совпадает с этой формой (проверено живым
    # воспроизведением команды из day-close-details.md:32). Точечная замена
    # ДО общего схлопывания кавычек сохраняет опознаваемость именно этого
    # прошитого паттерна, не открывая общий обход кавычек для прочего.
    # issue #460 путь 5: day-close/SKILL.md шаги 1/2 вызывают два read-only
    # диагностических python-скрипта через `${IWE_TEMPLATE:-<HOME_DIR>/IWE/...}/...`
    # — unquoted brace-expansion. Тот же класс проблемы, что day-close-prepare.sh
    # выше: `{`/`}` внутри `${...}` попадают под общий split-на-простые-команды
    # (шаг 2, символы `(){}&;` — разделители) и рвут путь на куски раньше, чем
    # whitelist-case у python|python3 успевает его увидеть целиком. Точечная
    # замена ДО split сохраняет опознаваемость именно этих двух прошитых вызовов
    # (подтверждено code review: без этого фикс путь 5 блокирует день. close на
    # первом же шаге — читай-только скрипты, а не место реального write).
    #
    # Точный путь в паттерне, НЕ wildcard: `[^}]*` вместо конкретного
    # default-значения разрешал бы `${IWE_TEMPLATE:-$(cmd)}/...` — command
    # substitution внутри default оказывался бы проглочен маркером ДО того, как
    # шаг 2 успевает его сегментировать и опознать (round-2 review, живое
    # воспроизведение: `${IWE_TEMPLATE:-$(touch /tmp/PWNED)}/...` проходил как
    # allow). Тот же урок, что уже применён к `WL_ABS`/`WL_ABS2` ниже (review-01
    # High/review-02 H1) — whitelist только по точной строке, не по glob.
    # issue #694: якорь — $IWE_ROOT_GUESS (путь самого хука, вычислен строкой
    # ~27 из BASH_SOURCE), не $HOME/IWE — тот же приём, что уже используется
    # для GATE_LOG выше. Не env-переменная (IWE_WORKSPACE/IWE_TEMPLATE
    # инжектируемы вызывающим окружением — тот самый обход, который
    # review-01/review-02 закрыли отказом от env-default в этом whitelist).
    WL_TEMPLATE_ABS="$IWE_ROOT_GUESS/FMT-exocortex-template"
    # Cold-review finding (Codex, 2026-09-14): a STATIC marker string in a
    # NORM whitelist is spoofable — an attacker can type the marker text
    # literally as the command's own bare argument and bypass the gate by
    # planting a same-named file, since NORM only ever ADDS the marker, it
    # never proves the marker came from OUR substitution rather than from
    # the attacker's own input. GATE_NONCE makes the NEW .iwe-paths marker
    # below unpredictable per invocation (this hook is a fresh process per
    # PreToolUse call, so the attacker's $CMD is fixed before this nonce
    # even exists) — scoped ONLY to issue #784/#785's whitelist, not to the
    # pre-existing static markers (__WL_DAY_CLOSE_PREPARE__ etc. below),
    # which are a separate, already-shipped finding outside this fix's scope.
    GATE_NONCE=$(od -An -N8 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
    [ -n "$GATE_NONCE" ] || GATE_NONCE="$$-$(date +%s%N 2>/dev/null || date +%s)"
    NORM=$(printf '%s' "$CMD" | sed -E \
        -e 's@"\$IWE_SCRIPTS/day-close-prepare\.sh"@ __WL_DAY_CLOSE_PREPARE__ @g' \
        -e 's@"\$IWE_SCRIPTS/dry-run-complete\.sh"@ __WL_DRY_RUN_COMPLETE__ @g' \
        -e "s@\\\$\\{IWE_TEMPLATE:-${WL_TEMPLATE_ABS//\//\\/}\\}/\\.claude/scripts/memory-drift-scan\\.py@ __WL_PY_MDS__ @g" \
        -e "s@\\\$\\{IWE_TEMPLATE:-${WL_TEMPLATE_ABS//\//\\/}\\}/\\.claude/scripts/check-index-health\\.py@ __WL_PY_CIH__ @g" \
        -e "s@\"\\\$HOME/\\.iwe-paths\"@ __WL_IWE_PATHS_${GATE_NONCE}__ @g" \
        -e "s@\"\\\$\\{IWE_PATHS_FILE:-\\\$HOME/\\.iwe-paths\\}\"@ __WL_IWE_PATHS_${GATE_NONCE}__ @g" \
        -e "s/'[^']*'/ QSTR /g" \
        -e 's/"[^"]*"/ QSTR /g' \
        -e 's@[0-9]?>[[:space:]]*/dev/null@ @g' \
        -e 's@2>&1@ @g')
    NORM_RC=$?
    # Codex review (2026-09-14): a broken -e expression makes the WHOLE sed
    # invocation fail with EMPTY stdout (verified live: any invalid -e in
    # this pipeline → exit 1, zero bytes out — sed validates the full -e
    # script upfront, before touching input). $(...) alone doesn't stop the
    # script (no `set -e` here, only pipefail) — without this check, NORM
    # would silently become "", SPLIT/the whole Bash-matcher loop below would
    # never iterate, and every single Bash command would fall through to
    # "read-only: allow" at the bottom of the file, regardless of content.
    # Found live while adding the #784/#785 whitelist to this same pipeline.
    if [ "$NORM_RC" -ne 0 ]; then
        fail_closed "NORM sed pipeline failed (exit $NORM_RC) — cannot classify command, refusing to allow"
    fi

    # Редирект в реальный файл — проверяем по нормализованной строке целиком
    # (позиционно-независим относительно сегментации ниже, как и раньше).
    if echo "$NORM" | grep -qE '[[:space:]]>>?[[:space:]]'; then
        block "$CMD (redirect to file)"
    fi

    # Шаг 2: разбить на простые команды.
    SPLIT=$(printf '%s\n' "$NORM" | sed -E 's/\$\(|`|[(){}&;]|\|\|?|&&/\n/g')

    # Live-review finding (Fable, 2026-09-14): whitelist для .iwe-paths матчит
    # ЛИТЕРАЛЬНЫЙ ТЕКСТ "$HOME/.iwe-paths"/"${IWE_PATHS_FILE:-...}", а не
    # разрешённое значение — цикл ниже классифицирует каждый сегмент НЕЗАВИСИМО
    # и не помнит присваиваний из предыдущих сегментов. Живой прогон подтвердил
    # обход: `HOME=/tmp/evil; . "$HOME/.iwe-paths"` при РЕАЛЬНОМ исполнении
    # сорсит /tmp/evil/.iwe-paths (bash подставляет переменную в момент
    # выполнения, уже после этого гейта), но классификатор видит второй сегмент
    # изолированно и не знает о переопределении в первом. Обнаружено уже после
    # деплоя — сканируем ВЕСЬ SPLIT заранее на переопределение HOME/
    # IWE_PATHS_FILE где угодно в команде и отзываем whitelist для всей команды,
    # если оно есть. round-2 cold-review (Codex, 2026-09-14) нашёл, что первая
    # версия regex (якорь на начало сегмента, только export) пропускала:
    # (a) префиксное присваивание НЕ первым словом сегмента (`x=1 HOME=evil cmd`),
    # (b) readonly/declare/typeset/local/builtin export/command export,
    # (c) printf -v HOME / read HOME (присваивание через builtin, не `VAR=`).
    # Регекс ниже покрывает все три класса; кавычные спаны уже схлопнуты в QSTR
    # к этому шагу (см. sed выше), поэтому "HOME=" внутри пользовательской
    # строки (напр. python -c "...HOME=...") сюда не протекает.
    HOME_OR_IWE_PATHS_TAMPERED=0
    if printf '%s\n' "$SPLIT" | grep -qE \
        '(^|[[:space:]])(builtin[[:space:]]+|command[[:space:]]+)?(export|readonly|declare|typeset|local)([[:space:]]+-[A-Za-z]+)*[[:space:]]+(HOME|IWE_PATHS_FILE)=|(^|[[:space:]])(HOME|IWE_PATHS_FILE)=|(^|[[:space:]])printf([[:space:]]+[^[:space:]]*)*[[:space:]]+-v[[:space:]]+(HOME|IWE_PATHS_FILE)([[:space:]]|$)|(^|[[:space:]])read([[:space:]]+-[A-Za-z]+)*[[:space:]]+(HOME|IWE_PATHS_FILE)([[:space:]]|$)' \
    ; then
        HOME_OR_IWE_PATHS_TAMPERED=1
    fi

    while IFS= read -r SEG; do
        [ -z "$SEG" ] && continue
        # shellcheck disable=SC2086
        set -- $SEG
        # Пропустить VAR=val / command / env / nohup / time / sudo / nice — переход
        # к реальной команде. issue #825, две дыры (обе живьём подтверждены
        # cold-review): (1) `nice` отсутствовал в списке обёрток — `nice rm -f
        # ...` проходил непроверенным; (2) сравнение по литеральному слову не
        # матчило `/usr/bin/nice ...`/абсолютный путь к любой обёртке —
        # basename (`${1##*/}`) закрывает это без обращения к файловой системе
        # (не readlink/stat — чистая строковая операция, не открывает тот же
        # класс обхода, что был закрыт для WL_ABS/WL_ABS2/WL_ABS3 review-01/02:
        # те сравнивают ВТОРОЙ токен — путь к скрипту-аргументу — для ALLOW,
        # остаются литеральными; здесь меняется только то, в какой БЛОКИРУЮЩИЙ
        # рукав попадёт команда).
        while [ $# -gt 0 ]; do
            case "$1" in
                *=*) shift ;;
                *)
                    case "${1##*/}" in
                        command|env|nohup|time|sudo) shift ;;
                        nice)
                            shift
                            # nice сам принимает необязательный аргумент
                            # приоритета — `nice -n 19 cmd`/`nice -n19 cmd`
                            # (самая частая форма реального вызова) без этого
                            # блока не матчили ни VAR=, ни список обёрток и
                            # останавливали цикл на W0=-n, снова проходя
                            # непроверенными (cold-review нашёл живьём).
                            case "${1:-}" in
                                -n) [ $# -ge 2 ] && shift 2 || shift ;;
                                -n*|--adjustment=*) shift ;;
                                -[0-9]*) shift ;;
                            esac
                            ;;
                        *) break ;;
                    esac
                    ;;
            esac
        done
        [ $# -eq 0 ] && continue
        W0="${1##*/}"

        case "$W0" in
            git)
                shift
                # Пропустить global opts: -C dir, --git-dir=X, --work-tree=X, -c key=val
                while [ $# -gt 0 ]; do
                    case "$1" in
                        -C|--git-dir|--work-tree) shift 2 ;;
                        --git-dir=*|--work-tree=*) shift ;;
                        -c) shift 2 ;;
                        -c*) shift ;;
                        *) break ;;
                    esac
                done
                case "${1:-}" in
                    add|commit|push|pull|reset|merge|rebase|mv|rm) block "$CMD (git write)" ;;
                    checkout) case "${2:-}" in -*) block "$CMD (git checkout -)" ;; esac ;;
                esac
                ;;
            rm|mv)
                shift
                ARGS=""
                for a in "$@"; do
                    case "$a" in
                        -*) ;;
                        *) ARGS="$ARGS $a" ;;
                    esac
                done
                # Cleanup-исключение: собственный dry-run sentinel — единственный allow.
                [ "$ARGS" = " $SENTINEL" ] && continue
                block "$CMD (filesystem mutation)"
                ;;
            tee)
                case "${2:-}" in
                    /dev/null) ;;
                    *) block "$CMD (tee write)" ;;
                esac
                ;;
            sed)
                echo "$SEG" | grep -qE '(^|[[:space:]])-[a-zA-Z]*i' && block "$CMD (sed in-place)"
                ;;
            curl)
                echo "$SEG" | grep -qE '(-X[[:space:]]*)?(POST|PUT|DELETE|PATCH)|--data|(^|[[:space:]])-d([[:space:]]|$)' \
                    && block "$CMD (HTTP write)"
                ;;
            psql)
                # SQL живёт в кавычках исходной команды — проверяем оригинал $CMD,
                # но только т.к. первое слово фрагмента уже подтверждено как psql.
                echo "$CMD" | grep -qiE '(INSERT|UPDATE|DELETE|TRUNCATE|DROP|ALTER)[[:space:]]' \
                    && block "$CMD (SQL write)"
                ;;
            bash|sh|zsh)
                # Whitelist read-only helpers (issue #264): явно перечисленные
                # read-only скрипты-перечислители разрешены под dry-run — их
                # payload инспектируем по коду скрипта (write-путей нет).
                # Список синхронизирован с memory/dry-run-contract.md §Bash matchers;
                # добавление = правка контракта + этого case + code review.
                # Абсолютный путь захардкожен по точной строке, не по glob
                # (review-01 High, review-02 H1): glob */.claude/... пропускал
                # /tmp-подделку, а ${IWE_ROOT:-...}/${IWE_WORKSPACE:-...} открывал
                # тот же обход через env-инъекцию (вызывающее окружение может
                # подставить произвольный env перед Bash-вызовом). Якорь —
                # $IWE_ROOT_GUESS (issue #694): путь самого хука через
                # BASH_SOURCE (строка ~27), нестандартный WORKSPACE_DIR
                # резолвится сам, инъекция через env невозможна.
                shift
                WL_ABS="$IWE_ROOT_GUESS/.claude/scripts/load-extensions.sh"
                # Реальный deployed путь — вложенный клон, не workspace-root
                # (scripts/ не копируется в $WORKSPACE_DIR, в отличие от .claude/;
                # см. IWE_SCRIPTS default в .claude/lib/iwe-env-bootstrap.sh:86).
                WL_ABS2="$IWE_ROOT_GUESS/FMT-exocortex-template/scripts/day-close-prepare.sh"
                # issue #549 stage 2: штатное завершение репетиции — переход
                # active→completed через helper (rm sentinel внутри него идёт
                # уже после completed, поэтому сам он безопасен под гейтом;
                # его внутренний `rm -f "$SENTINEL"` покрыт cleanup-исключением
                # ветки rm выше).
                WL_ABS3="$IWE_ROOT_GUESS/FMT-exocortex-template/scripts/dry-run-complete.sh"
                case "${1:-}" in
                    .claude/scripts/load-extensions.sh|"$WL_ABS") ;;
                    scripts/day-close-prepare.sh|"$WL_ABS2"|__WL_DAY_CLOSE_PREPARE__) ;;
                    scripts/dry-run-complete.sh|"$WL_ABS3"|__WL_DRY_RUN_COMPLETE__) ;;
                    *) block "$CMD (indirect execution under dry-run)" ;;
                esac
                ;;
            source|.)
                # issue #784/#785: сорсинг .iwe-paths (плоский KEY=VALUE
                # файл без побочных эффектов — межвызовое shell-состояние
                # не живёт между Bash-вызовами агента, поэтому его надо
                # сорсить в той же команде) блокировался безусловно.
                # Whitelist — по nonce-маркеру GATE_NONCE (см. NORM выше),
                # не по статическому тексту: cold-review (Codex) нашёл, что
                # статический маркер спуфится буквальным вводом атакующего
                # (`source __WL_СТАТИКА__` + одноимённый файл на диске =
                # обход гейта). eval/xargs намеренно НЕ включены сюда: общие
                # индирект-векторы без известного безопасного случая в контракте.
                # Live-review finding (Fable): HOME_OR_IWE_PATHS_TAMPERED
                # (вычислен до этого цикла) отзывает whitelist, если HOME/
                # IWE_PATHS_FILE переопределены где-то в этой же команде.
                if [ "$HOME_OR_IWE_PATHS_TAMPERED" = "1" ]; then
                    block "$CMD (HOME/IWE_PATHS_FILE reassigned earlier in the same command)"
                fi
                shift
                case "${1:-}" in
                    "__WL_IWE_PATHS_${GATE_NONCE}__")
                        shift
                        # round-2 cold-review (Codex): NORM вставляет пробелы
                        # вокруг маркера при замене — без этой проверки
                        # `. "$HOME/.iwe-paths"суффикс` (конкатенация без
                        # пробела в исходной команде) резолвился бы в W0=.
                        # $1=маркер $2=суффикс и прошёл бы как allow, хотя
                        # реально сорсит другой файл.
                        [ $# -gt 0 ] && block "$CMD (unexpected token after .iwe-paths whitelist marker)"
                        ;;
                    *) block "$CMD (indirect execution under dry-run)" ;;
                esac
                ;;
            eval|xargs)
                block "$CMD (indirect execution under dry-run)"
                ;;
            python|python3)
                # issue #460 path 5: real write path (extensions/day-close.before.garmin-verify.md
                # runs `python3 garmin-collect.py`, network + file writes) had no matcher branch
                # at all — passed through as read-only.
                shift
                case "${1:-}" in
                    # `-c "..."` inline snippets (e.g. day-close-details.md STRATEGY_DAY_NAME
                    # guard) — already outside this contract's threat model per
                    # memory/dry-run-contract.md §«Не входит в контракт» (a malicious
                    # `python -c 'open(...,"w")'` was always an accepted gap); exempting
                    # read-only inline snippets doesn't remove protection that existed.
                    -c) ;;
                    __WL_PY_MDS__|__WL_PY_CIH__) ;;
                    *) block "$CMD (indirect execution under dry-run)" ;;
                esac
                ;;
            uv|uvx)
                # issue #821: `uv run <script>` had no matcher branch at all — same
                # gap as python/python3 (#460 path 5). `uvx` is a distinct binary
                # (alias for `uv tool run`), same threat, needs its own case arm.
                shift
                case "${1:-}" in
                    --version|-V|--help|help) ;;
                    *) block "$CMD (indirect execution under dry-run)" ;;
                esac
                ;;
        esac
    done <<< "$SPLIT"
fi

# Read-only: allow
exit 0
