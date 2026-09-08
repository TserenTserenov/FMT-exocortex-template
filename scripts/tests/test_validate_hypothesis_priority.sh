#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
VALIDATOR="$ROOT/scripts/validate-hypothesis-priority.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# A valid П1–П4 value passes.
cat >"$TMP/valid.md" <<'EOF'
<!-- h id=H-001 p=П1 due=2026-08-31 status=review -->
<!-- h id=H-002 p=П4 due=2026-09-15 status=review -->
EOF
bash "$VALIDATOR" "$TMP/valid.md"

# An out-of-range value must be rejected, with a diagnostic naming the bad value.
cat >"$TMP/invalid.md" <<'EOF'
<!-- h id=H-003 p=П9 due=2026-08-31 status=review -->
EOF
if bash "$VALIDATOR" "$TMP/invalid.md" 2>"$TMP/invalid.err"; then
    echo 'validator accepted an out-of-range priority value' >&2
    exit 1
fi
grep -Fq 'p=П9' "$TMP/invalid.err"

# An empty p= value must be rejected, not silently skipped.
cat >"$TMP/empty.md" <<'EOF'
<!-- h id=H-004 p= due=2026-08-31 status=review -->
EOF
if bash "$VALIDATOR" "$TMP/empty.md" 2>"$TMP/empty.err"; then
    echo 'validator accepted an empty priority value' >&2
    exit 1
fi
grep -Fq 'пустое значение' "$TMP/empty.err"

# A file with no hypothesis contracts at all is not an error (nothing to validate).
cat >"$TMP/none.md" <<'EOF'
# Some unrelated document with no machine contracts.
EOF
bash "$VALIDATOR" "$TMP/none.md"

# A missing file is an error, not a silent pass.
if bash "$VALIDATOR" "$TMP/does-not-exist.md" 2>"$TMP/missing.err"; then
    echo 'validator accepted a nonexistent file' >&2
    exit 1
fi
grep -Fq 'не найден' "$TMP/missing.err"

# The real repo file must itself pass — its own contract examples use valid values.
bash "$VALIDATOR" "$ROOT/memory/lpf-hypothesis-log.md"

echo 'PASS: validate-hypothesis-priority.sh accepts П1–П4, rejects everything else'
