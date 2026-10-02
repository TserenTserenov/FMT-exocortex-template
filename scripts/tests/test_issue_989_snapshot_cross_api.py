"""Regression for issue #989: the agent-fault target snapshot compared lstat with fstat on st_ctime_ns.

On Windows lstat reads the directory entry and fstat the open handle, and the two disagree on st_ctime_ns for
a file written moments ago, so every legacy-shim snapshot failed with "target identity changed before
snapshot" and update.sh ended with exit 3 and a stuck .update-incomplete marker. The cross-API comparison is
now POSIX only; the lstat taken after the read, compared with the one before it, still covers a swap.

update.sh embeds the Python in a bash function, so the test cuts the snippet out of the function and runs it
under a harness that skews fstat's st_ctime_ns, pretends to be Windows (os.name) or changes the file between
the two lstat calls. Nothing here needs Windows.
"""
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

HARNESS = r'''
import hashlib, json, os, stat, sys, types  # imported first: their platform checks run before os.name is patched

snippet, path, fake_os_name, ctime_skew, lstat_after_mtime_skew = sys.argv[1:6]
ctime_skew, lstat_after_mtime_skew = int(ctime_skew), int(lstat_after_mtime_skew)


def view(result, **override):
    fields = {name: getattr(result, name) for name in
              ("st_dev", "st_ino", "st_mode", "st_size", "st_mtime_ns", "st_ctime_ns")}
    fields.update(override)
    return types.SimpleNamespace(**fields)


real_fstat, real_lstat = os.fstat, os.lstat
calls = {"lstat": 0}


def fstat(descriptor):
    result = real_fstat(descriptor)
    return view(result, st_ctime_ns=result.st_ctime_ns + ctime_skew)


def lstat(target):
    calls["lstat"] += 1
    result = real_lstat(target)
    if calls["lstat"] == 2:
        return view(result, st_mtime_ns=result.st_mtime_ns + lstat_after_mtime_skew)
    return view(result)


os.fstat, os.lstat = fstat, lstat
if fake_os_name != "-":
    os.name = fake_os_name
sys.argv = ["-c", path]
exec(compile(snippet, "<snapshot>", "exec"), {"__name__": "__main__"})
'''


def snapshot_snippet() -> str:
    text = (ROOT / "update.sh").read_text(encoding="utf-8")
    start = text.index("agent_fault_target_snapshot() {")
    body = text[start:text.index("\n}\n", start)]
    found = re.search(r"\$PY_BIN -c '\n(.*)\n' \"\$1\"", body, re.S)
    assert found, "the snapshot snippet was not found in agent_fault_target_snapshot of update.sh"
    return found.group(1)


def run_snapshot(tmp_path: Path, fake_os_name: str = "-", ctime_skew: int = 0, lstat_after_mtime_skew: int = 0):
    target = tmp_path / "shim.py"
    target.write_bytes(b"print('legacy shim')\n")
    result = subprocess.run(
        [sys.executable, "-c", HARNESS, snapshot_snippet(), str(target), fake_os_name,
         str(ctime_skew), str(lstat_after_mtime_skew)],
        capture_output=True, text=True,
    )
    return result, target


def test_unskewed_snapshot_succeeds_and_reports_the_content_hash(tmp_path):
    result, target = run_snapshot(tmp_path)
    assert result.returncode == 0, result.stderr
    kind, *_, digest = json.loads(result.stdout)
    assert kind == "file"
    assert digest == hashlib.sha256(target.read_bytes()).hexdigest()


def test_posix_still_rejects_a_ctime_that_differs_between_lstat_and_fstat(tmp_path):
    result, _ = run_snapshot(tmp_path, ctime_skew=1)
    assert result.returncode != 0
    assert "target identity changed before snapshot" in result.stderr


def test_windows_ignores_the_cross_api_ctime_difference(tmp_path):
    result, target = run_snapshot(tmp_path, fake_os_name="nt", ctime_skew=1)
    assert result.returncode == 0, result.stderr
    kind, *_, digest = json.loads(result.stdout)
    assert kind == "file"
    assert digest == hashlib.sha256(target.read_bytes()).hexdigest()


def test_windows_still_rejects_a_file_that_changes_between_the_two_lstat_calls(tmp_path):
    result, _ = run_snapshot(tmp_path, fake_os_name="nt", ctime_skew=1, lstat_after_mtime_skew=1)
    assert result.returncode != 0
    assert "target identity changed during snapshot" in result.stderr
