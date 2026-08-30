#!/bin/bash
# day-open-hooks.sh — shared bash-block extraction/execution for
# extensions/day-open.<hook>*.md (WP-529 Ф11).
#
# Same mechanism day-open-checks-runner.sh already uses for "checks" (WP-7
# Ф-DayOpen-Enforcement DOE2): each ```bash``` fenced block in a matching
# extensions/ markdown file is extracted and eval'd directly, no LLM involved.
# That is the point — day-open-pipeline.sh runs unattended under launchd/cron,
# where no LLM is present to read a Markdown instruction the way day-close's
# SKILL.md-driven extension points do (extensions/day-close.after.md is read
# and interpreted by an interactive agent; this file's mechanism is not that).
#
# NOTE: hook files are a trusted local source (not shared/untrusted input) —
# same trust boundary day-open-checks-runner.sh already documents.
#
# Fail-closed contract (Codex review, 2026-08-28): a hook is only allowed to
# "pass" by actually running something. A missing/unreadable extensions/ dir,
# a hook file that vanishes between discovery and read, or a hook file that
# contributes zero bash blocks (fencing typo) are all treated as failures —
# never silently folded into the same "nothing to do" path as the common,
# legitimate case of "no day-open.<hook>*.md at all".

# find_day_open_hook_files <ext_dir> <hook-name> — newline-separated list on
# stdout, sorted LC_ALL=C; exit status 0 on success (list may be empty — that
# is the normal "no customization for this hook" case), nonzero if the
# directory itself is missing/not a directory (every install ships
# extensions/, so this means a broken install, not "no hooks").
# Matches only the exact `day-open.<hook>.md` and the suffixed
# `day-open.<hook>.*.md` (the literal dot after <hook> is part of the glob,
# so `day-open.beforeevil.md` never matches `before`).
find_day_open_hook_files() {
  local ext_dir="$1" hook="$2"
  if [ ! -d "$ext_dir" ]; then
    echo "day-open-hooks: extensions directory not found or not a directory: $ext_dir" >&2
    return 2
  fi
  find -L "$ext_dir" -maxdepth 1 \( -name "day-open.$hook.md" -o -name "day-open.$hook.*.md" \) -type f | LC_ALL=C sort
  return "${PIPESTATUS[0]}"
}

# run_day_open_hook_files <files, newline-separated> — extracts and eval's
# every ```bash``` block from each file, in order. Sets two globals for the
# caller to read immediately after the call (bash 3.2 has no `local -n`,
# so plain globals rather than a return-by-reference param):
#   DAYOPEN_HOOK_BLOCKS_RUN    — total blocks executed across all files
#   DAYOPEN_HOOK_BLOCKS_FAILED — count of failure EVENTS, not files: one per
#                                nonzero-exit block, plus one more per file
#                                that contributed zero blocks or could not be
#                                read (TOCTOU — found by find, gone/unreadable
#                                by the time this function gets to it). The
#                                caller only ever checks "> 0", so the exact
#                                count's composition doesn't matter to it.
# Returns 0 normally; nonzero only if mktemp itself fails (genuine
# infrastructure problem, not a hook failure — caller must treat this as a
# failure too, since it cannot tell success from failure without the globals).
run_day_open_hook_files() {
  local files="$1"
  local hook_file block blocks_in_file awk_status err_file blocks_tmp
  err_file=$(mktemp) || { echo "day-open-hooks: mktemp failed (err_file)" >&2; return 1; }
  blocks_tmp=$(mktemp) || { echo "day-open-hooks: mktemp failed (blocks_tmp)" >&2; rm -f "$err_file"; return 1; }
  DAYOPEN_HOOK_BLOCKS_RUN=0

  while IFS= read -r hook_file; do
    [ -n "$hook_file" ] || continue

    # issue #546: a checks file may be addressed to the AGENT, not to this
    # bash runner (prose instructions; pre-#509 installs still carry such a
    # file — extensions/ is user space, update.sh never rewrites it). Zero
    # bash blocks in such a file is not_applicable here, not a failure. The
    # declaration must be explicit (`executor: agent`, plain or inside an
    # HTML comment, in the first 15 lines) — an UNdeclared zero-block file
    # stays a failure: it may equally be a fencing typo or a corrupt file.
    if head -15 "$hook_file" | grep -qE '^(<!--[[:space:]]*)?executor:[[:space:]]*agent([[:space:]]*-->)?[[:space:]]*$'; then
      echo "day-open-hooks: $hook_file declares executor: agent — checks run by the agent (step 7b), not this runner; skipping (not a failure)" >&2
      continue
    fi

    blocks_in_file=0

    awk '
      /^```bash$/ { block=""; in_block=1; next }
      /^```$/     { if(in_block){ printf "%s", block; printf "%c", 0 }; in_block=0; next }
      in_block    { block = block $0 "\n" }
    ' "$hook_file" > "$blocks_tmp"
    awk_status=$?
    if [ "$awk_status" -ne 0 ]; then
      # Found by find_day_open_hook_files a moment ago, but gone or
      # unreadable now — a real infrastructure failure, not "no hooks".
      echo "day-open-hooks: could not read $hook_file (awk exit $awk_status) — treating as failure" >&2
      echo "1" >> "$err_file"
      continue
    fi

    while IFS= read -r -d '' block; do
      blocks_in_file=$((blocks_in_file + 1))
      DAYOPEN_HOOK_BLOCKS_RUN=$((DAYOPEN_HOOK_BLOCKS_RUN + 1))
      # Subshell with set -e so any error inside the block is caught, without
      # aborting the outer runner (we collect failures across all blocks).
      # Deliberately NOT `if ! ( set -e; ... ); then` (Codex review,
      # 2026-08-28, High): bash suppresses errexit for a subshell that is
      # itself the condition of `if`/`!`, even though the subshell re-declares
      # `set -e` — `false; echo survived` inside it would run "survived" and
      # the whole thing would report success. Capture the exit status as its
      # own statement first, THEN branch on it.
      ( set -e; eval "$block" ) 2>&1
      block_status=$?
      if [ "$block_status" -ne 0 ]; then
        echo "1" >> "$err_file"
      fi
    done < "$blocks_tmp"

    if [ "$blocks_in_file" -eq 0 ]; then
      # Per-file, not per-run: a well-formed day-open.checks.md must not mask
      # a sibling day-open.checks.custom.md with a fencing typo (Codex review
      # — a shared BLOCKS_RUN==0 check across the whole set let exactly that
      # slip through silently).
      echo "day-open-hooks: $hook_file contributed zero bash blocks — check the \`\`\`bash fencing" >&2
      echo "1" >> "$err_file"
    fi
  done <<< "$files"

  # shellcheck disable=SC2034  # read by the caller, not this file — see the function doc comment
  DAYOPEN_HOOK_BLOCKS_FAILED=$(wc -l < "$err_file" | tr -d ' ')
  rm -f "$err_file" "$blocks_tmp"
  # Explicit, not "whatever rm -f returned" (Codex review, 2026-08-28) — the
  # doc comment above promises nonzero only means "mktemp itself failed",
  # and callers report any nonzero return as exactly that.
  return 0
}
