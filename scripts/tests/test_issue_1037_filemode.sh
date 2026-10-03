#!/usr/bin/env bash
# Issue #1037: a fork with core.fileMode=false needs exact index-mode repair hints.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/home"
export HOME="$fixture/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

git -C "$fixture" init -q
git -C "$fixture" config user.name test
git -C "$fixture" config user.email test@example.invalid
git -C "$fixture" config core.fileMode false
printf 'baseline\n' > "$fixture/README.md"
git -C "$fixture" add -- README.md
git -C "$fixture" commit -qm baseline

mkdir -p "$fixture/scripts" "$fixture/.claude/bin"
printf '#!/bin/sh\nexit 0\n' > "$fixture/scripts/new-tool.sh"
printf '#!/bin/sh\nexit 0\n' > "$fixture/.claude/bin/guarded-rm"
chmod +x "$fixture/scripts/new-tool.sh" "$fixture/.claude/bin/guarded-rm"

source <(sed -n '/^report_executable_index_mismatches() {/,/^}/p' "$repo_root/update.sh")
declare -F report_executable_index_mismatches >/dev/null

SCRIPT_DIR=$fixture
APPLIED_PATHS=(scripts/new-tool.sh .claude/bin/guarded-rm)
output=$(report_executable_index_mismatches)

expected_add=$(printf 'git -C %q add -- %q' "$fixture" ':(top,literal)scripts/new-tool.sh')
expected_mode=$(printf 'git -C %q update-index --chmod=+x -- %q' "$fixture" scripts/new-tool.sh)
[[ "$output" == *"$expected_add"* ]]
[[ "$output" == *"$expected_mode"* ]]
[[ "$output" == *'.claude/bin/guarded-rm'* ]]
[[ "$output" == *'100755'* ]]
test -z "$(git -C "$fixture" diff --cached --name-only)"

# Ordinary add with core.fileMode=false records the wrong mode even after chmod.
git -C "$fixture" add -- ':(top,literal)scripts/new-tool.sh'
mode=$(git -C "$fixture" ls-files --stage -- scripts/new-tool.sh)
[[ "$mode" == 100644* ]]
git -C "$fixture" update-index --chmod=+x -- scripts/new-tool.sh
mode=$(git -C "$fixture" ls-files --stage -- scripts/new-tool.sh)
[[ "$mode" == 100755* ]]

# A correct index entry is not listed again.
output=$(report_executable_index_mismatches)
[[ "$output" != *"$expected_add"* ]]
[[ "$output" == *'.claude/bin/guarded-rm'* ]]

# An unmerged index must never receive a suggested git add: that command could
# silently resolve the user's conflict with whichever bytes are in the worktree.
printf '#!/bin/sh\nexit 0\n' > "$fixture/scripts/conflicted.sh"
chmod +x "$fixture/scripts/conflicted.sh"
base_blob=$(printf 'base\n' | git -C "$fixture" hash-object -w --stdin)
ours_blob=$(printf 'ours\n' | git -C "$fixture" hash-object -w --stdin)
theirs_blob=$(printf 'theirs\n' | git -C "$fixture" hash-object -w --stdin)
printf '100755 %s 1\tscripts/conflicted.sh\n100755 %s 2\tscripts/conflicted.sh\n100755 %s 3\tscripts/conflicted.sh\n' \
    "$base_blob" "$ours_blob" "$theirs_blob" | git -C "$fixture" update-index --index-info
APPLIED_PATHS+=(scripts/conflicted.sh)
output=$(report_executable_index_mismatches)
conflict_add=$(printf 'git -C %q add -- %q' "$fixture" ':(top,literal)scripts/conflicted.sh')
[[ "$output" == *'scripts/conflicted.sh: в индексе неразрешённый конфликт'* ]]
[[ "$output" != *"$conflict_add"* ]]
test -n "$(git -C "$fixture" ls-files -u -- scripts/conflicted.sh)"

echo 'PASS: exact executable-bit commands are reported without staging user files'

# Full update, not just an extracted helper: a local curl shim serves a small
# manifest into an old template fork. Its Git index ignores working-file modes.
e2e="$fixture/e2e"
fake_home="$e2e/home"
upstream="$e2e/upstream"
workspace="$e2e/workspace"
template="$workspace/FMT-exocortex-template"
mkdir -p "$fake_home" "$upstream/.claude/lib" "$upstream/.claude/bin" \
    "$upstream/scripts" "$template/.claude/lib" "$template/.githooks" \
    "$template/scripts" "$e2e/bin"

printf '# Template instructions\n' > "$upstream/CLAUDE.md"
cp "$repo_root/.claude/lib/frontmatter.sh" "$upstream/.claude/lib/frontmatter.sh"
cp "$repo_root/update.sh" "$upstream/update.sh"
printf '#!/bin/sh\nexit 0\n' > "$upstream/scripts/new-tool.sh"
printf '#!/bin/sh\nexit 0\n' > "$upstream/.claude/bin/guarded-rm"
cp "$upstream/update.sh" "$template/update.sh"
cp "$upstream/CLAUDE.md" "$template/CLAUDE.md"
cp "$upstream/CLAUDE.md" "$template/.claude.md.base"
cp "$upstream/CLAUDE.md" "$workspace/CLAUDE.md"
cp "$upstream/CLAUDE.md" "$workspace/.claude.md.base"
cp "$upstream/.claude/lib/frontmatter.sh" "$template/.claude/lib/frontmatter.sh"
cp "$repo_root/.githooks/pre-commit" "$template/.githooks/pre-commit"

