#!/usr/bin/env bash
# routing: utility  deterministic=true
# see DP.SC.159, DP.ROLE.059
#
# verify-template-integrity.sh — local mirror of the CI template-integrity gate.
#
# Why: the authoritative integrity/contract checks live only in
# .github/workflows/validate-template.yml, downstream of "done". The 2026-06-29
# red CI (manifest drift + rules-lazy fresh-install gap) passed our local
# close-protocol because we had no local equivalent — only upstream CI ran them.
# This bundles the SAME scripts the CI runs into one command, so the promotion/
# close flow closes the loop before push, not after — i.e. catches locally what
# upstream CI would catch.
#
# Mirrors the CI `validate` + `integration-contract` jobs:
#   - manifest sync, setup/update parity, component-set parity
#   - integration contract (spec↔state drift), fresh-install smoke, detector regression
# NOT bundled (run separately): shellcheck (-S error over all .sh), upgrade-test
# (needs git-history checkout of the previous release — too heavy for a quick gate).
#
# Run before delivering template changes (template-sync / promote / close).
#
# Exit 0 — all checks pass. Exit 1 — at least one failed.
#
# Related: peer-session 2026-06-29-03-ci-verification-gap-diagnosis

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# Paths relative to repo root — same scripts the CI workflow invokes.
CHECKS=(
  "scripts/verify-manifest.sh"
  "scripts/check-setup-update-parity.sh"
  "scripts/check-component-parity.sh"
  "setup/integration-contract-validator.sh"
  "setup/smoke-test-fresh-install.sh"
  "setup/test-detectors.sh"
)

FAIL=0
for chk in "${CHECKS[@]}"; do
  echo "──────────────────────────────────────────────"
  echo "▶ $chk"
  echo "──────────────────────────────────────────────"
  if bash "$REPO_ROOT/$chk"; then
    echo "  → passed"
  else
    echo "  → FAILED ($chk)"
    FAIL=1
  fi
  echo ""
done

if [[ "$FAIL" -eq 0 ]]; then
  echo "✅ template integrity: all checks passed"
  exit 0
fi
echo "❌ template integrity: one or more checks failed (see above)"
exit 1
