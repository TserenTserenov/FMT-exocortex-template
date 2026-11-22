```bash
#!/bin/bash
# protocol-close.checks.md — Gate for KE pending-review extraction-reports
# 
# Purpose: Detect extraction-reports awaiting validation (R15 Validator decision)
# and warn user before Close. Implements ADR-01E Phase4 soft gate (warning, not block).
#
# Spec: DP.SC.004 § Hard gate. Report N pending-review; if N > 0 → SLA ≤24h to /apply-captures.
# Lifecycle: cron emits extraction-report (pending-review) → Close checks → user /apply-captures.

set -eu

IWE_WORKSPACE="${IWE_WORKSPACE:-${WORKSPACE_DIR:-$HOME/IWE}}"
REPORTS_DIR="${IWE_WORKSPACE}/${GOVERNANCE_REPO}/inbox/extraction-reports"

# Count extraction-reports with status: pending-review
PENDING=$(grep -rl "^status: pending-review" "$REPORTS_DIR"/ 2>/dev/null | wc -l)

if [ "$PENDING" -gt 0 ]; then
    echo ""
    echo "⚠️  KE (Knowledge Extraction): $PENDING candidate(s) awaiting review"
    echo ""
    echo "Status: $PENDING extraction-report(s) with status 'pending-review'."
    echo "Action: run '/apply-captures' to validate and integrate into Pack,"
    echo "        or '/defer-captures' to defer until tomorrow."
    echo ""
    echo "SLA: decision required within ≤24 hours (DP.SC.004 § Invariants)."
    echo ""
    exit 1
fi

exit 0
```