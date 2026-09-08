#!/bin/bash
# claude-hook: false — библиотека-диспетчер для event-specific wrappers и тестов
# rule-engine.sh — единый диспатчер правил агента (WP-272 Ф1)
#
# Входы (env vars):
#   RULE_EVENT — событие триггер (task_received, wp_create_attempt, response_emitted, ...)
#   RULE_CONTEXT — JSON-контекст события (response, file_path, command, ...)
#
# Выход (stdout JSON):
#   {"verdict": "block|warn|ok", "rule_id": "AR.NNN", "reason": "...", "applied_rules": [...]}
#
# Использование (как hook): event-specific обёртки делают source этого файла и вызывают
# dispatch_event. Прямой запуск тоже доступен — для тестов.
#
# REGISTRY: ~/IWE/.claude/rules-registry.yaml (генерируется из PACK-agent-rules/)

set -uo pipefail
umask 077

REGISTRY="${RULE_REGISTRY:-$HOME/IWE/.claude/rules-registry.yaml}"
JOURNAL_DIR="${RULE_JOURNAL_DIR:-$HOME/logs/rule-engine}"
mkdir -p "$JOURNAL_DIR"
JOURNAL_FILE="$JOURNAL_DIR/$(date +%Y-%m-%d).jsonl"

# Session-state: per-session warn/block log (WP-272 Ф5)
SESSION_ID="${CLAUDE_SESSION_ID:-default}"
SESSION_STATE_DIR="$HOME/.claude/state"
mkdir -p "$SESSION_STATE_DIR" 2>/dev/null || true
SESSION_WARN_LOG="$SESSION_STATE_DIR/session-${SESSION_ID}-warns.jsonl"

# === Утилиты ===

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
    # WP-272 Ф1 fix (R23 audit #4): ensure_ascii=False для читаемости в логах
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
    # Session-state: сохранить warn/block в per-session лог для summary при Close (WP-272 Ф5)
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

# === Загрузка реестра ===
# Парсим YAML через python (yaml stdlib не имеет в bash)
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

# === Чек-функции для конкретных правил ===
# Каждое правило AR.NNN имеет свой check_<name>. Вызывается диспатчером.

check_wp_gate() {
    # AR.001: проверить, есть ли согласие пользователя на новый РП
    # RULE_CONTEXT может содержать {"file_path": "inbox/WP-NNN-*.md", "wp_number": N, "user_consent": bool}
    local ctx="${RULE_CONTEXT:-}"
    [ -z "$ctx" ] && ctx='{}'
    local consent
    # WP-272 Ф1 fix (R23 audit #1): try/except — невалидный JSON не должен ронять traceback
    consent=$(echo "$ctx" | python3 -c '
import sys, json
try:
    d = json.loads(sys.stdin.read() or "{}")
    print(str(d.get("user_consent", False)).lower())
except (json.JSONDecodeError, ValueError):
    print("parse_error")
' 2>/dev/null)
    if [ "$consent" = "parse_error" ]; then
        emit_verdict "warn" "AR.001" "RULE_CONTEXT не распарсился как JSON — fail-safe block; проверить вызывающий код"
    elif [ "$consent" = "true" ]; then
        emit_verdict "ok" "AR.001" "user consent confirmed in dialog"
    else
        emit_verdict "block" "AR.001" "WP Gate Ритуал не закрыт: нет явного согласия пользователя на создание нового РП"
    fi
}

check_autonomy() {
    # AR.002: проверить, содержит ли ответ агента yes/no запрос подтверждения
    # RULE_CONTEXT: {"response_text": "..."}
    local resp
    resp=$(echo "${RULE_CONTEXT:-}" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("response_text", ""))' 2>/dev/null)

    # Простая regex-проверка (Ф1). В Ф2 заменится на Haiku R23 классификатор.
    # Сначала проверяем choice-question (исключение) — раньше чем yes/no
    if echo "$resp" | grep -qE 'или\s+[А-Яа-яA-Za-z0-9]+\?'; then
        emit_verdict "ok" "AR.002" "exception: choice_question detected"
        return
    fi

    # Yes/no запрос подтверждения
    if echo "$resp" | grep -qE 'ОК\?|применить\?|продолжить\?|записать\?|хотите\?|добавить\?|подтвер|Согласовываем'; then
        emit_verdict "warn" "AR.002" "yes/no запрос подтверждения обнаружен — проверить exceptions (wp_gate_ritual, choice_question, quoted_question_in_analysis)"
    else
        emit_verdict "ok" "AR.002" "no permission requests detected"
    fi
}

check_arch_gate() {
    # AR.003: архитектурное решение → /archgate ПЕРЕД финализацией
    local ctx="${RULE_CONTEXT:-}"
    [ -z "$ctx" ] && ctx='{}'
    local file_path
    file_path=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("file_path",""))' 2>/dev/null)

    # Создание нового Pack → ArchGate обязателен
    if echo "$file_path" | grep -qE '/PACK-[^/]+/(00-pack-manifest|pack-manifest)'; then
        emit_verdict "warn" "AR.003" "создание нового Pack — ArchGate обязателен ДО начала (CLAUDE.md §5). Запусти /archgate → ЭМОГССБ профиль"
        return
    fi
    # new_system_creation (крупная система) → ArchGate обязателен
    local event="${RULE_EVENT:-}"
    if [[ "$event" == "new_system_creation" ]]; then
        local archgate_done
        archgate_done=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(str(d.get("archgate_done",False)).lower())' 2>/dev/null)
        if [ "$archgate_done" != "true" ]; then
            emit_verdict "warn" "AR.003" "создание новой системы без /archgate — запусти /archgate ДО реализации (CLAUDE.md §5, DP.ARCH.001 §7)"
            return
        fi
    fi
    # new_tool_creation — IntegrationGate (AR.013) достаточен, ArchGate только если сложная архитектура
    # arch_decision_attempt — всегда проверяем
    if [[ "$event" == "arch_decision_attempt" ]]; then
        emit_verdict "warn" "AR.003" "архитектурное решение — /archgate ПЕРЕД финализацией (CLAUDE.md §5)"
        return
    fi
    emit_verdict "ok" "AR.003" "arch gate N/A for this event (${event})"
}

check_push() {
    # AR.004: «заливай»/«запуши» → commit + push без доп. вопросов
    # Post-condition check (WP-295 Ф5): emits push-state JSON for journal
    emit_verdict "ok" "AR.004" "push trigger — proceed: commit + push без подтверждения"
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
    # WP-295 Ф5: ${IWE_GOVERNANCE_REPO:-DS-strategy} has no uncommitted changes at Close time.
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
    # WP-295 Ф5: ORZ session file for today exists and has a non-empty # Главный инсайт section.
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
    if LC_ALL=en_US.UTF-8 awk '/^#{1,2} Главный инсайт/{found=1; next} found && /[^[:space:]]/{print; exit}' "$orz_file" | grep -q .; then
        printf '{"check":"orz_filled","result":"ok","detail":"%s"}\n' "$orz_file"
    else
        printf '{"check":"orz_filled","result":"warn","detail":"ORZ file exists but # Главный инсайт section is empty: %s"}\n' "$orz_file"
    fi
}

