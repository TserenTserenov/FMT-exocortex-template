#!/usr/bin/env bash
# session-dir-reserve.sh -- atomically reserve today's session number and create
# the session directory. Prints SESSION_ID on stdout.
#
#   session-dir-reserve.sh <DAY_DIR> <TODAY> <SLUG>
#
# Why this exists (WP-530, peer session 2026-09-05-24 with Kimi). Both writer
# skills (peer-conversation, kimi-peer-writer) used to inline this bash:
#
#     NUM=$(printf "%02d" $(( $(find "$DAY_DIR" -maxdepth 1 -type d \
#           -name "${TODAY}-[0-9][0-9]-*" | wc -l) + 1 )))
#     mkdir -p "$DAY_DIR/${TODAY}-${NUM}-${SLUG}"
#
# Two defects there:
#   A. Race. Nothing between the scan and `mkdir -p`, and `mkdir -p` does not
#      fail on an existing directory -- two sessions starting within the same
#      window silently share one directory and overwrite each other's journal.
#   B. count+1 != max+1. Archiving or deleting one session directory frees its
#      number for reissue, even with no concurrency at all -- while that number
#      already lives in the session index, the ORZ filename and WP cards.
#
# Both are closed by one mechanism: the number itself is the name of a marker
# directory under .numbers/, and `mkdir` without -p is the only arbiter. The
# marker is monotonic -- it survives archiving of the session directory, so a
# number is never reissued. Reissue is the actual hazard here (two objects, one
# identifier); a leftover marker for an archived session is not.
#
# Two-phase creation is deliberate: the container `.numbers/` is created with
# -p (a race there is harmless -- both sides end up with the same directory),
# the leaf is created without -p (EEXIST means we lost the race, retry).
#
# .numbers/ is allocator state, not a catalogue of sessions: the session index
# stays canonical for "which sessions existed". The `owner` file inside each
# marker is written by the winner after the race is settled, purely so a human
# reading .numbers/ can tell what took the number.
#
# Policy: never delete .numbers/ when archiving session directories. It is
# untracked by git on purpose (see the caller's .gitignore) -- if `git clean
# -fd` ever wipes it, the fallback below recomputes a safe starting number
# from whatever session directories are still on disk.

set -euo pipefail

usage() {
    echo "usage: session-dir-reserve.sh <DAY_DIR> <TODAY:YYYY-MM-DD> <SLUG>" >&2
    exit 2
}

[ $# -eq 3 ] || usage
DAY_DIR="$1"
TODAY="$2"
SLUG="$3"

[[ "$TODAY" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] \
    || { echo "session-dir-reserve: TODAY '$TODAY' не в формате YYYY-MM-DD" >&2; exit 2; }
# The slug lands in a directory name, a git path, the session index and the ORZ
# filename -- reject anything that would need quoting downstream rather than
# silently mangling it.
[[ "$SLUG" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] \
    || { echo "session-dir-reserve: SLUG '$SLUG' — допустимы только строчные латинские буквы, цифры и дефис (не в начале/конце)" >&2; exit 2; }

NUMBERS_DIR="$DAY_DIR/.numbers"
mkdir -p "$NUMBERS_DIR"

# Highest number already taken today. Two sources:
#   - marker directories: the registry, authoritative from the first run onwards;
#   - existing session directories: one-shot backfill for days that started
#     before this script existed. Once every live day has a .numbers/ registry
#     this branch stops contributing and can be dropped as a dead path.
highest_taken() {
    local max=0 d n
    shopt -s nullglob
    for d in "$DAY_DIR/${TODAY}-"[0-9][0-9]-*/; do
        n="${d#"$DAY_DIR/${TODAY}-"}"
        n="${n:0:2}"
        if [ "$((10#$n))" -gt "$max" ]; then max=$((10#$n)); fi
    done
    for d in "$NUMBERS_DIR"/[0-9][0-9]/; do
        n="$(basename "$d")"
        if [ "$((10#$n))" -gt "$max" ]; then max=$((10#$n)); fi
    done
    printf '%s\n' "$max"
}

# Retry until a number is won. Re-reading the maximum on every attempt is the
# point: losing the race means somebody else took that number, so the next
# attempt must see it.
for _attempt in $(seq 1 99); do
    next=$(( $(highest_taken) + 1 ))
    if [ "$next" -gt 99 ]; then
        echo "session-dir-reserve: за $TODAY выдано 99 номеров, двузначная схема исчерпана" >&2
        exit 1
    fi
    num=$(printf '%02d' "$next")
    # No -p on the leaf: EEXIST is the signal that another session won this
    # number, and it is the only atomic arbiter available on a POSIX filesystem.
    if mkdir "$NUMBERS_DIR/$num" 2>/dev/null; then
        session_id="${TODAY}-${num}-${SLUG}"
        # Session directory first: if this fails (permissions, full disk), the
        # number stays burned either way, but an `owner` file must never point
        # at a directory that doesn't exist.
        mkdir -p "$DAY_DIR/$session_id"
        printf '%s\n' "$session_id" > "$NUMBERS_DIR/$num/owner"
        printf '%s\n' "$session_id"
        exit 0
    fi
done

echo "session-dir-reserve: не удалось зарезервировать номер за 99 попыток" >&2
exit 1
