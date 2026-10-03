#!/usr/bin/env bash
# Issue #1036: migration guidance must not depend on a stale local seed copy.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

python3 - "$repo_root" <<'PY'
import json
import re
import subprocess
import sys
from pathlib import Path

root = Path(sys.argv[1])
changelog = (root / "CHANGELOG.md").read_text(encoding="utf-8")
manifest = json.loads((root / "update-manifest.json").read_text(encoding="utf-8"))

section = re.search(
    r"- \[migration\] \*\*Существующим установкам:\*\*(.*?)(?=\n### Added)",
    changelog,
    re.DOTALL,
)
assert section, "migration guidance for existing installations is missing"

source = re.search(
    r"https://raw\.githubusercontent\.com/[^/]+/"
    r"FMT-exocortex-template/([0-9a-f]{40})/"
    r"seed/strategy/inbox/fleeting-notes\.md",
    section.group(1),
)
assert source, "migration guidance must link to an immutable upstream seed"

seed = subprocess.run(
    ["git", "-C", str(root), "show", f"{source.group(1)}:seed/strategy/inbox/fleeting-notes.md"],
    check=True,
    capture_output=True,
    text=True,
).stdout
assert "Разбирает только пилот" in seed
assert "автоматического ночного разбора нет" in seed
assert "✅предложено" in seed
assert "вручную" in section.group(1)

delivered_paths = {entry["path"] for entry in manifest["files"]}
assert "inbox/fleeting-notes.md" not in delivered_paths, "user notes must not be replaced"
print("PASS: immutable migration legend is available; user notes stay outside delivery")
PY

# Exercise the real updater against an old installation. All downloads are
# served from this fixture; HOME and every writable path stay under mktemp.
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
fake_home="$fixture/home"
upstream="$fixture/upstream"
workspace="$fixture/workspace"
template="$workspace/FMT-exocortex-template"
governance="$workspace/DS-test"
mkdir -p "$fake_home" "$upstream/.claude/lib" "$template/.claude/lib" \
    "$template/seed/strategy/inbox" "$template/seed/strategy/scripts" \
    "$governance/inbox" "$governance/scripts" "$fixture/bin"

cp "$repo_root/CHANGELOG.md" "$upstream/CHANGELOG.md"
cp "$repo_root/.claude/lib/frontmatter.sh" "$upstream/.claude/lib/frontmatter.sh"
printf '# Template instructions\n' > "$upstream/CLAUDE.md"
cp "$repo_root/update.sh" "$template/update.sh"
cp "$upstream/CLAUDE.md" "$template/CLAUDE.md"
cp "$upstream/CLAUDE.md" "$template/.claude.md.base"
cp "$upstream/CLAUDE.md" "$workspace/CLAUDE.md"
cp "$upstream/CLAUDE.md" "$workspace/.claude.md.base"
cp "$upstream/.claude/lib/frontmatter.sh" "$template/.claude/lib/frontmatter.sh"
python3 - "$repo_root/CHANGELOG.md" "$template/CHANGELOG.md" <<'PY'
import sys
from pathlib import Path

current = Path(sys.argv[1]).read_text(encoding="utf-8")
old_line = (
    "- [migration] **Существующим установкам:** Замените легенду вручную по "
    "`seed/strategy/inbox/fleeting-notes.md`; сохраните свои заметки."
)
lines = current.splitlines(keepends=True)
matches = [
    index for index, line in enumerate(lines)
    if line.startswith("- [migration] **Существующим установкам:**") and "#1036" in line
]
assert len(matches) == 1, "expected exactly one corrected migration instruction"
lines[matches[0]] = old_line + "\n"
Path(sys.argv[2]).write_text("".join(lines), encoding="utf-8")
PY
printf '# Fleeting Notes\n> Old legend: plain notes processed at 23:00.\n\n---\n' \
    > "$template/seed/strategy/inbox/fleeting-notes.md"
cp "$template/seed/strategy/inbox/fleeting-notes.md" "$fixture/old-seed.md"
cat > "$governance/inbox/fleeting-notes.md" <<'NOTES'
# Fleeting Notes
> Old legend: plain notes processed at 23:00.

---

