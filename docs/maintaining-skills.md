# Поддержка skills в FMT

## Добавление нового skill

1. Создать директорию `.claude/skills/<name>/`
2. Написать `SKILL.md` с frontmatter:
   ```yaml
   ---
   name: <name>
   description: "..."
   version: 1.0.0
   layer: L1 | L2 | L3
   status: active | experimental | deprecated
   triggers:
     slash: [/<name>]
     phrases: ["..."]
   ---
   ```
3. Добавить skill в `docs/skills-catalog.md`
4. Запустить `python scripts/iwe-catalog-list.py` для проверки

## Изменение рубрик diagnose-iwe

SoT: `shared/rubrics/form-089.yaml`

```bash
# 1. Отредактировать YAML
vim shared/rubrics/form-089.yaml

# 2. Проверить синхронность (дрифт-детекция)
python scripts/generate-diagnose-iwe-skill.py --check
# Если ошибка — обнови SKILL.md вручную, чтобы вопросы совпадали с YAML

# 3. Закоммитить оба файла вместе
git add shared/rubrics/form-089.yaml .claude/skills/diagnose-iwe/SKILL.md
git commit -m "feat(diagnose-iwe): update rubrics"
```

Pre-commit hook проверяет синхронность автоматически.

## Удаление skill

1. Пометить `status: deprecated` в SKILL.md
2. Указать `sunset: "FMT vX.Y"` или `sunset_condition: "..."`
3. Добавить запись в CHANGELOG
4. Удалить файлы в следующем major релизе
