#!/bin/bash
# routing: helper  skill=day-close  called-by=haiku
# see DP.SC.159, DP.ROLE.059
# day-close.sh — Автоматические шаги Day Close (backup + reindex + linear sync + sessions)
#
# Вызывается Claude из протокола Day Close (protocol-close.md § День, шаг 4).
# Объединяет четыре механических операции в одну команду.
#
# Использование:
#   day-close.sh                # все четыре шага
#   day-close.sh --backup       # только backup
#   day-close.sh --reindex      # только reindex
#   day-close.sh --linear       # только linear sync
#   day-close.sh --sessions     # только консолидация сессий дня (DAP1-B, WP-7)
#
# Конфигурация: Пути заданы через переменные ниже — настроить при установке.

set -euo pipefail

# === КОНФИГУРАЦИЯ (настроить при установке) ===
# Load unified environment: WORKSPACE_DIR, IWE_ROOT, IWE_SCRIPTS, etc.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../.claude/lib/iwe-env-bootstrap.sh" || exit 1
# issue #545: iwe_sessions_dir (резолвер корня журналов по контракту писателя)
source "$SCRIPT_DIR/lib/common.sh" || {
  echo "FATAL: lib/common.sh not found next to $0 — промотированная копия устарела, обновите её вместе с шаблоном" >&2
  exit 1
}
GOVERNANCE_REPO="${GOVERNANCE_REPO:-${IWE_GOVERNANCE_REPO:-DS-strategy}}"
DS_STRATEGY="$WORKSPACE_DIR/$GOVERNANCE_REPO"
# Slug derived from WORKSPACE_DIR (not $HOME) so it matches Claude's project key
# regardless of workspace location. Override via IWE_MEMORY_SRC if needed.
WORKSPACE_SLUG=$(echo "$WORKSPACE_DIR" | tr '/_ ' '-')
MEMORY_SRC="${IWE_MEMORY_SRC:-$HOME/.claude/projects/${WORKSPACE_SLUG}/memory}"
EXOCORTEX_DST="$DS_STRATEGY/exocortex"
# MCP reindex — опциональный компонент (WP-187 iwe-knowledge Gateway заменяет локальный knowledge-mcp).
# Переопределить путь можно через env IWE_SELECTIVE_REINDEX.
# do_reindex() exit code for "some branches indexed, some failed" (see do_reindex).
readonly RC_REINDEX_PARTIAL=3
# A step that cannot run (missing script/dir/interpreter) is a SKIP, not an
# ok: the summary and log must distinguish "done" from "not attempted" (#559).
readonly RC_STEP_SKIPPED=90
SELECTIVE_REINDEX="${IWE_SELECTIVE_REINDEX:-$WORKSPACE_DIR/DS-MCP/knowledge-mcp/scripts/selective-reindex.sh}"
SOURCES_JSON="${IWE_SOURCES_JSON:-$WORKSPACE_DIR/DS-MCP/knowledge-mcp/scripts/sources.json}"
SOURCES_PERSONAL_JSON="${IWE_SOURCES_PERSONAL_JSON:-$WORKSPACE_DIR/DS-MCP/knowledge-mcp/scripts/sources-personal.json}"
# issue #463: linear_sync_path и защита day-rhythm-config.yaml ниже читаются через
# python3+yaml с fallback на пустую строку — без pyyaml это не падает, а тихо
# возвращает пустую строку, неотличимую от «поля нет в конфиге». Один явный
# warning здесь вместо голого ModuleNotFoundError на каждом отдельном вызове.
#
# Evgenii Red Team review 2026-08-19 (defect #5 class): resolve python3+PyYAML
# ONCE via the F6 shared resolver (scripts/lib/find-python3.sh, #453/#463),
# reuse RESOLVED_PYTHON3 for every python3 call in this file below — a bare
# `python3 -c "import yaml"` probe only sees PATH's own python3, which can
# lack PyYAML on the same Apple Silicon machine where the resolver's own
# Homebrew-path candidate (see find-python3.sh) does have it.
RESOLVER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/find-python3.sh"
RESOLVED_PYTHON3=""
if ! RESOLVED_PYTHON3=$("$RESOLVER" 2>/dev/null); then
  echo "⚠ pyyaml не найден — linear sync будет пропущен, а отличающийся day-rhythm-config.yaml сохранён без перезаписи. Установите: pip3 install --user pyyaml" >&2
fi
# The ownership manifest uses only Python's standard library. It must remain
# available even when PyYAML is absent; otherwise stale-file deletion would
# silently fall back to the unsafe historical rsync --delete behaviour (#536).
STDLIB_PYTHON3=""
for _stdlib_python_candidate in python3 python; do
  if command -v "$_stdlib_python_candidate" >/dev/null 2>&1 && \
     "$_stdlib_python_candidate" -c 'import sys; raise SystemExit(sys.version_info[0] != 3)' >/dev/null 2>&1; then
    STDLIB_PYTHON3="$_stdlib_python_candidate"
    break
  fi
done
unset _stdlib_python_candidate
BACKUP_MANIFEST_NAME=".day-close-backup-manifest.json"
BACKUP_QUARANTINE_NAME=".day-close-backup-incomplete"
readonly RC_BACKUP_WARNING=4
BACKUP_WARNING=false
# Linear sync: путь читается из params.yaml (ключ linear_sync_path)
PARAMS_YAML="$WORKSPACE_DIR/params.yaml"
LINEAR_SYNC=""
if [ -n "$RESOLVED_PYTHON3" ] && [ -f "$PARAMS_YAML" ]; then
  _raw=$("$RESOLVED_PYTHON3" -c "import yaml,sys; d=yaml.safe_load(open(sys.argv[1])); print(d.get('linear_sync_path',''))" "$PARAMS_YAML" 2>/dev/null || echo "")
  if [ -n "$_raw" ]; then
    LINEAR_SYNC="${_raw/#\~/$HOME}"
  fi
fi
LOG_FILE="${IWE_DAY_CLOSE_LOG:-$HOME/logs/day-close.log}"
# === /КОНФИГУРАЦИЯ ===

# Цвета
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log() { echo -e "${GREEN}[day-close]${NC} $1"; }
warn() { echo -e "${YELLOW}[day-close]${NC} $1"; }
err() { echo -e "${RED}[day-close]${NC} $1" >&2; }

atomic_copy_file() {
  local src="$1" dst="$2" label="$3" parent tmp
  parent=$(dirname "$dst")
  mkdir -p "$parent"

  if [ -e "$dst" ] && [ ! -f "$dst" ] && [ ! -L "$dst" ]; then
    warn "  $label: назначение не является обычным файлом — сохранено без изменений: $dst"
    return 1
  fi

  tmp=$(mktemp "$parent/.$(basename "$dst").tmp.XXXXXX") || {
    err "  $label: не удалось создать временный файл"
    return 1
  }
  if ! cp -p "$src" "$tmp"; then
    rm -f -- "$tmp"
    err "  $label: не удалось подготовить атомарную копию"
    return 1
  fi
  # Never follow a receiver-side final symlink. Remove only the link itself;
  # os/files behind it remain untouched, then mv creates a regular file.
  if [ -L "$dst" ] && ! rm -- "$dst"; then
    rm -f -- "$tmp"
    err "  $label: не удалось убрать конечный симлинк"
    return 1
  fi
  if ! mv -f -- "$tmp" "$dst"; then
    rm -f -- "$tmp"
    err "  $label: атомарная замена не удалась"
    return 1
  fi
}

atomic_instruction_backup() {
  local src="$1" dst="$2" label="$3" rendered rc=0
  rendered=$(mktemp "$EXOCORTEX_DST/.${label}.render.XXXXXX") || {
    err "  $label: не удалось создать временный файл для подстановки HOME"
    return 1
  }
  if ! sed "s|$HOME|{{HOME_DIR}}|g" "$src" > "$rendered"; then
    rm -f -- "$rendered"
    err "  $label: подстановка HOME не выполнена"
    return 1
  fi
  atomic_copy_file "$rendered" "$dst" "$label" || rc=$?
  rm -f -- "$rendered"
  return "$rc"
}

