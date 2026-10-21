#!/bin/bash
# claude-hook: false — library-dispatcher for event-specific wrappers and tests
# rule-engine.sh — unified agent rules dispatcher (WP-272 Phase1)
#
# Inputs (env vars):
#   RULE_EVENT — trigger event (task_received, wp_create_attempt, response_emitted, ...)
#   RULE_CONTEXT — JSON-event context (response, file_path, command, ...)
#
# Output (stdout JSON):
#   {"verdict": "block|warn|ok", "rule_id": "AR.NNN", "reason": "...", "applied_rules": [...]}
#
# Usage (as hook): event-specific wrappers source source this file and call
# dispatch_event. Direct invocation is also available — for tests.
#
# CLI exit codes: dispatch/list-rules/session-summary/session-clear/test — 0.
# check-trace-satisfaction|list-gates|mark-gate — 3 (NOT_IMPLEMENTED, issue #678:
# protocol-close.md references them, the mechanism is not yet implemented). Unknown
# subcommand — 1 (usage).
#
# REGISTRY: ~/IWE/.claude/rules-registry.yaml (generated from PACK-agent-rules/)

set -uo pipefail
umask 077

REGISTRY="${RULE_REGISTRY:-$HOME/IWE/.claude/rules-registry.yaml}"
JOURNAL_DIR="${RULE_JOURNAL_DIR:-$HOME/logs/rule-engine}"
mkdir -p "$JOURNAL_DIR"
JOURNAL_FILE="$JOURNAL_DIR/$(date +%Y-%m-%d).jsonl"

# Session-state: per-session warn/block log (WP-272 Phase5)
SESSION_ID="${CLAUDE_SESSION_ID:-default}"
SESSION_STATE_DIR="$HOME/.claude/state"
mkdir -p "$SESSION_STATE_DIR" 2>/dev/null || true
SESSION_WARN_LOG="$SESSION_STATE_DIR/session-${SESSION_ID}-warns.jsonl"

# === Utilities ===

log_journal() {
    local rule_id="$1" verdict="$2" reason="$3"
    local ctx="${RULE_CONTEXT:-{\}}"
    [ -z "$ctx" ] && ctx='{}'
    # SQL files may contain real user data or credentials in data migrations.
    # Keep only non-content evidence; never create a second raw copy in logs.
    if [ "${RULE_EVENT:-}" = "sql_file_write" ]; then
        ctx=$(printf '%s' "$ctx" | python3 -c '
import hashlib
import json
import sys

try:
    raw = json.load(sys.stdin)
    content = str(raw.get("file_content", ""))
    command = str(raw.get("command", ""))
    print(json.dumps({
        "file_path": raw.get("file_path", ""),
        "file_content_length": len(content),
        "file_content_sha256": hashlib.sha256(content.encode()).hexdigest(),
        "command_length": len(command),
        "content_redacted": True,
    }))
except Exception:
    print(json.dumps({"content_redacted": True, "context_parse_error": True}))
' 2>/dev/null) || ctx='{"content_redacted":true,"context_parse_error":true}'
    fi
    # WP-272 Phase1 fix (R23 audit #4): ensure_ascii=False for readability in logs
    printf '{"ts":"%s","event":"%s","rule":"%s","verdict":"%s","reason":%s,"context":%s}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "${RULE_EVENT:-unknown}" \
        "$rule_id" \
        "$verdict" \
        "$(printf '%s' "$reason" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read(), ensure_ascii=False))')" \
        "$ctx" \
        >> "$JOURNAL_FILE"
}

emit_verdict() {
    local verdict="$1" rule_id="$2" reason="$3"
    log_journal "$rule_id" "$verdict" "$reason"
    # Session-state: save warn/block in per-session log for summary at Close (WP-272 Phase5)
    if [ "$verdict" = "warn" ] || [ "$verdict" = "block" ]; then
        printf '{"ts":"%s","event":"%s","rule":"%s","verdict":"%s","reason":%s}\n' \
            "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            "${RULE_EVENT:-unknown}" \
            "$rule_id" \
            "$verdict" \
            "$(printf '%s' "$reason" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read(), ensure_ascii=False))')" \
            >> "$SESSION_WARN_LOG" 2>/dev/null || true
    fi
    printf '{"verdict":"%s","rule_id":"%s","reason":%s}\n' \
        "$verdict" \
        "$rule_id" \
        "$(printf '%s' "$reason" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read(), ensure_ascii=False))')"
}

# === Registry loading ===
# Parsing YAML via python (yaml stdlib is not available in bash)
load_rules_for_event() {
    local event="$1"
    if [ ! -f "$REGISTRY" ]; then
        echo "[]"
        return
    fi
    # WP-529 (continuation, 19.08): resolved here, inside the existing REGISTRY
    # existence check — same lazy-placement rationale as the other sites in
    # this migration (peer-session 2026-08-19-29, codex turn 1). No
    # bare-python3 fallback: the resolver's own first candidate is already
    # bare `python3` from PATH.
    local _resolved_python3
    _resolved_python3=$("${IWE_SCRIPTS:-$HOME/IWE/scripts}/lib/find-python3.sh" 2>/dev/null) || _resolved_python3=""
    [ -n "$_resolved_python3" ] || { echo "[]"; return; }
    _LRE_EVENT="$event" _LRE_REG="$REGISTRY" "$_resolved_python3" - << 'PYEOF' 2>/dev/null || echo "[]"
import yaml, json, os
with open(os.environ['_LRE_REG']) as f:
    reg = yaml.safe_load(f)
event = os.environ['_LRE_EVENT']
matches = [r for r in reg.get('rules', []) if event in r.get('triggers', []) and r.get('status') == 'active']
matches.sort(key=lambda r: r['priority'])
print(json.dumps(matches))
PYEOF
}

# === Check-functions for specific rules ===
# Each rule AR.NNN has its own check_<name>. Called by the dispatcher.

check_wp_gate() {
    # AR.001: check, whether user consent exists for a new WP
    # RULE_CONTEXT may contain {"file_path": "inbox/WP-NNN-*.md", "wp_number": N, "user_consent": bool}
    local ctx="${RULE_CONTEXT:-}"
    [ -z "$ctx" ] && ctx='{}'
    local consent
    # WP-272 Phase1 fix (R23 audit #1): try/except — invalid JSON must not crash traceback
    consent=$(echo "$ctx" | python3 -c '
import sys, json
try:
    d = json.loads(sys.stdin.read() or "{}")
    print(str(d.get("user_consent", False)).lower())
except (json.JSONDecodeError, ValueError):
    print("parse_error")
' 2>/dev/null)
    if [ "$consent" = "parse_error" ]; then
        emit_verdict "warn" "AR.001" "RULE_CONTEXT could not be parsed as JSON — fail-safe block; check the calling code"
    elif [ "$consent" = "true" ]; then
        emit_verdict "ok" "AR.001" "user consent confirmed in dialog"
    else
        emit_verdict "block" "AR.001" "WP Gate Ritual is not closed: no explicit user consent for creating a new WP"
    fi
}

check_autonomy() {
    # AR.002: check, whether the agent response contains yes/no confirmation request
    # RULE_CONTEXT: {"response_text": "..."}
    local resp
    resp=$(echo "${RULE_CONTEXT:-}" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("response_text", ""))' 2>/dev/null)

    # Simple regex-check (Phase1). In Phase2 will be replaced with Haiku R23 classifier.
    # First we check choice-question (exception) — before yes/no
    if echo "$resp" | grep -qE 'or\s+[A-Ya-yaA-Za-z0-9]+\?'; then
        emit_verdict "ok" "AR.002" "exception: choice_question detected"
        return
    fi

    # Yes/no confirmation request
    if echo "$resp" | grep -qE 'OK\?|apply\?|continue\?|save\?|do you want\?|add\?|confirm|Confirming'; then
        emit_verdict "warn" "AR.002" "yes/no confirmation request detected — check exceptions (wp_gate_ritual, choice_question, quoted_question_in_analysis)"
    else
        emit_verdict "ok" "AR.002" "no permission requests detected"
    fi
}

check_arch_gate() {
    # AR.003: architectural decision → /archgate BEFORE finalization
    local ctx="${RULE_CONTEXT:-}"
    [ -z "$ctx" ] && ctx='{}'
    local file_path
    file_path=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("file_path",""))' 2>/dev/null)

    # Creating a new Pack → ArchGate is required
    if echo "$file_path" | grep -qE '/PACK-[^/]+/(00-pack-manifest|pack-manifest)'; then
        emit_verdict "warn" "AR.003" "creating a new Pack — ArchGate is required BEFORE starting (CLAUDE.md §5). Run /archgate → EMOGSSB profile"
        return
    fi
    # new_system_creation (large system) → ArchGate is required
    local event="${RULE_EVENT:-}"
    if [[ "$event" == "new_system_creation" ]]; then
        local archgate_done
        archgate_done=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(str(d.get("archgate_done",False)).lower())' 2>/dev/null)
        if [ "$archgate_done" != "true" ]; then
            emit_verdict "warn" "AR.003" "creating a new system without /archgate — run /archgate BEFORE implementation (CLAUDE.md §5, DP.ARCH.001 §7)"
            return
        fi
    fi
    # new_tool_creation — IntegrationGate (AR.013) is sufficient, ArchGate only if the architecture is complex
    # arch_decision_attempt — always check
    if [[ "$event" == "arch_decision_attempt" ]]; then
        emit_verdict "warn" "AR.003" "architectural decision — /archgate BEFORE finalizing (CLAUDE.md §5)"
        return
    fi
    emit_verdict "ok" "AR.003" "arch gate N/A for this event (${event})"
}

check_push() {
    # AR.004: «push it»/«push» → commit + push without additional. questions
    # Post-condition check (WP-295 Phase5): emits push-state JSON for journal
    emit_verdict "ok" "AR.004" "push trigger — proceed: commit + push without confirmation"
    _check_pushed
}

_safe_timeout() {
    # portable timeout: gtimeout (homebrew coreutils) > timeout (GNU) > perl alarm
    local t="$1"; shift
    if command -v gtimeout &>/dev/null; then
        gtimeout "$t" "$@"
    elif command -v timeout &>/dev/null; then
        timeout "$t" "$@"
    else
        perl -e "alarm $t; exec @ARGV" -- "$@"
    fi
}

_check_repo_clean() {
    # WP-295 Phase5: ${IWE_GOVERNANCE_REPO:-DS-strategy} has no uncommitted changes at Close time.
    # Does NOT verify a commit was made this session; scope limited to ${IWE_GOVERNANCE_REPO:-DS-strategy}
    # (home-repo excluded: always has in-progress work from other agents → warn-fatigue).
    local repo_dir="${RULE_REPO_DIR:-$HOME/IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}}"
    local status
    if ! status=$(_safe_timeout 5 git -C "$repo_dir" status --porcelain 2>/dev/null); then
        printf '{"check":"repo_clean","result":"warn","detail":"git status timed out or failed in %s"}\n' "$repo_dir"
        return
    fi
    if [ -z "$status" ]; then
        printf '{"check":"repo_clean","result":"ok","detail":"no uncommitted changes in %s"}\n' "$repo_dir"
    else
        printf '{"check":"repo_clean","result":"warn","detail":"uncommitted changes in %s — commit before closing"}\n' "$repo_dir"
    fi
}

_check_orz_filled() {
    # WP-295 Phase5: ORZ session file for today exists and has a non-empty # Key Insight section.
    local today month repo_dir sessions_dir orz_file
    today=$(date +%Y-%m-%d)
    month=$(date +%Y-%m)
    repo_dir="${RULE_REPO_DIR:-$HOME/IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}}"
    sessions_dir="${repo_dir}/sessions/${month}"
    orz_file=$(find "$sessions_dir" -maxdepth 1 -type f -name "${today}-*.md" 2>/dev/null | head -1)
    if [ -z "$orz_file" ]; then
        printf '{"check":"orz_filled","result":"warn","detail":"no ORZ session file found for %s in %s"}\n' "$today" "$sessions_dir"
        return
    fi
    if LC_ALL=en_US.UTF-8 awk '/^#{1,2} Key Insight/{found=1; next} found && /[^[:space:]]/{print; exit}' "$orz_file" | grep -q .; then
        printf '{"check":"orz_filled","result":"ok","detail":"%s"}\n' "$orz_file"
    else
        printf '{"check":"orz_filled","result":"warn","detail":"ORZ file exists but # Key Insight section is empty: %s"}\n' "$orz_file"
    fi
}

