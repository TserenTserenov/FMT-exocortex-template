from __future__ import annotations
#!/usr/bin/env python3
"""
day-open-llm-fill.py — WP-356: per-section LLM-filling PENDING-markers DayPlan.

Interface:
  python3 day-open-llm-fill.py \
    --scaffold PATH --weekplan PATH --wp-registry PATH \
    [--wp-dir PATH] [--cp-profile PATH] [--calendar PATH] [--out PATH] \
    [--proxy-url URL]

Invariants:
- Only sections with <!-- PENDING... --> are sent to LLM (per-section isolation).
- Section 'Plan for today' uses consolidated prompt with JSON-facts from WP frontmatter.
- Section without PENDING = unchanged (idempotency).
- Atomic write: tmp→rename if out == scaffold.
- Timeout: 60s per section, 300s total.
- Proxy fail = hard fail (exit 1), fallback disabled.
- temperature=0 for today_plan (deterministic renderer).
"""

import argparse
import glob
from html.parser import HTMLParser
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request

import yaml
from pathlib import Path

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
from wp_inbox import wp_card_paths  # noqa: E402 — lib path set above

DEFAULT_PROXY_URL = "http://localhost:18765"
SECTION_TIMEOUT_S = 60
TOTAL_TIMEOUT_S = 300


def _validated_pipeline_workspace() -> Path | None:
    """Return a physical IWE_ROOT supplied by the installed Day Open pipeline."""

    raw = os.environ.get("IWE_ROOT", "").strip()
    if not raw or "\x00" in raw:
        return None
    candidate = Path(raw).expanduser()
    if candidate.is_symlink():
        return None
    try:
        resolved = candidate.resolve(strict=True)
    except (OSError, RuntimeError):
        return None
    return resolved if resolved.is_dir() else None


PIPELINE_WORKSPACE = _validated_pipeline_workspace()


def _fault_profile_workspace() -> Path:
    configured = os.environ.get("IWE_WORKSPACE") or os.environ.get("WORKSPACE_DIR")
    if configured:
        return Path(configured).expanduser()
    return PIPELINE_WORKSPACE or Path.home() / "IWE"


def _fault_profile_script() -> str:
    """Resolve the one agent-neutral CLI in installed and template layouts."""

    script_dir = Path(__file__).resolve().parent
    workspace = _fault_profile_workspace()
    configured_scripts = Path(os.environ.get("IWE_SCRIPTS") or workspace / "scripts")
    candidates = (
        script_dir / "agent-fault" / "iwe_checklist_memory.py",
        configured_scripts / "agent-fault" / "iwe_checklist_memory.py",
        workspace / "IWE" / "scripts" / "agent-fault" / "iwe_checklist_memory.py",
    )
    return str(next((candidate for candidate in candidates if candidate.is_file()), candidates[0]))


FAULT_PROFILE_SCRIPT = _fault_profile_script()


def read_file(path: str | None, default: str = "") -> str:
    if not path or not os.path.isfile(path):
        return default
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return f.read()