sync_owned_memory_files() {
  if [ -z "$STDLIB_PYTHON3" ]; then
    err "  Backup ownership: python3 не найден — копирование памяти остановлено безопасно"
    return 1
  fi

  # Bash 3.2 + `set -u` treats an empty array expansion as unbound. Build the
  # always-nonempty Python argv through the function's positional parameters
  # so a backup with no special targets remains portable on stock macOS.
  local params_backup_source=""
  [ -f "$WORKSPACE_DIR/params.yaml" ] && \
    params_backup_source="$WORKSPACE_DIR/params.yaml"
  set -- \
    "$MEMORY_SRC" \
    "$EXOCORTEX_DST" \
    "$EXOCORTEX_DST/$BACKUP_MANIFEST_NAME" \
    "$EXOCORTEX_DST/$BACKUP_QUARANTINE_NAME" \
    "$params_backup_source"
  [ -f "$WORKSPACE_DIR/params.yaml" ] && set -- "$@" "params.yaml"
  [ -f "$MEMORY_SRC/day-rhythm-config.yaml" ] && \
    set -- "$@" "day-rhythm-config.yaml"
  [ -f "$WORKSPACE_DIR/CLAUDE.md" ] && set -- "$@" "CLAUDE.md"
  [ -f "$WORKSPACE_DIR/AGENTS.md" ] && set -- "$@" "AGENTS.md"

  "$STDLIB_PYTHON3" - "$@" <<'PYEOF'
import hashlib
import fcntl
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import sys
import time
import unicodedata
import uuid


source_root = Path(sys.argv[1])
destination_root = Path(sys.argv[2])
manifest_path = Path(sys.argv[3])
quarantine_path = Path(sys.argv[4])
quarantine_root = destination_root / ".day-close-backup-quarantine"
lock_path = destination_root / ".day-close-backup.lock"
params_source = Path(sys.argv[5]) if sys.argv[5] else None
active_special_targets = set(sys.argv[6:])
protected_files = {
    "CLAUDE.md",
    "AGENTS.md",
    "day-rhythm-config.yaml",
    "params.yaml",
    manifest_path.name,
    quarantine_path.name,
    lock_path.name,
}
protected_roots = {
    ".git",
    quarantine_root.name,
    "extensions",
    "agent-fault-profile",
    "hindsight",
    "decisions",
    "rules",
}
hash_pattern = re.compile(r"[0-9a-f]{64}")


class PreflightError(RuntimeError):
    pass


def warn(message):
    print(f"⚠ day-close backup: {message}", file=sys.stderr)


def canonical_component(component):
    normalized = unicodedata.normalize(
        "NFKC", unicodedata.normalize("NFKC", component).casefold()
    )
    if (
        not normalized
        or normalized in {".", ".."}
        or "/" in normalized
        or "\\" in normalized
        or any(
            ord(character) < 32
            or ord(character) == 127
            or 0xD800 <= ord(character) <= 0xDFFF
            for character in normalized
        )
    ):
        raise ValueError(f"unsafe canonical path component: {component!r}")
    return normalized


def canonical_path(parts):
    return tuple(canonical_component(part) for part in parts)


protected_file_keys = {
    canonical_component(name): name for name in protected_files
}
protected_root_keys = {
    canonical_component(name): name for name in protected_roots
}


def validate_lexical(raw):
    if not isinstance(raw, str) or not raw or "\\" in raw:
        raise ValueError("path must be a non-empty POSIX relative path")
    if any(ord(character) < 32 or ord(character) == 127 for character in raw):
        raise ValueError("path contains a control character")
    raw_parts = raw.split("/")
    if any(part in {"", ".", ".."} for part in raw_parts):
        raise ValueError("path contains an empty/dot/traversal segment")
    relative = PurePosixPath(raw)
    if relative.is_absolute():
        raise ValueError("absolute path")
    root = os.path.abspath(destination_root)
    candidate = os.path.abspath(os.path.join(root, relative.as_posix()))
    if os.path.commonpath((root, candidate)) != root:
        raise ValueError("path escapes destination root")
    return relative


def is_exact_protected(parts):
    return len(parts) == 1 and (
        parts[0] in protected_files or parts[0] in protected_roots
    )


def protected_alias(parts):
    first_key = canonical_component(parts[0])
    if first_key in protected_root_keys and parts[0] != protected_root_keys[first_key]:
        return protected_root_keys[first_key]
    if len(parts) == 1:
        file_key = canonical_component(parts[0])
        if file_key in protected_file_keys and parts[0] != protected_file_keys[file_key]:
            return protected_file_keys[file_key]
    return None


def validate_owned_relative(raw):
    relative = validate_lexical(raw)
    parts = relative.parts
    if len(parts) == 1 and parts[0] in protected_files:
        raise ValueError("protected path")
    if parts[0] in protected_roots:
        raise ValueError("protected path")
    alias = protected_alias(parts)
    if alias is not None:
        raise ValueError(f"path aliases protected path {alias!r}")
    return relative


def stat_identity(value):
    return (
        value.st_dev,
        value.st_ino,
        value.st_mode,
        value.st_size,
        getattr(value, "st_mtime_ns", int(value.st_mtime * 1_000_000_000)),
        getattr(value, "st_ctime_ns", int(value.st_ctime * 1_000_000_000)),
    )


def same_file_content_identity(actual, expected):
    # Creating the retained hard link legitimately updates ctime. Device,
    # inode, mode, size and mtime still identify the exact inspected bytes.
    return tuple(actual[:5]) == tuple(expected[:5])


def exact_entry_stat(parent_descriptor, component):
    matches = [
        name
        for name in os.listdir(parent_descriptor)
        if canonical_component(name) == canonical_component(component)
    ]
    if not matches:
        return None
    if len(matches) != 1 or matches[0] != component:
        names = ", ".join(repr(name) for name in matches)
        raise PreflightError(
            f"destination alias collision for {component!r}: {names}"
        )
    try:
        return os.stat(component, dir_fd=parent_descriptor, follow_symlinks=False)
    except FileNotFoundError as error:
        raise PreflightError(
            f"destination entry changed during inspection: {component}"
        ) from error


def open_destination_parent(relative, create_parents):
    parts = validate_lexical(relative).parts
    descriptor = os.dup(destination_root_descriptor)
    try:
        for component in parts[:-1]:
            entry_stat = exact_entry_stat(descriptor, component)
            if entry_stat is None:
                if not create_parents:
                    os.close(descriptor)
                    return None
                os.mkdir(component, mode=0o700, dir_fd=descriptor)
                os.fsync(descriptor)
                entry_stat = exact_entry_stat(descriptor, component)
            if entry_stat is None or not stat.S_ISDIR(entry_stat.st_mode):
                raise PreflightError(
                    f"destination intermediate component is not a directory: {component}"
                )
            child_descriptor = os.open(
                component,
                os.O_RDONLY
                | getattr(os, "O_DIRECTORY", 0)
                | getattr(os, "O_NOFOLLOW", 0),
                dir_fd=descriptor,
            )
            child_stat = os.fstat(child_descriptor)
            if (
                child_stat.st_dev != entry_stat.st_dev
                or child_stat.st_ino != entry_stat.st_ino
                or not stat.S_ISDIR(child_stat.st_mode)
            ):
                os.close(child_descriptor)
                raise PreflightError(
                    f"destination directory changed during traversal: {component}"
                )
            os.close(descriptor)
            descriptor = child_descriptor
        return descriptor, parts[-1]
    except Exception:
        try:
            os.close(descriptor)
        except OSError:
            pass
        raise


def open_bound_regular(parent_descriptor, component, expected_identity=None):
    entry_stat = exact_entry_stat(parent_descriptor, component)
    if entry_stat is None:
        return None
    if not stat.S_ISREG(entry_stat.st_mode):
        raise PreflightError(f"destination entry is not a regular file: {component}")
    descriptor = os.open(
        component,
        os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
        dir_fd=parent_descriptor,
    )
    opened_stat = os.fstat(descriptor)
    opened_identity = stat_identity(opened_stat)
    if opened_identity != stat_identity(entry_stat) or (
        expected_identity is not None and opened_identity != expected_identity
    ):
        os.close(descriptor)
        raise PreflightError(f"destination identity changed before open: {component}")
    current_stat = exact_entry_stat(parent_descriptor, component)
    if current_stat is None or stat_identity(current_stat) != opened_identity:
        os.close(descriptor)
        raise PreflightError(f"destination identity changed after open: {component}")
    return descriptor, opened_identity


def digest_descriptor(descriptor):
    result = hashlib.sha256()
    os.lseek(descriptor, 0, os.SEEK_SET)
    while True:
        chunk = os.read(descriptor, 1024 * 1024)
        if not chunk:
            break
        result.update(chunk)
    return result.hexdigest()


def read_bound_bytes(parent_descriptor, component):
    bound_file = open_bound_regular(parent_descriptor, component)
    if bound_file is None:
        return None
    descriptor, identity = bound_file
    try:
        chunks = []
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        if stat_identity(os.fstat(descriptor)) != identity:
            raise PreflightError(f"destination changed while reading: {component}")
    finally:
        os.close(descriptor)
    current_stat = exact_entry_stat(parent_descriptor, component)
    if current_stat is None or stat_identity(current_stat) != identity:
        raise PreflightError(f"destination identity changed after read: {component}")
    return b"".join(chunks)


def create_temporary_file(parent_descriptor, mode):
    for _attempt in range(100):
        temporary_name = f".day-close-tmp-{uuid.uuid4().hex}"
        try:
            descriptor = os.open(
                temporary_name,
                os.O_WRONLY
                | os.O_CREAT
                | os.O_EXCL
                | getattr(os, "O_NOFOLLOW", 0),
                mode,
                dir_fd=parent_descriptor,
            )
            return descriptor, temporary_name
        except FileExistsError:
            continue
    raise PreflightError("could not allocate a unique destination temporary file")


def test_barrier(point, relative):
    if os.environ.get("IWE_DAY_CLOSE_TESTING") != "1":
        return
    if os.environ.get("IWE_DAY_CLOSE_TEST_POINT") != f"{point}:{relative}":
        return
    if os.environ.get("IWE_DAY_CLOSE_TEST_FAILURE") == "1":
        raise PreflightError(f"injected test failure: {point}:{relative}")
    raw_directory = os.environ.get("IWE_DAY_CLOSE_TEST_BARRIER")
    if not raw_directory:
        raise PreflightError("test barrier directory is missing")
    directory = Path(raw_directory)
    if not directory.is_dir() or directory.is_symlink():
        raise PreflightError("test barrier directory is unsafe")
    ready = directory / "ready"
    release = directory / "release"
    ready.write_text(f"{point}:{relative}\n", encoding="utf-8")
    deadline = time.monotonic() + 15
    while not release.exists():
        if time.monotonic() >= deadline:
            raise PreflightError(f"test barrier timed out: {point}:{relative}")
        time.sleep(0.01)


def capture_identity(path):
    try:
        link_stat = path.lstat()
        target_stat = path.stat()
    except OSError as error:
        raise PreflightError(f"source stat failed: {path} ({error})") from error
    return stat_identity(link_stat), stat_identity(target_stat)


def verify_identity(path, expected_link, expected_target):
    current_link, current_target = capture_identity(path)
    if current_link != expected_link or current_target != expected_target:
        raise PreflightError(f"source identity changed during backup: {path}")


def reject_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key!r}")
        result[key] = value
    return result


