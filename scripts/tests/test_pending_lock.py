#!/usr/bin/env python3
"""Directory lock of the pending-publish list without python3/fcntl (issue #1245).

Real bash processes run the production helper definitions extracted from the
pipeline. TEST_PIPELINE points the suite at another copy (mutation check).
"""
import os
import re
import signal
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PIPELINE = Path(os.environ.get("TEST_PIPELINE", ROOT / "scripts/day-open-pipeline.sh"))
BASH = os.environ.get("TEST_BASH", "bash")
REPO = "/tmp/some repo"


class PendingLockTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="pending lock ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.list = self.root / "state dir" / "day-open-pending-publish.list"
        self.list.parent.mkdir()
        self.lockdir = Path(str(self.list) + ".lockdir")
        source = PIPELINE.read_text(encoding="utf-8")
        defs = [m.group() for m in re.finditer(r"^day_open_\w+\(\) \{\n.*?^\}\n", source,
                                               re.MULTILINE | re.DOTALL)]
        self.helpers = self.root / "helpers.sh"
        self.helpers.write_text("set -uo pipefail\n" + "\n".join(defs) + "\n", encoding="utf-8")
        self.env = dict(os.environ, DAY_OPEN_PYTHON="/nonexistent/python")
        self.processes = []
        self.addCleanup(self.reap)

    def reap(self):
        for proc in self.processes:
            if proc.poll() is None:
                proc.kill()
            proc.wait()
            for pipe in (proc.stdout, proc.stderr):
                if pipe:
                    pipe.close()

    @staticmethod
    def sha(n):
        return "%040d" % n

    def spawn(self, body, **env):
        script = self.root / f"job{len(self.processes)}.sh"
        script.write_text(f'. "{self.helpers}"\nLIST="{self.list}"\n{body}\n', encoding="utf-8")
        proc = subprocess.Popen([BASH, str(script)], env=dict(self.env, **env),
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.processes.append(proc)
        return proc

    def record(self, n, **env):
        return self.spawn(f'day_open_pending_update_fallback "$LIST" record "{REPO}" origin '
                          f'refs/heads/main {self.sha(n)}', **env)

    def remove(self, n, **env):
        return self.spawn(f'day_open_pending_update_fallback "$LIST" remove "{REPO}" "{self.sha(n)}"',
                          **env)

    def holder(self, seconds):
        """A process that holds the lock the way the production code does, for `seconds`."""
        return self.spawn(
            f'mkdir "$LIST.lockdir" && printf "%s\\n" "$$" > "$LIST.lockdir/owner" && echo held\n'
            f'sleep {seconds}\n'
            f'printf "%s\\t%s\\t%s\\t%s\\n" "{REPO}" origin refs/heads/main {self.sha(999)} >> "$LIST"\n'
            f'rm -f "$LIST.lockdir/owner"; rmdir "$LIST.lockdir"')

    def wait_held(self, proc):
        self.assertEqual("held", proc.stdout.readline().strip())

    def entries(self):
        if not self.list.exists():
            return []
        return sorted(line.split("\t")[3] for line in self.list.read_text(encoding="utf-8").splitlines())

    def finish(self, proc, timeout=180):
        out, err = proc.communicate(timeout=timeout)
        self.assertEqual(0, proc.returncode, err)
        return err

    def test_live_holder_not_robbed(self):
        holder = self.holder(13)
        self.wait_held(holder)
        waiters = [self.record(n, DAY_OPEN_LOCK_STALE_SECS="2") for n in (1, 2, 3)]
        errors = [self.finish(w) for w in waiters]
        self.finish(holder)
        self.assertEqual([self.sha(n) for n in (1, 2, 3, 999)], self.entries())
        for err in errors:
            self.assertNotIn("taking it over", err)
        self.assertFalse(self.lockdir.exists())

    def test_waiter_gives_up(self):
        holder = self.holder(6)
        self.wait_held(holder)
        waiter = self.record(1, DAY_OPEN_LOCK_STALE_SECS="1", DAY_OPEN_LOCK_WAIT_SECS="2")
        _, err = waiter.communicate(timeout=60)
        self.assertNotEqual(0, waiter.returncode)
        self.assertIn("giving up", err)
        self.finish(holder)
        self.assertEqual([self.sha(999)], self.entries())

    def test_killed_holder_taken_over(self):
        holder = self.holder(600)
        self.wait_held(holder)
        holder.send_signal(signal.SIGKILL)
        holder.wait()
        self.assertTrue(self.lockdir.exists())
        started = time.time()
        err = self.finish(self.record(1, DAY_OPEN_LOCK_STALE_SECS="2"), timeout=60)
        self.assertLess(time.time() - started, 30)
        self.assertIn("taking it over", err)
        self.assertEqual([self.sha(1)], self.entries())
        self.assertFalse(self.lockdir.exists())

    def test_ownerless_lock_taken(self):
        self.lockdir.mkdir()
        old = time.time() - 60
        os.utime(self.lockdir, (old, old))
        self.finish(self.record(1, DAY_OPEN_LOCK_STALE_SECS="2"), timeout=60)
        self.assertEqual([self.sha(1)], self.entries())

    def test_fresh_ownerless_respected(self):
        self.lockdir.mkdir()
        waiter = self.record(1, DAY_OPEN_LOCK_STALE_SECS="30", DAY_OPEN_LOCK_WAIT_SECS="1")
        _, err = waiter.communicate(timeout=60)
        self.assertNotEqual(0, waiter.returncode)
        self.assertEqual([], self.entries())

    def test_waiters_dont_steal(self):
        holder = self.holder(600)
        self.wait_held(holder)
        holder.send_signal(signal.SIGKILL)
        holder.wait()
        waiters = [self.record(n, DAY_OPEN_LOCK_STALE_SECS="1") for n in range(1, 9)]
        for waiter in waiters:
            self.finish(waiter, timeout=120)
        self.assertEqual([self.sha(n) for n in range(1, 9)], self.entries())

    def mixed_round(self):
        seeded = list(range(1, 31))
        added = list(range(101, 106))
        self.list.write_text("".join(f"{REPO}\torigin\trefs/heads/main\t{self.sha(n)}\n" for n in seeded),
                             encoding="utf-8")
        jobs = [self.remove(n) for n in seeded] + [self.record(n) for n in added]
        for job in jobs:
            self.finish(job)
        self.assertEqual([self.sha(n) for n in added], self.entries())
        self.assertFalse(self.lockdir.exists())

    def test_mixed_35_parallel(self):
        for _ in range(int(os.environ.get("LOCK_ROUNDS", "20"))):
            self.mixed_round()
            self.list.unlink()


if __name__ == "__main__":
    unittest.main()
