---
agents: single
argument-hint: '[--skip-mcp] [--critical]'
browser_safe: false
description: Audit of a user IWE installation. Runs scripts/iwe-audit.sh + MCP healthcheck
  + ritual smoke-test via sentinel mechanics (dry-run-contract.md contract), passes
  the report to a subagent in the VR.R.002 Auditor role (context isolation) → verdict
  ✅/⚠️/❌ across 6 components (Inventory, L1 drift, {{GOVERNANCE_REPO}}, L3 customizations,
  MCP, ritual). Use after restore from Backup, after update.sh, or during weekly reconciliation.
gates_enforced: []
gates_rationale: operational skill; WP Gate applicable only when creating a new WP,
  not for operational invocations
gates_required: []
interaction: multi-step
layer: L1
name: audit-installation
routing:
  deterministic: false
  executor: haiku
status: active
triggers:
  phrases: []
  slash:
  - /audit-installation
version: 1.0.0
---

# IWE Installation Audit

> **Service Clause:** [VR.SC.005-installation-audit](https://github.com/{{GITHUB_USER}}/PACK-verification/blob/main/pack/verification/08-service-clauses/VR.SC.005-installation-audit.md)
> **Role:** VR.R.002 Auditor (PACK-verification) — subagent with context isolation
> **Principle:** the detector reports, the operator acts (see `scripts/iwe-drift.sh:7-11`). Auto-fix is not part of the promise.

Arguments: $ARGUMENTS

## When to use

Audit of a user IWE installation. Runs scripts/iwe-audit.sh + MCP healthcheck + ritual smoke-test via sentinel mechanics (dry-run-contract.md contract), passes the report to a subagent in the VR.R.002 Auditor role (context isolation) → verdict ✅/⚠️/❌ across 6 components (Inventory, L1 drift, {{GOVERNANCE_REPO}}, L3 customizations, MCP, ritual). Use after restore from Backup, after update.sh, or during weekly reconciliation.

## Promise

Within ≤5 minutes — a markdown report ✅/⚠️/❌ across 6 installation components:
1. **Inventory** — whether all critical L1 files (CLAUDE.md, skills, protocols) are present
2. **L1 drift** — divergences from IWE
3. **{{GOVERNANCE_REPO}}** — git status + diff against FMT-strategy-template
4. **L3 customizations** — extensions/, differences between params.yaml and the skeleton, AUTHOR-ONLY zones
5. **MCP healthcheck** — 4 tools respond (respecting subscription gating DP.SC.112)
6. **Ritual smoke-test** — `/run-protocol close day` runs under sentinel protection and reaches write steps (see `memory/dry-run-contract.md`)

The verdict is issued by a subagent in the Auditor role, reading the report **with no knowledge of the current session** (context isolation).

## Step 1. Deterministic checks (bash)

Locate and run `iwe-audit.sh` via the fallback chain (author-mode → workspace, user-mode → `$IWE_SCRIPTS` from `~/.iwe-paths`):

```bash
# issue #688: a non-interactive top-level Bash call doesn't go through
# .bashrc/.zshenv (interactive-shell guard) or BASH_ENV (read before the
# harness can set it) — $IWE_SCRIPTS is unset here on plenty of real
# installs even though ~/.iwe-paths exists and is correct. Source it
# directly, in this same shell, before reading the variable — `.` doesn't
# depend on interactive/BASH_ENV machinery at all.
# issue #932: the installer writes <workspace>/.iwe-paths (install-iwe-paths.sh);
# $HOME/.iwe-paths is the legacy location, tried last.
IWE_PATHS="${IWE_PATHS_FILE:-}"
if [ -z "$IWE_PATHS" ]; then
    for _c in "${IWE_WORKSPACE:-}/.iwe-paths" "${WORKSPACE_DIR:-}/.iwe-paths" \
              "$PWD/.iwe-paths" "${IWE_WORKSPACE:-$HOME/IWE}/.iwe-paths" "$HOME/.iwe-paths"; do
        [ -r "$_c" ] && { IWE_PATHS="$_c"; break; }
    done
fi
[ -n "$IWE_PATHS" ] && [ -r "$IWE_PATHS" ] && . "$IWE_PATHS"
if [ -n "${IWE_SCRIPTS:-}" ] && [ -f "$IWE_SCRIPTS/iwe-audit.sh" ]; then
    # $IWE_SCRIPTS first (#566): the hardcoded workspace copy, when it exists at
    # all, is a stale leftover — the installer points IWE_SCRIPTS at the template.
    AUDIT_SCRIPT="$IWE_SCRIPTS/iwe-audit.sh"
elif [ -f "${IWE_WORKSPACE:-$HOME/IWE}/scripts/iwe-audit.sh" ]; then
    AUDIT_SCRIPT="${IWE_WORKSPACE:-$HOME/IWE}/scripts/iwe-audit.sh"
else
    echo "iwe-audit.sh not found. \$IWE_PATHS ($IWE_PATHS) does not provide a working \$IWE_SCRIPTS — verify that the file exists and contains export IWE_SCRIPTS=... (run setup.sh from the FMT template if the file is missing)."
    exit 1
fi
bash "$AUDIT_SCRIPT" $([ "${ARGUMENTS:-}" = "--critical" ] && echo "--critical")
```

Save the output to the variable `bash_report`. Check the exit code:
- 0 → bash section ✅
- 1 → warnings (note, continue)
- 2 → critical gaps in bash checks (note, continue — the Auditor will assess together with MCP)

The script covers report sections 1–3 (Inventory, L1 drift, {{GOVERNANCE_REPO}}).

## Step 2. MCP healthcheck (unless `--skip-mcp`)

Call 4 MCP tools in parallel with minimal load and measure latency:

| Tool | Parameters | Level | What counts |
|------|------------|-------|-------------|
| `mcp__claude_ai_IWE__knowledge_search` | `query: "test"`, `limit: 1` | free | ✅ if response <15s |
| `mcp__claude_ai_IWE__github_status` | (no parameters) | free | ✅ if response |
| `mcp__claude_ai_IWE__personal_search` | `query: "ping"`, `limit: 1` | **subscription** | ✅ if response; **403/subscription_required → ⏸️** (do not count as failure) |
| `mcp__claude_ai_IWE__dt_read_digital_twin` | `path: "/"` | **subscription** | ✅ if response; **403/subscription_required → ⏸️** (do not count as failure) |

The digital twin is checked at the root `/`, not at a specific section: an unfilled metamodel category (for example `1_declarative`) returns `Path not found`, and a healthy installation was receiving a false ❌ (#932).

**Subscription gating (DP.SC.112).** `personal_*` and `dt_*` require an active subscription in `subscription_grants`. Without a subscription this is **not an installation failure** — it is an expected rejection. Mark as ⏸️ subscription_required, not ❌. Calculate coverage only across tools available to the user.

Build the markdown section `## 4. MCP healthcheck`:

```markdown
## Algorithm

## 4. MCP healthcheck

| Tool | Status | Latency | Note |
|------|--------|---------|------|
| personal_search | ✅/❌ | Nms | ... |
| knowledge_search | ✅/❌ | Nms | ... |
| github_status | ✅/❌ | Nms | ... |
| dt_read_digital_twin | ✅/❌ | Nms | ... |

Coverage: N/4
```

If `--skip-mcp` → section reads "⏸️ MCP healthcheck — skipped by flag".

## Step 2.5. Ritual smoke-test (sentinel + subagent)

> **Contract:** [memory/dry-run-contract.md](../../../memory/dry-run-contract.md). Protection via sentinel file + PreToolUse hook `dry-run-gate.sh`.

### Algorithm

1. **Create a rehearsal via begin-helper** (issue #549 stage 2 — exclusive creation under a transactional lock; token is printed once to stdout):
   ```bash
   bash "$IWE_SCRIPTS/dry-run-begin.sh" audit-installation "${CLAUDE_SESSION_ID:-}"
   ```
   The helper prints `gate_id=`, `owner_token=`, `owner_session_id=`. **Remember all three values from the tool-call output** — shell variables do not persist across your Bash calls (Codex r2), and the token must not be stored in a file (the rehearsal would read it). An active rehearsal owned by another session causes the helper to exit with an error showing its gate_id.
2. **Launch a subagent** via the Agent tool (subagent_type=general-purpose, Sonnet model) with this prompt:

   ```
   Run the ritual /run-protocol close day following the standard procedure. Do not improvise — follow SKILL.md as written.

   IMPORTANT: the sentinel /tmp/iwe-dry-run.flag is active in the current environment — this means dry-run mode.
   The PreToolUse hook dry-run-gate.sh will block any write tool (Write/Edit/git-write/MCP-write).
   This is expected — your task is to proceed as far as possible and record the step where you are blocked.

   After the run, report in the following format:
   ## Smoke-test /run-protocol close day
   - Steps completed: N of M
   - Blocked at: <step>: <tool>: <reason for block>
   - Read logic: ✅ works / ❌ failed before write step
   - Conclusion: ✅/⚠️/❌
   ```

3. **Wait for the subagent to finish.**
4. **Complete the rehearsal** (atomic active→completed transition with the capability token; the sentinel is removed by the helper itself after completed — the Stop hook is now only an idempotent fallback). Substitute the values remembered in step 1:
   ```bash
   bash "$IWE_SCRIPTS/dry-run-complete.sh" "<gate_id from step 1>" rehearsal-finished "<owner_session_id from step 1>" "<owner_token from step 1>"
   ```
5. **Build section 6 of the report:**
   ```markdown
   ## 6. Ritual smoke-test (/run-protocol close day)

   <subagent output>

   **Interpretation:**
   - Block at a write step after successful read steps → ✅ (read logic works; this is expected smoke-test behavior)
   - Block at step 1–2 → ❌ (ritual breaks early — source file missing or MCP failed)
   - All steps pass without a block → ⚠️ (suspicious — the ritual must have write steps)
   - Hook error → ❌ (infrastructure is broken)
   ```

### Protection against sticky sentinel

If the subagent crashes or hangs → attempt to delete the sentinel explicitly (always). The owner's Stop removes the capability file; another session's Stop does not affect the protection. The 10-minute TTL in the hook itself protects against cases where even this does not run (kill -9, CLI crash).

## Step 3. Assemble the unified report

```markdown
# IWE Installation Audit — YYYY-MM-DD HH:MM

[bash_report — sections 1–3]

[mcp_section — section 4]

---
[passed to the Auditor in step 4]
```

## Step 4. Launch a subagent in the Auditor role (VR.R.002)

Use the Agent tool with **context isolation** (subagent_type=general-purpose, Sonnet model):

**⛔ The subagent does NOT receive:**
- The history of the current session
- Knowledge of what the user was repairing or restoring
- Intermediate reasoning

**The subagent receives (prompt):**

```
You are performing the role of VR.R.002 Auditor (PACK-verification). Your task is to read the markdown report from the IWE installation audit and issue a verdict.

Reference:
- VR.SC.005 (Service Clause): the installation must have all critical L1 files, rituals must load, MCP must respond, {{GOVERNANCE_REPO}} must be a git repository.
- Gate criteria (from WP-265 §Gate criteria):
  - ✅ — 0 critical gaps, ≤2 warnings
  - ⚠️ — 1+ warning or ≥3 minor gaps; operational
  - ❌ — ≥1 critical: L1 broken (>5 files drift), ritual fails, MCP <2/4 respond

Context isolation principle (VR.SOTA.002): do not use knowledge of how the installation was created. Evaluate ONLY based on the report.

Report:
[insert full assembled report here]

Issue the verdict in the following format:

## Verdict: [✅ / ⚠️ / ❌]

**Component summary:**
- L1 (platform): ✅/⚠️/❌ — brief explanation
- Rituals: ✅/⚠️/❌ — ...
- MCP: ✅/⚠️/❌ — ...
- {{GOVERNANCE_REPO}}: ✅/⚠️/❌ — ...

**Critical gaps (if any):**
- [list with file/component references]

**Recommendations:**
- What to fix via `update.sh` (Synchronizer)
- What to fix manually (with a specific step)
- What to defer (non-critical)

Do not propose auto-fix. Do not go into implementation details. Your role is Auditor, not Coder.
```

## Step 5. Save the report and present it to the user

1. **Save the full report + verdict to a file:**
   ```bash
   # Priority (#566): $IWE_SCRIPTS convention first, hardcode only as fallback → $HOME/IWE
   if [ -d "${IWE_SCRIPTS:-$HOME/IWE/scripts}" ]; then
       AUDIT_LOG_DIR="${IWE_SCRIPTS:-$HOME/IWE/scripts}"
   else
       AUDIT_LOG_DIR="${IWE_WORKSPACE:-$HOME/IWE}"
   fi
   mkdir -p "$AUDIT_LOG_DIR"
   AUDIT_LOG="$AUDIT_LOG_DIR/iwe-audit-$(date +%Y%m%d-%H%M%S).log"
   # Write concatenation: full_report + verdict
   ```
2. **Present to the user:**
   - Full markdown report (sections 1–6)
   - Verdict from the Auditor
   - One-line summary: `Verdict: ⚠️ Operational with N caveats. Log: <AUDIT_LOG>`

The user decides what to fix.

## Limitations of the current implementation

- **Smoke-test covers one ritual** (`/run-protocol close day`). Extending to week-close / month-close is a mini work package — a copy of step 2.5 with different subcommands.
- **{{GOVERNANCE_REPO}} diff** — works only if `FMT-strategy-template/` (or `templates/strategy-skeleton/`) exists. If not, the section is marked "N/A".
- **MCP healthcheck** — depends on the currently available tools. If the set changes, update step 2.
- **Sentinel sticky state** — protection: 10-minute TTL in the hook + Stop-cleanup. Edge case: if the hook is modified and does not read the sentinel → no block occurs (fail-open). Protection: periodic re-testing via `/audit-installation` catches regressions.

<!-- USER-SPACE -->
<!-- /USER-SPACE -->
