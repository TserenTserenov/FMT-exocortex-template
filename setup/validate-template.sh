#!/bin/bash
# Validate Template — integrity check of FMT-exocortex-template
#
# Modes (--mode=...):
#   pristine  (default) — all 9 checks. For CI, author template-sync, fresh clone before setup.sh.
#   installed           — skips checks 2/3/4, which are legitimately violated after setup.sh
#                         (/Users/ substituted, /opt/homebrew in CLAUDE_PATH, MEMORY filled with work).
#                         Used by setup.sh --validate as a delegate for structural checks.
#
# 9 checks:
# 1. No author-specific content                                   [pristine + installed]
# 2. No hardcoded /Users/ paths                                   [pristine only]
# 3. No hardcoded /opt/homebrew paths                             [pristine only]
# 4. MEMORY.md — skeleton (few lines in the WP table)             [pristine only]
# 5. Required files exist                                         [pristine + installed]
# 6. No hardcoded paths to FMT/scripts|roles in protocols (WP-219)  [pristine + installed]
# 7. settings.json hooks ↔ .claude/hooks/ cross-ref (issue #13)   [pristine + installed]
# 8. No stale FPF semantic references                             [pristine + staged]
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

# Guard: post-setup state + default pristine mode -> suggest installed mode and exit.
# Stable detector: {{WORKSPACE_DIR}} in pristine FMT/CLAUDE.md is guaranteed (§4 Memory, Working Directory section).
# Previously the detector was {{HOME_DIR}} from §9; §9 in the distribution is now an empty stub (issue #883), no placeholder there.
if [ "$MODE" = "pristine" ] \
   && [ -f "$TEMPLATE_DIR/CLAUDE.md" ] \
   && ! grep -q '{{WORKSPACE_DIR}}' "$TEMPLATE_DIR/CLAUDE.md" 2>/dev/null; then
    echo "ВНИМАНИЕ: FMT обработан setup.sh (плейсхолдер {{WORKSPACE_DIR}} в CLAUDE.md уже подставлен)."
    echo ""
    echo "Pristine-режим (default) применим к:"
    echo "  • CI (.github/workflows/validate-template.yml)"
    echo "  • Author template-sync (перед commit FMT)"
    echo "  • Свежий clone ДО запуска setup.sh"
    echo ""
    echo "Для проверки установленного workspace используйте один из:"
    echo "  bash setup.sh --validate                              # env + структурные чеки (делегат)"
    echo "  bash setup/validate-template.sh --mode=installed      # явно installed (4 универсальных чека)"
    echo "  /audit-installation                                   # полный аудит (Claude Code skill)"
    exit 0
fi

echo "=== Validating: $TEMPLATE_DIR (mode=$MODE) ==="

# Staged mode (issue #1457): export the staged blobs ONCE into a private
# directory outside the worktree and run the very same recursive grep
# pipelines as pristine mode against it. The former per-file loop forked
# ~8 processes per (pattern x staged file) — tens of thousands of forks on a
# large commit, 35+ minutes on Git Bash. SCAN_ROOT is the tree every content
# check below scans: the worktree (pristine/installed) or the exported index
# snapshot (staged).
SCAN_ROOT="$TEMPLATE_DIR"
# Both listings use the same filter: every staged path whose new content
# ships — added, copied, modified, renamed (a move out of an excluded path,
# e.g. `git mv docs/adr/x.md docs/x.md`, is R100 and carries its content
# along) and type-changed (a symlink replaced by a file). Only deletions and
# unmerged entries are left out.
if [ "$MODE" = "staged" ]; then
    staged_count=$(cd "$TEMPLATE_DIR" && git diff --cached --name-only --diff-filter=ACMRT 2>/dev/null | wc -l | tr -d ' ' || true)
    if [ "${staged_count:-0}" -eq 0 ]; then
        echo "=== staged mode: нет staged файлов — skip ==="
        exit 0
    fi
    STAGE_TMP=$(mktemp -d)
    trap 'rm -rf -- "$STAGE_TMP"' EXIT
    chmod 700 "$STAGE_TMP"
    # -z on both ends keeps paths with spaces or newlines intact.
    if ! (cd "$TEMPLATE_DIR" && git diff --cached --name-only -z --diff-filter=ACMRT \
            | git checkout-index -z --stdin --prefix="$STAGE_TMP/"); then
        echo "ERROR: не удалось выгрузить staged-содержимое во временный каталог $STAGE_TMP" >&2
        exit 2
    fi
    SCAN_ROOT="$STAGE_TMP"
