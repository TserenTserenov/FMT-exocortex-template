#!/usr/bin/env bash
# Regression for issue #974 (and its twin #983): the Day Open pipeline took the directory it
# runs from for the governance repository.
#
# strategist.sh runs `$IWE_SCRIPTS/day-open-pipeline.sh`. On the layout setup.sh builds that is
# the copy inside the template (<workspace>/FMT-exocortex-template/scripts/), while the
# governance repository (DS-strategy by default, any name allowed) is a sibling directory.
# The script derived DS_STRATEGY and IWE_GOVERNANCE_REPO from its own location, so Scaffold
# died with "WeekPlan not found in .../FMT-exocortex-template/current" and every morning fell
# through to the free-form day-plan prompt; the forced IWE_GOVERNANCE_REPO export also
# overwrote a correct value from the environment (the children saw the template's name).
#
# This runs the REAL pipeline from a copy of this working tree placed the way setup.sh places
# it, inside a disposable workspace, under `env -i` with a throwaway HOME and stubs for
# claude/gh/curl in front of PATH (no network). The copy is taken from the working tree on
# purpose (not `git archive HEAD`): the test must see uncommitted edits and must work from an
# extracted archive without .git. Every date is taken from the real clock (no date literals):
# the normal run of case H archives any DayPlan that is not today's, and the fixtures hold for
# any weekday, including the strategy day and the Sunday Week Close window.
#
# Cases (probe = `--probe --scaffold-only`: real preflight + scaffold, no commit, no Telegram):
#   A  non-standard governance name from the environment (a sibling DS-strategy must not exist,
#      otherwise the default would mask an incomplete fix)
#   B  standard name, nothing in the environment, no logs/ in the fresh governance repo; it
#      carries a stale seeded scripts/ copy that must NOT be executed
#   C  non-standard name but no environment: fail loudly with an actionable message, never
#      guess and never touch the template
#   D  control: the copy promoted INTO the governance repo keeps deriving the repository from
#      its physical location (also against a stale inherited environment)
#   E  a template copy outside any workspace layout and without environment: the workspace
#      root cannot be determined, the pipeline refuses (no guessing a root either)
#   F  a template copy without IWE_SCRIPTS in the environment finds the shared tools next to
#      itself (there is no <workspace>/scripts on this layout)
#   G  early refusals (C and E layouts, an invalid IWE_ROOT) notify like a late abort does,
#      stay silent without a token and under --probe; the hint names the source of the root
#   H  issue #983 as reported: nothing but IWE_SCRIPTS in the environment, no model gateway,
#      the strategist's two calls (the pipeline as is, then --scaffold-only), a governance repo
#      with history; everything the pipeline reads or writes belongs to the governance repo
#   I  a gateway that passes both probes but whose fill fails hard or leaves PENDING sections:
#      the real pipeline preserves the scaffold, returns failure, and cannot push a false plan
#   S  static guard on both copies of the pipeline: no executable path built from $DS_STRATEGY
set -uo pipefail

case "${1:-}" in
    -h|--help)
        echo "usage: bash $0   (no arguments; runs the real pipeline in throwaway workspaces)"
        exit 0
        ;;
esac

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
# Explicit template: macOS mktemp without one ignores TMPDIR.
TMP=$(mktemp -d "${TMPDIR:-/tmp}/iwe-issue-974.XXXXXX")
TMP=$(cd "$TMP" && pwd -P)
trap 'rm -rf "$TMP"' EXIT
# Nothing below may read or write the real home or the real temp dir, and the fixture
# repositories must not pick up a caller's repository (a git hook exports GIT_DIR and friends).
export HOME="$TMP/home"
export TMPDIR="$TMP/tmp"
export GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_PREFIX
mkdir -p "$HOME" "$TMPDIR"

for tool in jq git tar python3; do
    command -v "$tool" >/dev/null 2>&1 || { echo "SKIP: $tool is not installed"; exit 0; }
done
REAL_PYTHON3=$(command -v python3)

