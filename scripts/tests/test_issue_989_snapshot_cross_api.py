"""Regression for issue #989: the agent-fault target snapshot compared lstat with fstat on st_ctime_ns.

Since CPython 3.12 on Windows os.lstat() reports the creation time as st_ctime (Modules/posixmodule.c, win32_xstat)
while os.fstat() reports the metadata change time (Python/fileutils.c, _Py_attribute_data_to_stat), so the two
can disagree for a file that was modified after it was created (checked in the CPython 3.12, 3.13 and 3.14
sources). The snapshot then failed with "target identity
changed before snapshot" and update.sh ended with exit 3 and a stuck .update-incomplete marker. The cross-API
comparison is now POSIX only; the lstat taken after the read, compared with the one before it, still catches a
file that was swapped and is still swapped by then. The descriptor is opened with O_BINARY where that flag exists:
a Windows descriptor without it is in text mode (\\r\\n translation, Ctrl-Z ends the file), so the hash would not be
the hash of the actual bytes.

update.sh embeds the Python in a bash function, so the test cuts the snippet out of the function and runs it
under a harness. The harness builds fstat from lstat of the same file (so the two agree on every host), adds the
requested ctime skew, pretends to be a given platform (os.name), imitates a metadata change between the two lstat
calls, and fakes os.O_BINARY to record the flags the snippet passes to os.open. None of that needs Windows; the last test runs
the unpatched snippet and is skipped everywhere else.
"""
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
FAKE_O_BINARY = 0x40000000  # a bit no POSIX open flag uses; the harness strips it before the real os.open

HARNESS = r'''
import hashlib, json, os, stat, sys, types  # imported first: their platform checks run before os.name is patched

snippet, path, fake_os_name, ctime_skew, lstat_after_mtime_skew, fake_o_binary = sys.argv[1:7]
ctime_skew, lstat_after_mtime_skew, fake_o_binary = int(ctime_skew), int(lstat_after_mtime_skew), int(fake_o_binary)


def view(result, **override):
    fields = {name: getattr(result, name) for name in
              ("st_dev", "st_ino", "st_mode", "st_size", "st_mtime_ns", "st_ctime_ns")}
    fields.update(override)
    return types.SimpleNamespace(**fields)


real_lstat, real_open = os.lstat, os.open
calls = {"lstat": 0}
opened_flags = []


def fstat(descriptor):
    base = real_lstat(path)
    return view(base, st_ctime_ns=base.st_ctime_ns + ctime_skew)


def lstat(target):
    calls["lstat"] += 1
    result = real_lstat(target)
    if calls["lstat"] == 2:
        return view(result, st_mtime_ns=result.st_mtime_ns + lstat_after_mtime_skew)
    return view(result)


def open_recording_flags(target, flags, *args, **kwargs):
    opened_flags.append(flags)
    return real_open(target, flags & ~fake_o_binary if fake_o_binary else flags, *args, **kwargs)


os.fstat, os.lstat, os.open = fstat, lstat, open_recording_flags
if fake_os_name != "-":
    os.name = fake_os_name
if fake_o_binary:
    os.O_BINARY = fake_o_binary
sys.argv = ["-c", path]
exec(compile(snippet, "<snapshot>", "exec"), {"__name__": "__main__"})
sys.stderr.write(json.dumps({"flags": opened_flags}))
'''


def snapshot_snippet() -> str:
    text = (ROOT / "update.sh").read_text(encoding="utf-8")
    start = text.index("agent_fault_target_snapshot() {")
    body = text[start:text.index("\n}\n", start)]
    found = re.search(r"\$PY_BIN -c '\n(.*)\n' \"\$1\"", body, re.S)
    assert found, "the snapshot snippet was not found in agent_fault_target_snapshot of update.sh"
    return found.group(1)


def run_snapshot(tmp_path: Path, fake_os_name: str, ctime_skew: int = 0, lstat_after_mtime_skew: int = 0,
                 fake_o_binary: int = 0):
    target = tmp_path / "shim.py"
    target.write_bytes(b"print('legacy shim')\n")
    result = subprocess.run(
        [sys.executable, "-c", HARNESS, snapshot_snippet(), str(target), fake_os_name,
         str(ctime_skew), str(lstat_after_mtime_skew), str(fake_o_binary)],
        capture_output=True, text=True,
    )
    return result, target


@pytest.mark.parametrize("fake_os_name", ["posix", "nt"])
def test_unskewed_snapshot_succeeds_and_reports_the_content_hash(tmp_path, fake_os_name):
    result, target = run_snapshot(tmp_path, fake_os_name)
    assert result.returncode == 0, result.stderr
    kind, *_, digest = json.loads(result.stdout)
    assert kind == "file"
    assert digest == hashlib.sha256(target.read_bytes()).hexdigest()


def test_posix_still_rejects_a_ctime_that_differs_between_lstat_and_fstat(tmp_path):
    result, _ = run_snapshot(tmp_path, "posix", ctime_skew=1)
    assert result.returncode != 0
    assert "target identity changed before snapshot" in result.stderr


def test_windows_ignores_the_cross_api_ctime_difference(tmp_path):
    result, target = run_snapshot(tmp_path, "nt", ctime_skew=1)
    assert result.returncode == 0, result.stderr
    kind, *_, digest = json.loads(result.stdout)
    assert kind == "file"
    assert digest == hashlib.sha256(target.read_bytes()).hexdigest()


def test_windows_still_rejects_a_file_that_changes_between_the_two_lstat_calls(tmp_path):
    result, _ = run_snapshot(tmp_path, "nt", ctime_skew=1, lstat_after_mtime_skew=1)
    assert result.returncode != 0
    assert "target identity changed during snapshot" in result.stderr


def test_descriptor_is_opened_with_o_binary_when_the_platform_has_that_flag(tmp_path):
    result, _ = run_snapshot(tmp_path, "nt", fake_o_binary=FAKE_O_BINARY)
    assert result.returncode == 0, result.stderr
    (flags,) = json.loads(result.stderr)["flags"]
    assert flags & FAKE_O_BINARY


@pytest.mark.skipif(os.name != "nt", reason="text-mode descriptors exist only on Windows")
def test_windows_snapshot_hashes_the_raw_bytes_of_a_file_with_crlf_and_ctrl_z(tmp_path):
    content = b"first line\r\nsecond line\r\n\x1a after ctrl-z\r\n"
    target = tmp_path / "shim.py"
    target.write_bytes(content)
    result = subprocess.run([sys.executable, "-c", snapshot_snippet(), str(target)], capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    kind, *_, digest = json.loads(result.stdout)
    assert kind == "file"
    assert digest == hashlib.sha256(content).hexdigest()
