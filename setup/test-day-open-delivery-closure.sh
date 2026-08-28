#!/bin/bash
# test-day-open-delivery-closure.sh — WP-529 F7 acceptance test for the Day Open
# delivery contract: every runtime dependency of scripts/day-open-pipeline.sh
# must resolve inside the delivery root (template scripts/ + seed mirror), with
# transitive closure over python imports and shell sources — not just the files
# someone remembered to list. Spec: peer sessions 2026-08-20-42 (5-point fixture
# spec) and 2026-08-21-17 (baseline->promote->green protocol, codex amendments:
# dynamic call sites, +x/shebang, manifest duplicates). Section 5 (extension
# graph) implemented WP-529 F11 — see scripts/day-open-hooks-runner.sh.
#
# Bash 3.2 compatible on purpose (macOS /bin/bash): no declare -A, no mapfile.
#
# Usage: bash setup/test-day-open-delivery-closure.sh

set -uo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SELF_DIR")"
PIPELINE="$REPO_ROOT/scripts/day-open-pipeline.sh"
SEED_SCRIPTS="$REPO_ROOT/seed/strategy/scripts"
MANIFEST="$REPO_ROOT/update-manifest.json"

FAIL_COUNT=0
PASS_COUNT=0
fail() { echo "  ❌ FAIL: $*" >&2; FAIL_COUNT=$((FAIL_COUNT + 1)); }
pass() { echo "  ✅ PASS: $*"; PASS_COUNT=$((PASS_COUNT + 1)); }

[ -f "$PIPELINE" ] || { echo "FATAL: $PIPELINE not found" >&2; exit 2; }

# --- 1. Closure of $DS_STRATEGY/scripts/ references in the pipeline ----------
# Dynamic extraction (codex amendment: no hand-kept list): every literal
# $DS_STRATEGY/scripts/<path> the pipeline mentions, in any call form (direct,
# bash -c, heredoc) — the literal is what delivery must satisfy.
echo "=== 1. Pipeline references resolve inside the delivery root ==="
STRATEGY_REFS=$(grep -o '\$DS_STRATEGY/scripts/[a-zA-Z0-9._/-]*' "$PIPELINE" | sed 's|^\$DS_STRATEGY/||' | sort -u)
# An empty extraction means the regex no longer matches the pipeline (variable
# renamed, quoting changed) — every section below would loop zero times and the
# test would pass while checking nothing (cold review 2026-08-21-17, High).
if [ -z "$STRATEGY_REFS" ]; then
  fail "no \$DS_STRATEGY/scripts/ references extracted from pipeline — extraction regex broken"
fi
for rel in $STRATEGY_REFS; do
  f="$REPO_ROOT/$rel"
  if [ -f "$f" ]; then
    pass "delivered: $rel"
  else
    fail "referenced by pipeline but NOT delivered in template: $rel"
    continue
  fi
  case "$rel" in
    *.sh)
      [ -x "$f" ] && pass "executable bit: $rel" || fail "missing +x: $rel"
      head -1 "$f" | grep -q '^#!' && pass "shebang: $rel" || fail "missing shebang: $rel"
      ;;
  esac
  # Seed mirror: the pipeline itself ships in seed for fresh installs, so every
  # $DS_STRATEGY-relative dependency must ship there too (2026-08-20-42, theme 4:
  # update path and seed are two separate delivery axes).
  if [ -f "$SEED_SCRIPTS/$rel" ] || [ -f "$SEED_SCRIPTS/${rel#scripts/}" ]; then
    pass "seed mirror: $rel"
  else
    fail "not mirrored into seed/strategy/: $rel"
  fi
done