def load_json_bytes(content):
    return json.loads(
        content.decode("utf-8"), object_pairs_hook=reject_duplicate_keys
    )


def load_previous_manifest():
    try:
        manifest_stat = exact_entry_stat(
            destination_root_descriptor, manifest_path.name
        )
        if manifest_stat is None:
            return {}
        if stat.S_ISLNK(manifest_stat.st_mode):
            warn(
                "manifest is a symlink; stale deletion disabled and the link will be replaced"
            )
            return {}
        content = read_bound_bytes(destination_root_descriptor, manifest_path.name)
        if content is None:
            return {}
        payload = load_json_bytes(content)
        if not isinstance(payload, dict) or payload.get("schema_version") != 1:
            raise ValueError("schema_version must equal 1")
        files = payload.get("files")
        if not isinstance(files, dict):
            raise ValueError("files must be an object")
        validated = {}
        canonical_entries = {}
        for raw_path, old_hash in files.items():
            relative = validate_owned_relative(raw_path)
            if not isinstance(old_hash, str) or not hash_pattern.fullmatch(old_hash):
                raise ValueError(f"invalid sha256 for {raw_path!r}")
            key = canonical_path(relative.parts)
            if key in canonical_entries and canonical_entries[key] != relative.as_posix():
                raise ValueError(
                    f"manifest path collision: {canonical_entries[key]!r} / {relative.as_posix()!r}"
                )
            canonical_entries[key] = relative.as_posix()
            validated[relative.as_posix()] = old_hash
        return validated
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as error:
        warn(f"manifest invalid ({error}); stale deletion disabled")
        return {}


def discover_sources():
    discovered = {}
    directory_identities = {}
    canonical_entries = {}
    source_namespace = {}

    root_link, root_target = capture_identity(source_root)
    if not stat.S_ISDIR(root_target[2]):
        raise PreflightError(f"memory source is not a directory: {source_root}")
    directory_identities[source_root] = (root_link, root_target)

    def register(relative, entry_kind):
        raw = relative.as_posix()
        validate_lexical(raw)
        parts = relative.parts
        if not is_exact_protected(parts):
            alias = protected_alias(parts)
            if alias is not None:
                raise PreflightError(
                    f"source path {raw!r} aliases protected path {alias!r}"
                )
        key = canonical_path(parts)
        previous = canonical_entries.get(key)
        if previous is not None and previous != (raw, entry_kind):
            raise PreflightError(
                "source path collision after NFKC+casefold: "
                f"{previous[0]!r} ({previous[1]}) / {raw!r} ({entry_kind})"
            )
        canonical_entries[key] = (raw, entry_kind)
        if not is_exact_protected(parts):
            source_namespace[raw] = entry_kind

    def scan(directory, relative_parts):
        try:
            with os.scandir(directory) as iterator:
                entries = sorted(list(iterator), key=lambda item: item.name)
        except OSError as error:
            raise PreflightError(f"source directory scan failed: {directory} ({error})") from error

        for entry in entries:
            relative = PurePosixPath(*(relative_parts + (entry.name,)))
            raw = relative.as_posix()
            try:
                link_stat = entry.stat(follow_symlinks=False)
            except OSError as error:
                raise PreflightError(f"source lstat failed: {raw} ({error})") from error

            if is_exact_protected(relative.parts):
                register(relative, "protected")
                continue

            if stat.S_ISLNK(link_stat.st_mode):
                try:
                    target_stat = entry.stat(follow_symlinks=True)
                except OSError as error:
                    raise PreflightError(f"source symlink target stat failed: {raw} ({error})") from error
                if stat.S_ISDIR(target_stat.st_mode):
                    register(relative, "directory-symlink")
                    raise PreflightError(
                        f"unprotected source directory symlink is unsupported: {raw}"
                    )
                if stat.S_ISREG(target_stat.st_mode):
                    entry_kind = "file"
                else:
                    entry_kind = "special"
            elif stat.S_ISDIR(link_stat.st_mode):
                entry_kind = "directory"
                target_stat = link_stat
            elif stat.S_ISREG(link_stat.st_mode):
                entry_kind = "file"
                target_stat = link_stat
            else:
                entry_kind = "special"
                target_stat = link_stat

            register(relative, entry_kind)
            if entry_kind == "directory":
                path = Path(entry.path)
                directory_identities[path] = (
                    stat_identity(link_stat),
                    stat_identity(target_stat),
                )
                scan(path, relative_parts + (entry.name,))
                continue
            if entry_kind == "special":
                if Path(entry.name).suffix in {".md", ".yaml", ".yml"}:
                    raise PreflightError(f"source backup candidate is not a regular file: {raw}")
                continue
            source = Path(entry.path)
            if source.suffix not in {".md", ".yaml", ".yml"}:
                continue
            discovered[raw] = {
                "path": source,
                "link_identity": stat_identity(link_stat),
                "target_identity": stat_identity(target_stat),
            }

    scan(source_root, ())
    return discovered, directory_identities, source_namespace


