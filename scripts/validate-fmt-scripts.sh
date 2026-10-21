#!/usr/bin/env bash
# routing: utility  deterministic=true
# see DP.SC.159, DP.ROLE.059
# validate-fmt-scripts.sh — validation FMT for personal hardcodes and convention violations
# Runs automatically from template-sync.sh and manually when suspected.
#
# Usage:
#   bash validate-fmt-scripts.sh [scripts-dir] [--scripts|--settings-json|--all]
#
#   --scripts       check scripts only (1, 2, 4) — default together with --all
#   --settings-json check only .claude/settings.json (check 3)
#   --all           full check [default]
#
# What it checks:
#   1. *.sh/*.py: absolute home path of the user (/Users/<name> or /home/<name>)
#   2. *.sh/*.py: bare name of the author governance-repo without ${VAR:-default} protection
#   3. .claude/settings.json: hook-commands for .claude/hooks/X.sh must have the prefix
#      $CLAUDE_PROJECT_DIR/ (otherwise they break when cwd shifts: subagent/worktree/MCP cwd: subagent/worktree/MCP)
#   4. *.sh under set -e: ((VAR++)) without || true → silent exit when VAR==0 (B8 gap)
#   5. .claude/skills/*/SKILL.md: $HOME/IWE/<author-repo>/ and ~/IWE/<author-repo>/
#      without env-fallback ${IWE_GOVERNANCE_REPO:-...} (WP-337 Z-Phase6, 1 June 2026)
#   6. .claude/skills/*/SKILL.md: L1 layer without the marker <!-- USER-SPACE -->
#   7. .claude/skills/*/SKILL.md: L1 layer with an unreplaced <!-- L3-author: KEY=value --> (WP-5)

set -uo pipefail

MODE="all"
SCRIPTS_DIR=""
FILES=()
MODE_FILES=0
for arg in "$@"; do
    case "$arg" in
        --scripts)       MODE="scripts" ;;
        --settings-json) MODE="settings-json" ;;
        --all)           MODE="all" ;;
        --files)         MODE_FILES=1 ;;   # FMT7 (#150): subsequent positional arguments = specific files
        *)
            if [ "$MODE_FILES" = "1" ] && [ -f "$arg" ]; then
                FILES+=("$arg")
            else
                SCRIPTS_DIR="$arg"
            fi ;;
    esac