# --- 2. Transitive closure: python imports and shell sources ------------------
echo "=== 2. Transitive closure (imports / sources) ==="
LIB_PY_MODULES=""
if [ -d "$REPO_ROOT/scripts/lib" ]; then
  LIB_PY_MODULES=$(ls "$REPO_ROOT/scripts/lib"/*.py 2>/dev/null | sed 's|.*/||; s|\.py$||')
fi
for rel in $STRATEGY_REFS; do
  f="$REPO_ROOT/$rel"
  [ -f "$f" ] || continue
  case "$rel" in
    *.py)
      # Local module imports (scripts/lib/*.py style: from X import / import X).
      IMPORTS=$(grep -E '^[[:space:]]*(from|import)[[:space:]]+[a-zA-Z_][a-zA-Z0-9_]*' "$f" | sed -E 's/^[[:space:]]*(from|import)[[:space:]]+([a-zA-Z_][a-zA-Z0-9_]*).*/\2/' | sort -u)
      for mod in $IMPORTS; do
        # Only local lib modules are delivery obligations; stdlib/3rd-party are not.
        libfile="$REPO_ROOT/scripts/lib/$mod.py"
        if echo "$IMPORTS" | grep -q "^$mod$" && [ -f "$libfile" ]; then
          pass "local import satisfied: $rel -> lib/$mod.py"
          [ -f "$SEED_SCRIPTS/lib/$mod.py" ] && pass "seed mirror: lib/$mod.py" || fail "lib/$mod.py not mirrored into seed"
        else
          # Missing local module is only a failure if some scripts/lib/<mod>.py
          # exists nowhere AND the import is known-local (wp_inbox, ledger_path
          # naming convention: module files we deliver under scripts/lib/).
          case "$mod" in
            wp_inbox|ledger_path)
              [ -f "$libfile" ] || fail "local import NOT delivered: $rel imports $mod (expected scripts/lib/$mod.py)"
              ;;
          esac
        fi
      done
      ;;
    *.sh)
      SOURCES=$(grep -oE '(source|\.)[[:space:]]+"?\$?[A-Za-z_{}]*/?(scripts/)?lib/[a-zA-Z0-9._-]+\.sh' "$f" | grep -o 'lib/[a-zA-Z0-9._-]*\.sh' | sort -u)
      for libref in $SOURCES; do
        if [ -f "$REPO_ROOT/scripts/$libref" ]; then
          pass "shell source satisfied: $rel -> $libref"
          [ -f "$SEED_SCRIPTS/$libref" ] && pass "seed mirror: $libref" || fail "$libref not mirrored into seed"
        else
          fail "shell source NOT delivered: $rel sources $libref"
        fi
      done
      ;;
  esac
done

# --- 2b. Pipeline-own dependencies invisible to $DS_STRATEGY extraction -------
# find-python3.sh is sourced via $(dirname BASH_SOURCE)/lib/ — not a
# $DS_STRATEGY literal, so section 1 never sees it; without this check its
# deletion would go unnoticed (RESOLVED_PY silently falls back to python3).
echo "=== 2b. Resolver delivery (BASH_SOURCE-relative dependency) ==="
if [ -f "$REPO_ROOT/scripts/lib/find-python3.sh" ] && [ -x "$REPO_ROOT/scripts/lib/find-python3.sh" ]; then
  pass "delivered + executable: scripts/lib/find-python3.sh"
else
  fail "scripts/lib/find-python3.sh missing or not executable"
fi
[ -f "$SEED_SCRIPTS/lib/find-python3.sh" ] && pass "seed mirror: lib/find-python3.sh" || fail "lib/find-python3.sh not mirrored into seed"
if [ -f "$MANIFEST" ]; then
  n=$(grep -c '"scripts/lib/find-python3.sh"' "$MANIFEST") || true
  [ "$n" -eq 1 ] && pass "manifest exactly once: scripts/lib/find-python3.sh" || fail "manifest entries for scripts/lib/find-python3.sh: $n (expected 1)"
fi

# --- 2c. Default checks file (data dependency of the Checks step) -------------
# The checks runner blocks on "found 0 bash blocks" but degrades to "nothing to
# check" when NO checks file exists at all — a fresh install shipped none
# (external user report, 2026-08-21). The default must exist, carry at least
# one bash block, and be in the manifest exactly once.
echo "=== 2c. Default day-open.checks.md delivery ==="
DEFAULT_CHECKS="$REPO_ROOT/extensions/day-open.checks.md"
if [ -f "$DEFAULT_CHECKS" ]; then
  pass "delivered: extensions/day-open.checks.md"
  if grep -q '^```bash$' "$DEFAULT_CHECKS"; then
    pass "default checks file carries executable bash block(s)"
  else
    fail "extensions/day-open.checks.md has no \`\`\`bash blocks — runner would block on 0 blocks"
  fi