fi

# Staged hits are reported relative to the repo root: the snapshot path is a
# private temp dir that means nothing to the reader. Pristine keeps the
# absolute paths it always printed.
display_hits() {
    local line
    if [ "$MODE" != "staged" ]; then
        cat
        return
    fi
    while IFS= read -r line; do
        printf '%s\n' "${line#"$SCAN_ROOT"/}"
    done
}

# Drop grep -r hits "<root>/<rel>:<line>:<text>" whose <rel> matches the ERE
# $2 — path-scoped exceptions shared by every mode, so a same-named file in
# another directory is still scanned.
drop_hits_in_paths() {
    local root="$1" skip_re="$2" line abs rel
    while IFS= read -r line; do
        abs="${line%%:*}"
        rel="${abs#"$root"/}"
        [[ "$rel" =~ $skip_re ]] && continue
        printf '%s\n' "$line"
    done
}

# Number of lines in a hit list held in a variable (0 for an empty list).
count_hits() {
    if [ -z "$1" ]; then
        echo 0
        return
    fi
    printf '%s\n' "$1" | wc -l | tr -d ' '
}

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
        '.github/workflows/release-watchdog.yml:# создана: DS-IT-systems для агента read-only.'|\
        '.github/workflows/validate-template.yml:      # Имитируем pristine user: DS-strategy вместо DS-my-strategy, DayPlan с минимальным шаблоном.'|\
        'guide-kit/generator/personal_export.py:    pathlib.Path.home() / "IWE/DS-my-strategy/inbox/WP-425/cache/derived_snapshot.json"'|\
        'memory/protocol-work.md:| Заготовка | `DS-Knowledge-Index` status: draft | 14 дней | пост (published) / archive |'|\
        'memory/protocol-work.md:> **Черновик ≠ Заготовка.** Черновик — личный (DS-strategy). Заготовка — публичная (DS-Knowledge-Index).'|\
        'roles/strategist/prompts/week-review.md:Для этого запуска скрипт-обёртка уже открыла служебную сессию охраны (`week-review`, область `current/`) и закроет её сама. Свою сессию (`session-guard.sh open`) не открывай: на замороженном каталоге она отказана, а придуманное значение `--wp` охрана отвергает. В репозитории governance изменяй и коммить только файлы в `current/`; пост клуба (шаг 6) относится к репозиторию Knowledge Index (`DS-Knowledge-Index`), не к governance, и этой сессией не покрывается. Отказ охраны не обходи (`--force`, `--no-verify`, правка хуков): выведи дословный текст отказа в итоговый ответ. Скрипт-обёртка проверяет, что отчёт недели попал на сервер, и поднимет тревогу владельцу, если нет.'|\
        'roles/synchronizer/scripts/collectors.d/README.md:- `publications.sh` — публикации (если есть DS-Knowledge-Index-*/docs/)'|\
        'scripts/week-draft-init.sh:  echo "   knowledge_repo: \"DS-Knowledge-Index\""'|\
        '.claude/hooks/rule-engine.sh:        if ! echo "$file_path" | grep -qE '"'"'DS-[^/]+-strategy/|DS-ecosystem-development/'"'"'; then'|\
        'update-manifest.json:    "scripts/session-dispatcher-tsekh.py",'|\
        'setup.sh:    echo "  ⚠ Не найден python3 >= 3.10 с библиотекой PyYAML — календарь, лента «Мир», обзор РП и core-скрипты (artifactor.py, session-dispatcher-tsekh.py) будут отключаться с явной ошибкой зависимости."'|\
        'generate-manifest.sh:    "scripts/session-dispatcher-tsekh.py"       # no references from delivered artifacts'|\
        'seed/strategy/scripts/lib/find-python3.sh:# core scripts (artifactor.py, session-dispatcher-tsekh.py). Reject 3.9 early'|\
        '.claude/lib/find-python3.sh:# core scripts (artifactor.py, session-dispatcher-tsekh.py). Reject 3.9 early'|\
        'scripts/lib/find-python3.sh:# core scripts (artifactor.py, session-dispatcher-tsekh.py). Reject 3.9 early'|\
        'setup/build-runtime.sh:# bug-2026-09-17-tsekh1-recovery-backups-abort: under `set -eu`, a single'|\
        'setup/build-runtime.sh:# bug-2026-09-17-tsekh1-recovery-backups-abort (continuation): leftovers from'|\
        'update.sh:# author_release_regression FPATH PAYLOAD — bug-2026-09-17-tsekh1-release-') return 0 ;;
    esac
    return 1
}
filter_excluded_hits() {
    # $1: scanned root (worktree or staged snapshot); stdin: grep -r output
    # "<root>/<rel>:<line>:<text>" — drop excluded_paths
    # and exact workflow-context exceptions, retaining every other .yml hit.
    local root="$1" line abs rel numbered key seen=$'\n'
    while IFS= read -r line; do
        abs="${line%%:*}"
        rel="${abs#"$root"/}"
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

# Global (forbidden everywhere except CHANGELOG and GitHub URLs)
# grep -i below: "tserentserenov" always appeared in the code as
# "TserenTserenov" (mixed-case) — case-sensitive grep never caught it, it was
# caught only by the paired pattern "DS-my-strategy" on the same lines (2026-07-27).
# One pipeline for every mode (issue #1457): docs/adr/ — historical ADR docs
# describing the past authorial install (issue #308), same exemption class as
# LEARNING-PATH.md/CHANGELOG.md.
author_global_hits() {
    grep -rin "$1" "$SCAN_ROOT" --include="*.md" --include="*.sh" \
        --include="*.py" --include="*.json" --include="*.plist" --include="*.yaml" --include="*.yml" \
        --exclude='validate-template.sh' --exclude='LEARNING-PATH.md' \
        --exclude='CHANGELOG.md' --exclude='aisystant-sync-targets.yaml' \
        --exclude='translation-manifest.yaml' 2>/dev/null \
        | grep -v 'github.com/' | grep -v 'docs/adr/' | grep -v 'githubusercontent\.com' \
        | grep -viE 'TserenTserenov/(FMT-exocortex-template|ZP|SPF)' \
        | filter_excluded_hits "$SCAN_ROOT" || true
}
for pattern in "tserentserenov" "PACK-MIM" "aist_bot_newarchitecture" \
               "DS-Knowledge-Index" "DS-IT-systems" "DS-ai-systems" \
               "DS-my-strategy" "engines/tailor" "tsekh" "DS-ecosystem-development" \
               "tseren" "aist_pilot_bot"; do
    hits=$(author_global_hits "$pattern")
    count=$(count_hits "$hits")
    if [ "$count" -gt 0 ]; then
        [ "$CHECK1_FAIL" -eq 0 ] && echo "FAIL"
        echo "  Found '$pattern' (global) in $count locations:"
        printf '%s\n' "$hits" | head -3 | display_hits || true
        CHECK1_FAIL=1
        FAIL=1
    fi
done

# Protocol-only — forbidden in protocols/skills/hooks/CLAUDE.md (allowed in README/docs/onboarding as a product mention)
for pattern in "@aist_me_bot" "digital-twin" "content-pipeline" \
               "knowledge-mcp" "gateway-mcp" "DS-agent-workspace/scheduler"; do
    hits=$(cd "$SCAN_ROOT" && grep -rn "$pattern" \
            .claude/skills .claude/hooks .claude/rules memory CLAUDE.md 2>/dev/null \
            | grep -v 'CHANGELOG.md' || true)
    count=$(count_hits "$hits")
    if [ "$count" -gt 0 ]; then
        [ "$CHECK1_FAIL" -eq 0 ] && echo "FAIL"
        echo "  Found '$pattern' (protocol-only) in $count locations:"
        printf '%s\n' "$hits" | head -3 || true
        CHECK1_FAIL=1
        FAIL=1
    fi
done

# staged mode: WARN about forbidden content in unstaged changes (does not
# block — parallel agents). Only the files `git diff` reports as changed in
# the worktree are read, not the whole tree (issue #1457).
if [ "$MODE" = "staged" ]; then
    UNSTAGED_FILES=()
    while IFS= read -r -d '' f; do
        case "$f" in *.md|*.sh|*.py|*.yaml|*.yml) ;; *) continue ;; esac
        case "${f##*/}" in validate-template.sh|CHANGELOG.md) continue ;; esac
        [ -f "$TEMPLATE_DIR/$f" ] && UNSTAGED_FILES+=("$f")
    done < <(cd "$TEMPLATE_DIR" && git diff --name-only -z 2>/dev/null || true)
    if [ "${#UNSTAGED_FILES[@]}" -gt 0 ]; then
        warn_hits=$(cd "$TEMPLATE_DIR" && grep -in -e "tserentserenov" -e "PACK-MIM" \
                    -e "aist_bot_newarchitecture" -e "DS-IT-systems" -- "${UNSTAGED_FILES[@]}" 2>/dev/null \
                    | grep -v 'github.com/' || true)
        if [ -n "$warn_hits" ]; then
            echo "  WARN (staged mode): unstaged files contain forbidden patterns — OK for parallel-agent workflow, review before next commit"
        fi
    fi
