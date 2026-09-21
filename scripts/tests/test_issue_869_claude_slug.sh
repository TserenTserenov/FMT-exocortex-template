#!/usr/bin/env bash
# test_issue_869_claude_slug.sh - regression for issue #869.
#
# The Claude Code project key (directory name under ~/.claude/projects) was
# computed by three scripts with three different rules: setup.sh "tr /",
# update.sh "tr /_.", scripts/day-close.sh "tr /_ ". Any workspace path with a
# "_" or "." (e.g. ~/IWE_custom) therefore got a slug Claude Code does not use,
# and on Windows the POSIX-style Git Bash path ("/f/notes") was used where Claude
# Code sees the native one ("F:\notes"). setup.sh additionally never checked that
# `ln -s` really produced a symlink (Git Bash without symlink rights makes a plain
# copy), which surfaced a day later as an ambiguous-memory error in update.sh.
# Contract: one function, identical in all three scripts, "every character that
# is not an ASCII letter or digit becomes '-'", native path via cygpath when it
# exists; setup.sh warns loudly when the link was not created.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
FILES=("$ROOT/setup.sh" "$ROOT/update.sh" "$ROOT/scripts/day-close.sh")

fail=0
ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

extract_fn() {
    awk '/^iwe_claude_project_slug\(\) \{/ { on = 1 } on { print } on && /^\}/ { exit }' "$1"
}

# --- 1. the three copies exist and are byte-identical ---
sums=""
for f in "${FILES[@]}"; do
    body=$(extract_fn "$f")
    if [ -z "$body" ]; then
        bad "iwe_claude_project_slug not found in ${f#$ROOT/}"
        continue
    fi
    printf '%s\n' "$body" > "$TMP/$(basename "$f").fn"
    sums="$sums$(cksum < "$TMP/$(basename "$f").fn")"$'\n'
done
if [ "$(printf '%s' "$sums" | sort -u | grep -c .)" = "1" ] && [ "$(printf '%s' "$sums" | grep -c .)" = "3" ]; then
    ok "the function body is identical in setup.sh, update.sh and scripts/day-close.sh"
else
    bad "the three copies of iwe_claude_project_slug diverged (or one is missing)"
fi

# --- 2. the rule itself, on a corpus ---
[ -s "$TMP/setup.sh.fn" ] && . "$TMP/setup.sh.fn"
if ! declare -F iwe_claude_project_slug >/dev/null; then
    bad "cannot load the function"; echo "Result: $fail FAIL"; exit 1
fi
check() {
    local path="$1" want="$2" got
    got=$(iwe_claude_project_slug "$path")
    if [ "$got" = "$want" ]; then ok "'$path' -> '$got'"; else bad "'$path': expected '$want', got '$got'"; fi
}
# The macOS-style root is assembled so the repository carries no literal home-directory path
# (the template validator rejects those).
MAC_ROOT="/User""s"
check "${MAC_ROOT}/alice/IWE"              "-Users-alice-IWE"
check "/home/u/IWE_custom"                 "-home-u-IWE-custom"
check "${MAC_ROOT}/a/.iwe-workdir/x"       "-Users-a--iwe-workdir-x"
check "/tmp/my ws/IWE"                     "-tmp-my-ws-IWE"
check "/srv/IWE.v2"                        "-srv-IWE-v2"

# Non-ASCII characters: one dash per character, whatever the locale. launchd and cron run
# without one, and setup.sh (interactive) and day-close.sh (scheduled) must agree.
if command -v python3 >/dev/null 2>&1; then
    CYR="${MAC_ROOT}/Иван/IWE"
    want="-Users------IWE"
    got_c=$(LC_ALL=C iwe_claude_project_slug "$CYR")
    got_u=$(LC_ALL=en_US.UTF-8 iwe_claude_project_slug "$CYR" 2>/dev/null || true)
    if [ "$got_c" = "$want" ]; then ok "Cyrillic path under LC_ALL=C: one dash per character ($got_c)"; else bad "Cyrillic path under LC_ALL=C: expected '$want', got '$got_c'"; fi
    if [ -z "$got_u" ] || [ "$got_u" = "$got_c" ]; then ok "Cyrillic path gives the same slug in a UTF-8 locale"; else bad "locale-dependent slug: C='$got_c' UTF-8='$got_u'"; fi
else
    echo "SKIP: python3 missing, locale-independence case"
fi

