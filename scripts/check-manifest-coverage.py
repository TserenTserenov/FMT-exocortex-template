#!/usr/bin/env python3
# check-manifest-coverage.py — checks that all repo files are covered by update-manifest.json
# Usage: git ls-files | python3 scripts/check-manifest-coverage.py update-manifest.json
# Exit 0 = everything is covered. Exit 1 = files without coverage (B2 gap). Exit 2 = invocation error.
#
# Files without coverage = in git, but not in manifest["files"] and not in exclusions.
# Fix: add to manifest["files"] or manifest["excluded_paths"].
# excluded_paths accepts a list of strings: ["path/to/file.md", ...]
#
# issue #247: update.sh (step 6e) replaces update-manifest.json wholesale on
# every update, so user edits to excluded_paths do not survive. Fork-local
# exclusions belong in update-manifest.local.json (same directory, same
# excluded_paths schema) — update.sh never touches it, this checker merges it.

from __future__ import annotations

import sys
import json
from pathlib import Path


# Files/folders, intentionally not included in manifest:
# - .github/ and setup/ are not excluded entirely: custom workflow and
#   bootstrap-scripts must be listed in the manifest. Exclusions below
#   list only maintainer/test-only subtrees and files.
# - seed/           — scaffold-templates (on first install only install)
# - templates/      — scaffold-templates (on first install only install)
# - extensions/     — user customizations, not overwritten
# - params.yaml     — user config (authored)
# - generate-manifest.sh / update-manifest.json — manifest tooling
# - README.md / LICENSE / CONTRIBUTING.md / CHANGELOG.md / CODE_OF_CONDUCT.md /
#   SECURITY.md / PRIVACY.md / CODEOWNERS / CITATION.cff / .gitattributes — repo meta files (root only) (root only)
# - .gitkeep        — empty directory markers
# - .DS_Store       — junk macOS

# File names, excluded ONLY when located in the repo root (len(parts)==1).
# Platform-specific README.md, CHANGELOG.md in subdirectories (roles/*/README.md) — in the manifest,
# and if a new one is added, do not forget to add it to the manifest → CI must catch that.
_ROOT_ONLY_EXCLUDED_NAMES = frozenset({
    "README.md",
    "README.en.md",
    "CONTRIBUTING.md",
    "LICENSE",
    "CHANGELOG.md",
    "CODE_OF_CONDUCT.md",
    "SECURITY.md",
    "PRIVACY.md",
    "CODEOWNERS",
    "CITATION.cff",
    ".gitattributes",
})

# File names, excluded everywhere regardless of directory.
_ALWAYS_EXCLUDED_NAMES = frozenset({
    ".DS_Store",
    ".gitkeep",
    "params.yaml",
    # issue #348: working params.yaml is no longer tracked by the template, in the repository
    # a sample file resides. Both names — user space, neither one nor the other
    # is not delivered via the manifest: the working file is seeded by build-runtime.sh.
    "params.yaml.example",
    "generate-manifest.sh",
    "update-manifest.json",
    "update-manifest.local.json",
})

# Exact paths for exclusion.
_EXCLUDED_EXACT_PATHS = frozenset({
    ".claude/settings.local.json",
    ".github/PULL_REQUEST_TEMPLATE.md",
    ".github/workflows/aisystant-sync.yml",
    ".github/workflows/release.yml",
    ".github/workflows/stale.yml",
    ".github/workflows/translate-sync.yml",
    ".github/workflows/validate-template.yml",
    ".github/workflows/weekly-release.yml",
    # WP-529 (29.09.2026): release-pipeline guards of this repo (stale release
    # PR notice, CHANGELOG entry gate) - maintainer-only, same category as
    # weekly-release.yml above.
    ".github/workflows/changelog-gate.yml",
    ".github/workflows/release-watchdog.yml",
    # WP-529 Phase21: this repo's own red-team attestation pipeline (compute
    # digest + sign via GitHub Attestations API) — references THIS repo's
    # specific red-team-auditors environment and policy file, same
    # maintainer-only category as release.yml/weekly-release.yml above, not
    # something a fork should get delivered via update.sh.
    ".github/workflows/attestation-compute.yml",
    ".github/workflows/attestation-sign.yml",
    "setup/detector-regex.sh",
    "setup/integration-contract-validator.sh",
    "setup/optional/COVER-IMAGES.md",
    "setup/optional/README.md",
    "setup/optional/generate-post-image.py",
    "setup/optional/pomodoro-alert.plist",
    "setup/optional/pomodoro-alert.py",
    "setup/optional/setup-agent-workspace.sh",
    "setup/optional/setup-calendar.sh",
    "setup/release-audit-prompt.md",
    "setup/smoke-test-fresh-install.sh",
    "setup/test-detectors.sh",
    "setup/test-update-edge-cases.sh",
    "setup/test-update-issue-226.sh",
    "setup/ux-walkthrough-prompt.md",
})

