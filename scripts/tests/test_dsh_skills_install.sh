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
#   7-14. Issue #1623: the marker text alone is not a bridge; our entry for another
#      path is a conflict, not a duplicate; two installers at once give one entry; a
#      busy lock is a bounded, clear refusal; permissions and a missing trailing
#      newline survive the atomic write; a symlinked layer stays a symlink;
#      a bad lock wait or an uncreatable lock is refused at once.
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

# --- 7. Marker text in a user comment is not a bridge (#1623) --------------
WS="$WORK/ws7"
mk_workspace "$WS"
DSH="$WORK/dsh7"
mk_dsh "$DSH" web
printf -- '# note: IWE skills bridge is planned, not installed\n- id: other\n  config: {}\n' > "$DSH/cordis.patch.yml"
out=$(bash "$SCRIPT" --workspace "$WS" --dsh-home "$DSH" 2>&1)
status=$?
PATCH="$DSH/cordis.patch.yml"
[ "$status" -eq 0 ] && ok "метка в комментарии: код 0" || bad "метка в комментарии: код $status ($out)"
grep -qF -- "$WS/.claude/skills" "$PATCH" && grep -q 'customSkillDirs' "$PATCH" \
    && ok "метка в комментарии: запись всё же добавлена" || bad "метка в комментарии: записи нет (ложное «уже подключено»)"
[ "$(grep -c 'id: skill-filesystem' "$PATCH")" = "1" ] \
    && ok "метка в комментарии: запись одна" || bad "метка в комментарии: число записей не 1"
# Second run (every later update): our block comes after the user's comment.
before=$(cksum "$PATCH")
out=$(bash "$SCRIPT" --workspace "$WS" --dsh-home "$DSH" 2>&1)
status=$?
[ "$status" -eq 0 ] && ok "метка в комментарии, второй запуск: код 0" || bad "метка в комментарии, второй запуск: код $status"
printf '%s' "$out" | grep -q 'уже подключены' \
    && ok "метка в комментарии, второй запуск: «уже подключены»" || bad "метка в комментарии, второй запуск: $out"
[ "$before" = "$(cksum "$PATCH")" ] \
    && ok "метка в комментарии, второй запуск: файл не тронут" || bad "метка в комментарии, второй запуск: файл изменён"
[ "$(grep -c 'id: skill-filesystem' "$PATCH")" = "1" ] \
    && ok "метка в комментарии, второй запуск: блок не продублирован" || bad "метка в комментарии, второй запуск: блок продублирован"

# --- 7b. Phrase in a comment, the user's own customSkillDirs elsewhere -------
# Not our block: the comment is followed by another entry, so it stays a conflict.
WS="$WORK/ws7b"
mk_workspace "$WS"
DSH="$WORK/dsh7b"
mk_dsh "$DSH" web
SKILLS_JSON=$(python3 -c 'import json, sys; print(json.dumps(sys.argv[1]))' "$WS/.claude/skills")
printf -- '# IWE skills bridge mentioned here\n- id: other\n  config: {}\n- id: skill-filesystem\n  config:\n    customSkillDirs:\n      - %s\n' "$SKILLS_JSON" > "$DSH/cordis.patch.yml"
before=$(cksum "$DSH/cordis.patch.yml")
out=$(bash "$SCRIPT" --workspace "$WS" --dsh-home "$DSH" 2>&1)
printf '%s' "$out" | grep -q 'customSkillDirs уже задан' \
    && ok "метка не над нашей записью: конфликт, а не «подключено»" || bad "метка не над нашей записью: $out"
[ "$before" = "$(cksum "$DSH/cordis.patch.yml")" ] \
    && ok "метка не над нашей записью: файл не тронут" || bad "метка не над нашей записью: файл изменён"

