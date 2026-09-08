#!/bin/bash
# shellcheck shell=bash
# network-wait.sh — active DNS wait for launchd jobs fired by WakeSystem timers.
#
# Root cause (WP-7, live failures 18-22.07.2026): launchd runs the job in the first
# seconds after the Mac wakes, before DNS/upstream connectivity is restored, so the
# very first network call dies with "could not resolve host" / "could not translate
# host name". A blind sleep is fragile (remind-deps-check.sh used sleep 20); this
# probes the actual dependency host until it resolves.
#
# Usage: . "$SCRIPT_DIR/lib/network-wait.sh" && network_wait api.telegram.org 45
# Returns 0 once the host resolves, 1 on timeout. Callers should `|| true` and
# proceed anyway — the real call then produces the real error for the state record.

network_wait() {
    local host="$1" timeout="${2:-45}" waited=0 step=3
    while ! python3 -c 'import socket, sys
socket.setdefaulttimeout(3)
socket.getaddrinfo(sys.argv[1], 443)' "$host" 2>/dev/null; do
        if (( waited >= timeout )); then
            echo "[network-wait] $host не резолвится за ${timeout}с — продолжаю без ожидания" >&2
            return 1
        fi
        sleep "$step"
        waited=$((waited + step))
    done
    if (( waited > 0 )); then
        echo "[network-wait] сеть поднялась через ${waited}с (host=$host)" >&2
    fi
    return 0
}
