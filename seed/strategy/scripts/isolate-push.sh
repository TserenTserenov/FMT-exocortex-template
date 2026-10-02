#!/usr/bin/env bash
# routing: helper  called-by=session-guard.sh(close)  deterministic=true
# see WP-484 Ф102, DRR-f102-isolated-push-cherry-pick.md — pushes an isolated
# session worktree's own commits to origin/<target-branch>.
#
# Isolated worktrees (WP-520 freeze) drift from origin/<target-branch> by
# however much other parallel sessions push while this session is open — one
# incident saw 10+ commits land in ~20 minutes. `merge` would pull every one
# of those foreign files into the staged diff, and the Scope gate (the guard
# that stops an agent from committing someone else's uncommitted work) can't
# tell them apart from a real cross-contamination without weakening itself.
# `rebase` avoids that but its conflict odds rise with the number of
# concurrent sessions (routinely 8+ live `claude-code` semaphores today) and
# it gives close() no clean signal to stop on. `cherry-pick` sidesteps both:
# the size of the transfer depends only on this session's own commits, and a
# conflict lands on the well-known `CHERRY_PICK_HEAD` marker instead of an
# ambiguous rebase state.
#
# Design consensus: peer-session 2026-08-16-08-wp484-isolate-push-cherry-pick
# (Claude + Codex, 2 turns to CONSENSUS). Codex's turn 1 caught a real
# self-contradiction in the initial draft (detached-HEAD-in-place can't both
# "roll back everything" and "leave CHERRY_PICK_HEAD for inspection" at once)
# and proposed the disposable-temp-worktree split adopted here: the session's
# own isolated worktree is never touched by this script, success or failure.
#
# Usage:
#   isolate-push.sh <isolate-worktree-path> <target-branch>
#   isolate-push.sh --cleanup-retry-conflict <conflict-worktree-path> <control-worktree> <expected-commits-csv> <target-branch>
#   isolate-push.sh --release-retry-conflict <conflict-worktree-path> <control-worktree> <expected-commits-csv> <target-branch>
#   isolate-push.sh --conflict-state-hash <conflict-worktree-path>
# Exit codes:
#   0 = pushed (possibly after 1+ retries)
#   1 = usage/precondition error (bad args, not a worktree, dirty source,
#       repo error) — printed to stderr
#   2 = unsupported history: a merge commit exists in the range being
#       transferred (base..isolate-branch) — this script only carries a
#       linear commit series; the offending SHAs are listed on stderr
#   3 = cherry-pick conflict — the disposable temp worktree is preserved
#       with CHERRY_PICK_HEAD set, its path printed on stdout, for manual
#       `git cherry-pick --continue|--abort`. The source isolate worktree is
#       untouched either way.

set -uo pipefail

# WP-485 Ф14: no silent personal governance-repo default anywhere in this script.
: "${IWE_GOVERNANCE_REPO:?isolate-push: IWE_GOVERNANCE_REPO is required, no silent default}"

MAX_RETRIES=3

