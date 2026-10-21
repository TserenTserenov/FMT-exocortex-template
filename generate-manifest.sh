#!/bin/bash
# Generates update-manifest.json from the current repository contents.
# Run before release: bash generate-manifest.sh
#
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MANIFEST="$SCRIPT_DIR/update-manifest.json"

# Version from CHANGELOG.md (first ## [X.Y.Z])
VERSION=$(grep -m1 '^\#\# \[[0-9]' "$SCRIPT_DIR/CHANGELOG.md" | sed 's/.*\[\(.*\)\].*/\1/')

if [ -z "$VERSION" ]; then
    echo "ERROR: Could not extract version from CHANGELOG.md"
    exit 1
fi

echo "Generating manifest v$VERSION..."

# === Exclusions, that do NOT appear in either files or excluded_paths files, or in excluded_paths ===
SKIP_PATTERNS=(
    ".git/"
    ".github/"
    ".backups/"
    ".DS_Store"
    # generate-manifest.sh is DELIVERED since WP-529 F6 (Evgenii defect #4,
    # 18.08): the shipped scripts/verify-manifest.sh hard-depends on the
    # repo-root generator, so an update-only install kept a stale copy and
    # the B2 completeness check exited 1 on the user's machine.
    "update-manifest.json"
    "update-manifest.local.json"
    "seed/"
    "templates/"
)

# === Exclusions, that go into excluded_paths excluded_paths (dev-only, not delivered to users) ===
# issue #247 (root #246): previously a blanket entry was placed here "scripts/" — the entire directory
# was considered dev-only, and update.sh never delivered any of the 92 files 92 files
# to users, contrary to docs/DATA-POLICY.md. Full reference graph analysis
# (peer-session 2026-07-11-11) showed, that this was incorrect: most scripts
# are called from delivered skills/hooks (sometimes transitively — day-open-pipeline.sh
# is launched via launchd, and not directly from a skill skill, and this is not caught by grep grep-).
# Decision following EMOGSSB review: default = deliver scripts/ in full; explicit
# exclude only for scripts, that have NO references from any delivered
# artifact (verified — only .github/workflows/* or nothing). An error in this
# direction (an extra dev-script delivered) is harmless; the reverse (a required script not
# delivered) — reproduces #246. EXCLUDED_SCRIPTS below — a short list,
# not growing with every new skill (unlike the previous allow-list for *delivery*).
EXCLUDED_PATTERNS=(
    "scripts/tests/"
    "docs/developer/"    # never delivered since the first manifest commit (23b0494, WP-7 MFC4) —
                          # unrelated to the WP-401 Phase6.1 docs/ freeze below, keep excluded
    "sessions/2026-06/"    # WP-401 Phase6.1: archived transcript, not for delivery. NOTE: sessions/00-index.md
                            # stays OUT of this exclusion on purpose — it's a protected seed-once-then-never-
                            # touch file like memory/MEMORY.md (see is_protected_user_file() in update.sh),
                            # not a deprecated artifact. A future "sessions/YYYY-MM/" transcript must get its
                            # own dated exclusion here, not a blanket "sessions/".
)

EXCLUDED_SCRIPTS=(
    "scripts/check-component-parity.sh"        # CI-only: validate-template.yml + verify-template-integrity.sh
    "scripts/check-manifest-rename-coverage.py" # CI-only: validate-template.yml
    "scripts/verify-template-integrity.sh"      # local mirror CI-gate for template contributors, not for end users
    "scripts/translate.py"                      # CI-only: translate-sync.yml (synchronization EN-EN docs by template author)
    "scripts/delivery_checks.py"                # CI-only: translate-sync.yml
    "scripts/audit-ad-hoc-roles.py"             # no references from any delivered artifact
    "scripts/agent-dashboard.py"                # only scripts/tests/, no references from any delivered artifact
    "scripts/generate-helper-catalog.py"        # no references from any delivered artifact
    "scripts/iwe-trace.py"                      # no references from any delivered artifact
    "scripts/session-dispatcher-tsekh.py"       # no references from any delivered artifact
    "scripts/iwe-catalog-list.py"               # referenced only by docs/maintaining-skills.md (itself dev-only)
    "scripts/guide-kit-sync.sh"                 # author-only: imports the release of iwesys/guide-kit into the template tree (WP-483 Phase4)
)

