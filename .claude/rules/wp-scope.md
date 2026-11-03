# WP Scope Rules

Any wp-context (not only umbrella): read by default ONLY phases marked `pending`/`in_progress`/`blocked`; do NOT read done/closed/defer phases unless the user explicitly asks or the current task needs one of them (long done-tails waste tokens).

Umbrella wp-context with `agent_scope: open-only` (WP-5, WP-7): the same restriction, but mandatory, not a default — such a card holds every phase of its coordinated sub-РП inline rather than moving them to an archive, so there is no implicit-need exception for it.

<!-- USER-SPACE -->
<!-- /USER-SPACE -->