def load_fault_profile() -> str:
    """Run the unified agent-fault CLI and return this subject's top rules.

    Returns empty string on failure. Logs reason to stderr so silent disable
    (caused by interpreter mismatch, regex drift, or CLI breakage)
    surfaces in pipeline logs instead of vanishing.

    Symmetric with .claude/hooks/inject-fault-profile.sh: same data source
    (iwe_memory.db via the unified CLI), filtered to CRITICAL/MAJOR
    with n>=3.
    """
    subject_kind = os.environ.get("IWE_FAULT_SUBJECT_KIND", "")
    subject_id = os.environ.get("IWE_FAULT_SUBJECT_ID", "")
    if subject_kind not in {"personality", "runtime", "system"} or not subject_id:
        print("[INFO] fault-profile: explicit subject is not configured — skipped", file=sys.stderr)
        return ""
    if not os.path.isfile(FAULT_PROFILE_SCRIPT):
        print(f"[INFO] fault-profile: {FAULT_PROFILE_SCRIPT} not found — skipped",
              file=sys.stderr)
        return ""
    try:
        child_env = os.environ.copy()
        if (
            not child_env.get("IWE_WORKSPACE")
            and not child_env.get("WORKSPACE_DIR")
            and PIPELINE_WORKSPACE is not None
        ):
            # The governance pipeline derives IWE_ROOT from its own physical
            # location. Adapt that trusted runtime fact to the canonical CLI's
            # unchanged IWE_WORKSPACE → WORKSPACE_DIR → HOME/IWE contract.
            child_env["IWE_WORKSPACE"] = str(PIPELINE_WORKSPACE)
        result = subprocess.run(
            [
                sys.executable,
                FAULT_PROFILE_SCRIPT,
                "remind",
                "--protocol",
                "open",
                "--subject-kind",
                subject_kind,
                "--subject-id",
                subject_id,
            ],
            env=child_env,
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode != 0:
            print(f"[WARN] fault-profile: unified CLI exit={result.returncode}, "
                  f"stderr={result.stderr.strip()[:200]}", file=sys.stderr)
            return ""
        lines = [
            line for line in result.stdout.splitlines()
            if re.match(r"^🔴 \[(CRITICAL|MAJOR) \| n=\d+\]", line)
        ]
        if not lines:
            print("[WARN] fault-profile: unified CLI output had 0 lines "
                  "matching CRITICAL/MAJOR n>=3 regex — possible format drift",
                  file=sys.stderr)
            return ""
        return "\n".join(lines[:3])
    except Exception as e:
        print(f"[WARN] fault-profile: load failed ({type(e).__name__}: {e})",
              file=sys.stderr)
        return ""


def extract_active_wps(wp_registry_text: str) -> str:
    lines = []
    for line in wp_registry_text.splitlines():
        if any(s in line for s in ("🔄", "⏳", "🔴", "🟡", "🟠")):
            lines.append(line)
    return "\n".join(lines[:50])


def rebuild_compact_dashboard(text: str) -> str:
    """Rebuild the WP block in Compact Dashboard from the completed section 'Plan for today'
    (top-7 by priority), and not from the alphabetical sweep active WPs.

    Compact dashboard is created in the scaffold BEFORE the plan is populated, therefore the scaffold
    takes sweep a sweep in WP order (WP without activity instead of day focus). Here, after
    population, the plan is already known — we take its top-7. WP-5 Phase 2026-06-11 P1.

    Plan is empty (not populated) → text is returned unchanged (fallback on scaffold).
    """
    lines = text.split("\n")

    # 1. Collect the top-7 rows-WP rows from the table 'Plan for today'
    plan_rows = []
    in_plan = False
    for ln in lines:
        if "Plan for today" in ln:
            in_plan = True
            continue
        if not in_plan:
            continue
        s = ln.strip()
        if s.startswith("|") and "**" in s and "🚦" not in s:
            plan_rows.append(s)
            if len(plan_rows) >= 7:
                break
        elif plan_rows and not s.startswith("|"):
            break  # table ended (Day budget / empty line / </details>)
    if not plan_rows:
        return text

    # 2. Compact rows: | flag | # short-name |
    compact = ["**Today (top-7 by priority):**"]
    for row in plan_rows:
        cols = [c.strip() for c in row.strip("|").split("|")]
        if len(cols) < 3:
            continue
        flag, num, name = cols[0], cols[1], cols[2]
        short = name.split(" — ")[0].strip()
        if len(short) > 60:
            short = short[:57] + "…"
        compact.append(f"| {flag} | {num} {short} |")

    # 3. Replace the old WP sub-block inside Compact Dashboard with compact
    out = []
    in_dash = False
    skipping = False
    for ln in lines:
        if "---COMPACT-DASHBOARD---" in ln:
            in_dash = True
            out.append(ln)
            continue
        if "---END-COMPACT-DASHBOARD---" in ln:
            in_dash = False
            skipping = False
            out.append(ln)
            continue
        s = ln.strip()
        if in_dash and s.startswith("**Today"):
            out.extend(compact)
            skipping = True
            continue
        if skipping:
            if s == "":
                skipping = False
                out.append(ln)
            continue  # skip old table rows
        out.append(ln)
    return "\n".join(out)


def _dashboard_today_iso() -> str:
    """Today according to the Moscow calendar -- the date, under which dashboard_worker.py
    writes the nightly snapshot (run 07:30 MSK, WP-417 Phase-cutover-switch 2026-09-02).
    Replaces _panel_yesterday_iso() -- the old panel counted as YESTERDAY (target_date
    in panel_worker.py), PD-dashboard writes the file under the date of the run itself."""
    from datetime import datetime, timezone
    try:
        from zoneinfo import ZoneInfo
        now = datetime.now(ZoneInfo("Europe/Moscow"))
    except Exception:  # noqa: BLE001 — zoneinfo not available → Moscow = UTC+3 (no DST since 2014)
        from datetime import timedelta
        now = datetime.now(timezone.utc) + timedelta(hours=3)
    return now.date().isoformat()


def _strip_panel_block(text: str, begin: str, end: str) -> str:
    """Remove the previous dashboard block (idempotency). No block present → text unchanged."""
    start = text.find(begin)
    if start == -1:
        return text
    stop = text.find(end, start)
    if stop == -1:
        return text
    stop += len(end)
    after = stop + 1 if text[stop:stop + 1] == "\n" else stop  # consume the trailing \n
    return text[:start] + text[after:]


GATE_METRICS_SCRIPT = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "gate-metrics.sh"
)
GATE_SECTION_BEGIN = "<summary><b>Gate-metrics"
GATE_SECTION_END = "</details>"

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


def _mask_code(text: str) -> str:
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


def _parse_details(text: str) -> _DetailsSections:
    visible = _mask_code(text)
    parser = _DetailsSections(visible)
    parser.feed(visible)
    return parser


