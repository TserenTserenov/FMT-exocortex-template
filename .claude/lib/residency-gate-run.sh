#!/usr/bin/env bash
# Shared ResidencyGate runner for all three shell adapters (issue #521).
#
# The Python CLI can type policy/config/runtime failures only after an
# interpreter with PyYAML has started. This boundary resolves that interpreter
# first and adds the otherwise-unrepresentable dependency_error outcome.
# Callers inspect the RESIDENCY_GATE_* globals; this function deliberately
# returns 0 after classification so `set -e` cannot skip their fail-closed
# message/return policy.

residency_gate_run() {
    if [ "$#" -lt 3 ]; then
        RESIDENCY_GATE_OUTCOME="runtime_error"
        RESIDENCY_GATE_DETAIL="residency_gate_run requires <project-root> <gate.py> <command>"
        RESIDENCY_GATE_RESULT=""
        RESIDENCY_GATE_EXIT_CODE=3
        RESIDENCY_GATE_PYTHON3=""
        RESIDENCY_GATE_RESOLVER=""
        return 0
    fi

    local project_root="$1"
    local gate_py="$2"
    shift 2

    RESIDENCY_GATE_OUTCOME="runtime_error"
    RESIDENCY_GATE_DETAIL=""
    RESIDENCY_GATE_RESULT=""
    RESIDENCY_GATE_EXIT_CODE=3
    RESIDENCY_GATE_PYTHON3=""
    RESIDENCY_GATE_RESOLVER="${IWE_PYTHON_RESOLVER:-$project_root/.claude/lib/find-python3.sh}"

    if [ ! -r "$gate_py" ]; then
        RESIDENCY_GATE_OUTCOME="dependency_error"
        RESIDENCY_GATE_DETAIL="ResidencyGate implementation is missing or unreadable: $gate_py"
        return 0
    fi

    if [ ! -x "$RESIDENCY_GATE_RESOLVER" ]; then
        RESIDENCY_GATE_OUTCOME="dependency_error"
        RESIDENCY_GATE_DETAIL="Python resolver is missing or not executable: $RESIDENCY_GATE_RESOLVER"
        return 0
    fi

    local resolver_output=""
    if ! resolver_output=$("$RESIDENCY_GATE_RESOLVER" 2>&1); then
        RESIDENCY_GATE_OUTCOME="dependency_error"
        RESIDENCY_GATE_DETAIL="$resolver_output"
        return 0
    fi

    RESIDENCY_GATE_PYTHON3="$resolver_output"
    if [ ! -x "$RESIDENCY_GATE_PYTHON3" ]; then
        RESIDENCY_GATE_OUTCOME="dependency_error"
        RESIDENCY_GATE_DETAIL="Python resolver returned a non-executable path: $RESIDENCY_GATE_PYTHON3"
        RESIDENCY_GATE_PYTHON3=""
        return 0
    fi

    local command_output=""
    local command_rc=0
    if command_output=$("$RESIDENCY_GATE_PYTHON3" "$gate_py" "$@" 2>&1); then
        command_rc=0
    else
        command_rc=$?
    fi

    RESIDENCY_GATE_RESULT="$command_output"
    RESIDENCY_GATE_EXIT_CODE=$command_rc
    case "$command_rc:$command_output" in
        '0:{"outcome":"allowed","allowed":true'* )
            RESIDENCY_GATE_OUTCOME="allowed"
            ;;
        '1:{"outcome":"policy_denied","allowed":false'* )
            RESIDENCY_GATE_OUTCOME="policy_denied"
            ;;
        '2:{"outcome":"manifest_invalid","allowed":false'* )
            RESIDENCY_GATE_OUTCOME="manifest_invalid"
            ;;
        '3:{"outcome":"runtime_error","allowed":false'* )
            RESIDENCY_GATE_OUTCOME="runtime_error"
            ;;
        *)
            RESIDENCY_GATE_OUTCOME="runtime_error"
            # Public result inspected by the sourcing adapter after return.
            # shellcheck disable=SC2034
            RESIDENCY_GATE_EXIT_CODE=3
            RESIDENCY_GATE_DETAIL="ResidencyGate returned an untyped or exit-code-mismatched response (rc=$command_rc): $command_output"
            ;;
    esac

    if [ -z "$RESIDENCY_GATE_DETAIL" ]; then
        RESIDENCY_GATE_DETAIL="$RESIDENCY_GATE_RESULT"
    fi
    return 0
}

residency_gate_human_detail() {
    if [ "$RESIDENCY_GATE_OUTCOME" = "dependency_error" ] || ! command -v jq >/dev/null 2>&1; then
        printf '%s\n' "$RESIDENCY_GATE_DETAIL"
        return 0
    fi

    local detail=""
    detail=$(printf '%s\n' "$RESIDENCY_GATE_RESULT" | jq -r '
        if (.blocking? | type) == "array" then (.blocking | join("; "))
        elif .reason? then .reason
        elif .error? then .error
        else empty
        end
    ' 2>/dev/null) || detail=""
    printf '%s\n' "${detail:-$RESIDENCY_GATE_DETAIL}"
}
