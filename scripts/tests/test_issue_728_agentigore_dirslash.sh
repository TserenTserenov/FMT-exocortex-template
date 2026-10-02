#!/usr/bin/env bash
# test_issue_728_agentigore_dirslash.sh — regression for issue #728.
#
# .agentigore trailing-slash directory patterns (e.g. `__pycache__/`) never
# matched anything: is_ignored() in peer-adapter-filter.py only fell through
# to a plain fnmatch(rel_path, pattern) / fnmatch(basename, pattern), and no
# real file's relative path or basename ever ends in "/". A build artifact
# like `guide-kit/structurer/__pycache__/foo.pyc` was copied into the peer
# projection uncut, even though `__pycache__/` was explicitly listed to
# exclude it (found live in a peer-session, issue #296's own fix regressed
# silently because it never worked to begin with).
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
PY3=$("$ROOT/scripts/lib/find-python3.sh")
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail=0
ok()  { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; fail=$((fail + 1)); }

SRC="$TMP/src"
DST="$TMP/dst"
mkdir -p "$SRC/guide-kit/structurer/__pycache__" "$SRC/keep"
echo "binary-ish" > "$SRC/guide-kit/structurer/__pycache__/foo.pyc"
echo "source" > "$SRC/guide-kit/structurer/foo.py"
echo "keep me" > "$SRC/keep/file.txt"

AGENTIGORE="$TMP/agentigore"
printf '__pycache__/\n' > "$AGENTIGORE"

RC=0
SRC_DIR="$SRC" DST_DIR="$DST" AGENTIGORE_FILE="$AGENTIGORE" \
  "$PY3" "$ROOT/scripts/peer-adapter-filter.py" >"$TMP/out.log" 2>"$TMP/err.log" || RC=$?

if [ "$RC" -eq 0 ]; then
  ok "фильтр отработал без ошибки"
else
  bad "фильтр отработал без ошибки (rc=$RC, stderr: $(cat "$TMP/err.log"))"
fi

if [ ! -e "$DST/guide-kit/structurer/__pycache__/foo.pyc" ]; then
  ok "__pycache__/ директория исключена из проекции (issue #728)"
else
  bad "__pycache__/ директория исключена из проекции (issue #728)"
fi

if [ -f "$DST/guide-kit/structurer/foo.py" ]; then
  ok "соседний исходник не задет исключением"
else
  bad "соседний исходник не задет исключением"
fi

if [ -f "$DST/keep/file.txt" ]; then
  ok "не связанный с паттерном файл скопирован как есть"
else
  bad "не связанный с паттерном файл скопирован как есть"
fi

if [ "$fail" -gt 0 ]; then
    echo "FAIL: $fail проверок упало"
    exit 1
fi
echo "PASS: .agentigore trailing-slash directory patterns exclude matching dirs (issue #728)"
