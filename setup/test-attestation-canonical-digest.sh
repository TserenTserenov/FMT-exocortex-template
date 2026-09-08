#!/bin/bash
# test-attestation-canonical-digest.sh — regression test for
# scripts/attestation-canonical-digest.sh (WP-529 Ф21).
#
# Builds small throwaway git repos in a temp dir and asserts observable
# properties of the digest (not "ran without crashing" — see
# CLAUDE.md P1): determinism, exclusion, sensitivity to real content
# changes, and every fail-closed case the peer session
# (2026-08-27-13/14-wp529-...) required.
#
# Usage: bash setup/test-attestation-canonical-digest.sh [--verbose]
# Exit: 0 — all cases passed. N — N cases failed.

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_DIR="$(dirname "$SCRIPT_DIR")"
DIGEST_SCRIPT="$TEMPLATE_DIR/scripts/attestation-canonical-digest.sh"
VERBOSE=false
[ "${1:-}" = "--verbose" ] && VERBOSE=true

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAIL=0
PASS=0

log() { $VERBOSE && echo "  $*" >&2 || true; }

# new_repo <name> — creates $WORK/<name> as a fresh git repo, cds nowhere
# (caller runs git -C explicitly so tests never depend on cwd).
new_repo() {
    local dir="$WORK/$1"
    mkdir -p "$dir"
    git -C "$dir" init -q
    git -C "$dir" config user.email t@t.example
    git -C "$dir" config user.name test
    echo "$dir"
}

commit_all() {
    local dir="$1"
    git -C "$dir" add -A
    git -C "$dir" commit -q -m "state"
}

digest_of() {
    local dir="$1" sha="$2" excluded="$3"
    bash "$DIGEST_SCRIPT" "$sha" "$excluded" "$dir" 2>/dev/null
}

assert_eq() {
    local name="$1" got="$2" want="$3"
    if [ "$got" = "$want" ]; then
        PASS=$((PASS + 1))
        log "PASS: $name"
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: $name — expected '$want', got '$got'" >&2
    fi
}

assert_neq() {
    local name="$1" got="$2" not_want="$3"
    if [ "$got" != "$not_want" ]; then
        PASS=$((PASS + 1))
        log "PASS: $name"
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: $name — expected value to differ from '$not_want', but it matched" >&2
    fi
}

assert_fails() {
    local name="$1" dir="$2" sha="$3" excluded="$4"
    if bash "$DIGEST_SCRIPT" "$sha" "$excluded" "$dir" >/dev/null 2>&1; then
        FAIL=$((FAIL + 1))
        echo "FAIL: $name — expected nonzero exit (fail-closed), got success" >&2
    else
        PASS=$((PASS + 1))
        log "PASS: $name"
    fi
}

is_hex64() {
    printf '%s' "$1" | grep -qE '^[0-9a-f]{64}$'
}

# --- Case 1: determinism — same tree hashed twice gives the same digest ---
r1="$(new_repo case1)"
echo "hello" > "$r1/a.txt"
echo "world" > "$r1/b.txt"
mkdir -p "$r1/attestation"
echo "att" > "$r1/attestation/att.yml"
commit_all "$r1"
sha1="$(git -C "$r1" rev-parse HEAD)"
d1a="$(digest_of "$r1" "$sha1" "attestation/att.yml")"
d1b="$(digest_of "$r1" "$sha1" "attestation/att.yml")"
assert_eq "determinism: repeated computation matches" "$d1b" "$d1a"
if is_hex64 "$d1a"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: output is not 64 hex chars: '$d1a'" >&2; fi

# --- Case 2: excluded path's content does NOT affect the digest ---
r2="$(new_repo case2)"
cp -R "$r1/." "$r2/"
rm -rf "$r2/.git"
git -C "$r2" init -q
git -C "$r2" config user.email t@t.example
git -C "$r2" config user.name test
echo "different attestation content" > "$r2/attestation/att.yml"
commit_all "$r2"
sha2="$(git -C "$r2" rev-parse HEAD)"
d2="$(digest_of "$r2" "$sha2" "attestation/att.yml")"
assert_eq "excluded path content is ignored" "$d2" "$d1a"

