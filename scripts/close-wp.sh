#!/usr/bin/env bash
# routing: helper  skill=wp-close  called-by=agent
# Closing WP: strikes through the row in REGISTRY, appends ## Closure in archive/wp-contexts/
# see DP.SC.159, DP.ROLE.037
#
# Usage:
#   bash close-wp.sh --wp 374 --summary "Summary: AR.3+AR.4 ready, 39 tests PASS"
#   bash close-wp.sh --wp 374 --summary "..." --reason "All phases completed"
#
# Compatibility: bash 3.2+ (macOS), bash 4+ (Linux)

set -uo pipefail

IWE="${IWE_ROOT:-$HOME/IWE}"
GOV_REPO="${IWE_GOVERNANCE_REPO:-DS-strategy}"
STRATEGY="$IWE/$GOV_REPO"
REGISTRY="$STRATEGY/docs/WP-REGISTRY.md"
ARCHIVE_DIR="$STRATEGY/archive/wp-contexts"

_WPN_ROOT_UP=".."
_WPN_OPTIONAL=""
# >>> wp-num locate
# Find scripts/lib/wp-num.sh (issue #954) from THIS file's own location with symlinks
# resolved, never from IWE_WORKSPACE / IWE_ROOT / STRATEGY_DIR: callers point those at
# fixtures. Candidates, in order: lib/ next to the file, <root>/scripts/lib, the template
# clone next to a delivered workspace (<root>/IWE), the explicit
# IWE_TEMPLATE. <root> is _WPN_ROOT_UP above the file's directory (set by each consumer
# just above this block: the only per-file difference, checked by test_issue_954_locate.sh).
# The library is mandatory: not finding it is an installation error, not "WP not found",
# hence exit 4 and not 1 (memory/protocol-open.md reads exit 1 as "WP not found").
# A consumer that must keep working without the library (session-guard: its hypothesis gate
# warns and checks the exact card names, it never blocks a session over a missing library)
# sets _WPN_OPTIONAL=1 next to _WPN_ROOT_UP: WP_NUM_LIB then stays empty and nothing is sourced.
_wpn_src="${BASH_SOURCE[0]}"
_wpn_hops=0
while [ -L "$_wpn_src" ] && [ "$_wpn_hops" -lt 40 ]; do
  _wpn_link="$(readlink "$_wpn_src")"
  case "$_wpn_link" in
    /*) _wpn_src="$_wpn_link" ;;
    *) _wpn_src="$(dirname "$_wpn_src")/$_wpn_link" ;;
  esac
  _wpn_hops=$((_wpn_hops + 1))
done
_wpn_dir="$(cd -P "$(dirname "$_wpn_src")" && pwd)"
_wpn_root="$(cd -P "$_wpn_dir/$_WPN_ROOT_UP" && pwd)"
WP_NUM_LIB=""
for _wpn_cand in "$_wpn_dir/lib/wp-num.sh" \
                 "$_wpn_root/scripts/lib/wp-num.sh" \
                 "$_wpn_root/IWE/scripts/lib/wp-num.sh" \
                 ${IWE_TEMPLATE:+"$IWE_TEMPLATE/scripts/lib/wp-num.sh"}; do
  if [ -r "$_wpn_cand" ]; then
    WP_NUM_LIB="$_wpn_cand"
    break
  fi
done
if [ -z "$WP_NUM_LIB" ] && [ -z "${_WPN_OPTIONAL:-}" ]; then
  echo "❌ wp-num.sh not found (installation error, this is not «WP not found»): required scripts/lib/wp-num.sh. Searched: ${_wpn_dir}/lib, ${_wpn_root}/scripts/lib, ${_wpn_root}/IWE/scripts/lib, IWE_TEMPLATE=${IWE_TEMPLATE:-not set}. Update the template: bash update.sh" >&2
  exit 4
fi
if [ -n "$WP_NUM_LIB" ]; then
  # shellcheck source=/dev/null
  . "$WP_NUM_LIB"
fi
# <<< wp-num locate

WP_NUM=""
SUMMARY=""
REASON=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --wp)      WP_NUM="$2";   shift 2 ;;
    --summary) SUMMARY="$2";  shift 2 ;;
    --reason)  REASON="$2";   shift 2 ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$WP_NUM" ]]; then
  echo "Usage: $0 --wp NNN --summary \"Summary\" [--reason \"Reason\"]" >&2
  exit 1
fi

# Public files use the canonical three-digit ID (WP-009), while the registry
# stores the bare number (9).  Normalise the CLI once so closing a freshly
# created card does not create a second WP-9 archive or miss WP-009.md.
# The reader is shared with the other WP scripts (issue #954): 9, 009, WP-9, WP-009, wp-009.
if ! WP_NUM=$(wp_num_normalize "$WP_NUM"); then
  echo "Invalid WP number: use a number or WP-N WP-N" >&2
  exit 1
fi
WP_ID=$(wp_num_padded "$WP_NUM")
# The registry's "#" cell as it may be written: 9, 009, WP-009, ~~WP-009~~ (not 90 or 0090).
CELL_RE=$(wp_num_registry_cell_regex "$WP_NUM")

TODAY=$(date +%Y-%m-%d)

# --- Step 1: strike through the row in REGISTRY ---
echo "1/3 Updating REGISTRY..."

python3 - "$REGISTRY" "$WP_NUM" "$CELL_RE" <<'PYEOF'
import sys, re
registry_path, wp_num, cell_re = sys.argv[1], sys.argv[2], sys.argv[3]

with open(registry_path, "r", encoding="utf-8") as f:
    lines = f.readlines()

changed = False
for i, line in enumerate(lines):
    # Searching for the row with this number WP (active — without ~~NNN~~). Cell "#" can be
    # 9, 009, WP-009, 13★ — pattern shared with wp-sync-bundle.sh (#954), 90/0090 do not match.
    m = re.match(r"^(\|\s*)(" + cell_re + r")(\s*\|)", line)
    pipe_pos = line.find("|", 1)
    if m and (pipe_pos == -1 or "~~" not in line[:pipe_pos]):
        # Strike through all fields: | N | P | Name | ... |
        # Pattern: split by | and wrap each cell in ~~...~~ (except emoji-status)
        def strikethrough_cell(cell):
            stripped = cell.strip()
            # Leave untouched: empty cells, emoji-statuses (✅ ↗️ 📦 ⏳), separators ---
            if not stripped or stripped in ("✅", "↗️", "📦", "⏳", "🔄"):
                return " " + stripped + " "
            # Remove existing ** around content
            stripped = re.sub(r"^\*\*(.+)\*\*$", r"\1", stripped)
            # Remove extra closure-notes INSIDE ~~ (if any were present)
            # Clean up: everything after ~~ — closed or ~~ (details
            stripped = re.sub(r"~~(.+?)~~\s*(?:—\s*closed\b.*|—\s*Phase\d[^$]*|\((?:peer-session|PHASE)[^)]*\).*)?$",
                              r"~~\1~~", stripped, flags=re.DOTALL)
            if stripped.startswith("~~") and stripped.endswith("~~"):
                return " " + stripped + " "
            # Remove closure-notes from name
            clean = re.sub(r"\s*—\s*closed\b.*$", "", stripped, flags=re.DOTALL)
            clean = re.sub(r"\s*—\s*closed-partial\b.*$", "", clean, flags=re.DOTALL)
            clean = re.sub(r"\s*—\s*Phase\d[^|]*$", "", clean, flags=re.DOTALL)
            clean = re.sub(r"\s*\((?:peer-session|PHASE\d|backlinks)[^)]*\).*$", "", clean, flags=re.DOTALL)
            clean = clean.strip()
            if clean:
                return " ~~" + clean + "~~ "
            return " " + stripped + " "

        parts = line.rstrip("\n").split("|")
        new_parts = []
        for j, part in enumerate(parts):
            if j == 0 or j == len(parts) - 1:
                new_parts.append(part)
            else:
                new_parts.append(strikethrough_cell(part))
        lines[i] = "|".join(new_parts) + "\n"
        changed = True
        break

if not changed:
    print(f"   ⚠️  Row WP-{wp_num} not found or already struck through", file=sys.stderr)
    sys.exit(0)

with open(registry_path, "w", encoding="utf-8") as f:
    f.writelines(lines)

print(f"   ✅ REGISTRY: WP-{wp_num} struck through")
PYEOF

# --- Step 2: create archive/wp-contexts file ---
# issue #280: previously a search was done here for an existing stub from create-wp.sh (Step 2/6,
# removed after TIF7) — with it close-wp.sh was appending the summary here, and git mv from
# protocol-close.md was failing on "destination exists". Stub is no longer created —
# file in archive/wp-contexts is always created here, from scratch, on close.
echo "2/3 Creating archive/wp-contexts..."

mkdir -p "$ARCHIVE_DIR"

# Determine slug from REGISTRY
SLUG=$(python3 - "$REGISTRY" "$WP_NUM" "$CELL_RE" <<'PYEOF2'
import sys, re
registry_path, wp_num, cell_re = sys.argv[1], sys.argv[2], sys.argv[3]
with open(registry_path, "r", encoding="utf-8") as f:
    for line in f:
        # Looking for the line with this WP (now already struck through): ~~9~~, ~~WP-009~~ (#954)
        row = re.match(r"^\|\s*(" + cell_re + r")\s*\|", line)
        if row and "~~" in row.group(1):
            # Extract the name from the name column (3-rd column)
            parts = line.split("|")
            if len(parts) >= 4:
                name = parts[3].strip().strip("~").strip("*").strip()
                # Make slug
                slug = re.sub(r"[^a-za-yaYoA-YaYo0-9\s-]", "", name.lower())
                slug = re.sub(r"\s+", "-", slug.strip())[:40].strip("-")
                print(slug or "context")
                sys.exit(0)
print("context")
PYEOF2
)
CANONICAL_CONTEXT_FILE="$ARCHIVE_DIR/WP-${WP_ID}-${SLUG}.md"
# An older context written under another title (or with the number spelled differently,
# WP-044-old-title.md vs WP-44-old-title.md) is appended to, not shadowed by a second file (#954).
LEGACY_CONTEXT_FILE=$(wp_num_flat_cards "$ARCHIVE_DIR" "$WP_NUM" | head -1)
if [[ -f "$CANONICAL_CONTEXT_FILE" ]]; then
  CONTEXT_FILE="$CANONICAL_CONTEXT_FILE"
elif [[ -n "$LEGACY_CONTEXT_FILE" ]]; then
  CONTEXT_FILE="$LEGACY_CONTEXT_FILE"
else
  CONTEXT_FILE="$CANONICAL_CONTEXT_FILE"
fi
if [[ -f "$CONTEXT_FILE" ]]; then
  echo "   ℹ️  File already exists (repeated run close-wp.sh?), appending to it"
else
  cat > "$CONTEXT_FILE" <<CTXEOF
---
wp: ${WP_NUM}
created: ${TODAY}
---

# WP-${WP_NUM} — Context

CTXEOF
  echo "   ✅ New file created: $(basename "$CONTEXT_FILE")"
fi

# Detect the file language (Russian if Cyrillic characters are present in headings)
LANG_HEADER="## Closure"
if python3 -c "
import sys
with open(sys.argv[1], 'r', encoding='utf-8') as f:
    content = f.read()
# If the majority of headings are in English
import re
en_headers = len(re.findall(r'^## [A-Z]', content, re.MULTILINE))
ru_headers = len(re.findall(r'^## [A-Ya]', content, re.MULTILINE))
sys.exit(0 if ru_headers >= en_headers else 1)
" "$CONTEXT_FILE" 2>/dev/null; then
  LANG_HEADER="## Closure"
else
  LANG_HEADER="## Closure"
fi

# Check, whether the Closure section already exists/Closure
if grep -q "^## Closure\|^## Closure" "$CONTEXT_FILE" 2>/dev/null; then
  echo "   ℹ️  Section '${LANG_HEADER}' already present, appending..."
  # Append to the existing section
  python3 - "$CONTEXT_FILE" "$TODAY" "$SUMMARY" "$REASON" <<'PYEOF3'
import sys
path, today, summary, reason = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(path, "r", encoding="utf-8") as f:
    content = f.read()
addition = f"\n**Date:** {today}"
if summary:
    addition += f"\n**Summary:** {summary}"
if reason:
    addition += f"\n**Closing reason:** {reason}"
addition += "\n"
import re
content = re.sub(r"(^## (?:Closure|Closure).*?)(\n^## )", addition + r"\2", content,
                 count=1, flags=re.MULTILINE | re.DOTALL)
if addition not in content:
    content = content.rstrip() + addition
with open(path, "w", encoding="utf-8") as f:
    f.write(content)
print("   ✅ Appended to the existing section")
PYEOF3
else
  # Append the section to the end of the file
  {
    echo ""
    echo "${LANG_HEADER}"
    echo ""
    echo "**Date:** ${TODAY}"
    [[ -n "$SUMMARY" ]] && echo "**Summary:** ${SUMMARY}"
    [[ -n "$REASON" ]] && echo "**Closing reason:** ${REASON}"
    echo ""
  } >> "$CONTEXT_FILE"
  echo "   ✅ Section added '${LANG_HEADER}'"
fi

# --- Step 3: update status in inbox/WP-NNN*.md ---
echo "3/3 Updating inbox/WP-${WP_ID}..."

# The folder card in either spelling (WP-044/ is canonical, WP-44/ legacy), else a flat legacy
# card WP-044-<slug>.md / WP-44.md in inbox (#954: the flat spelling with zeros was not found).
INBOX_FILE=$(wp_num_card_path "$STRATEGY/inbox" "$WP_NUM" || true)
if [[ -z "$INBOX_FILE" ]]; then
  INBOX_FILE=$(wp_num_flat_cards "$STRATEGY/inbox" "$WP_NUM" | head -1)
fi

if [[ -n "$INBOX_FILE" ]]; then
  python3 - "$INBOX_FILE" "$TODAY" <<'PYEOF4'
import sys, re
path, today = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as f:
    content = f.read()
# Update status: in frontmatter
content = re.sub(r"^(status:\s*).*$", r"\1done", content, count=1, flags=re.MULTILINE)
# Add closed_date if not present
if "closed_date:" not in content:
    content = re.sub(r"^(created:.*\n)", r"\1closed_date: " + today + "\n", content,
                     count=1, flags=re.MULTILINE)
else:
    content = re.sub(r"^(closed_date:\s*).*$", r"\1" + today, content,
                     count=1, flags=re.MULTILINE)
with open(path, "w", encoding="utf-8") as f:
    f.write(content)
print(f"   ✅ inbox: status=done, closed_date={today}")
PYEOF4
else
  echo "   ⚠️  inbox/WP-${WP_ID}*.md not found — update manually"
fi

echo ""
echo "✅ WP-${WP_ID} closed"
echo "   Context: $(basename "${CONTEXT_FILE}")"
echo "   Next step: git add + commit both files"
