#!/usr/bin/env bash
# Issue #1514: duplicate checks in /apply-captures must look at the user's own Pack
# files, and a fork of the author's Pack must see ID collisions with upstream.
# Synthetic fork: the user's card DP.METHOD.184 ("build number is assigned by the
# pipeline") and the author's DP.METHOD.184 with different content upstream.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$ROOT/scripts/pack-duplicate-check.py"
SKILL="$ROOT/.claude/skills/apply-captures/SKILL.md"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

commit_card() {  # repo, relative path, text
    mkdir -p "$(dirname "$1/$2")"
    printf '%s\n' "$3" > "$1/$2"
    git -C "$1" add "$2" && git -C "$1" commit -qm "add $2"
}

author="$TMP/author"
git init -q -b main "$author"
commit_card "$author" "pack/03-methods/DP.METHOD.184-optional-hook.md" \
    "# DP.METHOD.184 Optional executable hook"
commit_card "$author" "pack/03-methods/DP.METHOD.438-other.md" "# DP.METHOD.438 Other"
# Cyrillic file name: git quotes such paths by default (core.quotePath).
commit_card "$author" "pack/03-methods/Метод-сборки.md" "См. DP.METHOD.184 (авторская версия)"

user="$TMP/user-pack"
git clone -q "$author" "$user"
git -C "$user" remote rename origin upstream
commit_card "$user" "pack/03-methods/DP.METHOD.200-build-number.md" \
    "# DP.METHOD.200 Номер сборки назначает конвейер"
commit_card "$user" "pack/03-methods/DP.METHOD.184-build-number-old.md" \
    "# DP.METHOD.184 Конвейер выдаёт номер сборки"

run() { python3 "$CHECK" --pack "$user" "$@"; }

# 1. Keyword search finds the user's own card (the platform index did not).
out=$(run "конвейер" "номер сборки") || fail "keyword run failed"
first=$(grep '^KEYWORD_MATCH' <<<"$out" | head -1)
grep -q $'\t2\t' <<<"$first" || fail "best keyword match should hit both words: $out"
grep -q 'DP.METHOD.200-build-number.md\|DP.METHOD.184-build-number-old.md' <<<"$first" \
    || fail "keyword search missed the user's card: $out"

# 2. Same ID in the user's Pack and upstream with different content: both reported.
out=$(run --id DP.METHOD.184) || fail "id run failed"
grep -q $'^ID_LOCAL\tpack/03-methods/DP.METHOD.184-build-number-old.md$' <<<"$out" || fail "ID_LOCAL missing: $out"
grep -q $'^UPSTREAM\tok$' <<<"$out" || fail "upstream not detected: $out"
grep -q $'^ID_UPSTREAM\tupstream/main\tpack/03-methods/DP.METHOD.184-optional-hook.md$' <<<"$out" \
    || fail "upstream collision not reported: $out"
grep -q $'^ID_UPSTREAM\tupstream/main\tpack/03-methods/Метод-сборки.md$' <<<"$out" \
    || fail "upstream file with a Cyrillic name was dropped: $out"

# 3. A prefix ID does not match a longer one (DP.METHOD.43 vs DP.METHOD.438).
out=$(run --id DP.METHOD.43) || fail "prefix id run failed"
grep -q '^ID_' <<<"$out" && fail "DP.METHOD.43 matched a longer ID: $out"

# 4. Upstream states.
git -C "$user" update-ref -d refs/remotes/upstream/main
git -C "$user" update-ref -d refs/remotes/upstream/HEAD 2>/dev/null
out=$(run --id DP.METHOD.184)
grep -q $'^UPSTREAM\tno-ref$' <<<"$out" || fail "missing upstream ref not reported: $out"
out=$(run --id DP.METHOD.184 --fetch)
grep -q '^ID_UPSTREAM' <<<"$out" || fail "--fetch did not restore the upstream check: $out"
# The author's default branch is neither main nor master: --fetch learns it.
git -C "$author" branch -q -m main develop
git -C "$user" update-ref -d refs/remotes/upstream/main
git -C "$user" update-ref -d refs/remotes/upstream/HEAD 2>/dev/null
out=$(run --id DP.METHOD.184 --fetch)
grep -q $'^ID_UPSTREAM\tupstream/develop\t' <<<"$out" || fail "default branch 'develop' not found after --fetch: $out"
# A failed fetch is reported, not hidden behind stale local data.
git -C "$user" remote set-url upstream "$TMP/no-such-repo"
out=$(run --id DP.METHOD.184 --fetch 2>/dev/null)
grep -q $'^UPSTREAM\tfetch-failed$' <<<"$out" || fail "failed fetch not reported: $out"
grep -q '^ID_UPSTREAM' <<<"$out" && fail "stale upstream data shown after a failed fetch: $out"
git -C "$user" remote remove upstream
grep -q $'^UPSTREAM\tno-remote$' <<<"$(run --id DP.METHOD.184)" || fail "no-remote not reported"
mkdir -p "$TMP/plain/pack" && printf '# DP.X.1\n' > "$TMP/plain/pack/a.md"
grep -q $'^UPSTREAM\tnot-a-git-repo$' <<<"$(python3 "$CHECK" --pack "$TMP/plain" --id DP.X.1)" \
    || fail "non-git Pack not reported"

# 5. Bad arguments are refused.
python3 "$CHECK" --pack "$TMP/missing" --id X >/dev/null 2>&1; [ $? -eq 2 ] || fail "missing Pack not refused"
python3 "$CHECK" --pack "$user" >/dev/null 2>&1; [ $? -eq 2 ] || fail "no id and no keywords not refused"

# 6. The skill uses the helper and says whose base knowledge_search sees.
grep -q 'pack-duplicate-check.py" --pack' "$SKILL" || fail "skill does not call the helper"
grep -q 'semantic_gate: skipped (индекс ≠ Pack пользователя)' "$SKILL" || fail "skill lost the index rule"
grep -q '"path": "scripts/pack-duplicate-check.py"' "$ROOT/update-manifest.json" \
    || fail "helper is not in update-manifest.json (users would not get it)"

echo "PASS: issue 1514 (6 groups)"
