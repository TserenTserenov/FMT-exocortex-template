#!/usr/bin/env bash
# test_issue_961_note_review_pilot_only.sh - regression for issue #961: Note-Review against the template
# owner's decision of July 2026. Note-Review only classifies and PROPOSES: it never strips bold, never
# archives or deletes a note on its own, and the scheduler never starts it. A processed note is marked
# "**Title** ✅предложено", stays bold and visible until the pilot closes it (a command, or by
# striking it through).
#
# Layers (no network, no real HOME; every runner and notifier is a double):
#   A. text contract: roles/strategist/prompts/note-review.md, day-plan.md, the seed box legend,
#      and the cleanup script's safety net (a proposed note is never swept up);
#   B. roles/synchronizer/scripts/scheduler.sh: the REAL dispatch, run in a sandbox with a fake clock, a fake
#      platform name (Darwin and Linux, the two sleep-inhibitor branches) and recording stub runners, never
#      starts note-review (neither the evening run nor the catch-up) and ends with exit code 0 on both platforms;
#   C. Day Open scanner: the REAL render_fleeting_notes of scripts/ and of the seed snapshot lists a
#      "✅предложено" note as awaiting the pilot;
#   D. the Telegram text of a finished Note-Review no longer claims the inbox was cleaned;
#   E. daily-report.sh no longer reports a missing note-review marker as a failure;
#   G. the Day Open instructions, the user guides and the other prompts no longer describe the old flow
#      (a nightly review, a note that leaves the box after Note-Review) and do not attribute the decision
#      to a pilot on a date;
#   F. the canary function of strategist.sh on its own, H. one table of note titles on which the safety net,
#      the canary and the Day Open scanner must give the same answer.
# The canary of strategist.sh is covered end to end in setup/test-strategist-isolated-scenarios.sh (B10).

# SC2016: the single-quoted strings are literal prompt fragments (with backticks) and stub-script bodies
# that must stay unexpanded.
# shellcheck disable=SC2016
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROMPT="$ROOT/roles/strategist/prompts/note-review.md"
DAYPLAN_PROMPT="$ROOT/roles/strategist/prompts/day-plan.md"
SEED_LEGEND="$ROOT/seed/strategy/inbox/fleeting-notes.md"
CLEANUP_PY="$ROOT/roles/strategist/scripts/cleanup-processed-notes.py"

SB="$(cd -P "$(mktemp -d "${TMPDIR:-/tmp}/iwe-issue-961.XXXXXX")" && pwd -P)"
trap '[ "${KEEP:-0}" = "1" ] || rm -rf "$SB"' EXIT INT TERM
mkdir -p "$SB/tmp" "$SB/shim"