_check_pushed() {
    # WP-295 Phase5: verifies ${IWE_GOVERNANCE_REPO:-DS-strategy} has no unpushed commits (all commits reached the remote).
    local repo_dir="${RULE_REPO_DIR:-$HOME/IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}}"
    local unpushed
    if ! unpushed=$(_safe_timeout 5 git -C "$repo_dir" log '@{u}..' --oneline 2>/dev/null); then
        printf '{"check":"pushed","result":"warn","detail":"could not determine push status in %s (no upstream or timeout)"}\n' "$repo_dir"
        return
    fi
    if [ -z "$unpushed" ]; then
        printf '{"check":"pushed","result":"ok","detail":"no unpushed commits in %s"}\n' "$repo_dir"
    else
        local count
        count=$(printf '%s' "$unpushed" | wc -l | tr -d ' ')
        printf '{"check":"pushed","result":"warn","detail":"%s unpushed commit(s) in %s"}\n' "$count" "$repo_dir"
    fi
}

_run_postconditions_for_close() {
    # WP-295 Phase5: deterministic post-condition checks on Close event (on_fail: warn).
    local rc_result rc_verdict orz_result orz_verdict

    rc_result=$(_check_repo_clean)
    rc_verdict=$(echo "$rc_result" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read())["result"])' 2>/dev/null)

    orz_result=$(_check_orz_filled)
    orz_verdict=$(echo "$orz_result" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read())["result"])' 2>/dev/null)

    if [ "$rc_verdict" = "warn" ]; then
        echo "$rc_result"; return
    fi
    if [ "$orz_verdict" = "warn" ]; then
        echo "$orz_result"; return
    fi
    printf '{"check":"postconditions","result":"ok","detail":"repo_clean ok, orz_filled ok"}\n'
}

check_close() {
    # AR.005: Close-trigger → close protocol
    local ctx="${RULE_CONTEXT:-}"
    [ -z "$ctx" ] && ctx='{}'
    local has_changes
    has_changes=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(str(d.get("has_uncommitted_changes",False)).lower())' 2>/dev/null)
    if [ "$has_changes" = "true" ]; then
        emit_verdict "warn" "AR.005" "Close-trigger with uncommitted changes — run /run-protocol close (CLAUDE.md §2 item.3)"
        return
    fi

    # WP-295 Phase5: post-condition checks (deterministic, on_fail: warn)
    local pc_result pc_verdict pc_detail
    pc_result=$(_run_postconditions_for_close)
    pc_verdict=$(echo "$pc_result" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read())["result"])' 2>/dev/null)
    if [ "$pc_verdict" = "warn" ]; then
        pc_detail=$(echo "$pc_result" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read())["detail"])' 2>/dev/null)
        emit_verdict "warn" "AR.005" "Close post-condition: $pc_detail"
        return
    fi

    emit_verdict "ok" "AR.005" "Close-trigger — run /run-protocol close"
}

check_pull_on_touch() {
    # AR.006: first repo modification → git pull --rebase
    local ctx="${RULE_CONTEXT:-}"
    [ -z "$ctx" ] && ctx='{}'
    local repo pull_done
    repo=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("repo",""))' 2>/dev/null)
    pull_done=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(str(d.get("pull_done",False)).lower())' 2>/dev/null)
    if [ "$pull_done" = "true" ]; then
        emit_verdict "ok" "AR.006" "git pull --rebase already executed for $repo"
    else
        emit_verdict "warn" "AR.006" "first modification in repo ${repo:-?} — run git pull --rebase BEFORE commit (CLAUDE.md §2 item.4)"
    fi
}

check_checklist_verification() {
    # AR.007: Quick Close / Day Close → sub-agent Haiku R23 (if session ≥15 min and file changes exist)
    local ctx="${RULE_CONTEXT:-}"
    [ -z "$ctx" ] && ctx='{}'
    local verification_done files_changed
    verification_done=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(str(d.get("r23_verification_done",False)).lower())' 2>/dev/null)
    files_changed=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(str(d.get("files_changed",True)).lower())' 2>/dev/null)
    if [ "$files_changed" = "false" ]; then
        emit_verdict "ok" "AR.007" "no file changes — R23 R23 verification is not required"
        return
    fi
    if [ "$verification_done" = "true" ]; then
        emit_verdict "ok" "AR.007" "R23 verification passed"
    else
        emit_verdict "warn" "AR.007" "Close-attempt without R23 verification — run sub-agent Haiku R23 (context isolation) BEFORE the close report (CLAUDE.md §2 item.5)"
    fi
}

# === AR.012-014, AR.101-106, AR.200-202: check-functions (WP-272 Phase5.4) ===

check_priority_gate() {
    # AR.012: WP with budget ≥ 3h → must have an explicit R{N}
    local ctx="${RULE_CONTEXT:-}"
    [ -z "$ctx" ] && ctx='{}'
    local budget r_goal
    budget=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("budget_h",0))' 2>/dev/null)
    r_goal=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("r_goal",""))' 2>/dev/null)
    local verification_class
    verification_class=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("verification_class",""))' 2>/dev/null)

    # open-loop always requires R{N}
    local needs_r=false
    if python3 -c "import sys; exit(0 if float('$budget') >= 3 else 1)" 2>/dev/null; then
        needs_r=true
    fi
    [ "$verification_class" = "open-loop" ] && needs_r=true

    if $needs_r; then
        if [ -z "$r_goal" ] || ! echo "$r_goal" | grep -qE 'R[0-9]+'; then
            emit_verdict "warn" "AR.012" "WP with budget=${budget}h (or open-loop) without an explicit R{N} — which weekly result does it lead to? Add field r_goal: R{N} in frontmatter (CLAUDE.md §2 Priority Gate)"
            return
        fi
    fi
    emit_verdict "ok" "AR.012" "priority gate OK (budget=${budget}h r_goal=${r_goal})"
}

_classify_integration_phase() {
    # Sub-agent-phase classifier IntegrationGate (AR.013).
    # Accepts JSON-context as $1; returns JSON via integration-gate-classifier.py.
    local classifier="$HOME/IWE/.claude/scripts/integration-gate-classifier.py"
    if [ ! -f "$classifier" ]; then
        # issue #895: this file was read as "almost-working machinery" — the
        # dangling dependency degraded silently (phase:unknown) with nothing
        # marking it as expected. Per #310 the machine classifier for AR.013
        # is intentionally not built yet (the gate itself is "🧠 cognitive:
        # no machine detector", rule-engine.sh is claude-hook:false, a
        # library for future event wrappers) -- this is a known stub, not a
        # broken install. State that once per invocation instead of staying
        # quiet; still degrades the same way (phase:unknown).
        echo "rule-engine.sh: integration-gate-classifier.py is not shipped (known stub, see #310/#895) — IntegrationGate phase classification degrades to 'unknown'" >&2
        echo '{"phase":"unknown","skip_detected":false,"reason":"classifier script missing (known stub, #310/#895)","missing":[]}'
        return
    fi
    local ctx_arg="${1:-{}}"
    _IG_CTX="$ctx_arg" python3 "$classifier" 2>/dev/null || echo '{"phase":"unknown","skip_detected":false,"reason":"classifier error","missing":[]}'
}

check_integration_gate() {
    # AR.013: creation of a new tool/agent/system → promise → scenarios → role → implementation.
    # Uses _classify_integration_phase() — subagent-phase classifier (heuristic without LLM).
    local ctx="${RULE_CONTEXT:-}"
    [ -z "$ctx" ] && ctx='{}'

    local creation_type file_path
    creation_type=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("creation_type",""))' 2>/dev/null)
    file_path=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("file_path",""))' 2>/dev/null)

    # Fast path: file_path — SC-artifact (08-service-clauses) → correct phase, no warn
    if echo "$file_path" | grep -qE '08-service-clauses|DP\.SC\.[0-9]+'; then
        emit_verdict "ok" "AR.013" "IntegrationGate: file = SC-artifact (promise-phase) — sequence is satisfied"
        return
    fi
    # Fast path: file_path — Role-artifact (02-domain-entities/DP.ROLE) → correct phase
    if echo "$file_path" | grep -qE 'DP\.ROLE\.[0-9]+'; then
        emit_verdict "ok" "AR.013" "IntegrationGate: file = Role-artifact (role-phase) — sequence is satisfied"
        return
    fi

    # Running the phase classifier
    local phase_result
    phase_result=$(_classify_integration_phase "$ctx")

    local skip_detected missing_str
    skip_detected=$(echo "$phase_result" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(str(d.get("skip_detected",False)).lower())' 2>/dev/null)
    missing_str=$(echo "$phase_result" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(", ".join(d.get("missing",[])))' 2>/dev/null)

    local phase
    phase=$(echo "$phase_result" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("phase","unknown"))' 2>/dev/null)

    # The classifier determined the phase explicitly (not unknown) — trusting its decision
    if [ "$phase" != "unknown" ]; then
        if [ "$skip_detected" = "true" ] && [ -n "$missing_str" ]; then
            emit_verdict "warn" "AR.013" "IntegrationGate: creation of a new ${creation_type:-tool/agent} — skipping phase impl without [${missing_str}]. Sequence: promise → scenarios → role → implementation. Skip = P10 (DP.FM.010)"
            return
        fi
        emit_verdict "ok" "AR.013" "IntegrationGate: phase=${phase}, skip_detected=false — sequence is satisfied"
        return
    fi

    # Fallback: classifier returned phase=unknown → checking explicit references SC/Role in context
    local sc_ref role_ref scenarios_defined
    sc_ref=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("sc_ref",""))' 2>/dev/null)
    role_ref=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("role_ref",""))' 2>/dev/null)
    scenarios_defined=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(str(d.get("scenarios_defined",False)).lower())' 2>/dev/null)

    local missing=()
    [ -z "$sc_ref" ] && missing+=("DP.SC.NNN (promise)")
    [ "$scenarios_defined" != "true" ] && [ -z "$sc_ref" ] && missing+=("use cases")
    [ -z "$role_ref" ] && missing+=("DP.ROLE.NNN (role)")

    if [ "${#missing[@]}" -gt 0 ]; then
        local fallback_missing
        fallback_missing=$(IFS=', '; echo "${missing[*]}")
        emit_verdict "warn" "AR.013" "IntegrationGate: creating new ${creation_type:-tool/agent} without ${fallback_missing} — sequence: promise → use cases → role → implementation (CLAUDE.md §2 IntegrationGate). Skip = P10 (DP.FM.010)"
        return
    fi
    emit_verdict "ok" "AR.013" "IntegrationGate: SC + use cases + Role are present"
}

check_legacy_port_gate() {
    # AR.014: replacement legacy-component → first 15-min subagent «how it works now»
    local ctx="${RULE_CONTEXT:-}"
    [ -z "$ctx" ] && ctx='{}'
    local legacy_component subagent_done
    legacy_component=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("legacy_component",""))' 2>/dev/null)
    subagent_done=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(str(d.get("subagent_research_done",False)).lower())' 2>/dev/null)

    if [ "$subagent_done" = "true" ]; then
        emit_verdict "ok" "AR.014" "LegacyPortGate: subagent-investigation completed for ${legacy_component:-component}"
        return
    fi
    emit_verdict "warn" "AR.014" "LegacyPortGate: replacement ${legacy_component:-legacy-component} without subagent-investigation — run 15-min subagent «how it works now?» BEFORE design (CLAUDE.md §2 LegacyPortGate). Skip = DP.FM.014"
}

