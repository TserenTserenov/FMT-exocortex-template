"""Tests for .claude/skills/pack-subscribe/catalog.py (catalog merge and filter).

The skill directory name contains a hyphen, so the module is loaded by path.
"""

from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
SKILL_DIR = ROOT / ".claude" / "skills" / "pack-subscribe"

spec = importlib.util.spec_from_file_location("pack_catalog", SKILL_DIR / "catalog.py")
catalog = importlib.util.module_from_spec(spec)
# dataclasses look the module up in sys.modules while the class is created.
sys.modules[spec.name] = catalog
spec.loader.exec_module(catalog)


def write_catalog(path: Path, entries: list[dict]) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"schema_version": 1, "packs": entries}), encoding="utf-8")
    return path


def pack(name: str, **overrides) -> dict:
    entry = {
        "name": name,
        "owner": "someone",
        "domain": "domain",
        "description": "one line",
        "url": f"https://github.com/someone/{name}",
        "access": "open",
        "audience": "everyone",
    }
    entry.update(overrides)
    return entry


def listed(workspace: Path, capsys) -> dict[str, dict]:
    assert catalog.main(["list", "--workspace", str(workspace), "--format", "json"]) == 0
    return {e["name"]: e for e in json.loads(capsys.readouterr().out)}


def test_shipped_catalog_is_valid(capsys):
    assert catalog.main(["validate", str(SKILL_DIR / "pack-catalog.yaml")]) == 0
    assert capsys.readouterr().out.startswith("OK:")


def test_shipped_catalog_offers_only_https_pack_entries(tmp_path, capsys):
    entries = listed(tmp_path, capsys)
    assert entries, "shipped catalog must not be empty"
    for name, entry in entries.items():
        assert name.startswith("PACK-")
        assert entry["url"].startswith("https://")
        assert entry.get("offered") != "internal-only"
        assert entry["source"] == "shipped"
        assert entry["connected"] is False


def test_user_catalog_overrides_shipped_and_adds_entries(tmp_path, capsys):
    shipped_name = next(iter(listed(tmp_path, capsys)))
    write_catalog(
        tmp_path / "extensions" / "pack-catalog.yaml",
        [pack(shipped_name, owner="user-mirror"), pack("PACK-extra")],
    )
    entries = listed(tmp_path, capsys)
    assert entries[shipped_name]["owner"] == "user-mirror"
    assert entries[shipped_name]["source"] == "extensions/pack-catalog.yaml"
    assert entries["PACK-extra"]["source"] == "extensions/pack-catalog.yaml"


def test_internal_only_is_hidden_and_refused_by_exact_name(tmp_path, capsys):
    write_catalog(
        tmp_path / "extensions" / "pack-catalog.yaml",
        [pack("PACK-kitchen", offered="internal-only")],
    )
    assert "PACK-kitchen" not in listed(tmp_path, capsys)
    assert catalog.main(["show", "PACK-kitchen", "--workspace", str(tmp_path)]) == 3
    assert "internal-only" in capsys.readouterr().err


def test_internal_only_in_lower_source_still_closes_the_name(tmp_path, capsys):
    write_catalog(tmp_path / "extensions" / "pack-catalog.yaml", [pack("PACK-shared")])
    write_catalog(tmp_path / "other.yaml", [pack("PACK-shared", offered="internal-only")])
    (tmp_path / "params.yaml").write_text("pack_catalog_url: other.yaml\n", encoding="utf-8")
    assert "PACK-shared" not in listed(tmp_path, capsys)
    assert catalog.main(["show", "PACK-shared", "--workspace", str(tmp_path)]) == 3


def test_params_local_path_is_read(tmp_path, capsys):
    write_catalog(tmp_path / "my" / "catalog.yaml", [pack("PACK-from-params")])
    (tmp_path / "params.yaml").write_text("pack_catalog_url: my/catalog.yaml\n", encoding="utf-8")
    entries = listed(tmp_path, capsys)
    assert entries["PACK-from-params"]["source"].startswith("pack_catalog_url")


def test_unsafe_entries_are_skipped_and_reported(tmp_path, capsys):
    bad = write_catalog(
        tmp_path / "extensions" / "pack-catalog.yaml",
        [
            pack("PACK-evil", url="ext::sh -c touch% /tmp/pwned"),
            pack("not-a-pack"),
            pack("PACK-noaccess", access="maybe"),
        ],
    )
    entries = listed(tmp_path, capsys)
    assert not {"PACK-evil", "not-a-pack", "PACK-noaccess"} & set(entries)
    assert catalog.main(["validate", str(bad)]) == 1
    out = capsys.readouterr().out
    assert out.count("INVALID:") == 3


def test_duplicate_names_fail_validation(tmp_path, capsys):
    dup = write_catalog(tmp_path / "dup.yaml", [pack("PACK-a"), pack("PACK-a")])
    assert catalog.main(["validate", str(dup)]) == 1
    assert "duplicate name 'PACK-a'" in capsys.readouterr().out


def test_show_unknown_name_and_connected_flag(tmp_path, capsys):
    assert catalog.main(["show", "PACK-nowhere", "--workspace", str(tmp_path)]) == 4
    capsys.readouterr()
    name = next(iter(listed(tmp_path, capsys)))
    (tmp_path / name / ".git").mkdir(parents=True)
    assert catalog.main(["show", name, "--workspace", str(tmp_path)]) == 0
    assert json.loads(capsys.readouterr().out)["connected"] is True


@pytest.mark.parametrize("value", ["http://example.org/c.yaml", "file:///etc/passwd"])
def test_params_non_https_scheme_is_ignored(tmp_path, capsys, value):
    (tmp_path / "params.yaml").write_text(f"pack_catalog_url: {value}\n", encoding="utf-8")
    entries = listed(tmp_path, capsys)
    assert all(e["source"] == "shipped" for e in entries.values())
