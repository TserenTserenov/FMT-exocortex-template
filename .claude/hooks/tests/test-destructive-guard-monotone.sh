#!/usr/bin/env bash
# test-destructive-guard-monotone.sh — WP-529 F275, rc.10 red team F8: destructive-guard.sh must
# never be looser than the released guards it carries in destructive-guard.d/ (v0.42.1-rc.6 and
# rc.8), on any input. Property test: seeded random texts around here-docs, quotes, comments and
# expansions, plus the F8 rows, are fed to the hook and to each released guard alone; the hook's
# verdict (pass < ask < block) must be at least as strict as every one of them.
# Commands are passed as hook input only; nothing is executed.
#
# Run: bash .claude/hooks/tests/test-destructive-guard-monotone.sh [N]   (N random texts, default 150)
set -uo pipefail

HOOKS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
ROOT="$(cd "$HOOKS/../.." && pwd -P)"
[ -d "$HOOKS/destructive-guard.d" ] || { echo "FAIL: $HOOKS/destructive-guard.d is missing"; exit 1; }

python3 - "$HOOKS" "$ROOT" "${1:-150}" <<'PYEOF'
import glob, json, os, random, subprocess, sys
hooks, root, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
BS = "\\"
PIECES = [": x[ <<W", "cat notes[ <<W", ": a" + BS + " #b <<W", ": $(:)#b <<W", "cat <<W", "cat <<'W'", "bash <<W", ": $((1<<W))",
          ": ${x:-<<W}", "x[1<<W]=5", "x=(a <<W #b", "f()((1<<W))", ": $( : <<W", ")", "`", ": <(: <<W)", "# c " + BS, "# '",
          "echo 'a", "echo \"a", "'", "\"", "echo $'" + BS + "'", "\"${x:-\"", ": # <<W", ": x<<<W #b", "if((1<<W)); then :; fi", "W", "W",
          BS, "data " + BS, ": ${#x}", "case x in x)((1<<W));; esac", "bash <<< 'x' <<'W'", "true", "ls # don't", "{", "}", "(", ")"]
DEST = ["find . -delete", "git push --force", "git reset --hard", "rm -rf build", "git branch -D main",
        "cat README.md > .claude/settings.json", "grep zz README.md > params.yaml", "git push --fo" + BS + "\nrce", "find . -delete" + BS]
rnd = random.Random(20261119)
cases = []
for opener in [": x[ <<W", "cat notes[ <<W", ": a" + BS + " #b <<W", ": $(:)#b <<W"]:
    for dest in DEST[:5]:
        cases.append(opener + "\necho 'a\nW\n" + dest)
for _ in range(n):
    lines = [rnd.choice(PIECES) for _ in range(rnd.randint(1, 5))]
    lines.insert(rnd.randint(0, len(lines)), rnd.choice(DEST))
    lines += [rnd.choice(PIECES) for _ in range(rnd.randint(0, 2))]
    cases.append(rnd.choice(["\n"] * 6 + [" ; ", " && ", " "]).join(lines))
RANK = {"pass": 0, "ask": 1, "block": 2}
env = dict(os.environ, DG_LEGACY_HOOK_DIR=hooks)
env.pop("CC_ALLOW_DESTRUCTIVE_INPUT", None)


def verdict(script, cmd):
    p = subprocess.run(["bash", script], input=json.dumps({"tool_input": {"command": cmd}, "cwd": root}).encode(),
                       capture_output=True, env=env, cwd=root, timeout=120)
    if p.returncode == 2:
        return "block"
    if p.returncode != 0:
        return "block"
    return "ask" if b'"ask"' in p.stdout else "pass"


legacy = sorted(glob.glob(hooks + "/destructive-guard.d/*.sh"))
fails = 0
for cmd in cases:
    mine = verdict(hooks + "/destructive-guard.sh", cmd)
    for guard in legacy:
        old = verdict(guard, cmd)
        if RANK[mine] < RANK[old]:
            fails += 1
            print("FAIL: %s is %s, %s alone is %s" % (json.dumps(cmd), mine, os.path.basename(guard), old))
print("monotone: %d texts x %d released guards, %d looser" % (len(cases), len(legacy), fails))
sys.exit(1 if fails else 0)
PYEOF