else
  fail "extensions/day-open.checks.md not delivered — Checks step degrades to 'nothing to check' on fresh installs"
fi
if [ -f "$MANIFEST" ]; then
  n=$(grep -c '"extensions/day-open.checks.md"' "$MANIFEST") || true
  [ "$n" -eq 1 ] && pass "manifest exactly once: extensions/day-open.checks.md" || fail "manifest entries for extensions/day-open.checks.md: $n (expected 1)"
fi

# --- 2d. Snapshot updater resolves the installed workspace -------------------
echo "=== 2d. Derived snapshot path contract ==="
SNAPSHOT_ROOT_SCRIPT="$REPO_ROOT/scripts/update-derived-snapshot.py"
SNAPSHOT_SEED_SCRIPT="$SEED_SCRIPTS/update-derived-snapshot.py"
SNAPSHOT_TEST_ROOT="/tmp/iwe-snapshot-path-test-$$"
SNAPSHOT_PY=$("$REPO_ROOT/scripts/lib/find-python3.sh" 2>/dev/null) || SNAPSHOT_PY=""
[ -n "$SNAPSHOT_PY" ] || SNAPSHOT_PY=python3
SNAPSHOT_CONFIG_ROOT="$SNAPSHOT_TEST_ROOT/configured-workspace"
SNAPSHOT_EXPECTED="$SNAPSHOT_CONFIG_ROOT/custom-governance/inbox/WP-425/cache/derived_snapshot.json"