**Pilot note: keep this exact text.**
Second line of the user's note.
NOTES
cp "$governance/inbox/fleeting-notes.md" "$fixture/user-notes-before.md"
printf 'GOVERNANCE_REPO="DS-test"\n' > "$workspace/.exocortex.env"

# Existing installations already have these compatibility files. Keep them
# identical at source and destination so unrelated backfills need no migration.
for name in iwe_checklist_memory.py sync_feedback_to_memory.py agent_fault_remind.py agent_fault_remind.sh; do
    cp "$repo_root/seed/strategy/scripts/$name" "$template/seed/strategy/scripts/$name"
    cp "$template/seed/strategy/scripts/$name" "$governance/scripts/$name"
    chmod +x "$governance/scripts/$name"
done
for name in day-open-llm-fill.py update-derived-snapshot.py generate-executor-catalog.py ds-publish.sh; do
    cp "$repo_root/seed/strategy/scripts/$name" "$template/seed/strategy/scripts/$name"
done

python3 - "$upstream" "$template" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

upstream, template = map(Path, sys.argv[1:])
paths = ("CHANGELOG.md", "CLAUDE.md", ".claude/lib/frontmatter.sh")
for root in (upstream, template):
    manifest = {
        "schema_version": 2,
        "version": "0.41.0-test-1036",
        "files": [
            {"path": path, "sha256": hashlib.sha256((root / path).read_bytes()).hexdigest()}
            for path in paths
        ],
        "deprecated_files": [],
    }
    (root / "update-manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
PY

(
    export HOME="$fake_home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
    git -C "$template" init -q
    git -C "$template" config user.name Test
    git -C "$template" config user.email test@example.invalid
    git -C "$template" add -- CHANGELOG.md CLAUDE.md .claude.md.base update.sh \
        update-manifest.json .claude/lib/frontmatter.sh seed/strategy/inbox/fleeting-notes.md
    git -C "$template" commit -q -m 'old installation'
)

cat > "$fixture/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = --help ] && [ "${2:-}" = all ]; then
    printf '%s\n' '  -o, --output <file>'
    exit 0
fi
url="" output="" http_code=false
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o) output="$2"; shift 2 ;;
        -w) http_code=true; shift 2 ;;
        http*) url="$1"; shift ;;
        *) shift ;;
    esac
done
case "$url" in
    https://api.github.com/repos/*/commits/main)
        printf '{"sha":"%040d"}\n' 0
        exit 0 ;;
    https://raw.githubusercontent.com/TserenTserenov/FMT-exocortex-template/*)
        relative=${url#https://raw.githubusercontent.com/TserenTserenov/FMT-exocortex-template/}
        relative=${relative#*/}
        [ -n "$output" ] && [ -f "$FIXTURE_UPSTREAM/$relative" ] || exit 22
        cp "$FIXTURE_UPSTREAM/$relative" "$output"
        $http_code && printf '200'
        exit 0 ;;
esac
echo "fixture rejected unexpected curl URL: $url" >&2
exit 22
CURL
cat > "$fixture/bin/gh" <<'GH'
#!/usr/bin/env bash
exit 1
GH
chmod +x "$fixture/bin/curl" "$fixture/bin/gh"

env -u GH_TOKEN -u GITHUB_TOKEN \
    HOME="$fake_home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    PATH="$fixture/bin:$PATH" FIXTURE_UPSTREAM="$upstream" \
    IWE_UPDATE_CHANNEL=main IWE_SKIP_EXTRACTOR_FEEDERS=1 IWE_SKIP_FPF_REFRESH=1 \
    bash "$template/update.sh" --yes > "$fixture/update.log" 2>&1 || {
        tail -30 "$fixture/update.log" >&2
        echo 'FAIL: real update.sh did not finish in the old-installation fixture' >&2
        exit 1
    }

cmp "$upstream/CHANGELOG.md" "$template/CHANGELOG.md"
cmp "$fixture/old-seed.md" "$template/seed/strategy/inbox/fleeting-notes.md"
cmp "$fixture/user-notes-before.md" "$governance/inbox/fleeting-notes.md"
grep -q 'неизменяемому снимку выпуска' "$template/CHANGELOG.md"
echo 'PASS: real update delivered the pinned migration guidance and preserved user notes'
