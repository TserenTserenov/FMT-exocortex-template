#!/usr/bin/env python3
"""Shared read-only queue projection and explicit reconciliation (WP-170/569).

Requires PyYAML. Explicit '## R15 decisions' YAML sections accumulate per
candidate, overriding inline history. Extractor verdicts are not pilot decisions.
"""

import argparse
from dataclasses import dataclass, field
from datetime import date, datetime, timezone
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
import tempfile

import yaml


OPEN = {"pending", "pending-review", "partially-applied", "deferred"}
TERMINAL = {"applied", "rejected", "no-pending"}
FRONTMATTER = re.compile(r"\A---\r?\n(.*?)\r?\n---(?:\r?\n|\Z)", re.S)
CANDIDATE = re.compile(r"^#{2,3}\s+(?:Кандидат|Candidate)\s*#?\s*(\d+)\b", re.M | re.I)
FINAL_SECTION = re.compile(r"^##[ \t]+R15 decisions[ \t]*$", re.M | re.I)
OBJECT_ID = re.compile(r"[0-9a-fA-F]{40}(?:[0-9a-fA-F]{24})?\Z")


class InvalidReport(ValueError):
    """Input cannot be projected without inventing a decision."""


class UniqueLoader(yaml.SafeLoader):
    """Reject duplicate keys instead of silently choosing a value."""


def unique_mapping(loader, node, deep=False):
    result = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if not isinstance(key, (str, int)) or key in result:
            raise InvalidReport("duplicate_or_invalid_yaml_key")
        result[key] = loader.construct_object(value_node, deep=deep)
    return result


UniqueLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, unique_mapping)


def load_yaml(text):
    try:
        return yaml.load(text, Loader=UniqueLoader)
    except yaml.YAMLError as exc:
        raise InvalidReport("invalid_yaml") from exc


def candidate_id(value):
    if isinstance(value, bool) or not re.fullmatch(r"[1-9][0-9]*", str(value)):
        raise InvalidReport("invalid_candidate_id")
    return str(value)


@dataclass(frozen=True)
class Fence:
    start: int
    end: int
    language: str
    contents: str
    closed: bool


def fenced_blocks(text):
    """Top-level Markdown fences; nested shorter/different fences are content."""
    offset = 0
    opening = None
    for line in text.splitlines(keepends=True):
        visible = line.rstrip("\r\n")
        if opening is None:
            match = re.fullmatch(r" {0,3}(`{3,}|~{3,})(.*)", visible)
            if match and not (match[1][0] == "`" and "`" in match[2]):
                info = match[2].strip().split()
                opening = (offset, offset + len(line), match[1], info[0].lower() if info else "")
        else:
            start, content_start, marker, language = opening
            closing = r" {0,3}" + re.escape(marker[0]) + "{" + str(len(marker)) + r",}[ \t]*"
            if re.fullmatch(closing, visible):
                yield Fence(start, offset + len(line), language, text[content_start:offset], True)
                opening = None
        offset += len(line)
    if opening is not None:
        start, content_start, marker, language = opening
        yield Fence(start, len(text), language, text[content_start:], False)


def decision_records(text, overrides=None):
    records = {}
    overrides = overrides or {}
    for block in fenced_blocks(text):
        if block.language not in {"yaml", "yml"} or not re.search(r"^(?:candidate_id|decisions):", block.contents, re.M):
            continue
        if not block.closed:
            raise InvalidReport("unclosed_decision_fence")
        document = load_yaml(block.contents)
        if not isinstance(document, dict):
            raise InvalidReport("invalid_decision_document")
        entries = document.get("decisions", [document])
        if not isinstance(entries, list):
            raise InvalidReport("invalid_decisions_list")
        for entry in entries:
            if not isinstance(entry, dict):
                raise InvalidReport("invalid_decision_record")
            key = candidate_id(entry.get("candidate_id"))
            if key in overrides:
                continue
            if key in records:
                raise InvalidReport("duplicate_candidate_decision")
            common = {name: document[name] for name in ("decided_at", "decision_session") if name in document}
            records[key] = {**common, **entry}
    return {**records, **overrides}


def outside_fences(text):
    parts = []
    start = 0
    for block in fenced_blocks(text):
        parts.extend([text[start:block.start], re.sub(r"[^\n]", " ", text[block.start:block.end])])
        start = block.end
    return "".join(parts) + text[start:]


