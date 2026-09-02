# Процесс выпуска FMT-exocortex-template

> Кто, когда и как бампает версию шаблона. Цель: внятный критерий «готово к выпуску»
> вместо устного соглашения. Источник: WP-347 Ф3, 22 мая 2026.
> **Еженедельный авто-бамп** добавлен WP-5 (20 июля 2026) — см. «Регулярный выпуск» ниже.

## Что означает «выпуск»

`update.sh` по умолчанию работает через канал `release`: обновление закрепляется
на последнем опубликованном GitHub Release (тег; при наличии Python тег дополнительно
разрешается в commit SHA). Коммит в `main` доходит до пользователей только после
публикации следующего релиза. Если release определить не удалось, обновление
останавливается (fail-closed) — автоматического перехода на `main` нет.
Канал `main` (`IWE_UPDATE_CHANNEL=main`) — движущаяся ветка для авторского workflow.

**Версия** в `update-manifest.json["version"]` служит информационной меткой — отображается
при запуске `bash update.sh` как «Обновления экзокортекса (vX.Y.Z)», а также скачивается
при `--check` из remote-манифеста для сравнения с локальной. Бамп версии = сигнал
«этот набор изменений стабилизирован, пора обновляться».

## Регулярный выпуск (weekly-release.yml)

До WP-5 (20 июля 2026) бамп версии был только ручным — паузы между выпусками доходили
до 2-3 недель, хотя коммиты в CHANGELOG «Unreleased» шли почти ежедневно. Причина —
уведомление пользователям в боте генерируется как пересказ CHANGELOG и висит без выпуска
до тех пор, пока кто-то не подведёт черту вручную.

**`.github/workflows/weekly-release.yml`** — по расписанию (воскресенье 20:00 UTC) проверяет:
непустая ли секция `[Unreleased]` в CHANGELOG.md? Если да — сам бампает patch-версию
(`X.Y.Z` → `X.Y.(Z+1)`) в `update-manifest.json`, флашит `[Unreleased]` через
`scripts/changelog-flush.sh` и коммитит. Коммит триггерит `release.yml` — тег и
GitHub Release создаются автоматически.

**Ручной бамп по-прежнему возможен** для minor/major версий (новая функция, breaking change)
или для внепланового выпуска — критерии готовности и шаги ниже не отменяются, авто-бамп
их лишь применяет автоматически на patch-уровне раз в неделю вместо ожидания ручного решения.

---

## Критерии готовности к бампу версии

Все пункты должны быть выполнены:

- [ ] CI зелёный (`Validate Template` + все jobs)
- [ ] Нет открытых hotfix-веток (`git branch --list 'hotfix/*'` — пусто)
- [ ] CHANGELOG.md заполнен: секция `[Unreleased]` не пустая, нет «TODO» строк
- [ ] Все новые файлы добавлены в `update-manifest.json["files"]`
  (`git ls-files | python3 scripts/check-manifest-coverage.py update-manifest.json`)
- [ ] `deprecated_files` соответствует правилу (см. «Конвенция deprecated_files» ниже)
- [ ] fix-коммитов с последнего бампа ≤5 (если >5 → обязательный review нестабильности, см. секцию «Метрика стабильности»)

---

## Метрика стабильности

Количество fix-коммитов с момента последнего бампа версии служит прокси-метрикой стабильности кодовой базы. Порог ≤5 означает, что накопленная нестабильность ещё не критична и релиз можно проводить без дополнительного review; превышение порога требует явной оценки рисков.

```bash
# Подсчёт fix-коммитов с последнего бампа версии
# Ветка А — теги существуют (нормальный путь):
LAST_TAG=$(git tag --list 'v*' --sort=-v:refname | head -1)
if [ -n "$LAST_TAG" ]; then
  COUNT=$(git log "$LAST_TAG"..HEAD --oneline | grep -cE '^[a-f0-9]+ (fix|hotfix)(\(|: )' || true)
else
  # Ветка B — тегов нет (legacy, удалить через 2 релиза после восстановления тегов):
  LAST_MANIFEST_BUMP=$(git log -2 --format=%H -- update-manifest.json | sed -n '2p')
  if [ -z "$LAST_MANIFEST_BUMP" ]; then
    echo "ℹ️  Нет предыдущего бампа manifest — пропуск проверки fix-метрики (первый релиз)"
    exit 0
  fi
  COUNT=$(git log "$LAST_MANIFEST_BUMP"..HEAD --oneline | grep -cE '^[a-f0-9]+ (fix|hotfix)(\(|: )' || true)
fi
echo "fix-коммитов: $COUNT"
if [ "$COUNT" -gt 5 ]; then
  echo "⚠️  >5 фиксов — требуется review нестабильности перед бампом"
  exit 1
fi
```