_check_pushed() {
    # WP-295 Ф5: verifies ${IWE_GOVERNANCE_REPO:-DS-strategy} has no unpushed commits (all commits reached the remote).
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
    # WP-295 Ф5: deterministic post-condition checks on Close event (on_fail: warn).
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
    # AR.005: Close-триггер → протокол закрытия
    local ctx="${RULE_CONTEXT:-}"
    [ -z "$ctx" ] && ctx='{}'
    local has_changes
    has_changes=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(str(d.get("has_uncommitted_changes",False)).lower())' 2>/dev/null)
    if [ "$has_changes" = "true" ]; then
        emit_verdict "warn" "AR.005" "Close-триггер с незакоммиченными изменениями — запусти /run-protocol close (CLAUDE.md §2 п.3)"
        return
    fi

    # WP-295 Ф5: post-condition checks (deterministic, on_fail: warn)
    local pc_result pc_verdict pc_detail
    pc_result=$(_run_postconditions_for_close)
    pc_verdict=$(echo "$pc_result" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read())["result"])' 2>/dev/null)
    if [ "$pc_verdict" = "warn" ]; then
        pc_detail=$(echo "$pc_result" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read())["detail"])' 2>/dev/null)
        emit_verdict "warn" "AR.005" "Close post-condition: $pc_detail"
        return
    fi

    emit_verdict "ok" "AR.005" "Close-триггер — запусти /run-protocol close"
}

check_pull_on_touch() {
    # AR.006: первая модификация репо → git pull --rebase
    local ctx="${RULE_CONTEXT:-}"
    [ -z "$ctx" ] && ctx='{}'
    local repo pull_done
    repo=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("repo",""))' 2>/dev/null)
    pull_done=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(str(d.get("pull_done",False)).lower())' 2>/dev/null)
    if [ "$pull_done" = "true" ]; then
        emit_verdict "ok" "AR.006" "git pull --rebase уже выполнен для $repo"
    else
        emit_verdict "warn" "AR.006" "первая модификация в репо ${repo:-?} — выполни git pull --rebase ДО коммита (CLAUDE.md §2 п.4)"
    fi
}

check_checklist_verification() {
    # AR.007: Quick Close / Day Close → sub-agent Haiku R23 (если сессия ≥15 мин и есть изменения файлов)
    local ctx="${RULE_CONTEXT:-}"
    [ -z "$ctx" ] && ctx='{}'
    local verification_done files_changed
    verification_done=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(str(d.get("r23_verification_done",False)).lower())' 2>/dev/null)
    files_changed=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(str(d.get("files_changed",True)).lower())' 2>/dev/null)
    if [ "$files_changed" = "false" ]; then
        emit_verdict "ok" "AR.007" "нет изменений файлов — R23 верификация не требуется"
        return
    fi
    if [ "$verification_done" = "true" ]; then
        emit_verdict "ok" "AR.007" "R23 верификация пройдена"
    else
        emit_verdict "warn" "AR.007" "Close-попытка без R23 верификации — запусти sub-agent Haiku R23 (context isolation) ДО отчёта закрытия (CLAUDE.md §2 п.5)"
    fi
}

# === AR.012-014, AR.101-106, AR.200-202: check-функции (WP-272 Ф5.4) ===

check_priority_gate() {
    # AR.012: РП с budget ≥ 3h → должен быть явный R{N}
    local ctx="${RULE_CONTEXT:-}"
    [ -z "$ctx" ] && ctx='{}'
    local budget r_goal
    budget=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("budget_h",0))' 2>/dev/null)
    r_goal=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("r_goal",""))' 2>/dev/null)
    local verification_class
    verification_class=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("verification_class",""))' 2>/dev/null)

    # open-loop всегда требует R{N}
    local needs_r=false
    if python3 -c "import sys; exit(0 if float('$budget') >= 3 else 1)" 2>/dev/null; then
        needs_r=true
    fi
    [ "$verification_class" = "open-loop" ] && needs_r=true

    if $needs_r; then
        if [ -z "$r_goal" ] || ! echo "$r_goal" | grep -qE 'R[0-9]+'; then
            emit_verdict "warn" "AR.012" "РП с budget=${budget}h (или open-loop) без явного R{N} — к какому результату недели ведёт? Добавь поле r_goal: R{N} во frontmatter (CLAUDE.md §2 Priority Gate)"
            return
        fi
    fi
    emit_verdict "ok" "AR.012" "priority gate OK (budget=${budget}h r_goal=${r_goal})"
}

_classify_integration_phase() {
    # Субагент-классификатор фазы IntegrationGate (AR.013).
    # Принимает JSON-контекст как $1; возвращает JSON через integration-gate-classifier.py.
    local classifier="$HOME/IWE/.claude/scripts/integration-gate-classifier.py"
    [ ! -f "$classifier" ] && echo '{"phase":"unknown","skip_detected":false,"reason":"classifier script missing","missing":[]}' && return
    local ctx_arg="${1:-{}}"
    _IG_CTX="$ctx_arg" python3 "$classifier" 2>/dev/null || echo '{"phase":"unknown","skip_detected":false,"reason":"classifier error","missing":[]}'
}

check_integration_gate() {
    # AR.013: создание нового инструмента/агента/системы → обещание → сценарии → роль → реализация.
    # Использует _classify_integration_phase() — субагент-классификатор фазы (хэвристика без LLM).
    local ctx="${RULE_CONTEXT:-}"
    [ -z "$ctx" ] && ctx='{}'

    local creation_type file_path
    creation_type=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("creation_type",""))' 2>/dev/null)
    file_path=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("file_path",""))' 2>/dev/null)

    # Быстрый путь: file_path — SC-артефакт (08-service-clauses) → правильная фаза, не warn
    if echo "$file_path" | grep -qE '08-service-clauses|DP\.SC\.[0-9]+'; then
        emit_verdict "ok" "AR.013" "IntegrationGate: файл = SC-артефакт (обещание-фаза) — последовательность соблюдена"
        return
    fi
    # Быстрый путь: file_path — Role-артефакт (02-domain-entities/DP.ROLE) → правильная фаза
    if echo "$file_path" | grep -qE 'DP\.ROLE\.[0-9]+'; then
        emit_verdict "ok" "AR.013" "IntegrationGate: файл = Role-артефакт (роль-фаза) — последовательность соблюдена"
        return
    fi

    # Запускаем классификатор фазы
    local phase_result
    phase_result=$(_classify_integration_phase "$ctx")

    local skip_detected missing_str
    skip_detected=$(echo "$phase_result" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(str(d.get("skip_detected",False)).lower())' 2>/dev/null)
    missing_str=$(echo "$phase_result" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(", ".join(d.get("missing",[])))' 2>/dev/null)

    local phase
    phase=$(echo "$phase_result" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("phase","unknown"))' 2>/dev/null)

    # Классификатор определил фазу явно (не unknown) — доверяем его решению
    if [ "$phase" != "unknown" ]; then
        if [ "$skip_detected" = "true" ] && [ -n "$missing_str" ]; then
            emit_verdict "warn" "AR.013" "IntegrationGate: создание нового ${creation_type:-инструмента/агента} — пропуск фазы impl без [${missing_str}]. Последовательность: обещание → сценарии → роль → реализация. Пропуск = P10 (DP.FM.010)"
            return
        fi
        emit_verdict "ok" "AR.013" "IntegrationGate: phase=${phase}, skip_detected=false — последовательность соблюдена"
        return
    fi

    # Fallback: классификатор вернул phase=unknown → проверяем явные ссылки SC/Role в контексте
    local sc_ref role_ref scenarios_defined
    sc_ref=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("sc_ref",""))' 2>/dev/null)
    role_ref=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("role_ref",""))' 2>/dev/null)
    scenarios_defined=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(str(d.get("scenarios_defined",False)).lower())' 2>/dev/null)

    local missing=()
    [ -z "$sc_ref" ] && missing+=("DP.SC.NNN (обещание)")
    [ "$scenarios_defined" != "true" ] && [ -z "$sc_ref" ] && missing+=("сценарии использования")
    [ -z "$role_ref" ] && missing+=("DP.ROLE.NNN (роль)")

    if [ "${#missing[@]}" -gt 0 ]; then
        local fallback_missing
        fallback_missing=$(IFS=', '; echo "${missing[*]}")
        emit_verdict "warn" "AR.013" "IntegrationGate: создание нового ${creation_type:-инструмента/агента} без ${fallback_missing} — последовательность: обещание → сценарии → роль → реализация (CLAUDE.md §2 IntegrationGate). Пропуск = P10 (DP.FM.010)"
        return
    fi
    emit_verdict "ok" "AR.013" "IntegrationGate: SC + сценарии + Role присутствуют"
}

