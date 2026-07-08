#!/bin/bash
# Exocortex Update — загрузка обновлений платформы из FMT-exocortex-template
#
# Использование:
#   bash update.sh              # Превью + применение (с подтверждением)
#   bash update.sh --check      # Только превью (без изменений)
#   bash update.sh --yes        # Применить без подтверждения
#   bash update.sh --dry-run    # Alias для --check
#
# Работает с template repos (created via "Use this template") —
# не требует общей git-истории с upstream.
#
set -e

# Named exit codes (issue #31): improve diagnostics for non-obvious failures.
EXIT_OK=0
EXIT_USAGE=1
EXIT_NETWORK=2
EXIT_CONFLICT=49
EXIT_GENERAL=1

trap 'echo "ОШИБКА: update.sh прервался на строке ${LINENO}: ${BASH_COMMAND}" >&2' ERR

VERSION="2.4.0"  # fix #229: repair-pass no longer stale-repairs memory files with owner: user in frontmatter; fix #228: hot-budget validator warns when memory/*.md horizon:hot lines exceed threshold
REPO="TserenTserenov/FMT-exocortex-template" # UPSTREAM-CONST: do not substitute
BRANCH="main"
RAW_BASE="https://raw.githubusercontent.com/$REPO/$BRANCH"

CHECK_ONLY=false
AUTO_YES=false

# Allow extra curl flags via env var (e.g. CURL_OPTS="--insecure" for Windows corporate firewall).
# shellcheck disable=SC2086  # $CURL_BASE_OPTS intentionally unquoted (multi-token flag)
CURL_BASE_OPTS="${CURL_OPTS:-}"

# Windows (msys/cygwin) schannel backend may fail with CRYPT_E_NO_REVOCATION_CHECK.
# Detect the best available SSL revocation flag without making a network call.
_CURL_SSL_OPT=""
case "${OSTYPE:-}" in
  msys*|cygwin*)
    if curl --help 2>&1 | grep -q "ssl-revoke-best-effort"; then
      _CURL_SSL_OPT="--ssl-revoke-best-effort"
    elif curl --help 2>&1 | grep -q "ssl-no-revoke"; then
      _CURL_SSL_OPT="--ssl-no-revoke"
    fi
    ;;
esac

for arg in "$@"; do
    case "$arg" in
        --check|--dry-run)  CHECK_ONLY=true ;;
        --yes)              AUTO_YES=true ;;
        --version)          echo "exocortex-update v$VERSION"; exit 0 ;;
        --help|-h)
            echo "Usage: update.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --check     Показать доступные обновления без применения"
            echo "  --yes       Применить обновления без подтверждения"
            echo "  --version   Версия скрипта"
            echo "  --help      Эта справка"
            exit 0
            ;;
    esac
done

# === Cross-platform sed -i ===
if sed --version >/dev/null 2>&1; then
    sed_inplace() { sed -i "$@"; }
else
    sed_inplace() { sed -i '' "$@"; }
fi

# === Cross-platform hash ===
hash_file() {
    shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1 || \
    sha256sum "$1" 2>/dev/null | cut -d' ' -f1
}

# Личные L4-конфиги в memory/: update.sh сеет их при ОТСУТСТВИИ (новая инсталляция),
# но НИКОГДА не перезаписывает поверх существующего — там персональные правки
# пользователя (напр. calendar_ids, slot-настройки в day-rhythm-config.yaml).
# Файл сам объявляет себя «L4 Personal. Override defaults from IWE Template».
# MEMORY.md защищён отдельной проверкой ниже. См. issue про clobber day-rhythm-config.
is_personal_config() {
    case "$1" in
        day-rhythm-config.yaml) return 0 ;;
        *) return 1 ;;
    esac
}

# === Detect directories ===
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# issue #229: shared frontmatter reader (get_field), sourced by SCRIPT_DIR-relative
# path. Soft here (no || exit 1): an install upgrading from a pre-2.4.0 version
# won't have this file locally yet on its very first run — Step 0 self-update
# replaces update.sh itself and re-execs it before any file propagation happens,
# so this line runs before the file can exist on disk. Step 5 Apply delivers it
# (it's now in the manifest) and re-sources it below, right after copying files —
# that call is the hard-required one, by which point the file is guaranteed present.
[ -f "$SCRIPT_DIR/.claude/lib/frontmatter.sh" ] && source "$SCRIPT_DIR/.claude/lib/frontmatter.sh"

if [ ! -f "$SCRIPT_DIR/CLAUDE.md" ]; then
    echo "ОШИБКА: Запускайте из корня экзокортекс-репо."
    echo "  cd /path/to/your-exocortex && bash update.sh"
    exit 1
fi

WORKSPACE_DIR="$(dirname "$SCRIPT_DIR")"

# Claude memory dir — computed once here so both the normal propagation pass
# (Step 6) and the early repair-pass (see repair_pass() below, issue #226) can use it.
CLAUDE_PROJECT_SLUG="$(echo "$WORKSPACE_DIR" | tr '/' '-')"
CLAUDE_MEMORY_DIR="$HOME/.claude/projects/$CLAUDE_PROJECT_SLUG/memory"

# === Temp directory ===
TMPDIR_UPDATE=$(mktemp -d 2>/dev/null || { mkdir -p "/tmp/exocortex-update-$$"; echo "/tmp/exocortex-update-$$"; })
trap "rm -rf '$TMPDIR_UPDATE'" EXIT

echo "=========================================="
echo "  Exocortex Update v$VERSION"
echo "=========================================="
echo "  Репо: $SCRIPT_DIR"
echo ""

# === Step 0: Self-update (bootstrap) ===
echo "[0] Проверка update.sh..."
# Capture hash before any network activity — used for --check integrity guard below (fix #205)
SELF_HASH_BEFORE=$(hash_file "$SCRIPT_DIR/update.sh")
REMOTE_UPDATE="$TMPDIR_UPDATE/update.sh.new"
if curl $CURL_BASE_OPTS $_CURL_SSL_OPT -sSfL "$RAW_BASE/update.sh" -o "$REMOTE_UPDATE" 2>/dev/null; then
    LOCAL_HASH=$(hash_file "$SCRIPT_DIR/update.sh")
    REMOTE_HASH=$(hash_file "$REMOTE_UPDATE")
    if [ "$LOCAL_HASH" != "$REMOTE_HASH" ]; then
        if $CHECK_ONLY; then
            # In --check mode: report available update without touching the file
            echo "  ⚠ Новая версия update.sh доступна. Запустите без --check для обновления."
        else
            echo "  Найдена новая версия update.sh — обновляю..."
            cp "$REMOTE_UPDATE" "$SCRIPT_DIR/update.sh"
            chmod +x "$SCRIPT_DIR/update.sh"
            echo "  Перезапуск..."
            exec bash "$SCRIPT_DIR/update.sh" "$@"
        fi
    fi
fi
echo "  update.sh актуален."
echo ""

# === Step 1: Fetch manifest ===
echo "[1] Загрузка манифеста..."
MANIFEST_URL="$RAW_BASE/update-manifest.json"
MANIFEST="$TMPDIR_UPDATE/manifest.json"

if ! curl $CURL_BASE_OPTS $_CURL_SSL_OPT -sSfL "$MANIFEST_URL" -o "$MANIFEST" 2>/dev/null; then
    echo "ОШИБКА: Не удалось загрузить манифест обновлений."
    echo "  URL: $MANIFEST_URL"
    echo "  Проверьте подключение к интернету."
    exit 1
fi

# Parse version from manifest
UPSTREAM_VERSION=$(grep '"version"' "$MANIFEST" | head -1 | sed 's/.*"version"[[:space:]]*:[[:space:]]*"//;s/".*//')
echo "  Версия upstream: $UPSTREAM_VERSION"
echo ""