fi
[ "$CHECK1_FAIL" -eq 0 ] && echo "PASS"

# Common extension list for checks 2 and 3 (issue #247 item 2: count and print used to
# scan different --include sets, so FAIL (N hits) could show
# no lines at all if the hit was only in *.json/*.plist).
# --exclude-dir=guide-kit: vendored byte-identical release slice (WP-483) —
# the CI drift gate forbids in-place edits, so scanning it here would deadlock
# two blocking gates; its own upstream CI is responsible for content checks.
HARDCODE_SCAN_INCLUDES=(--include="*.md" --include="*.sh" --include="*.json" --include="*.plist" --exclude-dir="guide-kit")

# 2. No hardcoded /Users/ or C:\Users\ paths [pristine + staged; skip
# only installed]. In installed mode setup.sh legitimately substituted
# $WORKSPACE_DIR -> /Users/<user>/... (issue #835: previously only the
# POSIX macOS style matched — a native Windows path like C:\Users\<user>\... got
# through this barrier unnoticed).
HARDCODE_USER_PATH_RE='/Users/\|C:\\Users\\'
# Third alternative excludes placeholder instructional text (QUICK-START.md
# telling a Windows user to type their own name) — same intent as the
# existing "# ... e.g." exclusion for POSIX comments, just not restricted to
# `#`-comments since this one lives in markdown prose, not a script comment.
HARDCODE_USER_PATH_EXCLUDE_RE='/Users/\.\.\./|C:\\Users\\\.\.\.|# .*(/Users/|C:\\Users\\|e\.g\.)|C:\\Users\\(твоё-имя|<[^>]+>)'
# Files where /Users/ is not a hardcoded path but a search pattern for such paths
# (the default settings guard WP-7 and its test). Exclusion by file, not by
# line: a line exclusion would let the same text pass in any other file.
# One list of paths from the template root for both modes, matched against
# the whole relative path (^...$): exactly these files are dropped, not
# any files with the same name in other directories.
HARDCODE_USER_PATH_SKIP_FILES=(scripts/check-shipped-config-secrets.sh scripts/tests/test_template_hygiene_checks.sh)
HARDCODE_USER_PATH_SKIP_FILES_RE=''
for _skip in "${HARDCODE_USER_PATH_SKIP_FILES[@]}"; do
    HARDCODE_USER_PATH_SKIP_FILES_RE="${HARDCODE_USER_PATH_SKIP_FILES_RE:+$HARDCODE_USER_PATH_SKIP_FILES_RE|}^$(printf '%s' "$_skip" | sed 's/[.]/\\./g')\$"
