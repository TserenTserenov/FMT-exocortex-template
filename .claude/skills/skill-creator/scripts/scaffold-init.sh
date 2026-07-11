#!/bin/bash
# scaffold-init.sh — substitute {{placeholders}} in a skill scaffold template
# Usage: bash scripts/scaffold-init.sh --name <name> [options]
# Output: path to created SKILL.md (stdout)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_CREATOR_DIR="$(dirname "$SCRIPT_DIR")"

usage() {
  cat >&2 <<'EOF'
Usage: bash scaffold-init.sh --name <name> [options]

Required:
  --name <name>               Skill name (hyphen-case)

Optional:
  --description <text>        Skill description
  --layer L1|L2|L3            Skill layer (default: L2)
  --agents single|multi       Agent count (default: single)
  --interaction one-shot|multi-step  Interaction type (default: multi-step)
  --version <semver>          Version (default: 0.1.0)
  --status <status>           Status (default: experimental)
  --slash-trigger <cmd>       Slash trigger, repeatable
  --phrase-trigger <phrase>   Phrase trigger (may include spaces), repeatable
  --gates-required wp|integration|routing  Gate, repeatable
  --gates-enforced wp|integration|routing  Gate, repeatable
  --gates-rationale <text>    Required explanation when no gates declared
  --full                      Use full scaffold template (default: minimal)
  --target <path>             Output path (default: .claude/skills/<name>/SKILL.md)
EOF
  exit 1
}

SKILL_NAME=""
SKILL_DESCRIPTION="TODO: describe this skill"
SKILL_LAYER="L2"
SKILL_AGENTS="single"
SKILL_INTERACTION="multi-step"
SKILL_VERSION="0.1.0"
SKILL_STATUS="experimental"
SKILL_GATES_RATIONALE=""
USE_FULL=false
TARGET_PATH=""

declare -a SLASH_TRIGGERS=()
declare -a PHRASE_TRIGGERS=()
declare -a GATES_REQUIRED=()
declare -a GATES_ENFORCED=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)             SKILL_NAME="$2";                 shift 2 ;;
    --description)      SKILL_DESCRIPTION="$2";          shift 2 ;;
    --layer)            SKILL_LAYER="$2";                shift 2 ;;
    --agents)           SKILL_AGENTS="$2";               shift 2 ;;
    --interaction)      SKILL_INTERACTION="$2";          shift 2 ;;
    --version)          SKILL_VERSION="$2";              shift 2 ;;
    --status)           SKILL_STATUS="$2";               shift 2 ;;
    --slash-trigger)    SLASH_TRIGGERS+=("$2");          shift 2 ;;
    --phrase-trigger)   PHRASE_TRIGGERS+=("$2");         shift 2 ;;
    --gates-required)   GATES_REQUIRED+=("$2");          shift 2 ;;
    --gates-enforced)   GATES_ENFORCED+=("$2");          shift 2 ;;
    --gates-rationale)  SKILL_GATES_RATIONALE="$2";      shift 2 ;;
    --full)             USE_FULL=true;                   shift ;;
    --target)           TARGET_PATH="$2";                shift 2 ;;
    -h|--help)          usage ;;
    *) echo "ERROR: Unknown option: $1" >&2; usage ;;
  esac
done

if [ -z "$SKILL_NAME" ]; then
  echo "ERROR: --name is required" >&2
  usage
fi

if $USE_FULL; then
  TEMPLATE="$SKILL_CREATOR_DIR/assets/skill-scaffold-full.md"
else
  TEMPLATE="$SKILL_CREATOR_DIR/assets/skill-scaffold-minimal.md"
fi

if [ ! -f "$TEMPLATE" ]; then
  echo "ERROR: template not found: $TEMPLATE" >&2
  exit 1
fi

if [ -z "$TARGET_PATH" ]; then
  TARGET_PATH=".claude/skills/$SKILL_NAME/SKILL.md"
fi
mkdir -p "$(dirname "$TARGET_PATH")"

# Build YAML trigger list fragment (4-space indent under slash:/phrases: key)
build_trigger_yaml() {
  local result=""
  local item
  for item in "$@"; do
    result="${result}    - ${item}"$'\n'
  done
  printf '%s' "$result"
}

# Build inline YAML list: [] or [a, b, c]
build_gates_yaml() {
  if [ $# -eq 0 ]; then
    echo "[]"
    return
  fi
  local result="["
  local g
  for g in "$@"; do
    result="${result}${g}, "
  done
  result="${result%, }]"
  echo "$result"
}

SKILL_SLASH_TRIGGERS="$(build_trigger_yaml "${SLASH_TRIGGERS[@]+"${SLASH_TRIGGERS[@]}"}")"
SKILL_PHRASE_TRIGGERS="$(build_trigger_yaml "${PHRASE_TRIGGERS[@]+"${PHRASE_TRIGGERS[@]}"}")"
SKILL_GATES_REQUIRED="$(build_gates_yaml "${GATES_REQUIRED[@]+"${GATES_REQUIRED[@]}"}")"
SKILL_GATES_ENFORCED="$(build_gates_yaml "${GATES_ENFORCED[@]+"${GATES_ENFORCED[@]}"}")"

if [ "$SKILL_GATES_REQUIRED" = "[]" ] && [ "$SKILL_GATES_ENFORCED" = "[]" ] && [ -z "$SKILL_GATES_RATIONALE" ]; then
  echo "WARNING: gates_required=[] and gates_enforced=[] but --gates-rationale not set." >&2
  echo "         verify-skill.sh will FAIL. Pass --gates-rationale to explain why no gates." >&2
fi

export SKILL_NAME SKILL_DESCRIPTION SKILL_LAYER SKILL_AGENTS SKILL_INTERACTION
export SKILL_VERSION SKILL_STATUS SKILL_GATES_RATIONALE
export SKILL_SLASH_TRIGGERS SKILL_PHRASE_TRIGGERS
export SKILL_GATES_REQUIRED SKILL_GATES_ENFORCED

python3 - "$TEMPLATE" "$TARGET_PATH" <<'PYEOF'
import sys, os, pathlib

template_path, output_path = sys.argv[1], sys.argv[2]
text = pathlib.Path(template_path).read_text()

replacements = {
    "{{name}}":            os.environ["SKILL_NAME"],
    "{{description}}":     os.environ["SKILL_DESCRIPTION"],
    "{{version}}":         os.environ["SKILL_VERSION"],
    "{{status}}":          os.environ["SKILL_STATUS"],
    "{{layer}}":           os.environ["SKILL_LAYER"],
    "{{agents}}":          os.environ["SKILL_AGENTS"],
    "{{interaction}}":     os.environ["SKILL_INTERACTION"],
    "{{slash_triggers}}":  os.environ["SKILL_SLASH_TRIGGERS"],
    "{{phrase_triggers}}": os.environ["SKILL_PHRASE_TRIGGERS"],
    "{{gates_required}}":  os.environ["SKILL_GATES_REQUIRED"],
    "{{gates_enforced}}":  os.environ["SKILL_GATES_ENFORCED"],
    "{{gates_rationale}}": os.environ["SKILL_GATES_RATIONALE"],
}

for placeholder, value in replacements.items():
    text = text.replace(placeholder, value)

pathlib.Path(output_path).write_text(text)
PYEOF

echo "$TARGET_PATH"
