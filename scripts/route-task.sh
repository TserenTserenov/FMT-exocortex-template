#!/usr/bin/env bash
# route-task.sh — Маршрутизатор задач IWE (DP.ROLE.059)
# routing: executor=script  deterministic=true
# see DP.SC.159, DP.ROLE.059
#
# Получает routing-tag из WP Gate или Артефактора → lookup в executor-catalog.yaml →
# запускает нужный исполнитель (script | haiku | sonnet | opus | mcp-direct | agent | script+judgment).
#
# Usage:
#   route-task.sh --skill <skill-name> [--args "..."]   # strict: no fallback
#   route-task.sh --tag  <routing-tag>  [--args "..."]   # flex: fallback to Sonnet on miss
#   route-task.sh --list                                 # показать каталог
#   route-task.sh --validate                             # проверить каталог
#   route-task.sh --json                                 # machine-readable JSON output
#
# Exit: 0=OK, 1=error, 2=script_path not found, 3=unknown skill, 4=unsupported executor

set -euo pipefail

IWE_DIR="${IWE_DIR:-$HOME/IWE}"
IWE_TEMPLATE="${IWE_TEMPLATE:-$IWE_DIR/FMT-exocortex-template}"
GOV_REPO="${IWE_GOVERNANCE_REPO:-DS-strategy}"
CATALOG="${IWE_EXECUTOR_CATALOG:-${IWE_DIR}/${GOV_REPO}/scripts/executor-catalog.yaml}"
AUDIT_LOG="${IWE_ROUTER_AUDIT:-${IWE_DIR}/${GOV_REPO}/logs/routing-path-distribution.tsv}"
ERROR_LOG="${IWE_ROUTER_ERRORS:-${IWE_DIR}/${GOV_REPO}/logs/routing-errors.log}"
JSON_MODE="false"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

die() {
    local msg="$1" code="${2:-1}"
    if [[ "$JSON_MODE" == "true" ]]; then
        printf '{"exec_result":"ERROR","error_code":%s,"message":"%s"}\n' "$code" "$msg"
    else
        echo "ERROR: $msg" >&2
    fi
    exit "$code"
}

warn() { echo "WARN: $*" >&2; }

require_python() {
    if ! command -v python3 &>/dev/null; then
        die "python3 not found — required for catalog lookup" 1
    fi
    if ! python3 -c "import yaml" &>/dev/null; then
        die "PyYAML not found — required for catalog lookup (pip install pyyaml)" 1
    fi
}

require_catalog() {
    if [[ ! -f "$CATALOG" ]]; then
        die "executor-catalog.yaml not found: $CATALOG" 1
    fi
}

# ---------------------------------------------------------------------------
# Output formatting
# ---------------------------------------------------------------------------

emit_result() {
    local skill="$1" executor="$2" result="$3" routing_path="$4" model="${5:-}"
    if [[ "$JSON_MODE" == "true" ]]; then
        if [[ -n "$model" ]]; then
            printf '{"executor":"%s","routing_path":"%s","exec_result":"%s","model":"%s"}\n' \
                "$executor" "$routing_path" "$result" "$model"
        else
            printf '{"executor":"%s","routing_path":"%s","exec_result":"%s"}\n' \
                "$executor" "$routing_path" "$result"
        fi
    fi
}

emit_error() {
    local skill="$1" result="$2" reason="$3"
    local ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if [[ "$JSON_MODE" == "true" ]]; then
        printf '{"exec_result":"%s","skill":"%s","reason":"%s"}\n' \
            "$result" "$skill" "$reason"
    fi
    # Always log to routing-errors.log
    local err_dir
    err_dir="$(dirname "$ERROR_LOG")"
    [[ -d "$err_dir" ]] || mkdir -p "$err_dir"
    printf "%s\t%s\t%s\t%s\n" "$ts" "$skill" "$result" "$reason" >> "$ERROR_LOG"
}

# ---------------------------------------------------------------------------
# Audit log (routing-path-distribution)
# ---------------------------------------------------------------------------

log_audit() {
    local ts="$1" tag="$2" executor="$3" result="$4"
    local audit_dir
    audit_dir="$(dirname "$AUDIT_LOG")"
    [[ -d "$audit_dir" ]] || mkdir -p "$audit_dir"
    printf "%s\t%s\t%s\t%s\n" "$ts" "$tag" "$executor" "$result" >> "$AUDIT_LOG"
}

