#!/usr/bin/env python3
"""ResidencyGate CLI with a typed fail-closed result contract."""

import json
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional

import yaml

sys.path.insert(0, str(Path(__file__).parent.parent))

from lib.parser import ManifestParser, ManifestError, DataNeed
from lib.state import ResidencyState
from lib.consent import ResidencyGate, PreGrantError, load_pre_grant_entries


OUTCOME_ALLOWED = "allowed"
OUTCOME_POLICY_DENIED = "policy_denied"
OUTCOME_MANIFEST_INVALID = "manifest_invalid"
OUTCOME_RUNTIME_ERROR = "runtime_error"

EXIT_ALLOWED = 0
EXIT_POLICY_DENIED = 1
EXIT_MANIFEST_INVALID = 2
EXIT_RUNTIME_ERROR = 3


class CliUsageError(ValueError):
    """The caller did not satisfy the CLI command contract."""


def _emit(outcome: str, allowed: bool, **payload: Any) -> None:
    """Write one compact JSON object so shell adapters can classify it safely."""
    result: Dict[str, Any] = {"outcome": outcome, "allowed": allowed}
    result.update(payload)
    print(json.dumps(result, ensure_ascii=False, separators=(",", ":")))


def _require_args(argv: List[str], count: int, usage: str) -> None:
    if len(argv) < count:
        raise CliUsageError(f"Usage: {usage}")


def _check_activation(argv: List[str]) -> int:
    _require_args(
        argv,
        4,
        "residency-gate.py check-activation <function_id> <manifest_file>",
    )
    function_id, manifest_file = argv[2], argv[3]
    manifest_path = Path(manifest_file)
    manifest_content = manifest_path.read_text(encoding="utf-8")
    if manifest_path.suffix.lower() in {".sh", ".bash"}:
        needs = ManifestParser.parse_bash_manifest(manifest_content, function_id)
    else:
        needs = ManifestParser.parse_markdown(manifest_content, function_id)

    if not needs:
        _emit(OUTCOME_ALLOWED, True, reasons=[])
        return EXIT_ALLOWED

    allowed, blocking = ResidencyGate().check_activation(function_id, needs)
    if allowed:
        _emit(OUTCOME_ALLOWED, True, blocking=[])
        return EXIT_ALLOWED

    _emit(OUTCOME_POLICY_DENIED, False, blocking=blocking)
    return EXIT_POLICY_DENIED


def _check_lazy(argv: List[str]) -> int:
    _require_args(
        argv,
        6,
        "residency-gate.py check-lazy <function_id> <type> <flow> <name>",
    )
    function_id, data_type, flow_direction, need_name = argv[2:6]
    need = DataNeed(
        name=need_name,
        type=data_type,
        flow_direction=flow_direction,
        schema_version=1,
    )
    allowed, reason = ResidencyGate().check_lazy(function_id, need)
    if allowed:
        _emit(OUTCOME_ALLOWED, True, reason=reason)
        return EXIT_ALLOWED

    _emit(OUTCOME_POLICY_DENIED, False, reason=reason)
    return EXIT_POLICY_DENIED


def _grant_or_deny(argv: List[str], command: str) -> int:
    usage = f"residency-gate.py {command} <function_id> <type> <flow> <name>"
    if command == "deny":
        usage += " [reason]"
    _require_args(argv, 6, usage)

    function_id, data_type, flow_direction, need_name = argv[2:6]
    need_key = f"{data_type}_{flow_direction}_{need_name}"
    gate = ResidencyGate()
    if command == "grant":
        gate.state.grant_consent(function_id, need_key)
    else:
        reason = argv[6] if len(argv) > 6 else "user denied"
        gate.state.deny_consent(function_id, need_key, reason)

    print(
        json.dumps(
            {
                "status": "granted" if command == "grant" else "denied",
                "function_id": function_id,
                "need": need_key,
            },
            ensure_ascii=False,
        )
    )
    return EXIT_ALLOWED


def _list_consents(argv: List[str]) -> int:
    all_consents = ResidencyGate().state.list_all_consents()
    records = all_consents.get(argv[2], {}) if len(argv) > 2 else all_consents
    print(json.dumps(records, indent=2, ensure_ascii=False))
    return EXIT_ALLOWED


def _validate_pre_grant(argv: List[str]) -> int:
    pre_grant_file = Path(argv[2]) if len(argv) > 2 else None
    entries = load_pre_grant_entries(pre_grant_file)
    print(json.dumps({"valid": True, "entries": sorted(entries)}))
    return EXIT_ALLOWED


def _reset(argv: List[str]) -> int:
    _require_args(argv, 3, "residency-gate.py reset <function_id>")
    function_id = argv[2]
    ResidencyGate().state.reset_function_consents(function_id)
    print(json.dumps({"status": "reset", "function_id": function_id}))
    return EXIT_ALLOWED


def _dispatch(argv: List[str]) -> int:
    _require_args(argv, 2, "residency-gate.py <command> [args]")
    command = argv[1]
    handlers = {
        "check-activation": _check_activation,
        "check-lazy": _check_lazy,
        "grant": lambda args: _grant_or_deny(args, "grant"),
        "deny": lambda args: _grant_or_deny(args, "deny"),
        "list": _list_consents,
        "validate-pre-grant": _validate_pre_grant,
        "reset": _reset,
    }
    handler = handlers.get(command)
    if handler is None:
        raise CliUsageError(f"Unknown command: {command}")
    return handler(argv)


def main(argv: Optional[List[str]] = None) -> int:
    """Run the CLI and classify every fail-closed outcome for shell callers."""
    argv = argv or sys.argv
    try:
        return _dispatch(argv)
    except (ManifestError, PreGrantError, yaml.YAMLError) as error:
        _emit(
            OUTCOME_MANIFEST_INVALID,
            False,
            error=str(error),
            blocking=[str(error)],
        )
        return EXIT_MANIFEST_INVALID
    except (CliUsageError, OSError, UnicodeError) as error:
        _emit(OUTCOME_RUNTIME_ERROR, False, error=str(error))
        return EXIT_RUNTIME_ERROR
    except Exception as error:  # CLI boundary: never leak an untyped traceback.
        _emit(
            OUTCOME_RUNTIME_ERROR,
            False,
            error=f"{type(error).__name__}: {error}",
        )
        return EXIT_RUNTIME_ERROR


if __name__ == "__main__":
    sys.exit(main())