def preflight_destination_target(relative, final_kind="file"):
    components = validate_lexical(relative).parts
    parent_descriptor = os.dup(destination_root_descriptor)
    try:
        for index, component in enumerate(components):
            entry_stat = exact_entry_stat(parent_descriptor, component)
            if entry_stat is None:
                return
            is_final = index == len(components) - 1
            if not is_final:
                if not stat.S_ISDIR(entry_stat.st_mode):
                    raise PreflightError(
                        "destination intermediate component is not a directory: "
                        f"{relative}"
                    )
                child_descriptor = os.open(
                    component,
                    os.O_RDONLY
                    | getattr(os, "O_DIRECTORY", 0)
                    | getattr(os, "O_NOFOLLOW", 0),
                    dir_fd=parent_descriptor,
                )
                child_stat = os.fstat(child_descriptor)
                if (
                    child_stat.st_dev != entry_stat.st_dev
                    or child_stat.st_ino != entry_stat.st_ino
                    or not stat.S_ISDIR(child_stat.st_mode)
                ):
                    os.close(child_descriptor)
                    raise PreflightError(
                        f"destination directory changed during preflight: {relative}"
                    )
                os.close(parent_descriptor)
                parent_descriptor = child_descriptor
                continue
            if final_kind == "file" and stat.S_ISDIR(entry_stat.st_mode):
                raise PreflightError(
                    f"destination type mismatch (directory vs file): {relative}"
                )
            if final_kind == "file" and not (
                stat.S_ISREG(entry_stat.st_mode)
                or stat.S_ISLNK(entry_stat.st_mode)
            ):
                raise PreflightError(f"destination is non-regular: {relative}")
            if final_kind == "directory" and not stat.S_ISDIR(entry_stat.st_mode):
                raise PreflightError(
                    f"destination type mismatch (file vs directory): {relative}"
                )
    finally:
        os.close(parent_descriptor)


def preflight_destination(source_namespace, previous_files):
    for relative, entry_kind in sorted(source_namespace.items()):
        if entry_kind == "directory":
            preflight_destination_target(relative, final_kind="directory")
        elif entry_kind == "file":
            preflight_destination_target(relative)
    for relative in sorted(previous_files):
        preflight_destination_target(relative)
    reserved_file_targets = protected_files | active_special_targets
    for target in sorted(reserved_file_targets):
        preflight_destination_target(target)
    for target in sorted(protected_roots):
        preflight_destination_target(target, final_kind="directory")


def verify_source_tree(directory_identities):
    for path, identities in directory_identities.items():
        verify_identity(path, identities[0], identities[1])


def atomic_copy(record, relative):
    parent_descriptor, destination_name = open_destination_parent(
        relative, create_parents=True
    )
    descriptor = None
    temporary_name = None
    try:
        destination_stat = exact_entry_stat(parent_descriptor, destination_name)
        if destination_stat is not None and not (
            stat.S_ISLNK(destination_stat.st_mode)
            or stat.S_ISREG(destination_stat.st_mode)
        ):
            warn(f"non-regular destination preserved; copy skipped: {relative}")
            return None
        destination_identity = (
            None if destination_stat is None else stat_identity(destination_stat)
        )

        descriptor, temporary_name = create_temporary_file(parent_descriptor, 0o600)
        source = record["path"]
        verify_identity(source, record["link_identity"], record["target_identity"])
        source_descriptor = os.open(source, os.O_RDONLY)
        try:
            opened_identity = stat_identity(os.fstat(source_descriptor))
            verify_identity(source, record["link_identity"], record["target_identity"])
        except Exception:
            os.close(source_descriptor)
            raise
        if opened_identity != record["target_identity"]:
            os.close(source_descriptor)
            raise PreflightError(f"source identity changed before open: {relative}")
        copied_digest = hashlib.sha256()
        os.fchmod(descriptor, stat.S_IMODE(record["target_identity"][2]))
        with os.fdopen(source_descriptor, "rb") as source_stream, os.fdopen(descriptor, "wb") as target_stream:
            for chunk in iter(lambda: source_stream.read(1024 * 1024), b""):
                target_stream.write(chunk)
                copied_digest.update(chunk)
            target_stream.flush()
            os.fsync(target_stream.fileno())
        verify_identity(source, record["link_identity"], record["target_identity"])
        test_barrier("copy-before-publish", relative)
        current_stat = exact_entry_stat(parent_descriptor, destination_name)
        current_identity = None if current_stat is None else stat_identity(current_stat)
        if current_identity != destination_identity:
            raise PreflightError(
                f"destination changed while copy was staged: {relative}"
            )
        # Descriptor-relative replace binds the operation to the inspected
        # directory. Replacing a final symlink replaces only its entry.
        os.replace(
            temporary_name,
            destination_name,
            src_dir_fd=parent_descriptor,
            dst_dir_fd=parent_descriptor,
        )
        os.fsync(parent_descriptor)
        return copied_digest.hexdigest()
    except Exception:
        if descriptor is not None:
            try:
                os.close(descriptor)
            except OSError:
                pass
        if temporary_name is not None:
            try:
                os.unlink(temporary_name, dir_fd=parent_descriptor)
            except FileNotFoundError:
                pass
        raise
    finally:
        os.close(parent_descriptor)


def build_stale_plan(previous, current_paths, txid):
    entries = []
    for relative, expected_hash in sorted(previous.items()):
        if relative in current_paths:
            continue
        bound_parent = open_destination_parent(relative, create_parents=False)
        if bound_parent is None:
            continue
        parent_descriptor, destination_name = bound_parent
        try:
            destination_stat = exact_entry_stat(parent_descriptor, destination_name)
            if destination_stat is None:
                continue
            if not stat.S_ISREG(destination_stat.st_mode):
                warn(f"stale non-regular path preserved: {relative}")
                continue
            bound_file = open_bound_regular(parent_descriptor, destination_name)
            if bound_file is None:
                raise PreflightError(f"stale path vanished during planning: {relative}")
            file_descriptor, destination_identity = bound_file
            try:
                actual_hash = digest_descriptor(file_descriptor)
                if stat_identity(os.fstat(file_descriptor)) != destination_identity:
                    raise PreflightError(
                        f"stale file changed while hashing: {relative}"
                    )
            finally:
                os.close(file_descriptor)
            current_stat = exact_entry_stat(parent_descriptor, destination_name)
            if (
                current_stat is None
                or stat_identity(current_stat) != destination_identity
            ):
                raise PreflightError(f"stale path changed during planning: {relative}")
            if actual_hash != expected_hash:
                warn(f"modified formerly-owned file preserved: {relative}")
                continue
            entries.append(
                {
                    "path": relative,
                    "sha256": expected_hash,
                    "destination_identity": list(destination_identity),
                    "quarantine_rel": f"{txid}/{relative}",
                }
            )
        finally:
            os.close(parent_descriptor)
    return entries


def atomic_write(path, content, mode):
    if path.parent != destination_root:
        raise PreflightError(f"atomic root write has an invalid target: {path}")
    parent_descriptor = os.dup(destination_root_descriptor)
    descriptor = None
    temporary_name = None
    try:
        destination_stat = exact_entry_stat(parent_descriptor, path.name)
        destination_identity = (
            None if destination_stat is None else stat_identity(destination_stat)
        )
        descriptor, temporary_name = create_temporary_file(parent_descriptor, mode)
        os.fchmod(descriptor, mode)
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        current_stat = exact_entry_stat(parent_descriptor, path.name)
        current_identity = None if current_stat is None else stat_identity(current_stat)
        if current_identity != destination_identity:
            raise PreflightError(f"root target changed while staging: {path.name}")
        os.replace(
            temporary_name,
            path.name,
            src_dir_fd=parent_descriptor,
            dst_dir_fd=parent_descriptor,
        )
        os.fsync(parent_descriptor)
    except Exception:
        if descriptor is not None:
            try:
                os.close(descriptor)
            except OSError:
                pass
        if temporary_name is not None:
            try:
                os.unlink(temporary_name, dir_fd=parent_descriptor)
            except FileNotFoundError:
                pass
        raise
    finally:
        os.close(parent_descriptor)


def write_precopy_journal():
    atomic_write(
        quarantine_path,
        b'{"schema_version":1,"state":"precopy"}\n',
        0o600,
    )


def clear_quarantine():
    journal_stat = exact_entry_stat(
        destination_root_descriptor, quarantine_path.name
    )
    if journal_stat is None or not stat.S_ISREG(journal_stat.st_mode):
        raise PreflightError("quarantine journal changed before clear")
    os.unlink(quarantine_path.name, dir_fd=destination_root_descriptor)
    os.fsync(destination_root_descriptor)


