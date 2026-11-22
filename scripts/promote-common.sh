#!/bin/bash
# routing: helper  skill=script-promote,skill-promote,hook-promote,settings-promote  called-by=script
# see DP.SC.159, DP.ROLE.059
# promote-common.sh — shared library for promote-scripts
#
# Contains:
#   record_promotion()   — append promotion entry in promotion-status.yaml
#   record_extension()   — append entry for a disableable extension in marketplace-manifest.yaml
#
# Usage (from other promote-scripts):
#   source "$FMT_DIR/scripts/promote-common.sh"
#   record_promotion "<path>" "<type>" "<source_sha>" "<fmt_sha>" "<verified_in_clean_env>"
#   record_extension "<path>" "<type>" "<owner>" "<install_point>" "<permissions>" "<toggleable>" "<conflict_rule>" "<staging_source>"

# Do not run directly — this is a library.
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && { echo "[ERROR] promote-common.sh is a library — source it" >&2; exit 1; }

# record_promotion — append entry in promotion-status.yaml (idempotent for incomplete SHA)
# Parameters:
#   $1 artifact_path    — relative path from FMT_DIR (for example: .claude/skills/bottleneck-pick)
#   $2 type             — skill|script|hook|rule|protocol|catalog
#   $3 source_sha       — git short SHA from the author (if present, otherwise "")
#   $4 fmt_sha          — git short SHA from FMT (it is assumed, that the commit has already been made)
#   $5 verified_in_clean_env — true|false|na
#
# Schema file promotion-status.yaml:
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

    local fmt_dir="${IWE_TEMPLATE:-${IWE_WORKSPACE:-$HOME/IWE}/IWE}"
    local status_file="$fmt_dir/promotion-status.yaml"
    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # Initialize the file on first call
    if [[ ! -f "$status_file" ]]; then
        cat > "$status_file" <<EOF
---
schema_version: 1
updated_at: $now
---
# promotion-status.yaml — promotion log of artifacts from author IWE to FMT
# see DP.SC.NNN, WP-7/PZ-6
# Writer: scripts/promote-common.sh::record_promotion()
# Append-only: new records are appended at the bottom; manual editing is not recommended.
promotions:
EOF
    fi

    # Idempotency: if an incomplete record for this artifact already exists
    # (empty source_sha and fmt_sha), do not duplicate — update only updated_at.
    # This covers repeated runs promote before the commit.
    if [[ -z "$source_sha" && -z "$fmt_sha" ]]; then
        local last_pending
        last_pending=$(grep -n "artifact_path: $artifact_path$" "$status_file" 2>/dev/null | tail -1 | cut -d: -f1 || true)
        if [[ -n "$last_pending" ]]; then
            # Verify, that this record has empty SHA values SHA
            local block_end
            block_end=$((last_pending + 5))
            local block
            block=$(sed -n "${last_pending},${block_end}p" "$status_file" 2>/dev/null || true)
            if echo "$block" | grep -q 'source_sha: ""' && echo "$block" | grep -q 'fmt_sha: ""'; then
                sed -i.bak "s/^updated_at:.*/updated_at: $now/" "$status_file" \
                    && rm -f "$status_file.bak" \
                    || { echo "[ERROR] updated_at update updated_at failed, backup backup saved: $status_file.bak" >&2; return 1; }
                echo "📝 promotion-status.yaml: existing incomplete record updated $artifact_path ($type)"
                return 0
            fi
        fi
    fi

    # Append record
    cat >> "$status_file" <<EOF
  - artifact_path: $artifact_path
    type: $type
    source_sha: "$source_sha"
    fmt_sha: "$fmt_sha"
    promoted_at: $now
    verified_in_clean_env: $verified
EOF

    # Update updated_at (sed in-place, macOS compatible)
    sed -i.bak "s/^updated_at:.*/updated_at: $now/" "$status_file" \
        && rm -f "$status_file.bak" \
        || { echo "[ERROR] updated_at update updated_at failed, backup backup saved: $status_file.bak" >&2; return 1; }

    echo "📝 promotion-status.yaml: written $artifact_path ($type)"
}

# record_extension — append record for an optional extension in marketplace-manifest.yaml
# (ADR-IWE-014 R9, WP-552 Phase55: branch «marketplace extension» — mandatory template rule
# is written via record_promotion() above, the optional one — via this function)
# Parameters:
#   $1 artifact_path    — relative path from FMT_DIR
#   $2 type             — existing artifact type: pack|skill|AR.NNN|role
#   $3 owner            — who maintains the extension
#   $4 install_point    — where it is installed (directory/mount point)
#   $5 permissions      — what permissions the extension requests
#   $6 toggleable       — true|false (toggleability)
#   $7 conflict_rule    — what to do on conflict with another extension/rule
#   $8 staging_source   — line STAGING.md, from which it was promoted (auditability of test R8)
#
# Schema file marketplace-manifest.yaml:
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

    local fmt_dir="${IWE_TEMPLATE:-${IWE_WORKSPACE:-$HOME/IWE}/IWE}"
    local manifest_file="$fmt_dir/marketplace-manifest.yaml"
    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    if [[ ! -f "$manifest_file" ]]; then
        cat > "$manifest_file" <<EOF
---
schema_version: 1
updated_at: $now
---
# marketplace-manifest.yaml — registry of toggleable extensions (ADR-IWE-014 R9)
# see WP-552 Phase5, promote-common.sh::record_extension()
# Writer: scripts/promote-common.sh::record_extension()
# Append-only: new records are appended at the bottom; manual editing is not recommended.
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
        || { echo "[ERROR] update of updated_at failed, backup backup saved: $manifest_file.bak" >&2; return 1; }

    echo "📝 marketplace-manifest.yaml: written $artifact_path (owner: $owner)"
}