done
unset _skip
hardcode_user_path_hits() {
    grep -rn "$HARDCODE_USER_PATH_RE" "$SCAN_ROOT" "${HARDCODE_SCAN_INCLUDES[@]}" \
        --exclude='validate-template.sh' --exclude='setup.sh' \
        --exclude='CHANGELOG.md' 2>/dev/null \
        | drop_hits_in_paths "$SCAN_ROOT" "$HARDCODE_USER_PATH_SKIP_FILES_RE" \
        | grep -vE "$HARDCODE_USER_PATH_EXCLUDE_RE" || true
}
echo -n "[2/5] Hardcoded /Users/ or C:\\Users\\ paths... "
if [ "$MODE" = "installed" ]; then
    echo "SKIP (installed mode — путь подставлен setup'ом)"
else
    hits=$(hardcode_user_path_hits)
    count=$(count_hits "$hits")
    if [ "$count" -gt 0 ]; then
        echo "FAIL ($count hits)"
        printf '%s\n' "$hits" | head -3 | display_hits || true
        FAIL=1
    else
        echo "PASS"
    fi
fi

# 3. No hardcoded /opt/homebrew paths [pristine + staged; skip only installed]
# In installed mode CLAUDE_PATH=/opt/homebrew/bin/claude is a legitimate substitution.
#
# Path-scoped exceptions, one list for every mode (issue #1457): README.md,
# PLATFORM-COMPAT.md and the CI workflow document the standard prefix (#530).
# The shipped resolver copies are sanctioned exceptions (WP-529 F6,
# #453/#463): their job is enumerating STANDARD system Python locations
# (/opt/homebrew is stock macOS Apple Silicon), not an author-machine leak.
# secret-bypass-lib.sh (WP-544 D28) is the same class: it resolves
# jq/python3 across the standard FHS locations on macOS (both Intel
# /usr/local/bin and Apple Silicon /opt/homebrew/bin) and Linux (/usr/bin,
# /bin), falling back to PATH-based `command -v` only for non-standard
# layouts (NixOS) — an absolute-path-first resolver by design, not a
# hardcoded personal path.
HOMEBREW_SKIP_FILES_RE='^README\.md$|^docs/PLATFORM-COMPAT\.md$|^\.github/workflows/validate-template\.yml$|^\.claude/lib/find-python3\.sh$|^scripts/lib/find-python3\.sh$|^seed/strategy/scripts/lib/find-python3\.sh$|^\.claude/hooks/secret-bypass-lib\.sh$|^scripts/tests/test_issue_463_setup_reuses_resolved_python3\.sh$'
homebrew_hits() {
    grep -rn '/opt/homebrew' "$SCAN_ROOT" "${HARDCODE_SCAN_INCLUDES[@]}" \
        --exclude='validate-template.sh' --exclude='setup.sh' \
        --exclude='CHANGELOG.md' 2>/dev/null \
        | drop_hits_in_paths "$SCAN_ROOT" "$HOMEBREW_SKIP_FILES_RE" \
        | grep -v '/usr/local/bin.*:/opt/homebrew' || true
}
echo -n "[3/5] Hardcoded /opt/homebrew paths... "
if [ "$MODE" = "installed" ]; then
    echo "SKIP (installed mode — CLAUDE_PATH может быть /opt/homebrew/...)"
