#!/usr/bin/env bash
# routing: utility  deterministic=true
# see Backlog B-005 (Week Close §5b helper)
# pending-phases-sweep.sh — iterates over active WP-context files and outputs pending phases
#
# Usage:
#   bash pending-phases-sweep.sh                  # iterate over active WPs in DS-strategy/inbox/
#   bash pending-phases-sweep.sh --all            # include files without status
#   bash pending-phases-sweep.sh --repo <path>    # specify a different governance-repo
#
# Supported phase formats:
#   | Phase1 | description | pending |
#   - [ ] Phase1: description
#   ## Phase1: description   (heading of any level 2-6, number — any suffix:
#                       Phase10.5, Phase7b, Phase2a, "Phase0. Text")
#
# A heading on its own — only a phase candidate, not a source of errors.
# Checklist-status: "[ ]" = pending, "[x]"/"[X]" = closed, any other
# non-empty content ("[~]", emoji-markers) = also "not ready" — real
# the repository uses these notations throughout. UNSUPPORTED is emitted
# only for genuinely unrecognizable — empty brackets "[]" in
# checklist. A bare heading without a table body or a nearby checkbox
# (a log entry of a past event, retrospective) is not counted as a phase
# at all and is silently ignored — issue #458 a live run on real
# inbox/ found hundreds of false UNSUPPORTED under stricter versions
# (headings only 3 level, only a purely numeric number, any line
# "PhaseN..." was counted as a candidate, only "[ ]"/"[x]"/"[X]" as valid
# checkboxes), which made the sweep practically useless on real data
# of the repository. Final version: 378 pending-phases, 0 false positives on
# 91 cards.
#
# issue #541 (regression #458, found in external review 26.08.2026): "### PhaseN"
# a heading with a body consisting of several items — an unclosed "- [ ]" anywhere
# inside a section is now unconditionally counted as pending, even if in the heading
# already has "✅ DONE" or nearby there is another already closed "[x]"-item. Previously
# any "closed"-word in the section suppressed pending permanently pending permanently (one-shot
# latch) — real cards regularly mix closed items with one
# forgotten in the same section, real-world example: WP-529 "### Phase2 — ... ✅ DONE" with
# unclosed "- [ ] Acceptance-criterion" inside.
#
# Output: for each active WP with pending-phases — heading + list of phases
#
# Compatibility: macOS bash 3.2 (without mapfile, without assoc-arrays)

set -uo pipefail

IWE="${IWE_WORKSPACE:-$HOME/IWE}"
GOV_REPO="${IWE_GOVERNANCE_REPO:-DS-strategy}"
INBOX_DIR="$IWE/$GOV_REPO/inbox"

include_all=false
custom_repo=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --all) include_all=true; shift ;;
        --repo) custom_repo="$2"; shift 2 ;;
        -h|--help)
            sed -n '1,/^$/p' "$0" | grep -E '^#' | sed 's/^# *//'
            exit 0
            ;;
        *)
            echo "Unknown arg: $1" >&2
            exit 1
            ;;
    esac
done

[[ -n "$custom_repo" ]] && INBOX_DIR="$custom_repo/inbox"

if [[ ! -d "$INBOX_DIR" ]]; then
    echo "[ERROR] Inbox directory not found: $INBOX_DIR" >&2
    exit 1
fi

tmp_wp_list=$(mktemp)
tmp_active_list=$(mktemp)
trap "rm -f '$tmp_wp_list' '$tmp_active_list'" EXIT

find "$INBOX_DIR" -maxdepth 2 -name "WP-*.md" -type f 2>/dev/null | sort > "$tmp_wp_list"

if [[ ! -s "$tmp_wp_list" ]]; then
    echo "No WP-*.md files in $INBOX_DIR"
    exit 0
fi

