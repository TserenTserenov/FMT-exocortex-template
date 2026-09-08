#!/bin/bash
# peer-session-finalize.sh — finalize / interrupt для peer-сессий (DP.SC.154)
# Замена deprecated peer-conversation.sh --finalize / --interrupt
# Работает со структурой скиллов: sessions/YYYY-MM/DD/<id>/
#
# Usage:
#   bash scripts/peer-session-finalize.sh --finalize <session_id>
#   bash scripts/peer-session-finalize.sh --interrupt <session_id>
#   bash scripts/peer-session-finalize.sh --dry-run --finalize <session_id>
#   bash scripts/peer-session-finalize.sh --dry-run --interrupt <session_id>
#   bash scripts/peer-session-finalize.sh --validate <session_id>

set -euo pipefail

IWE_DIR="${IWE_DIR:-$HOME/IWE}"
# Имя governance-репо из окружения: жёстко зашитое ломает файл у пользователя
# шаблона с другим именем репозитория (validator FMT поймал при доставке 03.08).
REPO_DIR="${IWE_DIR}/${IWE_GOVERNANCE_REPO:-DS-strategy}"
SESSIONS_DIR="${REPO_DIR}/sessions"
INDEX_FILE="${SESSIONS_DIR}/00-index.md"

_now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

_usage() {
  echo "Usage: peer-session-finalize.sh --finalize <session_id>"
  echo "       peer-session-finalize.sh --interrupt <session_id>"
  echo "       peer-session-finalize.sh --dry-run --finalize <session_id>"
  echo "       peer-session-finalize.sh --dry-run --interrupt <session_id>"
  echo "       peer-session-finalize.sh --validate <session_id>"
  exit 1
}

DRY_RUN=false
VALIDATE=false
ACTION=""
SESSION_ID=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)   DRY_RUN=true; shift ;;
    --validate)  VALIDATE=true; shift ;;
    --finalize|--interrupt)
      if [[ -n "$ACTION" ]]; then
        echo "❌ Действие уже указано: $ACTION"
        _usage
      fi
      ACTION="$1"; shift
      ;;
    -h|--help) _usage ;;
    -*)
      echo "❌ Неизвестный флаг: $1"
      _usage
      ;;
    *)
      if [[ -n "$SESSION_ID" ]]; then
        echo "❌ SESSION_ID уже указан: $SESSION_ID"
        _usage
      fi
      SESSION_ID="$1"; shift
      ;;
  esac
done

[[ -n "$SESSION_ID" ]] || _usage

_require_peer_session() {
  local meta_file="$1"
  local peer_agent
  local test_subject

  peer_agent="$(grep -E '^peer_agent:' "$meta_file" | head -1 | sed 's/^[^:]*:[[:space:]]*//' | sed 's/"//g' | sed "s/'//g" | tr -d ' ')"
  test_subject="$(grep -E '^test_subject:' "$meta_file" | head -1 | sed 's/^[^:]*:[[:space:]]*//' | sed 's/"//g' | sed "s/'//g" | tr -d ' ')"

  if [[ -n "$test_subject" && "$test_subject" != "~" && "$test_subject" != "null" && ( -z "$peer_agent" || "$peer_agent" == "~" || "$peer_agent" == "null" ) ]]; then
    echo "❌ Это контрольная сессия с test_subject, а не peer-сессия: peer-session-finalize.sh к ней не применяется."
    return 1
  fi

  if [[ -z "$peer_agent" || "$peer_agent" == "~" || "$peer_agent" == "null" ]]; then
    echo "❌ Для peer-сессии отсутствует непустой peer_agent: $meta_file"
    return 1
  fi
}

