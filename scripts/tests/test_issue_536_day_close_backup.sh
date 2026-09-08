#!/usr/bin/env bash
# Regression for issue #536: Day Close owns only the files it copied, keeps
# byte-preserving configuration backups, and restores workspace-level params
# to the workspace rather than to Claude auto-memory.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DAY_CLOSE="$ROOT/scripts/day-close.sh"
RESTORE="$ROOT/scripts/restore-from-exocortex.sh"
MEMORY_HOOK="$ROOT/.claude/hooks/memory-exocortex-sync.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/iwe-issue-536-backup.XXXXXX")"
BACKUP_MANIFEST=".day-close-backup-manifest.json"
BACKUP_QUARANTINE=".day-close-backup-incomplete"

FAIL=0
fail() { echo "  ❌ FAIL: $*" >&2; FAIL=$((FAIL + 1)); }
pass() { echo "  ✅ PASS: $*"; }

# Invoked indirectly by the trap below.
# shellcheck disable=SC2329
cleanup() {
    local rc=$?
    rm -rf -- "$TEST_ROOT"
    exit "$rc"
}
trap cleanup EXIT INT TERM

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

run_backup() {
    local workspace=$1 memory=$2 output=$3
    env \
        HOME="$workspace/home" \
        PATH="$PATH" \
        WORKSPACE_DIR="$workspace" \
        IWE_ROOT="$workspace" \
        IWE_WORKSPACE="$workspace" \
        IWE_TEMPLATE="$ROOT" \
        IWE_SCRIPTS="$ROOT/scripts" \
        IWE_GOVERNANCE_REPO="governance" \
        GOVERNANCE_REPO="governance" \
        IWE_MEMORY_SRC="$memory" \
        IWE_DAY_CLOSE_LOG="$workspace/logs/day-close.log" \
        bash "$DAY_CLOSE" --backup >"$output" 2>&1
}

run_restore() {
    local workspace=$1 memory=$2 output=$3
    shift 3
    env \
        HOME="$workspace/home" \
        PATH="$PATH" \
        WORKSPACE_DIR="$workspace" \
        IWE_ROOT="$workspace" \
        IWE_WORKSPACE="$workspace" \
        IWE_GOVERNANCE_REPO="governance" \
        GOVERNANCE_REPO="governance" \
        IWE_MEMORY_SRC="$memory" \
        bash "$RESTORE" "$workspace/governance" "$@" >"$output" 2>&1
}

write_rhythm_v1() {
    printf '%s\n' \
        '# user comment must survive' \
        'zeta: keep-first' \
        'day_open:' \
        '  # calendar explanation' \
        '  calendar_ids:' \
        '    - personal' \
        'alpha: keep-last' > "$1"
}

write_rhythm_v2() {
    printf '%s\n' \
        '# second revision: exact bytes are the contract' \
        'zeta: still-first' \
        'day_open:' \
        '  calendar_ids: [personal, work]  # inline comment' \
        'alpha: still-last' > "$1"
}

assert_guard_signal() {
    local rc=$1 output=$2 pattern=$3 label=$4
    if [ "$rc" -ne 0 ] || grep -Eiq "$pattern" "$output"; then
        pass "$label is observable"
    else
        fail "$label was silently ignored"
    fi
}

wait_for_barrier() {
    local ready=$1 process_id=$2 attempt=0
    while [ "$attempt" -lt 1500 ]; do
        [ -f "$ready" ] && return 0
        kill -0 "$process_id" 2>/dev/null || return 1
        sleep 0.01
        attempt=$((attempt + 1))
    done
    return 1
}

echo "=== Backup ownership and byte preservation ==="
CASE="$TEST_ROOT/backup"
WORKSPACE="$CASE/workspace"
MEMORY="$CASE/auto-memory"
EXOCORTEX="$WORKSPACE/governance/exocortex"
mkdir -p \
    "$WORKSPACE/home" \
    "$MEMORY/reference" \
    "$MEMORY/extensions" \
    "$MEMORY/agent-fault-profile" \
    "$MEMORY/hindsight" \
    "$MEMORY/decisions" \
    "$MEMORY/rules" \
    "$EXOCORTEX/memory"

write_rhythm_v1 "$MEMORY/day-rhythm-config.yaml"
printf 'managed, unchanged\n' > "$MEMORY/owned-unchanged.md"
printf 'managed, later edited in backup\n' > "$MEMORY/owned-modified.md"
printf 'nested managed file\n' > "$MEMORY/reference/managed.yaml"
printf 'must not become memory-owned\n' > "$MEMORY/CLAUDE.md"
printf 'must not become memory-owned\n' > "$MEMORY/AGENTS.md"
printf 'protected\n' > "$MEMORY/extensions/private.md"
printf 'protected\n' > "$MEMORY/agent-fault-profile/private.md"
printf 'protected\n' > "$MEMORY/hindsight/private.md"
printf 'protected\n' > "$MEMORY/decisions/private.md"
printf 'protected\n' > "$MEMORY/rules/private.md"
printf '# workspace params\nprofile: private\n' > "$WORKSPACE/params.yaml"
printf 'foreign markdown\n' > "$EXOCORTEX/foreign.md"
printf 'foreign: yaml\n' > "$EXOCORTEX/foreign.yaml"
printf 'unowned legacy subtree\n' > "$EXOCORTEX/memory/foreign.md"

FIRST_RC=0
run_backup "$WORKSPACE" "$MEMORY" "$CASE/first.out" || FIRST_RC=$?
if [ "$FIRST_RC" -eq 0 ]; then
    pass "first real day-close --backup run succeeds"
else
    fail "first real day-close --backup run failed (rc=$FIRST_RC)"
fi

if cmp -s "$MEMORY/day-rhythm-config.yaml" "$EXOCORTEX/day-rhythm-config.yaml"; then
    pass "first day-rhythm backup is byte-identical"
else
    fail "first day-rhythm backup changed bytes"
fi
if [ -f "$EXOCORTEX/params.yaml" ] && cmp -s "$WORKSPACE/params.yaml" "$EXOCORTEX/params.yaml"; then
    pass "workspace params.yaml is backed up byte-for-byte"
else
    fail "workspace params.yaml is absent or differs in exocortex"
fi
if [ -f "$EXOCORTEX/foreign.md" ] && [ -f "$EXOCORTEX/foreign.yaml" ]; then
    pass "foreign root Markdown/YAML survive the first sync"
else
    fail "the first sync deleted foreign root Markdown/YAML"
fi
if [ "$(cat "$EXOCORTEX/memory/foreign.md" 2>/dev/null || true)" = "unowned legacy subtree" ]; then
    pass "unowned legacy exocortex/memory subtree survives backup"
else
    fail "backup recursively deleted unowned exocortex/memory data"
fi

LEDGER="$EXOCORTEX/$BACKUP_MANIFEST"
if [ -s "$LEDGER" ]; then
    pass "backup writes a non-empty ownership manifest"
    if python3 - "$LEDGER" <<'PYEOF'
import json
import re
import sys


with open(sys.argv[1], encoding="utf-8") as stream:
    payload = json.load(stream)
files = payload.get("files", {})
required = {"owned-unchanged.md", "owned-modified.md", "reference/managed.yaml"}
forbidden_files = {
    "CLAUDE.md",
    "AGENTS.md",
    "day-rhythm-config.yaml",
    "params.yaml",
}
forbidden_roots = {
    "extensions",
    "agent-fault-profile",
    "hindsight",
    "decisions",
    "rules",
}
assert payload.get("schema_version") == 1
assert required <= set(files)
assert not (forbidden_files & set(files))
assert all(path.split("/", 1)[0] not in forbidden_roots for path in files)
assert all(re.fullmatch(r"[0-9a-f]{64}", value) for value in files.values())
PYEOF
    then
        pass "manifest contains only owned memory paths with sha256 values"
    else
        fail "manifest schema/owned-set exclusions are wrong"
    fi
else
    fail "backup did not write $BACKUP_MANIFEST"
    # Continue the negative control on pre-fix code with the contract schema
    # that the production fix is expected to emit.
    UNCHANGED_HASH=$(sha256_file "$EXOCORTEX/owned-unchanged.md")
    MODIFIED_HASH=$(sha256_file "$EXOCORTEX/owned-modified.md")
    printf '%s\n' \
        '{' \
        '  "schema_version": 1,' \
        '  "files": {' \
        "    \"owned-unchanged.md\": \"$UNCHANGED_HASH\"," \
        "    \"owned-modified.md\": \"$MODIFIED_HASH\"" \
        '  }' \
        '}' > "$LEDGER"
fi

# The second run changes a byte-sensitive config and removes two formerly
# managed files. Only the unmodified receiver copy may be pruned.
write_rhythm_v2 "$MEMORY/day-rhythm-config.yaml"
rm -- "$MEMORY/owned-unchanged.md" "$MEMORY/owned-modified.md"
if [ -f "$EXOCORTEX/owned-modified.md" ]; then
    printf 'receiver-side user edit must survive\n' > "$EXOCORTEX/owned-modified.md"
else
    fail "first backup did not copy owned-modified.md"
    printf 'receiver-side user edit must survive\n' > "$EXOCORTEX/owned-modified.md"
fi

SECOND_RC=0
run_backup "$WORKSPACE" "$MEMORY" "$CASE/second.out" || SECOND_RC=$?
if [ "$SECOND_RC" -eq 0 ]; then
    pass "second real day-close --backup run succeeds"
else
    fail "second real day-close --backup run failed (rc=$SECOND_RC)"
fi

if cmp -s "$MEMORY/day-rhythm-config.yaml" "$EXOCORTEX/day-rhythm-config.yaml"; then
    pass "second day-rhythm backup preserves comments and key order byte-for-byte"
