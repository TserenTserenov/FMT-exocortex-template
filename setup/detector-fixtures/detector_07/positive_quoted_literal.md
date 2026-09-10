# Detector #7 regression sample (issue #748 fix)

> Этот файл — fixture для prompts_python_coverage detector.
> Содержит паттерн, который пропускал regex до этого фикса: голый
> quoted-литерал без {{GOVERNANCE_REPO}}, например в примере YAML внутри
> markdown-промпта.

Пример:

```yaml
governance_repo: "DS-strategy"
```

И одинарными кавычками:

```yaml
governance_repo: 'DS-strategy'
```

Detector #7 ДОЛЖЕН выдать violation для этого файла.