SNAPSHOT_ACTUAL=$(IWE_ROOT="$SNAPSHOT_CONFIG_ROOT" IWE_GOVERNANCE_REPO=custom-governance \
  "$SNAPSHOT_PY" - "$SNAPSHOT_ROOT_SCRIPT" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("snapshot_path_contract", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
print(module.SNAPSHOT_PATH)
PY
)
if [ "$SNAPSHOT_ACTUAL" = "$SNAPSHOT_EXPECTED" ]; then
  pass "template source uses the configured IWE_ROOT/governance path"
else
  fail "template source resolved the wrong snapshot path: $SNAPSHOT_ACTUAL"
fi

SNAPSHOT_INSTALLED_REPO="$SNAPSHOT_TEST_ROOT/physical-workspace/custom-governance"
mkdir -p "$SNAPSHOT_INSTALLED_REPO/scripts"
cp "$SNAPSHOT_SEED_SCRIPT" "$SNAPSHOT_INSTALLED_REPO/scripts/update-derived-snapshot.py"
cp "$REPO_ROOT/seed/strategy/REPO-TYPE.md" "$SNAPSHOT_INSTALLED_REPO/REPO-TYPE.md"
SNAPSHOT_INSTALLED_REPO_PHYSICAL=$(cd "$SNAPSHOT_INSTALLED_REPO" && pwd -P)
SNAPSHOT_INSTALLED_EXPECTED="$SNAPSHOT_INSTALLED_REPO_PHYSICAL/inbox/WP-425/cache/derived_snapshot.json"
SNAPSHOT_INSTALLED_ACTUAL=$( \
  IWE_ROOT="$SNAPSHOT_TEST_ROOT/stale-workspace" \
  IWE_GOVERNANCE_REPO=stale-governance \
  "$SNAPSHOT_PY" - "$SNAPSHOT_INSTALLED_REPO/scripts/update-derived-snapshot.py" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location("installed_snapshot_path_contract", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
print(module.SNAPSHOT_PATH)
PY
)
if [ "$SNAPSHOT_INSTALLED_ACTUAL" = "$SNAPSHOT_INSTALLED_EXPECTED" ]; then
  pass "installed updater derives custom governance from its physical location"
else
  fail "installed updater trusted stale caller identity: $SNAPSHOT_INSTALLED_ACTUAL"
fi

for snapshot_script in "$SNAPSHOT_ROOT_SCRIPT" "$SNAPSHOT_SEED_SCRIPT"; do
  if grep -Fq '${IWE_GOVERNANCE_REPO:-DS-strategy}' "$snapshot_script"; then
    fail "shell parameter expansion remains literal in ${snapshot_script#"$REPO_ROOT"/}"
  else
    pass "no shell-literal governance path: ${snapshot_script#"$REPO_ROOT"/}"
  fi
done

grep -vF '# SNAPSHOT — synced manually via script-promote.sh from FMT-exocortex-template/scripts/. Do not edit here directly.' \
  "$SNAPSHOT_SEED_SCRIPT" > "$SNAPSHOT_TEST_ROOT.seed-body"
if cmp -s "$SNAPSHOT_ROOT_SCRIPT" "$SNAPSHOT_TEST_ROOT.seed-body"; then
  pass "root and seed snapshot implementations are identical"
else
  fail "root and seed snapshot implementations drifted"
fi
rm -rf "$SNAPSHOT_TEST_ROOT" "$SNAPSHOT_TEST_ROOT.seed-body"

# --- 2e. Day Open exports the governance identity before background work -----
# A non-interactive launch does not inherit the user's shell configuration.
# The snapshot updater is the first child process, so it must receive the
# repository identity derived from the pipeline location, not the legacy
# DS-strategy default.
echo "=== 2e. Governance identity reaches the first child process ==="
PIPELINE_ENV_FIXTURE="/tmp/iwe-dayopen-governance-env-$$"
PIPELINE_ENV_GOV="$PIPELINE_ENV_FIXTURE/custom-governance"
PIPELINE_ENV_CAPTURE="$PIPELINE_ENV_FIXTURE/captured-governance.txt"
mkdir -p "$PIPELINE_ENV_GOV/scripts/lib" "$PIPELINE_ENV_GOV/logs" \
  "$PIPELINE_ENV_FIXTURE/scripts"
printf '#!/bin/bash\nexit 0\n' > "$PIPELINE_ENV_FIXTURE/scripts/session-guard.sh"
chmod +x "$PIPELINE_ENV_FIXTURE/scripts/session-guard.sh"
printf '# test fixture: no ledger helpers needed before snapshot launch\n' \
  > "$PIPELINE_ENV_GOV/scripts/lib/ledger-path.sh"
cat > "$PIPELINE_ENV_GOV/scripts/update-derived-snapshot.py" <<'PY'
#!/usr/bin/env python3
import os
from pathlib import Path

Path(os.environ["SNAPSHOT_ENV_CAPTURE"]).write_text(
    os.environ.get("IWE_ROOT", "")
    + "|"
    + os.environ.get("IWE_GOVERNANCE_REPO", ""),
    encoding="utf-8",
)
PY
awk '{ print } /echo "  snapshot refresh pid=\$SNAPSHOT_PID/ { exit }' "$PIPELINE" \
  > "$PIPELINE_ENV_GOV/scripts/day-open-prefix.sh"
printf '\nwait "$SNAPSHOT_PID"\n' >> "$PIPELINE_ENV_GOV/scripts/day-open-prefix.sh"
if env -i HOME="${HOME:-/tmp}" PATH="${PATH:-/usr/bin:/bin}" \
    SNAPSHOT_ENV_CAPTURE="$PIPELINE_ENV_CAPTURE" \
    bash "$PIPELINE_ENV_GOV/scripts/day-open-prefix.sh" >/dev/null 2>&1 \
    && [ "$(cat "$PIPELINE_ENV_CAPTURE" 2>/dev/null)" = "$PIPELINE_ENV_FIXTURE|custom-governance" ]; then
  pass "minimal environment passes custom governance identity to snapshot updater"
else
  fail "snapshot updater did not receive governance identity before background launch"
fi
printf 'not-overwritten' > "$PIPELINE_ENV_CAPTURE"
if env -i HOME="${HOME:-/tmp}" PATH="${PATH:-/usr/bin:/bin}" \
    IWE_ROOT="/tmp/stale-foreign-workspace" \
    IWE_GOVERNANCE_REPO="stale-foreign-governance" \
    SNAPSHOT_ENV_CAPTURE="$PIPELINE_ENV_CAPTURE" \
    bash "$PIPELINE_ENV_GOV/scripts/day-open-prefix.sh" >/dev/null 2>&1 \
    && [ "$(cat "$PIPELINE_ENV_CAPTURE" 2>/dev/null)" = "$PIPELINE_ENV_FIXTURE|custom-governance" ]; then
  pass "physical pipeline location overrides stale inherited workspace identity"
else
  fail "stale inherited workspace identity escaped into snapshot updater"
fi
rm -rf "$PIPELINE_ENV_FIXTURE"

# --- 3. Entry points run from a foreign cwd with a clean PYTHONPATH -----------
echo "=== 3. Foreign-cwd smoke (clean PYTHONPATH) ==="
RESOLVED_PY=""
[ -x "$REPO_ROOT/scripts/lib/find-python3.sh" ] && RESOLVED_PY=$("$REPO_ROOT/scripts/lib/find-python3.sh" 2>/dev/null) || true
[ -n "$RESOLVED_PY" ] || RESOLVED_PY="python3"
SMOKE_DIR="/tmp/iwe-dayopen-closure-smoke-$$"
mkdir -p "$SMOKE_DIR"
for rel in $STRATEGY_REFS; do
  f="$REPO_ROOT/$rel"
  [ -f "$f" ] || continue
  case "$rel" in
    scripts/day-open-*.py)
      if (cd "$SMOKE_DIR" && PYTHONPATH= "$RESOLVED_PY" "$f" --help >/dev/null 2>&1); then
        pass "runs from foreign cwd: $rel --help"
      else
        fail "broken from foreign cwd (import/path error?): $rel --help"
      fi
      ;;
  esac
done
rm -rf "$SMOKE_DIR"

# --- 4. Manifest: each delivered closure file present, no duplicate entries ---
echo "=== 4. update-manifest.json coverage ==="
if [ -f "$MANIFEST" ]; then
  for rel in $STRATEGY_REFS; do
    [ -f "$REPO_ROOT/$rel" ] || continue
    n=$(grep -c "\"$rel\"" "$MANIFEST") || true
    if [ "$n" -eq 1 ]; then
      pass "manifest exactly once: $rel"
    elif [ "$n" -eq 0 ]; then
      fail "missing from manifest: $rel"
    else
      fail "duplicate manifest entries ($n): $rel"
    fi
  done
else
  fail "update-manifest.json not found"
fi

# --- 5. Extension graph (WP-529 F11, ArchGate Q1 implemented) -----------------
# before/after now dispatch through scripts/day-open-hooks-runner.sh (same
# bash-block-in-Markdown mechanism "checks" already used, so it also runs
# correctly unattended with no LLM present — see scripts/lib/day-open-hooks.sh
# header comment). "core" is not a hook point — it is the built-in pipeline
# body between before and after (same shape as day-close: before/checks/after,
# no "core" call there either).
echo "=== 5. Extension graph (WP-529 F11) ==="
HOOKS_RUNNER="$REPO_ROOT/scripts/day-open-hooks-runner.sh"

# Dynamic extraction, same defensive pattern as section 1: an empty match
# means the pipeline no longer calls the dispatcher (renamed, refactored
# away) and every check below would pass while testing nothing.
DISPATCH_CALLS=$(grep -oE 'day-open-hooks-runner\.sh"[[:space:]]+(before|after)' "$PIPELINE" | grep -oE '(before|after)$' | sort -u)
if [ -z "$DISPATCH_CALLS" ]; then
  fail "day-open-pipeline.sh does not call day-open-hooks-runner.sh at all — extraction found nothing"
else
  for hook in before after; do
    if echo "$DISPATCH_CALLS" | grep -qx "$hook"; then
      pass "pipeline dispatches the '$hook' hook"
    else
      fail "pipeline does not dispatch the '$hook' hook"
    fi
  done
fi
[ -f "$HOOKS_RUNNER" ] || fail "scripts/day-open-hooks-runner.sh not found"

HOOKS_WORK=$(mktemp -d)
trap 'rm -rf "$HOOKS_WORK"' EXIT
mkdir -p "$HOOKS_WORK/extensions"

# 5a. No hook files -> silent no-op (exit 0, no output).
HOOKS_OUT=$(IWE_ROOT="$HOOKS_WORK" bash "$HOOKS_RUNNER" before 2>&1)
HOOKS_EXIT=$?
if [ "$HOOKS_EXIT" -eq 0 ] && [ -z "$HOOKS_OUT" ]; then
  pass "no hook files: silent no-op"
else
  fail "no hook files: expected silent exit 0, got exit=$HOOKS_EXIT output='$HOOKS_OUT'"
fi

# 5b. A passing hook runs and its bash block actually executes (not just
# "didn't crash" — P1: assert the observable side effect).
MARKER="$HOOKS_WORK/marker.txt"
cat > "$HOOKS_WORK/extensions/day-open.before.md" <<EOF
\`\`\`bash
echo "ran" > "$MARKER"
\`\`\`
EOF
IWE_ROOT="$HOOKS_WORK" bash "$HOOKS_RUNNER" before >/dev/null 2>&1
if [ "$?" -eq 0 ] && [ -f "$MARKER" ] && [ "$(cat "$MARKER")" = "ran" ]; then
  pass "passing before-hook: block executed, exit 0"
else
  fail "passing before-hook: expected marker file with 'ran', exit 0"
fi
rm -f "$MARKER" "$HOOKS_WORK/extensions/day-open.before.md"

# 5c. A failing hook block makes the runner exit nonzero — this is what the
# pipeline calls above use to decide whether to abort (a before/after hook
# can mutate DS_STRATEGY state, so a silent WARN-and-continue would let a
# half-failed mutation get committed — Codex review, 2026-08-28).
cat > "$HOOKS_WORK/extensions/day-open.after.md" <<'EOF'
```bash
exit 1
```
EOF
IWE_ROOT="$HOOKS_WORK" bash "$HOOKS_RUNNER" after >/dev/null 2>&1
if [ "$?" -ne 0 ]; then
  pass "failing after-hook: runner exits nonzero"
else
  fail "failing after-hook: runner exited 0, pipeline would commit past a failed hook"
fi
rm -f "$HOOKS_WORK/extensions/day-open.after.md"

# 5c2. A failing command FOLLOWED by a successful one must still be caught —
# not just a block whose only/last statement fails (Codex review, 2026-08-28,
# High regression: `if ! ( set -e; eval "$block" ); then` suppresses errexit
# for a subshell that is itself the condition of `if`/`!`, so `false` followed
# by a successful command silently "passed" even with `set -e` re-declared
# inside the subshell — a genuine footgun, not a hypothetical one).
cat > "$HOOKS_WORK/extensions/day-open.after.md" <<'EOF'
```bash
false
echo "survived"
```
EOF
IWE_ROOT="$HOOKS_WORK" bash "$HOOKS_RUNNER" after >/dev/null 2>&1
if [ "$?" -ne 0 ]; then
  pass "failing command followed by a successful one is still caught (errexit-in-condition footgun)"
else
  fail "a failing command followed by a successful one was NOT caught — errexit-in-condition footgun"
fi
rm -f "$HOOKS_WORK/extensions/day-open.after.md"

# 5d. Exact-name matching: day-open.beforeevil.md must NOT match the
# "before" hook (the literal dot after the hook name is part of the glob).
cat > "$HOOKS_WORK/extensions/day-open.beforeevil.md" <<'EOF'
```bash
exit 1
```
EOF
IWE_ROOT="$HOOKS_WORK" bash "$HOOKS_RUNNER" before >/dev/null 2>&1
if [ "$?" -eq 0 ]; then
  pass "day-open.beforeevil.md does not false-match the 'before' hook"
else
  fail "day-open.beforeevil.md incorrectly matched the 'before' hook"
fi
rm -f "$HOOKS_WORK/extensions/day-open.beforeevil.md"

# 5e. Split-file convention (day-open.<hook>.<suffix>.md) runs in LC_ALL=C
# sorted order — same convention "checks" already documents.
ORDER_FILE="$HOOKS_WORK/order.txt"
cat > "$HOOKS_WORK/extensions/day-open.after.a-first.md" <<EOF
\`\`\`bash
echo "a" >> "$ORDER_FILE"
\`\`\`
EOF
cat > "$HOOKS_WORK/extensions/day-open.after.b-second.md" <<EOF
\`\`\`bash
echo "b" >> "$ORDER_FILE"
\`\`\`
EOF
IWE_ROOT="$HOOKS_WORK" bash "$HOOKS_RUNNER" after >/dev/null 2>&1
if [ "$(tr '\n' ',' < "$ORDER_FILE" 2>/dev/null)" = "a,b," ]; then
  pass "split hook files run in sorted (a-first, b-second) order"
else
  fail "split hook files did not run in sorted order: $(cat "$ORDER_FILE" 2>/dev/null | tr '\n' ',')"
fi
rm -f "$ORDER_FILE" "$HOOKS_WORK/extensions/day-open.after.a-first.md" "$HOOKS_WORK/extensions/day-open.after.b-second.md"

# 5f. A hook file that contributes zero bash blocks is an error, not a
# silent pass (same fencing-typo trap issue #466 fixed for "checks").
cat > "$HOOKS_WORK/extensions/day-open.before.md" <<'EOF'
No bash blocks here, just prose.
EOF
IWE_ROOT="$HOOKS_WORK" bash "$HOOKS_RUNNER" before >/dev/null 2>&1
if [ "$?" -ne 0 ]; then
  pass "hook file with zero bash blocks fails loudly (fencing-typo trap)"
else
  fail "hook file with zero bash blocks silently passed"
fi
rm -f "$HOOKS_WORK/extensions/day-open.before.md"

# 5g. Bash 3.2 (macOS system bash) compatibility — the runner and the shared
# lib must work under the same interpreter the macOS CI matrix pins to.
if command -v /bin/bash >/dev/null 2>&1 && /bin/bash -c '[[ "${BASH_VERSINFO[0]}" -lt 4 ]]' 2>/dev/null; then
  cat > "$HOOKS_WORK/extensions/day-open.before.md" <<EOF
\`\`\`bash
echo "ran" > "$MARKER"
\`\`\`
EOF
  IWE_ROOT="$HOOKS_WORK" /bin/bash "$HOOKS_RUNNER" before >/dev/null 2>&1
  if [ "$?" -eq 0 ] && [ -f "$MARKER" ]; then
    pass "runs under /bin/bash 3.2"
  else
    fail "does not run under /bin/bash 3.2"
  fi
  rm -f "$MARKER" "$HOOKS_WORK/extensions/day-open.before.md"
fi

# 5h. A well-formed hook file must not mask a sibling with zero bash blocks
# for the SAME hook (Codex review, 2026-08-28, High: a shared "any blocks
# ran at all" check across the whole set let a fencing-typo file in a split
# day-open.<hook>.<suffix>.md set pass silently as long as another file in
# the set had valid blocks).
cat > "$HOOKS_WORK/extensions/day-open.before.md" <<EOF
\`\`\`bash
echo "valid" > "$MARKER"
\`\`\`
EOF
cat > "$HOOKS_WORK/extensions/day-open.before.custom.md" <<'EOF'
prose, no fencing — oops
EOF
IWE_ROOT="$HOOKS_WORK" bash "$HOOKS_RUNNER" before >/dev/null 2>&1
if [ "$?" -ne 0 ]; then
  pass "zero-block sibling file is not masked by a valid one"
else
  fail "zero-block sibling file was silently masked by a valid one in the same hook"
fi
rm -f "$MARKER" "$HOOKS_WORK/extensions/day-open.before.md" "$HOOKS_WORK/extensions/day-open.before.custom.md"

# 5i. A missing/unreadable extensions/ directory is a failure, not the same
# "no hooks" no-op as a legitimately empty one (Codex review, 2026-08-28,
# High: every install ships extensions/, so its absence means a broken
# install, and find's stderr was being discarded either way).
MISSING_EXT_ROOT=$(mktemp -d)
rmdir "$MISSING_EXT_ROOT"
IWE_ROOT="$MISSING_EXT_ROOT" bash "$HOOKS_RUNNER" before >/dev/null 2>&1
if [ "$?" -ne 0 ]; then
  pass "missing extensions/ directory fails, not treated as 'no hooks'"
else
  fail "missing extensions/ directory was silently treated as 'no hooks'"
fi

rm -rf "$HOOKS_WORK"
trap - EXIT

# --- 6. Workspace-root references: inventory only (ArchGate question 2) -------
echo "=== 6. \$IWE-root references (out of contract until ArchGate Q2) ==="
grep -o '\$IWE/scripts/[a-zA-Z0-9._/-]*' "$PIPELINE" | sort -u | sed 's/^/  ℹ️  /'

echo
echo "Result: $PASS_COUNT PASS, $FAIL_COUNT FAIL"
[ "$FAIL_COUNT" -eq 0 ] && exit 0 || exit 1
