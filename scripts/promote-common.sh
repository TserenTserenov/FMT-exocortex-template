#!/bin/bash
# routing: helper  skill=script-promote,skill-promote,hook-promote,settings-promote  called-by=script
# see DP.SC.159, DP.ROLE.059
# promote-common.sh — общая библиотека для promote-скриптов
#
# Содержит:
#   record_promotion()   — append запись о промоции в promotion-status.yaml
#   record_extension()   — append запись об отключаемом расширении в marketplace-manifest.yaml
#
# Использование (из других promote-скриптов):
#   source "$FMT_DIR/scripts/promote-common.sh"
#   record_promotion "<path>" "<type>" "<source_sha>" "<fmt_sha>" "<verified_in_clean_env>"
#   record_extension "<path>" "<type>" "<owner>" "<install_point>" "<permissions>" "<toggleable>" "<conflict_rule>" "<staging_source>"

# Не запускать напрямую — это библиотека.
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && { echo "[ERROR] promote-common.sh is a library — source it" >&2; exit 1; }

# record_promotion — append запись в promotion-status.yaml (идемпотентный для незавершённых SHA)
# Параметры:
#   $1 artifact_path    — относительный путь от FMT_DIR (например: .claude/skills/bottleneck-pick)
#   $2 type             — skill|script|hook|rule|protocol|catalog
#   $3 source_sha       — git short SHA из автора (если есть, иначе "")
#   $4 fmt_sha          — git short SHA из FMT (предполагается, что коммит уже сделан)
#   $5 verified_in_clean_env — true|false|na
#
# Schema файла promotion-status.yaml:
#   ---
#   schema_version: 1
#   updated_at: <ISO-8601 UTC>
#   ---
#   promotions:
#     - artifact_path: ...
#       type: ...
#       source_sha: ...
#       fmt_sha: ...
#       promoted_at: ...
#       verified_in_clean_env: ...
record_promotion() {
    local artifact_path="$1"
    local type="$2"
    local source_sha="${3:-}"
    local fmt_sha="${4:-}"
    local verified="${5:-na}"

    local fmt_dir="${IWE_TEMPLATE:-${IWE_WORKSPACE:-$HOME/IWE}/FMT-exocortex-template}"
    local status_file="$fmt_dir/promotion-status.yaml"
    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # Инициализация файла при первом вызове
    if [[ ! -f "$status_file" ]]; then
        cat > "$status_file" <<EOF
---
schema_version: 1
updated_at: $now
---
# promotion-status.yaml — журнал промоций артефактов из author IWE в FMT
# see DP.SC.NNN, WP-7/PZ-6
# Writer: scripts/promote-common.sh::record_promotion()
# Append-only: новые записи добавляются вниз; редактировать вручную не рекомендуется.
promotions:
EOF
    fi

    # Идемпотентность: если для этого артефакта уже есть незавершённая запись
    # (пустые source_sha и fmt_sha), не дублировать — обновить only updated_at.
    # Это covers повторные запуски promote до коммита.
    if [[ -z "$source_sha" && -z "$fmt_sha" ]]; then
        local last_pending
        last_pending=$(grep -n "artifact_path: $artifact_path$" "$status_file" 2>/dev/null | tail -1 | cut -d: -f1 || true)
        if [[ -n "$last_pending" ]]; then
            # Проверить, что эта запись имеет пустые SHA
            local block_end
            block_end=$((last_pending + 5))
            local block
            block=$(sed -n "${last_pending},${block_end}p" "$status_file" 2>/dev/null || true)
            if echo "$block" | grep -q 'source_sha: ""' && echo "$block" | grep -q 'fmt_sha: ""'; then
                sed -i.bak "s/^updated_at:.*/updated_at: $now/" "$status_file" \
                    && rm -f "$status_file.bak" \
                    || { echo "[ERROR] обновление updated_at не удалось, backup сохранён: $status_file.bak" >&2; return 1; }
                echo "📝 promotion-status.yaml: обновлена существующая незавершённая запись $artifact_path ($type)"
                return 0
            fi
        fi
    fi

    # Append запись
    cat >> "$status_file" <<EOF
  - artifact_path: $artifact_path
    type: $type
    source_sha: "$source_sha"
    fmt_sha: "$fmt_sha"
    promoted_at: $now
    verified_in_clean_env: $verified
EOF

    # Обновить updated_at (sed in-place, macOS compatible)
    sed -i.bak "s/^updated_at:.*/updated_at: $now/" "$status_file" \
        && rm -f "$status_file.bak" \
        || { echo "[ERROR] обновление updated_at не удалось, backup сохранён: $status_file.bak" >&2; return 1; }

    echo "📝 promotion-status.yaml: записано $artifact_path ($type)"
}

# record_extension — append запись об отключаемом расширении в marketplace-manifest.yaml
# (ADR-IWE-014 R9, WP-552 Ф5: ветка «расширение маркетплейса» — обязательное правило шаблона
# записывается через record_promotion() выше, отключаемое — через эту функцию)
# Параметры:
#   $1 artifact_path    — относительный путь от FMT_DIR
#   $2 type             — существующий тип артефакта: pack|skill|AR.NNN|role
#   $3 owner            — кто сопровождает расширение
#   $4 install_point    — куда устанавливается (директория/точка подключения)
#   $5 permissions      — какие разрешения расширение запрашивает
#   $6 toggleable       — true|false (отключаемость)
#   $7 conflict_rule    — что делать при конфликте с другим расширением/правилом
#   $8 staging_source   — строка STAGING.md, из которой промотировано (аудируемость теста R8)
#
# Schema файла marketplace-manifest.yaml:
#   ---
#   schema_version: 1
#   updated_at: <ISO-8601 UTC>
#   ---
#   extensions:
#     - artifact_path: ...
#       type: ...
#       owner: ...
#       install_point: ...
#       permissions: ...
#       toggleable: ...
#       conflict_rule: ...
#       staging_source: ...
#       promoted_at: ...
record_extension() {
    local artifact_path="$1"
    local type="$2"
    local owner="$3"
    local install_point="$4"
    local permissions="$5"
    local toggleable="$6"
    local conflict_rule="$7"
    local staging_source="$8"

    local fmt_dir="${IWE_TEMPLATE:-${IWE_WORKSPACE:-$HOME/IWE}/FMT-exocortex-template}"
    local manifest_file="$fmt_dir/marketplace-manifest.yaml"
    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    if [[ ! -f "$manifest_file" ]]; then
        cat > "$manifest_file" <<EOF
---
schema_version: 1
updated_at: $now
---
# marketplace-manifest.yaml — реестр отключаемых расширений (ADR-IWE-014 R9)
# see WP-552 Ф5, promote-common.sh::record_extension()
# Writer: scripts/promote-common.sh::record_extension()
# Append-only: новые записи добавляются вниз; редактировать вручную не рекомендуется.
extensions:
EOF
    fi

    cat >> "$manifest_file" <<EOF
  - artifact_path: $artifact_path
    type: $type
    owner: "$owner"
    install_point: "$install_point"
    permissions: "$permissions"
    toggleable: $toggleable
    conflict_rule: "$conflict_rule"
    staging_source: "$staging_source"
    promoted_at: $now
EOF

    sed -i.bak "s/^updated_at:.*/updated_at: $now/" "$manifest_file" \
        && rm -f "$manifest_file.bak" \
        || { echo "[ERROR] обновление updated_at не удалось, backup сохранён: $manifest_file.bak" >&2; return 1; }

    echo "📝 marketplace-manifest.yaml: записано $artifact_path (owner: $owner)"
}