def manifest_payload(files):
    validated_files = {}
    for raw_path, content_hash in files.items():
        relative = validate_owned_relative(raw_path)
        if not hash_pattern.fullmatch(content_hash):
            raise ValueError(f"invalid sha256 for {raw_path!r}")
        validated_files[relative.as_posix()] = content_hash
    return json.dumps(
        {"schema_version": 1, "files": dict(sorted(validated_files.items()))},
        ensure_ascii=False,
        indent=2,
    ).encode("utf-8") + b"\n"


def validate_journal_entry(entry, txid):
    if not isinstance(entry, dict):
        raise ValueError("journal entry must be an object")
    relative = validate_owned_relative(entry.get("path"))
    expected_hash = entry.get("sha256")
    identity = entry.get("destination_identity")
    quarantine_rel = entry.get("quarantine_rel")
    if not isinstance(expected_hash, str) or not hash_pattern.fullmatch(expected_hash):
        raise ValueError("journal entry has invalid sha256")
    if not (
        isinstance(identity, list)
        and len(identity) == 6
        and all(isinstance(value, int) for value in identity)
    ):
        raise ValueError("journal entry has invalid destination identity")
    expected_quarantine = f"{txid}/{relative.as_posix()}"
    if quarantine_rel != expected_quarantine:
        raise ValueError("journal quarantine path does not match transaction/path")
    return {
        "path": relative.as_posix(),
        "sha256": expected_hash,
        "destination_identity": identity,
        "quarantine_rel": quarantine_rel,
    }


def load_active_journal():
    journal_stat = exact_entry_stat(
        destination_root_descriptor, quarantine_path.name
    )
    if journal_stat is None:
        return None
    if stat.S_ISLNK(journal_stat.st_mode):
        raise PreflightError("quarantine journal must not be a symlink")
    if not stat.S_ISREG(journal_stat.st_mode):
        raise PreflightError("quarantine journal is not a regular file")
    content = read_bound_bytes(destination_root_descriptor, quarantine_path.name)
    if content is None:
        raise PreflightError("quarantine journal vanished during read")
    payload = load_json_bytes(content)
    if not isinstance(payload, dict) or payload.get("schema_version") != 1:
        raise ValueError("quarantine journal schema_version must equal 1")
    state = payload.get("state")
    if state in {"precopy", "incomplete"}:
        return {"schema_version": 1, "state": "precopy"}
    if state != "planned":
        raise ValueError("quarantine journal state is invalid")
    txid = payload.get("txid")
    target_hash = payload.get("target_manifest_sha256")
    raw_entries = payload.get("entries")
    if not isinstance(txid, str) or not re.fullmatch(r"[0-9a-f]{32}", txid):
        raise ValueError("quarantine journal txid is invalid")
    if not isinstance(target_hash, str) or not hash_pattern.fullmatch(target_hash):
        raise ValueError("quarantine journal target manifest hash is invalid")
    if not isinstance(raw_entries, list):
        raise ValueError("quarantine journal entries must be an array")
    entries = [validate_journal_entry(entry, txid) for entry in raw_entries]
    paths = [entry["path"] for entry in entries]
    if len(paths) != len(set(paths)):
        raise ValueError("quarantine journal contains duplicate paths")
    return {
        "schema_version": 1,
        "state": "planned",
        "txid": txid,
        "target_manifest_sha256": target_hash,
        "entries": entries,
    }


def write_planned_journal(txid, target_hash, entries):
    payload = json.dumps(
        {
            "schema_version": 1,
            "state": "planned",
            "txid": txid,
            "target_manifest_sha256": target_hash,
            "entries": entries,
        },
        ensure_ascii=False,
        indent=2,
    ).encode("utf-8") + b"\n"
    atomic_write(quarantine_path, payload, 0o600)


def open_quarantine_parent(entry, create_parents):
    relative = f"{quarantine_root.name}/{entry['quarantine_rel']}"
    return open_destination_parent(relative, create_parents=create_parents)


def retained_entry_exists(entry):
    bound_parent = open_quarantine_parent(entry, create_parents=False)
    if bound_parent is None:
        return False
    parent_descriptor, retained_name = bound_parent
    try:
        return exact_entry_stat(parent_descriptor, retained_name) is not None
    finally:
        os.close(parent_descriptor)


def move_stale_to_quarantine(entry):
    relative = entry["path"]
    expected_hash = entry["sha256"]
    expected_identity = tuple(entry["destination_identity"])
    live_parent = open_destination_parent(relative, create_parents=False)
    retained_parent = open_quarantine_parent(entry, create_parents=True)
    retained_parent_descriptor, retained_name = retained_parent
    live_parent_descriptor = None
    try:
        if live_parent is not None:
            live_parent_descriptor, live_name = live_parent
            live_stat = exact_entry_stat(live_parent_descriptor, live_name)
        else:
            live_name = PurePosixPath(relative).name
            live_stat = None
        retained_stat = exact_entry_stat(
            retained_parent_descriptor, retained_name
        )
        if retained_stat is not None:
            if live_stat is not None:
                if not (
                    stat.S_ISREG(live_stat.st_mode)
                    and stat.S_ISREG(retained_stat.st_mode)
                    and live_stat.st_dev == retained_stat.st_dev
                    and live_stat.st_ino == retained_stat.st_ino
                    and same_file_content_identity(
                        stat_identity(live_stat), expected_identity
                    )
                ):
                    raise PreflightError(
                        f"stale path exists both live and quarantined: {relative}"
                    )
                retained_file = open_bound_regular(
                    retained_parent_descriptor, retained_name
                )
                if retained_file is None:
                    raise PreflightError(
                        f"quarantined stale bytes vanished: {relative}"
                    )
                retained_descriptor, retained_identity = retained_file
                try:
                    retained_hash = digest_descriptor(retained_descriptor)
                finally:
                    os.close(retained_descriptor)
                current_live_stat = exact_entry_stat(
                    live_parent_descriptor, live_name
                )
                if (
                    retained_hash != expected_hash
                    or not same_file_content_identity(
                        retained_identity, expected_identity
                    )
                    or current_live_stat is None
                    or current_live_stat.st_dev != retained_stat.st_dev
                    or current_live_stat.st_ino != retained_stat.st_ino
                ):
                    raise PreflightError(
                        f"partial quarantine link changed during recovery: {relative}"
                    )
                os.unlink(live_name, dir_fd=live_parent_descriptor)
                os.fsync(live_parent_descriptor)
                os.fsync(retained_parent_descriptor)
                return
            retained_file = open_bound_regular(
                retained_parent_descriptor, retained_name
            )
            if retained_file is None:
                raise PreflightError(
                    f"quarantined stale bytes vanished: {relative}"
                )
            retained_descriptor, retained_identity = retained_file
            try:
                retained_hash = digest_descriptor(retained_descriptor)
            finally:
                os.close(retained_descriptor)
            if (
                retained_hash != expected_hash
                or not same_file_content_identity(
                    retained_identity, expected_identity
                )
            ):
                raise PreflightError(
                    f"quarantined stale bytes are ambiguous: {relative}"
                )
            return
        if live_stat is None or live_parent_descriptor is None:
            raise PreflightError(f"stale path vanished before quarantine move: {relative}")
        if not stat.S_ISREG(live_stat.st_mode):
            warn(f"stale non-regular path preserved during quarantine move: {relative}")
            return
        if stat_identity(live_stat) != expected_identity:
            warn(f"stale path changed before quarantine move and was preserved: {relative}")
            return
        live_file = open_bound_regular(
            live_parent_descriptor, live_name, expected_identity=expected_identity
        )
        if live_file is None:
            raise PreflightError(f"stale path vanished before quarantine move: {relative}")
        live_descriptor, live_identity = live_file
        try:
            live_hash = digest_descriptor(live_descriptor)
            if stat_identity(os.fstat(live_descriptor)) != live_identity:
                raise PreflightError(
                    f"stale file changed while verifying quarantine move: {relative}"
                )
        finally:
            os.close(live_descriptor)
        if live_hash != expected_hash:
            warn(f"stale path changed before quarantine move and was preserved: {relative}")
            return
        current_stat = exact_entry_stat(live_parent_descriptor, live_name)
        if current_stat is None or stat_identity(current_stat) != expected_identity:
            raise PreflightError(f"stale path changed before quarantine link: {relative}")
        test_barrier("stale-before-link", relative)

        # Link first with an exclusive destination name. This binds retained
        # bytes to the inspected inode before the live name is removed.
        os.link(
            live_name,
            retained_name,
            src_dir_fd=live_parent_descriptor,
            dst_dir_fd=retained_parent_descriptor,
            follow_symlinks=False,
        )
        retained_file = open_bound_regular(
            retained_parent_descriptor,
            retained_name,
        )
        if retained_file is None:
            raise PreflightError(f"stale quarantine link vanished: {relative}")
        retained_descriptor, retained_identity = retained_file
        try:
            retained_hash = digest_descriptor(retained_descriptor)
        finally:
            os.close(retained_descriptor)
        if (
            not same_file_content_identity(retained_identity, expected_identity)
            or retained_hash != expected_hash
        ):
            os.unlink(retained_name, dir_fd=retained_parent_descriptor)
            raise PreflightError(f"stale quarantine verification failed: {relative}")
        current_stat = exact_entry_stat(live_parent_descriptor, live_name)
        if current_stat is None or not same_file_content_identity(
            stat_identity(current_stat), expected_identity
        ):
            warn(f"stale path changed after quarantine link and was preserved: {relative}")
            return
        os.unlink(live_name, dir_fd=live_parent_descriptor)
        os.fsync(live_parent_descriptor)
        os.fsync(retained_parent_descriptor)
    finally:
        if live_parent_descriptor is not None:
            os.close(live_parent_descriptor)
        os.close(retained_parent_descriptor)


