"""Persistent storage and querying of consent state for data needs."""

import fcntl
import errno
import os
import stat
import tempfile
import yaml
from contextlib import contextmanager
from pathlib import Path
from typing import Callable, Dict, Iterator, Optional, Literal
from datetime import datetime


ConsentStatus = Literal["not_asked", "granted", "denied", "revoked"]
VALID_CONSENT_STATUSES = {"not_asked", "granted", "denied", "revoked"}


class ResidencyStateError(RuntimeError):
    """Persistent consent state is unreadable or violates its schema."""


class ResidencyState:
    """Manage local consent state outside the Git-backed IWE workspace."""

    STATE_FILE_NAME = "data-residency.yaml"
    LOCK_FILE_NAME = ".data-residency.lock"
    BACKUP_DIR_NAME = "migration-backups"
    LEGACY_BACKUP_NAME = "data-residency.yaml.legacy"
    LEGACY_QUARANTINE_NAME = ".data-residency.yaml.legacy.migrating"

    def __init__(self, state_file: Optional[str] = None):
        """Initialize state manager.

        Args:
            state_file: Explicit state path for embedding/tests. The default is
                ``${IWE_STATE_HOME:-$HOME/.iwe/state}/data-residency.yaml``.
        """
        self._uses_default_location = state_file is None
        self._standard_state_container: Optional[Path] = None
        if self._uses_default_location:
            state_home_override = os.environ.get("IWE_STATE_HOME")
            state_home_value = state_home_override or str(
                Path.home() / ".iwe" / "state"
            )
            raw_state_home = self._absolute_path(state_home_value, "IWE_STATE_HOME")
            if state_home_override is None:
                self._reject_symlink(
                    raw_state_home.parent, "default residency state container"
                )
            state_home = raw_state_home.resolve(strict=False)
            if state_home_override is None:
                self._standard_state_container = state_home.parent
            state_file = str(state_home / self.STATE_FILE_NAME)
        else:
            explicit_state_file = self._absolute_path(
                str(state_file), "explicit residency state path"
            )
            state_file = str(
                explicit_state_file.parent.resolve(strict=False)
                / explicit_state_file.name
            )

        self.state_file = Path(state_file)
        self._legacy_file_path: Optional[Path] = None
        self._legacy_workspace_root: Optional[Path] = None
        if self._uses_default_location:
            self._legacy_file_path = self._legacy_state_file()
            self._assert_default_location_is_private()
        if self._standard_state_container is not None:
            self._ensure_private_directory(self._standard_state_container)
        self._ensure_private_directory(self.state_file.parent)
        self.lock_file = self.state_file.parent / self.LOCK_FILE_NAME
        with self._state_lock(exclusive=True):
            if self._uses_default_location:
                self._migrate_legacy_state()
            self._ensure_file_exists()
            self._ensure_private_file(self.state_file)

    @staticmethod
    def _absolute_path(value: str, label: str) -> Path:
        """Return an expanded absolute path or fail closed."""
        path = Path(value).expanduser()
        if not path.is_absolute():
            raise ResidencyStateError(f"{label} must be an absolute path: {value!r}")
        return path

    @staticmethod
    def _reject_symlink(path: Path, label: str) -> None:
        """Reject a symlink at the security boundary instead of following it."""
        try:
            if path.is_symlink():
                raise ResidencyStateError(f"{label} must not be a symlink: {path}")
        except OSError as error:
            raise ResidencyStateError(f"cannot inspect {label}: {path}: {error}") from error

    @staticmethod
    def _is_within(path: Path, parent: Path) -> bool:
        """Return whether path is parent itself or one of its descendants."""
        try:
            path.relative_to(parent)
            return True
        except ValueError:
            return False

    def _assert_default_location_is_private(self) -> None:
        """Keep default consent state physically outside Git-backed IWE."""
        assert self._legacy_file_path is not None
        state_home = self.state_file.parent
        resolved_home = state_home.resolve(strict=False)
        assert self._legacy_workspace_root is not None
        resolved_workspace = self._legacy_workspace_root
        resolved_target = self.state_file.resolve(strict=False)
        resolved_legacy = self._legacy_file_path.resolve(strict=False)
        if self._is_within(resolved_home, resolved_workspace):
            raise ResidencyStateError(
                "IWE_STATE_HOME must be physically outside the IWE workspace: "
                f"{state_home}"
            )
        if resolved_target == resolved_legacy:
            raise ResidencyStateError(
                "local and legacy consent paths resolve to the same file: "
                f"{self.state_file}"
            )
        for parent in (resolved_home, *resolved_home.parents):
            if (parent / ".git").exists():
                raise ResidencyStateError(
                    f"IWE_STATE_HOME must be outside a Git repository: {state_home}"
                )

    def _ensure_private_directory(self, directory: Path) -> None:
        """Create a directory tree without following links and make its leaf private."""
        directory = self._absolute_path(
            str(directory), "residency state directory"
        )
        root = Path(directory.anchor)
        if directory == root:
            raise ResidencyStateError(
                "residency state directory must not be the filesystem root"
            )

        flags = os.O_RDONLY
        if hasattr(os, "O_DIRECTORY"):
            flags |= os.O_DIRECTORY
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW

        descriptor: Optional[int] = None
        try:
            descriptor = os.open(root, flags)
            components = directory.relative_to(root).parts
            current = root
            for index, component in enumerate(components):
                current = current / component
                is_target = index == len(components) - 1
                created = False
                try:
                    entry_stat = os.stat(
                        component, dir_fd=descriptor, follow_symlinks=False
                    )
                except FileNotFoundError:
                    try:
                        os.mkdir(component, mode=0o700, dir_fd=descriptor)
                    except FileExistsError:
                        pass
                    created = True
                    entry_stat = os.stat(
                        component, dir_fd=descriptor, follow_symlinks=False
                    )

                if stat.S_ISLNK(entry_stat.st_mode):
                    raise ResidencyStateError(
                        f"residency state directory must not be a symlink: {current}"
                    )
                if not stat.S_ISDIR(entry_stat.st_mode):
                    raise ResidencyStateError(
                        f"residency state directory is not a directory: {current}"
                    )

                # chmod through the pinned parent before open so a hostile
                # umask such as 0777 cannot make a just-created child
                # impossible to traverse.
                if created or is_target:
                    os.chmod(
                        component,
                        0o700,
                        dir_fd=descriptor,
                        follow_symlinks=False,
                    )

                child_descriptor = os.open(component, flags, dir_fd=descriptor)
                child_adopted = False
                try:
                    child_stat = os.fstat(child_descriptor)
                    if not stat.S_ISDIR(child_stat.st_mode):
                        raise ResidencyStateError(
                            f"residency state directory is not a directory: {current}"
                        )
                    if created or is_target:
                        os.fchmod(child_descriptor, 0o700)
                    os.close(descriptor)
                    descriptor = child_descriptor
                    child_adopted = True
                finally:
                    if not child_adopted:
                        os.close(child_descriptor)
        except ResidencyStateError:
            raise
        except OSError as error:
            raise ResidencyStateError(
                f"cannot secure residency state directory: {directory}: {error}"
            ) from error
        finally:
            if descriptor is not None:
                os.close(descriptor)

    def _ensure_private_file(self, path: Path) -> None:
        """Require a regular state file and enforce owner-only access."""
        self._reject_symlink(path, "residency state file")
        flags = os.O_RDWR
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        descriptor: Optional[int] = None
        try:
            descriptor = os.open(path, flags)
            file_stat = os.fstat(descriptor)
            if not stat.S_ISREG(file_stat.st_mode):
                raise ResidencyStateError(f"residency state is not a regular file: {path}")
            if file_stat.st_nlink != 1:
                raise ResidencyStateError(
                    f"residency state must have exactly one hard link: {path}"
                )
            os.fchmod(descriptor, 0o600)
        except ResidencyStateError:
            raise
        except OSError as error:
            raise ResidencyStateError(
                f"cannot secure residency state file: {path}: {error}"
            ) from error
        finally:
            if descriptor is not None:
                os.close(descriptor)

    @contextmanager
    def _state_lock(self, *, exclusive: bool) -> Iterator[None]:
        """Serialize migrations and read-modify-write consent updates."""
        if self._standard_state_container is not None:
            self._ensure_private_directory(self._standard_state_container)
        self._ensure_private_directory(self.state_file.parent)
        flags = os.O_RDWR | os.O_CREAT
        descriptor: Optional[int] = None
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        try:
            descriptor = os.open(self.lock_file, flags, 0o600)
            lock_stat = os.fstat(descriptor)
            if not stat.S_ISREG(lock_stat.st_mode):
                raise ResidencyStateError(
                    f"residency state lock is not a regular file: {self.lock_file}"
                )
            if lock_stat.st_nlink != 1:
                raise ResidencyStateError(
                    f"residency state lock must have exactly one hard link: {self.lock_file}"
                )
            os.fchmod(descriptor, 0o600)
            operation = fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH
            fcntl.flock(descriptor, operation)
        except ResidencyStateError:
            if descriptor is not None:
                try:
                    os.close(descriptor)
                except OSError:
                    pass
            raise
        except OSError as error:
            if descriptor is not None:
                try:
                    os.close(descriptor)
                except OSError:
                    pass
            raise ResidencyStateError(
                f"cannot lock residency state: {self.lock_file}: {error}"
            ) from error
        try:
            yield
        finally:
            assert descriptor is not None
            try:
                fcntl.flock(descriptor, fcntl.LOCK_UN)
            finally:
                os.close(descriptor)

    def _legacy_state_file(self) -> Path:
        """Resolve the one supported pre-#521B state location."""
        iwe_root_value = (
            os.environ.get("IWE_WORKSPACE")
            or os.environ.get("IWE_ROOT")
            or os.environ.get("IWE")
            or str(Path.home() / "IWE")
        )
        iwe_root = self._absolute_path(iwe_root_value, "IWE workspace")
        self._legacy_workspace_root = iwe_root.resolve(strict=False)
        return self._legacy_workspace_root / "current" / self.STATE_FILE_NAME

    @staticmethod
    def _validated_document(content: bytes, path: Path) -> dict:
        """Parse enough schema to compare migration candidates safely."""
        try:
            doc = yaml.safe_load(content.decode("utf-8")) or {}
        except (UnicodeError, yaml.YAMLError) as error:
            raise ResidencyStateError(
                f"consent state cannot be read safely: {path}: {error}"
            ) from error
        if not isinstance(doc, dict):
            raise ResidencyStateError(f"consent state root must be a mapping: {path}")
        functions = doc.get("functions", {})
        if functions is None:
            functions = {}
        if not isinstance(functions, dict):
            raise ResidencyStateError(
                f"consent state 'functions' must be a mapping: {path}"
            )
        return doc

    def _read_migration_candidate(self, path: Path) -> bytes:
        """Read a regular non-symlink file as an immutable migration snapshot."""
        flags = os.O_RDONLY
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        descriptor: Optional[int] = None
        try:
            descriptor = os.open(path, flags)
            content = self._read_candidate_descriptor(descriptor, path)
        except ResidencyStateError:
            raise
        except (OSError, UnicodeError) as error:
            raise ResidencyStateError(
                f"consent state cannot be read safely: {path}: {error}"
            ) from error
        finally:
            if descriptor is not None:
                os.close(descriptor)
        self._validated_document(content, path)
        return content

    def _read_candidate_descriptor(self, descriptor: int, path: Path) -> bytes:
        """Read one unique regular inode from an already pinned descriptor."""
        file_stat = os.fstat(descriptor)
        if not stat.S_ISREG(file_stat.st_mode):
            raise ResidencyStateError(
                f"residency migration candidate is not a regular file: {path}"
            )
        if file_stat.st_nlink != 1:
            raise ResidencyStateError(
                f"residency migration candidate must have exactly one hard link: {path}"
            )
        chunks = []
        while True:
            chunk = os.read(descriptor, 64 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        return b"".join(chunks)

    def _open_legacy_directory(self) -> Optional[int]:
        """Pin workspace/current without following a symlink below workspace."""
        assert self._legacy_workspace_root is not None
        directory_flags = os.O_RDONLY
        if hasattr(os, "O_DIRECTORY"):
            directory_flags |= os.O_DIRECTORY
        # The configured root was canonicalized once in __init__. Following a
        # symlink here would therefore mean the path was replaced afterwards.
        if hasattr(os, "O_NOFOLLOW"):
            directory_flags |= os.O_NOFOLLOW
        root_descriptor: Optional[int] = None
        try:
            root_descriptor = os.open(self._legacy_workspace_root, directory_flags)
        except FileNotFoundError:
            return None
        except OSError as error:
            raise ResidencyStateError(
                f"cannot open IWE workspace for consent migration: "
                f"{self._legacy_workspace_root}: {error}"
            ) from error

        current_flags = directory_flags
        if hasattr(os, "O_NOFOLLOW"):
            current_flags |= os.O_NOFOLLOW
        try:
            try:
                current_descriptor = os.open(
                    "current", current_flags, dir_fd=root_descriptor
                )
            except FileNotFoundError:
                return None
            except OSError as error:
                raise ResidencyStateError(
                    "legacy consent directory must be a real directory inside "
                    f"the IWE workspace: {self._legacy_workspace_root / 'current'}: {error}"
                ) from error
            if not stat.S_ISDIR(os.fstat(current_descriptor).st_mode):
                os.close(current_descriptor)
                raise ResidencyStateError(
                    "legacy consent directory is not a directory: "
                    f"{self._legacy_workspace_root / 'current'}"
                )
            return current_descriptor
        finally:
            os.close(root_descriptor)

    @staticmethod
    def _entry_exists_at(directory_descriptor: Optional[int], name: str) -> bool:
        """Check an entry without following its final symlink."""
        if directory_descriptor is None:
            return False
        try:
            os.stat(name, dir_fd=directory_descriptor, follow_symlinks=False)
            return True
        except FileNotFoundError:
            return False
        except OSError as error:
            raise ResidencyStateError(
                f"cannot inspect legacy consent entry {name}: {error}"
            ) from error

    def _read_legacy_candidate(self, directory_descriptor: int) -> bytes:
        """Read the legacy state through the pinned current directory."""
        flags = os.O_RDONLY
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        descriptor: Optional[int] = None
        assert self._legacy_file_path is not None
        try:
            descriptor = os.open(
                self.STATE_FILE_NAME, flags, dir_fd=directory_descriptor
            )
            content = self._read_candidate_descriptor(
                descriptor, self._legacy_file_path
            )
        except ResidencyStateError:
            raise
        except OSError as error:
            raise ResidencyStateError(
                f"consent state cannot be read safely: {self._legacy_file_path}: {error}"
            ) from error
        finally:
            if descriptor is not None:
                os.close(descriptor)
        self._validated_document(content, self._legacy_file_path)
        return content

    @staticmethod
    def _fsync_directory(directory: Path) -> None:
        """Best-effort durability barrier for directory entry changes."""
        try:
            descriptor = os.open(directory, os.O_RDONLY)
        except OSError:
            return
        try:
            os.fsync(descriptor)
        except OSError:
            pass
        finally:
            os.close(descriptor)

    @staticmethod
    def _fsync_descriptor(descriptor: int, label: Path) -> None:
        """Require durability for a security-sensitive directory transition."""
        try:
            os.fsync(descriptor)
        except OSError as error:
            raise ResidencyStateError(
                f"cannot durably persist consent migration in {label}: {error}"
            ) from error

    def _fsync_private_directory(self, directory: Path) -> None:
        """Strictly persist a private directory before retiring legacy data."""
        flags = os.O_RDONLY
        if hasattr(os, "O_DIRECTORY"):
            flags |= os.O_DIRECTORY
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        try:
            descriptor = os.open(directory, flags)
        except OSError as error:
            raise ResidencyStateError(
                f"cannot open private consent directory for fsync: {directory}: {error}"
            ) from error
        try:
            self._fsync_descriptor(descriptor, directory)
        finally:
            os.close(descriptor)

    def _create_exclusive_private_file(self, path: Path, content: bytes) -> None:
        """Create a private file without overwriting a concurrent writer."""
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        try:
            descriptor = os.open(path, flags, 0o600)
        except FileExistsError:
            existing = self._read_migration_candidate(path)
            if existing != content:
                raise ResidencyStateError(
                    f"migration target appeared with different content: {path}"
                )
            return
        except OSError as error:
            raise ResidencyStateError(f"cannot create private state file: {path}: {error}") from error

        try:
            with os.fdopen(descriptor, "wb") as output:
                os.fchmod(output.fileno(), 0o600)
                output.write(content)
                output.flush()
                os.fsync(output.fileno())
            self._fsync_directory(path.parent)
        except OSError as error:
            try:
                path.unlink(missing_ok=True)
            except OSError:
                pass
            raise ResidencyStateError(f"cannot persist private state file: {path}: {error}") from error

    def _ensure_legacy_backup(self, legacy_content: bytes) -> Path:
        """Keep one deterministic, exact and owner-only recovery snapshot."""
        backup_dir = self.state_file.parent / self.BACKUP_DIR_NAME
        self._ensure_private_directory(backup_dir)
        backup = backup_dir / self.LEGACY_BACKUP_NAME
        if backup.exists() or backup.is_symlink():
            existing = self._read_migration_candidate(backup)
            if existing != legacy_content:
                raise ResidencyStateError(
                    f"legacy migration backup conflicts with source: {backup}"
                )
            self._ensure_private_file(backup)
            return backup
        self._create_exclusive_private_file(backup, legacy_content)
        self._ensure_private_file(backup)
        return backup

    def _migrate_legacy_state(self) -> None:
        """Move the old workspace state once, never merging conflicting records."""
        assert self._legacy_file_path is not None
        legacy = self._legacy_file_path
        quarantine = self.state_file.parent / self.LEGACY_QUARANTINE_NAME
        legacy_directory = self._open_legacy_directory()
        legacy_exists = self._entry_exists_at(
            legacy_directory, self.STATE_FILE_NAME
        )
        quarantine_exists = quarantine.exists() or quarantine.is_symlink()
        target_exists = self.state_file.exists() or self.state_file.is_symlink()
        try:
            if legacy_exists and quarantine_exists:
                raise ResidencyStateError(
                    "both active and quarantined legacy consent states exist; "
                    f"manual reconciliation required: {legacy}, {quarantine}"
                )
            if not legacy_exists and not quarantine_exists:
                return

            source = quarantine if quarantine_exists else legacy
            if quarantine_exists:
                legacy_content = self._read_migration_candidate(quarantine)
            else:
                assert legacy_directory is not None
                legacy_content = self._read_legacy_candidate(legacy_directory)
            legacy_document = self._validated_document(legacy_content, source)
            target_content = None
            if target_exists:
                target_content = self._read_migration_candidate(self.state_file)
                target_document = self._validated_document(
                    target_content, self.state_file
                )
                if target_document != legacy_document:
                    raise ResidencyStateError(
                        "legacy and local consent state differ; refusing automatic merge: "
                        f"{source} != {self.state_file}"
                    )

            backup = self._ensure_legacy_backup(legacy_content)
            if target_content is None:
                self._create_exclusive_private_file(self.state_file, legacy_content)
            self._ensure_private_file(self.state_file)
            final_target = self._read_migration_candidate(self.state_file)
            if self._validated_document(final_target, self.state_file) != legacy_document:
                raise ResidencyStateError(
                    f"local consent state changed during migration: {self.state_file}"
                )

            # Both recovery copies and their directory entries must be durable
            # before the only Git-visible source is renamed away.
            self._fsync_private_directory(backup.parent)
            self._fsync_private_directory(self.state_file.parent)

            # Close the Git-visible path in one rename. The recovery copy lands
            # directly in private state storage; a crash never leaves a second
            # consent file inside the workspace. Cross-device layouts stop
            # safely because no atomic rename exists across filesystems.
            if not quarantine_exists:
                assert legacy_directory is not None
                state_directory_flags = os.O_RDONLY
                if hasattr(os, "O_DIRECTORY"):
                    state_directory_flags |= os.O_DIRECTORY
                if hasattr(os, "O_NOFOLLOW"):
                    state_directory_flags |= os.O_NOFOLLOW
                state_directory = os.open(
                    self.state_file.parent, state_directory_flags
                )
                try:
                    try:
                        os.rename(
                            self.STATE_FILE_NAME,
                            self.LEGACY_QUARANTINE_NAME,
                            src_dir_fd=legacy_directory,
                            dst_dir_fd=state_directory,
                        )
                    except OSError as error:
                        if error.errno == errno.EXDEV:
                            raise ResidencyStateError(
                                "legacy consent state is on a different filesystem; "
                                "automatic atomic migration is unavailable"
                            ) from error
                        raise ResidencyStateError(
                            f"cannot quarantine legacy consent state: {legacy}: {error}"
                        ) from error
                    self._fsync_descriptor(state_directory, quarantine.parent)
                    self._fsync_descriptor(legacy_directory, legacy.parent)
                finally:
                    os.close(state_directory)

            if self._read_migration_candidate(quarantine) != legacy_content:
                raise ResidencyStateError(
                    "legacy consent state changed during migration; preserving quarantine: "
                    f"{quarantine}"
                )

            fresh_legacy_directory = self._open_legacy_directory()
            try:
                if self._entry_exists_at(
                    fresh_legacy_directory, self.STATE_FILE_NAME
                ):
                    raise ResidencyStateError(
                        "an old-version writer recreated legacy consent state during migration; "
                        f"preserving both files: {legacy}, {quarantine}"
                    )
            finally:
                if fresh_legacy_directory is not None:
                    os.close(fresh_legacy_directory)

            try:
                quarantine.unlink()
                state_directory_flags = os.O_RDONLY
                if hasattr(os, "O_DIRECTORY"):
                    state_directory_flags |= os.O_DIRECTORY
                if hasattr(os, "O_NOFOLLOW"):
                    state_directory_flags |= os.O_NOFOLLOW
                state_directory = os.open(
                    self.state_file.parent, state_directory_flags
                )
                try:
                    self._fsync_descriptor(state_directory, quarantine.parent)
                finally:
                    os.close(state_directory)
            except OSError as error:
                raise ResidencyStateError(
                    "local copy is safe but quarantined legacy state could not be retired: "
                    f"{quarantine}: {error}"
                ) from error
        finally:
            if legacy_directory is not None:
                os.close(legacy_directory)

    def _ensure_file_exists(self) -> None:
        """Create empty state file if it doesn't exist."""
        if not self.state_file.exists() and not self.state_file.is_symlink():
            self._save_state_unlocked({})

    def _load_state_unlocked(self) -> dict:
        """Load current state from yaml."""
        try:
            self._ensure_private_file(self.state_file)
            content = self._read_migration_candidate(self.state_file)
            doc = self._validated_document(content, self.state_file)
        except (OSError, UnicodeError, yaml.YAMLError) as error:
            raise ResidencyStateError(
                f"consent state cannot be read safely: {self.state_file}: {error}"
            ) from error
        functions = doc.get("functions", {})
        if functions is None:
            functions = {}
        return functions

    def _save_state_unlocked(self, state: dict) -> None:
        """Save state to yaml file atomically."""
        doc = {"functions": state}
        header = "# Data residency consent state\n# Auto-generated\n\n"
        content = (
            header
            + yaml.safe_dump(
                doc,
                default_flow_style=False,
                sort_keys=True,
                allow_unicode=True,
            )
        ).encode("utf-8")

        if self.state_file.exists() or self.state_file.is_symlink():
            self._ensure_private_file(self.state_file)
        temp_path: Optional[Path] = None
        try:
            descriptor, raw_path = tempfile.mkstemp(
                prefix=f".{self.STATE_FILE_NAME}.",
                suffix=".tmp",
                dir=self.state_file.parent,
            )
            temp_path = Path(raw_path)
            with os.fdopen(descriptor, "wb") as output:
                os.fchmod(output.fileno(), 0o600)
                output.write(content)
                output.flush()
                os.fsync(output.fileno())
            os.replace(temp_path, self.state_file)
            temp_path = None
            self._ensure_private_file(self.state_file)
            self._fsync_directory(self.state_file.parent)
        except OSError as error:
            raise ResidencyStateError(
                f"cannot save consent state safely: {self.state_file}: {error}"
            ) from error
        finally:
            if temp_path is not None:
                try:
                    temp_path.unlink(missing_ok=True)
                except OSError:
                    pass

    def _load_state(self) -> dict:
        """Read one snapshot, rechecking legacy writers before every default read."""
        with self._state_lock(exclusive=self._uses_default_location):
            if self._uses_default_location:
                self._migrate_legacy_state()
            return self._load_state_unlocked()

    def _mutate_state(self, mutation: Callable[[dict], None]) -> None:
        """Apply one consent mutation without losing a concurrent update."""
        with self._state_lock(exclusive=True):
            if self._uses_default_location:
                self._migrate_legacy_state()
            state = self._load_state_unlocked()
            mutation(state)
            self._save_state_unlocked(state)

    def get_consent(self, function_id: str, data_need_key: str) -> Dict:
        """Get current consent status for a specific data need.

        Returns dict with keys:
        - status: ConsentStatus
        - granted_at: ISO timestamp or null
        - denied_reason: string or null
        """
        state = self._load_state()
        func_state = state.get(function_id, {})
        if not isinstance(func_state, dict):
            raise ResidencyStateError(f"consent state for '{function_id}' must be a mapping")
        need_state = func_state.get(data_need_key, {})
        if not isinstance(need_state, dict):
            raise ResidencyStateError(
                f"consent record '{function_id}/{data_need_key}' must be a mapping"
            )
        status = need_state.get("status", "not_asked")
        if status not in VALID_CONSENT_STATUSES:
            raise ResidencyStateError(
                f"consent record '{function_id}/{data_need_key}' has unknown status: {status!r}"
            )

        return {
            "status": status,
            "granted_at": need_state.get("granted_at"),
            "denied_reason": need_state.get("denied_reason"),
            "revoked_reason": need_state.get("revoked_reason"),
        }

    def grant_consent(self, function_id: str, data_need_key: str) -> None:
        """Record user grant for a data need."""
        def grant(state: dict) -> None:
            if function_id not in state:
                state[function_id] = {}
            state[function_id][data_need_key] = {
                "status": "granted",
                "granted_at": datetime.utcnow().isoformat() + "Z",
            }

        self._mutate_state(grant)

    def deny_consent(self, function_id: str, data_need_key: str, reason: str = "") -> None:
        """Record user denial for a data need."""
        def deny(state: dict) -> None:
            if function_id not in state:
                state[function_id] = {}
            state[function_id][data_need_key] = {
                "status": "denied",
                "denied_reason": reason,
                "denied_at": datetime.utcnow().isoformat() + "Z",
            }

        self._mutate_state(deny)

    def revoke_consent(self, function_id: str, data_need_key: str, reason: str = "") -> None:
        """User revokes previously granted consent."""
        def revoke(state: dict) -> None:
            if function_id not in state:
                state[function_id] = {}
            state[function_id][data_need_key] = {
                "status": "revoked",
                "revoked_reason": reason,
                "revoked_at": datetime.utcnow().isoformat() + "Z",
            }

        self._mutate_state(revoke)

    def list_all_consents(self) -> Dict:
        """Return all consent records."""
        return self._load_state()

    def reset_function_consents(self, function_id: str) -> None:
        """Clear all consent records for a function (for version upgrade/reset)."""
        def reset(state: dict) -> None:
            state.pop(function_id, None)

        self._mutate_state(reset)
