#!/usr/bin/env bash
# WP-529 Ф268: CHANGELOG slide on the back-merge of a release PR.
#
# Reproduces the slide with the real scripts/changelog-flush.sh on the release branch and an
# entry added to main after the cut the way template delivery adds it (top of "### Changed"
# in [Unreleased], placeholder fields): git merges cleanly and the entry ends up under the
# version header. scripts/check-release-merge-back.py must refuse that merge, name the entry
# and the placeholder, and pass once the entry is moved back to [Unreleased].
set -uo pipefail
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
CHECK="$ROOT/scripts/check-release-merge-back.py"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/iwe-f268-mb.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

FAILS=0
ok()   { echo "  ok: $1"; }
fail() { echo "  FAIL: $1"; FAILS=$((FAILS + 1)); }

W="$TMP/work"
LATE="- [behavior] Late entry delivered after the cut (#999)."

new_fixture() {
    rm -rf "$W"
    git init -q -b main "$W"
    mkdir -p "$W/scripts"
    cp "$ROOT/scripts/changelog-flush.sh" "$W/scripts/"
    cat > "$W/CHANGELOG.md" <<'EOF'
# Changelog

## [Unreleased]

### Fixed

- [behavior] Released fix (#1).
  - Цель: 84 · Результат: служебное — проверка
  - Как проверить: тест
  - Как откатить: git revert

### Changed

- [behavior] Released change (#2).
  - Цель: 84 · Результат: служебное — проверка
  - Как проверить: тест
  - Как откатить: git revert

## [0.42.0] — 2026-11-10

- [behavior] Old release entry.
EOF
    git -C "$W" add CHANGELOG.md scripts
    git -C "$W" commit -qm "main before the cut"
    # Cut: the release branch flushes [Unreleased] into [0.43.0]; rc.1 and the release tag.
    git -C "$W" checkout -q -b release/v0.43.0
    IWE_TEMPLATE="$W" bash "$W/scripts/changelog-flush.sh" --version 0.43.0 >/dev/null
    git -C "$W" commit -qam "chore(release): v0.43.0"
    git -C "$W" tag v0.43.0-rc.1
    git -C "$W" tag v0.43.0
    git -C "$W" checkout -q main
}

# Same placement as changelog_add_unreleased_line in DS-ai-systems template-sync.sh:
# right after "### Changed" (and its blank lines) of [Unreleased].
add_late_entry_on_main() {
    python3 - "$W/CHANGELOG.md" "$LATE" <<'PY'
import sys
path, top = sys.argv[1], sys.argv[2]
lines = open(path, encoding="utf-8").read().split("\n")
block = [top, "  - Цель: на разметке · Результат: на разметке", "  - Как проверить: на разметке",
         "  - Как откатить: на разметке"]
start = next(i for i, l in enumerate(lines) if l.startswith("## [Unreleased]"))
end = next(i for i in range(start + 1, len(lines)) if lines[i].startswith("## ["))
at = next(i for i in range(start, end) if lines[i].startswith("### Changed")) + 1
while at < end and not lines[at].strip():
    at += 1
lines[at:at] = [*block, ""]
open(path, "w", encoding="utf-8").write("\n".join(lines))
PY
    git -C "$W" commit -qam "late entry on main"
}

section_of() {  # section_of <section> -> the section body of CHANGELOG.md in the work tree
    awk -v s="## [$1]" 'index($0, s) == 1 {on=1; next} on && /^## \[/ {exit} on {print}' "$W/CHANGELOG.md"
}
check() { (cd "$W" && python3 "$CHECK" "$@") > "$TMP/out" 2>&1; echo $?; }

echo "== the slide: main entry added after the cut, release PR merged back =="
new_fixture
add_late_entry_on_main
git -C "$W" checkout -q -b pr-merge main
if git -C "$W" merge -q --no-edit release/v0.43.0 >/dev/null 2>&1; then
  ok "git merges the release branch into main without a conflict"
else fail "fixture: expected a clean merge"; fi
section_of 0.43.0 | grep -qF -e "$LATE" && ! section_of Unreleased | grep -qF -e "$LATE" \
  && ok "the late entry slid under [0.43.0] (reproduced)" || fail "fixture: the slide did not reproduce"

rc=$(check --version 0.43.0 --ref HEAD)
[ "$rc" = 1 ] && ok "check refuses the merge (exit 1)" || fail "slide: expected exit 1, got $rc: $(cat "$TMP/out")"
grep -qF "Лишние записи в [0.43.0]" "$TMP/out" && grep -qF "  $LATE" "$TMP/out" \
  && ok "names the extra entry" || fail "extra entry not named: $(cat "$TMP/out")"
grep -qF "обратно в [Unreleased]" "$TMP/out" && ok "tells to move it back to [Unreleased]" || fail "no instruction"
grep -qF "Заглушка «на разметке» вне [Unreleased]" "$TMP/out" && ok "placeholder outside [Unreleased] reported" \
  || fail "placeholder not reported: $(cat "$TMP/out")"

echo "== before the release tag: compared with the last rc =="
git -C "$W" tag -d v0.43.0 >/dev/null
rc=$(check --version 0.43.0 --ref HEAD)
[ "$rc" = 1 ] && grep -qF "отличается от вышедшего (v0.43.0-rc.1)" "$TMP/out" \
  && ok "no tag -> the last rc is the reference, slide still refused" || fail "rc reference: $rc $(cat "$TMP/out")"
git -C "$W" tag v0.43.0 release/v0.43.0

echo "== the entry moved back to [Unreleased] =="
python3 - "$W/CHANGELOG.md" "$LATE" <<'PY'
import sys
path, top = sys.argv[1], sys.argv[2]
lines = open(path, encoding="utf-8").read().split("\n")
i = lines.index(top)
j = i + 1
while j < len(lines) and lines[j].startswith("  "):
    j += 1
block = lines[i:j]
del lines[i:j + 1]
at = next(k for k, l in enumerate(lines) if l.startswith("## [Unreleased]")) + 1
lines[at:at] = ["", "### Changed", "", *block]
open(path, "w", encoding="utf-8").write("\n".join(lines))
PY
git -C "$W" commit -qam "move the late entry back to Unreleased"
section_of Unreleased | grep -qF -e "$LATE" || fail "fixture: entry not moved back"
rc=$(check --version 0.43.0 --ref HEAD)
[ "$rc" = 0 ] && grep -q "^OK:" "$TMP/out" && ok "fixed merge passes" || fail "fixed merge: expected 0, got $rc: $(cat "$TMP/out")"

echo "== main without new entries =="
new_fixture
git -C "$W" checkout -q -b pr-merge main
git -C "$W" merge -q --no-edit release/v0.43.0 >/dev/null 2>&1
rc=$(check --version 0.43.0 --ref HEAD)
[ "$rc" = 0 ] && ok "plain back-merge passes" || fail "plain back-merge: expected 0, got $rc: $(cat "$TMP/out")"

echo "== a released entry lost in the merge =="
python3 - "$W/CHANGELOG.md" <<'PY'
import sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
open(path, "w", encoding="utf-8").write(text.replace("- [behavior] Released fix (#1).\n", "", 1))
PY
git -C "$W" commit -qam "lose an entry"
rc=$(check --version 0.43.0 --ref HEAD)
[ "$rc" = 1 ] && grep -qF "Пропали записи выпуска" "$TMP/out" && grep -qF "Released fix (#1)" "$TMP/out" \
  && ok "missing released entry -> refused" || fail "missing entry: $rc $(cat "$TMP/out")"

echo "== nothing to compare with =="
rc=$(check --version 0.44.0 --ref HEAD)
[ "$rc" = 2 ] && grep -qF "нет ни метки v0.44.0" "$TMP/out" && ok "no tag and no rc -> exit 2" \
  || fail "no reference: $rc $(cat "$TMP/out")"

echo
if [ "$FAILS" -gt 0 ]; then
  echo "FAILED: $FAILS check(s)"
  exit 1
fi
echo "PASS"
