#!/usr/bin/env bash
# test-destructive-guard-legacy-floor.sh — WP-529 F275, rc.11 red team F12: destructive-guard.sh
# keeps the released guards in destructive-guard.d/ as a floor, and every way that floor can fail
# must block. Each case runs the hook of a scratch copy of .claude/hooks (and .claude/bin) on the
# F8 text, which the hook's own parser lets through and the released guards block; the copy is
# damaged, reached through a symlink, or run with a hostile environment. Also: the runner of one
# released guard stops it on its time limit, when killed and when the hook is gone, leaving no
# process; the hook leaves no temporary folder. Commands are hook input only; nothing is executed.
#
# Run: bash .claude/hooks/tests/test-destructive-guard-legacy-floor.sh
set -uo pipefail

HOOKS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
ROOT="$(cd "$HOOKS/../.." && pwd -P)"
[ -d "$HOOKS/destructive-guard.d" ] || { echo "FAIL: $HOOKS/destructive-guard.d is missing"; exit 1; }

python3 - "$HOOKS" "$ROOT" <<'PYEOF'
import json, os, shutil, signal, subprocess, sys, tempfile, time
hooks, root = sys.argv[1], sys.argv[2]
work = tempfile.mkdtemp(prefix="dg-floor-")
tmp = os.path.join(work, "tmp")
os.makedirs(tmp)
ENV = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "HOME": work, "LC_ALL": "en_US.UTF-8", "TMPDIR": tmp}
F8 = ": x[ <<W\necho 'a\nW\nfind . -delete"
fails = []


def copy(name, damage=None):
    ws = os.path.join(work, name)
    os.makedirs(ws + "/.claude")
    shutil.copytree(hooks, ws + "/.claude/hooks", symlinks=True)
    if os.path.isdir(root + "/.claude/bin"):
        shutil.copytree(root + "/.claude/bin", ws + "/.claude/bin")
    if damage:
        damage(ws + "/.claude/hooks/destructive-guard.d")
    return ws


def verdict(ws, cmd, env=None, hook=None):
    hook = hook or ws + "/.claude/hooks/destructive-guard.sh"
    p = subprocess.run(["bash", hook], input=json.dumps({"tool_input": {"command": cmd}, "cwd": ws}).encode(),
                       capture_output=True, env=env or ENV, cwd=ws, timeout=120)
    if p.returncode == 2:
        return "block"
    return "ask" if p.returncode == 0 and b'"ask"' in p.stdout else "pass" if p.returncode == 0 and not p.stdout.strip() else "odd"


def expect(name, got, want="block"):
    if got != want:
        fails.append("%s: %s, want %s" % (name, got, want))


def each(d, f):
    for n in sorted(os.listdir(d)):
        f(os.path.join(d, n))


def rewrite(body):
    return lambda d: each(d, lambda p: open(p, "w").write("#!/usr/bin/env bash\n" + body + "\n"))


DAMAGE = [
    ("folder missing", lambda d: shutil.rmtree(d)),
    ("folder empty", lambda d: each(d, os.remove)),
    ("rc.10 missing", lambda d: os.remove(d + "/v0.42.1-rc.10.sh")),
    ("folder is a file", lambda d: (shutil.rmtree(d), open(d, "w").write("x"))),
    ("folder is a dangling symlink", lambda d: (shutil.rmtree(d), os.symlink("/nonexistent-dg", d))),
    ("files renamed", lambda d: each(d, lambda p: os.rename(p, p + ".bak"))),
    ("files are dangling symlinks", lambda d: each(d, lambda p: (os.remove(p), os.symlink("/nonexistent-dg", p)))),
    ("files unreadable", lambda d: each(d, lambda p: os.chmod(p, 0))),
    ("folder unreadable", lambda d: os.chmod(d, 0)),
    ("files truncated", lambda d: each(d, lambda p: open(p, "w").write(open(p).read()[:5000]))),
    ("files empty", rewrite("")),
    ("files print garbage", rewrite("echo garbage")),
    ("files answer deny", rewrite("echo '{\"hookSpecificOutput\":{\"permissionDecision\":\"deny\"}}'")),
    ("files hang", rewrite("sleep 60")),
]
base = copy("base")
expect("intact copy, F8 text", verdict(base, F8))
expect("intact copy, ls", verdict(base, "ls -la"), "pass")
for name, damage in DAMAGE:
    ws = copy(name.replace(" ", "-"), damage)
    expect(name, verdict(ws, F8))
    try:
        os.chmod(ws + "/.claude/hooks/destructive-guard.d", 0o755)
    except OSError:
        pass

