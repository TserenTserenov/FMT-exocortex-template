#!/usr/bin/env python3
"""Unit tests for manifest parser."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent.parent / "lib"))

from parser import ManifestParser, ManifestError, DataNeed


def test_parse_yaml_needs():
    """Test parsing YAML-style data-needs in markdown."""
    content = """
# SKILL.md

data_needs:
  - type: 2.1, flow: inbound, name: user-profile, schema_version: 1
  - type: 2.2, flow: outbound, name: data-export, schema_version: 2
"""
    needs = ManifestParser.parse_markdown(content, "test-skill")
    assert len(needs) == 2
    assert needs[0].type == "2.1"
    assert needs[0].flow_direction == "inbound"
    assert needs[0].name == "user-profile"
    assert needs[0].schema_version == 1
    assert needs[1].type == "2.2"
    assert needs[1].flow_direction == "outbound"
    assert needs[1].schema_version == 2


def test_yaml_need_without_schema_version_raises():
    """A declaration without schema_version must fail loudly, not default to 1."""
    content = """
data_needs:
  - type: 2.1, flow: inbound, name: user-profile
"""
    try:
        ManifestParser.parse_markdown(content, "test-skill")
    except ManifestError as e:
        assert "schema_version" in str(e)
    else:
        raise AssertionError("declaration without schema_version must raise ManifestError")


def test_yaml_need_without_flow_raises():
    """A partial list item is a malformed declaration, never an empty manifest."""
    content = """
data_needs:
  - type: 2.1, name: user-profile, schema_version: 1
"""
    try:
        ManifestParser.parse_markdown(content, "test-skill")
    except ManifestError as error:
        assert "flow_direction" in str(error)
    else:
        raise AssertionError("declaration without flow must raise ManifestError")


def test_parse_multiline_yaml_need():
    """Continuation fields below a list item remain part of that need."""
    content = """
data_needs:
  - type: 2.1
    flow: inbound
    name: user-profile
    schema_version: 3
"""
    needs = ManifestParser.parse_markdown(content, "test-skill")
    assert len(needs) == 1
    assert needs[0] == DataNeed(
        name="user-profile",
        type="2.1",
        flow_direction="inbound",
        schema_version=3,
    )


def test_space_before_yaml_colon_is_still_a_declaration():
    content = """
data_needs :
  - type: 2.1
    flow: inbound
    name: user-profile
    schema_version: 1
"""
    assert len(ManifestParser.parse_markdown(content, "test-skill")) == 1


def test_unbalanced_comment_marker_raises():
    content = """#!/bin/bash
# --- data-needs
# type: 2.1, flow_direction: inbound, name: profile, schema_version: 1
"""
    try:
        ManifestParser.parse_bash_manifest(content, "broken-hook")
    except ManifestError as error:
        assert "unbalanced" in str(error)
    else:
        raise AssertionError("an unbalanced declaration marker must fail closed")


def test_parse_bash_manifest_block_level_version():
    """A standalone schema_version line applies to every need in the block."""
    content = """#!/bin/bash
# --- data-needs
# type: 2.2, flow_direction: inbound, name: daily-summary
# schema_version: 3
# ---
"""
    needs = ManifestParser.parse_bash_manifest(content, "day-open-hook")
    assert len(needs) == 1
    assert needs[0].type == "2.2"
    assert needs[0].flow_direction == "inbound"
    assert needs[0].schema_version == 3


def test_bash_need_without_schema_version_raises():
    """A bash manifest without any schema_version must fail loudly."""
    content = """#!/bin/bash
# --- data-needs
# type: 2.2, flow_direction: inbound, name: daily-summary
# ---
"""
    try:
        ManifestParser.parse_bash_manifest(content, "day-open-hook")
    except ManifestError as e:
        assert "schema_version" in str(e)
    else:
        raise AssertionError("declaration without schema_version must raise ManifestError")


def test_comment_manifest_without_complete_need_raises():
    content = """#!/bin/bash
# --- data-needs
# schema_version: 1
# ---
"""
    try:
        ManifestParser.parse_bash_manifest(content, "empty-hook")
    except ManifestError as error:
        assert "no complete need" in str(error)
    else:
        raise AssertionError("a declared but empty data-needs block must fail closed")


def test_per_need_version_overrides_block_level():
    """A need-line schema_version wins over the block-level line."""
    content = """#!/bin/bash
# --- data-needs
# type: 2.1, flow_direction: inbound, name: profile, schema_version: 5
# schema_version: 2
# ---
"""
    needs = ManifestParser.parse_bash_manifest(content, "hook")
    assert len(needs) == 1
    assert needs[0].schema_version == 5


def test_data_need_key():
    """Test DataNeed key generation."""
    need = DataNeed(
        name="test-data",
        type="2.1",
        flow_direction="inbound",
        schema_version=1
    )
    assert need.key() == "2.1_inbound_test-data"


def test_empty_manifest():
    """Test parsing file with no data-needs."""
    content = "# Some markdown without data needs"
    needs = ManifestParser.parse_markdown(content, "empty-skill")
    assert len(needs) == 0


if __name__ == "__main__":
    test_parse_yaml_needs()
    test_yaml_need_without_schema_version_raises()
    test_yaml_need_without_flow_raises()
    test_parse_multiline_yaml_need()
    test_space_before_yaml_colon_is_still_a_declaration()
    test_unbalanced_comment_marker_raises()
    test_parse_bash_manifest_block_level_version()
    test_bash_need_without_schema_version_raises()
    test_comment_manifest_without_complete_need_raises()
    test_per_need_version_overrides_block_level()
    test_data_need_key()
    test_empty_manifest()
    print("✓ All tests passed")
