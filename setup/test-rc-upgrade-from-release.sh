#!/usr/bin/env bash
# test-rc-upgrade-from-release.sh RC_TAG PREV_TAG [REPO_URL]
#
# WP-529 Ф270, F3 of the v0.42.0-rc.4 red team: the upgrade job of Validate Template took an
# internal commit of the candidate as "previous" and never ran update.sh, so the path users take
# (published release -> candidate) was proven only by hand. This runs it for real: a clean install
# of PREV_TAG, user edits on top, `IWE_UPDATE_CHANNEL=rc update.sh --yes`, then every delivered
# file must match the candidate's manifest, carry +x where git has 100755, the edits must survive,
# and a second run must find nothing to do. update.sh downloads by tag, so RC_TAG must already be
# pushed: release-candidate.yml runs this right after tagging.
set -uo pipefail

RC_TAG="${1:?usage: test-rc-upgrade-from-release.sh RC_TAG PREV_TAG [REPO_URL]}"
PREV_TAG="${2:?usage: test-rc-upgrade-from-release.sh RC_TAG PREV_TAG [REPO_URL]}"
REPO_URL="${3:-https://github.com/TserenTserenov/FMT-exocortex-template.git}"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/iwe-rc-upgrade.XXXXXX")
trap 'rm -rf "${TMP:?}"' EXIT
WS="$TMP/ws"
TPL="$WS/FMT-exocortex-template"
export HOME="$TMP/home"
mkdir -p "$WS" "$HOME"
export GIT_AUTHOR_NAME=rc-upgrade GIT_AUTHOR_EMAIL=rc-upgrade@test.local
export GIT_COMMITTER_NAME=rc-upgrade GIT_COMMITTER_EMAIL=rc-upgrade@test.local

FAILS=0
ok()   { echo "  ok: $1"; }
fail() { echo "  FAIL: $1"; FAILS=$((FAILS + 1)); }
die()  { echo "FATAL: $1" >&2; exit 2; }

echo "== clean install of $PREV_TAG =="
git clone -q --depth 1 --branch "$PREV_TAG" "$REPO_URL" "$TPL" || die "cannot clone $PREV_TAG"
git -C "$TPL" fetch -q --depth 1 origin "refs/tags/$RC_TAG:refs/tags/$RC_TAG" || die "tag $RC_TAG not on $REPO_URL"
SETUP_CI=1 GITHUB_USER=rc-upgrade WORKSPACE_DIR="$WS" bash "$TPL/setup.sh" --core > "$TMP/setup.log" 2>&1 \
  || { tail -20 "$TMP/setup.log"; die "setup.sh of $PREV_TAG failed"; }
ok "setup.sh --core of $PREV_TAG"

# Edits a user makes: an own extension and an own parameter.
mkdir -p "$TPL/extensions"
echo "rc-upgrade marker" > "$TPL/extensions/rc-upgrade-marker.md"
[ -f "$TPL/params.yaml" ] || cp "$TPL/params.yaml.example" "$TPL/params.yaml"
echo "rc_upgrade_marker: true" >> "$TPL/params.yaml"

echo "== update to $RC_TAG through the rc channel =="
rc=0
(cd "$TPL" && IWE_UPDATE_CHANNEL=rc bash update.sh --yes) > "$TMP/update.log" 2>&1 || rc=$?
[ "$rc" -eq 0 ] && ok "update.sh --yes exit 0" || { tail -30 "$TMP/update.log"; fail "update.sh --yes exit $rc"; }
grep -q "Канал поставки: кандидат $RC_TAG" "$TMP/update.log" && ok "delivered from $RC_TAG" \
  || fail "channel line does not name $RC_TAG: $(grep -m1 'Канал поставки' "$TMP/update.log")"

echo "== installed files equal the candidate =="
python3 - "$TPL" "$RC_TAG" <<'PY' > "$TMP/compare.log"
import hashlib, json, os, subprocess, sys
root, tag = sys.argv[1], sys.argv[2]
want = json.loads(subprocess.run(["git", "-C", root, "show", f"{tag}:update-manifest.json"],
                                 capture_output=True, text=True, check=True).stdout)
modes = {}
for line in subprocess.run(["git", "-C", root, "ls-tree", "-r", tag], capture_output=True, text=True,
                           check=True).stdout.splitlines():
    meta, path = line.split("\t", 1)
    modes[path] = meta.split()[0]
with open(os.path.join(root, "update-manifest.json"), encoding="utf-8") as fh:
    print("VERSION", json.load(fh)["version"] == want["version"])
# update.sh never rewrites these once seeded (is_protected_user_file): they hold what the install wrote, so an
# older release's seed legitimately differs from the candidate's (0.36.3 -> rc.11: MEMORY.md, 00-index.md).
protected = {"params.yaml", "memory/MEMORY.md", ".claude/settings.local.json", "sessions/00-index.md"}
for entry in want["files"]:
    full = os.path.join(root, entry["path"])
    if not os.path.isfile(full):
        print("MISSING", entry["path"])
        continue
    with open(full, "rb") as fh:
        if entry["path"] not in protected and hashlib.sha256(fh.read()).hexdigest() != entry["sha256"]:
            print("DIFFERS", entry["path"])
    if modes.get(entry["path"]) == "100755" and not os.access(full, os.X_OK):
        print("NOEXEC", entry["path"])
print("TOTAL", len(want["files"]))
PY
grep -q '^VERSION True' "$TMP/compare.log" && ok "installed manifest is the candidate's" || fail "installed manifest version differs"
for kind in MISSING DIFFERS NOEXEC; do
  n=$(grep -c "^$kind " "$TMP/compare.log")
  [ "$n" -eq 0 ] && ok "$kind: 0 of $(sed -n 's/^TOTAL //p' "$TMP/compare.log")" \
    || fail "$kind: $n — $(grep "^$kind " "$TMP/compare.log" | head -5 | cut -d' ' -f2 | tr '\n' ' ')"
done

echo "== user edits survive =="
grep -qx 'rc-upgrade marker' "$TPL/extensions/rc-upgrade-marker.md" && ok "own extension kept" || fail "own extension lost"
grep -qx 'rc_upgrade_marker: true' "$TPL/params.yaml" && ok "own parameter kept" || fail "own parameter lost"

echo "== second run changes nothing =="
rc=0
(cd "$TPL" && IWE_UPDATE_CHANNEL=rc bash update.sh --yes) > "$TMP/update2.log" 2>&1 || rc=$?
[ "$rc" -eq 0 ] && grep -q 'Всё актуально' "$TMP/update2.log" && ok "second run: nothing to update" \
  || { tail -15 "$TMP/update2.log"; fail "second run exit $rc without «Всё актуально»"; }

echo
if [ "$FAILS" -gt 0 ]; then
  echo "FAILED: $FAILS check(s) — upgrade $PREV_TAG -> $RC_TAG"
  exit 1
fi
echo "PASS: upgrade $PREV_TAG -> $RC_TAG"
