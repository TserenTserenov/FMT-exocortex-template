#!/usr/bin/env bash
# Issue #932: /audit-installation step 1 must find <workspace>/.iwe-paths (where
# install-iwe-paths.sh writes it), not only the legacy $HOME/.iwe-paths, and the
# digital-twin healthcheck must probe the root, not the "1_declarative" section
# (an empty metamodel category answers "Path not found" -> false red check).
# The bash block of SKILL.md step 1 is extracted and executed as written.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SKILL="$ROOT/.claude/skills/audit-installation/SKILL.md"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# Extract the first ```bash block under "## Шаг 1".
awk '/^## Шаг 1/{s=1} s&&/^```bash/{b=1;next} b&&/^```/{exit} b{print}' "$SKILL" > "$TMP/step1.sh"
[ -s "$TMP/step1.sh" ] || fail "could not extract step 1 bash block"

# Fixture: HOME without ~/.iwe-paths; workspace $HOME/IWE with .iwe-paths that
# exports IWE_SCRIPTS -> stub iwe-audit.sh.
HOME_FX="$TMP/home"
mkdir -p "$HOME_FX/IWE/tpl/scripts"
printf '#!/bin/bash\necho AUDIT_STUB_RAN\n' > "$HOME_FX/IWE/tpl/scripts/iwe-audit.sh"
printf 'export IWE_SCRIPTS="%s/IWE/tpl/scripts"\n' "$HOME_FX" > "$HOME_FX/IWE/.iwe-paths"

out=$(cd "$TMP" && env -u IWE_SCRIPTS -u IWE_PATHS_FILE -u IWE_WORKSPACE -u WORKSPACE_DIR \
    HOME="$HOME_FX" bash "$TMP/step1.sh" 2>&1)
grep -q 'AUDIT_STUB_RAN' <<<"$out" || fail "workspace .iwe-paths not picked up: $out"

# Legacy location still works as the last resort.
rm "$HOME_FX/IWE/.iwe-paths"
printf 'export IWE_SCRIPTS="%s/IWE/tpl/scripts"\n' "$HOME_FX" > "$HOME_FX/.iwe-paths"
out=$(cd "$TMP" && env -u IWE_SCRIPTS -u IWE_PATHS_FILE -u IWE_WORKSPACE -u WORKSPACE_DIR \
    HOME="$HOME_FX" bash "$TMP/step1.sh" 2>&1)
grep -q 'AUDIT_STUB_RAN' <<<"$out" || fail "legacy \$HOME/.iwe-paths no longer works: $out"

# Healthcheck probes the root.
grep -q 'path: "1_declarative"' "$SKILL" && fail "healthcheck still probes 1_declarative"
grep -q 'dt_read_digital_twin.*path: "/"' "$SKILL" || fail "healthcheck does not probe path \"/\""

echo "PASS: issue 932 (3 checks)"
