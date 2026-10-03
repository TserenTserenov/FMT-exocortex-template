#!/bin/bash
# Issue #1032: a delivered strategy-session can open an isolated copy without
# network access after the pilot inspects and explicitly pins a local commit.
set -euo pipefail

TEMPLATE_ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
FIXTURE="$(mktemp -d)"
trap 'rm -rf "$FIXTURE"' EXIT
WORKSPACE="$FIXTURE/offline workspace"
CANON="$WORKSPACE/DS-strategy"
GUARD="$WORKSPACE/scripts/session-guard.sh"
SKILL="$WORKSPACE/.claude/skills/strategy-session/SKILL.md"
mkdir -p "$CANON/inbox/WP-529" "$WORKSPACE/scripts/lib" "$WORKSPACE/.claude/skills/strategy-session" "$WORKSPACE/MC-sessions" "$FIXTURE/bin"

# These are the installer-delivered locations. Keep the fixture entirely in
# the temporary workspace; setup.sh also writes to the real user home.
cp "$TEMPLATE_ROOT/scripts/session-guard.sh" "$GUARD"
cp "$TEMPLATE_ROOT/scripts/lib/session-guard-isolate-lib.sh" "$WORKSPACE/scripts/lib/"
cp "$TEMPLATE_ROOT/scripts/lib/wp-num.sh" "$WORKSPACE/scripts/lib/"
cp "$TEMPLATE_ROOT/scripts/isolate-push.sh" "$WORKSPACE/scripts/"
cp "$TEMPLATE_ROOT/.claude/skills/strategy-session/SKILL.md" "$SKILL"
printf 'WP-529 offline fixture\n' > "$CANON/inbox/WP-529/WP-529.md"
git -C "$CANON" init -q -b main
git -C "$CANON" -c user.name=test -c user.email=offline@test.invalid add inbox/WP-529/WP-529.md
git -C "$CANON" -c user.name=test -c user.email=offline@test.invalid commit -q -m seed
git -C "$CANON" remote add origin 'https://SENTINEL_USERINFO_CREDENTIAL@127.0.0.1:9/offline/DS-strategy.git?access_token=SENTINEL_QUERY_CREDENTIAL'
git -C "$WORKSPACE/MC-sessions" init -q -b main
git -C "$WORKSPACE/MC-sessions" -c user.name=test -c user.email=offline@test.invalid commit -q --allow-empty -m seed
BASE_SHA=$(git -C "$CANON" rev-parse HEAD)

python3 - "$SKILL" "$WORKSPACE" "$FIXTURE/step0.sh" <<'PY'
from pathlib import Path
import re
import sys

text = Path(sys.argv[1]).read_text()
section = text.split("### Шаг 0. Рабочая копия", 1)[1]
block = re.search(r"```bash\n(.*?)```", section, re.S).group(1)
block = block.replace("{{WORKSPACE_DIR}}", sys.argv[2]).replace("{{GOVERNANCE_REPO}}", "DS-strategy")
Path(sys.argv[3]).write_text(block)
PY

REAL_GIT="$(command -v git)"
FETCH_LOG="$FIXTURE/fetch.log"
export REAL_GIT FETCH_LOG
cat > "$FIXTURE/bin/git" <<'SH'
#!/bin/bash
for arg in "$@"; do
  [ "$arg" = fetch ] && printf 'fetch\n' >> "$FETCH_LOG"
done
exec "$REAL_GIT" "$@"
SH
chmod +x "$FIXTURE/bin/git"

run_in_canon() {
  (cd "$CANON" || exit 1
   export IWE_ROOT="$WORKSPACE" IWE_SCRIPTS="$WORKSPACE/scripts" IWE_GOVERNANCE_REPO=DS-strategy
   export IWE_FROZEN_CANONICAL_PATH="$CANON" IWE_SESSIONS_ROOT="$WORKSPACE/MC-sessions"
   export IWE_AGENT=codex IWE_SESSION_ID="offline-1032-$$" PATH="$FIXTURE/bin:$PATH"
   "$@")
}