check_snapshot_before_action() {
    # AR.101: migration/DDL/bulk → snapshot BEFORE action
    local ctx="${RULE_CONTEXT:-}"
    [ -z "$ctx" ] && ctx='{}'
    local command snapshot_done
    command=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("command",""))' 2>/dev/null)
    snapshot_done=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(str(d.get("snapshot_done",False)).lower())' 2>/dev/null)

    # Dangerous operation patterns
    local is_dangerous=false
    if echo "$command" | grep -qiE '(ALTER TABLE|DROP TABLE|CREATE TABLE|TRUNCATE|DELETE FROM|UPDATE .* WHERE|INSERT INTO .* SELECT|COPY .* FROM|pg_restore|pg_dump.*restore|rm -rf|find .* -exec rm)'; then
        is_dangerous=true
    fi

    $is_dangerous || { emit_verdict "ok" "AR.101" "snapshot gate N/A (command is not DDL/migration/bulk-delete)"; return; }

    if [ "$snapshot_done" = "true" ]; then
        emit_verdict "ok" "AR.101" "snapshot taken BEFORE action — OK"
    else
        emit_verdict "warn" "AR.101" "DDL/migration/bulk-delete without prior snapshot — run \\dt / SELECT COUNT(*) / find BEFORE action (feedback_behaviour Rule 1b, WP-183 incident)"
    fi
}

check_incident_diagnosis() {
    # AR.102: incident → verify ALL backends BEFORE hypotheses
    local ctx="${RULE_CONTEXT:-}"
    [ -z "$ctx" ] && ctx='{}'
    local backends_checked hypothesis_count
    backends_checked=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(str(d.get("all_backends_checked",False)).lower())' 2>/dev/null)
    hypothesis_count=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("hypothesis_count",0))' 2>/dev/null)

    if [ "$backends_checked" != "true" ] && python3 -c "exit(0 if int('${hypothesis_count:-0}') > 0 else 1)" 2>/dev/null; then
        emit_verdict "warn" "AR.102" "hypotheses formed without verifying ALL backends — first call each backend via a separate client, then hypotheses (feedback_behaviour Rule 8, WP-183: 1.5h on false hypotheses)"
        return
    fi
    if [ "$backends_checked" = "true" ]; then
        emit_verdict "ok" "AR.102" "all backends verified — OK"
    else
        emit_verdict "warn" "AR.102" "incident diagnosis: check ALL backends (logs + DB + queue + cache) via an independent client BEFORE forming hypotheses"
    fi
}

check_memory_drift() {
    # AR.103: Day Close / Quick Close → update memory if there are Capture-markers
    local ctx="${RULE_CONTEXT:-}"
    [ -z "$ctx" ] && ctx='{}'
    local captures_pending memory_updated
    captures_pending=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(str(d.get("captures_pending",False)).lower())' 2>/dev/null)
    memory_updated=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(str(d.get("memory_updated",False)).lower())' 2>/dev/null)

    if [ "$captures_pending" = "true" ] && [ "$memory_updated" != "true" ]; then
        emit_verdict "warn" "AR.103" "there are Capture-markers in the session — update memory BEFORE the next Day Open (feedback_behaviour Rule 9). «Update in Day Close» = a task, not an intention"
        return
    fi
    emit_verdict "ok" "AR.103" "memory drift: no pending captures or memory already updated"
}

check_systemic_review() {
    # AR.104: «systemic fix» / «root cause» → independent review BEFORE the report
    local ctx="${RULE_CONTEXT:-}"
    [ -z "$ctx" ] && ctx='{}'
    local response_text review_done
    response_text=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("response_text",""))' 2>/dev/null)
    review_done=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(str(d.get("independent_review_done",False)).lower())' 2>/dev/null)

    local claims_systemic=false
    # WP-272 revision 2026-04-30: a completion marker is required; description ("fix closes X") without done-marker is not a trigger
    if echo "$response_text" | grep -qiE '(systemic fix|systemic fix|architectural.* resolved|not a workaround).*(done|ready|completed|done|closed|✅|DONE)'; then
        claims_systemic=true
    elif echo "$response_text" | grep -qiE '(root cause).*(done|ready|completed|resolved|eliminated|fix.?complete)'; then
        claims_systemic=true
    fi

    $claims_systemic || { emit_verdict "ok" "AR.104" "systemic review N/A (no systemic fix claim)"; return; }

    if [ "$review_done" = "true" ]; then
        emit_verdict "ok" "AR.104" "independent review completed — OK"
    else
        emit_verdict "warn" "AR.104" "claim for a «systemic fix» / «root cause» without independent review — launch Agent(haiku, R23) BEFORE the final report (feedback_behaviour Rule 13)"
    fi
}

check_rebrand_e2e() {
    # AR.106: change display identity → end-to-end retest in a real client
    local ctx="${RULE_CONTEXT:-}"
    [ -z "$ctx" ] && ctx='{}'
    local file_path retest_done
    file_path=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("file_path",""))' 2>/dev/null)
    retest_done=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(str(d.get("e2e_retest_done",False)).lower())' 2>/dev/null)

    # Checking display identity patterns in file
    local is_display_identity=false
    case "$file_path" in
        */serverInfo*|*/oauth_client*|*/tool_descriptions*|*index.ts|*/get_instructions*) is_display_identity=true ;;
    esac
    if [ -f "$file_path" ]; then
        grep -qiE '(serverInfo\.name|client_name|display_name|name.*Aisystant|name.*IWE|name.*Gateway)' "$file_path" 2>/dev/null && is_display_identity=true
    fi

    $is_display_identity || { emit_verdict "ok" "AR.106" "rebrand gate N/A (not display identity file)"; return; }

    if [ "$retest_done" = "true" ]; then
        emit_verdict "ok" "AR.106" "end-to-end retest passed in real client — OK"
    else
        emit_verdict "warn" "AR.106" "change display identity without end-to-end retest — REQUIRED manual test in real client: «what is the service called?», OAuth consent screen, connector label (feedback_behaviour Rule 20, WP-259 incident)"
    fi
}

check_formal_vs_content() {
    # AR.200: «DONE»/«completed» — does it actually answer the original question?
    local ctx="${RULE_CONTEXT:-}"
    [ -z "$ctx" ] && ctx='{}'
    local response_text
    response_text=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("response_text",""))' 2>/dev/null)

    if echo "$response_text" | grep -qiE '(DONE|completed|finished|closed|✅ DONE|WP .* closed)'; then
        emit_verdict "warn" "AR.200" "claim «DONE» — verify: result answers the original question or a simplified version? For DB: SELECT COUNT(*) + sample on the target schema/table BEFORE «DONE» (distinctions: Formal ≠ substantive)"
        return
    fi
    emit_verdict "ok" "AR.200" "formal-vs-content N/A"
}

check_owner_integrity() {
    # AR.201: one fact — one place; duplication Pack↔DS = error
    local ctx="${RULE_CONTEXT:-}"
    [ -z "$ctx" ] && ctx='{}'
    local target_path source_type
    target_path=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("target_path",""))' 2>/dev/null)
    source_type=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("source_type",""))' 2>/dev/null)

    # Domain knowledge is written to DS → violation
    if echo "$target_path" | grep -qE '/DS-[^/]+/' && [ "$source_type" = "domain_knowledge" ]; then
        emit_verdict "warn" "AR.201" "domain knowledge is written to DS-repo — domain knowledge → Pack (not DS). OwnerIntegrity: one fact = one place (distinctions)"
        return
    fi
    # Implementation decision is written to Pack → violation
    if echo "$target_path" | grep -qE '/PACK-[^/]+/' && [ "$source_type" = "implementation" ]; then
        if echo "$target_path" | grep -qiE '\.(sh|ts|py|js)$'; then
            emit_verdict "warn" "AR.201" "implementation file (.sh/.ts/.py) in Pack — implementation → DS, Pack domain content only (DP.KR.001 §5.2)"
            return
        fi
    fi
    emit_verdict "ok" "AR.201" "owner integrity OK"
}

check_log_incident_state() {
    # AR.202: log / incident / state-file → correct location
    local ctx="${RULE_CONTEXT:-}"
    [ -z "$ctx" ] && ctx='{}'
    local file_path
    file_path=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("file_path",""))' 2>/dev/null)
    [ -z "$file_path" ] && { emit_verdict "ok" "AR.202" "no file_path"; return; }

    # Incidents → correct location if: (a) in /incidents/ subdirectory of any repo, or (b) in governance-repo
    # WP-272 revision 2026-04-30: incidents/ in any repo = correct placement (FP: DS-MCP/.../incidents/ → ok)
    if echo "$file_path" | grep -qiE '(incident|incident)'; then
        if echo "$file_path" | grep -qE '/incidents/'; then
            emit_verdict "ok" "AR.202" "incident-file in /incidents/ directory — correct placement"
            return
        fi
        if ! echo "$file_path" | grep -qE 'DS-[^/]+-strategy/|DS-ecosystem-development/'; then
            emit_verdict "warn" "AR.202" "incident-file outside /incidents/ directory and outside governance-repo — standard location: <repo>/incidents/YYYY-MM-DD-*.md (distinctions: Log ≠ Incident ≠ State file)"
            return
        fi
    fi
    # State-files (*.json, *.state) in governance-repo → violation
    if echo "$file_path" | grep -qE '\.(json|state)$'; then
        if echo "$file_path" | grep -qE '${IWE_GOVERNANCE_REPO:-DS-strategy}/' && ! echo "$file_path" | grep -qE '/(inbox|current|archive)/'; then
            emit_verdict "warn" "AR.202" "state-file in governance-repo outside inbox/current/archive — state files next to the executor, not in strategy-hub"
            return
        fi
    fi
    emit_verdict "ok" "AR.202" "log/incident/state routing OK"
}

# === WP-272 Phase5.1: implemented check-check functions (5 most critical) ===

check_security_gate() {
    # AR.011: PII / payment_credentials / secrets in file_path + content_snippet
    local ctx="${RULE_CONTEXT:-}"
    [ -z "$ctx" ] && ctx='{}'

    local file_path content
    file_path=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("file_path",""))' 2>/dev/null)
    content=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("content_snippet",""))' 2>/dev/null)

    # Check only if content is available for analysis
    if [ -z "$content" ] && [ -n "$file_path" ] && [ -f "$file_path" ]; then
        content=$(head -100 "$file_path" 2>/dev/null || true)
    fi
    [ -z "$content" ] && { emit_verdict "ok" "AR.011" "no content to analyze"; return; }

    # PII logging patterns PII (lines with logger/print/console.log + PII-terms)
    if echo "$content" | grep -qiE '(logger|print|console\.log|logging\.)\.*.*telegram_id'; then
        emit_verdict "block" "AR.011" "PII in log statement: telegram_id detected in logging-call — replace with account_id"
        return
    fi
    if echo "$content" | grep -qiE '(logger|print|console\.log|logging\.).*email'; then
        emit_verdict "warn" "AR.011" "email in log statement — verify: whether it is PII (if yes — block, replace with account_id/hash)"
        return
    fi

    # payment_credentials in plain text (payment_method_id logging is strictly forbidden in any context)
    if echo "$content" | grep -qiE '(logger|print|console\.log).*payment_method_id'; then
        emit_verdict "block" "AR.011" "payment_credentials in log statement: payment_method_id — even masked logging is forbidden"
        return
    fi

    # Secrets in git-tracked files (not in .env)
    if echo "$file_path" | grep -qvE '\.(env|gitignore|example)$'; then
        if echo "$content" | grep -qiE '(sk_live_|pk_live_|napi_[a-zA-Z0-9]{30}|Authorization.*Bearer [a-zA-Z0-9+/]{20})'; then
            emit_verdict "block" "AR.011" "secret in tracked-tracked file: API key detected outside .env/.gitignore — move to env vars"
            return
        fi
    fi

    # API keys in non-.env files
    if echo "$content" | grep -qiE '(password\s*=\s*["\x27][^"\x27]{8,})'; then
        if ! echo "$file_path" | grep -qE '\.(env|example|test|spec)'; then
            emit_verdict "warn" "AR.011" "hardcoded password detected — verify, not secret whether it is (move to env if so)"
            return
        fi
    fi

    emit_verdict "ok" "AR.011" "no PII/payment/secret violations detected"
}

