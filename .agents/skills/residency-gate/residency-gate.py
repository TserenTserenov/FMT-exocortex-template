#!/usr/bin/env python3
"""ResidencyGate main entry point - API for hooks and functions."""

import sys
import json
from pathlib import Path
from typing import List, Optional

sys.path.insert(0, str(Path(__file__).parent.parent))

from lib.parser import ManifestParser, ManifestError, DataNeed
from lib.state import ResidencyState
from lib.consent import ResidencyGate, PreGrantError, load_pre_grant_entries


def main():
    """CLI interface for ResidencyGate operations."""
    if len(sys.argv) < 2:
        print("Usage: residency-gate.py <command> [args]", file=sys.stderr)
        sys.exit(1)

    command = sys.argv[1]
    gate = ResidencyGate()

    if command == "check-activation":
        # check-activation <function_id> <manifest_file>
        if len(sys.argv) < 4:
            print("Usage: residency-gate.py check-activation <function_id> <manifest_file>", file=sys.stderr)
            sys.exit(1)

        function_id = sys.argv[2]
        manifest_file = sys.argv[3]

        try:
            manifest_content = Path(manifest_file).read_text()
            needs = ManifestParser.parse_markdown(manifest_content, function_id)

            if not needs:
                print(json.dumps({"allowed": True, "reasons": []}))
                sys.exit(0)

            allowed, blocking = gate.check_activation(function_id, needs)
            print(json.dumps({"allowed": allowed, "blocking": blocking}))
            sys.exit(0 if allowed else 1)

        except (ManifestError, PreGrantError) as e:
            # Fail closed: a malformed declaration or pre-grant list blocks activation.
            print(json.dumps({"allowed": False, "blocking": [str(e)]}))
            sys.exit(1)
        except (OSError, IOError) as e:
            print(json.dumps({"error": str(e)}))
            sys.exit(1)

    elif command == "check-lazy":
        # check-lazy <function_id> <data_type> <flow_direction> <name>
        if len(sys.argv) < 6:
            print("Usage: residency-gate.py check-lazy <function_id> <type> <flow> <name>", file=sys.stderr)
            sys.exit(1)

        function_id = sys.argv[2]
        data_type = sys.argv[3]
        flow_direction = sys.argv[4]
        need_name = sys.argv[5]

        need = DataNeed(
            name=need_name,
            type=data_type,
            flow_direction=flow_direction,
            schema_version=1
        )

        allowed, reason = gate.check_lazy(function_id, need)
        print(json.dumps({"allowed": allowed, "reason": reason}))
        sys.exit(0 if allowed else 1)

    elif command == "grant":
        # grant <function_id> <data_type> <flow_direction> <name>
        if len(sys.argv) < 6:
            print("Usage: residency-gate.py grant <function_id> <type> <flow> <name>", file=sys.stderr)
            sys.exit(1)

        function_id = sys.argv[2]
        data_type = sys.argv[3]
        flow_direction = sys.argv[4]
        need_name = sys.argv[5]

        need_key = f"{data_type}_{flow_direction}_{need_name}"
        gate.state.grant_consent(function_id, need_key)
        print(json.dumps({"status": "granted", "function_id": function_id, "need": need_key}))
        sys.exit(0)

    elif command == "deny":
        # deny <function_id> <data_type> <flow_direction> <name> [reason]
        if len(sys.argv) < 6:
            print("Usage: residency-gate.py deny <function_id> <type> <flow> <name> [reason]", file=sys.stderr)
            sys.exit(1)

        function_id = sys.argv[2]
        data_type = sys.argv[3]
        flow_direction = sys.argv[4]
        need_name = sys.argv[5]
        reason = sys.argv[6] if len(sys.argv) > 6 else "user denied"

        need_key = f"{data_type}_{flow_direction}_{need_name}"
        gate.state.deny_consent(function_id, need_key, reason)
        print(json.dumps({"status": "denied", "function_id": function_id, "need": need_key}))
        sys.exit(0)

    elif command == "list":
        # list [function_id]
        all_consents = gate.state.list_all_consents()
        if len(sys.argv) > 2:
            function_id = sys.argv[2]
            print(json.dumps(all_consents.get(function_id, {}), indent=2))
        else:
            print(json.dumps(all_consents, indent=2))
        sys.exit(0)

    elif command == "validate-pre-grant":
        # validate-pre-grant [file] — deterministic check for the Week Close audit scan
        pre_grant_file = Path(sys.argv[2]) if len(sys.argv) > 2 else None
        try:
            entries = load_pre_grant_entries(pre_grant_file)
            print(json.dumps({"valid": True, "entries": sorted(entries)}))
            sys.exit(0)
        except PreGrantError as e:
            print(json.dumps({"valid": False, "error": str(e)}))
            sys.exit(1)

    elif command == "reset":
        # reset <function_id>
        if len(sys.argv) < 3:
            print("Usage: residency-gate.py reset <function_id>", file=sys.stderr)
            sys.exit(1)

        function_id = sys.argv[2]
        gate.state.reset_function_consents(function_id)
        print(json.dumps({"status": "reset", "function_id": function_id}))
        sys.exit(0)

    else:
        print(f"Unknown command: {command}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
