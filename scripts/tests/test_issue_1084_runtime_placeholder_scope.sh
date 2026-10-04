#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CHECKER="$SCRIPT_DIR/lib/runtime-placeholder-count.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/runtime/roles" "$TMP/runtime/isolated-worktrees/old/roles"
cat > "$TMP/overlay.yaml" <<'EOF'
substituted:
  - roles/current.md
copied_to_workspace:
  - params.yaml
EOF
printf 'ready\n' > "$TMP/runtime/roles/current.md"
printf '{{STALE_VALUE}}\n' > "$TMP/runtime/isolated-worktrees/old/roles/current.md"

actual=$(bash "$CHECKER" "$TMP/overlay.yaml" "$TMP/runtime")
[ "$actual" = 0 ] || { echo "preserved worktree counted as installed runtime: $actual" >&2; exit 1; }

printf '{{LIVE_VALUE}}\n' > "$TMP/runtime/roles/current.md"
actual=$(bash "$CHECKER" "$TMP/overlay.yaml" "$TMP/runtime")
[ "$actual" = 1 ] || { echo "declared runtime placeholder missed: $actual" >&2; exit 1; }

printf 'ready\n' > "$TMP/runtime/roles/current.md"
ln -s "$TMP/runtime/isolated-worktrees/old/roles/current.md" "$TMP/runtime/roles/link.md"
cat > "$TMP/overlay.yaml" <<'EOF'
substituted:
  - roles/current.md
  - roles/link.md
EOF
if bash "$CHECKER" "$TMP/overlay.yaml" "$TMP/runtime" > /dev/null 2>&1; then
    echo 'symlink target accepted' >&2
    exit 1
fi

echo 'PASS: declared runtime files only; preserved worktrees ignored'
