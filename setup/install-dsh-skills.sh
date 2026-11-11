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
# Idempotent. If customSkillDirs is already configured (in the home layer or in
# any profile layer), the file is left untouched and the script says so: the
# user's own choice wins, and a second layer overriding it would be a surprise.
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
DSH_HOME_DIR="${DSH_HOME_ARG:-${DSH_HOME:-$HOME/.dsh}}"
DSH_HOME_DIR="${DSH_HOME_DIR/#\~/$HOME}"

SKILLS_DIR="$WORKSPACE_DIR/.claude/skills"
PATCH_FILE="$DSH_HOME_DIR/cordis.patch.yml"

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

if [ -f "$PATCH_FILE" ] && grep -qF "$MARKER" "$PATCH_FILE" 2>/dev/null; then
    say "  ✓ DSH: навыки шаблона уже подключены ($PATCH_FILE)."
    exit 0
fi

# Someone already configured customSkillDirs by hand — do not fight over it.
conflict=""
if [ -f "$PATCH_FILE" ] && grep -q 'customSkillDirs' "$PATCH_FILE" 2>/dev/null; then
    conflict="$PATCH_FILE"
fi
if [ -z "$conflict" ]; then
    for profile_patch in "$DSH_HOME_DIR"/profiles/*/cordis.patch.yml; do
        [ -f "$profile_patch" ] || continue
        if grep -q 'customSkillDirs' "$profile_patch" 2>/dev/null; then
            conflict="$profile_patch"
            break
        fi
    done
fi
if [ -n "$conflict" ]; then
    say "  ⚠ DSH: customSkillDirs уже задан ($conflict) — файл не меняю."
    say "    Чтобы подключить навыки шаблона, добавьте вручную: $SKILLS_DIR"
    exit 0
fi

if $DRY_RUN; then
    say "  → DSH: добавил бы в $PATCH_FILE запись skill-filesystem с customSkillDirs: $SKILLS_DIR"
    exit 0
fi

mkdir -p "$DSH_HOME_DIR"

if [ -f "$PATCH_FILE" ]; then
    cp "$PATCH_FILE" "$PATCH_FILE.bak-iwe-skills"
    # A file without a trailing newline would swallow the new entry's first line.
    if [ -s "$PATCH_FILE" ] && [ -n "$(tail -c 1 "$PATCH_FILE")" ]; then
        printf '\n' >> "$PATCH_FILE"
    fi
else
    {
        printf '# DSH home-level patch layer: applies over every profile.\n'
        printf '# Managed by the IWE installer for the entry marked below.\n'
    } > "$PATCH_FILE"
fi

{
    printf '\n# %s: template skills live in .claude/skills, DSH does not look there.\n' "$MARKER"
    printf '# Entry appended by setup/install-dsh-skills.sh; keep it as the only\n'
    printf '# customSkillDirs source for skill-filesystem in this installation.\n'
    printf -- '- id: skill-filesystem\n'
    printf '  config:\n'
    printf '    customSkillDirs:\n'
    printf '      - %s\n' "$SKILLS_DIR"
} >> "$PATCH_FILE" || {
    echo "ERROR: не удалось записать $PATCH_FILE" >&2
    exit 2
}

if ! grep -qF "$SKILLS_DIR" "$PATCH_FILE" 2>/dev/null; then
    echo "ERROR: запись не появилась в $PATCH_FILE" >&2
    exit 2
fi

say "  ✓ DSH: навыки шаблона подключены ($PATCH_FILE → $SKILLS_DIR)."
say "    Перезапустите окно DSH, чтобы навыки появились в каталоге сессии."
