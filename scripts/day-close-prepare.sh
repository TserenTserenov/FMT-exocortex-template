#!/bin/bash
# routing: helper  skill=day-close  called-by=sonnet  deterministic=true
# see DP.SC.159, DP.ROLE.059
# day-close-prepare.sh — one-call data digest for the Day Close protocol (issue #234).
# Replaces ~10 separate agent round-trips (commit scan, drift scan, index health,
# lesson stats, WakaTime, dirty repos) with a single compact digest, so Day Close
# cost does not scale with the size of the day's conversation.
#
# Usage:
#   day-close-prepare.sh            # full digest (SKILL.md step 0б)
#   day-close-prepare.sh --verify   # postconditions 9a/9b + dirty-repo recheck
#
# Exit codes: digest mode always 0; --verify returns 1 if any check FAILs.
#
# Contributed by @maxborovik (issue #234), adapted to iwe-env-bootstrap conventions.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../.claude/lib/iwe-env-bootstrap.sh" || exit 1

GOV="$IWE_DS_MY_STRATEGY"
TODAY=$(date +%Y-%m-%d)
DAY_NUM=$(date +%-d)

# MEMORY.md location: workspace symlink first, auto-memory glob as fallback.
memory_files() {
  if [ -f "$WORKSPACE_DIR/memory/MEMORY.md" ]; then
    echo "$WORKSPACE_DIR/memory/MEMORY.md"
  else
    ls "$HOME"/.claude/projects/*/memory/MEMORY.md 2>/dev/null
  fi
}

dirty_scan() {
  if [ -x "$IWE_TEMPLATE/scripts/check-dirty-repos.sh" ]; then
    bash "$IWE_TEMPLATE/scripts/check-dirty-repos.sh" 2>/dev/null
  else
    local d n
    for d in "$WORKSPACE_DIR"/*/; do
      [ -d "$d/.git" ] || continue
      n=$(git -C "$d" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
      [ "$n" -gt 0 ] && echo "dirty: $(basename "$d") ($n files)"
    done
    echo "(fallback scan — top-level repos only)"
  fi
}

# ---------------------------------------------------------------- --verify --
# Postcondition patterns mirror SKILL.md step 9 (language-tolerant, 1c62621):
# 9a "Итоги дня|Day summary", 9b "Итоги|Сводка|Results" + day number.
if [ "${1:-}" = "--verify" ]; then
  FAIL=0

  DP="$GOV/archive/day-plans/DayPlan $TODAY.md"
  if [ -f "$DP" ] && grep -qE "Итоги дня|Day summary" "$DP" && grep -q "$TODAY" "$DP"; then
    echo "9a OK: day summary present in archived DayPlan $TODAY"
  else
    echo "9a FAIL: no day summary in $DP (file missing, not archived, or summary heading absent)"
    FAIL=1
  fi

  if grep -lE "(Итоги|Сводка|Results).*${DAY_NUM}" "$GOV/current/"WeekReport*.md >/dev/null 2>&1 \
     || grep -lE "(Итоги|Сводка|Results).*${DAY_NUM}" "$GOV/current/"WeekPlan*.md >/dev/null 2>&1; then
    echo "9b OK: day results found in WeekReport (or WeekPlan fallback)"
  else
    echo "9b FAIL: day results not found in WeekReport or WeekPlan"
    FAIL=1
  fi

  DIRTY=$(dirty_scan)
  if echo "$DIRTY" | grep -qE "⚠️|dirty:"; then
    echo "dirty FAIL:"
    echo "$DIRTY"
    FAIL=1
  else
    echo "dirty OK: all repos clean and pushed"
  fi

  exit $FAIL
fi

# ----------------------------------------------------------------- digest --
echo "=== DAY CLOSE DIGEST $TODAY $(date +%H:%M) ==="

echo "--- 1. COMMITS TODAY (filtered) ---"
FOUND=0
for d in "$WORKSPACE_DIR"/*/; do
  [ -d "$d/.git" ] || continue
  commits=$(git -C "$d" log --since="today 00:00" --oneline --no-merges 2>/dev/null \
    | grep -vE "^[a-f0-9]+ (docs|chore|ci|style|perf|test)(\(|:| )" \
    | grep -vE "memory/|\.claude/rules/|template-sync|backup|reindex" || true)
  if [ -n "$commits" ]; then
    echo "=== $(basename "$d") ==="
    echo "$commits"
    FOUND=1
  fi
done
[ "$FOUND" -eq 0 ] && echo "(no substantive commits today)"

echo "--- 2. DIRTY REPOS ---"
dirty_scan

echo "--- 3. OPEN SESSIONS LOG ---"
if [ -s "$GOV/inbox/open-sessions.log" ]; then
  head -30 "$GOV/inbox/open-sessions.log"
else
  echo "(empty or absent)"
fi

echo "--- 4. MEMORY DRIFT ---"
HITS=""
for m in $(memory_files); do
  H=$(grep -nE "→ ждёт|ждёт|dep:|блокер|blocked:|остановлен|ждёт согласования|waiting on|blocked by" "$m" 2>/dev/null || true)
  [ -n "$H" ] && HITS="$HITS$m:
$H
"
done
if [ -n "$HITS" ]; then echo "$HITS"; else echo "(no drift patterns found)"; fi

echo "--- 5. INDEX HEALTH ---"
IH="$IWE_TEMPLATE/.claude/scripts/check-index-health.py"
if [ -f "$IH" ]; then
  python3 "$IH" 2>&1 | head -60
else
  echo "skip: check-index-health.py not found"
fi

echo "--- 6. LESSON / MEMORY STATS ---"
for m in $(memory_files); do
  [ -f "$m" ] || continue
  LINES=$(wc -l < "$m" | tr -d ' ')
  # Lesson files are named lesson-<topic>.md / lessons_<topic>.md — match both
  # spellings; the old "lessons_" literal never matched and always counted 0 (#559).
  LESSONS=$(grep -cE "lessons?[-_]" "$m" 2>/dev/null || true)
  echo "MEMORY.md: $LINES lines (flag if >200), $LESSONS lesson references (target ≤8)"
done

echo "--- 7. WAKATIME ---"
# issue #859: wakatime-cli --today reads the statusbar endpoint, which does not
# include the AI Coding category. Use the summaries endpoint instead, matching
# the proven path in day-open-multiplier-backfill-patch.py.
python3 - "$TODAY" <<'PYEOF'
import sys, os, re, json, urllib.request, base64, configparser
target = sys.argv[1]
api_key = os.environ.get("WAKATIME_API_KEY", "").strip() or None
if not api_key:
    for env_path in [
        os.path.expanduser("~/.config/aist/env"),
        os.path.expanduser("~/.iwe/.exocortex.env"),
        os.path.expanduser("~/.wakatime.env"),
    ]:
        if not os.path.isfile(env_path):
            continue
        try:
            with open(env_path) as f:
                for line in f:
                    # Support KEY=value, KEY="value", KEY='value', export KEY=value
                    m = re.match(r"^(?:export\s+)?WAKATIME_API_KEY\s*=\s*([\"']?)([^\"'\n]+)\1\s*$", line)
                    if m:
                        api_key = m.group(2).strip()
                        break
        except (OSError, UnicodeError) as exc:
            print(f"(cannot read {env_path}: {exc})")
        if api_key:
            break
if not api_key and os.path.isfile(os.path.expanduser("~/.wakatime.cfg")):
    try:
        cfg = configparser.ConfigParser()
        cfg.read(os.path.expanduser("~/.wakatime.cfg"))
        api_key = cfg.get("settings", "api_key", fallback=None)
    except (OSError, configparser.Error) as exc:
        print(f"(cannot read ~/.wakatime.cfg: {exc})")
if not api_key:
    print("(WAKATIME_API_KEY not found — use Neon fallback: domain_event coding_time)")
    sys.exit(0)
url = f"https://wakatime.com/api/v1/users/current/summaries?start={target}&end={target}"
auth = base64.b64encode(f"{api_key}:".encode()).decode()
req = urllib.request.Request(url, headers={"Authorization": f"Basic {auth}", "Accept": "application/json"})
try:
    with urllib.request.urlopen(req, timeout=15) as resp:
        body = json.loads(resp.read().decode("utf-8"))
except (urllib.error.URLError, json.JSONDecodeError, TimeoutError) as exc:
    print(f"(WakaTime API error: {exc} — use Neon fallback: domain_event coding_time)")
    sys.exit(0)
days = body.get("data") if isinstance(body, dict) else None
if not isinstance(days, list) or not days:
    print("(no WakaTime data for today)")
    sys.exit(0)
day_entry = next((d for d in days if isinstance(d, dict) and d.get("range", {}).get("date") == target), None)
if not isinstance(day_entry, dict):
    print(f"(no WakaTime entry for {target})")
    sys.exit(0)
grand_total = day_entry.get("grand_total")
seconds = grand_total.get("total_seconds") if isinstance(grand_total, dict) else None
if not isinstance(seconds, (int, float)) or isinstance(seconds, bool) or seconds <= 0:
    print("(no positive WakaTime time for today)")
    sys.exit(0)
print(f"{seconds / 3600:.2f} h (WakaTime summaries)")
PYEOF

echo "--- 8. PEER SESSIONS TODAY ---"
if [ -f "$GOV/sessions/00-index.md" ]; then
  grep "$TODAY" "$GOV/sessions/00-index.md" || echo "(none today)"
else
  echo "(no sessions index)"
fi

echo "--- 9. DAYPLANS IN current/ (to archive) ---"
ls "$GOV/current/"DayPlan*.md 2>/dev/null || echo "(none — already archived)"

echo "--- 10. DONE WP CONTEXTS IN inbox/ (to archive) ---"
# ^status matches only the top-level frontmatter key; indented phase entries
# don't count. Both layouts supported: inbox/WP-N.md and inbox/WP-N/WP-N.md.
grep -lE "^status: (done|closed)" "$GOV/inbox/"WP-*.md "$GOV/inbox/"WP-*/WP-*.md 2>/dev/null || echo "(none)"

echo "--- 11. WEEKREPORT ---"
ls "$GOV/current/"WeekReport*.md 2>/dev/null || echo "(absent — fallback: write day facts to WeekPlan, flag for split)"

echo "=== END DIGEST ==="
