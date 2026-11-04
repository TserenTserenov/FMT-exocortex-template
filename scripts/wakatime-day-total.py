#!/usr/bin/env python3
"""Print WakaTime coding time for one calendar day, in seconds.

Usage: wakatime-day-total.py YYYY-MM-DD

Reads the summaries endpoint, not `wakatime-cli --today`: the CLI returns an
empty line with exit 0 on some installs (issue #1414) and can only answer for
the current day, so a Day Close after midnight got the wrong day (issue #1398).

Authentication (issue #1451): WakaTime may reject a plugin API key on the
summaries endpoint with HTTP 403 ("API Keys are only for plugins, use your
personal oauth token"). Therefore:
- WAKATIME_OAUTH_TOKEN set -> summaries with a Bearer token, any date.
- Otherwise summaries with the plugin key (Basic auth). On HTTP 403 for the
  current local day only, falls back to `status_bar/today` with the same key
  and accepts its answer only if its date equals the requested date (the date
  is in the WakaTime account timezone). Past days without an OAuth token
  return no value.
Issue #859 reported that the statusbar total omitted the AI Coding category;
the #1451 reporter observed on 2026-11-03 that `status_bar/today` grand_total
did include AI Coding time. Treat the fallback as best effort for that
category.

Exit 0: stdout is the total seconds (integer, > 0).
Exit 3: no value; stdout is a short reason in parentheses for the caller to
show as is. Never fabricates a number.
"""

import base64
import configparser
import json
import os
import re
import sys
import urllib.error
import urllib.request
from datetime import date

ENV_FILES = ("~/.config/aist/env", "~/.iwe/.exocortex.env", "~/.wakatime.env")
KEY_LINE = re.compile(
    r"^(?:export\s+)?WAKATIME_API_KEY\s*=\s*([\"']?)([^\"'\n]+)\1\s*$"
)


def no_value(reason):
    print(f"({reason})")
    sys.exit(3)


def key_from_env_file(path):
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                m = KEY_LINE.match(line)
                if m:
                    return m.group(2).strip()
    except (OSError, UnicodeError) as exc:
        print(f"wakatime-day-total: cannot read {path}: {exc}", file=sys.stderr)
    return None


def find_api_key():
    key = os.environ.get("WAKATIME_API_KEY", "").strip()
    if key:
        return key
    for raw in ENV_FILES:
        path = os.path.expanduser(raw)
        if os.path.isfile(path):
            key = key_from_env_file(path)
            if key:
                return key
    cfg_path = os.path.expanduser("~/.wakatime.cfg")
    if os.path.isfile(cfg_path):
        cfg = configparser.ConfigParser()
        try:
            cfg.read(cfg_path, encoding="utf-8")
            return cfg.get("settings", "api_key", fallback=None)
        except (OSError, configparser.Error) as exc:
            print(f"wakatime-day-total: cannot read {cfg_path}: {exc}", file=sys.stderr)
    return None


def day_seconds(body, target):
    days = body.get("data") if isinstance(body, dict) else None
    if not isinstance(days, list):
        return None
    entry = next(
        (
            d
            for d in days
            if isinstance(d, dict) and d.get("range", {}).get("date") == target
        ),
        None,
    )
    total = entry.get("grand_total") if isinstance(entry, dict) else None
    seconds = total.get("total_seconds") if isinstance(total, dict) else None
    if isinstance(seconds, bool) or not isinstance(seconds, (int, float)):
        return None
    return seconds


API_BASE = "https://wakatime.com/api/v1/users/current"
NEON_HINT = "use Neon fallback: domain_event coding_time"


def fetch_json(url, authorization):
    """GET url and decode JSON. Raises urllib.error.HTTPError, OSError, ValueError."""
    req = urllib.request.Request(
        url, headers={"Authorization": authorization, "Accept": "application/json"}
    )
    with urllib.request.urlopen(req, timeout=15) as resp:
        return json.loads(resp.read().decode("utf-8"))


def status_bar_seconds(body, target):
    """Seconds from a status_bar/today body, or a reason string on mismatch."""
    data = body.get("data") if isinstance(body, dict) else None
    if not isinstance(data, dict):
        return None, "WakaTime status_bar: no data"
    day_range = data.get("range")
    day = day_range.get("date") if isinstance(day_range, dict) else None
    if day != target:
        return None, (
            f"WakaTime status_bar answers for {day}, not {target} "
            "(account timezone differs?)"
        )
    total = data.get("grand_total")
    seconds = total.get("total_seconds") if isinstance(total, dict) else None
    if isinstance(seconds, bool) or not isinstance(seconds, (int, float)):
        return None, f"no WakaTime status_bar total for {target}"
    return round(seconds), None


def summaries_url(target):
    return f"{API_BASE}/summaries?start={target}&end={target}"


def basic_auth(api_key):
    return "Basic " + base64.b64encode(f"{api_key}:".encode()).decode()


def from_oauth(token, target):
    try:
        body = fetch_json(summaries_url(target), f"Bearer {token}")
    # OSError covers HTTPError, URLError and socket timeouts on every Python 3
    # version; ValueError covers JSONDecodeError and UnicodeDecodeError.
    # The token is only in the request header and never in exc's text.
    except (OSError, ValueError) as exc:
        no_value(f"WakaTime API error (OAuth token): {exc} — {NEON_HINT}")
    return day_seconds(body, target)


def from_plugin_key(api_key, target):
    try:
        body = fetch_json(summaries_url(target), basic_auth(api_key))
    except urllib.error.HTTPError as exc:
        if exc.code != 403:
            no_value(f"WakaTime API error: {exc} — {NEON_HINT}")
        if target != date.today().isoformat():
            no_value(
                "WakaTime summaries rejected the plugin API key (HTTP 403); "
                "past days need WAKATIME_OAUTH_TOKEN — " + NEON_HINT
            )
        return from_status_bar(api_key, target)
    except (OSError, ValueError) as exc:
        no_value(f"WakaTime API error: {exc} — {NEON_HINT}")
    return day_seconds(body, target)


def from_status_bar(api_key, target):
    try:
        body = fetch_json(f"{API_BASE}/status_bar/today", basic_auth(api_key))
    except (OSError, ValueError) as exc:
        no_value(f"WakaTime status_bar error: {exc} — {NEON_HINT}")
    seconds, reason = status_bar_seconds(body, target)
    if reason:
        no_value(reason)
    return seconds


def main():
    if len(sys.argv) != 2:
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        sys.exit(2)
    target = sys.argv[1]
    try:
        date.fromisoformat(target)
    except ValueError:
        print(f"wakatime-day-total: not a YYYY-MM-DD date: {target!r}", file=sys.stderr)
        sys.exit(2)

    oauth_token = os.environ.get("WAKATIME_OAUTH_TOKEN", "").strip()
    if oauth_token:
        seconds = from_oauth(oauth_token, target)
    else:
        api_key = find_api_key()
        if not api_key:
            no_value(f"WAKATIME_API_KEY not found — {NEON_HINT}")
        seconds = from_plugin_key(api_key, target)

    if seconds is None:
        no_value(f"no WakaTime entry for {target}")
    if seconds <= 0:
        no_value(f"no positive WakaTime time for {target}")
    print(int(seconds))


if __name__ == "__main__":
    main()