check_legacy_port_gate() {
    # AR.014: замена legacy-компонента → сначала 15-мин субагент «как работает сейчас»
    local ctx="${RULE_CONTEXT:-}"
    [ -z "$ctx" ] && ctx='{}'
    local legacy_component subagent_done
    legacy_component=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("legacy_component",""))' 2>/dev/null)
    subagent_done=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(str(d.get("subagent_research_done",False)).lower())' 2>/dev/null)

    if [ "$subagent_done" = "true" ]; then
        emit_verdict "ok" "AR.014" "LegacyPortGate: субагент-исследование проведено для ${legacy_component:-компонента}"
        return
    fi
    emit_verdict "warn" "AR.014" "LegacyPortGate: замена ${legacy_component:-legacy-компонента} без субагент-исследования — запусти 15-мин субагент «как работает сейчас?» ДО проектирования (CLAUDE.md §2 LegacyPortGate). Пропуск = DP.FM.014"
}

check_snapshot_before_action() {
    # AR.101: миграция/DDL/bulk → snapshot ПЕРЕД действием
    local ctx="${RULE_CONTEXT:-}"
    [ -z "$ctx" ] && ctx='{}'
    local command snapshot_done
    command=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("command",""))' 2>/dev/null)
    snapshot_done=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(str(d.get("snapshot_done",False)).lower())' 2>/dev/null)

    # Паттерны опасных операций
    local is_dangerous=false
    if echo "$command" | grep -qiE '(ALTER TABLE|DROP TABLE|CREATE TABLE|TRUNCATE|DELETE FROM|UPDATE .* WHERE|INSERT INTO .* SELECT|COPY .* FROM|pg_restore|pg_dump.*restore|rm -rf|find .* -exec rm)'; then
        is_dangerous=true
    fi

    $is_dangerous || { emit_verdict "ok" "AR.101" "snapshot gate N/A (команда не DDL/migration/bulk-delete)"; return; }

    if [ "$snapshot_done" = "true" ]; then
        emit_verdict "ok" "AR.101" "snapshot сделан ДО action — OK"
    else
        emit_verdict "warn" "AR.101" "DDL/migration/bulk-delete без предварительного snapshot — выполни \\dt / SELECT COUNT(*) / find ПЕРЕД действием (feedback_behaviour Правило 1b, WP-183 incident)"
    fi
}

check_incident_diagnosis() {
    # AR.102: инцидент → проверить ВСЕ backends ПЕРЕД гипотезами
    local ctx="${RULE_CONTEXT:-}"
    [ -z "$ctx" ] && ctx='{}'
    local backends_checked hypothesis_count
    backends_checked=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(str(d.get("all_backends_checked",False)).lower())' 2>/dev/null)
    hypothesis_count=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("hypothesis_count",0))' 2>/dev/null)

    if [ "$backends_checked" != "true" ] && python3 -c "exit(0 if int('${hypothesis_count:-0}') > 0 else 1)" 2>/dev/null; then
        emit_verdict "warn" "AR.102" "сформированы гипотезы без проверки ВСЕХ backends — сначала вызвать каждый backend через другого клиента, потом гипотезы (feedback_behaviour Правило 8, WP-183: 1.5h на ложных гипотезах)"
        return
    fi
    if [ "$backends_checked" = "true" ]; then
        emit_verdict "ok" "AR.102" "все backends проверены — OK"
    else
        emit_verdict "warn" "AR.102" "incident diagnosis: проверь ВСЕ backends (logs + DB + queue + cache) через независимый клиент ДО формирования гипотез"
    fi
}

check_memory_drift() {
    # AR.103: Day Close / Quick Close → обновить memory если есть Capture-маркеры
    local ctx="${RULE_CONTEXT:-}"
    [ -z "$ctx" ] && ctx='{}'
    local captures_pending memory_updated
    captures_pending=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(str(d.get("captures_pending",False)).lower())' 2>/dev/null)
    memory_updated=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(str(d.get("memory_updated",False)).lower())' 2>/dev/null)

    if [ "$captures_pending" = "true" ] && [ "$memory_updated" != "true" ]; then
        emit_verdict "warn" "AR.103" "есть Capture-маркеры в сессии — обнови memory ДО следующего Day Open (feedback_behaviour Правило 9). «Обновить в Day Close» = задача, не намерение"
        return
    fi
    emit_verdict "ok" "AR.103" "memory drift: нет pending captures или memory уже обновлена"
}

check_systemic_review() {
    # AR.104: «системный фикс» / «root cause» → независимый ревью ДО отчёта
    local ctx="${RULE_CONTEXT:-}"
    [ -z "$ctx" ] && ctx='{}'
    local response_text review_done
    response_text=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("response_text",""))' 2>/dev/null)
    review_done=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(str(d.get("independent_review_done",False)).lower())' 2>/dev/null)

    local claims_systemic=false
    # WP-272 ревизия 2026-04-30: требуется маркер завершения; описание ("фикс закрывает X") без done-маркера не триггер
    if echo "$response_text" | grep -qiE '(системный фикс|systemic fix|архитектурн.* решен|не костыль).*(done|готов|завершен|выполнен|закрыт|✅|DONE)'; then
        claims_systemic=true
    elif echo "$response_text" | grep -qiE '(root cause).*(done|готов|завершен|решён|устранён|fix.?complete)'; then
        claims_systemic=true
    fi

    $claims_systemic || { emit_verdict "ok" "AR.104" "systemic review N/A (нет заявки на системный фикс)"; return; }

    if [ "$review_done" = "true" ]; then
        emit_verdict "ok" "AR.104" "независимый ревью проведён — OK"
    else
        emit_verdict "warn" "AR.104" "заявка на «системный фикс» / «root cause» без независимого ревью — запусти Agent(haiku, R23) ДО финального отчёта (feedback_behaviour Правило 13)"
    fi
}