# The real pre-commit hook needs its secret scanner. This local stand-in only
# lets the executable-bit rule run; it performs no scanning or network access.
printf '#!/bin/sh\nexit 0\n' > "$template/scripts/pre-commit-secret-scan.sh"
chmod +x "$template/scripts/pre-commit-secret-scan.sh"

python3 - "$upstream" "$template" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

upstream, template = map(Path, sys.argv[1:])
base = ("CLAUDE.md", ".claude/lib/frontmatter.sh")
new = ("scripts/new-tool.sh", ".claude/bin/guarded-rm")
for root, paths in ((upstream, base + new), (template, base)):
    manifest = {
        "schema_version": 2,
        "version": "0.41.0-test-1037",
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
    git -C "$template" config user.name test
    git -C "$template" config user.email test@example.invalid
    git -C "$template" config core.fileMode false
    git -C "$template" add -- CLAUDE.md .claude.md.base update.sh update-manifest.json \
        .claude/lib/frontmatter.sh .githooks/pre-commit
    git -C "$template" commit -qm 'old installation'
)

cat > "$e2e/bin/curl" <<'CURL'
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
printf '#!/bin/sh\nexit 1\n' > "$e2e/bin/gh"
chmod +x "$e2e/bin/curl" "$e2e/bin/gh"

env -u GH_TOKEN -u GITHUB_TOKEN \
    HOME="$fake_home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    PATH="$e2e/bin:$PATH" FIXTURE_UPSTREAM="$upstream" \
    IWE_UPDATE_CHANNEL=main IWE_SKIP_EXTRACTOR_FEEDERS=1 IWE_SKIP_FPF_REFRESH=1 \
    bash "$template/update.sh" --yes > "$e2e/update.log" 2>&1 || {
        tail -30 "$e2e/update.log" >&2
        echo 'FAIL: real update.sh did not finish in the file-mode fixture' >&2
        exit 1
    }

test -x "$template/scripts/new-tool.sh"
test -x "$template/.claude/bin/guarded-rm"
test -x "$workspace/.claude/bin/guarded-rm"
test -z "$(git -C "$template" diff --cached --name-only)"

for file in scripts/new-tool.sh .claude/bin/guarded-rm; do
    add_command=$(printf 'git -C %q add -- %q' "$template" ":(top,literal)$file")
    mode_command=$(printf 'git -C %q update-index --chmod=+x -- %q' "$template" "$file")
    grep -Fqx "    $add_command" "$e2e/update.log"
    grep -Fqx "    $mode_command" "$e2e/update.log"
    bash -c "$add_command"
done

for file in scripts/new-tool.sh .claude/bin/guarded-rm; do
    mode=$(git -C "$template" ls-files --stage -- "$file")
    [[ "$mode" == 100644* ]]
done
if (cd "$template" && bash .githooks/pre-commit) > "$e2e/hook-red.log" 2>&1; then
    echo 'FAIL: real pre-commit hook accepted a staged 100644 shell script' >&2
    exit 1
fi
grep -q 'EXECUTABLE-BIT: FAIL' "$e2e/hook-red.log"

for file in scripts/new-tool.sh .claude/bin/guarded-rm; do
    mode_command=$(printf 'git -C %q update-index --chmod=+x -- %q' "$template" "$file")
    bash -c "$mode_command"
    mode=$(git -C "$template" ls-files --stage -- "$file")
    [[ "$mode" == 100755* ]]
done
(cd "$template" && bash .githooks/pre-commit) > "$e2e/hook-green.log" 2>&1 || {
    tail -30 "$e2e/hook-green.log" >&2
    echo 'FAIL: real pre-commit hook rejected corrected index modes' >&2
    exit 1
}
staged=$(git -C "$template" diff --cached --name-only)
[[ "$staged" == $'.claude/bin/guarded-rm\nscripts/new-tool.sh' ]]

# A previous bad index mode must still be diagnosed when the next update has
# no content changes. This is the case reported for an already updated fork.
for file in scripts/new-tool.sh .claude/bin/guarded-rm; do
    git -C "$template" update-index --chmod=-x -- "$file"
done
env -u GH_TOKEN -u GITHUB_TOKEN \
    HOME="$fake_home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    PATH="$e2e/bin:$PATH" FIXTURE_UPSTREAM="$upstream" \
    IWE_UPDATE_CHANNEL=main IWE_SKIP_EXTRACTOR_FEEDERS=1 IWE_SKIP_FPF_REFRESH=1 \
    bash "$template/update.sh" --yes > "$e2e/rerun.log" 2>&1 || {
        tail -30 "$e2e/rerun.log" >&2
        echo 'FAIL: no-change rerun did not finish in the file-mode fixture' >&2
        exit 1
    }
grep -q 'Всё актуально. Обновлений нет.' "$e2e/rerun.log"
for file in scripts/new-tool.sh .claude/bin/guarded-rm; do
    add_command=$(printf 'git -C %q add -- %q' "$template" ":(top,literal)$file")
    mode_command=$(printf 'git -C %q update-index --chmod=+x -- %q' "$template" "$file")
    if grep -Fqx "    $add_command" "$e2e/rerun.log"; then
        echo "FAIL: tracked $file must not be added again on rerun" >&2
        exit 1
    fi
    grep -Fqx "    $mode_command" "$e2e/rerun.log"
    mode=$(git -C "$template" ls-files --stage -- "$file")
    [[ "$mode" == 100644* ]]
done

echo 'PASS: real update reports exact commands; index repair passes the real pre-commit guard'