# --validate: only check meta.yaml, no side effects
if [[ "$VALIDATE" == true ]]; then
  MONTH="$(echo "$SESSION_ID" | cut -c1-7)"
  DAY="$(echo "$SESSION_ID" | cut -c9-10)"
  SESSION_DIR="${SESSIONS_DIR}/${MONTH}/${DAY}/${SESSION_ID}"
  META="${SESSION_DIR}/meta.yaml"

  [[ -d "$SESSION_DIR" ]] || { echo "❌ Сессия не найдена: $SESSION_DIR"; exit 1; }
  [[ -f "$META" ]] || { echo "❌ meta.yaml не найден: $META"; exit 1; }

  ERRORS=0
  _require_field() {
    local field="$1"
    local file="$2"
    if ! grep -qE "^${field}:" "$file"; then
      echo "  ✗ Поле '${field}' отсутствует"
      ERRORS=$((ERRORS + 1))
    else
      local val
      val="$(grep -E "^${field}:" "$file" | head -1 | sed 's/^[^:]*:[[:space:]]*//' | sed 's/"//g' | sed "s/'//g" | tr -d ' ')"
      if [[ -z "$val" || "$val" == "~" || "$val" == "null" ]]; then
        echo "  ✗ Поле '${field}' пустое"
        ERRORS=$((ERRORS + 1))
      else
        echo "  ✓ ${field}: ${val}"
      fi
    fi
  }

  echo "📋 Валидация meta.yaml: $META"
  _require_peer_session "$META" || exit 2
  _require_field "session_id" "$META"
  _require_field "start_time" "$META"
  _require_field "status" "$META"
  _require_field "writer_agent" "$META"

  # bug-2026-07-10 (Day Close, PRODSYNC2-round5-session): агент буквально
  # написал в meta.yaml незаполненный shell-плейсхолдер вместо реального
  # времени ("2026-07-10T$(date +%H:%M:%SZ)") — YAML не выполняет команды,
  # значение попало в файл как есть и молча ломало любой пересчёт
  # длительности сессии. Ловим любой `$(` в start_time/end_time до записи.
  for field in start_time end_time; do
    val="$(grep -E "^${field}:" "$META" | head -1)"
    if [[ "$val" == *'$('* ]]; then
      echo "  ✗ Поле '${field}' содержит неразвёрнутый shell-плейсхолдер: ${val}"
      ERRORS=$((ERRORS + 1))
    fi
  done

  # bug-2026-07-10: два meta.yaml в этой же папке за 10.07 содержали
  # start_time позже end_time (ручной ввод времени, не программный) —
  # portит расчёт мультипликатора дня (Day Close §6). Сравнение строк ISO
  # 8601 с одинаковым форматом безопасно и без внешних зависимостей.
  start_val="$(grep -E '^start_time:' "$META" | head -1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '"'"'"' ')"
  end_val="$(grep -E '^end_time:' "$META" | head -1 | sed 's/^[^:]*:[[:space:]]*//' | tr -d '"'"'"' ')"
  if [[ -n "$start_val" && -n "$end_val" && "$start_val" != *'$('* && "$end_val" != *'$('* ]]; then
    if [[ "$end_val" < "$start_val" ]]; then
      echo "  ✗ end_time ($end_val) раньше start_time ($start_val)"
      ERRORS=$((ERRORS + 1))
    fi
  fi

  if (( ERRORS > 0 )); then
    echo "❌ Валидация не пройдена: $ERRORS ошибок"
    exit 1
  fi
  echo "✅ Валидация пройдена"
  exit 0
fi

# Validate action for non-validate modes
[[ -n "$ACTION" ]] || _usage

MONTH="$(echo "$SESSION_ID" | cut -c1-7)"
DAY="$(echo "$SESSION_ID" | cut -c9-10)"
SESSION_DIR="${SESSIONS_DIR}/${MONTH}/${DAY}/${SESSION_ID}"
META="${SESSION_DIR}/meta.yaml"

[[ -d "$SESSION_DIR" ]] || { echo "❌ Сессия не найдена: $SESSION_DIR"; exit 1; }
[[ -f "$META" ]] || { echo "❌ meta.yaml не найден: $META"; exit 1; }
_require_peer_session "$META" || exit 2

end_time="$(_now_iso)"
turns_count=$(find "$SESSION_DIR" -maxdepth 1 -name "[0-9][0-9]-*.md" | wc -l | tr -d ' ')

