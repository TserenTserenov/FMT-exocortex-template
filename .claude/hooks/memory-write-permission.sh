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
#   - <workspace>/memory is a symlink named "memory" whose real target is inside the
#     Claude config folder's projects/ directory (a cloned repository that ships its own
#     memory -> ~/.ssh symlink is NOT approved);
#   - the REAL path of the written file (symlinks resolved) is inside that target.
# Anything else: no output and exit 0, so the permission flow stays unchanged.
# Opt out: IWE_MEMORY_WRITE_AUTO_APPROVE=0.
#
# Not verified against Claude Code's own symlink check order: the documentation does not
# say whether PermissionRequest hooks see this prompt (see issue #1487); confirm on the
# affected version.
set -uo pipefail

[ "${IWE_MEMORY_WRITE_AUTO_APPROVE:-1}" = "0" ] && exit 0
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-${IWE_WORKSPACE:-}}"
[ -n "$PROJECT_DIR" ] || exit 0
command -v python3 >/dev/null 2>&1 || exit 0

MEMORY_PROJECT_DIR="$PROJECT_DIR" python3 -I -c '
import json
import os
import sys

APPROVE_MODES = {"auto", "acceptEdits"}
PATH_FIELD = {
    "Write": "file_path",
    "Edit": "file_path",
    "MultiEdit": "file_path",
    "NotebookEdit": "notebook_path",
}
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

    link = os.path.join(os.environ["MEMORY_PROJECT_DIR"], "memory")
    if not os.path.islink(link):
        return
    memory = os.path.realpath(link)
    config = os.environ.get("CLAUDE_CONFIG_DIR") or os.path.expanduser("~/.claude")
    projects = os.path.realpath(os.path.join(config, "projects"))
    if os.path.basename(memory) != "memory" or not os.path.isdir(memory):
        return
    if not inside(memory, projects):
        return
    if inside(os.path.realpath(target), memory):
        json.dump(ALLOW, sys.stdout)


main()
'
exit 0
