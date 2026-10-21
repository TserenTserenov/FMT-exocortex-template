#!/usr/bin/env python3
# check-python-encoding.py — AST gate against open()/Path.open() calls without
# an explicit encoding= (issue #1114, phase 1: stop NEW violations; the
# existing ones live in scripts/tests/python-encoding-baseline.txt as a
# ratchet — a fix removes an entry, a new call must add encoding=).
#
# Why: on Windows with a cp1251 console/locale, open() without encoding
# decodes UTF-8 files as cp1251 (UnicodeDecodeError) and print/json.dumps to
# stdout crash on non-cp1251 characters (UnicodeEncodeError).
#
# Requirements: python3 stdlib only, and git — the file list comes from
# `git ls-files '*.py'` run at the repo root, so generated/vendored and
# untracked files are never scanned. CI runners always have git; there is no
# fallback by design.
#
# A call is a VIOLATION when ALL hold:
#   - it is the builtin open(...), or `<recv>.open(...)` where the receiver is
#     a Path(...) constructor whose Path name is PROVABLY pathlib's (imported
#     via `from pathlib import Path [as X]` or `<mod>.Path(...)` with
#     `import pathlib [as mod]`). Cold review: a bare `anything.Path(...)`
#     may be another library's class whose .open() has no encoding= —
#     flagging it fails CI on correct code. Precision over recall: a Path
#     stored in a variable first (`p = Path(x); p.open()`) is NOT tracked —
#     documented limitation; such calls may join the baseline deliberately), AND
#   - no encoding= keyword argument, AND
#   - positional args too few to carry encoding: for builtin open() encoding
#     is the 4th positional (index 3, open(file, mode, buffering, encoding)),
#     for Path.open() the 3rd positional (index 2, Path.open(mode, buffering,
#     encoding)) — both signature positions independently peer-verified, AND
#   - text mode: a string-literal mode containing 'b' is binary (not a
#     violation); a non-literal mode (variable) is conservatively treated as
#     text (violation when encoding is missing).
# `**kwargs` / `*args` calls are conservatively treated as carrying encoding.
#
# Baseline ratchet (scripts/tests/python-encoding-baseline.txt):
#   one line per known violation: `relative/path.py :: <normalized source line>`
#   matched on path + whitespace-normalized line content, NOT line numbers, so
#   unrelated edits do not shift entries. Violation not in baseline → exit 1;
#   baseline entry that no longer matches → "stale baseline entry", exit 1;
#   --regenerate rewrites the baseline from the current scan.
#
# Usage: python3 scripts/check-python-encoding.py [--regenerate] [--baseline PATH]
# Exit 0 = clean (all violations baselined, no stale entries).
# Exit 1 = new violations or stale baseline entries. Exit 2 = usage/setup error.

from __future__ import annotations

import argparse
import ast
import subprocess
import sys
from pathlib import Path

DEFAULT_BASELINE = "scripts/tests/python-encoding-baseline.txt"

# Positional index of the encoding argument (peer-verified signatures).
_BUILTIN_OPEN_ENC_POS = 3  # open(file, mode='r', buffering=-1, encoding=None, ...)
_PATH_OPEN_ENC_POS = 2  # Path.open(mode='r', buffering=-1, encoding=None, ...)
_BUILTIN_OPEN_MODE_POS = 1
_PATH_OPEN_MODE_POS = 0


