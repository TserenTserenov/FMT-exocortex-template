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
REPO="TserenTserenov/FMT-exocortex-template"
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
    LOCAL_HASH=$(shasum -a 256 "$SCRIPT_DIR/update.sh" 2>/dev/null | cut -d' ' -f1)
    REMOTE_HASH=$(shasum -a 256 "$REMOTE_UPDATE" 2>/dev/null | cut -d' ' -f1)
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
        LOCAL_HASH=$(shasum -a 256 "$SCRIPT_DIR/$fpath" 2>/dev/null | cut -d' ' -f1)
        REMOTE_HASH=$(shasum -a 256 "$REMOTE_FILE" 2>/dev/null | cut -d' ' -f1)
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
echo "  ✓ CLAUDE.md § «Мои правила» (секция USER-SPACE)"
echo "  ✓ .secrets/, .mcp.json (ключи и конфигурация)"
echo "  ✓ .claude/settings.local.json (permissions, MCP)"
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
    # Special handling for CLAUDE.md: preserve USER-SPACE section
    if [ "$f" = "CLAUDE.md" ] && [ -f "$SCRIPT_DIR/$f" ]; then
        USER_SECTION=$(sed -n '/^<!-- USER-SPACE/,/^<!-- \/USER-SPACE/p' "$SCRIPT_DIR/$f")
        cp "$TMPDIR_UPDATE/files/$f" "$SCRIPT_DIR/$f"
        if [ -n "$USER_SECTION" ]; then
            # Remote file has empty USER-SPACE template — replace it with user's content
            # Remove the template USER-SPACE block from downloaded file
            sed_inplace '/^<!-- USER-SPACE/,/^<!-- \/USER-SPACE/d' "$SCRIPT_DIR/$f"
            # Append user's preserved section
            echo "" >> "$SCRIPT_DIR/$f"
            echo "$USER_SECTION" >> "$SCRIPT_DIR/$f"
            echo "  ~ $f (USER-SPACE сохранён)"
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

# === Step 5b: Re-substitute placeholders in new/updated files ===
# After downloading from upstream, files contain {{PLACEHOLDERS}}
# Detect current values from existing configured files
echo ""
echo "Подстановка переменных..."

# Try to detect WORKSPACE_DIR from existing CLAUDE.md
DETECTED_WORKSPACE=""
if [ -f "$WORKSPACE_DIR/CLAUDE.md" ]; then
    # Look for workspace path patterns (e.g., ~/IWE or /Users/x/IWE)
    DETECTED_WORKSPACE="$WORKSPACE_DIR"
fi

PLACEHOLDER_HIT=0
for f in "${NEW_FILES[@]}" "${UPDATED_FILES[@]}"; do
    filepath="$SCRIPT_DIR/$f"
    [ -f "$filepath" ] || continue

    if grep -q '{{WORKSPACE_DIR}}' "$filepath" 2>/dev/null; then
        if [ -n "$DETECTED_WORKSPACE" ]; then
            sed_inplace "s|{{WORKSPACE_DIR}}|$DETECTED_WORKSPACE|g" "$filepath"
            PLACEHOLDER_HIT=$((PLACEHOLDER_HIT + 1))
        fi
    fi
    if grep -q '{{HOME_DIR}}' "$filepath" 2>/dev/null; then
        sed_inplace "s|{{HOME_DIR}}|$HOME|g" "$filepath"
        PLACEHOLDER_HIT=$((PLACEHOLDER_HIT + 1))
    fi
done

if [ "$PLACEHOLDER_HIT" -gt 0 ]; then
    echo "  Подставлено переменных в $PLACEHOLDER_HIT файлах."
fi

# Check remaining placeholders
REMAINING=$(grep -rl '{{[A-Z_]*}}' "$SCRIPT_DIR" --include="*.md" --include="*.sh" --include="*.json" --include="*.yaml" --include="*.yml" 2>/dev/null | wc -l | tr -d ' ')
if [ "$REMAINING" -gt 0 ]; then
    echo "  ⚠ $REMAINING файлов содержат незаменённые переменные."
    echo "  Для полной подстановки: bash setup.sh"
fi

# === Step 6: Reinstall platform-space ===
echo ""
echo "Обновление platform-space..."

# Copy CLAUDE.md to workspace root
CLAUDE_UPDATED=false
for f in "${NEW_FILES[@]}" "${UPDATED_FILES[@]}"; do
    if [ "$f" = "CLAUDE.md" ]; then
        # Preserve USER-SPACE from workspace CLAUDE.md (may differ from repo copy)
        if [ -f "$WORKSPACE_DIR/CLAUDE.md" ]; then
            WS_USER_SECTION=$(sed -n '/^<!-- USER-SPACE/,/^<!-- \/USER-SPACE/p' "$WORKSPACE_DIR/CLAUDE.md")
        fi
        cp "$SCRIPT_DIR/CLAUDE.md" "$WORKSPACE_DIR/CLAUDE.md"
        if [ -n "${WS_USER_SECTION:-}" ]; then
            sed_inplace '/^<!-- USER-SPACE/,/^<!-- \/USER-SPACE/d' "$WORKSPACE_DIR/CLAUDE.md"
            echo "" >> "$WORKSPACE_DIR/CLAUDE.md"
            echo "$WS_USER_SECTION" >> "$WORKSPACE_DIR/CLAUDE.md"
        fi
        echo "  ✓ $WORKSPACE_DIR/CLAUDE.md обновлён"
        CLAUDE_UPDATED=true
    fi
done

# Copy memory files to Claude projects directory
CLAUDE_PROJECT_SLUG="-$(echo "$WORKSPACE_DIR" | tr '/' '-')"
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
