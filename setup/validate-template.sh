#!/bin/bash
# Validate Template — integrity check IWE
#
# Modes (--mode=...):
#   pristine  (default) — all 9 checks. For CI, author template-sync, fresh clone before setup.sh.
#   installed           — skips checks 2/3/4, which are legitimately violated after setup.sh
#                         (/Users/ substituted, /opt/homebrew in CLAUDE_PATH, MEMORY gets populated through use).
#                         Used by setup.sh --validate as a delegate for structural checks.
#
# 9 checks:
# 1. No author-specific content                              [pristine + installed]
# 2. No hardcoded paths /Users/                             [pristine only]
# 3. No hardcoded paths /opt/homebrew                       [pristine only]
# 4. MEMORY.md — skeleton (few rows in the WP-table)                 [pristine only]
# 5. Required files exist                                [pristine + installed]
# 6. No hardcoded-paths to FMT/scripts|roles in protocols (WP-219)  [pristine + installed]
# 7. settings.json hooks ↔ .claude/hooks/ cross-ref (issue #13)   [pristine + installed]
# 8. No obsolete semantic references FPF                     [pristine + staged]
# 9. SKILL.md claims of an active hook match settings.json (#1109) [pristine + installed]

set -euo pipefail

# Parse args: --mode=pristine|installed|staged (default pristine) + positional TEMPLATE_DIR
MODE="pristine"
TEMPLATE_DIR=""
for arg in "$@"; do
    case "$arg" in
        --mode=pristine|--mode=installed|--mode=staged) MODE="${arg#--mode=}" ;;
        --mode=*)
            echo "ERROR: unknown mode '${arg#--mode=}'. Use --mode=pristine, --mode=installed, or --mode=staged." >&2
            exit 2
            ;;
        --help|-h)
            echo "Usage: validate-template.sh [--mode=pristine|installed|staged] [TEMPLATE_DIR]"
            echo "  Default mode: pristine (CI, author sync, fresh clone — scans full tree)"
            echo "  Use --mode=installed for post-setup checks (skips placeholder-substitution-related rules)."
            echo "  Use --mode=staged for pre-commit in multi-agent environments: checks ONLY staged files."
            echo "    Prevents false-positive failures from unstaged WIP of parallel agents."
            echo "    Unstaged forbidden content → WARN only (not blocking) so parallel work continues."
            exit 0
            ;;
        *) [ -z "$TEMPLATE_DIR" ] && TEMPLATE_DIR="$arg" ;;
    esac
done
TEMPLATE_DIR="${TEMPLATE_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
FAIL=0

# Guard: post-setup state + default pristine mode → suggest installed-mode and exit.
# Detector is stable: {{WORKSPACE_DIR}} in pristine FMT/CLAUDE.md is guaranteed (§4 Memory, section Working Directory).
# Previously the detector was {{HOME_DIR}} from §9; §9 in the distribution is now an empty stub (issue #883), the placeholder is not present there.
if [ "$MODE" = "pristine" ] \
   && [ -f "$TEMPLATE_DIR/CLAUDE.md" ] \
   && ! grep -q '{{WORKSPACE_DIR}}' "$TEMPLATE_DIR/CLAUDE.md" 2>/dev/null; then
    echo "WARNING: FMT has been processed by setup.sh (placeholder {{WORKSPACE_DIR}} in CLAUDE.md already substituted)."
    echo ""
    echo "Pristine-mode (default) applicable to:"
    echo "  • CI (.github/workflows/validate-template.yml)"
    echo "  • Author template-sync (before commit FMT)"
    echo "  • Fresh clone BEFORE running setup.sh"
    echo ""
    echo "To verify an installed workspace use one of workspace use one of:"
    echo "  bash setup.sh --validate                              # env + structural checks (delegate)"
    echo "  bash setup/validate-template.sh --mode=installed      # explicitly installed (4 universal checks)"
    echo "  /audit-installation                                   # full audit (Claude Code skill)"
    exit 0
fi

echo "=== Validating: $TEMPLATE_DIR (mode=$MODE) ==="

# Utility: count grep matches grep (safe with pipefail)
grep_count() {
    local pattern="$1"
    shift
    grep -rn "$pattern" "$@" 2>/dev/null | wc -l | tr -d ' ' || true
}

# Staged-mode: list staged files (relative paths). Empty if not in git or no staged.
STAGED_FILES=""
if [ "$MODE" = "staged" ]; then
    STAGED_FILES=$(cd "$TEMPLATE_DIR" && git diff --cached --name-only --diff-filter=ACM 2>/dev/null || true)
    if [ -z "$STAGED_FILES" ]; then
        echo "=== staged mode: no staged files — skip ==="
        exit 0
    fi
fi

