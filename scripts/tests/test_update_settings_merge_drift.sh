#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals are read by the function evaluated from update.sh.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

eval "$(awk '
  /^report_settings_merge_drift\(\)/ { capture=1 }
  capture { print }
  capture && /^}/ { exit }
' "$ROOT/update.sh")"
declare -F report_settings_merge_drift >/dev/null

SCRIPT_DIR="$TMP/template"
WORKSPACE_DIR="$TMP/workspace"
APPLY_SETTINGS_MERGE=false
CHECK_ONLY=false
mkdir -p "$SCRIPT_DIR/.claude" "$WORKSPACE_DIR/.claude"

report_settings_merge_preview() {
    printf '%s|%s\n' "$1" "$2" > "$TMP/preview-call"
}

printf '{"hooks":{"Stop":[]}}\n' > "$SCRIPT_DIR/.claude/settings.json"
printf '{"hooks":{"Stop":[],"SessionStart":[]}}\n' > "$WORKSPACE_DIR/.claude/settings.json"

OUT=$(report_settings_merge_drift)
if ! grep -Fq 'платформа обновила hooks/permissions' <(printf '%s' "$OUT"); then
    echo 'settings drift did not report a user-visible warning' >&2
    exit 1
fi
if [ "$(cat "$TMP/preview-call")" != "$SCRIPT_DIR/.claude/settings.json|$WORKSPACE_DIR/.claude/settings.json" ]; then
    echo 'settings drift did not invoke preview for the template/workspace pair' >&2
    exit 1
fi

rm "$TMP/preview-call"
cp "$SCRIPT_DIR/.claude/settings.json" "$WORKSPACE_DIR/.claude/settings.json"
report_settings_merge_drift >/dev/null
if [ -e "$TMP/preview-call" ]; then
    echo 'settings drift reported identical files' >&2
    exit 1
fi

printf '{"hooks":{"Stop":[],"SessionStart":[]}}\n' > "$WORKSPACE_DIR/.claude/settings.json"
CHECK_ONLY=true
OUT=$(report_settings_merge_drift)
if ! grep -Fq 'предпросмотр не записан' <(printf '%s' "$OUT") || [ -e "$TMP/preview-call" ]; then
    echo 'check mode wrote a settings preview or hid the drift' >&2
    exit 1
fi

echo 'PASS: settings merge drift is reported independently of downloaded files'
