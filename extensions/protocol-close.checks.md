#!/bin/bash
# protocol-close.checks.md — Gate for KE pending-review extraction-reports
# 
# Purpose: Detect extraction-reports awaiting validation (R15 Валидатор decision)
# and warn user before Close. Implements ADR-01E Ф4 soft gate (warning, not block).
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
    echo "⚠️  KE (Извлечение знаний): $PENDING кандидат(ов) ожидает разбора"
    echo ""
    echo "Статус: есть $PENDING extraction-report(ов) со статусом 'pending-review'."
    echo "Решение: запустите '/apply-captures' для валидации и интеграции в Pack,"
    echo "         или '/defer-captures' для отложения до завтра."
    echo ""
    echo "SLA: решение принять ≤24 часов (DP.SC.004 § Инварианты)."
    echo ""
    exit 1
fi

exit 0
