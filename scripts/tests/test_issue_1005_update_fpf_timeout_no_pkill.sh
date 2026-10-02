#!/usr/bin/env bash
# Issue #1005 (update.sh part): refresh_fpf_base_clone killed the timed-out git
# fetch with `pkill -P`, which Git Bash on Windows does not have -- the git
# child could outlive the timeout. Fixed: without pkill the process tree is
# killed with taskkill (Windows pid from /proc/<pid>/winpid).
# Real Windows is not available: simulated by a PATH that has no pkill, a stub
# taskkill that records its arguments, and a fake proc dir ($IWE_PROC_DIR).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

eval "$(awk '
  /^refresh_fpf_base_clone\(\)/ { capture=1 }
  capture { print }
  capture && /^}/ { exit }
' "$ROOT/update.sh")"
declare -F refresh_fpf_base_clone >/dev/null || fail "refresh_fpf_base_clone not found in update.sh"

export GIT_CONFIG_GLOBAL="$TMP/gitconfig" GIT_CONFIG_NOSYSTEM=1
: > "$GIT_CONFIG_GLOBAL"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
# Prefer a real git binary over a wrapper script (a wrapper that calls `git`
# through PATH would recurse into the shim below).
REAL_GIT=""
while IFS= read -r cand; do
    if [ "$(head -c 4 "$cand" 2>/dev/null | od -An -c | tr -d ' ')" = '177ELF' ]; then
        REAL_GIT="$cand"; break
    fi
done < <(type -ap git)
[ -n "$REAL_GIT" ] || REAL_GIT="$(command -v git)"

WORKSPACE_DIR="$TMP/workspace"
mkdir -p "$WORKSPACE_DIR/FPF"
"$REAL_GIT" -C "$WORKSPACE_DIR/FPF" -c init.defaultBranch=main init -q
echo one > "$WORKSPACE_DIR/FPF/Readme.md"
"$REAL_GIT" -C "$WORKSPACE_DIR/FPF" add Readme.md
"$REAL_GIT" -C "$WORKSPACE_DIR/FPF" commit -q -m first

# Minimal PATH: the usual tools, deliberately WITHOUT pkill.
TOOLS="$TMP/tools"
PROC="$TMP/proc"
mkdir -p "$TOOLS" "$PROC"
# Mirror every tool of the current PATH except pkill (the real git may be a
# wrapper script that needs arbitrary helpers).
IFS=: read -r -a path_dirs <<<"$PATH"
for d in "${path_dirs[@]}"; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
        n="$(basename "$f")"
        [ "$n" = pkill ] && continue
        [ -x "$f" ] && [ ! -e "$TOOLS/$n" ] && ln -s "$f" "$TOOLS/$n"
    done
done
[ -e "$TOOLS/pkill" ] && fail "test setup: pkill leaked into the stub PATH"

# Replace (never write through) the mirrored symlinks.
rm -f "$TOOLS/git" "$TOOLS/taskkill"

# git shim: a fetch that never returns; publishes a fake Windows pid first.
cat > "$TOOLS/git" <<SHIM
#!/bin/bash
for a in "\$@"; do
    if [ "\$a" = fetch ]; then
        mkdir -p "$PROC/\$\$"
        echo 4242 > "$PROC/\$\$/winpid"
        exec sleep 30
    fi
done
exec "$REAL_GIT" "\$@"
SHIM
cat > "$TOOLS/taskkill" <<STUB
#!/bin/bash
echo "\$*" >> "$TMP/taskkill.args"
STUB
chmod +x "$TOOLS/git" "$TOOLS/taskkill"

started=$(date +%s)
out=$(PATH="$TOOLS" IWE_PROC_DIR="$PROC" IWE_FPF_FETCH_TIMEOUT=2 refresh_fpf_base_clone 2>&1)
elapsed=$(( $(date +%s) - started ))
[ "$elapsed" -lt 12 ] || fail "watchdog did not fire (${elapsed}s): $out"
grep -q 'не ответил' <<<"$out" || fail "no timeout message: $out"
[ -f "$TMP/taskkill.args" ] || fail "taskkill was not used without pkill (child tree left running)"
grep -q '4242' "$TMP/taskkill.args" || fail "taskkill got no Windows pid: $(cat "$TMP/taskkill.args")"
grep -q '//T' "$TMP/taskkill.args" || fail "taskkill not asked for the process tree: $(cat "$TMP/taskkill.args")"

echo "PASS: issue 1005 update.sh fetch timeout without pkill (4 checks)"
