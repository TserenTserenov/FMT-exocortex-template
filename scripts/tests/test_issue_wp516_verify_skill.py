"""Behavioral regression coverage for the WP-516 skill validator audit.

Run with pytest. WP516_VERIFY_SCRIPT is a test-only override for trying a
temporary validator; production CLI options and HOME remain unchanged.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path

import pytest

DESCRIPTION = (
    "Validate a small example skill when a user requests a repeatable local "
    "verification workflow with explicit inputs and observable results."
)
FIELDS = {
    "name": "sample",
    "description": f'"{DESCRIPTION}"',
    "version": "1.2.3",
    "status": "experimental",
    "layer": "L2",
    "agents": "single",
    "interaction": "one-shot",
    "gates_required": "[]",
    "gates_enforced": "[]",
    "gates_rationale": '"This local example only reads an already provided fixture."',
    "triggers": "\n  slash:\n    - /sample",
}
BODY = """
# /sample

## When to use

Use this skill when the user requests validation of a local example.

## Algorithm

Read the provided input and report the observed validation result.

## Bundled resources

No extra resources are needed for this example.
"""
TEMPLATES = ("skill-scaffold-minimal.md", "skill-scaffold-full.md")


def document(
    overrides: dict[str, str] | None = None,
    *,
    omit: tuple[str, ...] = (),
    body: str = BODY,
    description_last: bool = False,
) -> str:
    fields = dict(FIELDS)
    fields.update(overrides or {})
    for key in omit:
        fields.pop(key)
    if description_last:
        fields["description"] = fields.pop("description")
    metadata = "\n".join(f"{key}: {value}" for key, value in fields.items())
    return f"---\n{metadata}\n---\n{body}"


@dataclass(frozen=True)
class Validator:
    script: Path
    workspace: Path

    @property
    def template_root(self) -> Path:
        return self.workspace / "FMT-exocortex-template"

    def write(
        self,
        content: str,
        *,
        name: str = "sample",
        platform: str = ".claude",
    ) -> Path:
        skill = self.workspace / platform / "skills" / name
        skill.mkdir(parents=True, exist_ok=True)
        (skill / "SKILL.md").write_text(content, encoding="utf-8")
        return skill

    def run(self, skill: Path) -> subprocess.CompletedProcess[str]:
        environment = os.environ.copy()
        environment["IWE_WORKSPACE"] = str(self.workspace)
        environment["IWE_TEMPLATE"] = str(self.template_root)
        return subprocess.run(
            ["bash", str(self.script), skill.name, str(skill.parent)],
            cwd=self.workspace,
            env=environment,
            text=True,
            capture_output=True,
            timeout=15,
            check=False,
        )

    def fmt_copy(self, skill: Path, platform: str) -> Path:
        target = self.template_root / platform / "skills" / skill.name / "SKILL.md"
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(skill / "SKILL.md", target)
        return target

    def creator(self) -> Path:
        skill = self.write(document({"name": "skill-creator"}), name="skill-creator")
        assets = skill / "assets"
        assets.mkdir()
        (skill / "scripts").mkdir()
        source = self.script.parent.parent / "assets"
        for template in TEMPLATES:
            shutil.copyfile(source / template, assets / template)
        return skill


@pytest.fixture
def validator(tmp_path: Path) -> Validator:
    default = (
        Path(__file__).resolve().parents[2]
        / ".claude/skills/skill-creator/scripts/verify-skill.sh"
    )
    script = Path(os.environ.get("WP516_VERIFY_SCRIPT", default)).resolve()
    assert script.is_file(), f"Validator not found: {script}"
    return Validator(script, tmp_path)


def output(result: subprocess.CompletedProcess[str]) -> str:
    return result.stdout + result.stderr


def assert_success(result: subprocess.CompletedProcess[str]) -> None:
    diagnostic = output(result)
    assert result.returncode == 0, diagnostic
    assert "pass" in diagnostic.lower(), diagnostic


def assert_failure(
    result: subprocess.CompletedProcess[str], *diagnostic_terms: str
) -> None:
    diagnostic = output(result)
    assert result.returncode == 1, diagnostic
    assert diagnostic.strip(), "Validation failed without an explanation"
    if diagnostic_terms:
        assert any(
            term.casefold() in diagnostic.casefold() for term in diagnostic_terms
        ), f"Expected one of {diagnostic_terms!r} in:\n{diagnostic}"


def test_valid_minimal_skill(validator: Validator) -> None:
    assert_success(validator.run(validator.write(document())))


@pytest.mark.parametrize(
    "description",
    ['"Only six words describe this skill"', '""', "", "null", "|\n  "],
    ids=["six-words", "quoted-empty", "empty", "null", "empty-block"],
)
def test_short_or_empty_description_cannot_borrow_metadata_words(
    validator: Validator, description: str
) -> None:
    skill = validator.write(document({"description": description}))
    assert_failure(validator.run(skill), "description")


@pytest.mark.parametrize("description_last", [False, True], ids=["first", "last"])
@pytest.mark.parametrize(
    "description",
    [
        f'"{DESCRIPTION}"',
        (
            "|\n  Validate a small example skill when a user requests\n"
            "  a repeatable workflow with explicit inputs and observable results."
        ),
        (
            ">-\n  Validate a small example skill when a user requests\n"
            "  a repeatable workflow with explicit inputs and observable results."
        ),
    ],
    ids=["inline", "literal", "folded"],
)
def test_description_is_counted_from_its_yaml_value(
    validator: Validator, description: str, description_last: bool
) -> None:
    skill = validator.write(
        document({"description": description}, description_last=description_last)
    )
    assert_success(validator.run(skill))


@pytest.mark.parametrize("boundary", ["both", "opening", "closing"])
def test_frontmatter_boundaries(
    validator: Validator, boundary: str
) -> None:
    content = document()
    if boundary in {"both", "opening"}:
        content = content.removeprefix("---\n")
    if boundary in {"both", "closing"}:
        content = content.replace("\n---\n", "\n", 1)
    assert_failure(validator.run(validator.write(content)), "frontmatter", "yaml")


@pytest.mark.parametrize("field", tuple(FIELDS))
def test_required_metadata_cannot_be_supplied_only_in_the_body(
    validator: Validator, field: str
) -> None:
    content = document(omit=(field,), body=f"{BODY}\n{field}: {FIELDS[field]}\n")
    assert_failure(validator.run(validator.write(content)), field)


@pytest.mark.parametrize(
    "overrides",
    [
        {"agents": "[single"},
        {"description": '"This quoted description is never closed'},
        {"triggers": "\n  slash:\n    - /sample\n   phrases: [broken]"},
    ],
    ids=["unclosed-list", "unclosed-quote", "invalid-indentation"],
)
def test_malformed_yaml_fails_with_a_parse_diagnostic(
    validator: Validator, overrides: dict[str, str]
) -> None:
    assert_failure(validator.run(validator.write(document(overrides))), "yaml", "parse")


@pytest.mark.parametrize("field", tuple(FIELDS))
def test_duplicate_yaml_keys_are_rejected(validator: Validator, field: str) -> None:
    content = document().replace("\n---\n", f"\n{field}: {FIELDS[field]}\n---\n", 1)
    assert_failure(validator.run(validator.write(content)), "duplicate", field)


@pytest.mark.parametrize(
    "field", ["name", "version", "status", "layer", "agents", "interaction"]
)
@pytest.mark.parametrize("value", ["", '""', "null"], ids=["empty", "quoted", "null"])
def test_required_scalars_must_be_nonempty(
    validator: Validator, field: str, value: str
) -> None:
    assert_failure(validator.run(validator.write(document({field: value}))), field)


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("layer", "L99"),
        ("status", "definitely-not-a-status"),
        ("agents", "many"),
        ("interaction", "interactive"),
        ("version", "not-a-version"),
        ("name", "[sample]"),
        (
            "description",
            "[long, enough, words, must, not, make, a, sequence, into, prose]",
        ),
        ("description", "{text: a description is a string and never a nested object}"),
        ("description", "42"),
        ("version", "[1.2.3]"),
        ("version", "3"),
        ("status", "[experimental]"),
        ("layer", "[L2]"),
        ("agents", "[single]"),
        ("interaction", "[one-shot]"),
    ],
)
def test_invalid_metadata_enums_and_types_are_rejected(
    validator: Validator, field: str, value: str
) -> None:
    assert_failure(validator.run(validator.write(document({field: value}))), field)


@pytest.mark.parametrize(
    "triggers",
    [
        "[]",
        "",
        "null",
        "{}",
        "\n  slash: []\n  phrases: []",
        "\n  slash: null",
        "\n  slash: [null]",
        "\n  slash: ['']",
    ],
    ids=[
        "list",
        "empty",
        "null",
        "mapping",
        "empty-groups",
        "null-group",
        "null-item",
        "empty-item",
    ],
)
def test_triggers_require_an_actual_nonempty_trigger(
    validator: Validator, triggers: str
) -> None:
    assert_failure(
        validator.run(validator.write(document({"triggers": triggers}))), "trigger"
    )


@pytest.mark.parametrize("field", ["gates_required", "gates_enforced"])
@pytest.mark.parametrize(
    "gates",
    ["\n  - wp\n  - integration", "[wp, ]"],
    ids=["multiline", "trailing-comma"],
)
def test_yaml_gate_lists_accept_multiline_and_trailing_comma_forms(
    validator: Validator, field: str, gates: str
) -> None:
    assert_success(validator.run(validator.write(document({field: gates}))))


@pytest.mark.parametrize("field", ["gates_required", "gates_enforced"])
@pytest.mark.parametrize(
    "gates", ["'[wp]'", "null", "{wp: true}", "[unknown-gate]", "[null]", "[123]"]
)
def test_gates_require_lists_of_known_names(
    validator: Validator, field: str, gates: str
) -> None:
    assert_failure(validator.run(validator.write(document({field: gates}))), field)


@pytest.mark.parametrize(
    "rationale", ["null", "", '""', '"   "', "[]", "{reason: local}", "123", "true"]
)
def test_empty_gates_require_a_nonempty_text_rationale(
    validator: Validator, rationale: str
) -> None:
    skill = validator.write(document({"gates_rationale": rationale}))
    assert_failure(validator.run(skill), "rationale")


def test_nonempty_gates_do_not_require_an_empty_gate_rationale(
    validator: Validator,
) -> None:
    skill = validator.write(
        document({"gates_required": "[wp]"}, omit=("gates_rationale",))
    )
    assert_success(validator.run(skill))


@pytest.mark.parametrize("section", ["When to use", "Algorithm"])
@pytest.mark.parametrize("form", ["backtick-fence", "tilde-fence", "sentence"])
def test_required_sections_must_be_real_headings(
    validator: Validator, section: str, form: str
) -> None:
    heading = f"## {section}"
    if form == "sentence":
        imitation = f"The following prose mentions {heading} as an example."
    else:
        fence = "```" if form == "backtick-fence" else "~~~"
        imitation = f"{fence}markdown\n{heading}\n{fence}"
    body = BODY.replace(heading, imitation)
    assert_failure(validator.run(validator.write(document(body=body))), section)


@pytest.mark.parametrize("prefix", ["scripts", "assets", "references"])
@pytest.mark.parametrize("marker", ["-", "*", "+", "1."])
@pytest.mark.parametrize("present", [False, True], ids=["missing", "existing"])
def test_bundled_files_are_checked_for_every_supported_bullet(
    validator: Validator, prefix: str, marker: str, present: bool
) -> None:
    resource = f"{prefix}/example.txt"
    skill = validator.write(document(body=f"{BODY}\n{marker} `{resource}` — example\n"))
    if present:
        target = skill / resource
        target.parent.mkdir()
        target.write_text("Example resource.\n", encoding="utf-8")
        assert_success(validator.run(skill))
    else:
        assert_failure(validator.run(skill), resource)


@pytest.mark.parametrize("prefix", ["scripts", "assets", "references"])
@pytest.mark.parametrize("marker", ["-", "*", "+", "1."])
def test_bundled_resource_directories_are_valid(
    validator: Validator, prefix: str, marker: str
) -> None:
    resource = f"{prefix}/examples/"
    skill = validator.write(
        document(body=f"{BODY}\n{marker} `{resource}` — examples\n")
    )
    (skill / resource).mkdir(parents=True)
    assert_success(validator.run(skill))


@pytest.mark.parametrize("prefix", ["scripts", "assets", "references"])
@pytest.mark.parametrize("fence", ["```", "~~~"])
def test_bundled_resource_examples_inside_code_do_not_require_files(
    validator: Validator, prefix: str, fence: str
) -> None:
    body = f"{BODY}\n{fence}markdown\n- `{prefix}/missing-example.txt`\n{fence}\n"
    assert_success(validator.run(validator.write(document(body=body))))


@pytest.mark.parametrize("layer", ["L1 # shared", "'L1'", '"L1" # shared'])
def test_l1_quotes_and_comments_cannot_bypass_the_template_requirement(
    validator: Validator, layer: str
) -> None:
    skill = validator.write(document({"layer": layer}))
    assert_failure(validator.run(skill), "FMT", "template")


@pytest.mark.parametrize("platform", [".claude", ".kimi"])
def test_l1_accepts_a_copy_for_its_own_platform(
    validator: Validator, platform: str
) -> None:
    skill = validator.write(document({"layer": "L1"}), platform=platform)
    validator.fmt_copy(skill, platform)
    assert_success(validator.run(skill))


def test_kimi_l1_cannot_use_a_claude_template_copy(validator: Validator) -> None:
    skill = validator.write(document({"layer": "L1"}), platform=".kimi")
    validator.fmt_copy(skill, ".claude")
    assert_failure(validator.run(skill), ".kimi", "FMT", "template")


def test_standard_scaffold_templates_are_valid_with_placeholders(
    validator: Validator,
) -> None:
    skill = validator.creator()
    for name in TEMPLATES:
        assert "{{description}}" in (skill / "assets" / name).read_text(
            encoding="utf-8"
        )
    assert_success(validator.run(skill))


@pytest.mark.parametrize("template", TEMPLATES)
@pytest.mark.parametrize("field", ["gates_required", "gates_enforced", "triggers"])
def test_scaffold_templates_must_retain_gate_and_trigger_fields(
    validator: Validator, template: str, field: str
) -> None:
    skill = validator.creator()
    path = skill / "assets" / template
    content = path.read_text(encoding="utf-8")
    if field == "triggers":
        content, removed = re.subn(
            r"(?m)^triggers:\n(?:  [^\n]*\n|\{\{[^\n]+\}\}\n)*", "", content, count=1
        )
    else:
        content, removed = re.subn(rf"(?m)^{field}:[^\n]*\n", "", content, count=1)
    assert removed == 1, f"Fixture did not remove {field} from {template}"
    path.write_text(content, encoding="utf-8")
    result = validator.run(skill)
    assert_failure(result, field)
    assert template in output(result), output(result)


@pytest.mark.parametrize("section", ["When to use", "Algorithm"])
@pytest.mark.parametrize("wrapper", ["pre", "div", "inline-comment"])
def test_html_examples_cannot_supply_required_markdown_headings(
    validator: Validator, section: str, wrapper: str
) -> None:
    heading = f"## {section}"
    if wrapper == "inline-comment":
        example = f"<!-- This is an HTML example. -->{heading}"
    else:
        example = f"<{wrapper}>\n{heading}\n</{wrapper}>"
    body = BODY.replace(heading, example)
    assert_failure(validator.run(validator.write(document(body=body))), section)


@pytest.mark.parametrize("fence", ["```", "~~~"])
def test_unclosed_html_comment_in_fenced_code_does_not_hide_later_sections(
    validator: Validator, fence: str
) -> None:
    example = f"{fence}html\n<!-- An unfinished comment shown as code\n{fence}\n\n"
    skill = validator.write(document(body=example + BODY))
    assert_success(validator.run(skill))


@pytest.mark.parametrize(
    "declaration",
    [
        "- [Guide](references/guide.md)",
        "- Guides:\n    - `references/guide.md`",
        "- Guides:\n    - [Guide](references/guide.md)",
        "- Read the guide:\n  `references/guide.md`",
        "- Read the guide:\n  [Guide](references/guide.md)",
    ],
    ids=["link", "nested-code", "nested-link", "continued-code", "continued-link"],
)
@pytest.mark.parametrize("present", [False, True], ids=["missing", "existing"])
def test_bundled_references_in_links_and_list_continuations_are_checked(
    validator: Validator, declaration: str, present: bool
) -> None:
    skill = validator.write(document(body=f"{BODY}\n{declaration}\n"))
    resource = skill / "references" / "guide.md"
    if present:
        resource.parent.mkdir()
        resource.write_text("An actual bundled guide.\n", encoding="utf-8")
        assert_success(validator.run(skill))
    else:
        assert_failure(validator.run(skill), "references/guide.md")


def test_python_yaml_tag_is_rejected_without_creating_a_file(
    validator: Validator,
) -> None:
    marker = validator.workspace / "python-yaml-tag-created-this-file"
    payload = f"!!python/object/apply:builtins.open ['{marker}', 'w']"
    skill = validator.write(document({"description": payload}))
    result = validator.run(skill)
    assert_failure(result, "yaml", "tag", "constructor")
    assert not marker.exists(), "Loading YAML executed a Python file operation"


def test_existing_file_outside_the_skill_is_not_a_bundled_resource(
    validator: Validator,
) -> None:
    resource = "references/../../outside"
    skill = validator.write(document(body=f"{BODY}\n- `{resource}`\n"))
    (skill / "references").mkdir()
    outside = skill.parent / "outside"
    outside.write_text("Existing file outside this skill.\n", encoding="utf-8")
    assert (skill / resource).is_file(), "Fixture must reach an existing file"
    assert_failure(validator.run(skill), resource)


def step7_shell_block(validator: Validator, platform: str) -> str:
    instruction = validator.script.parent.parent / "SKILL.md"
    text = instruction.read_text(encoding="utf-8")
    step = re.search(r"(?ms)^### Step 7 [^\n]*\n(.*?)(?=^### Step |\Z)", text)
    assert step is not None, f"Step 7 is missing from {instruction}"
    block = re.search(r"(?ms)^```bash\n(.*?)^```[ \t]*$", step[1])
    assert block is not None, "Step 7 must provide an executable bash block"
    commands = block[1]
    assert "<name>" in commands, "Expected the documented skill-name placeholder"
    commands = commands.replace("<name>", "sample")
    commands, skills_count = re.subn(
        r"(?m)^skills_dir=.*$", f"skills_dir={platform}/skills", commands, count=1
    )
    commands, creator_count = re.subn(
        r"(?m)^creator_dir=.*$",
        "creator_dir=.claude/skills/skill-creator",
        commands,
        count=1,
    )
    assert skills_count == creator_count == 1, "Routing paths must be configurable"
    return commands


def run_step7_in_sandbox(
    validator: Validator,
    *,
    generator_location: str,
    generator_fails: bool = False,
) -> subprocess.CompletedProcess[str]:
    """Run the real instructions against tools with observable local effects."""
    commands = step7_shell_block(validator, ".kimi")
    validator.write(document(), platform=".kimi")
    for platform in (".claude", ".kimi"):
        catalog = validator.workspace / platform / "skills-catalog.yaml"
        catalog.parent.mkdir(parents=True, exist_ok=True)
        catalog.write_text(f"original {platform} catalog\n", encoding="utf-8")

    generator_root = (
        validator.workspace
        if generator_location == "workspace"
        else validator.template_root
    )
    generator = generator_root / "scripts" / "generate-skills-catalog.sh"
    generator.parent.mkdir(parents=True, exist_ok=True)
    generator.write_text(
        """#!/usr/bin/env bash