# --- INTERRUPT ---
if [[ "$ACTION" == "--interrupt" ]]; then
  tmpf="$(mktemp)"
  sed "s/^status:.*/status: interrupted/" "$META" |
    sed "s/^end_time:.*/end_time: \"${end_time}\"/" |
    sed "s/^turns_count:.*/turns_count: ${turns_count}/" > "$tmpf"
  if [[ "$DRY_RUN" == true ]]; then
    echo "[DRY-RUN] Обновлю $META: status=interrupted, end_time=${end_time}, turns_count=${turns_count}"
    rm "$tmpf"
  else
    mv "$tmpf" "$META"
  fi

  # Update index: status → interrupted, report → —
  if [[ -f "$INDEX_FILE" ]]; then
    tmpf="$(mktemp)"
    awk -v id="$SESSION_ID" '
      $0 ~ id {
        gsub(/\| (started|completed|interrupted) \|/, "| interrupted |")
        gsub(/\| \[?report\.md[^|]*\|/, "| — |")
        # If no report link column, ensure last column is —
        if ($0 !~ /\| — \| *$/) { sub(/\| *$/, "| — |") }
        print
        next
      }
      { print }
    ' "$INDEX_FILE" > "$tmpf"
    if [[ "$DRY_RUN" == true ]]; then
      echo "[DRY-RUN] Обновлю $INDEX_FILE: статус прерван, report удалён"
      rm "$tmpf"
    else
      mv "$tmpf" "$INDEX_FILE"
    fi
  fi

  if [[ "$DRY_RUN" == true ]]; then
    echo "[DRY-RUN] Сессия $SESSION_ID была бы прервана."
  else
    echo "✅ Сессия $SESSION_ID прервана."
  fi
  exit 0
fi

# --- FINALIZE ---
if [[ "$ACTION" == "--finalize" ]]; then
  [[ -f "${SESSION_DIR}/00-writer.md" ]] || { echo "❌ Нет реплик в сессии"; exit 1; }

  writer_agent="$(grep "^writer_agent:" "$META" | sed 's/^writer_agent: *//; s/"//g' | tr -d "'")"

  # Choose adapter based on writer_agent
  if [[ "$writer_agent" == "kimi-headless" ]]; then
    ADAPTER="${REPO_DIR}/scripts/kimi-peer-adapter.sh"
  else
    ADAPTER="${REPO_DIR}/scripts/claude-peer-adapter.sh"
  fi

  report_file="${SESSION_DIR}/report.md"

  if [[ "$DRY_RUN" == true ]]; then
    echo "[DRY-RUN] Синтезирую report.md через $ADAPTER (пропущено в dry-run)"
  else
    # Synthesize report via Python (safe prompt handling)
    python3 - "$SESSION_DIR" "$META" "$report_file" "$ADAPTER" <<'PYEOF'
import sys, os, glob, subprocess, datetime

session_dir, meta_path, report_file, adapter = sys.argv[1:5]

# Read meta
meta = {}
with open(meta_path, encoding='utf-8') as f:
    for line in f:
        if ':' in line and not line.strip().startswith('#'):
            k, v = line.split(':', 1)
            meta[k.strip()] = v.strip().strip('"').strip("'")

task_desc = meta.get('task_description', '')
writer_agent = meta.get('writer_agent', '')
start_time = meta.get('start_time', '')
escalations_count = meta.get('escalations_count', '0')
session_id = meta.get('session_id', '')

# Gather turns
turn_files = sorted(glob.glob(os.path.join(session_dir, '[0-9][0-9]-*.md')))
turns_text = ''
for tf in turn_files:
    fname = os.path.basename(tf)
    with open(tf, encoding='utf-8') as f:
        body = f.read()
    turns_text += f'\n\n=== {fname} ===\n{body}'

synth_prompt = f"""Ты — синтезатор итогов диалога двух агентов (DP.SC.154).

Задача сессии: {task_desc}

Ниже — полная стенограмма диалога (реплики в порядке ходов):
{turns_text}

Напиши итоговый report.md строго по формату ниже. Соблюдай инвариант: при result_class: agreed раздел §4 непустой; при not-agreed — литерал «Консенсус не достигнут». Не оборачивай вывод в ```markdown ... ``` — пиши markdown напрямую.

---
schema_version: 1
session_id: {session_id}
generated_at: {datetime.datetime.utcnow().isoformat()}Z
writer: {writer_agent}
peer: <из meta.yaml: peer_agent>
duration_min: <вычислить: (end_time − start_time) в минутах, целое>
escalations_count: {escalations_count}
result_class: agreed | partial | escalated | not-agreed
confidence: low | med | high
confidence_basis: <обязателен, если confidence <= med; иначе omit>
ttl_event: <«до merge PR-NNN» | «до WP-NNN» | «до отмены пилотом» | omit>
cost_usd: <если известно; иначе omit>
cost_source: api | estimated | missing
---

# Итоговый отчёт

## 1. Исходная постановка
- **Задача:** <цитата из задания пилота, дословно>
- **Первоначальная позиция писателя:** <если зафиксирована в 00-writer.md; omit, если нет>

## 2. Позиции по темам
Под каждой темой (критерий существенности: затронута обеими сторонами и повлияла на итог):

**Тема N: <короткая формулировка>**
- Инициатор: писатель | напарник
- **Писатель:** тезис → обоснование → якорь (file:line-range / Pack-ID, обязателен для код-ссылок и внешних фактов)
- **Напарник:** тезис → обоснование → якорь
- Эволюция (опц.): если кто-то сменил позицию — указать ход и причину
- Разрешение: что приняли + чей аргумент перевесил

## 3. Отвергнутые альтернативы
Omit, если пусто. Фильтр: только альтернативы, аргументированные обеими сторонами ИЛИ отвергнутые с явным контраргументом.
- Альтернатива → причина отказа → ссылка на ход

## 4. Зафиксированное решение
- <Исполняемая формулировка> [synthesized]
- **Главный аргумент:** <одной строкой — почему именно это>
- **Confidence:** low | med | high (если ≤ med — обоснование обязательно)
- **TTL-event:** <привязка к событию или omit>

Инвариант: при result_class: agreed раздел непустой; при not-agreed — «Консенсус не достигнут».

## 5. Открытые вопросы и эскалации
Omit, если пусто. Единый список:
- <Вопрос или эскалация>
- Статус: needs-decision | needs-verification | deferred
- Ссылка: escalation-NN.md или NN-peer.md (если есть)

## 6. Метаданные и навигация
- **Журнал:** ссылки на все NN-writer.md / NN-peer.md по порядку
- **Связанные артефакты:** Pack-IDs, файлы (PR, спецификации) — если упоминались
- **Стоимость:** $X (источник: api / estimated / missing) — omit, если cost_source: missing
"""

# Write prompt to temp file and feed to adapter
import tempfile
with tempfile.NamedTemporaryFile(mode='w', suffix='.txt', delete=False, encoding='utf-8') as tmp:
    tmp.write(synth_prompt)
    tmp_path = tmp.name

# synth_prompt above already inlines the full transcript into stdin — neither
# adapter needs --add-dir to synthesize, and claude-peer-adapter.sh
# unconditionally rejects it (exit 64, WP-458 contract: text-only reviewer,
# no file access), which made every synthesis call through this path fail
# whenever ADAPTER resolved to claude-peer-adapter.sh (writer_agent !=
# "kimi-headless"). Same bug as kimi-peer-writer/SKILL.md's synthesis step,
# found independently by Codex re-auditing that fix — this script is a
# separate finalize path, not covered by that first pass. stderr is now
# captured (not discarded) so a future regression leaves a real diagnostic
# in the fallback stub instead of the same generic guess every time.
stderr_path = tmp_path + '.err'
try:
    with open(tmp_path, 'r', encoding='utf-8') as stdin_f, \
         open(report_file, 'w', encoding='utf-8') as stdout_f, \
         open(stderr_path, 'w', encoding='utf-8') as stderr_f:
        result = subprocess.run(
            ['bash', adapter],
            stdin=stdin_f,
            stdout=stdout_f,
            stderr=stderr_f
        )
finally:
    os.unlink(tmp_path)

if result.returncode != 0 or os.path.getsize(report_file) == 0:
    stderr_tail = ''
    if os.path.exists(stderr_path):
        with open(stderr_path, encoding='utf-8') as f:
            stderr_tail = f.read()[-2000:]
        os.unlink(stderr_path)
    now = datetime.datetime.utcnow().isoformat() + 'Z'
    with open(report_file, 'w', encoding='utf-8') as f:
        f.write(f"""---
session_id: {session_id}
generated_at: {now}
note: синтез не выполнен (субагент недоступен)
---

# Итоговый отчёт

Стенограмма диалога: см. файлы реплик в папке сессии.
Повтори синтез: `bash scripts/peer-session-finalize.sh --finalize {session_id}`

## Диагностика (stderr адаптера, для отладки — не для пилота)

```
returncode: {result.returncode}
{stderr_tail if stderr_tail else '(stderr пуст)'}
```
""")
    sys.exit(1)
elif os.path.exists(stderr_path):
    os.unlink(stderr_path)
PYEOF
  fi

  # Update meta.yaml
  tmpf="$(mktemp)"
  sed "s/^status:.*/status: \"completed\"/" "$META" |
    sed "s/^end_time:.*/end_time: \"${end_time}\"/" |
    sed "s/^turns_count:.*/turns_count: ${turns_count}/" > "$tmpf"
  if [[ "$DRY_RUN" == true ]]; then
    echo "[DRY-RUN] Обновлю $META: status=completed, end_time=${end_time}, turns_count=${turns_count}"
    rm "$tmpf"
  else
    mv "$tmpf" "$META"
  fi

  # Update index
  if [[ -f "$INDEX_FILE" ]]; then
    tmpf="$(mktemp)"
    awk -v id="$SESSION_ID" -v link="[report.md](${MONTH}/${DAY}/${SESSION_ID}/report.md)" '
      $0 ~ id {
        gsub(/\| (started|interrupted) \|/, "| completed |")
        gsub(/\| — \|/, "| " link " |")
        print
        next
      }
      { print }
    ' "$INDEX_FILE" > "$tmpf"
    if [[ "$DRY_RUN" == true ]]; then
      echo "[DRY-RUN] Обновлю $INDEX_FILE: статус завершён, report.md добавлен"
      rm "$tmpf"
    else
      mv "$tmpf" "$INDEX_FILE"
    fi
  fi

  if [[ "$DRY_RUN" == true ]]; then
    echo "[DRY-RUN] Сессия $SESSION_ID была бы завершена. Отчёт: $report_file"
  else
    echo "✅ Сессия $SESSION_ID завершена. Отчёт: $report_file"
  fi
  exit 0
fi

echo "❌ Неизвестное действие: $ACTION"
_usage