FAIL_COUNT=0
PASS_COUNT=0
fail() { echo "  ❌ FAIL: $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }
pass() { echo "  ✅ PASS: $*"; PASS_COUNT=$((PASS_COUNT + 1)); }
check() {  # <description> <expected> <actual>
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}
check_at_least() {  # <description> <minimum> <actual>
    if [ "$3" -ge "$2" ] 2>/dev/null; then pass "$1"; else fail "$1 (expected at least $2, got '$3')"; fi
}
count_fixed() {  # <fixed string> <file> -> number of matching lines, 0 for a missing file
    if [ -f "$2" ]; then grep -cF -- "$1" "$2" || true; else echo 0; fi
}

# ==== LAYER A: text contract ====
echo "== A1: the prompt marks processed notes instead of stripping bold =="
for category in "НЭП" "Задача" "Гипотеза" "Знание доменное" "Знание реализационное" "Черновик" "Личные данные"; do
    check "step 4: $category becomes '**Заголовок** ✅предложено'" "1" \
        "$(count_fixed "| $category | \`**Заголовок**\` | \`**Заголовок** ✅предложено\` |" "$PROMPT")"
done
check "step 4: noise becomes '**Заголовок** ✅предложено (шум)', it is not struck through by the agent" "1" \
    "$(count_fixed '| Шум | `**Заголовок**` | `**Заголовок** ✅предложено (шум)` |' "$PROMPT")"
check "no instruction to strip bold remains" "0" "$(count_fixed '(снять bold)' "$PROMPT")"
check "no instruction to strike noise through automatically remains" "0" "$(count_fixed '→ зачеркнуть ~~текст~~' "$PROMPT")"
check "the legend describes the proposed state" "1" "$(count_fixed '| `**Заголовок** ✅предложено` | Классифицирована, предложение записано — ждёт решения пилота |' "$PROMPT")"
check "new notes exclude the already proposed ones" "1" "$(count_fixed '- Заметки с `✅предложено` — уже обработаны, не переклассифицировать, оставить как есть' "$PROMPT")"

echo "== A2: the prompt no longer archives or deletes on its own =="
check "the old mandatory 'archive processed notes' step is gone" "0" "$(count_fixed '#### 10. Архивировать обработанные заметки' "$PROMPT")"
check "the old 'delete from fleeting-notes.md' step is gone" "0" "$(count_fixed 'Шаг 10b. Удалить из fleeting-notes.md' "$PROMPT")"
check "the old 'Step 10 is mandatory' block is gone" "0" "$(count_fixed 'Шаг 10 ОБЯЗАТЕЛЕН' "$PROMPT")"
check "step 10 never edits the box beyond the proposed mark and the notes the pilot struck through" "1" "$(count_fixed '`fleeting-notes.md` НЕ редактируется этим шагом, кроме простановки `✅предложено` в шаге 4 выше и удаления заметок, которые пилот сам зачеркнул' "$PROMPT")"
check "the 'do not touch the box' rule names the same exception" "1" "$(count_fixed 'кроме пометок шага 4 и удаления заметок, которые пилот сам зачеркнул' "$PROMPT")"
check_at_least "every archive record format carries the pilot decision (step 10 and the manual cleanup)" 2 "$(count_fixed '**Разбор:** YYYY-MM-DD — **Решение пилота:**' "$PROMPT")"
check "principle: a note leaves the box only with the pilot decision recorded" "1" "$(count_fixed '**Каждый разбор — запись решения:**' "$PROMPT")"
check "manual cleanup is the main way to remove a note, with step 10 and the safety net named as the exceptions" "1" "$(count_fixed 'Это основной путь физического удаления из `fleeting-notes.md` (кроме шага 10' "$PROMPT")"
check "no claim of an 'only way' to remove a note is left (step 10 and the safety net remove too)" "0" "$(count_fixed 'единственный путь физического удаления' "$PROMPT")"
check "the legend names the safety net as the only writer of a plain note's archive record" "1" "$(count_fixed 'только скриптом-страховкой, запись «auto-cleanup»' "$PROMPT")"

echo "== A3: pilot-only contract: no automatic and no headless run =="
check "the precondition says automatic runs are off" "1" "$(count_fixed 'Автоматические запуски отключены' "$PROMPT")"
check "the old 'runs every evening automatically' sentence is gone" "0" "$(count_fixed 'Процесс запускается вечером (~23:00) автоматически' "$PROMPT")"
check "a run from strategist.sh (no chat) only marks and proposes: the precondition says so" "1" "$(count_fixed 'идёт без чата и только ставит пометки `✅предложено` и пишет предложения (шаги 1-9 и 11)' "$PROMPT")"
check "a run without a chat archives and deletes nothing: step 9 says so" "1" "$(count_fixed 'ничего не архивирует и не удаляет' "$PROMPT")"
check "step 10 is skipped when there is no chat: the prompt names the mode line the runner adds" "1" "$(count_fixed 'раннер добавляет в начало промпта строку «РЕЖИМ: запуск из скрипта без чата' "$PROMPT")"
check "the old blanket ban that contradicted the terminal run is gone" "0" "$(count_fixed 'без живого пилота сценарий не выполняется вовсе' "$PROMPT")"
check "the old 'headless: do not wait for approval' block is gone" "0" "$(count_fixed '**Headless-режим:** НЕ ждать одобрения' "$PROMPT")"
check "the scenario is no longer called 'daily'" "0" "$(count_fixed 'Ежедневный разбор заметок' "$PROMPT")"

echo "== A4: the box legend and the Day Plan prompt follow the decision =="
check "seed legend: the proposed mark is described" "1" "$([ "$(count_fixed '✅предложено' "$SEED_LEGEND")" -ge 1 ] && echo 1 || echo 0)"
check "seed legend: no 'reviewed every day at 23:00' promise" "0" "$(count_fixed 'ежедневно, 23:00' "$SEED_LEGEND")"
check "seed legend: the box is reviewed by the pilot only" "1" "$(count_fixed 'Разбирает только пилот' "$SEED_LEGEND")"
check "day-plan prompt: no claim that Note-Review marks and archives notes at 23:00" "0" "$(count_fixed 'это делает Note-Review в 23:00' "$DAYPLAN_PROMPT")"

echo "== A5: the cleanup safety net never sweeps up a proposed note, bold or not =="
PY3="$(bash "$ROOT/scripts/lib/find-python3.sh" --stdlib-only)" || { echo "no python3 for the cleanup case" >&2; exit 2; }
mkdir -p "$SB/clean/inbox" "$SB/clean/archive/notes" "$SB/clean-home"
cat > "$SB/clean/inbox/fleeting-notes.md" <<'EOF'
---
title: Fleeting
---

# Fleeting Notes

> legend

---

**Note A** ✅предложено

---

**Note B noise** ✅предложено (шум)

---

**Note C new**

---

~~Note D closed by the pilot~~

---

Note E proposed, the model dropped the bold ✅предложено

---

Note F proposed, typed with a space ✅ предложено

---

Note G proposed, typed with a capital ✅Предложено

---

Note H plain, no mark at all

---

~~Note I struck through by the pilot~~ ✅предложено

---
EOF
CLEAN_OUT="$(env HOME="$SB/clean-home" IWE_CLEANUP_REPO_DIR="$SB/clean" "$PY3" "$CLEANUP_PY" 2>&1)"
check "cleanup run: 3 archived (D, H, I: closed by the pilot or never marked), 6 kept" "Cleaned: 3 archived, 6 kept" "$CLEAN_OUT"
check "cleanup: the proposed notes and the new note stay in the box" "3" "$(grep -c '^\*\*Note' "$SB/clean/inbox/fleeting-notes.md")"
check "cleanup: a proposed note without bold stays in the box, typed with a space or with a capital too" "3" "$(grep -cE '^Note [EFG] ' "$SB/clean/inbox/fleeting-notes.md")"
check "cleanup: the struck-through note went to the archive" "1" "$(count_fixed 'Note D closed by the pilot' "$SB/clean/archive/notes/Notes-Archive.md")"
check "cleanup control: a plain note without any mark is still archived" "1" "$(count_fixed 'Note H plain, no mark at all' "$SB/clean/archive/notes/Notes-Archive.md")"
check "cleanup: a note the pilot struck through is archived even though the mark is still on its line" "1" "$(count_fixed 'Note I struck through by the pilot' "$SB/clean/archive/notes/Notes-Archive.md")"

# ==== LAYER B: the scheduler never starts note-review ====
echo "== B: scheduler.sh dispatch =="
# A fake clock (date shim for +%H and +%u only), a fake platform name (uname shim) and recording stub runners next to a
# COPY of scheduler.sh, so the real script resolves its helpers (code-scan, daily-report) and runners from the sandbox.
# scheduler.sh keeps the machine awake differently per platform: `caffeinate` on Darwin, a background
# `systemd-inhibit ... sleep infinity` that an EXIT trap kills anywhere else. Every case runs under both platform names,
# so a Mac exercises the Linux branch and a Linux runner the Darwin one.
REAL_DATE="$(command -v date)"
REAL_UNAME="$(command -v uname)"
cat > "$SB/shim/date" <<EOF
#!/bin/bash
case "\$1" in
    +%H) printf '%s\n' "\${FAKE_HOUR:-12}" ;;
    +%u) printf '%s\n' "\${FAKE_DOW:-3}" ;;
    *) exec "$REAL_DATE" "\$@" ;;
esac
EOF
cat > "$SB/shim/uname" <<EOF
#!/bin/bash
[ -n "\${FAKE_UNAME:-}" ] || exec "$REAL_UNAME" "\$@"
case "\${1:-}" in
    ""|-s) printf 'uname %s\n' "\$FAKE_UNAME" >> "\${PLATFORM_LOG:-/dev/null}"; printf '%s\n' "\$FAKE_UNAME" ;;
    *) exec "$REAL_UNAME" "\$@" ;;
esac
EOF
printf '#!/bin/bash\nexit 0\n' > "$SB/shim/caffeinate"
# The Linux inhibitor. The real systemd-inhibit skips its own --options and runs the wrapped command in its place; the
# stub does the same, so the PID that scheduler.sh keeps in $! is a live process and the EXIT trap (kill $_INHIBIT_PID)
# succeeds. A stub that returned at once left the trap a dead PID: kill exited 1 and so did the whole dispatch on Linux
# ("dispatch completed" printed, exit code 1). BSD sleep (macOS) does not accept "infinity", a long number stands for it.
cat > "$SB/shim/systemd-inhibit" <<'EOF'
#!/bin/bash
while [ $# -gt 0 ]; do
    case "$1" in --*) shift ;; *) break ;; esac
done
[ $# -gt 0 ] || exit 0
if [ "$1" = sleep ] && [ "${2:-}" = infinity ]; then set -- sleep 600; fi
exec "$@"
EOF
# macOS only: the dispatch reads the AC sleep setting, and under pipefail an empty answer would abort it. The call is
# recorded: it happens in the foreground and on the Darwin branch only, which makes it the control that the branch ran
# (the inhibitors themselves run in the background and may be killed before they write anything)
cat > "$SB/shim/pmset" <<'EOF'
#!/bin/bash
printf 'pmset %s\n' "$*" >> "$PLATFORM_LOG"
printf 'AC Power:\n sleep 0\nBattery Power:\n sleep 1\n'
EOF
chmod +x "$SB/shim/"*

mkdir -p "$SB/sched/scripts" "$SB/runtime/roles/strategist/scripts" "$SB/runtime/roles/extractor/scripts"
cp "$ROOT/roles/synchronizer/scripts/scheduler.sh" "$SB/sched/scripts/scheduler.sh"
for stub in code-scan.sh dt-collect.sh daily-report.sh; do
    printf '#!/bin/bash\nexit 0\n' > "$SB/sched/scripts/$stub"
done
printf '#!/bin/bash\nprintf "strategist %%s\\n" "$*" >> "$CALLS_LOG"\nexit 0\n' > "$SB/runtime/roles/strategist/scripts/strategist.sh"
printf '#!/bin/bash\nprintf "extractor %%s\\n" "$*" >> "$CALLS_LOG"\nexit 0\n' > "$SB/runtime/roles/extractor/scripts/extractor.sh"
chmod +x "$SB/sched/scripts/"*.sh "$SB/runtime/roles/strategist/scripts/strategist.sh" "$SB/runtime/roles/extractor/scripts/extractor.sh"

RUN_N=0
run_scheduler() {  # <fake hour> <fake day of week> <platform name>; sets SCHED_RC, SCHED_HOME; runner calls -> $SB/calls.log
    RUN_N=$((RUN_N + 1))
    SCHED_HOME="$SB/sched-home-$RUN_N"
    mkdir -p "$SCHED_HOME"
    : > "$SB/calls.log"
    : > "$SB/platform.log"
    SCHED_RC=0
    env -i HOME="$SCHED_HOME" PATH="$SB/shim:$PATH" TMPDIR="$SB/tmp" IWE_TEMPLATE="$ROOT" IWE_RUNTIME="$SB/runtime" \
        IWE_WORKSPACE="$SB/ws" CALLS_LOG="$SB/calls.log" PLATFORM_LOG="$SB/platform.log" \
        FAKE_HOUR="$1" FAKE_DOW="$2" FAKE_UNAME="$3" \
        bash "$SB/sched/scripts/scheduler.sh" dispatch > "$SB/sched.out" 2>&1 || SCHED_RC=$?
}
state_markers() {  # <name fragment> -> number of scheduler state markers whose name contains it
    find "$SCHED_HOME/.local/state/exocortex" -name "*$1*" 2>/dev/null | wc -l | tr -d ' '
}

for B_PLATFORM in Darwin Linux; do
    B_EXPECT_PMSET=1
    [ "$B_PLATFORM" = Linux ] && B_EXPECT_PMSET=0

    echo "-- $B_PLATFORM, 23:00 on a Monday: the evening slot of the old nightly run (week-review is the control) --"
    run_scheduler 23 1 "$B_PLATFORM"
    check "$B_PLATFORM: dispatch completed" "0/1" "$SCHED_RC/$(count_fixed 'dispatch completed' "$SB/sched.out")"
    check_at_least "$B_PLATFORM: control: scheduler.sh asked for the platform and got $B_PLATFORM" 1 "$(count_fixed "uname $B_PLATFORM" "$SB/platform.log")"
    check "$B_PLATFORM: control: the AC sleep setting is read (pmset) on Darwin and only there" "$B_EXPECT_PMSET" "$(count_fixed 'pmset' "$SB/platform.log")"
    check "$B_PLATFORM: control: the stub strategist runner is wired in (week-review ran)" "1" "$(count_fixed 'strategist week-review' "$SB/calls.log")"
    check "$B_PLATFORM: note-review was NOT started in the evening" "0" "$(count_fixed 'note-review' "$SB/calls.log")"
    check "$B_PLATFORM: no note-review state marker was written" "0" "$(state_markers note-review)"

    echo "-- $B_PLATFORM, 09:00 on a Wednesday: the morning catch-up of the old nightly run (morning is the control) --"
    run_scheduler 9 3 "$B_PLATFORM"
    check "$B_PLATFORM: dispatch completed" "0/1" "$SCHED_RC/$(count_fixed 'dispatch completed' "$SB/sched.out")"
    check_at_least "$B_PLATFORM: control: scheduler.sh asked for the platform and got $B_PLATFORM" 1 "$(count_fixed "uname $B_PLATFORM" "$SB/platform.log")"
    check "$B_PLATFORM: control: the AC sleep setting is read (pmset) on Darwin and only there" "$B_EXPECT_PMSET" "$(count_fixed 'pmset' "$SB/platform.log")"
    check "$B_PLATFORM: control: the stub strategist runner is wired in (morning ran)" "1" "$(count_fixed 'strategist morning' "$SB/calls.log")"
    check "$B_PLATFORM: note-review was NOT started as a catch-up for yesterday" "0" "$(count_fixed 'note-review' "$SB/calls.log")"
    check "$B_PLATFORM: no note-review state marker (yesterday or today) was written" "0" "$(state_markers note-review)"
done

# ==== LAYER C: the Day Open scanner ====
echo "== C: Day Open scanner (render_fleeting_notes) =="
cat > "$SB/scan-fleeting.md" <<'EOF'
# Fleeting Notes

> legend with a **bold** word and ✅предложено

---

**Новая заметка**
<sub>10.09.2026, 10:00</sub>

---

**Предложенная заметка** ✅предложено
<sub>10.09.2026, 10:05</sub>

---

**Шумовая заметка** ✅предложено (шум)
<sub>10.09.2026, 10:10</sub>

---

**Отложенная заметка** 🔄
<sub>10.09.2026, 10:15</sub>

---

Обычная заметка
<sub>10.09.2026, 10:20</sub>

---

~~Зачёркнутая заметка~~
<sub>10.09.2026, 10:25</sub>

---
EOF
run_scanner() {  # <scaffold script> <fleeting notes file> -> the rendered table rows
    local fn
    fn="$(sed -n '/^render_fleeting_notes() {/,/^}/p' "$1")"
    [ -n "$fn" ] || { echo "render_fleeting_notes is missing in $1"; return 0; }
    mkdir -p "$SB/iwe/DS-strategy/inbox"
    cp "$2" "$SB/iwe/DS-strategy/inbox/fleeting-notes.md"
    IWE="$SB/iwe" IWE_GOVERNANCE_REPO=DS-strategy bash -c "$fn"$'\n''render_fleeting_notes'
}
for scaffold in "scripts/day-open-scaffold.sh" "seed/strategy/scripts/day-open-scaffold.sh"; do
    ROWS="$(run_scanner "$ROOT/$scaffold" "$SB/scan-fleeting.md")"
    check "$scaffold: three notes await the pilot (new, proposed, proposed noise)" "3" "$(printf '%s\n' "$ROWS" | grep -c '^| \[«')"
    check "$scaffold: the new note is listed" "1" "$(printf '%s\n' "$ROWS" | grep -cF '[«Новая заметка»]')"
    check "$scaffold: the proposed note is listed with its clean title" "1" "$(printf '%s\n' "$ROWS" | grep -cF '[«Предложенная заметка»]')"
    check "$scaffold: the proposed noise is listed without the mark in its title" "1" "$(printf '%s\n' "$ROWS" | grep -cF '[«Шумовая заметка»]')"
    check "$scaffold: deferred, plain and struck-through notes are not listed" "0" "$(printf '%s\n' "$ROWS" | grep -cE 'Отложенная|Обычная|Зачёркнутая')"
done
printf '# Fleeting Notes\n\n> legend\n\n---\n\nОбычная заметка\n\n---\n' > "$SB/scan-empty.md"
check "no note awaits the pilot: the empty row, no PENDING marker" "| нет заметок | — | — | ✅ |" "$(run_scanner "$ROOT/scripts/day-open-scaffold.sh" "$SB/scan-empty.md")"

# ==== LAYER D: the Telegram text ====
echo "== D: the Note-Review Telegram message =="
mkdir -p "$SB/tg/DS-strategy/current"
printf '# DayPlan\n' > "$SB/tg/DS-strategy/current/DayPlan $("$REAL_DATE" +%Y-%m-%d).md"
TG_MSG="$(env -i HOME="$SB/tg-home" PATH="$PATH" IWE_WORKSPACE="$SB/tg" IWE_GOVERNANCE_REPO=DS-strategy \
    bash -c 'source "$1"; build_message note-review' _ "$ROOT/roles/synchronizer/scripts/templates/strategist.sh" 2>&1)"
check "the message exists (the fixture Day Plan was found)" "1" "$(printf '%s\n' "$TG_MSG" | grep -cF 'Note-Review завершён')"
check "the message does not claim the inbox was cleaned" "0" "$(printf '%s\n' "$TG_MSG" | grep -cF 'inbox почищен')"
# the notifier cannot tell whether the model wrote anything, so it must not say that proposals were written
check "the message does not claim the proposals were written (a refused or failed model run sends it too)" "0" "$(printf '%s\n' "$TG_MSG" | grep -cF 'предложения записаны')"
check "the message says the notes wait for the pilot's decision" "1" "$(printf '%s\n' "$TG_MSG" | grep -cF 'пока вы не примете по ним решение')"

# ==== LAYER E: the scheduler report ====
echo "== E: daily-report.sh at 23:00 =="
mkdir -p "$SB/dr-home/.local/state/exocortex"
TODAY="$("$REAL_DATE" +%Y-%m-%d)"
echo "00:00:01" > "$SB/dr-home/.local/state/exocortex/synchronizer-code-scan-$TODAY"
echo "04:00:01" > "$SB/dr-home/.local/state/exocortex/strategist-morning-$TODAY"
DR_RC=0
DR_OUT="$(env -i HOME="$SB/dr-home" PATH="$SB/shim:$PATH" TMPDIR="$SB/tmp" IWE_WORKSPACE="$SB/ws" IWE_GOVERNANCE_REPO=DS-strategy \
    FAKE_HOUR=23 FAKE_DOW=3 bash "$ROOT/roles/synchronizer/scripts/daily-report.sh" --dry-run 2>&1)" || DR_RC=$?
check "the dry run succeeds" "0" "$DR_RC"
check "everything that must run did run: the traffic light is green (a missing note-review marker is no failure)" "1" "$(printf '%s\n' "$DR_OUT" | grep -cF '🟢')"
check "no note-review complaint in the remarks" "0" "$(printf '%s\n' "$DR_OUT" | grep -c 'note-review')"
check "no 'Разбор заметок' row that could show a failed run" "0" "$(printf '%s\n' "$DR_OUT" | grep -cF 'Разбор заметок')"
# ==== LAYER F: the canary ====
echo "== F: the canary counts as NEW only the notes nobody has dealt with (count_new_bold_notes) =="
cat > "$SB/canary-fleeting.md" <<'EOF'
# Fleeting Notes

---

**New note**

---

**Proposed note** ✅предложено

---

**Spaced note** ✅ предложено

---

**Capitalised note** ✅Предложено

---

**Mixed case note** ✅пРедложено

---

**Shouting noise note** ✅ПРЕДЛОЖЕНО (шум)

---

**Deferred note** 🔄

---

Plain note, the model dropped the bold ✅предложено

---

~~Struck note~~
EOF
# the function and the pattern it uses are cut out of the runner by name, as setup/test-strategist-isolated-scenarios.sh does
CANARY_CODE="$(sed -n '/^PROPOSED_MARK_ERE=/p;/^count_new_bold_notes() {/,/^}/p' "$ROOT/roles/strategist/scripts/strategist.sh")"
[ -n "$CANARY_CODE" ] || fail "count_new_bold_notes is missing in strategist.sh"
canary_count() {  # <fleeting notes file>
    bash -c "$CANARY_CODE"$'\n''count_new_bold_notes "$1"' _ "$1"
}
check "only the untouched note counts as new: marked notes (with a space, with capitals, in any mix of case), a deferred one, a plain one and a struck one do not" "1" "$(canary_count "$SB/canary-fleeting.md")"
check "a missing box counts as zero" "0" "$(canary_count "$SB/no-such-box.md")"

# ==== LAYER G: the other texts ====
echo "== G1: the Day Open instructions no longer say that a processed note leaves the box =="
for f in ".claude/skills/day-open/day-open-details.md" ".claude/skills/day-open/templates.md" "memory/templates-dayplan.md"; do
    for stale in 'проверить по git log (`note-review`)' 'проверить git log `note-review`' 'исчезает из fleeting-notes.md' \
        'Все заметки обработаны (коммит HASH' 'Источник: Note-Review (вчера)'; do
        check "$f: no '$stale'" "0" "$(count_fixed "$stale" "$ROOT/$f")"
    done
    check_at_least "$f: the condition is 'no notes waiting for the pilot's decision'" 1 "$(count_fixed 'ждущих решения пилота' "$ROOT/$f")"
    check_at_least "$f: what waits is a bold note OR a note marked ✅предложено; a deferred 🔄 note does not count (the scanner does not list it)" 1 "$(count_fixed 'отложенные `🔄` не считаются' "$ROOT/$f")"
done
check "day-open-details: a note marked ✅предложено is carried over to the next Day Plan" "1" "$(count_fixed 'такую заметку переносить в секцию «Разбор заметок» снова' "$ROOT/.claude/skills/day-open/day-open-details.md")"
check "day-open-details: the categorisation points at the prompt that is shipped" "1" "$(count_fixed 'Полная справка → `roles/strategist/prompts/note-review.md`' "$ROOT/.claude/skills/day-open/day-open-details.md")"

echo "== G2: no guide, seed file or prompt promises an automatic evening review =="
absent_in_texts() {  # <description> <fixed string>: no file under docs/, seed/, roles/, .claude/, memory/ contains it
    check "$1" "0" "$(grep -rlF -- "$2" "$ROOT/docs" "$ROOT/seed" "$ROOT/roles" "$ROOT/.claude" "$ROOT/memory" 2>/dev/null | wc -l | tr -d ' ')"
}
absent_in_texts "SETUP-GUIDE: the note is not 'reviewed in the evening' by the Strategist" 'Стратег разберёт её вечером'
absent_in_texts "SETUP-GUIDE: no 'Вечер (23:00)' row in the table of automatic jobs" '**Вечер (23:00)**'
absent_in_texts "IWE-HELP: no 'Вечером (23:00) — разбор заметок'" 'Вечером (23:00) — разбор заметок'
absent_in_texts "IWE-HELP: no 'Стратег разбирает вечером'" 'Стратег разбирает вечером'
absent_in_texts "LEARNING-PATH: note-review is not one of the nightly automations" '(sync-agent, note-review, reindex)'
absent_in_texts "LEARNING-PATH: the note lifecycle does not hand the review to the Strategist role" 'Note-Review (Стратег или вручную)'
absent_in_texts "LEARNING-PATH: noise is not struck through by the agent" '~~зачёркнуто~~ → архив'
absent_in_texts "seed draft list: not updated by a daily Note-Review" 'Note-Review (ежедневно)'
absent_in_texts "roles/README: the Strategist has no evening job" 'launchd (утро, вечер, неделя)'
absent_in_texts "session-prep: no 'daily triage' of Note-Review" 'ежедневного triage Note-Review'
absent_in_texts "strategy-session: no ambiguous 'clean the processed'" 'Очисти обработанные из'
absent_in_texts "strategy-session steps: no ambiguous 'clean the processed'" '**Очисти** обработанные из'
for f in "roles/strategist/prompts/strategy-session.md" "roles/strategist/prompts/strategy-session-weekly/steps/08-confirm.md"; do
    check "$f: only notes the pilot already decided on are cleaned" "1" "$(count_fixed 'по которым пилот уже принял решение' "$ROOT/$f")"
done
echo "== G2b: every text that sends the user to a manual review names a route that exists =="
absent_in_texts "no text points at a memory file that is not shipped" 'feedback_note_review_routing'
absent_in_texts "no text says 'ask in a chat' without naming a route" 'когда вы просите об этом в чате'
absent_in_texts "no text says 'ask the Strategist in a chat' without naming a route" 'попросите Стратега разобрать их в чате'
for f in docs/SETUP-GUIDE.md docs/IWE-HELP.md docs/LEARNING-PATH.md; do
    check_at_least "$f: the manual review names the terminal command" 1 "$(count_fixed 'strategist.sh note-review' "$ROOT/$f")"
done
check "SETUP-GUIDE: the chat route names the instruction file that is shipped" "1" "$(count_fixed 'по инструкции `roles/strategist/prompts/note-review.md`' "$ROOT/docs/SETUP-GUIDE.md")"
check "synchronizer README: a manual run from the terminal is described honestly" "1" "$(count_fixed 'Запуск `strategist.sh note-review` из терминала идёт без чата' "$ROOT/roles/synchronizer/README.md")"
check "synchronizer README: no promise that the manual run does the whole review" "0" "$(count_fixed 'вручную (`strategist.sh note-review`) или в секции' "$ROOT/roles/synchronizer/README.md")"

echo "== G3: the decision is not attributed to a pilot on a date =="
for stale in '29-30.07.2026' '(пилот, 30.07.2026)' 'Пилот (2026-07-29)' '(пилот, 2026-07-29)' \
    'pilot decision 2026-07-29/30' 'Pilot decision (2026-07-29)' 'Since the pilot decision of'; do
    absent_in_texts "no '$stale' in the shipped texts and script comments" "$stale"
done

echo "== G4: the scanner comment says what the scanner does with a bold line inside a note body =="
# the mark is looked for in the first line of a block only, but the legacy rule "a bold title alone on a line" takes such a
# line wherever it stands (a plain title with **Важно** in its body: the safety net does not keep it, the canary counts it
# as new, the scanner lists it); a comment that said "the body is never scanned" was wrong
for scaffold in "scripts/day-open-scaffold.sh" "seed/strategy/scripts/day-open-scaffold.sh"; do
    check "$scaffold: no claim that the body of a note is never scanned" "0" "$(count_fixed 'The body of a note is never scanned' "$ROOT/$scaffold")"
    check "$scaffold: the comment says a bold title alone on a line is taken wherever it stands" "1" "$(count_fixed 'is taken wherever it stands' "$ROOT/$scaffold")"
done

# ==== LAYER H: one answer in three places ====
echo "== H: the safety net, the canary and the Day Open scanner answer the same on one table of note titles =="
# The mark of a proposed note is recognised by three independent rules: should_keep() of the cleanup script (Python),
# count_new_bold_notes() of the runner (grep) and render_fleeting_notes() of the Day Open scaffold (awk). A model does
# not copy the mark letter for letter: a space after the check mark (also a no-break one), any mix of capitals, a tail
# such as ": задача" or "(шум)", sometimes no bold. The decision the three share: the mark in the FIRST line of a note
# makes it "waiting for the pilot's decision", unless that line is no note title (a quote, a heading, a timestamp, a
# list item) or the pilot struck the note through. Every row is the first line of a one-note box; the expectation is
# "kept by the safety net / counted as NEW by the canary / listed for the pilot by the scanner". A note nobody touched
# is new and listed; a deferred 🔄 note is kept and not listed (the strategy session handles it); a bold line with
# other text and no mark is the old legacy case (counted new by the canary, not listed by the scanner). The title the
# scanner prints is cleaned of the mark and of 🔄 (T09, T28, T38); a title without them stays as typed (T01, T37), and
# a line with nothing but the mark keeps it (T36) so that the row still has a name.
NB=$'\302\240'
H_ROWS=(
    'T01|1/1/1|**New note**'
    'T02|1/0/1|**Proposed** ✅предложено'
    'T03|1/0/1|**Spaced** ✅ предложено'
    'T04|1/0/1|**Capital** ✅Предложено'
    'T05|1/0/1|**Shout** ✅ПРЕДЛОЖЕНО (шум)'
    'T06|1/0/1|**Mixed** ✅пРедложено'
    'T07|1/0/1|**Tail** ✅предложено: задача, НЭП'
    'T08|1/0/1|**Tail** ✅предложено (шум: Реализовано: РП #54)'
    'T09|1/0/1|**Inside ✅предложено**'
    'T10|1/0/1|**Two**  ✅  предложено'
    'T11|1/0/1|Bare proposed ✅предложено'
    'T12|1/0/1|Bare space ✅ предложено'
    'T13|1/0/1|Bare capital ✅Предложено'
    'T14|1/0/1|Bare paren ✅предложено (шум)'
    'T15|1/0/1|Bare colon ✅предложено: задача'
    'T16|1/0/1|Bare mid ✅предложено в середине строки'
    'T17|1/0/1|Заметка про слово ✅предложено в тексте'
    'T18|0/0/0|> quoted ✅предложено'
    'T19|0/0/0|~~Struck~~ ✅предложено'
    'T20|0/0/0|~~Struck~~'
    'T21|0/0/0|- item ✅предложено'
    'T22|0/0/0|* item ✅предложено'
    'T23|0/0/0|1. numbered ✅предложено'
    'T24|0/0/0|# Heading ✅предложено'
    'T25|0/0/0|<sub>10.09.2026, 15:32</sub> ✅предложено'
    'T26|0/0/0|Plain note'
    'T27|1/0/0|**Deferred** 🔄'
    'T28|1/0/1|**Both** 🔄 ✅предложено'
    'T29|1/0/0|Plain 🔄'
    "T30|1/0/1|**Nbsp** ✅${NB}предложено"
    "T31|1/0/1|Bare nbsp ✅${NB}предложено"
    'T32|1/0/1|**Twice** ✅предложено ✅предложено'
    'T33|1/0/1|Bare ✅предложено (шум) хвост'
    'T34|1/1/0|**Other** ✔️предложено'
    'T35|1/1/0|**English** ✅proposed'
    'T36|1/0/1|**✅предложено**'
    'T37|1/1/1|**Обычное название  с двумя пробелами и (скобками)**'
    'T38|1/0/1|**Both 🔄** ✅предложено'
)
# the box layout is the real one: header, rule, title line, timestamp line (the bot format, which the safety net
# cannot date, so the 24-hour guard stays out of the way on every day of the year), rule
h_index=0
for h_row in "${H_ROWS[@]}"; do
    h_index=$((h_index + 1))
    IFS='|' read -r h_id h_expected h_title <<< "$h_row"
    printf '# Fleeting Notes\n\n---\n\n%s\n<sub>10.09.2026, 15:32</sub>\n\n---\n' "$h_title" > "$SB/h-box-$(printf '%02d' "$h_index").md"
done
H_KEPT="$(env HOME="$SB/clean-home" IWE_CLEANUP_REPO_DIR="$SB/clean" "$PY3" -c '
import importlib.util
import sys
spec = importlib.util.spec_from_file_location("cleanup_under_test", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
for path in sys.argv[2:]:
    with open(path, encoding="utf-8") as box:
        header, blocks = module.parse_notes(box.read())
    print(int(module.should_keep(blocks[0])) if blocks else -1)
' "$CLEANUP_PY" "$SB"/h-box-*.md)"
h_index=0
for h_row in "${H_ROWS[@]}"; do
    h_index=$((h_index + 1))
    IFS='|' read -r h_id h_expected h_title <<< "$h_row"
    h_file="$SB/h-box-$(printf '%02d' "$h_index").md"
    h_answer="$(printf '%s\n' "$H_KEPT" | sed -n "${h_index}p")/$(canary_count "$h_file")/$(run_scanner "$ROOT/scripts/day-open-scaffold.sh" "$h_file" | grep -c '^| \[«')"
    check "$h_id kept/new/listed for '$h_title'" "$h_expected" "$h_answer"
    check "$h_id the seed copy of the scanner agrees" "${h_answer##*/}" "$(run_scanner "$ROOT/seed/strategy/scripts/day-open-scaffold.sh" "$h_file" | grep -c '^| \[«')"
done
# one box with every row: each waiting note once, in file order, with a clean title (the mark is not part of it)
{
    printf '# Fleeting Notes\n\n---\n'
    for h_row in "${H_ROWS[@]}"; do
        IFS='|' read -r h_id h_expected h_title <<< "$h_row"
        printf '\n%s\n<sub>10.09.2026, 15:32</sub>\n\n---\n' "$h_title"
    done
} > "$SB/h-all-box.md"
H_LISTED_TITLES="$(run_scanner "$ROOT/scripts/day-open-scaffold.sh" "$SB/h-all-box.md" | sed -E 's/^\| \[«(.*)»\]\(.*$/\1/' | tr '\n' '|')"
check "one box with every row: the pilot sees each waiting note once, its title without the mark and without 🔄 (a title without them as typed)" \
    "New note|Proposed|Spaced|Capital|Shout|Mixed|Tail|Tail|Inside|Two|Bare proposed|Bare space|Bare capital|Bare paren|Bare colon|Bare mid|Заметка про слово|Both|Nbsp|Bare nbsp|Twice|Bare|✅предложено|Обычное название  с двумя пробелами и (скобками)|Both|" "$H_LISTED_TITLES"
# ==== END LAYERS ====

echo
echo "Passed: $PASS_COUNT, failed: $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
