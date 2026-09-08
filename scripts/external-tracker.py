#!/usr/bin/env python3
"""External tracker adapter for IWE work products.

The local WP context is authoritative.  GitHub Issues are an opt-in projection:
without an explicit allowlist this command never performs a network write.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any


TERMINAL_STATUSES = {"done", "closed", "complete", "completed", "archived"}
WP_RE = re.compile(r"^WP-(\d+)$")


@dataclass(frozen=True)
class Config:
    adapter: str = "none"
    failure_policy: str = "preserve_local"
    source_of_truth: str = "iwe"
    github_owner: str = ""
    github_repositories: tuple[str, ...] = ()


@dataclass
class Context:
    path: Path
    wp: str
    title: str
    status: str
    fields: dict[str, str]
    lines: list[str]
    frontmatter_end: int


class TrackerError(RuntimeError):
    pass


def result(status: str, **data: Any) -> dict[str, Any]:
    return {"status": status, **data}


def emit(payload: dict[str, Any]) -> int:
    print(json.dumps(payload, ensure_ascii=False, sort_keys=True))
    return 0


def unquote(value: str) -> str:
    return re.sub(r"\s+#.*$", "", value).strip().strip('"').strip("'")


def parse_config(path: Path) -> Config:
    if not path.exists():
        return Config()

    values: dict[str, str] = {}
    repositories: list[str] = []
    in_external = False
    in_github = False
    in_repositories = False

    for raw_line in path.read_text(encoding="utf-8").splitlines():
        if not raw_line.strip() or raw_line.lstrip().startswith("#"):
            continue
        indent = len(raw_line) - len(raw_line.lstrip(" "))
        line = raw_line.strip()
        if indent == 0:
            in_external = line == "external_tracker:"
            in_github = False
            in_repositories = False
            key, sep, value = line.partition(":")
            if sep and key.startswith("external_tracker_"):
                values[key] = unquote(value)
            continue
        if not in_external:
            continue
        if indent == 2 and line == "github:":
            in_github = True
            in_repositories = False
            continue
        if indent == 2:
            in_github = False
            key, sep, value = line.partition(":")
            if sep:
                values[key] = unquote(value)
                in_repositories = key == "repositories" and not value.strip()
            continue
        if in_github and indent == 4:
            key, sep, value = line.partition(":")
            if sep:
                values[f"github_{key}"] = unquote(value)
                in_repositories = key == "repositories" and not value.strip()
            continue
        if in_repositories and line.startswith("- "):
            repositories.append(unquote(line[2:]))

    flat_repositories = values.get("external_tracker_github_repositories", "")
    if flat_repositories:
        repositories.extend(item.strip() for item in flat_repositories.split(",") if item.strip())
    return Config(
        adapter=values.get("adapter", values.get("external_tracker_adapter", "none")),
        failure_policy=values.get("failure_policy", values.get("external_tracker_failure_policy", "preserve_local")),
        source_of_truth=values.get("source_of_truth", values.get("external_tracker_source_of_truth", "iwe")),
        github_owner=values.get("github_owner", values.get("external_tracker_github_owner", "")),
        github_repositories=tuple(dict.fromkeys(repositories)),
    )


def load_context(path: Path) -> Context:
    lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    if not lines or lines[0].strip() != "---":
        raise TrackerError("context has no YAML frontmatter")
    try:
        end = next(index for index, line in enumerate(lines[1:], start=1) if line.strip() == "---")
    except StopIteration as exc:
        raise TrackerError("context frontmatter is not closed") from exc

    fields: dict[str, str] = {}
    for line in lines[1:end]:
        key, sep, value = line.partition(":")
        if sep and re.fullmatch(r"[A-Za-z0-9_]+", key.strip()):
            fields[key.strip()] = unquote(value)
    wp_raw = fields.get("wp", "")
    if not wp_raw.isdigit():
        raise TrackerError("context frontmatter requires numeric wp")
    return Context(
        path=path,
        wp=f"WP-{int(wp_raw)}",
        title=fields.get("title", f"{wp_raw} work product"),
        status=fields.get("status", "unknown").lower(),
        fields=fields,
        lines=lines,
        frontmatter_end=end,
    )


def configured(config: Config) -> dict[str, Any] | None:
    if config.adapter == "none":
        return result("DISABLED", reason="external_tracker.adapter is none")
    if config.adapter != "github_issues":
        return result("INVALID_CONFIG", reason="only github_issues and none are supported")
    if config.failure_policy != "preserve_local" or config.source_of_truth != "iwe":
        return result("INVALID_CONFIG", reason="failure_policy=preserve_local and source_of_truth=iwe are required")
    if not config.github_repositories:
        return result("INVALID_CONFIG", reason="GitHub repository allowlist is empty")
    if any("/" not in repository for repository in config.github_repositories):
        return result("INVALID_CONFIG", reason="every allowed repository must be owner/name")
    if config.github_owner and any(not repository.startswith(f"{config.github_owner}/") for repository in config.github_repositories):
        return result("INVALID_CONFIG", reason="repository allowlist conflicts with github.owner")
    return None


def run_gh(arguments: list[str]) -> tuple[int, str, str]:
    executable = os.environ.get("IWE_GITHUB_CLI", "gh")
    process = subprocess.run([executable, *arguments], capture_output=True, text=True, check=False)
    return process.returncode, process.stdout, process.stderr


def gh_json(arguments: list[str]) -> tuple[dict[str, Any] | list[dict[str, Any]] | None, dict[str, Any] | None]:
    rc, stdout, stderr = run_gh(arguments)
    if rc != 0:
        return None, result("UNAVAILABLE", reason=(stderr or stdout or "GitHub CLI failed").strip())
    try:
        return json.loads(stdout), None
    except json.JSONDecodeError:
        return None, result("UNAVAILABLE", reason="GitHub CLI returned invalid JSON")


def write_link(context: Context, repository: str, issue: dict[str, Any]) -> None:
    values = {
        "external_tracker_adapter": "github_issues",
        "external_tracker_repository": repository,
        "external_tracker_id": str(issue["number"]),
        "external_tracker_url": str(issue["url"]),
    }
    frontmatter = [context.lines[0]]
    pending = dict(values)
    for line in context.lines[1 : context.frontmatter_end]:
        key, separator, _ = line.partition(":")
        normalized_key = key.strip()
        if separator and normalized_key in pending:
            frontmatter.append(f'{normalized_key}: "{pending.pop(normalized_key)}"\n')
        else:
            frontmatter.append(line)
    for key, value in pending.items():
        frontmatter.append(f'{key}: "{value}"\n')
    frontmatter.append(context.lines[context.frontmatter_end])
    temp_path = context.path.with_suffix(f"{context.path.suffix}.external-tracker.tmp")
    temp_path.write_text("".join(frontmatter + context.lines[context.frontmatter_end + 1 :]), encoding="utf-8")
    temp_path.replace(context.path)


def link_from_context(context: Context) -> tuple[str, str] | None:
    repository = context.fields.get("external_tracker_repository", "")
    issue_id = context.fields.get("external_tracker_id", "")
    return (repository, issue_id) if repository and issue_id else None


def is_terminal(status: str) -> bool:
    return status in TERMINAL_STATUSES


def check_context(context: Context, config: Config) -> dict[str, Any]:
    invalid = configured(config)
    if invalid:
        return invalid | {"wp": context.wp}
    link = link_from_context(context)
    if not link:
        return result("MISSING", wp=context.wp)
    repository, issue_id = link
    if repository not in config.github_repositories:
        return result("WRONG_REPO", wp=context.wp, repository=repository)
    issue, error = gh_json(["issue", "view", issue_id, "--repo", repository, "--json", "number,state,url,title"])
    if error:
        return error | {"wp": context.wp, "repository": repository, "external_id": issue_id}
    assert isinstance(issue, dict)
    external_closed = str(issue.get("state", "")).upper() == "CLOSED"
    if is_terminal(context.status) != external_closed:
        return result("STALE", wp=context.wp, repository=repository, external_id=issue_id, local_status=context.status, external_status=issue.get("state"), url=issue.get("url"))
    return result("OK", wp=context.wp, repository=repository, external_id=issue_id, url=issue.get("url"))


def exact_matches(issues: list[dict[str, Any]], wp: str) -> list[dict[str, Any]]:
    marker = re.compile(rf"^{re.escape(wp)}(?:\s|:|—|-)")
    return [issue for issue in issues if marker.search(str(issue.get("title", "")))]


def create_context(context: Context, config: Config, repository: str, dry_run: bool) -> dict[str, Any]:
    invalid = configured(config)
    if invalid:
        return invalid | {"wp": context.wp}
    if repository not in config.github_repositories:
        return result("WRONG_REPO", wp=context.wp, repository=repository)
    if link_from_context(context):
        return check_context(context, config)
    if dry_run:
        return result("DRY_RUN", wp=context.wp, repository=repository)

    workspace = context.path.parents[2] if context.path.parent.name.startswith("WP-") else context.path.parent
    lock_dir = workspace / ".iwe-runtime" / "locks" / f"external-tracker-{context.wp}"
    try:
        lock_dir.mkdir(parents=True)
    except FileExistsError:
        return result("BUSY", wp=context.wp, repository=repository)
    try:
        issues, error = gh_json(["issue", "list", "--repo", repository, "--state", "all", "--search", f"{context.wp} in:title", "--json", "number,state,url,title"])
        if error:
            return error | {"wp": context.wp, "repository": repository}
        assert isinstance(issues, list)
        matches = exact_matches(issues, context.wp)
        if len(matches) > 1:
            return result("DUPLICATE", wp=context.wp, repository=repository, issues=[issue.get("url") for issue in matches])
        if len(matches) == 1:
            write_link(context, repository, matches[0])
            return result("OK", wp=context.wp, repository=repository, external_id=matches[0]["number"], url=matches[0]["url"], reused=True)

        body = f"Projection of {context.wp}. The local IWE context remains the source of truth."
        rc, stdout, stderr = run_gh(["issue", "create", "--repo", repository, "--title", f"{context.wp} {context.title}", "--body", body])
        if rc != 0:
            return result("UNAVAILABLE", wp=context.wp, repository=repository, reason=(stderr or stdout or "GitHub CLI failed").strip())
        url = stdout.strip().splitlines()[-1]
        match = re.search(r"/issues/(\d+)$", url)
        if not match:
            return result("UNAVAILABLE", wp=context.wp, repository=repository, reason="GitHub CLI did not return an issue URL")
        created = {"number": int(match.group(1)), "url": url}
        verify, error = gh_json(["issue", "list", "--repo", repository, "--state", "all", "--search", f"{context.wp} in:title", "--json", "number,state,url,title"])
        if error:
            return error | {"wp": context.wp, "repository": repository}
        assert isinstance(verify, list)
        if len(exact_matches(verify, context.wp)) != 1:
            return result("DUPLICATE", wp=context.wp, repository=repository, created_url=url)
        write_link(context, repository, created)
        return result("OK", wp=context.wp, repository=repository, external_id=created["number"], url=url, created=True)
    finally:
        lock_dir.rmdir()


def context_paths(governance: Path) -> list[Path]:
    patterns = ("inbox/WP-*/WP-*.md", "archive/wp-contexts/WP-*.md", "archive/wp-contexts/WP-*/WP-*.md")
    return sorted({path for pattern in patterns for path in governance.glob(pattern)})


def main() -> int:
    parser = argparse.ArgumentParser(description="IWE external tracker adapter")
    parser.add_argument("command", choices=("create", "check", "audit"))
    parser.add_argument("--context", type=Path)
    parser.add_argument("--repository")
    parser.add_argument("--governance", type=Path)
    parser.add_argument("--config", type=Path, default=Path(os.environ.get("EXTERNAL_TRACKER_CONFIG", "params.yaml")))
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    config = parse_config(args.config)

    try:
        if args.command == "audit":
            if not args.governance:
                raise TrackerError("audit requires --governance")
            entries = []
            for path in context_paths(args.governance):
                try:
                    entries.append(check_context(load_context(path), config) | {"context": str(path.relative_to(args.governance))})
                except TrackerError as exc:
                    entries.append(result("INVALID_CONTEXT", context=str(path.relative_to(args.governance)), reason=str(exc)))
            return emit(result("OK", audited=len(entries), results=entries))
        if not args.context:
            raise TrackerError(f"{args.command} requires --context")
        context = load_context(args.context)
        if args.command == "check":
            return emit(check_context(context, config))
        if not args.repository:
            raise TrackerError("create requires --repository")
        return emit(create_context(context, config, args.repository, args.dry_run))
    except TrackerError as exc:
        return emit(result("INVALID_CONTEXT", reason=str(exc)))


if __name__ == "__main__":
    raise SystemExit(main())
