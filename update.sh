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

VERSION="2.1.0"  # WP-273 Этап 2: Generated runtime architecture (F)
REPO="TserenTserenov/FMT-exocortex-template" # UPSTREAM-CONST: do not substitute
BRANCH="main"
RAW_BASE="https://raw.githubusercontent.com/$REPO/$BRANCH"

CHECK_ONLY=false
AUTO_YES=false

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

# === Detect directories ===
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ ! -f "$SCRIPT_DIR/CLAUDE.md" ]; then
    echo "ОШИБКА: Запускайте из корня экзокортекс-репо."
    echo "  cd /path/to/your-exocortex && bash update.sh"
    exit 1
fi

WORKSPACE_DIR="$(dirname "$SCRIPT_DIR")"

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
REMOTE_UPDATE="$TMPDIR_UPDATE/update.sh.new"
if curl -sSfL "$RAW_BASE/update.sh" -o "$REMOTE_UPDATE" 2>/dev/null; then
    LOCAL_HASH=$(hash_file "$SCRIPT_DIR/update.sh")
    REMOTE_HASH=$(hash_file "$REMOTE_UPDATE")
    if [ "$LOCAL_HASH" != "$REMOTE_HASH" ]; then
        echo "  Найдена новая версия update.sh — обновляю..."
        cp "$REMOTE_UPDATE" "$SCRIPT_DIR/update.sh"
        chmod +x "$SCRIPT_DIR/update.sh"
        echo "  Перезапуск..."
        exec bash "$SCRIPT_DIR/update.sh" "$@"
    fi
fi
echo "  update.sh актуален."
echo ""

# === Step 1: Fetch manifest ===
echo "[1] Загрузка манифеста..."
MANIFEST_URL="$RAW_BASE/update-manifest.json"
MANIFEST="$TMPDIR_UPDATE/manifest.json"

if ! curl -sSfL "$MANIFEST_URL" -o "$MANIFEST" 2>/dev/null; then
    echo "ОШИБКА: Не удалось загрузить манифест обновлений."
    echo "  URL: $MANIFEST_URL"
    echo "  Проверьте подключение к интернету."
    exit 1
fi

# Parse version from manifest
UPSTREAM_VERSION=$(grep '"version"' "$MANIFEST" | head -1 | sed 's/.*"version"[[:space:]]*:[[:space:]]*"//;s/".*//')
echo "  Версия upstream: $UPSTREAM_VERSION"
echo ""

# === Step 2: Download and compare files ===
echo "[2] Сравнение файлов..."

NEW_FILES=()
NEW_DESCS=()
UPDATED_FILES=()
UPDATED_LINES=()
UNCHANGED=0

# Parse manifest: extract path and desc for each file entry
while IFS='|' read -r fpath fdesc; do
    [ -z "$fpath" ] && continue

    # Download remote file
    REMOTE_FILE="$TMPDIR_UPDATE/files/$fpath"
    mkdir -p "$(dirname "$REMOTE_FILE")"

    if ! curl -sSfL "$RAW_BASE/$fpath" -o "$REMOTE_FILE" 2>/dev/null; then
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

