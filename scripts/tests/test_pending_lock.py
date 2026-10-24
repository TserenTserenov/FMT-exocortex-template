#!/usr/bin/env python3
"""Lock file of the pending-publish list without python3/fcntl (issue #1245).

Real bash processes run the production helper definitions extracted from the
pipeline. TEST_PIPELINE points the suite at another copy (mutation checks).
"""
import os
import re
import signal
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PIPELINE = Path(os.environ.get("TEST_PIPELINE", ROOT / "scripts/day-open-pipeline.sh"))
BASH = os.environ.get("TEST_BASH", "bash")
REPO = "/tmp/some repo"
BLOCKED = "список публикаций заблокирован файлом"


class PendingLockTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="pending lock ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.list = self.root / "state dir" / "day-open-pending-publish.list"
        self.list.parent.mkdir()
        self.lock = Path(str(self.list) + ".lock")
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
        script.write_text(f'. "{self.helpers}"\nLIST="{self.list}"\nLOCK="$LIST.lock"\n{body}\n',
                          encoding="utf-8")
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
        """A process holding the lock through the production acquire for `seconds`."""
        return self.spawn(f'day_open_lock_acquire "$LOCK" && echo held\nsleep {seconds}\n'
                          'day_open_lock_release "$LOCK"')

    def wait_held(self, proc):
        self.assertEqual("held", proc.stdout.readline().strip())

    def entries(self):
        if not self.list.exists():
            return []
        return sorted(line.split("\t")[3] for line in self.list.read_text(encoding="utf-8").splitlines())

    def finish(self, proc, timeout=180):
        _, err = proc.communicate(timeout=timeout)
        self.assertEqual(0, proc.returncode, err)
        return err

    def refused(self, proc, timeout=60):
        _, err = proc.communicate(timeout=timeout)
        self.assertEqual(1, proc.returncode, err)
        return err

    # ---- many processes lose nothing ----

    def mixed_round(self):
        seeded = list(range(1, 31))
        added = list(range(101, 106))
        self.list.write_text("".join(f"{REPO}\torigin\trefs/heads/main\t{self.sha(n)}\n" for n in seeded),
                             encoding="utf-8")
        jobs = [self.remove(n) for n in seeded] + [self.record(n) for n in added]
        for job in jobs:
            self.finish(job)
        self.assertEqual([self.sha(n) for n in added], self.entries())
        self.assertFalse(self.lock.exists())
        self.assertEqual([], [p.name for p in self.list.parent.iterdir() if ".lock." in p.name],
                         "prepared files must be cleaned up")

    def test_mixed_35_parallel(self):
        for _ in range(int(os.environ.get("LOCK_ROUNDS", "20"))):
            self.mixed_round()
            self.list.unlink()

    # ---- a holder is never robbed, a refusal is clear ----

    def test_waiter_waits_for_release(self):
        holder = self.holder(3)
        self.wait_held(holder)
        self.finish(self.record(1, DAY_OPEN_LOCK_WAIT_SECS="30"))
        self.finish(holder)
        self.assertEqual([self.sha(1)], self.entries())

    def test_live_holder_refusal(self):
        holder = self.holder(8)
        self.wait_held(holder)
        waiters = [self.record(n, DAY_OPEN_LOCK_WAIT_SECS="2") for n in (1, 2, 3)]
        for waiter in waiters:
            err = self.refused(waiter)
            self.assertIn(BLOCKED, err)
            self.assertIn(str(self.lock), err)
            self.assertIn(f"PID {holder.pid}", err)
            self.assertIn("создан 20", err)
            self.assertIn("удалите этот файл", err)
            self.assertNotIn("не найден", err)
        self.assertEqual(str(holder.pid), self.lock.read_text(encoding="utf-8").strip(), "lock not robbed")
        self.finish(holder)
        self.assertEqual([], self.entries(), "refused records are not written")

    def test_killed_holder_refusal(self):
        holder = self.holder(600)
        self.wait_held(holder)
        holder.send_signal(signal.SIGKILL)
        holder.wait()
        err = self.refused(self.record(1, DAY_OPEN_LOCK_WAIT_SECS="2"))
        self.assertIn(BLOCKED, err)
        self.assertIn(f"PID {holder.pid}", err)
        self.assertIn("Процесс с этим PID не найден", err)
        self.assertTrue(self.lock.exists(), "never taken over automatically")
        self.assertEqual([], self.entries())
        self.lock.unlink()  # the manual step the message asks for
        self.finish(self.record(1))
        self.assertEqual([self.sha(1)], self.entries())

    def test_foreign_pid_no_hint(self):
        # pid 1 belongs to another user: a failed `kill -0` there is EPERM, not "gone".
        self.lock.write_text("1\n", encoding="utf-8")
        err = self.refused(self.record(1, DAY_OPEN_LOCK_WAIT_SECS="1"))
        self.assertIn("PID 1", err)
        self.assertNotIn("не найден", err)

    def test_lock_is_a_directory(self):
        self.lock.mkdir()
        (self.lock / "keep").write_text("x", encoding="utf-8")
        err = self.refused(self.record(1))
        self.assertIn("папка", err)
        self.assertEqual(["keep"], [p.name for p in self.lock.iterdir()], "nothing linked inside")
        self.assertEqual([], self.entries())

    # ---- release and the failed remove ----

    def test_release_keeps_foreign_lock(self):
        self.lock.write_text("424242\n", encoding="utf-8")
        self.finish(self.spawn('day_open_lock_release "$LOCK"'))
        self.assertEqual("424242\n", self.lock.read_text(encoding="utf-8"))
        self.lock.unlink()
        holder = self.holder(1)
        self.wait_held(holder)
        self.assertTrue(self.lock.exists())
        self.finish(holder)
        self.assertFalse(self.lock.exists(), "own lock is released")

    def test_remove_logs_failure(self):
        self.list.write_text(f"{REPO}\torigin\trefs/heads/main\t{self.sha(5)}\n", encoding="utf-8")
        holder = self.holder(6)
        self.wait_held(holder)
        proc = self.spawn('day_open_pending_file() { printf "%s\\n" "$LIST"; }\n'
                          f'day_open_pending_remove "{REPO}" "{self.sha(5)}"',
                          DAY_OPEN_LOCK_WAIT_SECS="2")
        err = self.refused(proc)
        self.assertIn("could not be updated; the record(s) stay", err)
        self.assertIn(self.sha(5), err)
        self.finish(holder)
        self.assertEqual([self.sha(5)], self.entries())


if __name__ == "__main__":
    unittest.main()