check_rebrand_e2e() {
    # AR.106: изменение display identity → end-to-end retest в реальном клиенте
    local ctx="${RULE_CONTEXT:-}"
    [ -z "$ctx" ] && ctx='{}'
    local file_path retest_done
    file_path=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("file_path",""))' 2>/dev/null)
    retest_done=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(str(d.get("e2e_retest_done",False)).lower())' 2>/dev/null)

    # Проверяем display identity паттерны в файле
    local is_display_identity=false
    case "$file_path" in
        */serverInfo*|*/oauth_client*|*/tool_descriptions*|*index.ts|*/get_instructions*) is_display_identity=true ;;
    esac
    if [ -f "$file_path" ]; then
        grep -qiE '(serverInfo\.name|client_name|display_name|name.*Aisystant|name.*IWE|name.*Gateway)' "$file_path" 2>/dev/null && is_display_identity=true
    fi

    $is_display_identity || { emit_verdict "ok" "AR.106" "rebrand gate N/A (не display identity файл)"; return; }

    if [ "$retest_done" = "true" ]; then
        emit_verdict "ok" "AR.106" "end-to-end retest в реальном клиенте пройден — OK"
    else
        emit_verdict "warn" "AR.106" "изменение display identity без end-to-end retest — ОБЯЗАТЕЛЕН ручной тест в реальном клиенте: «как называется сервис?», OAuth consent screen, connector label (feedback_behaviour Правило 20, WP-259 incident)"
    fi
}

check_formal_vs_content() {
    # AR.200: «DONE»/«выполнено» — реально ли отвечает на исходный вопрос?
    local ctx="${RULE_CONTEXT:-}"
    [ -z "$ctx" ] && ctx='{}'
    local response_text
    response_text=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("response_text",""))' 2>/dev/null)

    if echo "$response_text" | grep -qiE '(DONE|выполнено|завершено|закрыто|✅ DONE|WP .* закрыт)'; then
        emit_verdict "warn" "AR.200" "заявка «DONE» — проверь: результат отвечает на исходный вопрос или на упрощённую версию? Для БД: SELECT COUNT(*) + sample на целевой схеме/таблице ДО «DONE» (distinctions: Формальное ≠ содержательное)"
        return
    fi
    emit_verdict "ok" "AR.200" "formal-vs-content N/A"
}

check_owner_integrity() {
    # AR.201: один факт — одно место; дублирование Pack↔DS = ошибка
    local ctx="${RULE_CONTEXT:-}"
    [ -z "$ctx" ] && ctx='{}'
    local target_path source_type
    target_path=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("target_path",""))' 2>/dev/null)
    source_type=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("source_type",""))' 2>/dev/null)

    # Доменное знание записывается в DS → нарушение
    if echo "$target_path" | grep -qE '/DS-[^/]+/' && [ "$source_type" = "domain_knowledge" ]; then
        emit_verdict "warn" "AR.201" "доменное знание записывается в DS-репо — domain knowledge → Pack (не DS). OwnerIntegrity: один факт = одно место (distinctions)"
        return
    fi
    # Реализационное решение записывается в Pack → нарушение
    if echo "$target_path" | grep -qE '/PACK-[^/]+/' && [ "$source_type" = "implementation" ]; then
        if echo "$target_path" | grep -qiE '\.(sh|ts|py|js)$'; then
            emit_verdict "warn" "AR.201" "реализационный файл (.sh/.ts/.py) в Pack — implementation → DS, Pack только доменное (DP.KR.001 §5.2)"
            return
        fi
    fi
    emit_verdict "ok" "AR.201" "owner integrity OK"
}

check_log_incident_state() {
    # AR.202: лог / инцидент / state-file → правильное место
    local ctx="${RULE_CONTEXT:-}"
    [ -z "$ctx" ] && ctx='{}'
    local file_path
    file_path=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("file_path",""))' 2>/dev/null)
    [ -z "$file_path" ] && { emit_verdict "ok" "AR.202" "no file_path"; return; }

    # Инциденты → правильное место если: (a) в /incidents/ поддиректории любого репо, или (b) в governance-репо
    # WP-272 ревизия 2026-04-30: incidents/ в любом репо = корректное размещение (FP: DS-MCP/.../incidents/ → ok)
    if echo "$file_path" | grep -qiE '(incident|инцидент)'; then
        if echo "$file_path" | grep -qE '/incidents/'; then
            emit_verdict "ok" "AR.202" "инцидент-файл в /incidents/ директории — корректное размещение"
            return
        fi
        if ! echo "$file_path" | grep -qE 'DS-[^/]+-strategy/|DS-ecosystem-development/'; then
            emit_verdict "warn" "AR.202" "инцидент-файл вне /incidents/ директории и вне governance-репо — стандартное место: <repo>/incidents/YYYY-MM-DD-*.md (distinctions: Лог ≠ Инцидент ≠ State file)"
            return
        fi
    fi
    # State-файлы (*.json, *.state) в governance-репо → нарушение
    if echo "$file_path" | grep -qE '\.(json|state)$'; then
        if echo "$file_path" | grep -qE '${IWE_GOVERNANCE_REPO:-DS-strategy}/' && ! echo "$file_path" | grep -qE '/(inbox|current|archive)/'; then
            emit_verdict "warn" "AR.202" "state-файл в governance-репо вне inbox/current/archive — state files рядом с исполнителем, не в strategy-хабе"
            return
        fi
    fi
    emit_verdict "ok" "AR.202" "log/incident/state routing OK"
}

# === WP-272 Ф5.1: реализованные check-функции (5 наиболее критичных) ===

check_security_gate() {
    # AR.011: PII / payment_credentials / secrets в file_path + content_snippet
    local ctx="${RULE_CONTEXT:-}"
    [ -z "$ctx" ] && ctx='{}'

    local file_path content
    file_path=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("file_path",""))' 2>/dev/null)
    content=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("content_snippet",""))' 2>/dev/null)

    # Проверяем только если есть контент для анализа
    if [ -z "$content" ] && [ -n "$file_path" ] && [ -f "$file_path" ]; then
        content=$(head -100 "$file_path" 2>/dev/null || true)
    fi
    [ -z "$content" ] && { emit_verdict "ok" "AR.011" "no content to analyze"; return; }

    # Паттерны логирования PII (строки с logger/print/console.log + PII-термины)
    if echo "$content" | grep -qiE '(logger|print|console\.log|logging\.)\.*.*telegram_id'; then
        emit_verdict "block" "AR.011" "PII в log statement: telegram_id обнаружен в logging-вызове — заменить на account_id"
        return
    fi
    if echo "$content" | grep -qiE '(logger|print|console\.log|logging\.).*email'; then
        emit_verdict "warn" "AR.011" "email в log statement — проверь: является ли PII (если да — block, заменить на account_id/хеш)"
        return
    fi

    # payment_credentials в открытом виде (payment_method_id в любом контексте строго запрещено логировать)
    if echo "$content" | grep -qiE '(logger|print|console\.log).*payment_method_id'; then
        emit_verdict "block" "AR.011" "payment_credentials в log statement: payment_method_id — запрещено даже маскированное логирование"
        return
    fi

    # Secrets в git-tracked файлах (не в .env)
    if echo "$file_path" | grep -qvE '\.(env|gitignore|example)$'; then
        if echo "$content" | grep -qiE '(sk_live_|pk_live_|napi_[a-zA-Z0-9]{30}|Authorization.*Bearer [a-zA-Z0-9+/]{20})'; then
            emit_verdict "block" "AR.011" "secret в tracked-файле: API ключ обнаружен вне .env/.gitignore — перенести в env vars"
            return
        fi
    fi

    # API keys в не-.env файлах
    if echo "$content" | grep -qiE '(password\s*=\s*["\x27][^"\x27]{8,})'; then
        if ! echo "$file_path" | grep -qE '\.(env|example|test|spec)'; then
            emit_verdict "warn" "AR.011" "hardcoded password обнаружен — проверь, не secret ли (перенести в env если да)"
            return
        fi
    fi

    emit_verdict "ok" "AR.011" "no PII/payment/secret violations detected"
}

