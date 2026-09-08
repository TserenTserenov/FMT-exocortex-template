#!/bin/bash
# ledger-publish-kick.sh — async trigger for ledger-publish.service after a
# successful ledger-append.sh write (WP-503, PILOT DECISION 09.08 in
# ledger-publish.sh, unblocked 18.08 once ledger-publish.sh's own self-heal —
# quarantine_untracked() — existed to prevent a jammed automation checkout).
#
# Single call site by design: ledger-append.sh is the ONLY writer all 5
# pipeline scripts (wp-sync-bundle-batch.sh, wp-secretary-queue.sh,
# wp-pool-cascade.sh, wp-pool-tiebreak.sh, ledger-append.sh itself) funnel
# through — wiring the kick into ledger-append.sh alone covers every caller
# without double-kicking (peer review, 2026-08-18: the other 4 scripts call
# ledger-append.sh for their actual write, so kicking from both would fire
# twice per event).
#
# Usage: kick_ledger_publish (call ONLY after a confirmed successful append —
# this function itself doesn't verify the write, the caller already did)

# kick_ledger_publish — logs LEDGER_COMMIT_OK (the append succeeded, which is
# why this function is being called at all), then fire-and-forgets
# `systemctl --user start --no-block ledger-publish.service`. Always returns
# 0 — a failed/unavailable kick is diagnostic, not a pipeline error (the
# ledger write already succeeded; the periodic watchdog timer remains the
# backstop, per PILOT DECISION 09.08's "один редкий писатель" model).
kick_ledger_publish() {
  echo "LEDGER_COMMIT_OK"

  if ! command -v systemctl >/dev/null 2>&1; then
    # Not a systemd host (e.g. macOS during an interactive peer-session) —
    # expected, not an error. The watchdog timer on the pipeline's systemd
    # host is the actual activation surface; this kick is only ever a
    # same-host optimization.
    echo "PUBLISH_TRIGGER_FAIL reason=systemctl_unavailable"
    return 0
  fi

  # --user scope confirmed against DS-autonomous-agents/systemd/install-systemd.sh
  # (systemctl --user enable/start for every unit in this pipeline, including
  # ledger-publish.timer itself) — not assumed (peer review, 2026-08-18: an
  # unconfirmed --user vs system-wide mismatch would silently no-op and log a
  # false PUBLISH_TRIGGER_FAIL).
  if systemctl --user start --no-block ledger-publish.service 2>&1; then
    echo "PUBLISH_TRIGGERED"
  else
    echo "PUBLISH_TRIGGER_FAIL reason=systemctl_start_failed"
  fi
  return 0
}