def _pathlib_names(tree: ast.Module):
    """(path_aliases, module_aliases) bound to pathlib.Path / pathlib by imports.

    Only provable pathlib bindings count (cold review): a bare name like
    `anything.Path(...)` may be another library's class whose .open() has no
    encoding parameter — flagging it would fail CI on correct code. Bindings
    are processed in source order: a LATER non-pathlib binding of the same
    name (another import, assignment, def/class) shadows and removes the
    pathlib one. Known limitation (documented, precision over recall): a
    function PARAMETER named Path and a use earlier in the file than the
    shadowing line are not tracked.
    """
    path_aliases = set()
    module_aliases = set()
    binding_nodes = sorted(
        (
            n
            for n in ast.walk(tree)
            if isinstance(
                n, (ast.Import, ast.ImportFrom, ast.Assign, ast.AnnAssign, ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)
            )
        ),
        key=lambda n: (n.lineno, n.col_offset),
    )
    for node in binding_nodes:
        if isinstance(node, ast.Import):
            for alias in node.names:
                bound = alias.asname or alias.name.split(".")[0]
                if alias.name == "pathlib":
                    module_aliases.add(alias.asname or "pathlib")
                else:
                    module_aliases.discard(bound)
                    path_aliases.discard(bound)
        elif isinstance(node, ast.ImportFrom):
            for alias in node.names:
                bound = alias.asname or alias.name
                if node.module == "pathlib" and node.level == 0 and alias.name == "Path":
                    path_aliases.add(bound)
                else:
                    path_aliases.discard(bound)
                    module_aliases.discard(bound)
        elif isinstance(node, (ast.Assign, ast.AnnAssign)):
            targets = node.targets if isinstance(node, ast.Assign) else [node.target]
            for target in targets:
                # ast.walk covers tuple/list unpacking and starred targets:
                # `Path, unused = OtherPath, 0` rebinds Path (cold review r3).
                for name_node in ast.walk(target):
                    if isinstance(name_node, ast.Name):
                        path_aliases.discard(name_node.id)
                        module_aliases.discard(name_node.id)
        else:  # FunctionDef / AsyncFunctionDef / ClassDef name rebinds
            path_aliases.discard(node.name)
            module_aliases.discard(node.name)
    return path_aliases, module_aliases


def _is_path_constructor(node: ast.expr, path_aliases, module_aliases) -> bool:
    """Receiver is visibly a pathlib Path(...) constructor call."""
    if not isinstance(node, ast.Call):
        return False
    func = node.func
    if isinstance(func, ast.Name):
        return func.id in path_aliases
    if isinstance(func, ast.Attribute):
        return (
            func.attr == "Path"
            and isinstance(func.value, ast.Name)
            and func.value.id in module_aliases
        )
    return False


def _open_signature(call: ast.Call, path_aliases, module_aliases):
    """(encoding_pos, mode_pos) for an open-like call, or None."""
    func = call.func
    if isinstance(func, ast.Name) and func.id == "open":
        return _BUILTIN_OPEN_ENC_POS, _BUILTIN_OPEN_MODE_POS
    if (
        isinstance(func, ast.Attribute)
        and func.attr == "open"
        and _is_path_constructor(func.value, path_aliases, module_aliases)
    ):
        return _PATH_OPEN_ENC_POS, _PATH_OPEN_MODE_POS
    return None


def _is_violation(call: ast.Call, path_aliases, module_aliases) -> bool:
    sig = _open_signature(call, path_aliases, module_aliases)
    if sig is None:
        return False
    enc_pos, mode_pos = sig
    for keyword in call.keywords:
        if keyword.arg == "encoding":
            return False
        if keyword.arg is None:  # **kwargs may carry encoding
            return False
    if any(isinstance(arg, ast.Starred) for arg in call.args):
        return False  # *args may carry encoding
    if len(call.args) > enc_pos:
        return False  # encoding passed positionally
    mode = None
    for keyword in call.keywords:
        if keyword.arg == "mode":
            mode = keyword.value
    if mode is None and len(call.args) > mode_pos:
        mode = call.args[mode_pos]
    if isinstance(mode, ast.Constant) and isinstance(mode.value, str):
        if "b" in mode.value:
            return False  # binary mode never decodes
    return True


def _normalize_line(line: str) -> str:
    return " ".join(line.split())