else
    fail "second day-rhythm backup normalized or left stale bytes"
fi
if [ -f "$EXOCORTEX/params.yaml" ] && cmp -s "$WORKSPACE/params.yaml" "$EXOCORTEX/params.yaml"; then
    pass "params.yaml survives repeated backup"
else
    fail "params.yaml was lost or changed on repeated backup"
fi
if [ -f "$EXOCORTEX/foreign.md" ] && [ -f "$EXOCORTEX/foreign.yaml" ]; then
    pass "foreign root Markdown/YAML survive repeated backup"
else
    fail "repeated backup deleted foreign root Markdown/YAML"
fi
if [ "$(cat "$EXOCORTEX/memory/foreign.md" 2>/dev/null || true)" = "unowned legacy subtree" ]; then
    pass "unowned legacy exocortex/memory subtree survives repeated backup"
else
    fail "repeated backup deleted unowned exocortex/memory data"
fi
if [ ! -e "$EXOCORTEX/owned-unchanged.md" ]; then
    pass "removed upstream file is pruned when receiver hash still matches the manifest"
else
    fail "unchanged formerly-owned file was not pruned"
fi
if [ "$(cat "$EXOCORTEX/owned-modified.md" 2>/dev/null || true)" = "receiver-side user edit must survive" ]; then
    pass "modified formerly-owned receiver file survives"
else
    fail "modified formerly-owned receiver file was deleted or overwritten"
fi

echo "=== Empty source config is fail-closed and observable ==="
LEGACY="$TEST_ROOT/legacy-empty"
LEGACY_WS="$LEGACY/workspace"
LEGACY_MEMORY="$LEGACY/auto-memory"
LEGACY_EXO="$LEGACY_WS/governance/exocortex"
mkdir -p "$LEGACY_WS/home" "$LEGACY_MEMORY" "$LEGACY_EXO"
printf '%s\n' \
    '# template default deliberately has no selected calendars' \
    'day_open:' \
    '  calendar_ids: []' \
    'other: source-value' > "$LEGACY_MEMORY/day-rhythm-config.yaml"
printf 'ordinary memory still backs up\n' > "$LEGACY_MEMORY/ordinary.md"
printf '%s\n' \
    '# legacy destination contains the only usable copy' \
    'day_open:' \
    '  calendar_ids: [legacy]' \
    'other: preserve-me' > "$LEGACY_EXO/day-rhythm-config.yaml"
cp "$LEGACY_EXO/day-rhythm-config.yaml" "$LEGACY/expected.yaml"

LEGACY_RC=0
run_backup "$LEGACY_WS" "$LEGACY_MEMORY" "$LEGACY/run.out" || LEGACY_RC=$?
if cmp -s "$LEGACY/expected.yaml" "$LEGACY_EXO/day-rhythm-config.yaml"; then
    pass "empty source cannot erase a non-empty legacy destination"
else
    fail "empty source changed the non-empty legacy destination"
fi
assert_guard_signal \
    "$LEGACY_RC" "$LEGACY/run.out" \
    'day-rhythm-config[^[:cntrl:]]*(empty|пуст|zero[ -]?byte)' \
    "empty day-rhythm source refusal/warning"
if grep -q 'backup=warn' "$LEGACY/run.out"; then
    pass "calendar conflict is reflected in the final backup status"
else
    fail "calendar conflict warning was not reflected as backup=warn"
fi
if [ "$(cat "$LEGACY_EXO/ordinary.md" 2>/dev/null || true)" = "ordinary memory still backs up" ]; then
    pass "calendar guard does not abort the rest of backup"
else
    fail "calendar guard aborted or lost an ordinary memory copy"
fi

echo "=== Backup remains functional without PyYAML ==="
NOYAML="$TEST_ROOT/no-pyyaml"
NOYAML_WS="$NOYAML/workspace"
NOYAML_MEMORY="$NOYAML/auto-memory"
NOYAML_EXO="$NOYAML_WS/governance/exocortex"
mkdir -p "$NOYAML_WS/home" "$NOYAML_MEMORY" "$NOYAML_EXO" "$NOYAML/fakelib"
printf 'raise ImportError("mocked: no yaml")\n' > "$NOYAML/fakelib/yaml.py"
printf 'ordinary stdlib copy\n' > "$NOYAML_MEMORY/current.md"
printf 'day_open:\n  calendar_ids: [source]\n' > "$NOYAML_MEMORY/day-rhythm-config.yaml"
printf 'day_open:\n  calendar_ids: [destination]\n' > "$NOYAML_EXO/day-rhythm-config.yaml"
cp "$NOYAML_EXO/day-rhythm-config.yaml" "$NOYAML/expected-rhythm.yaml"
NOYAML_RC=0
PYTHONPATH="$NOYAML/fakelib" \
    run_backup "$NOYAML_WS" "$NOYAML_MEMORY" "$NOYAML/run.out" || NOYAML_RC=$?
if [ "$NOYAML_RC" -eq 0 ] && \
   [ "$(cat "$NOYAML_EXO/current.md" 2>/dev/null || true)" = "ordinary stdlib copy" ] && \
   [ -s "$NOYAML_EXO/$BACKUP_MANIFEST" ]; then
    pass "stdlib ownership backup works when PyYAML is unavailable"
else
    fail "missing PyYAML disabled the ordinary ownership backup (rc=$NOYAML_RC)"
fi
if cmp -s "$NOYAML/expected-rhythm.yaml" "$NOYAML_EXO/day-rhythm-config.yaml" && \
   grep -q 'backup=warn' "$NOYAML/run.out"; then
    pass "ambiguous rhythm is preserved and reported without PyYAML"
else
    fail "missing PyYAML overwrote rhythm or hid the warning status"
fi

BASH32_EMPTY="$TEST_ROOT/bash32-empty-specials"
BASH32_EMPTY_WS="$BASH32_EMPTY/workspace"
BASH32_EMPTY_MEMORY="$BASH32_EMPTY/auto-memory"
mkdir -p "$BASH32_EMPTY_WS/home" "$BASH32_EMPTY_MEMORY"
printf 'ordinary memory only\n' > "$BASH32_EMPTY_MEMORY/ordinary.md"
BASH32_EMPTY_RC=0
run_backup \
    "$BASH32_EMPTY_WS" "$BASH32_EMPTY_MEMORY" \
    "$BASH32_EMPTY/run.out" || BASH32_EMPTY_RC=$?
if [ "$BASH32_EMPTY_RC" -eq 0 ] && \
   [ -f "$BASH32_EMPTY_WS/governance/exocortex/ordinary.md" ]; then
    pass "backup with zero special targets is safe under Bash 3.2 nounset"
else
    fail "zero special targets triggered a Bash 3.2 nounset failure"
fi

echo "=== Ownership manifest is path-safe and fail-closed ==="
SECURITY="$TEST_ROOT/security"
SECURITY_WS="$SECURITY/workspace"
SECURITY_MEMORY="$SECURITY/auto-memory"
SECURITY_EXO="$SECURITY_WS/governance/exocortex"
OUTSIDE="$SECURITY/outside-sentinel.md"
mkdir -p "$SECURITY_WS/home" "$SECURITY_MEMORY" "$SECURITY_EXO"
printf 'ordinary source\n' > "$SECURITY_MEMORY/current.md"
printf 'must never be deleted\n' > "$OUTSIDE"
OUTSIDE_HASH=$(sha256_file "$OUTSIDE")
printf '%s\n' \
    '{' \
    '  "schema_version": 1,' \
    '  "files": {' \
    "    \"../../../outside-sentinel.md\": \"$OUTSIDE_HASH\"" \
    '  }' \
    '}' > "$SECURITY_EXO/$BACKUP_MANIFEST"

MALICIOUS_RC=0
run_backup "$SECURITY_WS" "$SECURITY_MEMORY" "$SECURITY/malicious.out" || MALICIOUS_RC=$?
if [ -f "$OUTSIDE" ] && [ "$(cat "$OUTSIDE")" = "must never be deleted" ]; then
    pass "traversal entry cannot delete outside exocortex"
else
    fail "traversal entry escaped exocortex and deleted/changed outside data"
fi
assert_guard_signal \
    "$MALICIOUS_RC" "$SECURITY/malicious.out" \
    '(manifest|манифест)[^[:cntrl:]]*(unsafe|invalid|travers|небезопас|некоррект|отказ)' \
    "unsafe manifest path refusal/warning"

printf 'must still never be deleted\n' > "$OUTSIDE"
printf '{ invalid json\n' > "$SECURITY_EXO/$BACKUP_MANIFEST"
printf 'copied despite invalid manifest\n' > "$SECURITY_MEMORY/after-invalid.md"
INVALID_RC=0
run_backup "$SECURITY_WS" "$SECURITY_MEMORY" "$SECURITY/invalid.out" || INVALID_RC=$?
if [ -f "$OUTSIDE" ] && [ "$(cat "$OUTSIDE")" = "must still never be deleted" ]; then
    pass "invalid manifest cannot delete outside exocortex"
else
    fail "invalid manifest caused an outside deletion/change"
fi
assert_guard_signal \
    "$INVALID_RC" "$SECURITY/invalid.out" \
    '(manifest|манифест)[^[:cntrl:]]*(invalid|parse|некоррект|ошиб|отказ)' \
    "invalid manifest refusal/warning"
if [ "$(cat "$SECURITY_EXO/after-invalid.md" 2>/dev/null || true)" = "copied despite invalid manifest" ]; then
    pass "invalid manifest disables deletion but still allows current source copies"
