#!/usr/bin/env bash
# extract-update-download-batch.sh — pulls download_batch(), verify_batch_
# integrity() and hash_file() out of update.sh via unique line-content
# markers (WP-546 Ф2, main commit 8112b1a).
#
# Same technique setup/test-update-edge-cases.sh T10 uses for update.sh's
# Step 5/6 fallback blocks, and scripts/tests/lib/extract-update-fetch-*
# used for the (now superseded) WP-546 Ф2 draft: a hand-retyped copy of
# these functions would silently diverge from the real code the moment
# someone edits update.sh without touching the test.
#
# Usage:
#   extract_update_hash_file <path-to-update.sh>            > hash_file.sh
#   extract_update_download_batch <path-to-update.sh>       > download_batch.sh
#   extract_update_verify_batch_integrity <path-to-update.sh> > verify_batch_integrity.sh
#   extract_update_retry_and_classify <path-to-update.sh>   > retry_and_classify.sh
extract_update_hash_file() {
    awk '
        /^hash_file\(\) \{$/ { found=1 }
        found { print }
        found && /^\}$/ { exit }
    ' "$1"
}

extract_update_download_batch() {
    awk '
        /^download_batch\(\) \{$/ { found=1 }
        found { print }
        found && /^\}$/ { exit }
    ' "$1"
}

extract_update_verify_batch_integrity() {
    awk '
        /^verify_batch_integrity\(\) \{$/ { found=1 }
        found { print }
        found && /^\}$/ { exit }
    ' "$1"
}

# The retry-queue + final per-file classification block (update.sh Step 2,
# "if [ ${#DOWNLOAD_QUEUE[@]} -gt 0 ]; then ... done" right before the
# trailing `printf "\n"`) — the glue between download_batch()/
# verify_batch_integrity() and SKIPPED_DOWNLOAD/NEW_FILES/UPDATED_FILES/
# UNCHANGED. Extracted separately because a bug can live in this glue even
# when both functions are individually correct (e.g. the retry queue built
# from the wrong array, or a file landing in the wrong bucket).
extract_update_retry_and_classify() {
    # Two sibling top-level constructs, not one nested block: the retry
    # `if [ ${#DOWNLOAD_QUEUE[@]} -gt 0 ]; then...fi`, immediately followed
    # by the classification `for _dq_i in ...; do...done`. Tracks
    # block-open (line ends in "then"/"do" — including elif, deliberately:
    # an elif shares its if's single closing fi, so counting elif as an
    # opener too keeps the running depth correct) vs block-close (trimmed
    # line is "fi"/"done", trailing whitespace tolerated) depth, and stops
    # the SECOND time depth unwinds back to 0 — once per construct.
    #
    # This line-content counting is inherently fragile to a *future* edit
    # of update.sh reshaping the block (a cold-context review flagged this:
    # an `elif` sharing its `if`'s single `fi` throws the running depth off
    # by one, and a broken/never-reconverging depth just keeps consuming
    # lines with no error — tried a "next line must be the known sentinel"
    # check first, but that only fires if depth ever DOES return to 0 a
    # second time; a mutation that leaves depth permanently unbalanced runs
    # to EOF without ever reaching that check at all — verified experimentally
    # both failure shapes with a deliberately mutated update.sh copy). A hard
    # line-count ceiling catches both shapes uniformly: the real block is 77
    # lines: markers-still-technically-matched-but-wrong-range extraction
    # reliably blows well past any reasonable multiple of that, so this
    # doesn't need to know exactly where the block should end, only that it
    # didn't run away.
    local out lines
    out=$(awk '
        /^if \[ \$\{#DOWNLOAD_QUEUE\[@\]\} -gt 0 \]; then$/ { found=1; depth=1; print; next }
        !found { next }
        {
            print
            line = $0
            sub(/^[ \t]+/, "", line)
            sub(/[ \t]+$/, "", line)
            is_closer = 0
            if (line == "fi" || line == "done") { depth--; is_closer = 1 }
            else if (line ~ /then$/ || line ~ /do$/) depth++
            # Only a fi/done that itself brings depth to 0 counts as a close
            # — depth otherwise SITS at 0 across blank/comment lines between
            # the two constructs, and counting every such line would exit
            # after the very next line instead of after the second construct.
            if (is_closer && depth == 0) {
                closes++
                if (closes == 2) exit
            }
        }
    ' "$1")
    lines=$(printf '%s\n' "$out" | wc -l)
    if [ "$lines" -gt 150 ]; then
        echo "extract_update_retry_and_classify: extracted $lines lines (expected ~77) — depth-tracking likely broke on an edited update.sh, refusing to hand back a wrong range" >&2
        return 1
    fi
    printf '%s\n' "$out"
}