def recover_active_journal(journal):
    if journal is None:
        return False
    if journal["state"] == "precopy":
        warn("previous incomplete backup detected before commit")
        return True

    manifest_stat = exact_entry_stat(
        destination_root_descriptor, manifest_path.name
    )
    manifest_content = None
    if manifest_stat is not None and stat.S_ISREG(manifest_stat.st_mode):
        manifest_content = read_bound_bytes(
            destination_root_descriptor, manifest_path.name
        )
    manifest_committed = (
        manifest_content is not None
        and hashlib.sha256(manifest_content).hexdigest()
        == journal["target_manifest_sha256"]
    )
    if manifest_committed:
        for entry in journal["entries"]:
            move_stale_to_quarantine(entry)
        warn("previous committed backup transaction recovered")
        return True

    for entry in journal["entries"]:
        if retained_entry_exists(entry):
            raise PreflightError(
                "uncommitted transaction has quarantined bytes; manual recovery required"
            )
    warn("previous uncommitted backup transaction aborted without deletion")
    return True


destination_root.mkdir(parents=True, exist_ok=True)
if destination_root.is_symlink():
    raise SystemExit("destination exocortex root must not be a symlink")
try:
    destination_root_descriptor = os.open(
        destination_root,
        os.O_RDONLY
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_NOFOLLOW", 0),
    )
    if not stat.S_ISDIR(os.fstat(destination_root_descriptor).st_mode):
        raise PreflightError("destination exocortex root is not a directory")
    destination_root_stat = os.fstat(destination_root_descriptor)
    destination_root_identity = (
        destination_root_stat.st_dev,
        destination_root_stat.st_ino,
    )
except (OSError, PreflightError) as error:
    warn(f"destination root open failed ({error}); no files copied")
    raise SystemExit(1)


def verify_destination_root_path():
    try:
        current = os.lstat(destination_root)
    except OSError as error:
        raise PreflightError("destination root path changed during backup") from error
    if (
        stat.S_ISLNK(current.st_mode)
        or (current.st_dev, current.st_ino) != destination_root_identity
    ):
        raise PreflightError("destination root path changed during backup")

# Serialize cooperating backup processes. O_NOFOLLOW prevents a hostile lock
# symlink from redirecting the open; the canonical alias check runs before the
# lock file is created so case-insensitive targets are never opened by mistake.
try:
    preflight_destination_target(lock_path.name)
    lock_flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0)
    lock_descriptor = os.open(
        lock_path.name,
        lock_flags,
        0o600,
        dir_fd=destination_root_descriptor,
    )
    fcntl.flock(lock_descriptor, fcntl.LOCK_EX)
except (OSError, ValueError, PreflightError) as error:
    warn(f"backup lock failed ({error}); no files copied")
    raise SystemExit(1)

try:
    source_files, directory_identities, source_namespace = discover_sources()
    params_record = None
    if params_source is not None:
        params_link_identity, params_target_identity = capture_identity(params_source)
        if not stat.S_ISREG(params_target_identity[2]):
            raise PreflightError("params.yaml source is not a regular file")
        params_record = {
            "path": params_source,
            "link_identity": params_link_identity,
            "target_identity": params_target_identity,
        }
    previous_files = load_previous_manifest()
    active_journal = load_active_journal()
    recovery_paths = dict(previous_files)
    if active_journal is not None and active_journal["state"] == "planned":
        for entry in active_journal["entries"]:
            recovery_paths.setdefault(entry["path"], entry["sha256"])
    preflight_destination(source_namespace, recovery_paths)
    verify_source_tree(directory_identities)
    recovered_incomplete = recover_active_journal(active_journal)
except (OSError, UnicodeError, ValueError, PreflightError) as error:
    warn(f"backup preflight failed ({error}); no files copied")
    raise SystemExit(1)

try:
    write_precopy_journal()
    copied_files = {}
    for relative, record in sorted(source_files.items()):
        copied_hash = atomic_copy(record, relative)
        if copied_hash is None:
            raise PreflightError(f"current source was not copied: {relative}")
        copied_files[relative] = copied_hash

    # params.yaml is published while the inspected exocortex dirfd and backup
    # lock are still held. A path swap after the memory transaction therefore
    # cannot redirect this special root artefact outside the bound directory.
    if params_record is not None:
        if atomic_copy(params_record, "params.yaml") is None:
            raise PreflightError("params.yaml was not copied")
    verify_destination_root_path()

    second_files, second_directories, second_namespace = discover_sources()
    if (
        second_files != source_files
        or second_directories != directory_identities
        or second_namespace != source_namespace
    ):
        raise PreflightError("source tree snapshot changed after copy")
    verify_source_tree(second_directories)
    preflight_destination(second_namespace, recovery_paths)

    target_manifest = manifest_payload(copied_files)
    target_manifest_hash = hashlib.sha256(target_manifest).hexdigest()
    txid = uuid.uuid4().hex
    if recovered_incomplete:
        stale_entries = []
        warn("previous incomplete backup detected; stale deletion skipped once")
    else:
        stale_entries = build_stale_plan(previous_files, set(source_files), txid)
    write_planned_journal(txid, target_manifest_hash, stale_entries)
    atomic_write(manifest_path, target_manifest, 0o600)
    for stale_entry in stale_entries:
        move_stale_to_quarantine(stale_entry)
    preflight_destination(second_namespace, recovery_paths)
    verify_destination_root_path()
    clear_quarantine()
except (OSError, UnicodeError, ValueError, PreflightError) as error:
    warn(f"backup incomplete ({error}); quarantine marker retained")
    raise SystemExit(1)
raise SystemExit(0)
PYEOF
}

backup_day_rhythm_config() {
  local rhythm_src="$MEMORY_SRC/day-rhythm-config.yaml"
  local rhythm_dst="$EXOCORTEX_DST/day-rhythm-config.yaml"
  local action

  [ -f "$rhythm_src" ] || return 0
  if [ ! -e "$rhythm_dst" ] || [ -L "$rhythm_dst" ]; then
    atomic_copy_file "$rhythm_src" "$rhythm_dst" "day-rhythm-config.yaml"
    return
  fi
  if cmp -s "$rhythm_src" "$rhythm_dst"; then
    return 0
  fi
  if [ -z "$RESOLVED_PYTHON3" ]; then
    warn "  day-rhythm-config.yaml: байты различаются, но pyyaml недоступен — существующий бэкап сохранён"
    BACKUP_WARNING=true
    return 0
  fi

  if ! action=$("$RESOLVED_PYTHON3" - "$rhythm_src" "$rhythm_dst" <<'PYEOF'
import sys
import yaml


def calendar_ids(path):
    with open(path, encoding="utf-8") as stream:
        document = yaml.safe_load(stream) or {}
    if not isinstance(document, dict):
        return []
    if "calendar_ids" in document:
        return document.get("calendar_ids") or []
    day_open = document.get("day_open") or {}
    if not isinstance(day_open, dict):
        return []
    return day_open.get("calendar_ids") or []


source_ids = calendar_ids(sys.argv[1])
destination_ids = calendar_ids(sys.argv[2])
print("preserve" if not source_ids and destination_ids else "copy")
PYEOF
  ); then
    warn "  day-rhythm-config.yaml: YAML не разобран — существующий бэкап сохранён"
    BACKUP_WARNING=true
    return 0
  fi

  if [ "$action" = "preserve" ]; then
    warn "  day-rhythm-config.yaml: source calendar_ids пуст, destination непуст — бэкап сохранён; сверьте оба файла и перенесите нужные calendar_ids вручную"
    BACKUP_WARNING=true
    return 0
  fi
  atomic_copy_file "$rhythm_src" "$rhythm_dst" "day-rhythm-config.yaml"
}

