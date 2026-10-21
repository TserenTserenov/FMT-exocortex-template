#!/usr/bin/env bash
# routing: migration  one-time=true
# see DP.SC.159, DP.ROLE.059
# memory-migrate.sh — adding missing frontmatter-fields (WP-217 Phase10.2/Phase10.4)
#
# Adds fields schema_version/horizon/domains/status/owner to existing files.
# Does NOT overwrite fields, that already exist.
# Determines type/horizon/domains automatically based on the file name.
# issue #1147: assignment horizon: hot is checked against the HOT budget HOT
# (≤150 lines total, memory-lifecycle-spec.md §4) BEFORE any write — if
# exceeded the migration stops with a list of candidates and writes nothing, writes nothing;
# valid_from is taken from metadata.modified / mtime file, not from the run date.
#
# Usage:
#   bash scripts/memory-migrate.sh memory/file.md         # single file
#   bash scripts/memory-migrate.sh --all                  # all memory/*.md
#   bash scripts/memory-migrate.sh --dry-run --all        # show without making changes
#   bash scripts/memory-migrate.sh --from 1 --to 2 file   # future schema migration
#
# Spec: memory/memory-lifecycle-spec.md §8 (WP-217 Phase10.1)

set -eu

# Load unified environment: WORKSPACE_DIR, IWE_ROOT, IWE_SCRIPTS, etc.
# NOTE: iwe-env-bootstrap.sh reassigns SCRIPT_DIR to its OWN location (via its
# BASH_SOURCE[0]) as a side effect of being sourced — save ours first so the
# frontmatter.sh source below still resolves relative to THIS script (issue #229).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_MEMORY_MIGRATE_DIR="$SCRIPT_DIR"
source "$SCRIPT_DIR/../.claude/lib/iwe-env-bootstrap.sh" || exit 1
# issue #658: was a private get_field() unaware of the `metadata:`-nested
# frontmatter dialect (issue #281) — every already-nested scalar field
# (type/horizon/status/owner/valid_from/...) read back as empty, which made
# the migration below think the field was missing and propose a filename-
# guessed flat duplicate on top of the real value. Sourcing the shared
# reader fixes scalar fields. issue #1147: `domains:` as a columnar YAML
# list (`- item` lines) is parsed by frontmatter.sh too, so a nested
# columnar list no longer triggers a flat duplicate either.
source "$_MEMORY_MIGRATE_DIR/../.claude/lib/frontmatter.sh" || exit 1
MEMORY_DIR="$IWE_ROOT/memory"
DRY_RUN=0
ALL=0
FROM_VER=""
TO_VER=""
TARGET=""
EXCLUDE="MEMORY.md"

# issue #1147: budget HOT — memory-lifecycle-spec.md §4 (axis 2: horizon)
# limits the total body size of all hot-files 150 lines. Migration
# must check the budget BEFORE writing, and not inflate HOT HOT based on the file name.
HOT_LIMIT_LINES=150

# Body lines of the file (after the closing ---) are what actually gets loaded (after the closing ---) — what, what is actually loaded.
# f<2: line "---" INSIDE the body (horizontal separator markdown) does not
# count as a frontmatter separator frontmatter and is not excluded from the count (cold-review).
body_lines() {
    awk '/^---/ && f<2{f++; next} f>=2{print}' "$1" | wc -l | tr -d ' '
}

