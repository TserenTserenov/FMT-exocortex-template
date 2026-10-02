# Detector #7 regression sample — negative (issue #748 fix)

> Negative fixture for the prompts_python_coverage detector. Detector #7
> must NOT flag this file: every mention of the governance repo default
> below goes through {{GOVERNANCE_REPO}} or an env-fallback pattern, never
> as a bare quoted/backticked literal on its own.

Путь к WP всегда через плейсхолдер:

`{{GOVERNANCE_REPO}}/inbox/WP-{N}-{slug}.md`

Пример конфигурации с fallback (не голый литерал — окружён `${...:-...}`):

```yaml
governance_repo: "${GOVERNANCE_REPO:-DS-strategy}"
```

И явная ссылка на переменную:

Значение по умолчанию задаётся через $GOVERNANCE_REPO.
