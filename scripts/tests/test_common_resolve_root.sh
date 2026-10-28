#!/usr/bin/env bash
set -euo pipefail

# WP-5 (2026-10-28): iwe_resolve_root() in scripts/lib/common.sh jumped three
# directories up from scripts/lib/ and looked for workspace markers there. On a
# FLAT install — where the template checkout IS the workspace — that jump
# landed on the checkout's PARENT, so every caller resolved DS-strategy/,
# memory/ and .exocortex.env one directory too high. The failure was silent
# ("DayPlan not found", "DS-strategy not found in $HOME/IWE", "0 cards
# checked") instead of loud, which is how bug 2026-10-16 stayed open after the
# 2026-10-20 fix: that fix taught the python half (scripts/lib/iwe_root.py) to
# walk up level by level, while this half kept the fixed-depth assumption.
#
# These fixtures pin the two resolvers to the same behaviour, including the
# case that hid the defect for four days: a flat install must resolve to the
# checkout itself, never to its parent.
#
# Fixtures mirror scripts/tests/test_iwe_root.py one-for-one so the two halves
# cannot drift apart again unnoticed.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
LIB_SRC="$ROOT/scripts/lib/common.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

[ -f "$LIB_SRC" ] || { echo "library not found: $LIB_SRC"; exit 1; }

# install_lib <root> — put the real library where a script of this install
# would find it, so the resolver walks up from a fixture tree, not the repo.
install_lib() {
    mkdir -p "$1/scripts/lib"
    cp "$LIB_SRC" "$1/scripts/lib/common.sh"
}

# resolve <path-to-installed-common.sh> [EXPLICIT] — echo root and exit status
# as resolver callers see them (env overrides cleared by the caller).
resolve() {
    local lib="$1" explicit="${2:-}"
    env -u IWE_WORKSPACE -u IWE_ROOT -u IWE_GOVERNANCE_REPO \
        bash -c 'source "$1"; iwe_resolve_root "${2:-}"' _ "$lib" "$explicit" 2>"$TMP/stderr.txt"
}

# --- Fixture 1: flat install — the checkout is the workspace. This is the
#     regression itself: the old three-level jump returned $TMP/flat's parent. ---
mkdir -p "$TMP/flat/DS-strategy"
install_lib "$TMP/flat"
expected=$(cd "$TMP/flat" && pwd -P)
got=$(resolve "$TMP/flat/scripts/lib/common.sh") || {
    echo "flat install: resolver failed: $(cat "$TMP/stderr.txt")"; exit 1; }
[ "$got" = "$expected" ] || {
    echo "flat install: expected '$expected', got '$got' — resolver returned the parent again"; exit 1; }

# --- Fixture 2: depth must not matter. A helper in scripts/lib/ and a script
#     in scripts/ resolve to the same root (the fixed-depth assumption broke
#     the first time this was called from a different depth). ---
got=$(resolve "$TMP/flat/scripts/lib/common.sh")
[ "$got" = "$expected" ] || { echo "flat install from scripts/lib: expected '$expected', got '$got'"; exit 1; }

# --- Fixture 3: container install — the workspace is ABOVE the checkout. ---
mkdir -p "$TMP/container/DS-strategy"
install_lib "$TMP/container/FMT-exocortex-template"
expected=$(cd "$TMP/container" && pwd -P)
got=$(resolve "$TMP/container/FMT-exocortex-template/scripts/lib/common.sh") || {
    echo "container install: resolver failed: $(cat "$TMP/stderr.txt")"; exit 1; }
[ "$got" = "$expected" ] || {
    echo "container install: expected '$expected', got '$got'"; exit 1; }

# --- Fixture 3b: container install with NO other marker — the workspace holds
#     neither the governance repo nor .iwe-runtime (a config-only governance
#     name, as scripts/tests/test_update_build_runtime_fail_closed.sh sets up).
#     The only signal is that this level contains the template checkout. Found
#     by that test going red while WP-5 was in progress: dropping the
#     "contains a template checkout" rule in favour of markers alone broke it. ---
mkdir -p "$TMP/container_bare/FMT-exocortex-template/scripts/lib"
install_lib "$TMP/container_bare/FMT-exocortex-template"
expected=$(cd "$TMP/container_bare" && pwd -P)
got=$(resolve "$TMP/container_bare/FMT-exocortex-template/scripts/lib/common.sh") || {
    echo "container-without-markers: resolver failed: $(cat "$TMP/stderr.txt")"; exit 1; }