# Sum of body lines of all files with horizon: hot in MEMORY_DIR (we read the actual value,
# not the declared value): horizon — from frontmatter, lines — from the file body.
hot_total_lines() {
    local total=0 f n skip exc
    for f in "$MEMORY_DIR"/*.md; do
        [ -f "$f" ] || continue
        n=$(basename "$f"); skip=0
        for exc in $EXCLUDE; do [ "$n" = "$exc" ] && skip=1 && break; done
        [ $skip -eq 1 ] && continue
        [ "$(get_field "$f" "horizon")" = "hot" ] || continue
        total=$((total + $(body_lines "$f")))
    done
    echo "$total"
}

# Strict validation YYYY-MM-DD without dependency on the date dialect date (GNU -d / BSD -j).
validate_ymd() {
    date -d "$1" >/dev/null 2>&1 && return 0
    date -j -f "%Y-%m-%d" "$1" >/dev/null 2>&1 && return 0
    return 1
}

# issue #1147: valid_from = date the fact appeared, not the date the migration was run.
# Chain: metadata.modified (normalization to YYYY-MM-DD) → mtime file →
# today. We do not substitute an invalid value — we continue along the chain.
infer_valid_from() {
    local file="$1" v
    v=$(get_field "$file" "modified" 2>/dev/null || true)
    v=$(printf '%s' "$v" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1 || true)
    if [ -n "$v" ] && validate_ymd "$v"; then echo "$v"; return 0; fi
    # mtime: GNU stat -c, then BSD stat -f (order as in canon-dirty-snapshot.sh)
    v=$(stat -c %y "$file" 2>/dev/null | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}' || true)
    [ -n "$v" ] || v=$(stat -f %Sm -t %Y-%m-%d "$file" 2>/dev/null || true)
    if [ -n "$v" ] && validate_ymd "$v"; then echo "$v"; return 0; fi
    date +%Y-%m-%d
}

while [ $# -gt 0 ]; do
    case "$1" in
        --all)      ALL=1; shift ;;
        --dry-run)  DRY_RUN=1; shift ;;
        --from)     FROM_VER="$2"; shift 2 ;;
        --to)       TO_VER="$2"; shift 2 ;;
        --dir)      MEMORY_DIR="$2"; shift 2 ;;
        -h|--help)
            grep '^#' "$0" | head -18
            exit 0
            ;;
        *.md) TARGET="$1"; shift ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

has_frontmatter() {
    head -1 "$1" | grep -q '^---$'
}

# Generate name from the file name
infer_name() {
    local name="$1"
    local stem="${name%.md}"
    case "$stem" in
        feedback_behaviour*)    echo "Feedback: agent behavior" ;;
        feedback_architecture*) echo "Feedback: architecture and code" ;;
        feedback_writing*)      echo "Feedback: writing and publications" ;;
        feedback_governance*)   echo "Feedback: governance" ;;
        feedback_neon*)         echo "Lesson: Neon pooler and LISTEN/NOTIFY" ;;
        feedback_railway*)      echo "Lesson: Railway — project creation" ;;
        feedback_quantum*)      echo "Lesson: trigger Quantum-like analysis" ;;
        feedback_*)
            local short="${stem#feedback_}"
            short="${short//_/ }"
            echo "Feedback: $short"
            ;;
        project_*)
            local short="${stem#project_}"
            short="${short//_/ }"
            echo "Project: $short"
            ;;
        reference_*)
            local short="${stem#reference_}"
            short="${short//_/ }"
            echo "Reference: $short"
            ;;
        user_*)
            local short="${stem#user_}"
            short="${short//_/ }"
            echo "Profile: $short"
            ;;
        lessons_*)
            local short="${stem#lessons_}"
            short="${short//_/ }"
            echo "Lessons: $short"
            ;;
        protocol-*)
            local short="${stem#protocol-}"
            short="${short//-/ }"
            echo "Protocol: $short"
            ;;
        *-spec)
            local short="${stem%-spec}"
            echo "Specification: $short"
            ;;
        *)
            echo "${stem//_/ }"
            ;;
    esac
}

# Generate description from the file name
infer_description() {
    local stem="${1%.md}"
    case "$stem" in
        feedback_*) echo "Feedback rules — guidance for future sessions" ;;
        project_*)  echo "Project initiative context — goals, status, decisions" ;;
        reference_*) echo "Reference information for an external system or resource" ;;
        user_*)     echo "User profile — for personalizing interaction" ;;
        lessons_*)  echo "Accumulated lessons on the topic — patterns and anti-patterns" ;;
        protocol-*) echo "IWE protocol — step-by-step instructions for the ritual" ;;
        *-spec*)    echo "Specification — formal description of the system or protocol" ;;
        *)          echo "IWE operational memory file IWE" ;;
    esac
}

# Determine type from the file name
infer_type() {
    local name="$1"
    case "$name" in
        feedback_*)  echo "feedback" ;;
        project_*)   echo "project" ;;
        reference_*) echo "reference" ;;
        user_*)      echo "user" ;;
        lessons_*)   echo "lesson" ;;
        protocol-*)  echo "protocol" ;;
        *-spec.md)   echo "protocol" ;;
        r-questionnaire*|t-checklist*|checklists*|templates-*|dry-run*) echo "protocol" ;;
        *)           echo "reference" ;;
    esac
}

# Determine horizon by type
infer_horizon() {
    local type="$1" name="$2"
    case "$type" in
        user)     echo "hot" ;;
        feedback)
            # Active feedback → hot, archived → warm
            case "$name" in
                *_archive*) echo "warm" ;;
                *)           echo "hot" ;;
            esac
            ;;
        project)  echo "warm" ;;
        reference) echo "warm" ;;
        lesson)   echo "warm" ;;
        protocol) echo "warm" ;;
        *)        echo "warm" ;;
    esac
}

# Determine domains from the file name
infer_domains() {
    local name="$1"
    case "$name" in
        feedback_behaviour*)   echo "[behaviour]" ;;
        feedback_architecture*) echo "[architecture]" ;;
        feedback_writing*)     echo "[writing]" ;;
        feedback_governance*)  echo "[protocol]" ;;
        feedback_neon*|feedback_railway*|feedback_cloudflare*) echo "[infrastructure]" ;;
        feedback_*cutover*|feedback_*release*|feedback_*deploy*) echo "[architecture, infrastructure]" ;;
        feedback_*)            echo "[behaviour]" ;;
        project_*)             echo "[project-iwe]" ;;
        reference_neon*)       echo "[infrastructure, neon]" ;;
        reference_railway*)    echo "[infrastructure, railway]" ;;
        reference_cloudflare*) echo "[infrastructure, cloudflare]" ;;
        reference_github*)     echo "[infrastructure, git]" ;;
        reference_ory*)        echo "[infrastructure]" ;;
        reference_*)           echo "[reference]" ;;
        user_*)                echo "[user-profile]" ;;
        lessons_infra*)        echo "[infrastructure]" ;;
        lessons_tools*)        echo "[infrastructure]" ;;
        lessons_*)             echo "[behaviour]" ;;
        protocol-*)            echo "[protocol]" ;;
        *-spec.md)             echo "[protocol, memory]" ;;
        *)                     echo "[reference]" ;;
    esac
}

migrate_file() {
    local file="$1"
    local name
    name=$(basename "$file")

    if ! has_frontmatter "$file"; then
        echo "SKIP $name — no frontmatter, add frontmatter manually first" >&2
        return 1
    fi

    # Collecting current fields
    cur_type=$(get_field "$file" "type")
    cur_horizon=$(get_field "$file" "horizon")
    cur_domains=$(get_field "$file" "domains")
    cur_status=$(get_field "$file" "status")
    cur_owner=$(get_field "$file" "owner")
    cur_schema=$(get_field "$file" "schema_version")
    cur_name=$(get_field "$file" "name")
    cur_desc=$(get_field "$file" "description")
    cur_valid_from=$(get_field "$file" "valid_from")

    # Determining defaults
    new_type="${cur_type:-$(infer_type "$name")}"
    new_horizon="${cur_horizon:-$(infer_horizon "$new_type" "$name")}"
    new_domains="${cur_domains:-$(infer_domains "$name")}"
    new_status="${cur_status:-active}"
    new_owner="${cur_owner:-user}"
    new_schema="${cur_schema:-1}"
    new_name="${cur_name:-$(infer_name "$name")}"
    new_desc="${cur_desc:-$(infer_description "$name")}"
    new_valid_from="${cur_valid_from:-$(infer_valid_from "$file")}"

    # issue #1147: assignment hot is checked against the budget BEFORE writing
    # (single file and --all write pass --all go through the same check;
    # the total of files already migrated in this run is accounted for, because hot_total_lines, i.e. hot_total_lines
    # re-reads the files). Rejection = nothing is written.
    if [ -z "$cur_horizon" ] && [ "$new_horizon" = "hot" ]; then
        hot_now=$(hot_total_lines)
        projected=$((hot_now + $(body_lines "$file")))
        if [ "$projected" -gt "$HOT_LIMIT_LINES" ]; then
            echo "REFUSE $name — horizon: hot would push HOT over the limit of $HOT_LIMIT_LINES lines (currently $hot_now, would become $projected; memory-lifecycle-spec.md §4). Lower the horizon of the file or reduce the existing HOT." >&2
            return 1
        fi
    fi

    # If nothing needs to be added — skip
    if [ -n "$cur_type" ] && [ -n "$cur_horizon" ] && [ -n "$cur_domains" ] \
       && [ -n "$cur_status" ] && [ -n "$cur_owner" ] && [ -n "$cur_schema" ] \
       && [ -n "$cur_name" ] && [ -n "$cur_desc" ] && [ -n "$cur_valid_from" ]; then
        echo "OK   $name — already complete frontmatter"
        return 0
    fi

    if [ $DRY_RUN -eq 1 ]; then
        echo "DRY  $name"
        [ -z "$cur_type" ]       && echo "     + type: $new_type"
        [ -z "$cur_horizon" ]    && echo "     + horizon: $new_horizon"
        [ -z "$cur_domains" ]    && echo "     + domains: $new_domains"
        [ -z "$cur_status" ]     && echo "     + status: $new_status"
        [ -z "$cur_owner" ]      && echo "     + owner: $new_owner"
        [ -z "$cur_schema" ]     && echo "     + schema_version: $new_schema"
        [ -z "$cur_name" ]       && echo "     + name: $new_name"
        [ -z "$cur_desc" ]       && echo "     + description: $new_desc"
        [ -z "$cur_valid_from" ] && echo "     + valid_from: $new_valid_from"
        return 0
    fi

    # Build new frontmatter
    # Read the file body (without frontmatter); f<2: line "---" inside the body —
    # not a delimiter, such lines must not be dropped from the file (cold-review).
    body=$(awk '/^---/ && f<2{f++; next} f>=2{print}' "$file")

    # Existing fields frontmatter (without ---)
    existing_fm=$(awk '/^---/ && f<2{f++; next} f==1{print}' "$file")

    # Append missing fields at the end frontmatter
    additions=""
    [ -z "$cur_type" ]       && additions="$additions\ntype: $new_type"
    [ -z "$cur_horizon" ]    && additions="$additions\nhorizon: $new_horizon"
    [ -z "$cur_domains" ]    && additions="$additions\ndomains: $new_domains"
    [ -z "$cur_status" ]     && additions="$additions\nstatus: $new_status"
    [ -z "$cur_owner" ]      && additions="$additions\nowner: $new_owner"
    [ -z "$cur_schema" ]     && additions="$additions\nschema_version: $new_schema"
    [ -z "$cur_name" ]       && additions="$additions\nname: \"$new_name\""
    [ -z "$cur_desc" ]       && additions="$additions\ndescription: \"$new_desc\""
    [ -z "$cur_valid_from" ] && additions="$additions\nvalid_from: $new_valid_from"

    # Write the updated file
    {
        echo "---"
        echo "$existing_fm"
        printf "%b" "$additions"
        echo ""
        echo "---"
        printf "%s" "$body"
    } > "$file"

    echo "DONE $name"
}

# Main loop
# cold-review #1147 (round 3): two concurrent runs could both see
# remaining HOT budget HOT and overwrite the same files via `> "$file"` — risk of corruption,
# not only budget overrun. Shared mkdir-lock for the entire run (check
# budget + write). The lock is NEVER removed automatically: any scheme
# «check staleness, then rm» leaves a window, where another fresh lock gets deleted
# lock (the same finding, as in protocol-stop-gate #1184). Busy → fail with
# manual cleanup instructions; the lock is released only by trap EXIT creator.
MIGRATE_LOCK="$MEMORY_DIR/.migrate.lock"
if ! mkdir "$MIGRATE_LOCK" 2>/dev/null; then
    lock_pid=$(cat "$MIGRATE_LOCK/pid" 2>/dev/null || true)
    echo "FAILURE: another run memory-migrate holds the lock $MIGRATE_LOCK (pid ${lock_pid:-unknown})." >&2
    echo "If that run crashed — verify, that the process is no longer alive (kill -0 ${lock_pid:-PID}), and remove the lock directory manually." >&2
    exit 1
fi
echo "$$" > "$MIGRATE_LOCK/pid" 2>/dev/null || true
trap 'rm -rf "$MIGRATE_LOCK" 2>/dev/null || true' EXIT

if [ $ALL -eq 1 ]; then
    # Pass 1 (without writing, issue #1147): budget HOT is checked against the ENTIRE set
    # before any write — otherwise a failure midway would have produced a partial migration.
    # Total = body lines of existing hot-files + body lines of files, that will be assigned
    # this migration will assign hot (horizon is absent and infer_horizon = hot).
    hot_base=$(hot_total_lines)
    cand_lines=0
    candidates=""
    # Names with spaces/newlines must not be lost: iteration via NUL
    # (process substitution, not pipeline — otherwise counters in subshell).
    while IFS= read -r -d '' f; do
        [ -f "$f" ] || continue
        n=$(basename "$f"); skip=0
        for exc in $EXCLUDE; do [ "$n" = "$exc" ] && skip=1 && break; done
        [ $skip -eq 1 ] && continue
        has_frontmatter "$f" || continue
        [ -z "$(get_field "$f" "horizon")" ] || continue
        cand_type=$(get_field "$f" "type")
        [ -n "$cand_type" ] || cand_type=$(infer_type "$n")
        [ "$(infer_horizon "$cand_type" "$n")" = "hot" ] || continue
        candidates="$candidates  $n\n"
        cand_lines=$((cand_lines + $(body_lines "$f")))
    done < <(find "$MEMORY_DIR/" -maxdepth 1 -name "*.md" -print0)
    projected_total=$((hot_base + cand_lines))
    if [ "$projected_total" -gt "$HOT_LIMIT_LINES" ]; then
        echo "STOP: migration would push HOT over the limit of HOT over the limit of $HOT_LIMIT_LINES lines (memory-lifecycle-spec.md §4)." >&2
        echo "Currently in HOT: $hot_base lines; candidates would add $cand_lines (total $projected_total). Nothing has been written." >&2
        echo "Candidates for hot — lower the horizon or trim the files, then retry:" >&2
        printf "%b" "$candidates" >&2
        exit 1
    fi

    changed=0; skipped=0; ok=0
    while IFS= read -r -d '' f; do
        [ -f "$f" ] || continue
        n=$(basename "$f"); skip=0
        for exc in $EXCLUDE; do [ "$n" = "$exc" ] && skip=1 && break; done
        [ $skip -eq 1 ] && continue
        result=$(migrate_file "$f" 2>&1)
        echo "$result"
        echo "$result" | grep -q "^DONE" && changed=$((changed+1)) || true
        echo "$result" | grep -q "^OK"   && ok=$((ok+1)) || true
        echo "$result" | grep -q "^SKIP" && skipped=$((skipped+1)) || true
    done < <(find "$MEMORY_DIR/" -maxdepth 1 -name "*.md" -print0)
    echo ""
    [ $DRY_RUN -eq 1 ] && echo "Dry-run complete" || echo "Summary: changed=$changed, already complete=$ok, skipped=$skipped"
elif [ -n "$TARGET" ]; then
    migrate_file "$TARGET"
else
    echo "Specify a file or --all" >&2
    exit 1
fi