else
    fail "invalid manifest blocked or lost a current source copy"
fi

echo "=== Manifest version and receiver symlink boundaries ==="
VERSION="$TEST_ROOT/version-mismatch"
VERSION_WS="$VERSION/workspace"
VERSION_MEMORY="$VERSION/auto-memory"
VERSION_EXO="$VERSION_WS/governance/exocortex"
mkdir -p "$VERSION_WS/home" "$VERSION_MEMORY" "$VERSION_EXO"
printf 'current under mismatched manifest\n' > "$VERSION_MEMORY/current.md"
printf 'old receiver must survive\n' > "$VERSION_EXO/formerly-owned.md"
VERSION_HASH=$(sha256_file "$VERSION_EXO/formerly-owned.md")
printf '%s\n' \
    '{' \
    '  "schema_version": 2,' \
    '  "files": {' \
    "    \"formerly-owned.md\": \"$VERSION_HASH\"" \
    '  }' \
    '}' > "$VERSION_EXO/$BACKUP_MANIFEST"
VERSION_RC=0
run_backup "$VERSION_WS" "$VERSION_MEMORY" "$VERSION/run.out" || VERSION_RC=$?
if [ "$(cat "$VERSION_EXO/formerly-owned.md" 2>/dev/null || true)" = "old receiver must survive" ]; then
    pass "schema-version mismatch disables stale deletion"
else
    fail "schema-version mismatch deleted formerly-owned data"
fi
if [ "$(cat "$VERSION_EXO/current.md" 2>/dev/null || true)" = "current under mismatched manifest" ]; then
    pass "schema-version mismatch still allows current source copies"
else
    fail "schema-version mismatch blocked the current source copy"
fi
assert_guard_signal \
    "$VERSION_RC" "$VERSION/run.out" \
    '(manifest|манифест)[^[:cntrl:]]*(schema|version|верс|invalid|некоррект)' \
    "manifest schema-version mismatch"

SYMLINK="$TEST_ROOT/symlinks"
SYMLINK_WS="$SYMLINK/workspace"
SYMLINK_MEMORY="$SYMLINK/auto-memory"
SYMLINK_EXO="$SYMLINK_WS/governance/exocortex"
SYMLINK_OUTSIDE="$SYMLINK/outside"
mkdir -p "$SYMLINK_WS/home" "$SYMLINK_MEMORY" "$SYMLINK_EXO" "$SYMLINK_OUTSIDE"
printf 'new regular receiver\n' > "$SYMLINK_MEMORY/final.md"
printf 'outside final target remains\n' > "$SYMLINK_OUTSIDE/final-target.md"
ln -s "$SYMLINK_OUTSIDE/final-target.md" "$SYMLINK_EXO/final.md"
SYMLINK_RC=0
run_backup "$SYMLINK_WS" "$SYMLINK_MEMORY" "$SYMLINK/run.out" || SYMLINK_RC=$?
if [ "$SYMLINK_RC" -eq 0 ] && [ ! -L "$SYMLINK_EXO/final.md" ] && \
    [ -f "$SYMLINK_EXO/final.md" ] && \
    [ "$(cat "$SYMLINK_EXO/final.md")" = "new regular receiver" ]; then
    pass "final receiver symlink is replaced by a regular copied file"
else
    fail "final receiver symlink was followed or not replaced safely"
fi
if [ "$(cat "$SYMLINK_OUTSIDE/final-target.md")" = "outside final target remains" ]; then
    pass "final receiver symlink target remains untouched"
else
    fail "copy through final receiver symlink changed its outside target"
fi

INTERMEDIATE="$TEST_ROOT/intermediate-symlink"
INTERMEDIATE_WS="$INTERMEDIATE/workspace"
INTERMEDIATE_MEMORY="$INTERMEDIATE/auto-memory"
INTERMEDIATE_EXO="$INTERMEDIATE_WS/governance/exocortex"
INTERMEDIATE_OUTSIDE="$INTERMEDIATE/outside"
mkdir -p \
    "$INTERMEDIATE_WS/home" \
    "$INTERMEDIATE_MEMORY/nested" \
    "$INTERMEDIATE_EXO" \
    "$INTERMEDIATE_OUTSIDE"
printf 'must not be partially copied\n' > "$INTERMEDIATE_MEMORY/a-safe.md"
printf 'must not cross intermediate link\n' > "$INTERMEDIATE_MEMORY/nested/inside.md"
printf 'outside directory sentinel\n' > "$INTERMEDIATE_OUTSIDE/directory-sentinel.md"
printf 'stale receiver must survive preflight\n' > "$INTERMEDIATE_EXO/stale.md"
INTERMEDIATE_STALE_HASH=$(sha256_file "$INTERMEDIATE_EXO/stale.md")
printf '%s\n' \
    '{' \
    '  "schema_version": 1,' \
    '  "files": {' \
    "    \"stale.md\": \"$INTERMEDIATE_STALE_HASH\"" \
    '  }' \
    '}' > "$INTERMEDIATE_EXO/$BACKUP_MANIFEST"
cp "$INTERMEDIATE_EXO/$BACKUP_MANIFEST" "$INTERMEDIATE/manifest-before.json"
ln -s "$INTERMEDIATE_OUTSIDE" "$INTERMEDIATE_EXO/nested"
INTERMEDIATE_RC=0
run_backup "$INTERMEDIATE_WS" "$INTERMEDIATE_MEMORY" "$INTERMEDIATE/run.out" || INTERMEDIATE_RC=$?
if [ "$INTERMEDIATE_RC" -ne 0 ] && [ -L "$INTERMEDIATE_EXO/nested" ] && \
    [ ! -e "$INTERMEDIATE_OUTSIDE/inside.md" ] && \
    [ "$(cat "$INTERMEDIATE_OUTSIDE/directory-sentinel.md")" = "outside directory sentinel" ]; then
    pass "intermediate receiver symlink fails preflight and is never traversed"
else
    fail "intermediate receiver symlink did not fail closed"
fi
assert_guard_signal \
    "$INTERMEDIATE_RC" "$INTERMEDIATE/run.out" \
    '(preflight|intermediate component|промежуточн[^[:cntrl:]]*симлинк)' \
    "intermediate receiver symlink refusal"
if [ ! -e "$INTERMEDIATE_EXO/a-safe.md" ] && \
   [ "$(cat "$INTERMEDIATE_EXO/stale.md" 2>/dev/null || true)" = \
    "stale receiver must survive preflight" ] && \
   cmp -s "$INTERMEDIATE/manifest-before.json" "$INTERMEDIATE_EXO/$BACKUP_MANIFEST" && \
   [ ! -e "$INTERMEDIATE_EXO/.day-close-backup-incomplete" ]; then
    pass "destination preflight fails before copy, prune, manifest, or quarantine"
else
    fail "destination preflight allowed a partial backup mutation"
fi

echo "=== Component-wise collision preflight is conservative ==="
PROTECTED_ALIAS="$TEST_ROOT/protected-alias"
PROTECTED_ALIAS_WS="$PROTECTED_ALIAS/workspace"
PROTECTED_ALIAS_MEMORY="$PROTECTED_ALIAS/auto-memory"
PROTECTED_ALIAS_EXO="$PROTECTED_ALIAS_WS/governance/exocortex"
mkdir -p "$PROTECTED_ALIAS_WS/home" "$PROTECTED_ALIAS_MEMORY" "$PROTECTED_ALIAS_EXO"
printf 'must not be copied\n' > "$PROTECTED_ALIAS_MEMORY/a-safe.md"
printf 'case alias of a protected path\n' > "$PROTECTED_ALIAS_MEMORY/CLAUDE.MD"
PROTECTED_ALIAS_RC=0
run_backup \
    "$PROTECTED_ALIAS_WS" "$PROTECTED_ALIAS_MEMORY" "$PROTECTED_ALIAS/run.out" || \
    PROTECTED_ALIAS_RC=$?
if [ "$PROTECTED_ALIAS_RC" -ne 0 ] && \
   [ ! -e "$PROTECTED_ALIAS_EXO/a-safe.md" ] && \
   [ ! -e "$PROTECTED_ALIAS_EXO/$BACKUP_MANIFEST" ] && \
   [ ! -e "$PROTECTED_ALIAS_EXO/$BACKUP_QUARANTINE" ]; then
    pass "case alias to a protected path fails before the first copy"
else
    fail "protected-path case alias allowed a partial backup"
fi

NFKC="$TEST_ROOT/nfkc-collision"
NFKC_WS="$NFKC/workspace"
NFKC_MEMORY="$NFKC/auto-memory"
NFKC_EXO="$NFKC_WS/governance/exocortex"
mkdir -p "$NFKC_WS/home" "$NFKC_MEMORY" "$NFKC_EXO"
printf 'ASCII spelling\n' > "$NFKC_MEMORY/A.md"
printf 'full-width spelling\n' > "$NFKC_MEMORY/Ａ.md"
NFKC_RC=0
run_backup "$NFKC_WS" "$NFKC_MEMORY" "$NFKC/run.out" || NFKC_RC=$?
if [ "$NFKC_RC" -ne 0 ] && [ ! -e "$NFKC_EXO/A.md" ] && [ ! -e "$NFKC_EXO/Ａ.md" ]; then
    pass "NFKC-equivalent source files fail before copy"
else
    fail "NFKC-equivalent source files were copied ambiguously"
fi