while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    status_line=$(grep -m1 -iE "^status:" "$f" 2>/dev/null || true)
    if echo "$status_line" | grep -qiE "in_progress|active|in-progress"; then
        echo "$f" >> "$tmp_active_list"
    elif [[ "$include_all" == "true" && -z "$status_line" ]]; then
        echo "$f" >> "$tmp_active_list"
    fi
done < "$tmp_wp_list"

if [[ ! -s "$tmp_active_list" ]]; then
    echo "No active WP-* files (status: in_progress) in $INBOX_DIR"
    [[ "$include_all" != "true" ]] && echo "Run with --all to include files without an explicit status status"
    exit 0
fi

total_wp=0
total_pending=0
format_error=0

while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    wp_name=$(basename "$f" .md)

    if ! scan_output=$(
        awk '
            function trim(s) {
                sub(/^[[:space:]]+/, "", s)
                sub(/[[:space:]]+$/, "", s)
                return s
            }

            function unbold(s) {
                gsub(/\*\*/, "", s)
                return trim(s)
            }

            # Phase number — only the numeric part of the number (decimal point
            # between digits is allowed: "Phase10.5"). any suffix after the first
            # non-digit (letter, dot-as-punctuation, space) is discarded
            # BEFORE validation — issue #458: real numbers in the repository
            # contain letter suffixes (Phase7b, Phase2a) and the dot as an ordinary
            # punctuation mark before the next word ("Phase0. Text"), not
            # decimal numbering only.
            function phase_number(s,    n) {
                s = unbold(s)
                n = s
                sub(/^Phase/, "", n)
                sub(/^Phase[[:space:]]*/, "", n)
                # Keep leading digits and decimal digit groups; everything; everything
                # after the first character that is not a digit and not, that is not a digit and not "." before
                # a digit — discard.
                match(n, /^[0-9]+(\.[0-9]+)*/)
                return substr(n, RSTART, RLENGTH)
            }

            function phase_candidate(s) {
                s = unbold(s)
                return s ~ /^Phase[0-9]/ || s ~ /^Phase[[:space:]]*[0-9]/
            }

            function is_closed(s,    stripped) {
                # Word stems without endings — Russian text appears in
                # all genders/numbers ("closed (feminine)", "closed (neuter)", "closed (masculine)"), issue
                # #458 found in the wild: "Status: closed" did not match
                # the old exact word "closed". A boundary before the
                # stem ("^" or non-Cyrillic) — without it "Unclosed" (with
                # negating prefix "ne--") would also match as closed,
                # found by this same test for "- [ ] Unclosed item".
                #
                # WP-484 item M (01.09, peer-session with Kimi+Codex): two-letter
                # Cyrillic bracket-classes ([Vv], [Zz], [Oo], [Nn]) byte-
                # are unsafe — under LC_ALL=C (typical default cron/systemd without
                # explicit LANG) awk awk matches one byte instead of a 2-byte UTF-8 2-byte UTF-8
                # sequence, because of-which the subsequent literal portion
                # of the word does not align on byte boundaries and the word stops matching altogether
                # being detected (closed items falsely remain "pending").
                # Live test Codex: (^|[^a-yaioA-YAio])([Vv]ypolnen) under LC_ALL=C
                # gives 0, the same boundary with a literal alternation gives — 1 in both
                # locales. The outer boundary (^|[^a-yaioA-YAio]) on its own
                # byte-safe (range, not a two-character class) — retained.
                #
                # Additionally (found by the same live run on card WP-526,
                # "### Phase3 — ... the cleanup itself was not completed"): the separate "not
                # completed" is not protected by the original boundary ("not" separated
                # by a space -- a space is not Cyrillic, so the boundary passes -- and falsely — a space is not Cyrillic, the boundary matches) and falsely
                # was considered closed. [[:space:]]+ (not "*") is required — otherwise
                # "more relevant completed"/"sincerely completed" falsely matches
                # ("not" as a substring preceding a space inside another word) —
                # the boundary before "not" already eliminates that on its own (Cyrillic
                # immediately before "not" blocks it), "+" instead of "*" — second line
                # of defense for the zero-space case.
                #
                # The fused form ("NotCompleted") we do not check separately — it is already
                # protected by the original boundary before the root: "e" from "not" — itself
                # Cyrillic, the boundary before "closed"/"completed" does not match.
                # The explicit check for the fused form was present in the first version of the patch in this
                # session and turned out to be redundant (code review, 01.09) — removed.
                #
                # The split form cannot simply be discarded with an early "return 0":
                # that suppresses a genuine positive marker further along on THE SAME
                # line (found in code review 01.09: "Unclosed item, but
                # status Completed" falsely produced pending). Instead of an early-return early-return
                # we strip the detected negation via gsub and check the remainder gsub and check the remainder —
                # thus an independent positive-marker on the same line is not suppressed.
                if (s ~ /✅|\[[xX]\]|[Dd]one|[Cc]ompleted|[Cc]omplete|[Cc]ancelled|[Cc]anceled|[Ss]kipped|[Bb]locked/) return 1
                stripped = s
                gsub(/(^|[^a-yaeyoA-YaYo])(Not|not)[[:space:]]+(Completed|completed|Finished|finished|Closed|closed|Cancelled|cancelled)/, " ", stripped)
                return stripped ~ /(^|[^a-yaeyoA-YaYo])(Completed|completed|Finished|finished|Closed|closed|Cancelled|cancelled)/
            }

            function is_pending(s) {
                return s ~ /⏳|⏸|[Pp]ending|Awaiting|awaiting|Awaiting|awaiting/
            }

            function header_level(s, hashes) {
                hashes = s
                sub(/[^#].*$/, "", hashes)
                return length(hashes)
            }

            function header_text(s) {
                sub(/^#+[[:space:]]+/, "", s)
                return trim(s)
            }

            function phase_description(s) {
                s = unbold(s)
                # "—" (em dash, U+2014) — a common separator between the number and
                # the phase description in real headings ("Phase3b — text"), but
                # does not belong to the class [:space:]:- — without an explicit exclusion
                # it would remain at the start of the description and be doubled with the dash,
                # which the script itself adds on output ("Phase3 — — text"),
                # detected by this same test.
                sub(/^[^[:space:]:—-]+[[:space:]:—-]*/, "", s)
                return trim(s)
            }

            function emit_section() {
                # An open checkbox — a structural fact, not an opinion. The word
                # "done"/"closed" ANYWHERE in the same section (in the heading,
                # in the summary prose, in a NEIGHBORING already-checked "[x]"-item) must not
                # suppress it: issue #541 (regression #458) — real
                # cards regularly mix inside a single "### PhaseN" section already
                # closed items and one forgotten "- [ ]" nearby, or else
                # the phase heading receives "✅ DONE" earlier, than actually
                # the last checkbox is cleared. section_closed was previously. section_closed was previously
                # a one-shot latch for the entire section — the only
                # found "closed" anywhere would override any later
                # later found "- [ ]". section_open_checkbox — the second,
                # a stronger piece of evidence, which is not suppressed by section_closed.
                if (section_open && (section_open_checkbox || (section_pending && !section_closed))) {
                    print "PENDING\t" section_phase "\t" section_desc
                }
                section_open = 0
                section_pending = 0
                section_closed = 0
                section_open_checkbox = 0
                section_phase = ""
                section_desc = ""
            }

            {
                line = $0

                # The PhaseN sectionN-heading (any level 2-6) ends at
                # the next heading of the same or higher level.
                # The heading by itself — only a CANDIDATE: it opens
                # a section, if it carries a recognizable number, but UNSUPPORTED
                # is not emitted immediately — only if a structural signal is found inside the section
                # structural signal of being open/closed, which could not be
                # parsed. A bare heading with no table body. A bare heading with no table body
                # or checkbox (journal entry, retrospective) simply
                # does not open a phase section with a pending or closed status pending/closed status —
                # silently ignored, as before for unrecognized lines.
                if (line ~ /^#{2,6}[[:space:]]+/) {
                    level = header_level(line)
                    title = header_text(line)
                    is_new_phase = phase_candidate(title)

                    # Close the current section either on a heading of the same or higher/higher
                    # level without a phase number (ordinary subheading
                    # such as "### Criterion" inside "## Phase1"), or on a heading
                    # WITH A DIFFERENT recognized phase number REGARDLESS of
                    # level — issue #458, found by this same test: "###
                    # Phase2 (~2.5h)" (level 3) inside the not yet closed "## Phase1"
                    # (level 2) must close Phase1 and open Phase2, and not
                    # remain "deeper" and silently disappear together with Phase1 —
                    # real WP cards freely mix heading levels
                    # between phases.
                    if (section_open && (level <= section_level ||
                        (is_new_phase && phase_number(title) != section_phase))) {
                        emit_section()
                    }

                    if (is_new_phase) {
                        section_open = 1
                        section_level = level
                        section_phase = phase_number(title)
                        section_desc = phase_description(title)
                        section_pending = is_pending(line)
                        section_closed = is_closed(line)
                        section_open_checkbox = 0
                    }
                    next
                }

                if (section_open) {
                    if (is_closed(line)) {
                        section_closed = 1
                    }
                    if (is_pending(line)) {
                        section_pending = 1
                    }
                    # An unchecked checkbox inside the section body — is also a signal
                    # of incompleteness, even without the word "pending" nearby.
                    # issue #458, found by this same test: "### Phase2 (~2.5h)"
                    # with body "- [ ] Unchecked item" was not found at all
                    # — section_pending remained false, because the checkbox
                    # on its own did not match is_pending().
                    #
                    # Deliberate trade-off (issue #541 cold-review): a line,
                    # THAT QUOTED the checkbox syntax as documentation
                    # ("Example: `- [ ] item`") inside a genuinely closed section,
                    # also matches this regex and produces a false pending pending — to distinguish
                    # a quote from the current item with a line-by-line parser without
                    # parsing fenced-fenced blocks is not possible. Left intentionally: the cost of
                    # a rare false «check this» is lower than the cost of silently
                    # swallowing a real pending-item — Fixture 7 in
                    # test_pending_phases_sweep.sh test_pending_phases_sweep.sh records this behaviour as
                    # expected, not as a bug for a silent fix.
                    if (line ~ /^[[:space:]]*[-*+][[:space:]]+\[[[:space:]]\][[:space:]]+/) {
                        section_pending = 1
                        section_open_checkbox = 1
                    }
                }

                # Format 1: row markdown-table. Phase can only be
                # a standalone first cell PhaseN / **PhaseN**. phase_candidate alreadyN / **PhaseN**. phase_candidate already
                # requires a digit immediately after Phase -- phase_number() from the same "Phase" — phase_number() from the same
                # cell will reliably find at least that digit, therefore, therefore
                # a separate check for "number not recognised" does not occur here
                # (unreachable branch was removed — issue #458 review).
                if (line ~ /^[[:space:]]*\|/) {
                    cell_count = split(line, cells, /\|/)
                    phase_cell = unbold(cells[2])

                    if (phase_candidate(phase_cell)) {
                        if (is_pending(line) && !is_closed(line)) {
                            description = unbold(cells[3])
                            print "PENDING\t" phase_number(phase_cell) "\t" description
                        }
                    }
                    next
                }

                # Format 2: checklist. An unchecked phase is pending pending by default;
                # a closing marker in the text takes priority.
                if (line ~ /^[[:space:]]*[-*+][[:space:]]+/) {
                    list_text = line
                    sub(/^[[:space:]]*[-*+][[:space:]]+/, "", list_text)

                    # "- PhaseN text" without square brackets at all — a plain
                    # list line (enumeration of triggers, references to
                    # phases in prose), not an attempt to describe the phase itself as a
                    # checklist-item. UNSUPPORTED is appropriate only when
                    # the author already tried to write a checkbox (there is a bracket at the very (there is "[" at the very
                    # beginning of the item text) next to something that looks like a phase number
                    # — issue #458, found by live run: "- Phase7b
                    # Laboratory: ..." (trigger list WP-151) falsely
                    # was considered a broken checklist-checklist item of the phase.
                    if (list_text ~ /^\[/) {
                        # phase_token is computed from the text AFTER the checkbox,
                        # not from the entire line — otherwise phase_token would have become
                        # the character itself "[" (first delimiter — space
                        # inside "[ ]"), and not a single valid checklist-item
                        # would not have been recognized at all (found by this same test
                        # on the first run: "- [ ] Phase2: Not ready" silently
                        # was ignored).
                        after_box = list_text
                        sub(/^\[[^]]*\][[:space:]]+/, "", after_box)
                        phase_token = after_box
                        sub(/[[:space:]:-].*$/, "", phase_token)

                        # phase_candidate already requires a digit immediately after "Phase"
                        # — the number is guaranteed to be recognized here. The
                        # checkbox: "[x]"/"[X]" = closed (skipped), "[ ]"
                        # (space) = pending. Any OTHER non-empty
                        # content ("[~]", "[🔄]", "[⏸]") — also has status "not
                        # ready" (in progress/partial/on hold), actually
                        # used in the repository — issue #458, found
                        # by a run on real inbox/: 24+ instances "[~]" and
                        # emoji-status markers, all were incorrectly flagged
                        # as UNSUPPORTED. "[^]]" (any character except "]"),
                        # not "." — some emoji-markers are multiple
                        # Unicode code points (e.g. "↗️" = arrow +
                        # variation selector), "." matches only one,
                        # found by this same test. UNSUPPORTED remains for
                        # empty brackets "[]".
                        if (phase_candidate(phase_token)) {
                            if (list_text !~ /^\[[^]]+\][[:space:]]+/) {
                                print "UNSUPPORTED\t" NR "\tinvalid checklist-phase: " line
                                next
                            }

                            if (list_text !~ /^\[[xX]\]/ && !is_closed(line)) {
                                description = phase_description(after_box)
                                print "PENDING\t" phase_number(unbold(phase_token)) "\t" description
                            }
                        }
                    }
                    next
                }
            }

            END {
                emit_section()
            }
        ' "$f"
    ); then
        echo "[ERROR] Failed to parse $f" >&2
        format_error=1
        continue
    fi

    pending_count=0
    while IFS=$'\t' read -r kind field_a field_b; do
        [[ -z "$kind" ]] && continue

        case "$kind" in
            PENDING)
                if [[ $pending_count -eq 0 ]]; then
                    echo ""
                    echo "=== $wp_name: pending phases ==="
                fi
                [[ -n "$field_b" ]] || field_b="(no description)"
                echo "  Phase$field_a — $field_b"
                pending_count=$((pending_count + 1))
                ;;
            UNSUPPORTED)
                echo "[ERROR] $wp_name:$field_a — $field_b" >&2
                format_error=1
                ;;
        esac
    done <<< "$scan_output"

    if [[ $pending_count -gt 0 ]]; then
        total_pending=$((total_pending + pending_count))
        total_wp=$((total_wp + 1))
    fi
done < "$tmp_active_list"

active_count=$(wc -l < "$tmp_active_list" | tr -d ' ')

echo ""
echo "---"
if [[ $total_wp -eq 0 ]]; then
    echo "Pending phases not found in $active_count active WPs"
else
    echo "Total: $total_pending pending-phases in $total_wp active WPs (of $active_count reviewed)"
    echo "Resolution for each: (a) do next week. week → W+1; (b) re-evaluate (blocker/outdated); (c) keep with expected trigger"
fi

if [[ $format_error -ne 0 ]]; then
    echo "[ERROR] Unsupported structural phase format detected (table/checklist with unrecognized number); fix the WP markup WP and re-run sweep." >&2
    exit 2
fi
