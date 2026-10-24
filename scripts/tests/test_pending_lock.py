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
        self.lock = Path(str(self.list) + ".lock")
        self.mutex = Path(str(self.lock) + ".takeover")
        self.log = self.root / "section.log"
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

    def holder(self, seconds, release=True):
        """A process holding the lock through the production acquire, for `seconds`."""
        tail = ('day_open_lock_release "$LOCK"\n' if release else "")
        return self.spawn(f'day_open_lock_acquire "$LOCK" && echo held\nsleep {seconds}\n{tail}')

    def section(self, tag, hold=0.2, **env):
        """Takes the lock, logs enter/exit around a pause, releases: overlaps show in the log."""
        return self.spawn(
            f'day_open_lock_acquire "$LOCK" || exit 1\n'
            f'echo "enter {tag}" >> "{self.log}"\nsleep {hold}\necho "exit {tag}" >> "{self.log}"\n'
            f'day_open_lock_release "$LOCK"', **env)

    def assert_no_overlap(self, tags):
        rows = self.log.read_text(encoding="utf-8").split("\n")[:-1]
        inside = None
        for row in rows:
            kind, tag = row.split()
            if kind == "enter":
                self.assertIsNone(inside, f"{tag} entered while {inside} was inside: {rows}")
                inside = tag
            else:
                self.assertEqual(inside, tag, rows)
                inside = None
        self.assertEqual(sorted(tags), sorted(r.split()[1] for r in rows if r.startswith("enter")), rows)

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

    def kill(self, proc):
        proc.send_signal(signal.SIGKILL)
        proc.wait()

    def age(self, path, seconds):
        old = time.time() - seconds
        os.utime(path, (old, old))

    def plant(self, content, age=60):
        self.lock.write_text(content, encoding="utf-8")
        self.age(self.lock, age)

    # ---- the lock is a file with its owner inside from the first instant ----

    def test_lock_always_has_its_owner(self):
        holder = self.holder(3)
        self.wait_held(holder)
        content = self.lock.read_text(encoding="utf-8").strip()
        self.assertRegex(content, r"^[0-9]+ ")
        self.assertEqual(str(holder.pid), content.split()[0])
        self.finish(holder)
        self.assertFalse(self.lock.exists())

    # ---- a live owner is never robbed ----

    def test_live_holder_not_robbed(self):
        holder = self.holder(13)
        self.wait_held(holder)
        waiters = [self.record(n, DAY_OPEN_LOCK_STALE_SECS="2") for n in (1, 2, 3)]
        errors = [self.finish(w) for w in waiters]
        self.finish(holder)
        self.assertEqual([self.sha(n) for n in (1, 2, 3)], self.entries())
        for err in errors:
            self.assertNotIn("taking it over", err)

    def test_waiter_gives_up(self):
        holder = self.holder(6)
        self.wait_held(holder)
        waiter = self.record(1, DAY_OPEN_LOCK_STALE_SECS="1", DAY_OPEN_LOCK_WAIT_SECS="2")
        _, err = waiter.communicate(timeout=60)
        self.assertNotEqual(0, waiter.returncode)
        self.assertIn("giving up", err)
        self.finish(holder)
        self.assertEqual([], self.entries())

    def test_foreign_pid_alive(self):
        # pid 1 belongs to another user: `kill -0` would fail with EPERM and call it gone.
        start = subprocess.run(["ps", "-p", "1", "-o", "lstart="], capture_output=True, text=True)
        start = " ".join(start.stdout.split())
        self.assertTrue(start)
        self.plant(f"1 {start}\n")
        waiter = self.record(1, DAY_OPEN_LOCK_STALE_SECS="1", DAY_OPEN_LOCK_WAIT_SECS="2")
        _, err = waiter.communicate(timeout=60)
        self.assertNotEqual(0, waiter.returncode)
        self.assertNotIn("taking it over", err)
        self.assertEqual([], self.entries())

    # ---- a dead owner is replaced ----

    def test_killed_holder_taken_over(self):
        holder = self.holder(600)
        self.wait_held(holder)
        self.kill(holder)
        self.assertTrue(self.lock.exists())
        started = time.time()
        err = self.finish(self.record(1, DAY_OPEN_LOCK_STALE_SECS="2"), timeout=60)
        self.assertLess(time.time() - started, 30)
        self.assertIn("taking it over", err)
        self.assertEqual([self.sha(1)], self.entries())
        self.assertFalse(self.lock.exists())

    def test_dead_fresh_respected(self):
        holder = self.holder(600)
        self.wait_held(holder)
        self.kill(holder)
        waiter = self.record(1, DAY_OPEN_LOCK_STALE_SECS="60", DAY_OPEN_LOCK_WAIT_SECS="1")
        _, err = waiter.communicate(timeout=60)
        self.assertNotEqual(0, waiter.returncode)
        self.assertEqual([], self.entries())

    def test_reused_pid_is_not_an_owner(self):
        # The pid is alive but was started at another time: the real owner is gone.
        self.plant(f"{os.getpid()} Mon Jan  1 00:00:00 2001\n")
        err = self.finish(self.record(1, DAY_OPEN_LOCK_STALE_SECS="2"), timeout=60)
        self.assertIn("taking it over", err)
        self.assertEqual([self.sha(1)], self.entries())

    def test_empty_lock_not_owner(self):
        self.plant("")
        self.finish(self.record(1, DAY_OPEN_LOCK_STALE_SECS="2"), timeout=60)
        self.assertEqual([self.sha(1)], self.entries())

    def test_fresh_empty_lock_respected(self):
        self.plant("", age=0)
        waiter = self.record(1, DAY_OPEN_LOCK_STALE_SECS="30", DAY_OPEN_LOCK_WAIT_SECS="1")
        waiter.communicate(timeout=60)
        self.assertNotEqual(0, waiter.returncode)
        self.assertEqual([], self.entries())

    # ---- release, takeover and replacement never remove somebody else's lock ----

    def test_release_keeps_new_lock(self):
        old = self.holder(3)
        self.wait_held(old)
        replacement = self.root / "replacement"
        replacement.write_text("424242 Mon Jan  1 00:00:00 2001\n", encoding="utf-8")
        os.replace(replacement, self.lock)
        self.finish(old)  # the old owner finishes and releases
        self.assertEqual("424242 Mon Jan  1 00:00:00 2001\n", self.lock.read_text(encoding="utf-8"))

    def test_interleaved_takeover(self):
        # Waiter 1 judged the lock dead and sits inside the takeover mutex. Others arrive
        # now; nobody may enter or remove anything until it is done, and then one at a time.
        holder = self.holder(600)
        self.wait_held(holder)
        self.kill(holder)
        gate = self.root / "gate"
        first = self.section("first", DAY_OPEN_LOCK_STALE_SECS="1", DAY_OPEN_LOCK_TEST_GATE=str(gate))
        deadline = time.time() + 30
        while not self.mutex.exists():
            self.assertLess(time.time(), deadline, "first waiter never reached the takeover")
            time.sleep(0.05)
        others = [self.section(f"other{n}", DAY_OPEN_LOCK_STALE_SECS="1") for n in range(4)]
        time.sleep(2.5)
        self.assertFalse(self.log.exists(), "somebody entered while the takeover was in progress")
        gate.write_text("", encoding="utf-8")
        for proc in [first] + others:
            self.finish(proc, timeout=120)
        self.assert_no_overlap(["first"] + [f"other{n}" for n in range(4)])

    def test_empty_lock_judged_then_gate(self):
        # Same interleaving for an ownerless old lock: it cannot be swapped under the judge.
        self.plant("")
        gate = self.root / "gate"
        first = self.section("first", DAY_OPEN_LOCK_STALE_SECS="1", DAY_OPEN_LOCK_TEST_GATE=str(gate))
        deadline = time.time() + 30
        while not self.mutex.exists():
            self.assertLess(time.time(), deadline)
            time.sleep(0.05)
        second = self.section("second", DAY_OPEN_LOCK_STALE_SECS="1")
        time.sleep(2)
        self.assertFalse(self.log.exists())
        gate.write_text("", encoding="utf-8")
        for proc in (first, second):
            self.finish(proc, timeout=120)
        self.assert_no_overlap(["first", "second"])

    def test_waiters_dont_steal(self):
        for _ in range(3):
            holder = self.holder(600)
            self.wait_held(holder)
            self.kill(holder)
            waiters = [self.section(f"w{n}", hold=0.05, DAY_OPEN_LOCK_STALE_SECS="1") for n in range(8)]
            for waiter in waiters:
                self.finish(waiter, timeout=120)
            self.assert_no_overlap([f"w{n}" for n in range(8)])
            self.log.unlink()

    def test_stale_mutex_removed(self):
        self.mutex.mkdir()
        self.age(self.mutex, 120)
        self.plant("")
        self.finish(self.record(1, DAY_OPEN_LOCK_STALE_SECS="2"), timeout=60)
        self.assertEqual([self.sha(1)], self.entries())
        self.assertFalse(self.mutex.exists())

    # ---- losing the lock must be visible ----

    def test_remove_reports_failure(self):
        self.list.write_text(f"{REPO}\torigin\trefs/heads/main\t{self.sha(5)}\n", encoding="utf-8")
        holder = self.holder(6)
        self.wait_held(holder)
        proc = self.spawn(
            'day_open_pending_file() { printf "%s\\n" "$LIST"; }\n'
            f'day_open_pending_remove "{REPO}" "{self.sha(5)}"',
            DAY_OPEN_LOCK_STALE_SECS="1", DAY_OPEN_LOCK_WAIT_SECS="2")
        _, err = proc.communicate(timeout=60)
        self.assertNotEqual(0, proc.returncode)
        self.assertIn("could not be updated; the record(s) stay", err)
        self.assertIn(self.sha(5), err)
        self.finish(holder)
        self.assertEqual([self.sha(5)], self.entries())

    # ---- many processes ----

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

    def test_mixed_35_parallel(self):
        for _ in range(int(os.environ.get("LOCK_ROUNDS", "20"))):
            self.mixed_round()
            self.list.unlink()


if __name__ == "__main__":
    unittest.main()
