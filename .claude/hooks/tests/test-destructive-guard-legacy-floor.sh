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
