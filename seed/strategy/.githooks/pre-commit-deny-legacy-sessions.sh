#!/usr/bin/env bash
# pre-commit-deny-legacy-sessions.sh — blocks new writes under the retired
# governance-repo `sessions/` directory, but ONLY on an already-migrated
# installation (MC-sessions exists as a sibling repo, or IWE_SESSIONS_ROOT is
# set explicitly). A fresh, unmigrated template install legitimately still
# writes into `sessions/` (session-guard.sh:resolve_orz_sessions_dir() falls
# back there with a WARN) — blocking that would break every new user's first
# commit. Seed variant of the same guard already used in the author's own
# governance repo (WP-526, peer-session 2026-08-31-09-wp526-migration-continue):
# same guard, gated on migration state so it stays inert until the user
# actually migrates.
#
# Migration-state check mirrors resolve_orz_sessions_dir() in
# scripts/session-guard.sh exactly (4-state matrix — do not diverge):
#   - IWE_SESSIONS_ROOT set (valid or broken) -> migrated, guard active
#   - $IWE_ROOT/MC-sessions exists (valid or broken git repo) -> migrated, guard active
#   - neither -> unmigrated, guard inert (exit 0 immediately)
#
# Guard analyzes the INDEX (staged), not the working tree. --no-renames is
# required: moving a file into the forbidden directory shows up as
# delete+add and would otherwise bypass the check.
#
# Optional exact-path allowlist:
#   .git/info/iwe-legacy-sessions.allow
#
# Example line:
#   sessions/README-migration-tombstone.md
#
# Limitation: local pre-commit is bypassed by `git commit --no-verify` — this
# is a regression guard, not a security boundary. A server-side/CI gate would
# be needed for enforced policy (open question, not addressed here).

set -u

repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  echo "deny-legacy-sessions: cannot resolve repository root" >&2
  exit 2
}
cd "$repo_root" || exit 2

iwe_root="${IWE_ROOT:-$HOME/IWE}"

is_migrated() {
  if [ -n "${IWE_SESSIONS_ROOT:-}" ]; then
    return 0
  fi
  local default_mc="$iwe_root/MC-sessions"
  [ -d "$default_mc" ]
}

is_migrated || exit 0

allow_file="${IWE_LEGACY_SESSIONS_ALLOWLIST:-$(git rev-parse --git-path info/iwe-legacy-sessions.allow)}"

is_explicitly_allowed() {
  candidate="$1"
  [ -f "$allow_file" ] || return 1

  while IFS= read -r allowed || [ -n "$allowed" ]; do
    case "$allowed" in
      ""|\#*) continue ;;
    esac
    [ "$candidate" = "$allowed" ] && return 0
  done <"$allow_file"

  return 1
}

blocked=0

# NUL-delimited input correctly handles spaces, tabs and newlines in Git paths.
# --no-renames makes every new destination appear as an addition.
while IFS= read -r -d '' path; do
  case "$path" in
    sessions/*)
      if is_explicitly_allowed "$path"; then
        printf 'ALLOW legacy sessions path: %q\n' "$path" >&2
      else
        printf 'BLOCK: staged addition under retired sessions/: %q\n' \
          "$path" >&2
        blocked=1
      fi
      ;;
  esac
done < <(
  git diff --cached \
    --name-only \
    --no-renames \
    --diff-filter=A \
    -z \
    --
)

if [ "$blocked" -ne 0 ]; then
  cat >&2 <<'EOF'
Commit rejected: new files under legacy sessions/ are forbidden on this
already-migrated installation (MC-sessions exists).

Move the file to MC-sessions. A genuine migration tombstone requires an exact
path entry in the local approved allowlist; do not add broad prefixes.
EOF
  exit 1
fi

exit 0
