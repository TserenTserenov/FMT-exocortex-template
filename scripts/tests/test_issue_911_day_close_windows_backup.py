"""Regression coverage for issue #911: sync_owned_memory_files() in
day-close.sh cannot run on Windows Python at all (unconditional `import
fcntl`, `os.*(dir_fd=...)`). This exercises the new Windows-only branch by
forcing is_windows_shell() to return True and running the actual embedded
Python script extracted from day-close.sh -- not a reimplementation, the
real code.

Deliberately NOT done: monkeypatching os.name to "nt". pathlib.Path()
selects WindowsPath vs PosixPath from the live os.name at each
CONSTRUCTION site, not once at import time -- forcing "nt" while the
underlying OS is still macOS gives every Path() call WindowsPath semantics
(backslash-flavoured) running against real POSIX syscalls, which is not
"simulating Windows", it is a third, nonexistent platform (confirmed
directly: .exists() on such a path silently returns False for a file that
is really there). Patching only is_windows_shell() keeps every filesystem
call on real, correct PosixPath semantics and tests the portable parts of
the algorithm -- file selection, protected paths, manifest format,
lock-marker behavior, atomic-write fallback. It cannot and does not test
genuinely Windows-specific quirks (reserved device names, reparse-point
detection, non-atomic os.replace on a locked destination) -- those need a
real Windows host, unavailable here, and stay unverified as documented in
the code itself.

Scope, per the peer-session consensus (WP-7 F171, 24.09): the Windows
branch is deliberately smaller than the POSIX one -- no deletion of stale
files, no hardlink quarantine, cooperative locking via the existing marker
file only. These tests check that reduced contract, not parity with POSIX.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
DAY_CLOSE = ROOT / "scripts" / "day-close.sh"


def _extract_embedded_python() -> str:
    """The exact text between the first `<<'PYEOF'` and its matching
    terminator in day-close.sh -- the sync_owned_memory_files() heredoc."""
    text = DAY_CLOSE.read_text(encoding="utf-8")
    match = re.search(r"<<'PYEOF'\n(.*?)\nPYEOF\n", text, re.DOTALL)
    assert match, "could not find the sync_owned_memory_files PYEOF heredoc in day-close.sh"
    return match.group(1)


EMBEDDED_SCRIPT = _extract_embedded_python()
_FORCE_WINDOWS_MARKER = "def is_windows_shell():\n    return os.name == \"nt\""
assert _FORCE_WINDOWS_MARKER in EMBEDDED_SCRIPT, "is_windows_shell() definition not found or changed shape"
EMBEDDED_SCRIPT_FORCED_WINDOWS = EMBEDDED_SCRIPT.replace(
    _FORCE_WINDOWS_MARKER, "def is_windows_shell():\n    return True", 1
)


def _run_windows_branch(tmp_path: Path, *, params_active: bool = False):
    """Run the real embedded script with is_windows_shell() forced to True,
    via a subprocess (not exec() in-process -- the script calls raise
    SystemExit and reads sys.argv, both cleaner isolated as their own
    process). See the module docstring for why this patches the function,
    not os.name."""
    source_root = tmp_path / "memory"
    destination_root = tmp_path / "exocortex"
    source_root.mkdir(exist_ok=True)
    destination_root.mkdir(exist_ok=True)
    manifest_path = destination_root / ".day-close-backup-manifest.json"
    quarantine_path = destination_root / ".day-close-backup-incomplete"
    params_source = tmp_path / "params.yaml"
    argv = [str(source_root), str(destination_root), str(manifest_path), str(quarantine_path)]
    argv.append(str(params_source) if params_active else "")
    if params_active:
        params_source.write_text("tier: pilot\n", encoding="utf-8")
        argv.append("params.yaml")

    wrapper = (
        "import sys\n"
        "sys.argv = " + repr(["day-close-embedded"] + argv) + "\n"
        + EMBEDDED_SCRIPT_FORCED_WINDOWS
    )
    script_path = tmp_path / "_wrapper.py"
    script_path.write_text(wrapper, encoding="utf-8")
    result = subprocess.run(
        [sys.executable, str(script_path)],
        capture_output=True, text=True, timeout=30,
    )
    return result, source_root, destination_root, manifest_path, quarantine_path


def test_copies_new_files_and_writes_compatible_manifest(tmp_path):
    # First run just to create source_root/destination_root; the real case
    # under test is the second run, once source has a file to copy.
    result, source_root, destination_root, manifest_path, quarantine_path = _run_windows_branch(tmp_path)
    (source_root / "MEMORY.md").write_text("hello\n", encoding="utf-8")
    result, *_ = _run_windows_branch(tmp_path)
    assert result.returncode == 0, result.stderr

    published = destination_root / "MEMORY.md"
    assert published.read_text(encoding="utf-8") == "hello\n"

    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    assert manifest["schema_version"] == 1
    expected_hash = hashlib.sha256(b"hello\n").hexdigest()
    assert manifest["files"] == {"MEMORY.md": expected_hash}
    assert not quarantine_path.exists(), "precopy marker must be cleared after a clean run"


def test_warns_about_reduced_windows_contract(tmp_path):
    result, *_ = _run_windows_branch(tmp_path)
    assert "Windows compatibility mode" in result.stderr
    assert "stale files are not removed" in result.stderr


def test_stale_file_is_neither_deleted_nor_falsely_recorded(tmp_path):
    """Per the peer-session consensus: a file present in destination but no
    longer in source is left alone AND dropped from the manifest -- not
    deleted (degraded function, accepted), and not carried forward as a
    stale entry (the race a reviewer found in an earlier draft: the file
    could change between the hash check and the manifest write, and a
    carried-forward entry would then be silently wrong)."""
    source_root = tmp_path / "memory"
    source_root.mkdir()
    (source_root / "keep.md").write_text("v1\n", encoding="utf-8")
    result, source_root, destination_root, manifest_path, quarantine_path = _run_windows_branch(tmp_path)
    assert result.returncode == 0, result.stderr

    # Second run: keep.md removed from source, a stray extra file sits in
    # destination from some earlier POSIX run (simulated).
    (source_root / "keep.md").unlink()
    (destination_root / "orphan.md").write_text("still here\n", encoding="utf-8")
    result, *_ = _run_windows_branch(tmp_path)
    assert result.returncode == 0, result.stderr

    assert (destination_root / "orphan.md").exists(), "Windows branch must never delete files it didn't just write"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    assert "orphan.md" not in manifest["files"], "orphan.md was never touched this run and must not be claimed in the manifest"


def test_protected_files_are_never_overwritten_by_source(tmp_path):
    source_root = tmp_path / "memory"
    source_root.mkdir()
    # CLAUDE.md is a protected_files entry -- even if a same-named file
    # somehow exists at the top of the source tree, it must be skipped.
    (source_root / "CLAUDE.md").write_text("attempted overwrite\n", encoding="utf-8")
    (source_root / "MEMORY.md").write_text("real content\n", encoding="utf-8")
    result, source_root, destination_root, manifest_path, quarantine_path = _run_windows_branch(tmp_path)
    assert result.returncode == 0, result.stderr

    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    assert "CLAUDE.md" not in manifest["files"]
    assert "MEMORY.md" in manifest["files"]
    assert not (destination_root / "CLAUDE.md").exists()


def test_protected_files_cannot_be_bypassed_by_case(tmp_path):
    """Cold-review Critical (24.09): an exact-string protected-path check
    missed a differently-cased source file -- the SAME filesystem object as
    the real, protected file on any case-insensitive filesystem, which is
    Windows always and this test machine's own APFS by default. The fix
    reuses the same NFKC+casefold canonicalization the POSIX branch already
    applies (protected_alias()), not a second, weaker check."""
    source_root = tmp_path / "memory"
    source_root.mkdir()
    (source_root / "Day-Rhythm-Config.yaml").write_text("attempted overwrite\n", encoding="utf-8")
    (source_root / "MEMORY.md").write_text("real content\n", encoding="utf-8")
    result, source_root, destination_root, manifest_path, quarantine_path = _run_windows_branch(tmp_path)
    assert result.returncode == 0, result.stderr

    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    assert "Day-Rhythm-Config.yaml" not in manifest["files"]
    assert "day-rhythm-config.yaml" not in manifest["files"]
    assert "MEMORY.md" in manifest["files"]
    assert not (destination_root / "Day-Rhythm-Config.yaml").exists()


def test_mkdir_failure_for_one_file_does_not_abort_the_whole_run(tmp_path):
    """Cold-review High (24.09): target.parent.mkdir() used to sit outside
    atomic_write_windows()'s try/except, so a stale non-directory blocking
    an intermediate path component crashed the entire run instead of
    skipping that one file, same as the write/replace failures already
    handle."""
    source_root = tmp_path / "memory"
    source_root.mkdir()
    (source_root / "blocked").mkdir()
    (source_root / "blocked" / "nested.md").write_text("nested\n", encoding="utf-8")
    result, source_root, destination_root, manifest_path, quarantine_path = _run_windows_branch(tmp_path)
    assert result.returncode == 0, result.stderr

    # Replace the "blocked" directory this run just created in destination
    # with a plain file -- "blocked" must become a directory component
    # again for blocked/nested.md, but a plain file now occupies the path.
    shutil.rmtree(destination_root / "blocked")
    (destination_root / "blocked").write_text("occupies the path a directory needs\n", encoding="utf-8")

    (source_root / "ok2.md").write_text("also fine\n", encoding="utf-8")
    result, *_ = _run_windows_branch(tmp_path)
    assert result.returncode == 0, "one file's mkdir failure must not fail the whole run"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    assert "ok2.md" in manifest["files"], "an unrelated file in the same run must still be published"
    assert "blocked/nested.md" not in manifest["files"], "the blocked file must be skipped, not silently dropped without a trace"


def test_second_backup_marker_present_refuses_to_start(tmp_path):
    source_root = tmp_path / "memory"
    source_root.mkdir()
    destination_root = tmp_path / "exocortex"
    destination_root.mkdir()
    lock_marker = destination_root / ".day-close-backup.lock"
    lock_marker.write_text("someone-else\n", encoding="ascii")
    result, *_ = _run_windows_branch(tmp_path)
    assert result.returncode != 0
    assert "refusing to start" in result.stderr
    assert lock_marker.read_text(encoding="ascii") == "someone-else\n", "must not touch a lock marker it doesn't own"


def test_params_yaml_published_only_when_active_target(tmp_path):
    source_root = tmp_path / "memory"
    source_root.mkdir()
    result, source_root, destination_root, manifest_path, quarantine_path = _run_windows_branch(tmp_path, params_active=True)
    assert result.returncode == 0, result.stderr
    assert (destination_root / "params.yaml").read_text(encoding="utf-8") == "tier: pilot\n"