check_sc_gate() {
    # AR.008: user-facing path must have a reference to DP.SC.NNN
    local ctx="${RULE_CONTEXT:-}"
    [ -z "$ctx" ] && ctx='{}'

    local file_path
    file_path=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("file_path",""))' 2>/dev/null)
    [ -z "$file_path" ] && { emit_verdict "ok" "AR.008" "no file_path in context"; return; }

    # Check only user-facing paths
    local is_user_facing=false
    case "$file_path" in
        */handlers/*.py|*/routes/*.ts|*/tools/*.ts|*/api/*|*/subscriptions/tariffs*)
            is_user_facing=true ;;
    esac

    if ! $is_user_facing; then
        emit_verdict "ok" "AR.008" "not a user-facing path, SC gate N/A"
        return
    fi

    # Check for presence of DP.SC.NNN reference in file
    if [ -f "$file_path" ]; then
        if grep -qE 'DP\.SC\.[0-9]+' "$file_path" 2>/dev/null; then
            emit_verdict "ok" "AR.008" "SC reference found in file"
        else
            emit_verdict "warn" "AR.008" "user-facing file without DP.SC.NNN reference — which promise is affected? Create/update SC in 08-service-clauses/"
        fi
    else
        # New file — reminder to create SC
        emit_verdict "warn" "AR.008" "new user-facing file — ensure, that DP.SC.NNN created/updated in 08-service-clauses/"
    fi
}

check_routing_gate() {
    # AR.009: new file must conform to routing map DP.KR.001 §5
    local ctx="${RULE_CONTEXT:-}"
    [ -z "$ctx" ] && ctx='{}'

    local target_path is_new
    target_path=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("target_path",""))' 2>/dev/null)
    is_new=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(str(d.get("is_new_file",False)).lower())' 2>/dev/null)

    [ -z "$target_path" ] && { emit_verdict "ok" "AR.009" "no target_path in context"; return; }
    # If file exists — not new, routing gate N/A
    [ -f "$target_path" ] && { emit_verdict "ok" "AR.009" "file exists, routing gate N/A (edit, not create)"; return; }
    [ "$is_new" = "false" ] && { emit_verdict "ok" "AR.009" "not a new file write"; return; }

    # Known-patterns whitelist
    case "$target_path" in
        */rules/AR.[0-9]*.md|*/inbox/*.md|*/fleeting-notes.md) emit_verdict "ok" "AR.009" "known pattern (rules/inbox)"; return ;;
        */WeekPlan*.md|*/DayPlan*.md|*/Strategy.md) emit_verdict "ok" "AR.009" "known pattern (governance)"; return ;;
        */.claude/rules-registry.yaml|*/rules-registry.yaml) emit_verdict "ok" "AR.009" "known pattern (generated registry)"; return ;;
        */extraction-reports/*.md|*/drafts/*.md|*/archive/*) emit_verdict "ok" "AR.009" "known pattern (workspace artifacts)"; return ;;
    esac

    # Heuristic risks
    if echo "$target_path" | grep -qiE '/(health|log|incident).*\.(json|csv|log)$'; then
        emit_verdict "warn" "AR.009" "health/log in FS — DP.KR.001 §5.7: must reside in DB #8 or alongside the executor"
        return
    fi

    if echo "$target_path" | grep -q '/PACK-' && echo "$target_path" | grep -qiE '\.(sh|ts|py|js)$'; then
        emit_verdict "warn" "AR.009" "implementation file (.sh/.ts/.py) in Pack-directory — DP.KR.001 §5.2: implementation → DS, Pack domain content only"
        return
    fi

    emit_verdict "warn" "AR.009" "new file did not match any known-patterns — check DP.KR.001 §5 (full routing map)"
}

check_schema_registration_gate() {
    # AR.234: creation of a new code scheme/registry → axis design checklist DP.METHOD.054 §5.
    # ADR-IWE-020: membership lives in schema-triggers.yaml (single source, two consumers).
    # Level — E3-prompted: review (soft nudge), not block. Correctness of axis design
    # the machine does not judge — raises the question BEFORE commit, while the agent still has design-context.
    local ctx="${RULE_CONTEXT:-}"
    [ -z "$ctx" ] && ctx='{}'

    local target_path
    target_path=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("target_path",""))' 2>/dev/null)
    [ -z "$target_path" ] && { emit_verdict "ok" "AR.234" "no target_path in context"; return; }

    # Exception: existing file = instance/edit/rename, not a new schema → AR.211/AR.233
    [ -f "$target_path" ] && { emit_verdict "ok" "AR.234" "file exists — instance/edit, not a new schema (AR.211/AR.233)"; return; }

    # is_in_scope: the same config, that the wrapper reads-hook (single-source membership)
    local cfg="${SCHEMA_TRIGGERS_CONFIG:-$HOME/IWE/.claude/hooks/schema-triggers.yaml}"
    local in_scope
    # WP-529 (continuation, 19.08, cold review — missed in the initial `import
    # yaml` survey, found by a second full-file grep after codex's turn-1
    # completeness concern): same lazy-placement + no-fallback rationale as
    # the other sites in this migration.
    local _stg_resolved_python3
    _stg_resolved_python3=$("${IWE_SCRIPTS:-$HOME/IWE/scripts}/lib/find-python3.sh" 2>/dev/null) || _stg_resolved_python3=""
    in_scope=$([ -n "$_stg_resolved_python3" ] && _STG_CFG="$cfg" _STG_PATH="$target_path" "$_stg_resolved_python3" - <<'PYEOF' 2>/dev/null || echo "error"
import os, fnmatch
cfg = os.environ["_STG_CFG"]
base = os.path.basename(os.environ["_STG_PATH"])
try:
    import yaml
    with open(cfg) as f:
        c = yaml.safe_load(f) or {}
    globs = c.get("path_globs", [])
except Exception:
    print("error"); raise SystemExit
print("yes" if any(fnmatch.fnmatch(base, g) for g in globs) else "no")
PYEOF
)

    if [ "$in_scope" = "yes" ]; then
        emit_verdict "warn" "AR.234" "New coding scheme (${target_path}) — fill in DP.METHOD.054 §5 BEFORE commit: owner (Registration Authority)? axis is orthogonal/mutually exclusive? bounded_context (namespace)? enforcement_mechanism (E0-E3)? §8: new registry = entry in registry-catalog.yaml + namespace in the numbering registry"
        return
    fi
    if [ "$in_scope" = "error" ]; then
        # fail-open: nudge advisory, must not block operation when config is broken
        emit_verdict "ok" "AR.234" "schema-triggers.yaml unreadable — fail-open (nudge skipped)"
        return
    fi
    emit_verdict "ok" "AR.234" "target not a schema-file per schema-triggers.yaml"
}

check_repo_touch_gate() {
    # AR.010: on first touch of the repo — check CLAUDE.md for «mandatory load»
    # WP-272 Phase5.3: added READ-ONLY protection (tool_name + sub-path check)
    local ctx="${RULE_CONTEXT:-}"
    [ -z "$ctx" ] && ctx='{}'

    local tool_arg tool_name session_id
    tool_arg=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("tool_arg",""))' 2>/dev/null)
    tool_name=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("tool_name",""))' 2>/dev/null)
    session_id=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("session_id",""))' 2>/dev/null)
    [ -z "$session_id" ] && session_id="${CLAUDE_SESSION_ID:-default}"

    [ -z "$tool_arg" ] && { emit_verdict "ok" "AR.010" "no tool_arg in context"; return; }

    # READ-ONLY: check BEFORE session-state (block even repeated touches)
    local rel_path=""
    if [[ "$tool_arg" == "$HOME/IWE/"* ]]; then
        rel_path="${tool_arg#$HOME/IWE/}"
    elif [[ "$tool_arg" =~ /IWE/(.+)$ ]]; then
        rel_path="${BASH_REMATCH[1]}"
    fi

    if [ -n "$rel_path" ]; then
        local ro
        IFS=',' read -ra _READONLY_REPOS <<< "${IWE_READONLY_REPOS:-}"
        for ro in "${_READONLY_REPOS[@]}"; do
            if [[ "$rel_path" == "$ro" ]] || [[ "$rel_path" == "$ro/"* ]]; then
                case "$tool_name" in
                    Edit|Write|MultiEdit|NotebookEdit)
                        emit_verdict "block" "AR.010" "READ-ONLY repo ${ro} — ${tool_name} is not permitted (CLAUDE.md §9). Read only."
                        return ;;
                esac
                # Read and other operations — are permitted; exit the loop, proceed
                break
            fi
        done
    fi

    # Extract the repo name (top level) for session-state
    local repo=""
    if [[ "$tool_arg" =~ $HOME/IWE/([^/]+)/ ]]; then
        repo="${BASH_REMATCH[1]}"
    elif [[ "$tool_arg" =~ /IWE/([^/]+)/ ]]; then
        repo="${BASH_REMATCH[1]}"
    fi
    [ -z "$repo" ] && { emit_verdict "ok" "AR.010" "path outside ~/IWE/, gate N/A"; return; }

    # Check the state file: has this repo already been touched state-file: whether it has already been touch this repo
    local state_dir="$HOME/.claude/state"
    local state_file="$state_dir/repo-touched-${session_id}.json"
    mkdir -p "$state_dir" 2>/dev/null || true

    if [ -f "$state_file" ]; then
        local already_touched
        already_touched=$(_SF="$state_file" _REPO="$repo" python3 -c '
import json, os
try:
    with open(os.environ["_SF"]) as f:
        repos = json.load(f)
    print("yes" if os.environ["_REPO"] in repos else "no")
except Exception:
    print("no")' 2>/dev/null)
        [ "$already_touched" = "yes" ] && { emit_verdict "ok" "AR.010" "repo $repo already touched this session"; return; }
    fi

    # First touch — mark and verify CLAUDE.md
    _SF="$state_file" _REPO="$repo" python3 -c '
import json, os
sf = os.environ["_SF"]
repo = os.environ["_REPO"]
try:
    with open(sf) as f:
        repos = json.load(f)
except Exception:
    repos = []
if repo not in repos:
    repos.append(repo)
    with open(sf, "w") as f:
        json.dump(repos, f)' 2>/dev/null || true

    local claudemd="$HOME/IWE/$repo/CLAUDE.md"
    if [ ! -f "$claudemd" ]; then
        emit_verdict "ok" "AR.010" "first touch repo $repo — no CLAUDE.md, gate N/A"
        return
    fi

    if grep -qE '(MUST LOAD|must load|load on touch)' "$claudemd" 2>/dev/null; then
        emit_verdict "warn" "AR.010" "first touch of repo $repo — CLAUDE.md contains block «MUST LOAD», load the listed files BEFORE responding"
    else
        emit_verdict "ok" "AR.010" "first touch repo $repo — CLAUDE.md checked, no mandatory-load block"
    fi
}

check_entry_point() {
    # AR.105: when Edit index.*/main.*/app.* — remind to check config entry point
    local ctx="${RULE_CONTEXT:-}"
    [ -z "$ctx" ] && ctx='{}'

    local target_path
    target_path=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("target_path",""))' 2>/dev/null)
    [ -z "$target_path" ] && { emit_verdict "ok" "AR.105" "no target_path in context"; return; }

    local basename
    basename=$(basename "$target_path")

    # Triggers only on entry-point patterns
    case "$basename" in
        index.*|main.*|app.*) ;;
        *) emit_verdict "ok" "AR.105" "not an entry-point filename pattern"; return ;;
    esac

    # Find configs in repo
    local repo_root
    repo_root=$(git -C "$(dirname "$target_path")" rev-parse --show-toplevel 2>/dev/null || true)
    [ -z "$repo_root" ] && { emit_verdict "ok" "AR.105" "not in a git repo, gate N/A"; return; }

    local hints=()
    [ -f "$repo_root/wrangler.toml" ] && hints+=("wrangler.toml:main")
    [ -f "$repo_root/package.json" ] && hints+=("package.json:main")
    [ -f "$repo_root/Dockerfile" ] && hints+=("Dockerfile:CMD")
    [ -f "$repo_root/pyproject.toml" ] && hints+=("pyproject.toml:[project.scripts]")

    if [ "${#hints[@]}" -gt 0 ]; then
        local hint_str
        hint_str=$(IFS=', '; echo "${hints[*]}")
        emit_verdict "warn" "AR.105" "Edit ${basename} — verify that this is a real entry point. Configs in repo: ${hint_str}"
    else
        emit_verdict "ok" "AR.105" "no config files found, proceeding without entry-point check"
    fi
}