else
    hits=$(homebrew_hits)
    count=$(count_hits "$hits")
    if [ "$count" -gt 0 ]; then
        echo "FAIL ($count hits)"
        printf '%s\n' "$hits" | head -3 | display_hits || true
        FAIL=1
    else
        echo "PASS"
    fi
fi

# 4. MEMORY.md — skeleton (<=15 lines in the table) [pristine only]
# In installed mode MEMORY is filled by the user's work (WPs, notes).
echo -n "[4/5] MEMORY.md is skeleton... "
if [ "$MODE" = "installed" ]; then
    echo "SKIP (installed mode — MEMORY заполняется работой)"
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

# 6. No hardcoded script paths in protocols/skills (WP-219, DP.FM.009)
# Protocols and skills must use $IWE_SCRIPTS / $IWE_ROLES / $IWE_TEMPLATE / $IWE_WORKSPACE
# instead of absolute paths to FMT-exocortex-template/scripts|roles or bare ~/IWE/scripts.
# Enumerate-all: collect ALL violations across all patterns, print as a list, then fail (prevents iterative fix-retry).
echo -n "[6/6] Hardcoded script paths in protocols/skills... "
CHECK6_FAIL=0
CHECK6_HITS=""
# Pattern 1-2: references to the FMT-template path (legacy DP.FM.009)
# Pattern 3: bare `bash ~/IWE/scripts/X.sh` or `bash $HOME/IWE/scripts/X.sh` without fallback to $IWE_SCRIPTS
#   (excludes correct `bash ${IWE_SCRIPTS:-$HOME/IWE/scripts}/X.sh`, since after `bash ` comes `${`, not `~` or `$HOME`)
for pattern in 'FMT-exocortex-template/scripts' \
               'FMT-exocortex-template/roles/[a-z]*/scripts' \
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
    echo "  Должен быть \$IWE_SCRIPTS / \$IWE_ROLES (или \${IWE_SCRIPTS:-\$HOME/IWE/scripts} для inline-команд):"
    echo "$CHECK6_HITS"
