#!/usr/bin/env bash
# #1010: bounded proof records must never discard existing records or edits.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
TMP=$(mktemp -d)
trap 'rm -rf -- "$TMP"' EXIT
PYTHON=$("$ROOT/.claude/lib/find-python3.sh")
LIMIT=1048576
HASH=$(printf '%064d' 0)
FAIL=0
PASS=0

check() {
    local description=$1
    shift
    if "$@"; then
        PASS=$((PASS + 1))
    else
        printf 'FAIL: %s\n' "$description" >&2
        FAIL=$((FAIL + 1))
    fi
}

rejects_put() {
    if memory_record_put "$@"; then return 1; fi
}

extract() {
    awk -v signature="$2() {" '$0 == signature {copy=1} copy {print} copy && /^}$/ {exit}' "$1"
}

make_record() {
    "$PYTHON" - "$1" "$2" "$HASH" <<'PY'
import sys
from pathlib import Path
path, size, digest = sys.argv[1:]
prefix = f"memory/note.md\t{digest}\n".encode()
Path(path).write_bytes(prefix + b"x" * (int(size) - len(prefix)))
PY
}

for source in setup.sh update.sh; do
    # setup has no reader; both writers must preserve the same invariant.
    eval "$(extract "$ROOT/$source" memory_record_size_ok)"
    eval "$(extract "$ROOT/$source" memory_record_put)"
    eval "$(extract "$ROOT/update.sh" memory_record_get)"
    dir="$TMP/${source%.sh}"
    mkdir -p "$dir"
    record="$dir/record.tsv"
    : > "$record"
    check "$source: empty record accepts first proof" memory_record_put "$record" memory/note.md "$HASH"
    check "$source: first proof is readable" test "$(memory_record_get "$record" memory/note.md)" = "$HASH"
    printf 'memory/note.md\t%s' "$HASH" > "$record"
    check "$source: final newline is optional" test "$(memory_record_get "$record" memory/note.md)" = "$HASH"
    make_record "$record" "$LIMIT"
    check "$source: exact limit remains readable" test "$(memory_record_get "$record" memory/note.md)" = "$HASH"
    make_record "$record" "$((LIMIT + 1))"
    cp "$record" "$dir/before"
    check "$source: oversized record proves nothing" test -z "$(memory_record_get "$record" memory/note.md)"
    check "$source: oversized record rejects get-to-put transition" rejects_put "$record" memory/new.md "$HASH"
    check "$source: rejected get-to-put leaves record intact" cmp -s "$record" "$dir/before"
    make_record "$record" 128
    cp "$record" "$dir/before"
    stat() { return 1; }
    check "$source: failed size check proves nothing" test -z "$(memory_record_get "$record" memory/note.md)"
    check "$source: failed size check prevents rewriting" rejects_put "$record" memory/new.md "$HASH"
    unset -f stat
    check "$source: failed size check keeps previous record" cmp -s "$record" "$dir/before"
    # Valid input just below the limit, but a new key would exceed it.
    "$PYTHON" - "$record" "$LIMIT" "$HASH" <<'PY'
import sys
from pathlib import Path
path, limit, digest = sys.argv[1:]
row = b"k" * (int(limit) - len(digest) - 3) + b"\t" + digest.encode() + b"\n"
Path(path).write_bytes(row)
PY
    cp "$record" "$dir/before"
    check "$source: oversized candidate is rejected before rename" rejects_put "$record" memory/new.md "$HASH"
    check "$source: candidate rejection keeps previous record" cmp -s "$record" "$dir/before"
    check "$source: candidate rejection removes temporary files" test "$(find "$dir" -name 'record.tsv.*' | wc -l | tr -d ' ')" = 0
    rm -f "$record"
    printf 'memory/note.md\t%s\n' "$HASH" > "$dir/target"
    ln -s "$dir/target" "$record"
    check "$source: symlink proves nothing" test -z "$(memory_record_get "$record" memory/note.md)"
    check "$source: symlink writer is rejected" rejects_put "$record" memory/new.md "$HASH"
    check "$source: symlink stays a symlink" test -L "$record"
    rm -f "$record"
    mkfifo "$record"
    check "$source: fifo proves nothing without reading it" test -z "$(memory_record_get "$record" memory/note.md)"
    check "$source: fifo cannot be replaced" rejects_put "$record" memory/new.md "$HASH"
done

for fn in hash_file memory_decided_once memory_reason_text memory_copy_verdict \
    saving_cp_command backup_memory_file_before_overwrite replace_memory_copy \
    remember_memory_deployed apply_memory_policy; do
    eval "$(extract "$ROOT/update.sh" "$fn")"
done
SCRIPT_DIR="$TMP/policy/template"
WORKSPACE_DIR="$TMP/policy/workspace"
mkdir -p "$SCRIPT_DIR/memory" "$WORKSPACE_DIR/memory"
printf 'platform revision\n' > "$SCRIPT_DIR/memory/note.md"
printf 'user customization\n' > "$WORKSPACE_DIR/memory/note.md"
cp "$WORKSPACE_DIR/memory/note.md" "$TMP/custom-before"
MEMORY_DEPLOYED_RECORD="$WORKSPACE_DIR/.memory-deployed.tsv"
HASH=$(hash_file "$WORKSPACE_DIR/memory/note.md")
make_record "$MEMORY_DEPLOYED_RECORD" "$((LIMIT + 1))"
cp "$MEMORY_DEPLOYED_RECORD" "$TMP/proof-before"
MEMORY_POLICY_SEEN=""
MEMORY_BACKUP_RUN=""
MEMORY_RECORD_WARNED=false
MEMORY_KEPT=()
MEMORY_REPLACED=()
if apply_memory_policy memory/note.md "$WORKSPACE_DIR/memory/note.md" > "$TMP/policy.out" 2>&1; then
    printf 'FAIL: oversized proof authorized replacement\n' >&2
    FAIL=$((FAIL + 1))
fi
check 'updater preserves customization despite a matching oversized proof' cmp -s "$WORKSPACE_DIR/memory/note.md" "$TMP/custom-before"
check 'updater leaves oversized proof intact' cmp -s "$MEMORY_DEPLOYED_RECORD" "$TMP/proof-before"
check 'updater names the file it kept' grep -q 'memory/note.md — НЕ обновлён' "$TMP/policy.out"
check 'updater does not create a replacement backup' test ! -e "$WORKSPACE_DIR/.backups"

check 'setup/update writers stay identical' diff -u <(extract "$ROOT/setup.sh" memory_record_put) <(extract "$ROOT/update.sh" memory_record_put)
check 'setup/update size checks stay identical' diff -u <(extract "$ROOT/setup.sh" memory_record_size_ok) <(extract "$ROOT/update.sh" memory_record_size_ok)
printf 'memory record limit: %s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
