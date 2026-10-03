#!/usr/bin/env bash
# Issue #1032: native Windows Git Bash must refuse a session before writing.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
FIXTURE="$(mktemp -d)"
trap 'rm -rf "$FIXTURE"' EXIT
WORKSPACE="$FIXTURE/workspace"
CANON="$WORKSPACE/DS-strategy"
mkdir -p "$CANON/inbox/WP-529" "$FIXTURE/bin"
printf 'unchanged\n' > "$CANON/inbox/WP-529/WP-529.md"
git -C "$CANON" init -q -b main
git -C "$CANON" -c user.name=test -c user.email=test@example.invalid add inbox/WP-529/WP-529.md
git -C "$CANON" -c user.name=test -c user.email=test@example.invalid commit -q -m seed
HEAD_BEFORE="$(git -C "$CANON" rev-parse HEAD)"
WORKTREES_BEFORE="$(git -C "$CANON" worktree list --porcelain)"
BRANCHES_BEFORE="$(git -C "$CANON" branch --list)"

# On Unix, emulate only Git Bash's platform signature. The windows-latest job
# below runs this same fixture with Git Bash and native Windows Python.
case "$(uname -s)" in
  MINGW*|MSYS*)
    python -c 'import sys; assert sys.platform == "win32", sys.platform'
    ;;
  *)
    cat > "$FIXTURE/bin/uname" <<'SH'
#!/usr/bin/env bash
printf 'MINGW64_NT-10.0\n'
SH
    chmod +x "$FIXTURE/bin/uname"
    ;;
esac

set +e
OUTPUT=$(cd "$CANON" && IWE_ROOT="$WORKSPACE" IWE_GOVERNANCE_REPO=DS-strategy \
  IWE_FROZEN_CANONICAL_PATH="$CANON" PATH="$FIXTURE/bin:$PATH" \
  bash "$ROOT/scripts/session-guard.sh" open --wp WP-529 --task windows \
    --slug windows --agent codex --isolate 2>&1)
CODE=$?
set -e
[ "$CODE" -ne 0 ] || { echo 'FAIL: native Windows session was accepted' >&2; exit 1; }
printf '%s\n' "$OUTPUT" | grep -q 'Git Bash' || { echo "FAIL: missing platform diagnosis: $OUTPUT" >&2; exit 1; }
printf '%s\n' "$OUTPUT" | grep -q 'WSL2' || { echo "FAIL: missing WSL2 instruction: $OUTPUT" >&2; exit 1; }
if printf '%s\n' "$OUTPUT" | grep -Eq 'Traceback|ImportError'; then
  echo "FAIL: raw Python error escaped: $OUTPUT" >&2
  exit 1
fi

[ "$(git -C "$CANON" rev-parse HEAD)" = "$HEAD_BEFORE" ] || { echo 'FAIL: canonical HEAD changed' >&2; exit 1; }
[ -z "$(git -C "$CANON" status --porcelain)" ] || { echo 'FAIL: canonical files changed' >&2; exit 1; }
[ "$(git -C "$CANON" worktree list --porcelain)" = "$WORKTREES_BEFORE" ] || { echo 'FAIL: worktree registered' >&2; exit 1; }
[ "$(git -C "$CANON" branch --list)" = "$BRANCHES_BEFORE" ] || { echo 'FAIL: branch created' >&2; exit 1; }
[ ! -e "$WORKSPACE/.iwe-runtime" ] || { echo 'FAIL: runtime directory created' >&2; exit 1; }
[ ! -e "$CANON/inbox/open-sessions.log" ] || { echo 'FAIL: open log created' >&2; exit 1; }
echo 'PASS: native Windows Git Bash refuses before canonical or runtime writes'
