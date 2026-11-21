#!/usr/bin/env python3
"""Repair an existing note-review plist without changing its activation state."""

import copy
import os
from pathlib import Path
import plistlib
import stat
import sys
import tempfile
from xml.parsers.expat import ExpatError


LABEL = "com.strategist.notereview"
MANAGED_ENV = (
    "IWE_TEMPLATE",
    "IWE_WORKSPACE",
    "IWE_RUNTIME",
    "IWE_SCRIPTS",
    "IWE_GOVERNANCE_REPO",
)


def read_plist(path):
    raw = path.read_bytes()
    data = plistlib.loads(raw)
    if not isinstance(data, dict) or data.get("Label") != LABEL:
        raise ValueError("unexpected plist label or root")
    env = data.get("EnvironmentVariables", {})
    if not isinstance(env, dict) or any(
        not isinstance(key, str) or not isinstance(value, str)
        for key, value in env.items()
    ):
        raise ValueError("invalid environment")
    # Program overrides ProgramArguments[0] in launchd: do not guess its intent.
    if "Program" in data:
        raise ValueError("custom Program is not supported")
    return raw, data


def existing_plist(directory):
    candidates = [
        directory / (LABEL + suffix) for suffix in (".plist", ".plist.disabled")
    ]
    present = [path for path in candidates if os.path.lexists(path)]
    if not present:
        return None
    if len(present) != 1 or present[0].is_symlink() or not present[0].is_file():
        raise ValueError("ambiguous or non-regular note-review plist; unchanged")
    return present[0]


def validate_template(template, workspace, script):
    raw, data = read_plist(template)
    env = data.get("EnvironmentVariables", {})
    if b"{{" in raw or any(not env.get(key) for key in MANAGED_ENV):
        raise ValueError("runtime template is not fully expanded")
    if Path(env["IWE_WORKSPACE"]).resolve() != workspace:
        raise ValueError("runtime template belongs to another workspace")
    expected = Path(env["IWE_RUNTIME"]) / "roles/strategist/scripts/strategist.sh"
    if not script.is_absolute() or not script.is_file() or script != expected:
        raise ValueError("generated runtime script is unavailable or inconsistent")
    if data.get("ProgramArguments") != [str(script), "note-review"]:
        raise ValueError("unexpected runtime command")
    return env


def is_legacy_command(command, workspace):
    # Old role layout: <workspace>/<repository>/strategist/scripts/strategist.sh.
    # Repository names are installation data, not a template-wide constant.
    try:
        parts = command.resolve().relative_to(workspace).parts
    except ValueError:
        return False
    return len(parts) == 4 and parts[1:] == ("strategist", "scripts", "strategist.sh")


def migrated_data(installed, workspace, script, runtime_env):
    env = installed.get("EnvironmentVariables", {})
    args = installed.get("ProgramArguments")
    if (
        not isinstance(args, list)
        or len(args) != 2
        or not isinstance(args[0], str)
        or args[1] != "note-review"
        or not Path(args[0]).is_absolute()
    ):
        raise ValueError("unknown note-review command; unchanged")
    command = Path(args[0])
    legacy = is_legacy_command(command, workspace)
    if not legacy and command.resolve() != script.resolve():
        raise ValueError("unknown note-review command; unchanged")
    owner = env.get("IWE_WORKSPACE")
    if owner is not None:
        if not Path(owner).is_absolute() or Path(owner).resolve() != workspace:
            raise ValueError("note-review belongs to another workspace; unchanged")
    elif not legacy:
        raise ValueError("note-review owner cannot be established; unchanged")
    result = copy.deepcopy(installed)
    result["ProgramArguments"] = [str(script), "note-review"]
    result.setdefault("EnvironmentVariables", {}).update(
        {key: runtime_env[key] for key in MANAGED_ENV}
    )
    return result


def write_migration(path, original, updated):
    metadata = path.stat(follow_symlinks=False)
    mode = stat.S_IMODE(metadata.st_mode)
    backup = None
    temporary = None
    try:
        # Same-directory temp file permits atomic replacement on one filesystem.
        with tempfile.NamedTemporaryFile(
            dir=path.parent, prefix=path.name + ".tmp-", delete=False
        ) as stream:
            temporary = Path(stream.name)
            os.fchmod(stream.fileno(), mode)
            plistlib.dump(updated, stream, sort_keys=False)
            stream.flush()
            os.fsync(stream.fileno())
        with tempfile.NamedTemporaryFile(
            dir=path.parent, prefix=path.name + ".bak-", delete=False
        ) as stream:
            backup = Path(stream.name)
            os.fchmod(stream.fileno(), mode)
            stream.write(original)
            stream.flush()
            os.fsync(stream.fileno())
        # Check after backup I/O, immediately before replacement. This detects
        # observed edits, but is not a lock against a non-cooperating writer.
        if path.is_symlink() or path.stat() != metadata or path.read_bytes() != original:
            raise ValueError("note-review changed during migration; retry after inspection")
        os.replace(temporary, path)
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    return backup


def main(argv):
    if len(argv) != 5:
        print(
            "Usage: migrate-notereview-launchd.py TEMPLATE LAUNCH_AGENTS WORKSPACE SCRIPT",
            file=sys.stderr,
        )
        return 2
    try:
        template, directory, workspace, script = map(Path, argv[1:])
        path = existing_plist(directory)
        if path is None:
            print("note-review: no existing job; manual mode unchanged")
            return 0
        if not workspace.is_absolute() or not workspace.is_dir():
            raise ValueError("current workspace is unavailable")
        workspace = workspace.resolve()
        runtime_env = validate_template(template, workspace, script)
        original, installed = read_plist(path)
        updated = migrated_data(installed, workspace, script, runtime_env)
        if installed == updated:
            print("note-review: paths already current; activation unchanged")
            return 0
        backup = write_migration(path, original, updated)
        print(f"note-review: repaired {path.name}; backup: {backup.name}")
        print(
            "note-review: activation unchanged; a loaded job adopts the paths "
            "only after an explicit reload"
        )
        return 0
    except (OSError, ValueError, plistlib.InvalidFileException, ExpatError) as error:
        print(f"note-review migration refused: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