# --- Шаг 1: Backup memory/ + CLAUDE.md → exocortex/ ---
do_backup() {
  log "Шаг 1/3: Backup memory/ → exocortex/"

  if [ ! -d "$MEMORY_SRC" ]; then
    err "Memory source not found: $MEMORY_SRC"
    return 1
  fi

  mkdir -p "$EXOCORTEX_DST"

  # Historical installs may contain exocortex/memory/, but the current backup
  # has no ownership ledger for those bytes. Preserve it: recursive cleanup
  # cannot prove either provenance or an unchanged receiver hash (#536).
  if [ -e "$EXOCORTEX_DST/memory" ] || [ -L "$EXOCORTEX_DST/memory" ]; then
    warn "  legacy exocortex/memory сохранён: нет ownership/hash-доказательства для удаления"
    BACKUP_WARNING=true
  fi

  # Mirror *.md/*.yaml/*.yml from auto-memory. Deletion is ownership-ledger
  # based: a disappeared source is pruned only while receiver bytes still
  # match the sha256 recorded by the previous successful backup (#536).
  # exocortex/ is a multi-writer destination: extensions/, fault-profile, hindsight,
  # and legacy decision logs are primary data written by other platform mechanisms.
  # Root-anchored protected paths are ownership boundaries, not copy masks.
  # CLAUDE.md/AGENTS.md, params.yaml and day-rhythm-config.yaml are excluded
  # from this owned set and copied by their dedicated contracts below. Source
  # file symlinks are dereferenced, matching the historical rsync -L contract;
  # destination symlinks are never followed.
  # Python stdlib handles the copy as well as the manifest so receiver-side
  # symlinks cannot redirect writes/deletes outside exocortex.
  sync_owned_memory_files || return 1

  # #380: rules may carry an explicitly legal USER-SPACE block. Mirror them to
  # a dedicated subtree so recovery never confuses platform rules with memory.
  if [ -d "$WORKSPACE_DIR/.claude/rules" ]; then
    mkdir -p "$EXOCORTEX_DST/rules"
    rsync -a --delete "$WORKSPACE_DIR/.claude/rules/" "$EXOCORTEX_DST/rules/"
  fi

  # day-rhythm is also a separate root artefact. Exact bytes win except for a
  # legacy safety case: an empty source calendar list must not erase a non-empty
  # destination list. No YAML parser means preserve rather than guess.
  backup_day_rhythm_config || return 1

  # issue #217: обратная подстановка $HOME -> {{HOME_DIR}} делает бэкап ОС-агностичным
  # (симметрично прямой подстановке в setup.sh и restore-from-exocortex.sh).
  if [ -f "$WORKSPACE_DIR/CLAUDE.md" ]; then
    atomic_instruction_backup \
      "$WORKSPACE_DIR/CLAUDE.md" "$EXOCORTEX_DST/CLAUDE.md" "CLAUDE.md" || return 1
  fi

  if [ -f "$WORKSPACE_DIR/AGENTS.md" ]; then
    atomic_instruction_backup \
      "$WORKSPACE_DIR/AGENTS.md" "$EXOCORTEX_DST/AGENTS.md" "AGENTS.md" || return 1
  fi

  local count
  count=$(find "$EXOCORTEX_DST" -maxdepth 1 -type f \( -name '*.md' -o -name '*.yaml' -o -name '*.yml' \) | wc -l | tr -d ' ')
  log "  Синхронизировано: $count файлов → $EXOCORTEX_DST/"
  if $BACKUP_WARNING; then
    return "$RC_BACKUP_WARNING"
  fi
}

# iwe_repo_dirs — печатает поддиректории с .git, дедуплицированные по реальному
# физическому пути (repo-symlink алиас иначе считается отдельным репозиторием
# наравне с оригиналом — двойной reindex одного источника, найдено 2026-07-17).
iwe_repo_dirs() {
  local repo real seen=""
  for repo in "$@"; do
    [ -d "$repo/.git" ] || continue
    real=$(cd -P "$repo" 2>/dev/null && pwd) || continue
    case " $seen " in
      *" $real "*) continue ;;
    esac
    seen="$seen $real"
    echo "$repo"
  done
}

# --- Шаг 2: Knowledge-MCP reindex ---
do_reindex() {
  log "Шаг 2/3: Knowledge-MCP reindex"

  if [ ! -x "$SELECTIVE_REINDEX" ]; then
    warn "  selective-reindex.sh не найден: $SELECTIVE_REINDEX — пропуск"
    return "$RC_STEP_SKIPPED"
  fi

  if [ -z "$RESOLVED_PYTHON3" ]; then
    warn "  reindex: пропущено — pyyaml не найден (см. предупреждение выше)"
    return "$RC_STEP_SKIPPED"
  fi

  # Маппинг dir→source+config из L2 (sources.json) и L4 (sources-personal.json)
  # Python резолвит path→git-root, чтобы связать dirname репо с source-именем.
  local dir_map
  dir_map=$("$RESOLVED_PYTHON3" - "$SOURCES_JSON" "$SOURCES_PERSONAL_JSON" << 'PYEOF'
import sys, json, os
for config_path in sys.argv[1:]:
    if not os.path.exists(config_path):
        continue
    for s in json.load(open(config_path)):
        resolved = os.path.expanduser(s["path"])
        while not os.path.isdir(os.path.join(resolved, ".git")) and resolved != "/":
            resolved = os.path.dirname(resolved)
        if resolved == "/":
            continue
        print(f"{os.path.basename(resolved)}\t{s['source']}\t{config_path}")
PYEOF
  ) || { warn "  Mapping build failed — пропуск reindex"; return 0; }

  # Определяем, какие Pack/DS были изменены сегодня
  local l2_sources="" l4_sources=""
  while IFS= read -r repo; do
    local repo_name
    repo_name=$(basename "$repo")
    local today_commits
    today_commits=$(git -C "$repo" log --since="today 00:00" --oneline --no-merges 2>/dev/null | wc -l | tr -d ' ')
    if [ "$today_commits" -gt 0 ]; then
      local match
      match=$(echo "$dir_map" | awk -F'\t' -v d="$repo_name" '$1==d {print $2"\t"$3; exit}')
      if [ -n "$match" ]; then
        local src cfg
        src=$(echo "$match" | cut -f1)
        cfg=$(echo "$match" | cut -f2)
        if [ "$cfg" = "$SOURCES_JSON" ]; then
          l2_sources="$l2_sources $src"
        else
          l4_sources="$l4_sources $src"
        fi
      else
        log "  ⚠ $repo_name: не в sources — пропуск"
      fi
    fi
  done < <(iwe_repo_dirs "$WORKSPACE_DIR"/PACK-* "$WORKSPACE_DIR"/DS-*)

  if [ -z "$l2_sources" ] && [ -z "$l4_sources" ]; then
    log "  Нет изменений в индексируемых источниках — пропуск reindex"
    return 0
  fi

  # Each call keeps its own exit code: under `set -e` a bare failing call would abort
  # do_reindex() before the next step ever runs, and collapsing both into one status
  # blocks the whole Day Close on a single failed branch (WP-7 02.08 — 31.07 and 01.08
  # stalled on a failed L4 while L2 had already indexed 3078/2116 docs).
  local l2_rc=0 l4_rc=0 ran=0 failed=0

  # Вызов 1: L2 источники (sources.json — дефолт selective-reindex)
  if [ -n "$l2_sources" ]; then
    log "  L2 источники:$l2_sources"
    ran=$((ran + 1))
    # shellcheck disable=SC2086
    "$SELECTIVE_REINDEX" $l2_sources || l2_rc=$?
    if [ "$l2_rc" -ne 0 ]; then
      failed=$((failed + 1))
      warn "  L2 reindex отказал (код $l2_rc)"
    fi
  fi

  # Вызов 2: L4 источники (sources-personal.json через SOURCES_CONFIG)
  if [ -n "$l4_sources" ]; then
    log "  L4 источники:$l4_sources"
    ran=$((ran + 1))
    # shellcheck disable=SC2086
    SOURCES_CONFIG="$SOURCES_PERSONAL_JSON" "$SELECTIVE_REINDEX" $l4_sources || l4_rc=$?
    if [ "$l4_rc" -ne 0 ]; then
      failed=$((failed + 1))
      warn "  L4 reindex отказал (код $l4_rc)"
    fi
  fi

  if [ "$failed" -eq 0 ]; then
    return 0
  elif [ "$failed" -lt "$ran" ]; then
    warn "  reindex: отказала часть веток ($failed из $ran) — Day Close продолжается"
    return "$RC_REINDEX_PARTIAL"
  else
    return 1
  fi
}

