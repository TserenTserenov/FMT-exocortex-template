#!/usr/bin/env python3
"""Validate skill metadata and its declared local resources without executing them."""

import argparse
import os
import re
import sys
from pathlib import Path
from urllib.parse import unquote, urlsplit

import yaml

try:
    from markdown_it import MarkdownIt
except ImportError:
    sys.exit(
        f"FAIL: markdown-it-py is required; install requirements.txt with {sys.executable}"
    )


class UniqueLoader(yaml.SafeLoader):
    """Duplicate YAML keys must not silently replace the value being checked."""

    def construct_mapping(self, node, deep=False):
        self.flatten_mapping(node)
        keys = set()
        for key_node, _ in node.value:
            key = self.construct_object(key_node, deep=deep)
            if not isinstance(key, str) or key in keys:
                raise yaml.constructor.ConstructorError(
                    None,
                    None,
                    "duplicate or non-string metadata key",
                    key_node.start_mark,
                )
            keys.add(key)
        return super().construct_mapping(node, deep=deep)


class Checks:
    def __init__(self):
        self.failed = False

    def require(self, condition, message):
        print(f"{'OK:  ' if condition else 'FAIL:'} {message}")
        self.failed |= not condition
        return condition


def parse_document(text):
    lines = text.splitlines(keepends=True)
    if not lines or lines[0].rstrip("\r\n \t") != "---":
        raise ValueError("frontmatter must start with ---")
    end = next(
        (i for i, line in enumerate(lines[1:], 1) if line.rstrip("\r\n \t") == "---"),
        None,
    )
    if end is None:
        raise ValueError("frontmatter closing --- is missing")
    metadata = yaml.load("".join(lines[1:end]), Loader=UniqueLoader)
    if not isinstance(metadata, dict):
        raise TypeError("frontmatter must be a YAML mapping")
    return metadata, "".join(lines[end + 1 :])


def document(path, checks):
    try:
        return parse_document(path.read_text(encoding="utf-8-sig"))
    except (OSError, UnicodeError, ValueError, TypeError, yaml.YAMLError) as error:
        checks.require(False, f"{path.name}: invalid YAML frontmatter: {error}")
        return None


def nonempty_string(value):
    return isinstance(value, str) and bool(value.strip())


def check_metadata(data, expected_name, checks):
    for field in (
        "name",
        "description",
        "version",
        "status",
        "layer",
        "agents",
        "interaction",
    ):
        checks.require(
            nonempty_string(data.get(field)), f"frontmatter.{field}: non-empty string"
        )
    checks.require(
        data.get("name") == expected_name,
        f"name matches skill directory: {expected_name}",
    )
    version = data.get("version")
    checks.require(
        isinstance(version, str)
        and re.fullmatch(r"(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)", version),
        "version: X.Y.Z required",
    )
    for field, values in {
        "status": ("active", "experimental", "deprecated"),
        "layer": ("L1", "L2", "L3"),
        "agents": ("single", "multi"),
        "interaction": ("one-shot", "multi-step"),
    }.items():
        checks.require(
            data.get(field) in values, f"{field}: expected {'|'.join(values)}"
        )
    description = data.get("description")
    words = len(description.split()) if isinstance(description, str) else 0
    checks.require(words >= 10, f"description length ({words} words, need >=10)")
    check_gates(data, checks)
    check_triggers(data.get("triggers"), checks)


def check_gates(data, checks):
    fields = ("gates_required", "gates_enforced")
    for field in fields:
        values = data.get(field)
        if checks.require(isinstance(values, list), f"{field}: YAML list required"):
            checks.require(
                all(
                    isinstance(v, str) and v in ("wp", "integration", "routing")
                    for v in values
                ),
                f"{field}: only wp, integration, routing allowed",
            )
    if all(data.get(field) == [] for field in fields):
        checks.require(
            nonempty_string(data.get("gates_rationale")),
            "gates_rationale: explain empty gate lists",
        )


def check_triggers(triggers, checks):
    if not checks.require(
        isinstance(triggers, dict), "triggers: YAML mapping required"
    ):
        return
    active = 0
    for field in ("slash", "phrases"):
        values = triggers.get(field, [])
        if not checks.require(
            isinstance(values, list), f"triggers.{field}: YAML list required"
        ):
            continue
        for value in values:
            valid = nonempty_string(value)
            if field == "slash" and valid:
                valid = (
                    value.startswith("/")
                    and len(value) > 1
                    and not re.search(r"\s", value)
                )
            if checks.require(valid, f"triggers.{field}: non-empty valid trigger"):
                active += 1
    checks.require(
        active > 0, "triggers: at least one slash or phrase trigger required"
    )