def _details_sections(text: str) -> list[dict]:
    return sorted(_parse_details(text).sections, key=lambda section: section["start"])


def inject_gate_metrics(text: str) -> str:
    """Run gate-metrics.sh and replace Gate-metrics section body with actual output.

    Idempotent: replaces on every run. Degrades gracefully if script/log absent.
    Gate log lives at ~/.iwe/gate-decisions.jsonl — only present on Mac.
    """
    gate_log = os.path.expanduser("~/.iwe/gate-decisions.jsonl")
    if not os.path.isfile(gate_log):
        print("[inject_gate_metrics] gate log absent — skipping", file=sys.stderr)
        return text
    if not os.path.isfile(GATE_METRICS_SCRIPT):
        print(f"[inject_gate_metrics] {GATE_METRICS_SCRIPT} not found — skipping", file=sys.stderr)
        return text

    try:
        r = subprocess.run(
            ["bash", GATE_METRICS_SCRIPT],
            capture_output=True, text=True, timeout=10,
        )
        output = r.stdout.strip()
        if not output:
            print("[inject_gate_metrics] empty output — skipping", file=sys.stderr)
            return text
    except Exception as e:
        print(f"[inject_gate_metrics] failed: {e}", file=sys.stderr)
        return text

    # Find <summary><b>Gate-metrics then </summary> then </details>
    # Replace everything between </summary> and </details> with gate output.
    idx = text.find(GATE_SECTION_BEGIN)
    if idx == -1:
        return text
    summary_end = text.find("</summary>", idx)
    if summary_end == -1:
        return text
    summary_end += len("</summary>")
    close = text.find(GATE_SECTION_END, summary_end)
    if close == -1:
        return text

    new_body = "\n\n" + output + "\n\n"
    return text[:summary_end] + new_body + text[close:]


def inject_panel_tile(text: str) -> str:
    """Insert dashboard tile (WP-417 Phase-cutover-switch, 2026-09-02) into Compact Dashboard
    before the END-END marker.

    Source -- PD-dashboard (git, nightly writer dashboard_worker.py), not
    panel.db/Neon (old WP-417 Phase3.4 source superseded architectural pivot
    18.08-01.09, see. inbox/WP-417/WP-417.md "Update and pilot decision on
    dashboard composition"). Idempotent -- the old block <!-- panel-tile --> is removed
    and is replaced with a fresh one (a repeated Day Open does not duplicate). Degrades gracefully:
    no PD-dashboard/file for today -> tile is skipped, day open does not
    crash (P4: reason to log). Overall scaffold is not touched -- insertion only in
    local pipeline ${IWE_GOVERNANCE_REPO:-DS-strategy}.
    """
    sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "lib"))
    try:
        from dashboard_render import (
            PANEL_BEGIN, PANEL_END, read_dashboard_snapshot, render_dashboard_panel_block,
        )
    except Exception:  # noqa: BLE001 — dashboard-modules unavailable → tile is simply not shown
        print("[inject_panel_tile] dashboard-modules unavailable — tile skipped", file=sys.stderr)
        return text

    marker = "---END-COMPACT-DASHBOARD---"
    if marker not in text:
        return text  # no dashboard (non-standard scaffold) — nowhere to insert

    try:
        snapshot = read_dashboard_snapshot(_fault_profile_workspace())
    except Exception:  # noqa: BLE001 — PD-dashboard unavailable → tile is skipped, day is not failed
        print("[inject_panel_tile] reading PD-dashboard failed — tile skipped", file=sys.stderr)
        return text

    block = render_dashboard_panel_block(snapshot, _dashboard_today_iso())
    text = _strip_panel_block(text, PANEL_BEGIN, PANEL_END)
    idx = text.find(marker)
    return text[:idx] + block + "\n" + text[idx:]


def parse_frontmatter(path: str) -> dict:
    """Parse YAML frontmatter from a markdown file, top-level keys as strings.

    Uses a real YAML parser: the previous line-by-line version conflated nested
    keys with top-level ones — a WP card with `phases:` sub-keys like
    `Phase-x: superseded` overwrote the top-level `status: in_progress`, so WP-149
    was misread as closed and dropped from the DayPlan (2026-07-01).
    """
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            text = f.read()
    except OSError:
        return {}
    if not text.startswith("---"):
        return {}
    # Frontmatter is the block between the first two `---` fences.
    parts = text.split("\n---", 1)
    body = parts[0][3:] if parts else ""
    try:
        data = yaml.safe_load(body) or {}
        if isinstance(data, dict):
            # Normalize scalar top-level values to strings; callers expect .get()->str.
            return {k: ("" if v is None else str(v)) for k, v in data.items()}
    except yaml.YAMLError:
        pass
    # Fallback: some WP cards have unquoted prose in frontmatter that breaks strict
    # YAML. Scan top-level keys only (no leading indent) so nested `status:` under
    # `phases:` can't clobber the real one, and a malformed tail is tolerated.
    return _parse_toplevel_lines(body)