check_sc_gate() {
    # AR.008: user-facing path должен иметь ссылку на DP.SC.NNN
    local ctx="${RULE_CONTEXT:-}"
    [ -z "$ctx" ] && ctx='{}'

    local file_path
    file_path=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("file_path",""))' 2>/dev/null)
    [ -z "$file_path" ] && { emit_verdict "ok" "AR.008" "no file_path in context"; return; }

    # Проверяем только user-facing пути
    local is_user_facing=false
    case "$file_path" in
        */handlers/*.py|*/routes/*.ts|*/tools/*.ts|*/api/*|*/subscriptions/tariffs*)
            is_user_facing=true ;;
    esac

    if ! $is_user_facing; then
        emit_verdict "ok" "AR.008" "not a user-facing path, SC gate N/A"
        return
    fi

    # Проверить наличие DP.SC.NNN ссылки в файле
    if [ -f "$file_path" ]; then
        if grep -qE 'DP\.SC\.[0-9]+' "$file_path" 2>/dev/null; then
            emit_verdict "ok" "AR.008" "SC reference found in file"
        else
            emit_verdict "warn" "AR.008" "user-facing файл без DP.SC.NNN ссылки — какое обещание затронуто? Создай/обнови SC в 08-service-clauses/"
        fi
    else
        # Новый файл — напоминание создать SC
        emit_verdict "warn" "AR.008" "новый user-facing файл — убедись, что DP.SC.NNN создан/обновлён в 08-service-clauses/"
    fi
}

check_routing_gate() {
    # AR.009: новый файл должен соответствовать карте маршрутизации DP.KR.001 §5
    local ctx="${RULE_CONTEXT:-}"
    [ -z "$ctx" ] && ctx='{}'

    local target_path is_new
    target_path=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("target_path",""))' 2>/dev/null)
    is_new=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(str(d.get("is_new_file",False)).lower())' 2>/dev/null)

    [ -z "$target_path" ] && { emit_verdict "ok" "AR.009" "no target_path in context"; return; }
    # Если файл существует — не новый, routing gate N/A
    [ -f "$target_path" ] && { emit_verdict "ok" "AR.009" "file exists, routing gate N/A (edit, not create)"; return; }
    [ "$is_new" = "false" ] && { emit_verdict "ok" "AR.009" "not a new file write"; return; }

    # Known-patterns whitelist
    case "$target_path" in
        */rules/AR.[0-9]*.md|*/inbox/*.md|*/fleeting-notes.md) emit_verdict "ok" "AR.009" "known pattern (rules/inbox)"; return ;;
        */WeekPlan*.md|*/DayPlan*.md|*/Strategy.md) emit_verdict "ok" "AR.009" "known pattern (governance)"; return ;;
        */.claude/rules-registry.yaml|*/rules-registry.yaml) emit_verdict "ok" "AR.009" "known pattern (generated registry)"; return ;;
        */extraction-reports/*.md|*/drafts/*.md|*/archive/*) emit_verdict "ok" "AR.009" "known pattern (workspace artifacts)"; return ;;
    esac

    # Heuristic риски
    if echo "$target_path" | grep -qiE '/(health|log|incident).*\.(json|csv|log)$'; then
        emit_verdict "warn" "AR.009" "health/log в FS — DP.KR.001 §5.7: должно быть в БД #8 или рядом с исполнителем"
        return
    fi

    if echo "$target_path" | grep -q '/PACK-' && echo "$target_path" | grep -qiE '\.(sh|ts|py|js)$'; then
        emit_verdict "warn" "AR.009" "файл реализации (.sh/.ts/.py) в Pack-директории — DP.KR.001 §5.2: реализация → DS, Pack только доменное"
        return
    fi

    emit_verdict "warn" "AR.009" "новый файл не совпал с known-patterns — проверь DP.KR.001 §5 (полная карта маршрутизации)"
}

check_schema_registration_gate() {
    # AR.234: создание новой кодовой схемы/реестра → чеклист дизайна осей DP.METHOD.054 §5.
    # ADR-IWE-020: membership живёт в schema-triggers.yaml (один источник, два потребителя).
    # Уровень — E3-prompted: review (мягкий nudge), не block. Корректность дизайна осей
    # машина не судит — поднимает вопрос ДО фиксации, пока у агента есть design-контекст.
    local ctx="${RULE_CONTEXT:-}"
    [ -z "$ctx" ] && ctx='{}'

    local target_path
    target_path=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("target_path",""))' 2>/dev/null)
    [ -z "$target_path" ] && { emit_verdict "ok" "AR.234" "no target_path in context"; return; }

    # Exception: существующий файл = экземпляр/edit/rename, не новая схема → AR.211/AR.233
    [ -f "$target_path" ] && { emit_verdict "ok" "AR.234" "file exists — экземпляр/edit, не новая схема (AR.211/AR.233)"; return; }

    # is_in_scope: тот же конфиг, что читает обёртка-хук (single-source membership)
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
        emit_verdict "warn" "AR.234" "Новая кодовая схема (${target_path}) — заполни DP.METHOD.054 §5 ДО фиксации: owner (Registration Authority)? ось ортогональна/взаимоисключающа? bounded_context (namespace)? enforcement_mechanism (E0-E3)? §8: новый реестр = запись в registry-catalog.yaml + namespace в реестре нумераций"
        return
    fi
    if [ "$in_scope" = "error" ]; then
        # fail-open: nudge advisory, не должен блокировать работу при битом конфиге
        emit_verdict "ok" "AR.234" "schema-triggers.yaml unreadable — fail-open (nudge пропущен)"
        return
    fi
    emit_verdict "ok" "AR.234" "target не схема-файл по schema-triggers.yaml"
}

check_repo_touch_gate() {
    # AR.010: при первом касании репо — проверить CLAUDE.md на «обязательно загружай»
    # WP-272 Ф5.3: добавлена READ-ONLY защита (tool_name + sub-path check)
    local ctx="${RULE_CONTEXT:-}"
    [ -z "$ctx" ] && ctx='{}'

    local tool_arg tool_name session_id
    tool_arg=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("tool_arg",""))' 2>/dev/null)
    tool_name=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("tool_name",""))' 2>/dev/null)
    session_id=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("session_id",""))' 2>/dev/null)
    [ -z "$session_id" ] && session_id="${CLAUDE_SESSION_ID:-default}"

    [ -z "$tool_arg" ] && { emit_verdict "ok" "AR.010" "no tool_arg in context"; return; }

    # READ-ONLY: проверить ДО session-state (блокировать даже повторные касания)
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
                        emit_verdict "block" "AR.010" "READ-ONLY репо ${ro} — ${tool_name} запрещён (CLAUDE.md §9). Только чтение."
                        return ;;
                esac
                # Read и прочие операции — разрешены; выходим из цикла, идём дальше
                break
            fi
        done
    fi

    # Извлекаем имя репо (верхний уровень) для session-state
    local repo=""
    if [[ "$tool_arg" =~ $HOME/IWE/([^/]+)/ ]]; then
        repo="${BASH_REMATCH[1]}"
    elif [[ "$tool_arg" =~ /IWE/([^/]+)/ ]]; then
        repo="${BASH_REMATCH[1]}"
    fi
    [ -z "$repo" ] && { emit_verdict "ok" "AR.010" "path outside ~/IWE/, gate N/A"; return; }

    # Проверяем state-файл: уже ли был touch этого репо
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

    # Первое касание — отметить и проверить CLAUDE.md
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

    if grep -qE '(ОБЯЗАТЕЛЬНО ЗАГРУЖАЙ|обязательно загружай|load on touch)' "$claudemd" 2>/dev/null; then
        emit_verdict "warn" "AR.010" "первое касание репо $repo — CLAUDE.md содержит блок «ОБЯЗАТЕЛЬНО ЗАГРУЖАЙ», загрузить указанные файлы ДО ответа"
    else
        emit_verdict "ok" "AR.010" "first touch repo $repo — CLAUDE.md checked, no mandatory-load block"
    fi
}

check_entry_point() {
    # AR.105: при Edit index.*/main.*/app.* — напомнить проверить конфиг entry point
    local ctx="${RULE_CONTEXT:-}"
    [ -z "$ctx" ] && ctx='{}'

    local target_path
    target_path=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("target_path",""))' 2>/dev/null)
    [ -z "$target_path" ] && { emit_verdict "ok" "AR.105" "no target_path in context"; return; }

    local basename
    basename=$(basename "$target_path")

    # Триггерится только на entry-point паттерны
    case "$basename" in
        index.*|main.*|app.*) ;;
        *) emit_verdict "ok" "AR.105" "not an entry-point filename pattern"; return ;;
    esac

    # Найти конфиги в репо
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
        emit_verdict "warn" "AR.105" "Edit ${basename} — проверь что это реальный entry point. Конфиги в репо: ${hint_str}"
    else
        emit_verdict "ok" "AR.105" "no config files found, proceeding without entry-point check"
    fi
}

