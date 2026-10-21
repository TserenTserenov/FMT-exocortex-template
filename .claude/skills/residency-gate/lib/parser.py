"""Parser for data-needs manifest blocks in SKILL.md and bash hooks."""

import re
from dataclasses import dataclass
from typing import Any, Dict, List, Optional

import yaml


class ManifestError(ValueError):
    """A data-needs declaration is malformed and must not be silently skipped."""


@dataclass
class DataNeed:
    """Single data requirement declaration."""
    name: str
    type: str  # 2.1, 2.2, 2.3, 2.4
    flow_direction: str  # inbound | outbound
    schema_version: int  # mandatory — a declaration without it fails validation (pilot decision 2026-07-16)

    def key(self) -> str:
        """Unique identifier for this need within a function."""
        return f"{self.type}_{self.flow_direction}_{self.name}"


class ManifestParser:
    """Parse data-needs blocks from skill/hook files."""

    @staticmethod
    def parse_markdown(content: str, skill_id: str) -> List[DataNeed]:
        """Extract data-needs from SKILL.md frontmatter or body."""
        needs = []

        # Pattern 1: YAML frontmatter block
        for block in ManifestParser._yaml_need_blocks(content):
            needs.extend(ManifestParser._parse_yaml_needs(block, skill_id))

        # Pattern 2: Markdown code fence with data-needs comment
        fence_pattern = r'```(?:python|bash)?\n# --- data-needs\n(.*?)\n# ---\n```'
        fence_matches = list(re.finditer(fence_pattern, content, re.DOTALL))
        marker_count = len(re.findall(r'(?m)^# --- data-needs\s*$', content))
        if marker_count != len(fence_matches):
            raise ManifestError("data-needs comment marker is malformed or unbalanced")
        for match in fence_matches:
            needs.extend(ManifestParser._parse_comment_block(match.group(1), skill_id))

        return needs

    @staticmethod
    def _yaml_need_blocks(content: str) -> List[str]:
        """Return complete indented YAML values below every data_needs key.

        The previous line regex captured only list-item lines and dropped their
        indented continuation fields. A valid multiline declaration therefore
        became an empty need list and silently allowed activation.
        """
        lines = content.splitlines()
        blocks: List[str] = []
        header = re.compile(r'^(?P<indent>[ \t]*)data[-_]needs[ \t]*:[ \t]*(?P<inline>.*)$')
        index = 0
        while index < len(lines):
            match = header.match(lines[index])
            if match is None:
                index += 1
                continue
            base_indent = len(match.group("indent").expandtabs(8))
            block_lines: List[str] = []
            inline = match.group("inline")
            if inline:
                block_lines.append(f"{match.group('indent')}  {inline}")
            index += 1
            while index < len(lines):
                line = lines[index]
                if not line.strip():
                    block_lines.append(line)
                    index += 1
                    continue
                leading = len(line) - len(line.lstrip(" \t"))
                expanded_leading = len(line[:leading].expandtabs(8))
                if expanded_leading <= base_indent:
                    break
                block_lines.append(line)
                index += 1
            blocks.append("\n".join(block_lines))
        return blocks

    @staticmethod
    def parse_bash_manifest(content: str, script_name: str) -> List[DataNeed]:
        """Extract data-needs from bash hook file (# --- data-needs ... --- comment block)."""
        needs = []

        pattern = r'# --- data-needs\n((?:#.*\n)*?)# ---'
        matches = list(re.finditer(pattern, content, re.MULTILINE))
        marker_count = len(re.findall(r'(?m)^# --- data-needs\s*$', content))
        if marker_count != len(matches):
            raise ManifestError("data-needs comment marker is malformed or unbalanced")
        for match in matches:
            needs.extend(ManifestParser._parse_comment_block(match.group(1), script_name))

        return needs

    @staticmethod
    def _parse_yaml_needs(block: str, skill_id: str) -> List[DataNeed]:
        """Parse YAML-style list of needs. Each item must carry its own schema_version."""
        # Historical manifests use a readable comma-separated shorthand that
        # is YAML-shaped but not a YAML flow mapping (no surrounding braces).
        # Keep accepting it while validating every declared field strictly.
        nonblank_lines = [line.strip() for line in block.splitlines() if line.strip()]
        if nonblank_lines and all(
            (line.startswith("-") or line.startswith("*")) and "," in line
            for line in nonblank_lines
        ):
            shorthand_needs = []
            for line in nonblank_lines:
                pairs = re.findall(r'(\w+):\s*([^,]+)', line)
                need_dict: Dict[str, Any] = {key.strip(): value.strip() for key, value in pairs}
                if "flow" in need_dict:
                    need_dict["flow_direction"] = need_dict.pop("flow")
                shorthand_needs.append(
                    ManifestParser._build_need(need_dict, None, skill_id, line)
                )
            return shorthand_needs

        try:
            document = yaml.safe_load(f"data_needs:\n{block}")
        except yaml.YAMLError as error:
            raise ManifestError(f"data_needs is not valid YAML: {error}") from error
        raw_needs = document.get("data_needs") if isinstance(document, dict) else None
        if not isinstance(raw_needs, list) or not raw_needs:
            raise ManifestError("data_needs must be a non-empty YAML list")

        needs = []
        for index, raw_need in enumerate(raw_needs):
            if not isinstance(raw_need, dict):
                raise ManifestError(f"data_need #{index + 1} must be a mapping")
            need_dict: Dict[str, Any] = dict(raw_need)
            if "flow" in need_dict and "flow_direction" in need_dict:
                if need_dict["flow"] != need_dict["flow_direction"]:
                    raise ManifestError(
                        f"data_need #{index + 1} has conflicting flow and flow_direction"
                    )
            if "flow" in need_dict:
                need_dict["flow_direction"] = need_dict.pop("flow")
            needs.append(
                ManifestParser._build_need(
                    need_dict,
                    None,
                    skill_id,
                    yaml.safe_dump(raw_need, default_flow_style=True).strip(),
                )
            )
        return needs

    @staticmethod
    def _parse_comment_block(block: str, fallback_id: str) -> List[DataNeed]:
        """Parse a '#'-comment block (code fence or bash hook).

        Each need is a complete one-line comma declaration. This deliberately
        rejects partial continuation lines instead of guessing how to merge
        them; only schema_version may be declared on its own for the block.
        A standalone 'schema_version: N' line applies to every need in the
        block; a need-line value overrides it.
        """
        pending = []  # (need_dict, source_line)
        block_version: Optional[str] = None
        for line in block.strip().split('\n'):
            line = line.strip('#').strip()
            if ':' not in line:
                continue
            pairs = re.findall(r'(\w+):\s*([^,]+)', line)
            need_dict = {k.strip(): v.strip() for k, v in pairs}
            if 'flow' in need_dict and 'flow_direction' not in need_dict:
                need_dict['flow_direction'] = need_dict.pop('flow')
            has_need_field = any(
                field in need_dict for field in ('type', 'flow_direction', 'name')
            )
            if has_need_field:
                pending.append((need_dict, line))
            elif 'schema_version' in need_dict and 'type' not in need_dict:
                block_version = need_dict['schema_version']
        if not pending:
            raise ManifestError(
                f"data-needs comment block for '{fallback_id}' contains no complete need"
            )
        return [
            ManifestParser._build_need(need_dict, block_version, fallback_id, source_line)
            for need_dict, source_line in pending
        ]

    @staticmethod
    def _build_need(
        need_dict: dict, block_version: Optional[str], fallback_id: str, source_line: str
    ) -> DataNeed:
        """Construct a DataNeed; raise ManifestError instead of guessing missing fields."""
        missing = [field for field in ('type', 'flow_direction') if field not in need_dict]
        if missing:
            raise ManifestError(
                f"data-need declaration lacks mandatory {', '.join(missing)}: '{source_line}'"
            )
        raw_version = need_dict.get('schema_version', block_version)
        if raw_version is None:
            raise ManifestError(
                f"data-need declaration lacks mandatory schema_version: '{source_line}' — "
                f"add 'schema_version: N' to the need line or as a block-level line"
            )
        try:
            version = int(raw_version)
        except (TypeError, ValueError):
            raise ManifestError(f"data-need schema_version is not an integer: '{source_line}'")
        if version < 1:
            raise ManifestError(f"data-need schema_version must be positive: '{source_line}'")
        data_type = str(need_dict['type'])
        flow_direction = str(need_dict['flow_direction'])
        if data_type not in {'2.1', '2.2', '2.3', '2.4'}:
            raise ManifestError(f"unsupported data-need type '{data_type}': '{source_line}'")
        if flow_direction not in {'inbound', 'outbound'}:
            raise ManifestError(
                f"unsupported data-need flow_direction '{flow_direction}': '{source_line}'"
            )
        return DataNeed(
            name=str(need_dict.get('name', f"{fallback_id}_0")),
            type=data_type,
            flow_direction=flow_direction,
            schema_version=version,
        )
