"""Regression coverage for issue #907, findings 1 and 2.

1. A skip/skip-cells marker had nowhere reachable once a file's YAML
   frontmatter alone exceeded the fixed first-512-char scan window -- an
   ordinary long `summary` field is enough. The window now also covers the
   first ~20 lines right after a closing frontmatter `---`.
2. A marker comment carrying a trailing explanation
   (`<!-- index-health: skip-cells — комментарий -->`) defeated the old
   literal substring check entirely, silently, with no signal that the
   exemption never took effect. Detection is now regex-based and warns when
   the header mentions the key but no directive parses.

Finding 3 (a per-file `cell-limit=N` override) is explicitly out of scope
for this fix (deferred per the peer-session decision) and is not asserted
here.
"""

from __future__ import annotations

import importlib.util
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / ".claude" / "scripts" / "check-index-health.py"


def _load_module():
    spec = importlib.util.spec_from_file_location("check_index_health_907", SCRIPT)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _write(tmp_path: Path, content: str) -> Path:
    registry = tmp_path / "WP-REGISTRY.md"
    registry.write_text(content, encoding="utf-8")
    return registry


def test_marker_with_trailing_comment_is_recognized(tmp_path):
    content = (
        "<!-- index-health: skip-cells — реестр РП, длинные ячейки закрытия -->\n"
        "| # | Название | Статус |\n"
        "|---|---|---|\n"
        "| 1 | x | 🔄 |\n"
    )
    findings = _load_module().check_file(_write(tmp_path, content))
    assert findings["skip_cells"] is True
    assert findings["marker_warning"] is None


def test_plain_marker_without_trailing_text_still_works(tmp_path):
    content = "<!-- index-health: skip -->\n" "| # | Название | Статус |\n" "|---|---|---|\n"
    findings = _load_module().check_file(_write(tmp_path, content))
    assert findings["size_skip"] is True
    assert findings["marker_warning"] is None


def test_unrecognized_directive_warns_instead_of_silently_doing_nothing(tmp_path):
    content = "<!-- index-health: skiped -->\n" "| # | Название | Статус |\n" "|---|---|---|\n"
    findings = _load_module().check_file(_write(tmp_path, content))
    assert findings["size_skip"] is False
    assert findings["skip_cells"] is False
    assert findings["marker_warning"] is not None
    assert "не распознана" in findings["marker_warning"]


def test_file_without_marker_has_no_warning(tmp_path):
    content = "| # | Название | Статус |\n" "|---|---|---|\n" "| 1 | x | 🔄 |\n"
    findings = _load_module().check_file(_write(tmp_path, content))
    assert findings["marker_warning"] is None


def test_marker_reachable_past_512_chars_after_long_frontmatter(tmp_path):
    # A ~600-char summary field alone pushes the marker (placed right after
    # the closing "---") past the original fixed window.
    long_summary = "x" * 600
    content = (
        "---\n"
        f"name: catalog\n"
        f"summary: {long_summary}\n"
        "---\n"
        "<!-- index-health: skip -->\n"
        "| # | Название | Статус |\n"
        "|---|---|---|\n"
    )
    assert content.index("index-health: skip") > 512, "fixture must actually exceed the old window"
    findings = _load_module().check_file(_write(tmp_path, content))
    assert findings["size_skip"] is True
    assert findings["marker_warning"] is None


def test_marker_mentioned_in_prose_is_not_a_directive(tmp_path):
    # Cold-review finding (24.09): the wider window (see previous test) must
    # not pick up the marker's syntax merely being cited as an example --
    # only a line that is nothing but the marker comment disables checks.
    # The "mention found, no directive parsed" warning is a separate,
    # best-effort diagnostic and may still fire here; what must not happen
    # is the checks for this file actually turning off.
    content = (
        "---\n"
        "name: catalog\n"
        "---\n"
        "Пометки: `<!-- index-health: skip -->` отключает проверки раздутия.\n"
        "| # | Название | Статус |\n"
        "|---|---|---|\n"
    )
    findings = _load_module().check_file(_write(tmp_path, content))
    assert findings["size_skip"] is False


def test_marker_more_than_20_lines_after_frontmatter_still_not_found(tmp_path):
    # Sanity check on the window's own boundary: this is not "search the
    # whole file", it is a bounded window right after the frontmatter. Each
    # filler line is long enough that the total also clears the original
    # 512-char window, or that window alone would find the marker and the
    # test would not actually exercise the new window's own limit.
    filler = "\n".join(f"line number {i} of filler text padding" for i in range(25))
    content = "---\n" "name: catalog\n" "---\n" f"{filler}\n" "<!-- index-health: skip -->\n"
    assert len(content) > 512, "fixture must exceed the original window too"
    findings = _load_module().check_file(_write(tmp_path, content))
    assert findings["size_skip"] is False
