### 7c. Unclosed External Sessions via Bot (WP-358 Phase10)

> Scan `inbox/agent/sessions/SESSION-*.md` (Telegram-initiated sessions via `/claude`).
> Unclosed = `status != "completed"` OR (`status: completed` AND age ≥24h without moving to `sessions/external/`).
> Do not backfill pre-cutover files — filter by mtime ≥ CUTOVER_DATE in the script.
> If N>0 — insert a markdown section into DayPlan (between "Requires Attention" and "Week Context") and duplicate to stdout.
> Skip silently if N=0. Equivalent to 7a (peer sessions DP.SC.154), but for the external channel (DP.SC.NNN external-session-request).

```bash
SECTION=$(bash {{IWE_GOVERNANCE_REPO}}/scripts/check-open-sessions.sh 2>/dev/null)
if [ -n "$SECTION" ]; then
  echo "$SECTION"
  FILE="$(ls {{IWE_GOVERNANCE_REPO}}/current/DayPlan\ *.md 2>/dev/null | head -1)"
  if [ -f "$FILE" ] && ! grep -q "Unclosed sessions" "$FILE"; then
    if grep -q "<summary><b>Week Context" "$FILE"; then
      python3 -c "
import sys
file=sys.argv[1]; section=sys.argv[2]
with open(file) as f: lines=f.readlines()
out=[]
inserted=False
for line in lines:
    if not inserted and '<summary><b>Week Context' in line:
        out.append(section+'\n\n')
        inserted=True
    out.append(line)
with open(file,'w') as f: f.writelines(out)
" "$FILE" "$SECTION"
      echo "  ✅ Section «Unclosed sessions» inserted into DayPlan"
    fi
  fi
fi
```

- [ ] If any `SESSION-*` post-cutover files exist in `inbox/agent/sessions/` with status != completed or age ≥24h — the section is inserted into DayPlan with links. Finalization — DP.SC.NNN §close.