TYPE_COLLISION="$TEST_ROOT/type-collision"
TYPE_WS="$TYPE_COLLISION/workspace"
TYPE_MEMORY="$TYPE_COLLISION/auto-memory"
TYPE_EXO="$TYPE_WS/governance/exocortex"
mkdir -p "$TYPE_WS/home" "$TYPE_MEMORY/Node.md" "$TYPE_EXO"
printf 'nested\n' > "$TYPE_MEMORY/Node.md/inside.md"
printf 'file aliases directory\n' > "$TYPE_MEMORY/Ｎｏｄｅ.md"
TYPE_RC=0
run_backup "$TYPE_WS" "$TYPE_MEMORY" "$TYPE_COLLISION/run.out" || TYPE_RC=$?
if [ "$TYPE_RC" -ne 0 ] && [ ! -e "$TYPE_EXO/Node.md" ] && [ ! -e "$TYPE_EXO/Ｎｏｄｅ.md" ]; then
    pass "NFKC file/directory type collision fails before copy"
else
    fail "file/directory alias type mismatch was not fail-closed"
fi

DEST_ALIAS="$TEST_ROOT/destination-alias"
DEST_ALIAS_WS="$DEST_ALIAS/workspace"
DEST_ALIAS_MEMORY="$DEST_ALIAS/auto-memory"
DEST_ALIAS_EXO="$DEST_ALIAS_WS/governance/exocortex"
mkdir -p "$DEST_ALIAS_WS/home" "$DEST_ALIAS_MEMORY" "$DEST_ALIAS_EXO"
printf 'new source\n' > "$DEST_ALIAS_MEMORY/report.md"
printf 'foreign destination alias\n' > "$DEST_ALIAS_EXO/ＲＥＰＯＲＴ.md"
DEST_ALIAS_RC=0
run_backup "$DEST_ALIAS_WS" "$DEST_ALIAS_MEMORY" "$DEST_ALIAS/run.out" || DEST_ALIAS_RC=$?
if [ "$DEST_ALIAS_RC" -ne 0 ] && [ ! -e "$DEST_ALIAS_EXO/report.md" ] && \
   [ "$(cat "$DEST_ALIAS_EXO/ＲＥＰＯＲＴ.md")" = "foreign destination alias" ]; then
    pass "destination Unicode alias to foreign data blocks all copies"
else
    fail "backup overwrote or coexisted ambiguously with a destination alias"
fi

GIT_EXCLUDE="$TEST_ROOT/git-exclude"
GIT_WS="$GIT_EXCLUDE/workspace"
GIT_MEMORY="$GIT_EXCLUDE/auto-memory"
GIT_EXO="$GIT_WS/governance/exocortex"
mkdir -p "$GIT_WS/home" "$GIT_MEMORY/.git/docs" "$GIT_EXO"
printf 'ordinary\n' > "$GIT_MEMORY/current.md"
printf 'must not leak\n' > "$GIT_MEMORY/.git/docs/leak.md"
GIT_RC=0
run_backup "$GIT_WS" "$GIT_MEMORY" "$GIT_EXCLUDE/run.out" || GIT_RC=$?
if [ "$GIT_RC" -eq 0 ] && [ -f "$GIT_EXO/current.md" ] && [ ! -e "$GIT_EXO/.git" ] && \
   ! grep -q '".git/' "$GIT_EXO/$BACKUP_MANIFEST"; then
    pass "source root .git is excluded completely"
else
    fail "backup copied or registered content from source .git"
fi

BROKEN="$TEST_ROOT/broken-source"
BROKEN_WS="$BROKEN/workspace"
BROKEN_MEMORY="$BROKEN/auto-memory"
BROKEN_EXO="$BROKEN_WS/governance/exocortex"
mkdir -p "$BROKEN_WS/home" "$BROKEN_MEMORY" "$BROKEN_EXO"
printf 'must not be copied before failed stat\n' > "$BROKEN_MEMORY/a-safe.md"
ln -s "$BROKEN/missing-target" "$BROKEN_MEMORY/broken.md"
BROKEN_RC=0
run_backup "$BROKEN_WS" "$BROKEN_MEMORY" "$BROKEN/run.out" || BROKEN_RC=$?
if [ "$BROKEN_RC" -ne 0 ] && [ ! -e "$BROKEN_EXO/a-safe.md" ] && \
   [ ! -e "$BROKEN_EXO/$BACKUP_QUARANTINE" ]; then
    pass "source stat failure aborts before copy and quarantine"
else
    fail "source stat failure allowed backup mutation"
fi
if grep -q 'os.fstat(source_descriptor)' "$DAY_CLOSE" && \
   grep -q 'source identity changed during backup' "$DAY_CLOSE"; then
    pass "copy path revalidates opened source identity against preflight"
else
    fail "source identity race revalidation is absent"
fi
if grep -q 'sys.version_info\[0\] != 3' "$DAY_CLOSE"; then
    pass "stdlib resolver rejects a possible Python 2 fallback"
else
    fail "stdlib resolver accepts an interpreter without checking Python major"
fi

echo "=== Descriptor-bound destination race handling ==="
COPY_RACE="$TEST_ROOT/copy-race"
COPY_RACE_WS="$COPY_RACE/workspace"
COPY_RACE_MEMORY="$COPY_RACE/auto-memory"
COPY_RACE_EXO="$COPY_RACE_WS/governance/exocortex"
COPY_RACE_OUTSIDE="$COPY_RACE/outside"
COPY_RACE_BARRIER="$COPY_RACE/barrier"
mkdir -p \
    "$COPY_RACE_WS/home" \
    "$COPY_RACE_MEMORY/nested" \
    "$COPY_RACE_EXO/nested" \
    "$COPY_RACE_OUTSIDE" \
    "$COPY_RACE_BARRIER"
printf 'copy must remain in bound directory\n' > \
    "$COPY_RACE_MEMORY/nested/copy.md"
printf 'outside copy sentinel\n' > "$COPY_RACE_OUTSIDE/copy.md"
export IWE_DAY_CLOSE_TESTING=1
export IWE_DAY_CLOSE_TEST_POINT='copy-before-publish:nested/copy.md'
export IWE_DAY_CLOSE_TEST_BARRIER="$COPY_RACE_BARRIER"
run_backup \
    "$COPY_RACE_WS" "$COPY_RACE_MEMORY" "$COPY_RACE/run.out" &
COPY_RACE_PID=$!
unset IWE_DAY_CLOSE_TESTING IWE_DAY_CLOSE_TEST_POINT IWE_DAY_CLOSE_TEST_BARRIER
COPY_RACE_BARRIER_OK=0
if wait_for_barrier "$COPY_RACE_BARRIER/ready" "$COPY_RACE_PID"; then
    mv "$COPY_RACE_EXO/nested" "$COPY_RACE_EXO/nested-bound"
    ln -s "$COPY_RACE_OUTSIDE" "$COPY_RACE_EXO/nested"
    touch "$COPY_RACE_BARRIER/release"
else
    COPY_RACE_BARRIER_OK=1
    touch "$COPY_RACE_BARRIER/release"
fi
COPY_RACE_RC=0
wait "$COPY_RACE_PID" || COPY_RACE_RC=$?
if [ "$COPY_RACE_BARRIER_OK" -eq 0 ] && [ "$COPY_RACE_RC" -ne 0 ] && \
   [ "$(cat "$COPY_RACE_OUTSIDE/copy.md")" = "outside copy sentinel" ] && \
   cmp -s "$COPY_RACE_MEMORY/nested/copy.md" \
       "$COPY_RACE_EXO/nested-bound/copy.md" && \
   [ -L "$COPY_RACE_EXO/nested" ]; then
    pass "parent swap during copy cannot redirect bytes outside the bound directory"
else
    fail "copy parent swap escaped, mutated the sentinel, or returned success"
fi

PARAMS_RACE="$TEST_ROOT/params-root-race"
PARAMS_RACE_WS="$PARAMS_RACE/workspace"
PARAMS_RACE_MEMORY="$PARAMS_RACE/auto-memory"
PARAMS_RACE_EXO="$PARAMS_RACE_WS/governance/exocortex"
PARAMS_RACE_BOUND="$PARAMS_RACE_WS/governance/exocortex-bound"
PARAMS_RACE_OUTSIDE="$PARAMS_RACE/outside"
PARAMS_RACE_BARRIER="$PARAMS_RACE/barrier"
mkdir -p \
    "$PARAMS_RACE_WS/home" \
    "$PARAMS_RACE_MEMORY" \
    "$PARAMS_RACE_EXO" \
    "$PARAMS_RACE_OUTSIDE" \
    "$PARAMS_RACE_BARRIER"
printf 'ordinary memory\n' > "$PARAMS_RACE_MEMORY/ordinary.md"
printf 'profile: bound-source\n' > "$PARAMS_RACE_WS/params.yaml"
printf 'outside params sentinel\n' > "$PARAMS_RACE_OUTSIDE/params.yaml"
export IWE_DAY_CLOSE_TESTING=1
export IWE_DAY_CLOSE_TEST_POINT='copy-before-publish:params.yaml'
export IWE_DAY_CLOSE_TEST_BARRIER="$PARAMS_RACE_BARRIER"
run_backup \
    "$PARAMS_RACE_WS" "$PARAMS_RACE_MEMORY" "$PARAMS_RACE/run.out" &
PARAMS_RACE_PID=$!
unset IWE_DAY_CLOSE_TESTING IWE_DAY_CLOSE_TEST_POINT IWE_DAY_CLOSE_TEST_BARRIER
PARAMS_RACE_BARRIER_OK=0
if wait_for_barrier "$PARAMS_RACE_BARRIER/ready" "$PARAMS_RACE_PID"; then
    mv "$PARAMS_RACE_EXO" "$PARAMS_RACE_BOUND"
    ln -s "$PARAMS_RACE_OUTSIDE" "$PARAMS_RACE_EXO"
    touch "$PARAMS_RACE_BARRIER/release"