# issue #547: paths the manifest deliberately freezes out of delivery
# (excluded_paths) never get refreshed on forks — an author-content hit there
# is permanent and unactionable for a fork owner, so excluding a path from
# delivery while including it in this scan makes the two rules contradict
# each other forever. Scope: ONLY check [1/5] (author-content); the other
# checks below intentionally still see excluded paths — this must not become
# a general validation bypass.
EXCLUDED_LIST=$(jq -r '.excluded_paths[]? // empty' "$TEMPLATE_DIR/update-manifest.json" 2>/dev/null || true)
is_excluded_path() {
    local rel="$1" ex
    [ -n "$EXCLUDED_LIST" ] || return 1
    while IFS= read -r ex; do
        [ -n "$ex" ] || continue
        [ "$rel" = "$ex" ] && return 0
        case "$rel" in "$ex"/*) return 0 ;; esac
    done <<< "$EXCLUDED_LIST"
    return 1
}
is_author_context_exception() {
    # Existing workflow-only context: one host access control and three
    # historical/test comments; one vendored-copy line that can't be edited
    # in place (guide-kit/, byte-identical sync — see
    # scripts/guide-kit-sync-state.yaml; fix belongs upstream, issue #1107);
    # five lines using "DS-Knowledge-Index" as the generic, flat convention
    # name for this optional per-pilot repo (same pattern as DS-strategy and
    # DS-personal-guide — every pilot creates their OWN repo with this same
    # name, it is not one specific author's instance; issue #1107 triage);
    # one functional check for "DS-ecosystem-development/" — docs/LEARNING-PATH.md
    # (exempt from this scan) documents it the same way: an optional, locally-
    # created ecosystem governance repo any pilot may set up, parallel to
    # DS-strategy, not one author's personal instance; six references to
    # session-dispatcher-tsekh.py (one manifest entry, three byte-identical
    # find-python3.sh comments, two tool comments) for the same reason: the
    # script itself is deliberately excluded from delivery (EXCLUDED_SCRIPTS)
    # because it is author-host-specific, so renaming it would require
    # coordinating the author's own external systemd/cron setup for zero
    # end-user benefit (issue #1107 triage); three stable incident-ID slugs
    # (bug-2026-09-17-tsekh1-*) that the author cross-references outside this
    # repo — the ID's date+host encoding is disambiguating information, not
    # personal leakage, and no local bugs/ directory exists here to confirm a
    # rename is even safe (issue #1107 triage).
    # Match the whole line, never the whole file.
    local line="$2"
    line="${line%$'\r'}"  # grep preserves a final CR in Windows line endings.
    case "$1:$line" in
        '.github/workflows/changelog-gate.yml:      NO_CHANGELOG_ALLOWED: "TserenTserenov"'|\
        '.github/workflows/translate-sync.yml:# TserenTserenov; it was never one of the aisystant repos slated for a'|\
        '.github/workflows/release-watchdog.yml:# created: DS-IT-systems for the agent read-only.'|\
        '.github/workflows/validate-template.yml:      # Simulate pristine user: DS-strategy instead of DS-my-strategy, DayPlan with minimal template.'|\
        'guide-kit/generator/personal_export.py:    pathlib.Path.home() / "IWE/DS-my-strategy/inbox/WP-425/cache/derived_snapshot.json"'|\
        'memory/protocol-work.md:| Draft template | `DS-Knowledge-Index` status: draft | 14 days | post (published) / archive |'|\
        'memory/protocol-work.md:> **Draft ≠ Draft template.** Draft — personal (DS-strategy). Draft template — public (DS-Knowledge-Index).'|\
        'roles/strategist/prompts/week-review.md:For this run the script-wrapper has already opened a service guard session (`week-review`, scope `current/`) and will close it on its own. Your own session (`session-guard.sh open`) do not open: on a frozen directory it is denied, and an invented value `--wp` the guard rejects. In the repository governance modify and commit only files in `current/`; club post (step 6) belongs to the repository Knowledge Index (`DS-Knowledge-Index`), not covered by governance, and is not covered by this session. Do not bypass guard refusals (`--force`, `--no-verify`, editing hooks): output the verbatim refusal text in the final response. The script-wrapper verifies, that the weekly report was uploaded to the server, and will alert the owner, if not.'|\
        'roles/synchronizer/scripts/collectors.d/README.md:- `publications.sh` — publications (if present DS-Knowledge-Index-*/docs/)'|\
        'scripts/week-draft-init.sh:  echo "   knowledge_repo: \"DS-Knowledge-Index\""'|\
        '.claude/hooks/rule-engine.sh:        if ! echo "$file_path" | grep -qE '"'"'DS-[^/]+-strategy/|DS-ecosystem-development/'"'"'; then'|\
        'update-manifest.json:    "scripts/session-dispatcher-tsekh.py",'|\
        'setup.sh:    echo "  ⚠ Not found python3 >= 3.10 with the library PyYAML — calendar, feed «World», WP overview and core-scripts (artifactor.py, session-dispatcher-tsekh.py) will fail with an explicit dependency error."'|\
        'generate-manifest.sh:    "scripts/session-dispatcher-tsekh.py"       # no references from the delivered'|\
        'seed/strategy/scripts/lib/find-python3.sh:# core scripts (artifactor.py, session-dispatcher-tsekh.py). Reject 3.9 early'|\
        '.claude/lib/find-python3.sh:# core scripts (artifactor.py, session-dispatcher-tsekh.py). Reject 3.9 early'|\
        'scripts/lib/find-python3.sh:# core scripts (artifactor.py, session-dispatcher-tsekh.py). Reject 3.9 early'|\
        'setup/build-runtime.sh:# bug-2026-09-17-tsekh1-recovery-backups-abort: under `set -eu`, a single'|\
        'setup/build-runtime.sh:# bug-2026-09-17-tsekh1-recovery-backups-abort (continuation): leftovers from'|\
        'update.sh:# author_release_regression FPATH PAYLOAD — bug-2026-09-17-tsekh1-release-') return 0 ;;
    esac
    return 1
}
filter_staged_author_hits() {
    local rel="$1" entry key seen=$'\n'
    while IFS= read -r entry; do
        if is_author_context_exception "$rel" "${entry#*:}"; then
            key="$rel:${entry#*:}"
            key="${key%$'\r'}"
            case "$seen" in
                *$'\n'"$key"$'\n'*) ;;
                *) seen="${seen}${key}"$'\n'; continue ;;
            esac
        fi
        printf '%s\n' "$entry"
    done
}
filter_excluded_hits() {
    # stdin: grep -r output "<abs-path>:<line>:<text>" — drop excluded_paths
    # and exact workflow-context exceptions, retaining every other .yml hit.
    local line abs rel numbered key seen=$'\n'
    while IFS= read -r line; do
        abs="${line%%:*}"
        rel="${abs#"$TEMPLATE_DIR"/}"
        is_excluded_path "$rel" && continue
        # Local runtime directories are not template content: backups that update.sh,
        # skill-promote and friends leave next to the files they replaced hold copies
        # of OTHER people's files and would fail this scan for ever (FMT #1010, DS-ai-systems
        # pre-commit validates a live checkout). Tracked files never live here.
        case "$rel" in .backups/*|.iwe-runtime/*) continue ;; esac
        numbered="${line#"$abs":}"
        if is_author_context_exception "$rel" "${numbered#*:}"; then
            key="$rel:${numbered#*:}"
            key="${key%$'\r'}"
            case "$seen" in
                *$'\n'"$key"$'\n'*) ;;
                *) seen="${seen}${key}"$'\n'; continue ;;
            esac
        fi
        printf '%s\n' "$line"
    done
}

# 1. No author-specific content
echo -n "[1/5] Author-specific content... "
CHECK1_FAIL=0

# Global (forbidden everywhere, except CHANGELOG and GitHub URLs)
# grep -i below (all invocations of this pattern): "tserentserenov" was always found in
# the code as "TserenTserenov" (mixed-case) — case-sensitive grep was never caught
# it, caught only by the paired pattern "DS-my-strategy" on the same lines (2026-07-27).
for pattern in "tserentserenov" "PACK-MIM" "aist_bot_newarchitecture" \
               "DS-Knowledge-Index" "DS-IT-systems" "DS-ai-systems" \
               "DS-my-strategy" "engines/tailor" "tsekh" "DS-ecosystem-development" \
               "tseren"; do
    if [ "$MODE" = "staged" ]; then
        # staged-mode: check only the contents of staged-files (git show :path)
        count=0
        hits=""
        while IFS= read -r f; do
            is_excluded_path "$f" && continue  # frozen out of delivery (#547)
            case "$f" in
                *.md|*.sh|*.py|*.json|*.plist|*.yaml|*.yml) ;;
                *) continue ;;
            esac
            case "$(basename "$f")" in
                validate-template.sh|LEARNING-PATH.md|CHANGELOG.md|aisystant-sync-targets.yaml|translation-manifest.yaml) continue ;;
            esac
            # issue #308: docs/adr/* — historical ADR docs describing the past
            # authorial install, same exemption class as LEARNING-PATH.md/CHANGELOG.md above.
            case "$f" in
                docs/adr/*) continue ;;
            esac
            file_hits=$(cd "$TEMPLATE_DIR" && git show ":$f" 2>/dev/null \
                | grep -in "$pattern" | grep -v 'github.com/' | grep -v 'docs/adr/' \
                | grep -v 'githubusercontent\.com' \
                | grep -viE 'TserenTserenov/(IWE|ZP|SPF)' \
                | filter_staged_author_hits "$f" || true)
            if [ -n "$file_hits" ]; then
                count=$((count + $(echo "$file_hits" | wc -l | tr -d ' ')))
                hits="${hits}${f}:"$'\n'"${file_hits}"$'\n'
            fi
        done <<< "$STAGED_FILES"
    else
        count=$(grep -rin "$pattern" "$TEMPLATE_DIR" --include="*.md" --include="*.sh" \
                --include="*.py" --include="*.json" --include="*.plist" --include="*.yaml" --include="*.yml" \
                --exclude='validate-template.sh' --exclude='LEARNING-PATH.md' \
                --exclude='CHANGELOG.md' --exclude='aisystant-sync-targets.yaml' \
                --exclude='translation-manifest.yaml' 2>/dev/null \
                | grep -v 'github.com/' | grep -v 'docs/adr/' | grep -v 'githubusercontent\.com' \
                | grep -viE 'TserenTserenov/(IWE|ZP|SPF)' \
                | filter_excluded_hits | wc -l | tr -d ' ' || true)
    fi
    if [ "$count" -gt 0 ]; then
        [ "$CHECK1_FAIL" -eq 0 ] && echo "FAIL"
        echo "  Found '$pattern' (global) in $count locations:"
        if [ "$MODE" = "staged" ]; then
            echo "$hits" | head -3 || true
        else
            grep -rin "$pattern" "$TEMPLATE_DIR" --include="*.md" --include="*.sh" \
                --include="*.py" --include="*.json" --include="*.plist" --include="*.yaml" --include="*.yml" \
                --exclude='validate-template.sh' --exclude='LEARNING-PATH.md' \
                --exclude='CHANGELOG.md' --exclude='aisystant-sync-targets.yaml' \
                --exclude='translation-manifest.yaml' 2>/dev/null \
                | grep -v 'github.com/' | grep -v 'docs/adr/' | grep -v 'githubusercontent\.com' \
                | grep -viE 'TserenTserenov/(IWE|ZP|SPF)' \
                | filter_excluded_hits | head -3 || true
        fi
        CHECK1_FAIL=1
        FAIL=1
    fi
done

# Protocol-only — forbidden in protocols/skills/hooks/CLAUDE.md (allowed in README/docs/onboarding as a product mention)
for pattern in "@aist_me_bot" "digital-twin" "content-pipeline" \
               "knowledge-mcp" "gateway-mcp" "DS-agent-workspace/scheduler"; do
    if [ "$MODE" = "staged" ]; then
        count=0
        hits=""
        while IFS= read -r f; do
            case "$f" in
                .claude/skills/*|.claude/hooks/*|.claude/rules/*|memory/*|CLAUDE.md) ;;
                *) continue ;;
            esac
            case "$(basename "$f")" in CHANGELOG.md) continue ;; esac
            file_hits=$(cd "$TEMPLATE_DIR" && git show ":$f" 2>/dev/null | grep -n "$pattern" || true)
            if [ -n "$file_hits" ]; then
                count=$((count + $(echo "$file_hits" | wc -l | tr -d ' ')))
                hits="${hits}${f}:"$'\n'"${file_hits}"$'\n'
            fi
        done <<< "$STAGED_FILES"
    else
        count=$(cd "$TEMPLATE_DIR" && grep -rn "$pattern" \
                .claude/skills .claude/hooks .claude/rules memory CLAUDE.md 2>/dev/null \
                | grep -v 'CHANGELOG.md' | wc -l | tr -d ' ' || true)
    fi
    if [ "$count" -gt 0 ]; then
        [ "$CHECK1_FAIL" -eq 0 ] && echo "FAIL"
        echo "  Found '$pattern' (protocol-only) in $count locations:"
        if [ "$MODE" = "staged" ]; then
            echo "$hits" | head -3 || true
        else
            (cd "$TEMPLATE_DIR" && grep -rn "$pattern" \
                .claude/skills .claude/hooks .claude/rules memory CLAUDE.md 2>/dev/null | head -3) || true
        fi
        CHECK1_FAIL=1
        FAIL=1
    fi
done

# staged-mode: WARN about unstaged forbidden content (does not block — parallel agents)
if [ "$MODE" = "staged" ] && [ "$(cd "$TEMPLATE_DIR" && git status --porcelain 2>/dev/null | grep -c '^.M')" -gt 0 ]; then
    UNSTAGED_WARN=0
    for pattern in "tserentserenov" "PACK-MIM" "aist_bot_newarchitecture" "DS-IT-systems"; do
        warn_count=$(grep -rin "$pattern" "$TEMPLATE_DIR" --include="*.md" --include="*.sh" \
                     --include="*.py" --include="*.yaml" --include="*.yml" \
                     --exclude='validate-template.sh' --exclude='CHANGELOG.md' 2>/dev/null \
                     | grep -v 'github.com/' | wc -l | tr -d ' ' || true)
        if [ "$warn_count" -gt 0 ]; then
            [ "$UNSTAGED_WARN" -eq 0 ] && echo "  WARN (staged mode): unstaged files contain forbidden patterns — OK for parallel-agent workflow, review before next commit"
            UNSTAGED_WARN=1
        fi
    done
fi
[ "$CHECK1_FAIL" -eq 0 ] && echo "PASS"

# Shared list of extensions for checks 2 and 3 (issue #247 p.2: count and print earlier
# scanned different sets --include, because-of which FAIL (N hits) could not show
# any line, if the hit was only in *.json/*.plist).
# --exclude-dir=guide-kit: vendored byte-identical release slice (WP-483) —
# the CI drift gate forbids in-place edits, so scanning it here would deadlock
# two blocking gates; its own upstream CI is responsible for content checks.
HARDCODE_SCAN_INCLUDES=(--include="*.md" --include="*.sh" --include="*.json" --include="*.plist" --exclude-dir="guide-kit")

# Staged-mode for checks 2/3: scan only staged-content of the listed
# in STAGED_FILES files (git show ":$f"), not the entire $TEMPLATE_DIR — the same fix,
# already applied to check 1 above (issue #330: staged claimed "checks ONLY staged
# files" in its --help, but actually scanned the entire repository).
# Prints the match-count to stdout, per-line hits — to file $3.
hardcode_scan_staged() {
    # $4 (optional): regex of file PATHS to skip for this scan only — the
    # $2 exclude_re filters content lines (no filename in them), so per-file
    # exceptions cannot be expressed there (WP-529 F6).
    local pattern="$1" exclude_re="$2" hits_file="$3" skip_files_re="${4:-}"
    local f file_hits count=0
    : > "$hits_file"
    while IFS= read -r f; do
        case "$f" in
            */validate-template.sh|validate-template.sh|*/setup.sh|setup.sh|CHANGELOG.md) continue ;;
        esac
        if [ -n "$skip_files_re" ] && echo "$f" | grep -qE "$skip_files_re"; then
            continue
        fi
        case "$f" in
            *.md|*.sh|*.json|*.plist) ;;
            *) continue ;;
        esac
        case "$f" in guide-kit/*) continue ;; esac
        file_hits=$(cd "$TEMPLATE_DIR" && git show ":$f" 2>/dev/null | grep -n "$pattern" \
            | { [ -n "$exclude_re" ] && grep -vE "$exclude_re" || cat; } || true)
        if [ -n "$file_hits" ]; then
            count=$((count + $(echo "$file_hits" | wc -l | tr -d ' ')))
            { echo "${f}:"; echo "$file_hits"; } >> "$hits_file"
        fi
    done <<< "$STAGED_FILES"
    echo "$count"
}

# 2. No hardcoded /Users/ or C:\Users\ paths [pristine + staged; skip
# only installed]. In installed-mode setup.sh legitimately substituted
# $WORKSPACE_DIR → /Users/<user>/... (issue #835: previously matched only
# POSIX-style macOS — native Windows-path of the form C:\Users\<user>\... via
# this barrier passed unnoticed).
HARDCODE_USER_PATH_RE='/Users/\|C:\\Users\\'
# Third alternative excludes placeholder instructional text (QUICK-START.md
# telling a Windows user to type their own name) — same intent as the
# existing "# ... e.g." exclusion for POSIX comments, just not restricted to
# `#`-comments since this one lives in markdown prose, not a script comment.
HARDCODE_USER_PATH_EXCLUDE_RE='/Users/\.\.\./|C:\\Users\\\.\.\.|# .*(/Users/|C:\\Users\\|e\.g\.)|C:\\Users\\(your-name|<[^>]+>)'
echo -n "[2/5] Hardcoded /Users/ or C:\\Users\\ paths... "
if [ "$MODE" = "installed" ]; then
    echo "SKIP (installed mode — path substituted setup'by)"
elif [ "$MODE" = "staged" ]; then
    TMPDIR_CHECK2_HITS_FILE="$(mktemp)"
    count=$(hardcode_scan_staged "$HARDCODE_USER_PATH_RE" "$HARDCODE_USER_PATH_EXCLUDE_RE" "$TMPDIR_CHECK2_HITS_FILE")
    if [ "$count" -gt 0 ]; then
        echo "FAIL ($count hits)"
        head -3 "$TMPDIR_CHECK2_HITS_FILE" || true
        FAIL=1
    else
        echo "PASS"
    fi
    rm -f "$TMPDIR_CHECK2_HITS_FILE"
else
    count=$(grep -rn "$HARDCODE_USER_PATH_RE" "$TEMPLATE_DIR" "${HARDCODE_SCAN_INCLUDES[@]}" \
            --exclude='validate-template.sh' --exclude='setup.sh' \
            --exclude='CHANGELOG.md' 2>/dev/null \
            | grep -vE "$HARDCODE_USER_PATH_EXCLUDE_RE" \
            | wc -l | tr -d ' ' || true)
    if [ "$count" -gt 0 ]; then
        echo "FAIL ($count hits)"
        grep -rn "$HARDCODE_USER_PATH_RE" "$TEMPLATE_DIR" "${HARDCODE_SCAN_INCLUDES[@]}" \
            --exclude='validate-template.sh' --exclude='setup.sh' \
            --exclude='CHANGELOG.md' 2>/dev/null \
            | grep -vE "$HARDCODE_USER_PATH_EXCLUDE_RE" | head -3 || true
        FAIL=1
    else
        echo "PASS"
    fi
fi

# 3. No hardcoded /opt/homebrew paths [pristine + staged; skip only installed]
# In installed-mode CLAUDE_PATH=/opt/homebrew/bin/claude — a legitimate substitution.
echo -n "[3/5] Hardcoded /opt/homebrew paths... "
if [ "$MODE" = "installed" ]; then
    echo "SKIP (installed mode — CLAUDE_PATH can be /opt/homebrew/...)"
elif [ "$MODE" = "staged" ]; then
    TMPDIR_CHECK3_HITS_FILE="$(mktemp)"
    # The shipped resolver copies are sanctioned exceptions (WP-529 F6,
    # #453/#463): their job is enumerating STANDARD system Python locations
    # (/opt/homebrew is stock macOS Apple Silicon), not an author-machine leak.
    # secret-bypass-lib.sh (WP-544 D28) is the same class: it resolves
    # jq/python3 across the standard FHS locations on macOS (both Intel
    # /usr/local/bin and Apple Silicon /opt/homebrew/bin) and Linux (/usr/bin,
    # /bin), falling back to PATH-based `command -v` only for non-standard
    # layouts (NixOS) — an absolute-path-first resolver by design, not a
    # hardcoded personal path.
    count=$(hardcode_scan_staged '/opt/homebrew' '/usr/local/bin.*:/opt/homebrew' "$TMPDIR_CHECK3_HITS_FILE" '^README\.md$|^docs/PLATFORM-COMPAT\.md$|^\.github/workflows/validate-template\.yml$|^\.claude/lib/find-python3\.sh$|^scripts/lib/find-python3\.sh$|^seed/strategy/scripts/lib/find-python3\.sh$|^\.claude/hooks/secret-bypass-lib\.sh$|^scripts/tests/test_issue_463_setup_reuses_resolved_python3\.sh$')
    if [ "$count" -gt 0 ]; then
        echo "FAIL ($count hits)"
        head -3 "$TMPDIR_CHECK3_HITS_FILE" || true
        FAIL=1
    else
        echo "PASS"
    fi
    rm -f "$TMPDIR_CHECK3_HITS_FILE"
else
    # scripts/lib/find-python3.sh: sanctioned exception (WP-529 F6, #453/#463) —
    # the resolver's whole job is enumerating STANDARD system python locations
    # (/opt/homebrew is stock macOS Apple Silicon), not an author-machine leak.
    count=$(grep -rn '/opt/homebrew' "$TEMPLATE_DIR" "${HARDCODE_SCAN_INCLUDES[@]}" \
            --exclude='validate-template.sh' --exclude='setup.sh' \
            --exclude='find-python3.sh' --exclude='test_issue_463_setup_reuses_resolved_python3.sh' \
            --exclude='secret-bypass-lib.sh' \
            --exclude='CHANGELOG.md' 2>/dev/null \
            | grep -v 'README.md' \
            | grep -v 'PLATFORM-COMPAT.md' \
            | grep -v 'validate-template.yml' \
            | grep -v '/usr/local/bin.*:/opt/homebrew' \
            | wc -l | tr -d ' ' || true)
    if [ "$count" -gt 0 ]; then
        echo "FAIL ($count hits)"
        grep -rn '/opt/homebrew' "$TEMPLATE_DIR" "${HARDCODE_SCAN_INCLUDES[@]}" \
            --exclude='validate-template.sh' --exclude='setup.sh' \
            --exclude='find-python3.sh' --exclude='test_issue_463_setup_reuses_resolved_python3.sh' \
            --exclude='secret-bypass-lib.sh' \
            --exclude='CHANGELOG.md' 2>/dev/null \
            | grep -v 'README.md' | grep -v 'PLATFORM-COMPAT.md' \
            | grep -v 'validate-template.yml' \
            | grep -v '/usr/local/bin.*:/opt/homebrew' | head -3 || true
        FAIL=1
    else
        echo "PASS"
    fi
fi

# 4. MEMORY.md — skeleton (≤15 rows in the table) [pristine only]
# In installed-mode MEMORY is populated by user work (WP, notes).
echo -n "[4/5] MEMORY.md is skeleton... "
if [ "$MODE" = "installed" ]; then
    echo "SKIP (installed mode — MEMORY is populated by work)"
else
    MEMORY_FILE="$TEMPLATE_DIR/memory/MEMORY.md"
    if [ -f "$MEMORY_FILE" ]; then
        rp_rows=$(grep -c '^|' "$MEMORY_FILE" 2>/dev/null || true); rp_rows=${rp_rows:-0}
        if [ "$rp_rows" -gt 15 ]; then
            echo "FAIL ($rp_rows table rows, expected ≤15)"
            FAIL=1
        else
            echo "PASS ($rp_rows rows)"
        fi
    else
        echo "WARN (file missing)"
    fi
fi

# 5. Required files
echo -n "[5/5] Required files... "
MISSING=0
for f in CLAUDE.md ONTOLOGY.md README.md \
         memory/MEMORY.md memory/hard-distinctions.md \
         memory/protocol-open.md memory/protocol-close.md \
         memory/navigation.md \
         roles/strategist/scripts/strategist.sh; do
    if [ ! -f "$TEMPLATE_DIR/$f" ]; then
        echo ""
        echo "  MISSING: $f"
        MISSING=1
        FAIL=1
    fi
done
[ "$MISSING" -eq 0 ] && echo "PASS"

# 6. No hardcoded-paths to scripts in protocols/skills (WP-219, DP.FM.009)
# Protocols and skills must use $IWE_SCRIPTS / $IWE_ROLES / $IWE_TEMPLATE / $IWE_WORKSPACE
# instead of absolute paths to IWE/scripts|roles or bare ~/IWE/scripts.
# Enumerate-all: collect ALL violations across all patterns, print as a list, then fail (prevents iterative fix-retry).
echo -n "[6/6] Hardcoded script paths in protocols/skills... "
CHECK6_FAIL=0
CHECK6_HITS=""
# Pattern 1-2: references to FMT-template path (legacy DP.FM.009)
# Pattern 3: bare `bash ~/IWE/scripts/X.sh` or `bash $HOME/IWE/scripts/X.sh` without fallback to $IWE_SCRIPTS
#   (excludes correct `bash ${IWE_SCRIPTS:-$HOME/IWE/scripts}/X.sh`, i.e. after `bash ` comes `${`, not `~` and not `$HOME`)
for pattern in 'IWE/scripts' \
               'IWE/roles/[a-z]*/scripts' \
               'bash (~|\$HOME)/IWE/scripts/'; do
    hits=$(grep -rnE "$pattern" \
            "$TEMPLATE_DIR/memory" \
            "$TEMPLATE_DIR/.claude/skills" \
            --include="*.md" 2>/dev/null \
            | grep -v '\$IWE_' || true)
    if [ -n "$hits" ]; then
        CHECK6_HITS="${CHECK6_HITS}${CHECK6_HITS:+$'\n'}--- Pattern: $pattern ---"$'\n'"$hits"
        CHECK6_FAIL=1
        FAIL=1
    fi