# Dates come from the real clock, never from literals. A normal (non-probe) run archives every
# DayPlan that is not today's (step 4.6), so case H must run on the real "today" with the real
# "yesterday" in the governance history; the other cases use the same date.
date_shift() { # <YYYY-MM-DD> <+N|-N days> -> YYYY-MM-DD (BSD date, then GNU date)
    date -j -v"${2}"d -f "%Y-%m-%d" "$1" "+%Y-%m-%d" 2>/dev/null || date -d "$1 ${2} days" "+%Y-%m-%d"
}
date_field() { # <YYYY-MM-DD> <strftime format> (BSD date, then GNU date)
    date -j -f "%Y-%m-%d" "$1" "$2" 2>/dev/null || date -d "$1" "$2"
}
weekday_name() { # <1-7, monday = 1> -> the lower-case English name day-rhythm-config.yaml uses
    case "$1" in
        1) echo monday ;; 2) echo tuesday ;; 3) echo wednesday ;; 4) echo thursday ;;
        5) echo friday ;; 6) echo saturday ;; *) echo sunday ;;
    esac
}
seconds_to_midnight() {
    echo $((86400 - 10#$(date +%H) * 3600 - 10#$(date +%M) * 60 - 10#$(date +%S)))
}
# The whole run has to stay inside one calendar day (see above): do not start just before midnight.
if [ "$(seconds_to_midnight)" -lt 240 ]; then
    sleep $(($(seconds_to_midnight) + 2))
fi
DATE=$(date +%Y-%m-%d)
YESTERDAY=$(date_shift "$DATE" -1)
DOW=$(date_field "$DATE" +%u)                                        # 1 = monday ... 7 = sunday
WEEK_NUM=$((10#$(date_field "$DATE" +%V)))
WEEK_MONDAY=$(date_shift "$DATE" "-$((DOW - 1))")

# Offline stubs; the Telegram variant answers like the Bot API and records what was sent.
STUBS="$TMP/stubs"
STUBS_TG="$TMP/stubs-tg"
mkdir -p "$STUBS" "$STUBS_TG"
for stub in claude gh curl; do
    printf '#!/bin/sh\necho "stub %s: no network in this test" >&2\nexit 1\n' "$stub" > "$STUBS/$stub"
    chmod +x "$STUBS/$stub"
done
cp "$STUBS/claude" "$STUBS/gh" "$STUBS_TG/"
cat > "$STUBS_TG/curl" <<'EOF'
#!/bin/sh
# Telegram stand-in: records the request (url and JSON body), answers like the Bot API.
out=""; body=""; url=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        -d) body="$2"; shift 2 ;;
        -w|-X|-H|-m) shift 2 ;;
        http*) url="$1"; shift ;;
        *) shift ;;
    esac
done
printf '%s\n' "$url" > "$CURL_LOG_DIR/call-$$.url"
printf '%s' "$body" > "$CURL_LOG_DIR/call-$$.json"
[ -n "$out" ] && printf '{"ok":true}' > "$out"
printf 200
EOF
cat > "$STUBS_TG/python3" <<'EOF'
#!/bin/sh
# network-wait.sh probes DNS through python3; that probe must not touch the network.
case "$*" in *getaddrinfo*) exit 0 ;; esac
exec "$REAL_PYTHON3" "$@"
EOF
chmod +x "$STUBS_TG/curl" "$STUBS_TG/python3"

fail=0
ok()  { echo "  PASS: $1"; }
bad() { echo "  FAIL: $1"; fail=$((fail + 1)); }
has() { grep -qF -- "$2" "$1" 2>/dev/null; }   # <file> <literal text>

# A copy of this working tree, placed as <workspace>/FMT-exocortex-template.
copy_template() { # <dest>
    mkdir -p "$1"
    tar -C "$ROOT" --exclude=.git -cf - . | tar -C "$1" -xf -
}

# The seed of a governance repository, with optional tar options (--exclude=...).
copy_seed() { # <dir> [tar options]
    local dir="$1"
    shift
    mkdir -p "$dir"
    tar -C "$ROOT/seed/strategy" "$@" -cf - . | tar -C "$dir" -xf -
}

