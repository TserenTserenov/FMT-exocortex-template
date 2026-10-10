#!/usr/bin/env bash
# issue #1149: day-open-scaffold.sh pasted $CONFIG into Python source text; on Git Bash
# the MSYS path is not converted there and Windows Python cannot open it. The path now
# goes through cygpath -m when cygpath exists.
# issue #1156: the lesson-hygiene activity regex matched only English words, so a Russian
# commit «memory: сжатие индекса памяти, ротация уроков» never counted as activity.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail=0
check() { if [ "$2" = ok ]; then echo "  ✅ $1"; else echo "  ❌ $1"; fail=1; fi; }

SCAFFOLD="$ROOT/scripts/day-open-scaffold.sh"
grep -q "open('\$CONFIG')" "$SCAFFOLD" && r=bad || r=ok
check "no raw open('\$CONFIG') left in the scaffold" "$r"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
printf '#!/bin/sh\nprintf "C:/fake/day-rhythm-config.yaml\\n"\n' > "$T/cygpath"
chmod +x "$T/cygpath"
BLOCK="$(sed -n '/^CONFIG_PY="\$CONFIG"$/,/^fi$/p' "$SCAFFOLD")"
CONFIG=/c/workspace/IWE/memory/day-rhythm-config.yaml
(PATH="$T:$PATH"; eval "$BLOCK"; [ "$CONFIG_PY" = "C:/fake/day-rhythm-config.yaml" ]) && r=ok || r=bad
check "CONFIG_PY goes through cygpath -m when available" "$r"
mkdir -p "$T/empty"
(PATH="$T/empty"; eval "$BLOCK"; [ "$CONFIG_PY" = "$CONFIG" ]) && r=ok || r=bad
check "CONFIG_PY equals CONFIG without cygpath" "$r"

REGEX="$(sed -n 's/^    commit_pattern_regex: "\(.*\)"$/\1/p' "$ROOT/.claude/sync-manifest.yaml" | sed -n 1p)"
[ -n "$REGEX" ] && r=ok || r=bad
check "lesson-hygiene regex found in sync-manifest.yaml" "$r"
for msg in "memory: сжатие индекса памяти, ротация уроков" "Уроки: архивация старых" "lessons_ archive old" "memory hygiene pass"; do
  printf '%s\n' "$msg" | grep -qE "$REGEX" && r=ok || r=bad
  check "matches: $msg" "$r"
done
printf '%s\n' "feat: новая функция календаря" | grep -qE "$REGEX" && r=bad || r=ok
check "unrelated commit does not match" "$r"
exit $fail