check_auto_verify_code() {
    # AR.107: after modifying .py/.ts/.sh files — remind to run sub-agent R23 BEFORE commit
    local ctx="${RULE_CONTEXT:-}"
    [ -z "$ctx" ] && ctx='{}'

    local changed_files
    changed_files=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(" ".join(d.get("changed_files",[])))' 2>/dev/null)

    if echo "$changed_files" | grep -qE '\.(py|ts|sh|js|go|rb)($| )'; then
        emit_verdict "warn" "AR.107" "Code changed (.py/.ts/.sh) — run sub-agent R23 (Haiku) BEFORE commit: PASS → commit; FAIL → fix"
        return
    fi
    emit_verdict "ok" "AR.107" "no code files changed, verification not required"
}

check_script_errors() {
    # AR.108: when errors are detected in script output — diagnose and raise immediately
    local ctx="${RULE_CONTEXT:-}"
    [ -z "$ctx" ] && ctx='{}'

    local script_output
    script_output=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("script_output",""))' 2>/dev/null)
    local exit_code
    exit_code=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("exit_code","0"))' 2>/dev/null)

    if [ "$exit_code" != "0" ] && [ -n "$exit_code" ]; then
        emit_verdict "warn" "AR.108" "Script exited with exit=${exit_code} — diagnose the cause and report BEFORE continuing"
        return
    fi
    if echo "$script_output" | grep -qiE '(^ERROR|^FAIL|error:|fail:|exception:|duplicate|duplicate|Traceback|panic:|CRITICAL)'; then
        emit_verdict "warn" "AR.108" "Error in script output — diagnose the root cause and propose a fix BEFORE the next step"
        return
    fi
    emit_verdict "ok" "AR.108" "no error signals in script output"
}

check_domain_question_pack() {
    # AR.109: domain question (IWE/FPF/Pack-terminology) → search in Pack before falling back to general knowledge
    local ctx="${RULE_CONTEXT:-}"
    [ -z "$ctx" ] && ctx='{}'

    local question
    question=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("question",""))' 2>/dev/null)
    [ -z "$question" ] && { emit_verdict "ok" "AR.109" "no question in context"; return; }

    if echo "$question" | grep -qiE '(IWE|FPF|ZP|PACK|DP\.|AR\.|DS-|[Rr]ole|distinct|subagent|verifier|orchestrator|[Pp]ortnoj|[Oo]censhchik|skill|protocol|ORS)'; then
        emit_verdict "warn" "AR.109" "Domain question — look up the answer in Pack (DS→Pack→Base) BEFORE using the model general knowledge"
        return
    fi
    emit_verdict "ok" "AR.109" "question does not appear domain-specific"
}

check_instruction_deviation() {
    # AR.110: intentional deviation from the literal instruction — must notify
    local ctx="${RULE_CONTEXT:-}"
    [ -z "$ctx" ] && ctx='{}'

    local deviation_detected
    deviation_detected=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(str(d.get("deviation_detected","false")).lower())' 2>/dev/null)

    if [ "$deviation_detected" = "true" ]; then
        emit_verdict "warn" "AR.110" "Deviation from user instruction — notify explicitly: what was done, why it differs from the literal instruction"
        return
    fi
    emit_verdict "ok" "AR.110" "no deviation signal in context"
}

check_release_verification_trigger() {
    # AR.203: version bump update-manifest.json or staged change in release scope → 5-layer verify
    local ctx="${RULE_CONTEXT:-}"
    [ -z "$ctx" ] && ctx='{}'

    local file_path staged_files
    file_path=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("file_path","") or d.get("target_path",""))' 2>/dev/null)
    staged_files=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(" ".join(d.get("staged_files",[])))' 2>/dev/null)

    # Collect all paths for verification
    local all_paths="$file_path $staged_files"

    # Release scope patterns (from AR.203 applies_when)
    local in_scope=false
    if echo "$all_paths" | grep -qE 'update-manifest\.json'; then
        in_scope=true
    elif echo "$all_paths" | grep -qE '/(roles|\.claude|setup|memory|extensions|seed)/'; then
        in_scope=true
    elif echo "$all_paths" | grep -qE 'IWE/(roles|\.claude|setup|memory|extensions|seed|update-manifest)'; then
        in_scope=true
    fi

    $in_scope || { emit_verdict "ok" "AR.203" "not in FMT release scope"; return; }

    # Check, whether verification was performed
    local verification_done
    verification_done=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(str(d.get("release_verification_done",False)).lower())' 2>/dev/null)

    if [ "$verification_done" = "true" ]; then
        emit_verdict "ok" "AR.203" "release verification completed — OK"
    else
        emit_verdict "warn" "AR.203" "change in FMT release scope ($(echo "$all_paths" | tr ' ' '\n' | grep -E 'update-manifest|/(roles|\.claude|setup|memory|extensions|seed)/' | head -1 | xargs basename 2>/dev/null || echo 'scope file')) — run 5-layer verification BEFORE push: pre-commit + CI + upgrade-test + detector regression + adversarial (VR.M.006, AR.203)"
    fi
}

check_secret_in_chat() {
    # AR.111: secret/API-key in chat — block the request, upon receipt — rotation-alert
    local ctx="${RULE_CONTEXT:-}"
    [ -z "$ctx" ] && ctx='{}'

    local chat_content
    chat_content=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("user_message","") + " " + d.get("tool_input",""))' 2>/dev/null)

    local secret_request
    secret_request=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(str(d.get("secret_request","false")).lower())' 2>/dev/null)

    # Active secret pattern in text (postgres:// and postgresql://, password ≥4 characters)
    if echo "$chat_content" | grep -qE '(napi_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9]{20,}|ghp_[A-Za-z0-9]{20,}|postgre(s|sql)://[^@:]+:[^@]{4,}@|-----BEGIN (PRIVATE|RSA) KEY-----|Bearer eyJ[A-Za-z0-9._-]{50,})'; then
        emit_verdict "block" "AR.111" "Secret in chat — treat as compromised: revoke → new → cascade rotation across all usage points"
        return
    fi
    # Request for a plaintext secret
    if [ "$secret_request" = "true" ]; then
        emit_verdict "warn" "AR.111" "Request for secret value — pass via reference to source (.secrets/, env var name), not as plaintext"
        return
    fi
    emit_verdict "ok" "AR.111" "no secret signals detected"
}

sql_security_analysis() {
    # Statement-aware, dependency-free scanner shared by AR.112 and AR.113.
    # Comments and string literals are removed before matching so that a WHERE
    # or consent-looking word in documentation cannot create a false pass.
    python3 - <<'PYEOF'
import json
import os
import re
import sys


def split_sql(text):
    statements, buf = [], []
    i, state, dollar_tag = 0, "normal", None
    while i < len(text):
        ch = text[i]
        nxt = text[i + 1] if i + 1 < len(text) else ""
        if state == "line_comment":
            if ch == "\n":
                state = "normal"
                buf.append(" ")
            i += 1
            continue
        if state == "block_comment":
            if ch == "*" and nxt == "/":
                state = "normal"
                buf.append(" ")
                i += 2
            else:
                i += 1
            continue
        if state == "single_quote":
            if ch == "'" and nxt == "'":
                i += 2
            elif ch == "'":
                state = "normal"
                buf.append(" __literal__ ")
                i += 1
            else:
                i += 1
            continue
        if state == "dollar_quote":
            if text.startswith(dollar_tag, i):
                state = "normal"
                buf.append(" __literal__ ")
                i += len(dollar_tag)
            else:
                i += 1
            continue

        if ch == "-" and nxt == "-":
            state = "line_comment"
            i += 2
        elif ch == "/" and nxt == "*":
            state = "block_comment"
            i += 2
        elif ch == "'":
            state = "single_quote"
            i += 1
        elif ch == "$":
            match = re.match(r"\$[A-Za-z_][A-Za-z0-9_]*\$|\$\$", text[i:])
            if match:
                dollar_tag = match.group(0)
                state = "dollar_quote"
                i += len(dollar_tag)
            else:
                buf.append(ch)
                i += 1
        elif ch == '"':
            # Preserve quoted identifier content, but not the quote delimiters.
            i += 1
            while i < len(text):
                if text[i] == '"' and i + 1 < len(text) and text[i + 1] == '"':
                    buf.append('"')
                    i += 2
                elif text[i] == '"':
                    i += 1
                    break
                else:
                    buf.append(text[i])
                    i += 1
        elif ch == ";":
            statement = "".join(buf).strip()
            if statement:
                statements.append(statement)
            buf = []
            i += 1
        else:
            buf.append(ch)
            i += 1

    if state in {"block_comment", "single_quote", "dollar_quote"}:
        raise ValueError("unterminated SQL comment or string literal")
    statement = "".join(buf).strip()
    if statement:
        statements.append(statement)
    return statements


try:
    context = json.loads(os.environ.get("RULE_CONTEXT", "{}") or "{}")
    content = f'{context.get("file_content", "")}\n{context.get("command", "")}'
    statements = split_sql(content)
    pii_table = re.compile(
        r"(?:\blearning\s*\.\s*(?:users|accounts|person_accounts|sessions)\b"
        r"|\bpayment\s*\.\s*(?:accounts|subscriptions)\b"
        r"|\brewards\s*\.\s*accounts\b"
        r"|\bpublic\s*\.\s*users\b"
        r"|\b(?:public\s*\.\s*)?(?:domain_event|ory_identity)\b"
        r"|\b(?:users|accounts|person_accounts|sessions|subscriptions|profiles|contacts|"
        r"user_events|persona|stage_transitions|graduation_log|dt_tokens|"
        r"github_connections|digital_twins|google_calendar|google_calendar_connections)\b"
        r"|\b[A-Za-z0-9_]*(?:user|account|profile|contact|persona|session|subscription|"
        r"identity|token|connection|event|customer|member|person|payment)s?"
        r"(?:_[A-Za-z0-9_]*)?\b)",
        re.I,
    )
    pii_operation = re.compile(
        r"\b(?:select|table|insert|update|delete|merge|copy|truncate|drop|alter|refresh|import)\b",
        re.I,
    )
    dynamic_sql = re.compile(
        r"\bdo\b|\bexecute\b|\bcall\b|"
        r"\bcreate\s+(?:or\s+replace\s+)?(?:function|procedure)\b",
        re.I,
    )
    privilege_or_rls_change = re.compile(
        r"\b(?:create|alter|drop)\s+(?:role|user|group)\b|\bbypassrls\b|\bnoinherit\b|\bsecurity\s+definer\b|"
        r"\b(?:enable|disable|force|no\s+force)\s+row\s+level\s+security\b|"
        r"\bset\s+(?:local\s+|session\s+)?role\b|"
        r"\bset\s+session\s+authorization\b|"
        r"\bset\s+(?:local\s+|session\s+)?row_security\b|"
        r"\b(?:create|alter|drop)\s+policy\b|"
        r"\b(?:grant|revoke)\b|\balter\s+default\s+privileges\b|"
        r"\bimport\s+foreign\s+schema\b|\brefresh\s+materialized\s+view\b|"
        r"\balter\s+(?:table|database|schema|sequence|view|materialized\s+view|function|procedure|type)\b[\s\S]*\bowner\s+to\b|"
        r"\bdrop\s+owned\s+by\b|\breassign\s+owned\s+by\b|"
        r"\balter\s+table\b[\s\S]*\b(?:enable|disable)\s+trigger\b",
        re.I,
    )
    raw_privilege_change = re.compile(
        r"\bset_config\s*\(|\bset\s+(?:local\s+|session\s+)?row_security\b",
        re.I,
    )

    direct_pii_terms = {
        "email", "username", "phone", "mobile", "name", "passport", "inn",
        "snils", "dob", "birth", "address", "postal", "telegram", "ip",
        "device", "tax", "national", "evidence",
    }

    def has_pii_identifier(statement):
        for identifier in re.findall(r"\b[A-Za-z_][A-Za-z0-9_]*\b", statement):
            normalized = re.sub(r"(?<=[a-z0-9])(?=[A-Z])", "_", identifier)
            parts = set(normalized.lower().split("_"))
            if parts & direct_pii_terms:
                return True
        return False

    unsafe_rls = sorted({
        index
        for index, statement in enumerate(statements, 1)
        if (
            raw_privilege_change.search(content)
            or dynamic_sql.search(statement)
            or privilege_or_rls_change.search(statement)
            or (
                pii_operation.search(statement)
                and (pii_table.search(statement) or has_pii_identifier(statement))
            )
        )
    })

    create_table = re.compile(r"\bcreate\s+table\b", re.I)
    alter_add_column = re.compile(
        r"\balter\s+table\b[\s\S]*\badd\s+(?:column\s+)?\b", re.I
    )
    pii_schema_change = [
        index
        for index, statement in enumerate(statements, 1)
        if (
            create_table.search(statement) or alter_add_column.search(statement)
        ) and (has_pii_identifier(statement) or pii_table.search(statement))
    ]
    print(json.dumps({
        "status": "ok",
        "statement_count": len(statements),
        "unsafe_rls_statements": unsafe_rls,
        "pii_schema_statements": pii_schema_change,
    }))
except Exception as exc:
    print(json.dumps({"status": "error", "error_type": type(exc).__name__}))
    sys.exit(2)
PYEOF
}

