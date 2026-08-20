#!/usr/bin/env bash
# extract-update-fetch-worker.sh — pulls the real Phase A worker body out of
# update.sh's heredoc (WP-546 F2, peer-session
# 2026-08-20-06-wp546-wp529-update-parallel) via unique line-content markers.
#
# Same technique setup/test-update-edge-cases.sh T10 uses for update.sh's
# Step 5/6 fallback blocks: a hand-retyped copy of the worker would silently
# diverge from the real code the moment someone edits update.sh without
# touching the test — T10's own review history proved that experimentally
# (a hand-copied block kept passing after the real fix was reverted).
#
# Usage: extract_update_fetch_worker <path-to-update.sh> > worker.sh
extract_update_fetch_worker() {
    awk '
        /^cat > "\$IWE_UPDATE_WORKER" <<.FETCH_WORKER_EOF.$/ { found=1; next }
        found && /^FETCH_WORKER_EOF$/ { exit }
        found { print }
    ' "$1"
}