[ "$got" = "$expected" ] || {
    echo "container-without-markers: expected '$expected', got '$got'"; exit 1; }

# --- Fixture 4: .exocortex.env WORKSPACE_DIR wins over the markers of the
#     same level — same precedence as _workspace_dir_from_env_file() in
#     iwe_root.py. ---
mkdir -p "$TMP/envcase/chosen"
mkdir -p "$TMP/envcase/FMT-exocortex-template/DS-strategy"
configured=$(cd "$TMP/envcase/chosen" && pwd -P)
printf 'WORKSPACE_DIR="%s"\n' "$configured" > "$TMP/envcase/FMT-exocortex-template/.exocortex.env"
install_lib "$TMP/envcase/FMT-exocortex-template"
got=$(resolve "$TMP/envcase/FMT-exocortex-template/scripts/lib/common.sh") || {
    echo "env-file case: resolver failed: $(cat "$TMP/stderr.txt")"; exit 1; }
[ "$got" = "$configured" ] || {
    echo "env-file case: expected '$configured', got '$got'"; exit 1; }

# --- Fixture 5: an .exocortex.env pointing at a directory that does not exist
#     must not be returned (the python half checks is_dir()). Markers of that
#     level take over instead. ---
printf 'WORKSPACE_DIR="%s/does-not-exist"\n' "$TMP/envcase" > "$TMP/envcase/FMT-exocortex-template/.exocortex.env"
expected=$(cd "$TMP/envcase/FMT-exocortex-template" && pwd -P)
got=$(resolve "$TMP/envcase/FMT-exocortex-template/scripts/lib/common.sh") || {
    echo "stale-env-file case: resolver failed: $(cat "$TMP/stderr.txt")"; exit 1; }
[ "$got" = "$expected" ] || {
    echo "stale-env-file case: expected '$expected', got '$got'"; exit 1; }

# --- Fixture 6: nothing to resolve to — fail loudly, never guess $HOME/IWE.
#     A guessed root is what made the original defect invisible. ---
mkdir -p "$TMP/bare/deep/nest"
install_lib "$TMP/bare/deep/nest"
if got=$(resolve "$TMP/bare/deep/nest/scripts/lib/common.sh"); then
    echo "unresolvable case: expected failure, got root '$got'"; exit 1
fi
grep -Fq 'cannot determine workspace root' "$TMP/stderr.txt" || {
    echo "unresolvable case: error must say the root could not be determined"; cat "$TMP/stderr.txt"; exit 1; }
# The library must not carry a $HOME/IWE default anywhere — the comment
# mentioning the old behaviour is fine, an assignment is not.
grep -Eq '(:-|\=)[[:space:]]*"?\$HOME/IWE' "$LIB_SRC" && {
    echo "unresolvable case: library still defaults to \$HOME/IWE"; exit 1; } || true

# --- Fixture 7: explicit argument and env overrides keep priority (same order
#     as ENV_OVERRIDE_VARS in iwe_root.py). ---
explicit=$(cd "$TMP" && pwd -P)
got=$(resolve "$TMP/flat/scripts/lib/common.sh" "$explicit")
[ "$got" = "$explicit" ] || { echo "explicit arg: expected '$explicit', got '$got'"; exit 1; }

got=$(env -u IWE_ROOT IWE_WORKSPACE="$explicit" bash -c \
    'source "$1"; iwe_resolve_root' _ "$TMP/flat/scripts/lib/common.sh")
[ "$got" = "$explicit" ] || { echo "IWE_WORKSPACE override: expected '$explicit', got '$got'"; exit 1; }

got=$(env -u IWE_WORKSPACE IWE_ROOT="$explicit" bash -c \
    'source "$1"; iwe_resolve_root' _ "$TMP/flat/scripts/lib/common.sh")
[ "$got" = "$explicit" ] || { echo "IWE_ROOT override: expected '$explicit', got '$got'"; exit 1; }

echo 'PASS: iwe_resolve_root resolves flat and container installs, honours .exocortex.env and overrides, and fails instead of guessing'
