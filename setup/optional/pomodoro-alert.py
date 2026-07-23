#!/usr/bin/env python3
"""Pomodoro break reminder based on WakaTime activity.

Checks WakaTime durations API for continuous coding blocks.
If active block > session_alert_minutes (from day-rhythm-config.yaml),
sends a macOS notification to take a break.

Designed to run via launchd every 5 minutes during working hours.

Prerequisites:
  - WakaTime installed and configured (~/.wakatime.cfg with api_key)
  - macOS (uses osascript for notifications)

Install:
  1. Copy this script to your workspace
  2. Install the launchd plist (see setup/optional/pomodoro-alert.plist)
  3. Adjust memory/day-rhythm-config.yaml → pomodoro section
"""

import json
import shutil
import subprocess
import time
from base64 import b64encode
from pathlib import Path
from urllib.request import Request, urlopen

# --- Paths ---
# Auto-detect workspace: script parent's parent (setup/optional/ → workspace root)
WORKSPACE_ROOT = Path(__file__).resolve().parent.parent.parent
CONFIG_PATH = WORKSPACE_ROOT / "memory" / "day-rhythm-config.yaml"
WAKATIME_CFG = Path.home() / ".wakatime.cfg"
STATE_FILE = Path(__file__).parent / ".pomodoro-state.json"

# Gap threshold: if no heartbeat for this many seconds, session resets
GAP_THRESHOLD_SEC = 5 * 60  # 5 minutes


def load_config() -> dict:
    """Read pomodoro settings from day-rhythm-config.yaml (simple parser)."""
    defaults = {"session_alert_minutes": 50, "work_minutes": 25, "break_minutes": 5}
    if not CONFIG_PATH.exists():
        return defaults

    text = CONFIG_PATH.read_text()
    result = {}
    in_pomodoro = False
    for line in text.splitlines():
        stripped = line.strip()
        if stripped == "pomodoro:":
            in_pomodoro = True
            continue
        if in_pomodoro:
            if stripped and not stripped.startswith("#") and ":" in stripped:
                if not line.startswith(" ") and not line.startswith("\t"):
                    break  # left pomodoro section
                key, _, val = stripped.partition(":")
                val = val.strip().split("#")[0].strip()
                try:
                    result[key.strip()] = int(val)
                except ValueError:
                    pass
    return {**defaults, **result}


def get_api_key() -> str:
    """Read WakaTime API key from ~/.wakatime.cfg."""
    for line in WAKATIME_CFG.read_text().splitlines():
        line = line.strip()
        if line.startswith("api_key"):
            return line.split("=", 1)[1].strip()
    raise SystemExit("WakaTime API key not found in ~/.wakatime.cfg")


def fetch_durations(api_key: str) -> list:
    """Fetch today's durations from WakaTime API."""
    today = time.strftime("%Y-%m-%d")
    url = f"https://wakatime.com/api/v1/users/current/durations?date={today}"
    token = b64encode(api_key.encode()).decode()
    req = Request(url, headers={"Authorization": f"Basic {token}"})
    with urlopen(req, timeout=10) as resp:
        return json.loads(resp.read())["data"]


def find_current_block(durations: list) -> float:
    """Find length of the current continuous activity block in minutes.

    Durations are sorted by time. Walk backwards from the most recent,
    merging blocks that have gaps < GAP_THRESHOLD_SEC.
    Returns 0 if no recent activity.
    """
    if not durations:
        return 0.0

    now = time.time()
    durations.sort(key=lambda d: d["time"])

    last = durations[-1]
    last_end = last["time"] + last["duration"]
    if now - last_end > GAP_THRESHOLD_SEC:
        return 0.0

    block_end = last_end
    block_start = last["time"]

    for i in range(len(durations) - 2, -1, -1):
        d = durations[i]
        d_end = d["time"] + d["duration"]
        gap = block_start - d_end
        if gap <= GAP_THRESHOLD_SEC:
            block_start = d["time"]
        else:
            break

    return (block_end - block_start) / 60.0


def load_state() -> dict:
    """Load state to track when we last alerted."""
    if STATE_FILE.exists():
        try:
            return json.loads(STATE_FILE.read_text())
        except (json.JSONDecodeError, OSError):
            pass
    return {"last_alert_time": 0}


def save_state(state: dict):
    STATE_FILE.write_text(json.dumps(state))


def notify(title: str, message: str):
    """Send a desktop notification: osascript (macOS) or notify-send (Linux).

    WP-5 Ubuntu-audit факт #4: subprocess.run(["osascript", ...], check=False)
    still raises FileNotFoundError when the binary itself is missing —
    check=False only suppresses a non-zero exit code, not a missing
    executable — so this crashed every 5-minute launchd/cron tick on Linux.
    """
    if shutil.which("osascript"):
        script = f'display notification "{message}" with title "{title}" sound name "Purr"'
        subprocess.run(["osascript", "-e", script], check=False)
    elif shutil.which("notify-send"):
        subprocess.run(["notify-send", title, message], check=False)


def main():
    config = load_config()
    alert_minutes = config["session_alert_minutes"]
    break_minutes = config["break_minutes"]

    api_key = get_api_key()
    durations = fetch_durations(api_key)
    block_minutes = find_current_block(durations)

    state = load_state()

    if block_minutes >= alert_minutes:
        if time.time() - state["last_alert_time"] > 10 * 60:
            notify(
                "Time for a break!",
                f"Continuous work: {int(block_minutes)} min. "
                f"Break: {break_minutes} min.",
            )
            state["last_alert_time"] = time.time()
            save_state(state)
            print(f"ALERT: {int(block_minutes)} min continuous work (threshold: {alert_minutes})")
        else:
            print(f"Suppressed: {int(block_minutes)} min (alerted recently)")
    else:
        if block_minutes == 0 and state["last_alert_time"] > 0:
            state["last_alert_time"] = 0
            save_state(state)
        print(f"OK: {int(block_minutes)} min (threshold: {alert_minutes})")


if __name__ == "__main__":
    main()
