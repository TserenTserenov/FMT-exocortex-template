#!/usr/bin/env python3
"""Merge a template launchd plist with the installed copy's schedule (issue #981).

update.sh used to overwrite the installed plist wholesale on every run, silently
reverting a user's schedule edit (Weekday/RunAtLoad) back to the template default.
This keeps StartCalendarInterval/RunAtLoad from the INSTALLED copy when present
there, and drops them from the result when the user removed them on purpose
(e.g. to disable auto-run) -- everything else (paths, env, labels) still comes
from the template, so unrelated upstream fixes keep landing.

Usage: merge-launchd-schedule.py <template.plist> <installed.plist> <output.plist>
"""
import plistlib
import sys

SCHEDULE_KEYS = ("StartCalendarInterval", "RunAtLoad")


def main(argv):
    template_path, installed_path, output_path = argv[1:4]
    with open(template_path, "rb") as f:
        merged = plistlib.load(f)
    with open(installed_path, "rb") as f:
        installed = plistlib.load(f)
    for key in SCHEDULE_KEYS:
        if key in installed:
            merged[key] = installed[key]
        else:
            merged.pop(key, None)
    with open(output_path, "wb") as f:
        plistlib.dump(merged, f)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
