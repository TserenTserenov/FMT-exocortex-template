#!/usr/bin/env python3
"""
hindsight_trigger.py — entry point for Hindsight L2 memory integration.

Reads JSON from stdin. Two input formats:
  1. PostToolUse hook: {"tool_input": {"skill": "run-protocol", ...}}
     → routes to recall if skill in RECALL_SKILLS whitelist.
  2. Direct call: {"action": "retain|recall|reflect", ...payload}
     → executes specified action.

Actions:
  retain  — async detached subprocess (never blocks caller)
  recall  — sync HTTP call to Hindsight, prints JSON to stdout
  reflect — async detached subprocess

Exit code: always 0 (graceful degradation).
Log: ~/.iwe/hindsight.log (adapter writes; trigger is silent on success).
"""

import json
import os
import subprocess
import sys
import time
from pathlib import Path

# Whitelist of skills that trigger Hindsight recall
RECALL_SKILLS = {
    "run-protocol",
    "week-close",
    "peer-conversation",
    "apply-captures",
    "strategy-session",
}

HINDSIGHT_URL = os.environ.get("HINDSIGHT_URL", "http://localhost:8888")
DISABLED = os.environ.get("IWE_HINDSIGHT_DISABLED", "").lower() in ("1", "true", "yes")

# Adapter path: same directory as this script
ADAPTER_PATH = Path(__file__).with_name("hindsight_adapter.py")


def log(msg: str) -> None:
    ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    line = f"{ts} TRIGGER {msg}\n"
    log_path = Path.home() / ".iwe" / "hindsight.log"
    try:
        log_path.parent.mkdir(parents=True, exist_ok=True)
        with open(log_path, "a", encoding="utf-8") as f:
            f.write(line)
    except Exception:
        pass


def write_tmp_json(data: dict) -> Path:
    pid = os.getpid()
    ns = time.monotonic_ns()
    tmp_path = Path("/tmp") / f"{pid}-{ns}.json"
    tmp_path.write_text(json.dumps(data), encoding="utf-8")
    return tmp_path


def run_retain(payload: dict) -> None:
    """Fire-and-forget retain via detached adapter process."""
    tmp_path = write_tmp_json(payload)
    cmd = [
        sys.executable,
        str(ADAPTER_PATH),
        "retain",
        str(tmp_path),
    ]
    try:
        subprocess.Popen(
            cmd,
            start_new_session=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        log(f"RETAIN_LAUNCHED pid={os.getpid()} tmp={tmp_path.name}")
    except Exception as e:
        tmp_path.unlink(missing_ok=True)
        log(f"RETAIN_FAIL launch_error={e}")


def run_recall(payload: dict) -> None:
    """Synchronous recall. Prints Hindsight response JSON to stdout."""
    import urllib.request

    query = payload.get("query", "")
    if not query:
        # Build query from context if available
        query = payload.get("context", "")
    if not query:
        log("RECALL_SKIP empty_query")
        print(json.dumps({"results": [], "source": "hindsight", "status": "empty_query"}))
        return

    req_body = json.dumps({"query": query, "n": 3}).encode("utf-8")
    req = urllib.request.Request(
        f"{HINDSIGHT_URL}/recall",
        data=req_body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            result = resp.read().decode("utf-8")
            print(result)
            log(f"RECALL_OK bytes={len(result)}")
    except Exception as e:
        log(f"RECALL_FAIL {e}")
        # Graceful: print empty result so caller doesn't crash
        print(json.dumps({"results": [], "source": "hindsight", "status": "unavailable"}))


def run_reflect(payload: dict) -> None:
    """Fire-and-forget reflect via detached adapter process."""
    tmp_path = write_tmp_json(payload)
    cmd = [
        sys.executable,
        str(ADAPTER_PATH),
        "reflect",
        str(tmp_path),
    ]
    try:
        subprocess.Popen(
            cmd,
            start_new_session=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        log(f"REFLECT_LAUNCHED pid={os.getpid()} tmp={tmp_path.name}")
    except Exception as e:
        tmp_path.unlink(missing_ok=True)
        log(f"REFLECT_FAIL launch_error={e}")


def main() -> None:
    if DISABLED:
        sys.exit(0)

    try:
        data = json.load(sys.stdin)
    except json.JSONDecodeError as e:
        log(f"PARSE_FAIL {e}")
        sys.exit(0)

    # Determine action
    action = data.get("action", "").lower()

    # PostToolUse hook path: infer action from tool_input.skill
    if not action and "tool_input" in data:
        skill_name = data.get("tool_input", {}).get("skill", "")
        if skill_name in RECALL_SKILLS:
            action = "recall"
            # Build query from skill context
            data["query"] = f"skill:{skill_name}"
        else:
            # Not in whitelist — silent skip
            sys.exit(0)

    if action == "retain":
        run_retain(data)
    elif action == "recall":
        run_recall(data)
    elif action == "reflect":
        run_reflect(data)
    elif action == "memory_audit":
        run_memory_audit(data)
    else:
        log(f"UNKNOWN_ACTION action={action}")

    sys.exit(0)


# -- Memory Lifecycle Audit (WP-337 L2 integration) --------------------------

def run_memory_audit(payload: dict) -> None:
    """Run memory lifecycle audit via Hindsight L2."""
    import subprocess
    
    audit_script = Path(__file__).parent.parent / "exocortex" / "hindsight" / "memory_lifecycle.py"
    if not audit_script.exists():
        log("MEMORY_AUDIT_SKIP script_not_found")
        print(json.dumps({"status": "skip", "reason": "memory_lifecycle.py not found"}))
        return
    
    try:
        result = subprocess.run(
            [sys.executable, str(audit_script), "audit"],
            capture_output=True,
            text=True,
            timeout=300,
        )
        output = result.stdout.strip()
        print(output)
        log(f"MEMORY_AUDIT_OK rc={result.returncode}")
    except subprocess.TimeoutExpired:
        log("MEMORY_AUDIT_TIMEOUT")
        print(json.dumps({"status": "timeout"}))
    except Exception as e:
        log(f"MEMORY_AUDIT_FAIL {e}")
        print(json.dumps({"status": "error", "error": str(e)}))


if __name__ == "__main__":
    main()
