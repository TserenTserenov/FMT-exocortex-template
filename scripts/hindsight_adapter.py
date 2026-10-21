#!/usr/bin/env python3
"""
hindsight_adapter.py — detached Hindsight HTTP client.

Called by hindsight_trigger.py via subprocess.Popen(start_new_session=True).
Reads a temp JSON file, POSTs to Hindsight, logs outcome, cleans up file.

Usage:
  python3 hindsight_adapter.py <action> <tmp_json_file>

Actions: retain | recall | reflect
"""

import json
import os
import sys
import time
import urllib.request
from pathlib import Path

HINDSIGHT_URL = os.environ.get("HINDSIGHT_URL", "http://localhost:8888")


def log(status: str, reason: str = "", payload_bytes: int = 0, latency_ms: int = 0) -> None:
    ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    reason_token = reason.replace(" ", "_") if reason else "-"
    line = f"{ts} {status} {reason_token} {payload_bytes}bytes {latency_ms}ms\n"
    log_path = Path.home() / ".iwe" / "hindsight.log"
    try:
        log_path.parent.mkdir(parents=True, exist_ok=True)
        with open(log_path, "a", encoding="utf-8") as f:
            f.write(line)
    except Exception:
        pass


def post(action: str, payload: dict) -> None:
    endpoint = f"{HINDSIGHT_URL}/{action}"
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        endpoint,
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            _ = resp.read()
            latency = int((time.time() - t0) * 1000)
            log("OK", f"HTTP_{resp.status}", len(body), latency)
    except urllib.error.HTTPError as e:
        latency = int((time.time() - t0) * 1000)
        log("FAIL", f"HTTP_{e.code}", len(body), latency)
    except urllib.error.URLError as e:
        latency = int((time.time() - t0) * 1000)
        log("FAIL", e.reason.__class__.__name__, len(body), latency)
    except Exception as e:
        latency = int((time.time() - t0) * 1000)
        log("FAIL", e.__class__.__name__, len(body), latency)


def main() -> None:
    if len(sys.argv) < 3:
        log("FAIL", "MISSING_ARGS", 0, 0)
        sys.exit(0)

    action = sys.argv[1]
    tmp_path = Path(sys.argv[2])

    try:
        payload = json.loads(tmp_path.read_text(encoding="utf-8"))
    except Exception as e:
        log("FAIL", f"PARSE_{e.__class__.__name__}", 0, 0)
        tmp_path.unlink(missing_ok=True)
        sys.exit(0)

    try:
        post(action, payload)
    finally:
        tmp_path.unlink(missing_ok=True)

    sys.exit(0)


if __name__ == "__main__":
    main()