check_auto_verify_code() {
    # AR.107: после изменения .py/.ts/.sh файлов — напомнить запустить sub-agent R23 ДО коммита
    local ctx="${RULE_CONTEXT:-}"
    [ -z "$ctx" ] && ctx='{}'

    local changed_files
    changed_files=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(" ".join(d.get("changed_files",[])))' 2>/dev/null)

    if echo "$changed_files" | grep -qE '\.(py|ts|sh|js|go|rb)($| )'; then
        emit_verdict "warn" "AR.107" "Код изменён (.py/.ts/.sh) — запусти sub-agent R23 (Haiku) ДО коммита: PASS → коммит; FAIL → фикс"
        return
    fi
    emit_verdict "ok" "AR.107" "no code files changed, verification not required"
}

check_script_errors() {
    # AR.108: при обнаружении ошибок в выводе скрипта — диагностировать и поднимать немедленно
    local ctx="${RULE_CONTEXT:-}"
    [ -z "$ctx" ] && ctx='{}'

    local script_output
    script_output=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("script_output",""))' 2>/dev/null)
    local exit_code
    exit_code=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("exit_code","0"))' 2>/dev/null)

    if [ "$exit_code" != "0" ] && [ -n "$exit_code" ]; then
        emit_verdict "warn" "AR.108" "Скрипт завершился с exit=${exit_code} — диагностировать причину и сообщить ПЕРЕД продолжением"
        return
    fi
    if echo "$script_output" | grep -qiE '(^ERROR|^FAIL|error:|fail:|exception:|duplicate|дубликат|Traceback|panic:|CRITICAL)'; then
        emit_verdict "warn" "AR.108" "Ошибка в выводе скрипта — диагностировать первопричину и предложить фикс ПЕРЕД следующим шагом"
        return
    fi
    emit_verdict "ok" "AR.108" "no error signals in script output"
}

check_domain_question_pack() {
    # AR.109: доменный вопрос (IWE/FPF/Pack-терминология) → искать в Pack до использования общих знаний
    local ctx="${RULE_CONTEXT:-}"
    [ -z "$ctx" ] && ctx='{}'

    local question
    question=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("question",""))' 2>/dev/null)
    [ -z "$question" ] && { emit_verdict "ok" "AR.109" "no question in context"; return; }

    if echo "$question" | grep -qiE '(IWE|FPF|ZP|PACK|DP\.|AR\.|DS-|[Рр]оль|различен|субагент|верификатор|оркестратор|[Пп]ортной|[Оо]ценщик|скилл|протокол|ОРЗ)'; then
        emit_verdict "warn" "AR.109" "Доменный вопрос — искать ответ в Pack (DS→Pack→Base) ДО использования общих знаний модели"
        return
    fi
    emit_verdict "ok" "AR.109" "question does not appear domain-specific"
}

check_instruction_deviation() {
    # AR.110: намеренное отклонение от буквальной инструкции — обязательно уведомить
    local ctx="${RULE_CONTEXT:-}"
    [ -z "$ctx" ] && ctx='{}'

    local deviation_detected
    deviation_detected=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(str(d.get("deviation_detected","false")).lower())' 2>/dev/null)

    if [ "$deviation_detected" = "true" ]; then
        emit_verdict "warn" "AR.110" "Отклонение от инструкции пользователя — уведомить явно: что сделано, почему отличается от буквального"
        return
    fi
    emit_verdict "ok" "AR.110" "no deviation signal in context"
}