# --- Шаг 3: Linear sync ---
do_linear() {
  log "Шаг 3/3: Linear sync"

  if [ ! -x "$LINEAR_SYNC" ]; then
    warn "  linear-sync.sh не найден: $LINEAR_SYNC — пропуск"
    return "$RC_STEP_SKIPPED"
  fi

  "$LINEAR_SYNC"
}

# --- Шаг 4: Консолидация сессий дня (DAP1-B, WP-7) ---
do_session_consolidation() {
  log "Шаг 4/4: Консолидация сессий дня"

  if [ -z "$RESOLVED_PYTHON3" ]; then
    warn "  Консолидация сессий: пропущено — pyyaml не найден (см. предупреждение выше)"
    return "$RC_STEP_SKIPPED"
  fi

  local today
  today=$(date +%Y-%m-%d)
  local month_dir
  month_dir=$(date +%Y-%m)
  # issue #545: корень журналов — тем же контрактом, что писатель
  # (session-guard.sh): MC-sessions после миграции, legacy иначе.
  local sessions_base
  if ! sessions_base=$(iwe_sessions_dir); then
    warn "  IWE_SESSIONS_ROOT=${IWE_SESSIONS_ROOT:-} недоступен — консолидация читает legacy-путь"
    sessions_base="$DS_STRATEGY/sessions"
  fi
  local sessions_root="$sessions_base/$month_dir"
  local output_file="$DS_STRATEGY/current/sessions-today.md"

  if [ ! -d "$sessions_root" ]; then
    warn "  Папка $sessions_root не найдена — пропуск"
    return "$RC_STEP_SKIPPED"
  fi

  # Сканируем meta.yaml для сессий сегодняшнего дня
  local entries=()
  while IFS= read -r meta; do
    local session_dir
    session_dir=$(dirname "$meta")
    local session_id
    session_id=$(basename "$session_dir")

    # Читаем task_id и task_description из meta.yaml (python для YAML)
    local task_id task_desc start_time
    task_id=$("$RESOLVED_PYTHON3" -c "
import sys, yaml
with open('$meta') as f:
    d = yaml.safe_load(f)
print(d.get('task_id', '') or '')
" 2>/dev/null || echo "")
    task_desc=$("$RESOLVED_PYTHON3" -c "
import sys, yaml
with open('$meta') as f:
    d = yaml.safe_load(f)
desc = d.get('task_description', '') or ''
print(desc[:80] + ('...' if len(desc) > 80 else ''))
" 2>/dev/null || echo "")
    start_time=$("$RESOLVED_PYTHON3" -c "
import sys, yaml
with open('$meta') as f:
    d = yaml.safe_load(f)
t = str(d.get('start_time', '') or '')
print(t[11:16] if len(t) >= 16 else '')
" 2>/dev/null || echo "")

    # Только если task_id не пустой — WP-явная сессия
    if [ -n "$task_id" ]; then
      entries+=("| $start_time | $task_id | $task_desc |")
    fi
  done < <(find "$sessions_root" -maxdepth 2 -name "meta.yaml" 2>/dev/null \
    | while IFS= read -r f; do
        # Проверяем дату в meta.yaml
        date_val=$("$RESOLVED_PYTHON3" -c "
import yaml
with open('$f') as fh:
    d = yaml.safe_load(fh)
print(str(d.get('date','') or ''))
" 2>/dev/null || echo "")
        if [ "$date_val" = "$today" ]; then
          echo "$f"
        fi
      done | sort)

  mkdir -p "$(dirname "$output_file")"

  if [ ${#entries[@]} -eq 0 ]; then
    log "  Нет WP-сессий за $today — sessions-today.md не записан"
    return 0
  fi

  {
    echo "<!-- sessions-today: $today — auto-generated by day-close.sh -->"
    echo "## Сессии дня $today"
    echo ""
    echo "| Время | РП | Задача |"
    echo "|-------|----|--------|"
    for e in "${entries[@]}"; do
      echo "$e"
    done
    echo ""
  } > "$output_file"

  log "  Записано ${#entries[@]} сессий → $(basename "$output_file")"
}

# --- Лог ---
write_log() {
  local date_str
  date_str=$(date "+%Y-%m-%d %H:%M")
  mkdir -p "$(dirname "$LOG_FILE")"
  echo "$date_str | day-close | backup=$1 reindex=$2 linear=$3 sessions=$4" >> "$LOG_FILE"
}

# --- Main ---
main() {
  local do_all=true
  local run_backup=false
  local run_reindex=false
  local run_linear=false
  local run_sessions=false

  for arg in "$@"; do
    case "$arg" in
      --backup)   run_backup=true; do_all=false ;;
      --reindex)  run_reindex=true; do_all=false ;;
      --linear)   run_linear=true; do_all=false ;;
      --sessions) run_sessions=true; do_all=false ;;
      --help|-h)
        echo "Использование: day-close.sh [--backup] [--reindex] [--linear] [--sessions]"
        echo "  Без аргументов — все четыре шага"
        exit 0
        ;;
      *)
        err "Неизвестный аргумент: $arg"
        exit 1
        ;;
    esac
  done

  if $do_all; then
    run_backup=true
    run_reindex=true
    run_linear=true
    run_sessions=true
  fi

  log "=== Day Close (автоматические шаги) ==="

  local backup_status="skip" reindex_status="skip" linear_status="skip" sessions_status="skip"

  if $run_backup; then
    local backup_rc=0
    do_backup || backup_rc=$?
    case "$backup_rc" in
      0)                     backup_status="ok" ;;
      "$RC_BACKUP_WARNING") backup_status="warn" ;;
      *)                     backup_status="fail" ;;
    esac
  fi

  if $run_reindex; then
    local reindex_rc=0
    do_reindex || reindex_rc=$?
    case "$reindex_rc" in
      0)                     reindex_status="ok" ;;
      "$RC_REINDEX_PARTIAL") reindex_status="partial" ;;
      "$RC_STEP_SKIPPED")    reindex_status="skip" ;;
      *)                     reindex_status="fail" ;;
    esac
  fi

  # skip must not read as fail: a template install legitimately lacks the
  # optional components these steps need (#559 follow-up — cold review found
  # the RC_STEP_SKIPPED returns landed without this mapping, turning the old
  # false-ok into a false-FAIL with exit 1).
  if $run_linear; then
    local linear_rc=0
    do_linear || linear_rc=$?
    case "$linear_rc" in
      0)                  linear_status="ok" ;;
      "$RC_STEP_SKIPPED") linear_status="skip" ;;
      *)                  linear_status="fail" ;;
    esac
  fi

  if $run_sessions; then
    local sessions_rc=0
    do_session_consolidation || sessions_rc=$?
    case "$sessions_rc" in
      0)                  sessions_status="ok" ;;
      "$RC_STEP_SKIPPED") sessions_status="skip" ;;
      *)                  sessions_status="fail" ;;
    esac
  fi

  write_log "$backup_status" "$reindex_status" "$linear_status" "$sessions_status"

  log "=== Готово ==="
  log "  backup=$backup_status  reindex=$reindex_status  linear=$linear_status  sessions=$sessions_status"

  # A warning or partial reindex is an observable degraded success. A real
  # operation failure must reach the caller instead of being hidden by the
  # final logging command's zero exit status (#536).
  local final_status
  for final_status in "$backup_status" "$reindex_status" "$linear_status" "$sessions_status"; do
    [ "$final_status" = "fail" ] && return 1
  done
  return 0
}

main "$@"