def sections(body):
    """Read CommonMark structure without treating HTML or code as headings."""
    tokens = MarkdownIt("commonmark").parse(body)
    result = {}
    current = None
    for index, token in enumerate(tokens):
        if token.type == "heading_open" and token.tag in ("h1", "h2"):
            current = None
            if token.tag == "h2":
                children = tokens[index + 1].children or []
                current = "".join(
                    child.content
                    for child in children
                    if child.type in ("text", "code_inline")
                ).strip()
                result.setdefault(current, [])
        elif current and token.type == "inline":
            result[current].extend(token.children or [])
    return result


def check_sections(body, checks):
    found = sections(body)
    for title in ("When to use", "Algorithm"):
        checks.require(
            title in found, f"section '## {title}' required outside code examples"
        )
    return found


def local_resource(token):
    if token.type == "code_inline":
        resource = token.content
    elif token.type == "link_open":
        target = urlsplit(token.attrGet("href") or "")
        if target.scheme or target.netloc:
            return None
        resource = unquote(target.path)
    else:
        return None
    resource = resource.removeprefix("./")
    return (
        resource
        if resource.startswith(("scripts/", "assets/", "references/"))
        else None
    )


def check_resources(found, skill_dir, checks):
    for token in found.get("Bundled resources", []):
        resource = local_resource(token)
        if resource is None:
            continue
        path = skill_dir / resource
        try:
            inside = path.resolve().is_relative_to(skill_dir.resolve())
            exists = path.is_dir() if resource.endswith("/") else path.is_file()
        except (OSError, ValueError, RuntimeError) as error:
            checks.require(False, f"bundled resource {resource}: {error}")
            continue
        checks.require(
            inside and exists, f"bundled resource exists inside skill: {resource}"
        )


def check_l1_location(data, skill_name, skills_dir, checks):
    if data.get("layer") != "L1":
        return
    workspace = Path(os.environ.get("IWE_WORKSPACE") or Path.home() / "IWE")
    template = Path(
        os.environ.get("IWE_TEMPLATE") or workspace / "FMT-exocortex-template"
    )
    platform = ".kimi" if skills_dir.parent.name == ".kimi" else ".claude"
    source = template / platform / "skills" / skill_name / "SKILL.md"
    checks.require(source.is_file(), f"L1 skill present in FMT: {source}")


def check_templates(skill_dir, checks):
    substitutions = {
        "name": "template-skill",
        "description": "Classify the supplied notes into named categories and preserve every original note.",
        "version": "0.1.0",
        "status": "experimental",
        "layer": "L2",
        "agents": "single",
        "interaction": "one-shot",
        "gates_required": "[]",
        "gates_enforced": "[]",
        "gates_rationale": "Local classification of supplied text only.",
        "slash_triggers": "    - /template-skill",
        "phrase_triggers": "    - classify template-skill notes",
    }
    for name in ("skill-scaffold-minimal.md", "skill-scaffold-full.md"):
        path = skill_dir / "assets" / name
        try:
            rendered = path.read_text(encoding="utf-8-sig")
            for key, value in substitutions.items():
                rendered = rendered.replace("{{" + key + "}}", value)
            data, body = parse_document(rendered)
        except (OSError, UnicodeError, ValueError, TypeError, yaml.YAMLError) as error:
            checks.require(False, f"template/{name}: invalid YAML frontmatter: {error}")
            continue
        print(f"=== template/{name} ===")
        check_metadata(data, "template-skill", checks)
        check_sections(body, checks)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("skill_name")
    parser.add_argument(
        "skills_dir", nargs="?", type=Path, default=Path(".claude/skills")
    )
    args = parser.parse_args()
    if not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", args.skill_name):
        parser.error("skill_name must use lowercase hyphen-case")
    checks = Checks()
    skill_dir = args.skills_dir / args.skill_name
    parsed = document(skill_dir / "SKILL.md", checks)
    print(f"=== verify-skill: {args.skill_name} ===")
    if parsed:
        data, body = parsed
        check_metadata(data, args.skill_name, checks)
        found = check_sections(body, checks)
        check_resources(found, skill_dir, checks)
        check_l1_location(data, args.skill_name, args.skills_dir, checks)
        if args.skill_name == "skill-creator":
            check_templates(skill_dir, checks)
    if checks.failed:
        print(f"FAIL: {args.skill_name} — one or more checks failed")
        return 1
    print(f"PASS: {args.skill_name} — all checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
