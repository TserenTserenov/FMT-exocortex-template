# Detector #7 regression sample (0.29.14 fix)

> Этот файл — fixture для prompts_python_coverage detector.
> Содержит реальный паттерн, который пропускал regex до 0.29.14.

Пример bare DS-strategy в backtick + slash:

`DS-strategy/inbox/WP-{N}-{slug}.md`

И ещё:

`DS-strategy/current/WeekPlan W{N}.md`
`DS-strategy/docs/WP-REGISTRY.md`

Все три формы — bare DS-strategy без `{{GOVERNANCE_REPO}}`.
Detector #7 ДОЛЖЕН выдать violation для этого файла.