retry_cleanup_state() {
  python3 - "$@" <<'PYEOF'
import fcntl
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import time


def fail(message, code=1):
    print("isolate-push: " + message, file=sys.stderr)
    raise SystemExit(code)


def git_output(worktree, *args):
    result = subprocess.run(
        ["git", "-C", worktree, *args],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", "replace").strip()
        raise RuntimeError(detail or "git " + " ".join(args) + " failed")
    return result.stdout


def feed(digest, label, payload):
    digest.update(label.encode("ascii") + b"\0")
    digest.update(len(payload).to_bytes(8, "big"))
    digest.update(payload)


def feed_filesystem_tree(digest, label, base_path):
    for root, directories, files in os.walk(base_path, topdown=True, followlinks=False):
        directories.sort(key=os.fsencode)
        files.sort(key=os.fsencode)
        for name in directories + files:
            full_path = os.path.join(root, name)
            relative_path = os.path.relpath(full_path, base_path)
            info = os.lstat(full_path)
            feed(digest, label + "-path", os.fsencode(relative_path))
            feed(digest, label + "-mode", str(info.st_mode).encode("ascii"))
            if stat.S_ISLNK(info.st_mode):
                feed(digest, label + "-link", os.fsencode(os.readlink(full_path)))
            elif stat.S_ISREG(info.st_mode):
                with open(full_path, "rb") as source:
                    feed(digest, label + "-content", source.read())
            elif not stat.S_ISDIR(info.st_mode):
                feed(digest, label + "-special", b"")


def worktree_state_hash(worktree):
    digest = hashlib.sha256()
    commands = (
        ("head", ("rev-parse", "--verify", "HEAD^{commit}")),
        ("cherry-pick-head", ("rev-parse", "--verify", "CHERRY_PICK_HEAD")),
        ("status", ("status", "--porcelain=v2", "-z", "--untracked-files=all", "--ignored=matching")),
        ("worktree-diff", ("diff", "--binary", "--no-ext-diff", "--")),
        ("index-diff", ("diff", "--cached", "--binary", "--no-ext-diff", "--")),
    )
    for label, args in commands:
        feed(digest, label, git_output(worktree, *args))

    index_name = os.fsdecode(git_output(worktree, "rev-parse", "--git-path", "index").strip())
    index_path = index_name if os.path.isabs(index_name) else os.path.join(worktree, index_name)
    with open(index_path, "rb") as source:
        feed(digest, "index", source.read())

    # Conflict progress also lives outside the checkout: MERGE_MSG,
    # AUTO_MERGE, sequencer/, rebase-* and similar files are stored in this
    # linked worktree's private gitdir. Hash the whole private tree (including
    # locks/logs, conservatively) so changing only that state cannot be erased
    # by an automatic `worktree remove --force`.
    git_dir_name = os.fsdecode(git_output(worktree, "rev-parse", "--git-dir").strip())
    git_dir_path = git_dir_name if os.path.isabs(git_dir_name) else os.path.join(worktree, git_dir_name)
    git_dir_path = os.path.realpath(git_dir_path)
    if git_dir_path == physical_git_common_dir(worktree):
        raise RuntimeError("conflict-state-hash требует отдельный linked worktree")
    feed_filesystem_tree(digest, "worktree-gitdir", git_dir_path)

    # `git diff` and ordinary status deliberately omit ignored files. They
    # still matter here: a human may put recovery notes or generated output
    # under an ignore rule, and `worktree remove --force` would destroy them.
    # Hash both ordinary untracked and ignored-untracked content so any such
    # write after the passport snapshot blocks automatic cleanup.
    untracked = git_output(worktree, "ls-files", "--others", "--exclude-standard", "-z")
    ignored = git_output(
        worktree, "ls-files", "--others", "--ignored", "--exclude-standard", "-z"
    )
    extra_paths = {
        path
        for listing in (untracked, ignored)
        for path in listing.split(b"\0")
        if path
    }
    for raw_path in sorted(extra_paths):
        relative_path = os.fsdecode(raw_path)
        full_path = os.path.join(worktree, relative_path)
        info = os.lstat(full_path)
        feed(digest, "untracked-path", raw_path)
        feed(digest, "untracked-mode", str(info.st_mode).encode("ascii"))
        if stat.S_ISLNK(info.st_mode):
            feed(digest, "untracked-link", os.fsencode(os.readlink(full_path)))
        elif stat.S_ISREG(info.st_mode):
            with open(full_path, "rb") as source:
                feed(digest, "untracked-content", source.read())
        elif stat.S_ISDIR(info.st_mode):
            # Git may collapse a wholly ignored directory (including an
            # embedded repository) to one `path/` entry. Walk it ourselves;
            # otherwise changing a descendant after the snapshot is invisible.
            feed_filesystem_tree(digest, "untracked-tree", full_path)
        else:
            feed(digest, "untracked-special", b"")
    return digest.hexdigest()


def physical_git_common_dir(worktree):
    value = os.fsdecode(git_output(worktree, "rev-parse", "--git-common-dir").strip())
    if not os.path.isabs(value):
        value = os.path.join(worktree, value)
    return os.path.realpath(value)


def atomic_write(path, record):
    temp_path = path + ".tmp.%d" % os.getpid()
    try:
        with open(temp_path, "w", encoding="utf-8") as target:
            json.dump(record, target, indent=2)
        os.replace(temp_path, path)
    finally:
        try:
            os.unlink(temp_path)
        except FileNotFoundError:
            pass


operation = sys.argv[1]
if operation == "hash":
    if len(sys.argv) != 3:
        fail("внутренняя ошибка аргументов conflict-state-hash")
    try:
        print(worktree_state_hash(sys.argv[2]))
    except (OSError, RuntimeError) as error:
        fail("не удалось снять снимок конфликтного worktree: %s" % error)
    raise SystemExit(0)

if operation not in {"cleanup", "release"} or len(sys.argv) != 8:
    fail("внутренняя ошибка аргументов retry cleanup")

requested_path, control_worktree, expected_commits_csv, target_branch, home, cleanup_token = sys.argv[2:8]
if not re.fullmatch(r"[0-9a-f]{32}", cleanup_token):
    fail("retry cleanup token отсутствует или повреждён")
expected_commits = expected_commits_csv.split(",")
if not expected_commits or any(
    not re.fullmatch(r"[0-9a-fA-F]{40,64}", commit)
    for commit in expected_commits
):
    fail("ожидаемый список commits для retry cleanup повреждён")

physical_path = os.path.realpath(requested_path)
attempt_id = os.path.basename(physical_path)
if not re.fullmatch(r"attempt-[0-9]+-[0-9]+-[0-9a-fA-F]{8}", attempt_id):
    fail("неверный attempt id для retry cleanup")

temp_store = os.path.dirname(physical_path)
source_parent = os.path.dirname(temp_store)
expected_source = os.path.join(source_parent, "worktree")
if os.path.basename(source_parent) == "isolated-worktrees":
    registry = os.path.join(os.path.dirname(source_parent), "isolate-push-attempts")
else:
    registry = os.path.join(home, "IWE", ".iwe-runtime", "isolate-push-attempts")

record_path = os.path.join(registry, attempt_id + ".json")
lock_path = os.path.join(registry, ".registry.lock")
if not os.path.isdir(registry) or not os.path.isfile(record_path) or os.path.islink(record_path):
    fail("паспорт retry cleanup не найден или небезопасен")

with open(lock_path, "w", encoding="utf-8") as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    try:
        with open(record_path, encoding="utf-8") as source:
            record = json.load(source)
    except (OSError, ValueError):
        fail("паспорт retry cleanup повреждён")

    if record.get("owner") != "isolate-push":
        fail("паспорт retry cleanup имеет чужого владельца")
    if record.get("attempt_id") != attempt_id:
        fail("attempt id паспорта не совпадает с путём")
    stored_path = record.get("worktree_path")
    if not isinstance(stored_path, str) or os.path.realpath(stored_path) != physical_path:
        fail("путь паспорта retry cleanup не совпадает")
    source_worktree = record.get("source_worktree")
    if not isinstance(source_worktree, str) or os.path.realpath(source_worktree) != os.path.realpath(expected_source):
        fail("source_worktree паспорта не совпадает с владельцем вызова")
    if record.get("target_branch") != target_branch:
        fail("target_branch паспорта не совпадает")
    if record.get("source_commits") != expected_commits:
        fail("source_commits паспорта не совпадает")
    status_value = record.get("status")
    handoff_id = hashlib.sha256(cleanup_token.encode("ascii")).hexdigest()
    if operation == "release":
        if (
            status_value == "needs-manual-resolve"
            and record.get("manual_handoff_id") == handoff_id
        ):
            # Crash-safe idempotence: the owner may have been interrupted
            # after the atomic handoff but before its shell cleared the active
            # flag. Repeating the same token is a byte no-op.
            try:
                control_common = physical_git_common_dir(control_worktree)
                target_common = physical_git_common_dir(physical_path)
                listed = git_output(
                    control_worktree, "worktree", "list", "--porcelain"
                ).decode("utf-8", "surrogateescape")
            except (OSError, RuntimeError) as error:
                fail("не удалось подтвердить завершённый handoff: %s" % error)
            if control_common != target_common or not any(
                line.startswith("worktree ")
                and os.path.realpath(line[9:]) == physical_path
                for line in listed.splitlines()
            ):
                fail("завершённый handoff больше не указывает на живой worktree")
            raise SystemExit(0)
        if record.get("retry_cleanup_token") != cleanup_token:
            fail("retry cleanup token паспорта не совпадает")
        if status_value not in {
            "retry-pending-classification",
            "needs-manual-resolve",
            "retry-cleanup-in-progress",
        }:
            fail("паспорт не ожидает классификации retry-wrapper")
        if (
            status_value == "retry-cleanup-in-progress"
            and record.get("retry_cleanup_claim") != cleanup_token
        ):
            fail("transient cleanup захвачен другим владельцем")
        if not os.path.isdir(physical_path):
            fail("конфликтный worktree уже отсутствует")
        try:
            control_common = physical_git_common_dir(control_worktree)
            target_common = physical_git_common_dir(physical_path)
            if control_common != target_common:
                fail("control worktree принадлежит другому git-репозиторию")
            listed = git_output(
                control_worktree, "worktree", "list", "--porcelain"
            ).decode("utf-8", "surrogateescape")
            registered = any(
                line.startswith("worktree ")
                and os.path.realpath(line[9:]) == physical_path
                for line in listed.splitlines()
            )
            if not registered:
                fail("конфликтный путь не зарегистрирован как worktree")
        except (OSError, RuntimeError) as error:
            fail("не удалось передать конфликт ручному resume: %s" % error)
        # Handoff is non-destructive. Drift since the original snapshot is
        # therefore a reason to preserve the copy, not to reject the handoff.
        # A fresh hash is useful for audit but is not an availability gate:
        # manual work may already have removed CHERRY_PICK_HEAD.
        try:
            fresh_hash = worktree_state_hash(physical_path)
        except (OSError, RuntimeError):
            fresh_hash = None
        record["status"] = "needs-manual-resolve"
        if fresh_hash is None:
            record.pop("conflict_state_hash", None)
        else:
            record["conflict_state_hash"] = fresh_hash
        record["manual_handoff_id"] = handoff_id
        record["manual_handoff_at"] = time.strftime(
            "%Y-%m-%dT%H:%M:%SZ", time.gmtime()
        )
        record["updated_at"] = record["manual_handoff_at"]
        record.pop("retry_cleanup_token", None)
        record.pop("retry_cleanup_claim", None)
        record.pop("retry_cleanup_git_common_dir", None)
        atomic_write(record_path, record)
        raise SystemExit(0)

    if record.get("retry_cleanup_token") != cleanup_token:
        fail("retry cleanup token паспорта не совпадает")
    expected_hash = record.get("conflict_state_hash")
    if not isinstance(expected_hash, str) or not re.fullmatch(r"[0-9a-f]{64}", expected_hash):
        fail("в паспорте нет проверяемого снимка конфликтного состояния")

    if status_value == "removed-retry":
        if os.path.exists(physical_path):
            fail("removed-retry указывает на существующий worktree")
        try:
            if physical_git_common_dir(control_worktree) != record.get("retry_cleanup_git_common_dir"):
                fail("control worktree не совпадает с репозиторием завершённого cleanup")
            listed = git_output(control_worktree, "worktree", "list", "--porcelain").decode(
                "utf-8", "surrogateescape"
            )
        except (OSError, RuntimeError) as error:
            fail("не удалось проверить терминальный cleanup: %s" % error)
        if any(
            line.startswith("worktree ") and os.path.realpath(line[9:]) == physical_path
            for line in listed.splitlines()
        ):
            fail("removed-retry всё ещё зарегистрирован как worktree")
        raise SystemExit(0)

    if status_value == "retry-cleanup-in-progress":
        if record.get("retry_cleanup_claim") != cleanup_token:
            fail("retry cleanup уже захвачен другим владельцем")
        expected_common = record.get("retry_cleanup_git_common_dir")
        try:
            if not isinstance(expected_common, str) or physical_git_common_dir(control_worktree) != expected_common:
                fail("control worktree не совпадает с репозиторием незавершённого cleanup")
            listed = git_output(control_worktree, "worktree", "list", "--porcelain").decode("utf-8", "surrogateescape")
        except (OSError, RuntimeError) as error:
            fail("не удалось проверить регистрацию незавершённого cleanup: %s" % error)
        registered = any(
            line.startswith("worktree ") and os.path.realpath(line[9:]) == physical_path
            for line in listed.splitlines()
        )
        if not os.path.exists(physical_path):
            if registered:
                fail("путь исчез, но всё ещё зарегистрирован; паспорт сохранён transient")
            record["status"] = "removed-retry"
            record["updated_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
            record.pop("retry_cleanup_claim", None)
            atomic_write(record_path, record)
            raise SystemExit(0)
        try:
            if not registered or physical_git_common_dir(physical_path) != expected_common:
                fail("существующий путь незавершённого cleanup повреждён или снят с регистрации")
            if worktree_state_hash(physical_path) != expected_hash:
                fail("существующий worktree изменён после claim; паспорт сохранён transient")
        except (OSError, RuntimeError) as error:
            fail("не удалось проверить сохранившийся worktree cleanup: %s" % error)
        record["status"] = "retry-pending-classification"
        record["updated_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        record.pop("retry_cleanup_claim", None)
        atomic_write(record_path, record)
        fail("восстановлен прерванный cleanup до удаления; worktree сохранён")

    if status_value != "retry-pending-classification":
        fail("паспорт не ожидает классификации retry-wrapper")
    if not os.path.isdir(physical_path):
        fail("конфликтный worktree уже отсутствует")

    try:
        control_common = physical_git_common_dir(control_worktree)
        target_common = physical_git_common_dir(physical_path)
        if control_common != target_common:
            fail("control worktree принадлежит другому git-репозиторию")
        listed = git_output(control_worktree, "worktree", "list", "--porcelain").decode("utf-8", "surrogateescape")
        registered = any(
            line.startswith("worktree ") and os.path.realpath(line[9:]) == physical_path
            for line in listed.splitlines()
        )
        if not registered:
            fail("конфликтный путь не зарегистрирован как worktree")
        if worktree_state_hash(physical_path) != expected_hash:
            fail("конфликтный worktree изменён после выдачи; автоматическая очистка запрещена")
    except (OSError, RuntimeError) as error:
        fail("не удалось провалидировать retry cleanup: %s" % error)

    record["status"] = "retry-cleanup-in-progress"
    record["retry_cleanup_claim"] = cleanup_token
    record["retry_cleanup_git_common_dir"] = control_common
    record["updated_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    atomic_write(record_path, record)

    if os.environ.get("ISOLATE_PUSH_TEST_STOP_AFTER_RETRY_CLAIM") == "1":
        fail("тестовая остановка после claim")

    removal = subprocess.run(
        ["git", "-C", control_worktree, "worktree", "remove", physical_path, "--force"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
        # Keep the same open-file-description flock alive if this Python
        # owner is killed while Git is still removing the worktree. Without
        # inheritance, resume/release could publish a path that the orphaned
        # Git child then deletes.
        pass_fds=(lock.fileno(),),
    )
    if removal.returncode != 0:
        if os.path.isdir(physical_path):
            try:
                listed_after = git_output(control_worktree, "worktree", "list", "--porcelain").decode("utf-8", "surrogateescape")
                registered_after = any(
                    line.startswith("worktree ") and os.path.realpath(line[9:]) == physical_path
                    for line in listed_after.splitlines()
                )
                intact = (
                    registered_after
                    and physical_git_common_dir(physical_path) == control_common
                    and worktree_state_hash(physical_path) == expected_hash
                )
            except (OSError, RuntimeError):
                intact = False
            if intact:
                record["status"] = "retry-pending-classification"
                record.pop("retry_cleanup_claim", None)
                record["updated_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
                atomic_write(record_path, record)
        detail = removal.stderr.decode("utf-8", "replace").strip()
        fail("не удалось удалить промежуточный worktree; retry остановлен: %s" % detail)

    if os.path.exists(physical_path):
        fail("git сообщил успех cleanup, но путь worktree остался; паспорт сохранён transient")
    try:
        listed_after = git_output(control_worktree, "worktree", "list", "--porcelain").decode(
            "utf-8", "surrogateescape"
        )
    except (OSError, RuntimeError) as error:
        fail("не удалось подтвердить снятие worktree с регистрации; паспорт сохранён transient: %s" % error)
    if any(
        line.startswith("worktree ") and os.path.realpath(line[9:]) == physical_path
        for line in listed_after.splitlines()
    ):
        fail("путь удалён, но worktree остался зарегистрирован; паспорт сохранён transient")
    if os.environ.get("ISOLATE_PUSH_TEST_FAIL_RETRY_FINALIZE") == "1":
        fail("тестовая остановка после удаления до finalize")

    record["status"] = "removed-retry"
    record.pop("retry_cleanup_claim", None)
    record["updated_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    atomic_write(record_path, record)
PYEOF
}

if [ "${1:-}" = "--conflict-state-hash" ]; then
  [ "$#" -eq 2 ] || {
    echo "Использование: isolate-push.sh --conflict-state-hash <conflict-worktree-path>" >&2
    exit 1
  }
  retry_cleanup_state hash "$2"
  exit $?
fi

if [ "${1:-}" = "--cleanup-retry-conflict" ]; then
  [ "$#" -eq 5 ] || {
    echo "Использование: isolate-push.sh --cleanup-retry-conflict <conflict-worktree-path> <control-worktree> <expected-commits-csv> <target-branch>" >&2
    exit 1
  }
  retry_cleanup_state cleanup "$2" "$3" "$4" "$5" "$HOME" "${DS_PUBLISH_RETRY_CLEANUP_TOKEN:-}"
  exit $?
fi

if [ "${1:-}" = "--release-retry-conflict" ]; then
  [ "$#" -eq 5 ] || {
    echo "Использование: isolate-push.sh --release-retry-conflict <conflict-worktree-path> <control-worktree> <expected-commits-csv> <target-branch>" >&2
    exit 1
  }
  retry_cleanup_state release "$2" "$3" "$4" "$5" "$HOME" "${DS_PUBLISH_RETRY_CLEANUP_TOKEN:-}"
  exit $?
fi

if [ "$#" -ne 2 ] && { [ "$#" -ne 4 ] || [ "$3" != "--exact-commit" ]; }; then
  echo "Использование: isolate-push.sh <isolate-worktree-path> <target-branch> [--exact-commit <sha>]" >&2
  exit 1
fi

SOURCE_WORKTREE="$1"
TARGET_BRANCH="$2"
EXACT_COMMIT="${4:-}"

if [ -z "$TARGET_BRANCH" ]; then
  echo "isolate-push: target-branch не может быть пустым" >&2
  exit 1
fi

git -C "$SOURCE_WORKTREE" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { echo "isolate-push: $SOURCE_WORKTREE — не git worktree" >&2; exit 1; }

# defense in depth: session-guard.sh may check this too for a faster UX
# message, but this script must not be the only thing standing between a
# partially-committed session and a push that silently drops the rest.
if [ -n "$(git -C "$SOURCE_WORKTREE" status --porcelain 2>/dev/null)" ]; then
  echo "isolate-push: $SOURCE_WORKTREE есть незакоммиченные изменения — закоммить или почисти перед push" >&2
  exit 1
fi

SOURCE_BRANCH=$(git -C "$SOURCE_WORKTREE" rev-parse --abbrev-ref HEAD 2>/dev/null)

# WP-530 Ф38 (peer-session 2026-09-11-07, Claude+Kimi+Codex): the canonical
# checkout this worktree was forked from still points at its own commits, which
# now live on origin under new SHAs (cherry-pick republish). Nothing else moves
# that ref, so the canon diverges further with every publish (74/230 on 11.09).
# canon-reconcile-published.sh replaces the ref only when every dropped commit is
# provably on origin, no live writer is inside the canon and nothing on disk
# would be overwritten; it fails closed otherwise. Best-effort: its result never
# changes this script's exit code, and a missing script is a plain no-op.
# Defined here, before the resume branch below, which is the first caller.
post_publish_reconcile() {  # <pushed-oid>
  local workspace="${IWE_WORKSPACE:-$HOME/IWE}"
  local gov="${IWE_GOVERNANCE_REPO:?isolate-push: IWE_GOVERNANCE_REPO is required, no silent default}"
  local canon="$workspace/$gov"
  local tool="$workspace/scripts/canon-reconcile-published.sh"
  [ -x "$tool" ] && [ -d "$canon/.git" ] || return 0
  local src_origin canon_origin
  src_origin=$(git -C "$SOURCE_WORKTREE" remote get-url origin 2>/dev/null | sed 's#\.git$##')
  canon_origin=$(git -C "$canon" remote get-url origin 2>/dev/null | sed 's#\.git$##')
  [ -n "$src_origin" ] && [ "$src_origin" = "$canon_origin" ] || return 0
  bash "$tool" "$canon" "$TARGET_BRANCH" "$1" 2>&1 | sed 's/^/isolate-push: /' || true
}
[ -n "$SOURCE_BRANCH" ] && [ "$SOURCE_BRANCH" != "HEAD" ] \
  || { echo "isolate-push: detached HEAD в $SOURCE_WORKTREE, отказ" >&2; exit 1; }

if [ -n "$EXACT_COMMIT" ]; then
  git -C "$SOURCE_WORKTREE" cat-file -e "$EXACT_COMMIT^{commit}" 2>/dev/null \
    || { echo "isolate-push: --exact-commit не является коммитом источника: $EXACT_COMMIT" >&2; exit 1; }
  git -C "$SOURCE_WORKTREE" merge-base --is-ancestor "$EXACT_COMMIT" "$SOURCE_BRANCH" \
    || { echo "isolate-push: --exact-commit не достижим из ветки источника: $EXACT_COMMIT" >&2; exit 1; }
fi

TEMP_STORE_DIR="$(dirname "$SOURCE_WORKTREE")/.isolate-push-tmp"

# F5 (пир-сессия 2026-08-21-02-day-close-anomaly-classes): паспорт попытки —
# во внешнем реестре, НЕ внутри worktree (маркер в checkout делал бы worktree
# dirty и ломал критерий clean для будущего свипера). Статусы: active при
# создании; retry-pending-classification — пока retry-wrapper единолично решает,
# удалять ли конфликт; needs-manual-resolve — после атомарной передачи человеку;
# removed/done — когда worktree убран. Свипер (каталог WP-545)
# вправе трогать только маркированные записи с доказанной достижимостью
# коммитов — само удаление этим фиксом не вводится.
ATTEMPT_REGISTRY=""
if [ "$(basename "$(dirname "$SOURCE_WORKTREE")")" = "isolated-worktrees" ]; then
  ATTEMPT_REGISTRY="$(dirname "$(dirname "$SOURCE_WORKTREE")")/isolate-push-attempts"
else
  ATTEMPT_REGISTRY="${IWE_ROOT:-$HOME/IWE}/.iwe-runtime/isolate-push-attempts"
fi

# review-01 High-7: attempt-<n>-$$ переиспользуется после реюза PID — добавляем
# uuid-суффикс, а начальную запись создаём exclusive (не перезаписать чужую).
ATTEMPT_UUID=$(uuidgen 2>/dev/null | cut -c1-8 || true)
if [ -z "$ATTEMPT_UUID" ]; then
  ATTEMPT_UUID=$(python3 -c "import secrets; print(secrets.token_hex(4))" 2>/dev/null || true)
fi
if [ -z "$ATTEMPT_UUID" ]; then
  echo "isolate-push: ни uuidgen, ни python3 secrets недоступны — без случайного attempt id не работаем (fail closed)" >&2
  exit 1
fi

attempt_marker() {
  # $1=attempt_id $2=status $3=worktree_path $4=commits(через пробел)
  # [$5=create_only] [$6=retry_cleanup_token] [$7=conflict_state_hash]
  # review-01 High-6: запись под lock реестра, через temp+rename; сбой НАЧАЛЬНОЙ
  # записи (create_only=1) — не WARN, а отказ (паспорт обязателен до работы).
  [ -d "$ATTEMPT_REGISTRY" ] || mkdir -p "$ATTEMPT_REGISTRY" 2>/dev/null
  python3 - "$ATTEMPT_REGISTRY" "$1" "$2" "$3" "$4" "$SOURCE_WORKTREE" "${5:-0}" "$TARGET_BRANCH" "${6:-}" "${7:-}" <<'PYEOF'
import json, sys, time, os, fcntl
registry, attempt_id, status, wt_path, commits, source_wt, create_only, target_branch, cleanup_token, conflict_hash = sys.argv[1:11]
os.makedirs(registry, exist_ok=True)
lock_path = os.path.join(registry, ".registry.lock")
path = os.path.join(registry, attempt_id + ".json")
with open(lock_path, "w") as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    try:
        if os.path.exists(path):
            if create_only == "1":
                print(f"attempt_marker: запись {attempt_id} уже существует — отказ перезаписи", file=sys.stderr)
                sys.exit(1)
            try:
                rec = json.load(open(path))
            except Exception:
                rec = {}
        else:
            rec = {}
        # Cold review 2026-08-30 Critical-2: проигравший гонку resume не должен
        # затирать done обратно в needs-manual-resolve по несуществующему worktree.
        if str(rec.get("status", "")).startswith("done") and status == "needs-manual-resolve":
            print(f"attempt_marker: {attempt_id} уже {rec['status']} — даунгрейд в needs-manual-resolve запрещён", file=sys.stderr)
            sys.exit(0)
        if rec.get("status") == "retry-cleanup-in-progress" and status != "retry-cleanup-in-progress":
            print(f"attempt_marker: {attempt_id} захвачен retry cleanup — внешняя перезапись запрещена", file=sys.stderr)
            sys.exit(1)
        rec.update({
            "attempt_id": attempt_id,
            "target_branch": target_branch,
            "owner": "isolate-push",
            "run_id": "%d-%d" % (int(time.time()), os.getpid()),
            "worktree_path": wt_path,
            "source_worktree": source_wt,
            "source_commits": commits.split(),
            "status": status,
            "updated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        })
        if cleanup_token:
            rec["retry_cleanup_token"] = cleanup_token
        if conflict_hash:
            rec["conflict_state_hash"] = conflict_hash
        rec.setdefault("created_at", rec["updated_at"])
        tmp = path + ".tmp.%d" % os.getpid()
        json.dump(rec, open(tmp, "w"), indent=2)
        os.rename(tmp, path)
    finally:
        fcntl.flock(lock, fcntl.LOCK_UN)
PYEOF
}

patch_equivalent_to_head() {  # <commit> -- true only for a non-empty patch already represented by HEAD
  local commit="$1" parent source_patch_id cherry_line

  # Empty source commits have no patch-id, so their empty cherry-pick is not
  # evidence of publication. Keep those (and every read error) on the manual
  # path instead of silently skipping them.
  parent=$(git -C "$SOURCE_WORKTREE" rev-parse "$commit^" 2>/dev/null) || return 1
  source_patch_id=$(
    git -C "$SOURCE_WORKTREE" show --pretty=format:'commit %H' --no-ext-diff --binary "$commit" 2>/dev/null \
      | git -C "$SOURCE_WORKTREE" patch-id --stable 2>/dev/null \
      | awk 'NR == 1 { print $1 }'
  )
  [ -n "$source_patch_id" ] || return 1

  # `git cherry` compares stable patch-ids. The explicit parent limit makes
  # the verdict about this one commit only, even when its source branch also
  # contains unrelated unpublished history.
  cherry_line=$(git -C "$TEMP_WORKTREE" cherry HEAD "$commit" "$parent" 2>/dev/null) || return 1
  [ "$cherry_line" = "- $commit" ]
}

# WP-530 Ф29/Ф30: `patch_equivalent_to_head` compares the patch-id of the
# WHOLE commit. If the same file with the same content lands on origin as
# part of a DIFFERENT commit (e.g. a batch publisher bundling several queue
# files into one commit), the whole-commit patch-id never matches even
# though every touched file is byte-identical to HEAD -- the cherry-pick
# falls into the manual-conflict path and the temp worktree is orphaned.
# Reproduced live 2026-09-07 (commit 4d197df33, WP-530). This is a fallback,
# tried only after patch_equivalent_to_head fails -- it does not change
# behavior for a real conflict.
# Design: peer-session 2026-09-07-08-fix-isolate-push-patch-equiv (Claude +
# Kimi + Codex, 5 rounds to CONSENSUS). Codex caught 5 real correctness gaps
# across the rounds: file mode ignored (100644 vs 100755 with identical blob
# read as equivalent), diff-tree's exit status lost inside process
# substitution, type-change status "T" excluded from the mode+oid check
# where it belongs, a literal filename containing pathspec magic characters
# (e.g. "a*") glob-matched by `ls-tree -- "$path"` instead of looked up
# exactly, and unresolved-HEAD errors indistinguishable from "path already
# deleted" in the deletion branch.
content_equivalent_to_head() {  # <commit> -- true only if every file the commit touches already matches HEAD's mode+content exactly
  local commit="$1" head_commit raw_diff_file meta path new_mode new_oid status head_line head_mode head_oid rc

  # Snapshot the commit object HEAD points at ONCE -- every later lookup uses
  # this fixed SHA, not the symbolic "HEAD", so a ref update mid-function
  # (even if nothing in this call path currently causes one) cannot make the
  # function compare paths from two different commits and return a false 0.
  head_commit=$(git -C "$TEMP_WORKTREE" rev-parse --verify -q 'HEAD^{commit}') || return 1

  raw_diff_file=$(mktemp) || return 1
  # RETURN trap, not a repeated `rm -f` at each of the 7 exit points below --
  # one cleanup path is easier to verify complete than seven kept in sync.
  # Single-quoted: $raw_diff_file expands when the trap FIRES (still in this
  # function's local scope), not when it's set -- early expansion (double
  # quotes) would splice the mktemp path's literal value into the trap
  # command string, breaking on a path containing a single quote.
  trap 'rm -f "$raw_diff_file"' RETURN

  git -C "$SOURCE_WORKTREE" diff-tree --no-commit-id --raw -z -r --no-renames "$commit" \
    > "$raw_diff_file" 2>/dev/null
  rc=$?
  # Captured into a file (not read under process substitution) so $? reflects
  # diff-tree itself, not a subshell -- a partial/failed listing must not be
  # silently treated as a short, fully-checked one. -z (NUL-delimited) avoids
  # the tab/newline-in-filename ambiguity of the default --name-status form.
  [ "$rc" -eq 0 ] && [ -s "$raw_diff_file" ] || return 1

  # -z: each changed file is two NUL-terminated records back to back --
  # ":old_mode new_mode old_oid new_oid status"<NUL>"path"<NUL>. NUL cannot
  # appear in a valid path, so this is safe regardless of tabs/newlines in
  # filenames.
  while IFS= read -r -d '' meta && IFS= read -r -d '' path; do
    new_mode=$(awk '{print $2}' <<<"$meta")
    new_oid=$(awk '{print $4}' <<<"$meta")
    status=$(awk '{print $5}' <<<"$meta" | cut -c1)

    case "$status" in
      D)
        # ls-tree, not `cat-file -e $head_commit:$path`: a nonzero exit here
        # means "could not read the tree" (fail closed), a different fact
        # from "empty output, rc 0" (path genuinely absent, already deleted
        # upstream) -- cat-file -e could not tell those apart.
        head_line=$(git -C "$TEMP_WORKTREE" --literal-pathspecs ls-tree "$head_commit" -- "$path" 2>/dev/null)
        rc=$?
        [ "$rc" -eq 0 ] || return 1
        [ -z "$head_line" ] || return 1
        ;;
      A|M|T)
        # --literal-pathspecs: without it, a literal filename containing
        # pathspec magic characters (e.g. "a*") would be glob-matched by
        # `ls-tree -- "$path"` against unrelated files instead of looked up
        # exactly -- a real false-positive path, not a theoretical one.
        # T (type change, e.g. regular file -> symlink) carries the same
        # mode+oid shape as A|M in --raw output -- same comparison applies.
        head_line=$(git -C "$TEMP_WORKTREE" --literal-pathspecs ls-tree "$head_commit" -- "$path" 2>/dev/null)
        [ -n "$head_line" ] || return 1
        head_mode=$(awk '{print $1}' <<<"$head_line")
        head_oid=$(awk '{print $3}' <<<"$head_line")
        [ "$new_mode" = "$head_mode" ] && [ "$new_oid" = "$head_oid" ] || return 1
        ;;
      *)
        # Type change already handled above; anything else (copy, unmerged,
        # unknown) stays on the manual path.
        return 1
        ;;
    esac
  done < "$raw_diff_file"

  return 0
}

# --- Резюмируемость (WP-484 Ф132/Ф133 ← WP-530, пир-сессия 2026-08-30-01) ---
# Раньше повторный запуск после конфликта всегда переигрывал перенос с нуля в
# НОВОМ worktree — ручное разрешение конфликта в сохранённой копии молча
# терялось (живой инцидент 24.08: разрешение потеряно, финальный коммит
# восстанавливали вручную по SHA). Теперь запуск сначала ищет в реестре
# попыток свежую needs-manual-resolve запись этого же источника с тем же
# набором коммитов и ПРОДОЛЖАЕТ из её worktree вместо replay: push-отказ не
# откатывает разрешение, а оставляет его в pending-состоянии (контракт
# prepared/pending_publish из консенсуса пир-сессии).
# Строгий ключ операции (Codex, раунд 3, блокер 1): паспорт подбирается только
# при ПОЛНОМ совпадении {источник, целевая ветка, точный упорядоченный список
# коммитов текущего вызова} -- иначе resume мог подхватить worktree другого
# диапазона/ветки и запушить его, минуя merge-guard и patch-equivalent логику.
# Список текущего вызова считается той же формулой, что в основном цикле.
if ! git -C "$SOURCE_WORKTREE" fetch origin "$TARGET_BRANCH" --quiet 2>&1; then
  echo "isolate-push: git fetch origin $TARGET_BRANCH не прошёл" >&2
  exit 1
fi
RESUME_BASE=$(git -C "$SOURCE_WORKTREE" merge-base "$SOURCE_BRANCH" "origin/$TARGET_BRANCH" 2>/dev/null)
if [ -n "$EXACT_COMMIT" ]; then
  RESUME_KEY_COMMITS="$EXACT_COMMIT"
elif [ -n "$RESUME_BASE" ]; then
  RESUME_KEY_COMMITS=$(git -C "$SOURCE_WORKTREE" rev-list --reverse "$RESUME_BASE..$SOURCE_BRANCH")
else
  RESUME_KEY_COMMITS=""
fi
RESUME_INFO=""
if [ -n "$RESUME_KEY_COMMITS" ]; then
  # Выбор и захват паспорта -- атомарно под замком реестра (cold review
  # 2026-08-30 Critical-2): два одновременных вызова иначе подбирают одну
  # запись, победитель удаляет worktree, проигравший портит паспорт. Захват =
  # переход needs-manual-resolve → resume-in-progress; проигравший просто не
  # находит кандидата и идёт обычным replay-путём. Застрявший
  # resume-in-progress (упавший процесс) лечится вручную -- см.
  # docs/isolate-push-states.md.
  RESUME_INFO=$(python3 - "$ATTEMPT_REGISTRY" "$SOURCE_WORKTREE" "$TARGET_BRANCH" "$RESUME_KEY_COMMITS" <<'PYEOF'
import fcntl, glob, hashlib, json, os, sys, time
registry, source_wt, target_branch, key_commits = sys.argv[1:5]
key = key_commits.split()
lock_path = os.path.join(registry, ".registry.lock")
os.makedirs(registry, exist_ok=True)
with open(lock_path, "w") as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    best = best_path = None
    for path in glob.glob(os.path.join(registry, "*.json")):
        try:
            rec = json.load(open(path))
        except Exception:
            continue
        if rec.get("status") not in {
            "needs-manual-resolve",
            "retry-pending-classification",
        }:
            continue
        if rec.get("source_worktree") != source_wt:
            continue
        # Старые паспорта без target_branch ключом не считаются -- нет resume.
        if rec.get("target_branch") != target_branch:
            continue
        if rec.get("source_commits") != key:
            continue
        if not os.path.isdir(rec.get("worktree_path", "")):
            continue
        if best is None or rec.get("updated_at", "") > best.get("updated_at", ""):
            best, best_path = rec, path
    if best:
        cleanup_token = best.pop("retry_cleanup_token", None)
        if cleanup_token:
            # Manual resume and retry cleanup use the same registry lock.
            # Whichever transition wins owns the worktree before any path is
            # printed. Removing the destructive token here makes a later
            # cleanup fail closed.
            best["manual_handoff_id"] = hashlib.sha256(
                cleanup_token.encode("ascii")
            ).hexdigest()
            best["manual_handoff_at"] = time.strftime(
                "%Y-%m-%dT%H:%M:%SZ", time.gmtime()
            )
        best.pop("retry_cleanup_claim", None)
        best.pop("retry_cleanup_git_common_dir", None)
        best["status"] = "resume-in-progress"
        best["updated_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        tmp = best_path + ".tmp.%d" % os.getpid()
        json.dump(best, open(tmp, "w"), indent=2)
        os.rename(tmp, best_path)
        print(best["attempt_id"])
        print(best["worktree_path"])
        print(" ".join(best.get("source_commits", [])))
    fcntl.flock(lock, fcntl.LOCK_UN)
PYEOF
)
fi
if [ -n "$RESUME_INFO" ]; then
  RESUME_ID=$(sed -n 1p <<<"$RESUME_INFO")
  RESUME_WT=$(sed -n 2p <<<"$RESUME_INFO")
  RESUME_COMMITS=$(sed -n 3p <<<"$RESUME_INFO")
  echo "isolate-push: найдена сохранённая попытка с ручным разбором ($RESUME_ID) — продолжаю из неё, не с нуля"

  # На каждом «заверши руками и повтори» возвращаем паспорт в
  # needs-manual-resolve -- захват (resume-in-progress) иначе спрячет запись
  # от следующего вызова.
  if git -C "$RESUME_WT" rev-parse CHERRY_PICK_HEAD >/dev/null 2>&1; then
    attempt_marker "$RESUME_ID" "needs-manual-resolve" "$RESUME_WT" "$RESUME_COMMITS" || true
    echo "isolate-push: разрешение конфликта в $RESUME_WT не завершено." >&2
    echo "  Заверши: git -C $RESUME_WT cherry-pick --continue   (или --abort, чтобы отказаться)" >&2
    echo "  Затем повтори этот же вызов isolate-push — он продолжит из этой копии." >&2
    echo "isolate-push: manual-resume-conflict=$RESUME_WT"
    echo "$RESUME_WT"
    exit 3
  fi
  # Прерванный rebase проверяется ДО общего теста «дерево грязное» (Codex,
  # раунд 4): иначе он попадал в подсказку про незакоммиченные правки.
  if git -C "$RESUME_WT" rev-parse --verify REBASE_HEAD >/dev/null 2>&1; then
    attempt_marker "$RESUME_ID" "needs-manual-resolve" "$RESUME_WT" "$RESUME_COMMITS" || true
    echo "isolate-push: в $RESUME_WT незавершённый rebase — заверши его и повтори вызов:" >&2
    echo "  git -C $RESUME_WT status   # что конфликтует" >&2
    echo "  git -C $RESUME_WT rebase --continue   (или --abort)" >&2
    echo "isolate-push: manual-resume-conflict=$RESUME_WT"
    echo "$RESUME_WT"
    exit 3
  fi
  if [ -n "$(git -C "$RESUME_WT" status --porcelain 2>/dev/null)" ]; then
    attempt_marker "$RESUME_ID" "needs-manual-resolve" "$RESUME_WT" "$RESUME_COMMITS" || true
    echo "isolate-push: в $RESUME_WT незакоммиченные правки — закоммить (cherry-pick --continue уже прошёл?) и повтори" >&2
    echo "isolate-push: manual-resume-conflict=$RESUME_WT"
    echo "$RESUME_WT"
    exit 3
  fi

  # Помечает done только после проверки, что HEAD реально виден на remote
  # (Codex, раунд 3, критерий приёмки 2: push-код возврата -- не доказательство
  # публикации, "published" требует remote verification).
  finish_resume_publish() {  # $1=контекст для сообщения
    if ! git -C "$RESUME_WT" fetch origin "$TARGET_BRANCH" --quiet 2>&1 \
       || ! git -C "$RESUME_WT" merge-base --is-ancestor HEAD "origin/$TARGET_BRANCH" 2>/dev/null; then
      attempt_marker "$RESUME_ID" "needs-manual-resolve" "$RESUME_WT" "$RESUME_COMMITS" || true
      echo "isolate-push: push сообщил успех, но HEAD не подтверждён на origin/$TARGET_BRANCH — копия сохранена: $RESUME_WT" >&2
      exit 1
    fi
    echo "isolate-push: запушено из сохранённой попытки $RESUME_ID ($1), remote подтверждён"
    post_publish_reconcile "$(git -C "$RESUME_WT" rev-parse HEAD)"
    if git -C "$SOURCE_WORKTREE" worktree remove "$RESUME_WT" --force 2>&1; then
      attempt_marker "$RESUME_ID" "done" "$RESUME_WT" "$RESUME_COMMITS" || echo "isolate-push: WARN паспорт попытки не обновлён (done)" >&2
    else
      attempt_marker "$RESUME_ID" "done-worktree-left" "$RESUME_WT" "$RESUME_COMMITS" || true
      echo "isolate-push: push прошёл, но временный worktree $RESUME_WT не убран — почисти вручную" >&2
    fi
    exit 0
  }

  if git -C "$RESUME_WT" push origin "HEAD:$TARGET_BRANCH" 2>&1; then
    finish_resume_publish "replay не понадобился"
  fi

  # origin уехал, пока конфликт разбирали руками. Одна попытка догнать rebase'ом
  # ВНУТРИ той же копии: разрешение сохраняется; новый конфликт остаётся ЛЕЖАТЬ
  # (без --abort -- Codex, раунд 3, блокер 2: abort стирал то, что тут же
  # предлагалось разобрать) — снова к рукам, НЕ к replay с нуля.
  echo "isolate-push: push из сохранённой попытки отклонён — origin уехал, догоняю rebase'ом в той же копии"
  if git -C "$RESUME_WT" pull --rebase origin "$TARGET_BRANCH" 2>&1 \
     && git -C "$RESUME_WT" push origin "HEAD:$TARGET_BRANCH" 2>&1; then
    finish_resume_publish "после rebase"
  fi
  attempt_marker "$RESUME_ID" "needs-manual-resolve" "$RESUME_WT" "$RESUME_COMMITS" || true
  if git -C "$RESUME_WT" rev-parse --verify REBASE_HEAD >/dev/null 2>&1; then
    echo "isolate-push: rebase-конфликт в сохранённой копии — состояние НЕ отменено, разбери и продолжи:" >&2
    echo "$RESUME_WT" >&2
    echo "  git -C $RESUME_WT rebase --continue   (после разрешения), затем повтори вызов" >&2
    echo "isolate-push: manual-resume-conflict=$RESUME_WT"
    echo "$RESUME_WT"
    exit 3
  fi
  echo "isolate-push: догнать origin из сохранённой копии не удалось (не rebase-конфликт — смотри вывод выше); копия сохранена:" >&2
  echo "$RESUME_WT" >&2
  exit 1
fi

attempt=1
while [ "$attempt" -le "$MAX_RETRIES" ]; do
  echo "isolate-push: попытка $attempt/$MAX_RETRIES"

  if ! git -C "$SOURCE_WORKTREE" fetch origin "$TARGET_BRANCH" --quiet 2>&1; then
    echo "isolate-push: git fetch origin $TARGET_BRANCH не прошёл" >&2
    exit 1
  fi

  BASE=$(git -C "$SOURCE_WORKTREE" merge-base "$SOURCE_BRANCH" "origin/$TARGET_BRANCH" 2>/dev/null)
  if [ -z "$BASE" ]; then
    echo "isolate-push: не нашёл merge-base между $SOURCE_BRANCH и origin/$TARGET_BRANCH" >&2
    exit 1
  fi

  if [ -n "$EXACT_COMMIT" ]; then
    COMMITS="$EXACT_COMMIT"
  else
    COMMITS=$(git -C "$SOURCE_WORKTREE" rev-list --reverse "$BASE..$SOURCE_BRANCH")
  fi
  if [ -z "$COMMITS" ]; then
    echo "isolate-push: нечего пушить — $SOURCE_BRANCH не опережает origin/$TARGET_BRANCH"
    exit 0
  fi

  # A merge commit in the range has no single well-defined parent to
  # cherry-pick against — bail with the exact SHAs rather than let
  # `git cherry-pick` fail later on whichever one it reaches first with a
  # less specific message.
  if [ -n "$EXACT_COMMIT" ]; then
    MERGE_COMMITS=$(git -C "$SOURCE_WORKTREE" rev-list --merges "$EXACT_COMMIT^..$EXACT_COMMIT")
  else
    MERGE_COMMITS=$(git -C "$SOURCE_WORKTREE" rev-list --merges "$BASE..$SOURCE_BRANCH")
  fi
  if [ -n "$MERGE_COMMITS" ]; then
    echo "isolate-push: merge-коммит(ы) в переносимом диапазоне — этот скрипт переносит только линейную историю:" >&2
    echo "$MERGE_COMMITS" >&2
    exit 2
  fi

  mkdir -p "$TEMP_STORE_DIR"
  ATTEMPT_ID="attempt-${attempt}-$$-${ATTEMPT_UUID}"
  TEMP_WORKTREE="$TEMP_STORE_DIR/$ATTEMPT_ID"

  # Паспорт ДО worktree add: при сбое создания worktree запись creating
  # остаётся маркером прерванной попытки, при сбое паспорта worktree не
  # существует вовсе — немаркированного worktree не бывает ни в одном порядке.
  if ! attempt_marker "$ATTEMPT_ID" "creating" "$TEMP_WORKTREE" "$COMMITS" 1; then
    echo "isolate-push: не удалось создать паспорт попытки $ATTEMPT_ID — попытка не начинается" >&2
    exit 1
  fi
  if ! git -C "$SOURCE_WORKTREE" worktree add --detach "$TEMP_WORKTREE" "origin/$TARGET_BRANCH" --quiet 2>&1; then
    attempt_marker "$ATTEMPT_ID" "failed" "$TEMP_WORKTREE" "$COMMITS" || true
    echo "isolate-push: не удалось создать временный worktree $TEMP_WORKTREE" >&2
    exit 1
  fi
  attempt_marker "$ATTEMPT_ID" "active" "$TEMP_WORKTREE" "$COMMITS" || echo "isolate-push: WARN паспорт попытки не обновлён (active)" >&2

  # $COMMITS is a newline-separated SHA list, not a single token — word
  # splitting is intentional. A competing publisher may already have landed
  # one patch under another OID while this attempt waited for the gate. Git
  # then stops the whole sequence on an empty pick, before later unique
  # commits. Resume only when BOTH facts are proven: the failed pick left no
  # index/worktree changes, and its stable patch-id is represented by HEAD.
  # A real conflict, a hook/signing failure, or an empty source commit fails
  # one of those checks and stays on the existing manual-resolution path.
  # Disable rerere autoupdate both through config and the command flag: a
  # repository may have rerere.autoupdate=true plus a learned resolution that
  # stages the target's current content, making a real conflict look clean.
  # shellcheck disable=SC2086
  git -C "$TEMP_WORKTREE" -c rerere.autoupdate=false \
    cherry-pick --no-rerere-autoupdate $COMMITS 2>&1
  CHERRY_PICK_RC=$?
  while [ "$CHERRY_PICK_RC" -ne 0 ]; do
    CURRENT_PICK=$(git -C "$TEMP_WORKTREE" rev-parse CHERRY_PICK_HEAD 2>/dev/null || true)
    [ -n "$CURRENT_PICK" ] || break
    PICK_STATUS=$(git -C "$TEMP_WORKTREE" status --porcelain --untracked-files=all 2>/dev/null) || break
    [ -z "$PICK_STATUS" ] || break
    patch_equivalent_to_head "$CURRENT_PICK" || content_equivalent_to_head "$CURRENT_PICK" || break

    echo "isolate-push: коммит $CURRENT_PICK патч- или файлово-эквивалентен текущему HEAD — уже опубликован, продолжаю"
    # --no-rerere-autoupdate is incompatible with --skip in Git's sequencer;
    # the command-scoped config still covers every later pick resumed here.
    git -C "$TEMP_WORKTREE" -c rerere.autoupdate=false cherry-pick --skip 2>&1
    CHERRY_PICK_RC=$?
  done

  if [ "$CHERRY_PICK_RC" -ne 0 ]; then
    # A linked worktree's .git is a gitdir-pointer FILE, not a directory --
    # `$TEMP_WORKTREE/.git/CHERRY_PICK_HEAD` never exists here (the real file
    # lives under the source worktree's .git/worktrees/<name>/, resolved by
    # --git-path). Found by cold-context review: the naive `-f` check below
    # this comment used to be permanently false, dead code papering over the
    # real check on the next line.
    if git -C "$TEMP_WORKTREE" rev-parse CHERRY_PICK_HEAD >/dev/null 2>&1; then
      CONFLICT_STATE_HASH=$(retry_cleanup_state hash "$TEMP_WORKTREE" 2>/dev/null || true)
      CONFLICT_STATUS="needs-manual-resolve"
      CONFLICT_CLEANUP_TOKEN=""
      if [ -n "${DS_PUBLISH_RETRY_CLEANUP_TOKEN:-}" ] && \
         [[ "$CONFLICT_STATE_HASH" =~ ^[0-9a-f]{64}$ ]]; then
        CONFLICT_STATUS="retry-pending-classification"
        CONFLICT_CLEANUP_TOKEN="$DS_PUBLISH_RETRY_CLEANUP_TOKEN"
      elif [ -n "${DS_PUBLISH_RETRY_CLEANUP_TOKEN:-}" ]; then
        echo "isolate-push: WARN снимок конфликта недоступен — копия сразу передана ручному resume без права автоудаления" >&2
      fi
      if ! attempt_marker "$ATTEMPT_ID" "$CONFLICT_STATUS" "$TEMP_WORKTREE" "$COMMITS" 0 \
        "$CONFLICT_CLEANUP_TOKEN" "$CONFLICT_STATE_HASH"; then
        echo "isolate-push: WARN паспорт попытки не обновлён; автоматическая очистка запрещена" >&2
        echo "$TEMP_WORKTREE"
        exit 3
      fi
      echo "isolate-push: cherry-pick конфликт — временный worktree сохранён для ручного разбора:"
      if [ "$CONFLICT_STATUS" = "retry-pending-classification" ]; then
        # Machine-readable operation key captured by retry-wrapper before it
        # classifies the conflict as stale. Cleanup later compares this exact
        # ordered range with the passport under the registry lock; checking
        # only the tip would reject or misidentify a multi-commit transfer.
        CLEANUP_COMMITS_CSV=${COMMITS//$'\n'/,}
        echo "isolate-push: retry-cleanup-commits=$CLEANUP_COMMITS_CSV"
      else
        echo "isolate-push: manual-resume-conflict=$TEMP_WORKTREE"
      fi
      echo "$TEMP_WORKTREE"
      exit 3
    fi
    # review-01 Critical-4: needs-manual-resolve — только при факте конфликта
    # (CHERRY_PICK_HEAD существует); прочая ошибка — отдельный статус failed,
    # иначе будущий свипер читал бы ложное «ждёт ручного разбора конфликта».
    attempt_marker "$ATTEMPT_ID" "failed" "$TEMP_WORKTREE" "$COMMITS" || echo "isolate-push: WARN паспорт попытки не обновлён (failed)" >&2
    echo "isolate-push: cherry-pick упал не в конфликт (неожиданная ошибка) — временный worktree сохранён:" >&2
    echo "$TEMP_WORKTREE" >&2
    exit 1
  fi

  if git -C "$TEMP_WORKTREE" push origin "HEAD:$TARGET_BRANCH" 2>&1; then
    echo "isolate-push: запушено на попытке $attempt"
    post_publish_reconcile "$(git -C "$TEMP_WORKTREE" rev-parse HEAD)"
    if git -C "$SOURCE_WORKTREE" worktree remove "$TEMP_WORKTREE" --force 2>&1; then
      attempt_marker "$ATTEMPT_ID" "done" "$TEMP_WORKTREE" "$COMMITS" || echo "isolate-push: WARN паспорт попытки не обновлён (done)" >&2
    else
      attempt_marker "$ATTEMPT_ID" "done-worktree-left" "$TEMP_WORKTREE" "$COMMITS" || echo "isolate-push: WARN паспорт попытки не обновлён (done-worktree-left)" >&2
      echo "isolate-push: push прошёл, но не удалось убрать временный worktree $TEMP_WORKTREE — остался на диске, почисти вручную: git worktree remove $TEMP_WORKTREE" >&2
    fi
    exit 0
  fi

  echo "isolate-push: push отклонён (попытка $attempt/$MAX_RETRIES) — вероятно параллельный push, повторяю с fetch+cherry-pick заново"
  if git -C "$SOURCE_WORKTREE" worktree remove "$TEMP_WORKTREE" --force 2>&1; then
    attempt_marker "$ATTEMPT_ID" "removed-retry" "$TEMP_WORKTREE" "$COMMITS" || echo "isolate-push: WARN паспорт попытки не обновлён (removed-retry)" >&2
  else
    attempt_marker "$ATTEMPT_ID" "left-after-reject" "$TEMP_WORKTREE" "$COMMITS" || echo "isolate-push: WARN паспорт попытки не обновлён (left-after-reject)" >&2
    echo "isolate-push: не удалось убрать временный worktree $TEMP_WORKTREE перед retry — останется висеть, следующая попытка создаст новый по соседству" >&2
  fi
  attempt=$((attempt + 1))
done

echo "isolate-push: push не прошёл после $MAX_RETRIES попыток — реальный конфликт с параллельными push, нужна ручная проверка" >&2
exit 1
