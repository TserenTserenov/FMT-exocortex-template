#!/bin/bash
# install-hooks.sh — устанавливает .githooks/ как core.hooksPath для governance-репо.
#
# Usage:
#   bash scripts/install-hooks.sh [REPO_PATH]
#
# If REPO_PATH is omitted, uses the current working directory.
# This script is intentionally minimal and template-safe: it does not hardcode
# governance-repo paths or agent-specific checks. It only wires the repository
# to the tracked .githooks/ directory (pre-commit + pre-push guards).
#
# issue #342: an install where .githooks/ predates the pre-push guard (only
# pre-commit tracked) would run this script, get "✅ Hooks wired" and still
# have no force-push protection — nothing here ever copied the hook content,
# only backed up / chmod'd whatever already happened to exist. Fixed by
# copying missing hooks from the template's canonical seed/strategy/.githooks/
# (found via IWE_TEMPLATE / IWE_ROOT, same fallback chain roles/extractor and
# create-wp.sh already use) and by refusing to claim success if a hook is
# still missing afterwards.
#
# WP-484 (31.08.2026): a hook that exists but differs from canonical is never
# overwritten anymore — only a MISSING hook gets copied. The previous
# behavior force-synced content on every drift, which discarded a governance
# repo's own repo-specific composite pre-commit hook during an unrelated
# core.hooksPath repair. Divergent local content is assumed intentional; the
# backup-then-overwrite dance existed only to make that destructive overwrite
# less bad, so it's gone along with it.
#
# see WP-436 (force-push guard) + seed/strategy/.githooks/

set -euo pipefail

# --check-secret-scan: a read-only probe for update.sh, prints nothing, exit 3 when the commit
# check that will run in this repository never calls the secret scan (issue #1670, point 4).
CHECK_SECRET_SCAN=false
if [ "${1:-}" = "--check-secret-scan" ]; then
  CHECK_SECRET_SCAN=true
  shift
fi

REPO="${1:-${PWD}}"
HOOK_DIR="$REPO/.githooks"

if [ -L "$REPO" ] || [ -L "$REPO/.git" ] || [ ! -d "$REPO/.git" ]; then
  echo "❌ Not a git repo: $REPO"
  exit 1
fi

