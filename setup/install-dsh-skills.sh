#!/bin/bash
# install-dsh-skills.sh — connect the template's skills to DeepSeek Harness (DSH).
#
# Why: IWE skills live in <workspace>/.claude/skills. Claude Code reads that
# directory by itself; DSH discovers skills only in <project>/.dsh/skills,
# <project>/.agents/skills and in the customSkillDirs of its profile layers.
# Without this step a DSH agent sees none of the template's skills, and every
# protocol that starts with a skill (day-open, wp-new, artifactor, ...) degrades
# to reading files by hand.
#
# What: appends one patch entry to $DSH_HOME/cordis.patch.yml — the layer DSH
# applies over EVERY profile (web, headless, tui, and profiles created later) —
# so that skill-filesystem also scans <workspace>/.claude/skills. Skills stay in
# place: no copies, no symlink farm, template updates are picked up as they land.
#
# Idempotent: "connected" means the whole managed block (marker, customSkillDirs and
# the current skills path), not just the marker text. The write is serialized by a
# lock directory next to the file and done through a temporary file.
# If customSkillDirs is already configured (in the home layer, in any profile
# layer, or by this entry for another workspace path), the file is left
# untouched and the script says so: the user's own choice wins, and a second
# layer overriding it would be a surprise.
#
# Called from:
#   - setup.sh (initial installation)
#   - update.sh (after an upgrade)
#
# Usage:
#   bash install-dsh-skills.sh --workspace PATH [--dsh-home PATH] [--dry-run] [--quiet]
#
# Exit codes:
#   0 — connected / already connected / nothing to connect (DSH not installed)
#   1 — invalid arguments
#   2 — write failure

set -eu

WORKSPACE_DIR=""
DSH_HOME_ARG=""
DRY_RUN=false
QUIET=false
MARKER="IWE skills bridge"

while [ $# -gt 0 ]; do
    case "$1" in
        --workspace) WORKSPACE_DIR="$2"; shift 2 ;;
        --dsh-home)  DSH_HOME_ARG="$2"; shift 2 ;;
        --dry-run)   DRY_RUN=true; shift ;;
        --quiet|-q)  QUIET=true; shift ;;
        --help|-h)
            grep '^#' "$0" | head -30
            exit 0
            ;;
        *)
            echo "ERROR: Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

if [ -z "$WORKSPACE_DIR" ]; then
    echo "ERROR: --workspace обязателен" >&2
    exit 1
fi

say() { $QUIET || echo "$@"; }

WORKSPACE_DIR="${WORKSPACE_DIR/#\~/$HOME}"
# "--workspace /x/ws/" and "--workspace /x/ws" are the same workspace and must
# give the same stored path, or the second form would look like a conflict.
while [ "${#WORKSPACE_DIR}" -gt 1 ] && [ "${WORKSPACE_DIR%/}" != "$WORKSPACE_DIR" ]; do
    WORKSPACE_DIR="${WORKSPACE_DIR%/}"
done
DSH_HOME_DIR="${DSH_HOME_ARG:-${DSH_HOME:-$HOME/.dsh}}"
DSH_HOME_DIR="${DSH_HOME_DIR/#\~/$HOME}"