EXCLUDED_EXACT=(
    "promotion-status.yaml"
    "scripts/guide-kit-sync-state.yaml"         # provenance vendored-copy guide-kit/ — needed by CI drift-check, not for end users
    "${EXCLUDED_SCRIPTS[@]}"
)

# === Exclusions from files, but not in excluded_paths (user space) ===
FILES_EXCLUDE_PATTERNS=(
    "seed/"
    ".claude/settings.local.json"
)

FILES_EXCLUDE_EXACT=(
    "README.md"
    "README.en.md"
    "CONTRIBUTING.md"
    "LICENSE"
    "CODE_OF_CONDUCT.md"
    "SECURITY.md"
    "PRIVACY.md"
    "CODEOWNERS"
    "CITATION.cff"
    ".gitattributes"
    "params.yaml"
    "params.yaml.example"
    "extensions/day-close.after.md"
    "extensions/mcp-user.json"
)

# issue #325: .github/ and setup/ are blanket-excluded below (CI-only / install-time),
# but cloud-scheduler is a documented, maintained feature living in both namespaces —
# its workflow and install script never reached users despite fix #188. Explicit
# per-file include, same technique as setup/validate-template.sh below.
GITHUB_EXPLICIT_INCLUDE=(
    ".github/workflows/cloud-scheduler.yml"
    ".github/workflows/notify-security.yml"
    ".github/workflows/notify-update.yml"
    ".github/workflows/post-release-audit.yml"
    # issue #1223: never shipped at all (not in files, not in excluded_paths),
    # so a fork's copy froze at whatever version it last had and stayed red
    # forever on checks that need files this manifest deliberately never
    # delivers (setup/integration-contract-validator.sh, scripts/tests/*).
    # Shipping it now delivers the issue #1223 repo-gate fix (jobs skip on
    # forks instead of failing) to existing forks, not just new ones.
    ".github/workflows/validate-template.yml"
)
GITHUB_CI_ONLY_EXCLUDE=(
    ".github/workflows/nightly-template-audit.yml"
)
SETUP_EXPLICIT_INCLUDE=(
    "setup/build-runtime.sh"
    "setup/install-iwe-paths.sh"
    "setup/validate-template.sh"
    "setup/optional/setup-cloud-scheduler.sh"   # install-time, but requires one-time delivery — issue #325
    "setup/optional/setup-local-gateway.sh"     # referenced by delivered docs/AGENT-VENDOR-SETUP.md (WP-499 Phase16), same class as #325
)
# issue #502/#508.2: seed/ is user-owned by default, but these files are
# platform delivery infrastructure. Existing installations need their target
# release bytes before update.sh can migrate hooks and the derived-snapshot
# updater into the governance repo. Routed via docs/critical-files-map.yaml
# category 'platform-hooks-explicit-include' — any future addition/removal
# here needs a matching `Delivery-Route: platform-hooks-explicit-include`
# trailer (scripts/check-delivery-route-label.sh, WP-529 Phase2).
PLATFORM_HOOKS_EXPLICIT_INCLUDE=(
    "seed/strategy/.githooks/pre-commit"
    "seed/strategy/.githooks/pre-push"
    "seed/strategy/scripts/install-hooks.sh"
    # WP-485 Phase14: portable isolate-push for template users (a∩g)
    "seed/strategy/scripts/isolate-push.sh"
    # issue #941: strategist.sh publishes through $governance/scripts/ds-publish.sh,
    # which the template never shipped; update.sh delivers it only when absent.
    "seed/strategy/scripts/ds-publish.sh"
    # #533: existing installations need the subject-scoped Day Open reader.
    "seed/strategy/scripts/day-open-llm-fill.py"
    "seed/strategy/scripts/update-derived-snapshot.py"
    "seed/strategy/scripts/generate-executor-catalog.py"
    # issue #693: full transitive call graph of day-open-pipeline.sh (the live
    # Day Open pipeline) — every entry below is `source`d or invoked by
    # day-open-pipeline.sh, day-open-scaffold.sh, or one of the two *-runner.sh
    # it calls. Missing any one of them reproduces the FATAL that
    # scripts/iwe-audit.sh §3b already warns about for lib/common.sh (a stale
    # or absent lib/ breaks the scaffold identically to an outdated one), but
    # the audit only ever checked 3 of these 22 files — this list is the
    # verified full closure, not a re-scoped subset.
    "seed/strategy/scripts/day-open-pipeline.sh"
    "seed/strategy/scripts/day-open-scaffold.sh"
    "seed/strategy/scripts/day-open-hooks-runner.sh"
    "seed/strategy/scripts/day-open-checks-runner.sh"
    "seed/strategy/scripts/day-open-bottleneck-patch.sh"
    "seed/strategy/scripts/day-open-budget-patch.py"
    "seed/strategy/scripts/day-open-close-error-patch.py"
    "seed/strategy/scripts/day-open-ledger-render-patch.py"
    "seed/strategy/scripts/day-open-multiplier-backfill-patch.py"
    "seed/strategy/scripts/day-open-priorities-patch.py"
    "seed/strategy/scripts/day-open-version-check-patch.py"
    "seed/strategy/scripts/ledger-append.sh"
    "seed/strategy/scripts/llm-proxy-launcher.sh"
    "seed/strategy/scripts/lib/common.sh"
    "seed/strategy/scripts/lib/day-open-hooks.sh"
    "seed/strategy/scripts/lib/find-python3.sh"
    "seed/strategy/scripts/lib/ledger-path.sh"
    "seed/strategy/scripts/lib/ledger-publish-kick.sh"
    "seed/strategy/scripts/lib/ledger_path.py"
    "seed/strategy/scripts/lib/network-wait.sh"
    "seed/strategy/scripts/lib/notification-render.sh"
    "seed/strategy/scripts/lib/telegram.sh"
    "seed/strategy/scripts/lib/wp_inbox.py"
    # issue #1102: extractor.sh looks for scripts/lib/publish-gate.sh since
    # WP-5 F48, but it never shipped -- every install silently fell back to
    # a raw `git push` with no retry on a stale origin/main.
    "seed/strategy/scripts/lib/publish-gate.sh"
)
# #533: unlike ordinary seed content, these are platform-owned delivery and
# upgrade infrastructure.  Keep each path explicit so the blanket seed/
# exclusion cannot silently remove the canonical privacy boundary or its four
# compatibility entrypoints from an update payload.
AGENT_FAULT_EXPLICIT_INCLUDE=(
    "scripts/agent-fault/iwe_checklist_memory.py"
    "seed/strategy/exocortex/agent-fault-profile/.gitignore"
    "seed/strategy/scripts/iwe_checklist_memory.py"
    "seed/strategy/scripts/sync_feedback_to_memory.py"
    "seed/strategy/scripts/agent_fault_remind.py"
    "seed/strategy/scripts/agent_fault_remind.sh"
)
# WP-7 Phase-script-contract-gate: EXCLUDED_PATTERNS below still blanket-excludes
# scripts/tests/ (correct default — it's mostly the author's own pytest suite,
# dev-only, same reasoning as issue #246/#247 above but scoped to this one
# directory instead of removed entirely). These paths are the exception —
# the verification gate itself, meant to ship so a user's own template copy
# can run it. Found live 03.08: without this list, generate-manifest.sh
# silently dropped all 11 back into excluded_paths on every real run, even
# though they'd been hand-added to files[] in an earlier commit — the next
# real release would have shipped a template without its own test gate and
# nobody would have noticed until a user hit the bug the gate exists to catch.
SCRIPT_CONTRACT_EXPLICIT_INCLUDE=(
    # Changes to this array require a `Delivery-Route: github-explicit-include`
    # commit trailer (docs/critical-files-map.yaml) — enforced by
    # scripts/check-delivery-route-label.sh in CI.
    # 2026-08-23 (v0.38.7 matrix, finding 4): check-python-resolver-contract.sh
    # is delivered, but its required baseline was sitting in excluded — on install
    # strictly from the manifest the guard failed with rc=2. Ratchet-snapshot — part of the delivery.
    "scripts/tests/fixtures/python-resolver-baseline.txt"
    "scripts/tests/test_issue_728_agentigore_dirslash.sh"
    "scripts/tests/test_issue_718_sync_canary.sh"
    "scripts/tests/test_issue_720_decision_log_sot.sh"
    "scripts/tests/test_create_wp_registry_coherence.sh"
    "scripts/tests/test_check_orphan_hooks.sh"
    "scripts/tests/test_capture_bus_detector_timeout.sh"
    "scripts/tests/test_critical_alert_disabled_tracker.sh"
    "scripts/tests/test_create_wp_contract.sh"
    "scripts/tests/test_capture_bus_contract.sh"
    "scripts/tests/test_critical_alert_contract.sh"
    "scripts/tests/test_create_wp_number_padding.py"
    "scripts/tests/test_create_wp_weekplan_writer.py"
    "scripts/tests/validate_manifest_coverage.sh"
    "scripts/tests/lib/capture_fixture.sh"
    "scripts/tests/lib/seed_strategy_fixture.sh"
    "scripts/tests/test_critical_alert_failure_matrix.sh"
    "scripts/tests/test_create_wp_repeat_and_cwd.sh"
    "scripts/tests/test_create_wp_hypothesis_relation.sh"
    # issue #956: run-issue-tests.sh (delivered) names both in ADDITIONAL_ISSUE_TESTS,
    # and a registered test file that is missing fails the runner on an installed copy.
    "scripts/tests/test_create_wp_verification_class.sh"
    "scripts/tests/test_create_wp_artifactor_gate.sh"
    "scripts/tests/test_day_close_lock_timezone.sh"
    "scripts/tests/test_fresh_seed_reproduction.sh"
    "scripts/tests/test_generate_manifest_registers_setup_exclusions.sh"
    "scripts/tests/test_hook_classification.sh"
    "scripts/tests/test_install_hooks.py"
    "scripts/tests/test_update_install_path_guard.sh"
    "scripts/tests/test_update_install_path_guard_provenance.sh"
    "scripts/tests/test_update_deprecated_mirror_guard.sh"
    "scripts/tests/test_update_settings_merge_drift.sh"
    "scripts/tests/test_update_delivery_ref.sh"
    "scripts/tests/test_upgrade_worktree_cleanup.sh"
    "scripts/tests/test_issues_413_418.py"
    "scripts/tests/test_hindsight_docs_contract.sh"
    "scripts/tests/test_launchd_identity_runtime.sh"
    "scripts/tests/test_session_guard_hypothesis_gate.sh"
    # WP-529 F6 (Evgenii 18.08): the whole test_issue_* family plus its runner
    # ship with the template — a user's copy must be able to run its own
    # issue-regression gate (same rationale as the 03.08 block above).
    "scripts/tests/run-issue-tests.sh"
    "scripts/tests/test_issue_1032_strategy_session_offline.sh"
    "scripts/tests/test_issue_1032_windows_fail_closed.sh"
    "scripts/tests/test_issue_434_pipeline_scaffold_only.sh"
    "scripts/tests/test_issue_453_calendar_private_visibility.sh"
    "scripts/tests/test_issue_455_scaffold_missing_lib_fatal.sh"
    "scripts/tests/test_issue_463_pyyaml_explicit_diagnostics.sh"
    "scripts/tests/test_issue_463_setup_reuses_resolved_python3.sh"
    "scripts/tests/test_issue_469_settings_merge_hook_identity.py"
    "scripts/tests/test_issue_471_drift_scan_status_boundary.py"
    "scripts/tests/test_issue_473_build_active_wp_columns.py"
    "scripts/tests/test_issue_473_wp_sync_bundle_status.sh"
    "scripts/tests/test_issue_511_day_close_commit_guard.sh"
    # #533/#536: ship the installed-delivery and crash-recovery regressions.
    "scripts/tests/test_issue_533_agent_fault_delivery.py"
    "scripts/tests/test_issue_536_day_close_backup.sh"
    "scripts/tests/test_issue_calendar_api_error_named.sh"
    "scripts/tests/test_update_build_runtime_fail_closed.sh"
    "scripts/tests/test_update_delivers_python_resolver_before_roles.sh"
    "scripts/tests/test_role_runner_update_marker_guard.sh"
    # issue #557 (30.08): zsh regression for the day-close commit guard —
    # runs in CI via run-issue-tests.sh, must ship with the template like its
    # bash sibling above.
    "scripts/tests/test_issue_557_zsh_special_vars.sh"
    # WP-7 Phase216 (11.10): phase-1 gate issue #1114 (cp1251) and regressions #1147
    # are delivered, like the entire family test_issue_*; baseline — required
    # ratchet-file of the delivered check-python-encoding.py (same reason, as
    # python-resolver-baseline.txt above: without it the gate fails on install).
    "scripts/tests/cp1251-smoke.sh"
    "scripts/tests/python-encoding-baseline.txt"
    "scripts/tests/test_issue_1114_encoding_gate.sh"
    "scripts/tests/test_issue_1147_memory_migrate.sh"
)