points_at_platform_hooks() {
  case "$1" in
    .githooks|.githooks/|./.githooks|./.githooks/) return 0 ;;
    /*) [ -d "$1" ] && [ -d "$HOOK_DIR" ] && [ "$(cd "$1" && pwd -P)" = "$(cd "$HOOK_DIR" && pwd -P)" ] ;;
    *) return 1 ;;
  esac
}

# issue #1670, point 4: the pre-commit that really runs in this repository may be the user's own (a
# copy that differs from the platform one, or one in their own hooks folder). When it never calls the
# secret scan, commits are not checked for secrets, and the only trace used to be the line
# "pre-commit отличается от канонического шаблона", easy to miss. Say it plainly, with the line to
# add. The user's hook is never changed (WP-484). Only a verified target counts as delegation.
# Complex custom shell is conservatively unconfirmed; never execute a hook to inspect it.
simple_hook_calls() { # <file> <scan|delegate>
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - "$1" "$2" "$REPO" <<'PY_HOOK'
import os
import re
import shlex
import sys

path, wanted, repo = sys.argv[1:]
try:
    with open(path, encoding="utf-8") as stream:
        lines = stream.readlines()
except (OSError, UnicodeError):
    sys.exit(1)
if not lines or lines[0].strip() not in {
    "#!/bin/sh", "#!/bin/bash", "#!/usr/bin/sh", "#!/usr/bin/bash",
    "#!/usr/bin/env sh", "#!/usr/bin/env bash",
}:
    sys.exit(1)
errexit = False
delegates = {
    ".githooks/pre-commit", "./.githooks/pre-commit",
    "$(git rev-parse --show-toplevel)/.githooks/pre-commit",
    os.path.join(repo, ".githooks", "pre-commit"),
}
for line in lines:
    try:
        words = shlex.split(line, comments=True)
    except ValueError:
        sys.exit(1)
    if not words:
        continue
    replaced_shell = words[0] == "exec"
    if words[0] in ("exec", "command"):
        words = words[1:]
    if not words:
        sys.exit(1)
    command = words[0]
    called = words[1:] if os.path.basename(command) in {"bash", "sh"} else words
    if called and called[0] == "--":
        called = called[1:]
    script = called[0] if called else ""
    matched = (
        wanted == "scan" and os.path.basename(script) == "pre-commit-secret-scan.sh"
        or wanted == "delegate" and script in delegates
    )
    if matched:
        tail = called[1:]
        # The call must gate the commit, rather than run asynchronously or swallow failure.
        aborts_on_failure = "#" not in line and tail == ["||", "exit", "1"] and re.search(
            r"\s\|\|\s+exit\s+1\s*(?:#.*)?$", line
        )
        if aborts_on_failure or not tail and (errexit or replaced_shell):
            sys.exit(0)
        sys.exit(1)
    if replaced_shell:
        sys.exit(1)
    if command == "set":
        flags = words[1] if len(words) > 1 else ""
        if not (
            len(words) == 2 and re.fullmatch(r"-[eux]+", flags)
            or len(words) == 3 and re.fullmatch(r"-[eux]*o", flags) and words[2] == "pipefail"
        ):
            sys.exit(1)
        errexit = errexit or "e" in flags
        continue
    # Only an unambiguous prologue is supported: a conditional continuation cannot
    # make its following physical line look like an unconditional scanner invocation.
    if command != "echo" or any(
        any(char in word for char in ";&|<>$(){}" + chr(96)) for word in words[1:]
    ):
        sys.exit(1)
sys.exit(1)
PY_HOOK
}

hook_calls_scan() { # <pre-commit>
  [ -f "$1" ] || return 1
  if [ -n "$CANONICAL_HOOKS_DIR" ] && cmp -s "$1" "$CANONICAL_HOOKS_DIR/pre-commit"; then
    return 0
  fi
  simple_hook_calls "$1" scan
}

# secret_scan_gap <core.hooksPath value or empty>: prints the pre-commit that will run and returns 0
# when a scanner call cannot be established; returns 1 for the current canonical hook,
# a simple scanner invocation or delegation to a target with one of those forms.
secret_scan_gap() {
  local hooks_path="$1" pre_commit
  if [ -n "$hooks_path" ] && [ "$hooks_path" != /dev/null ] && ! points_at_platform_hooks "$hooks_path"; then
    case "$hooks_path" in
      /*) pre_commit="${hooks_path%/}/pre-commit" ;;
      *) pre_commit="$REPO/${hooks_path%/}/pre-commit" ;;
    esac
  else
    pre_commit="$HOOK_DIR/pre-commit"
  fi
  if hook_calls_scan "$pre_commit"; then
    return 1
  fi
  if [ "$pre_commit" != "$HOOK_DIR/pre-commit" ] \
      && simple_hook_calls "$pre_commit" delegate \
      && hook_calls_scan "$HOOK_DIR/pre-commit"; then
    return 1
  fi
  printf '%s\n' "$pre_commit"
}

warn_secret_scan_gap() { # <pre-commit path>
  local scanner="${CANONICAL_HOOKS_DIR%/seed/strategy/.githooks}/scripts/pre-commit-secret-scan.sh"
  echo "⚠️  СЕКРЕТЫ НЕ ПРОВЕРЯЮТСЯ при сохранении в $REPO: проверяемый вызов pre-commit-secret-scan.sh не найден (#1670)."
  if [ -f "$1" ]; then
    echo "   Файл: $1"
  else
    echo "   В папке $(dirname "$1") нет pre-commit."
  fi
  echo "   Добавьте в начало своего pre-commit строку (образец — блок «secret corpus scan» в seed/strategy/.githooks/pre-commit):"
  echo "     bash \"$scanner\" || exit 1"
  echo "   Свой pre-commit установщик не меняет."
}

CANONICAL_HOOKS_DIR=""
for candidate in \
  "${IWE_TEMPLATE:-}/seed/strategy/.githooks" \
  "${IWE_ROOT:-$HOME/IWE}/FMT-exocortex-template/seed/strategy/.githooks" \
  "$HOME/IWE/FMT-exocortex-template/seed/strategy/.githooks"
do
  if [ -n "$candidate" ] && [ ! -L "$candidate" ] && [ -d "$candidate" ]; then
    CANONICAL_HOOKS_DIR="$candidate"
    break
  fi
done

if $CHECK_SECRET_SCAN; then
  hooks_path_rc=0
  current_hooks_path=$(git -C "$REPO" config --get core.hooksPath) || hooks_path_rc=$?
  [ "$hooks_path_rc" -le 1 ] || exit 1
  if secret_scan_gap "$current_hooks_path" >/dev/null; then
    exit 3
  fi
  exit 0
fi

MISSING_SOURCE=""
for hook in pre-commit pre-push; do
  [ -n "$CANONICAL_HOOKS_DIR" ] \
    && [ ! -L "$CANONICAL_HOOKS_DIR/$hook" ] \
    && [ -f "$CANONICAL_HOOKS_DIR/$hook" ] \
    || MISSING_SOURCE="$MISSING_SOURCE $hook"
done
if [ -n "$MISSING_SOURCE" ]; then
  echo "⚠️  Канонический источник hooks не найден или неполон:$MISSING_SOURCE"
  echo "   Искали в \$IWE_TEMPLATE, \$IWE_ROOT/FMT-exocortex-template, \$HOME/IWE/FMT-exocortex-template."
  echo "   core.hooksPath не изменён."
  exit 1
fi

if [ -L "$HOOK_DIR" ]; then
  echo "❌ Refusing symlink hook directory in $REPO" >&2
  echo "   core.hooksPath не изменён." >&2
  exit 1
fi
for hook in pre-commit pre-push; do
  if [ -L "$HOOK_DIR/$hook" ]; then
    echo "❌ Refusing symlink hook target: $HOOK_DIR/$hook" >&2
    echo "   Ни один hook и core.hooksPath не изменены." >&2
    exit 1
  fi
done
mkdir -p "$HOOK_DIR"

copy_hook_atomically() {
  local source_hook="$1" target="$2" temporary
  temporary=$(mktemp "$HOOK_DIR/.iwe-hook-copy.XXXXXX")
  if ! cp "$source_hook" "$temporary" \
    || ! chmod +x "$temporary" \
    || ! mv -f "$temporary" "$target"; then
    rm -f "$temporary"
    echo "❌ Hook copy failed atomically: $target" >&2
    return 1
  fi
}

for hook in pre-commit pre-push; do
  target="$HOOK_DIR/$hook"
  source_hook="$CANONICAL_HOOKS_DIR/$hook"

  if [ ! -f "$target" ]; then
    copy_hook_atomically "$source_hook" "$target"
  elif ! cmp -s "$source_hook" "$target"; then
    echo "⚠️  $hook отличается от канонического шаблона — оставляю локальную версию (не самолечу контент, см. WP-484 в комментарии выше)."
  fi

  [ -f "$target" ] && chmod +x "$target"
done

# issue #1688: a core.hooksPath the user already pointed at their own hooks
# (.husky, a shared hooks folder, set locally or globally) is kept. Replacing it
# silently switched off the user's linters and secret checks on every update.
# Only an unset value, or one that already resolves to this repo's .githooks,
# is (re)written.
hooks_path_rc=0
current_hooks_path=$(git -C "$REPO" config --get core.hooksPath) || hooks_path_rc=$?
if [ "$hooks_path_rc" -gt 1 ]; then
  echo "❌ Cannot read core.hooksPath of $REPO (git config rc=$hooks_path_rc)" >&2
  echo "   core.hooksPath не изменён." >&2
  exit 1
fi

if [ -n "$current_hooks_path" ] && [ "$current_hooks_path" != /dev/null ] && ! points_at_platform_hooks "$current_hooks_path"; then
  hooks_path_scope=$(git -C "$REPO" config --show-scope --get core.hooksPath 2>/dev/null | cut -f1) || hooks_path_scope=""
  echo "⚠️  core.hooksPath уже задан: «${current_hooks_path}»${hooks_path_scope:+ (${hooks_path_scope})} — оставляю как есть, не заменяю (#1688)."
  echo "   Платформенные проверки из $HOOK_DIR в этом репозитории НЕ активны:"
  echo "   pre-commit (в том числе закрытие РП с неразобранными входящими) и pre-push (защита от force-push)."
  echo "   Включить их вместо своих хуков: git -C \"$REPO\" config --local core.hooksPath .githooks"
  echo "   Либо вызывайте .githooks/pre-commit и .githooks/pre-push из своих хуков."
  if gap_file=$(secret_scan_gap "$current_hooks_path"); then
    warn_secret_scan_gap "$gap_file"
  fi
  exit 0
fi

git -C "$REPO" config --local core.hooksPath .githooks

MISSING=""
for hook in pre-commit pre-push; do
  [ -x "$HOOK_DIR/$hook" ] || MISSING="$MISSING $hook"
done

if [ -n "$MISSING" ]; then
  echo "⚠️  core.hooksPath = .githooks, но отсутствуют или не исполняются:$MISSING"
  echo "   Хуки НЕ активны, пока эти файлы не появятся в $HOOK_DIR."
  exit 1
fi

echo "✅ Hooks wired: $HOOK_DIR"
echo "   core.hooksPath = $(git -C "$REPO" config core.hooksPath)"

if gap_file=$(secret_scan_gap "$(git -C "$REPO" config core.hooksPath)"); then
  warn_secret_scan_gap "$gap_file"
fi