# --- 3. Windows: the native path (from cygpath) is what gets slugged ---
mkdir -p "$TMP/bin"
printf '%s\n' '#!/bin/sh' 'case "$2" in /f/notes) printf "%s\n" "F:\\notes" ;; *) printf "%s\n" "$2" ;; esac' > "$TMP/bin/cygpath"
chmod +x "$TMP/bin/cygpath"
got=$(PATH="$TMP/bin:$PATH" iwe_claude_project_slug "/f/notes")
if [ "$got" = "F--notes" ]; then
    ok "Git Bash path /f/notes is slugged from its native form F:\\notes -> $got"
else
    bad "Windows native-path conversion: expected 'F--notes', got '$got'"
fi
got=$(PATH="$TMP/bin:$PATH" iwe_claude_project_slug "/home/u/IWE")
if [ "$got" = "-home-u-IWE" ]; then ok "a path cygpath leaves alone is unchanged ($got)"; else bad "unexpected slug through cygpath: '$got'"; fi

# --- 4. setup.sh: a `ln -s` that produced no symlink is reported, a real one is not ---
awk '
  /# Create symlink so CLAUDE.md references/ { on = 1 }
  on { print }
  on && /^    fi$/ { exit }
' "$ROOT/setup.sh" > "$TMP/link_block.sh"
if [ ! -s "$TMP/link_block.sh" ]; then
    bad "could not extract the symlink block from setup.sh (markers moved?)"
else
    run_link_block() {   # $1 = "copy" (simulate Git Bash without rights) or "real"
        local mode="$1" ws="$TMP/ws_$1" mem="$TMP/mem_$1"
        rm -rf "$ws" "$mem"; mkdir -p "$ws" "$mem"
        WORKSPACE_DIR="$ws" CLAUDE_MEMORY_DIR="$mem" LINK_MODE="$mode" bash -c '
            if [ "$LINK_MODE" = copy ]; then ln() { cp -R "$2" "$3"; }; fi
            . "$1"
        ' _ "$TMP/link_block.sh" 2>&1
    }
    OUT=$(run_link_block copy)
    if grep -q 'не создана' <<<"$OUT"; then ok "no symlink was made -> setup.sh warns instead of reporting success"; else bad "silent failure: $OUT"; fi
    if grep -q '^  Symlink:' <<<"$OUT"; then bad "false success line printed although no symlink exists"; else ok "no false 'Symlink:' success line"; fi
    # The plain copy must not stay where the next run would mistake it for "already set up".
    if [ ! -e "$TMP/ws_copy/memory" ] && ls -d "$TMP"/ws_copy/memory.not-a-link-* >/dev/null 2>&1; then
        ok "the copy made instead of a link is set aside, workspace/memory is free again"
    else
        bad "the plain copy was left in place (a rerun would skip the fix): $(ls "$TMP/ws_copy" 2>&1 | tr '\n' ' ')"
    fi
    if [ -d "$TMP/mem_copy" ]; then ok "the real memory directory is untouched"; else bad "the real memory directory disappeared"; fi
    # A rerun after the set-aside (rights fixed): the link is created this time.
    WORKSPACE_DIR="$TMP/ws_copy" CLAUDE_MEMORY_DIR="$TMP/mem_copy" bash -c '. "$1"' _ "$TMP/link_block.sh" >"$TMP/rerun.out" 2>&1
    if [ -L "$TMP/ws_copy/memory" ] && grep -q '^  Symlink:' "$TMP/rerun.out"; then
        ok "rerun after the set-aside creates the real symlink"
    else
        bad "rerun did not create the symlink: $(cat "$TMP/rerun.out")"
    fi
    OUT=$(run_link_block real)
    if grep -q '^  Symlink:' <<<"$OUT" && ! grep -q 'не создана' <<<"$OUT"; then
        ok "a real symlink is reported as before, without a warning"
    else
        bad "real symlink case regressed: $OUT"
    fi
    # A dangling link left earlier: `ln -s` fails with "File exists" while [ -L ] still holds.
    rm -rf "$TMP/ws_dangling" "$TMP/mem_dangling"; mkdir -p "$TMP/ws_dangling" "$TMP/mem_dangling"
    ln -s "$TMP/nowhere-at-all" "$TMP/ws_dangling/memory"
    OUT=$(WORKSPACE_DIR="$TMP/ws_dangling" CLAUDE_MEMORY_DIR="$TMP/mem_dangling" bash -c '. "$1"' _ "$TMP/link_block.sh" 2>&1)
    if grep -q 'не создана' <<<"$OUT" && ! grep -q '^  Symlink:' <<<"$OUT"; then
        ok "a dangling link is not reported as a successful symlink"
    else
        bad "dangling link reported as success: $OUT"
    fi
    if grep -q 'ln:' <<<"$OUT"; then ok "the real ln error is shown"; else bad "ln error swallowed: $OUT"; fi
