#!/usr/bin/env bash
# shellcheck disable=SC2034  # globals are read by the functions evaluated from update.sh.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# issue #1089 cold review (Fable, 2026-10-05): the previous version of this
# test captured only report_settings_merge_drift. That function now calls
# three more helpers (build_settings_merge_report, settings_merge_report_is_quiet,
# and -- on real drift -- report_settings_merge_preview/print_settings_merge_report);
# none of those were in scope, so every call failed as "command not found"
# inside an `if ...; then` (set -e does not abort there), fell through to the
# pre-#1089 unconditional-warn behaviour by accident, and this test passed
# for that old behaviour -- not for the code it claims to cover. Capture the
# full block instead of one function.
eval "$(awk '
  /^build_settings_merge_report\(\)/ { capture=1 }
  capture { print }
  capture && /^report_settings_merge_drift\(\)/ { in_target=1 }
  in_target && /^}/ { exit }
' "$ROOT/update.sh")"
for fn in build_settings_merge_report print_settings_merge_report \
          report_settings_merge_preview settings_merge_report_is_quiet \
          report_settings_merge_drift; do
    declare -F "$fn" >/dev/null || { echo "setup failed: $fn not captured from update.sh" >&2; exit 1; }
done

PY_BIN=python3
py_available() { command -v python3 >/dev/null 2>&1; }
TMPDIR_UPDATE="$TMP/tmp"
SCRIPT_DIR="$TMP/template"
WORKSPACE_DIR="$TMP/workspace"
PREVIEW="$WORKSPACE_DIR/.claude/settings.merged.preview.json"
APPLY_SETTINGS_MERGE=false
CHECK_ONLY=false
mkdir -p "$SCRIPT_DIR/.claude/scripts" "$WORKSPACE_DIR/.claude" "$TMPDIR_UPDATE"
cp "$ROOT/.claude/scripts/settings-merge-preview.py" "$SCRIPT_DIR/.claude/scripts/"

# --- Case 1: template genuinely adds a hook the workspace doesn't have ---
# (not just reordered or an empty extra key -- Fable's review found the old
# fixture here was workspace-only-empty-key, which is correctly quiet under
# the content-aware check and was masking that this case tested nothing real)
printf '{"hooks":{"Stop":[{"matcher":"*","hooks":[{"type":"command","command":"a.sh"}]},{"matcher":"*","hooks":[{"type":"command","command":"b.sh"}]}]}}\n' \
    > "$SCRIPT_DIR/.claude/settings.json"
printf '{"hooks":{"Stop":[{"matcher":"*","hooks":[{"type":"command","command":"a.sh"}]}]}}\n' \
    > "$WORKSPACE_DIR/.claude/settings.json"
rm -f "$PREVIEW"
OUT=$(report_settings_merge_drift)
if ! grep -Fq 'платформа обновила hooks/permissions' <(printf '%s' "$OUT"); then
    echo 'FAIL: a real template addition did not report a user-visible warning' >&2
    exit 1
fi
if [ ! -f "$PREVIEW" ]; then
    echo 'FAIL: a real addition (non-check mode) did not write the workspace preview' >&2
    exit 1
fi

# --- Case 2: byte-for-byte identical -> quiet, nothing written ---
rm -f "$PREVIEW"
cp "$SCRIPT_DIR/.claude/settings.json" "$WORKSPACE_DIR/.claude/settings.json"
OUT=$(report_settings_merge_drift)
if [ -n "$OUT" ]; then
    echo 'FAIL: byte-identical settings printed output' >&2
    exit 1
fi
if [ -f "$PREVIEW" ]; then
    echo 'FAIL: byte-identical settings wrote a preview file' >&2
    exit 1
fi

# --- Case 3: same hook set, different array order -> quiet, nothing written ---
# This is the actual issue #1088/#1089 motivating case: a real-world pilot
# whose settings.json differs from the template only by array order must not
# be warned at all, and must not get a stray preview file.
printf '{"hooks":{"Stop":[{"matcher":"*","hooks":[{"type":"command","command":"b.sh"}]},{"matcher":"*","hooks":[{"type":"command","command":"a.sh"}]}]}}\n' \
    > "$SCRIPT_DIR/.claude/settings.json"
printf '{"hooks":{"Stop":[{"matcher":"*","hooks":[{"type":"command","command":"a.sh"}]},{"matcher":"*","hooks":[{"type":"command","command":"b.sh"}]}]}}\n' \
    > "$WORKSPACE_DIR/.claude/settings.json"
rm -f "$PREVIEW"
OUT=$(report_settings_merge_drift)
if [ -n "$OUT" ]; then
    echo 'FAIL: order-only difference printed output' >&2
    exit 1
fi
if [ -f "$PREVIEW" ]; then
    echo 'FAIL: order-only difference wrote a preview file' >&2
    exit 1
fi

# --- Case 4: template drops a hook the workspace still has -> must warn ---
# (High finding, Fable: this was invisible under the first #1089 fix --
# neither an addition nor a conflict, so the quiet-check missed it entirely)
printf '{"hooks":{"Stop":[]}}\n' > "$SCRIPT_DIR/.claude/settings.json"
rm -f "$PREVIEW"
OUT=$(report_settings_merge_drift)
if ! grep -Fq 'платформа обновила hooks/permissions' <(printf '%s' "$OUT"); then
    echo 'FAIL: an orphaned workspace-only hook did not report a warning' >&2
    exit 1
fi

# --- Case 5: --check mode on real drift -> warns, writes NOTHING ---
printf '{"hooks":{"Stop":[{"matcher":"*","hooks":[{"type":"command","command":"a.sh"}]},{"matcher":"*","hooks":[{"type":"command","command":"c.sh"}]}]}}\n' \
    > "$SCRIPT_DIR/.claude/settings.json"
printf '{"hooks":{"Stop":[{"matcher":"*","hooks":[{"type":"command","command":"a.sh"}]}]}}\n' \
    > "$WORKSPACE_DIR/.claude/settings.json"
rm -f "$PREVIEW"
CHECK_ONLY=true
OUT=$(report_settings_merge_drift)
CHECK_ONLY=false
if ! grep -Fq 'предпросмотр не записан' <(printf '%s' "$OUT"); then
    echo 'FAIL: check mode did not report the no-preview message' >&2
    exit 1
fi
if [ -f "$PREVIEW" ]; then
    echo 'FAIL: --check mode wrote a settings preview (critical finding, Fable cold review)' >&2
    exit 1
fi

echo 'PASS: settings merge drift (quiet on reorder, warns on real add/removal, --check writes nothing)'