else
    echo "PASS"
fi

# 7. settings.json hooks ↔ .claude/hooks/ cross-ref (issue #13)
# Check in both directions:
#   (a) FAIL: hook mentioned in settings.json but the file is missing in .claude/hooks/
#   (b) WARN: hook exists in .claude/hooks/ but is not mentioned in any settings.json
#       (may be invoked directly, e.g. wakatime-heartbeat.sh)
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
        # The directory historically holds not only Claude hooks. We do not guess by
        # name: a standalone service/CLI/library must explicitly declare the
        # contract in its own header. A new unclassified file will still
        # produce a warning and require the owner's decision.
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
            echo "  WARN: hook $name не упомянут в settings.json (может быть dead code или прямой вызов)"
        fi
    done
    [ "$CHECK7_FAIL" -eq 0 ] && [ "$ORPHAN_WARN" -eq 0 ] && echo "PASS"
fi

# 8. Stale FPF semantic references (issue #390 follow-up).
# A.2 and A.2.1 are valid on their own for roles and assignments. Only two
# provably false bindings are forbidden: the removed A.6.8 and treating the word mastery/
# «мастерство» as an A.2 entity. In installed mode user memory may
# contain historical quotes, so the check applies only to the delivered
# pristine/staged template.
echo -n "[8/8] Obsolete FPF semantic references... "
if [ "$MODE" = "installed" ]; then
    echo "SKIP (installed mode — пользовательская память может содержать исторические цитаты)"
else
    FPF_STALE_PATTERN='A\.6\.8|(mastery|мастерство).*A\.2([^0-9.]|$)'
    FPF_STALE_HITS=$(grep -rniE "$FPF_STALE_PATTERN" \
        "$SCAN_ROOT/memory" "$SCAN_ROOT/.claude" "$SCAN_ROOT/docs" \
        --include='*.md' 2>/dev/null || true)

    if [ -n "$FPF_STALE_HITS" ]; then
        echo "FAIL"
        printf '%s\n' "$FPF_STALE_HITS" | display_hits | sed 's/^/  /'
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
# documents a hook as ACTIVE protection ("Hook `x.sh` блокирует ..." / "hook
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
#   (b) the word "hook" or "хук" (case-insensitive),
#   (c) an enforcement verb — blocks/guards/prevents/denies/stops/enforces
#       (EN) or блокир/защища/запрещ/отказ (RU), either case.
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
    ENFORCE_RE='block|Block|блокир|Блокир|guard|Guard|защища|Защища|запрещ|Запрещ|prevent|Prevent|enforc|Enforc|deni|Deni|отказ|Отказ|stop|Stop'
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
            | grep -Ei 'hook|хук' | grep -E "$ENFORCE_RE" || true)
        if [ -n "$hits" ]; then
            [ "$CHECK9_FAIL" -eq 0 ] && echo "FAIL"
            echo "  $hookname: SKILL.md заявляет активную защиту (хук + блокирующий глагол в одной строке), но хук не зарегистрирован под PreToolUse ни в одном settings.json:"
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