# Workspace skeleton: the template copy, extensions/, params.yaml and a before-hook that records
# the identity the pipeline hands to its children.
build_skeleton() { # <workspace>
    local ws="$1"
    copy_template "$ws/FMT-exocortex-template"
    mkdir -p "$ws/extensions"
    printf 'calendar_source: none\n' > "$ws/params.yaml"
    cat > "$ws/extensions/day-open.before.md" <<EOF
\`\`\`bash
printf '%s|%s\n' "\${IWE_GOVERNANCE_REPO:-unset}" "\${IWE_ROOT:-unset}" > "$ws/child-identity.txt"
\`\`\`
EOF
}

# Governance repository the way a fresh install gets it: the seed (without its own scripts/
# unless asked), a git repo with core.hooksPath already wired, optionally the logs/ dir.
build_governance() { # <dir> <with-seed-scripts: yes|no> <with-logs: yes|no>
    local dir="$1"
    if [ "$2" = yes ]; then
        copy_seed "$dir"
    else
        copy_seed "$dir" --exclude=./scripts
    fi
    [ "$3" = yes ] && mkdir -p "$dir/logs"
    git -C "$dir" init -q 2>/dev/null
    git -C "$dir" config core.hooksPath .githooks
    git -C "$dir" -c user.name=fixture -c user.email=fixture@example.invalid \
        -c core.hooksPath=/dev/null commit -q --allow-empty -m "fixture: governance repo" 2>/dev/null
}

build_workspace() { # <workspace> <governance name> <with-seed-scripts: yes|no> <with-logs: yes|no>
    build_skeleton "$1"
    build_governance "$1/$2" "$3" "$4"
}

# Governance repository of a user who has been working for a while (issue #983): the plan of
# the week, the memory file, yesterday's DayPlan archived and committed yesterday, a local bare
# repository as origin. No .githooks on purpose: the seed's pre-commit validator rejects a
# DayPlan built without the model (no budget line, no multiplier), a separate matter from the
# layout under test. Weekday-proof for any real "today":
#  - strategy_day is set three days ahead, so neither today nor yesterday is a strategy day
#    (the Day Close guard of step 1.1 then looks for yesterday's archived DayPlan);
#  - on a Sunday the Week Close guard (step 1.1b, after 23:00 Cyprus time) finds the WeekReport.
build_working_governance() { # <dir> <bare remote dir>
    local dir="$1" remote="$2" week_plan="WeekPlan W${WEEK_NUM} ${WEEK_MONDAY}.md"
    local -a committed
    copy_seed "$dir" --exclude=./scripts --exclude=./.githooks
    mkdir -p "$dir/logs" "$dir/archive/day-plans" "$dir/exocortex"
    rm -f "$dir/current/WeekPlan W1.md"
    printf '# WeekPlan W%s\n' "$WEEK_NUM" > "$dir/current/$week_plan"
    printf 'active\n' > "$dir/current/active-wp.md"
    printf '# DayPlan %s\n' "$YESTERDAY" > "$dir/archive/day-plans/DayPlan $YESTERDAY.md"
    printf 'day_open:\n  strategy_day: %s\n' "$(weekday_name $(((DOW + 2) % 7 + 1)))" \
        > "$dir/exocortex/day-rhythm-config.yaml"
    committed=("archive/day-plans/DayPlan $YESTERDAY.md" current/active-wp.md "current/$week_plan")
    if [ "$DOW" -eq 7 ]; then
        printf '# WeekReport W%s\n' "$WEEK_NUM" > "$dir/current/WeekReport W${WEEK_NUM} ${WEEK_MONDAY}.md"
        committed+=("current/WeekReport W${WEEK_NUM} ${WEEK_MONDAY}.md")
    fi
    git init -q --bare "$remote" 2>/dev/null
    git -C "$dir" init -q 2>/dev/null
    git -C "$dir" symbolic-ref HEAD refs/heads/main
    git -C "$dir" remote add origin "$remote"
    git -C "$dir" config user.name fixture
    git -C "$dir" config user.email fixture@example.invalid
    git -C "$dir" add -- "${committed[@]}"
    GIT_AUTHOR_DATE="${YESTERDAY}T12:00:00" GIT_COMMITTER_DATE="${YESTERDAY}T12:00:00" \
        git -C "$dir" commit -q -m "fixture: yesterday closed" 2>/dev/null
    git -C "$dir" push -q -u origin main 2>/dev/null
}

# run_pipeline <probe|scaffold|plain> <workspace> <pipeline script> <output file> [VAR=value ...]
#   probe     --probe --scaffold-only: nothing is committed, Telegram is suppressed
#   scaffold  --scaffold-only, a normal run
#   plain     no flags, a normal run
# Mirrors what the strategist job provides: IWE_SCRIPTS pointing into the template. Later
# VAR=value pairs override the defaults (an empty IWE_SCRIPTS= counts as unset for the script).
# DAY_OPEN_FORCE_STRATEGY_DAY=1: whatever the weekday, the scaffold builds the plan (it skips a
# strategy day, monday by default, which is not what any case here is about).
run_pipeline() {
    local mode="$1" ws="$2" script="$3" out="$4"
    local -a args
    shift 4
    case "$mode" in
        probe)    args=(--probe --scaffold-only --date "$DATE") ;;
        scaffold) args=(--scaffold-only --date "$DATE") ;;
        *)        args=(--date "$DATE") ;;
    esac
    env -i HOME="$HOME" PATH="$STUBS:$PATH" TMPDIR="$TMPDIR" PYTHONDONTWRITEBYTECODE=1 \
        DAY_OPEN_LOCK_FILE="$ws/day-open.lock" DAY_OPEN_FORCE_STRATEGY_DAY=1 \
        IWE_SCRIPTS="$ws/FMT-exocortex-template/scripts" \
        "$@" "$BASH" "$script" "${args[@]}" > "$out" 2>&1
}

# Same, with a Telegram token and a curl that records what would be sent into <record dir>.
run_notifying() { # <mode> <workspace> <script> <output> <record dir> [VAR=value ...]
    local mode="$1" ws="$2" script="$3" out="$4" record="$5"
    shift 5
    mkdir -p "$record"
    run_pipeline "$mode" "$ws" "$script" "$out" PATH="$STUBS_TG:$PATH" REAL_PYTHON3="$REAL_PYTHON3" \
        CURL_LOG_DIR="$record" TELEGRAM_BOT_TOKEN=fake-token-974 TELEGRAM_CHAT_ID=974 "$@"
}

snapshot_tree() { # <dir> <out>
    find "$1" | LC_ALL=C sort > "$2"
}

# Assertions shared by the probe cases where the pipeline must reach Scaffold.
expect_scaffold_in_governance() { # <label> <workspace> <governance> <output> <rc>
    local label="$1" ws="$2" gov="$3" out="$4" rc="$5"
    if has "$out" "=== 3. Scaffold ===" && ! has "$out" "WeekPlan not found"; then
        ok "$label: Scaffold проходит, «WeekPlan not found» нет"
    else
        bad "$label: Scaffold не пройден (rc=$rc): $(grep -F 'WeekPlan not found' "$out" | head -1)"
    fi
    if has "$out" "Scaffold OK: $ws/$gov/current/DayPlan $DATE (probe).md"; then
        ok "$label: скелет DayPlan собран в governance-репозитории $gov"
    else
        bad "$label: нет строки «Scaffold OK» с путём в $ws/$gov/current (см. вывод: $(grep -F '=== 3. Scaffold' -A1 "$out" | tail -1))"
    fi
    if [ "$(cat "$ws/child-identity.txt" 2>/dev/null)" = "$gov|$ws" ]; then
        ok "$label: дочерние процессы получили IWE_GOVERNANCE_REPO=$gov и IWE_ROOT=$ws"
    else
        bad "$label: дочерние процессы получили «$(cat "$ws/child-identity.txt" 2>/dev/null)», ожидалось «${gov}|${ws}»"
    fi
    if has "$out" "install-hooks.sh failed"; then
        bad "$label: шаг 1.2 пытался чинить хуки не в том репозитории"
    else
        ok "$label: шаг 1.2 не трогает чужой репозиторий"
    fi
    # The strategist treats any non-zero exit as a failed Day Open (no plan, an alarm), so the
    # whole probe run (every later step is started from the directory the copy runs from) must end green.
    if [ "$rc" -eq 0 ] && has "$out" "verdict=🟢 green"; then
        ok "$label: прогон дошёл до конца, код возврата 0, вердикт green"
    else
        bad "$label: прогон не завершился успешно (rc=$rc): $(grep -F 'PROBE SUMMARY' -A1 "$out" | tail -1)"
    fi
}

expect_template_untouched() { # <label> <workspace> <before snapshot>
    local label="$1" ws="$2" before="$3"
    snapshot_tree "$ws/FMT-exocortex-template" "$before.after"
    if cmp -s "$before" "$before.after"; then
        ok "$label: в каталоге шаблона ничего не создано и не удалено"
    else
        bad "$label: каталог шаблона изменился: $(diff "$before" "$before.after" | head -3 | tr '\n' ' ')"
    fi
}

# What the curl stand-in recorded: how many messages, and their decoded text.
tg_calls() { # <record dir>
    local n=0 f
    for f in "$1"/*.url; do [ -f "$f" ] && n=$((n + 1)); done
    echo "$n"
}
tg_text() { # <record dir>
    local f
    for f in "$1"/*.json; do
        [ -f "$f" ] && PYTHONIOENCODING=utf-8 python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["text"])' "$f"
    done
}

# The pipeline refused (rc != 0, reason printed) and told Telegram the same reason.
expect_refusal_notified() { # <label> <output> <rc> <record dir> <reason fragment>
    local label="$1" out="$2" rc="$3" record="$4" fragment="$5" text
    text=$(tg_text "$record")
    if [ "$rc" -ne 0 ] && has "$out" "$fragment"; then
        ok "$label: отказ с понятным текстом (rc=$rc)"
    else
        bad "$label: нет понятного отказа (rc=$rc): $(head -3 "$out" | tr '\n' ' ')"
    fi
    case "$text" in
        *"Day Open pipeline aborted"*"$fragment"*)
            if [ "$(tg_calls "$record")" -eq 1 ] \
               && [ "$(cat "$record"/*.url)" = "https://api.telegram.org/botfake-token-974/sendMessage" ]; then
                ok "$label: одно сообщение в Telegram, тот же формат, что у позднего отказа"
            else
                bad "$label: сообщений в Telegram: $(tg_calls "$record"), адрес «$(cat "$record"/*.url)»"
            fi
            ;;
        *) bad "$label: в Telegram не ушло сообщение с причиной «${fragment}» (ушло: «${text}»)" ;;
    esac
}

# ---------------------------------------------------------------- case A
echo "== A: governance с нестандартным именем, имя задано окружением"
A="$TMP/a"; GOV_A=DS-custom-gov
build_workspace "$A/ws" "$GOV_A" no yes
snapshot_tree "$A/ws/FMT-exocortex-template" "$A/before.txt"
run_pipeline probe "$A/ws" "$A/ws/FMT-exocortex-template/scripts/day-open-pipeline.sh" "$A/out.txt" \
    IWE_GOVERNANCE_REPO="$GOV_A"
rc=$?
expect_scaffold_in_governance "A" "$A/ws" "$GOV_A" "$A/out.txt" "$rc"
expect_template_untouched "A" "$A/ws" "$A/before.txt"
if [ -e "$A/ws/DS-strategy" ]; then
    bad "A: появился каталог DS-strategy — конвейер откатился на имя по умолчанию"
else
    ok "A: имя по умолчанию DS-strategy не подставлялось"
fi

# ---------------------------------------------------------------- case B
echo "== B: стандартное имя DS-strategy, окружение пустое, logs/ в свежем governance нет; устаревшая копия scripts/"
B="$TMP/b"
build_workspace "$B/ws" DS-strategy no no
mkdir -p "$B/ws/DS-strategy/scripts"
cat > "$B/ws/DS-strategy/scripts/day-open-hooks-runner.sh" <<EOF
#!/bin/sh
echo executed > "$B/stale-runner-was-executed"
exit 1
EOF
chmod +x "$B/ws/DS-strategy/scripts/day-open-hooks-runner.sh"
snapshot_tree "$B/ws/FMT-exocortex-template" "$B/before.txt"
run_pipeline probe "$B/ws" "$B/ws/FMT-exocortex-template/scripts/day-open-pipeline.sh" "$B/out.txt"
rc=$?
expect_scaffold_in_governance "B" "$B/ws" DS-strategy "$B/out.txt" "$rc"
expect_template_untouched "B" "$B/ws" "$B/before.txt"
if [ -e "$B/stale-runner-was-executed" ]; then
    bad "B: выполнена копия скрипта из governance-репозитория, а не из шаблона"
else
    ok "B: исполняемые файлы берутся рядом с конвейером (из шаблона), не из governance"
fi

# ---------------------------------------------------------------- case C
echo "== C: нестандартное имя, окружения нет — громкий отказ без догадок"
C="$TMP/c"
build_workspace "$C/ws" DS-custom-gov no yes
snapshot_tree "$C/ws/FMT-exocortex-template" "$C/before.txt"
run_pipeline probe "$C/ws" "$C/ws/FMT-exocortex-template/scripts/day-open-pipeline.sh" "$C/out.txt"
rc=$?
if [ "$rc" -ne 0 ] && has "$C/out.txt" "Governance-репозиторий не найден: $C/ws/DS-strategy" \
   && has "$C/out.txt" "IWE_GOVERNANCE_REPO"; then
    ok "C: отказ с понятным текстом и подсказкой про IWE_GOVERNANCE_REPO (rc=$rc)"
else
    bad "C: нет понятного отказа (rc=$rc): $(head -3 "$C/out.txt" | tr '\n' ' ')"
fi
if has "$C/out.txt" "=== 3. Scaffold ==="; then
    bad "C: конвейер дошёл до Scaffold, хотя governance-репозиторий не определён"
else
    ok "C: до Scaffold дело не дошло"
fi
expect_template_untouched "C" "$C/ws" "$C/before.txt"

# ---------------------------------------------------------------- case D
echo "== D: контроль — копия, промотированная в governance-репозиторий, при устаревшем окружении"
D="$TMP/d"; GOV_D=DS-promoted-gov
build_workspace "$D/ws" "$GOV_D" yes yes
run_pipeline probe "$D/ws" "$D/ws/$GOV_D/scripts/day-open-pipeline.sh" "$D/out.txt" \
    IWE_ROOT="$D/stale-workspace" IWE_GOVERNANCE_REPO=stale-governance
rc=$?
expect_scaffold_in_governance "D" "$D/ws" "$GOV_D" "$D/out.txt" "$rc"

# ---------------------------------------------------------------- case E
echo "== E: копия шаблона вне раскладки рабочего пространства, окружения нет — корень не определить"
E="$TMP/e"
copy_template "$E/loose-template"
run_pipeline probe "$E" "$E/loose-template/scripts/day-open-pipeline.sh" "$E/out.txt" \
    IWE_SCRIPTS="$E/loose-template/scripts"
rc=$?
if [ "$rc" -ne 0 ] && has "$E/out.txt" "cannot determine workspace root"; then
    ok "E: отказ с названием причины (rc=$rc)"
else
    bad "E: нет отказа про корень рабочего пространства (rc=$rc): $(head -3 "$E/out.txt" | tr '\n' ' ')"
fi
if has "$E/out.txt" "=== 1.5."; then
    bad "E: конвейер продолжил работу без корня рабочего пространства"
else
    ok "E: ни один шаг конвейера не запускался"
fi

# ---------------------------------------------------------------- case F
echo "== F: копия шаблона без IWE_SCRIPTS в окружении — общие скрипты берутся рядом с ней"
F="$TMP/f"
build_workspace "$F/ws" DS-strategy no yes
run_pipeline probe "$F/ws" "$F/ws/FMT-exocortex-template/scripts/day-open-pipeline.sh" "$F/out.txt" \
    IWE_SCRIPTS=
rc=$?
expect_scaffold_in_governance "F" "$F/ws" DS-strategy "$F/out.txt" "$rc"
if has "$F/out.txt" "Triage preflight failed"; then
    bad "F: preflight не нашёлся (каталога <рабочее пространство>/scripts на этой раскладке нет)"
else
    ok "F: preflight найден"
fi

# ---------------------------------------------------------------- case G
echo "== G: ранние отказы уведомляют так же, как поздний отказ"
G="$TMP/g"
# G1: the governance directory does not exist (layout C, no environment)
run_notifying scaffold "$C/ws" "$C/ws/FMT-exocortex-template/scripts/day-open-pipeline.sh" "$G/g1.txt" "$G/tg1"
rc=$?
expect_refusal_notified "G1 (нет governance-репозитория)" "$G/g1.txt" "$rc" "$G/tg1" \
    "Governance-репозиторий не найден: $C/ws/DS-strategy"
if has "$G/g1.txt" "взят из: расположение скрипта"; then
    ok "G1: подсказка называет источник корня — расположение скрипта"
else
    bad "G1: подсказка не называет источник корня: $(head -2 "$G/g1.txt" | tr '\n' ' ')"
fi
# G2: an invalid IWE_ROOT inherited from the environment
run_notifying scaffold "$C/ws" "$C/ws/FMT-exocortex-template/scripts/day-open-pipeline.sh" "$G/g2.txt" "$G/tg2" \
    IWE_ROOT="$G/no-such-workspace"
rc=$?
expect_refusal_notified "G2 (устаревший IWE_ROOT)" "$G/g2.txt" "$rc" "$G/tg2" \
    "Governance-репозиторий не найден: $G/no-such-workspace/DS-strategy"
if has "$G/g2.txt" "взят из: IWE_ROOT"; then
    ok "G2: подсказка называет источник корня — IWE_ROOT"
else
    bad "G2: подсказка не называет IWE_ROOT: $(head -2 "$G/g2.txt" | tr '\n' ' ')"
fi
# G3: the workspace root cannot be determined (layout E)
run_notifying scaffold "$E" "$E/loose-template/scripts/day-open-pipeline.sh" "$G/g3.txt" "$G/tg3" \
    IWE_SCRIPTS="$E/loose-template/scripts"
rc=$?
expect_refusal_notified "G3 (корень не определить)" "$G/g3.txt" "$rc" "$G/tg3" "cannot determine workspace root"
# G4: no token — same refusal and exit code, nothing is sent, nothing breaks
run_notifying scaffold "$C/ws" "$C/ws/FMT-exocortex-template/scripts/day-open-pipeline.sh" "$G/g4.txt" "$G/tg4" \
    TELEGRAM_BOT_TOKEN= TELEGRAM_CHAT_ID=
rc=$?
if [ "$rc" -eq 1 ] && has "$G/g4.txt" "Governance-репозиторий не найден" && has "$G/g4.txt" "[no tg credentials]" \
   && [ "$(tg_calls "$G/tg4")" -eq 0 ]; then
    ok "G4: без токена отказ прежний (rc=1), в Telegram ничего не отправлено"
else
    bad "G4: без токена поведение изменилось (rc=$rc, сообщений: $(tg_calls "$G/tg4")): $(head -4 "$G/g4.txt" | tr '\n' ' ')"
fi
# G5: --probe suppresses Telegram, as everywhere else in the pipeline
run_notifying probe "$C/ws" "$C/ws/FMT-exocortex-template/scripts/day-open-pipeline.sh" "$G/g5.txt" "$G/tg5"
rc=$?
if [ "$rc" -eq 1 ] && has "$G/g5.txt" "[probe: TG suppressed]" && [ "$(tg_calls "$G/tg5")" -eq 0 ]; then
    ok "G5: под --probe уведомление подавлено, как и у позднего отказа"
else
    bad "G5: под --probe (rc=$rc, сообщений: $(tg_calls "$G/tg5")): $(head -4 "$G/g5.txt" | tr '\n' ' ')"
fi

# ---------------------------------------------------------------- case H
echo "== H: #983 — ночной strategist.sh morning: IWE_SCRIPTS=<шаблон>/scripts, шлюза нет, DS-strategy с историей"
H="$TMP/h"; SCRIPT_H="$H/ws/FMT-exocortex-template/scripts/day-open-pipeline.sh"
build_skeleton "$H/ws"
build_working_governance "$H/ws/DS-strategy" "$H/remote.git"
snapshot_tree "$H/ws/FMT-exocortex-template" "$H/before.txt"
run_pipeline plain "$H/ws" "$SCRIPT_H" "$H/call1.txt"
rc1=$?
run_pipeline scaffold "$H/ws" "$SCRIPT_H" "$H/call2.txt"
rc2=$?
if [ "$rc1" -eq 9 ] && has "$H/call1.txt" "LLM gateway is not configured"; then
    ok "H: первый вызов отказывает «шлюз не задан» с кодом 9 — по нему strategist.sh повторяет с --scaffold-only"
else
    bad "H: первый вызов: rc=$rc1, ожидалось 9 и «LLM gateway is not configured»: $(tail -2 "$H/call1.txt" | tr '\n' ' ')"
fi
if has "$H/call2.txt" "Scaffold OK: $H/ws/DS-strategy/current/DayPlan $DATE.md" && ! has "$H/call2.txt" "WeekPlan not found"; then
    ok "H: повтор с --scaffold-only проходит Scaffold, план дня создан в DS-strategy"
else
    bad "H: повтор не прошёл Scaffold (rc=$rc2): $(grep -F 'WeekPlan not found' "$H/call2.txt" | head -1)"
fi
if [ "$rc2" -eq 0 ] && [ -f "$H/ws/DS-strategy/current/DayPlan $DATE.md" ]; then
    ok "H: повтор завершился успешно (rc=0), файл плана лежит в DS-strategy"
else
    bad "H: повтор: rc=$rc2, файл плана в DS-strategy: $([ -f "$H/ws/DS-strategy/current/DayPlan $DATE.md" ] && echo есть || echo нет)"
fi
if [ "$(git -C "$H/remote.git" log -1 --format=%s main 2>/dev/null)" = "feat(dayplan): $DATE — auto Day Open (WP-356) [allow:current]" ]; then
    ok "H: коммит с планом дня отправлен в origin governance-репозитория"
else
    bad "H: в origin нет коммита с планом дня: $(git -C "$H/remote.git" log -1 --format=%s main 2>&1 | head -1)"
fi
# "missing" is the symptom (the file is looked up in the template); ok and stale both prove it
# was found in the governance repository (stale = older than a week by the clock the run sees).
if has "$H/call2.txt" "memory=ok" || has "$H/call2.txt" "memory=stale"; then
    ok "H: preflight находит память (current/active-wp.md) в DS-strategy, а не memory=missing"
else
    bad "H: preflight не находит память в DS-strategy: $(grep -F 'calendar=' "$H/call2.txt" | head -1)"
fi
if has "$H/call2.txt" "Day Close for $YESTERDAY found (archived DayPlan present)" \
   && ! has "$H/call2.txt" "No commits for $YESTERDAY"; then
    ok "H: поиск вчерашних коммитов идёт в DS-strategy (закрытие дня найдено), не «тихий день»"
else
    bad "H: вчерашние коммиты не найдены в DS-strategy: $(grep -F "$YESTERDAY" "$H/call2.txt" | head -1)"
fi
if [ -f "$H/ws/DS-strategy/logs/personal-guide-update.log" ] \
   && ! has "$H/call2.txt" "personal-guide-update.log: No such file"; then
    ok "H: журнал personal-guide-update.log появился в DS-strategy/logs, без ошибки записи"
else
    bad "H: журнал personal-guide-update.log не в DS-strategy/logs: $(grep -F 'personal-guide-update.log' "$H/call2.txt" | head -1)"
fi
expect_template_untouched "H" "$H/ws" "$H/before.txt"

# ---------------------------------------------------------------- case I
echo "== I: ошибка LLM Fill не превращается в успешное Открытие дня"
STUBS_LLM="$TMP/stubs-llm"
mkdir -p "$STUBS_LLM"
cat > "$STUBS_LLM/curl" <<'EOF'
#!/bin/sh
# The pipeline checks health and authorization before starting the real fill stage.
case " $* " in
    *'/v1/health'*) printf '{"status":"ok"}\n' ;;
    *'/v1/messages'*) printf 200 ;;
    *) echo "unexpected curl call: $*" >&2; exit 1 ;;
esac
EOF
chmod +x "$STUBS_LLM/curl"
for fill_rc in 1 2; do
    I="$TMP/i-$fill_rc"
    build_skeleton "$I/ws"
    build_working_governance "$I/ws/DS-strategy" "$I/remote.git"
    # Fake only the model fill boundary; every other stage is the delivered pipeline.
    cat > "$I/ws/FMT-exocortex-template/scripts/day-open-llm-fill.py" <<'EOF'
import os
import sys

print("[WARN] fake LLM left PENDING" if os.environ["FAKE_LLM_FILL_RC"] == "2"
      else "[ERROR] fake LLM failed", file=sys.stderr)
sys.exit(int(os.environ["FAKE_LLM_FILL_RC"]))
EOF
    run_pipeline plain "$I/ws" "$I/ws/FMT-exocortex-template/scripts/day-open-pipeline.sh" "$I/out.txt" \
        PATH="$STUBS_LLM:$STUBS:$PATH" LLM_PROXY_URL=https://fake.invalid \
        FAKE_LLM_FILL_RC="$fill_rc"
    rc=$?
    plan="$I/ws/DS-strategy/current/DayPlan $DATE.md"
    if [ "$rc" -eq 1 ] && has "$I/out.txt" "=== 4. LLM Fill ===" \
       && has "$I/ws/DS-strategy/machine/logs/day-open-$DATE.log" "exit=$fill_rc"; then
        ok "I/$fill_rc: ошибка заполнения дошла через реальный конвейер до кода 1"
    else
        bad "I/$fill_rc: ожидали ошибку заполнения и код 1, получили rc=$rc: $(tail -4 "$I/out.txt" | tr '\n' ' ')"
    fi
    if [ -f "$plan" ] && has "$plan" "PENDING"; then
        ok "I/$fill_rc: незавершённый скелет сохранён для повтора"
    else
        bad "I/$fill_rc: скелет с PENDING не сохранён"
    fi
    if [ "$(git -C "$I/remote.git" rev-parse main 2>/dev/null)" = \
         "$(git -C "$I/ws/DS-strategy" rev-parse HEAD 2>/dev/null)" ] \
       && ! git -C "$I/ws/DS-strategy" ls-files --error-unmatch "current/DayPlan $DATE.md" >/dev/null 2>&1; then
        ok "I/$fill_rc: незавершённый план не закоммичен и не отправлен"
    else
        bad "I/$fill_rc: незавершённый план попал в историю"
    fi
done
# The actual morning runner must see the pipeline failure, alarm/retry it, and never
# write its success marker. Use the partial branch because it used to continue to
# weak default checks and could publish a plan with PENDING content.
I="$TMP/i-2"
cat > "$STUBS_LLM/caffeinate" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$STUBS_LLM/systemd-inhibit" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$STUBS_LLM/caffeinate" "$STUBS_LLM/systemd-inhibit"
env -i HOME="$HOME" PATH="$STUBS_LLM:$STUBS:$PATH" TMPDIR="$TMPDIR" PYTHONDONTWRITEBYTECODE=1 \
    IWE_WORKSPACE="$I/ws" IWE_GOVERNANCE_REPO=DS-strategy \
    IWE_TEMPLATE="$I/ws/FMT-exocortex-template" \
    IWE_SCRIPTS="$I/ws/FMT-exocortex-template/scripts" \
    DAY_OPEN_LOCK_FILE="$I/ws/day-open.lock" DAY_OPEN_FORCE_STRATEGY_DAY=1 \
    LLM_PROXY_URL=https://fake.invalid FAKE_LLM_FILL_RC=2 \
    "$BASH" "$I/ws/FMT-exocortex-template/roles/strategist/scripts/strategist.sh" morning \
    > "$I/strategist.txt" 2>&1
rc=$?
if [ "$rc" -eq 1 ] && has "$I/strategist.txt" "FAILED scenario: day-plan (rc=1)" \
   && ! has "$I/strategist.txt" "Morning: Day Open pipeline OK"; then
    ok "I/2: утренний сценарий получает ошибку и не ставит ложную отметку готовности"
else
    bad "I/2: утренний сценарий скрывает ошибку или ставит отметку готовности (rc=$rc): $(tail -5 "$I/strategist.txt" | tr '\n' ' ')"
fi

# ---------------------------------------------------------------- guard S
echo "== S: ни одной ссылки \$DS_STRATEGY/scripts/ в исполняемых строках обеих копий конвейера"
for pipeline in "$ROOT/scripts/day-open-pipeline.sh" "$ROOT/seed/strategy/scripts/day-open-pipeline.sh"; do
    # The cases above notice a wrong executable path only where its failure is loud; many call
    # sites sit behind `|| true` or run in the background, so the spelling itself is checked:
    # $DS_STRATEGY/scripts/, ${DS_STRATEGY}/scripts/ and "$DS_STRATEGY"/scripts/.
    # shellcheck disable=SC2016  # regex literal: $ must stay literal
    refs=$(grep -E '\$\{?DS_STRATEGY\}?"?/scripts/' "$pipeline" | grep -vc '^[[:space:]]*#' || true)
    if [ "$refs" = 0 ]; then
        ok "S: ${pipeline#"$ROOT"/} — ссылок на \$DS_STRATEGY/scripts/ нет"
    else
        bad "S: ${pipeline#"$ROOT"/} — исполняемых ссылок на \$DS_STRATEGY/scripts/: ${refs:-?} (должны идти от \$SCRIPT_HOME)"
    fi
done

echo
if [ "$fail" -eq 0 ]; then
    echo "PASS: issue #974 — конвейер находит governance-репозиторий по окружению, а не по расположению"
else
    echo "FAIL: issue #974 — провалено проверок: $fail"
    exit 1
fi