done
SCRIPTS_DIR="${SCRIPTS_DIR:-$(dirname "$0")}"
if [ ${#FILES[@]} -eq 0 ] && [ ! -d "$SCRIPTS_DIR" ]; then
    echo "validate-fmt-scripts: SCRIPTS_DIR must be a directory: $SCRIPTS_DIR" >&2
    exit 1
fi
FMT_ROOT="$(cd "$SCRIPTS_DIR/.." && pwd)"
AUTHOR_HOME="${HOME}"
AUTHOR_GOV_REPO="${IWE_GOVERNANCE_REPO:-DS-strategy}"

errors=0
checked=0

if [[ "$MODE" != "settings-json" ]]; then
    # FMT7: specific files were passed (--files) → check only those files, otherwise scan the entire directory
    if [ ${#FILES[@]} -gt 0 ]; then
        TARGETS=("${FILES[@]}")
    else
        TARGETS=("$SCRIPTS_DIR"/*.sh "$SCRIPTS_DIR"/*.py)
    fi
    for f in "${TARGETS[@]}"; do
        [[ -f "$f" ]] || continue
        fname=$(basename "$f")
        # Do not check itself
        [[ "$fname" == "validate-fmt-scripts.sh" ]] && continue
        checked=$((checked + 1))

        # Check 1: absolute personal path (resolved $HOME, not a variable)
        if grep -qF "$AUTHOR_HOME" "$f" 2>/dev/null; then
            echo "  ❌ $fname: contains '$AUTHOR_HOME'" >&2
            grep -nF "$AUTHOR_HOME" "$f" | head -3 | sed 's/^/     /' >&2
            errors=$((errors + 1))
        fi

        # Check 2: bare name of the author governance-repo (without env-var fallback)
        # Allowed::
        #   - ${IWE_GOVERNANCE_REPO:-DS-strategy}  (bash default)
        #   - ${IWE_GOVERNANCE_REPO:?...}          (bash required)
        #   - os.environ.get("GOVERNANCE_REPO", "DS-strategy")  (python fallback)
        #   - os.environ.get("IWE_GOVERNANCE_REPO") or "DS-strategy"
        #     (python fallback for unset AND empty values, issue #1038)
        #   - GOV_REPO_TMPL="DS-strategy"          (template identity literal)
        #   - VAR="DS-strategy" \                  (env override in the command, line cont)
        #   - cmd || echo "DS-strategy"            (bare fallback after ||, issue #275)
        #   - if [ -d "$DIR/DS-strategy" ]; ... case DS-strategy)  (auto-detect idiom,
        #     physical check for repo existence, not a hardcoded leak, issue #275, not a hardcoded-leak, issue #275)
        #   - a line containing a reference to the variable $IWE_GOVERNANCE_REPO or its dict-dict key
        #     "IWE_GOVERNANCE_REPO": — structurally demonstrates an override, not, not
        #     merely contains the variable name somewhere-in a comment (issues #446/#450)
        #   - the file resides in scripts/tests/ -- a test fixture legitimately uses a literal scripts/tests/ — test fixture legitimately uses the literal
        #     of the default name as a value, not as a leak of a personal repo (issues #446/#450)
        # Forbidden: literal name governance-repo outside fallback-pattern in executable lines
        # Comments (#) are skipped — documentation does not affect behavior
        #
        # issue #275: patterns "|| echo <literal>" and "if [ -d .../<literal> ]" are excluded
        # only when <literal> appears on the line EXACTLY ONCE — otherwise, for example,
        # `cd ".../DS-strategy" || echo "DS-strategy"` (real hardcode in cd, disguised
        # safe fallback-tail) would pass unnoticed, i.e. the tail of the line matches
        # safe-pattern, even when the beginning of the line contains a separate dangerous hardcode, dangerous hardcode.
        # issue #759: previously `case ... *) <check> ;; esac` — three branches-exclusions
        # no-op'or via `:`, the default branch carried the entire check. Adding
        # the fourth branch is moved into a flag, the check remains one, below the case, below case.
        #
        # Guard by shebang/+x (was discussed when closing the issue issue) does not work here:
        # files .claude/hooks/tests/*.sh — are themselves real executable test-
        # harnesses with shebang (run directly), not fixtures-as-file-as-file.
        # A fixture is a STRING LITERAL inside expect ... pass ... — this is a STRING LITERAL inside `expect "..." pass '...'`
        # (a call argument), not the whole file; file-level guard cannot
        # distinguish a literal from code inside a single real executable file.
        # Therefore the exclusion here — the same unconditional path-based, as with
        # scripts/tests/* (issues #446/#450): the whole directory — test
        # wrapper by convention, its contents are not scanned.
        skip_hardcode_check=0
        case "$f" in
            scripts/tests/*|*/scripts/tests/*) skip_hardcode_check=1 ;;  # issues #446/#450: convention fixtures for scripts/tests/ scripts/tests/ — do not scan. Narrower, than */tests/* — other tests/-repo directories (.claude/skills/*/tests/, guide-kit/tests/) continue to be checked as usual.
            setup/test-*|*/setup/test-*|setup/smoke-test-*|*/setup/smoke-test-*) skip_hardcode_check=1 ;;  # issue #499: test-wrappers setup/ by naming convention — their fail-messages and grep-patterns CONTAIN the literal as the subject of their own check; class-based path exclusion (not a per-line heuristic), remaining setup/ is scanned as before.
            setup/validate-template.sh|*/setup/validate-template.sh) skip_hardcode_check=1 ;;  # WP-544 D28: same class, as #499 — this file itself scans the repo for author-specific literals (check [1/5]) via a string array in a for for-loop; its own list of patterns — subject of the check, not hardcode. Do not quote literals verbatim in this comment — this itself would be caught [1/5] in the file itself validate-fmt-scripts.sh.
            .claude/hooks/tests/*|*/.claude/hooks/tests/*) skip_hardcode_check=1 ;;  # issue #759: hook test fixtures-tests — same class, as scripts/tests/.
        esac
        if [ "$skip_hardcode_check" != "1" ]; then
        if grep -q "$AUTHOR_GOV_REPO" "$f" 2>/dev/null; then
            bad_lines=$(grep -n "$AUTHOR_GOV_REPO" "$f" \
                | grep -v '^\s*#\|^[0-9]*:\s*#' \
                | grep -v '\${[^}]*:-' \
                | grep -v '\${[^}]*:?' \
                | grep -vE '^[0-9]*:[[:space:]]*[A-Z_]+_TMPL=' \
                | grep -vE "os\.environ\.get\([^)]*,[[:space:]]*[\"']" \
                | grep -vE '^[0-9]*:\s*[A-Z_][A-Z0-9_]*="[^"]*"[[:space:]]*[\\]$' \
                | grep -vE '\$IWE_GOVERNANCE_REPO|"IWE_GOVERNANCE_REPO"[[:space:]]*:' \
                || true)
            if [[ -n "$bad_lines" ]]; then
                bad_lines=$(echo "$bad_lines" | while IFS= read -r bl; do
                    line_content="${bl#*:}"
                    occurrences=$(grep -o "$AUTHOR_GOV_REPO" <<<"$line_content" | wc -l | tr -d ' ')
                    if [[ "$occurrences" -eq 1 ]]; then
                        # Python's `or` matches shell `${VAR:-default}` for both
                        # an unset and an empty variable. Require one literal on
                        # the line so an unrelated hardcode cannot hide next to it.
                        if echo "$bl" | grep -qE "os\\.environ\\.get\\([\"']IWE_GOVERNANCE_REPO[\"']\\)[[:space:]]+or[[:space:]]+[\"']${AUTHOR_GOV_REPO}[\"']"; then
                            continue
                        fi
                        if echo "$bl" | grep -qE "\\|\\|[[:space:]]*echo[[:space:]]+\"$AUTHOR_GOV_REPO\"[[:space:]]*\\)?[[:space:]]*\$"; then
                            continue
                        fi
                        if echo "$bl" | grep -qE '^[0-9]*:[[:space:]]*if \[ -d "[^"]*/'"$AUTHOR_GOV_REPO"'" \]; then$'; then
                            continue
                        fi
                        if echo "$bl" | grep -qE '^[0-9]*:[[:space:]]*[A-Za-z0-9_*|-]*\|?'"$AUTHOR_GOV_REPO"'\)[[:space:]]*$'; then
                            continue
                        fi
                        # auto-detect idiom, continuation (issue #450): follow-up
                        # assignment INSIDE an already safe `if [ -d .../LITERAL" ]; then`
                        # (the if itself if the line above already matmatches the pattern at 2 checks earlier) — that
                        # same physical detect, not a separate hardcode. Safe only for
                        # bare `VAR="LITERAL"` without a trailing part — does not expand the pattern to lines
                        # with something-else after the literal.
                        if echo "$bl" | grep -qE '^[0-9]*:[[:space:]]*[A-Z_][A-Z0-9_]*="'"$AUTHOR_GOV_REPO"'"[[:space:]]*$'; then
                            lineno="${bl%%:*}"
                            prev_line=$(sed -n "$((lineno - 1))p" "$f" 2>/dev/null)
                            if echo "$prev_line" | grep -qE '^[[:space:]]*if \[ -d "[^"]*/'"$AUTHOR_GOV_REPO"'" \]; then$'; then
                                continue
                            fi
                        fi
                        # issue #665: bare literal as a positional fallback-default
                        # argument to a helper call, split across lines —
                        # `_selected_env(values, "IWE_GOVERNANCE_REPO",
                        # "GOVERNANCE_REPO", "DS-strategy")`. The literal's own line
                        # carries no env-var reference, but the call it belongs to
                        # does (same "structural override, not a mystery hardcode"
                        # reasoning as the $IWE_GOVERNANCE_REPO exception above).
                        # Safe only when the override key literal sits in the SAME
                        # call — walk back through the immediately preceding,
                        # unbroken run of non-blank, non-comment lines (a blank or
                        # `#`-only line marks a statement boundary) and stop looking
                        # there. Cold-context review finding: a plain fixed-size
                        # lookback window matched an unrelated `#`-comment mention of
                        # "IWE_GOVERNANCE_REPO" a few lines above a genuine hardcode
                        # in a different call — the statement-boundary stop closes
                        # that false negative.
                        if echo "$bl" | grep -qE '^[0-9]*:[[:space:]]*"'"$AUTHOR_GOV_REPO"'"[[:space:]]*,?[[:space:]]*\)?[[:space:]]*,?[[:space:]]*$'; then
                            lineno="${bl%%:*}"
                            found_override_key=0
                            check_line=$((lineno - 1))
                            steps=0
                            while [ "$check_line" -ge 1 ] && [ "$steps" -lt 6 ]; do
                                context_line=$(sed -n "${check_line}p" "$f" 2>/dev/null)
                                if echo "$context_line" | grep -qE '^[[:space:]]*$|^[[:space:]]*#'; then
                                    break
                                fi
                                if echo "$context_line" | grep -qE '"IWE_GOVERNANCE_REPO"'; then
                                    found_override_key=1
                                    break
                                fi
                                check_line=$((check_line - 1))
                                steps=$((steps + 1))
                            done
                            if [ "$found_override_key" -eq 1 ]; then
                                continue
                            fi
                        fi
                        # issue #1135: the literal's only occurrence sits inside a
                        # trailing comment that explains why the code earlier on
                        # the line already covers it (e.g. a shellcheck directive
                        # reference, another issue number, or a WP- id) — same
                        # "comments don't affect behavior" contract as the
                        # whole-line-comment skip above. Two conditions, both
                        # required: (a) the literal must actually disappear once
                        # we cut from the first whitespace-preceded `#` onward —
                        # a hardcode sitting BEFORE that `#`, with an unrelated
                        # marker word further in the same trailing comment, must
                        # still be caught; (b) what remains of the comment must
                        # carry one of the markers actually seen in practice —
                        # staying a narrow whitelist, not "any trailing comment",
                        # since a general comment/quote-aware parser is not
                        # reliable here (a `#` can legitimately sit inside a
                        # quoted string too).
                        if ! echo "$bl" | sed -E 's/[[:space:]]#.*$//' | grep -q "$AUTHOR_GOV_REPO"; then
                            if echo "$bl" | grep -qE '[[:space:]]#.*\b(shellcheck|WP-[0-9]+|issue[[:space:]]*#[0-9]+)\b'; then
                                continue
                            fi
                        fi
                    fi
                    echo "$bl"
                done)
            fi
            if [[ -n "$bad_lines" ]]; then
                echo "  ❌ $fname: '$AUTHOR_GOV_REPO' without env fallback in the code" >&2
                echo "$bad_lines" | head -3 | sed 's/^/     /' >&2
                errors=$((errors + 1))
            fi
        fi
        fi

        # Check 4: set -e + ((VAR++)) without || true → silent exit when VAR==0 (B8 gap)
        # $((VAR + 1)) — safe (arithmetic, not a command).
        # ((VAR++)) without || true — dangerous: when VAR=0 command returns 0 → set -e terminates the script.
        if grep -qE 'set -[a-z]*e|set -e' "$f" 2>/dev/null; then
            bad_arith=$(grep -nE '^\s*\(\([^)]+(\+\+|--|\+=|-=)[^)]*\)\)\s*$' "$f" \
                | grep -v '|| true' \
                | grep -v '^\s*#' || true)
            if [[ -n "$bad_arith" ]]; then
                echo "  ⚠ $fname: set -e + ((VAR++)) without || true — script will terminate if VAR==0" >&2
                echo "$bad_arith" | head -5 | sed 's/^/     /' >&2
                echo "     → Replace with: ((VAR++)) || true" >&2
                errors=$((errors + 1))
            fi
        fi
    done

    if [[ $checked -eq 0 && "$MODE" != "settings-json" ]]; then
        echo "validate-fmt-scripts: no files to check in $SCRIPTS_DIR"
    fi
fi

if [[ "$MODE" != "scripts" && "$MODE" != "settings-json" ]]; then
    # Check 5: .claude/skills/*/SKILL.md — literal hardcoded file paths
    # Catches: $HOME/IWE/<author-repo>/scripts/... and ~/IWE/<author-repo>/scripts/...
    # Allowed: $HOME/IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/scripts/... (env-fallback)
    # Allowed: bare DS-strategy in comments/documentation
    SKILLS_DIR="$FMT_ROOT/.claude/skills"
    if [[ -d "$SKILLS_DIR" ]]; then
        skills_checked=0
        while IFS= read -r -d '' md_file; do
            skills_checked=$((skills_checked + 1))
            fname=${md_file#$FMT_ROOT/}

            # Pattern 1: $HOME/IWE/<author-repo-name>/(scripts|sessions|docs|current)/
            # WITHOUT env-fallback ${...:-...}. Excluding: # comments, echo, printf, export
            bad_home=$(grep -nE '\$HOME/IWE/[A-Za-z][A-Za-z0-9_-]+/(scripts|sessions|docs|current)/' "$md_file" 2>/dev/null \
                | grep -v ':\s*#' \
                | grep -v ':\s*>' \
                | grep -vE 'echo |printf |export ' \
                | grep -vE '\$\{[A-Z_]+:-[A-Za-z0-9_-]+\}' \
                || true)
            if [[ -n "$bad_home" ]]; then
                echo "  ❌ $fname: \$HOME/IWE/<author-repo>/ without env-fallback" >&2
                echo "$bad_home" | head -3 | sed 's/^/     /' >&2
                errors=$((errors + 1))
            fi

            # Pattern 2: ~/IWE/<author-repo>/(scripts|sessions|docs|current)/  (Python expanduser)
            bad_tilde=$(grep -nE '~/IWE/[A-Za-z][A-Za-z0-9_-]+/(scripts|sessions|docs|current)/' "$md_file" 2>/dev/null \
                | grep -v ':\s*#' \
                | grep -v ':\s*>' \
                | grep -vE 'echo |printf |export ' \
                | grep -vE '\$\{[A-Z_]+:-[A-Za-z0-9_-]+\}' \
                || true)
            if [[ -n "$bad_tilde" ]]; then
                echo "  ❌ $fname: ~/IWE/<author-repo>/ without env-fallback" >&2
                echo "$bad_tilde" | head -3 | sed 's/^/     /' >&2
                errors=$((errors + 1))
            fi
        done < <(find "$SKILLS_DIR" -type f -name "*.md" -print0 2>/dev/null)

        if [[ $skills_checked -gt 0 ]]; then
            checked=$((checked + skills_checked))
        fi

        # Check 6: L1 SKILL.md files must carry USER-SPACE marker block
        # Check 7: L1 SKILL.md must not carry an unresolved L3-author value (WP-5 L1/L3-separation)
        # Checks BOTH marker forms — unresolved (skill-promote.sh never ran) AND resolved
        # (skill-promote.sh ran but the substitution silently failed, e.g. a sed-special
        # character in `value` broke the replacement) — a resolved marker whose placeholder
        # is NOT actually present in the file means the value leaked through unreplaced.
        while IFS= read -r -d '' md_file; do
            fname="${md_file#$FMT_ROOT/}"
            if grep -qE '^layer:[[:space:]]*L1' "$md_file" 2>/dev/null; then
                if ! grep -q '^<!-- USER-SPACE -->' "$md_file" 2>/dev/null; then
                    echo "  ❌ $fname: L1 SKILL.md without marker <!-- USER-SPACE -->" >&2
                    echo "     → Run: bash \$IWE_SCRIPTS/add-skill-markers.sh" >&2
                    errors=$((errors + 1))
                fi

                l3_leftover=""
                while IFS= read -r marker; do
                    [ -n "$marker" ] || continue
                    key=$(printf '%s' "$marker" | sed -E 's/^<!-- L3-author: ([A-Za-z_][A-Za-z0-9_]*)=.*/\1/')
                    val=$(printf '%s' "$marker" | sed -E 's/^<!-- L3-author: [A-Za-z_][A-Za-z0-9_]*=(.*), in template → \{\{[A-Za-z0-9_]+\}\}$/\1/')
                    [ -n "$key" ] && [ -n "$val" ] || continue
                    grep -qF "\"$val\"" "$md_file" 2>/dev/null && l3_leftover="${l3_leftover}${key}=${val}
"
                done < <(grep -oE '<!-- L3-author: [A-Za-z_][A-Za-z0-9_]*=[^,]+, in template → \{\{[A-Za-z0-9_]+\}\}' "$md_file" 2>/dev/null)

                while IFS= read -r marker; do
                    [ -n "$marker" ] || continue
                    key=$(printf '%s' "$marker" | sed -E 's/^<!-- L3-author: ([A-Za-z_][A-Za-z0-9_]*) was here.*/\1/')
                    placeholder=$(printf '%s' "$marker" | grep -oE '\{\{[A-Za-z0-9_]+\}\}')
                    [ -n "$key" ] && [ -n "$placeholder" ] || continue
                    grep -qF "\"$placeholder\"" "$md_file" 2>/dev/null \
                        || l3_leftover="${l3_leftover}${key}: marker resolved, but \"${placeholder}\" not found in file — substitution did not take effect
"
                done < <(grep -oE '<!-- L3-author: [A-Za-z_][A-Za-z0-9_]* was here, replaced with \{\{[A-Za-z0-9_]+\}\}' "$md_file" 2>/dev/null)

                if [[ -n "$l3_leftover" ]]; then
                    echo "  ❌ $fname: L3-author value not replaced with {{PLACEHOLDER}} during promotion" >&2
                    echo "$l3_leftover" | sed '/^$/d; s/^/     /' >&2
                    errors=$((errors + 1))
                fi
            fi
        done < <(find "$SKILLS_DIR" -name "SKILL.md" -print0 2>/dev/null)
    fi
fi

if [[ "$MODE" != "scripts" ]]; then
    # Check 3: .claude/settings.json — hook-commands must use the prefix $CLAUDE_PROJECT_DIR/
    SETTINGS_JSON="$FMT_ROOT/.claude/settings.json"
    if [[ -f "$SETTINGS_JSON" ]]; then
        if command -v jq >/dev/null 2>&1; then
            # Extract all .hooks.*[].hooks[].command, find those, that reference .claude/hooks/
            bad_cmds=$(jq -r '.hooks // {} | to_entries[] | .value[] | .hooks[]? | .command // empty' "$SETTINGS_JSON" \
                | grep -E '\.claude/hooks/' \
                | grep -vE '^\$CLAUDE_PROJECT_DIR/' || true)
            if [[ -n "$bad_cmds" ]]; then
                echo "  ❌ .claude/settings.json: hook-commands without the prefix \$CLAUDE_PROJECT_DIR/" >&2
                echo "$bad_cmds" | sed 's/^/     /' >&2
                echo "     → Replace with \$CLAUDE_PROJECT_DIR/.claude/hooks/<name>.sh" >&2
                echo "     → Docs: https://code.claude.com/docs/en/hooks#reference-scripts-by-path" >&2
                errors=$((errors + 1))
            fi
        else
            echo "  ⚠ jq not found, skipping check of .claude/settings.json" >&2
        fi
    fi
fi

if [[ $errors -eq 0 ]]; then
    label=""
    if [[ "$MODE" == "scripts" ]]; then
        label="$checked script(s) checked"
    elif [[ "$MODE" == "settings-json" ]]; then
        label="settings.json checked"
    else
        label="$checked files + settings.json checked"
    fi
    echo "✅ validate-fmt-scripts: $label, no violations"
    exit 0
else
    echo "❌ validate-fmt-scripts: $errors violations — fix before committing to FMT" >&2
    exit 1
fi