> Fallback-ветка B удаляется через 2 релиза после восстановления нормальной тегальности.

## Шаги бампа версии

```bash
# 1. Убедиться что CI зелёный, pull последние изменения
git pull --rebase

# 2. Определить новую версию (semver: patch = фиксы, minor = новый скилл/функция)
NEW_VERSION="0.35.0"

# 3. Забампать версию в манифесте
python3 - "$NEW_VERSION" <<'EOF'
import json, sys
with open('update-manifest.json', encoding='utf-8') as f:
    m = json.load(f)
m['version'] = sys.argv[1]
with open('update-manifest.json', 'w', encoding='utf-8') as f:
    json.dump(m, f, ensure_ascii=False, indent=2)
    f.write('\n')
print(f"version bumped to {sys.argv[1]}")
EOF

# 4. Добавить раздел в CHANGELOG.md: переименовать [Unreleased] → [X.Y.Z] и добавить новый [Unreleased]
# Шаблон:
# ## [X.Y.Z] — YYYY-MM-DD
# ### Что нового
# - краткое описание
# ## [Unreleased]

# 5. Commit + push
git add update-manifest.json CHANGELOG.md
git commit -m "chore: release $NEW_VERSION"
git push
```

---

## Владелец выпуска

Автор шаблона (режим `author_mode: true` в `params.yaml`). Выпуск — синхронный шаг,
не может быть делегирован агентам без явного разрешения. Периодичность: по накоплению
изменений, ориентир ~1 раз в неделю при наличии значимых изменений.

Сигнал к выпуску: ≥1 фич или ≥3 фикса в `[Unreleased]`.

---

## Конвенция `deprecated_files`

Запись в `deprecated_files` означает: **файл УЖЕ удалён из репо или уже не используется**.
Это НЕ «планируем удалить» или «скоро мигрируем».

**Правило:**

1. Удаляешь файл из репо → в том же коммите добавляешь его в `deprecated_files`.
2. Вручную проверить что ни один скрипт/хук в репо не ссылается на этот путь:
   ```bash
   grep -r "path/to/deprecated-file" . --include="*.sh" --include="*.md" --include="*.json"
   ```
   Detector 10 в `integration-contract-validator.sh` ловит этот случай для
   `roles/strategist/prompts/` — но только для этого подмножества файлов.
   Для всех остальных deprecated-файлов ручная проверка обязательна.
3. Использовать `deprecated_files` как TODO-трекер («скоро уберём») — запрещено:
   после `update.sh` пользователь не получит новый файл, но и старый уже удалён из доставки.

**Почему важно:** если `deprecated_files` содержит файл, который runner ещё использует,
после `update.sh` runner упадёт с «файл не найден» (прецедент: `af3b15c`, роли стратегиста,
22 мая 2026).

---

## Чеклист при добавлении нового файла в FMT

При каждом `git add <new-file>` убедиться:

1. Файл добавлен в `update-manifest.json["files"]` (иначе пользователи не получат его).
   CI-проверка: `git ls-files | python3 scripts/check-manifest-coverage.py update-manifest.json`.
2. Если файл намеренно НЕ предназначен для доставки — добавить в `excluded_paths` или в
   один из исключённых каталогов (`.github/`, `setup/`, `seed/`, `extensions/`, `templates/`).
3. Если скрипт `.sh` — запустить `bash scripts/validate-fmt-scripts.sh scripts/` для проверки
   хардкодов и небезопасной арифметики под `set -e`.

---

## Связанные файлы

| Файл | Назначение |
|------|-----------|
| `update-manifest.json` | Список доставляемых файлов + версия |
| `CHANGELOG.md` | Changelog в формате Keep a Changelog |
| `scripts/check-manifest-coverage.py` | CI-проверка полноты манифеста (B2) |
| `scripts/validate-fmt-scripts.sh` | Проверка хардкодов + set-e арифметики (B8) |
| `setup/integration-contract-validator.sh` | Validator spec↔state (включая Detector 10) |
| `docs/SCRIPT-PROMOTION.md` | Процесс промоции скрипта L3→L1 |
