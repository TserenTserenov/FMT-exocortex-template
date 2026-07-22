"""Parser for data-needs manifest blocks in SKILL.md and bash hooks."""

import re
from dataclasses import dataclass
from typing import List, Optional


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
        yaml_pattern = r'data[-_]needs:\s*\n((?:^\s+[-*].+\n?)*)'
        for match in re.finditer(yaml_pattern, content, re.MULTILINE):
            needs.extend(ManifestParser._parse_yaml_needs(match.group(1), skill_id))

        # Pattern 2: Markdown code fence with data-needs comment
        fence_pattern = r'```(?:python|bash)?\n# --- data-needs\n(.*?)\n# ---\n```'
        for match in re.finditer(fence_pattern, content, re.DOTALL):
            needs.extend(ManifestParser._parse_comment_block(match.group(1), skill_id))

        return needs

    @staticmethod
    def parse_bash_manifest(content: str, script_name: str) -> List[DataNeed]:
        """Extract data-needs from bash hook file (# --- data-needs ... --- comment block)."""
        needs = []

        pattern = r'# --- data-needs\n((?:#.*\n)*?)# ---'
        for match in re.finditer(pattern, content, re.MULTILINE):
            needs.extend(ManifestParser._parse_comment_block(match.group(1), script_name))

        return needs

    @staticmethod
    def _parse_yaml_needs(block: str, skill_id: str) -> List[DataNeed]:
        """Parse YAML-style list of needs. Each item must carry its own schema_version."""
        needs = []
        for line in block.strip().split('\n'):
            line = line.strip()
            if not (line.startswith('-') or line.startswith('*')):
                continue
            # Parse: - type: 2.1, flow: inbound, name: user-profile, schema_version: 1
            pairs = re.findall(r'(\w+):\s*([^,]+)', line)
            need_dict = {k.strip(): v.strip() for k, v in pairs}
            if 'type' in need_dict and 'flow' in need_dict:
                need_dict['flow_direction'] = need_dict.pop('flow')
                needs.append(ManifestParser._build_need(need_dict, None, skill_id, line))
        return needs

    @staticmethod
    def _parse_comment_block(block: str, fallback_id: str) -> List[DataNeed]:
        """Parse a '#'-comment block (code fence or bash hook).

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
            if 'type' in need_dict and 'flow_direction' in need_dict:
                pending.append((need_dict, line))
            elif 'schema_version' in need_dict and 'type' not in need_dict:
                block_version = need_dict['schema_version']
        return [
            ManifestParser._build_need(need_dict, block_version, fallback_id, source_line)
            for need_dict, source_line in pending
        ]

    @staticmethod
    def _build_need(
        need_dict: dict, block_version: Optional[str], fallback_id: str, source_line: str
    ) -> DataNeed:
        """Construct a DataNeed; raise ManifestError instead of guessing missing fields."""
        raw_version = need_dict.get('schema_version', block_version)
        if raw_version is None:
            raise ManifestError(
                f"data-need declaration lacks mandatory schema_version: '{source_line}' — "
                f"add 'schema_version: N' to the need line or as a block-level line"
            )
        try:
            version = int(raw_version)
        except ValueError:
            raise ManifestError(f"data-need schema_version is not an integer: '{source_line}'")
        return DataNeed(
            name=need_dict.get('name', f"{fallback_id}_0"),
            type=need_dict['type'],
            flow_direction=need_dict['flow_direction'],
            schema_version=version,
        )