done
if [ "$CHECK6_FAIL" -eq 1 ]; then
    echo "FAIL"
    echo "  Must be \$IWE_SCRIPTS / \$IWE_ROLES (or \${IWE_SCRIPTS:-\$HOME/IWE/scripts} for inline-commands):"
    echo "$CHECK6_HITS"
else
    echo "PASS"
fi

# 7. settings.json hooks ↔ .claude/hooks/ cross-ref (issue #13)
# Check in both directions:
#   (a) FAIL: hook is referenced in settings.json, but the file is missing from .claude/hooks/
#   (b) WARN: hook exists in .claude/hooks/, but is not referenced in any settings.json
#       (may be invoked directly, for example wakatime-heartbeat.sh)
echo -n "[7/7] Hooks cross-ref (settings.json ↔ .claude/hooks/)... "
CHECK7_FAIL=0
HOOKS_DIR="$TEMPLATE_DIR/.claude/hooks"
SETTINGS_FILES=()
[ -f "$TEMPLATE_DIR/.claude/settings.json" ] && SETTINGS_FILES+=("$TEMPLATE_DIR/.claude/settings.json")
[ -f "$TEMPLATE_DIR/.claude/settings.local.json" ] && SETTINGS_FILES+=("$TEMPLATE_DIR/.claude/settings.local.json")

