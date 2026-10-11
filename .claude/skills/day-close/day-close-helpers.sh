#!/usr/bin/env bash
# Helper functions for day-close skill.
# Kept in a separate file so that Claude Code skill-arg substitution ($1/$2)
# does not corrupt positional parameters inside function bodies (issue #1176).

assert_staged_scope_or_stop() {
  if [ "$#" -lt 2 ]; then
    echo "STOP: assert_staged_scope_or_stop requires <repo> <path>..." >&2
    return 74
  fi
  local repo="$1"
  shift
  # Variable names deliberately avoid zsh special parameters: `path` shadows
  # PATH (git stops resolving) and `status` is read-only in zsh (#557); the
  # agent sources these functions in the pilot's login shell, not bash.
  local staged_status staged_path staged_path_after allowed_path commit_path normalized_path display_path
  while IFS= read -r -d '' staged_status; do
    IFS= read -r -d '' staged_path || {
      echo "STOP: staged index status could not be parsed" >&2
      return 76
    }
    staged_path_after=""
    case "$staged_status" in
      R*|C*)
        IFS= read -r -d '' staged_path_after || {
          echo "STOP: staged rename/copy status could not be parsed" >&2
          return 76
        }
        ;;
    esac
    allowed_path=false
    for commit_path in "$@"; do
      normalized_path="${commit_path#./}"
      if [ "$staged_path" = "$normalized_path" ] || \
         [ "$staged_path_after" = "$normalized_path" ]; then
        allowed_path=true
        break
      fi
    done
    if ! $allowed_path; then
      display_path="$staged_path"
      [ -n "$staged_path_after" ] && display_path="$staged_path -> $staged_path_after"
      echo "STOP: staged path is outside the explicit commit scope: $display_path" >&2
      return 75
    fi
  done < <(git -C "$repo" diff --cached --name-status -z -M)
}

stage_and_commit_or_stop() {
  if [ "$#" -lt 3 ]; then
    echo "STOP: usage: stage_and_commit_or_stop <repo> <message> <path>..." >&2
    return 63
  fi
  local repo="$1" message="$2"
  shift 2
  if [ "$#" -eq 0 ]; then
    echo "STOP: no explicit paths supplied for commit" >&2
    return 64
  fi

  local commit_path normalized_path tracked_descendant
  for commit_path in "$@"; do
    case "$commit_path" in
      .|./|-A|--all|-u|--update)
        echo "STOP: broad git-add path/options are forbidden: $commit_path" >&2
        return 65
        ;;
    esac
    if [ -d "$repo/$commit_path" ]; then
      echo "STOP: explicit commit scope requires files, not a directory: $commit_path" >&2
      return 65
    fi
    normalized_path="${commit_path#./}"
    normalized_path="${normalized_path%/}"
    tracked_descendant=""
    while IFS= read -r -d '' tracked_descendant; do
      break
    done < <(git -C "$repo" ls-files -z -- "$normalized_path/")
    if [ -n "$tracked_descendant" ]; then
      echo "STOP: explicit commit scope resolves to tracked descendants, not one file: $commit_path" >&2
      return 65
    fi
    local path_status=""
    if ! path_status=$(git -C "$repo" status --porcelain=v1 --untracked-files=all -- "$commit_path"); then
      echo "STOP: path status could not be inspected: $commit_path" >&2
      return 66
    fi
    if [ -z "$path_status" ]; then
      echo "STOP: explicit path has no pending or staged change: $commit_path" >&2
      return 67
    fi
  done

  # A shared repository can already contain another agent's staged work.
  # Refuse it before mutating the index; `git commit -m` commits the whole
  # index, not only the pathspec later passed to `git add`.
  assert_staged_scope_or_stop "$repo" "$@" || return $?

  if ! git -C "$repo" add -- "$@"; then
    echo "STOP: git add failed; commit was not attempted" >&2
    return 68
  fi
  for commit_path in "$@"; do
    if git -C "$repo" diff --cached --quiet --exit-code -- "$commit_path"; then
      echo "STOP: explicit path has no staged content: $commit_path" >&2
      return 69
    else
      local path_diff_rc=$?
      if [ "$path_diff_rc" -ne 1 ]; then
        echo "STOP: staged content could not be inspected for: $commit_path" >&2
        return 70
      fi
    fi
  done
  if git -C "$repo" diff --cached --quiet --exit-code; then
    echo "STOP: staged diff is empty" >&2
    return 71
  else
    local diff_rc=$?
    if [ "$diff_rc" -ne 1 ]; then
      echo "STOP: staged diff could not be inspected" >&2
      return 72
    fi
  fi
  if ! git -C "$repo" commit -m "$message"; then
    echo "STOP: git commit failed" >&2
    return 73
  fi
}