# --- 8. Our entry for another workspace path: conflict, file untouched ------
WS_A="$WORK/ws8a"; WS_B="$WORK/ws8b"
mk_workspace "$WS_A"; mk_workspace "$WS_B"
DSH="$WORK/dsh8"
mk_dsh "$DSH" web
bash "$SCRIPT" --workspace "$WS_A" --dsh-home "$DSH" >/dev/null 2>&1
before=$(cksum "$DSH/cordis.patch.yml")
out=$(bash "$SCRIPT" --workspace "$WS_B" --dsh-home "$DSH" 2>&1)
status=$?
[ "$status" -eq 0 ] && ok "запись для другого пути: код 0" || bad "запись для другого пути: код $status"
[ "$before" = "$(cksum "$DSH/cordis.patch.yml")" ] \
    && ok "запись для другого пути: файл не тронут" || bad "запись для другого пути: файл изменён"
printf '%s' "$out" | grep -q 'customSkillDirs уже задан' \
    && ok "запись для другого пути: сказано словами" || bad "запись для другого пути: молчит"
[ "$(grep -c 'IWE skills bridge' "$DSH/cordis.patch.yml")" = "1" ] \
    && ok "запись для другого пути: блок не продублирован" || bad "запись для другого пути: блок продублирован"

# --- 9. Two installers at once: exactly one entry, valid YAML ---------------
WS="$WORK/ws9"
mk_workspace "$WS"
DSH="$WORK/dsh9"
mk_dsh "$DSH" web
bash "$SCRIPT" --workspace "$WS" --dsh-home "$DSH" >/dev/null 2>&1 &
pid_a=$!
bash "$SCRIPT" --workspace "$WS" --dsh-home "$DSH" >/dev/null 2>&1 &
pid_b=$!
wait "$pid_a"; status_a=$?
wait "$pid_b"; status_b=$?
PATCH="$DSH/cordis.patch.yml"
{ [ "$status_a" -eq 0 ] && [ "$status_b" -eq 0 ]; } \
    && ok "два запуска сразу: оба код 0" || bad "два запуска сразу: коды $status_a/$status_b"
[ "$(grep -c 'id: skill-filesystem' "$PATCH")" = "1" ] \
    && ok "два запуска сразу: запись одна" || bad "два запуска сразу: записей не одна"
[ ! -e "$PATCH.lock" ] && ok "два запуска сразу: замок снят" || bad "два запуска сразу: замок остался"
if python3 -c 'import yaml' >/dev/null 2>&1; then
    python3 -c 'import sys, yaml; d = yaml.safe_load(open(sys.argv[1], encoding="utf-8")); assert isinstance(d, list) and len(d) == 1, d' "$PATCH" \
        && ok "два запуска сразу: YAML разбирается" || bad "два запуска сразу: YAML сломан"
else
    echo "  ○ два запуска сразу: разбор YAML пропущен (нет PyYAML)"
fi

# --- 10. Busy lock: bounded wait, clear refusal, foreign lock kept ----------
WS="$WORK/ws10"
mk_workspace "$WS"
DSH="$WORK/dsh10"
mk_dsh "$DSH" web
printf -- '- id: other\n  config: {}\n' > "$DSH/cordis.patch.yml"
mkdir "$DSH/cordis.patch.yml.lock"
before=$(cksum "$DSH/cordis.patch.yml")
out=$(IWE_DSH_LOCK_WAIT_SEC=1 bash "$SCRIPT" --workspace "$WS" --dsh-home "$DSH" 2>&1)
status=$?
[ "$status" -eq 2 ] && ok "занятый замок: код 2" || bad "занятый замок: код $status"
printf '%s' "$out" | grep -q 'cordis.patch.yml.lock' \
    && ok "занятый замок: назван путь замка" || bad "занятый замок: путь не назван"
[ "$before" = "$(cksum "$DSH/cordis.patch.yml")" ] \
    && ok "занятый замок: файл не тронут" || bad "занятый замок: файл изменён"
[ -d "$DSH/cordis.patch.yml.lock" ] \
    && ok "занятый замок: чужой замок не удалён" || bad "занятый замок: чужой замок удалён"

