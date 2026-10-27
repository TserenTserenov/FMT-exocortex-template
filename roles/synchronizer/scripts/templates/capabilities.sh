#!/bin/bash
# Шаблон уведомлений: возможности установки (WP-7 F267, этап 2)
# Вызывается из notify.sh через source. Текст собирает iwe-capabilities.sh regress
# и передаёт в IWE_CAP_ALERT_TEXT; здесь только имена возможностей, без адресов и секретов.

build_message() {
    case "$1" in
        regress) printf '%s' "${IWE_CAP_ALERT_TEXT:-}" ;;
        *) echo "" ;;
    esac
}

build_buttons() {
    echo "[]"
}