def _parse_toplevel_lines(body: str) -> dict:
    result = {}
    for line in body.splitlines():
        if not line or line[0] in " \t#":
            continue  # skip indented (nested) lines, blanks, comments
        if ":" in line:
            key, val = line.split(":", 1)
            result[key.strip()] = val.strip().strip("\"'")
    return result


def collect_wp_facts(wp_dir: str) -> list[dict]:
    """Collect active WP facts from frontmatter of WP-*.md files."""
    facts = []
    if not os.path.isdir(wp_dir):
        return facts
    for path in wp_card_paths(wp_dir):
        fm = parse_frontmatter(path)
        status = fm.get("status", "").lower()
        if status not in ("in_progress", "active", "pending"):
            continue
        wp_id = fm.get("wp", "")
        if not wp_id:
            m = re.search(r"WP-(\d+)", os.path.basename(path))
            if m:
                wp_id = m.group(1)
        wp_id = re.sub(r"^WP-", "", str(wp_id))
        # Budget field fallback: budget_h → budget_hours → budget
        budget = fm.get("budget_h") or fm.get("budget_hours") or fm.get("budget", "")
        facts.append({
            "id": f"WP-{wp_id}" if wp_id else "WP-??",
            "title": fm.get("title", ""),
            "status": status,
            "priority": fm.get("priority", ""),
            "budget_h": budget,
        })
    return facts


def _strip_leading_details(content: str) -> str:
    """Drop leading <details...> lines the LLM wrapped around its answer.

    The canonical opening tag lives in the section header line, so any <details>
    the LLM prepends is a duplicate with no <summary> — browsers render it as the
    literal word "Details". Loops because the LLM occasionally stacks two openers.
    """
    stripped = content.lstrip("\n")
    while stripped.lower().startswith("<details"):
        first_nl = stripped.find("\n")
        if first_nl == -1:
            return ""
        stripped = stripped[first_nl + 1:].lstrip("\n")
    return stripped


def _drop_trailing_closers(content: str, extra: int) -> str:
    """Remove `extra` trailing </details> tags the LLM emitted beyond the original.

    Excess closers close the outer <details> early and orphan every section below,
    so the DayPlan tail silently disappears. Strips from the end, where stray
    closers accumulate.
    """
    lines = content.rstrip().split("\n")
    kept = []
    for line in reversed(lines):
        if extra > 0 and line.strip() == "</details>":
            extra -= 1
            continue
        kept.append(line)
    return "\n".join(reversed(kept))


def has_bare_details(text: str) -> bool:
    """True if any <details> opener lacks a <summary> within the next few lines.

    A bare <details> is the "Details" rendering bug. Used as a post-fill gate so a
    regression blocks the commit instead of reaching the pilot.
    """
    return any("summary_end" not in section for section in _parse_details(text).openers)


def split_into_chunks(text: str) -> list[dict]:
    """Split text into chunks by headings ## or <details>."""
    chunks = []
    current_lines = []
    current_header = "preamble"
    world_sections = [section for section in _details_sections(text) if section["title"] == "World"]
    offset = 0

    for line, visible in zip(text.splitlines(keepends=True), _mask_code(text).splitlines(keepends=True)):
        inside_world = any(section["start"] < offset < section["end"] for section in world_sections)
        if not inside_world and (visible.startswith("## ") or visible.strip().startswith("<details")):
            if current_lines:
                chunks.append({"header": current_header, "lines": current_lines, "has_pending": "<!-- PENDING" in _mask_code("".join(current_lines))})
            current_header = line.strip()
            current_lines = [line]
        else:
            current_lines.append(line)
        offset += len(line)

    if current_lines:
        chunks.append({"header": current_header, "lines": current_lines, "has_pending": "<!-- PENDING" in _mask_code("".join(current_lines))})
    return chunks