@dataclass
class Report:
    path: Path
    text: str
    frontmatter: dict
    frontmatter_match: re.Match
    candidates: list
    decisions: dict
    has_final: bool
    legacy_r15: bool

    @property
    def status(self):
        return self.frontmatter["status"]

    @property
    def decision_hash(self):
        data = json.dumps({"candidates": self.candidates, "decisions": self.decisions},
                          sort_keys=True, ensure_ascii=False, default=str)
        return hashlib.sha256(data.encode()).hexdigest()


def read_report(path):
    if path.is_symlink() or not path.is_file():
        raise InvalidReport("report_not_regular_file")
    text = path.read_text(encoding="utf-8")
    front = FRONTMATTER.match(text)
    if not front:
        raise InvalidReport("missing_frontmatter")
    metadata = load_yaml(front[1])
    if (not isinstance(metadata, dict) or not isinstance(metadata.get("status"), str)
            or metadata["status"] not in OPEN | TERMINAL):
        raise InvalidReport("unknown_or_missing_status")
    cached = metadata.get("reconciled_published_candidates", [])
    if not isinstance(cached, list) or any(not isinstance(item, (str, int)) for item in cached):
        raise InvalidReport("invalid_publication_cache")
    body = text[front.end():]
    final_sections = list(FINAL_SECTION.finditer(outside_fences(body)))
    legacy = body[:final_sections[0].start()] if final_sections else body
    candidates = CANDIDATE.findall(outside_fences(legacy))
    if len(candidates) != len(set(candidates)):
        raise InvalidReport("duplicate_candidate_heading")
    current = {}
    for final_section in final_sections:
        section = body[final_section.end():]
        next_heading = re.search(r"^##[ \t]+", outside_fences(section), re.M)
        if next_heading:
            section = section[:next_heading.start()]
        entries = decision_records(section)
        if not entries:
            raise InvalidReport("empty_final_decisions")
        for decision in entries.values():
            try:
                decided = datetime.fromisoformat(str(decision.get("decided_at")))
            except ValueError as exc:
                raise InvalidReport("final_decision_time_missing_or_invalid") from exc
            if decided.tzinfo is None or not isinstance(decision.get("decision_session"), str) or not decision["decision_session"].strip():
                raise InvalidReport("final_decision_provenance_missing")
        current.update(entries)
    decisions = decision_records(legacy, current)
    legacy_r15 = bool(re.search(r"^##\s+R15\s+итог|Вердикт R15", legacy, re.M | re.I))
    if set(decisions) - set(candidates):
        raise InvalidReport("decision_without_candidate")
    if not candidates and metadata["status"] in OPEN:
        raise InvalidReport("missing_candidate_headings")
    return Report(path, text, metadata, front, candidates, decisions, bool(final_sections), legacy_r15)


def git(repo, *args):
    try:
        return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True,
                              timeout=15, env={**os.environ, "GIT_TERMINAL_PROMPT": "0"})
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise InvalidReport("publication_git_unavailable") from exc


