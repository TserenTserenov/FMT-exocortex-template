### 🟡 CHECK: Unclosed external sessions (WP-358 Phase10)

> Finalize sessions via the `/claude` bot — DP.SC.NNN §close.
> Warning, not block: if there are unclosed SESSION-* entries post-cutover — remind, but allow the commit.

```bash
SECTION=$(bash {{IWE_GOVERNANCE_REPO}}/scripts/check-open-sessions.sh 2>/dev/null)
if [ -n "$SECTION" ]; then
  COUNT=$(printf '%s\n' "$SECTION" | grep -c '^| \[SESSION-' || true)
  echo "  🟡 $COUNT unclosed external sessions in inbox/agent/sessions/ — consider finalizing (DP.SC.NNN §close)"
  printf '%s\n' "$SECTION" | grep '^| \[SESSION-' | head -5
else
  echo "  ✅ No unclosed external sessions"
fi
```

- [ ] If ⚠️ — assess whether finalization is needed now (create `sessions/external/YYYY-MM/SESSION-<id>/report.md` + `git mv`). If not today — commit as-is; it will remain open until tomorrow's Day Open.