def build_section_prompt(header: str, section_content: str, weekplan: str,
                         active_wps: str, calendar: str, cp_profile: str,
                         fault_profile: str = "", fleeting_notes: str = "") -> str:
    parts = ["You — morning assistant of the IWE pilot IWE."]
    if fault_profile:
        parts += [
            "",
            "=== AGENT RECURRING ERROR PROFILE (n>=3 across session history) ===",
            "Apply when filling the section. Source: WP-316 (Session Memory).",
            fault_profile,
            "",
        ]
    parts += [
        "You are given ONE section DayPlan with markers <!-- PENDING: description --> or <!-- PENDING -->.",
        "TASK: replace EVERY marker in this section with real, concrete content.",
        "",
        "RULES:",
        "1. Write specifically, without generic phrases.",
        "2. Reference real WP-numbers from the context.",
        "3. If there is no data — write 'No data' and remove the marker.",
        "4. Do not change the structure markdown (tables, lists, bold text).",
        "4a. If the section starts with <details> — make sure to keep <summary>...</summary> (if present) and the closing </details> at the end of the section.",
        "5. Return ONLY the section content — WITHOUT the section heading.",
        "6. If the section contains a table — fill in the cells marked with PENDING, do not touch the rest.",
        "6a. For the table 'Note Review': cells in the column 'Note' — links of the form [«text»](../inbox/fleeting-notes.md) WITHOUT an anchor (bold-text does not create GitHub-anchors). Do not add #anchor. Do not leave bare text without a link.",
        "6b. For the section 'World': if there is a block '**Conclusion:**' with PENDING — fill in 2-4 sentences: which news items are relevant to active WPs from WeekPlan WeekPlan. No generic phrases, specifics by WP-numbers.",
        "6c. For the table 'Note Review': FORBIDDEN to invent note names. Use ONLY the headings from 'CONTEXT: Fleeting Notes' below. If the context is empty or contains only frontmatter — write 'no notes' into the column 'Note'.",
        "",
        "=== CONTEXT: WeekPlan ===",
        weekplan[:6000],
        "",
        "=== CONTEXT: Active WP ===",
        active_wps or "No active WP.",
        "",
    ]
    if calendar:
        parts += ["=== CONTEXT: Calendar ===", calendar[:1500], ""]
    if cp_profile:
        parts += ["=== CONTEXT: Pilot Profile ===", cp_profile[:800], ""]
    if fleeting_notes:
        parts += ["=== CONTEXT: Fleeting Notes (source of notes for the table 'Note Review') ===",
                  fleeting_notes[:3000], ""]
    parts += [
        f"=== SECTION: {header} ===",
        section_content,
        "",
        "Return ONLY the section content (without the header) with all substitutions applied.",
        "Do not wrap the response in ```markdown ```.",
    ]
    return "\n".join(parts)


def build_today_plan_prompt(header: str, section_content: str, weekplan: str,
                            wp_facts: list[dict], calendar: str, cp_profile: str,
                            fault_profile: str = "") -> str:
    """Consolidated prompt for today_plan with JSON facts."""
    facts_json = json.dumps(wp_facts, ensure_ascii=False, indent=2)
    parts = ["You are — morning assistant to the IWE pilot IWE."]
    if fault_profile:
        parts += [
            "",
            "=== AGENT RECURRING ERROR PROFILE (n>=3 across session history) ===",
            "Apply when filling the section. Source: WP-316 (Session Memory).. Source: WP-316 (Session Memory).",
            fault_profile,
            "",
        ]
    parts += [
        "You are given ONE DayPlan section DayPlan: 'Plan for Today' with markers <!-- PENDING: description --> or <!-- PENDING -->.",
        "TASK: replace EVERY marker with real, specific content.",
        "",
        "CRITICALLY IMPORTANT (invariants):",
        "1. Below is the LIST OF ACTIVE WPs as JSON. This is the ONLY source of WP composition, statuses, and hours., statuses and hours.",
        "2. Table 'Plan for Today' MUST contain EXACTLY the WPs present in the JSON., that are in JSON. Do NOT add new ones.. Do NOT remove existing ones..",
        "3. Statuses and hours (budget_h) are taken verbatim from JSON. Do not infer or change them from WeekPlan or other sources.",
        "4. You may adapt only: prioritization (🔴/🟡/🟢), wording of the Result column 'Result', row order.",
        "5. The day budget must strictly equal the sum of hours from JSON + mandatory_daily_wps.",
        "6. Do not change the structure markdown (tables, lists, bold text).",
        "7. Return ONLY the section content — WITHOUT the section heading.",
        "8. Audit-trail for carry-over: after the line '**Carry-over from Day Close yesterday:**' reproduce the FULL list from WeekReport ('Not completed (carry-over ...)') or the previous days DayPlan ('Start tomorrow with'). If any-item carry-over did NOT make it into the plan table — keep it in the line itself carry-over with the note `(deferred: <reason>)` in parentheses immediately after the item. Possible reasons: 'no WP-ID — ad-hoc task, does not pass JSON-fact pipeline' / 'conditional carry-over \"if the budget\", the daily budget is filled by other WPs' / 'WP in JSON, but the status — done/blocked'. do NOT silently drop the item — the pilot must have a trace remaining. IMPORTANT: items marked as '(deferred: ...)' exist ONLY in the line carry-over (text trace), their hours do NOT count toward the Day Budget (invariant 5 remains in effect: budget = sum of hours JSON-actuals + mandatory_daily_wps).",
        "9. In the provided section the table contains one row-FORMAT SAMPLE: '| 🔴 | C | NNN | **<!-- PENDING -->** | X | pending |'. This is NOT data and not a WP from JSON — this is only a demonstration of the column format. This entire row (including the literals NNN, X, pending) MUST NOT appear in your response in any form. Replace it (and add the remaining) EXACTLY N rows, where N = the number of WPs in JSON-facts (invariant 2) — one row per WP, real number/name/hours/status from JSON, without a single NNN/X/<!-- PENDING --> in the final table.",
        "",
        "=== JSON-FACTS: Active WPs (source — frontmatter WP-*.md) ===",
        facts_json,
        "",
        "=== CONTEXT: WeekPlan ===",
        weekplan[:6000],
        "",
    ]
    if calendar:
        parts += ["=== CONTEXT: Calendar ===", calendar[:1500], ""]
    if cp_profile:
        parts += ["=== CONTEXT: Pilot Profile ===", cp_profile[:800], ""]
    parts += [
        f"=== SECTION: {header} ===",
        section_content,
        "",
        "Return ONLY the section content (without the heading) with all substitutions applied.",
        "Do not wrap the response in ```markdown ```.",
    ]
    return "\n".join(parts)


