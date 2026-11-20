#!/usr/bin/env python3
"""Batch fix for SKILL.md files missing required fields/sections.
Adds: agents, interaction, gates_required, gates_enforced, gates_rationale,
      ## When to use, ## Algorithm.
"""

import os
import re
import sys

SKILLS_DIR = os.path.expanduser("~/IWE/.claude/skills")

# Already PASS — skip
SKIP = {"agent-fault", "apply-captures", "skill-creator"}

# executor:script + deterministic:true → agents: none, interaction: one-shot
SCRIPT_EXECUTOR = {
    "check-secret", "connect-guide", "consent", "extend",
    "iwe-bug-report", "lesson-close", "setup-wakatime", "transcribe", "w-reflection"
}

# Skills where ## Scope should be renamed to ## When to use (Scope = When-to-use content)
SCOPE_AS_WTU = {"ke"}


def get_description(content):
    m = re.search(r'^description:\s*["\']?(.*?)["\']?$', content, re.MULTILINE)
    return m.group(1).strip() if m else ""


def has_field(content, field):
    return bool(re.search(rf'^{re.escape(field)}:', content, re.MULTILINE))


def add_frontmatter(content, skill_name):
    """Insert missing frontmatter fields before closing ---."""
    is_script = skill_name in SCRIPT_EXECUTOR
    agents_val = "none" if is_script else "single"
    inter_val = "one-shot" if is_script else "multi-step"

    # Find end of frontmatter (second occurrence of ---)
    idx = content.find('\n---', 4)
    if idx == -1:
        return content

    additions = []
    if not has_field(content, 'agents'):
        additions.append(f'agents: {agents_val}')
    if not has_field(content, 'interaction'):
        additions.append(f'interaction: {inter_val}')
    if not has_field(content, 'gates_required'):
        additions.append('gates_required: []')
    if not has_field(content, 'gates_enforced'):
        additions.append('gates_enforced: []')
    # Rationale needed when both gates are empty
    if not has_field(content, 'gates_rationale'):
        # Determine if gates will be empty after fix
        req_val = re.search(r'^gates_required:\s*(.*)', content, re.MULTILINE)
        enf_val = re.search(r'^gates_enforced:\s*(.*)', content, re.MULTILINE)
        req_empty = (req_val is None) or re.match(r'\[\s*\]', req_val.group(1).strip())
        enf_empty = (enf_val is None) or re.match(r'\[\s*\]', enf_val.group(1).strip())
        if req_empty and enf_empty:
            additions.append(
                'gates_rationale: '
                '"операционный скилл; WP Gate применим только при создании нового РП, '
                'не для операционных вызовов"'
            )

    if additions:
        content = content[:idx] + '\n' + '\n'.join(additions) + content[idx:]
    return content


def add_when_to_use(content, description, skill_name):
    """Add ## When to use section if missing."""
    if '## When to use' in content:
        return content

    # ke: rename ## Scope → ## When to use (Scope IS the when-to-use content)
    if skill_name in SCOPE_AS_WTU:
        if re.search(r'^## Scope\b', content, re.MULTILINE):
            return re.sub(r'^## Scope\b', '## When to use', content, count=1, flags=re.MULTILINE)

    # Insert before first level-2 section in the body
    fm_end = content.find('\n---\n', 4)
    if fm_end == -1:
        return content
    body_start = fm_end + 4

    m = re.search(r'\n## ', content[body_start:])
    if m:
        pos = body_start + m.start()
    else:
        pos = len(content)

    section = f'\n## When to use\n\n{description}\n'
    return content[:pos] + section + content[pos:]


def add_algorithm(content):
    """Add ## Algorithm section if missing."""
    if '## Algorithm' in content:
        return content

    # Priority order: rename known Russian/alternative headings first
    rename_map = [
        r'^## Алгоритм\b',
        r'^## Инструкция для Claude\b',
        r'^## Порядок выполнения\b',
        r'^## Поведение\b',
    ]
    for pattern in rename_map:
        if re.search(pattern, content, re.MULTILINE):
            return re.sub(pattern, '## Algorithm', content, count=1, flags=re.MULTILINE)

    # Numbered sections ## N. (like think skill)
    m = re.search(r'\n## \d+\.', content)
    if m:
        return content[:m.start()] + '\n## Algorithm\n' + content[m.start():]

    # Level-2 ## Шаг or ## Step
    m = re.search(r'\n## (Шаг|Step)\b', content)
    if m:
        return content[:m.start()] + '\n## Algorithm\n' + content[m.start():]

    # Level-2 ## Режим (multi-mode skills like vdv)
    m = re.search(r'\n## Режим\b', content)
    if m:
        return content[:m.start()] + '\n## Algorithm\n' + content[m.start():]

    # Fallback: append minimal section
    return content.rstrip() + '\n\n## Algorithm\n\nВыполнить согласно инструкции в теле скилла.\n'


def process_skill(skill_name):
    path = os.path.join(SKILLS_DIR, skill_name, 'SKILL.md')
    if not os.path.exists(path):
        return False

    with open(path, encoding='utf-8') as f:
        orig = f.read()

    content = orig
    desc = get_description(content)
    content = add_frontmatter(content, skill_name)
    content = add_when_to_use(content, desc, skill_name)
    content = add_algorithm(content)

    if content != orig:
        with open(path, 'w', encoding='utf-8') as f:
            f.write(content)
        return True
    return False


def main():
    target = sys.argv[1] if len(sys.argv) > 1 else None
    skills = [target] if target else sorted(os.listdir(SKILLS_DIR))

    fixed = []
    skipped = []
    for skill_name in skills:
        if skill_name in SKIP:
            skipped.append(skill_name)
            continue
        skill_dir = os.path.join(SKILLS_DIR, skill_name)
        if not os.path.isdir(skill_dir):
            continue
        if process_skill(skill_name):
            fixed.append(skill_name)
            print(f"  fixed: {skill_name}")
        else:
            print(f"  no-op: {skill_name}")

    print(f"\nDone: {len(fixed)} fixed, {len(skipped)} skipped (already PASS)")


if __name__ == '__main__':
    main()
