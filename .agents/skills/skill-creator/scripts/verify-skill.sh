#!/bin/bash
# verify-skill.sh — smoke test for a newly created IWE skill
# Usage: bash scripts/verify-skill.sh <skill-name> [skills-dir]

set -euo pipefail

SKILL_NAME="${1:-}"
SKILLS_DIR="${2:-.claude/skills}"

if [ -z "$SKILL_NAME" ]; then
  echo "Usage: bash scripts/verify-skill.sh <skill-name> [skills-dir]"
  exit 1
fi

SKILL_PATH="$SKILLS_DIR/$SKILL_NAME/SKILL.md"
SKILL_DIR="$SKILLS_DIR/$SKILL_NAME"
FAILED=0

fail() { echo "FAIL: $1"; FAILED=1; }
ok()   { echo "OK:   $1"; }

check_frontmatter_fields() {
  local file="$1" label="$2"
  for field in name description version status layer agents interaction; do
    if grep -qE "^${field}:" "$file"; then
      ok "$label frontmatter.$field"
    else
      fail "$label missing frontmatter.$field"
    fi
  done
}

check_body_sections() {
  local file="$1" label="$2"
  for section in "## When to use" "## Algorithm"; do
    if grep -qF "$section" "$file"; then
      ok "$label section '${section}'"
    else
      fail "$label missing required section '${section}'"
    fi
  done
}

check_gates() {
  local file="$1"
  local has_req has_enf
  has_req=$(grep -cE "^gates_required:" "$file" || true)
  has_enf=$(grep -cE "^gates_enforced:" "$file" || true)

  if [ "$has_req" -eq 0 ] || [ "$has_enf" -eq 0 ]; then
    fail "missing frontmatter: both gates_required and gates_enforced are mandatory"
    return
  fi
  ok "gates_required + gates_enforced present"

  local valid_re="^(wp|integration|routing)$"
  for gfield in gates_required gates_enforced; do
    while IFS= read -r v; do
      v_clean=$(echo "$v" | tr -d ' "'"'"'[],'  )
      [ -z "$v_clean" ] && continue
      if ! echo "$v_clean" | grep -qE "$valid_re"; then
        fail "$gfield: unknown value '$v_clean' (allowed: wp, integration, routing)"
      fi
    done < <(grep "^${gfield}:" "$file" | sed 's/^.*\[//;s/\].*//;s/,/\n/g')
  done

  local req_empty enf_empty
  req_empty=$(grep "^gates_required:" "$file" | grep -cE "\[\s*\]" || true)
  enf_empty=$(grep "^gates_enforced:" "$file" | grep -cE "\[\s*\]" || true)
  if [ "$req_empty" -gt 0 ] && [ "$enf_empty" -gt 0 ]; then
    local rationale
    rationale=$(grep "^gates_rationale:" "$file" | sed 's/^gates_rationale: *//' | tr -d '"' | xargs)
    if [ -z "$rationale" ]; then
      fail "both gates lists empty but gates_rationale is missing"
    else
      ok "gates_rationale present (no gates declared)"
    fi
  fi
}

check_bundled_resources() {
  local file="$1" skill_dir="$2"
  grep -qE "^## Bundled resources" "$file" || return 0
  while IFS= read -r line; do
    [[ "$line" =~ ^\-\ \`(scripts|assets)/[^\`]+\` ]] || continue
    local resource="${line#*\`}"
    resource="${resource%%\`*}"
    if [ -f "$skill_dir/$resource" ]; then
      ok "bundled resource exists: $resource"
    else
      fail "bundled resource missing: $skill_dir/$resource"
    fi
  done < "$file"
}

check_scaffold_templates() {
  local skill_dir="$1"
  for tmpl in "$skill_dir/assets/skill-scaffold-minimal.md" "$skill_dir/assets/skill-scaffold-full.md"; do
    local label
    label="template/$(basename "$tmpl")"
    if [ ! -f "$tmpl" ]; then
      fail "$label missing"
      continue
    fi
    check_frontmatter_fields "$tmpl" "$label"
    check_body_sections "$tmpl" "$label"
  done
}

check_l1_location() {
  local file="$1" skill_name="$2"
  local layer
  layer=$(grep "^layer:" "$file" | sed 's/^layer: *//' | tr -d '"' | xargs)
  [ "$layer" = "L1" ] || return 0
  local fmt_path="$HOME/IWE/FMT-exocortex-template/.agents/skills/$skill_name/SKILL.md"
  if [ -f "$fmt_path" ]; then
    ok "L1 skill present in FMT-exocortex-template"
  else
    fail "L1 skill not found in FMT ($fmt_path)"
  fi
}

# --- Main ---

if [ ! -f "$SKILL_PATH" ]; then
  echo "FAIL: $SKILL_PATH not found"
  exit 1
fi

echo "=== verify-skill: $SKILL_NAME ==="

check_frontmatter_fields "$SKILL_PATH" "skill"

DESC_WORDS=$(grep -A 10 "^description:" "$SKILL_PATH" | sed '1d' | tr '\n' ' ' | wc -w | tr -d ' ')
if [ "$DESC_WORDS" -ge 10 ]; then
  ok "description length ($DESC_WORDS words)"
else
  fail "description too short ($DESC_WORDS words, need ≥10)"
fi

if grep -qE "^triggers:" "$SKILL_PATH"; then
  ok "triggers section"
else
  fail "missing triggers section"
fi

check_body_sections "$SKILL_PATH" "skill"
check_gates "$SKILL_PATH"
check_bundled_resources "$SKILL_PATH" "$SKILL_DIR"
[ "$SKILL_NAME" = "skill-creator" ] && check_scaffold_templates "$SKILL_DIR"
check_l1_location "$SKILL_PATH" "$SKILL_NAME"

echo ""
if [ "$FAILED" -eq 0 ]; then
  echo "PASS: $SKILL_NAME — all checks passed"
  exit 0
else
  echo "FAIL: $SKILL_NAME — one or more checks failed (see above)"
  exit 1
fi