set +e
STEP0_OUTPUT=$(run_in_canon bash "$FIXTURE/step0.sh" 2>&1)
STEP0_CODE=$?
set -e
[ "$STEP0_CODE" -eq 2 ] && printf '%s\n' "$STEP0_OUTPUT" | grep -qF -- "--base-sha $BASE_SHA" || {
  printf 'FAIL: step 0 did not show the inspected local revision: %s\n' "$STEP0_OUTPUT" >&2
  exit 1
}

set +e
FETCH_OUTPUT=$(run_in_canon bash "$GUARD" open --isolate --wp WP-529 --task offline --slug offline --agent codex 2>&1)
FETCH_CODE=$?
set -e
HINT=$(printf '%s\n' "$FETCH_OUTPUT" | sed -n 's/^session-guard: Офлайн после проверки ревизии: //p')
[ "${FETCH_OUTPUT#*SENTINEL_USERINFO_CREDENTIAL}" = "$FETCH_OUTPUT" ] && [ "${FETCH_OUTPUT#*SENTINEL_QUERY_CREDENTIAL}" = "$FETCH_OUTPUT" ] || {
  echo 'FAIL: remote credential appeared in guard diagnostics' >&2
  exit 1
}
[ "$FETCH_CODE" -ne 0 ] && printf '%s\n' "$FETCH_OUTPUT" | grep -q 'origin/main недоступен: нет соединения' && [ -n "$HINT" ] || {
  printf 'FAIL: unavailable origin had no classified cause and executable hint: %s\n' "$FETCH_OUTPUT" >&2
  exit 1
}
[ "$(wc -l < "$FETCH_LOG" | tr -d ' ')" -ge 1 ] || { echo 'FAIL: fetch was not attempted' >&2; exit 1; }
: > "$FETCH_LOG"

OPEN_OUTPUT=$(run_in_canon bash -c "$HINT" 2>&1) || {
  printf 'FAIL: printed offline command failed: %s\n' "$OPEN_OUTPUT" >&2
  exit 1
}
[ "${OPEN_OUTPUT#*SENTINEL_USERINFO_CREDENTIAL}" = "$OPEN_OUTPUT" ] && [ "${OPEN_OUTPUT#*SENTINEL_QUERY_CREDENTIAL}" = "$OPEN_OUTPUT" ] || {
  echo 'FAIL: remote credential appeared in offline open output' >&2
  exit 1
}
WORKTREE=$(printf '%s\n' "$OPEN_OUTPUT" | python3 -c 'import json,sys; print(next((json.loads(s)["worktree_path"] for s in sys.stdin if s.startswith("{")), ""))')
[ -d "$WORKTREE" ] && [ "$(git -C "$WORKTREE" rev-parse HEAD)" = "$BASE_SHA" ] || {
  printf 'FAIL: offline copy is missing or has a different base: %s\n' "$OPEN_OUTPUT" >&2
  exit 1
}
[ ! -s "$FETCH_LOG" ] || { echo 'FAIL: --base-sha queried origin' >&2; exit 1; }
[ "$(git -C "$CANON" rev-parse HEAD)" = "$BASE_SHA" ] && [ "$(cat "$CANON/inbox/WP-529/WP-529.md")" = 'WP-529 offline fixture' ] || {
  echo 'FAIL: canonical contents changed' >&2
  exit 1
}
STEP0_COPY=$(cd "$WORKTREE" && IWE_SCRIPTS="$WORKSPACE/scripts" bash "$FIXTURE/step0.sh" 2>&1) || {
  printf 'FAIL: step 0 did not accept the isolated copy: %s\n' "$STEP0_COPY" >&2
  exit 1
}
printf '%s\n' "$STEP0_COPY" | grep -qF "GOV_WT=$WORKTREE mode=isolated" || {
  printf 'FAIL: step 0 chose another worktree: %s\n' "$STEP0_COPY" >&2
  exit 1
}
echo 'PASS: installed strategy-session opens a pinned copy offline without touching canonical contents'