TOTAL_CHANGES=$(( ${#NEW_FILES[@]} + ${#UPDATED_FILES[@]} ))

# === Step 3: Display results ===
echo ""
echo "=========================================="
echo "  Обновления экзокортекса (v$UPSTREAM_VERSION)"
echo "=========================================="
echo ""

if [ "$TOTAL_CHANGES" -eq 0 ]; then
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

echo "Не затрагиваются:"
echo "  ✓ memory/MEMORY.md (личная оперативная память)"
echo "  ✓ CLAUDE.md (3-way merge: ваши правки сохраняются)"
echo "  ✓ extensions/ (ваши расширения протоколов)"
echo "  ✓ params.yaml (ваши параметры)"
echo "  ✓ .secrets/ (ключи)"
echo "  ✓ .claude/settings.local.json (permissions)"
echo "  ✓ personal/ (ваши файлы)"
echo "  ✓ DS-strategy/ (ваше планирование)"
echo ""

if [ "$UNCHANGED" -gt 0 ]; then
    echo "Без изменений: $UNCHANGED файлов"
    echo ""
fi

# === Check-only mode ===
if $CHECK_ONLY; then
    echo "Режим --check: изменения не применяются."
    echo "Для применения: bash update.sh"
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
    else
        cp "$TMPDIR_UPDATE/files/$f" "$SCRIPT_DIR/$f"
        case "$f" in *.sh) chmod +x "$SCRIPT_DIR/$f" ;; esac
        echo "  ~ $f"
    fi
    APPLIED=$((APPLIED + 1))
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
        # Substituted значения генерируются build-runtime.sh в .iwe-runtime/ (Step 8 ниже).
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
            if [ -d "${DETECT_WS}/DS-strategy" ]; then
                DETECTED_GOV="DS-strategy"
            else
                for d in "${DETECT_WS}"/DS-*; do
                    case "${d##*/}" in
                        DS-*strategy*) DETECTED_GOV="${d##*/}"; break ;;
                    esac
                done
            fi
            if [ -z "$DETECTED_GOV" ]; then
                DETECTED_GOV="DS-strategy"
                echo "  ⚠ Governance repo не найден в $DETECT_WS — fallback DS-strategy. Проверьте .exocortex.env вручную."
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

# Check remaining placeholders
REMAINING=$(grep -rl '{{[A-Z_]*}}' "$SCRIPT_DIR" --include="*.md" --include="*.sh" --include="*.json" --include="*.yaml" --include="*.yml" 2>/dev/null | wc -l | tr -d ' ')
if [ "$REMAINING" -gt 0 ]; then
    echo "  ⚠ $REMAINING файлов содержат незаменённые переменные."
    echo "  Проверьте .exocortex.env и перезапустите: bash update.sh"
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
                if [ "$WS_CONFLICTS" -gt 0 ]; then
                    echo "  ✓ $WS_CURRENT обновлён (3-way merge, $WS_CONFLICTS конфликтов)"
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
CLAUDE_PROJECT_SLUG="$(echo "$WORKSPACE_DIR" | tr '/' '-')"
CLAUDE_MEMORY_DIR="$HOME/.claude/projects/$CLAUDE_PROJECT_SLUG/memory"

if [ -d "$CLAUDE_MEMORY_DIR" ]; then
    MEM_UPDATED=0
    for f in "${NEW_FILES[@]}" "${UPDATED_FILES[@]}"; do
        case "$f" in
            memory/*.md)
                fname=$(basename "$f")
                if [ "$fname" != "MEMORY.md" ]; then
                    cp "$SCRIPT_DIR/$f" "$CLAUDE_MEMORY_DIR/$fname"
                    MEM_UPDATED=$((MEM_UPDATED + 1))
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
    case "$f" in .claude/skills/*|.claude/hooks/*|.claude/rules/*|.claude/lib/*|.claude/config/*|.claude/detectors/*|.claude/settings.json)
        src="$SCRIPT_DIR/$f"
        dst="$WORKSPACE_DIR/$f"
        mkdir -p "$(dirname "$dst")"
        cp "$src" "$dst"
        echo "  ✓ $f → workspace"
        ;;
    esac
done

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

# Reinstall roles if changed
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
    for role_dir in "$SCRIPT_DIR"/roles/*/; do
        [ -f "$role_dir/install.sh" ] && [ -f "$role_dir/role.yaml" ] || continue
        if grep -q 'auto:.*true' "$role_dir/role.yaml" 2>/dev/null; then
            bash "$role_dir/install.sh" 2>/dev/null && \
                echo "  ✓ $(basename "$role_dir") переустановлен" || \
                echo "  ○ $(basename "$role_dir"): переустановите вручную"
        fi
    done
fi

# === Step 7: Commit changes ===
echo ""
echo "Фиксация изменений..."
cd "$SCRIPT_DIR"
if ! git diff --quiet 2>/dev/null || [ -n "$(git ls-files --others --exclude-standard 2>/dev/null)" ]; then
    git add -A
    git commit -m "chore: update from upstream template v$UPSTREAM_VERSION" --no-verify 2>&1 | sed 's/^/  /'
    echo "  ✓ Изменения закоммичены"
else
    echo "  Нет изменений для коммита"
fi

# === Step 7.5: Migration hint — initial-marker для old clones (0.28.5+) ===
# Если у пользователя есть Strategy.md без маркера IWE-INITIAL-NEEDED — намекнуть.
# Это для пользователей, склонировавших до 0.28.5 (skeleton-marker появился в 0.28.5).
ENV_FILE="$SCRIPT_DIR/.exocortex.env"
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

# === Step 8: Rebuild generated runtime (WP-273 Этап 2, архитектура F) ===
# Идемпотентный rebuild $WORKSPACE_DIR/.iwe-runtime/ из обновлённого FMT + .exocortex.env.
# Закрывает R4.6 (self-heal): даже если update прервался, повторный запуск чинит drift.
if [ -x "$SCRIPT_DIR/setup/build-runtime.sh" ] || [ -f "$SCRIPT_DIR/setup/build-runtime.sh" ]; then
    echo ""
    echo "Generated runtime (.iwe-runtime/)..."
    bash "$SCRIPT_DIR/setup/build-runtime.sh" \
        --workspace "$WORKSPACE_DIR" \
        --env-file "${WORKSPACE_DIR}/.exocortex.env" \
        --quiet 2>&1 | sed 's/^/  /' || \
        echo "  ⚠ build-runtime.sh завершился с ошибкой. Запустите вручную: bash $SCRIPT_DIR/setup/build-runtime.sh"
fi

# === Done ===
echo ""
echo "=========================================="
echo "  Обновление завершено ($APPLIED файлов)"
echo "=========================================="
echo ""
echo "Перезапустите Claude Code для применения обновлений в memory/."