SKILLS_DIR="$WORKSPACE_DIR/.claude/skills"
PATCH_FILE="$DSH_HOME_DIR/cordis.patch.yml"
# A patch layer kept as a symlink (dotfiles repository) must stay one: work on
# the real file, the temporary file and the final move then land beside it.
# The recursive resolver of readlink is absent on macOS: follow the chain by hand, bounded.
link_hops=0
while [ -L "$PATCH_FILE" ] && [ "$link_hops" -lt 20 ]; do
    link_target=$(readlink "$PATCH_FILE")
    case "$link_target" in
        /*) PATCH_FILE="$link_target" ;;
        *)  PATCH_FILE="$(dirname "$PATCH_FILE")/$link_target" ;;
    esac
    link_hops=$((link_hops + 1))
done

# No skills in the workspace (partial checkout, or a workspace that keeps them
# elsewhere): nothing to connect, and that is not an error.
if [ ! -d "$SKILLS_DIR" ]; then
    say "  ○ DSH: каталог навыков не найден ($SKILLS_DIR) — подключение пропущено."
    exit 0
fi

# DSH is optional: an installation without it must not fail or create $HOME/.dsh.
if [ ! -d "$DSH_HOME_DIR/profiles" ]; then
    say "  ○ DSH не установлен ($DSH_HOME_DIR/profiles) — подключать нечего."
    exit 0
fi

# The entry as the installer writes it: one JSON string per path (valid YAML scalar).
skills_dir_yaml() {
    python3 -c 'import json, sys; print(json.dumps(sys.argv[1]))' "$SKILLS_DIR"
}

# Prints "yes" when some occurrence of the marker opens a managed block of ours.
# A block starts at a comment line (column 0) carrying the marker and ends at the
# next such line, at the second top-level entry ("- " at the start of a line) or
# at a non-indented line that is not a comment. It is ours when its first
# top-level entry is exactly "- id: skill-filesystem" and the customSkillDirs list
# of that entry holds this workspace's path, written as the installer writes it.
# Every occurrence counts: a user comment repeating the phrase may come before
# our block (#1623). Values go through ENVIRON, not "awk -v": -v would expand the
# backslash escapes json.dumps writes for non-ASCII, quotes and backslashes.
# A trailing CR is ignored, so a file converted to CRLF is still recognised.
managed_block_installed() {
    DSH_MARKER="$MARKER" DSH_WANT="      - $1" awk '
        BEGIN { marker = ENVIRON["DSH_MARKER"]; want = ENVIRON["DSH_WANT"] }
        function close_block() {
            if (inblk && first_ok && has_path) ok = 1
            inblk = 0; inlist = 0
        }
        { sub(/\r$/, "") }
        /^#/ && index($0, marker) {
            close_block()
            inblk = 1; entries = 0; first_ok = 0; has_path = 0
            next
        }
        !inblk { next }
        /^- / {
            entries++
            if (entries > 1) { close_block(); next }
            first_ok = ($0 == "- id: skill-filesystem")
            next
        }
        /^[^ #]/ { close_block(); next }
        entries != 1 { next }
        /^    customSkillDirs:[ \t]*$/ { inlist = 1; next }
        inlist && /^      - / { if ($0 == want) has_path = 1; next }
        inlist && !/^[ \t]*(#.*)?$/ { inlist = 0 }
        END { close_block(); print (ok ? "yes" : "no") }
    ' "$PATCH_FILE"
}

# Sets DSH_STATE: installed | conflict | absent (and DSH_CONFLICT for conflict).
# "installed" needs the whole managed block, not just the marker text: a user
# comment that repeats the phrase proves nothing (#1623).
evaluate_state() {
    DSH_STATE="absent"
    DSH_CONFLICT=""
    if [ -f "$PATCH_FILE" ] && grep -qF "$MARKER" "$PATCH_FILE" 2>/dev/null \
        && [ "$(managed_block_installed "$(skills_dir_yaml)")" = "yes" ]; then
        DSH_STATE="installed"
        return 0
    fi
    # Someone already configured customSkillDirs (by hand, or this entry for
    # another workspace path) — do not fight over it.
    if [ -f "$PATCH_FILE" ] && grep -q 'customSkillDirs' "$PATCH_FILE" 2>/dev/null; then
        DSH_CONFLICT="$PATCH_FILE"
    fi
    if [ -z "$DSH_CONFLICT" ]; then
        for profile_patch in "$DSH_HOME_DIR"/profiles/*/cordis.patch.yml; do
            [ -f "$profile_patch" ] || continue
            if grep -q 'customSkillDirs' "$profile_patch" 2>/dev/null; then
                DSH_CONFLICT="$profile_patch"
                break
            fi
        done
    fi
    [ -z "$DSH_CONFLICT" ] || DSH_STATE="conflict"
}

# Returns 0 when nothing is left to do (the message is printed).
report_final_state() {
    case "$DSH_STATE" in
        installed)
            say "  ✓ DSH: навыки шаблона уже подключены ($PATCH_FILE)."
            return 0 ;;
        conflict)
            say "  ⚠ DSH: customSkillDirs уже задан ($DSH_CONFLICT) — файл не меняю."
            say "    Чтобы подключить навыки шаблона, добавьте вручную: $SKILLS_DIR"
            return 0 ;;
    esac
    return 1
}

evaluate_state
if report_final_state; then
    exit 0
fi

if $DRY_RUN; then
    say "  → DSH: добавил бы в $PATCH_FILE запись skill-filesystem с customSkillDirs: $SKILLS_DIR"
    exit 0
fi