# The hook reached through a file symlink in another folder still finds its floor.
os.makedirs(work + "/elsewhere/.claude/hooks")
os.symlink(base + "/.claude/hooks/destructive-guard.sh", work + "/elsewhere/.claude/hooks/destructive-guard.sh")
expect("hook through a file symlink", verdict(base, F8, hook=work + "/elsewhere/.claude/hooks/destructive-guard.sh"))

# A hostile environment of the caller does not switch the floor off.
open(work + "/benv.sh", "w").write("exit() { builtin exit 0; }\n")
for k, v in [("SHELLOPTS", "noglob"), ("BASH_ENV", work + "/benv.sh"), ("ENV", work + "/benv.sh"), ("GLOBIGNORE", "*"),
             ("BASHOPTS", "nullglob"), ("BASHOPTS", "failglob"), ("IFS", "/"), ("CDPATH", "/"), ("POSIXLY_CORRECT", "1"),
             ("TMPDIR", ""), ("DG_LEGACY_HOOK_DIR", "/nonexistent"), ("DG_LEGACY_DIR", "/nonexistent"), ("LC_ALL", "C")]:
    expect("env %s=%s" % (k, v), verdict(base, F8, env=dict(ENV, **{k: v})))

# No temporary folder is left after an allow, a released-guard block and an own block.
before = set(os.listdir(tmp))
for c in ("ls -la", F8, "git push --force"):
    verdict(base, c)
left = sorted(set(os.listdir(tmp)) - before)
if left:
    fails.append("temporary folders left: %s" % left)

# rc.12 red team F15: a jq that writes CR LF (as on Windows) on any platform. The floor gets a jq
# without the CRs, wherever the probe sees them; the F8 text still blocks.
fakejq = work + "/crjq"
os.makedirs(fakejq)
real_jq = shutil.which("jq")
open(fakejq + "/jq", "w").write(
    "#!/bin/bash\nset -o pipefail\nargs=(); b=0\nfor a in \"$@\"; do if [ \"$a\" = -b ]; then b=1; else args+=(\"$a\"); fi; done\n"
    "if [ $b = 1 ]; then exec '%s' \"${args[@]}\"; fi\n'%s' \"${args[@]}\" | perl -pe 's/\\n/\\r\\n/'\n" % (real_jq, real_jq))
os.chmod(fakejq + "/jq", 0o755)
expect("jq writing CR LF, F8 text", verdict(base, F8, env=dict(ENV, PATH=fakejq + ":" + ENV["PATH"])))
expect("jq writing CR LF, ls", verdict(base, "ls -la", env=dict(ENV, PATH=fakejq + ":" + ENV["PATH"])), "pass")

# rc.12 red team F17: the command text does not outlive a hook killed by a signal it cannot trap.
big = "ls " + "a" * 200000
for sig in (signal.SIGKILL, signal.SIGQUIT):
    before = set(os.listdir(tmp))
    p = subprocess.Popen(["bash", base + "/.claude/hooks/destructive-guard.sh", "--dg-budget"], stdin=subprocess.PIPE,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=ENV, cwd=base)
    p.stdin.write(json.dumps({"tool_input": {"command": big}, "cwd": base}).encode()); p.stdin.close()
    time.sleep(1.0)
    p.send_signal(sig)
    p.wait(30)
    time.sleep(1.5)
    left = sorted(set(os.listdir(tmp)) - before)
    if left:
        fails.append("%s: temporary folder left: %s" % (sig.name, left))

# The total time budget: past it the hook's process group is stopped and the answer is a block.
src_wrap = open(hooks + "/destructive-guard.sh").read()
w0 = src_wrap.index("\n  perl -e '", src_wrap.index("--dg-budget ]; then")) + len("\n  perl -e '")
wrapper = src_wrap[w0:src_wrap.index("' -- 40 bash", w0)]
mark2 = "DGBUDGETMARK%d" % os.getpid()
t0 = time.time()
q = subprocess.run(["perl", "-e", wrapper, "--", "1", "bash", "-c", "exec -a %s sleep 30" % mark2], capture_output=True, timeout=60)
took = time.time() - t0
if q.returncode != 2 or b"BLOCKED" not in q.stderr or took > 10:
    fails.append("budget: exit %d after %.1f s, %r" % (q.returncode, took, q.stderr[:120]))
time.sleep(0.3)
if [x for x in subprocess.run(["pgrep", "-f", mark2], capture_output=True).stdout.split() if x]:
    fails.append("budget: the stopped hook is still running")