def call_proxy(prompt: str, proxy_url: str, proxy_secret: str | None,
               temperature: float | None = None) -> str:
    payload = {
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": 2048,
        "verification_class": "closed-loop",
    }
    if temperature is not None:
        payload["temperature"] = temperature
    headers = {"Content-Type": "application/json"}
    if proxy_secret:
        headers["X-IWE-Internal-Secret"] = proxy_secret

    req = urllib.request.Request(
        f"{proxy_url.rstrip('/')}/v1/messages",
        data=json.dumps(payload).encode("utf-8"),
        headers=headers,
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=SECTION_TIMEOUT_S) as resp:
        data = json.loads(resp.read().decode("utf-8"))
        for block in data.get("content", []):
            if block.get("type") == "text":
                return block.get("text", "")
        return data.get("text", "")


def is_world_chunk(chunk: dict) -> bool:
    return any(section["title"] == "World" for section in _details_sections("".join(chunk["lines"])))


def fill_world_lens_inplace(chunk: dict, weekplan: str, active_wps: str,
                            proxy_url: str, proxy_secret: str | None) -> bool:
    """Phase32 p.1 (WP-484, 31.07): the world section's news list is scaffold-rendered
    fact, not LLM material — sending the whole section for rewriting reliably lost
    the list (the model returned only its «Summary», with hallucinated WP numbers).
    Replace ONLY the single '**Summary:** <!-- PENDING ... -->' line; every other
    line stays byte-identical. Returns True if a replacement happened."""
    lens_indices = [i for i, line in enumerate(_mask_code("".join(chunk["lines"])).splitlines())
                    if line.startswith("**Summary:**") and "<!-- PENDING" in line]
    if not lens_indices:
        return False  # deterministic «no data» Summary from the scaffold — nothing to fill
    if len(lens_indices) != 1:
        raise ValueError("World lens is ambiguous; original PENDING retained")
    lens_idx = lens_indices[0]
    news_body = "".join(
        line for i, line in enumerate(chunk["lines"][2:], start=2)
        if i != lens_idx and line.strip() != "</details>"
    )
    prompt = "\n".join([
        "You are — the morning assistant of the IWE pilot IWE.",
        "Below is the list of todays news (section «World» DayPlan) and the week plan.",
        "TASK: return ONLY the text for the line '**Summary:**' — 2-4 sentences: which of THESE news items are relevant to active WPs from WeekPlan.",
        "Reference only WP-numbers, actually present in the context below; do not fabricate anything.",
        "Do not repeat the news list, do not add headings or HTML, return the bare output text as a single line.",
        "",
        "=== NEWS ===",
        news_body,
        "=== CONTEXT: WeekPlan ===",
        weekplan[:4000],
        "=== CONTEXT: Active WP ===",
        active_wps or "No active WP.",
    ])
    response = call_proxy(prompt, proxy_url, proxy_secret).strip()
    if not response:
        raise RuntimeError("Empty response for world lens (Conclusion)")
    response = re.sub(r"^\**Conclusion:\**\s*", "", response)
    if not response or "\n" in response or "\r" in response or re.search(r"</?[A-Za-z]|<!--", response):
        raise ValueError("World lens must contain one nonempty plain-text line; original PENDING retained")
    chunk["lines"][lens_idx] = f"**Conclusion:** {response}\n"
    return True


def is_today_plan_section(header: str, content: str) -> bool:
    return (
        "Plan for today" in content or "today_plan" in content.lower()
        or "Plan for today" in header or "today_plan" in header.lower()
    )


def warn_today_plan_placeholders(text: str) -> None:
    """Report final table placeholders using the Block DOF signature (WP-561)."""
    for chunk in split_into_chunks(text):
        content = "".join(chunk["lines"])
        if not is_today_plan_section(chunk["header"], content):
            continue
        leftover = [line for line in content.splitlines()
                    if line.strip().startswith("|")
                    and re.search(r"\|\s*NNN\s*\||<!-- PENDING|\|\s*X\s*\|", line)]
        if leftover:
            print("[WARN] today_plan final table contains placeholders "
                  "(NNN/X/PENDING) -- Block DOF check will block the commit. "
                  "Offending line(s):", file=sys.stderr)
            for line in leftover:
                print(f"[WARN]   {line}", file=sys.stderr)