if [ ${#SETTINGS_FILES[@]} -eq 0 ] || [ ! -d "$HOOKS_DIR" ]; then
    echo "SKIP (no settings.json or hooks/ dir)"
else
    REFERENCED=$(grep -hoE '\.claude/hooks/[a-zA-Z0-9_-]+\.sh' "${SETTINGS_FILES[@]}" 2>/dev/null | sort -u || true)
    for ref in $REFERENCED; do
        if [ ! -f "$TEMPLATE_DIR/$ref" ]; then
            [ "$CHECK7_FAIL" -eq 0 ] && echo "FAIL"
            echo "  Missing hook: $ref (referenced in settings.json but file not found)"
            CHECK7_FAIL=1
            FAIL=1
        fi
    done

    # Hooks intentionally user-deployed (installed to ~/.claude/hooks/ via skill,
    # registered in user settings.local.json — not project settings.json by design).
    USER_DEPLOYED_HOOKS=("wakatime-heartbeat.sh")

    ORPHAN_WARN=0
    for hook in "$HOOKS_DIR"/*.sh; do
        [ -f "$hook" ] || continue
        name=$(basename "$hook")
        # The directory has historically contained more than just Claude hooks. Do not guess by
        # name: a standalone service/CLI/library must explicitly declare
        # the contract in its own header. A new unclassified file still. A new unclassified file will still
        # give warning and will require a decision from the owner.
        grep -q '^# claude-hook: false — ' "$hook" && continue
        # Skip known user-deployed hooks (see .claude/skills/setup-wakatime/SKILL.md)
        skip=0
        for ud in "${USER_DEPLOYED_HOOKS[@]}"; do [ "$name" = "$ud" ] && skip=1 && break; done
        [ "$skip" -eq 1 ] && continue
        if ! grep -q "\.claude/hooks/$name" "${SETTINGS_FILES[@]}" 2>/dev/null; then
            if [ "$ORPHAN_WARN" -eq 0 ]; then
                [ "$CHECK7_FAIL" -eq 0 ] && echo "PASS (with warnings)"
                ORPHAN_WARN=1
            fi
            echo "  WARN: hook $name is not mentioned in settings.json (may be dead code or a direct call)"
        fi
    done
    [ "$CHECK7_FAIL" -eq 0 ] && [ "$ORPHAN_WARN" -eq 0 ] && echo "PASS"
fi

# 8. Deprecated semantic references FPF (issue #390 follow-up).
# A.2 and A.2.1 are valid on their own for roles and assignments. Only the following are prohibited
# two proven false bindings: removed A.6.8 and the interpretation of the word mastery/
# «mastery» as an entity of A.2. In installed-mode user memory may
# contain historical quotes, therefore the check applies only to the shipped
# pristine/staged template.
echo -n "[8/8] Obsolete FPF semantic references... "
if [ "$MODE" = "installed" ]; then
    echo "SKIP (installed mode — user memory may contain historical quotes)"
else
    FPF_STALE_PATTERN='A\.6\.8|(mastery|mastery).*A\.2([^0-9.]|$)'
    FPF_STALE_HITS=""
    if [ "$MODE" = "staged" ]; then
        while IFS= read -r f; do
            case "$f" in
                memory/*.md|.claude/*.md|.claude/*/*.md|.claude/*/*/*.md|docs/*.md)
                    hits=$(git -C "$TEMPLATE_DIR" show ":$f" 2>/dev/null \
                        | grep -niE "$FPF_STALE_PATTERN" \
                        | sed "s#^#$f:#" || true)
                    [ -n "$hits" ] && FPF_STALE_HITS="${FPF_STALE_HITS}${FPF_STALE_HITS:+$'\n'}$hits"
                    ;;
            esac
        done <<<"$STAGED_FILES"
    else
        FPF_STALE_HITS=$(grep -rniE "$FPF_STALE_PATTERN" \
            "$TEMPLATE_DIR/memory" "$TEMPLATE_DIR/.claude" "$TEMPLATE_DIR/docs" \
            --include='*.md' 2>/dev/null || true)
    fi

    if [ -n "$FPF_STALE_HITS" ]; then
        echo "FAIL"
        echo "$FPF_STALE_HITS" | sed 's/^/  /'
        FAIL=1
    else
        echo "PASS"
    fi
fi

# 9. SKILL.md hook-claims must be registered (issue #1109).
#
# Check [7/7] above only WARNs when a hook file in .claude/hooks/ is not
# referenced from settings.json — a legitimate state for a script that is
# invoked directly rather than through Claude Code's PreToolUse dispatch
# (e.g. a library sourced by other hooks). But when a SKILL.md explicitly
# documents a hook as ACTIVE protection ("Hook `x.sh` blocks ..." / "hook
# ... blocks ..."), an unregistered hook is not a benign unused file — it is
# a fail-open security claim: the hook's own isolated unit test can pass
# forever while no real session ever invokes it (same false-confidence class
# as issues #310/#323, found by independent audit on pack-creator-spf-guard.sh).
# This check escalates exactly that case from WARN to FAIL.
#
# Detection is mechanical, not NLP, to keep it reliable across the whole
# .claude/skills/ tree (general version, not hardcoded to one hook): a
# SKILL.md line counts as an "active protection" claim only when THREE
# things co-occur on the SAME line —
#   (a) the basename of a real file under .claude/hooks/*.sh,
#   (b) the word "hook" or "hook" (case-insensitive),
#   (c) an enforcement verb — blocks/guards/prevents/denies/stops/enforces
#       (EN) or blokir/zashchishcha/zapreshch/otkaz (RU), either case.
# Verified against this repo before the settings.json fix in this same
# commit: the triple co-occurs on exactly 3 lines across every SKILL.md —
# destructive-guard.sh and dry-run-gate.sh (both already registered → PASS)
# and pack-creator-spf-guard.sh (not registered → exactly the bug this
# check exists to catch).
echo -n "[9/9] SKILL.md hook-claims are registered... "
if [ ${#SETTINGS_FILES[@]} -eq 0 ] || [ ! -d "$HOOKS_DIR" ]; then
    echo "SKIP (no settings.json or hooks/ dir)"
else
    CHECK9_FAIL=0
    ENFORCE_RE='block|Block|blokir|Blokir|guard|Guard|zashchishcha|Zashchishcha|zapreshch|Zapreshch|prevent|Prevent|enforc|Enforc|deni|Deni|otkaz|Otkaz|stop|Stop'
    for hook_path in "$HOOKS_DIR"/*.sh; do
        [ -f "$hook_path" ] || continue
        hookname=$(basename "$hook_path")
        # Already wired under PreToolUse specifically — the only event type
        # that can actually block a Write/Edit/MultiEdit/NotebookEdit before
        # it runs. A plain string-presence grep (the check this replaced)
        # can't tell PreToolUse apart from SessionStart/PostToolUse/Stop etc,
        # so a hook registered under the wrong event type still read as
        # "registered" and this check never escalated it (found by
        # adversarial review, 2026-10-06: moved a hook's own registration to
        # SessionStart while leaving its path string elsewhere in the same
        # file — check [9/9] kept reporting PASS).
        registered_pretooluse=0
        for settings_file in "${SETTINGS_FILES[@]}"; do
            if python3 -c "
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
except (OSError, ValueError):
    sys.exit(1)
for entry in data.get('hooks', {}).get('PreToolUse', []):
    for h in entry.get('hooks', []):
        if sys.argv[2] in h.get('command', ''):
            sys.exit(0)
sys.exit(1)
" "$settings_file" "$hookname" 2>/dev/null; then
                registered_pretooluse=1
                break
            fi
        done
        [ "$registered_pretooluse" -eq 1 ] && continue
        esc_name=$(printf '%s' "$hookname" | sed 's/\./\\./g')
        hits=$(grep -rnEi "$esc_name" "$TEMPLATE_DIR/.claude/skills" --include=SKILL.md 2>/dev/null \
            | grep -Ei 'hook|hook' | grep -E "$ENFORCE_RE" || true)
        if [ -n "$hits" ]; then
            [ "$CHECK9_FAIL" -eq 0 ] && echo "FAIL"
            echo "  $hookname: SKILL.md claims active protection (hook + blocking verb on the same line), but the hook is not registered under PreToolUse in any settings.json:"
            echo "$hits" | sed 's/^/    /' | head -5
            CHECK9_FAIL=1
            FAIL=1
        fi
    done
    [ "$CHECK9_FAIL" -eq 0 ] && echo "PASS"
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "=== ALL CHECKS PASSED ==="
    exit 0
else
    echo "=== VALIDATION FAILED ==="
    exit 1
fi