else
    PARAMS_RACE_BARRIER_OK=1
    touch "$PARAMS_RACE_BARRIER/release"
fi
PARAMS_RACE_RC=0
wait "$PARAMS_RACE_PID" || PARAMS_RACE_RC=$?
if [ "$PARAMS_RACE_BARRIER_OK" -eq 0 ] && \
   [ "$PARAMS_RACE_RC" -ne 0 ] && \
   [ "$(cat "$PARAMS_RACE_OUTSIDE/params.yaml")" = \
        "outside params sentinel" ] && \
   [ "$(cat "$PARAMS_RACE_BOUND/params.yaml" 2>/dev/null || true)" = \
        "profile: bound-source" ] && \
   [ -L "$PARAMS_RACE_EXO" ]; then
    pass "params backup stays on the bound root and reports a root-path swap"
else
    fail "params backup followed or hid an exocortex root swap"
fi

STALE_RACE="$TEST_ROOT/stale-race"
STALE_RACE_WS="$STALE_RACE/workspace"
STALE_RACE_MEMORY="$STALE_RACE/auto-memory"
STALE_RACE_EXO="$STALE_RACE_WS/governance/exocortex"
STALE_RACE_OUTSIDE="$STALE_RACE/outside"
STALE_RACE_BARRIER="$STALE_RACE/barrier"
mkdir -p \
    "$STALE_RACE_WS/home" \
    "$STALE_RACE_MEMORY/nested" \
    "$STALE_RACE_EXO" \
    "$STALE_RACE_OUTSIDE" \
    "$STALE_RACE_BARRIER"
printf 'current file\n' > "$STALE_RACE_MEMORY/nested/current.md"
printf 'owned stale bytes\n' > "$STALE_RACE_MEMORY/nested/stale.md"
cp "$STALE_RACE_MEMORY/nested/stale.md" "$STALE_RACE/expected-stale.md"
STALE_RACE_HASH="$(sha256_file "$STALE_RACE/expected-stale.md")"
STALE_RACE_FIRST_RC=0
run_backup \
    "$STALE_RACE_WS" "$STALE_RACE_MEMORY" "$STALE_RACE/first.out" || \
    STALE_RACE_FIRST_RC=$?
rm -- "$STALE_RACE_MEMORY/nested/stale.md"
printf 'outside stale sentinel\n' > "$STALE_RACE_OUTSIDE/stale.md"
export IWE_DAY_CLOSE_TESTING=1
export IWE_DAY_CLOSE_TEST_POINT='stale-before-link:nested/stale.md'
export IWE_DAY_CLOSE_TEST_BARRIER="$STALE_RACE_BARRIER"
run_backup \
    "$STALE_RACE_WS" "$STALE_RACE_MEMORY" "$STALE_RACE/run.out" &
STALE_RACE_PID=$!
unset IWE_DAY_CLOSE_TESTING IWE_DAY_CLOSE_TEST_POINT IWE_DAY_CLOSE_TEST_BARRIER
STALE_RACE_BARRIER_OK=0
if wait_for_barrier "$STALE_RACE_BARRIER/ready" "$STALE_RACE_PID"; then
    mv "$STALE_RACE_EXO/nested" "$STALE_RACE_EXO/nested-bound"
    ln -s "$STALE_RACE_OUTSIDE" "$STALE_RACE_EXO/nested"
    touch "$STALE_RACE_BARRIER/release"
else
    STALE_RACE_BARRIER_OK=1
    touch "$STALE_RACE_BARRIER/release"
fi
STALE_RACE_RC=0
wait "$STALE_RACE_PID" || STALE_RACE_RC=$?
STALE_RACE_RETAINED="$(find \
    "$STALE_RACE_EXO/.day-close-backup-quarantine" \
    -type f -path '*/nested/stale.md' -print -quit 2>/dev/null)"
if [ "$STALE_RACE_FIRST_RC" -eq 0 ] && \
   [ "$STALE_RACE_BARRIER_OK" -eq 0 ] && [ "$STALE_RACE_RC" -ne 0 ] && \
   [ "$(cat "$STALE_RACE_OUTSIDE/stale.md")" = "outside stale sentinel" ] && \
   [ ! -e "$STALE_RACE_EXO/nested-bound/stale.md" ] && \
   [ -n "$STALE_RACE_RETAINED" ] && \
   [ "$(sha256_file "$STALE_RACE_RETAINED")" = "$STALE_RACE_HASH" ] && \
   cmp -s "$STALE_RACE/expected-stale.md" "$STALE_RACE_RETAINED" && \
   [ -f "$STALE_RACE_EXO/$BACKUP_QUARANTINE" ]; then
    pass "parent swap during stale move retains exact bytes without touching outside"
else
    fail "stale parent swap escaped, lost bytes, or cleared the recovery journal"
fi

echo "=== Durable incomplete-run quarantine ==="
QUARANTINE="$TEST_ROOT/quarantine"
QUARANTINE_WS="$QUARANTINE/workspace"
QUARANTINE_MEMORY="$QUARANTINE/auto-memory"
QUARANTINE_EXO="$QUARANTINE_WS/governance/exocortex"
mkdir -p "$QUARANTINE_WS/home" "$QUARANTINE_MEMORY" "$QUARANTINE_EXO"
printf 'always current\n' > "$QUARANTINE_MEMORY/current.md"
printf 'owned before simulated crash\n' > "$QUARANTINE_MEMORY/old.md"
cp "$QUARANTINE_MEMORY/old.md" "$QUARANTINE/expected-old.md"
QUARANTINE_OLD_HASH="$(sha256_file "$QUARANTINE/expected-old.md")"
QUARANTINE_FIRST_RC=0
run_backup \
    "$QUARANTINE_WS" "$QUARANTINE_MEMORY" "$QUARANTINE/first.out" || \
    QUARANTINE_FIRST_RC=$?
rm -- "$QUARANTINE_MEMORY/old.md"
printf 'new recovery copy\n' > "$QUARANTINE_MEMORY/recovery.md"
cp "$QUARANTINE_MEMORY/recovery.md" "$QUARANTINE/expected-recovery.md"
QUARANTINE_RECOVERY_HASH="$(sha256_file "$QUARANTINE/expected-recovery.md")"
printf '{"schema_version":1,"state":"precopy"}\n' > \
    "$QUARANTINE_EXO/$BACKUP_QUARANTINE"
QUARANTINE_RECOVERY_RC=0
run_backup \
    "$QUARANTINE_WS" "$QUARANTINE_MEMORY" "$QUARANTINE/recovery.out" || \
    QUARANTINE_RECOVERY_RC=$?
if [ "$QUARANTINE_FIRST_RC" -eq 0 ] && [ "$QUARANTINE_RECOVERY_RC" -eq 0 ] && \
   [ -f "$QUARANTINE_EXO/old.md" ] && [ -f "$QUARANTINE_EXO/recovery.md" ] && \
   [ "$(sha256_file "$QUARANTINE_EXO/old.md")" = "$QUARANTINE_OLD_HASH" ] && \
   cmp -s "$QUARANTINE/expected-old.md" "$QUARANTINE_EXO/old.md" && \
   [ ! -e "$QUARANTINE_EXO/$BACKUP_QUARANTINE" ] && \
   ! grep -q '"old.md"' "$QUARANTINE_EXO/$BACKUP_MANIFEST" && \
   grep -q 'previous incomplete backup detected' "$QUARANTINE/recovery.out"; then
    pass "first successful run after a crash skips prune, publishes current manifest, and clears marker"
else
    fail "quarantine recovery did not perform the one-run safe handoff"
fi
rm -- "$QUARANTINE_MEMORY/recovery.md"
QUARANTINE_NORMAL_RC=0
run_backup \
    "$QUARANTINE_WS" "$QUARANTINE_MEMORY" "$QUARANTINE/normal.out" || \
    QUARANTINE_NORMAL_RC=$?
QUARANTINE_RETAINED="$(find \
    "$QUARANTINE_EXO/.day-close-backup-quarantine" \
    -type f -name recovery.md -print -quit 2>/dev/null)"
if [ "$QUARANTINE_NORMAL_RC" -eq 0 ] && [ ! -e "$QUARANTINE_EXO/recovery.md" ] && \
   [ -f "$QUARANTINE_EXO/old.md" ] && \
   [ "$(sha256_file "$QUARANTINE_EXO/old.md")" = "$QUARANTINE_OLD_HASH" ] && \
   [ -n "$QUARANTINE_RETAINED" ] && \
   [ "$(sha256_file "$QUARANTINE_RETAINED")" = "$QUARANTINE_RECOVERY_HASH" ] && \
   cmp -s "$QUARANTINE/expected-recovery.md" "$QUARANTINE_RETAINED"; then
    pass "backup resumes pruning by retaining hash-owned stale bytes in quarantine"
else
    fail "normal pruning did not resume after quarantine recovery"
fi

echo "=== Planned transaction recovery is durable and idempotent ==="
PLANNED="$TEST_ROOT/planned-recovery"
PLANNED_WS="$PLANNED/workspace"
PLANNED_MEMORY="$PLANNED/auto-memory"
PLANNED_EXO="$PLANNED_WS/governance/exocortex"
PLANNED_TXID="0123456789abcdef0123456789abcdef"
mkdir -p "$PLANNED_WS/home" "$PLANNED_MEMORY" "$PLANNED_EXO"
printf 'current survives recovery\n' > "$PLANNED_MEMORY/current.md"
printf 'first stale bytes\n' > "$PLANNED_MEMORY/stale-one.md"
printf 'second stale bytes\n' > "$PLANNED_MEMORY/stale-two.md"
cp "$PLANNED_MEMORY/stale-one.md" "$PLANNED/expected-one.md"
cp "$PLANNED_MEMORY/stale-two.md" "$PLANNED/expected-two.md"
PLANNED_ONE_HASH="$(sha256_file "$PLANNED/expected-one.md")"
PLANNED_TWO_HASH="$(sha256_file "$PLANNED/expected-two.md")"
PLANNED_FIRST_RC=0
run_backup "$PLANNED_WS" "$PLANNED_MEMORY" "$PLANNED/first.out" || \
    PLANNED_FIRST_RC=$?