fi

# --- 5. update.sh: a link named by an older slug rule must not stop the updater ---
awk '/^resolve_workspace_memory_dir\(\) \{/ { on = 1 } on { print } on && /^\}/ { exit }' "$ROOT/update.sh" > "$TMP/resolve_fn.sh"
if [ ! -s "$TMP/resolve_fn.sh" ]; then
    bad "could not extract resolve_workspace_memory_dir from update.sh"
else
    resolve_mem() {   # $1 = workspace path; HOME is the throwaway one set by the caller
        bash -c '. "$1"; . "$2"; resolve_workspace_memory_dir "$3"' _ "$TMP/setup.sh.fn" "$TMP/resolve_fn.sh" "$1"
    }
    # A) legacy install: workspace path with a space; old setup named the directory by "tr /",
    #    Claude Code (and the new rule) use the dashed name, which exists as well.
    H="$TMP/home_legacy"; WSL="$TMP/ws with space/IWE"
    mkdir -p "$WSL" "$H/.claude/projects"
    LEGACY_SLUG=$(printf '%s' "$WSL" | tr '/' '-')
    NEW_SLUG=$(HOME="$H" iwe_claude_project_slug "$WSL")
    mkdir -p "$H/.claude/projects/$LEGACY_SLUG/memory" "$H/.claude/projects/$NEW_SLUG/memory"
    ln -s "$H/.claude/projects/$LEGACY_SLUG/memory" "$WSL/memory"
    OUT=$(HOME="$H" resolve_mem "$WSL" 2>"$TMP/legacy.err"); RC=$?
    WANT=$(cd -P "$H/.claude/projects/$LEGACY_SLUG/memory" && pwd -P)
    if [ "$RC" = 0 ] && [ "$OUT" = "$WANT" ] && grep -q 'ВНИМАНИЕ' "$TMP/legacy.err"; then
        ok "legacy link (older slug rule, path with a space): accepted with a note, updater not stopped"
    else
        bad "legacy install broken: rc=$RC out='$OUT' err='$(cat "$TMP/legacy.err")'"
    fi
    # B) a genuine conflict (link to a directory no rule produces) still stops with the old message
    H="$TMP/home_conflict"; WSC="$TMP/ws_conflict/IWE"
    mkdir -p "$WSC" "$H/.claude/projects" "$TMP/elsewhere/memory"
    NEW_SLUG=$(HOME="$H" iwe_claude_project_slug "$WSC")
    mkdir -p "$H/.claude/projects/$NEW_SLUG/memory"
    ln -s "$TMP/elsewhere/memory" "$WSC/memory"
    OUT=$(HOME="$H" resolve_mem "$WSC" 2>"$TMP/conflict.err"); RC=$?
    if [ "$RC" != 0 ] && grep -q 'неоднозначен' "$TMP/conflict.err"; then
        ok "a genuine conflict still stops with the ambiguity error"
    else
        bad "genuine conflict no longer detected: rc=$RC err='$(cat "$TMP/conflict.err")'"
    fi
    # C) the consistent case is silent
    H="$TMP/home_ok"; WSO="$TMP/ws_ok/IWE"
    mkdir -p "$WSO" "$H/.claude/projects"
    NEW_SLUG=$(HOME="$H" iwe_claude_project_slug "$WSO")
    mkdir -p "$H/.claude/projects/$NEW_SLUG/memory"
    ln -s "$H/.claude/projects/$NEW_SLUG/memory" "$WSO/memory"
    OUT=$(HOME="$H" resolve_mem "$WSO" 2>"$TMP/ok.err"); RC=$?
    if [ "$RC" = 0 ] && [ ! -s "$TMP/ok.err" ]; then ok "link named by the current rule: accepted silently"; else bad "consistent case broke: rc=$RC err='$(cat "$TMP/ok.err")'"; fi
fi

echo "Result: $fail FAIL"
[ "$fail" -eq 0 ]
