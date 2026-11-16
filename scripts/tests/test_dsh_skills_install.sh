#!/usr/bin/env bash
# install-dsh-skills.sh connects <workspace>/.claude/skills to DeepSeek Harness
# through the home-level DSH patch layer ($DSH_HOME/cordis.patch.yml), because
# DSH scans .dsh/skills and .agents/skills and never .claude/skills.
#
# Observed facts covered here:
#   1. DSH not installed (no $DSH_HOME/profiles) — exit 0, nothing is created,
#      no $HOME/.dsh appears on a machine without DSH.
#   2. Fresh DSH — the patch file is created and holds the skill-filesystem
#      entry with customSkillDirs pointing at the workspace skills.
#   3. Second run changes nothing (byte-identical file), so update.sh may call
#      the script on every upgrade.
#   4. When the user already set customSkillDirs (profile layer) the file is
#      left untouched and the run says so — the user's choice wins.
#   5. --dry-run writes nothing.
#   6. Missing --workspace is a usage error (exit 1).
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$(cd "$TESTS_DIR/../.." && pwd)/setup/install-dsh-skills.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok()  { echo "  ✅ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ❌ $1 — fact: ${2:-no data}"; FAIL=$((FAIL + 1)); }

[ -f "$SCRIPT" ] || { echo "  ❌ FAIL: нет $SCRIPT"; exit 1; }

# A workspace with skills and one without; DSH homes start empty.
mk_workspace() {
    local ws="$1"
    mkdir -p "$ws/.claude/skills/day-open"
    printf -- '---\nname: day-open\ndescription: test\n---\n' > "$ws/.claude/skills/day-open/SKILL.md"
}
mk_dsh() {
    local home="$1" profile="$2"
    mkdir -p "$home/profiles/$profile"
    printf -- '[]\n' > "$home/profiles/$profile/cordis.patch.yml"
}

# --- 1. DSH not installed ---------------------------------------------------
WS="$WORK/ws1"
mk_workspace "$WS"
DSH="$WORK/dsh1"
out=$(bash "$SCRIPT" --workspace "$WS" --dsh-home "$DSH" 2>&1)
status=$?
[ "$status" -eq 0 ] && ok "DSH отсутствует: код 0" || bad "DSH отсутствует: код $status"
[ ! -e "$DSH" ] && ok "DSH отсутствует: каталог не создан" || bad "DSH отсутствует: каталог создан"

# --- 2. Fresh DSH: entry appears -------------------------------------------
WS="$WORK/ws2"
mk_workspace "$WS"
DSH="$WORK/dsh2"
mk_dsh "$DSH" web
out=$(bash "$SCRIPT" --workspace "$WS" --dsh-home "$DSH" 2>&1)
status=$?
[ "$status" -eq 0 ] && ok "чистая установка: код 0" || bad "чистая установка: код $status ($out)"
PATCH="$DSH/cordis.patch.yml"
[ -f "$PATCH" ] && ok "чистая установка: файл слоя создан" || bad "чистая установка: файла нет"
grep -q 'id: skill-filesystem' "$PATCH" 2>/dev/null \
    && ok "чистая установка: запись skill-filesystem есть" || bad "чистая установка: записи нет"
grep -qF -- "$WS/.claude/skills" "$PATCH" 2>/dev/null \
    && ok "чистая установка: путь к навыкам записан" || bad "чистая установка: пути нет"
# The entry must parse as YAML with the documented shape, not just look right.
if command -v python3 >/dev/null 2>&1; then
    python3 - "$PATCH" "$WS/.claude/skills" <<'PY' && ok "чистая установка: YAML разбирается, customSkillDirs верный" || bad "чистая установка: YAML не разбирается"
import sys, yaml
data = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
assert isinstance(data, list) and len(data) == 1, data
assert data[0]["id"] == "skill-filesystem", data
assert data[0]["config"]["customSkillDirs"] == [sys.argv[2]], data
PY
fi

# --- 3. Idempotent ----------------------------------------------------------
before=$(cksum "$PATCH")
out=$(bash "$SCRIPT" --workspace "$WS" --dsh-home "$DSH" 2>&1)
status=$?
after=$(cksum "$PATCH")
[ "$status" -eq 0 ] && ok "повторный запуск: код 0" || bad "повторный запуск: код $status"
[ "$before" = "$after" ] && ok "повторный запуск: файл не изменился" || bad "повторный запуск: файл переписан"
[ "$(grep -c 'id: skill-filesystem' "$PATCH")" = "1" ] \
    && ok "повторный запуск: запись одна" || bad "повторный запуск: записей больше одной"

# --- 4. User already configured customSkillDirs -----------------------------
WS="$WORK/ws4"
mk_workspace "$WS"
DSH="$WORK/dsh4"
mk_dsh "$DSH" web
printf -- '- id: skill-filesystem\n  config:\n    customSkillDirs:\n      - /opt/user/skills\n' \
    > "$DSH/profiles/web/cordis.patch.yml"
profile_before=$(cksum "$DSH/profiles/web/cordis.patch.yml")
out=$(bash "$SCRIPT" --workspace "$WS" --dsh-home "$DSH" 2>&1)
status=$?
[ "$status" -eq 0 ] && ok "чужой customSkillDirs: код 0 (не ошибка)" || bad "чужой customSkillDirs: код $status"
[ ! -f "$DSH/cordis.patch.yml" ] && ok "чужой customSkillDirs: домашний слой не создан" || bad "чужой customSkillDirs: слой создан"
[ "$profile_before" = "$(cksum "$DSH/profiles/web/cordis.patch.yml")" ] \
    && ok "чужой customSkillDirs: профильный слой не тронут" || bad "чужой customSkillDirs: профиль изменён"
printf '%s' "$out" | grep -q 'customSkillDirs уже задан' \
    && ok "чужой customSkillDirs: сказано словами" || bad "чужой customSkillDirs: молчит"

# --- 5. Dry run -------------------------------------------------------------
WS="$WORK/ws5"
mk_workspace "$WS"
DSH="$WORK/dsh5"
mk_dsh "$DSH" web
out=$(bash "$SCRIPT" --workspace "$WS" --dsh-home "$DSH" --dry-run 2>&1)
status=$?
[ "$status" -eq 0 ] && ok "dry-run: код 0" || bad "dry-run: код $status"
[ ! -f "$DSH/cordis.patch.yml" ] && ok "dry-run: файл не создан" || bad "dry-run: файл создан"

# --- 6. Usage error ---------------------------------------------------------
bash "$SCRIPT" --dsh-home "$WORK/dsh6" >/dev/null 2>&1
[ $? -eq 1 ] && ok "без --workspace: код 1" || bad "без --workspace: неверный код"

echo
if [ "$FAIL" -eq 0 ]; then
    echo "test_dsh_skills_install: ALL PASS ($PASS)"
    exit 0
fi
echo "test_dsh_skills_install: FAILED ($FAIL из $((PASS + FAIL)))"
exit 1