rm -- "$PLANNED_MEMORY/stale-one.md" "$PLANNED_MEMORY/stale-two.md"
PLANNED_FIXTURE_RC=0
python3 - \
    "$PLANNED_EXO/$BACKUP_MANIFEST" \
    "$PLANNED_EXO/$BACKUP_QUARANTINE" \
    "$PLANNED_EXO/.day-close-backup-quarantine" \
    "$PLANNED_TXID" \
    "$PLANNED_EXO/stale-one.md" \
    "$PLANNED_EXO/stale-two.md" <<'PYEOF' || PLANNED_FIXTURE_RC=$?
import hashlib
import json
import os
from pathlib import Path
import sys


manifest_path = Path(sys.argv[1])
journal_path = Path(sys.argv[2])
retained_root = Path(sys.argv[3])
txid = sys.argv[4]
stale_paths = [Path(value) for value in sys.argv[5:]]
payload = json.loads(manifest_path.read_text(encoding="utf-8"))
entries = []
for stale_path in stale_paths:
    relative = stale_path.name
    expected_hash = payload["files"].pop(relative)
    value = stale_path.lstat()
    identity = [
        value.st_dev,
        value.st_ino,
        value.st_mode,
        value.st_size,
        getattr(value, "st_mtime_ns", int(value.st_mtime * 1_000_000_000)),
        getattr(value, "st_ctime_ns", int(value.st_ctime * 1_000_000_000)),
    ]
    entries.append(
        {
            "path": relative,
            "sha256": expected_hash,
            "destination_identity": identity,
            "quarantine_rel": f"{txid}/{relative}",
        }
    )
manifest_bytes = (
    json.dumps(payload, ensure_ascii=False, indent=2).encode("utf-8") + b"\n"
)
manifest_path.write_bytes(manifest_bytes)
journal_path.write_text(
    json.dumps(
        {
            "schema_version": 1,
            "state": "planned",
            "txid": txid,
            "target_manifest_sha256": hashlib.sha256(manifest_bytes).hexdigest(),
            "entries": entries,
        },
        ensure_ascii=False,
        indent=2,
    )
    + "\n",
    encoding="utf-8",
)
already_retained = retained_root / txid / stale_paths[0].name
already_retained.parent.mkdir(parents=True)
os.link(stale_paths[0], already_retained)
PYEOF
PLANNED_RETAINED_ONE="$PLANNED_EXO/.day-close-backup-quarantine/$PLANNED_TXID/stale-one.md"
PLANNED_RETAINED_TWO="$PLANNED_EXO/.day-close-backup-quarantine/$PLANNED_TXID/stale-two.md"
PLANNED_FAILURES_OK=0
for recovery_attempt in 1 2; do
    export IWE_DAY_CLOSE_TESTING=1
    export IWE_DAY_CLOSE_TEST_POINT='stale-before-link:stale-two.md'
    export IWE_DAY_CLOSE_TEST_FAILURE=1
    PLANNED_FAILURE_RC=0
    run_backup \
        "$PLANNED_WS" "$PLANNED_MEMORY" \
        "$PLANNED/recovery-failure-$recovery_attempt.out" || \
        PLANNED_FAILURE_RC=$?
    unset \
        IWE_DAY_CLOSE_TESTING \
        IWE_DAY_CLOSE_TEST_POINT \
        IWE_DAY_CLOSE_TEST_FAILURE
    if [ "$PLANNED_FAILURE_RC" -ne 0 ] && \
       [ -f "$PLANNED_EXO/$BACKUP_QUARANTINE" ] && \
       [ ! -e "$PLANNED_EXO/stale-one.md" ] && \
       [ -f "$PLANNED_RETAINED_ONE" ] && \
       [ -f "$PLANNED_EXO/stale-two.md" ] && \
       [ ! -e "$PLANNED_RETAINED_TWO" ] && \
       grep -q 'injected test failure: stale-before-link:stale-two.md' \
           "$PLANNED/recovery-failure-$recovery_attempt.out"; then
        PLANNED_FAILURES_OK=$((PLANNED_FAILURES_OK + 1))
    fi
done
if [ "$PLANNED_FAILURES_OK" -eq 2 ]; then
    pass "two consecutive recovery failures retain the same journal and exact bytes"
else
    fail "repeated recovery failure lost state, bytes, or the durable journal"
fi
PLANNED_RECOVERY_RC=0
run_backup "$PLANNED_WS" "$PLANNED_MEMORY" "$PLANNED/recovery.out" || \
    PLANNED_RECOVERY_RC=$?
if [ "$PLANNED_FIRST_RC" -eq 0 ] && [ "$PLANNED_FIXTURE_RC" -eq 0 ] && \
   [ "$PLANNED_RECOVERY_RC" -eq 0 ] && \
   [ ! -e "$PLANNED_EXO/stale-one.md" ] && \
   [ ! -e "$PLANNED_EXO/stale-two.md" ] && \
   [ ! -e "$PLANNED_EXO/$BACKUP_QUARANTINE" ] && \
   [ -f "$PLANNED_RETAINED_ONE" ] && [ -f "$PLANNED_RETAINED_TWO" ] && \
   grep -q 'previous committed backup transaction recovered' \
       "$PLANNED/recovery.out"; then
    pass "committed planned journal finishes every stale move and clears the journal"
else
    fail "committed planned journal recovery was incomplete"
fi
if [ "$(sha256_file "$PLANNED_RETAINED_ONE")" = "$PLANNED_ONE_HASH" ] && \
   [ "$(sha256_file "$PLANNED_RETAINED_TWO")" = "$PLANNED_TWO_HASH" ] && \
   cmp -s "$PLANNED/expected-one.md" "$PLANNED_RETAINED_ONE" && \
   cmp -s "$PLANNED/expected-two.md" "$PLANNED_RETAINED_TWO"; then
    pass "partially quarantined planned transaction resumes idempotently with exact bytes"
else
    fail "planned recovery changed or lost retained stale bytes"
fi

echo "=== Invalid recovery journals fail before mutation ==="
BAD_JOURNAL="$TEST_ROOT/bad-journal"
BAD_JOURNAL_WS="$BAD_JOURNAL/workspace"
BAD_JOURNAL_MEMORY="$BAD_JOURNAL/auto-memory"
BAD_JOURNAL_EXO="$BAD_JOURNAL_WS/governance/exocortex"
mkdir -p "$BAD_JOURNAL_WS/home" "$BAD_JOURNAL_MEMORY" "$BAD_JOURNAL_EXO"
printf 'stable receiver\n' > "$BAD_JOURNAL_MEMORY/stable.md"
BAD_JOURNAL_FIRST_RC=0
run_backup \
    "$BAD_JOURNAL_WS" "$BAD_JOURNAL_MEMORY" "$BAD_JOURNAL/first.out" || \
    BAD_JOURNAL_FIRST_RC=$?
cp "$BAD_JOURNAL_EXO/stable.md" "$BAD_JOURNAL/expected-stable.md"
cp "$BAD_JOURNAL_EXO/$BACKUP_MANIFEST" "$BAD_JOURNAL/expected-manifest.json"
printf 'must not copy\n' > "$BAD_JOURNAL_MEMORY/later.md"
printf '{ definitely not valid json\n' > \
    "$BAD_JOURNAL_EXO/$BACKUP_QUARANTINE"
cp "$BAD_JOURNAL_EXO/$BACKUP_QUARANTINE" "$BAD_JOURNAL/expected-bad-journal"
BAD_JSON_RC=0
run_backup \
    "$BAD_JOURNAL_WS" "$BAD_JOURNAL_MEMORY" "$BAD_JOURNAL/bad-json.out" || \
    BAD_JSON_RC=$?
if [ "$BAD_JOURNAL_FIRST_RC" -eq 0 ] && [ "$BAD_JSON_RC" -ne 0 ] && \
   [ ! -e "$BAD_JOURNAL_EXO/later.md" ] && \
   cmp -s "$BAD_JOURNAL/expected-stable.md" "$BAD_JOURNAL_EXO/stable.md" && \
   cmp -s "$BAD_JOURNAL/expected-manifest.json" \
       "$BAD_JOURNAL_EXO/$BACKUP_MANIFEST" && \
   cmp -s "$BAD_JOURNAL/expected-bad-journal" \
       "$BAD_JOURNAL_EXO/$BACKUP_QUARANTINE"; then
    pass "malformed journal returns nonzero without receiver mutation"
else
    fail "malformed journal changed receiver state or returned success"
fi
rm -- "$BAD_JOURNAL_EXO/$BACKUP_QUARANTINE"
printf 'outside journal target\n' > "$BAD_JOURNAL/outside-journal"
ln -s "$BAD_JOURNAL/outside-journal" \
    "$BAD_JOURNAL_EXO/$BACKUP_QUARANTINE"
BAD_SYMLINK_RC=0
run_backup \
    "$BAD_JOURNAL_WS" "$BAD_JOURNAL_MEMORY" "$BAD_JOURNAL/symlink.out" || \
    BAD_SYMLINK_RC=$?