is_explicit_include() {
    local rel="$1"; shift
    local item
    for item in "$@"; do
        [ "$rel" = "$item" ] && return 0
    done
    return 1
}

# Collecting files.
FILES=()
EXCLUDED_PATHS=()
while IFS= read -r rel; do
    # Skipping junk/tooling
    if is_explicit_include "$rel" \
        "${GITHUB_EXPLICIT_INCLUDE[@]}" \
        "${SCRIPT_CONTRACT_EXPLICIT_INCLUDE[@]}" \
        "${PLATFORM_HOOKS_EXPLICIT_INCLUDE[@]}" \
        "${AGENT_FAULT_EXPLICIT_INCLUDE[@]}"; then
        FILES+=("$rel")
        continue
    fi
    # .github/ is normally outside the delivery manifest.  Keep every tracked
    # workflow explicitly classified, otherwise manifest-coverage correctly
    # reports a silent delivery gap (#423).
    if is_explicit_include "$rel" "${GITHUB_CI_ONLY_EXCLUDE[@]}"; then
        EXCLUDED_PATHS+=("$rel")
        continue
    fi
    skip=false
    for pattern in "${SKIP_PATTERNS[@]}"; do
        case "$rel" in
            $pattern*) skip=true; break ;;
        esac
    done
    [[ "$(basename "$rel")" == ".gitkeep" ]] && skip=true
    $skip && continue

    # setup/ contains install-time scripts; skip all except explicit includes
    # (validate-template.sh referenced by .githooks/pre-commit and update.sh
    # after delivery; setup-cloud-scheduler.sh — see SETUP_EXPLICIT_INCLUDE above).
    # Register in EXCLUDED_PATHS same as .github/ above (#423) — Evgenii's
    # Red Team review 2026-08-19 found setup/test-delivery-route-label.sh
    # (and every other setup/test-*.sh) as a silent manifest-coverage gap:
    # this branch's bare `continue` never recorded WHY the file was skipped,
    # so check-manifest-coverage.py had no way to distinguish it from a
    # forgotten delivery.
    if [[ "$rel" == setup/* ]] && ! is_explicit_include "$rel" "${SETUP_EXPLICIT_INCLUDE[@]}"; then
        EXCLUDED_PATHS+=("$rel")
        continue
    fi

    # Checking excluded_paths (dev-only)
    is_excluded=false
    for pattern in "${EXCLUDED_PATTERNS[@]}"; do
        case "$rel" in
            $pattern*) is_excluded=true; break ;;
        esac
    done
    for exact in "${EXCLUDED_EXACT[@]}"; do
        [ "$rel" = "$exact" ] && { is_excluded=true; break; }
    done

    if $is_excluded; then
        EXCLUDED_PATHS+=("$rel")
        continue
    fi

    # Checking files-exclusions (user space)
    is_files_exclude=false
    for pattern in "${FILES_EXCLUDE_PATTERNS[@]}"; do
        case "$rel" in
            $pattern*) is_files_exclude=true; break ;;
        esac
    done
    for exact in "${FILES_EXCLUDE_EXACT[@]}"; do
        [ "$rel" = "$exact" ] && { is_files_exclude=true; break; }
    done

    $is_files_exclude && continue
    FILES+=("$rel")
# LC_ALL=C pins byte-order collation so the manifest is reproducible across
# contributor locales (CI sorts under C.UTF-8). Without it, a UTF-8 locale
# reorders entries like README.md / sync_feedback_to_memory.py and breaks the
# manifest-completeness check (issue #207).
done < <(git -C "$SCRIPT_DIR" ls-files | LC_ALL=C sort)

# Reading existing manifest for deprecated_files (manual management)
DEPRECATED_JSON="[]"
if [ -f "$MANIFEST" ]; then
    DEPRECATED_JSON=$(python3 -c "
import json
with open('$MANIFEST') as f:
    data = json.load(f)
print(json.dumps(data.get('deprecated_files', []), ensure_ascii=False))
")
fi

TMPDIR=$(mktemp -d)
# Via printf: line-by-line writing without bash-array-interpolation inside the string
printf '%s\n' "${FILES[@]}" > "$TMPDIR/files.txt"
printf '%s\n' "${EXCLUDED_PATHS[@]}" > "$TMPDIR/excluded.txt"

# Generating JSON
python3 -c "
import hashlib
import json
from pathlib import Path

files = [line.strip() for line in open('$TMPDIR/files.txt') if line.strip()]
excluded = [line.strip() for line in open('$TMPDIR/excluded.txt') if line.strip()]
root = Path('$SCRIPT_DIR')

def manifest_entry(path):
    digest = hashlib.sha256((root / path).read_bytes()).hexdigest()
    return {'path': path, 'sha256': digest}

data = {
    'schema_version': 2,
    'version': '$VERSION',
    'description': 'Manifest of platform files IWE. Used by update.sh for delivering updates.',
    'files': [manifest_entry(p) for p in files],
    'excluded_paths': excluded,
    'deprecated_files': json.loads('''$DEPRECATED_JSON'''),
}

# 2026-08-22 (external report): deprecated_files is hand-managed and carried
# over from the previous manifest — a path that came BACK into the delivered
# tree stayed listed as deprecated, and update.sh deleted 10 files HEAD still
# ships. A path cannot be delivered and deprecated at once: delivery wins,
# the stale deprecation entry is dropped with a warning.
import subprocess
import sys
delivered_now = {e['path'] for e in data['files']}
# Same class, wider net (the live 10-file incident): a path still TRACKED in
# git HEAD ships with every fresh clone — deprecating it makes update.sh
# delete what the canon still distributes, leaving clones with tracked
# deletions. Deprecated may only list paths git no longer carries.
# 2026-08-22 (Codex peer-review): git ls-files without checking the return code —
# on failure git tracked_now silently became empty, and the filter «deprecated ∩
# tree» degraded fail-open. Failure of git = generation failure (fail-closed).
_ls = subprocess.run(
    ['git', 'ls-files'], capture_output=True, text=True, cwd='$SCRIPT_DIR'
)
if _ls.returncode != 0:
    sys.exit('generate-manifest: git ls-files failed: ' + _ls.stderr.strip())
tracked_now = set(_ls.stdout.splitlines())
# WP-7 Phase92: a files[] to excluded_paths[] move needs a deprecated_files entry
# too (already-installed pilots got the file while it was still delivered),
# but bare tracked_now above would auto-purge that entry right back out.
# excluded_confirmed=true on the entry itself (not a code-side list) marks
# a deliberate transition, keeping the 22.08 protection for every other
# tracked-but-unmarked path.
excluded_now = set(excluded)
kept, dropped = [], []
for entry in data['deprecated_files']:
    path = entry.get('path')
    confirmed_excluded_transition = entry.get('excluded_confirmed') and path in excluded_now
    (kept if confirmed_excluded_transition or (path not in delivered_now and path not in tracked_now)
     else dropped).append(entry)
for entry in dropped:
    print('  ⚠ deprecated_files: %s back in the distribution — entry removed from deprecated' % entry.get('path'), file=sys.stderr)
data['deprecated_files'] = kept

# Remove empty arrays
if not data['excluded_paths']:
    del data['excluded_paths']
if not data['deprecated_files']:
    del data['deprecated_files']

with open('$MANIFEST', 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write('\n')
"

rm -rf "$TMPDIR"

echo "Done: $MANIFEST"
echo "  Version: $VERSION"
echo "  Files: ${#FILES[@]}"
echo "  Excluded (excluded_paths): ${#EXCLUDED_PATHS[@]}"
echo ""
echo "Review diff and commit:"
echo "  git diff update-manifest.json"