def fill_chunk(chunk: dict, weekplan: str, active_wps: str, calendar: str,
               cp_profile: str, proxy_url: str, proxy_secret: str | None,
               wp_facts: list[dict] | None = None,
               fault_profile: str = "",
               fleeting_notes: str = "") -> str:
    header = chunk["header"]
    content = "".join(chunk["lines"][1:])  # without heading

    # Consolidated prompt with JSON facts for today_plan.
    # `header` is usually the bare "<details>"/"<details open>" tag (chunking
    # stores the <summary> title in `content`, not `header`) — checking
    # `header` alone means this branch never fires for that shape, and the
    # plan table falls through to the generic per-section prompt, which
    # leaves the scaffold's example placeholders (N/NNN/X) unreplaced instead
    # of computing a real seq/hours value per WP. Checking `content` alone
    # would instead miss a plain "## Plan for today" heading (chunk header
    # can carry the title directly there) if the body never repeats the
    # phrase — Codex review, WP-484 backfill-regression-fix session, 31.08.
    # Checking both covers each chunking shape without betting on which one
    # is live. Regressed and re-fixed three times in a consumer's installed
    # copy (2026-07-09, then 26.08, then 31.08) — each time only that copy
    # was patched, so this canonical source kept re-seeding the bug on the
    # next backfill; fixed here too (WP-484, peer-session with Codex, same
    # day) to close that loop.
    is_today_plan = is_today_plan_section(header, content)
    if is_today_plan and wp_facts:
        prompt = build_today_plan_prompt(header, content, weekplan, wp_facts,
                                         calendar, cp_profile, fault_profile)
        response = call_proxy(prompt, proxy_url, proxy_secret, temperature=0.0)
    else:
        prompt = build_section_prompt(header, content, weekplan, active_wps,
                                      calendar, cp_profile, fault_profile,
                                      fleeting_notes=fleeting_notes)
        response = call_proxy(prompt, proxy_url, proxy_secret)

    if not response.strip():
        raise RuntimeError(f"Empty response for section {header}")
    return response