# === Repair-pass для critical runtime files (issue #226) ===
# Закрывает два gap-а:
#   (1) «UNCHANGED ⇒ файл отсутствует» — ручное удаление / сбой предыдущего update.
#   (2) «UNCHANGED ⇒ файл stale» — файл есть, но hash расходится с FMT source
#       (возникает при частичном применении update, dirty workspace, или если workspace
#       не перезаписывал существующий файл при прошлом update).
# Функция (не инлайн), потому что нужна ДО раннего "TOTAL_CHANGES=0 ⇒ exit 0"
# (иначе repair недостижим ровно тогда, когда он нужнее всего — SCRIPT_DIR уже
# на актуальной версии от предыдущего запуска, а workspace остался stale) И
# после обычной propagation (Step 6) — чтобы не дублировать работу NEW/UPDATED_FILES.
# REPAIRED — глобальный счётчик, читается вызывающим кодом после возврата.
repair_pass() {
    REPAIRED=0
    while IFS='|' read -r fpath _; do
        [ -z "$fpath" ] && continue
        [ ! -f "$SCRIPT_DIR/$fpath" ] && continue

        case "$fpath" in
            memory/*.md|memory/*.yaml|memory/*.yml)
                fname=$(basename "$fpath")
                [ "$fname" = "MEMORY.md" ] && continue
                if [ -d "$CLAUDE_MEMORY_DIR" ]; then
                    mem_dst="$CLAUDE_MEMORY_DIR/$fname"
                    if [ ! -f "$mem_dst" ]; then
                        cp "$SCRIPT_DIR/$fpath" "$mem_dst"
                        echo "  ⟲ $fpath → memory/ (repair)"
                        REPAIRED=$((REPAIRED + 1))
                    elif [ -r "$mem_dst" ] && [ "$(get_field "$mem_dst" owner)" = "user" ]; then
                        : # issue #229: owner: user в frontmatter — пилот владеет файлом, stale-repair не применяется никогда
                    elif is_personal_config "$fname"; then
                        : # личный L4-конфиг без frontmatter (day-rhythm-config.yaml) — НЕ stale-repair
                    elif [ -r "$mem_dst" ] && [ "$(hash_file "$SCRIPT_DIR/$fpath")" != "$(hash_file "$mem_dst")" ]; then
                        cp "$SCRIPT_DIR/$fpath" "$mem_dst"
                        echo "  ⟲ $fpath → memory/ (stale repair)"
                        REPAIRED=$((REPAIRED + 1))
                    fi
                fi
                ;;
            .claude/skills/*|.claude/hooks/*|.claude/rules/*|.claude/rules-lazy/*|.claude/lib/*|.claude/config/*|.claude/detectors/*|.claude/scripts/*|.claude/agents/*|.claude/styles/*|.claude/templates/*|.claude/settings.json)
                dst="$WORKSPACE_DIR/$fpath"
                if [ ! -f "$dst" ]; then
                    mkdir -p "$(dirname "$dst")"
                    cp "$SCRIPT_DIR/$fpath" "$dst"
                    case "$fpath" in *.sh) chmod +x "$dst" ;; esac
                    echo "  ⟲ $fpath → workspace (repair)"
                    REPAIRED=$((REPAIRED + 1))
                elif [ -r "$dst" ] && [ "$(hash_file "$SCRIPT_DIR/$fpath")" != "$(hash_file "$dst")" ]; then
                    cp "$SCRIPT_DIR/$fpath" "$dst"
                    case "$fpath" in *.sh) chmod +x "$dst" ;; esac
                    echo "  ⟲ $fpath → workspace (stale repair)"
                    REPAIRED=$((REPAIRED + 1))
                fi
                ;;
        esac
    done < <(
        python3 -c "
import json
with open('$MANIFEST') as f:
    data = json.load(f)
for entry in data.get('files', []):
    print(entry['path'] + '|')
" 2>/dev/null
    )
    if [ "$REPAIRED" -gt 0 ]; then
        echo "  ✓ $REPAIRED runtime-файлов восстановлено"
    fi
    # An explicit success: as a function (unlike the old inline block), this is
    # a plain top-level command at the call site, and its own exit status
    # (not exempted by the && short-circuit rule that saved the old inline code)
    # is what set -e sees.
    return 0
}

# === Step 2: Download and compare files ===
echo "[2] Сравнение файлов..."

NEW_FILES=()
NEW_DESCS=()
UPDATED_FILES=()
UPDATED_LINES=()
UNCHANGED=0
CLAUDE_CONFLICTS=0  # unresolved CLAUDE.md merge conflict counter (WP-7)
# issue #226: a CLAUDE.md conflict must not abort delivery of the rest of the
# update (memory/hooks/skills, repair-pass, commit) — it's an isolated artifact.
# Collect it here and fail at the very end instead of exiting mid-script.
CLAUDE_CONFLICT_DETECTED=false
CLAUDE_CONFLICT_FILES=()

# Count total files for progress display
TOTAL_FILES=$(python3 -c "
import json
with open('$MANIFEST') as f:
    data = json.load(f)
print(len(data.get('files', [])))
" 2>/dev/null || echo "?")
DOWNLOAD_IDX=0

# Parse manifest: extract path and desc for each file entry
while IFS='|' read -r fpath fdesc; do
    [ -z "$fpath" ] && continue
    # Protected user files (issue #154): never overwrite if they already exist locally.
    # The "Не затрагиваются" list below is cosmetic; this is the actual skip-if-exists guard.
    case "$fpath" in
        params.yaml|memory/MEMORY.md|.claude/settings.local.json|sessions/00-index.md)
            if [ -f "$SCRIPT_DIR/$fpath" ]; then
                UNCHANGED=$((UNCHANGED + 1))
                continue
            fi ;;
    esac
    DOWNLOAD_IDX=$((DOWNLOAD_IDX + 1))
    printf "  (%s/%s) %s\r" "$DOWNLOAD_IDX" "$TOTAL_FILES" "$fpath"

    # Download remote file
    REMOTE_FILE="$TMPDIR_UPDATE/files/$fpath"
    mkdir -p "$(dirname "$REMOTE_FILE")"

    if ! curl $CURL_BASE_OPTS $_CURL_SSL_OPT -sSfL "$RAW_BASE/$fpath" -o "$REMOTE_FILE" 2>/dev/null; then
        continue
    fi

    if [ ! -f "$SCRIPT_DIR/$fpath" ]; then
        # New file
        NEW_FILES+=("$fpath")
        NEW_DESCS+=("$fdesc")
    else
        # Existing file — compare hashes
        LOCAL_HASH=$(hash_file "$SCRIPT_DIR/$fpath")
        REMOTE_HASH=$(hash_file "$REMOTE_FILE")
        if [ "$LOCAL_HASH" != "$REMOTE_HASH" ]; then
            DIFF_COUNT=$(diff "$SCRIPT_DIR/$fpath" "$REMOTE_FILE" 2>/dev/null | grep -c '^[<>]' || true); DIFF_COUNT=${DIFF_COUNT:-?}
            UPDATED_FILES+=("$fpath")
            UPDATED_LINES+=("$DIFF_COUNT")
        else
            UNCHANGED=$((UNCHANGED + 1))
        fi
    fi
done < <(
    # Parse JSON: extract path|desc pairs
    python3 -c "
import json, sys
with open('$MANIFEST') as f:
    data = json.load(f)
for entry in data.get('files', []):
    print(entry['path'] + '|' + entry.get('desc', ''))
" 2>/dev/null || {
    # Fallback: basic grep parsing if python3 not available
    grep '"path"' "$MANIFEST" | while read -r line; do
        fpath=$(echo "$line" | sed 's/.*"path"[[:space:]]*:[[:space:]]*"//;s/".*//')
        echo "$fpath|"
    done
}
)
printf "\n"

# === Step 2b: Deprecated files (устаревшие L1-файлы к удалению) ===
DEPRECATED_FOUND=()
DEPRECATED_REASONS=()

while IFS='|' read -r fpath freason; do
    [ -z "$fpath" ] && continue
    if [ -f "$SCRIPT_DIR/$fpath" ]; then
        DEPRECATED_FOUND+=("$fpath")
        DEPRECATED_REASONS+=("${freason:-устарел}")
    fi