check_bypassrls_explicit_where() {
    # AR.112: a regex can find PII access but cannot prove SQL identity scope.
    local analysis status unsafe_count
    if ! analysis=$(sql_security_analysis 2>/dev/null); then
        emit_verdict "warn" "AR.112" "SQL detector failed — privileged PII operation requires manual review"
        return
    fi
    status=$(printf '%s' "$analysis" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status", "error"))' 2>/dev/null)
    [ "$status" != "ok" ] && { emit_verdict "warn" "AR.112" "SQL detector returned an invalid analysis — manual review required"; return; }
    unsafe_count=$(printf '%s' "$analysis" | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("unsafe_rls_statements", [])))' 2>/dev/null)
    case "$unsafe_count" in ''|*[!0-9]*) emit_verdict "warn" "AR.112" "SQL detector returned an invalid count — manual review required"; return ;; esac
    if [ "$unsafe_count" -gt 0 ]; then
        emit_verdict "warn" "AR.112" "$unsafe_count PII/dynamic SQL statement(s) require manual identity-scope review — regex evidence cannot prove safe boolean, alias, CTE or dynamic-SQL semantics"
        return
    fi
    emit_verdict "ok" "AR.112" "no known PII data operation or dynamic SQL detected"
}

check_pii_consent_two_tier() {
    # AR.113: SQL can detect a PII schema, but cannot prove valid user consent.
    local analysis status create_count
    if ! analysis=$(sql_security_analysis 2>/dev/null); then
        emit_verdict "warn" "AR.113" "SQL detector failed — PII schema requires manual Security Gate review"
        return
    fi
    status=$(printf '%s' "$analysis" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status", "error"))' 2>/dev/null)
    [ "$status" != "ok" ] && { emit_verdict "warn" "AR.113" "SQL detector returned an invalid analysis — manual Security Gate review required"; return; }
    create_count=$(printf '%s' "$analysis" | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("pii_schema_statements", [])))' 2>/dev/null)
    case "$create_count" in ''|*[!0-9]*) emit_verdict "warn" "AR.113" "SQL detector returned an invalid count — manual Security Gate review required"; return ;; esac
    if [ "$create_count" -gt 0 ]; then
        emit_verdict "warn" "AR.113" "$create_count schema statement(s) define direct PII columns — SQL cannot prove two-tier consent; complete a manual Security Gate review"
        return
    fi
    emit_verdict "ok" "AR.113" "no direct PII CREATE TABLE statement detected"
}

check_git_staged_only() {
    # AR.216: git add -A / -u / . — forbidden; use explicit paths
    # RULE_CONTEXT: {"command": "git add -A ..."}
    local ctx="${RULE_CONTEXT:-}"
    [ -z "$ctx" ] && ctx='{}'

    local cmd
    cmd=$(echo "$ctx" | python3 -c '
import sys, json
d = json.loads(sys.stdin.read() or "{}")
print(d.get("command",""))
' 2>/dev/null)

    if echo "$cmd" | grep -qE "git add[[:space:]]+(-A|--all|\.|--update|-u)[[:space:]]*(--[[:space:]]*)?$"; then
        emit_verdict "warn" "AR.216" "Detected git add -A/./u — forbidden (captures files of other agents). Stage only specific files: git add <path>. CRITICAL rule from AGENTS.md"
        return
    fi

    emit_verdict "ok" "AR.216" "git staging scope OK"
}

# === Dispatcher ===

dispatch_event() {
    local event="${RULE_EVENT:?error: RULE_EVENT required}"

    local matches
    matches=$(load_rules_for_event "$event")

    local count
    count=$(echo "$matches" | python3 -c 'import sys,json; print(len(json.loads(sys.stdin.read() or "[]")))')

    if [ "$count" -eq 0 ]; then
        printf '{"verdict":"ok","rule_id":"none","reason":"no rules match event %s"}\n' "$event"
        return
    fi

    # Apply rules in priority order priority (sorted in load_rules_for_event)
    local final_verdict="ok"
    local final_rule="none"
    local final_reason=""
    local applied=()

    while IFS= read -r rule_json; do
        [ -z "$rule_json" ] && continue
        local rule_id check_fn
        rule_id=$(echo "$rule_json" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read())["id"])')
        check_fn=$(echo "$rule_json" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read())["hook"].split("::")[-1])')

        if ! declare -f "$check_fn" > /dev/null; then
            log_journal "$rule_id" "warn" "check function $check_fn not implemented"
            continue
        fi

        local result
        result=$($check_fn)
        local verdict
        verdict=$(echo "$result" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read())["verdict"])')
        applied+=("$rule_id:$verdict")

        # Block overrides warn overrides ok
        if [ "$verdict" = "block" ]; then
            final_verdict="block"
            final_rule="$rule_id"
            final_reason=$(echo "$result" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read())["reason"])')
            break  # priority-sorted, first block — final
        elif [ "$verdict" = "warn" ] && [ "$final_verdict" != "block" ]; then
            final_verdict="warn"
            final_rule="$rule_id"
            final_reason=$(echo "$result" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read())["reason"])')
        fi
    done < <(echo "$matches" | python3 -c 'import sys,json; [print(json.dumps(r)) for r in json.loads(sys.stdin.read() or "[]")]')

    printf '{"verdict":"%s","rule_id":"%s","applied_rules":%s,"reason":%s}\n' \
        "$final_verdict" \
        "$final_rule" \
        "$(printf '%s\n' "${applied[@]}" | python3 -c 'import sys,json; print(json.dumps([l.strip() for l in sys.stdin if l.strip()], ensure_ascii=False))')" \
        "$(printf '%s' "$final_reason" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read(), ensure_ascii=False))')"
}

# === CLI ===

case "${1:-dispatch}" in
    dispatch)
        dispatch_event
        ;;
    session-summary)
        # WP-272 Phase5: output warn/block for the current session for Close-protocol
        SID="${2:-$SESSION_ID}"
        WARN_LOG="$SESSION_STATE_DIR/session-${SID}-warns.jsonl"
        if [ ! -f "$WARN_LOG" ] || [ ! -s "$WARN_LOG" ]; then
            echo '{"session_id":"'"$SID"'","total":0,"blocks":0,"warns":0,"items":[]}'
            exit 0
        fi
        export _SID="$SID" _STATE_DIR="$SESSION_STATE_DIR"
        python3 - << 'PYEOF' 2>/dev/null
import json, sys, os
sid = os.environ.get('_SID', 'default')
state_dir = os.environ.get('_STATE_DIR', os.path.join(os.path.expanduser('~'), '.claude', 'state'))
warn_log = os.path.join(state_dir, f'session-{sid}-warns.jsonl')
items = []
try:
    with open(warn_log) as f:
        for line in f:
            line = line.strip()
            if line:
                try:
                    items.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
except FileNotFoundError:
    pass
blocks = [i for i in items if i.get('verdict') == 'block']
warns = [i for i in items if i.get('verdict') == 'warn']
# Deduplication by rule_id (keep unique entries)
seen = {}
for i in items:
    seen[i.get('rule', '?')] = i
unique = list(seen.values())
print(json.dumps({
    'session_id': sid,
    'total': len(unique),
    'blocks': len([i for i in unique if i.get('verdict') == 'block']),
    'warns': len([i for i in unique if i.get('verdict') == 'warn']),
    'items': unique
}, ensure_ascii=False))
PYEOF
        ;;
    session-clear)
        # Clear session warn-log (after Close)
        SID="${2:-$SESSION_ID}"
        WARN_LOG="$SESSION_STATE_DIR/session-${SID}-warns.jsonl"
        [ -f "$WARN_LOG" ] && rm -f "$WARN_LOG" && echo "cleared: $WARN_LOG" || echo "nothing to clear"
        ;;
    list-rules)
        # WP-529 (continuation, 19.08, cold review — same second-pass grep as
        # is_in_scope above): explicit CLI subcommand, invoked by a human —
        # fails loudly rather than degrading silently, matching require_python()
        # in route-task.sh (same resolver contract).
        _lr_resolved_python3=$("${IWE_SCRIPTS:-$HOME/IWE/scripts}/lib/find-python3.sh" 2>/dev/null) || _lr_resolved_python3=""
        if [ -z "$_lr_resolved_python3" ]; then
            echo "ERROR: python3 with library PyYAML not found (pip install pyyaml)" >&2
            exit 1
        fi
        "$_lr_resolved_python3" -c "
import yaml
with open('$REGISTRY') as f:
    reg = yaml.safe_load(f)
