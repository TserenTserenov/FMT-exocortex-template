# SNAPSHOT — synced manually via script-promote.sh from FMT-exocortex-template/scripts/. Do not edit here directly.
"""Match DayPlan headings using the recognition keys in the installed catalogs."""
import json
import os
import re
from functools import lru_cache
from html.parser import HTMLParser
from pathlib import Path


def _locale_dir():
    override = os.environ.get("IWE_LOCALE_DIR")
    if override:
        return Path(override)
    # Source, installed strategy, and seed snapshot have the same scripts/lib
    # layout, at different depths relative to the workspace catalog.
    script_root = Path(__file__).resolve().parents[2]
    for root in (script_root, script_root.parent, script_root.parent.parent):
        directory = root / ".claude" / "lib" / "locale"
        if directory.is_dir():
            return directory
    workspace = os.environ.get("IWE_ROOT") or os.environ.get("IWE_WORKSPACE")
    if workspace:
        return Path(workspace) / ".claude" / "lib" / "locale"
    raise ValueError(f"Cannot find the DayPlan language catalogs from {script_root}")


@lru_cache(maxsize=None)
def _heading(directory, section):
    key = f"recognition.dayplan.section.{section}"
    catalogs = sorted(directory.glob("*.json"))
    if not catalogs:
        raise ValueError(f"No language catalogs in {directory}")
    aliases = []
    for path in catalogs:
        pattern = json.loads(path.read_text(encoding="utf-8")).get(key)
        if not isinstance(pattern, str) or not pattern:
            raise ValueError(f"Missing recognition pattern {key} in {path}")
        aliases.append(pattern)
    title = "(?:" + "|".join(aliases) + ")"
    # Match a whole heading. A reference to a section in a table or a sentence
    # must not dispatch that section's prompt or receive its findings.
    return re.compile(
        rf"^[ \t]*(?:(?:<details(?:[ \t]+open)?>[ \t]*)?<summary>[ \t]*"
        rf"(?:<(?:b|strong)>)?{title}(?:</(?:b|strong)>)?[ \t]*</summary>"
        rf"|#{{1,6}}[ \t]+{title}[ \t]*#*)[ \t]*\r?$",
        re.IGNORECASE | re.MULTILINE,
    )


def section_heading(section):
    return _heading(_locale_dir(), section)


def _mask_fenced_code(text: str) -> str:
    """Hide Markdown code from HTML parsing while preserving every text offset."""
    fence = ""
    output = []
    for line in text.splitlines(keepends=True):
        marker = re.match(r"^ {0,3}(`{3,}|~{3,})(.*)$", line.rstrip("\r\n"))
        masked = bool(fence or marker)
        if marker:
            token, tail = marker.groups()
            if not fence:
                fence = token
            elif token[0] == fence[0] and len(token) >= len(fence) and not tail.strip():
                fence = ""
        output.append(re.sub(r"[^\r\n]", " ", line) if masked else line)
    return "".join(output)


class _DetailsSections(HTMLParser):
    """Locate matched details/summary boundaries; comments and code are inert."""

    def __init__(self, text: str):
        super().__init__()
        self.text = text
        self.line_offsets = [0]
        for line in text.splitlines(keepends=True):
            self.line_offsets.append(self.line_offsets[-1] + len(line))
        self.stack = []
        self.openers = []
        self.summary = None
        self.sections = []
        self.code_tags = []
        self.code_start = None
        self.code_spans = []

    def _text_offset(self):
        line, column = self.getpos()
        return self.line_offsets[line - 1] + column

    def handle_starttag(self, tag, attrs):
        if tag in {"pre", "code"}:
            if not self.code_tags:
                self.code_start = self._text_offset()
            self.code_tags.append(tag)
            return
        if self.code_tags:
            return
        if tag == "details":
            section = {"start": self._text_offset(), "title_parts": []}
            self.stack.append(section)
            self.openers.append(section)
        elif tag == "summary" and self.stack and "summary_end" not in self.stack[-1]:
            self.summary = self.stack[-1]

    def handle_data(self, data):
        if self.summary is not None and not self.code_tags:
            self.summary["title_parts"].append(data)

    def handle_endtag(self, tag):
        if self.code_tags:
            if tag == self.code_tags[-1]:
                self.code_tags.pop()
                if not self.code_tags:
                    self.code_spans.append((self.code_start, self.text.find(">", self._text_offset()) + 1))
            return
        if tag == "summary" and self.summary is not None:
            self.summary["summary_end"] = self.text.find(">", self._text_offset()) + 1
            self.summary["title"] = "".join(self.summary["title_parts"]).strip()
            self.summary = None
        elif tag == "details" and self.stack:
            section = self.stack.pop()
            if "summary_end" in section:
                section["body_end"] = self._text_offset()
                section["end"] = self.text.find(">", self._text_offset()) + 1
                self.sections.append(section)


def mask_code(text: str) -> str:
    visible = _mask_fenced_code(text)
    visible = re.sub(r"(?<!`)(`+)(?!`)(.*?)(?<!`)\1(?!`)",
                     lambda match: re.sub(r"[^\r\n]", " ", match.group()), visible, flags=re.DOTALL)
    parser = _DetailsSections(visible)
    parser.feed(visible)
    if parser.code_tags:
        parser.code_spans.append((parser.code_start, len(visible)))
    parts = []
    offset = 0
    for start, end in parser.code_spans:
        parts.extend([visible[offset:start], re.sub(r"[^\r\n]", " ", visible[start:end])])
        offset = end
    parts.append(visible[offset:])
    return "".join(parts)


def visible_headings(text):
    """Blank comments and examples without moving offsets into the original text."""
    return re.sub(r"<!--.*?(?:-->|\Z)", lambda m: re.sub(r"[^\r\n]", " ", m.group()),
                  mask_code(text), flags=re.DOTALL)


def section_body(text, section):
    visible = visible_headings(text)
    heading = section_heading(section).search(visible)
    if not heading:
        return ""
    body = visible[heading.end():]
    boundary = re.search(r"^[ \t]*(?:#{1,6}[ \t]|</?details\b|<summary\b)", body,
                         re.IGNORECASE | re.MULTILINE)
    end = heading.end() + boundary.start() if boundary else len(text)
    original = text[heading.end():end].splitlines(keepends=True)
    exposed = visible[heading.end():end].splitlines(keepends=True)
    # Keep inline Markdown in real table cells; skip rows inside examples.
    return "".join(raw if shown.strip() else shown for raw, shown in zip(original, exposed))