class PublicationVerifier:
    """Read the remote's actual advertised tip; never fetch or trust local main."""

    def __init__(self, workspace):
        self.workspace = workspace
        self.tips = {}

    def remote_tip(self, repo, branch):
        key = (repo, branch)
        if key not in self.tips:
            ref = "refs/heads/" + branch
            if git(repo, "check-ref-format", ref).returncode:
                self.tips[key] = (None, "publication_invalid_branch")
            else:
                result = git(repo, "ls-remote", "--exit-code", "origin", ref)
                rows = [line.split() for line in result.stdout.splitlines()]
                matches = [row[0] for row in rows if len(row) == 2 and row[1] == ref]
                self.tips[key] = ((matches[0], None) if not result.returncode and len(matches) == 1
                                  else (None, "publication_remote_unavailable"))
        return self.tips[key]

    def verify(self, decision):
        proof = decision.get("publication")
        if not isinstance(proof, dict):
            return "publication_missing"
        name, commit, branch, blob = (proof.get(key) for key in ("repo", "commit", "branch", "blob"))
        if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", name):
            return "publication_invalid_repo"
        if not isinstance(branch, str) or not branch:
            return "publication_invalid_branch"
        if not isinstance(commit, str) or not OBJECT_ID.fullmatch(commit):
            return "publication_invalid_commit"
        if not isinstance(blob, str) or not OBJECT_ID.fullmatch(blob):
            return "publication_blob_missing_or_invalid"
        target = decision.get("target_path")
        if not isinstance(target, str):
            return "publication_target_missing"
        parts = PurePosixPath(target).parts
        if len(parts) < 2 or parts[0] != name or ".." in parts or target.startswith("/"):
            return "publication_target_outside_repo"
        relative = PurePosixPath(*parts[1:]).as_posix()
        repo = self.workspace / name
        if not repo.is_dir():
            return "publication_repo_unavailable"
        tip, error = self.remote_tip(repo, branch)
        if error:
            return error
        if git(repo, "cat-file", "-e", tip + "^{commit}").returncode:
            return "publication_remote_snapshot_unavailable"
        if git(repo, "merge-base", "--is-ancestor", commit, tip).returncode:
            return "publication_commit_not_published"
        result = git(repo, "rev-parse", "--verify", commit + ":" + relative)
        if result.returncode or result.stdout.strip().lower() != blob.lower():
            return "publication_target_blob_mismatch"
        if git(repo, "cat-file", "-t", blob).stdout.strip() != "blob":
            return "publication_target_not_file"
        return None


@dataclass
class Projection:
    status: str
    decide: list = field(default_factory=list)
    deliver: list = field(default_factory=list)
    wait: list = field(default_factory=list)
    published: list = field(default_factory=list)
    diagnostics: list = field(default_factory=list)
    stale: bool = False


def defer_ready(decision, today):
    trigger = decision.get("defer_until")
    if isinstance(trigger, datetime):
        trigger = trigger.date()
    if isinstance(trigger, date):
        return trigger <= today
    if not isinstance(trigger, str) or not trigger.strip():
        raise InvalidReport("defer_until_missing")
    try:
        return date.fromisoformat(trigger) <= today
    except ValueError:
        if re.fullmatch(r"\d{4}-\d{2}-\d{2}", trigger):
            raise InvalidReport("defer_until_invalid_date")
        return decision.get("defer_trigger_confirmed") is True


def project(report, today, verifier=None):
    result = Projection(report.status)
    if report.status in TERMINAL and not report.has_final and not report.frontmatter.get("reconciliation_version"):
        if report.status != "no-pending":
            result.diagnostics.append("legacy_terminal_unverified")
        return result
    if report.legacy_r15 and not report.has_final:
        result.diagnostics.append("legacy_r15_requires_structured_decisions")
        return result
    cached = set()
    if report.frontmatter.get("reconciled_decisions_sha256") == report.decision_hash:
        cached = {str(item) for item in report.frontmatter.get("reconciled_published_candidates", [])}
    started = False
    rejected = []
    for key in report.candidates:
        decision = report.decisions.get(key)
        if not decision or decision.get("decision_source") != "pilot":
            result.decide.append(key)
            if decision:
                result.diagnostics.append(key + ":decision_source_invalid")
            continue
        started = True
        outcome = decision.get("decision")
        if outcome == "accept":
            try:
                error = verifier.verify(decision) if verifier else (None if key in cached else "publication_not_verified")
            except InvalidReport as exc:
                error = str(exc)
            if error:
                result.deliver.append(key)
                if verifier:
                    result.diagnostics.append(key + ":" + error)
                    if key in cached and error in {
                        "publication_remote_unavailable", "publication_remote_snapshot_unavailable",
                        "publication_git_unavailable",
                    }:
                        result.stale = True
            else:
                result.published.append(key)
        elif outcome == "reject" and isinstance(decision.get("reason"), str) and decision["reason"].strip():
            rejected.append(key)
        elif outcome == "defer" and decision.get("reason"):
            try:
                (result.decide if defer_ready(decision, today) else result.wait).append(key)
            except InvalidReport as exc:
                result.decide.append(key)
                result.diagnostics.append(key + ":" + str(exc))
        else:
            result.decide.append(key)
            result.diagnostics.append(key + ":invalid_decision")
    if result.stale and report.status in TERMINAL:
        result.status = report.status
    elif result.decide or result.deliver:
        result.status = "partially-applied" if started else "pending-review"
    elif result.wait:
        result.status = "deferred"
    elif result.published:
        result.status = "applied"
    elif rejected and len(rejected) == len(report.candidates):
        result.status = "rejected"
    return result