print(f\"{'ID':<10} {'Type':<13} {'Pri':<4} {'Name':<35} {'Status'}\")
print('-' * 80)
for r in reg.get('rules', []):
    print(f\"{r['id']:<10} {r['type']:<13} {r['priority']:<4} {r['name']:<35} {r['status']}\")
"
        ;;
    test)
        # WP-272 revision 2026-04-30: tests write to a separate log, not in production
        export RULE_JOURNAL_DIR="${HOME}/logs/rule-engine/test"
        mkdir -p "$RULE_JOURNAL_DIR"
        PASS=0; FAIL=0
        run_test() {
            local num="$1" desc="$2" expected_verdict="$3"
            shift 3
            local result
            result=$(env RULE_JOURNAL_DIR="${HOME}/logs/rule-engine/test" "$@" bash "$0" dispatch 2>/dev/null)
            local got
            got=$(echo "$result" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read()).get("verdict","error"))' 2>/dev/null)
            if [ "$got" = "$expected_verdict" ]; then
                echo "PASS Test $num: $desc → $got"
                PASS=$((PASS+1))
            else
                echo "FAIL Test $num: $desc → expected=$expected_verdict got=$got result=$result"
                FAIL=$((FAIL+1))
            fi
        }

        # AR.001 WP Gate
        run_test 1 "WP create without consent → block" "block" \
            RULE_EVENT="wp_create_attempt" RULE_CONTEXT='{"user_consent":false,"file_path":"inbox/WP-271.md"}'
        run_test 2 "WP create with consent → ok" "ok" \
            RULE_EVENT="wp_create_attempt" RULE_CONTEXT='{"user_consent":true,"file_path":"inbox/WP-272.md"}'

        # AR.002 Autonomy
        run_test 3 "yes/no question in response → warn" "warn" \
            RULE_EVENT="response_emitted" RULE_CONTEXT='{"response_text":"Method OK?"}'
        run_test 4 "choice question in response → ok" "ok" \
            RULE_EVENT="response_emitted" RULE_CONTEXT='{"response_text":"Do we do X or Y?"}'

        # AR.011 Security Gate
        run_test 5 "telegram_id in logger → block" "block" \
            RULE_EVENT="pii_touch_attempt" \
            RULE_CONTEXT='{"file_path":"/tmp/test_handler.py","content_snippet":"logger.info(telegram_id)"}'
        run_test 6 "account_id in logger → ok (not PII)" "ok" \
            RULE_EVENT="pii_touch_attempt" \
            RULE_CONTEXT='{"file_path":"/tmp/test_handler.py","content_snippet":"logger.info(account_id)"}'

        # AR.009 Routing Gate
        run_test 7 "new file in known inbox pattern → ok" "ok" \
            RULE_EVENT="artifact_creation_attempt" \
            RULE_CONTEXT='{"target_path":"/tmp/IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/inbox/WP-999-test.md","is_new_file":true}'
        run_test 8 "new .sh in Pack → warn (implementation in Pack)" "warn" \
            RULE_EVENT="artifact_creation_attempt" \
            RULE_CONTEXT='{"target_path":"/tmp/IWE/PACK-digital-platform/scripts/deploy.sh","is_new_file":true}'

        # AR.105 Entry Point
        run_test 9 "edit non-entry-point file → ok" "ok" \
            RULE_EVENT="runtime_file_edit_attempt" \
            RULE_CONTEXT='{"target_path":"/tmp/src/utils.ts"}'
        run_test 10 "edit main.py (no configs in /tmp) → ok (no configs found)" "ok" \
            RULE_EVENT="runtime_file_edit_attempt" \
            RULE_CONTEXT='{"target_path":"/tmp/main.py"}'

        # AR.010 Repo-Touch Gate — READ-ONLY block (WP-272 Phase5.3)
        # Configure IWE_READONLY_REPOS="DS-sample/repo-a,DS-sample/repo-b" to activate
        run_test 11 "Edit in readonly repo → block (IWE_READONLY_REPOS set)" "block" \
            IWE_READONLY_REPOS="DS-sample/readonly-repo" \
            RULE_EVENT="first_repo_action" \
            RULE_CONTEXT="{\"tool_arg\":\"$HOME/IWE/DS-sample/readonly-repo/sample.py\",\"tool_name\":\"Edit\",\"session_id\":\"test-ro-1\"}"
        run_test 12 "Write in readonly repo → block (IWE_READONLY_REPOS set)" "block" \
            IWE_READONLY_REPOS="DS-sample/readonly-repo" \
            RULE_EVENT="first_repo_action" \
            RULE_CONTEXT="{\"tool_arg\":\"$HOME/IWE/DS-sample/readonly-repo/README.md\",\"tool_name\":\"Write\",\"session_id\":\"test-ro-2\"}"

        # AR.012 Priority Gate (WP-272 Phase5.4)
        run_test 13 "WP budget=8h without R{N} → warn" "warn" \
            RULE_EVENT="wp_creation_with_budget_attempt" \
            RULE_CONTEXT='{"budget_h":8,"r_goal":"","verification_class":"closed-loop"}'
        run_test 14 "WP budget=1h → ok (small task)" "ok" \
            RULE_EVENT="wp_creation_with_budget_attempt" \
            RULE_CONTEXT='{"budget_h":1,"r_goal":"","verification_class":"closed-loop"}'

        # AR.013 IntegrationGate
        run_test 15 "new tool without SC + Role → warn (P10)" "warn" \
            RULE_EVENT="new_tool_creation" \
            RULE_CONTEXT='{"creation_type":"hook","sc_ref":"","role_ref":"","scenarios_defined":false}'
        run_test 16 "new tool with SC + Role → ok" "ok" \
            RULE_EVENT="new_tool_creation" \
            RULE_CONTEXT='{"creation_type":"hook","sc_ref":"DP.SC.125","role_ref":"DP.ROLE.042","scenarios_defined":true}'

        # AR.101 Snapshot Before Action
        run_test 17 "ALTER TABLE without snapshot → warn" "warn" \
            RULE_EVENT="ddl_attempt" \
            RULE_CONTEXT='{"command":"ALTER TABLE finance.payments ADD COLUMN x INT","snapshot_done":false}'
        run_test 18 "ALTER TABLE with snapshot → ok" "ok" \
            RULE_EVENT="ddl_attempt" \
            RULE_CONTEXT='{"command":"ALTER TABLE finance.payments ADD COLUMN x INT","snapshot_done":true}'

        # AR.104 Systemic Fix Review
        # WP-272 revision 2026-04-30: now required is a done-marker; description without done = not a trigger
        run_test 19 "system fix DONE without review DONE without review → warn" "warn" \
            RULE_EVENT="systemic_fix_completion" \
            RULE_CONTEXT='{"response_text":"system fix resolves root cause -- DONE root cause — DONE","independent_review_done":false}'
        run_test 20 "normal completion without a ticket → ok" "ok" \
            RULE_EVENT="systemic_fix_completion" \
            RULE_CONTEXT='{"response_text":"editing config file","independent_review_done":false}'
        run_test 20 "fix description without done-marker → ok (FP-protection)" "ok" \
            RULE_EVENT="systemic_fix_completion" \
            RULE_CONTEXT='{"response_text":"system fix resolves root cause root cause","independent_review_done":false}'

        # AR.202 Log/Incident/State routing
        # WP-272 revision 2026-04-30: incidents/ in any repo = ok; warn warn only if outside /incidents/ AND outside governance
        run_test 21 "incident in /incidents/ subdirectory → ok (correct location)" "ok" \
            RULE_EVENT="incident_creation_attempt" \
            RULE_CONTEXT="{\"file_path\":\"$HOME/IWE/DS-sample/sample-service/incidents/incident-001.md\"}"
        run_test 21 "incident outside /incidents/ and outside governance → warn" "warn" \
            RULE_EVENT="incident_creation_attempt" \
            RULE_CONTEXT="{\"file_path\":\"$HOME/IWE/DS-sample/sample-service/src/incident-001.md\"}"
        run_test 22 "incident in ${IWE_GOVERNANCE_REPO:-DS-strategy} → ok" "ok" \
            RULE_EVENT="incident_creation_attempt" \
            RULE_CONTEXT="{\"file_path\":\"$HOME/IWE/${IWE_GOVERNANCE_REPO:-DS-strategy}/inbox/incident-001.md\"}"

        # AR.003 ArchGate
        run_test 23 "new_tool_creation → warn (archgate required)" "warn" \
            RULE_EVENT="new_tool_creation" \
            RULE_CONTEXT='{"file_path":""}'
        run_test 24 "non-arch event → ok" "ok" \
            RULE_EVENT="pii_touch_attempt" \
            RULE_CONTEXT='{"file_path":""}'

        # AR.107 Auto Verify Code
        run_test 25 "modified .py file → warn (verify before commit)" "warn" \
            RULE_EVENT="code_change_with_files" \
            RULE_CONTEXT='{"changed_files":["src/main.py","config.yaml"]}'
        run_test 26 "only .md modified → ok (no verify needed)" "ok" \
            RULE_EVENT="code_change_with_files" \
            RULE_CONTEXT='{"changed_files":["README.md","docs/guide.md"]}'

        # AR.108 Script Errors Surface
        run_test 27 "script exit=1 → warn (diagnose first)" "warn" \
            RULE_EVENT="script_error_detected" \
            RULE_CONTEXT='{"script_output":"Some output","exit_code":"1"}'
        run_test 28 "script exit=0, no errors → ok" "ok" \
            RULE_EVENT="script_error_detected" \
            RULE_CONTEXT='{"script_output":"All done successfully","exit_code":"0"}'

        # AR.111 Secret In Chat
        run_test 29 "PostgreSQL URL with password in chat → block" "block" \
            RULE_EVENT="secret_in_chat_detected" \
            RULE_CONTEXT='{"user_message":"postgresql://user:supersecretpass123@ep-xyz.neon.tech/db","tool_input":""}'
        run_test 30 "regular message → ok (no secret)" "ok" \
            RULE_EVENT="secret_in_chat_detected" \
            RULE_CONTEXT='{"user_message":"run psql and show tables","tool_input":""}'

        # AR.112/AR.113 statement-aware SQL security (WP-544 D6.1-D6.2)
        run_test D6.2a "WHERE in another statement does not scope PII query → warn" "warn" \
            RULE_EVENT="sql_file_write" RULE_CONTEXT='{"file_path":"migration.sql","file_content":"SET ROLE privileged; SELECT * FROM user_events LIMIT 1; SELECT 1 WHERE account_id = 1;"}'
        run_test D6.2b "scoped PII query still requires semantic review → warn" "warn" \
            RULE_EVENT="sql_file_write" RULE_CONTEXT='{"file_path":"migration.sql","file_content":"SET ROLE privileged; SELECT * FROM user_events WHERE account_id = current_setting('"'"'app.current_user_id'"'"');"}'
        run_test D6.2c "commented WHERE does not scope PII query → warn" "warn" \
            RULE_EVENT="sql_file_write" RULE_CONTEXT='{"file_path":"migration.sql","file_content":"SET ROLE privileged; SELECT * FROM user_events /* WHERE account_id = 1 */ LIMIT 1;"}'
        run_test D6.2d "PII CREATE TABLE always requires manual review → warn" "warn" \
            RULE_EVENT="sql_file_write" RULE_CONTEXT='{"file_path":"migration.sql","file_content":"CREATE TABLE profile (date_of_birth date, address text); -- consent_grants"}'
        run_test D6.2e "non-PII CREATE TABLE → ok" "ok" \
            RULE_EVENT="sql_file_write" RULE_CONTEXT='{"file_path":"migration.sql","file_content":"CREATE TABLE counters (counter_id uuid, value integer);"}'
        run_test D6.2f "unterminated SQL literal fails visible → warn" "warn" \
            RULE_EVENT="sql_file_write" RULE_CONTEXT='{"file_path":"migration.sql","file_content":"SET ROLE privileged; SELECT * FROM user_events WHERE account_id = '"'"'broken;"}'
        run_test D6.2g "unscoped UNION branch cannot borrow scope → warn" "warn" \
            RULE_EVENT="sql_file_write" RULE_CONTEXT='{"file_path":"migration.sql","file_content":"SET ROLE privileged; SELECT * FROM user_events WHERE account_id = 1 UNION ALL SELECT * FROM user_events;"}'
        run_test D6.2h "OR can broaden an identity predicate → warn" "warn" \
            RULE_EVENT="sql_file_write" RULE_CONTEXT='{"file_path":"migration.sql","file_content":"SET ROLE privileged; SELECT * FROM user_events WHERE true OR account_id = 1;"}'
        run_test D6.2i "self-comparison is not identity scope → warn" "warn" \
            RULE_EVENT="sql_file_write" RULE_CONTEXT='{"file_path":"migration.sql","file_content":"SET ROLE privileged; SELECT * FROM user_events WHERE account_id = account_id;"}'
        run_test D6.2j "bare PII table without role marker → warn" "warn" \
            RULE_EVENT="sql_file_write" RULE_CONTEXT='{"file_path":"migration.sql","file_content":"SELECT * FROM users;"}'
        run_test D6.2k "canonical event table requires review → warn" "warn" \
            RULE_EVENT="sql_file_write" RULE_CONTEXT='{"file_path":"migration.sql","file_content":"SELECT * FROM public.domain_event WHERE account_id = 1;"}'
        run_test D6.2l "ALTER TABLE adding PII requires consent review → warn" "warn" \
            RULE_EVENT="sql_file_write" RULE_CONTEXT='{"file_path":"migration.sql","file_content":"ALTER TABLE profiles ADD COLUMN telegram_username text, ADD COLUMN ip_address inet;"}'
        run_test D6.2m "COPY from PII table requires review → warn" "warn" \
            RULE_EVENT="sql_file_write" RULE_CONTEXT='{"file_path":"migration.sql","file_content":"COPY user_events TO STDOUT;"}'
        run_test D6.2n "RLS policy DDL requires review → warn" "warn" \
            RULE_EVENT="sql_file_write" RULE_CONTEXT='{"file_path":"migration.sql","file_content":"CREATE POLICY all_access ON user_events USING (true);"}'
        run_test D6.2o "compound PII column names require consent review → warn" "warn" \
            RULE_EVENT="sql_file_write" RULE_CONTEXT='{"file_path":"migration.sql","file_content":"CREATE TABLE people (contact_email text, legal_full_name text, national_id text);"}'
        run_test D6.2p "PostgreSQL TABLE shorthand requires PII review → warn" "warn" \
            RULE_EVENT="sql_file_write" RULE_CONTEXT='{"file_path":"migration.sql","file_content":"TABLE user_events;"}'
        run_test D6.2q "cursor TABLE shorthand requires PII review → warn" "warn" \
            RULE_EVENT="sql_file_write" RULE_CONTEXT='{"file_path":"migration.sql","file_content":"DECLARE c CURSOR FOR TABLE user_events;"}'
        run_test D6.2r "materialized view over PII requires review → warn" "warn" \
            RULE_EVENT="sql_file_write" RULE_CONTEXT='{"file_path":"migration.sql","file_content":"CREATE MATERIALIZED VIEW archive AS TABLE user_events;"}'
        run_test D6.2s "SET row_security TO off requires review → warn" "warn" \
            RULE_EVENT="sql_file_write" RULE_CONTEXT='{"file_path":"migration.sql","file_content":"SET row_security TO off;"}'
        run_test D6.2t "set_config call requires privilege review → warn" "warn" \
            RULE_EVENT="sql_file_write" RULE_CONTEXT='{"file_path":"migration.sql","file_content":"SELECT set_config('"'"'row_security'"'"','"'"'off'"'"',true);"}'
        run_test D6.2u "GRANT on PII table requires privilege review → warn" "warn" \
            RULE_EVENT="sql_file_write" RULE_CONTEXT='{"file_path":"migration.sql","file_content":"GRANT ALL PRIVILEGES ON TABLE user_events TO exporter;"}'
        run_test D6.2v "default privileges change requires review → warn" "warn" \
            RULE_EVENT="sql_file_write" RULE_CONTEXT='{"file_path":"migration.sql","file_content":"ALTER DEFAULT PRIVILEGES GRANT ALL ON TABLES TO exporter;"}'
        run_test D6.2w "PII SELECT column on neutral table requires review → warn" "warn" \
            RULE_EVENT="sql_file_write" RULE_CONTEXT='{"file_path":"migration.sql","file_content":"SELECT email FROM audit_log;"}'
        run_test D6.2x "PII INSERT column on neutral table requires review → warn" "warn" \
            RULE_EVENT="sql_file_write" RULE_CONTEXT='{"file_path":"migration.sql","file_content":"INSERT INTO audit_log (email) VALUES ('"'"'synthetic@example.invalid'"'"');"}'
        run_test D6.2y "PII UPDATE column on neutral table requires review → warn" "warn" \
            RULE_EVENT="sql_file_write" RULE_CONTEXT='{"file_path":"migration.sql","file_content":"UPDATE audit_log SET phone_number = '"'"'synthetic'"'"';"}'
        run_test D6.2z "evidence JSONB read requires indirect-PII review → warn" "warn" \
            RULE_EVENT="sql_file_write" RULE_CONTEXT='{"file_path":"migration.sql","file_content":"SELECT evidence FROM audit_log;"}'
        run_test D6.2aa "quoted camelCase PII identifier requires review → warn" "warn" \
            RULE_EVENT="sql_file_write" RULE_CONTEXT='{"file_path":"migration.sql","file_content":"SELECT \"emailAddress\" FROM audit_log;"}'
        run_test D6.2ab "PostgreSQL CREATE USER alias requires privilege review → warn" "warn" \
            RULE_EVENT="sql_file_write" RULE_CONTEXT='{"file_path":"migration.sql","file_content":"CREATE USER exporter LOGIN;"}'
        run_test D6.2ac "foreign schema import requires review → warn" "warn" \
            RULE_EVENT="sql_file_write" RULE_CONTEXT='{"file_path":"migration.sql","file_content":"IMPORT FOREIGN SCHEMA remote FROM SERVER analytics INTO public;"}'
        run_test D6.2ad "materialized view refresh requires review → warn" "warn" \
            RULE_EVENT="sql_file_write" RULE_CONTEXT='{"file_path":"migration.sql","file_content":"REFRESH MATERIALIZED VIEW archive;"}'
        run_test D6.2ae "row_security=false requires review → warn" "warn" \
            RULE_EVENT="sql_file_write" RULE_CONTEXT='{"file_path":"migration.sql","file_content":"SET row_security TO false;"}'
        run_test D6.2af "row_security=0 requires review → warn" "warn" \
            RULE_EVENT="sql_file_write" RULE_CONTEXT='{"file_path":"migration.sql","file_content":"SET row_security = 0;"}'
        run_test D6.2ag "quoted row_security off requires review → warn" "warn" \
            RULE_EVENT="sql_file_write" RULE_CONTEXT='{"file_path":"migration.sql","file_content":"SET row_security = '"'"'off'"'"';"}'
        run_test D6.2ah "row_security=no requires review → warn" "warn" \
            RULE_EVENT="sql_file_write" RULE_CONTEXT='{"file_path":"migration.sql","file_content":"SET LOCAL row_security TO no;"}'
        run_test D6.2ai "PostgreSQL CREATE GROUP alias requires privilege review → warn" "warn" \
            RULE_EVENT="sql_file_write" RULE_CONTEXT='{"file_path":"migration.sql","file_content":"CREATE GROUP exporters;"}'
        run_test D6.2aj "table ownership transfer requires privilege review → warn" "warn" \
            RULE_EVENT="sql_file_write" RULE_CONTEXT='{"file_path":"migration.sql","file_content":"ALTER TABLE audit_log OWNER TO exporter;"}'
        run_test D6.2ak "DROP OWNED requires privilege review → warn" "warn" \
            RULE_EVENT="sql_file_write" RULE_CONTEXT='{"file_path":"migration.sql","file_content":"DROP OWNED BY exporter;"}'
        run_test D6.2al "REASSIGN OWNED requires privilege review → warn" "warn" \
            RULE_EVENT="sql_file_write" RULE_CONTEXT='{"file_path":"migration.sql","file_content":"REASSIGN OWNED BY exporter TO app;"}'
        run_test D6.2am "disabling table triggers requires security review → warn" "warn" \
            RULE_EVENT="sql_file_write" RULE_CONTEXT='{"file_path":"migration.sql","file_content":"ALTER TABLE audit_log DISABLE TRIGGER ALL;"}'


        # AR.013 IntegrationGate phase-skip classifier
        run_test 31 "impl without SC/Role → warn (phase skip)" "warn" \
            RULE_EVENT="new_tool_creation" \
            RULE_CONTEXT="{\"creation_type\":\"hook\",\"file_path\":\"$HOME/IWE/DS-MCP/src/new-tool.ts\",\"sc_ref\":\"\",\"role_ref\":\"\",\"scenarios_defined\":false}"
        run_test 32 "SC-Phase (creation DP.SC file) → ok" "ok" \
            RULE_EVENT="new_tool_creation" \
            RULE_CONTEXT="{\"creation_type\":\"hook\",\"file_path\":\"$HOME/IWE/PACK-digital-platform/pack/digital-platform/08-service-clauses/DP.SC.125.md\",\"sc_ref\":\"\",\"role_ref\":\"\",\"scenarios_defined\":false}"

        # AR.203 Release Verification Trigger (WP-272 Phase5)
        run_test 33 "modification update-manifest.json → warn (verify before push)" "warn" \
            RULE_EVENT="version_bump_in_update_manifest_json" \
            RULE_CONTEXT='{"file_path":"${IWE:-$HOME/IWE}/IWE/update-manifest.json","release_verification_done":false}'
        run_test 34 "modification roles/ in FMT scope → warn" "warn" \
            RULE_EVENT="staged_files_in_validator_scope" \
            RULE_CONTEXT='{"staged_files":["${IWE:-$HOME/IWE}/IWE/roles/R.001.md"],"release_verification_done":false}'
        run_test 35 "verification done → ok" "ok" \
            RULE_EVENT="version_bump_in_update_manifest_json" \
            RULE_CONTEXT='{"file_path":"${IWE:-$HOME/IWE}/IWE/update-manifest.json","release_verification_done":true}'
        run_test 36 "file outside FMT release scope → ok (N/A)" "ok" \
            RULE_EVENT="version_bump_in_update_manifest_json" \
            RULE_CONTEXT='{"file_path":"${IWE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}/inbox/notes.md","release_verification_done":false}'

        # AR.234 Schema Registration Gate (ADR-IWE-020)
        run_test 37 "new *-catalog.yaml (in scope, does not exist) → warn (axis design)" "warn" \
            RULE_EVENT="schema_registration_attempt" \
            RULE_CONTEXT='{"target_path":"/tmp/iwe-dogfood-foo-catalog.yaml","is_new_file":true}'
        run_test 38 "new non-schema file (.md) → ok (outside scope)" "ok" \
            RULE_EVENT="schema_registration_attempt" \
            RULE_CONTEXT='{"target_path":"/tmp/iwe-dogfood-notes.md","is_new_file":true}'
        run_test 39 "existing registry-file → ok (instance/edit, not a new schema)" "ok" \
            RULE_EVENT="schema_registration_attempt" \
            RULE_CONTEXT="{\"target_path\":\"$HOME/IWE/.claude/rules-registry.yaml\",\"is_new_file\":false}"

        # AR.234 dogfood: liveness membership-config (ADR-IWE-020 §5 — anti-silent-death).
        # Verifies: (1) schema-triggers.yaml is readable; (2) fired_event matches triggers AR.234 in registry.
        # Cold review 2026-08-19 (Codex, High): this PyYAML consumer was missed
        # by the initial two-pass `import yaml` grep — a self-test that fails
        # closed ("FAIL config unreadable") on a yaml-less bare python3 would
        # falsely report the dogfood check itself as broken, on a machine
        # where the shared resolver would have found a working interpreter.
        # No bare-python3 fallback — same rationale as the other sites in
        # this migration: an unresolved interpreter fails the dogfood check
        # explicitly, it does not fall through to a bare-python3 retry.
        DOGFOOD_RESOLVED_PYTHON3=$("${IWE_SCRIPTS:-$HOME/IWE/scripts}/lib/find-python3.sh" 2>/dev/null) || DOGFOOD_RESOLVED_PYTHON3=""
        if [ -z "$DOGFOOD_RESOLVED_PYTHON3" ]; then
            DOGFOOD="FAIL no python3 with PyYAML found"
        else
            DOGFOOD=$(_REG="$REGISTRY" _CFG="${SCHEMA_TRIGGERS_CONFIG:-$HOME/IWE/.claude/hooks/schema-triggers.yaml}" "$DOGFOOD_RESOLVED_PYTHON3" - <<'PYEOF' 2>/dev/null || echo "FAIL config unreadable"
import os, yaml
with open(os.environ["_CFG"]) as f:
    cfg = yaml.safe_load(f) or {}
fired = cfg.get("fired_event")
if not fired:
    print("FAIL no fired_event in schema-triggers.yaml"); raise SystemExit
with open(os.environ["_REG"]) as f:
    reg = yaml.safe_load(f) or {}
ar234 = next((r for r in reg.get("rules", []) if r.get("id") == "AR.234"), None)
if ar234 is None:
    print("FAIL AR.234 not in registry"); raise SystemExit
if fired not in ar234.get("triggers", []):
    print("FAIL fired_event '%s' not in AR.234.triggers %s" % (fired, ar234.get("triggers"))); raise SystemExit
print("PASS")
PYEOF
)
        fi
        if [ "$DOGFOOD" = "PASS" ]; then
            echo "PASS Test 40: dogfood — schema-triggers.yaml is alive, fired_event matches AR.234.triggers"
            PASS=$((PASS+1))
        else
            echo "FAIL Test 40: dogfood — $DOGFOOD"
            FAIL=$((FAIL+1))
        fi

        echo ""
        echo "=== Results: $PASS PASS / $FAIL FAIL (total $((PASS+FAIL))) ==="
        [ "$FAIL" -eq 0 ] && exit 0 || exit 1
        ;;
    check-trace-satisfaction|list-gates|mark-gate)
        # issue #678: memory/protocol-close.md references these three
        # subcommands (Quick/Week/Month Close, gate-tracing WP-481 Phase5.1),
        # but the mechanism was never implemented. Previously this fell into
        # the unnamed branch *) below with generic usage — in practice indistinguishable
        # from a typo in the subcommand name and does not report, exactly what is not
        # working. An explicit branch with a clear message instead of a silent guess:
        # gate checking did not actually occur, this is not «passed with exit 1».
        echo "NOT_IMPLEMENTED: '$1' (rule-engine.sh) — gate-tracing (WP-481 Phase5.1) is described in protocol-close.md, but is not implemented (issue #678)." >&2
        echo "Gates of this section have NOT been checked automatically — Close-Close-protocol must treat this step as failed, not skipped." >&2
        exit 3
        ;;
    *)
        echo "Usage: rule-engine.sh {dispatch|list-rules|test|session-summary|session-clear}"
        echo "  dispatch     — process event (use RULE_EVENT + RULE_CONTEXT env vars)"
        echo "  list-rules   — show all rules in registry"
        echo "  test         — run smoke tests (WP-271 incident simulation)"
        exit 1
        ;;
esac
