#!/usr/bin/env python3
"""Private, agent-neutral fault memory for IWE.

SQLite is the sole source of truth. Recording never emits a plaintext audit;
``export`` is the only command that materializes a complete Markdown snapshot.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import sqlite3
import stat
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from typing import Iterable, Mapping, Sequence


SUBJECT_KINDS = ("personality", "runtime", "system")
PROTOCOLS = ("open", "close", "day_close", "work", "all")
SEVERITIES = ("critical", "major", "minor")
SEVERITY_RANK = {"minor": 0, "major": 1, "critical": 2}
GOVERNANCE_NAME = re.compile(r"^(?!\.)[A-Za-z0-9._-]{1,64}$")
PROFILE_REL = Path("exocortex/agent-fault-profile")
DB_NAME = "iwe_memory.db"
IGNORE_BEGIN = "# BEGIN FMT agent-fault private data"
IGNORE_END = "# END FMT agent-fault private data"
IGNORE_CONTENT = f"""{IGNORE_BEGIN}
*
!.gitignore
{IGNORE_END}
"""
DECAY_DAYS = 30
REACTIVATION_BONUS = 2


class FaultProfileError(RuntimeError):
    """A safe, user-actionable fault-profile refusal."""


@dataclass(frozen=True)
class ProfilePaths:
    workspace: Path
    governance: Path
    profile: Path
    database: Path
    ignore: Path
    audit: Path
    export: Path


@dataclass(frozen=True)
class FaultRecord:
    """Immutable, subject-scoped fault data for trusted local consumers."""

    id: int
    content: str
    record_date: str | None
    fault_subtype: str | None
    occurrences_count: int
    severity: str
    status: str
    subject_kind: str
    subject_id: str


def _selected_env(env: Mapping[str, str], primary: str, legacy: str, default: str) -> str:
    return env.get(primary) or env.get(legacy) or default


def resolve_paths(env: Mapping[str, str] | None = None) -> ProfilePaths:
    """Resolve and validate the private profile without following data symlinks."""

    values = os.environ if env is None else env
    workspace_raw = _selected_env(
        values,
        "IWE_WORKSPACE",
        "WORKSPACE_DIR",
        str(Path.home() / "IWE"),
    ).strip()
    governance_name = _selected_env(
        values,
        "IWE_GOVERNANCE_REPO",
        "GOVERNANCE_REPO",
        "DS-strategy",
    ).strip()
    if not workspace_raw or "\x00" in workspace_raw:
        raise FaultProfileError("workspace path is empty or invalid")
    if not GOVERNANCE_NAME.fullmatch(governance_name) or governance_name.startswith("."):
        raise FaultProfileError(
            "IWE_GOVERNANCE_REPO must be one safe directory name "
            "([A-Za-z0-9._-], no leading dot, 1..64 characters)"
        )

    workspace_input = Path(workspace_raw).expanduser()
    if workspace_input.is_symlink():
        raise FaultProfileError(f"workspace symlink is not allowed: {workspace_input}")
    try:
        workspace = workspace_input.resolve(strict=True)
    except (OSError, RuntimeError) as exc:
        raise FaultProfileError(f"workspace is unavailable: {workspace_input}") from exc
    if not workspace.is_dir():
        raise FaultProfileError(f"workspace is not a directory: {workspace}")

    governance_input = workspace / governance_name
    if governance_input.is_symlink():
        raise FaultProfileError(f"governance repository symlink is not allowed: {governance_input}")
    try:
        governance = governance_input.resolve(strict=True)
    except (OSError, RuntimeError) as exc:
        raise FaultProfileError(f"governance repository is unavailable: {governance_input}") from exc
    if not governance.is_dir() or governance.parent != workspace:
        raise FaultProfileError("governance repository escaped the configured workspace")

    profile = governance / PROFILE_REL
    audit = profile / "audit"
    return ProfilePaths(
        workspace=workspace,
        governance=governance,
        profile=profile,
        database=profile / DB_NAME,
        ignore=profile / ".gitignore",
        audit=audit,
        export=audit / "faults.md",
    )


def _lstat_kind(path: Path) -> str:
    try:
        mode = path.lstat().st_mode
    except FileNotFoundError:
        return "missing"
    if stat.S_ISLNK(mode):
        return "symlink"
    if stat.S_ISDIR(mode):
        return "directory"
    if stat.S_ISREG(mode):
        return "file"
    return "other"


def _require_safe_directory(
    path: Path,
    *,
    create: bool,
    mode: int,
    harden_existing: bool = True,
) -> bool:
    kind = _lstat_kind(path)
    created = False
    if kind == "missing":
        if not create:
            return False
        try:
            path.mkdir(mode=mode)
            created = True
        except FileExistsError:
            pass
        kind = _lstat_kind(path)
    if kind != "directory":
        raise FaultProfileError(f"private path must be a real directory, not {kind}: {path}")
    if created or harden_existing:
        try:
            path.chmod(mode)
        except OSError as exc:
            raise FaultProfileError(f"cannot enforce private permissions on {path}") from exc
    return True


def _atomic_write(path: Path, content: str, mode: int) -> None:
    target_kind = _lstat_kind(path)
    if target_kind not in {"missing", "file"}:
        raise FaultProfileError(f"refusing unsafe output target ({target_kind}): {path}")
    fd, temporary_raw = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_raw)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            fd = -1
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        path.chmod(mode)
    finally:
        if fd >= 0:
            os.close(fd)
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass


def _ensure_ignore(paths: ProfilePaths) -> None:
    kind = _lstat_kind(paths.ignore)
    if kind not in {"missing", "file"}:
        raise FaultProfileError(
            f"refusing unsafe profile .gitignore ({kind}): {paths.ignore}"
        )
    existing = paths.ignore.read_text(encoding="utf-8") if kind == "file" else ""
    managed = re.compile(
        rf"(?:\n?){re.escape(IGNORE_BEGIN)}.*?{re.escape(IGNORE_END)}\n?",
        re.DOTALL,
    )
    preserved = managed.sub("\n", existing).rstrip()
    merged = f"{preserved}\n\n{IGNORE_CONTENT}" if preserved else IGNORE_CONTENT
    if existing != merged:
        _atomic_write(paths.ignore, merged, 0o600)
    else:
        paths.ignore.chmod(0o600)


def _ensure_profile(paths: ProfilePaths, *, create: bool) -> bool:
    exocortex = paths.governance / "exocortex"
    if not _require_safe_directory(
        exocortex,
        create=create,
        mode=0o755,
        harden_existing=False,
    ):
        return False
    if not _require_safe_directory(paths.profile, create=create, mode=0o700):
        return False
    _ensure_ignore(paths)
    return True


def _git_environment() -> dict[str, str]:
    environment = {
        "LC_ALL": "C",
        "LANG": "C",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": os.devnull,
        "GIT_TERMINAL_PROMPT": "0",
    }
    for name in ("PATH", "SYSTEMROOT", "WINDIR", "PATHEXT", "TMPDIR", "TMP", "TEMP"):
        if name in os.environ:
            environment[name] = os.environ[name]
    return environment


def _git_metadata_in_ancestry(start: Path) -> bool:
    current = start
    while True:
        try:
            (current / ".git").lstat()
        except FileNotFoundError:
            pass
        except OSError as exc:
            raise FaultProfileError(
                "cannot inspect Git metadata ancestry; refusing access"
            ) from exc
        else:
            return True
        if current.parent == current:
            return False
        current = current.parent


def _git_toplevel_from(start: Path) -> Path | None:
    try:
        result = subprocess.run(
            [
                "git",
                "-C",
                str(start),
                "rev-parse",
                "--show-toplevel",
            ],
            capture_output=True,
            check=False,
            timeout=5,
            env=_git_environment(),
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise FaultProfileError(
            "cannot locate the Git worktree for private-data checks; refusing access"
        ) from exc
    if result.returncode != 0:
        stderr = result.stderr.decode("utf-8", errors="replace")
        if "not a git repository" in stderr and not _git_metadata_in_ancestry(start):
            return None
        raise FaultProfileError(
            "cannot locate the Git worktree for private-data checks "
            f"(git rev-parse exit {result.returncode}); refusing access"
        )
    raw_root = result.stdout.decode("utf-8", errors="surrogateescape").rstrip("\n")
    if not raw_root or "\x00" in raw_root:
        raise FaultProfileError("Git returned an invalid worktree root; refusing access")
    try:
        root = Path(raw_root).resolve(strict=True)
    except (OSError, RuntimeError) as exc:
        raise FaultProfileError("Git worktree root is unavailable; refusing access") from exc
    if not root.is_dir():
        raise FaultProfileError("Git worktree root is not a directory; refusing access")
    return root


def _real_directory_exists(path: Path) -> bool:
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        return False
    except OSError as exc:
        raise FaultProfileError(f"cannot inspect potential Git directory: {path}") from exc
    return stat.S_ISDIR(metadata.st_mode)


def _relevant_git_roots(
    paths: ProfilePaths,
    nested_starts: Sequence[Path],
) -> tuple[Path, ...]:
    roots: list[Path] = []
    starts = (paths.governance, paths.workspace, *nested_starts)
    for start in starts:
        if not _real_directory_exists(start):
            continue
        root = _git_toplevel_from(start)
        if root is not None and root not in roots:
            roots.append(root)
    return tuple(roots)


def _git_ls_files_at_root(
    root: Path,
    pathspecs: Sequence[str],
) -> tuple[str, ...]:
    try:
        result = subprocess.run(
            [
                "git",
                "-C",
                str(root),
                "ls-files",
                "-z",
                "--full-name",
                "--",
                *pathspecs,
            ],
            capture_output=True,
            check=False,
            timeout=5,
            env=_git_environment(),
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise FaultProfileError(
            "cannot inspect the Git index for private data; refusing access"
        ) from exc
    if result.returncode != 0:
        raise FaultProfileError(
            "cannot inspect the Git index for private data "
            f"(git ls-files exit {result.returncode}); refusing access"
        )
    tracked = tuple(
        os.fsdecode(item) for item in result.stdout.split(b"\0") if item
    )
    return tracked


def _repo_relative(root: Path, candidate: Path) -> str:
    try:
        return candidate.relative_to(root).as_posix()
    except ValueError as exc:
        raise FaultProfileError(
            f"private path escaped the detected Git worktree: {candidate}"
        ) from exc


def _tracked_candidates(
    paths: ProfilePaths,
    candidates: Sequence[Path],
    nested_starts: Sequence[Path],
) -> tuple[tuple[Path, str], ...]:
    tracked: list[tuple[Path, str]] = []
    for root in _relevant_git_roots(paths, nested_starts):
        relatives = tuple(_repo_relative(root, candidate) for candidate in candidates)
        literal_pathspecs = tuple(
            f":(top,icase,literal){relative}" for relative in relatives
        )
        tracked.extend(
            (root, relative)
            for relative in _git_ls_files_at_root(root, literal_pathspecs)
        )
    return tuple(tracked)


DB_RELATIVE = (PROFILE_REL / DB_NAME).as_posix()
SQLITE_PRIVATE_SUFFIXES = ("", "-wal", "-shm", "-journal")


def _database_files(paths: ProfilePaths) -> tuple[Path, ...]:
    return tuple(Path(f"{paths.database}{suffix}") for suffix in SQLITE_PRIVATE_SUFFIXES)


def _refuse_tracked_database(paths: ProfilePaths) -> None:
    tracked = _tracked_candidates(
        paths,
        _database_files(paths),
        (paths.profile.parent, paths.profile),
    )
    if tracked:
        commands: list[str] = []
        for root in dict.fromkeys(root for root, _relative in tracked):
            relatives = [relative for item_root, relative in tracked if item_root == root]
            removal = " ".join(shlex.quote(relative) for relative in relatives)
            commands.append(
                f"git -C {shlex.quote(str(root))} rm --cached -- {removal}"
            )
        raise FaultProfileError(
            f"{Path(tracked[0][1]).name} is tracked by Git; "
            "refusing to read or write private SQLite data. "
            "Review it, then run: "
            + " ; ".join(commands)
        )


def _refuse_tracked_export_outputs(paths: ProfilePaths) -> None:
    tracked: list[tuple[Path, str]] = []
    roots = _relevant_git_roots(
        paths,
        (paths.profile.parent, paths.profile, paths.audit),
    )
    for root in roots:
        audit_relative = _repo_relative(root, paths.audit)
        audit_pattern = (
            "faults*.md"
            if audit_relative in ("", ".")
            else f"{audit_relative}/faults*.md"
        )
        tracked.extend(
            (root, relative)
            for relative in _git_ls_files_at_root(
                root,
                (f":(top,icase,glob){audit_pattern}",),
            )
        )
    if tracked:
        names = ", ".join(Path(relative).name for _root, relative in tracked)
        raise FaultProfileError(
            f"private fault export is tracked by Git ({names}); refusing export. "
            "Remove every faults*.md path from the Git index before retrying"
        )


def _harden_database_files(paths: ProfilePaths) -> None:
    _validate_existing_database_files(paths)
    for path in _database_files(paths):
        kind = _lstat_kind(path)
        if kind == "missing":
            continue
        if kind != "file":
            raise FaultProfileError(
                f"private SQLite path must be a regular file, not {kind}: {path}"
            )
        try:
            path.chmod(0o600)
        except FileNotFoundError:
            # SQLite may remove a rollback journal between lstat() and chmod()
            # after another process commits. Its disappearance is the desired
            # end state; every surviving file is rechecked on close.
            continue
        except OSError as exc:
            raise FaultProfileError(
                f"cannot enforce 0600 on private SQLite file: {path}"
            ) from exc


def _validate_existing_database_files(paths: ProfilePaths) -> None:
    for path in _database_files(paths):
        try:
            metadata = path.lstat()
        except FileNotFoundError:
            continue
        except OSError as exc:
            raise FaultProfileError(f"cannot inspect private SQLite path: {path}") from exc
        if not stat.S_ISREG(metadata.st_mode):
            kind = _lstat_kind(path)
            raise FaultProfileError(
                f"private SQLite path must be a regular file, not {kind}: {path}"
            )
        if metadata.st_nlink == 0 and path != paths.database:
            # A concurrent SQLite commit can expose an already-unlinked
            # rollback journal briefly through a racing lookup. It has no
            # surviving directory alias and cannot mutate a tracked hardlink.
            continue
        if metadata.st_nlink != 1:
            raise FaultProfileError(
                f"private SQLite path has {metadata.st_nlink} hard links; "
                f"refusing access: {path}"
            )


def _prepare_database(paths: ProfilePaths, *, create: bool) -> bool:
    # The Git index is authoritative even when the worktree copy (or the whole
    # profile directory) was deleted. Probe it before chmod, .gitignore repair,
    # directory creation, or any other local mutation so a tracked private DB
    # always fails closed without changing either filesystem or index state.
    _refuse_tracked_database(paths)
    _validate_existing_database_files(paths)
    if not _ensure_profile(paths, create=create):
        return False
    kind = _lstat_kind(paths.database)
    if kind == "missing":
        if not create:
            return False
        flags = os.O_RDWR | os.O_CREAT | os.O_EXCL
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        try:
            fd = os.open(paths.database, flags, 0o600)
        except FileExistsError:
            # Another local writer may have won the same lazy-create race.
            # Re-run the index privacy gate and validate its filesystem result
            # instead of turning a benign winner into a failed record.
            _refuse_tracked_database(paths)
            _validate_existing_database_files(paths)
            kind = _lstat_kind(paths.database)
        except OSError as exc:
            raise FaultProfileError(f"cannot create private database: {paths.database}") from exc
        else:
            try:
                os.fchmod(fd, 0o600)
            finally:
                os.close(fd)
            kind = _lstat_kind(paths.database)
    if kind != "file":
        raise FaultProfileError(f"private database must be a regular file, not {kind}")
    _harden_database_files(paths)
    return True


def _connect(paths: ProfilePaths, *, create: bool) -> sqlite3.Connection | None:
    if not _prepare_database(paths, create=create):
        return None
    # 30s (было 5s): десятки параллельных писателей (хуки нескольких агентов
    # одновременно) на нагруженном хосте периодически превышали 5s очереди на
    # блокировке — "database is locked" и в проде, и в CI (issue-tests 533,
    # мерцал на каждом втором прогоне). busy_timeout остаётся ограничением
    # ожидания, не бесконечным зависанием.
    connection = sqlite3.connect(paths.database, timeout=30)
    connection.row_factory = sqlite3.Row
    connection.execute("PRAGMA busy_timeout=30000")
    try:
        _migrate(connection)
        _harden_database_files(paths)
    except Exception:
        connection.close()
        _harden_database_files(paths)
        raise
    return connection


def _close(connection: sqlite3.Connection, paths: ProfilePaths) -> None:
    connection.close()
    _harden_database_files(paths)


def _parse_context_object(raw_context: object) -> dict[str, object]:
    if not isinstance(raw_context, (str, bytes, bytearray)):
        return {}
    try:
        parsed = json.loads(raw_context)
    except (TypeError, UnicodeDecodeError, json.JSONDecodeError):
        return {}
    return parsed if isinstance(parsed, dict) else {}


def _context_protocols(context: Mapping[str, object]) -> set[str]:
    raw_protocols = context.get("protocols")
    if isinstance(raw_protocols, str):
        protocols = {raw_protocols} if raw_protocols in PROTOCOLS else set()
    elif isinstance(raw_protocols, Sequence):
        protocols = {
            protocol
            for protocol in raw_protocols
            if isinstance(protocol, str) and protocol in PROTOCOLS
        }
    else:
        protocols = set()
    return protocols or {"work"}


def _legacy_positive_count(value: object) -> int | None:
    if isinstance(value, bool) or not isinstance(value, int):
        return None
    return value if 1 <= value <= 1_000_000 else None


def _legacy_enum(value: object, allowed: Sequence[str]) -> str | None:
    if not isinstance(value, str):
        return None
    normalized = value.strip().lower()
    return normalized if normalized in allowed else None


def _legacy_severity(value: object) -> str | None:
    if not isinstance(value, str):
        return None
    normalized = value.strip().lower()
    normalized = {"high": "major", "medium": "minor"}.get(normalized, normalized)
    return normalized if normalized in SEVERITIES else None


def _stronger_severity(*values: object) -> str:
    normalized = [severity for value in values if (severity := _legacy_severity(value))]
    return max(normalized, key=SEVERITY_RANK.__getitem__) if normalized else "minor"


def _legacy_trust(value: object) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    normalized = float(value)
    return normalized if 0.0 <= normalized <= 1.0 else None


def _legacy_citation(value: object) -> str | None:
    if not isinstance(value, str):
        return None
    if not value.strip() or len(value) > 20_000:
        return None
    return value


def _legacy_timestamp(value: object) -> tuple[str, str] | None:
    if not isinstance(value, str):
        return None
    candidate = value.strip()
    if not candidate or len(candidate) > 64:
        return None
    parse_value = f"{candidate[:-1]}+00:00" if candidate.endswith("Z") else candidate
    try:
        parsed = datetime.fromisoformat(parse_value)
    except (TypeError, ValueError, OverflowError):
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    try:
        normalized = parsed.astimezone(timezone.utc)
    except (ValueError, OverflowError):
        return None
    return normalized.isoformat(), normalized.date().isoformat()


def _legacy_date(value: object) -> str | None:
    if not isinstance(value, str):
        return None
    candidate = value.strip()
    if len(candidate) != 10:
        return None
    try:
        parsed = date.fromisoformat(candidate)
    except ValueError:
        return None
    return candidate if parsed.isoformat() == candidate else None


def _legacy_subject(kind: object, subject_id: object) -> tuple[str, str] | None:
    if not isinstance(kind, str) or not isinstance(subject_id, str):
        return None
    try:
        return _validate_subject(kind.strip().lower(), subject_id)
    except FaultProfileError:
        return None


def _backfill_added_legacy_columns(
    connection: sqlite3.Connection,
    added_columns: set[str],
) -> None:
    semantic_columns = {
        "occurrences_count",
        "severity",
        "status",
        "last_occurrence",
        "record_date",
        "personality_id",
        "subject_kind",
        "subject_id",
        "source_citation",
    }
    writable_columns = added_columns & semantic_columns
    if not writable_columns:
        return

    rows = connection.execute(
        """SELECT id, context, personality_id, subject_kind, subject_id,
                  last_occurrence, record_date
             FROM facts"""
    ).fetchall()
    for row in rows:
        context = _parse_context_object(row["context"])
        values: dict[str, object] = {}

        count = _legacy_positive_count(context.get("occurrences"))
        if count is not None and "occurrences_count" in writable_columns:
            values["occurrences_count"] = count

        severity = _legacy_severity(context.get("severity"))
        if severity is not None and "severity" in writable_columns:
            values["severity"] = severity

        status = _legacy_enum(context.get("status"), ("active", "dormant"))
        if status is not None and "status" in writable_columns:
            values["status"] = status

        citation = _legacy_citation(context.get("source_citation"))
        if citation is not None and "source_citation" in writable_columns:
            values["source_citation"] = citation

        occurrence = None
        for key in ("last_update", "last_sync"):
            occurrence = _legacy_timestamp(context.get(key))
            if occurrence is not None:
                break
        if occurrence is not None and "last_occurrence" in writable_columns:
            values["last_occurrence"] = occurrence[0]

        record_date = None
        for key in ("created", "date"):
            record_date = _legacy_date(context.get(key))
            if record_date is not None:
                break
        occurrence_for_date = occurrence or _legacy_timestamp(row["last_occurrence"])
        if record_date is None and occurrence_for_date is not None:
            record_date = occurrence_for_date[1]
        if record_date is not None and "record_date" in writable_columns:
            values["record_date"] = record_date

        context_personality = context.get("personality_id")
        personality = _legacy_subject("personality", context_personality)
        if personality is not None and "personality_id" in writable_columns:
            values["personality_id"] = personality[1]

        explicit_subject = _legacy_subject(
            context.get("subject_kind"), context.get("subject_id")
        )
        fallback_personality = values.get("personality_id") or row["personality_id"]
        fallback_subject = _legacy_subject("personality", fallback_personality)
        subject = explicit_subject or fallback_subject
        if subject is not None:
            if "subject_kind" in writable_columns:
                # Never create a mismatched pair when subject_id pre-existed.
                existing_id = row["subject_id"]
                if "subject_id" in writable_columns or existing_id == subject[1]:
                    values["subject_kind"] = subject[0]
            if "subject_id" in writable_columns:
                # Never create a mismatched pair when subject_kind pre-existed.
                existing_kind = row["subject_kind"]
                if "subject_kind" in writable_columns or existing_kind == subject[0]:
                    values["subject_id"] = subject[1]

        if not values:
            continue
        assignments = ", ".join(f"{column}=?" for column in values)
        connection.execute(
            f"UPDATE facts SET {assignments} WHERE id=?",
            (*values.values(), row["id"]),
        )


def _migrate(connection: sqlite3.Connection) -> None:
    connection.execute("BEGIN IMMEDIATE")
    try:
        connection.execute(
            """
            CREATE TABLE IF NOT EXISTS facts (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                fact_type TEXT NOT NULL,
                content TEXT NOT NULL,
                context TEXT,
                trust_score REAL DEFAULT 0.5,
                created_at TEXT DEFAULT CURRENT_TIMESTAMP,
                session_id TEXT,
                status TEXT DEFAULT 'active',
                last_occurrence TEXT,
                occurrences_count INTEGER DEFAULT 1,
                severity TEXT DEFAULT 'major',
                record_date TEXT,
                fault_subtype TEXT,
                personality_id TEXT,
                subject_kind TEXT,
                subject_id TEXT,
                source_citation TEXT
            )
            """
        )
        existing = {
            row["name"]
            for row in connection.execute("PRAGMA table_info(facts)").fetchall()
        }
        migrations = {
            "status": "ALTER TABLE facts ADD COLUMN status TEXT DEFAULT 'active'",
            "last_occurrence": "ALTER TABLE facts ADD COLUMN last_occurrence TEXT",
            "occurrences_count": (
                "ALTER TABLE facts ADD COLUMN occurrences_count INTEGER DEFAULT 1"
            ),
            "severity": "ALTER TABLE facts ADD COLUMN severity TEXT DEFAULT 'major'",
            "record_date": "ALTER TABLE facts ADD COLUMN record_date TEXT",
            "fault_subtype": "ALTER TABLE facts ADD COLUMN fault_subtype TEXT",
            "personality_id": "ALTER TABLE facts ADD COLUMN personality_id TEXT",
            "subject_kind": "ALTER TABLE facts ADD COLUMN subject_kind TEXT",
            "subject_id": "ALTER TABLE facts ADD COLUMN subject_id TEXT",
            "source_citation": "ALTER TABLE facts ADD COLUMN source_citation TEXT",
        }
        added_columns: set[str] = set()
        for column, statement in migrations.items():
            if column not in existing:
                connection.execute(statement)
                added_columns.add(column)
        _backfill_added_legacy_columns(connection, added_columns)
        connection.execute(
            """
            CREATE TABLE IF NOT EXISTS feedback (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                fact_id INTEGER,
                helpful INTEGER,
                created_at TEXT DEFAULT CURRENT_TIMESTAMP,
                FOREIGN KEY (fact_id) REFERENCES facts(id)
            )
            """
        )
    except Exception:
        connection.rollback()
        raise
    connection.commit()


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _today() -> str:
    return date.today().isoformat()


def _join_words(words: Sequence[str] | None, name: str, *, required: bool) -> str:
    value = " ".join(words or ()).strip()
    if required and not value:
        raise FaultProfileError(f"{name} must not be empty")
    if len(value) > 20_000:
        raise FaultProfileError(f"{name} is too long")
    return value


def _validate_subject(kind: str, subject_id: str) -> tuple[str, str]:
    value = subject_id.strip()
    if kind not in SUBJECT_KINDS or not value:
        raise FaultProfileError("subject-kind and non-empty subject-id are required")
    if len(value) > 256 or any(ord(character) < 32 for character in value):
        raise FaultProfileError("subject-id is invalid")
    return kind, value


def _post_m15_practiced_fact(paths: ProfilePaths, fault: str) -> None:
    """WP-522 (раздел М, пир-сессия 2026-08-31-30): за завершённую запись
    косяка агента (М15 «зафиксировал инцидент или паттерн ошибки в журнале»)
    отчитаться в чек-лист участника экосистемы — best-effort, не влияет на
    уже сохранённую в SQLite запись косяка (вызывается ПОСЛЕ commit).
    Специфично для персонального проекта этого пилота (writer живёт в
    governance-репо, не в этом платформенном шаблоне) — молча пропустить,
    если writer не установлен, вместо ошибки для остальных пользователей IWE."""
    writer = paths.governance / "scripts" / "post-culture-fact.py"
    if not writer.is_file():
        return
    try:
        # Короткий таймаут (не 10с, как у самого writer'а — код-ревью 31.08,
        # High): запись косяка не должна заметно виснуть на медленной сети
        # ради best-effort побочного отчёта.
        subprocess.run(
            [sys.executable, str(writer), "--element", "M15", "--mode", "record", "--evidence", fault],
            timeout=3,
            check=False,
        )
    except subprocess.TimeoutExpired:
        # Code review 31.08 (Critical): `str(TimeoutExpired)` включает полный
        # cmd, а значит и `fault` (может нести чувствительные детали
        # инцидента) — логировать только тип и таймаут, не текст исключения.
        print("culture_element_practiced (M15): writer call timed out", file=sys.stderr)
    except (OSError, subprocess.SubprocessError) as e:
        print(f"culture_element_practiced (M15): writer call failed: {type(e).__name__}", file=sys.stderr)


def record_fault(paths: ProfilePaths, args: argparse.Namespace) -> None:
    fault = _join_words(args.fault, "fault", required=True)
    citation = _join_words(args.source_citation, "source-citation", required=False)
    subject_kind, subject_id = _validate_subject(args.subject_kind, args.subject_id)
    connection = _connect(paths, create=True)
    assert connection is not None
    now = _now()
    today = _today()
    session_id = args.session or os.environ.get("IWE_SESSION_ID") or f"sess-{today}"
    try:
        connection.execute("BEGIN IMMEDIATE")
        row = connection.execute(
            """
            SELECT id, trust_score, occurrences_count, status, context,
                   source_citation, fault_subtype
              FROM facts
             WHERE fact_type='agent_fault' AND content=?
               AND subject_kind=? AND subject_id=?
            """,
            (fault, subject_kind, subject_id),
        ).fetchone()
        if row:
            old_count = _legacy_positive_count(row["occurrences_count"]) or 1
            increment = REACTIVATION_BONUS if row["status"] == "dormant" else 1
            count = old_count + increment
            trust = min(0.95, 0.5 + 0.1 * count)
            context = _parse_context_object(row["context"])
            protocols = _context_protocols(context)
            protocols.add(args.protocol)
            context.update(
                {
                    "fault_text": fault,
                    "short_content": fault[:120],
                    "protocols": sorted(protocols),
                    "severity": args.severity,
                    "occurrences": count,
                    "last_update": now,
                    "subject_kind": subject_kind,
                    "subject_id": subject_id,
                }
            )
            if args.fault_subtype is not None:
                context["fault_subtype"] = args.fault_subtype
            stored_citation = (
                citation
                or _legacy_citation(row["source_citation"])
                or _legacy_citation(context.get("source_citation"))
                or ""
            )
            if stored_citation:
                context["source_citation"] = stored_citation
            connection.execute(
                """
                UPDATE facts
                   SET trust_score=?, occurrences_count=?, status='active',
                       last_occurrence=?, record_date=?, session_id=?, context=?,
                       severity=?, fault_subtype=?, subject_kind=?, subject_id=?,
                       source_citation=?
                 WHERE id=?
                """,
                (
                    trust,
                    count,
                    now,
                    today,
                    session_id,
                    json.dumps(context, ensure_ascii=False),
                    args.severity,
                    args.fault_subtype
                    if args.fault_subtype is not None
                    else row["fault_subtype"],
                    subject_kind,
                    subject_id,
                    stored_citation or None,
                    row["id"],
                ),
            )
            action = "updated"
        else:
            count = 1
            context = {
                "fault_text": fault,
                "short_content": fault[:120],
                "protocols": [args.protocol],
                "severity": args.severity,
                "occurrences": count,
                "created": today,
                "subject_kind": subject_kind,
                "subject_id": subject_id,
            }
            if args.fault_subtype is not None:
                context["fault_subtype"] = args.fault_subtype
            if citation:
                context["source_citation"] = citation
            connection.execute(
                """
                INSERT INTO facts (
                    fact_type, content, context, trust_score, session_id, status,
                    last_occurrence, occurrences_count, severity, record_date,
                    fault_subtype, subject_kind, subject_id, source_citation
                ) VALUES (?, ?, ?, 0.6, ?, 'active', ?, 1, ?, ?, ?, ?, ?, ?)
                """,
                (
                    "agent_fault",
                    fault,
                    json.dumps(context, ensure_ascii=False),
                    session_id,
                    now,
                    args.severity,
                    today,
                    args.fault_subtype,
                    subject_kind,
                    subject_id,
                    citation or None,
                ),
            )
            action = "created"
        connection.commit()
    except Exception:
        connection.rollback()
        raise
    finally:
        _close(connection, paths)
    _post_m15_practiced_fact(paths, fault)
    print(f"OK: fault {action} ({subject_kind}:{subject_id}, n={count})")


def _severity(value: object) -> str:
    normalized = str(value or "major").lower()
    return {"high": "major", "medium": "minor"}.get(normalized, normalized)


def _read_api_since_date(value: str | date | datetime | None) -> str | None:
    if value is None:
        return None
    if isinstance(value, datetime):
        parsed_timestamp = _legacy_timestamp(value.isoformat())
        if parsed_timestamp is not None:
            return parsed_timestamp[1]
    elif isinstance(value, date):
        return value.isoformat()
    elif isinstance(value, str):
        parsed_date = _legacy_date(value)
        if parsed_date is not None:
            return parsed_date
        parsed_timestamp = _legacy_timestamp(value)
        if parsed_timestamp is not None:
            return parsed_timestamp[1]
    raise FaultProfileError("since_date must be a valid ISO date or timestamp")


def _read_api_subtype(value: str | None, name: str) -> str | None:
    if value is None:
        return None
    normalized = value.strip()
    if (
        not normalized
        or len(normalized) > 256
        or any(ord(character) < 32 for character in normalized)
    ):
        raise FaultProfileError(f"{name} is invalid")
    return normalized


def read_faults(
    *,
    subject_kind: str,
    subject_id: str,
    since_date: str | date | datetime | None = None,
    fault_subtype: str | None = None,
    exclude_fault_subtype: str | None = None,
    env: Mapping[str, str] | None = None,
) -> tuple[FaultRecord, ...]:
    """Read immutable fault rows for exactly one subject without creating a DB."""

    subject_kind, subject_id = _validate_subject(subject_kind, subject_id)
    normalized_since = _read_api_since_date(since_date)
    included_subtype = _read_api_subtype(fault_subtype, "fault_subtype")
    excluded_subtype = _read_api_subtype(
        exclude_fault_subtype,
        "exclude_fault_subtype",
    )
    if included_subtype is not None and excluded_subtype is not None:
        raise FaultProfileError(
            "fault_subtype and exclude_fault_subtype are mutually exclusive"
        )

    clauses = [
        "fact_type='agent_fault'",
        "subject_kind=?",
        "subject_id=?",
    ]
    params: list[object] = [subject_kind, subject_id]
    if normalized_since is not None:
        clauses.append(
            "COALESCE(julianday(record_date), julianday(last_occurrence), "
            "julianday(created_at)) >= julianday(?)"
        )
        params.append(normalized_since)
    if included_subtype is not None:
        clauses.append("fault_subtype=?")
        params.append(included_subtype)
    elif excluded_subtype is not None:
        clauses.append("COALESCE(fault_subtype, '') != ?")
        params.append(excluded_subtype)

    paths = resolve_paths(env)
    connection = _connect(paths, create=False)
    if connection is None:
        return ()
    try:
        rows = connection.execute(
            f"""SELECT id, content, record_date, last_occurrence, created_at,
                       fault_subtype, occurrences_count, severity, status,
                       subject_kind, subject_id
                  FROM facts
                 WHERE {' AND '.join(clauses)}
                 ORDER BY COALESCE(julianday(record_date),
                                   julianday(last_occurrence),
                                   julianday(created_at)) DESC,
                          id DESC""",
            params,
        ).fetchall()
    finally:
        _close(connection, paths)

    records: list[FaultRecord] = []
    for row in rows:
        normalized_record_date = _legacy_date(row["record_date"])
        if normalized_record_date is None:
            timestamp = _legacy_timestamp(row["last_occurrence"])
            normalized_record_date = timestamp[1] if timestamp is not None else None
        records.append(
            FaultRecord(
                id=int(row["id"]),
                content=str(row["content"]),
                record_date=normalized_record_date,
                fault_subtype=(
                    str(row["fault_subtype"])
                    if row["fault_subtype"] is not None
                    else None
                ),
                occurrences_count=(
                    _legacy_positive_count(row["occurrences_count"]) or 1
                ),
                severity=_severity(row["severity"]),
                status=str(row["status"] or "active"),
                subject_kind=str(row["subject_kind"]),
                subject_id=str(row["subject_id"]),
            )
        )
    return tuple(records)


def remind(paths: ProfilePaths, args: argparse.Namespace) -> None:
    subject_kind, subject_id = _validate_subject(args.subject_kind, args.subject_id)
    if args.limit < 1 or args.limit > 100:
        raise FaultProfileError("limit must be between 1 and 100")
    connection = _connect(paths, create=False)
    if connection is None:
        print("<!-- iwe_memory.db not found -->")
        return
    try:
        rows = connection.execute(
            """
            SELECT id, content, context, trust_score, severity, occurrences_count
              FROM facts
             WHERE fact_type='agent_fault'
               AND COALESCE(status, 'active')='active'
               AND subject_kind=? AND subject_id=?
            """,
            (subject_kind, subject_id),
        ).fetchall()
    finally:
        _close(connection, paths)

    keywords = [word.lower() for word in args.context.split() if len(word) > 2]
    candidates: list[tuple[int, float, int, str, str, int]] = []
    for row in rows:
        context = _parse_context_object(row["context"])
        protocols = _context_protocols(context)
        if args.protocol == "all":
            protocol_rank = 0
        elif args.protocol in protocols or "all" in protocols:
            protocol_rank = 0
        elif "work" in protocols:
            protocol_rank = 1
        else:
            continue
        display = str(context.get("short_content") or row["content"])
        boost = sum(keyword in display.lower() for keyword in keywords) * 0.3
        candidates.append(
            (
                protocol_rank,
                -(float(row["trust_score"] or 0.5) + boost),
                -int(row["id"]),
                display,
                _severity(row["severity"] or context.get("severity")),
                _legacy_positive_count(row["occurrences_count"])
                or _legacy_positive_count(context.get("occurrences"))
                or 1,
            )
        )
    candidates.sort()
    selected = candidates[: args.limit]
    if not selected:
        print(f"<!-- No active reminders for {subject_kind}:{subject_id} -->")
        return
    for _rank, negative_trust, _negative_id, display, severity, count in selected:
        trust = -negative_trust
        marker = "🔴" if trust >= 0.8 else "🟡" if trust >= 0.65 else "🟢"
        print(f"{marker} [{severity.upper()} | n={count}] {display}")


def escalation_check(paths: ProfilePaths, args: argparse.Namespace) -> None:
    if args.threshold < 1:
        raise FaultProfileError("threshold must be greater than zero")
    if bool(args.subject_kind) != bool(args.subject_id):
        raise FaultProfileError(
            "escalation-check subject-kind and subject-id must be supplied together"
        )
    where = (
        "fact_type='agent_fault' "
        "AND COALESCE(status, 'active')='active' "
        "AND COALESCE(occurrences_count, 1) >= ?"
    )
    params: list[object] = [args.threshold]
    if args.subject_kind:
        subject_kind, subject_id = _validate_subject(
            args.subject_kind,
            args.subject_id,
        )
        where += " AND subject_kind=? AND subject_id=?"
        params.extend((subject_kind, subject_id))

    connection = _connect(paths, create=False)
    if connection is None:
        print(f"No active faults with occurrences >= {args.threshold}")
        return
    try:
        rows = connection.execute(
            f"""SELECT id, content, context, trust_score, severity,
                       occurrences_count
                  FROM facts
                 WHERE {where}
                 ORDER BY COALESCE(occurrences_count, 1) DESC,
                          COALESCE(trust_score, 0.5) DESC, id DESC""",
            params,
        ).fetchall()
    finally:
        _close(connection, paths)

    if not rows:
        print(f"No active faults with occurrences >= {args.threshold}")
        return
    print(f"Agent Fault Escalation (occurrences >= {args.threshold}):")
    for row in rows:
        context = _parse_context_object(row["context"])
        display = str(context.get("short_content") or row["content"])
        count = (
            _legacy_positive_count(row["occurrences_count"])
            or _legacy_positive_count(context.get("occurrences"))
            or 1
        )
        severity = _severity(row["severity"] or context.get("severity"))
        marker = "🔴" if severity == "critical" else "🟡" if severity == "major" else "🟢"
        print(f"{marker} [{severity.upper()} | n={count}] {display[:100]}")


def decay(paths: ProfilePaths) -> None:
    connection = _connect(paths, create=False)
    if connection is None:
        print("OK: no database to decay")
        return
    cutoff = (datetime.now(timezone.utc) - timedelta(days=DECAY_DAYS)).isoformat()
    try:
        connection.execute("BEGIN IMMEDIATE")
        cursor = connection.execute(
            """
            UPDATE facts SET status='dormant'
             WHERE fact_type='agent_fault' AND COALESCE(status, 'active')='active'
               AND COALESCE(
                       julianday(last_occurrence),
                       julianday(created_at)
                   ) < julianday(?)
            """,
            (cutoff,),
        )
        connection.commit()
        count = cursor.rowcount
    except Exception:
        connection.rollback()
        raise
    finally:
        _close(connection, paths)
    print(f"OK: {count} fault(s) marked dormant")


def stats(paths: ProfilePaths, args: argparse.Namespace) -> None:
    if bool(args.subject_kind) != bool(args.subject_id):
        raise FaultProfileError("stats subject-kind and subject-id must be supplied together")
    connection = _connect(paths, create=False)
    if connection is None:
        print("agent faults: 0")
        return
    where = "WHERE fact_type='agent_fault'"
    params: tuple[object, ...] = ()
    if args.subject_kind:
        subject_kind, subject_id = _validate_subject(args.subject_kind, args.subject_id)
        where += " AND subject_kind=? AND subject_id=?"
        params = (subject_kind, subject_id)
    try:
        rows = connection.execute(
            f"""SELECT COALESCE(status, 'active') AS state,
                       CASE LOWER(COALESCE(severity, 'major'))
                           WHEN 'high' THEN 'major'
                           WHEN 'medium' THEN 'minor'
                           ELSE LOWER(COALESCE(severity, 'major'))
                       END AS normalized_severity,
                       COUNT(*) AS count
                  FROM facts {where}
                 GROUP BY state, normalized_severity
                 ORDER BY state, normalized_severity""",
            params,
        ).fetchall()
    finally:
        _close(connection, paths)
    if not rows:
        print("agent faults: 0")
    for row in rows:
        print(f"{row['state']}/{row['normalized_severity']}: {row['count']}")


def remove_test(paths: ProfilePaths, args: argparse.Namespace) -> None:
    subject_kind, subject_id = _validate_subject(args.subject_kind, args.subject_id)
    if not args.session.startswith("test-"):
        raise FaultProfileError("remove-test accepts only test-* session IDs")
    connection = _connect(paths, create=False)
    if connection is None:
        print("OK: test faults removed: 0")
        return
    try:
        connection.execute("BEGIN IMMEDIATE")
        cursor = connection.execute(
            """DELETE FROM facts
                WHERE fact_type='agent_fault' AND session_id=?
                  AND subject_kind=? AND subject_id=?""",
            (args.session, subject_kind, subject_id),
        )
        connection.commit()
        count = cursor.rowcount
    except Exception:
        connection.rollback()
        raise
    finally:
        _close(connection, paths)
    print(f"OK: test faults removed: {count}")


def export_snapshot(paths: ProfilePaths) -> None:
    _refuse_tracked_export_outputs(paths)
    connection = _connect(paths, create=False)
    if connection is None:
        print("<!-- iwe_memory.db not found -->")
        return
    try:
        rows = connection.execute(
            """SELECT content, severity, record_date, occurrences_count, status,
                      subject_kind, subject_id, source_citation
                 FROM facts WHERE fact_type='agent_fault'
                ORDER BY subject_kind, subject_id, record_date, id"""
        ).fetchall()
    finally:
        _close(connection, paths)
    _require_safe_directory(paths.audit, create=True, mode=0o700)
    for legacy in paths.audit.glob("faults*.md"):
        if legacy == paths.export:
            if _lstat_kind(legacy) == "symlink":
                legacy.unlink()
            continue
        kind = _lstat_kind(legacy)
        if kind in {"file", "symlink"}:
            legacy.unlink()
        elif kind != "missing":
            raise FaultProfileError(f"refusing to remove legacy export ({kind}): {legacy}")
    lines = ["# Agent Fault Profile export", "", "Explicit full snapshot; do not edit.", ""]
    for row in rows:
        lines.extend(
            (
                f"## {row['record_date'] or 'unknown'} · {_severity(row['severity']).upper()}",
                "",
                f"- Subject: `{row['subject_kind']}:{row['subject_id']}`",
                f"- Status: `{row['status'] or 'active'}`",
                f"- Occurrences: {row['occurrences_count'] or 1}",
                f"- Fault: {row['content']}",
            )
        )
        if row["source_citation"]:
            lines.append(f"- Source citation: {row['source_citation']}")
        lines.append("")
    _atomic_write(paths.export, "\n".join(lines), 0o600)
    print(f"OK: full export regenerated: {paths.export}")


def _feedback_faults(path: Path) -> list[dict[str, object]]:
    text = path.read_text(encoding="utf-8", errors="replace")
    frontmatter = re.search(r"^---\s*\n(.*?)\n---", text, re.DOTALL)
    name = path.stem
    description = ""
    if frontmatter:
        name_match = re.search(r"^name:\s*[\"']?(.+?)[\"']?\s*$", frontmatter.group(1), re.MULTILINE)
        description_match = re.search(
            r"^description:\s*[\"']?(.+?)[\"']?\s*$",
            frontmatter.group(1),
            re.MULTILINE,
        )
        if name_match:
            name = name_match.group(1).strip('"\'')
        if description_match:
            description = description_match.group(1).strip('"\'')
    faults: list[dict[str, object]] = []
    section_pattern = re.compile(r"^##\s+([^\n]+)\n(.*?)(?=^##\s|\Z)", re.MULTILINE | re.DOTALL)
    for section in section_pattern.finditer(text):
        rule_name = section.group(1).strip()
        body = section.group(2)
        journal = re.search(r"\*\*Журнал:\*\*(.*)", body, re.DOTALL | re.IGNORECASE)
        journal_text = journal.group(1) if journal else ""
        textual_or_iso_dates = len(
            re.findall(
                r"\b(?:\d{1,2}\s+[а-яa-z]+(?:\s+\d{4})?|\d{4}-\d{2}-\d{2})\b",
                journal_text,
                re.IGNORECASE,
            )
        )
        occurrences = max(
            1,
            len(re.findall(r"WP-\d+", journal_text)),
            textual_or_iso_dates,
            len(journal_text) // 300,
        )
        lower = body.lower()
        protocol_set = {
            protocol
            for protocol, needles in {
                "open": ("day open", "day_open", "protocol-open"),
                "close": ("day close", "day_close", "protocol-close"),
                "work": ("work", "session", "сесс"),
            }.items()
            if any(needle in lower for needle in needles)
        }
        if "open" in lower and "protocol" in lower:
            protocol_set.add("open")
        if "close" in lower and "protocol" in lower:
            protocol_set.add("close")
        protocols = sorted(protocol_set) or ["work"]
        severity = "critical" if occurrences >= 5 else "major" if occurrences >= 3 else "minor"
        faults.append(
            {
                "source_file": path.stem,
                "rule_name": rule_name,
                "content": f"{name}: {rule_name}",
                "short_content": rule_name,
                "protocols": protocols,
                "occurrences": occurrences,
                "severity": severity,
                "description": description,
            }
        )
    if not faults and description:
        faults.append(
            {
                "source_file": path.stem,
                "rule_name": name,
                "content": f"{name}: {description}",
                "short_content": description,
                "protocols": ["work"],
                "occurrences": 1,
                "severity": "minor",
                "description": description,
            }
        )
    return faults


def _feedback_files(paths: ProfilePaths) -> Iterable[Path]:
    seen: set[str] = set()
    for directory in (paths.governance / "exocortex", paths.workspace / "memory"):
        if not directory.is_dir():
            continue
        for path in sorted(directory.glob("feedback_*.md")):
            if path.is_symlink() or not path.is_file() or path.stem in seen:
                continue
            seen.add(path.stem)
            yield path


def _feedback_key(context: Mapping[str, object]) -> tuple[str, str] | None:
    source_file = context.get("source_file")
    rule_name = context.get("rule_name")
    if not isinstance(source_file, str) or not isinstance(rule_name, str):
        return None
    if not source_file or not rule_name:
        return None
    return source_file, rule_name


def import_feedback(paths: ProfilePaths, args: argparse.Namespace) -> None:
    subject_kind, subject_id = _validate_subject(args.subject_kind, args.subject_id)
    may_adopt_legacy = subject_kind == "system" and subject_id == "feedback-import"
    incoming: list[tuple[tuple[str, str], dict[str, object]]] = []
    for source in _feedback_files(paths):
        for fault in _feedback_faults(source):
            key = (str(fault["source_file"]), str(fault["rule_name"]))
            incoming.append((key, fault))

    connection = _connect(paths, create=True)
    assert connection is not None
    imported = 0
    try:
        connection.execute("BEGIN IMMEDIATE")
        targeted: dict[tuple[str, str], list[sqlite3.Row]] = {}
        adoptable: dict[tuple[str, str], list[sqlite3.Row]] = {}
        rows = connection.execute(
            """SELECT id, context, trust_score, occurrences_count, severity,
                      session_id, subject_kind, subject_id
                 FROM facts
                WHERE fact_type='agent_fault'
                  AND (
                        (subject_kind=? AND subject_id=?)
                        OR (
                            session_id='sync-feedback'
                            AND subject_kind IS NULL AND subject_id IS NULL
                        )
                  )""",
            (subject_kind, subject_id),
        ).fetchall()
        for row in rows:
            context = _parse_context_object(row["context"])
            key = _feedback_key(context)
            if key is None:
                continue
            if row["subject_kind"] == subject_kind and row["subject_id"] == subject_id:
                targeted.setdefault(key, []).append(row)
            elif may_adopt_legacy:
                adoptable.setdefault(key, []).append(row)
        now = _now()
        today = _today()
        for key, fault in incoming:
            target_rows = targeted.get(key, [])
            legacy_rows = adoptable.get(key, [])
            if len(target_rows) > 1 or len(legacy_rows) > 1 or (
                target_rows and legacy_rows
            ):
                raise FaultProfileError(
                    "ambiguous feedback rows for one source/rule key; refusing import"
                )
            selected = target_rows[0] if target_rows else legacy_rows[0] if legacy_rows else None
            previous_context = (
                _parse_context_object(selected["context"]) if selected is not None else {}
            )
            incoming_count = int(fault["occurrences"])
            incoming_severity = str(fault["severity"])
            incoming_trust = min(0.95, 0.5 + 0.1 * incoming_count)
            if selected is not None:
                previous_count = (
                    _legacy_positive_count(selected["occurrences_count"])
                    or _legacy_positive_count(previous_context.get("occurrences"))
                    or 1
                )
                count = max(previous_count, incoming_count)
                severity = _stronger_severity(
                    selected["severity"],
                    previous_context.get("severity"),
                    incoming_severity,
                )
                trust = max(
                    _legacy_trust(selected["trust_score"]) or 0.0,
                    incoming_trust,
                )
            else:
                count = incoming_count
                severity = _stronger_severity(incoming_severity)
                trust = incoming_trust
            context = {
                **previous_context,
                **fault,
                "occurrences": count,
                "severity": severity,
                "last_sync": now,
                "subject_kind": subject_kind,
                "subject_id": subject_id,
            }
            if selected is not None:
                connection.execute(
                    """UPDATE facts
                          SET content=?, context=?, trust_score=?, status='active',
                              last_occurrence=?, occurrences_count=?, severity=?,
                              record_date=?, session_id=?, subject_kind=?, subject_id=?
                        WHERE id=?""",
                    (
                        fault["content"],
                        json.dumps(context, ensure_ascii=False),
                        trust,
                        now,
                        count,
                        severity,
                        today,
                        "sync-feedback",
                        subject_kind,
                        subject_id,
                        selected["id"],
                    ),
                )
                targeted[key] = [selected]
                adoptable.pop(key, None)
            else:
                cursor = connection.execute(
                    """INSERT INTO facts (
                           fact_type, content, context, trust_score, session_id,
                           status, last_occurrence, occurrences_count, severity,
                           record_date, subject_kind, subject_id
                       ) VALUES ('agent_fault', ?, ?, ?, 'sync-feedback', 'active',
                                 ?, ?, ?, ?, ?, ?)""",
                    (
                        fault["content"],
                        json.dumps(context, ensure_ascii=False),
                        trust,
                        now,
                        count,
                        severity,
                        today,
                        subject_kind,
                        subject_id,
                    ),
                )
                inserted = connection.execute(
                    """SELECT id, context, trust_score, occurrences_count, severity,
                              session_id, subject_kind, subject_id
                         FROM facts WHERE id=?""",
                    (cursor.lastrowid,),
                ).fetchone()
                assert inserted is not None
                targeted[key] = [inserted]
                imported += 1
        connection.commit()
    except Exception:
        connection.rollback()
        raise
    finally:
        _close(connection, paths)
    print(f"OK: feedback import complete ({imported} new pattern(s))")


def _add_subject(parser: argparse.ArgumentParser, *, required: bool) -> None:
    parser.add_argument("--subject-kind", choices=SUBJECT_KINDS, required=required)
    parser.add_argument("--subject-id", required=required)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="IWE private agent-fault memory")
    commands = parser.add_subparsers(dest="command", required=True)

    record = commands.add_parser("record", help="record or reactivate a fault")
    record.add_argument("--fault", nargs="+", required=True)
    record.add_argument("--severity", choices=SEVERITIES, default="major")
    record.add_argument("--protocol", choices=PROTOCOLS, default="work")
    record.add_argument("--source-citation", nargs="+", default=[])
    record.add_argument("--session")
    record.add_argument("--fault-subtype")
    _add_subject(record, required=True)

    reminder = commands.add_parser("remind", help="show active faults for one subject")
    reminder.add_argument("--protocol", choices=PROTOCOLS, default="work")
    reminder.add_argument("--limit", type=int, default=3)
    reminder.add_argument("--context", default="")
    _add_subject(reminder, required=True)

    stats_parser = commands.add_parser("stats", help="show aggregate counts")
    _add_subject(stats_parser, required=False)

    escalation = commands.add_parser(
        "escalation-check",
        help="show active faults at or above an occurrence threshold",
    )
    escalation.add_argument("--threshold", type=int, default=3)
    _add_subject(escalation, required=False)

    commands.add_parser("decay", help="mark old active faults dormant")
    commands.add_parser("export", help="regenerate the full private Markdown snapshot")

    remove = commands.add_parser("remove-test", help="delete one test session's rows")
    remove.add_argument("--session", required=True)
    _add_subject(remove, required=True)

    importer = commands.add_parser("import-feedback", help="idempotently import feedback_*.md")
    _add_subject(importer, required=True)
    return parser


def dispatch(args: argparse.Namespace) -> None:
    paths = resolve_paths()
    if args.command == "record":
        record_fault(paths, args)
    elif args.command == "remind":
        remind(paths, args)
    elif args.command == "stats":
        stats(paths, args)
    elif args.command == "escalation-check":
        escalation_check(paths, args)
    elif args.command == "decay":
        decay(paths)
    elif args.command == "export":
        export_snapshot(paths)
    elif args.command == "remove-test":
        remove_test(paths, args)
    elif args.command == "import-feedback":
        import_feedback(paths, args)
    else:  # pragma: no cover - argparse owns the command taxonomy
        raise FaultProfileError(f"unsupported command: {args.command}")


def main(argv: Sequence[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    previous_umask = os.umask(0o077)
    try:
        dispatch(args)
    except (FaultProfileError, sqlite3.Error, OSError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2
    finally:
        os.umask(previous_umask)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