# --- Case 3: excluded path missing from the tree → fail-closed ---
r3="$(new_repo case3)"
echo "hello" > "$r3/a.txt"
commit_all "$r3"
sha3="$(git -C "$r3" rev-parse HEAD)"
assert_fails "missing excluded path fails closed" "$r3" "$sha3" "attestation/att.yml"

# --- Case 4: changing a non-excluded file changes the digest ---
r4="$(new_repo case4)"
cp -R "$r1/." "$r4/"
rm -rf "$r4/.git"
git -C "$r4" init -q
git -C "$r4" config user.email t@t.example
git -C "$r4" config user.name test
echo "hello, but different" > "$r4/a.txt"
commit_all "$r4"
sha4="$(git -C "$r4" rev-parse HEAD)"
d4="$(digest_of "$r4" "$sha4" "attestation/att.yml")"
assert_neq "changing a tracked file changes the digest" "$d4" "$d1a"

# --- Case 4b: empty excluded-path means "exclude nothing" (production
# mode — the attestation is published via the GitHub Attestations API,
# never committed, so there is nothing to exclude; peer-session 05-peer.md
# turn 5) — same tree, with vs without an excluded path, differ, and the
# no-exclusion digest is stable across repeated calls.
d1_noexcl_a="$(digest_of "$r1" "$sha1" "")"
d1_noexcl_b="$(digest_of "$r1" "$sha1" "")"
assert_eq "empty excluded-path is deterministic too" "$d1_noexcl_b" "$d1_noexcl_a"
assert_neq "excluding a path changes the digest vs excluding nothing" "$d1_noexcl_a" "$d1a"

# --- Case 5: NUL-safety — path with a literal tab and a literal newline ---
r5="$(new_repo case5)"
weird_dir="$r5/w"
mkdir -p "$weird_dir"
# git allows control bytes in paths (not NUL); build filenames with tab/LF.
tabname="$(printf 'a\tb.txt')"
nlname="$(printf 'c\nd.txt')"
printf 'content-tab\n' > "$weird_dir/$tabname"
printf 'content-nl\n' > "$weird_dir/$nlname"
mkdir -p "$r5/attestation"
echo "att" > "$r5/attestation/att.yml"
commit_all "$r5"
sha5="$(git -C "$r5" rev-parse HEAD)"
d5="$(digest_of "$r5" "$sha5" "attestation/att.yml")"
if is_hex64 "$d5"; then
    PASS=$((PASS + 1))
    log "PASS: tab/newline path names do not break parsing"
else
    FAIL=$((FAIL + 1))
    echo "FAIL: tab/newline path names broke digest computation, got '$d5'" >&2
fi

# --- Case 6: mode matters — same bytes, different mode (regular vs exec) ---
r6="$(new_repo case6)"
echo "same content" > "$r6/script.sh"
mkdir -p "$r6/attestation"
echo "att" > "$r6/attestation/att.yml"
commit_all "$r6"
sha6a="$(git -C "$r6" rev-parse HEAD)"
d6a="$(digest_of "$r6" "$sha6a" "attestation/att.yml")"
chmod +x "$r6/script.sh"
commit_all "$r6"
sha6b="$(git -C "$r6" rev-parse HEAD)"
d6b="$(digest_of "$r6" "$sha6b" "attestation/att.yml")"
assert_neq "chmod +x (same bytes) changes the digest" "$d6b" "$d6a"

# --- Case 7: symlink content is the target path, hashed as opaque bytes ---
r7="$(new_repo case7)"
echo "real" > "$r7/real.txt"
ln -s real.txt "$r7/link.txt"
mkdir -p "$r7/attestation"
echo "att" > "$r7/attestation/att.yml"
commit_all "$r7"
sha7="$(git -C "$r7" rev-parse HEAD)"
d7="$(digest_of "$r7" "$sha7" "attestation/att.yml")"
if is_hex64 "$d7"; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "FAIL: symlink handling broke digest computation, got '$d7'" >&2; fi

# --- Case 8: submodule (gitlink, mode 160000) → fail-closed ---
r8="$(new_repo case8)"
sub="$(new_repo case8-sub)"
echo "x" > "$sub/x.txt"
commit_all "$sub"
mkdir -p "$r8/attestation"
echo "att" > "$r8/attestation/att.yml"
git -C "$r8" -c protocol.file.allow=always submodule add -q "$sub" vendored 2>/dev/null || \
    git -C "$r8" update-index --add --cacheinfo 160000,"$(git -C "$sub" rev-parse HEAD)",vendored