check_release_verification_trigger() {
    # AR.203: version bump update-manifest.json или staged изменение в release scope → 5-layer verify
    local ctx="${RULE_CONTEXT:-}"
    [ -z "$ctx" ] && ctx='{}'

    local file_path staged_files
    file_path=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("file_path","") or d.get("target_path",""))' 2>/dev/null)
    staged_files=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(" ".join(d.get("staged_files",[])))' 2>/dev/null)

    # Собираем все пути для проверки
    local all_paths="$file_path $staged_files"

    # Release scope паттерны (из AR.203 applies_when)
    local in_scope=false
    if echo "$all_paths" | grep -qE 'update-manifest\.json'; then
        in_scope=true
    elif echo "$all_paths" | grep -qE '/(roles|\.claude|setup|memory|extensions|seed)/'; then
        in_scope=true
    elif echo "$all_paths" | grep -qE 'FMT-exocortex-template/(roles|\.claude|setup|memory|extensions|seed|update-manifest)'; then
        in_scope=true
    fi

    $in_scope || { emit_verdict "ok" "AR.203" "not in FMT release scope"; return; }

    # Проверить, выполнена ли верификация
    local verification_done
    verification_done=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(str(d.get("release_verification_done",False)).lower())' 2>/dev/null)

    if [ "$verification_done" = "true" ]; then
        emit_verdict "ok" "AR.203" "release verification выполнена — OK"
    else
        emit_verdict "warn" "AR.203" "изменение в FMT release scope ($(echo "$all_paths" | tr ' ' '\n' | grep -E 'update-manifest|/(roles|\.claude|setup|memory|extensions|seed)/' | head -1 | xargs basename 2>/dev/null || echo 'scope file')) — запусти 5-слойную верификацию ДО push: pre-commit + CI + upgrade-test + detector regression + adversarial (VR.M.006, AR.203)"
    fi
}

check_secret_in_chat() {
    # AR.111: секрет/API-key в чате — блокировать запрос, при получении — rotation-алерт
    local ctx="${RULE_CONTEXT:-}"
    [ -z "$ctx" ] && ctx='{}'

    local chat_content
    chat_content=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(d.get("user_message","") + " " + d.get("tool_input",""))' 2>/dev/null)

    local secret_request
    secret_request=$(echo "$ctx" | python3 -c 'import sys,json; d=json.loads(sys.stdin.read() or "{}"); print(str(d.get("secret_request","false")).lower())' 2>/dev/null)

    # Активный паттерн секрета в тексте (postgres:// и postgresql://, пароль ≥4 символа)
    if echo "$chat_content" | grep -qE '(napi_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9]{20,}|ghp_[A-Za-z0-9]{20,}|postgre(s|sql)://[^@:]+:[^@]{4,}@|-----BEGIN (PRIVATE|RSA) KEY-----|Bearer eyJ[A-Za-z0-9._-]{50,})'; then
        emit_verdict "block" "AR.111" "Секрет в чате — считать скомпрометированным: revoke → новый → cascade rotation по всем точкам использования"
        return
    fi
    # Запрос плейнтекстного секрета
    if [ "$secret_request" = "true" ]; then
        emit_verdict "warn" "AR.111" "Запрос значения секрета — передавать через ссылку на источник (.secrets/, env var name), не плейнтекстом"
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
    # AR.216: git add -A / -u / . — запрещено; использовать явные пути
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
        emit_verdict "warn" "AR.216" "Обнаружен git add -A/./u — запрещено (захватывает файлы других агентов). Стейдж только конкретные файлы: git add <path>. CRITICAL rule из AGENTS.md"
        return
    fi

    emit_verdict "ok" "AR.216" "git staging scope OK"
}