_EXCLUDED_PREFIXES = frozenset({
    ".github/ISSUE_TEMPLATE/",
    "setup/detector-fixtures/",
    "setup/promote-fixtures/",
})

# Top-level directories: all content is excluded.
_EXCLUDED_TOP_DIRS = frozenset({
    "seed",
    "templates",
    "extensions",
})


def _is_excluded(path: str, extra: list[str]) -> bool:
    p = Path(path)
    parts = p.parts

    if p.name in _ALWAYS_EXCLUDED_NAMES:
        return True

    # Root meta-files: exclude only if they are directly in the repo root
    if len(parts) == 1 and p.name in _ROOT_ONLY_EXCLUDED_NAMES:
        return True

    if path in _EXCLUDED_EXACT_PATHS:
        return True

    if any(path.startswith(prefix) for prefix in _EXCLUDED_PREFIXES):
        return True

    if parts and parts[0] in _EXCLUDED_TOP_DIRS:
        return True

    if path in extra:
        return True

    for exc in extra:
        exc_norm = exc.rstrip("/")
        if path.startswith(exc_norm + "/") or path == exc_norm:
            return True

    return False


def _parse_excluded_paths(raw: object) -> list[str]:
    """Accepts a list of strings or a list of dict's {"path": "..."} → list of strings."""
    if not isinstance(raw, list):
        return []
    result = []
    for item in raw:
        if isinstance(item, str):
            result.append(item)
        elif isinstance(item, dict) and "path" in item:
            result.append(item["path"])
    return result


def _force_utf8_streams() -> None:
    """Emit the report as UTF-8 whatever the console code page is.

    On Windows (cp1251/cp866 consoles) printing the status emoji raises
    UnicodeEncodeError -- on the success path, which turned a passed check
    into a blocked commit (issue #927). reconfigure() exists on text streams
    from Python 3.7; skip silently where a stream lacks it (e.g. replaced).
    """
    for stream in (sys.stdout, sys.stderr):
        reconfigure = getattr(stream, "reconfigure", None)
        if reconfigure is not None:
            reconfigure(encoding="utf-8")


def main() -> None:
    _force_utf8_streams()
    if len(sys.argv) < 2:
        print("Usage: git ls-files | python3 check-manifest-coverage.py <manifest.json>",
              file=sys.stderr)
        sys.exit(2)

    manifest_path = sys.argv[1]
    try:
        with open(manifest_path, encoding="utf-8") as fh:
            manifest = json.load(fh)
    except FileNotFoundError:
        print(f"ERROR: manifest not found: {manifest_path}", file=sys.stderr)
        sys.exit(2)

    manifest_files = {entry["path"] for entry in manifest.get("files", [])}
    deprecated_files = {entry["path"] for entry in manifest.get("deprecated_files", [])}
    extra_exclusions = _parse_excluded_paths(manifest.get("excluded_paths", []))

    # Fork-local exclusions survive update.sh (which replaces the main manifest
    # wholesale at step 6e). Malformed JSON is a loud error, not a silent skip:
    # otherwise a typo would silently re-enable blocking on excluded files.
    local_path = Path(manifest_path).parent / "update-manifest.local.json"
    if local_path.is_file():
        try:
            with open(local_path, encoding="utf-8") as fh:
                local_manifest = json.load(fh)
        except json.JSONDecodeError as exc:
            print(f"ERROR: {local_path} is not valid JSON: {exc}", file=sys.stderr)
            sys.exit(2)
        extra_exclusions += _parse_excluded_paths(
            local_manifest.get("excluded_paths", [])
        )

    repo_files = [line.strip() for line in sys.stdin if line.strip()]

    if not repo_files:
        print("ERROR: stdin is empty — git ls-files returned no files (empty repo or pipe error)",
              file=sys.stderr)
        sys.exit(2)

    gaps = []
    excluded_count = 0
    deprecated_count = 0
    for f in repo_files:
        if f in manifest_files:
            continue
        if f in deprecated_files:
            deprecated_count += 1
            continue
        if _is_excluded(f, extra_exclusions):
            excluded_count += 1
            continue
        gaps.append(f)

    if gaps:
        print(
            f"❌ manifest-coverage: {len(gaps)} file(s) present in the repo, but not in {manifest_path}:",
            file=sys.stderr,
        )
        for g in sorted(gaps):
            print(f"  {g}", file=sys.stderr)
        print(
            '  → Add to manifest["files"] or manifest["excluded_paths"];\n'
            "    fork-personal files — in update-manifest.local.json "
            '("excluded_paths": [...]), it update.sh does not overwrite',
            file=sys.stderr,
        )
        sys.exit(1)

    total = len(repo_files)
    in_manifest = len(manifest_files)
    print(
        f"✅ manifest-coverage: all {total} repo-repo files are covered "
        f"(manifest={in_manifest}, excluded={excluded_count}, deprecated_in_repo={deprecated_count})"
    )


if __name__ == "__main__":
    main()