git -C "$r8" add -A
git -C "$r8" commit -q -m "with submodule"
sha8="$(git -C "$r8" rev-parse HEAD)"
assert_fails "submodule/gitlink entry fails closed" "$r8" "$sha8" "attestation/att.yml"

# --- Case 9: empty tree (no files at all) → fail-closed ---
r9="$(new_repo case9)"
git -C "$r9" commit -q --allow-empty -m "empty"
sha9="$(git -C "$r9" rev-parse HEAD)"
assert_fails "empty tree fails closed" "$r9" "$sha9" "attestation/att.yml"

# --- Case 10: golden vector, built via git plumbing (hash-object + mktree),
# never through the filesystem — the cross-OS determinism concern is about
# whether a filesystem SILENTLY NORMALIZES Unicode filenames on write (HFS+
# historically did; verified live on this machine's APFS that it currently
# does not, but that is exactly the kind of runner/version-specific behavior
# this test must not depend on). Building the tree directly in git's object
# database sidesteps the question entirely: blob and tree SHAs are
# content-addressed, so the same bytes always produce the same tree
# regardless of what any given runner's filesystem would have done with
# them (peer-session 2026-08-27-14-wp529-f21-implement-attestation, turn 11).
# If this ever produces a different digest on a different OS, this
# hardcoded expected value catches it immediately — see also the
# ubuntu-latest/macos-latest CI matrix that runs this whole suite on both.
golden_dir="$WORK/golden"
mkdir -p "$golden_dir"
git -C "$golden_dir" init -q

blob_ascii="$(printf 'plain ascii\n' | git -C "$golden_dir" hash-object -w --stdin)"
blob_nfc="$(printf 'nfc content\n' | git -C "$golden_dir" hash-object -w --stdin)"
blob_nfd="$(printf 'nfd content\n' | git -C "$golden_dir" hash-object -w --stdin)"
blob_space="$(printf 'space content\n' | git -C "$golden_dir" hash-object -w --stdin)"
blob_symlink_target="$(printf 'a.txt' | git -C "$golden_dir" hash-object -w --stdin)"
blob_no_newline="$(printf 'no trailing newline' | git -C "$golden_dir" hash-object -w --stdin)"

# NFC_NAME: e-acute as one codepoint (U+00E9). NFD_NAME: e + combining
# acute accent (U+0065 U+0301) — same rendered glyph, different bytes; git
# (and our digest) must treat them as two distinct files, never collapse
# them, on every OS.
nfc_name="$(printf 'unicode-nfc-\xc3\xa9.txt')"
nfd_name="$(printf 'unicode-nfd-e\xcc\x81.txt')"
space_name="$(printf 'name with space.txt')"
tab_name="$(printf 'name\twith\ttab.txt')"
nl_name="$(printf 'name\nwith\nnewline.txt')"

{
  printf '100644 blob %s\t%s\0' "$blob_ascii" "a.txt"
  printf '100644 blob %s\t%s\0' "$blob_nfc" "$nfc_name"
  printf '100644 blob %s\t%s\0' "$blob_nfd" "$nfd_name"
  printf '100644 blob %s\t%s\0' "$blob_space" "$space_name"
  printf '100644 blob %s\t%s\0' "$blob_no_newline" "no-newline.txt"
  printf '120000 blob %s\t%s\0' "$blob_symlink_target" "link.txt"
  printf '100644 blob %s\t%s\0' "$blob_ascii" "$tab_name"
  printf '100644 blob %s\t%s\0' "$blob_ascii" "$nl_name"
} > "$golden_dir/tree-input"

golden_tree_sha="$(git -C "$golden_dir" mktree -z < "$golden_dir/tree-input")"
golden_digest="$(digest_of "$golden_dir" "$golden_tree_sha" "")"
assert_eq "golden vector matches the hardcoded expected digest" \
  "$golden_digest" \
  "e01345666ec30bf71ce15703132a22e87300a9089bb9716aa93a56171252113a"

echo ""
echo "attestation-canonical-digest.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
