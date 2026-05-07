---
purpose: adversarial post-release audit prompt
trigger: каждый релиз — после `git push` тегов или version bump'а в update-manifest.json
who_runs: автор шаблона (через Claude Code session) ИЛИ scheduled subagent
---

# Adversarial Post-Release Audit Prompt

> **Назначение:** найти регрессии, которые detector'ы 8/8 + smoke 14/14 НЕ ловят. Этот промпт воспроизводит роль Євгения (внешний пилот) с context isolation.
>
> **Использование (ручное):** скопировать в Claude Code сессии: `cat setup/release-audit-prompt.md`. Адаптировать version + предыдущую под контекст.
>
> **Использование (автоматизация):** workflow `.github/workflows/post-release-audit.yml` (workflow_dispatch) опубликует issue с этим промптом — автор затем прогонит в Claude.

---

## Промпт (копировать в Claude session)

```
Ты — adversarial sub-agent post-release verify для FMT-exocortex-template
v<TARGET-VERSION>. Контекст изоляции: проверяй самостоятельно, не доверяй
CHANGELOG автора.

**Директория:** /path/to/FMT-exocortex-template

**Задача — найти 5+ потенциальных классов регрессий:**

1. **Прогон валидаторов:**
   bash setup/integration-contract-validator.sh
   bash setup/smoke-test-fresh-install.sh
   Должны быть PASS 8/8 + 14/14.

2. **Author-space drift:** Есть ли OTHER skills/files в авторском IWE
   (~/IWE/.claude/skills/ или ~/IWE/memory/), которые существуют у автора,
   но НЕТ в FMT?
   diff <(ls ~/IWE/.claude/skills/) <(ls ~/IWE/FMT-exocortex-template/.claude/skills/)

3. **Author-constants остались:** Помимо очевидных (DS-strategy и т.д.),
   есть ли другие авторские константы в FMT? Пример паттернов которые
   стоит проверить: имя пользователя (lowercase + camelCase),
   имена авторских ботов (заканчиваются на `_bot`), имена авторских
   репо (DS-* кроме платформенных), имена облачных проектов автора
   (Railway/Heroku/etc).
   Прогон: `grep -rEn '<pattern1>|<pattern2>|...' --include='*.sh' \
       --include='*.md' --include='*.py' --include='*.json' \
       --include='*.yaml' .` где `<patternN>` — авторские константы.

4. **Substituted list integrity:** Все ли файлы в .claude/runtime-overlay.yaml
   реально содержат хотя бы один {{X}} плейсхолдер?

5. **EXTENSION POINT consistency:** Все ли declared hooks в extensions/README.md
   действительно вызываются через load-extensions.sh в коде skill/protocol?
   И наоборот — все ли вызовы load-extensions.sh имеют запись в README?
   grep -rohE 'extensions/[a-z-]+\.[a-z]+\.md' memory/ .claude/skills/ | sort -u
   grep -rohE 'load-extensions\.sh [a-z-]+ [a-z]+' .claude/skills/ | sort -u

6. **Manifest integrity:** Все ли файлы в update-manifest.json:files
   физически существуют? И обратное — все ли L1 файлы в дереве учтены?

7. **Broken refs:** Все ли ссылки в memory/*.md, .claude/skills/*/SKILL.md,
   docs/*.md указывают на существующие файлы?
   grep -rohE 'memory/[a-z-]+\.md' memory/ .claude/skills/

8. **Validator regex gaps:** Можно ли пропустить current detector regex'ом,
   создав violation в новой синтаксической форме? Например, для DS-strategy
   detector pattern `'`DS-strategy[`/]|/DS-strategy/| DS-strategy[ /]'` —
   найди форму hardcode которую он не ловит.

9. **Update.sh flow risks:** Что может сломаться при upgrade с предыдущей
   версии (НЕ fresh install)? Анализ: какие файлы были перемещены, удалены,
   получили новые placeholders с прошлого релиза?

10. **OS portability:** Найди shell/python синтаксис, специфичный для одной ОС
    (macOS: sed -i '', date -v-; Linux: sed -i, date -d).

**Формат ответа:** для каждого класса — конкретные файлы и строки + severity
(blocker/important/nice-to-have). Финальный вердикт STABLE или есть проблемы.

Бюджет: до 200 строк.
```

---

## История применения

| Дата | Версия | Кем запущен | Результат |
|------|--------|-------------|-----------|
| 2026-04-29 | 0.29.13 | Євгений (manual fresh clone) | 8 violations найдено, → 0.29.14/15/16/17 |
| 2026-04-29 | 0.29.16 | sub-agent (этот промпт) | 2 minor найдены, → 0.29.17 |

Каждая запись = новый класс регрессий → +1 detector в `integration-contract-validator.sh`.
