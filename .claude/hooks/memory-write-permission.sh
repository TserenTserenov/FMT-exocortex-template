#!/usr/bin/env bash
# PermissionRequest — approve writes into the agent's auto-memory folder (issue #1487).
#
# On an IWE install `memory/` in the workspace is a symlink to the agent's auto-memory
# (~/.claude/projects/<project>/memory). Since Claude Code 2.1.280 a write through that
# symlink asks for confirmation even in auto mode ("... (outside working directory) via a
# symlink"), and neither allow rules nor additionalDirectories lift it.
#
# This hook answers ONLY that request, and only when ALL of these hold:
#   - permission_mode is auto or acceptEdits (a user in default mode keeps the prompt);
#   - the tool is Write/Edit/MultiEdit/NotebookEdit with an absolute path;
#   - <workspace>/memory resolves to THIS project's auto-memory folder:
#     <claude config>/projects/<project slug>/memory (a cloned repository that ships its
#     own memory -> ~/.ssh, or -> another project's memory, is NOT approved);
#   - the path as written goes through <workspace>/memory/ (a direct real path is already
#     approved by Claude Code itself), its parent folder exists, and the REAL path of the
#     file (symlinks resolved) is still inside the memory folder.
#   - no component of the real path inside the memory folder is hidden (starts with ".")
#     or named .git/.claude/.github/.ssh/.gnupg (those keep their own confirmation).
# Anything else: no output and exit 0, so the permission flow stays unchanged.
# Opt out: IWE_MEMORY_WRITE_AUTO_APPROVE=0.
#
# Known limits (all fail safe: the hook stays silent and the prompt remains as before):
#   - an "ask" rule of the user for a folder inside memory is NOT seen by this hook: for a
#     path through memory/ it approves an ordinary file even though the same rule prompts
#     for the real path (the hook cannot read the user's permission rules);
#   - the request carries no reason, so the hook cannot tell the symlink prompt from any
#     other prompt for the same path; the documentation does not say whether
#     PermissionRequest hooks see the symlink prompt at all (issue #1487) - confirm on the
#     affected version;
#   - check and write are not atomic: a process that swaps the memory/ symlink between
#     them defeats any hook. The hook is not a boundary against an attacker who can
#     already change files in your workspace;
#   - it needs python3; the project slug rule (every non-alphanumeric character becomes
#     "-", override CLAUDE_CODE_PROJECT_DIR_NAME) and case-sensitive path comparison may
#     not match on every platform (case-insensitive macOS volumes, Git Bash drive paths).
set -uo pipefail

[ "${IWE_MEMORY_WRITE_AUTO_APPROVE:-1}" = "0" ] && exit 0
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-${IWE_WORKSPACE:-}}"
[ -n "$PROJECT_DIR" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

MEMORY_PROJECT_DIR="$PROJECT_DIR" python3 -I -c '
import json
import os
import re
import sys

APPROVE_MODES = {"auto", "acceptEdits"}
PATH_FIELD = {
    "Write": "file_path",
    "Edit": "file_path",
    "MultiEdit": "file_path",
    "NotebookEdit": "notebook_path",
}
SENSITIVE = {".git", ".claude", ".github", ".ssh", ".gnupg"}
ALLOW = {
    "hookSpecificOutput": {
        "hookEventName": "PermissionRequest",
        "decision": {"behavior": "allow"},
    }
}


def inside(path, root):
    return path.startswith(root + os.sep)


def main():
    try:
        data = json.load(sys.stdin)
    except ValueError:
        return
    if not isinstance(data, dict) or data.get("permission_mode") not in APPROVE_MODES:
        return
    field = PATH_FIELD.get(data.get("tool_name"))
    tool_input = data.get("tool_input")
    if field is None or not isinstance(tool_input, dict):
        return
    target = tool_input.get(field)
    if not isinstance(target, str) or not os.path.isabs(target):
        return

    project = os.environ["MEMORY_PROJECT_DIR"]
    link = os.path.join(project, "memory")
    # The auto-memory folder of this very project, not any projects/<name>/memory.
    slug = os.environ.get("CLAUDE_CODE_PROJECT_DIR_NAME") or re.sub(
        r"[^A-Za-z0-9]", "-", os.path.realpath(project)
    )
    config = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
    expected = os.path.realpath(os.path.join(config, "projects", slug, "memory"))
    memory = os.path.realpath(link)
    if memory != expected or not os.path.isdir(memory):
        return
    # The path as written must go through <workspace>/memory/ before symlinks are resolved.
    if not inside(os.path.normpath(target), os.path.normpath(link)):
        return
    real = os.path.realpath(target)
    if not (inside(real, memory) and os.path.isdir(os.path.dirname(real))):
        return
    # Sensitive places inside memory keep their own confirmation (hidden files and
    # folders, .git/.claude/.github/.ssh/.gnupg): approving them here would drop it.
    # Both the path as written and the resolved path are checked: a link inside memory
    # (for example `.git` pointing to an ordinary folder) would hide the name after resolving.
    written = os.path.normpath(target)[len(os.path.normpath(link)) + 1 :]
    for part in written.split(os.sep) + real[len(memory) + 1 :].split(os.sep):
        if part.startswith(".") or part.lower() in SENSITIVE:
            return
    json.dump(ALLOW, sys.stdout)


main()
'
exit 0