# A partial clone may know an old commit while its blob is still promised by
# origin. Pinning that commit must reject locally before Git creates a branch
# or tries its implicit promisor fetch.
PARTIAL_SOURCE="$FIXTURE/partial-source"
PARTIAL_CANON="$WORKSPACE/DS-partial"
mkdir -p "$PARTIAL_SOURCE/inbox/WP-529"
git -C "$PARTIAL_SOURCE" init -q -b main
printf 'partial fixture\n' > "$PARTIAL_SOURCE/inbox/WP-529/WP-529.md"
printf 'old\n' > "$PARTIAL_SOURCE/data.txt"
git -C "$PARTIAL_SOURCE" -c user.name=test -c user.email=offline@test.invalid add inbox/WP-529/WP-529.md data.txt
git -C "$PARTIAL_SOURCE" -c user.name=test -c user.email=offline@test.invalid commit -q -m old
OLD_SHA=$(git -C "$PARTIAL_SOURCE" rev-parse HEAD)
printf 'new\n' > "$PARTIAL_SOURCE/data.txt"
git -C "$PARTIAL_SOURCE" -c user.name=test -c user.email=offline@test.invalid commit -qam new
git -C "$PARTIAL_SOURCE" config uploadpack.allowFilter true
git clone -q --filter=blob:none "file://$PARTIAL_SOURCE" "$PARTIAL_CANON"
MISSING=$(GIT_NO_LAZY_FETCH=1 git -C "$PARTIAL_CANON" rev-list --objects --missing=print "$OLD_SHA")
printf '%s\n' "$MISSING" | grep -q '^?' || { echo 'FAIL: partial fixture has no missing object' >&2; exit 1; }
git -C "$PARTIAL_CANON" remote set-url origin file:///nonexistent/wp529-1032-offline-remote
PARTIAL_HEAD=$(git -C "$PARTIAL_CANON" rev-parse HEAD)
PARTIAL_STATUS=$(git -C "$PARTIAL_CANON" status --porcelain)
PARTIAL_TRACE="$FIXTURE/partial.trace"
PARTIAL_SESSION="offline-partial-$$"
set +e
PARTIAL_OUTPUT=$(
  cd "$PARTIAL_CANON" || exit 1
  export IWE_ROOT="$WORKSPACE" IWE_SCRIPTS="$WORKSPACE/scripts" IWE_GOVERNANCE_REPO=DS-partial
  export IWE_FROZEN_CANONICAL_PATH="$PARTIAL_CANON" IWE_SESSIONS_ROOT="$WORKSPACE/MC-sessions"
  export IWE_AGENT=codex IWE_SESSION_ID="$PARTIAL_SESSION" GIT_TRACE="$PARTIAL_TRACE"
  bash "$GUARD" open --isolate --wp WP-529 --task offline-partial --slug offline-partial --agent codex --base-sha "$OLD_SHA" 2>&1
)
PARTIAL_CODE=$?
set -e
[ "$PARTIAL_CODE" -ne 0 ] && printf '%s\n' "$PARTIAL_OUTPUT" | grep -q 'неполон локально' || {
  printf 'FAIL: incomplete local commit had no clear refusal: %s\n' "$PARTIAL_OUTPUT" >&2
  exit 1
}
[ "$(git -C "$PARTIAL_CANON" rev-parse HEAD)" = "$PARTIAL_HEAD" ] && [ "$(git -C "$PARTIAL_CANON" status --porcelain)" = "$PARTIAL_STATUS" ] || {
  echo 'FAIL: partial canonical checkout changed' >&2
  exit 1
}
! git -C "$PARTIAL_CANON" show-ref --verify --quiet "refs/heads/session-isolate/codex-$PARTIAL_SESSION" || {
  echo 'FAIL: partial refusal left an isolated branch' >&2
  exit 1
}
[ ! -e "$WORKSPACE/.iwe-runtime/isolated-worktrees/codex-$PARTIAL_SESSION" ] || {
  echo 'FAIL: partial refusal left a worktree' >&2
  exit 1
}
! grep -q 'git-upload-pack' "$PARTIAL_TRACE" || {
  echo 'FAIL: partial refusal queried promisor origin' >&2
  exit 1
}
echo 'PASS: incomplete partial clone refuses offline pin before worktree or remote access'