def write_projection(report, projection):
    updates = {
        "status": projection.status, "reconciliation_version": 1,
        "reconciliation_stale": projection.stale, "reconciliation_warnings": projection.diagnostics,
        "reconciled_decisions_sha256": report.decision_hash,
        "reconciled_published_candidates": projection.published,
    }
    if projection.stale:
        updates["reconciled_published_candidates"] = report.frontmatter.get("reconciled_published_candidates", [])
    if all(report.frontmatter.get(key) == value for key, value in updates.items()):
        return False
    updates["reconciled_at"] = datetime.now(timezone.utc).isoformat()
    source = report.frontmatter_match[1]
    node = yaml.compose(source, Loader=UniqueLoader)
    remove_lines = set()
    for key_node, value_node in node.value:
        if key_node.value in updates:
            end = value_node.end_mark.line + (value_node.end_mark.column > 0)
            remove_lines.update(range(key_node.start_mark.line, end))
    kept = "\n".join(line for index, line in enumerate(source.splitlines()) if index not in remove_lines)
    metadata = kept.rstrip() + "\n" + yaml.safe_dump(updates, allow_unicode=True, sort_keys=False).rstrip()
    text = "---\n" + metadata + "\n---\n" + report.text[report.frontmatter_match.end():]
    if report.path.is_symlink() or report.path.read_text(encoding="utf-8") != report.text:
        raise InvalidReport("report_changed_during_reconcile")
    descriptor, temporary = tempfile.mkstemp(prefix=".ke-reconcile-", dir=report.path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            output.write(text)
        os.chmod(temporary, report.path.stat().st_mode & 0o777)
        if report.path.read_text(encoding="utf-8") != report.text:
            raise InvalidReport("report_changed_during_reconcile")
        os.replace(temporary, report.path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return True


def report_paths(args):
    if not args.reports_dir.is_dir():
        raise InvalidReport("queue_unavailable")
    if not args.report:
        return sorted(args.reports_dir.glob("*.md"))
    paths = []
    for value in args.report:
        path = Path(value)
        if not path.is_absolute():
            path = args.reports_dir / path
        if path.parent.resolve() != args.reports_dir.resolve() or path.suffix != ".md":
            raise InvalidReport("report_outside_queue")
        paths.append(path)
    return list(dict.fromkeys(paths))


def reconcile(args):
    verifier = PublicationVerifier(args.workspace)
    failures = 0
    for path in report_paths(args):
        try:
            report = read_report(path)
            projection = project(report, args.today, verifier)
            changed = False
            legacy = any(code.startswith("legacy_") for code in projection.diagnostics)
            if not args.dry_run and not legacy:
                changed = write_projection(report, projection)
            print(json.dumps({"report": path.name, **vars(projection), "changed": changed, "dry_run": args.dry_run}, ensure_ascii=False))
            failures += bool(projection.diagnostics)
        except (InvalidReport, OSError, UnicodeError) as exc:
            print(json.dumps({"report": path.name, "error": str(exc) if isinstance(exc, InvalidReport) else "report_unreadable"}))
            failures += 1
    return 1 if failures else 0


def report_age(report, today):
    value = report.frontmatter.get("date")
    if isinstance(value, datetime):
        value = value.date()
    if isinstance(value, str):
        try:
            value = date.fromisoformat(value)
        except ValueError:
            return None
    return max(0, (today - value).days) if isinstance(value, date) else None


def queue_stats(args):
    result = {"count": 0, "oldest_age_days": 0, "estimated_minutes": 0, "estimated_hours": 0,
              "sla_status": "ok", "decision_reports": 0, "delivery_reports": 0, "waiting_reports": 0,
              "decision_candidates": 0, "delivery_candidates": 0, "waiting_candidates": 0, "diagnostics": []}
    try:
        paths = report_paths(args)
    except InvalidReport as exc:
        result["diagnostics"].append({"code": str(exc)})
        paths = []
    report_list = []
    for path in paths:
        try:
            report = read_report(path)
            projection = project(report, args.today)
            if report.frontmatter.get("reconciliation_stale"):
                projection.diagnostics.append("publication_snapshot_stale")
            for problem in projection.diagnostics:
                result["diagnostics"].append({"report": path.name, "code": problem})
            if projection.status in TERMINAL and not projection.decide and not projection.deliver and not projection.wait:
                continue
            result["count"] += 1
            report_list.append({"report": path.name, **vars(projection)})
            for name, values in [("decision", projection.decide), ("delivery", projection.deliver), ("waiting", projection.wait)]:
                result[name + "_reports"] += bool(values)
                result[name + "_candidates"] += len(values)
            if projection.decide or projection.deliver:
                age = report_age(report, args.today)
                if age is None:
                    result["diagnostics"].append({"report": path.name, "code": "report_date_invalid"})
                else:
                    result["oldest_age_days"] = max(result["oldest_age_days"], age)
        except (InvalidReport, OSError, UnicodeError) as exc:
            result["diagnostics"].append({"report": path.name, "code": str(exc) if isinstance(exc, InvalidReport) else "report_unreadable"})
    days = result["oldest_age_days"]
    result["sla_status"] = "critical" if days >= 6 else "warning" if days >= 3 else "approaching" if days >= 1 else "ok"
    if result["diagnostics"]:
        result["sla_status"] = "unknown"
    result["estimated_minutes"] = 5 * (result["decision_reports"] + result["delivery_reports"])
    result["estimated_hours"] = round(result["estimated_minutes"] / 60, 1)
    if args.list_reports:
        for item in report_list:
            print(json.dumps(item, ensure_ascii=False))
        for item in result["diagnostics"]:
            print(json.dumps({"diagnostic": item}, ensure_ascii=False))
    elif args.human or args.dayplan_row:
        if args.dayplan_row and not result["count"] and not result["diagnostics"]:
            return 0
        signals = {"ok": "○", "approaching": "🟡", "warning": "🔴", "critical": "🔴", "unknown": "⚠️"}
        signal = signals[result["sla_status"]]
        summary = (f"{result['count']} незавершённых отчётов; решить: {result['decision_reports']}; "
                   f"доставить: {result['delivery_reports']}; ждут условия: {result['waiting_reports']}")
        if result["decision_reports"] or result["delivery_reports"]:
            summary += f"; самый старый: {result['oldest_age_days']} дн."
        if result["diagnostics"]:
            summary += f"; ошибок проверки: {len(result['diagnostics'])}"
        if args.dayplan_row:
            print(f"| {signal} | — | **apply-captures** — {summary} | {result['estimated_hours']} | pending | — |")
        else:
            print(f"| KE-очередь | {signal} | {summary} |")
    else:
        print(json.dumps(result, ensure_ascii=False))
    return 1 if result["diagnostics"] else 0


def arguments():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["stats", "reconcile"])
    parser.add_argument("--report", action="append", default=[])
    parser.add_argument("--reports-dir", type=Path)
    parser.add_argument("--workspace", type=Path, default=Path(os.environ.get("IWE_BASE", os.environ.get("IWE_WORKSPACE", str(Path.home() / "IWE")))))
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--all", action="store_true", help="explicitly reconcile the entire queue")
    parser.add_argument("--human", action="store_true")
    parser.add_argument("--dayplan-row", action="store_true")
    parser.add_argument("--list", dest="list_reports", action="store_true", help="read-only list of open reports and diagnostics")
    parser.add_argument("--today", type=date.fromisoformat, default=date.today())
    args = parser.parse_args()
    if args.command == "reconcile" and not args.report and not args.all and not args.dry_run:
        parser.error("writing requires --report FILE or explicit --all; --dry-run is read-only")
    if args.reports_dir is None:
        own_repo = Path(__file__).resolve().parent.parent
        governance = os.environ.get("IWE_GOVERNANCE_REPO", "DS-strategy")
        if (own_repo / "inbox/extraction-reports").is_dir():
            args.reports_dir = own_repo / "inbox/extraction-reports"
        else:
            args.reports_dir = args.workspace / governance / "inbox/extraction-reports"
    return args


def main():
    args = arguments()
    try:
        return reconcile(args) if args.command == "reconcile" else queue_stats(args)
    except (InvalidReport, OSError) as exc:
        print(json.dumps({"error": str(exc) if isinstance(exc, InvalidReport) else "io_unavailable"}), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
