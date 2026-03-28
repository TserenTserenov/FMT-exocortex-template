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

VERSION="2.0.0"
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
            DIFF_COUNT=$(diff "$SCRIPT_DIR/$fpath" "$REMOTE_FILE" 2>/dev/null | grep -c '^[<>]' || echo "?")
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
echo "  ✓ .secrets/, .mcp.json (ключи и конфигурация)"
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
                CONFLICT_COUNT=$(grep -c '^<<<<<<<' "$TMPDIR_UPDATE/claude-merged.md" 2>/dev/null || echo "0")
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

# === Step 5b: Re-substitute placeholders in new/updated files ===
# After downloading from upstream, files contain {{PLACEHOLDERS}}.
# Read saved configuration from .exocortex.env (created by setup.sh).
echo ""
echo "Подстановка переменных..."

ENV_FILE="$SCRIPT_DIR/.exocortex.env"

if [ -f "$ENV_FILE" ]; then
    # Validate: only KEY=VALUE lines allowed (no shell commands)
    if grep -qE '^\s*(source|eval|exec|\.|`|;|\$\()' "$ENV_FILE" 2>/dev/null; then
        echo "  ОШИБКА: .exocortex.env содержит недопустимые конструкции. Пропускаю подстановку."
        echo "  Пересоздайте: bash setup.sh"
    else
        # Read variables safely (only simple KEY=VALUE)
        while IFS='=' read -r key value; do
            # Skip comments and empty lines
            case "$key" in \#*|"") continue ;; esac
            # Trim whitespace
            key=$(echo "$key" | tr -d '[:space:]')
            # Export for use below
            declare "ENV_$key=$value"
        done < "$ENV_FILE"

        PLACEHOLDER_HIT=0
        for f in "${NEW_FILES[@]}" "${UPDATED_FILES[@]}"; do
            filepath="$SCRIPT_DIR/$f"
            [ -f "$filepath" ] || continue

            if grep -q '{{[A-Z_]*}}' "$filepath" 2>/dev/null; then
                sed_inplace \
                    -e "s|{{GITHUB_USER}}|${ENV_GITHUB_USER:-}|g" \
                    -e "s|{{EXOCORTEX_REPO}}|${ENV_EXOCORTEX_REPO:-}|g" \
                    -e "s|{{WORKSPACE_DIR}}|${ENV_WORKSPACE_DIR:-}|g" \
                    -e "s|{{CLAUDE_PATH}}|${ENV_CLAUDE_PATH:-}|g" \
                    -e "s|{{CLAUDE_PROJECT_SLUG}}|${ENV_CLAUDE_PROJECT_SLUG:-}|g" \
                    -e "s|{{TIMEZONE_HOUR}}|${ENV_TIMEZONE_HOUR:-}|g" \
                    -e "s|{{TIMEZONE_DESC}}|${ENV_TIMEZONE_DESC:-}|g" \
                    -e "s|{{HOME_DIR}}|${ENV_HOME_DIR:-$HOME}|g" \
                    "$filepath"
                PLACEHOLDER_HIT=$((PLACEHOLDER_HIT + 1))
            fi

            # Replace template repo name with user's repo name (skip UPSTREAM-CONST lines)
            if [ -n "${ENV_EXOCORTEX_REPO:-}" ] && grep -q 'FMT-exocortex-template' "$filepath" 2>/dev/null; then
                sed_inplace "/UPSTREAM-CONST/!s|FMT-exocortex-template|${ENV_EXOCORTEX_REPO}|g" "$filepath"
            fi
        done

        if [ "$PLACEHOLDER_HIT" -gt 0 ]; then
            echo "  Подставлено переменных в $PLACEHOLDER_HIT файлах."
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
GITHUB_USER=your-username
EXOCORTEX_REPO=$DETECTED_REPO
WORKSPACE_DIR=$DETECTED_WORKSPACE
CLAUDE_PATH=$(command -v claude 2>/dev/null || echo '/opt/homebrew/bin/claude')
CLAUDE_PROJECT_SLUG=$(echo "$DETECTED_WORKSPACE" | tr '/' '-')
TIMEZONE_HOUR=4
TIMEZONE_DESC=4:00 UTC
HOME_DIR=$HOME
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
                WS_CONFLICTS=$(grep -c '^<<<<<<<' "$TMPDIR_UPDATE/ws-claude-merged.md" 2>/dev/null || echo "0")
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

# Propagate skills, hooks, rules to workspace if changed
for f in "${NEW_FILES[@]}" "${UPDATED_FILES[@]}"; do
    case "$f" in .claude/skills/*|.claude/hooks/*|.claude/rules/*|.claude/settings.json)
        src="$SCRIPT_DIR/$f"
        dst="$WORKSPACE_DIR/$f"
        mkdir -p "$(dirname "$dst")"
        cp "$src" "$dst"
        echo "  ✓ $f → workspace"
        ;;
    esac
done

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

# === Done ===
echo ""
echo "=========================================="
echo "  Обновление завершено ($APPLIED файлов)"
echo "=========================================="
echo ""
echo "Перезапустите Claude Code для применения обновлений в memory/."