# --- 11. Existing file: no trailing newline, permissions, no leftovers ------
WS="$WORK/ws11"
mk_workspace "$WS"
DSH="$WORK/dsh11"
mk_dsh "$DSH" web
printf -- '- id: other\n  config: {}' > "$DSH/cordis.patch.yml"   # no trailing newline
chmod 600 "$DSH/cordis.patch.yml"
bash "$SCRIPT" --workspace "$WS" --dsh-home "$DSH" >/dev/null 2>&1
PATCH="$DSH/cordis.patch.yml"
[ -n "$(find "$PATCH" -perm 600)" ] && ok "права файла сохранены (600)" || bad "права файла изменились"
[ -f "$PATCH.bak-iwe-skills" ] && ok "резервная копия создана" || bad "резервной копии нет"
[ -z "$(find "$DSH" -maxdepth 1 \( -name '*tmp*' -o -name '*lock*' \))" ] \
    && ok "временных файлов и замка не осталось" || bad "остались временные файлы: $(find "$DSH" -maxdepth 1 -type f)"
grep -q '^- id: skill-filesystem' "$PATCH" && ok "запись начинается с новой строки" || bad "запись склеилась с предыдущей строкой"

# --- 12. Patch layer is a symlink: it stays one, the real file is updated ---
WS="$WORK/ws12"
mk_workspace "$WS"
DSH="$WORK/dsh12"
mk_dsh "$DSH" web
mkdir -p "$WORK/dotfiles"
printf -- '- id: other\n  config: {}\n' > "$WORK/dotfiles/real.yml"
ln -s "$WORK/dotfiles/real.yml" "$DSH/cordis.patch.yml"
bash "$SCRIPT" --workspace "$WS" --dsh-home "$DSH" >/dev/null 2>&1
[ -L "$DSH/cordis.patch.yml" ] && ok "символическая ссылка: осталась ссылкой" || bad "символическая ссылка: заменена обычным файлом"
grep -qF -- "$WS/.claude/skills" "$WORK/dotfiles/real.yml" \
    && ok "символическая ссылка: запись попала в настоящий файл" || bad "символическая ссылка: настоящий файл не обновлён"

# --- 13. Lock wait that is not a number: immediate refusal -----------------
WS="$WORK/ws13"
mk_workspace "$WS"
DSH="$WORK/dsh13"
mk_dsh "$DSH" web
out=$(IWE_DSH_LOCK_WAIT_SEC=abc timeout 20 bash "$SCRIPT" --workspace "$WS" --dsh-home "$DSH" 2>&1)
status=$?
[ "$status" -eq 1 ] && ok "нечисловое ожидание замка: код 1" || bad "нечисловое ожидание замка: код $status"
printf '%s' "$out" | grep -q "abc" && ok "нечисловое ожидание замка: значение названо" || bad "нечисловое ожидание замка: $out"
[ ! -f "$DSH/cordis.patch.yml" ] && ok "нечисловое ожидание замка: файл не создан" || bad "нечисловое ожидание замка: файл создан"

# --- 14. Lock cannot be created (read-only DSH home): refuse at once ---------
if [ "$(id -u)" -ne 0 ]; then
    WS="$WORK/ws14"
    mk_workspace "$WS"
    DSH="$WORK/dsh14"
    mk_dsh "$DSH" web
    printf -- '- id: other\n  config: {}\n' > "$DSH/cordis.patch.yml"
    chmod 555 "$DSH"
    start=$(date +%s)
    out=$(timeout 20 bash "$SCRIPT" --workspace "$WS" --dsh-home "$DSH" 2>&1)
    status=$?
    elapsed=$(( $(date +%s) - start ))
    chmod 755 "$DSH"
    [ "$status" -eq 2 ] && ok "замок не создать: код 2" || bad "замок не создать: код $status"
    [ "$elapsed" -lt 5 ] && ok "замок не создать: отказ сразу, без ожидания" || bad "замок не создать: ждал $elapsed с"
    printf '%s' "$out" | grep -q 'не удалось создать замок' \
        && ok "замок не создать: причина названа" || bad "замок не создать: $out"
fi

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