if [ "$BAD_SYMLINK_RC" -ne 0 ] && \
   [ -L "$BAD_JOURNAL_EXO/$BACKUP_QUARANTINE" ] && \
   [ "$(cat "$BAD_JOURNAL/outside-journal")" = "outside journal target" ] && \
   [ ! -e "$BAD_JOURNAL_EXO/later.md" ] && \
   cmp -s "$BAD_JOURNAL/expected-stable.md" "$BAD_JOURNAL_EXO/stable.md" && \
   cmp -s "$BAD_JOURNAL/expected-manifest.json" \
       "$BAD_JOURNAL_EXO/$BACKUP_MANIFEST"; then
    pass "symlink journal returns nonzero without following or mutating its target"
else
    fail "symlink journal was followed, mutated, or accepted"
fi

echo "=== Mid-day hook leaves day-rhythm to conflict-aware backup ==="
if command -v jq >/dev/null 2>&1; then
    HOOK_CASE="$TEST_ROOT/hook"
    HOOK_WS="$HOOK_CASE/workspace"
    HOOK_MEMORY="$HOOK_CASE/auto-memory"
    HOOK_EXO="$HOOK_WS/governance/exocortex"
    mkdir -p "$HOOK_WS/home" "$HOOK_MEMORY" "$HOOK_EXO"
    printf 'day_open:\n  calendar_ids: []\n' > "$HOOK_MEMORY/day-rhythm-config.yaml"
    printf 'day_open:\n  calendar_ids: [destination]\n' > "$HOOK_EXO/day-rhythm-config.yaml"
    cp "$HOOK_EXO/day-rhythm-config.yaml" "$HOOK_CASE/expected-rhythm.yaml"
    printf 'ordinary direct\n' > "$HOOK_MEMORY/direct.md"
    printf '%s\n' \
        "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$HOOK_MEMORY/day-rhythm-config.yaml\"}}" | \
        env HOME="$HOOK_WS/home" WORKSPACE_DIR="$HOOK_WS" GOVERNANCE_REPO=governance \
            IWE_MEMORY_SRC="$HOOK_MEMORY" bash "$MEMORY_HOOK"
    printf '%s\n' \
        "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$HOOK_MEMORY/direct.md\"}}" | \
        env HOME="$HOOK_WS/home" WORKSPACE_DIR="$HOOK_WS" GOVERNANCE_REPO=governance \
            IWE_MEMORY_SRC="$HOOK_MEMORY" bash "$MEMORY_HOOK"
    if cmp -s "$HOOK_CASE/expected-rhythm.yaml" "$HOOK_EXO/day-rhythm-config.yaml" && \
       [ "$(cat "$HOOK_EXO/direct.md" 2>/dev/null || true)" = "ordinary direct" ]; then
        pass "direct hook skips day-rhythm but still mirrors ordinary memory"
    else
        fail "direct hook overwrote day-rhythm or stopped ordinary mirroring"
    fi

    printf 'ordinary Bash reconcile\n' > "$HOOK_MEMORY/bash.md"
    printf 'day_open:\n  calendar_ids: [new-source]\n' > "$HOOK_MEMORY/day-rhythm-config.yaml"
    printf '%s\n' '{"tool_name":"Bash","tool_input":{}}' | \
        env HOME="$HOOK_WS/home" WORKSPACE_DIR="$HOOK_WS" GOVERNANCE_REPO=governance \
            IWE_MEMORY_SRC="$HOOK_MEMORY" bash "$MEMORY_HOOK"
    if cmp -s "$HOOK_CASE/expected-rhythm.yaml" "$HOOK_EXO/day-rhythm-config.yaml" && \
       [ "$(cat "$HOOK_EXO/bash.md" 2>/dev/null || true)" = "ordinary Bash reconcile" ]; then
        pass "Bash hook reconcile skips day-rhythm but mirrors ordinary memory"
    else
        fail "Bash hook reconcile overwrote day-rhythm or missed ordinary memory"
    fi
else
    pass "hook regression skipped because jq is unavailable in this test environment"
fi

echo "=== Missing memory source is a real failure ==="
MISSING="$TEST_ROOT/missing-source"
MISSING_WS="$MISSING/workspace"
mkdir -p "$MISSING_WS/home" "$MISSING_WS/governance/exocortex"
MISSING_RC=0
run_backup "$MISSING_WS" "$MISSING/not-present" "$MISSING/run.out" || MISSING_RC=$?
if [ "$MISSING_RC" -ne 0 ] && grep -q 'backup=fail' "$MISSING/run.out"; then
    pass "missing memory source returns nonzero and reports backup=fail"
else
    fail "missing memory source was hidden behind final logging success"
fi

echo "=== Restore routes params.yaml to workspace root ==="
FRESH="$TEST_ROOT/restore-fresh"
FRESH_WS="$FRESH/workspace"
FRESH_MEMORY="$FRESH/auto-memory"
FRESH_EXO="$FRESH_WS/governance/exocortex"
UPPERCASE_PRIVATE_ROOT='Agent-Fault-Profile'
UNICODE_PRIVATE_ROOT='Ａｇｅｎｔ－Ｆａｕｌｔ－Ｐｒｏｆｉｌｅ'
mkdir -p \
    "$FRESH_WS/home" \
    "$FRESH_MEMORY" \
    "$FRESH_EXO/agent-fault-profile/audit" \
    "$FRESH_EXO/$UPPERCASE_PRIVATE_ROOT/audit" \
    "$FRESH_EXO/$UNICODE_PRIVATE_ROOT/audit" \
    "$FRESH_EXO/hindsight" \
    "$FRESH_EXO/decisions" \
    "$FRESH_EXO/extensions" \
    "$FRESH_EXO/rules/-nested" \
    "$FRESH_EXO/.day-close-backup-quarantine/tx"
HOSTILE_NAME=$'odd "quote $dollar\nline.md'
DASH_MEMORY_NAME='-rf.md'
DASH_EXTENSION_NAME='--force.md'
DASH_RULE_NAME='-n.yaml'
printf '# portable params\nprofile: restored\n' > "$FRESH_EXO/params.yaml"
printf 'day_open:\n  calendar_ids: [restored]\n' > \
    "$FRESH_EXO/day-rhythm-config.yaml"
printf 'ordinary memory\n' > "$FRESH_EXO/note.md"
printf 'hostile name content\n' > "$FRESH_EXO/$HOSTILE_NAME"
printf 'dash-prefixed memory\n' > "$FRESH_EXO/$DASH_MEMORY_NAME"
printf 'dash-prefixed extension\n' > "$FRESH_EXO/extensions/$DASH_EXTENSION_NAME"
printf 'dash-prefixed rule\n' > "$FRESH_EXO/rules/-nested/$DASH_RULE_NAME"
printf 'private raw fault\n' > "$FRESH_EXO/agent-fault-profile/audit/faults.md"
printf 'case-alias raw fault\n' > "$FRESH_EXO/$UPPERCASE_PRIVATE_ROOT/audit/faults.md"
printf 'unicode-alias raw fault\n' > "$FRESH_EXO/$UNICODE_PRIVATE_ROOT/audit/faults.md"
printf 'private hindsight\n' > "$FRESH_EXO/hindsight/private.md"
printf 'governance decision\n' > "$FRESH_EXO/decisions/private.md"
printf 'retained stale data\n' > "$FRESH_EXO/.day-close-backup-quarantine/tx/private.md"
FRESH_RC=0
run_restore "$FRESH_WS" "$FRESH_MEMORY" "$FRESH/run.out" || FRESH_RC=$?
if [ "$FRESH_RC" -eq 0 ]; then
    pass "fresh restore succeeds"
else
    fail "fresh restore failed (rc=$FRESH_RC)"
fi
if [ -f "$FRESH_WS/params.yaml" ] && cmp -s "$FRESH_EXO/params.yaml" "$FRESH_WS/params.yaml"; then
    pass "fresh restore writes params.yaml to workspace root"
else
    fail "fresh restore did not write params.yaml to workspace root"
fi
if [ ! -e "$FRESH_MEMORY/params.yaml" ]; then
    pass "fresh restore keeps params.yaml out of auto-memory"
else
    fail "fresh restore incorrectly copied params.yaml into auto-memory"
fi
if cmp -s \
    "$FRESH_EXO/day-rhythm-config.yaml" \
    "$FRESH_MEMORY/day-rhythm-config.yaml"; then
    pass "fresh restore routes canonical day-rhythm to auto-memory"
else
    fail "fresh restore lost or misrouted canonical day-rhythm"
fi
if [ ! -e "$FRESH_MEMORY/agent-fault-profile" ] && \
   [ ! -e "$FRESH_MEMORY/$UPPERCASE_PRIVATE_ROOT" ] && \
   [ ! -e "$FRESH_MEMORY/$UNICODE_PRIVATE_ROOT" ] && \
   [ ! -e "$FRESH_MEMORY/hindsight" ] && \
   [ ! -e "$FRESH_MEMORY/decisions" ] && \
   [ ! -e "$FRESH_MEMORY/.day-close-backup-quarantine" ]; then
    pass "restore keeps exact, case, and NFKC private roots out of auto-memory"
else
    fail "restore leaked a private or multi-writer subtree into auto-memory"
fi
if [ "$(cat "$FRESH_MEMORY/$HOSTILE_NAME" 2>/dev/null || true)" = "hostile name content" ]; then
    pass "restore handles quotes, dollars, spaces, and newlines as argv-only filenames"
else
    fail "restore corrupted or skipped a hostile-but-valid filename"
