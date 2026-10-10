#!/usr/bin/env bash
# issue #1174: detector_decision.sh selected user messages with `.role == "user"`, but
# Claude Code transcript entries carry `"type":"user"` and `.message.role`, so the
# filter matched nothing and the detector never saw a human reply. The filter must
# keep typed human text and drop tool results, meta entries and injected service text.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/.claude/detectors/detector_decision.sh"
command -v jq >/dev/null || { echo "  ⏭ jq not installed, skipped"; exit 0; }
fail=0
check() { if [ "$2" = ok ]; then echo "  ✅ $1"; else echo "  ❌ $1"; fail=1; fi; }

eval "$(sed -n '/^# HUMAN_JQ_BEGIN$/,/^# HUMAN_JQ_END$/p' "$SRC")"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

cat > "$T/t.jsonl" <<'EOF'
{"type":"user","message":{"role":"user","content":"выбираю вариант Б"}}
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"принято, берём второй"}]}}
{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"x","content":"выбираю из вывода"}]}}
{"type":"user","isMeta":true,"message":{"role":"user","content":"мета-вставка"}}
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"Base directory for this skill: /x\n\n# Skill"}]}}
{"type":"user","message":{"role":"user","content":"<system-reminder>служебное</system-reminder>"}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"ответ ассистента"}]}}
{"type":"human","content":"старая форма"}
EOF

out="$(jq -r "$HUMAN_JQ" "$T/t.jsonl")"
[ "$(printf '%s\n' "$out" | grep -c .)" = 3 ] && r=ok || r=bad
check "exactly the 3 typed human messages are kept" "$r"
printf '%s\n' "$out" | grep -qxF 'выбираю вариант Б' && r=ok || r=bad
check "string content of type=user is read" "$r"
printf '%s\n' "$out" | grep -qxF 'принято, берём второй' && r=ok || r=bad
check "text block of type=user is read" "$r"
printf '%s\n' "$out" | grep -qxF 'старая форма' && r=ok || r=bad
check "legacy type=human form still works" "$r"
printf '%s\n' "$out" | grep -qE 'выбираю из вывода|мета-вставка|Base directory|служебное|ответ ассистента' && r=bad || r=ok
check "tool results, meta, service text and assistant text are dropped" "$r"
exit $fail