set -euo pipefail
# Match the real generator's CLI and default destination.
catalog_output="$IWE_WORKSPACE/.claude/skills-catalog.yaml"
catalog_input=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --skills-dir) catalog_input="$2"; shift 2 ;;
    --output) catalog_output="$2"; shift 2 ;;
    *) echo "Unexpected generator argument: $1" >&2; exit 2 ;;
  esac
done
printf '%s\\n' "$catalog_input" > "$IWE_WORKSPACE/generator-invocation"
if [ "${WP516_TEST_GENERATOR_FAIL:-0}" = 1 ]; then
  echo "Test generator deliberately failed with status 3" >&2
  exit 3
fi
mkdir -p "$(dirname "$catalog_output")"
printf 'generated for %s\\n' "$catalog_input" > "$catalog_output"
""",
        encoding="utf-8",
    )
    generator.chmod(0o755)
    verifier = (
        validator.workspace / ".claude/skills/skill-creator/scripts/verify-skill.sh"
    )
    verifier.parent.mkdir(parents=True, exist_ok=True)
    verifier.write_text(
        """#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$@" > "$IWE_WORKSPACE/verify-invocation"
echo "PASS: test verifier completed"
""",
        encoding="utf-8",
    )
    verifier.chmod(0o755)
    environment = os.environ.copy()
    environment["IWE_WORKSPACE"] = str(validator.workspace)
    environment["IWE_TEMPLATE"] = str(validator.template_root)
    environment["WP516_TEST_GENERATOR_FAIL"] = "1" if generator_fails else "0"
    # An outer `bash -e` would conceal missing error handling in the instructions.
    return subprocess.run(
        ["bash", "-c", commands],
        cwd=validator.workspace,
        env=environment,
        text=True,
        capture_output=True,
        timeout=15,
        check=False,
    )


@pytest.mark.parametrize("generator_location", ["workspace", "template"])
def test_step7_for_kimi_updates_its_catalog_and_preserves_claude(
    validator: Validator, generator_location: str
) -> None:
    result = run_step7_in_sandbox(validator, generator_location=generator_location)
    assert_success(result)
    claude_catalog = validator.workspace / ".claude" / "skills-catalog.yaml"
    kimi_catalog = validator.workspace / ".kimi" / "skills-catalog.yaml"
    assert claude_catalog.read_text(encoding="utf-8") == "original .claude catalog\n"
    generated = kimi_catalog.read_text(encoding="utf-8")
    assert generated.startswith("generated for "), generated
    assert ".kimi/skills" in generated, generated
    invocation = (
        (validator.workspace / "verify-invocation")
        .read_text(encoding="utf-8")
        .splitlines()
    )
    assert len(invocation) == 2 and invocation[0] == "sample", invocation
    assert (validator.workspace / invocation[1]).resolve() == (
        validator.workspace / ".kimi" / "skills"
    )


@pytest.mark.parametrize("generator_location", ["workspace", "template"])
def test_step7_stops_before_verification_when_catalog_generation_fails(
    validator: Validator, generator_location: str
) -> None:
    result = run_step7_in_sandbox(
        validator, generator_location=generator_location, generator_fails=True
    )
    assert result.returncode != 0, output(result)
    assert "Test generator deliberately failed with status 3" in output(result)
    assert (validator.workspace / "generator-invocation").is_file()
    assert not (validator.workspace / "verify-invocation").exists(), (
        "Step 7 ran verification after catalog generation failed"
    )
    for platform in (".claude", ".kimi"):
        catalog = validator.workspace / platform / "skills-catalog.yaml"
        assert catalog.read_text(encoding="utf-8") == f"original {platform} catalog\n"
