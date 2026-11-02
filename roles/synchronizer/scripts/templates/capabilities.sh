#!/bin/bash
# Notification template: installation capabilities (WP-7 F267, stage 2)
# Called from notify.sh via source. The text is assembled by iwe-capabilities.sh regress
# and passed in IWE_CAP_ALERT_TEXT; here only capability names, without addresses and secrets.

build_message() {
    case "$1" in
        regress) printf '%s' "${IWE_CAP_ALERT_TEXT:-}" ;;
        *) echo "" ;;
    esac
}

build_buttons() {
    echo "[]"
}
