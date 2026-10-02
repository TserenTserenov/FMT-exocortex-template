#!/usr/bin/env bash
# Issue #927: pre-commit checks must not fail on a non-UTF-8 Windows console
# (cp1251). Real Windows is not available in CI, so the two failure modes are
# simulated on POSIX:
#   1. console encoding  -> PYTHONIOENCODING=cp1251 (the success-path emoji of
#      check-manifest-coverage.py is not encodable there);
#   2. default open() encoding -> ASCII (PYTHONUTF8=0, LC_ALL=C, no locale
#      coercion), so open() without encoding= cannot decode Cyrillic in
#      update-manifest.json.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not found"; exit 0; }

# --- fixture: tiny tree with a manifest that contains Cyrillic text ---------
FX="$TMP/fx"
mkdir -p "$FX/setup" "$FX/scripts"
echo x > "$FX/scripts/a.sh"
printf '%s\n' '{"version":"1.0.0","description":"Платформенный манифест","files":[{"path":"scripts/a.sh"}],"excluded_paths":[],"deprecated_files":[{"path":"roles/strategist/prompts/day-plan.md","reason":"перенесён в скилл"}]}' \
    > "$FX/update-manifest.json"
printf '%s\n' '## [1.0.0] - 2026-01-01' > "$FX/CHANGELOG.md"
# Detector 10 fixture: runner still calls a prompt the manifest marks deprecated.
mkdir -p "$FX/roles/strategist/scripts"
printf '%s\n' 'run_claude "day-plan"' > "$FX/roles/strategist/scripts/strategist.sh"

# 1. check-manifest-coverage.py: success path under a cp1251 console.
out=$(printf 'scripts/a.sh\n' | PYTHONIOENCODING=cp1251 \
    python3 "$ROOT/scripts/check-manifest-coverage.py" "$FX/update-manifest.json" 2>&1)
rc=$?
[ "$rc" -eq 0 ] || fail "check-manifest-coverage exit $rc under cp1251 console: $out"
grep -q 'manifest-coverage' <<<"$out" || fail "no success report: $out"
grep -q 'Traceback' <<<"$out" && fail "traceback in output: $out"

# 2. integration-contract-validator.sh: detector 1/9/10 read the manifest with
#    an ASCII default encoding. Must not crash with UnicodeDecodeError.
cp "$ROOT/setup/integration-contract-validator.sh" "$ROOT/setup/detector-regex.sh" "$FX/setup/"
out=$(cd "$FX" && PYTHONUTF8=0 PYTHONCOERCECLOCALE=0 LC_ALL=C LANG=C \
    bash setup/integration-contract-validator.sh 2>&1)
grep -q 'UnicodeDecodeError' <<<"$out" && fail "validator crashed on manifest encoding: $out"
grep -q '\[1/11\] manifest_paths' <<<"$out" || fail "detector 1 did not run: $out"
grep -A1 '\[1/11\] manifest_paths' <<<"$out" | grep -q 'PASS' \
    || fail "detector 1 did not PASS: $out"

# Detectors 9 and 10 must really run (not silently SKIP / swallow the error):
grep -A1 '\[9/11\] manifest_version' <<<"$out" | grep -q 'PASS (v1.0.0)' \
    || fail "detector 9 did not PASS (SKIP or crash?): $out"
grep -A1 '\[10/11\] deprecated_runner_usage' <<<"$out" | grep -q 'SKIP' \
    && fail "detector 10 was skipped: $out"
grep -q 'CONFLICT: roles/strategist/prompts/day-plan.md' <<<"$out" \
    || fail "detector 10 did not read the manifest (expected CONFLICT): $out"

echo "PASS: issue 927 (2 checks, detectors 1/9/10 asserted)"
