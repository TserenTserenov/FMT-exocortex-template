# WP Scope Rules — Umbrella РП

Wp-context with `umbrella: true` + `agent_scope: open-only` (WP-5, WP-7): read ONLY phases marked `pending`/`in_progress`/`blocked`; do NOT read done/closed/defer phases unless the user explicitly asks (long done-tails waste tokens).

<!-- USER-SPACE -->
<!-- /USER-SPACE -->