done < <(
    python3 -c "
import json, sys
with open('$MANIFEST') as f:
    data = json.load(f)
for entry in data.get('deprecated_files', []):
    print(entry.get('path','') + '|' + entry.get('reason',''))
" 2>/dev/null || true)

TOTAL_CHANGES=$(( ${#NEW_FILES[@]} + ${#UPDATED_FILES[@]} + ${#DEPRECATED_FOUND[@]} ))

# === Step 3: Display results ===
echo ""
echo "=========================================="
echo "  Обновления экзокортекса (v$UPSTREAM_VERSION)"
echo "=========================================="
echo ""

if [ "$TOTAL_CHANGES" -eq 0 ]; then
    # issue #226: TOTAL_CHANGES=0 значит SCRIPT_DIR уже совпадает с upstream — но
    # workspace мог остаться stale (прерванный предыдущий запуск). Чиним прямо тут,
    # иначе repair-pass ниже никогда не выполнится (недостижим после этого exit).
    repair_pass
    echo "✓ Всё актуально. Обновлений нет. ($UNCHANGED файлов проверено)"
    exit 0
fi

if [ ${#NEW_FILES[@]} -gt 0 ]; then
    echo "Новые файлы (${#NEW_FILES[@]}):"
    for i in "${!NEW_FILES[@]}"; do
        f="${NEW_FILES[$i]}"
        d="${NEW_DESCS[$i]}"
        if [ -n "$d" ]; then
            printf "  + %-45s — %s\n" "$f" "$d"
        else
            printf "  + %s\n" "$f"
        fi
    done
    echo ""
fi

if [ ${#UPDATED_FILES[@]} -gt 0 ]; then
    echo "Обновлённые файлы (${#UPDATED_FILES[@]}):"
    for i in "${!UPDATED_FILES[@]}"; do
        f="${UPDATED_FILES[$i]}"
        lines="${UPDATED_LINES[$i]}"
        printf "  ~ %-45s — %s строк изменено\n" "$f" "$lines"
    done
    echo ""
fi

if [ ${#DEPRECATED_FOUND[@]} -gt 0 ]; then
    echo "Устаревшие файлы к удалению (${#DEPRECATED_FOUND[@]}):"
    for i in "${!DEPRECATED_FOUND[@]}"; do
        f="${DEPRECATED_FOUND[$i]}"
        r="${DEPRECATED_REASONS[$i]}"
        printf "  - %-45s — %s\n" "$f" "$r"
    done
    echo ""
fi

echo "Не затрагиваются:"
echo "  ✓ memory/MEMORY.md (личная оперативная память)"
echo "  ✓ CLAUDE.md (3-way merge: ваши правки сохраняются)"
echo "  ✓ extensions/ (ваши расширения протоколов)"
echo "  ✓ params.yaml (ваши параметры)"
echo "  ✓ .secrets/ (ключи)"
echo "  ✓ .claude/settings.local.json (permissions)"
echo "  ✓ sessions/00-index.md (журнал peer-сессий)"
echo "  ✓ personal/ (ваши файлы)"
echo "  ✓ ${IWE_GOVERNANCE_REPO:-DS-strategy}/ (ваше планирование)"
echo ""

if [ "$UNCHANGED" -gt 0 ]; then
    echo "Без изменений: $UNCHANGED файлов"
    echo ""
fi

# === Check-only mode ===
if $CHECK_ONLY; then
    echo "Режим --check: изменения не применяются."
    echo "Для применения: bash update.sh"
    # Self-integrity guard: verify update.sh was not mutated during the check pass (fix #205)
    SELF_HASH_AFTER=$(hash_file "$SCRIPT_DIR/update.sh")
    if [ "$SELF_HASH_BEFORE" != "$SELF_HASH_AFTER" ]; then
        echo "ОШИБКА: update.sh мутировал в режиме --check — это баг!" >&2
        exit 1
    fi
    exit 0
fi

# === Step 4: Confirmation ===
if ! $AUTO_YES; then
    read -p "Применить обновления? (y/n) " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Отменено."
        exit 0
    fi
fi

# === Step 5: Apply updates ===
echo ""
echo "Применяю обновления..."

APPLIED=0
REMOVED=0

for f in "${NEW_FILES[@]}"; do
    mkdir -p "$SCRIPT_DIR/$(dirname "$f")"
    cp "$TMPDIR_UPDATE/files/$f" "$SCRIPT_DIR/$f"
    # Make scripts executable
    case "$f" in *.sh) chmod +x "$SCRIPT_DIR/$f" ;; esac
    echo "  + $f"
    APPLIED=$((APPLIED + 1))
done

for f in "${UPDATED_FILES[@]}"; do
    # Special handling for CLAUDE.md: 3-way merge preserving user customizations
    if [ "$f" = "CLAUDE.md" ] && [ -f "$SCRIPT_DIR/$f" ]; then
        BASE_FILE="$SCRIPT_DIR/.claude.md.base"
        NEW_FILE="$TMPDIR_UPDATE/files/$f"
        CURRENT_FILE="$SCRIPT_DIR/$f"

        if [ -f "$BASE_FILE" ] && command -v git >/dev/null 2>&1; then
            # 3-way merge: base (last update) + current (user's) + new (upstream)
            # git merge-file modifies the first argument in place
            MERGE_TMP="$TMPDIR_UPDATE/claude-merge.md"
            cp "$CURRENT_FILE" "$MERGE_TMP"

            if git merge-file -p "$MERGE_TMP" "$BASE_FILE" "$NEW_FILE" > "$TMPDIR_UPDATE/claude-merged.md" 2>/dev/null; then
                # Clean merge — no conflicts
                cp "$TMPDIR_UPDATE/claude-merged.md" "$CURRENT_FILE"
                cp "$NEW_FILE" "$BASE_FILE"
                echo "  ~ $f (3-way merge, чисто)"
            else
                CONFLICT_COUNT=$(grep -c '^<<<<<<<' "$TMPDIR_UPDATE/claude-merged.md" 2>/dev/null || true); CONFLICT_COUNT=${CONFLICT_COUNT:-0}
                if [ "$CONFLICT_COUNT" -gt 0 ]; then
                    # Conflicts detected — save merged file with markers
                    cp "$TMPDIR_UPDATE/claude-merged.md" "$CURRENT_FILE"
                    cp "$NEW_FILE" "$BASE_FILE"
                    CLAUDE_CONFLICTS=$((CLAUDE_CONFLICTS + CONFLICT_COUNT))
                    echo "  ~ $f (3-way merge, $CONFLICT_COUNT конфликтов — разрешите вручную)"
                    echo "    Конфликты обозначены <<<<<<< / ======= / >>>>>>>"
                else
                    # git merge-file returned non-zero but no conflict markers — treat as success
                    cp "$TMPDIR_UPDATE/claude-merged.md" "$CURRENT_FILE"
                    cp "$NEW_FILE" "$BASE_FILE"
                    echo "  ~ $f (3-way merge)"
                fi
            fi
        else
            # No base file (first update after migration) — fallback to USER-SPACE preserve
            USER_SECTION=$(sed -n '/^<!-- USER-SPACE/,/^<!-- \/USER-SPACE/p' "$CURRENT_FILE")
            cp "$NEW_FILE" "$CURRENT_FILE"
            if [ -n "$USER_SECTION" ]; then
                sed_inplace '/^<!-- USER-SPACE/,/^<!-- \/USER-SPACE/d' "$CURRENT_FILE"
                echo "" >> "$CURRENT_FILE"
                echo "$USER_SECTION" >> "$CURRENT_FILE"
                echo "  ~ $f (USER-SPACE сохранён, базовый файл создан)"
            else
                echo "  ~ $f"
            fi
            # Save base for next update
            cp "$NEW_FILE" "$SCRIPT_DIR/.claude.md.base"
        fi
    elif [[ "$f" == .claude/skills/*/SKILL.md ]]; then
        # USER-SPACE preserve for L1 skill spec files (no install_constants in SCRIPT_DIR — already {{KEY}})
        CURR_SKILL_FILE="$SCRIPT_DIR/$f"
        if [ -f "$CURR_SKILL_FILE" ]; then
            USER_SECTION=$(sed -n '/^<!-- USER-SPACE -->/,/^<!-- \/USER-SPACE -->/p' "$CURR_SKILL_FILE")
        else
            USER_SECTION=""
        fi
        cp "$TMPDIR_UPDATE/files/$f" "$SCRIPT_DIR/$f"
        if [ -n "$USER_SECTION" ]; then
            perl -i -0pe 's/^<!-- USER-SPACE -->.*?^<!-- \/USER-SPACE -->//ms' "$SCRIPT_DIR/$f"
            perl -i -0pe 's/\n+$/\n/' "$SCRIPT_DIR/$f"
            printf '\n%s\n' "$USER_SECTION" >> "$SCRIPT_DIR/$f"
            echo "  ~ $f (USER-SPACE preserved)"
        else
            echo "  ~ $f"
        fi
    else
        cp "$TMPDIR_UPDATE/files/$f" "$SCRIPT_DIR/$f"
        case "$f" in *.sh) chmod +x "$SCRIPT_DIR/$f" ;; esac
        echo "  ~ $f"
    fi
    APPLIED=$((APPLIED + 1))
done

# issue #229: hard-require frontmatter.sh now — NEW_FILES/UPDATED_FILES above have
# just delivered it to disk if this is the first run after upgrading from a
# pre-2.4.0 install (the soft source near SCRIPT_DIR could not find it yet then).
# Everything below this point (repair_pass, Step 6 memory copy, hot-budget
# validator) calls get_field(), so a missing file here is a real delivery bug
# (manifest/git tracking), not a bootstrap-ordering race — fail loudly.
source "$SCRIPT_DIR/.claude/lib/frontmatter.sh" || {
    echo "ОШИБКА: .claude/lib/frontmatter.sh отсутствует после применения обновлений." >&2
    exit 1
}

# Detect pre-existing nested conflict markers before we propagate merged files.
# This prevents stacking new 3-way merges on top of unresolved ones (issue #31).
conflict_marker_files=()
for cf in "$SCRIPT_DIR/CLAUDE.md" "$WORKSPACE_DIR/CLAUDE.md"; do
    [ -f "$cf" ] && grep -q '^<<<<<<<' "$cf" && conflict_marker_files+=("$cf")
done
if [ "${#conflict_marker_files[@]}" -gt 0 ]; then
    echo ""
    echo "ОШИБКА: обнаружены неразрешённые конфликты слияния (вложенные маркеры):"
    for cf in "${conflict_marker_files[@]}"; do echo "  - $cf"; done
    echo "  Разрешите их вручную и перезапустите update.sh."
    exit "$EXIT_CONFLICT"
fi

# CLAUDE.md conflict (issue #226): warn and remember, but keep going — propagation
# and commit of everything else must not be blocked by one unresolved merge.
if [ "$CLAUDE_CONFLICTS" -gt 0 ]; then
    echo ""
    echo "ОШИБКА: CLAUDE.md содержит неразрешённые конфликты слияния."
    echo "  Конфликты обозначены <<<<<<< / ======= / >>>>>>>"
    echo "  Разрешите их вручную в $SCRIPT_DIR/CLAUDE.md после завершения обновления."
    CLAUDE_CONFLICT_DETECTED=true
    CLAUDE_CONFLICT_FILES+=("$SCRIPT_DIR/CLAUDE.md")
fi

# Remove deprecated files
for i in "${!DEPRECATED_FOUND[@]}"; do
    f="${DEPRECATED_FOUND[$i]}"
    fpath="$SCRIPT_DIR/$f"
    if [ -f "$fpath" ]; then
        rm "$fpath"
        echo "  - $f (удалён: устарел)"
        REMOVED=$((REMOVED + 1))
        # Also remove from workspace .claude/ (propagated L1 files)
        case "$f" in .claude/*)
            ws_path="$WORKSPACE_DIR/$f"
            [ -f "$ws_path" ] && rm "$ws_path" && echo "    (также из workspace)"
            ;;
        esac
        # Also remove from Claude memory dir (memory/* files)
        case "$f" in memory/*.md|memory/*.yaml|memory/*.yml)
            mem_path="$CLAUDE_MEMORY_DIR/$(basename "$f")"
            [ -f "$mem_path" ] && rm "$mem_path" && echo "    (также из memory/)"
            ;;
        esac
    fi
done
# Clean up empty deprecated directories
for i in "${!DEPRECATED_FOUND[@]}"; do
    f="${DEPRECATED_FOUND[$i]}"
    dir="$SCRIPT_DIR/$(dirname "$f")"
    [ "$dir" = "$SCRIPT_DIR/." ] && continue
    [ -d "$dir" ] && [ -z "$(ls -A "$dir" 2>/dev/null)" ] && rmdir "$dir" 2>/dev/null && echo "  - $(dirname "$f")/ (пустая директория удалена)"
done

# === Step 5b: Re-substitute placeholders + ensure .exocortex.env in workspace ===
# WP-273 Этап 2: substituted-файлы живут в $WORKSPACE_DIR/.iwe-runtime/, не в FMT.
# Substitution в FMT-файлах больше НЕ выполняется. CLAUDE.md substitute отдельно (3-way merge).
# Поиск .exocortex.env: workspace (Variant F) → FMT (legacy ≤0.28.x).
echo ""
echo "Подстановка переменных..."

if [ -f "$WORKSPACE_DIR/.exocortex.env" ]; then
    ENV_FILE="$WORKSPACE_DIR/.exocortex.env"
elif [ -f "$SCRIPT_DIR/.exocortex.env" ]; then
    ENV_FILE="$SCRIPT_DIR/.exocortex.env"
    echo "  ⚠ .exocortex.env найден в FMT (legacy). Будет мигрирован в \$WORKSPACE_DIR/ при первом setup ≥0.7.0."
else
    ENV_FILE="$WORKSPACE_DIR/.exocortex.env"  # для дальнейшего автогенерирования (миграция С5)
fi

if [ -f "$ENV_FILE" ]; then
    # Validate: only KEY=VALUE lines allowed (no shell commands)
    if grep -qE '^\s*(source|eval|exec|\.|`|;|\$\()' "$ENV_FILE" 2>/dev/null; then
        echo "  ОШИБКА: .exocortex.env содержит недопустимые конструкции. Пропускаю подстановку."
        echo "  Пересоздайте: bash setup.sh"
    else
        # Read variables safely (only simple KEY=VALUE)
        # Use read -r line + split on first '=' to handle values containing '=' (e.g. URLs, tokens)
        while IFS= read -r line; do
            # Skip comments and empty lines
            case "$line" in \#*|"") continue ;; esac
            # Split on first '=' only
            key="${line%%=*}"
            value="${line#*=}"
            # Trim whitespace from key
            key=$(echo "$key" | tr -d '[:space:]')
            [ -z "$key" ] && continue
            # Export for use below (secrets: L4_DATABASE_URL etc. are loaded but not substituted into files)
            declare "ENV_$key=$value"
        done < "$ENV_FILE"

        # WP-273 Этап 2: substitution в FMT-файлах больше НЕ выполняется.
        # Substituted значения генерируются build-runtime.sh в .iwe-runtime/ (Step 6d ниже, ПЕРЕД roles reinstall).
        # Это закрывает R4.6 (self-heal): build-runtime идемпотентен, повторный запуск
        # update.sh пересоздаёт runtime даже если предыдущий прервался.
        :  # placeholder substitution NO-OP в FMT

        # === Preserve secrets: L4_BACKEND, L4_DATABASE_URL ===
        # These are NOT substituted into template files.
        # If they exist in .exocortex.env, they must NOT be overwritten by update.sh.

        # === Auto-add GOVERNANCE_REPO + IWE_TEMPLATE to legacy .exocortex.env (0.28.5+) ===
        # Если .exocortex.env создан до 0.28.5 — этих ключей нет; дописать.
        if ! grep -q '^GOVERNANCE_REPO=' "$ENV_FILE" 2>/dev/null; then
            # Resolve workspace: ENV_WORKSPACE_DIR (если есть) → fallback dirname $SCRIPT_DIR
            DETECT_WS="${ENV_WORKSPACE_DIR:-$(dirname "$SCRIPT_DIR")}"
            DETECTED_GOV=""
            if [ -d "${DETECT_WS}/${IWE_GOVERNANCE_REPO:-DS-strategy}" ]; then
                DETECTED_GOV="${IWE_GOVERNANCE_REPO:-DS-strategy}"
            else
                for d in "${DETECT_WS}"/DS-*; do
                    case "${d##*/}" in
                        DS-*strategy*) DETECTED_GOV="${d##*/}"; break ;;
                    esac
                done
            fi
            if [ -z "$DETECTED_GOV" ]; then
                DETECTED_GOV="${IWE_GOVERNANCE_REPO:-DS-strategy}"
                echo "  ⚠ Governance repo не найден в $DETECT_WS — fallback ${IWE_GOVERNANCE_REPO:-DS-strategy}. Проверьте .exocortex.env вручную."
            fi
            echo "GOVERNANCE_REPO=$DETECTED_GOV" >> "$ENV_FILE"
            echo "  ✓ Добавлено GOVERNANCE_REPO=$DETECTED_GOV в .exocortex.env (миграция 0.28.5)"
            ENV_GOVERNANCE_REPO="$DETECTED_GOV"
        fi
        if ! grep -q '^IWE_TEMPLATE=' "$ENV_FILE" 2>/dev/null; then
            echo "IWE_TEMPLATE=$SCRIPT_DIR" >> "$ENV_FILE"
            echo "  ✓ Добавлено IWE_TEMPLATE=$SCRIPT_DIR в .exocortex.env (миграция 0.28.5)"
            ENV_IWE_TEMPLATE="$SCRIPT_DIR"
        fi

        # === WP-273 Этап 2: IWE_RUNTIME для Generated runtime architecture (F) ===
        if ! grep -q '^IWE_RUNTIME=' "$ENV_FILE" 2>/dev/null; then
            DETECT_WS_RT="${ENV_WORKSPACE_DIR:-$WORKSPACE_DIR}"
            echo "IWE_RUNTIME=$DETECT_WS_RT/.iwe-runtime" >> "$ENV_FILE"
            echo "  ✓ Добавлено IWE_RUNTIME=$DETECT_WS_RT/.iwe-runtime (миграция WP-273 → 0.29.0)"
            ENV_IWE_RUNTIME="$DETECT_WS_RT/.iwe-runtime"
        fi

        # === Migrate .exocortex.env from FMT to workspace (WP-273 Этап 2) ===
        # Если .exocortex.env живёт в FMT (legacy ≤0.28.x), копируем в workspace.
        # FMT остаётся read-only. Workspace = source-of-truth user state.
        if [ "$ENV_FILE" = "$SCRIPT_DIR/.exocortex.env" ] && [ ! -f "$WORKSPACE_DIR/.exocortex.env" ]; then
            cp "$ENV_FILE" "$WORKSPACE_DIR/.exocortex.env"
            chmod 600 "$WORKSPACE_DIR/.exocortex.env"
            echo "  ✓ .exocortex.env скопирован в $WORKSPACE_DIR/ (миграция WP-273 → 0.29.0)"
            echo "    Старая копия в FMT остаётся для backward compat; уберите вручную после проверки."
        fi

        # === Migrate ~/.iwe-env if present (Ф8 migration scenario) ===
        IWE_ENV_GLOBAL="$HOME/.iwe-env"
        if [ -f "$IWE_ENV_GLOBAL" ]; then
            MIGRATED_KEYS=0
            # Check which keys are missing from .exocortex.env
            for migrate_key in L4_BACKEND L4_DATABASE_URL; do
                eval "existing=\${ENV_${migrate_key}:-}"
                if [ -z "$existing" ]; then
                    # Extract from ~/.iwe-env
                    migrated_val=$(grep "^${migrate_key}=" "$IWE_ENV_GLOBAL" 2>/dev/null | head -1)
                    migrated_val="${migrated_val#*=}"
                    if [ -n "$migrated_val" ]; then
                        echo "" >> "$ENV_FILE"
                        echo "${migrate_key}=${migrated_val}" >> "$ENV_FILE"
                        MIGRATED_KEYS=$((MIGRATED_KEYS + 1))
                    fi
                fi
            done
            if [ "$MIGRATED_KEYS" -gt 0 ]; then
                echo "  ✓ Мигрировано $MIGRATED_KEYS ключей из ~/.iwe-env → .exocortex.env"
                echo "  ~/.iwe-env больше не нужен. Удалить вручную: rm $IWE_ENV_GLOBAL"
            fi
        fi
    fi
else
    # No .exocortex.env — try to detect and generate (migration scenario С5)
    echo "  ⚠ .exocortex.env не найден (установка до Ф0.5?)."
    echo "  Попытка восстановления конфигурации..."

    DETECTED_WORKSPACE="$WORKSPACE_DIR"
    DETECTED_REPO="$(basename "$SCRIPT_DIR")"

    cat > "$ENV_FILE" <<ENVEOF
# Exocortex configuration (auto-detected by update.sh — verify and fix values)
# SECURITY: chmod 600. Listed in .gitignore. Do NOT commit this file.
GITHUB_USER=your-username
WORKSPACE_DIR=$DETECTED_WORKSPACE
CLAUDE_PATH=$(command -v claude 2>/dev/null || echo 'claude')
CLAUDE_PROJECT_SLUG=$(echo "$DETECTED_WORKSPACE" | tr '/' '-')
TIMEZONE_HOUR=4
TIMEZONE_DESC=4:00 UTC
HOME_DIR=$HOME

# === Knowledge Gateway (T3+) — fill in if using personal Pack index ===
L4_BACKEND=
L4_DATABASE_URL=
ENVEOF
    chmod 600 "$ENV_FILE"
    echo "  Конфигурация восстановлена в $ENV_FILE"
    echo "  ⚠ ПРОВЕРЬТЕ значения (особенно GITHUB_USER) и перезапустите: bash update.sh"

    # Still substitute what we can (HOME_DIR and WORKSPACE_DIR)
    for f in "${NEW_FILES[@]}" "${UPDATED_FILES[@]}"; do
        filepath="$SCRIPT_DIR/$f"
        [ -f "$filepath" ] || continue
        sed_inplace \
            -e "s|{{WORKSPACE_DIR}}|$DETECTED_WORKSPACE|g" \
            -e "s|{{HOME_DIR}}|$HOME|g" \
            "$filepath" 2>/dev/null || true
    done
fi

# Check remaining placeholders.
# WP-273 0.29.4 R6.2 fix: раньше сканировали $SCRIPT_DIR (FMT) — но в FMT
# плейсхолдеры это by design (clean upstream). Получали навсегда «⚠ 54 файлов
# содержат незаменённые переменные» у каждого пилота на каждом update.
# Проверяем теперь .iwe-runtime/ — там их быть не должно после build-runtime.
RUNTIME_CHECK_DIR="${WORKSPACE_DIR}/.iwe-runtime"
if [ -d "$RUNTIME_CHECK_DIR" ]; then
    REMAINING=$(grep -rl '{{[A-Z_]*}}' "$RUNTIME_CHECK_DIR" --include="*.md" --include="*.sh" --include="*.json" --include="*.yaml" --include="*.yml" --include="*.plist" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$REMAINING" -gt 0 ]; then
        echo "  ⚠ $REMAINING файлов в .iwe-runtime/ содержат незаменённые переменные."
        echo "  Проверьте .exocortex.env (значения placeholders) и перезапустите: bash $SCRIPT_DIR/setup/build-runtime.sh"
    fi
fi

# === Step 6: Reinstall platform-space ===
echo ""
echo "Обновление platform-space..."

# Copy CLAUDE.md to workspace root
CLAUDE_UPDATED=false
for f in "${NEW_FILES[@]}" "${UPDATED_FILES[@]}"; do
    if [ "$f" = "CLAUDE.md" ]; then
        # 3-way merge for workspace CLAUDE.md (same logic as repo copy)
        WS_BASE="$WORKSPACE_DIR/.claude.md.base"
        WS_CURRENT="$WORKSPACE_DIR/CLAUDE.md"
        WS_NEW="$SCRIPT_DIR/CLAUDE.md"

        if [ -f "$WS_BASE" ] && [ -f "$WS_CURRENT" ] && command -v git >/dev/null 2>&1; then
            WS_MERGE_TMP="$TMPDIR_UPDATE/ws-claude-merge.md"
            cp "$WS_CURRENT" "$WS_MERGE_TMP"
            if git merge-file -p "$WS_MERGE_TMP" "$WS_BASE" "$WS_NEW" > "$TMPDIR_UPDATE/ws-claude-merged.md" 2>/dev/null; then
                cp "$TMPDIR_UPDATE/ws-claude-merged.md" "$WS_CURRENT"
                cp "$WS_NEW" "$WS_BASE"
                echo "  ✓ $WS_CURRENT обновлён (3-way merge)"
            else
                WS_CONFLICTS=$(grep -c '^<<<<<<<' "$TMPDIR_UPDATE/ws-claude-merged.md" 2>/dev/null || true); WS_CONFLICTS=${WS_CONFLICTS:-0}
                cp "$TMPDIR_UPDATE/ws-claude-merged.md" "$WS_CURRENT"
                cp "$WS_NEW" "$WS_BASE"
                CLAUDE_CONFLICTS=$((CLAUDE_CONFLICTS + WS_CONFLICTS))
                if [ "$WS_CONFLICTS" -gt 0 ]; then
                    # issue #226: don't abort here — a CLAUDE.md conflict is an isolated
                    # artifact, not a reason to skip the rest of the delivery (memory/hooks/
                    # skills propagation, repair-pass, commit). Warn now, fail at the end.
                    echo "  ~ $WS_CURRENT ($WS_CONFLICTS конфликтов — разрешите вручную)"
                    echo "    Конфликты обозначены <<<<<<< / ======= / >>>>>>>"
                    CLAUDE_CONFLICT_DETECTED=true
                    CLAUDE_CONFLICT_FILES+=("$WS_CURRENT")
                else
                    echo "  ✓ $WS_CURRENT обновлён (3-way merge)"
                fi
            fi
        else
            # Fallback: USER-SPACE preserve (first update or no git)
            if [ -f "$WS_CURRENT" ]; then
                WS_USER_SECTION=$(sed -n '/^<!-- USER-SPACE/,/^<!-- \/USER-SPACE/p' "$WS_CURRENT")
            fi
            cp "$WS_NEW" "$WS_CURRENT"
            if [ -n "${WS_USER_SECTION:-}" ]; then
                sed_inplace '/^<!-- USER-SPACE/,/^<!-- \/USER-SPACE/d' "$WS_CURRENT"
                echo "" >> "$WS_CURRENT"
                echo "$WS_USER_SECTION" >> "$WS_CURRENT"
            fi
            cp "$WS_NEW" "$WS_BASE"
            echo "  ✓ $WS_CURRENT обновлён (базовый файл создан)"
        fi
        CLAUDE_UPDATED=true
    fi
done

# Copy memory files to Claude projects directory
if [ -d "$CLAUDE_MEMORY_DIR" ]; then
    MEM_UPDATED=0
    for f in "${NEW_FILES[@]}" "${UPDATED_FILES[@]}"; do
        case "$f" in
            memory/*.md|memory/*.yaml|memory/*.yml)
                fname=$(basename "$f")
                dst="$CLAUDE_MEMORY_DIR/$fname"
                if [ "$fname" != "MEMORY.md" ]; then
                    # issue #229: same owner:user guard as repair_pass() — this loop runs on
                    # every update.sh call (not just repair), so it's the more common path
                    # that was clobbering user-owned memory files.
                    if [ -f "$dst" ] && [ "$(get_field "$dst" owner)" = "user" ]; then
                        echo "  ✓ $fname — owner: user, не перезаписан"
                    elif is_personal_config "$fname" && [ -f "$dst" ]; then
                        echo "  ✓ $fname — личный L4-конфиг, не перезаписан"
                    else
                        cp "$SCRIPT_DIR/$f" "$dst"
                        MEM_UPDATED=$((MEM_UPDATED + 1))
                    fi
                fi
                ;;
        esac
    done
    if [ "$MEM_UPDATED" -gt 0 ]; then
        echo "  ✓ $MEM_UPDATED memory-файлов обновлено в $CLAUDE_MEMORY_DIR"
    fi
    echo "  ✓ memory/MEMORY.md — не тронут"
fi

# Propagate skills, hooks, rules, lib, config, detectors to workspace if changed.
# lib/config/detectors — runtime dependencies капчер-шины (capture-bus.sh) и детекторов.
for f in "${NEW_FILES[@]}" "${UPDATED_FILES[@]}"; do
    case "$f" in
        .claude/skills/*/SKILL.md)
            src="$SCRIPT_DIR/$f"
            dst="$WORKSPACE_DIR/$f"
            mkdir -p "$(dirname "$dst")"
            # 1. Extract USER_SECTION from workspace before overwriting
            if [ -f "$dst" ]; then
                USER_SECTION=$(sed -n '/^<!-- USER-SPACE -->/,/^<!-- \/USER-SPACE -->/p' "$dst" 2>/dev/null || true)
            else
                USER_SECTION=""
            fi
            # 2. Extract install_constants values from workspace frontmatter
            if [ -f "$dst" ]; then
                IC_BLOCK=$(awk '/^install_constants:/{found=1} found && /^[a-z][^:]+:/ && !/^install_constants:/{exit} found{print}' "$dst" 2>/dev/null || true)
            else
                IC_BLOCK=""
            fi
            # 3. Copy src (with {{KEY}} placeholders) → dst
            cp "$src" "$dst"
            # 4. Substitute install_constants: {{KEY}} → VALUE
            if [ -n "$IC_BLOCK" ]; then
                while IFS=': ' read -r key val; do
                    key="${key#"${key%%[! ]*}"}"
                    val="${val#"${val%%[! ]*}"}"
                    [[ "$key" =~ ^[A-Z_]+$ ]] && [ -n "$val" ] || continue
                    sed_inplace "s|{{${key}}}|${val}|g" "$dst"
                done <<< "$IC_BLOCK"
            fi
            # 5. Reinject USER_SECTION
            if [ -n "$USER_SECTION" ]; then
                perl -i -0pe 's/^<!-- USER-SPACE -->.*?^<!-- \/USER-SPACE -->//ms' "$dst"
                perl -i -0pe 's/\n+$/\n/' "$dst"
                printf '\n%s\n' "$USER_SECTION" >> "$dst"
                echo "  ✓ $f → workspace (USER-SPACE preserved)"
            else
                echo "  ✓ $f → workspace"
            fi
            ;;
        .claude/skills/*|.claude/hooks/*|.claude/rules/*|.claude/rules-lazy/*|.claude/lib/*|.claude/config/*|.claude/detectors/*|.claude/scripts/*|.claude/agents/*|.claude/styles/*|.claude/templates/*|.claude/settings.json)
            src="$SCRIPT_DIR/$f"
            dst="$WORKSPACE_DIR/$f"
            mkdir -p "$(dirname "$dst")"
            cp "$src" "$dst"
            echo "  ✓ $f → workspace"
            ;;
    esac
done

# === Step 5d: Repair-pass для critical runtime files ===
# Выполняется ПОСЛЕ propagation, чтобы repair не дублировал работу NEW_FILES/UPDATED_FILES.
# Определение функции — см. repair_pass() перед Step 2 (нужна там же для early-exit ветки).
repair_pass

# === Step 5e: Hot-budget validator (issue #228) ===
# Политика CLAUDE.md §4: суммарно ≤150 строк в memory/*.md с horizon: hot.
# Warning-only (не hard-fail) — превышение не должно блокировать доставку остального
# (тот же принцип, что и CLAUDE.md conflict handling, issue #226).
HOT_BUDGET_LIMIT=150
if [ -d "$CLAUDE_MEMORY_DIR" ]; then
    HOT_LINES=0
    HOT_FILES=()
    for mem_file in "$CLAUDE_MEMORY_DIR"/*.md; do
        [ -f "$mem_file" ] || continue
        if [ "$(get_field "$mem_file" horizon)" = "hot" ]; then
            # awk NR (not wc -l) — wc -l counts newlines and undercounts by 1
            # for files without a trailing newline, silently hiding an overrun.
            n=$(awk 'END{print NR}' "$mem_file")
            HOT_LINES=$((HOT_LINES + n))
            HOT_FILES+=("$(basename "$mem_file"): $n")
        fi
    done
    if [ "$HOT_LINES" -gt "$HOT_BUDGET_LIMIT" ]; then
        echo ""
        echo "  ⚠ HOT-бюджет превышен: $HOT_LINES строк (лимит $HOT_BUDGET_LIMIT) в $CLAUDE_MEMORY_DIR"
        for entry in "${HOT_FILES[@]}"; do echo "      - $entry"; done
        echo "    Понизьте horizon: hot → warm для части файлов или сократите содержимое."
    fi
fi

# (Step 6b removed — repo rename no longer supported, no link migration needed)

# === Step 6b2: Ensure ~/.iwe-paths exists (WP-219, DP.FM.009) ===
# Lookup-слой env-переменных для путей к скриптам. Генерируется setup.sh,
# но при обновлении со старой версии (до WP-219) файл может отсутствовать.
IWE_PATHS_FILE="$HOME/.iwe-paths"
ZSHENV_FILE="$HOME/.zshenv"
if [ ! -f "$IWE_PATHS_FILE" ]; then
    cat > "$IWE_PATHS_FILE" <<IWEPATHS_EOF
# IWE environment variables
# Generated by update.sh (WP-219 migration). Rerun setup.sh or update.sh to regenerate.
# Do not edit manually — changes will be lost.

export IWE_WORKSPACE="$WORKSPACE_DIR"
export IWE_TEMPLATE="\$IWE_WORKSPACE/FMT-exocortex-template"
export IWE_SCRIPTS="\$IWE_TEMPLATE/scripts"
export IWE_ROLES="\$IWE_TEMPLATE/roles"
IWEPATHS_EOF
    echo "  ✓ Миграция WP-219: создан $IWE_PATHS_FILE"

    # Ensure ~/.zshenv sources ~/.iwe-paths (idempotent)
    if [ -f "$ZSHENV_FILE" ] && grep -qF '.iwe-paths' "$ZSHENV_FILE"; then
        : # already present
    else
        cat >> "$ZSHENV_FILE" <<'ZSHENV_EOF'

# IWE environment (WP-219, DP.FM.009): lookup-слой для путей к скриптам
[ -f "$HOME/.iwe-paths" ] && source "$HOME/.iwe-paths"
ZSHENV_EOF
        echo "  ✓ Миграция WP-219: $ZSHENV_FILE → sources \$HOME/.iwe-paths"
        echo "  ℹ  Перезапустите shell: source $ZSHENV_FILE"
    fi
fi

# === Step 6c: Regenerate .mcp.json in workspace (if template .mcp.json updated) ===
# .mcp.json is immune from direct overwrite — but if the template version changed,
# we regenerate the workspace copy with fresh variable substitution + user merge.
MCP_TEMPLATE="$SCRIPT_DIR/.mcp.json"
MCP_WORKSPACE="$WORKSPACE_DIR/.mcp.json"
MCP_USER="$WORKSPACE_DIR/extensions/mcp-user.json"

MCP_TEMPLATE_CHANGED=false
for f in "${NEW_FILES[@]}" "${UPDATED_FILES[@]}"; do
    if [ "$f" = ".mcp.json" ]; then MCP_TEMPLATE_CHANGED=true; break; fi
done

# === Step 6c: Migrate workspace .mcp.json to Gateway ===
# Strategy: migrate in-place first (preserving user servers), then fallback to template copy.
# This preserves any user-added MCP servers that are NOT in extensions/mcp-user.json.

if [ -f "$MCP_WORKSPACE" ] && command -v python3 >/dev/null 2>&1; then
    python3 -c "
import json, sys

with open('$MCP_WORKSPACE') as f:
    data = json.load(f)

servers = data.get('mcpServers', {})
old_keys = [k for k in servers if k in ('knowledge-mcp', 'digital-twin-mcp', 'personal-knowledge-mcp')]
changed = False

if old_keys:
    # Remove old stdio servers
    for k in old_keys:
        del servers[k]
    changed = True

if 'iwe-knowledge' not in servers:
    # Add new remote Gateway
    servers['iwe-knowledge'] = {'type': 'http', 'url': 'https://mcp.aisystant.com/mcp'}
    changed = True

if changed:
    # Move iwe-knowledge to the front, keep all other servers
    ordered = {'iwe-knowledge': servers.pop('iwe-knowledge')}
    ordered.update(servers)
    data['mcpServers'] = ordered
    with open('$MCP_WORKSPACE', 'w') as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write('\n')
    removed = ', '.join(old_keys) if old_keys else ''
    msg = '  ✓ .mcp.json мигрирован'
    if removed:
        msg += ': ' + removed + ' → iwe-knowledge (Gateway)'
    else:
        msg += ': добавлен iwe-knowledge (Gateway)'
    print(msg)
" 2>/dev/null
elif [ ! -f "$MCP_WORKSPACE" ] && [ -f "$MCP_TEMPLATE" ]; then
    # No workspace .mcp.json — copy from template
    cp "$MCP_TEMPLATE" "$MCP_WORKSPACE"
    echo "  ✓ .mcp.json создан из шаблона (Gateway)"
elif [ -f "$MCP_WORKSPACE" ] && ! command -v python3 >/dev/null 2>&1; then
    # No python3 — check if already migrated, otherwise warn
    if grep -q 'iwe-knowledge' "$MCP_WORKSPACE" 2>/dev/null; then
        echo "  ✓ .mcp.json уже содержит iwe-knowledge"
    else
        echo "  ⚠ .mcp.json: python3 не найден, автомиграция пропущена."
        echo "    Замените knowledge-mcp/digital-twin-mcp на iwe-knowledge вручную."
        echo "    Образец: $MCP_TEMPLATE"
    fi
fi

# Merge extensions/mcp-user.json into workspace .mcp.json (always, if both exist)
if [ -f "$MCP_WORKSPACE" ] && [ -f "$MCP_USER" ]; then
    if command -v jq >/dev/null 2>&1; then
        USER_COUNT=$(jq '.mcpServers | length' "$MCP_USER" 2>/dev/null || echo "0")
        if [ "$USER_COUNT" -gt 0 ]; then
            MCP_MERGED=$(jq -s '.[0].mcpServers * .[1].mcpServers | {mcpServers: .}' "$MCP_WORKSPACE" "$MCP_USER" 2>/dev/null)
            if [ -n "$MCP_MERGED" ]; then
                echo "$MCP_MERGED" > "$MCP_WORKSPACE"
                echo "  ✓ .mcp.json — $USER_COUNT пользовательских MCP из extensions/mcp-user.json добавлены"
            fi
        fi
    else
        echo "  ○ .mcp.json — jq не установлен, мёрж extensions/mcp-user.json пропущен"
        echo "    Установите jq: brew install jq"
    fi
fi

# === Step 6d: Rebuild generated runtime ПЕРЕД roles reinstall (WP-273 R5 fix) ===
# Round 5 Евгения обнаружил порядковую проблему: roles reinstall вызывался ДО build-runtime,
# из-за чего install.sh брал плисты из устаревшего .iwe-runtime/ или legacy FMT с placeholder'ами.
# Правильный порядок: сначала пересобрать .iwe-runtime/ из актуального FMT + .exocortex.env,
# потом install.sh каждой роли (чтение из свежего runtime).
if [ -x "$SCRIPT_DIR/setup/build-runtime.sh" ] || [ -f "$SCRIPT_DIR/setup/build-runtime.sh" ]; then
    echo ""
    echo "Generated runtime (.iwe-runtime/)..."
    bash "$SCRIPT_DIR/setup/build-runtime.sh" \
        --workspace "$WORKSPACE_DIR" \
        --env-file "${WORKSPACE_DIR}/.exocortex.env" \
        --quiet 2>&1 | sed 's/^/  /' || \
        echo "  ⚠ build-runtime.sh завершился с ошибкой. Запустите вручную: bash $SCRIPT_DIR/setup/build-runtime.sh"
fi

# Reinstall roles if changed (ПОСЛЕ build-runtime — install читает из свежего .iwe-runtime/)
ROLES_CHANGED=false
for f in "${NEW_FILES[@]}" "${UPDATED_FILES[@]}"; do
    case "$f" in roles/*)
        ROLES_CHANGED=true
        break
        ;;
    esac
done

if $ROLES_CHANGED && command -v launchctl >/dev/null 2>&1; then
    echo ""
    echo "Роли обновлены. Переустановка..."
    # Source ~/.iwe-paths (если есть) — гарантирует IWE_RUNTIME/IWE_TEMPLATE в env для install.sh
    [ -f "$HOME/.iwe-paths" ] && . "$HOME/.iwe-paths"
    for role_dir in "$SCRIPT_DIR"/roles/*/; do
        [ -f "$role_dir/install.sh" ] && [ -f "$role_dir/role.yaml" ] || continue
        if grep -q 'auto:.*true' "$role_dir/role.yaml" 2>/dev/null; then
            bash "$role_dir/install.sh" 2>/dev/null && \
                echo "  ✓ $(basename "$role_dir") переустановлен" || \
                echo "  ○ $(basename "$role_dir"): переустановите вручную"
        fi
    done
fi

# === Step 6e: Replace local manifest with downloaded remote manifest ===
# Replaces entire manifest (files + deprecated_files + version), not just version field.
# This ensures validators (D1/D9/D10) and future updates see the correct file list.
if [ -f "$MANIFEST" ]; then
    cp "$MANIFEST" "$SCRIPT_DIR/update-manifest.json" \
        && echo "  • update-manifest.json: заменён remote manifest (v$UPSTREAM_VERSION)"
fi

# === Step 6f: Orphan detection — L1 files not in manifest ===
# Warn about files present on disk in L1 directories that are not listed in
# update-manifest.json (neither in files[] nor deprecated_files[]).
# These may be stale user customisations or files left over from a renamed skill.
# Never auto-deletes; always informational only.
if command -v python3 &>/dev/null && [ -f "$SCRIPT_DIR/update-manifest.json" ]; then
    ORPHAN_OUTPUT=$(python3 - <<'PYEOF'
import json, os

script_dir = os.path.dirname(os.path.abspath(__file__))
manifest_path = os.path.join(script_dir, "update-manifest.json")

with open(manifest_path) as f:
    manifest = json.load(f)

def _path(e): return e["path"] if isinstance(e, dict) else e
known = {_path(e) for e in manifest.get("files", [])}
deprecated = {_path(e) for e in manifest.get("deprecated_files", [])}
all_known = known | deprecated

L1_DIRS = [".claude/hooks", ".claude/rules", ".claude/skills"]
L1_PREFIXES = ["memory/protocol-"]

orphans = []
for base in L1_DIRS:
    full_base = os.path.join(script_dir, base)
    if not os.path.isdir(full_base):
        continue
    for root, dirs, files in os.walk(full_base):
        for fname in files:
            full = os.path.join(root, fname)
            rel = os.path.relpath(full, script_dir)
            if rel not in all_known:
                tag = "[maybe-L3]" if "extensions/" in rel else "[orphan]"
                orphans.append((tag, rel))

for tag, rel in sorted(orphans):
    print(f"  {tag} {rel}")
PYEOF
)
    if [ -n "$ORPHAN_OUTPUT" ]; then
        echo ""
        echo "⚠  Файлы в L1-директориях не найдены в манифесте (не удалять автоматически):"
        echo "$ORPHAN_OUTPUT"
        echo "   [orphan]   — возможно устаревший платформенный файл; удалите вручную или"
        echo "               добавьте в deprecated_files если это намеренно удалённый артефакт."
        echo "   [maybe-L3] — возможно пользовательское расширение (extensions/)."
    fi
fi

# === Step 7: Commit changes ===
echo ""
echo "Фиксация изменений..."
cd "$SCRIPT_DIR"

# issue #226: если HEAD стоит не на дефолтной ветке (например, контрибьютор оставил
# чекаут на PR-ветке после предыдущей работы), автокоммит обновления загрязнит эту
# ветку. Предупредить и, без явного согласия, коммит пропустить.
CURRENT_BRANCH="$(git branch --show-current 2>/dev/null || true)"
SKIP_COMMIT=false
if [ -n "$CURRENT_BRANCH" ] && [ "$CURRENT_BRANCH" != "$BRANCH" ]; then
    echo "⚠ Текущая ветка репозитория — '$CURRENT_BRANCH', не '$BRANCH'."
    echo "  Коммит обновления попадёт в неё и может загрязнить открытый PR."
    if $AUTO_YES; then
        echo "  Коммит пропущен (--yes на нестандартной ветке)."
        echo "  Переключитесь на '$BRANCH' и запустите update.sh снова, либо закоммитьте вручную."
        SKIP_COMMIT=true
    else
        read -p "  Всё равно закоммитить в '$CURRENT_BRANCH'? (y/n) " -n 1 -r
        echo ""
        [[ $REPLY =~ ^[Yy]$ ]] || SKIP_COMMIT=true
    fi
fi

if ! $SKIP_COMMIT; then
    if ! git diff --quiet 2>/dev/null || [ -n "$(git ls-files --others --exclude-standard 2>/dev/null)" ]; then
        git add -A
        git commit -m "chore: update from upstream template v$UPSTREAM_VERSION" --no-verify 2>&1 | sed 's/^/  /'
        echo "  ✓ Изменения закоммичены"
    else
        echo "  Нет изменений для коммита"
    fi
fi

# === Step 7.5: Migration hint — initial-marker для old clones (0.28.5+) ===
# Если у пользователя есть Strategy.md без маркера IWE-INITIAL-NEEDED — намекнуть.
# Это для пользователей, склонировавших до 0.28.5 (skeleton-marker появился в 0.28.5).
# WP-273 0.29.4 R6.4 fix: после WP-273 .exocortex.env живёт в workspace, не в FMT.
# Раньше использовали $SCRIPT_DIR (FMT) → файла там нет → hint никогда не показывался.
ENV_FILE="${WORKSPACE_DIR}/.exocortex.env"
if [ -f "$ENV_FILE" ]; then
    ENV_WS=$(grep -E '^WORKSPACE_DIR=' "$ENV_FILE" | head -1 | cut -d= -f2-)
    ENV_GOV=$(grep -E '^GOVERNANCE_REPO=' "$ENV_FILE" | head -1 | cut -d= -f2-)
    USER_STRATEGY="${ENV_WS:-}/${ENV_GOV:-DS-strategy}/docs/Strategy.md"
    if [ -f "$USER_STRATEGY" ] && ! grep -qF 'IWE-INITIAL-NEEDED' "$USER_STRATEGY"; then
        if grep -qE '^created: YYYY-MM-DD$|^updated: YYYY-MM-DD$' "$USER_STRATEGY" 2>/dev/null; then
            echo ""
            echo "⚠ Strategy.md выглядит как seed-скелет, но без маркера IWE-INITIAL-NEEDED (0.28.5+)."
            echo "  Чтобы /strategy-session корректно ушёл в initial flow, добавьте маркер:"
            echo "    bash $SCRIPT_DIR/scripts/migrate-initial-marker.sh"
        fi
    fi
fi

# === Done ===
echo ""
echo "=========================================="
SUMMARY_MSG="  Обновление завершено ($APPLIED файлов"
[ "$REMOVED" -gt 0 ] && SUMMARY_MSG="$SUMMARY_MSG, $REMOVED удалено"
SUMMARY_MSG="$SUMMARY_MSG)"
echo "$SUMMARY_MSG"
echo "=========================================="
echo ""
echo "Перезапустите Claude Code для применения обновлений в memory/."

# issue #226: остальная доставка (memory/hooks/skills, repair-pass, коммит) уже
# выполнена выше независимо от конфликта — теперь сообщаем и выходим с ошибкой,
# чтобы CI/скрипты-обёртки увидели неуспех, а пилот — список файлов на разрешение.
if $CLAUDE_CONFLICT_DETECTED; then
    echo ""
    echo "⚠ CLAUDE.md содержит неразрешённые конфликты слияния в:"
    for cf in "${CLAUDE_CONFLICT_FILES[@]}"; do echo "  - $cf"; done
    echo "  Разрешите их вручную (маркеры <<<<<<< / ======= / >>>>>>>) и закоммитьте отдельно."
    exit "$EXIT_CONFLICT"
fi
