#!/usr/bin/env bash
# wp529-f21-toggle-required-review.sh — включить/выключить обязательное
# одобрение перед слиянием в main (WP-529 Ф21, предложение Артёма о
# привлечении сторонних проверяющих релиза).
#
# Подготовлено, но осознанно НЕ запущено как часть этой доставки — пилот
# решил включать только после сбора аккаунтов готовых проверять людей
# (карточка РП-529, 17.10 и 22.10). По умолчанию --dry-run: печатает
# планируемый запрос, ничего не меняет на GitHub. Сохраняет
# required_status_checks как есть — не трогает уже работающие проверки
# (release-receipt, changelog-entry).
#
# Usage:
#   bash setup/wp529-f21-toggle-required-review.sh on --dry-run|--apply
#   bash setup/wp529-f21-toggle-required-review.sh off --dry-run|--apply
#
# Полное аварийное снятие защиты ветки (не только review) и её точное
# восстановление — не этим скриптом, см. docs/BRANCH-PROTECTION-EMERGENCY.md.

set -euo pipefail
REPO="TserenTserenov/FMT-exocortex-template"
ACTION="${1:?usage: $0 on|off --dry-run|--apply}"
MODE="${2:?usage: $0 on|off --dry-run|--apply}"

case "$ACTION" in
    on)  REVIEW_COUNT=1; CODEOWNER_REVIEW=true ;;
    off) REVIEW_COUNT=0; CODEOWNER_REVIEW=false ;;
    *) echo "ОШИБКА: действие должно быть 'on' или 'off', получено '$ACTION'" >&2; exit 1 ;;
esac

CURRENT_JSON=$(gh api "repos/$REPO/branches/main/protection")
PAYLOAD=$(CURRENT_JSON="$CURRENT_JSON" python3 - "$REVIEW_COUNT" "$CODEOWNER_REVIEW" <<'PYEOF'
import json, os, sys
current = json.loads(os.environ["CURRENT_JSON"])
review_count = int(sys.argv[1])
codeowner = sys.argv[2] == "true"
payload = {
    "required_status_checks": {
        "strict": current["required_status_checks"]["strict"],
        "contexts": current["required_status_checks"]["contexts"],
    },
    "enforce_admins": current["enforce_admins"]["enabled"],
    "required_pull_request_reviews": {
        "dismiss_stale_reviews": True,
        "require_code_owner_reviews": codeowner,
        "require_last_push_approval": False,
        "required_approving_review_count": review_count,
    },
    "restrictions": None,
    "required_linear_history": current["required_linear_history"]["enabled"],
    "allow_force_pushes": current["allow_force_pushes"]["enabled"],
    "allow_deletions": current["allow_deletions"]["enabled"],
    "block_creations": current["block_creations"]["enabled"],
    "required_conversation_resolution": current["required_conversation_resolution"]["enabled"],
    "lock_branch": current["lock_branch"]["enabled"],
    "allow_fork_syncing": current["allow_fork_syncing"]["enabled"],
}
print(json.dumps(payload))
PYEOF
)

echo "Действие: $ACTION (required_approving_review_count=$REVIEW_COUNT, require_code_owner_reviews=$CODEOWNER_REVIEW)"
echo "Планируемый запрос (остальные настройки защиты сохраняются как сейчас):"
printf '%s\n' "$PAYLOAD" | python3 -m json.tool

case "$MODE" in
    --apply)
        printf '%s' "$PAYLOAD" | gh api -X PUT "repos/$REPO/branches/main/protection" --input -
        echo "Применено."
        ;;
    --dry-run)
        echo "(--dry-run: ничего не изменено; для применения — повторить с --apply)"
        ;;
    *)
        echo "ОШИБКА: режим должен быть '--dry-run' или '--apply'" >&2
        exit 1
        ;;
esac