# ---------------------------------------------------------------------------
# Catalog lookup via Python (reliable YAML parsing)
# ---------------------------------------------------------------------------

lookup_skill() {
    local skill_name="$1"
    require_python
    require_catalog
    python3 - "$CATALOG" "$skill_name" << 'PYEOF'
import sys, yaml

catalog_path, skill_name = sys.argv[1], sys.argv[2]
with open(catalog_path) as f:
    cat = yaml.safe_load(f)

for entry in cat.get("entries", []):
    if entry["name"] == skill_name:
        r = entry["routing"]
        print(f"executor={r['executor']}")
        print(f"deterministic={r.get('deterministic', 'false')}")
        if "script_path" in r:
            print(f"script_path={r['script_path']}")
        if "model" in r:
            print(f"model={r['model']}")
        if "optimization_priority" in r:
            print(f"optimization_priority={r['optimization_priority']}")
        sys.exit(0)

sys.exit(3)  # not found
PYEOF
}

# ---------------------------------------------------------------------------
# Executors
# ---------------------------------------------------------------------------

_resolve_interpreter() {
    local script_path="$1"
    local ext="${script_path##*.}"
    if [[ "$ext" == "py" ]]; then
        echo "python3"
    elif [[ "$ext" == "rb" ]]; then
        echo "ruby"
    elif [[ -r "$script_path" ]]; then
        local shebang
        shebang=$(head -n1 "$script_path" 2>/dev/null)
        if [[ "$shebang" =~ ^#!/usr/bin/env[[:space:]]+python ]]; then
            echo "python3"
        elif [[ "$shebang" =~ ^#!/usr/bin/env[[:space:]]+ruby ]]; then
            echo "ruby"
        else
            echo "bash"
        fi
    else
        echo "bash"
    fi
}

run_script() {
    local skill_name="$1"
    local script_path="$2"
    local args="${3:-}"
    local allow_fallback="${4:-true}"
    local routing_path="${5:-$skill_name → script}"

    # executor-catalog.yaml is generated from template SKILL.md frontmatter,
    # so relative script_path is relative to the template root, not the
    # workspace root (issue #634).
    if [[ "$script_path" != /* ]]; then
        script_path="$IWE_TEMPLATE/$script_path"
    fi

    if [[ ! -f "$script_path" ]]; then
        if [[ "$allow_fallback" == "false" ]]; then
            warn "script not found: $script_path (skill=$skill_name)"
            emit_error "$skill_name" "EXEC_FAILED" "script_path not found: $script_path"
            emit_result "$skill_name" "script" "EXEC_FAILED" "$routing_path"
            exit 2
        fi
        warn "script not found: $script_path (skill=$skill_name)"
        warn "Script may be aspirational (pending Ф12 implementation)."
        warn "Falling back to Haiku LLM executor."
        run_haiku "$skill_name" "$args"
        log_audit "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$skill_name" "haiku" "OK"
        emit_result "$skill_name" "haiku" "OK" "$skill_name → haiku (fallback)"
        return 0
    fi

    if [[ ! -x "$script_path" ]]; then
        chmod +x "$script_path"
    fi

    local interpreter
    interpreter=$(_resolve_interpreter "$script_path")

    if [[ "$JSON_MODE" != "true" ]]; then
        echo "[router] skill=$skill_name executor=script interpreter=$interpreter path=$script_path"
    fi
    local script_exit=0
    if [[ -n "$args" ]]; then
        read -r -a ARGS_ARRAY <<< "$args"
        "$interpreter" "$script_path" "${ARGS_ARRAY[@]}" || script_exit=$?
    else
        "$interpreter" "$script_path" || script_exit=$?
    fi
    if [[ $script_exit -ne 0 ]]; then
        emit_error "$skill_name" "EXEC_FAILED" "script exit $script_exit"
        emit_result "$skill_name" "script" "EXEC_FAILED" "$routing_path"
        log_audit "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$skill_name" "script" "EXEC_FAILED"
    else
        emit_result "$skill_name" "script" "OK" "$routing_path"
        log_audit "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$skill_name" "script" "OK"
    fi
    return $script_exit
}

run_llm() {
    local skill_name="$1"
    local model="$2"
    local args="${3:-}"

    if [[ "$JSON_MODE" != "true" ]]; then
        echo "[router] skill=$skill_name executor=llm model=$model"
        echo "ROUTE_TO_LLM skill=$skill_name model=$model args=$args"
    fi
}

run_haiku()  { run_llm "$1" "claude-haiku-4-5-20251001" "${2:-}"; }
run_sonnet() { run_llm "$1" "claude-sonnet-4-6"          "${2:-}"; }
run_opus()   { run_llm "$1" "claude-opus-4-7"            "${2:-}"; }

run_mcp_direct() {
    local skill_name="$1"
    local args="${2:-}"
    if [[ "$JSON_MODE" != "true" ]]; then
        echo "[router] skill=$skill_name executor=mcp-direct"
        echo "ROUTE_TO_MCP skill=$skill_name args=$args"
    fi
}

run_agent() {
    local skill_name="$1"
    local model="$2"
    local args="${3:-}"
    if [[ "$JSON_MODE" != "true" ]]; then
        echo "[router] skill=$skill_name executor=agent model=$model"
        echo "ROUTE_TO_AGENT skill=$skill_name model=$model args=$args"
    fi
}

run_script_judgment() {
    local skill_name="$1"
    local args="${2:-}"
    if [[ "$JSON_MODE" != "true" ]]; then
        echo "[router] skill=$skill_name executor=script+judgment"
        echo "ROUTE_TO_JUDGMENT skill=$skill_name mode=script+judgment args=$args"
    fi
}

fallback_to_sonnet() {
    local skill_name="$1" args="$2" ts="$3" reason="$4"
    warn "${reason} Falling back to Sonnet."
    run_sonnet "$skill_name" "$args"
    log_audit "$ts" "$skill_name" "sonnet" "OK"
    emit_result "$skill_name" "sonnet" "OK" "$skill_name → sonnet (fallback)"
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

dispatch_skill() {
    local skill_name="$1"
    local args="${2:-}"
    local allow_fallback="${3:-true}"
    local ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    local routing_path="$skill_name → "

    local lookup_result lookup_exit
    lookup_result=$(lookup_skill "$skill_name") && lookup_exit=0 || lookup_exit=$?
    if [[ $lookup_exit -ne 0 ]]; then
        if [[ $lookup_exit -eq 3 ]]; then
            if [[ "$allow_fallback" == "false" ]]; then
                warn "skill '$skill_name' not in catalog."
                emit_error "$skill_name" "NO_MATCH" "skill not in catalog"
                emit_result "$skill_name" "unknown" "NO_MATCH" "$skill_name → NO_MATCH"
                log_audit "$ts" "$skill_name" "unknown" "NO_MATCH"
                exit 3
            fi
            fallback_to_sonnet "$skill_name" "$args" "$ts" "skill '$skill_name' not in catalog."
            return 0
        fi
        die "catalog lookup failed (exit=$lookup_exit)"
    fi

    local executor script_path="" model=""
    executor=$(echo "$lookup_result" | grep "^executor=" | cut -d= -f2)
    script_path=$(echo "$lookup_result" | grep "^script_path=" | cut -d= -f2- || true)
    model=$(echo "$lookup_result" | grep "^model=" | cut -d= -f2- || true)
    routing_path="${routing_path}${executor}"

    case "$executor" in
        script)
            run_script "$skill_name" "$script_path" "$args" "$allow_fallback" "$routing_path"
            ;;
        haiku)
            run_haiku "$skill_name" "$args"
            log_audit "$ts" "$skill_name" "haiku" "OK"
            emit_result "$skill_name" "haiku" "OK" "$routing_path"
            return 0
            ;;
        sonnet)
            run_sonnet "$skill_name" "$args"
            log_audit "$ts" "$skill_name" "sonnet" "OK"
            emit_result "$skill_name" "sonnet" "OK" "$routing_path"
            return 0
            ;;
        opus)
            run_opus "$skill_name" "$args"
            log_audit "$ts" "$skill_name" "opus" "OK"
            emit_result "$skill_name" "opus" "OK" "$routing_path"
            return 0
            ;;
        mcp-direct)
            run_mcp_direct "$skill_name" "$args"
            log_audit "$ts" "$skill_name" "mcp-direct" "OK"
            emit_result "$skill_name" "mcp-direct" "OK" "$routing_path"
            return 0
            ;;
        agent)
            if [[ -z "$model" ]]; then
                if [[ "$allow_fallback" == "false" ]]; then
                    warn "agent executor missing model for skill '$skill_name'."
                    emit_error "$skill_name" "EXEC_FAILED" "agent executor missing model"
                    emit_result "$skill_name" "agent" "EXEC_FAILED" "$routing_path"
                    log_audit "$ts" "$skill_name" "agent" "EXEC_FAILED"
                    exit 4
                fi
                fallback_to_sonnet "$skill_name" "$args" "$ts" "agent executor missing model for skill '$skill_name'."
                return 0
            fi
            run_agent "$skill_name" "$model" "$args"
            log_audit "$ts" "$skill_name" "agent" "OK"
            emit_result "$skill_name" "agent" "OK" "$routing_path" "$model"
            return 0
            ;;
        script+judgment)
            run_script_judgment "$skill_name" "$args"
            log_audit "$ts" "$skill_name" "script+judgment" "OK"
            emit_result "$skill_name" "script+judgment" "OK" "$routing_path"
            return 0
            ;;
        *)
            if [[ "$allow_fallback" == "false" ]]; then
                warn "unknown executor '$executor' for skill '$skill_name'."
                emit_error "$skill_name" "EXEC_FAILED" "unknown executor: $executor"
                emit_result "$skill_name" "unknown" "EXEC_FAILED" "$routing_path"
                log_audit "$ts" "$skill_name" "unknown" "EXEC_FAILED"
                exit 4
            fi
            fallback_to_sonnet "$skill_name" "$args" "$ts" "unknown executor '$executor' for skill '$skill_name'."
            return 0
            ;;
    esac
}

show_list() {
    require_python
    require_catalog
    python3 - "$CATALOG" << 'PYEOF'
import sys, yaml

with open(sys.argv[1]) as f:
    cat = yaml.safe_load(f)

print(f"executor-catalog: {cat['total_entries']} entries  (generated {cat['generated_at']})")
print(f"{'SKILL':<25} {'EXECUTOR':<12} {'DET':<6} SCRIPT_PATH")
print("-" * 80)

by_exec = {}
for e in cat["entries"]:
    ex = e["routing"]["executor"]
    by_exec.setdefault(ex, []).append(e)

for ex in ["script", "haiku", "sonnet", "opus", "mcp-direct", "agent", "script+judgment"]:
    for e in by_exec.get(ex, []):
        r = e["routing"]
        sp = r.get("script_path", "—")
        det = "✓" if r.get("deterministic") else "✗"
        prio = f" [{r['optimization_priority']}]" if "optimization_priority" in r else ""
        print(f"{e['name']:<25} {ex:<12} {det:<6} {sp}{prio}")
PYEOF
}

validate_catalog() {
    require_python
    require_catalog
    python3 - "$CATALOG" << 'PYEOF'
import sys, yaml

VALID = {"script", "haiku", "sonnet", "opus", "mcp-direct", "agent", "script+judgment"}
VALID_AGENT_MODELS = {"haiku", "sonnet", "opus"}
errors = []

with open(sys.argv[1]) as f:
    cat = yaml.safe_load(f)

for e in cat["entries"]:
    r = e["routing"]
    name = e["name"]
    if r.get("executor") not in VALID:
        errors.append(f"{name}: invalid executor '{r.get('executor')}'")
    if "deterministic" not in r:
        errors.append(f"{name}: missing deterministic")
    if r.get("executor") == "script" and "script_path" not in r:
        errors.append(f"{name}: script executor missing script_path")
    if r.get("executor") == "agent" and r.get("model") not in VALID_AGENT_MODELS:
        errors.append(f"{name}: agent executor requires model: haiku|sonnet|opus")

if errors:
    print("FAIL:")
    for e in errors:
        print(f"  ❌ {e}")
    sys.exit(1)
else:
    print(f"PASS: {cat['total_entries']} entries validated, no errors")
PYEOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    local skill_name=""
    local args=""
    local mode="dispatch"
    local allow_fallback="true"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --skill)    skill_name="$2"; allow_fallback="false"; shift 2 ;;
            --tag)      skill_name="$2"; allow_fallback="true";  shift 2 ;;
            --args)     args="$2"; shift 2 ;;
            --list)     mode="list"; shift ;;
            --validate) mode="validate"; shift ;;
            --json)     JSON_MODE="true"; shift ;;
            -h|--help)  mode="help"; shift ;;
            *)          die "unknown option: $1" ;;
        esac
    done

    case "$mode" in
        list)     show_list ;;
        validate) validate_catalog ;;
        help)
            grep "^# " "$0" | head -20 | sed 's/^# //'
            ;;
        dispatch)
            [[ -z "$skill_name" && "$allow_fallback" == "false" ]] && die "required: --skill <name>"
            dispatch_skill "$skill_name" "$args" "$allow_fallback"
            ;;
    esac
}

main "$@"