# rc.14 red team F21: a perl that exits 0 without running anything does not make an allow.
fakeperl = work + "/fakeperl"
os.makedirs(fakeperl)
open(fakeperl + "/perl", "w").write("#!/bin/sh\nexit 0\n")
os.chmod(fakeperl + "/perl", 0o755)
expect("perl exits 0 without running, ls", verdict(base, "ls -la", env=dict(ENV, PATH=fakeperl + ":" + ENV["PATH"])))

# rc.14 red team F22: a stopped timer does not leave the hook waiting; a second clock blocks.
p = subprocess.Popen(["bash", base + "/.claude/hooks/destructive-guard.sh"], stdin=subprocess.PIPE,
                     stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, env=ENV, cwd=base)
p.stdin.write(json.dumps({"tool_input": {"command": "ls -la"}, "cwd": base}).encode()); p.stdin.close()
time.sleep(0.2)
stopped = []
for k in subprocess.run(["pgrep", "-P", str(p.pid)], capture_output=True, text=True).stdout.split():
    if "perl" in subprocess.run(["ps", "-o", "comm=", "-p", k], capture_output=True, text=True).stdout:
        os.kill(int(k), signal.SIGSTOP); stopped.append(int(k))
t0 = time.time()
try:
    p.wait(70)
    if p.returncode != 2:
        fails.append("stopped timer: exit %d, want a block" % p.returncode)
except subprocess.TimeoutExpired:
    fails.append("stopped timer: the hook still waits after 70 s")
    p.kill()
for k in stopped:
    try:
        os.kill(k, signal.SIGKILL)
    except ProcessLookupError:
        pass
if not stopped:
    fails.append("stopped timer: no timer process found")

# The runner of one released guard, taken from the hook: time limit, kill, gone hook.
src = open(hooks + "/destructive-guard.sh").read()
if "DG_LEGACY_RUN_PL='" not in src:
    fails.append("runner: DG_LEGACY_RUN_PL not found in the hook")
    for f in fails:
        print("FAIL: " + f)
    print("legacy floor: %d failures" % len(fails))
    sys.exit(1)
start = src.index("DG_LEGACY_RUN_PL='") + len("DG_LEGACY_RUN_PL='")
runner = src[start:src.index("\n'\n", start)]
mark = "DGFLOORMARK%d" % os.getpid()
open(work + "/slow.sh", "w").write("exec -a %s sleep 30\n" % mark)
open(work + "/three.sh", "w").write("echo out; exit 3\n")
open(work + "/in", "w").write("")


def alive():
    return [x for x in subprocess.run(["pgrep", "-f", mark], capture_output=True).stdout.decode().split() if x]


def start_runner(guard, limit, rc):
    return subprocess.Popen(["perl", "-e", runner, "--", guard, hooks, work + "/in", work + "/o", work + "/e", rc, str(limit)],
                            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


p = start_runner(work + "/three.sh", 10, work + "/rc-three")
p.wait(30)
if open(work + "/rc-three").read().strip() != "3":
    fails.append("runner: exit code 3 not recorded")
p = start_runner(work + "/slow.sh", 1, work + "/rc-slow")
p.wait(30)
time.sleep(0.3)
if open(work + "/rc-slow").read().strip() != "timeout":
    fails.append("runner: time limit not recorded as timeout")
if alive():
    fails.append("runner: the guard outlived its time limit")
p = start_runner(work + "/slow.sh", 30, work + "/rc-term")
time.sleep(1)
p.send_signal(signal.SIGTERM)
p.wait(30)
time.sleep(0.3)
if alive():
    fails.append("runner: the guard outlived a killed runner")
if os.path.exists(work + "/rc-term"):
    fails.append("runner: a killed run left a verdict")
# The hook gone: the runner sees its parent change and stops the guard.
q = subprocess.Popen(["bash", "-c", "perl -e \"$1\" -- \"$2\" \"$3\" \"$4\" \"$5\" \"$6\" \"$7\" 30 & sleep 1; kill -9 $$",
                      "x", runner, work + "/slow.sh", hooks, work + "/in", work + "/o", work + "/e", work + "/rc-orphan"],
                     stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
q.wait(30)
time.sleep(1)
if alive():
    fails.append("runner: the guard outlived the hook")
subprocess.run(["pkill", "-f", mark])

for root_dir, dirs, files in os.walk(work):
    for d in dirs:
        try:
            os.chmod(os.path.join(root_dir, d), 0o755)
        except OSError:
            pass
shutil.rmtree(work, ignore_errors=True)
for f in fails:
    print("FAIL: " + f)
print("legacy floor: %d failures" % len(fails))
sys.exit(1 if fails else 0)
PYEOF
