# Снятие и восстановление защиты `main` (аварийная процедура)

> WP-529 Ф21. Пишется заранее, на спокойную голову — не во время самой аварии.
> Переключение обычного режима (`required_approving_review_count`/
> `require_code_owner_reviews`) — отдельный скрипт
> `setup/wp529-f21-toggle-required-review.sh`, см. его `--help`-комментарий в
> шапке файла. Этот документ — только для случая, когда защита сама блокирует
> нужное действие (например, экстренный откат, а `enforce_admins` не даёт его
> сделать) и обычного переключателя недостаточно.

## Почему это отдельная процедура, не часть скрипта

GitHub API не умеет точечно «временно выключить одно правило защиты и
включить обратно» — `DELETE .../protection` снимает защиту целиком: вместе с
требованием ревью уходят и обязательные проверки (`release-receipt`,
`changelog-entry`), запрет force-push, запрет удаления ветки и всё остальное.
Включить защиту обратно через `PUT` можно, но только если заранее знать,
*что именно* включать — после `DELETE` эти настройки нигде не хранятся,
читать их у GitHub уже не у кого.

## Текущий базовый профиль (зафиксирован 22.10.2026)

```json
{
  "required_status_checks": {
    "strict": false,
    "contexts": ["release-receipt", "changelog-entry"]
  },
  "enforce_admins": true,
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": false,
    "require_last_push_approval": false,
    "required_approving_review_count": 0
  },
  "restrictions": null,
  "required_linear_history": false,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "block_creations": false,
  "required_conversation_resolution": false,
  "lock_branch": false,
  "allow_fork_syncing": false
}
```

**Это живые текущие настройки, не образец.** Если профиль защиты меняется
штатно (например, `setup/wp529-f21-toggle-required-review.sh on --apply`
включит обязательное ревью) — обновить этот блок тем же коммитом, который
меняет защиту, иначе процедура ниже восстановит устаревший профиль.
Перед любым плановым изменением защиты сверить, что блок выше совпадает с
`gh api repos/TserenTserenov/FMT-exocortex-template/branches/main/protection`
— расхождение значит, что кто-то поменял защиту напрямую через UI/API мимо
этого документа.

## Процедура

**1. Снять защиту:**
```bash
gh api -X DELETE repos/TserenTserenov/FMT-exocortex-template/branches/main/protection
```

**2. Сделать то единственное действие, ради которого защита снималась.**
Не пользоваться открытым окном для чего-то ещё — после него сразу шаг 3.

**3. Восстановить защиту** — скопировать JSON-блок «Текущий базовый профиль»
выше в файл и применить:
```bash
cat > /tmp/branch-protection-restore.json <<'EOF'
{
  "required_status_checks": {
    "strict": false,
    "contexts": ["release-receipt", "changelog-entry"]
  },
  "enforce_admins": true,
  "required_pull_request_reviews": {
    "dismiss_stale_reviews": true,
    "require_code_owner_reviews": false,
    "require_last_push_approval": false,
    "required_approving_review_count": 0
  },
  "restrictions": null,
  "required_linear_history": false,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "block_creations": false,
  "required_conversation_resolution": false,
  "lock_branch": false,
  "allow_fork_syncing": false
}
EOF
gh api -X PUT repos/TserenTserenov/FMT-exocortex-template/branches/main/protection \
  --input /tmp/branch-protection-restore.json
rm -f /tmp/branch-protection-restore.json
```

**4. Проверить, что восстановилось именно это:**
```bash
gh api repos/TserenTserenov/FMT-exocortex-template/branches/main/protection | python3 -m json.tool
```
Сравнить с блоком «Текущий базовый профиль» построчно — не бегло.

## Что здесь сознательно не решено

**Дедлок identity параллельных пир-сессий (Ф21, открыто).** Если
`required_approving_review_count` когда-нибудь включат (`on --apply`), а две
пир-сессии одновременно будут ждать одобрения друг от друга на свои PR —
ни одна не сможет продвинуться (или обе ждут, или обе не имеют права
одобрить собственный PR под одним и тем же GitHub-аккаунтом, если push
у обеих сессий идёт от одной и той же identity `gh auth`). Этот документ
решает только «снять/вернуть защиту целиком», не этот конкретный дедлок —
он остаётся открытым пунктом Ф21 до отдельного разбора.

**`enforce_admins: true` в текущем профиле.** Значит, что даже владелец
репозитория не обходит защиту через UI без явного снятия этой самой
процедурой — это намеренно (иначе защита не защищает ни от чего), но
значит и то, что шаг 1 выше — единственный путь даже для владельца, если
обычная защита сама заблокировала нужное действие.