def _scan_file(repo_root: Path, rel_path: str):
    """[(rel_path, normalized_line)] — one per violating call."""
    source_path = repo_root / rel_path
    try:
        source = source_path.read_text(encoding="utf-8")
        tree = ast.parse(source, filename=rel_path)
    except (OSError, SyntaxError, ValueError) as exc:
        print(f"WARN: cannot parse {rel_path}: {exc}", file=sys.stderr)
        return []
    lines = source.splitlines()
    path_aliases, module_aliases = _pathlib_names(tree)
    violations = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Call) and _is_violation(node, path_aliases, module_aliases):
            line = lines[node.lineno - 1] if node.lineno - 1 < len(lines) else ""
            violations.append((rel_path, _normalize_line(line)))
    return violations


def _tracked_python_files(repo_root: Path):
    result = subprocess.run(
        ["git", "ls-files", "*.py"],
        cwd=repo_root,
        capture_output=True,
        text=True,
        encoding="utf-8",
    )
    if result.returncode != 0:
        print(f"ERROR: git ls-files failed: {result.stderr.strip()}", file=sys.stderr)
        sys.exit(2)
    return [line for line in result.stdout.splitlines() if line]


def _load_baseline(baseline_path: Path):
    entries = {}
    if not baseline_path.exists():
        return entries
    for raw in baseline_path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if " :: " not in line:
            print(f"WARN: malformed baseline entry skipped: {line}", file=sys.stderr)
            continue
        path, _, text = line.partition(" :: ")
        key = (path.strip(), _normalize_line(text))
        entries[key] = entries.get(key, 0) + 1
    return entries


def _counted(violations):
    counts = {}
    for item in violations:
        counts[item] = counts.get(item, 0) + 1
    return counts


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Gate: no new open()/Path.open() calls without encoding= (issue #1114)."
    )
    parser.add_argument(
        "--regenerate",
        action="store_true",
        help="rewrite the baseline from the current scan (ratchet reset)",
    )
    parser.add_argument(
        "--baseline",
        default=DEFAULT_BASELINE,
        help=f"baseline file path (default: {DEFAULT_BASELINE})",
    )
    args = parser.parse_args()

    repo_root_result = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, encoding="utf-8"
    )
    if repo_root_result.returncode != 0:
        print("ERROR: not inside a git repository (git is required)", file=sys.stderr)
        return 2
    repo_root = Path(repo_root_result.stdout.strip())
    baseline_path = Path(args.baseline)
    if not baseline_path.is_absolute():
        baseline_path = repo_root / baseline_path

    violations = []
    for rel_path in _tracked_python_files(repo_root):
        violations.extend(_scan_file(repo_root, rel_path))

    if args.regenerate:
        lines = [
            "# Known open()/Path.open() calls without encoding= (issue #1114 ratchet).",
            "# Format: relative/path.py :: <normalized source line>. A fix removes",
            "# its entry by re-scanning; regenerate with --regenerate after fixing.",
        ]
        for path, text in sorted(violations):
            lines.append(f"{path} :: {text}")
        baseline_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        print(f"regenerated {baseline_path}: {len(violations)} entries")
        return 0

    baseline = _load_baseline(baseline_path)
    found = _counted(violations)

    fail = False
    for key in sorted(found):
        missing = found[key] - baseline.get(key, 0)
        for _ in range(max(missing, 0)):
            print(f"NEW VIOLATION: {key[0]} :: {key[1]}")
            fail = True
    for key in sorted(baseline):
        stale = baseline[key] - found.get(key, 0)
        for _ in range(max(stale, 0)):
            print(f"stale baseline entry: {key[0]} :: {key[1]}")
            fail = True

    if fail:
        print(
            "FAIL: python-encoding gate — add encoding= to new calls; "
            "if you fixed a call, run with --regenerate to shrink the baseline"
        )
        return 1
    print(
        f"PASS: python-encoding gate — {sum(found.values())} known violations baselined, "
        "no new ones, no stale entries"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