fi
if [ "$(cat "$FRESH_MEMORY/$DASH_MEMORY_NAME" 2>/dev/null || true)" = \
        "dash-prefixed memory" ] && \
   [ "$(cat "$FRESH_WS/extensions/$DASH_EXTENSION_NAME" 2>/dev/null || true)" = \
        "dash-prefixed extension" ] && \
   [ "$(cat "$FRESH_WS/.claude/rules/-nested/$DASH_RULE_NAME" 2>/dev/null || true)" = \
        "dash-prefixed rule" ]; then
    pass "every variable-filename restore branch treats dash-prefixed names as operands"
else
    fail "a restore branch interpreted a dash-prefixed filename as an option"
fi

RHYTHM_ALIAS="$TEST_ROOT/restore-rhythm-alias"
RHYTHM_ALIAS_WS="$RHYTHM_ALIAS/workspace"
RHYTHM_ALIAS_MEMORY="$RHYTHM_ALIAS/auto-memory"
RHYTHM_ALIAS_EXO="$RHYTHM_ALIAS_WS/governance/exocortex"
RHYTHM_CASE_ALIAS='DAY-RHYTHM-CONFIG.YAML'
RHYTHM_NFKC_ALIAS='ｄａｙ－ｒｈｙｔｈｍ－ｃｏｎｆｉｇ．ｙａｍｌ'
mkdir -p "$RHYTHM_ALIAS_WS/home" "$RHYTHM_ALIAS_EXO"
printf 'case alias private config\n' > \
    "$RHYTHM_ALIAS_EXO/$RHYTHM_CASE_ALIAS"
printf 'NFKC alias private config\n' > \
    "$RHYTHM_ALIAS_EXO/$RHYTHM_NFKC_ALIAS"
printf 'ordinary alias control\n' > "$RHYTHM_ALIAS_EXO/ordinary.md"
RHYTHM_ALIAS_RC=0
run_restore \
    "$RHYTHM_ALIAS_WS" "$RHYTHM_ALIAS_MEMORY" \
    "$RHYTHM_ALIAS/run.out" || RHYTHM_ALIAS_RC=$?
if [ "$RHYTHM_ALIAS_RC" -eq 0 ] && \
   [ ! -e "$RHYTHM_ALIAS_MEMORY/$RHYTHM_CASE_ALIAS" ] && \
   [ ! -e "$RHYTHM_ALIAS_MEMORY/$RHYTHM_NFKC_ALIAS" ] && \
   [ ! -e "$RHYTHM_ALIAS_MEMORY/day-rhythm-config.yaml" ] && \
   [ -f "$RHYTHM_ALIAS_MEMORY/ordinary.md" ]; then
    pass "restore excludes case and NFKC aliases of day-rhythm"
else
    fail "restore leaked a day-rhythm alias into auto-memory"
fi

DRY="$TEST_ROOT/restore-dry-run"
DRY_WS="$DRY/workspace"
DRY_MEMORY="$DRY/auto-memory"
DRY_EXO="$DRY_WS/governance/exocortex"
mkdir -p "$DRY_WS/home" "$DRY_EXO"
printf 'profile: preview-only\n' > "$DRY_EXO/params.yaml"
printf 'preview memory\n' > "$DRY_EXO/note.md"
DRY_RC=0
run_restore "$DRY_WS" "$DRY_MEMORY" "$DRY/run.out" --dry-run || DRY_RC=$?
if [ "$DRY_RC" -eq 0 ] && [ ! -e "$DRY_WS/params.yaml" ] && [ ! -e "$DRY_MEMORY" ]; then
    pass "restore --dry-run creates neither params nor auto-memory"
else
    fail "restore --dry-run mutated the workspace (rc=$DRY_RC)"
fi

PARAMS_LINK="$TEST_ROOT/restore-params-source-symlink"
PARAMS_LINK_WS="$PARAMS_LINK/workspace"
PARAMS_LINK_MEMORY="$PARAMS_LINK/auto-memory"
PARAMS_LINK_EXO="$PARAMS_LINK_WS/governance/exocortex"
PARAMS_LINK_OUTSIDE="$PARAMS_LINK/outside.yaml"
mkdir -p "$PARAMS_LINK_WS/home" "$PARAMS_LINK_EXO"
printf 'outside params secret remains\n' > "$PARAMS_LINK_OUTSIDE"
printf 'ordinary must not copy before refusal\n' > "$PARAMS_LINK_EXO/ordinary.md"
ln -s "$PARAMS_LINK_OUTSIDE" "$PARAMS_LINK_EXO/params.yaml"
PARAMS_LINK_RC=0
run_restore \
    "$PARAMS_LINK_WS" "$PARAMS_LINK_MEMORY" \
    "$PARAMS_LINK/run.out" || PARAMS_LINK_RC=$?
if [ "$PARAMS_LINK_RC" -ne 0 ] && \
   [ ! -e "$PARAMS_LINK_MEMORY" ] && \
   [ ! -e "$PARAMS_LINK_WS/params.yaml" ] && \
   [ "$(cat "$PARAMS_LINK_OUTSIDE")" = "outside params secret remains" ] && \
   ! grep -q 'outside params secret remains' "$PARAMS_LINK/run.out"; then
    pass "params source symlink fails before restore writes or leaks bytes"
else
    fail "restore followed or partially applied a params source symlink"
fi

CLAUDE_LINK="$TEST_ROOT/restore-claude-symlink"
CLAUDE_LINK_WS="$CLAUDE_LINK/workspace"
CLAUDE_LINK_MEMORY="$CLAUDE_LINK/auto-memory"
CLAUDE_LINK_EXO="$CLAUDE_LINK_WS/governance/exocortex"
CLAUDE_LINK_OUTSIDE="$CLAUDE_LINK/outside.md"
mkdir -p "$CLAUDE_LINK_WS/home" "$CLAUDE_LINK_MEMORY" "$CLAUDE_LINK_EXO"
printf 'outside target remains\n' > "$CLAUDE_LINK_OUTSIDE"
printf 'workspace={{HOME_DIR}}\n' > "$CLAUDE_LINK_EXO/CLAUDE.md"
printf 'ordinary\n' > "$CLAUDE_LINK_EXO/note.md"
ln -s "$CLAUDE_LINK_OUTSIDE" "$CLAUDE_LINK_WS/CLAUDE.md"
CLAUDE_LINK_RC=0
run_restore \
    "$CLAUDE_LINK_WS" "$CLAUDE_LINK_MEMORY" "$CLAUDE_LINK/run.out" || \
    CLAUDE_LINK_RC=$?
if [ "$CLAUDE_LINK_RC" -eq 0 ] && [ ! -L "$CLAUDE_LINK_WS/CLAUDE.md" ] && \
   [ "$(cat "$CLAUDE_LINK_WS/CLAUDE.md")" = "workspace=$CLAUDE_LINK_WS/home" ] && \
   [ "$(cat "$CLAUDE_LINK_OUTSIDE")" = "outside target remains" ]; then
    pass "CLAUDE restore atomically replaces only the final symlink"
else
    fail "CLAUDE restore followed a receiver symlink or rendered non-atomically"
fi
if ! grep -Eq '(^|[^[:alnum:]_])eval([^[:alnum:]_]|$)' "$RESTORE"; then
    pass "restore contains no eval-based command execution"
else
    fail "restore still contains eval"
fi

PROTECTED="$TEST_ROOT/restore-protected"
PROTECTED_WS="$PROTECTED/workspace"
PROTECTED_MEMORY="$PROTECTED/auto-memory"
PROTECTED_EXO="$PROTECTED_WS/governance/exocortex"
mkdir -p "$PROTECTED_WS/home" "$PROTECTED_MEMORY" "$PROTECTED_EXO"
printf 'profile: keep-local\n' > "$PROTECTED_WS/params.yaml"
printf 'profile: from-backup\n' > "$PROTECTED_EXO/params.yaml"
printf 'ordinary memory\n' > "$PROTECTED_EXO/note.md"

PROTECTED_RC=0
run_restore "$PROTECTED_WS" "$PROTECTED_MEMORY" "$PROTECTED/no-force.out" || PROTECTED_RC=$?
if [ "$(cat "$PROTECTED_WS/params.yaml")" = "profile: keep-local" ]; then
    pass "restore without --force does not overwrite existing workspace params"
else
    fail "restore without --force overwrote existing workspace params"
fi
if [ ! -e "$PROTECTED_MEMORY/params.yaml" ]; then
    pass "no-force restore still keeps params out of auto-memory"
else
    fail "no-force restore copied params into auto-memory"
fi
assert_guard_signal \
    "$PROTECTED_RC" "$PROTECTED/no-force.out" \
    'params\.yaml[^[:cntrl:]]*(skip|пропуск|exist|существ|не перезап)' \
    "existing params no-overwrite decision"

FORCE_RC=0
run_restore "$PROTECTED_WS" "$PROTECTED_MEMORY" "$PROTECTED/force.out" --force || FORCE_RC=$?
if [ "$FORCE_RC" -eq 0 ]; then
    pass "forced restore succeeds"
else
    fail "forced restore failed (rc=$FORCE_RC)"
fi
if [ "$(cat "$PROTECTED_WS/params.yaml")" = "profile: from-backup" ]; then
    pass "--force restores backup params to workspace root"
else
    fail "--force did not restore backup params to workspace root"
fi
if [ ! -e "$PROTECTED_MEMORY/params.yaml" ]; then
    pass "forced restore keeps params.yaml out of auto-memory"
else
    fail "forced restore left params.yaml in auto-memory"
fi

echo "---"
if [ "$FAIL" -eq 0 ]; then
    echo "PASS: issue #536 backup/restore contracts"
    exit 0
fi
echo "FAIL: issue #536 has $FAIL contract violation(s)"
exit 1