# === Диспатчер ===

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

    # Применяем правила в порядке priority (sorted в load_rules_for_event)
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

        # Block перевешивает warn перевешивает ok
        if [ "$verdict" = "block" ]; then
            final_verdict="block"
            final_rule="$rule_id"
            final_reason=$(echo "$result" | python3 -c 'import sys,json; print(json.loads(sys.stdin.read())["reason"])')
            break  # priority-sorted, первый block — финальный
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
        # WP-272 Ф5: вывод warn/block за текущую сессию для Close-протокола
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
# Дедупликация по rule_id (оставляем уникальные)
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
        # Очистить session warn-log (после Close)
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
            echo "ERROR: python3 с библиотекой PyYAML не найден (pip install pyyaml)" >&2
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
        # WP-272 ревизия 2026-04-30: тесты пишут в отдельный журнал, не в production
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
            RULE_EVENT="response_emitted" RULE_CONTEXT='{"response_text":"Метод ОК?"}'
        run_test 4 "choice question in response → ok" "ok" \
            RULE_EVENT="response_emitted" RULE_CONTEXT='{"response_text":"Делаем X или Y?"}'

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

        # AR.010 Repo-Touch Gate — READ-ONLY block (WP-272 Ф5.3)
        # Configure IWE_READONLY_REPOS="DS-sample/repo-a,DS-sample/repo-b" to activate
        run_test 11 "Edit в readonly repo → block (IWE_READONLY_REPOS set)" "block" \
            IWE_READONLY_REPOS="DS-sample/readonly-repo" \
            RULE_EVENT="first_repo_action" \
            RULE_CONTEXT="{\"tool_arg\":\"$HOME/IWE/DS-sample/readonly-repo/sample.py\",\"tool_name\":\"Edit\",\"session_id\":\"test-ro-1\"}"
        run_test 12 "Write в readonly repo → block (IWE_READONLY_REPOS set)" "block" \
            IWE_READONLY_REPOS="DS-sample/readonly-repo" \
            RULE_EVENT="first_repo_action" \
            RULE_CONTEXT="{\"tool_arg\":\"$HOME/IWE/DS-sample/readonly-repo/README.md\",\"tool_name\":\"Write\",\"session_id\":\"test-ro-2\"}"

        # AR.012 Priority Gate (WP-272 Ф5.4)
        run_test 13 "РП budget=8h без R{N} → warn" "warn" \
            RULE_EVENT="wp_creation_with_budget_attempt" \
            RULE_CONTEXT='{"budget_h":8,"r_goal":"","verification_class":"closed-loop"}'
        run_test 14 "РП budget=1h → ok (мелкая задача)" "ok" \
            RULE_EVENT="wp_creation_with_budget_attempt" \
            RULE_CONTEXT='{"budget_h":1,"r_goal":"","verification_class":"closed-loop"}'

        # AR.013 IntegrationGate
        run_test 15 "новый инструмент без SC + Role → warn (P10)" "warn" \
            RULE_EVENT="new_tool_creation" \
            RULE_CONTEXT='{"creation_type":"hook","sc_ref":"","role_ref":"","scenarios_defined":false}'
        run_test 16 "новый инструмент с SC + Role → ok" "ok" \
            RULE_EVENT="new_tool_creation" \
            RULE_CONTEXT='{"creation_type":"hook","sc_ref":"DP.SC.125","role_ref":"DP.ROLE.042","scenarios_defined":true}'

        # AR.101 Snapshot Before Action
        run_test 17 "ALTER TABLE без snapshot → warn" "warn" \
            RULE_EVENT="ddl_attempt" \
            RULE_CONTEXT='{"command":"ALTER TABLE finance.payments ADD COLUMN x INT","snapshot_done":false}'
        run_test 18 "ALTER TABLE со snapshot → ok" "ok" \
            RULE_EVENT="ddl_attempt" \
            RULE_CONTEXT='{"command":"ALTER TABLE finance.payments ADD COLUMN x INT","snapshot_done":true}'

        # AR.104 Systemic Fix Review
        # WP-272 ревизия 2026-04-30: теперь требуется done-маркер; описание без done = не триггер
        run_test 19 "системный фикс DONE без ревью → warn" "warn" \
            RULE_EVENT="systemic_fix_completion" \
            RULE_CONTEXT='{"response_text":"системный фикс закрывает root cause — DONE","independent_review_done":false}'
        run_test 20 "обычное завершение без заявки → ok" "ok" \
            RULE_EVENT="systemic_fix_completion" \
            RULE_CONTEXT='{"response_text":"правка файла конфига","independent_review_done":false}'
        run_test 20 "описание фикса без done-маркера → ok (FP-защита)" "ok" \
            RULE_EVENT="systemic_fix_completion" \
            RULE_CONTEXT='{"response_text":"системный фикс закрывает root cause","independent_review_done":false}'

        # AR.202 Log/Incident/State routing
        # WP-272 ревизия 2026-04-30: incidents/ в любом репо = ok; warn только если вне /incidents/ AND вне governance
        run_test 21 "инцидент в /incidents/ поддиректории → ok (корректное место)" "ok" \
            RULE_EVENT="incident_creation_attempt" \
            RULE_CONTEXT="{\"file_path\":\"$HOME/IWE/DS-sample/sample-service/incidents/incident-001.md\"}"
        run_test 21 "инцидент вне /incidents/ и вне governance → warn" "warn" \
            RULE_EVENT="incident_creation_attempt" \
            RULE_CONTEXT="{\"file_path\":\"$HOME/IWE/DS-sample/sample-service/src/incident-001.md\"}"
        run_test 22 "инцидент в ${IWE_GOVERNANCE_REPO:-DS-strategy} → ok" "ok" \
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
        run_test 25 "изменён .py файл → warn (verify before commit)" "warn" \
            RULE_EVENT="code_change_with_files" \
            RULE_CONTEXT='{"changed_files":["src/main.py","config.yaml"]}'
        run_test 26 "только .md изменён → ok (no verify needed)" "ok" \
            RULE_EVENT="code_change_with_files" \
            RULE_CONTEXT='{"changed_files":["README.md","docs/guide.md"]}'

        # AR.108 Script Errors Surface
        run_test 27 "скрипт exit=1 → warn (diagnose first)" "warn" \
            RULE_EVENT="script_error_detected" \
            RULE_CONTEXT='{"script_output":"Some output","exit_code":"1"}'
        run_test 28 "скрипт exit=0, нет ошибок → ok" "ok" \
            RULE_EVENT="script_error_detected" \
            RULE_CONTEXT='{"script_output":"All done successfully","exit_code":"0"}'

        # AR.111 Secret In Chat
        run_test 29 "PostgreSQL URL с паролем в чате → block" "block" \
            RULE_EVENT="secret_in_chat_detected" \
            RULE_CONTEXT='{"user_message":"postgresql://user:supersecretpass123@ep-xyz.neon.tech/db","tool_input":""}'
        run_test 30 "обычное сообщение → ok (no secret)" "ok" \
            RULE_EVENT="secret_in_chat_detected" \
            RULE_CONTEXT='{"user_message":"запусти psql и покажи таблицы","tool_input":""}'

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
        run_test 31 "impl без SC/Role → warn (phase skip)" "warn" \
            RULE_EVENT="new_tool_creation" \
            RULE_CONTEXT="{\"creation_type\":\"hook\",\"file_path\":\"$HOME/IWE/DS-MCP/src/new-tool.ts\",\"sc_ref\":\"\",\"role_ref\":\"\",\"scenarios_defined\":false}"
        run_test 32 "SC-фаза (создание DP.SC файла) → ok" "ok" \
            RULE_EVENT="new_tool_creation" \
            RULE_CONTEXT="{\"creation_type\":\"hook\",\"file_path\":\"$HOME/IWE/PACK-digital-platform/pack/digital-platform/08-service-clauses/DP.SC.125.md\",\"sc_ref\":\"\",\"role_ref\":\"\",\"scenarios_defined\":false}"

        # AR.203 Release Verification Trigger (WP-272 Ф5)
        run_test 33 "изменение update-manifest.json → warn (verify before push)" "warn" \
            RULE_EVENT="version_bump_in_update_manifest_json" \
            RULE_CONTEXT='{"file_path":"${IWE:-$HOME/IWE}/FMT-exocortex-template/update-manifest.json","release_verification_done":false}'
        run_test 34 "изменение roles/ в FMT scope → warn" "warn" \
            RULE_EVENT="staged_files_in_validator_scope" \
            RULE_CONTEXT='{"staged_files":["${IWE:-$HOME/IWE}/FMT-exocortex-template/roles/R.001.md"],"release_verification_done":false}'
        run_test 35 "верификация выполнена → ok" "ok" \
            RULE_EVENT="version_bump_in_update_manifest_json" \
            RULE_CONTEXT='{"file_path":"${IWE:-$HOME/IWE}/FMT-exocortex-template/update-manifest.json","release_verification_done":true}'
        run_test 36 "файл вне FMT release scope → ok (N/A)" "ok" \
            RULE_EVENT="version_bump_in_update_manifest_json" \
            RULE_CONTEXT='{"file_path":"${IWE:-$HOME/IWE}/${IWE_GOVERNANCE_REPO:-DS-strategy}/inbox/notes.md","release_verification_done":false}'

        # AR.234 Schema Registration Gate (ADR-IWE-020)
        run_test 37 "новый *-catalog.yaml (в scope, не существует) → warn (дизайн осей)" "warn" \
            RULE_EVENT="schema_registration_attempt" \
            RULE_CONTEXT='{"target_path":"/tmp/iwe-dogfood-foo-catalog.yaml","is_new_file":true}'
        run_test 38 "новый не-схема файл (.md) → ok (вне scope)" "ok" \
            RULE_EVENT="schema_registration_attempt" \
            RULE_CONTEXT='{"target_path":"/tmp/iwe-dogfood-notes.md","is_new_file":true}'
        run_test 39 "существующий registry-файл → ok (экземпляр/edit, не новая схема)" "ok" \
            RULE_EVENT="schema_registration_attempt" \
            RULE_CONTEXT="{\"target_path\":\"$HOME/IWE/.claude/rules-registry.yaml\",\"is_new_file\":false}"

        # AR.234 dogfood: живость membership-конфига (ADR-IWE-020 §5 — анти-молчаливая-смерть).
        # Проверяет: (1) schema-triggers.yaml читается; (2) fired_event совпадает с triggers AR.234 в реестре.
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
            echo "PASS Test 40: dogfood — schema-triggers.yaml жив, fired_event совпадает с AR.234.triggers"
            PASS=$((PASS+1))
        else
            echo "FAIL Test 40: dogfood — $DOGFOOD"
            FAIL=$((FAIL+1))
        fi

        echo ""
        echo "=== Results: $PASS PASS / $FAIL FAIL (total $((PASS+FAIL))) ==="
        [ "$FAIL" -eq 0 ] && exit 0 || exit 1
        ;;
    *)
        echo "Usage: rule-engine.sh {dispatch|list-rules|test|session-summary|session-clear}"
        echo "  dispatch     — process event (use RULE_EVENT + RULE_CONTEXT env vars)"
        echo "  list-rules   — show all rules in registry"
        echo "  test         — run smoke tests (WP-271 incident simulation)"
        exit 1
        ;;
esac