lock_wait_limit="${IWE_DSH_LOCK_WAIT_SEC:-30}"
case "$lock_wait_limit" in
    ''|*[!0-9]*)
        echo "ERROR: IWE_DSH_LOCK_WAIT_SEC должен быть целым числом секунд, получено: '$lock_wait_limit'" >&2
        exit 1 ;;
esac

mkdir -p "$DSH_HOME_DIR"

# Two updates at once must not both back up and append: one holds the lock, the
# other waits (bounded) and then sees the finished entry. mkdir is the atomic
# step; only a lock this process created is ever removed (rmdir, never rm -rf).
LOCK_DIR="$PATCH_FILE.lock"
LOCK_HELD=false
TMP_FILE=""
cleanup() {
    [ -z "$TMP_FILE" ] || rm -f "$TMP_FILE"
    if $LOCK_HELD; then rmdir "$LOCK_DIR" 2>/dev/null || true; fi
}
trap cleanup EXIT

waited=0
while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    # mkdir failed for another reason (read-only directory): waiting would not
    # help and "busy" would be the wrong diagnosis. The directory, not the lock,
    # is checked: another run may remove its lock between our mkdir and here.
    if { [ -e "$LOCK_DIR" ] || [ -L "$LOCK_DIR" ]; } && [ ! -d "$LOCK_DIR" ]; then
        echo "ERROR: DSH: на месте замка $LOCK_DIR лежит не каталог — уберите его и повторите." >&2
        exit 2
    fi
    if [ ! -d "$LOCK_DIR" ] && [ ! -w "$(dirname "$LOCK_DIR")" ]; then
        echo "ERROR: DSH: не удалось создать замок $LOCK_DIR (нет прав на запись в $(dirname "$LOCK_DIR")?)." >&2
        exit 2
    fi
    if [ "$waited" -ge "$lock_wait_limit" ]; then
        echo "ERROR: DSH: файл $PATCH_FILE занят другим запуском (замок $LOCK_DIR не снялся за ${lock_wait_limit} с)." >&2
        echo "       Если другого обновления нет, удалите пустой каталог замка и повторите: rmdir $LOCK_DIR" >&2
        exit 2
    fi
    sleep 1
    waited=$((waited + 1))
done
LOCK_HELD=true

# The state may have changed while we waited for the lock.
evaluate_state
if report_final_state; then
    exit 0
fi

# Build the new content next to the target and move it over in one step, so a
# reader (or a crash) never sees a half-written patch layer.
TMP_FILE=$(mktemp "$PATCH_FILE.tmp.XXXXXX")
if [ -f "$PATCH_FILE" ]; then
    cp "$PATCH_FILE" "$PATCH_FILE.bak-iwe-skills"
    cp -p "$PATCH_FILE" "$TMP_FILE"   # keeps the owner's permissions
    # A file without a trailing newline would swallow the new entry's first line.
    if [ -s "$TMP_FILE" ] && [ -n "$(tail -c 1 "$TMP_FILE")" ]; then
        printf '\n' >> "$TMP_FILE"
    fi
else
    {
        printf '# DSH home-level patch layer: applies over every profile.\n'
        printf '# Managed by the IWE installer for the entry marked below.\n'
    } > "$TMP_FILE"
fi

SKILLS_DIR_YAML=$(skills_dir_yaml)
{
    printf '\n# %s: template skills live in .claude/skills, DSH does not look there.\n' "$MARKER"
    printf '# Entry appended by setup/install-dsh-skills.sh; keep it as the only\n'
    printf '# customSkillDirs source for skill-filesystem in this installation.\n'
    printf -- '- id: skill-filesystem\n'
    printf '  config:\n'
    printf '    customSkillDirs:\n'
    printf '      - %s\n' "$SKILLS_DIR_YAML"
} >> "$TMP_FILE" || {
    echo "ERROR: не удалось записать $PATCH_FILE" >&2
    exit 2
}

if ! grep -qxF "      - $SKILLS_DIR_YAML" "$TMP_FILE" 2>/dev/null; then
    echo "ERROR: запись не появилась в $PATCH_FILE" >&2
    exit 2
fi

mv "$TMP_FILE" "$PATCH_FILE" || {
    echo "ERROR: не удалось записать $PATCH_FILE" >&2
    exit 2
}
TMP_FILE=""

say "  ✓ DSH: навыки шаблона подключены ($PATCH_FILE → $SKILLS_DIR)."
say "    Перезапустите окно DSH, чтобы навыки появились в каталоге сессии."
