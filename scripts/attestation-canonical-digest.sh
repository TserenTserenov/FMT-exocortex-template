#!/bin/bash
# attestation-canonical-digest.sh — WP-529 Ф21 canonical digest for red-team attestation.
#
# Computes a deterministic digest over every tracked file in a commit's
# tree. Used by both the untrusted compute job (diagnostic only) and the
# trusted signing job (authoritative — see attestation-sign.sh), which MUST
# run this exact same script from a pinned trusted ref, never from the PR
# tree being evaluated (peer-session
# 2026-08-27-14-wp529-f21-implement-attestation, turn 1: a signer that
# checks out and executes the PR's own copy of this script lets the PR
# author control what gets "verified").
#
# The attestation itself is published via the GitHub Attestations API
# (actions/attest — see attestation-sign.sh), never committed into the
# repo tree, so ordinarily nothing needs to be excluded from the digest
# (peer-session 05-peer.md, turn 5: committing the attestation was the
# only reason an excluded path existed in the first place). The optional
# excluded-path argument is kept for the alternate deployment where a
# consumer commits the attestation file into their own tree and needs to
# exclude it from what it signs — pass "" to exclude nothing (the
# production default here).
#
# Deliberately does NOT use `git ls-tree -r -t` (which also returns
# intermediate tree objects) — plain `git ls-tree -r` returns only blobs and
# submodule commit entries, so an excluded path's presence/absence never
# leaks into a parent tree SHA the way it did in the first (rejected) design
# (peer-session 2026-08-27-13-wp529-f19-shag2-enforce, round 1/2: "ancestor
# tree SHA leak").
#
# Fails closed (nonzero exit, no digest printed) on:
#   - a non-empty excluded path missing from the tree (misconfiguration or
#     an attempt to dodge the check by renaming the file away)
#   - any submodule/gitlink entry (mode 160000) anywhere in the tree
#   - any tree entry whose git object is missing or truncated (partial/
#     shallow clone that doesn't actually have the object)
#
# Usage: attestation-canonical-digest.sh <commit-ish> <excluded-path|""> [repo-path]
# repo-path defaults to the repo this script lives in (production use: the
# workflow already checked out the right repo). Tests pass an explicit
# throwaway repo instead of mutating the real one.
# Output (stdout, on success): one line, "^[0-9a-f]{64}$".

set -euo pipefail

if [ $# -lt 2 ] || [ $# -gt 3 ]; then
  echo "usage: $0 <commit-ish> <excluded-path|\"\"> [repo-path]" >&2
  exit 2
fi

COMMIT="$1"
EXCLUDED_PATH="$2"
REPO_ROOT="${3:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

TMP_RECORDS="$(mktemp)"
trap 'rm -f "$TMP_RECORDS"' EXIT

found_excluded=false
saw_any=false

# NUL-delimited throughout: git paths cannot contain NUL, so it is a safe
# universal separator and needs no length-prefix bookkeeping. `read -d ''`
# reads up to (and consumes) a NUL byte; works on bash 3.2 (macOS default).
while IFS= read -r -d '' entry; do
  saw_any=true
  mode="${entry%% *}"
  rest="${entry#* }"
  type="${rest%% *}"
  rest2="${rest#* }"
  blob_sha="${rest2%%$'\t'*}"
  path="${rest2#*$'\t'}"

  if [ "$type" = "commit" ]; then
    echo "ERROR: submodule/gitlink present at '$path' (mode $mode) — not supported, fail-closed" >&2
    exit 3
  fi
  if [ "$type" != "blob" ]; then
    echo "ERROR: unexpected tree entry type '$type' at '$path' — fail-closed" >&2
    exit 3
  fi

  if [ -n "$EXCLUDED_PATH" ] && [ "$path" = "$EXCLUDED_PATH" ]; then
    found_excluded=true
    continue
  fi

  # `git cat-file -p` dumps the blob's raw bytes — for a symlink (mode
  # 120000) that IS the target path text, not the referenced file's
  # content; treated uniformly as opaque blob bytes, same as any other
  # blob, deliberately (no special-casing symlinks).
  if ! content_sha="$(git -C "$REPO_ROOT" cat-file -p "$blob_sha" 2>/dev/null | sha256sum | awk '{print $1}')"; then
    echo "ERROR: could not read blob '$blob_sha' for '$path' — missing object (shallow/partial clone?), fail-closed" >&2
    exit 4
  fi

  # Path first: lets the final sort key on the whole NUL-terminated record
  # without a -t/-k argument (see note below on why -t can't carry NUL).
  printf '%s\0%s\0%s\0%s\0' "$path" "$mode" "$type" "$content_sha" >> "$TMP_RECORDS"
done < <(git -C "$REPO_ROOT" ls-tree -r -z "$COMMIT")

if [ "$saw_any" != "true" ]; then
  echo "ERROR: '$COMMIT' has an empty tree — fail-closed (refusing to attest nothing)" >&2
  exit 5
fi

if [ -n "$EXCLUDED_PATH" ] && [ "$found_excluded" != "true" ]; then
  echo "ERROR: excluded path '$EXCLUDED_PATH' not found in tree of '$COMMIT' — fail-closed" >&2
  exit 6
fi

# Explicit re-sort by raw path bytes (not relied-upon git traversal order):
# each record is "path\0mode\0type\0content_sha\0" with path moved to the
# front, so a plain whole-record `sort -z` (LC_ALL=C, byte-wise) already
# sorts by path first — paths are unique per tree, so the trailing fields
# never need to break a tie. Deliberately NOT `-t $'\0' -k4` (the field-4
# approach this replaced): bash cannot pass a literal NUL byte as a command
# argument, so $'\0' arrives at `sort` as an empty string — GNU sort (Linux
# CI) rejects that outright ("sort: empty tab", exit 2), while BSD sort
# (macOS, where this was authored) silently tolerates it, which is why the
# bug shipped past local testing and only broke on integration-contract-ubuntu.
SORTED_RECORDS="$(mktemp)"
trap 'rm -f "$TMP_RECORDS" "$SORTED_RECORDS"' EXIT
LC_ALL=C sort -z "$TMP_RECORDS" > "$SORTED_RECORDS"

# Version/domain separator prefix (Codex, turn 1: prevents a digest computed
# for an unrelated purpose from being replayed here even if the byte format
# happened to coincide).
{
  printf 'wp529-canonical-digest-v1\0'
  cat "$SORTED_RECORDS"
} | sha256sum | awk '{print $1}'