def main() -> None:
    parser = argparse.ArgumentParser(description="WP-356 per-section LLM DayPlan filler")
    parser.add_argument("--scaffold", required=True)
    parser.add_argument("--weekplan", required=True)
    parser.add_argument("--wp-registry", required=True)
    parser.add_argument("--wp-dir", default=None)
    parser.add_argument("--cp-profile", default=None)
    parser.add_argument("--calendar", default=None)
    parser.add_argument("--fleeting-notes", default=None, dest="fleeting_notes")
    parser.add_argument("--out", required=True)
    parser.add_argument("--proxy-url", default=os.getenv("LLM_PROXY_URL", DEFAULT_PROXY_URL))
    parser.add_argument("--proxy-secret", default=os.getenv("LLM_PROXY_SECRET", None))
    args = parser.parse_args()

    scaffold = read_file(args.scaffold)
    if "<!-- PENDING" not in scaffold:
        warn_today_plan_placeholders(scaffold)
        print("[INFO] No PENDING markers — nothing to fill.")
        Path(args.out).write_text(scaffold, encoding="utf-8")
        return

    weekplan = read_file(args.weekplan)
    wp_registry = read_file(args.wp_registry)
    calendar = read_file(args.calendar)
    cp_profile = read_file(args.cp_profile)
    fleeting_notes = read_file(args.fleeting_notes)
    active_wps = extract_active_wps(wp_registry)

    # Collect structured WP facts from frontmatter
    wp_dir = args.wp_dir
    if not wp_dir:
        wp_dir = os.path.join(os.path.dirname(args.wp_registry), "..", "inbox")
        wp_dir = os.path.normpath(wp_dir)
    wp_facts = collect_wp_facts(wp_dir)
    if wp_facts:
        print(f"[INFO] Collected {len(wp_facts)} WP facts from {wp_dir}", file=sys.stderr)

    fault_profile = load_fault_profile()
    if fault_profile:
        n_rules = len(fault_profile.splitlines())
        print(f"[INFO] Loaded fault profile ({n_rules} rules)", file=sys.stderr)

    chunks = split_into_chunks(scaffold)
    filled_chunks = []
    failed_sections = []

    for chunk in chunks:
        if not chunk["has_pending"]:
            filled_chunks.append(chunk)
            continue
        # World section: targeted single-line lens fill, list stays byte-identical
        # (Phase32 item.1 — the generic whole-chunk path lost the scaffold's news list).
        if is_world_chunk(chunk):
            try:
                if fill_world_lens_inplace(chunk, weekplan, active_wps,
                                           args.proxy_url, args.proxy_secret):
                    print("[OK] Filled: World (only the Conclusion line, list preserved)", file=sys.stderr)
                else:
                    print("[INFO] World: PENDING outside the Conclusion line (no source data) — section left as is", file=sys.stderr)
            except Exception as e:  # noqa: BLE001 — same per-section failure contract as below
                failed_sections.append("World")
                print(f"[FAIL] Section World: {e}", file=sys.stderr)
            filled_chunks.append(chunk)
            continue
        try:
            new_content = fill_chunk(chunk, weekplan, active_wps, calendar, cp_profile,
                                     args.proxy_url, args.proxy_secret, wp_facts,
                                     fault_profile, fleeting_notes=fleeting_notes)
            # Structural tag protection: restore canonical <summary>, drop LLM-wrapped
            # <details>, and balance </details> so nesting stays valid.
            original_text = "".join(chunk["lines"])
            header_line = chunk["lines"][0]
            # Always restore canonical <summary> from scaffold — LLM may omit or alter it.
            # re.sub removes whatever the LLM produced; we then prepend the original.
            # If LLM dropped </summary> (malformed), regex doesn't match → prepend still runs,
            # browser renders first <summary> (canonical) and ignores malformed tail.
            if len(chunk["lines"]) > 1:
                second_line = chunk["lines"][1]
                if second_line.strip().startswith("<summary>"):
                    nc = re.sub(r"<summary>.*?</summary>", "", new_content, count=1, flags=re.DOTALL).lstrip("\n")
                    # Strip the LLM's own <details> opener from `nc` here, while it's still
                    # leading (this is what the LLM wrapped its whole answer in, summary and
                    # all). Doing this AFTER prepending `second_line` below is too late: the
                    # combined string then starts with the canonical <summary>, not <details>,
                    # so _strip_leading_details silently no-ops and the LLM's opener survives
                    # as an orphaned bare <details> right after the summary (found 2026-07-02,
                    # 8 sections in one DayPlan) — its matching closer is still counted as
                    # "balanced" against the header's opener further down, so the header's own
                    # <details> never gets closed and every section after it renders nested.
                    nc = _strip_leading_details(nc)
                    new_content = second_line + "\n" + nc
            # Strip every leading <details...> line the LLM wrapped its answer in. header_line
            # already carries the canonical opening tag; a leftover bare <details> without a
            # <summary> renders as the literal word "Details". Loop, because the LLM sometimes
            # emits two opening tags in a row.
            new_content = _strip_leading_details(new_content)
            # Balance </details> both ways. LLM may drop nested closers (add missing) or emit
            # extras that close the outer block early and orphan the sections below (drop extras).
            original_details_count = original_text.count("</details>")
            new_details_count = new_content.count("</details>")
            if new_details_count < original_details_count:
                new_content = new_content.rstrip() + "\n</details>\n" * (original_details_count - new_details_count)
            elif new_details_count > original_details_count:
                new_content = _drop_trailing_closers(new_content, new_details_count - original_details_count)
            # Reconstruct chunk: keep header, replace content
            new_lines = [header_line]  # header
            new_lines.append(new_content)
            # Ensure trailing newline if original had it
            if chunk["lines"] and chunk["lines"][-1].endswith("\n") and not new_content.endswith("\n"):
                new_lines.append("\n")
            chunk["lines"] = new_lines
            filled_chunks.append(chunk)
            print(f"[OK] Filled: {chunk['header'][:60]}", file=sys.stderr)
        except Exception as e:
            print(f"[WARN] Failed section {chunk['header'][:60]}: {e}", file=sys.stderr)
            failed_sections.append(chunk["header"])
            filled_chunks.append(chunk)  # keep original with PENDING

    # Reassemble
    result_lines = []
    for chunk in filled_chunks:
        result_lines.extend(chunk["lines"])
    result = "".join(result_lines)

    # WP-5 Phase 2026-06-11 Item1: Compact Dashboard — top-7 from the finished plan, not sweep
    result = rebuild_compact_dashboard(result)
    # WP-417 Phase3.4: scoreboard tile for yesterday — AFTER rebuild (otherwise it will overwrite the block), locally
    result = inject_panel_tile(result)
    # Gate-metrics: replace the section body with the real output of gate-metrics.sh (Mac only Mac)
    result = inject_gate_metrics(result)
    # Inspect the actual output after all local post-processing.
    # A failed LLM call can also leave the original scaffold table in this output.
    warn_today_plan_placeholders(result)

    # Sanity: if result is much shorter than scaffold, something went wrong
    if len(result) < len(scaffold) * 0.5:
        print("[ERROR] Result too short, aborting.", file=sys.stderr)
        sys.exit(1)

    # Atomic write
    out_path = Path(args.out)
    tmp = out_path.with_suffix(out_path.suffix + ".tmp")
    tmp.write_text(result, encoding="utf-8")
    tmp.rename(out_path)

    # Gate: a bare <details> without <summary> renders as the word "Details" in the
    # pilot's DayPlan. Exit 2 so day-open-checks blocks the commit until it's fixed.
    if has_bare_details(result):
        print("[WARN] Bare <details> without <summary> detected — 'Details' rendering bug.", file=sys.stderr)
        sys.exit(2)

    if failed_sections:
        print(f"[WARN] Sections not filled: {failed_sections}", file=sys.stderr)
        sys.exit(2)  # partial fill — checks will catch remaining PENDING

    print(f"[OK] Written to {args.out}")


if __name__ == "__main__":
    main()
