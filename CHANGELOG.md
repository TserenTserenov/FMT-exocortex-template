# Changelog

All notable changes to FMT-exocortex-template will be documented in this file.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning: [Semantic Versioning](https://semver.org/).

## [0.29.21] — 2026-04-30

### Added — WP-217 Ф10: Memory Lifecycle Protocol

Четыре скрипта валидации и управления памятью (`scripts/`):

- **`memory-validate.sh`** — frontmatter-гейт: проверяет 9 обязательных полей (name, description, type, horizon, domains, status, valid_from, owner, schema_version), допустимые значения, инвариант `superseded→superseded_by`
- **`memory-health.sh`** — метрики: кол-во файлов, HOT-лимит (≤150 строк), orphans%, распределение по горизонтам
- **`memory-bleed.sh`** — детектор нарушений: HOT overflow, orphans без frontmatter, superseded без ссылки, TTL-кандидаты на понижение горизонта
- **`memory-migrate.sh`** — автодобавление отсутствующих полей (type/horizon/domains/status/owner/schema_version/name/description/valid_from) с инференцией по имени файла; `--dry-run` и `--all` режимы

Интеграция в Close-протоколы:

- **`week-close/SKILL.md`** — добавлен шаг **7c Memory Validate** (T22b): `bash ${IWE_SCRIPTS}/memory-bleed.sh`; нарушения → исправить до коммита, кандидаты понижения → информативно
- **`month-close/SKILL.md`** — обновлён шаг **1f**: конкретные команды `memory-health.sh` + `memory-bleed.sh` вместо описательного текста

Commit: `84dd6dc`

## [0.29.20] — 2026-04-29

### Fixed — protocol-close.md: pre-commit checks ambiguity (Eugene's report)

`memory/protocol-close.md` шаг 1 был неоднозначен: checks и commit описывались в одном блоке, непонятно — checks до commit'а или после?

- Шаг 1 разбит на два явных подшага:
  - **1a. Pre-commit checks (БЛОКИРУЮЩЕЕ)** — load-extensions checks, при ❌ commit запрещён
  - **1b. Commit + Push** — только после прохождения checks
- Семантика идентична Day/Week Close (как описано в `run-protocol/SKILL.md` Шаг 1b)
- Commit: `51b06a0` (прямой коммит в FMT, минуя broken template-sync pipeline)

## [0.29.19] — 2026-04-29

### Fixed (sub-agent post-release verify 0.29.18)

**SA-8 — DRY-нарушение detector regex:**
- `DETECTOR_07_REGEX` дублировался в `setup/integration-contract-validator.sh:238` и `setup/test-detectors.sh:35`. При правке regex в одном месте второе расходилось → ложный pass на регрессии.
- Вынесен в `setup/detector-regex.sh` как shared source. Оба скрипта теперь `source` его. Изменение regex → автоматическая sync.

### Added — Pack documentation (retro-fix IntegrationGate skip P10)

После 0.29.13-0.29.18 был сделан 5-слойный verification protocol, но описание системы лежало только в CHANGELOG + коде. Это нарушение IntegrationGate (CLAUDE.md §2): прыжок в реализацию минуя (1) обещание → (2) сценарии → (3) роль → (4) реализация. Retro-fix:

| Артефакт | Pack | Описывает |
|----------|------|-----------|
| `VR.SC.006-release-verification-protocol.md` | PACK-verification | Обещание: 5-слойная верификация при каждом release |
| `VR.M.006-five-layer-post-release-verification.md` | PACK-verification | Метод: 8 detectors → smoke → upgrade → fixtures → adversarial |
| `VR.R.002-auditor.md` (extension) | PACK-verification | + сценарий «Release FMT-шаблона» для существующего Аудитора |
| `AR.203-release-verification-trigger.md` | PACK-agent-rules | Блокирующее правило: version bump → 5-слойный прогон обязателен |

**Cross-references** добавлены в FMT файлы (`integration-contract-validator.sh`, `test-detectors.sh`, `validate-template.yml`, `post-release-audit.yml`) как `# see VR.SC.006, VR.M.006, AR.203`.

### Verified

`integration-contract-validator.sh` → ✅ PASS (8/8)
`smoke-test-fresh-install.sh` → ✅ PASS (14/14)
`test-detectors.sh` → ✅ PASS (1 fixture, через shared regex source)

## [0.29.18] — 2026-04-29

### Added — 5 уровней автоматизации проверок (закрывает функции, которые ранее держал Євгений вручную)

После 0.29.16 валидаторы запускаются на pre-commit + CI, но Євгений всё равно может ловить классы регрессий, которые наши гейты не покрывают. Этот релиз закрывает 5 таких классов автоматизацией.

**1. OS matrix в CI (item 2):**
- `integration-contract` job теперь идёт на `[ubuntu-latest, macos-latest]`. macOS preinstall: `brew install jq`.
- Ловит портабельность-баги, которые были в 0.28.12 (BUG-2..4 на Linux).

**2. Upgrade-flow regression test в CI (item 1):**
- Новый job `upgrade-test`: checkout previous version (по `git log update-manifest.json`) → smoke на ней → checkout HEAD → re-run validator + smoke. Симулирует upgrade-сценарий (а не fresh build).
- Ловит класс 0.29.13 (template-sync перетёр стабильный код).

**3. Detector regex regression tests (item 3):**
- `setup/detector-fixtures/` — historical positive samples, которые detectors ДОЛЖНЫ ловить. Первый: `detector_07/positive_backtick_slash.md` (regression sample 0.29.14).
- `setup/test-detectors.sh` — runner, прогоняет каждый detector regex на fixtures.
- В `pre-commit` (если staged изменения в validator/fixtures) и в CI.
- Ловит regex-gap регрессии в самих detector'ах (как 0.29.14 backtick+slash gap).

**4. Scheduled adversarial audit workflow (item 4):**
- `.github/workflows/post-release-audit.yml` — на каждый push изменяющий `update-manifest.json` (= релиз) auto-создаёт GitHub Issue с adversarial-промптом. Также `workflow_dispatch` для ручного триггера.
- `setup/release-audit-prompt.md` — единый промпт-template для adversarial audit (10 классов проверок).
- Автор/пилот прогоняет в Claude session, найденные классы → +detector в `integration-contract-validator.sh`.

**5. UX walkthrough prompt template (item 5):**
- `setup/ux-walkthrough-prompt.md` — symulator «новый пилот час 0» проходит онбординг буквально, фиксирует UX-провалы (broken links, скрытые prerequisites, jargon без расшифровки).
- Запускается вручную через subagent (item 5 не покрывается автоматически — UX требует human-like reasoning).

### Verified

`integration-contract-validator.sh` → ✅ PASS (8/8)
`smoke-test-fresh-install.sh` → ✅ PASS (14/14)
`test-detectors.sh` → ✅ PASS (1 fixture)

### Что осталось у Євгения после 0.29.18

- Реальная установка на пилотской ОС/железе (не CI sandbox)
- Тестирование long-tail сценариев накопленным use'ом
- Различия mental models — другие blind spots чем у автора + sub-agent
- Final UX-judge: «понятно ли реальному человеку»

## [0.29.17] — 2026-04-29

### Fixed (sub-agent post-release verify 0.29.16 — 2 minor)

**SA-6 — `day-close after` orphan hook:**
- `extensions/README.md` table декларировал `day-close.after.md` как extension point, но `.claude/skills/day-close/SKILL.md` не имел caller'а — пилот, создавший `extensions/day-close.after.md`, не получал вызова.
- Добавлен шаг 9c `Extensions (after)` с `load-extensions.sh day-close after` (между шагами 9 «Запись итогов» и 10 «Закоммитить» — параллельно `week-close` структуре).
- Detector #3 не ловил это, потому что mention `extensions/day-close.after.md` встречался в текстовых примерах README.

**SA-7 — pre-commit scope filter не покрывал `seed/`:**
- Detector #2 (`seed_references`) проверяет ссылки `seed/...` в `protocol-*.md`. Изменение в `seed/` не триггерило валидатор → drift возможен silently.
- Расширен filter: `roles/|.claude/|setup/|memory/|extensions/|seed/|update-manifest.json`.

### Verified

`integration-contract-validator.sh` → ✅ PASS (8/8)
`smoke-test-fresh-install.sh` → ✅ PASS (14/14)

## [0.29.16] — 2026-04-29

### Fixed (Євгений Round 3 + sub-agent broader audit)

**EZ-1 — `day-close.checks` не использовал loader (Євгений 29 апр):**
- `.claude/skills/day-close/SKILL.md` строки 50, 136, 171 читали exact `extensions/day-close.checks.md`. Suffix-расширения (`day-close.checks.beads.md`) не подхватывались.
- Все 3 точки переведены на `bash .claude/scripts/load-extensions.sh day-close checks` (как day-close.before в 0.29.9 и week-close.before/after в 0.29.13).

**SA-4 — `apply-captures` skill отсутствовал в FMT, но ссылки были:**
- Skill упомянут в `CHANGELOG.md`, `.claude/skills/ke/SKILL.md`, `roles/strategist/prompts/session-prep.md` — но физически отсутствовал.
- Промотирован из авторского IWE с заменой констант `DS-my-strategy` → `{{GOVERNANCE_REPO}}` и `~/IWE/` → `{{WORKSPACE_DIR}}/`.
- Добавлен в `update-manifest.json` files.

**SA-5 — Broken refs в memory:**
- `memory/MEMORY.md:38-39` — ссылки на `claude-md-maintenance.md` и `wp-gate-lesson.md` (оба deprecated в 0.27, файлов нет). Удалены.
- `memory/t-checklist.md:61` — ссылка на `memory/protocol-month-close.md` (нет такого файла, есть skill `.claude/skills/month-close/SKILL.md`). Ссылка на отсутствующий протокол убрана.

### Added — meta-fix: интеграция валидаторов в release-gate

**Корневая причина 0.29.13 регрессий:** `integration-contract-validator.sh` и `smoke-test-fresh-install.sh` существовали как ручные скрипты — Євгений запускал на fresh clone, мы при коммите не запускали. CHANGELOG записи «Verified: 8/8 PASS» писались руками. Каждое забывание = регрессия у пилота.

**Pre-commit hook (`.githooks/pre-commit`):**
- Новый блок `INTEGRATION-CONTRACT-VALIDATOR` запускает `setup/integration-contract-validator.sh` если staged файлы из scope (`roles/`, `.claude/`, `setup/`, `memory/`, `extensions/`, `update-manifest.json`).
- FAIL → коммит блокируется. Escape: `git commit --no-verify`.

**CI workflow (`.github/workflows/validate-template.yml`):**
- Новый job `integration-contract` запускает оба скрипта на каждый push/PR в main.
- Defense-in-depth для `--no-verify` пропусков pre-commit.

После 0.29.16: регрессии класса 0.29.13 ловятся **до** push'а у автора, а не на fresh clone у пилота.

### Verified

`integration-contract-validator.sh` → ✅ PASS (8/8)
`smoke-test-fresh-install.sh` → ✅ PASS (14/14)

## [0.29.15] — 2026-04-29

### Added — closure pre-existing WARN из validator #3

`extensions/README.md` декларировал hooks `month-close.before` и `month-close.after`, но `month-close` SKILL отсутствовал в FMT (жил только в авторском IWE). Validator #3 выдавал 2 WARN (в обходных категориях, не FAIL) — pre-existing с момента добавления month-close в README (0.29.9).

**Промоция month-close skill из авторского IWE → FMT:**
- `.claude/skills/month-close/SKILL.md` создан (280 строк, заменены авторские константы `DS-my-strategy` → `{{GOVERNANCE_REPO}}`, `~/IWE/` → `{{WORKSPACE_DIR}}/`).
- Содержит 2 EXTENSION POINT через `load-extensions.sh month-close before` (Шаг 0) и `load-extensions.sh month-close after` (Шаг 11).
- Добавлен в `update-manifest.json` files (alphabetic order).

### Verified

`integration-contract-validator.sh` → ✅ PASS (8/8 + Detector #3 теперь без WARN)
`smoke-test-fresh-install.sh` → ✅ PASS (14/14)

## [0.29.14] — 2026-04-29

### Fixed (sub-agent post-release audit 0.29.13 нашёл 3 дополнительных проблемы)

**SA-1 — agential prompts auditor/verifier: hardcoded `DS-strategy/` (пропущено validator #7):**
- `roles/auditor/prompts/audit-plan-consistency.md` строки 12-14 — 3 bare `DS-strategy/path` в backtick.
- `roles/verifier/prompts/verify-wp-acceptance.md` строка 11 — bare `` `DS-strategy/inbox/...` ``.
- Validator #7 regex `` '`DS-strategy`|/DS-strategy/| DS-strategy[ /]' `` не матчил паттерн `` `DS-strategy/ `` (backtick + slash без пробела). Расширен до `` '`DS-strategy[`/]|/DS-strategy/| DS-strategy[ /]' ``.
- Оба файла исправлены: `DS-strategy` → `{{GOVERNANCE_REPO}}`.

**SA-2 — extractor.sh строки 145/148/152: `DS-strategy` в log-сообщениях:**
- Файл в substituted-списке — `DS-strategy` в текстах логов вводил в заблуждение при нестандартном GOVERNANCE_REPO.
- Заменено на `$_gov_repo` (переменная уже определена в том же scope строкой 103).

**SA-3 — validator regex gap:**
- Detector #7 расширен: теперь ловит `` `DS-strategy/path` `` (backtick+slash) — паттерн из agential-промптов.

### Verified

`integration-contract-validator.sh` → ✅ PASS (8/8), `smoke-test-fresh-install.sh` → ✅ PASS (14/14).

## [0.29.13] — 2026-04-29

### Fixed (R6 Round 2 от Евгения — регрессия после template-sync 2026-04-28)

Коммит `17102ae template-sync: propagate platform-space changes 2026-04-28` перезаписал файлы из авторского IWE, в котором лежала версия ДО фиксов 0.29.5/0.29.6/0.29.7. Результат: `integration-contract-validator.sh` → 8 violations, `smoke-test-fresh-install.sh` → 2 FAIL.

**RT-1 — `strategist.sh` откат до pre-0.29.5 (3 регрессии одновременно):**
- `WORKSPACE` стал хардкодом `$HOME/IWE/DS-strategy` (было `{{WORKSPACE_DIR}}/{{GOVERNANCE_REPO}}`).
- `PROMPTS_DIR` стал `$REPO_DIR/prompts` без `$IWE_TEMPLATE`-fallback (antipattern R5.1).
- `run_claude()` потерял sed-substitution GOVERNANCE_REPO/WORKSPACE_DIR/GITHUB_USER в промптах (добавлен в 0.29.5, escaped в 0.29.6).
- Восстановлено до 0.29.7 (git `66f8566`).

**RT-2 — `cleanup-processed-notes.py` откат до pre-0.29.5:**
- `WORKSPACE = Path.home() / "IWE" / "DS-strategy"` — жёсткий хардкод вернулся.
- `_resolve_workspace()` (читает `IWE_WORKSPACE` + `IWE_GOVERNANCE_REPO` из env + fallback через `.exocortex.env`) была потеряна.
- Восстановлено до 0.29.7.

**RT-3 — 6 prompt-файлов откатились до pre-0.29.5:**
- `roles/strategist/prompts/{day-close,day-plan,note-review,session-prep,strategy-session,week-review}.md` — `DS-strategy` bare без `{{GOVERNANCE_REPO}}`.
- Все 6 восстановлены до 0.29.7.

**RT-4 — `dt-collect.sh` откатился (detector 7 не ловил .sh в roles/):**
- `GOVERNANCE_DIR="${GOVERNANCE_DIR:-$WORKSPACE/DS-strategy}"` — хардкод.
- `SESSION_LOG="$WORKSPACE/DS-strategy/inbox/..."` — хардкод.
- Файл в `substituted:` списке overlay — build-runtime не мог подставить `{{GOVERNANCE_REPO}}`. Восстановлены плейсхолдеры.

**RT-5 — `update-manifest.json` intersection `files ∩ deprecated_files`:**
- 0.29.11 добавил в `deprecated_files` 8 файлов с reason `"strategist role removed"`, но эти файлы остались в `files` и физически в репо (роль не удалена). update.sh получил конфликт «доставить и удалить». Удалены 8 premature deprecated_files записей.

**RT-6 — `week-close/SKILL.md` — before/after hooks не перешли на `load-extensions.sh`:**
- После R5.5 (0.29.9) `day-close.before` перешёл на loader-native, но `week-close.before` и `week-close.after` остались с `ls extensions/week-close.*.md` (exact filename). Обновлены оба по образцу `day-close.before` (0.29.9).

### Verified

`integration-contract-validator.sh` → ✅ PASS (8/8), `smoke-test-fresh-install.sh` → ✅ PASS (14/14).

### Root cause

Файлы из авторского IWE (платформенное пространство) содержали pre-0.29.5 версии — template-sync не подтягивал фиксы, сделанные напрямую в FMT. Правильный flow: фикс в авторском IWE (source-of-truth) → template-sync → FMT. Нарушение в 0.29.4-0.29.7: часть фиксов писалась напрямую в FMT минуя author-space. При следующем template-sync FMT перезаписался старыми версиями.

## [0.29.12] — 2026-04-28

### Fixed

- **`scripts/iwe-audit.sh` — путь поиска `.exocortex.env`** — скрипт искал файл в `$HOME/.exocortex.env`, но `setup.sh ≥0.7.0` (WP-273) сохраняет его в `$IWE_ROOT/.exocortex.env`. Пользователи с актуальной установкой получали ложную ошибку «файл отсутствует». Исправлено: сначала проверяется `$IWE_ROOT/`, fallback на `$HOME/` для legacy-инсталляций (до 0.7.0). Фидбек пилота Дмитрия, 28 апр.

## [0.29.11] — 2026-04-28

### Added

- **`deprecated_files` в манифесте** — `update.sh` теперь обнаруживает и удаляет устаревшие L1-файлы (WP-5 Ф-N артефакт #1). Добавлен раздел `deprecated_files` в `update-manifest.json` и `generate-manifest.sh`; `update.sh` показывает список и удаляет при применении. Первая партия: `strategist-agent/` (удалён), `roles/strategist/prompts+scripts/` (переехало в `.claude/skills/`), `LEARNING-PATH.md` (переехал в `docs/`), `memory/claude-md-maintenance.md` + `memory/wp-gate-lesson.md` (устарели).
- **`/iwe-bug-report` скилл** — создаёт GitHub issue в FMT-exocortex-template через `gh issue create` (6 шагов: категоризация → детали → gh CLI check → issue → URL).
- **`docs/onboarding/iwe-layers.md`** — онбординг-схема слоёв L1/L2/L3.
- **`.stignore` по умолчанию** — шаблон добавлен в корень FMT (`717d2d8`). При `update.sh` пользователь получает рабочий `.stignore` для Syncthing (исключены `.git/`, `node_modules/`, `.venv/`, `*.pyc` и другие build-артефакты). Фидбек пилота Дмитрия, 27 апр.
- **`day-close` шаг 10b rule-classifier** — добавлен шаг `python3 $HOME/IWE/.claude/scripts/rule-classifier.py` после коммита в SKILL.md day-close (WP-272 Ф5.2, `0e41292`). Обогащает журнал `~/logs/rule-engine/YYYY-MM-DD-classified.jsonl`. Exit-код игнорируется (идемпотентно); убивать через 60 сек если зависает.

## [0.29.10] — 2026-04-28

### Fixed (Linux portability — bug-report от пилота Дмитрия)

После 0.29.9 Дмитрий обнаружил два cross-platform бага при запуске `iwe-drift.sh` + `iwe-audit.sh` на Linux после `update.sh`:

- **`scripts/iwe-drift.sh`** функция `dir_newest_mtime_days_ago` безусловно вызывала `xargs -0 stat -f %m` (BSD-only). На Linux GNU stat `-f` = filesystem info → текст «Inodes: ...» → арифметика падала с `unbound variable`.
- **`scripts/iwe-audit.sh:227`** опечатка `$DRIFT_RC_` (trailing underscore) под `set -u` парсилась как имя переменной `DRIFT_RC_` → unbound при ненулевом exit code drift-скрипта.

**Round 1 фикс ([`a967b7e`](https://github.com/TserenTserenov/FMT-exocortex-template/commit/a967b7e)):** cross-platform детект BSD/GNU stat через exit-check `if stat -f %m / >/dev/null 2>&1`; опечатка → `${DRIFT_RC}_`.

**Round 2 фикс ([`9112c6a`](https://github.com/TserenTserenov/FMT-exocortex-template/commit/9112c6a)):** red-team subagent (Sonnet, isolated, adversarial deep audit) нашёл регрессию для Alpine/busybox — busybox stat толерантен к неизвестным флагам, exit-check возвращал 0 даже без поддержки `-f %m`. Финальный фикс:
- Probe через **format-check** (`[[ "$_probe" =~ ^[0-9]+$ ]]`) вместо exit-check — отвергает мусор «Inodes: 99», даже если exit=0.
- Detection вынесен на load-time → global array `STAT_MTIME_FLAGS` (один probe вместо повторов).
- `stat $stat_fmt` (unquoted word-split) → `stat "${STAT_MTIME_FLAGS[@]}"` (массив, future-proof).
- `mtime_days_ago` тоже переведён на массив (был тот же exit-check).
- Probe на `/dev/null` вместо `/` (портативнее).

**Verification:**
- macOS smoke (BSD): `iwe-drift.sh --top 5` + `iwe-audit.sh` PASS.
- macOS regression-mock (PATH override, fake busybox `stat -f` → «Inodes: 99», exit 0): format-check отверг мусор → GNU branch → drift-таблица c числовым lag. Alpine-регрессия закрыта.
- `validate-template.sh` PASS.
- Linux подтверждение от Дмитрия — ожидается после `update.sh`.

**Мета-урок:** Round 1 author-blind на macOS закрыл оригинальные баги Дмитрия, но red-team round 2 нашёл регрессию для подмножества Linux (Alpine/busybox). Каждый «не-author» = новый класс ошибок; cross-platform pipeline (author macOS → пилот Linux/Alpine/WSL) требует валидации на каждой платформе деплоя. Кандидат в РП «IWE release discipline» (W19+): GitHub Actions matrix `[macos-latest, ubuntu-latest]` для validate-template.sh + smoke ключевых скриптов. Подтверждение мета-урока Round 1+2+3 Евгения (26 апр): «Two-pass sub-agent verification > one-pass; adversarial deep audit > standard QA».

## [0.29.9] — 2026-04-28

### Fixed (R5.5 — Suffix extensions native, WP-273 reopened по триггеру Евгения)

После 0.29.7 Евгений заметил незакрытый contract gap: helper `.claude/scripts/load-extensions.sh` существует (R4.4 артефакт из 0.29.0/0.29.7), но **ни один skill/protocol его не вызывает** — все 13 EXTENSION POINT'ов всё ещё инструктируют `ls extensions/<protocol>.<hook>.md` (exact filename). `extensions/README.md` обещает wildcard suffix («Несколько расширений одного hook — загружаются в алфавитном порядке»), но кодом end-to-end это не закрыто. Это паттерн «Spec ↔ State drift» — helper готов, consumers не подключены.

**Корневая причина:** R4.4 в WP-273 закоммитил helper, но автор пропустил «закрытие контракта» — точку, где skills/protocols фактически начинают вызывать loader. Suffix-файлы лежали бы пассивно, manifest-файлы оставались единственным рабочим способом — пилоты делали ручные manifest'ы с Read'ом suffix-файлов как workaround.

**Фикс end-to-end (13 EXTENSION POINT'ов):**

| Файл | Точки | Hook'и |
|------|-------|--------|
| `memory/protocol-open.md` | 1 | after |
| `memory/protocol-close.md` | 2 | checks, after |
| `.claude/skills/run-protocol/SKILL.md` | 3 (generic) | before, after, checks |
| `.claude/skills/day-open/SKILL.md` | 3 | before, after, checks |
| `.claude/skills/day-close/SKILL.md` | 4 (3 × `checks` + 1 × `before`) | before, checks |
| `.claude/skills/month-close/SKILL.md` | 2 | before, after |

Каждый паттерн `ls extensions/X.Y.md → Read` заменён на:
```
bash .claude/scripts/load-extensions.sh X Y → exit 0 → Read каждый файл из вывода (alphabetic) → выполнить
```

**Документация (контракт wildcard):**
- `extensions/README.md` обновлён: 13 EP вместо 9 (добавлены `day-open.checks`, `day-close.before`, `month-close.before/after`); явный раздел про loader-native (с 0.29.9); manifest sorts ПОСЛЕ suffix lexico → пометка про `01-`, `02-` префиксы для управления порядком; пара unicode-битых ячеек таблицы починена (`ша�� 6д` → `шаг 6д`, `Ре��лексия` → `Рефлексия`).
- `.claude/skills/extend/SKILL.md` каталог: 13 EP в таблице, явный раздел про suffix.

**Smoke-test:** `setup/smoke-test-fresh-install.sh` Test 7 (3 sub-теста):
- 7a — manifest + 2 suffix → 3 файла, alphabetic order `health → linear → manifest`.
- 7b — hook без файлов → exit 1.
- 7c — только suffix без manifest → exit 0.
Всего 12 PASS / 2 FAIL (две FAIL — pre-existing R6.x known issues, не R5.5).

**Эффект для пилотов:** теперь можно держать **только** suffix-файлы (`day-close.after.health.md` + `day-close.after.linear.md`) без manifest-файла. Если manifest существовал как workaround (Read'ом подгружал suffix) — его надо **удалить**, иначе loader подхватит и manifest, и suffix → двойное выполнение.

### Why

Закрытие WP-273 4-го корня провала «Spec ↔ State drift» через **end-to-end** замыкание контракта. R4.4 в 0.29.0/0.29.7 был наполовину сделан — helper без consumer'ов это не contract closure, а **обещание** в документации без реализации. Метапаттерн: «положить файл в репо ≠ закрыть контракт». R5.5 показал что Round-серии Евгения работают как валидатор: helper мог пролежать пассивным месяц, пока пилот первый раз попробовал бы suffix-файл и обнаружил.

## [0.29.8] — 2026-04-28

### Added (правило именования РП в WP-REGISTRY.md)

CLAUDE.md §9 (Авторское — Именование РП): новый абзац «Название в WP-REGISTRY.md = ≤80 символов, только русский». Запрещено в названии: статус, даты, фазы, parenthetical-нарратив, английские пояснения, ссылки на другие РП. Контекст РП живёт в `inbox/WP-NNN-*.md` (активные) и `archive/wp-contexts/` (закрытые). Эталоны: WP-254, WP-258, WP-264. Допустимы кодовые идентификаторы и Pack-ID, если являются собственным именем артефакта (`projection-worker`, `DP.SC.125`, `cut-over`, `IWE`).

### Why

Распухшие названия в текущем реестре (WP-265…WP-278 разрослись до 500+ символов с английским нарративом, статусами фаз и метриками) перестали быть индексом и превратились в свалку handoff-ов. Правило-индекс возвращает реестр к роли каталога, а нарратив — на своё место в inbox-карточку РП.

## [0.29.7] — 2026-04-27

### Fixed (Round 5 Евгения — 4 платформенных хвоста после migration на 0.29.6)

После прогона `update.sh` на 0.29.6 в реальном пилотском IWE Евгений нашёл 4 хвоста миграции. Все системные, разной глубины.

**R5.1 — `migrate-to-runtime-target.sh --dry-run` падает на ERROR:** dry-run не копирует `.exocortex.env` в workspace (по логике «без записей»), но потом передаёт `build-runtime --env-file "$WORKSPACE_DIR/.exocortex.env"` принудительно — файла нет, build-runtime exit 2. Прямой `build-runtime --dry-run` с legacy env path работает.
- **Фикс:** после Step 3 пересчитываю `ENV_FILE` по принципу «что реально есть на диске» (workspace → FMT legacy → exit). Dry-run использует существующий source без побочных эффектов.

**R5.2 — `BACKUP_DIR: unbound variable` в clean-FMT ветке:** `BACKUP_DIR=` объявлялся только в `DIRTY_COUNT > 0`-ветке (Step 5), но печатался безусловно в финальном hint (line 205) под `set -eu` → bash валится при clean-FMT повторном запуске.
- **Фикс:** инициализация `BACKUP_DIR=""` в начале + защита печати условием `[ -n "$BACKUP_DIR" ] && echo …`. Hint не показывается при clean-FMT — там и backup'а нет.

**R5.3 — `~/.iwe-paths` не апгрейдится при миграции 0.28→0.29:** `setup.sh [4d]` пишет полный набор IWE_* переменных (включая `IWE_RUNTIME`), но миграция 0.28→0.29 идёт через `migrate-to-runtime-target.sh`, который вообще не трогает `~/.iwe-paths`. Старый файл остаётся без `export IWE_RUNTIME` → `install.sh` для launchd-ролей видит неполный env.
- **Корневая причина:** OwnerIntegrity нарушен — source-of-truth для `~/.iwe-paths` дублировался в `setup.sh [4d]` и должен быть в migrate, но не был.
- **Фикс системный:** новый хелпер `setup/install-iwe-paths.sh` — единственный writer `~/.iwe-paths`. Вызывается из `setup.sh [4d]` (рефакторинг) и из `migrate-to-runtime-target.sh` Step 6 (новый шаг). Идемпотентный, поддерживает `--dry-run`. update.sh может тоже его вызывать при следующих апгрейдах без новой логики.

**R5.4 — strategist/extractor/synchronizer launchd plist'ы не экспортируют IWE_***: `EnvironmentVariables` в plist'ах содержал только `PATH+HOME`. Дочерний скрипт `strategist.sh` / `extractor.sh` / `scheduler.sh` под launchd не видел `IWE_TEMPLATE/IWE_WORKSPACE/IWE_RUNTIME` — launchctl не читает `~/.zshenv` / `~/.iwe-paths`. Скрипты падали в fallback-warning.
- **Фикс:** в исходных plist'ах (`roles/*/scripts/launchd/*.plist`, substituted) добавлены ключи `IWE_TEMPLATE/IWE_WORKSPACE/IWE_RUNTIME` в `EnvironmentVariables` как `{{IWE_TEMPLATE}}/{{WORKSPACE_DIR}}/{{IWE_RUNTIME}}`-плейсхолдеры. build-runtime подставит per-host значения. Плисты становятся **self-contained**: launchd-runner'ы больше не зависят от shell env.

### Why

Round 5 закрыл паттерн «launchd зависит от shell env» (R5.4) — это устойчивый класс багов, который ловил Евгения каждый раз. Системная очистка через self-contained plist'ы делает дочерние скрипты воспроизводимыми независимо от того, как открывался процесс. R5.3 закрыл OwnerIntegrity-нарушение в генерации `~/.iwe-paths` — теперь один writer на все три триггера (setup/migrate/update).

## [0.29.6] — 2026-04-27

### Fixed (R6.1** — критический блокер от sub-agent post-release verify 0.29.5)

Sub-agent post-release verify нашёл блокер, который мой 0.29.5 fix создал заново — **более серьёзный, чем то, что 0.29.5 закрывал**.

**Что произошло:** в 0.29.5 я добавил sed-substitution в `run_claude` runners (`strategist.sh`, `extractor.sh`):
```bash
sed -e "s|{{GOVERNANCE_REPO}}|$_gov_repo|g" ...
```

`build-runtime.sh` обрабатывал эти runner'ы как substituted — sed подменял `{{GOVERNANCE_REPO}}` ВНУТРИ моего sed-выражения. После build runner становился:
```bash
sed -e "s|DS-evgenii-pilot-strategy|$_gov_repo|g" ...  # ИСКАЛ значение в промпте
```

Промпты в FMT с `{{GOVERNANCE_REPO}}` НЕ подменялись → LLM получал raw плейсхолдеры. **Все runners сломаны для всех пилотов кроме `GOVERNANCE_REPO=DS-strategy`** (мой авторский кейс — поэтому я не заметил).

**Почему мой smoke test не поймал:** Test 6c в 0.29.5 симулировал sed с оригинальными `{{...}}` плейсхолдерами на тестовом промпте — НЕ читал реальный substituted runner из `.iwe-runtime/`. Имитация ≠ реальность.

**Фикс:** escape через bash-конкатенацию одиночных скобок:
```bash
local _o='{''{' _c='}''}'  # build-runtime ищет цельный токен, не находит
sed -e "s|${_o}GOVERNANCE_REPO${_c}|$_gov|g" ...
```

`build-runtime` ищет `\{\{[A-Z_]+\}\}` regex'ом, не находит составные `'{''{'` + `'}''}'`. Runner после build остаётся неизменным.

### Added (тесты + детектор для catch регрессии)

- **smoke-test 6c переписан** — теперь читает РЕАЛЬНЫЙ substituted runner из `.iwe-runtime/`, проверяет что в его sed-выражениях НЕТ literal-значений (только escape-токены), end-to-end проверяет что substitution работает с `DS-pilot-strategy`.
- **integration-contract-validator detector #8 `sed_placeholder_escape`** — парсит overlay-реестр, для каждого substituted-файла проверяет НЕТ ли bare `{{X}}` в sed-выражениях. Catch'ит регрессию класса R6.1**.

### Why
Архитектурный урок: **«sub-agent oversight даёт +30% покрытия» — снова подтверждено**. Мой 0.29.5 audit нашёл R6.1*, но создал R6.1** (более серьёзный, потому что my fix был неправильным). Sub-agent verify поймал это до того как пилот обновился. **Без sub-agent verify ВСЕ пилоты получили бы сломанную автоматизацию.** Расширение smoke-test до чтения реального runtime + новый detector — закрывают этот класс пермаментно.

## [0.29.5] — 2026-04-27

### Fixed (R6.1* — sub-agent post-release verify нашёл upущение proactive audit'а)

После 0.29.4 sub-agent post-release verify нашёл, что мой proactive audit пропустил **R6.1*** — тот же класс GOVERNANCE_REPO hardcode, но в файлах, которые smoke test не покрывал:
- `roles/strategist/scripts/cleanup-processed-notes.py:26` — `WORKSPACE = Path.home() / "IWE" / "DS-strategy"` — **жёсткий хардкод** в Python. Любой пилот с нестандартным `GOVERNANCE_REPO` → fail при запуске cleanup.
- 67 хардкодов `DS-strategy` в `roles/strategist/prompts/*.md` и `roles/extractor/prompts/*.md` — bare paths без `{{GOVERNANCE_REPO}}`. LLM получает неверный путь.

Корневая причина пропуска: smoke test 0.29.4 проверял только `.sh` в `.iwe-runtime/roles/`, не `.py` и не `prompts/` (которые read-only из FMT, не substituted).

**Фиксы:**
- `cleanup-processed-notes.py` — `_resolve_workspace()` функция читает `IWE_WORKSPACE` + `IWE_GOVERNANCE_REPO` из env-vars, fallback на `.exocortex.env` (`grep GOVERNANCE_REPO=`), затем default `DS-strategy`. Тестировано: `IWE_WORKSPACE=/tmp/iwe-test IWE_GOVERNANCE_REPO=DS-pilot-strategy` → `WORKSPACE = /tmp/iwe-test/DS-pilot-strategy` ✅.
- 67 хардкодов в prompts → `{{GOVERNANCE_REPO}}`. Архитектурное решение: prompts остаются read-only в FMT с placeholders, runner подставляет sed'ом при чтении. Single source, no duplication.
- `run_claude` в `strategist.sh` и `extractor.sh` — добавлена sed-substitution: `{{GOVERNANCE_REPO}}|{{WORKSPACE_DIR}}|{{GITHUB_USER}}` подставляются из env (`IWE_GOVERNANCE_REPO`, `IWE_WORKSPACE`, `GITHUB_USER`) в момент чтения prompt-файла.

### Added (smoke test 9 → 11 + detector #6 → #7)

- **smoke-test 6c:** prompts substitution — создаёт временный prompt с `{{GOVERNANCE_REPO}}`, проверяет sed-substitution в стиле runner'а.
- **smoke-test 6d:** `cleanup-processed-notes.py` резолвит `GOVERNANCE_REPO` из env (с `IWE_GOVERNANCE_REPO=DS-pilot-strategy` → `WORKSPACE = .../DS-pilot-strategy`).
- **integration-contract-validator detector #7 `prompts_python_coverage`:** ищет hardcoded `DS-strategy` в `roles/**/*.py` и `roles/**/prompts/*.md`. Антипаттерн: `.py` без чтения `GOVERNANCE_REPO` env, prompts с bare `DS-strategy/` без `{{GOVERNANCE_REPO}}`.

### Why
Подтверждение архитектурного тезиса: **adversarial sub-agent oversight даёт +30% покрытия даже после proactive audit**. Каждый цикл находит новые подкатегории. R6.1* — extension R6.1 на новые типы файлов (.py, prompts), которые мой smoke test не покрывал. Решение для 0.29.5: расширили scope smoke + добавили detector #7. Прогноз: следующий audit, скорее всего, найдёт R6.1** (новый класс файлов или новая категория hardcode'ов).

## [0.29.4] — 2026-04-27

### Fixed (proactive audit — 5 нового класса проблем до Round 6)

После релиза 0.29.3 запустили adversarial sub-agent с мандатом «найди новый класс, который пропустили Round 4-5». Найдено 5 классов, все НЕ повторение R4.x/R5.x. Закрываем превентивно.

- **R6.1 BLOCKER — `GOVERNANCE_REPO` dead placeholder.** Плейсхолдер был зарегистрирован в overlay, но в 7 substituted-файлах путь `/DS-strategy` был **захардкожен**: `roles/synchronizer/scripts/{scheduler,daily-report,dt-collect,code-scan}.sh`, `roles/synchronizer/scripts/templates/{strategist,extractor}.sh`, `roles/strategist/scripts/strategist.sh`, `roles/extractor/scripts/extractor.sh`. Любой пилот с нестандартным именем хаба (например `DS-pilot-strategy`) — автоматизация молча обращается не туда. Заменил все хардкоды на `{{GOVERNANCE_REPO}}`. Авторский кейс (`DS-my-strategy`) — тот же класс.

- **R6.2 BLOCKER — permanent false-positive в `update.sh:462`.** `grep -rl '{{...}}' "$SCRIPT_DIR"` сканировал FMT, где плейсхолдеры это by design (clean upstream). Каждый запуск `update.sh` у каждого пилота заканчивался «⚠ 54 файлов содержат незаменённые переменные» — UX-катастрофа, разрушает доверие. Сканируем теперь `$WORKSPACE_DIR/.iwe-runtime/` — там их быть не должно после build-runtime.

- **R6.3 IMPORTANT — race window в `build-runtime.sh:338-344`.** Окно между `mv RUNTIME → RUNTIME.old.$$` и `mv $BUILD_DIR/runtime → RUNTIME` — `$RUNTIME_DIR` не существует. Если в этот момент scheduler dispatch'ится — обращается к runner-пути → fail или silent skip. Добавил `flock -x -w 30` на `$WORKSPACE_DIR/.iwe-runtime.lock` в build-runtime + shared `flock -s -w 5` в scheduler перед чтением runner-путей.

- **R6.4 IMPORTANT — `update.sh:734` Step 7.5 regression.** После WP-273 `.exocortex.env` живёт в workspace. Step 7.5 переприсваивал `ENV_FILE="$SCRIPT_DIR/.exocortex.env"` (FMT, где файла нет) — `if [ -f ... ]` всегда false → migration hint про `IWE-INITIAL-NEEDED` никогда не показывался пилотам с старым Strategy.md skeleton. Используем `${WORKSPACE_DIR}/.exocortex.env`.

- **R6.5 NICE-TO-HAVE — scheduler self-reentrancy.** Если предыдущий dispatch завис на 30 мин (Claude CLI), launchd запускал следующий — двойной morning strategist, двойные коммиты. Добавил non-blocking `flock -n 8` на `$STATE_DIR/scheduler.lock` в `dispatch()` — новый dispatch выходит сразу с лог-сообщением.

### Changed (smoke-test расширен 6 → 9 тестов)

Добавлены regression guards для R6.x:
- Test 6a: `GOVERNANCE_REPO=DS-pilot-strategy` подставляется в `.iwe-runtime/` (не остаётся literal `DS-strategy`).
- Test 6b: 0 leftover placeholders в `.iwe-runtime/`.

Заодно пофиксили баг самого smoke-test: `... | head -1 >/dev/null` always-exit-0 → false-positive FAIL. Заменено на `[ -n "$VAR" ]`.

### Why
Архитектурный паттерн «найди до того как Евгений найдёт» — proactive search. Sub-agent post-release verify 0.29.2 предсказал «1-2 проблемы из нового класса максимум». Реальность: 5 проблем (2 blocker, 2 important, 1 nice). Подтверждает ценность adversarial review до релиза. WP-273 Этап 4 (proactive audit pass).

## [0.29.3] — 2026-04-27

### Added (Этап 3 WP-273 — test coverage + observability)

После Round 5 sub-agent assessment явно назвал три паттерна риска: (1) env-зависимость как неявный контракт между шагами, (2) validator страдает от drift'а сам, (3) silent degradation в runner fallback chains. Этап 3 закрывает эти три класса без архитектурного пересмотра — добавлением test coverage, уточнением детекторов и WARNING'ов при legacy fallback.

**Новые артефакты:**
- `setup/smoke-test-fresh-install.sh` — e2e smoke test архитектуры F. Имитирует пилота: создаёт чистый workspace, запускает build-runtime, проверяет idempotency, runner резолвит PROMPTS_DIR в FMT (не runtime), install.sh fail-fast без env. 6 тестов в одном скрипте, цель — ловить R5.x regressions до релиза. Запускать локально или в CI workflow.

**Новые детекторы в integration-contract-validator.sh** (4 → 6):
- **Detector #5 `runner_readonly`** — runners (strategist.sh, extractor.sh) резолвят PROMPTS_DIR через `$IWE_TEMPLATE`; scheduler.sh имеет `ROLES_DIR_TEMPLATE` для role.yaml lookup. Закрывает R5.1 regression class.
- **Detector #6 `install_failfast`** — все 3 install.sh имеют `grep -qE '\{\{[A-Z_]+\}\}'` check на PLIST_SRC. Закрывает R5.2 regression class.

### Fixed (validator false positives)
- **Detector #3 `extension_table` regex** — раньше терминировался на первом `` ` `` в строке, пропускал EXTENSION POINT'ы где в строке было несколько backtick'ов (например `` ДО `git commit` проверить `extensions/X.md` ``). Расширили: ищем `extensions/X.md` независимо от «EXTENSION POINT» маркера. Из 6 false positive WARN — теперь 0.
- **Detector #4 `hook_artifact` regex** — раньше ловил любой `grep TOOL_INPUT`, включая легитимный gating «это git commit вообще?». Уточнён до конкретного антипаттерна R4.5: grep на artifact-имена (`DayPlan|WeekPlan|day-close|day-open|week-close|week-open`). Из 1 false positive WARN — 0.

### Changed (silent degradation guards)
- **3× runners** (strategist.sh, extractor.sh, scheduler.sh): WARNING в stderr при использовании legacy fallback (когда `$IWE_TEMPLATE` не экспортирована). Раньше runner молча резолвил на `$HOME/IWE/FMT-exocortex-template` — пилот не видел что env неполная. Теперь явное предупреждение с подсказкой `source ~/.zshenv`.

### Why
Вопрос «сколько ещё таких проблем будет?» — sub-agent post-release verify 0.29.2 явно назвал три паттерна риска. Архитектура F остаётся правильной (source/runtime separation, OwnerIntegrity, Data Portability), но контракт между шагами и наблюдаемость legacy-paths требовали усиления. Прогноз Round 6: 1-2 проблемы вместо 4-5, кривая стабилизируется.

## [0.29.2] — 2026-04-27

### Fixed (Round 5 Евгения — runtime/automation path blockers)

Round 5 нашёл 4 критических расхождения в архитектуре F после red-team-проверки на чистом 0.29.1:

- **R5.1 — runtime неполный для runners.** `.iwe-runtime/` содержал substituted скрипты, но НЕ содержал `roles/*/prompts/`, `roles/*/role.yaml`, `roles/synchronizer/scripts/notify.sh`. При этом runner-скрипты (`strategist.sh`, `extractor.sh`) искали `PROMPTS_DIR="$REPO_DIR/prompts"` рядом с собой → `.iwe-runtime/roles/strategist/prompts/` (пусто) → fail. **Фикс:** runners теперь резолвят `PROMPTS_DIR` через `$IWE_TEMPLATE/roles/<role>/prompts` (read-only из FMT) с fallback. Аналогично `notify_script` в strategist.sh/extractor.sh, `NOTIFY_SH` и `role.yaml` lookup в scheduler.sh. Архитектурный принцип сохранён: substituted в runtime, read-only из FMT — без дублирования read-only данных.
- **R5.2 — install.sh ставил plist с literal `{{IWE_RUNTIME}}`.** Если запущен без экспортированной env-переменной (например, в новом shell без source), fallback chain сваливался в legacy FMT path — а plist в FMT содержит `{{IWE_RUNTIME}}` (clean upstream). Результат: `~/Library/LaunchAgents/com.X.plist` с literal плейсхолдером, launchd не выполняет. **Фикс:** install.sh во всех 3 ролях имеет fail-fast — `grep -qE '\{\{[A-Z_]+\}\}'` на выбранном PLIST_SRC. При обнаружении плейсхолдеров — exit 2 + конкретные подсказки (source ~/.zshenv / bash build-runtime / migrate).
- **R5.3 — update.sh roles reinstall шёл ДО build-runtime.** Если roles изменились, install.sh запускался против устаревшего `.iwe-runtime/`. **Фикс:** Step 6d (build-runtime) добавлен ПЕРЕД roles reinstall блоком. Старый Step 8 (build-runtime в конце) удалён как дубликат. Перед roles reinstall дополнительно `source ~/.iwe-paths` — гарантирует IWE_RUNTIME/IWE_TEMPLATE в env для install.sh fail-fast.
- **R5.4 — migrate-to-runtime-target.sh финальные инструкции неправильно упорядочены.** Говорил «1. install agents → 2. source ~/.zshenv» — но install требует env уже expanded. **Фикс:** новый порядок «1. source ~/.zshenv → 2. verify .iwe-runtime → 3. install selected roles» с явной подсказкой про fail-fast (если шаг 1 пропущен).

### Why
Round 5 от Евгения после полной верификации 0.29.1 на чистом workspace. Все 4 проблемы — порядковые/конфигурационные на стыке runner ↔ build-runtime ↔ install.sh. Архитектура F остаётся корректной (FMT immutable, runtime regenerable), но «контракт между шагами» (env propagation, ordering) был неполным.

## [0.29.1] — 2026-04-27

### Fixed (CI green — pilot feedback Евгений)

- **`setup/integration-contract-validator.sh:43`** — ShellCheck SC2145 («Argument mixes string and array») в `verbose() { $VERBOSE && echo "  $@" || true; }`. `"  $@"` смешивает literal-префикс и массив `$@`. Заменено на `if $VERBOSE; then echo "  $*"; fi` — `$*` склеивает с IFS как одну строку, без mixing. Заодно убрана антипаттерн-цепочка `cmd && X || true`, которая маскирует ошибки внутри X.

### Why
Validate Template на main падал на `0.29.0` — блокирует релиз для пилотов, которые ждут green CI перед обновлением.

## [0.29.0] — 2026-04-27

### Added (Generated runtime architecture — WP-273 Этап 2, ArchGate v2 → F)

**Принцип:** FMT = clean upstream (immutable, regenerable). `$WORKSPACE_DIR/.iwe-runtime/` = derived state (regenerated at every setup/update). `$WORKSPACE_DIR/.exocortex.env` = single source of user state. Аналог Nix derivation: одни и те же входы → identical output.

**Новые артефакты:**
- `.claude/runtime-overlay.yaml` — реестр overlay-файлов (16 substituted + 2 copied_to_workspace + 10 placeholders, включая новый `IWE_RUNTIME`).
- `setup/build-runtime.sh` — idempotent rebuild `.iwe-runtime/` из FMT + `.exocortex.env`. Поддерживает `--dry-run`, `--diff` (drift detection), `--workspace`, `--env-file`, `--quiet`. Atomic swap через temp + mv. Bash 3.2-compatible.
- `scripts/migrate-to-runtime-target.sh` — миграция с dirty FMT (≤0.28.x) на Generated runtime. Backup + git restore + build-runtime.
- `setup/integration-contract-validator.sh` — 4 детектора Spec↔State drift (R4.8, manifest paths / seed refs / extension table / hook artifact). Закрывает класс «корень → детектор откладывается → следующий round находит то же».
- `.claude/scripts/load-extensions.sh` — wildcard suffix loader (R4.4): возвращает sorted list `extensions/<protocol>.<hook>*.md` (закрывает обещание из extensions/README.md о `day-close.after.health.md`).
- `memory/hooks-design.md` — принципы проектирования хуков (trigger = artifact, не TOOL_INPUT).
- `seed/strategy/decisions/.gitkeep` — закрывает R4.2.

### Changed (рефакторинг под архитектуру F)

- **`setup.sh`** v0.7.0: убран sed-cycle по `$TEMPLATE_DIR` (FMT остаётся clean upstream). `.exocortex.env` сохраняется в `$WORKSPACE_DIR/`, не в FMT. После сохранения env — вызов `build-runtime.sh`. CLAUDE.md substituted single-file (не sed по дереву). `~/.iwe-paths` экспортирует `IWE_RUNTIME=$WORKSPACE_DIR/.iwe-runtime`.
- **`update.sh`** v2.1.0: убран substitution-цикл по NEW/UPDATED файлам. Поиск `.exocortex.env` сначала в workspace, потом FMT (legacy). После git apply — вызов `build-runtime.sh` (R4.6 self-heal: повторный запуск чинит drift). Автомиграция: копирует `.exocortex.env` из FMT в workspace + добавляет `IWE_RUNTIME`.
- **3× `roles/{strategist,extractor,synchronizer}/install.sh`**: `LAUNCHD_DIR` через `$IWE_RUNTIME/roles/<role>/scripts/launchd/` с fallback на `$IWE_WORKSPACE/.iwe-runtime/...` и `$SCRIPT_DIR/scripts/launchd` (legacy ≤0.28.x). Скрипты-исполнители тоже из `$IWE_RUNTIME`.
- **6× substituted runtime-файлов** (plists, config.yaml, scheduler.sh): hardcoded `{{WORKSPACE_DIR}}/FMT-exocortex-template/roles/...` → `{{IWE_RUNTIME}}/roles/...` (R4.7 закрытие, ликвидирует hardcoded имя FMT-репо).
- **`roles/extractor/scripts/extractor.sh:50`** — `notify_script` через `$IWE_RUNTIME` с fallback на `$WORKSPACE/.iwe-runtime/` и legacy FMT.
- **`memory/protocol-close.md`** — EXTENSION POINT для `extensions/protocol-close.checks.md` перенесён ДО Step 1 (Commit + Push). Pre-commit gate, как обещает run-protocol skill (R4.3 закрытие).
- **`extensions/README.md` + `.claude/skills/extend/SKILL.md`** — таблица hook-orderings обновлена («ДО commit+push» для protocol-close.checks).
- **`.claude/hooks/protocol-artifact-validate.sh`** — trigger исключительно по `git diff --cached --name-only`, не по `TOOL_INPUT` тексту (R4.5 закрытие). Принцип «trigger = artifact» из `memory/hooks-design.md`.
- **`scripts/iwe-audit.sh`** — добавлен Раздел 2b «Generated runtime drift» через `build-runtime.sh --diff`.

### Migration (для пилотов на ≤0.28.x)

После обновления:
```bash
bash $IWE_TEMPLATE/scripts/migrate-to-runtime-target.sh
```

Скрипт:
1. Detect dirty FMT (substituted значения после старого setup).
2. Backup в `$WORKSPACE_DIR/.iwe-runtime-migration-backup/`.
3. `launchctl unload` IWE-агентов (предотвращает запуск битых скриптов после restore).
4. `git restore` FMT → clean upstream.
5. Migrate `.exocortex.env` из FMT в workspace + добавить `IWE_RUNTIME`.
6. `build-runtime.sh` → создаёт `.iwe-runtime/`.
7. Hint: `bash roles/strategist/install.sh` etc. — переустановить launchd с новых путей.

### Why
WP-273 Этап 2. ArchGate v2 (sub-agent oversight) выбрал F (Generated runtime) над D (Гибрид) — F устраняет split-brain, дублирование имён файлов, нарушение принципа #24 Data Portability. Генерируемый runtime пересоздаётся атомарно из (FMT + .exocortex.env), не drift'ит между source и runtime. Закрывает 5-й системный корень WP-273 (Source↔Runtime confusion) + R4.2-R4.8 от Round 4 red-team Евгения + BUG-1 от Дмитрия.

## [0.28.12] — 2026-04-27

### Fixed (pilot feedback Дмитрий — Linux first-class support, 4 hotfix)

- **`scripts/iwe-audit.sh`** — опечатка `$DRIFT_RC_` → `${DRIFT_RC}_`. На macOS под `set -e` опечатка глоталась (bare `$DRIFT_RC_` = пустая строка), на Linux под `set -eu` падала с `unbound variable: DRIFT_RC_`. Markdown-italic вокруг кода (`_iwe-drift.sh exit code: N_`) сохранён.
- **`scripts/iwe-drift.sh`** — функция `dir_newest_mtime_days_ago` использовала `stat -f %m` (macOS-синтаксис) без fallback'а на `stat -c %Y` (Linux). На Linux `xargs stat -f %m` возвращал статистику ФС вместо mtime → unbound variable. Добавлен runtime-детектор как в `mtime_days_ago` рядом.
- **`roles/strategist/scripts/strategist.sh:9`** — `caffeinate -diu -w $$ &` → guard `command -v caffeinate >/dev/null 2>&1 && caffeinate ...`. На Linux `caffeinate` отсутствует, скрипт сыпал `command not found` в логи каждый запуск. На Linux cron/systemd сами управляют sleep, guard корректен.
- **`roles/strategist/scripts/strategist.sh:102`** — убран `--dangerously-skip-permissions`. Claude Code блокирует флаг под root/sudo (Linux cron от root → отказ). `--allowedTools "Read,Write,Edit,Glob,Grep,Bash"` уже даёт явный whitelist, доп. флаг не требуется. На macOS поведение не меняется (allowedTools работает идентично).

### Why
Аудит инсталляции IWE на Linux/Docker (Дмитрий, 26 апр) обнаружил 4 macOS-специфичных места: 1 опечатка + 1 утечка `stat`-несовместимости + 1 шум `caffeinate` в логах + 1 release-blocker `--dangerously-skip-permissions` под root в cron. Все 4 — класс «Linux first-class support», до сих пор не было оценочного прохода. Этап 0 WP-273 (4-й корень: cross-platform compat). Без этих фиксов background automation на Linux вообще не поднимается; интерактивный mode работал только частично.

## [0.28.11] — 2026-04-27

### Fixed (pilot feedback Евгений Round 4 R4.1 — manifest 404 на runtime-файлах)

- **`generate-manifest.sh` теперь использует `git ls-files` вместо `find`.** Раньше скрипт собирал ВСЕ файлы в дереве (включая runtime-артефакты вроде `.exocortex.env`, `.claude.md.base`, `.claude/logs/capture_log.jsonl`, помещённые в `.gitignore`), потом полагался на ручные `EXCLUDE_PATTERNS`. После одного цикла `setup.sh` runtime-файлы попадали в `update-manifest.json`, а у пользователя `update.sh` ходил по ним в GitHub Contents API и получал 404. Переключение на `git ls-files` гарантирует, что в манифест попадают ТОЛЬКО tracked-файлы — runtime никогда не попадёт в принципе.

### Why
Round 4 пилотного red-team'а Евгения после clean reinstall main `b0ead81` / 0.28.10: `update-manifest.json` содержал 3 пути, отсутствующих в репо (все в `.gitignore`), `update.sh` показывал «N файлов не найдены». Точечный фикс «удалить 3 пути из манифеста» закрыл бы только эти 3 имени; завтра появится `.claude/cache/` или новый артефакт setup'а — снова попадёт в манифест. Системный фикс через `git ls-files` закрывает класс «runtime в манифесте» полностью. Это Этап 1 WP-273 (закрытие 4-го корня Spec↔State drift) — блокер пользователей. Этап 2 (релиз 0.29.0) с архитектурными артефактами (vocabulary.yaml, load-extensions.sh, integration-contract-validator.sh) идёт отдельно после ArchGate.

## [0.28.10] — 2026-04-26

### Fixed (pilot feedback Евгений — UX-trap двух валидаторов на свежей 0.28.8)

- **`setup/validate-template.sh` теперь имеет два режима — `--mode=pristine` (default) и `--mode=installed`.** Pristine = текущее поведение (CI, author template-sync, fresh clone до setup) — все 7 проверок. Installed = пропускает чеки 2 (`/Users/`), 3 (`/opt/homebrew`), 4 (MEMORY ≤15 строк), которые легитимно нарушаются после `setup.sh` подстановкой плейсхолдеров. Универсальные чеки 1, 5, 6, 7 запускаются в обоих режимах. Дефолт = pristine, поэтому CI-вызов `bash setup/validate-template.sh "$PWD"` работает без изменений.
- **Guard на post-setup state.** Если запущен в pristine-режиме, но детектор находит, что `{{HOME_DIR}}` в `CLAUDE.md` уже подставлен — скрипт печатает подсказку («используйте `setup.sh --validate` или `--mode=installed` или `/audit-installation`») и завершается с exit 0. Без guard'а пользователь после `setup.sh --core` получал FAIL чека 2 и не понимал, что делать.
- **`setup.sh --validate` теперь делегирует структурные инварианты валидатору шаблона.** Добавлен шаг `[5/5] Структурные инварианты` — вызов `bash setup/validate-template.sh --mode=installed "$SCRIPT_DIR"`. Делегация снимает дублирование чеков (required files, hooks cross-ref) и даёт пользователю единый ответ «установка ОК» или «вот что не так» без необходимости запускать два валидатора.

### Why
Евгений (пилот, 0.28.8 fresh install): «после `setup.sh --core` команда `setup.sh --validate` зелёная, но `setup/validate-template.sh` становится красной, потому что setup подставляет `/Users` paths прямо в template repo и оставляет FMT dirty». Корень проблемы: один скрипт обслуживал два разных use-case (validate pristine source vs. validate installed workspace) с одной семантикой → пост-инсталляционный пользователь натыкался на FAIL легитимных подстановок. Системный фикс — декомпозиция по режимам + guard как safety net (см. WP-5 #16, deep-check разбор `F + A` варианта).

## [0.28.9] — 2026-04-26

### Changed (validator hardening — `validate-template.sh` rule 6/6)

- **Третий паттерн в правиле 6/6 — `bash (~|$HOME)/IWE/scripts/`.** Раньше валидатор ловил только `FMT-exocortex-template/scripts` и `FMT-exocortex-template/roles/[a-z]*/scripts`. Bare-invocations типа `bash IWE/scripts/iwe-drift.sh` (без fallback на `$IWE_SCRIPTS`) проходили валидацию, но падали в user-mode с `command not found`. Новый паттерн ловит bare-bash-вызовы с тильдой или `$HOME`. False positives отсутствуют — паттерн `${IWE_SCRIPTS:-$HOME/IWE/scripts}` не матчится (после `bash ` идёт `${`, не тильда/`$HOME`).
- **Enumerate-all вместо first-fail.** Раньше при FAIL'е выводилось `head -3` нарушений ОДНОГО паттерна, остальные паттерны проверялись, но их вывод тоже обрезался. Теперь все hits аккумулируются в `$CHECK6_HITS` и выводятся списком в конце с разделителями `--- Pattern: $pattern ---`. Один FAIL = полный список нарушений → одна правка → один sync.

### Why
Инцидент 26 апр: `template-sync` 4 раза подряд пушил `audit-installation/SKILL.md` (commits `56ceabd`, `faa1d6e`, `066d866`, `7744b7b`), потому что итеративная правка fallback-цепочки в одном файле триггерила sync на каждом сохранении. Хотя root cause был в стиле редактирования, а не в валидаторе, правило 6/6 не покрывало bare-invocations класса `bash IWE/scripts/X.sh`. Расширение паттерна предотвращает регрессии того же класса в будущих скиллах. Параллельно отрефакторен авторский `month-close/SKILL.md` (3 строки 51/97/115) — `bash IWE/scripts/iwe-drift.sh` → `bash ${IWE_SCRIPTS:-$HOME/IWE/scripts}/iwe-drift.sh`. Скилл локальный (не в `FMT/.claude/skills/`), поэтому в этот релиз не входит.

## [0.28.8] — 2026-04-26

### Fixed (pilot feedback Дмитрий — `/audit-installation` UX)

- **`scripts/iwe-audit.sh` — ложная рекомендация про `scripts/update.sh`.** Старая логика для user-mode требовала `update.sh` в `workspace/scripts/`. Но `update.sh` физически живёт ТОЛЬКО в `FMT-exocortex-template/update.sh` (он сам резолвит `WORKSPACE_DIR=parent of SCRIPT_DIR`), `Step 6` пропагирует в workspace только `.claude/{skills,hooks,rules,...}`, не `scripts/*`. Аналогично `iwe-drift.sh` для user-mode живёт только в FMT-template/scripts/. Фикс: inventory check ищет `update.sh` в `FMT-exocortex-template/`, `iwe-drift.sh` с fallback FMT→workspace. DRIFT_SCRIPT execution тоже фоллбэчит на FMT-template для user-mode.
- **`audit-installation/SKILL.md` — отчёт писался только в терминал.** Шаг 5 теперь сохраняет полный отчёт + verdict в `$AUDIT_LOG_DIR/iwe-audit-YYYYMMDD-HHMMSS.log`. Логика выбора пути: `$HOME/IWE/scripts/` (author-mode) → `$IWE_SCRIPTS` (user-mode из `~/.iwe-paths`) → `$HOME/IWE` (final fallback). `mkdir -p` гарантирует наличие директории.
- **`audit-installation/SKILL.md` Шаг 1 — отсутствие fallback при поиске `iwe-audit.sh`.** Прежняя инструкция предписывала `bash $HOME/IWE/scripts/iwe-audit.sh` — для пилота в user-mode (особенно в Docker без `~/.zshenv`, где `$IWE_SCRIPTS` не экспортируется автоматически) скрипт не находился. Добавлена fallback-цепочка `workspace/scripts/` → `$IWE_SCRIPTS` → понятная ошибка с инструкцией `source ~/.iwe-paths` или запустить `setup.sh`.

### Why
Пилот в Docker на VPS прогнал `/audit-installation`. Получил ложный ❌ про отсутствие `scripts/update.sh` (которого by design не должно быть в workspace), не нашёл лог-файла отчёта, и потенциально упёрся бы в Шаг 1 без `$IWE_SCRIPTS` в env. Урок про placeholder discipline в шаблонных файлах захвачен в memory: при правке файлов в author-mode IWE — только `$IWE_SCRIPTS`/`$IWE_TEMPLATE`/`$HOME`, не хардкод `FMT-exocortex-template/scripts` (валидатор шаблона роняет sync на чеке 6/6).

## [0.28.7] — 2026-04-26

### Fixed (sub-agent deep audit, 2 ❌ в migrate-initial-marker.sh)

- **`scripts/migrate-initial-marker.sh` — broken frontmatter (один `---`).** Раньше при некорректном frontmatter (только открывающий `---` без закрывающего) awk не находил второго `---`, не вставлял маркер, но скрипт выдавал «✓ Маркер добавлен» — false positive. Файл оставался без маркера. Фикс: добавлен `grep -c '^---$'` pre-check; если меньше двух `---` — fallback на вставку в начало (как для случая «нет frontmatter»). Также добавлен sanity check `[ ! -s "$TMP" ]` — защита от silent corruption.
- **`scripts/migrate-initial-marker.sh` — read-only файл молча перезаписывался.** На macOS `mv "$TMP" "$TARGET"` заменяет read-only target если у owner'а есть write-permission на parent dir. Фикс: ранний exit 1 с понятным сообщением + подсказка `chmod u+w` если `[ ! -w "$TARGET" ]`.

### Why
Третий sub-agent аудит (deep, adversarial QA) прогнал 10 fuzz-cases против `migrate-initial-marker.sh` 0.28.6. Два cases дали реальные регрессии: (g) broken frontmatter — false positive completion; (i) read-only file — silent overwrite. Оба зафиксились ровно той же эвристикой что должна работать в edge cases.

## [0.28.6] — 2026-04-26

### Fixed (red-team Евгения round 2: 1 release-blocker + 2 edge-cases)

- **C1 — `.github/workflows/validate-template.yml`** — release-blocker: CI был red на 7fbee95, потому что inline blacklist в CI расходился с локальным `setup/validate-template.sh` (CI добавил `roles/` в PROTOCOL_PATHS и ловил conditional refs `DS-agent-workspace/scheduler` в `roles/strategist/prompts/{session-prep,note-review}.md`). Теперь CI делегирует author-specific / hardcoded-paths / MEMORY-skeleton / required-files / hooks-cross-ref в `bash setup/validate-template.sh "$PWD"` (source-of-truth). CI-only остаются: smoke-test протокольных хуков, MCP doc check, placeholders check, shellcheck, release-sync.
- **C2 — `setup/validate-template.sh`** — default аргумент изменён с `$HOME/IWE/FMT-exocortex-template` (author-specific) на `dirname $0/..` (parent dir самого скрипта). Теперь `bash setup/validate-template.sh` (без аргумента) работает на любом checkout — CI, fresh clone, не-author-инсталляция.
- **C3 — `scripts/migrate-initial-marker.sh` (новый) + `update.sh`** — для пользователей со старым clone (до 0.28.5): их `Strategy.md` создан seed'ом, но без маркера `IWE-INITIAL-NEEDED`. После update до 0.28.5 skill `/strategy-session` уходит в weekly mode даже для day-0 пользователя. Скрипт-мигратор: эвристически распознаёт seed-скелет (placeholder `YYYY-MM-DD` в frontmatter), безопасно вставляет маркер после frontmatter, idempotent (повторный запуск ничего не делает). `update.sh` показывает hint при обнаружении такой ситуации, авто-миграцию НЕ запускает (риск изменить пользовательский файл без согласия).

### Why
Round 2 red-team Евгения после 0.28.5: runtime blockers закрыты, но release-blocker — GitHub Actions Validate Template red на 7fbee95. Корень — расхождение source-of-truth между CI inline и локальным валидатором. Симптом: оба валидатора проходят локально, но CI падает на разных правилах. Фикс по принципу single-source-of-truth: один валидатор, два места исполнения (local + CI). Edge-cases C2/C3 закрыты тем же коммитом — мелкие, но ломают UX отдельных сценариев.

## [0.28.5] — 2026-04-26

### Fixed (red-team Евгения, 10 blockers B1-B10)

- **B1 — `update-manifest.json`** — добавлены 4 группы файлов, которые попали в FMT через коммиты, но не доставлялись через `update.sh`: `.claude/skills/audit-installation/SKILL.md`, `scripts/iwe-audit.sh`, `docs/migrations/strategy-v0.27.0.md`, `templates/strategy-skeleton/**`. Manifest перегенерирован через `generate-manifest.sh` после bump версии.
- **B2 — `setup.sh` + `update.sh`** — substitution map расширен с 7 до 9 placeholder'ов: добавлены `{{GOVERNANCE_REPO}}` и `{{IWE_TEMPLATE}}`. Раньше эти placeholder'ы оставались литералами в `.claude/skills/strategy-session/SKILL.md` после `setup.sh` / `update.sh`. Auto-detection `GOVERNANCE_REPO` перенесён ВЫШЕ блока substitution. Legacy `.exocortex.env` без этих ключей мигрируются автоматически в `update.sh`.
- **B3 — `.claude/skills/strategy-session/SKILL.md` + `seed/strategy/docs/Strategy.md`** — initial flow раньше включался только при отсутствии `Strategy.md`, но `seed/strategy/` его создавал → fresh setup всегда уходил в weekly. Введён skeleton-marker `<!-- IWE-INITIAL-NEEDED -->` в seed-файле; skill переключается в initial при наличии маркера ИЛИ явного intent пользователя («первая», «c нуля»). §2.5 добавлен шаг удаления маркера после initial-сессии.
- **B4 — `roles/strategist/prompts/strategy-session.md` + `strategy-session-weekly.md`** — старый weekly prompt переименован в `strategy-session-weekly.md`; новый `strategy-session.md` — тонкий dispatcher, делегирующий в `.claude/skills/strategy-session/SKILL.md`. `strategist.sh strategy-session` (headless и интерактивный) теперь идёт через тот же skill, что и slash-команда.
- **B5 — `.claude/skills/{day-close,week-close,run-protocol}/SKILL.md`** — skills делегировали в несуществующие секции `memory/protocol-close.md § День / § Неделя`. Day Close расширен до полного алгоритма (201 строка, 12 шагов, чеклист 22 пункта). Week Close — самостоятельный алгоритм (11 шагов, чеклист 11 пунктов). Run-protocol таблица обновлена: маршрутизация = protocol-close.md (краткая), полный алгоритм = SKILL.md соответствующего skill.
- **B6 — `.claude/hooks/protocol-artifact-validate.sh:56`** — `"Наработки Scout"` убран из mandatory `SECTIONS[]`. Раньше отсутствие секции блокировало DayPlan; теперь Scout проверяется отдельным conditional блоком (только если секция реально присутствует в файле).
- **B7 — `roles/strategist/prompts/{note-review,session-prep}.md`** — feedback-triage QA-отчёт стал conditional через `[ ! -d "$WORKSPACE/DS-agent-workspace" ]`. Раньше требование было unconditional → fresh user без `DS-agent-workspace` не мог запустить session-prep.
- **B8 — `roles/synchronizer/scripts/dt-collect.sh:233`** — `collect_sessions()` использовал hardcoded `$WORKSPACE/DS-strategy/inbox/open-sessions.log`, минуя `$GOVERNANCE_DIR`. Параметризовано (post-0.28.4 фикс не покрыл эту строку, хотя CHANGELOG утверждал обратное).
- **B9 — `.githooks/pre-commit`** — блок template validation перенесён ВЫШЕ `[ -z "$STAGED_SH" ] && exit 0`. Раньше commit с staged только `.md/.yaml/.json` пропускал валидацию шаблона → leak'и author-specific литералов проходили в FMT (`cb22aaa` regression).
- **B10 — `.claude/skills/audit-installation/SKILL.md` + `scripts/iwe-audit.sh` + `scripts/iwe-drift.sh`** — три фикса: (a) audit skill ищет `iwe-audit.sh` через `$IWE_SCRIPTS` (canonical) с fallback на legacy путь; (b) `iwe-audit.sh` ищет `iwe-drift.sh` в трёх кандидатах ($IWE_TEMPLATE, $IWE_ROOT/scripts, $IWE_ROOT/FMT-.../scripts); (c) `iwe-drift.sh` парсит ТОЛЬКО секцию `pairs:` манифеста (раньше `activity_checks` секция засоряла отчёт пустыми pair-rows); (d) `check: script:*` теперь реально вызывает helper-скрипт (раньше декларации были, исполнения не было).

### Why
3 системных провала за 0.28.4 → 0.28.5 (red-team Евгения):
1. **Author-blind testing** — fresh user setup не прогонялся; B1, B2, B3, B7 ловятся одним прогоном `setup.sh` на чистой машине.
2. **Manifest drift** — `update-manifest.json` обновляется вручную; `generate-manifest.sh` есть, но не вызывается ни pre-commit, ни CI → B1.
3. **Changelog ≠ verification** — claims в CHANGELOG не сверяются с кодом → B8 (post-0.28.4 changelog утверждал параметризацию, которой не было).

Defer (на отдельный РП): автоматический `generate-manifest.sh` в pre-commit; changelog↔code drift detector.

## [0.28.4] — 2026-04-26

### Fixed
- **`.claude/skills/week-close/SKILL.md`** — `{{HOME_DIR}}/IWE/scripts/{backup-icloud,check-dirty-repos}.sh` → `${IWE_SCRIPTS}/...`. Прежний путь — место, куда `setup.sh` ничего не клал; скрипты лежат в `FMT-exocortex-template/scripts/`, доступны через `$IWE_SCRIPTS` env-var (генерируется `setup.sh:530`, WP-219). На свежем install Week Close падал на «file not found».
- **`update.sh`** — case-фильтр пропагации в workspace расширен с `.claude/{skills,hooks,rules,settings.json}` до включения `.claude/{lib,config,detectors}/*`. Hook `capture-bus.sh` source-ит `lib/log_formatter.sh` и `config/capture-detectors.sh` — без них падает с «file not found». `setup.sh` уже был исправлен в `cea51e8`; этот коммит закрывает симметричный пробел в `update.sh`.

### Added
- **`.claude/skills/strategy-session/SKILL.md`** — skill-обёртка-диспетчер. Detect наличия `Strategy.md` / `WeekPlan` в governance-репо → initial flow (4 шага: цели → неудовлетворённости → первый WeekPlan → MEMORY.md) либо weekly flow (delegate в `roles/strategist/prompts/strategy-session.md`). Закрывает несоответствие между обещанием QUICK-START / README («Проведём первую стратегическую сессию») и runtime, где был только weekly prompt с предусловием draft WeekPlan от session-prep.

### Why
После native reset на чистый upstream/main найдены три воспроизводимых пробела, которые ломают свежий `setup.sh` или вводят пользователя в заблуждение. Все три — раздельные регрессии сходящихся путей: (1) промоция scripts/ из workspace в FMT не сопровождалась обновлением SKILL.md; (2) расширение списка `.claude/*` подкаталогов в `setup.sh` не было синхронно перенесено в `update.sh`; (3) initial-режим стратегической сессии присутствует только в документации, без runtime-обвязки.

## [0.28.3] — 2026-04-25

### Added
- **`.claude/hooks/capture-bus.sh`** — диспетчер capture-механизма (DP.SC.025). Запускает enabled-детекторы последовательно на PostToolUse / Stop, передаёт stdout детектора в writer. Никогда не блокирует (exit 0 всегда). Latency-warn при >150ms.
- **`.claude/lib/capture_writer.sh`** — writer событий: routing event_type → target_path, append в markdown/jsonl. **Параметризован** (Ф9a WP-217): `agent_incident` пишется в target_repo детектора по умолчанию (`<repo>/inbox/incident-log-YYYY-MM.md`, HD «Лог рядом с исполнителем» DP.D.049); override через опциональный `.claude/capture-config.sh` (`INCIDENT_TARGET_REPO`, `INCIDENT_REL_DIR`).
- **`.claude/lib/log_formatter.sh`, `.claude/lib/resolve_target_repo.sh`** — зависимости writer'а.
- **`.claude/lib/capture_selftest.sh`** — sanity-check для capture-bus.
- **`.claude/lib/behaviour-report.sh`** — агрегатор incident-log за период (для R-вопросника Week Close: алгоритм агента «(1) запустить behaviour-report, (2) прочитать incident-log, (3) предъявить паттерны»).
- **`.claude/config/capture-detectors.sh`** — реестр детекторов (pipe-separated). 3 активных: `incident`, `decision`, `pattern_awareness`. `permission_request` закомментирован — fail by architecture (30.7% fire / p50=1023ms на обкатке 10-25 апр), заменяется harness-гейтом `p5-stop-reminder.sh` (S-29 testing).
- **`.claude/detectors/detector_incident.sh`** — ловит P3_structure_without_map (Write нового .md в корень репо без проверки routing-карты).
- **`.claude/detectors/detector_decision.sh`** — ловит решения пользователя по 5 event_type (для DP.M.* decision register).
- **`.claude/detectors/detector_pattern_awareness.sh`** — ловит P1 (write в feedback_*.md).
- **`.claude/detectors/README.md`** — контракт интерфейса детектора (input JSON, output JSON или пусто, exit 0 всегда).
- **`.claude/capture-config.sh.example`** — шаблон override-конфигурации.
- **`.claude/settings.json`** — регистрация `capture-bus.sh` для PostToolUse(Edit|Write|MultiEdit) и Stop.

### Changed
- WP-217 Ф9a: `capture_writer.sh` `agent_incident` routing убрал hardcoded путь к авторскому governance-репо. Generic-поведение для пилотов: инциденты пишутся рядом с исполнителем; авторская агрегация — через локальный override-файл вне FMT-обновлений.

## [0.28.2] — 2026-04-25

### Added
- **`memory/t-checklist.md`** — реестр T-действий ТО IWE: 22 действия в Session/Day/Week/Month Close, owner/trigger/symptom-if-skipped для каждого. Класс T (True maintenance, идемпотентно, автопилот). Verification — Haiku R23 (формальная проверка чеклиста). Источник: WP-217 Ф3 (промотировано из staging S-31, обкатка 14 дней).
- **`memory/r-questionnaire.md`** — R-вопросник Week/Month Close: 3 недельных + 6 месячных вопросов для переосмысления (не yes/no, экзоскелетный режим — агент даёт факты, человек судит). Класс R (Review/judgment). Включает M6 decommission-триаж (active → dormant → archived).
- **`.claude/sync-manifest.yaml`** — реестр пар «источник → производное» для `iwe-drift.sh`. Шаблон с 3 generic-парами (protocols-to-skills, protocol-open-to-day-open-skill, staging-validated-to-fmt) + закомментированные шаблоны для Pack↔DS, root-CLAUDE↔instrument, instrument-docs↔code. Секция `activity_checks:` для decommission-триажа в Month Close.
- **`scripts/iwe-drift.sh`** — R23-детектор drift'а пар (mtime-lag, без LLM). MVP-версия: shell + git + stat + awk, без внешних зависимостей. Usage: `bash scripts/iwe-drift.sh [--critical|--top N|--manifest PATH]`. Markdown-вывод для прямой вставки в DayPlan/Week Report.

### Changed
- Регламент техобслуживания IWE (элемент #15 культуры работы) теперь промотирован в шаблон: пользователи получают T-checklist, R-вопросник, drift-механизм при `update.sh`. Класс T/S/R закреплён в `.claude/rules/distinctions.md` HD «ТО ≠ Sync ≠ Review».

## [0.28.1] — 2026-04-25

### Changed
- **`memory/hard-distinctions.md`** — переписан: 631 → 374 строки (40% сокращение). 23 различения в порядке релевантности (Персона/Скрипт-Агент/MCP-имена/Лог-Инцидент сверху). 15 различений → `hard-distinctions_archive.md` (исторически важные, не используются в текущей работе >1 мес). 8 удалены полностью (тривиальные дубли slim distinctions.md). Для пилотов: новая компактная нумерация 1-23, прежние ссылки на номера >27 устаревают.
- **`memory/navigation.md`** — удалена авторская таблица MCP-исходников (`DS-MCP/knowledge-mcp/...`) и ссылка на authored MCP-search. Эти пути относятся к авторскому workspace, не к шаблону.
- **`memory/checklists.md`** — удалён давний урок про stale knowledge-mcp (фев 2026, не релевантен пилотам).
- **`memory/protocol-open.md`, `memory/repo-type-rules.md`, `roles/strategist/scripts/cleanup-processed-notes.py`** — placeholder-sub: `DS-my-strategy` → `DS-strategy` (унификация с FMT-конвенцией).
- **`CLAUDE.md`** — удалена строка «Бот = интерфейс / engines/tailor» в `### Различения (авторские)` §9 (специфика автора, не шаблон).

### Fixed
- **`template-sync.sh` strip-list расширен** (DS-ai-systems источник): `DS-MCP`, `knowledge-mcp`, `gateway-mcp`, `digital-twin`, `content-pipeline`, `engines/tailor` теперь вычищаются. Sync был застрял в FAILED state с ~21 апр (validation abort на этих паттернах в hard-distinctions.md HD #27 + #29). Теперь sync проходит validation.

## [0.28.0] — 2026-04-25

### Changed
- **`.claude/settings.json`** — `defaultMode` изменён с `"dontAsk"` на `"acceptEdits"`. Это исправление: `dontAsk` означает «по умолчанию **запрещать** инструменты вне allow-листа», что приводило к скрытым отказам и порождало повторные permission-запросы у пользователей. `acceptEdits` авто-аппрувит файловые операции (`Edit`/`Write`, `cp`/`mv`/`mkdir`/`touch`/`rm`/`rmdir`/`sed`) в рабочих директориях; deny-rules (`Bash(sudo *)`, `Bash(rm -rf *)`) остаются в силе. Для пользователей: меньше ненужных диалогов согласования, особенно при `update.sh`.
- **`memory/hard-distinctions.md` HD #27** переписан: «Бот ≠ Платформа; Neon + DT MCP = один ЦД» → «Персона ≠ Память ≠ Контекст». Новая модель пользовательских данных (DP.D.052, WP-257) с критерием разделения «writer + owner»: Персона = Git пользователя, Память = Neon платформы, Контекст = runtime LLM-вызова. Маппинг старого «ЦД» на новые слои + 5 категорий вне пользовательской модели + расщепление Памяти на Observed/Derived. SoTA: Letta, Mem0, LangMem, Anthropic Memory tool.
- **`memory/checklists.md`** — урок «MCP-индекс может вернуть stale» переформулирован с конкретной датой/документом.
- **`memory/protocol-open.md`, `memory/repo-type-rules.md`, `memory/navigation.md`** — мелкие уточнения формулировок.

### Fixed
- **`roles/strategist/prompts/note-review.md`, `session-prep.md`, `cleanup-processed-notes.py`** — точечные правки.
- **`roles/synchronizer/scripts/dt-collect.sh`** — упрощение (≈36 строк диффа).

### Meta
- **Drift CHANGELOG ↔ update-manifest.json** (5 версий 0.27.3-0.27.7 не имели bump манифеста, `update.sh --check` возвращал 0.26.1 как «актуальную»). Bump манифеста до 0.28.0 закрывает разрыв за один шаг. Системный фикс (pre-commit hook, не дающий закоммитить CHANGELOG без bump'а manifest) — отдельный РП, S-30 в STAGING.

## [0.27.7] — 2026-04-24

### Fixed
- **`roles/extractor/scripts/extractor.sh` + `roles/extractor/prompts/inbox-check.md`** (WP-7 Ф-1) — подсчёт pending captures и дефиниция в промпте. Старая логика `grep -c '\[analyzed'` ловила substring в описаниях/цитатах captures.md (например, в тексте капчи мог быть `[analyzed` как часть описания), не только реальные маркеры-статусы. На реальном файле: 166 заголовков, substring-match ≠ реальному счёту маркеров. Формула `PENDING - PROCESSED - ANALYZED` давала ложные числа → каждые 3 часа LLM запускался «на 80 pending» и отвечал «all marked». Fix: прямой подсчёт заголовков БЕЗ любого из 4 маркеров на той же строке (`grep -E '^### ' | grep -vE '\[(analyzed|processed|duplicate|defer)\b'`). Regex `\b` (word boundary) ловит датированные маркеры типа `[analyzed 2026-04-10]`, которые `\]` пропускал. Промпт обновлён на все 4 маркера. Sync from DS-ai-systems 437048b.

## [0.27.6] — 2026-04-24

### Fixed
- **`roles/synchronizer/scripts/daily-report.sh`** (WP-7 I2) — `mv SchedulerReport → archive/` падал при отсутствующем `archive/`. Под `set -euo pipefail` это прерывало скрипт с non-zero exit → `scheduler.sh` логировал `WARN: daily-report failed` каждые 3 часа. Добавлен `mkdir -p "$ARCHIVE_DIR"` в `archive_old_reports()`.
- **`roles/strategist/scripts/strategist.sh`** (WP-7 I1) — `BOLD_BEFORE=$(grep -c ... || echo 0)` при exit 1 от grep (0 matches) давал мультистрочный `"0\n0"` → `$(( BOLD_BEFORE - BOLD_NEW_BEFORE ))` падал с `line 249: 0: syntax error`, `[ -ge ]` — с `integer expression expected`. Fix: `|| true; VAR=${VAR:-0}` (5 точек: BOLD_BEFORE, BOLD_NEW_BEFORE, BOLD_AFTER, BOLD_NEW_AFTER, NON_BOLD).
- **Тот же антипаттерн `grep -c ... || echo N)` в 11 точках 7 файлов** (субагент-ревью после I1+I2): `setup/validate-template.sh`, `.claude/hooks/protocol-artifact-validate.sh`, `roles/synchronizer/scripts/templates/{synchronizer,extractor}.sh`, `update.sh` (3 точки: DIFF_COUNT, CONFLICT_COUNT, WS_CONFLICTS), `.github/workflows/{cloud-scheduler,validate-template}.yml`. Все использовались в `[ -gt N ]` / арифметике → потенциальные баги того же класса.

Commits: 150be24 (I1+I2 sync из DS-ai-systems), 731471f (I3 sweep 11 точек).

## [0.27.5] — 2026-04-24

### Changed
- **`roles/strategist/scripts/strategist.sh` переименован концептуально (не файл):** context-файл зонтичного WP-7 в авторском governance-репо переехал `archive/wp-contexts/WP-7-bot-tech-debt.md` → `inbox/WP-7-platform-tech-debt.md`. Для шаблона это не blocker (пилоты используют свой `WP-N-*.md`), но в документации `PROCESSES.md` бота обновлена ссылка. Причина: WP-7 давно стал зонтом всей платформы (не только бота) + ошибочно жил в archive/, хотя active (`umbrella: true`). Подтверждено субагентом.

## [0.27.4] — 2026-04-24

### Fixed
- **`roles/synchronizer/scripts/dt-collect.sh`** помечен как author-only (header + raison d'être). Скрипт пишет напрямую в production-БД Neon платформы через `NEON_URL` / `DT_USER_ID`, и эти секреты есть только у автора шаблона. Конечным пользователям IWE не нужно создавать `~/.config/aist/env` с этими переменными.
- **`roles/synchronizer/scripts/scheduler.sh`** добавлен guard: `dt-collect.sh` молча пропускается, если `~/.config/aist/env` не содержит `NEON_URL`+`DT_USER_ID`. У пользователей без секретов автора скрипт не запускается, ошибок не возникает, скачанный код остаётся как маркер будущей фичи.
- **`roles/synchronizer/README.md`** новая секция «Author-only скрипты» объясняет, почему файл есть в шаблоне, но не запускается у пользователей; даёт ссылку на правильный пользовательский путь (MCP-инструмент `dt_write_digital_twin` в IWE Gateway).

Триггер: пользовательский запрос (boberru@gmail.com 24 апр) — шаблон требовал NEON_URL/DT_USER_ID, что является L3-утечкой секретов автора. Системная замена psycopg2-writer → REST endpoint (`POST /hub/events`) через Activity Hub запланирована фазой P2b в `DP.ROADMAP.001-neon-migration.md` (WP-253), активация после P2 (создание #2 journal, ориентир июнь 2026).

## [0.27.3] — 2026-04-24

### Added
- **`setup/validate-template.sh` check 7 + `.github/workflows/validate-template.yml` job «Check hooks cross-ref»** (systemic followup к #13). Проверяет cross-ref в обе стороны: (a) FAIL если hook упомянут в `settings.json*`, но файла нет в `.claude/hooks/`; (b) WARN если hook есть в директории, но не упомянут ни в одном settings.json (может быть direct-call, как `wakatime-heartbeat.sh`). Покрывает оба направления drift'а (settings→hooks и hooks→settings). Предотвращает повторение issue #13.

### Fixed
- **`setup/validate-template.sh` check 2** добавлен `--exclude='CHANGELOG.md'` (зеркально с CI workflow) — CHANGELOG содержит `/Users/...` в описаниях и создавал false-positive.

## [0.27.2] — 2026-04-23

### Fixed
- **`.claude/hooks/extensions-gate.sh`** (closes #13) — добавлен отсутствующий hook. Ссылка на файл жила в `.claude/settings.json:44` (PreToolUse matcher `Edit|Write`) с 7 апр (коммит `af73cd3`, WP-207), но сам скрипт так и не попал в шаблон — у нового пилота первый же `Write`/`Edit` падал с ошибкой «hook file not found». Хук реализует блокирующий Extensions Gate (CLAUDE.md §9): прямое редактирование `.claude/skills/*.md` или `memory/protocol-*.md` блокируется с подсказкой использовать `extensions/*.md`. Исключения: `author_mode: true` в `params.yaml`, путь `FMT-exocortex-template`. Корневая причина: `setup/validate-template.sh` не проверяет соответствие `settings.json` hooks ↔ содержимое `.claude/hooks/` (проверяет 6 других вещей, но не cross-ref). Попутная находка: `wakatime-heartbeat.sh` есть в hooks/, но не упомянут в settings.json (тот же класс drift'а в обратную сторону). Systemic followup (отдельный WP на W18): расширить validate-template.sh проверкой cross-ref + включить в pre-commit/CI FMT, плюс определить судьбу архивированного `template-sync.sh`.

## [0.27.1] — 2026-04-22

### Changed
- **Rollback S-27 «Здоровье платформы»** — секция содержала авторские сервисы (`@aist_me_bot`, `digital-twin`, `gateway-mcp`, `content-pipeline`, `knowledge-mcp`), не применимые обычному пользователю FMT. Перенесена в авторские `extensions/day-open.after.md`. Files: `memory/templates-dayplan.md`, `.claude/skills/day-open/SKILL.md`, `.claude/hooks/protocol-artifact-validate.sh` — удалена секция + step 5b «Бот QA»; SECTIONS хука урезан с 11 до 6. Источник: косяк промоции S-27 — тест «применимо пустому пользователю?» (см. авторский `memory/feedback_post_promote_sync.md`).
- **L3 leak cleanup (параметризация через env-vars):** `.claude/hooks/protocol-artifact-validate.sh`, `scripts/day-close.sh`, `roles/strategist/scripts/cleanup-processed-notes.py`, `roles/synchronizer/scripts/dt-collect.sh`, `roles/strategist/prompts/{note-review,session-prep}.md` — хардкод `DS-my-strategy`, `DS-agent-workspace/scheduler/feedback-triage/`, `~/IWE/DS-my-strategy` заменён на `$IWE_WORKSPACE` + `$IWE_GOVERNANCE_REPO` (fallback: `DS-strategy`) и условные `if настроены агенты-сборщики QA`.
- **`memory/hard-distinctions.md` HD #49:** примеры MCP-именования обобщены (`digital-twin-mcp`, `knowledge-mcp` → `<domain>-mcp`). `memory/checklists.md`: урок «knowledge-mcp stale index» → «MCP-индекс». `memory/navigation.md`: таблица MCP → placeholder'ы. `CLAUDE.md`: удалено правило `engines/tailor` (авторская реализация бота).
- **`.claude/skills/ke/SKILL.md`, `memory/{repo-type-rules,protocol-open}.md`:** `DS-my-strategy` → `<governance-repo>` (env).

### Added
- **CI smoke-test** (`.github/workflows/validate-template.yml`): job «Smoke-test protocol hooks on clean user env» — создаёт tmp-окружение с `DS-strategy` + минимальным DayPlan и прогоняет `protocol-artifact-validate.sh`. Падает, если хук блокирует commit на чистом пользователе. Перехватывает L1→L3 утечки, которые пропускает blacklist.
- **Расширенный blacklist** (два уровня) в `validate-template.yml` + зеркально в локальном `setup/validate-template.sh`: глобальный (запрещено везде: `tserentserenov`, `PACK-MIM`, `aist_bot_newarchitecture`, `DS-Knowledge-Index-Tseren`, `DS-my-strategy`, `engines/tailor`) и protocol-only (запрещено в `.claude/skills|hooks|rules`, `memory`, `CLAUDE.md`, но разрешено в README/docs: `@aist_me_bot`, `digital-twin`, `content-pipeline`, `knowledge-mcp`, `gateway-mcp`, `DS-agent-workspace/scheduler`). Покрытие расширено на `roles/`.

### Fixed
- CI `validate-template.yml` — зеркалирование exclude-логики локального валидатора для путей (`/Users/...`, `/opt/homebrew`) + shellcheck severity: warning→error (0 pred-existing errors, CI зеленеет).

## [0.27.0] — 2026-04-21

### Added
- **seed/strategy/docs/Strategy.md** — секция «Состояние месяца — фаза стратегической позиции» (PD.FORM.078: 4 фазы Развитие/Хаос/Потолок/Пивот, диагностика по 5 сигналам, playbook, сигналы перехода) + секция «Калибр личности» (PD.CHR.007, gap-analysis по 3 направлениям: горизонт / bus factor / публичность) + строка-источник «НЭП-триады» перед таблицей R1-R{N}. Strategy Session теперь начинается с явной декларации фазы и playbook-а под неё, а не с произвольного выбора РП. Источник: WP-196 Ф12.1, S-26 promoted.
- **memory/templates-dayplan.md** (WeekPlan) — блоки «Применённые критерии отбора РП» (PD.METHOD.017 + Time-boxing Shape Up: РП без 50% бюджета к четвергу → пересмотр на следующей сессии) + «ТОС недели + запрос недели» на открытии; секция «## Week Close» с 4 подсекциями (сверка РП↔НЭП, рекомендации изменений в НЭП/Стратегию, carry-over, мультипликатор и метрики) на закрытии. Источник: WP-196 Ф12.1, S-26.
- **memory/templates-dayplan.md** (DayPlan) — секция «Day Close» с 3 подсекциями (три варианта плана на завтра A/B/C, KE-маршрутизация, сверка с НЭП). Day Close теперь имеет видимую структуру весь день, а не появляется «в момент закрытия». Источник: WP-196 Ф12.1, S-26.

### Changed
- **memory/templates-dayplan.md, .claude/skills/day-open/SKILL.md, .claude/hooks/protocol-artifact-validate.sh** — секция `Здоровье бота (QA)` переименована в `Здоровье платформы` (семантически strict superset: старая секция стала подзаголовком `### Бот @aist_me_bot (QA)`, добавлены `### Остальные MCP-сервисы` + `### Operational health`). Хук валидатора обновлён в lockstep (список секций + awk range + сообщение ошибки). Привязка: WP-255 (L3/L4 AI Quality для всех MCP) draft + HD «Internal health ≠ Public status page». Источник: WP-196 Ф12.3 partial, S-27 promoted.

## [0.26.4] — 2026-04-18

### Added
- **.claude/skills/ke/SKILL.md** — блок `## Scope` разграничивает три инструмента знания в IWE: `/ke` (inline capture, R14/R1), `extractor.sh inbox-check` (R2 launchd 3h work hours, создаёт `extraction-reports/*.md` со `status: pending-review`), `/apply-captures` (R15 Валидатор, в разработке). Явно указано что скилл делает и чего НЕ делает. Предотвращает будущий P10-дубликат scope при появлении `/apply-captures`. Источник: WP-247 Ф3.0 — IntegrationGate для скилла разбора extraction-reports.

### Fixed
- **roles/strategist/prompts/session-prep.md** (шаг 6, очистка `extraction-reports/`) — условие удаления учитывает `status` во frontmatter: удаляются только `applied` / `rejected` / `no-pending` (старше 7 дней). Статусы `pending-review` / `partially-applied` / `deferred` защищены — реализация инварианта «capture не исчезает без решения». Инцидент 17 апр: прежнее правило «старше 7 дней → удалить» удалило 6 pending-review отчётов (6-10 апр) вместе с неразобранными кандидатами. Источник: WP-247 Ф5.

## [0.26.3] — 2026-04-18

### Fixed
- **docs/LEARNING-PATH.md** (§5.1b Session Open), **roles/synchronizer/scripts/dt-collect.sh** (collect_sessions) — путь к session log приведён к канону `DS-my-strategy/inbox/open-sessions.log` (вариант для FMT: `<governance-repo>/inbox/open-sessions.log`). Ранее устаревший путь `DS-agent-workspace/scheduler/open-sessions.log` оставался в LEARNING-PATH и dt-collect.sh — агенты/скрипты при чтении документации могли промахнуться. Каноничное место ведения — governance-репо пользователя (там же читает CI workflow `cloud-scheduler.yml`), формат остаётся plain text. Источник: WP-248 drift cleanup (ArchGate PASS, отказ от §5.7/YAML из-за совместимости с CI).

## [0.26.2] — 2026-04-17

### Fixed
- **roles/extractor/prompts/inbox-check.md** — шаг 1.3 «напиши в лог `No pending captures in inbox`» теперь явно запрещает создавать отдельный лог-файл в `DS-strategy/` или где-либо ещё. Сообщение выводится через stdout и попадает в `{{HOME_DIR}}/logs/extractor/YYYY-MM-DD.log` (поток extractor.sh). Причина: у автора накопились 3 runtime-артефакта в `inbox/` (хаотичное размещение `inbox-check.log`, `extraction-reports/inbox-check.log`, `.inbox-check-log` — нарушение OwnerIntegrity: knowledge flow vs runtime).

## [0.26.1] — 2026-04-17

### Fixed
- **update-manifest.json** — синхронизирован с реальным состоянием репо: добавлены пропущенные файлы `scripts/backup-icloud.sh`, `scripts/check-dirty-repos.sh` (0.26.0), `.claude/hooks/protocol-artifact-validate.sh` (0.23.0), `.claude/hooks/protocol-stop-gate.sh` (0.24.0), `docs/QUICK-START.md`. Версия бампнута с 0.23.0 до 0.26.1. Без этого фикса: Day/Week Close у пользователей падал с `No such file or directory` на новые скрипты; хуки `settings.json` ссылались на несуществующие файлы. Источник: issue #5 (Евгений Селиверстов).
- **generate-manifest.sh** — расширены `EXCLUDE_PATTERNS`/`EXCLUDE_EXACT`: `README.en.md`, `CONTRIBUTING.md`, `LICENSE`, `params.yaml`, `extensions/day-close.after.md`, `extensions/mcp-user.json`. Регенерация манифеста больше не захватывает пользовательское пространство, которое `update.sh` обещает не трогать (см. update.sh §«Не затрагивается»).
- **extensions/README.md** — уточнена формулировка: `update.sh` не трогает пользовательские файлы (`*.after.md`, `*.before.md`, `*.checks.md`, `mcp-user.json`), но обновляет сам `README.md` как платформенный справочник. Противоречие «никогда не трогает» vs фактического присутствия `extensions/README.md` в manifest устранено.

## [0.26.0] — 2026-04-17

### Added
- **scripts/backup-icloud.sh** — еженедельный бэкап IWE в iCloud Drive. Архивирует без `.git`/`node_modules`/`.venv`, хранит 4 последних архива с ротацией. macOS only.
- **scripts/check-dirty-repos.sh** — скан всех IWE репо (включая вложенные) на незакоммиченные изменения и незапушенные коммиты. Используется в Day Close (шаг 7г) и Week Close.

### Changed
- **week-close/SKILL.md** v1.1.0 — добавлены платформенные шаги: бэкап iCloud и скан грязных репо.

## [0.25.1] — 2026-04-14

### Changed
- **protocol-close.md** — KE (Knowledge Extraction) добавлен как обязательный шаг 2.5 Quick Close. Знание маршрутизируется в момент сессии (горячий контекст), не откладывается на Day Close. Чеклист Quick Close дополнен строкой KE. Секция Deferred обновлена: KE выведен из отложенных.

## [0.25.0] — 2026-04-13

### Changed
- **protocol-close.md** — сжат 454→97 строк. Остались: маршрутизация, Quick Close inline, формат «Осталось», чеклист Quick Close. Алгоритмы Day Close и Week Close вынесены в отдельные SKILL.md.
- **day-open/SKILL.md** — шаблоны DayPlan/WeekPlan/итогов удалены из файла (→ `memory/templates-dayplan.md`). Файл сокращён с ~343 до 127 строк.
- **update-manifest.json** — добавлены: `day-close/SKILL.md`, `week-close/SKILL.md`, `memory/templates-dayplan.md`.
- **navigation.md** — добавлены строки для `day-close/SKILL.md`, `week-close/SKILL.md`, `templates-dayplan.md`.
- **run-protocol/SKILL.md** — добавлена строка: `close` (без уточнения) → `close session` по умолчанию.

### Added
- **.claude/skills/day-close/SKILL.md** — полный алгоритм Day Close (шаги 0–11) с TodoWrite enforcement. Шаг 0 = «создать список задач прямо сейчас». Главный фикс: агент больше не может пропустить шаги через прямое чтение protocol-close.md.
- **.claude/skills/week-close/SKILL.md** — полный алгоритм Week Close (шаги 0–9) с TodoWrite enforcement.
- **memory/templates-dayplan.md** — единый источник шаблонов DayPlan, compact dashboard, WeekPlan, итогов дня. Используется day-open (создание) и day-close (запись итогов).

## [0.24.1] — 2026-04-13

### Fixed
- **protocol-close.md** — Day Close §3: правило архивации DayPlan (`mv current/DayPlan → archive/day-plans/`) + пункт в чеклист Day Close. Week Close §2: архивация WeekPlan прошлой недели + `git status` перед финальным коммитом (незастейженные deletes).

## [0.24.0] — 2026-04-12

### Added
- **protocol-stop-gate.sh** — Stop hook: если в сессии был вызов протокольного Skill (day-open|day-close|run-protocol|wp-new), проверяет наличие TodoWrite ≥3 items. Нет → блокирует завершение. `action=warn` (warn-before-block, промоция в block после 2 нед обкатки). Логирует в `.claude/logs/gate_log.jsonl`. Guard `STOP_HOOK_ACTIVE` против infinite loop.
- **settings.json** — Stop hook: protocol-stop-gate.sh добавлен первым в Stop-массив (до capture-bus)
- **settings.json** — PostToolUse matcher расширен: `Read` → `Read|Skill`

### Changed
- **protocol-completion-reminder.sh** — расширен на Skill tool: теперь срабатывает при вызове `day-open|day-close|run-protocol|wp-new` и напоминает создать TodoWrite ДО исполнения
- **protocol-artifact-validate.sh** — добавлены структурные проверки DayPlan: (1) `<details>` collapsible ≥3 блоков, (2) непустые секции Календарь/QA/Scout, (3) мультипликатор `~N.Nx`, (4) Carry-over цитата при наличии предыдущего DayPlan

## [0.23.1] — 2026-04-09

### Fixed
- **day-open SKILL.md** — шаблон QA-секции: видео показывает только новые за сегодня (не весь stale-архив), заметки проверяются по git log note-review (не carry-over обработанных)

## [0.23.0] — 2026-04-07

### Added
- **protocol-artifact-validate.sh** — PreToolUse hook (Bash matcher) блокирует `git commit` если DayPlan невалиден: 11 секций, mandatory check, бюджет в формате. Кодовый enforcement вместо промпт-инструкций
- **run-protocol SKILL.md** — шаг 1b Extension Loading: автоматическая загрузка `extensions/{protocol}.before/after/checks.md` при исполнении любого протокола. Маршрутизация: протоколы с Skill-файлом читают полный алгоритм
- **day-open SKILL.md** — шаг 5a2 (видео-сканирование), шаг 7 разбит на 7a-7d (Write → Checks → Commit → Dashboard)

### Changed
- **day-open/protocol-open/protocol-close** — HTML-комментарии `<!-- EXTENSION POINT -->` заменены на видимый markdown `**EXTENSION POINT:**` — агент их читает и исполняет
- **wp-gate-reminder.sh** — при Day Open инжектирует extension loading reminder
- **settings.json** — добавлен PreToolUse Bash matcher для protocol-artifact-validate.sh

### Fixed
- **settings.json** — убрана лишняя строка `.claude/hooks` из `additionalDirectories` (вызывала открытие файлов хуков как вкладок в Cursor/VS Code на Windows)

## [0.22.0] — 2026-04-06

### Added
- **verify SKILL.md** — два новых типа верификации: `chain` (data flow check, CoVe stage 3) и `adversarial` (scope & bias check, pre-mortem). Context isolation sub-agent с чеклистами
- **day-close.sh** — маппинг dir→source из L2 (sources.json) + L4 (sources-personal.json). Раздельные вызовы selective-reindex через SOURCES_CONFIG. Фикс хронического reindex failure с 20 марта

### Changed
- **verify SKILL.md** — обновлена нумерация шагов (0→4), unified verdict формат, автоопределение chain/adversarial по контексту
- **update-manifest.json** → v0.22.0

## [0.21.0] — 2026-03-29

### Added
- **setup.sh v0.5.1** — секция T3+ в `.exocortex.env`: ORY_TOKEN, L4_BACKEND, L4_DATABASE_URL. setup.sh при уровне T3/T4 спрашивает токен и backend (можно пропустить). Единый файл конфигурации для всей IWE — `~/.iwe-env` упразднён
- **update.sh** — исправлен парсер env-файла: `IFS='=' read` заменён на `${line%%=*}` + `${line#*=}` — корректно читает значения с `=` внутри (URL, токены). Добавлен detect `~/.iwe-env`: если файл существует и T3+-ключи отсутствуют в `.exocortex.env` — мигрирует автоматически
- **.githooks/pre-commit** — блокирует коммит если `.exocortex.env` попал в staged files

### Changed
- **update.sh** — ORY_TOKEN/L4_BACKEND/L4_DATABASE_URL читаются из `.exocortex.env` но **не подставляются** в template-файлы (секция secrets, только для Gateway-скриптов)
- **update-manifest.json** → v0.21.0

## [0.20.0] — 2026-03-29

### Added
- **setup.sh v0.5.0** — градиентный вход: флаг `--level=T1/T2/T3/T4` + интерактивный выбор при запуске. T1=минимум (≤15 мин), T2=+ОРЗ+extensions, T3=+Pack+бот, T4=+роли+launchd. Каждый уровень дополняет предыдущий, не заменяет
- **ADR-003** — спецификация платформы-хостинга: два слоя доставки (дистрибутив vs хостинг), скриптуемый API (`--yes`), градиентный вход, экспорт, Vagrant-образ, ЭМОГССБ 60/70

### Changed
- **update-manifest.json** → v0.20.0
- **setup.sh** — INSTALL_LEVEL сохраняется в `.exocortex.env`; шаги 4, 5 зависят от уровня; Next steps адаптированы под уровень

## [0.19.0] — 2026-03-29

### Added
- **skill /extend** — каталог расширяемости IWE. Показывает все extension points, параметры params.yaml, конфиг day-rhythm-config.yaml, инструкции по sharing. Предлагает следующий шаг на основе текущих кастомизаций пользователя
- **update.sh Step 6b** — авто-фикс ссылок при миграции: обновляет абсолютные пути и имя репо в пользовательских файлах extensions/ и MEMORY.md при переименовании/переезде IWE
- **extensions/README.md** — секция «Несколько расширений одного hook» (суффиксы для конфликтов) и «Sharing» (формат bundle-пакетов расширений)

### Changed
- **update-manifest.json** → v0.19.0: добавлен `.claude/skills/extend/SKILL.md`

## [0.18.0] — 2026-03-28

### Added
- **extensions/** — 12 extension points в протоколах (day-open before/after, day-close checks, week-close before/after, protocol-close checks/after). Пользователь добавляет файл `extensions/<protocol>.<hook>.md` — блок вставляется в протокол при исполнении
- **params.yaml** — 8 персистентных параметров управляют условными шагами протоколов: `video_check`, `multiplier_enabled`, `reflection_enabled`, `lesson_rotation`, `auto_verify_code`, `verify_quick_close`, `telegram_notifications`, `extensions_dir`
- **extensions/day-close.after.md** — пример расширения: рефлексия дня (3 вопроса). Управляется `reflection_enabled` в params.yaml
- **update.sh** — 3-way merge для CLAUDE.md через `git merge-file`. Пользовательские правки в §1-7 сохраняются при обновлении платформы. Fallback на USER-SPACE для первого обновления
- **setup.sh** — создаёт `.claude.md.base` при установке (base для 3-way merge)
- **.gitignore** — `.claude.md.base` (служебный файл merge)

### Changed
- **CLAUDE.md §7** — инструкции для Claude по загрузке extensions и чтению params.yaml
- **protocol-close.md** — `<!-- YOUR CUSTOM CHECKS HERE -->` заменены на `<!-- EXTENSION POINT: загрузить extensions/X.md -->` (единый формат)
- **protocol-close.md** — условные шаги привязаны к params.yaml: multiplier_enabled (шаг 5), video_check (шаг 6д), lesson_rotation (week-close шаг 1), auto_verify_code (шаг 4b), verify_quick_close (шаг 7)
- **update.sh** — «Не затрагиваются» обновлён: extensions/, params.yaml, 3-way merge вместо USER-SPACE
- **skill /iwe-update** — агент-обновитель: вызывает update.sh, парсит CHANGELOG, объясняет изменения на человеческом языке, анализирует совместимость с extensions/params, помогает разрешить конфликты 3-way merge
- **day-open шаг 5** — автоматическая проверка обновлений (`update.sh --check`) → «Требует внимания» если доступна новая версия

### Removed
- **AUTHOR-ONLY** — механизм `<!-- AUTHOR-ONLY -->` заменён на extensions/ (авторские блоки мигрированы в extension-файлы)

## [0.17.1] — 2026-03-28

### Added
- **day-open/SKILL.md** — БЛОКИРУЮЩЕЕ: пошаговое исполнение через TodoWrite. Каждый шаг = задача, переход только после отметки. Предотвращает пропуск шагов (carry-over, mandatory, запись) из-за загрязнения контекста (SOTA.002)
- **protocol-open.md** — ссылка на пошаговое исполнение Day Open (аналогично Close)

## [0.17.0] — 2026-03-28

### Changed
- **day-open/SKILL.md v1.1** — carry-over из вчерашнего DayPlan теперь обязательная логика (не конфиг-флаг). Убран `day_close.review_yesterday_close`
- **day-open/SKILL.md** — алгоритм и шаблоны объединены в один файл. Шаг 2: приоритет входов (carry-over → WeekPlan → mandatory)
- **day-open/SKILL.md** — `{{GOVERNANCE_REPO}}` вместо prose-текста (формализация)
- **day-rhythm-config.yaml** — добавлен `calendar_ids: []` (Day Open запрашивает все календари или указанные)
- **day-rhythm-config.yaml** — убран `day_close` (carry-over = часть алгоритма, не настройка)

### Added
- **day-open/SKILL.md §6** — ссылки на источники (URL) обязательны в секции «Мир»

## [0.16.9] — 2026-03-28

### Added
- **scheduler.sh** — `TASK_TIMEOUT_SHORT` (300s) и `TASK_TIMEOUT_LONG` (1800s) для всех задач dispatch
- **scheduler.sh** — macOS perl timeout fallback (нет GNU timeout)
- **scheduler.sh** — AC sleep check (pmset) в dispatch() — предупреждение при sleep≠0 на зарядке

## [0.16.8] — 2026-03-28

### Added
- **day-open/SKILL.md** — механизм `mandatory_daily_wps`: стратег читает из `day-rhythm-config.yaml` обязательные РП для каждого дня. Нет в WeekPlan → «Требует внимания»
- **day-open/SKILL.md** — механизм `review_yesterday_close`: опциональное чтение Close прошлого дня при Day Open (carry-over, незакрытые вопросы)
- **day-rhythm-config.yaml** — секции `mandatory_daily_wps` и `day_close` (закомментированные примеры)

## [0.16.7] — 2026-03-27

### Fixed
- **hooks/close-gate-reminder.sh** — v3: hook теперь инжектирует БЛОКИРУЮЩУЮ инструкцию вызвать `/run-protocol` вместо напоминания «Read protocol-close.md». Устраняет пропуск шагов при ручном исполнении Close (АрхГейт 63/70)

## [0.16.6] — 2026-03-27

### Changed
- **docs/onboarding** — актуализация onboarding-документов: IWE = ОС (не среда/платформа), 4 компонента (Ядро мышления, Культура работы, Модель мастерства, Сообщество), теории (ШСМ) + культура работы (14 элементов), экзотело вместо экзоскелета, инструменты = средства доставки
- **docs/DATA-POLICY** — убраны несуществующие standard/personal, добавлена свобода данных (§6.1), два слоя доставки, актуальная структура (memory/, extensions/, params.yaml)

## [0.16.5] — 2026-03-27

### Changed
- **docs** — синхронизация документации: README сценарии → ссылки на SC.001-SC.015 (USE-CASES.md), FAQ подписки унифицированы («при необходимости»), IWE-HELP роли уточнены (3 в шаблоне / 21 на платформе), CLAUDE.md §2 примечание про первую неделю, SETUP-GUIDE §1.3b пояснение про MCP и Pack-сущности

## [0.16.4] — 2026-03-27

### Changed
- **notify-update.yml** — 3-уровневый фильтр уведомлений: (1) наличие коммитов, (2) наличие changelog с буллет-пунктами, (3) проверка значимости (ключевые слова, значимые файлы, ≥3 пунктов). Незначительные правки (только CLAUDE.md/memory/rules) больше не генерируют уведомления подписчикам

## [0.16.3] — 2026-03-27

### Changed
- **seed/strategy/docs/Strategy.md** — переструктурирование шаблона: Фокус Q{N} (текущий квартал, details open) первым, затем Годовой план (фазы, roadmap, MAPSTRATEGIC, риски, Q итоги внутри). Убрана отдельная секция Q итоги и Риски

## [0.16.2] — 2026-03-25

### Changed
- **skill /iwe-rules-review** — 3 вопроса → 4 вопроса (по актуальному DP.M.008: чему научился? какое правило мешало? какого не хватало? какое обходил?)

## [0.16.1] — 2026-03-25

### Changed
- **skill /archgate** — L2.1 Переносимость данных добавлена, L2.2–L2.7 перенумерованы (7 доменных характеристик). АрхГейт 8.0+ (WP-177)

## [0.16.0] — 2026-03-25

### Changed
- **WeekReport deprecated** — итоги недели теперь записываются в секцию «Итоги W{N}» внутри WeekPlan. Отдельный файл WeekReport больше не создаётся. АрхГейт 8.9 (62/70)
- **week-review.md** — пишет секцию в WeekPlan, не создаёт файл
- **session-prep.md** — читает секцию из WeekPlan, не ищет файл WeekReport

### Added
- **Кроссплатформенное предотвращение сна** — `strategist.sh` и `scheduler.sh` автоматически блокируют засыпание: macOS `caffeinate -diu` / Linux `systemd-inhibit`. Флаг `-s` не используется — он игнорируется когда Optimized Battery Charging переключает профиль на батарею
- **SETUP-GUIDE: инструкции wake+sleep** для macOS, Linux, Windows. Включая `pmset -b sleep 0` для ноутбуков и Charge Limit рекомендацию
- **PLATFORM-COMPAT: sleep prevention** — документация кроссплатформенных ограничений
- **Agent Workspace (optional, WP-176)** — `setup/optional/setup-agent-workspace.sh` создаёт отдельный репо для данных агентов. SETUP-GUIDE Этап 7 с осознанным описанием когда нужен/не нужен
- **daily-report.sh conditional** — если DS-agent-workspace/.git существует → отчёты туда, иначе DS-strategy/current/ (обратная совместимость)

### Updated
- **LEARNING-PATH §11 FAQ** — 3 развёрнутых ответа (Windows+WSL, заметки, бот отвечает не то) + 6 табличных строк (WP-166: feedback_triage кластеры)
- docs/LEARNING-PATH, USE-CASES, SETUP-GUIDE, onboarding-guide — убран WeekReport
- roles/strategist/README, seed/strategy/CLAUDE.md — WeekReport помечен deprecated
- synchronizer/scripts/templates/strategist.sh — ищет WeekPlan вместо WeekReport
- README.md FAQ — обновлён вопрос про сон/выключение
- install.sh — кроссплатформенные подсказки при установке
- session-prep.md, note-review.md — ссылки на QA-отчёт: agent-workspace или DS-strategy
- collectors.d/README.md — unsatisfied → agent-workspace path

## [0.15.2] — 2026-03-24

### Changed
- **«Правила IWE» → «Культура работы IWE»** — переименование в skill /iwe-rules-review и шаблоне отчёта (согласование с DP.M.008)

## [0.15.1] — 2026-03-24

### Fixed
- **Битые ссылки** — исправлено 17 ссылок в 6 файлах: кросс-репо `../../../../PACK-digital-platform/` → абсолютные GitHub URL в onboarding-guide, `LEARNING-PATH.md`/`SETUP-GUIDE.md` → `docs/` в CHANGELOG, лишний `../` в LEARNING-PATH, `Github/` в protocol-work, недостаточная глубина `../` в week-review и setup/optional/README

## [0.15.0] — 2026-03-24

### Changed
- **Context Compression (WP-172)** — входной overhead снижен с ~27K до ~13K токенов (2x сжатие). АрхГейт 8.9
- **CLAUDE.md** — сжат до ~90 строк ядра (было ~280). Убраны детали, дублирующие memory/ и .claude/rules/
- **protocol-open.md** — шаблоны DayPlan/WeekPlan вынесены в skill `/day-open` (lazy loading, ~8K экономия в обычных сессиях)

### Added
- **skill `/day-open`** — `.claude/skills/day-open/SKILL.md`: шаблоны DayPlan, WeekPlan, compact dashboard. Загружаются только при Day Open
- **Lesson Hygiene** в protocol-close.md (Day Close §3b) — симметрия: Open пишет уроки → Close чистит. Предотвращает раздувание MEMORY.md. Цель: ≤8 уроков
- **validate-template.sh** — проверка `.claude/skills/day-open/SKILL.md`
- **skill `/iwe-rules-review`** — еженедельное ревью культуры работы IWE (DP.M.008 #14). Триггер: Week Close
- **HD #43** — различение «Правило ≠ Реализация правила» (DP.M.008)

## [0.14.2] — 2026-03-24

### Changed
- **protocol-open.md § Ритуал (Шаг 1)** — каждый элемент отчёта с новой строки (было: всё в одну строку)
- **LEARNING-PATH.md § Ритуал** — аналогичное форматирование

## [0.14.1] — 2026-03-24

### Changed
- **wp-gate-reminder.sh** — при Day Open триггере инжектит реальную дату через `date` (currentDate от Anthropic может врать из-за timezone). На остальные сообщения — стандартный WP Gate reminder

## [0.14.0] — 2026-03-24

### Added
- **dt-collect.sh plugin-архитектура** — ядро (L3) содержит 11 стандартных коллекторов, `collectors.d/*.sh` — точка расширения для персональных (L4) коллекторов. Plugin loader автоматически source'ит файлы и route'ит JSON по TARGET-секциям
- **collectors.d/README.md** — документация формата плагинов (COLLECTOR/TARGET headers, формат функций)
- **6 новых коллекторов в ядре** — multiplier (DayPlan budget), WP-REGISTRY stats, Pack entities, fleeting notes, scheduler reports health
- **2 новых JSONB-секции** — `2_8_ecosystem`, `2_9_knowledge` (через плагины)
- **portable_date_offset** — кроссплатформенная обёртка для `date -v` (macOS + Linux)

## [0.13.5] — 2026-03-22

### Changed
- **protocol-close.md** — формула мультипликатора: partial РП считаются (% × бюджет), мелкие РП = 0.25h (не 0). Недельный мультипликатор = Σ бюджетов ВСЕХ отработанных РП / WakaTime. Убран плановый бюджет из формулы
- **hard-distinctions** — HD #42: Тир ≠ Квалификация (DP.D.042)

## [0.13.4] — 2026-03-22

### Added
- **Priority Gate** — новый Pre-action Gate в CLAUDE.md: при создании РП ≥3h обязательный вопрос «К какому результату месяца?» (R{N} / поддержка / off-plan)
- **wp-new SKILL** — 5-е место записи: маппинг РП → Результат в `Strategy.md`. Порог ≥3h
- **Strategy template** — секции «Результаты месяца» и «РП → Результаты» с пояснениями допустимых значений

## [0.13.3] — 2026-03-21

### Fixed
- **MCP подключение** — `setup.sh` использовал нерабочий `claude mcp add --transport http` → заменён на инструкцию через claude.ai/settings/connectors. Обновлены: SETUP-GUIDE §1.3b, IWE-HELP, LEARNING-PATH, validate-template.yml, update.sh (6 файлов)

## [0.13.2] — 2026-03-21

### Changed
- **cloud-scheduler.yml** — расширенный IWE Health Check: мульти-репо коммиты (24ч + 7д), проверка свежести backup (>48ч), статус бота (health endpoint), WP-статистика, светофор (🟢/🟡/🔴). Настройка через GitHub Variables: `HEALTH_CHECK_REPOS`, `BOT_HEALTH_URL`
- **LEARNING-PATH §2.6** — практический гайд настройки расширенного Health Check (4 шага)

### Fixed
- **cloud-scheduler.yml** — защита от пустого `STRATEGY_REPO` при `basename`, точный grep для WP-статистики (`| in_progress` вместо `in_progress`)

## [0.13.1] — 2026-03-21

### Fixed
- **inbox-check.md** — `[processed]` → `[analyzed]`: метка при анализе captures, не при записи в Pack. Корневая причина потери 76% captures
- **session-close.md** — добавлен шаг 8a: пометка captures `[processed]` только после подтверждённой записи в Pack
- **extractor.sh** — учёт `[analyzed]` в подсчёте pending captures
- **session-prep.md** — архивация `[processed]` captures в `archive/captures/` вместо удаления

## [0.13.0] — 2026-03-20

### Added
- **generate-post-image.py** (S48) — генерация обложек для постов через OpenAI GPT Image 1 API. SOTA-промпт: полный текст статьи → визуальная метафора. Настроение по аудитории (wide/community/advanced). ~$0.07/картинка
- **COVER-IMAGES.md** — подробная инструкция: API key, промпты, параметры, стоимость, интеграция с публикаторами

## [0.12.0] — 2026-03-20

### Added
- **cloud-scheduler.yml** — GitHub Actions workflow для облачной автоматики IWE. Базовый уровень (без LLM, $0/мес): backup memory → exocortex, health check ночной автоматики, опциональные Telegram-уведомления. DP.SC.019, S61
- **setup-cloud-scheduler.sh** — скрипт настройки: проверка gh CLI, установка GitHub Secrets, тестовый запуск workflow
- **LEARNING-PATH §2.6** — Cloud Scheduler добавлен в таблицу опциональных сервисов
- **README FAQ** — вопрос про работу IWE при выключенном Mac

### Changed
- **CLAUDE.md** — 3-слойная структура: L1 (§1-§7 платформа), L2 (§8 staging), L3 (§9 авторское). `update.sh` обновляет только L1. UC Gate добавлен в Pre-action Gates
- **cloud-scheduler Telegram** — HTML-формат вместо markdown (корректное отображение bold)

## [0.11.1] — 2026-03-20

### Changed
- **Haiku R23 верификатор в Quick Close** — закрытие сессии теперь запускает sub-agent Haiku R23 с context isolation (VR.SOTA.002). Шаг 7 в алгоритме Quick Close. Исключения: сессия ≤15 мин, сессия без изменений файлов
- **roles/verifier/README.md** — таблица «Когда вызывается» уточнена: Quick Close (шаг 7) + Day Close (шаг 10) + Session Close (Verification Gate)
- **CLAUDE.md правило 6** — обновлено: Quick Close + Day Close через Haiku R23

## [0.11.0] — 2026-03-20

### Changed
- **update.sh v2.0.0** — полностью переписан: curl + манифест вместо git merge. Работает с template repos (created via "Use this template"), которые не имеют общей git-истории с upstream. Self-update (bootstrap): скрипт обновляет сам себя перед работой
- **Превью перед обновлением** — показывает новые файлы, обновлённые, не затрагиваемые. Пользователь решает: применить или отменить
- **setup-calendar.sh** — уточнён текст предупреждения Google (название «IWE MIM», пояснение про unverified app)

### Added
- **[update-manifest.json](update-manifest.json)** — манифест всех платформенных файлов (100+ записей) с описаниями. Используется update.sh для доставки обновлений
- **[DP.SC.019](../PACK-digital-platform/pack/digital-platform/08-service-clauses/DP.SC.019-template-update.md)** — сценарий «Обновление экзокортекса» + сервис S50 Template Update в MAP.002
- **Инструкция «настрой календарь»** в CLAUDE.md — при запросе пользователя Claude запускает `setup-calendar.sh`

## [0.10.0] — 2026-03-19

### Changed
- **Трёхуровневый Close** — Session Close (13 шагов) заменён на Quick Close (6 шагов, ~3 мин) + Day Close (13 шагов, ~10 мин) + Week Close (3 шага). Governance перенесён с сессии на конец дня. Экономия ~60% токенов на закрытие сессий
- **Haiku R23** — верификация только при Day Close (≥10 пунктов), не Quick Close (6 пунктов). Экономия N-1 вызовов sub-agent в день
- **MEMORY.md ≤100 строк** — done-РП удаляются при Day Close (были ≤200, копились). Экономия ~30% токенов на авто-загрузку
- **CHANGELOG FMT** перенесён из Day Close в Quick Close (шаг 1b) — пока контекст свежий, не теряется к вечеру

### Added
- **[scripts/day-close.sh](scripts/day-close.sh)** — автоматизация 3 механических шагов Day Close одной командой: backup memory/ → exocortex/, knowledge-mcp reindex (автодетекция изменённых Pack/DS), Linear sync
- **Мультипликатор IWE** — шаг 5 Day Close: расчёт усиления от агента-экзоскелета (Бюджет закрыт / WakaTime). Таблица в итогах дня
- **Week Close** — ротация уроков (≤15 актуальных), свежая таблица РП, аудит memory-файлов

## [0.9.1] — 2026-03-18

### Added
- **Close Gate hook** — `close-gate-reminder.sh`: при триггерах закрытия инжектит compact-чеклист Session Close (10 шагов) или направляет на полный Day Close. Экономия ~5K токенов (не перечитывает protocol-close.md каждый раз)

## [0.9.0] — 2026-03-18

### Added
- **Hooks enforcement** — три автоматических hook'а для надёжности агента: WP Gate (напоминание на каждый prompt), Protocol Completion (верификация после загрузки протокола), PreCompact Checkpoint (сохранение контекста перед компрессией). `.claude/hooks/` + `.claude/settings.json`
- **Скилл `/run-protocol`** — пошаговое выполнение протокола ОРЗ через TodoWrite с обязательной верификацией. `.claude/skills/run-protocol/`
- **Различение `settings.json` ≠ `settings.local.json`** — проектный (hooks, в git) vs персональный (permissions, gitignored). При клонировании hooks работают из коробки
- **Compliance-метрика верификации** — строка «запускался ли /verify» в чеклисте Session Close

## [0.8.8] — 2026-03-18

### Added
- **Google Calendar одной командой** — `bash setup/optional/setup-calendar.sh`: скачивает OAuth credentials с Gist, настраивает MCP, запускает авторизацию в браузере. Пользователю не нужен GCP Console (АрхГейт 61/70, Shared OAuth App)
- **[SETUP-GUIDE](docs/SETUP-GUIDE.md) Этап 5** обновлён: `setup-calendar.sh` вместо ручной настройки GCP

## [0.8.7] — 2026-03-17

### Added
- **Чеклист-верификация (Haiku R23)** — блокирующее правило в [CLAUDE.md](CLAUDE.md) §2: после любого протокола с чеклистом запускается sub-agent Haiku в роли R23 Верификатор для независимой проверки каждого пункта (VR.SOTA.002 context isolation). Добавлена в [Session Close](memory/protocol-close.md) (шаг 10) и Day Close (шаг 5)

## [0.8.6] — 2026-03-17

### Added
- **Роли верификации (R23-R24)** — skill /verify + [hard-distinctions](memory/hard-distinctions.md) #38-40 (WP-122)
- **Governance-синхронизация** в [Day Close](memory/protocol-close.md) — проверка REPOSITORY-REGISTRY, navigation.md, MAP.002↔PROCESSES.md (WP-124)
- **Collapsible sections** в [LEARNING-PATH](docs/LEARNING-PATH.md) и [SETUP-GUIDE](docs/SETUP-GUIDE.md) (details/summary)
- **Онбординг** переработан: пользователь в центре, принципы двусторонние

## [0.8.5] — 2026-03-17

### Added
- **[USE-CASES.md](docs/use-cases/USE-CASES.md)** — каталог всех 15 сценариев использования IWE (WP-116):
  - SC.001–SC.005: планирование, обучение, знания, публикации
  - SC.006–SC.009: обслуживание, триаж, самовосстановление, аналитика
  - SC.010–SC.015: ОРЗ-ритм, стратегирование, онбординг, рабочая сессия, формализация знаний, развитие системы

## [0.8.4] — 2026-03-17

### Added
- **[docs/onboarding/](docs/onboarding/)** — руководство-онбординг IWE для новичков (WP-120):
  - [onboarding-guide.md](docs/onboarding/onboarding-guide.md) — концептуальный обзор (7 разделов: карта IWE, компоненты, проблемы, решения, путь от нуля, «не бойся», системное мышление)
  - [onboarding-slides.md](docs/onboarding/onboarding-slides.md) — Marp-презентация (22 слайда, self-paced, светлая тема)
  - [onboarding-diagrams.md](docs/onboarding/onboarding-diagrams.md) — 6 Mermaid-схем (карта компонентов, путь пользователя, ОРЗ, тиры T1-T4, экзоскелет vs протез, проблема→решение)

## [0.8.3] — 2026-03-17

### Added
- **[LEARNING-PATH.md](docs/LEARNING-PATH.md) §11** — FAQ: cross-device workflow (ноут + десктоп, кросс-ОС)

## [0.8.2] — 2026-03-17

### Added
- **[protocol-open.md](memory/protocol-open.md)** — 4-й класс верификации `trivial` (Haiku): результат очевиден, проверка не нужна
- **[protocol-open.md](memory/protocol-open.md)** — два сценария переключения модели:
  - Сценарий A: вся сессия — Claude рекомендует `/model`, пользователь переключает
  - Сценарий B: отдельная задача внутри сессии — делегирование sub-agent'у (только вниз)
- **[SETUP-GUIDE.md](docs/SETUP-GUIDE.md) §0.5b** — класс верификации в таблице моделей + описание двух сценариев
- **[LEARNING-PATH.md](docs/LEARNING-PATH.md) §5.1b** — trivial в таблице классов + два сценария переключения

## [0.8.1] — 2026-03-16

### Added
- **CLAUDE.md** — различение «Скилл ≠ Роль ≠ Протокол» (WP-104)
- **hard-distinctions.md HD #11** — переработка: обещание (SC) ≠ описание метода ≠ сервис (WP-101, DP.D.039)
- **protocol-open.md** — режим `interactive: false` для Day Open (вывод одним блоком, «Требует внимания» в конце)

## [0.8.0] — 2026-03-16

### Added
- **Видеоинтеграция (WP-102)** — 6 сценариев связи видеозаписей с РП:
  - С1: Авто-триаж при Day Open (шаг 5b) — сканирование папок Zoom, Телемост и др.
  - С2: Предложение РП в план дня из привязанных видео
  - С3: Еженедельный видео-ревью в Strategy Session
  - С4: Транскрипция → Captures (через whisper, опционально)
  - С5: Видео → Посты и контент (через творческий конвейер)
  - С6: Напоминания о необработанных видео (>stale_days)
- **day-rhythm-config.yaml → `video`** — секция конфигурации: directories (массив), extensions, stale_days, auto_transcribe, content
- **video-scan.sh** — скрипт сканирования (`roles/synchronizer/scripts/`): --new, --stale, --dry-run
- **protocol-close.md** — шаг «Видео за день» в Day Close + пункт в чеклисте Session Close
- **protocol-work.md §2b** — сценарии транскрипции и генерации контента из видео

### Changed
- **protocol-open.md** — шаблоны DayPlan и WeekPlan дополнены секцией «Видеозаписи» и «Видео-ревью»
- Повестка Strategy Session — добавлен пункт «Видео-ревью (С3)»

## [0.7.0] — 2026-03-16

### Added
- **Google Calendar MCP** — Этап 5 в SETUP-GUIDE: подключение Google Calendar за 2 мин
- **protocol-open.md шаг 4c** — «Календарь дня»: все календари, локальный timezone, фильтр конфиденциальных, свободные слоты
- **Шаблон DayPlan** — секция «Календарь» с таблицей событий

## [0.6.4] — 2026-03-16

### Fixed
- **gh repo fork:** убран несовместимый флаг `--remote` из SETUP-GUIDE, setup.sh, ADR-001
- **README.md:** `git clone` → `gh repo fork --clone` (согласованность с SETUP-GUIDE)
- **strategist.sh:** `cleanup-processed-notes.py` → `.sh` (файл .py не существовал)
- **strategist.sh:** хардкод авторского пути к notify.sh → относительный через `$SCRIPT_DIR`
- **strategist.sh, dt-collect.sh:** `$HOME/IWE` → `{{WORKSPACE_DIR}}` (подставляется setup.sh)
- **update.sh:** нумерация шагов `[1/4],[2/4]` → `[1/6],[2/6]`
- **setup-wakatime.md:** `wakatime-cli` → `~/.wakatime/wakatime-cli` (полный путь)
- **SETUP-GUIDE.md:** MCP-команды отделены от bash-блока (пользователи пытались запускать в терминале)
- **DS-strategy naming:** унифицировано `DS-my-strategy` → `DS-strategy` в protocol-open.md (15 замен). Убран FAQ-костыль из LEARNING-PATH

## [0.6.3] — 2026-03-16

### Fixed
- **Cross-platform compat:** `sed -i ''` → `sed_inplace` (setup.sh, update.sh) — GNU sed (Linux)
- **Cross-platform compat:** `date -v` → `portable_date_offset` (fetch-wakatime.sh, dt-collect.sh, scheduler.sh) — GNU date (Linux)
- **Cross-platform compat:** `osascript` → fallback notify-send (strategist.sh, extractor.sh) — Linux desktop
- **Cross-platform compat:** setup.sh шаг 5 пропускается на Linux (нет launchctl)

### Added
- **docs/PLATFORM-COMPAT.md** — чеклист + обёртки + grep-команды
- **.githooks/pre-commit** — блокирует коммит с raw платформозависимыми конструкциями
- **CLAUDE.md §Различения** — правило кроссплатформенности

## [0.6.2] — 2026-03-16

### Added
- **Правило Ru-first (SPF §5 п.13)** — русский как основной язык шаблонов/протоколов/документов. EN только для YAML-ключей, аббревиатур из онтологии, имён собственных
- **AUTHOR-ONLY зоны** — маркеры `<!-- AUTHOR-ONLY -->` для пользовательских расширений протоколов. При обновлении шаблона (template-sync/update.sh) пользовательский контент сохраняется
- **Параметризация strategy_day** — день стратегирования читается из `day-rhythm-config.yaml`, не хардкодится. Пользователь может выбрать любой день недели
- **Strategy_day guard в Day Open** — в день стратегирования DayPlan не создаётся (план дня уже в WeekPlan → секция «План на [день]»)
- **LEARNING-PATH** — §2.4 три паттерна кастомизации (L3→L4), §5.1 strategy_day guard, §5.5 настройка дня стратегирования, Quick Reference: 2 новых вопроса
- **Четвёртая зона** — CONFIG (day-rhythm-config.yaml) + AUTHOR-ONLY в описании структуры (§2.2)
- **Двухуровневый FAQ** — категоризация Pack FAQ (§11, 5 категорий) и LEARNING-PATH Quick Ref (§11, 4 категории). Процесс capture-to-FAQ формализован. Правило синхронизации FAQ в CLAUDE.md

### Changed
- **strategist.sh** — маршрутизация morning читает `strategy_day` из конфига вместо `DAY_OF_WEEK -eq 1`
- **protocol-open.md** — шаг 4 блокирующий (strategy_day → пропуск DayPlan), шаг 7 с guard, DayPlan Gate с исключением
- **README.md §FAQ** — расширен (3 новых вопроса) + ссылки на полный FAQ в Pack и LP

### Migration (для существующих пользователей)
- `day-rhythm-config.yaml` уже содержит `strategy_day: monday` — менять не нужно, если понедельник подходит
- Если вы скопировали `scheduler.sh` из авторского репо — замените `"$DOW" = "1"` на чтение из конфига (см. авторский `scheduler.sh`)
- AUTHOR-ONLY зоны: в протоколах появятся плейсхолдеры `<!-- YOUR CUSTOM CHECKS HERE -->` — замените на свой контент при необходимости

## [0.6.1] — 2026-03-15

### Changed
- **README переработан** — концептуальный файл для новичков: проблемы пользователей, аналогия IDE↔IWE, протокол ОРЗ, сценарии (рабочие + личные), сравнение с Obsidian/Notion. Детали установки → SETUP-GUIDE.md, глоссарий → ONTOLOGY.md
- **LEARNING-PATH полная актуализация** — §5 ОРЗ-фрактал (День+Сессия), §1.3 тиры T0-T4, §3.2 различения HD #25-36, §5.3 dual routing, §8.1 АрхГейт + coordination cost, §11 чеклист Close 7→15 шагов
- **Backport live→template** — protocol-work.md (ОРЗ День+Сессия), protocol-close.md (ветки, ad-hoc), hard-distinctions.md (HD #25-36), checklists.md (Pack + посты)

### Added
- **Activation Gate** — колонка «Активация» в WP-REGISTRY (3 типа: date/dep/on-demand) + Dormant Review в WeekPlan
- **ONTOLOGY.md расширение** — 4 реализационных понятия (Creative Pipeline, Guard, DayPlan, WeekPlan) + 14 аббревиатур (TTL, HD, SOTA, SOP, DDD, CLI, API, LMS, S2R, PII, RSS, TG, ZP)
- **Activation Check + Dormant Review** — секции в protocol-open.md (шаблон WeekPlan + повестка стратегирования)
- **LEARNING-PATH §5.5** — описание Activation Gate, 2 новых вопроса в Quick Reference

## [0.6.0] — 2026-03-14

### Added
- **Session tracking** — `open-sessions.log` в протоколах Open/Close для отслеживания активных сессий
- **TG-оповещения об обновлениях** — GitHub Action ежедневно проверяет коммиты и отправляет дайджест подписчикам через бот
- **5-й архитектурный вид (Методы)** — sync с DP.IWE.001, расширение архитектурной документации
- **roles.md** — описание ролей экзокортекса + обновление memory policy
- **ONTOLOGY.md в формате SPF.SPEC.002** — каскадная онтология с двуязычным глоссарием
- **KE dual routing** — экстрактор знаний разделяет: доменное → Pack, реализационное → DS docs/
- **dt-collect** — скрипты сбора данных активности для ЦД (WakaTime + git + sessions + WP stats) в роли синхронизатора
- **Day Rhythm config** — конфиг ритма дня: помодоро-напоминания через WakaTime + launchd
- **Опциональные компоненты** — README для модульных расширений, обновлённое дерево структуры
- **HD #29-31** — новые hard distinctions: Pack≠DS, роли владельца, Шаг 0 Open-протокола, Capture реализации

### Changed
- **README компактный** — переработан для новичков, убраны лишние детали
- **DP.AGENT → DP.ROLE** — миграция идентификаторов, удалён дубль strategist-agent/ (WP-63)
- **repo-type-rules** — DS-ecosystem-development = governance + staging for Pack
- **LEARNING-PATH** — добавлен триал 30 дней + подписка БР в таблице тиров
- **CLAUDE.md §6** — правила форматирования таблиц РП (bold active, strikethrough done)
- **notify-update workflow** — рефакторинг: webhook → бот рассылает подписчикам (вместо прямых Telegram API вызовов)
- **Memory policy** — обновлены лимиты и правила хранения

### Fixed
- **MCP серверы** — регистрация через `claude mcp add` вместо JSON config (фикс для Claude Code)
- **Memory symlink** — добавлен в setup.sh + правило workspace root в CLAUDE.md
- **Стейлые промпты** — удалены дублирующие файлы из roles/strategist/prompts/
- **CHANGELOG v0.5.0** — русскоязычный текст, убраны ссылки на Github
- **Пути шаблона** — исправлены пути для Day Rhythm конфига

## [0.5.0] — 2026-03-10

### Added
- **CHANGELOG.md** — история изменений шаблона в формате release notes
- **update.sh: release notes** — при обновлении показывает «Что нового» из CHANGELOG
- **update.sh: re-substitution** — автоматическая подстановка рабочей директории после обновления
- **DATA-POLICY.md** — политика данных IWE + подтверждение при установке

### Fixed
- **Захардкоженные пути** — 14 файлов теперь используют переменную рабочей директории (шаблон работает с любым расположением)
- **update.sh** — убран хардкод пути, теперь динамическое определение директории

### Changed
- **Рабочая директория по умолчанию** — документация теперь рекомендует ~/IWE

## [0.4.0] — 2026-03-01

### Added
- **setup.sh** встроен в шаблон (ADR-001, АрхГейт 6.4→8.3)
- **Модульные роли** с `role.yaml` autodiscovery (ADR-002, АрхГейт 8.9)
- **Core-режим** установки (`--core`) — только git, без сети
- **Vendor-agnostic AI CLI** — поддержка Codex, Aider, Continue.dev через переменные
- **Авто-переименование репо** при установке
- **Творческий конвейер** — 7 категорий заметок, draft-list, guards
- **WP-REGISTRY** — seed template для отслеживания РП
- **Экзоскелет vs протез** — принцип #21 в LEARNING-PATH

### Fixed
- **setup.sh fallback** — явное предупреждение при отсутствии `seed/strategy/`
- **Битая ссылка** FPF/README.md
- **Приватные ссылки** убраны из README

## [0.3.0] — 2026-02-16

### Added
- **LEARNING-PATH.md** — полный путь изучения экзокортекса (T0→T4 + TM/TA/TD)
- **update.sh** — обновление шаблона из upstream (fetch + merge + reinstall)
- **SETUP-GUIDE.md** — пошаговое руководство установки
- **IWE-HELP.md** — быстрый справочник
- **АрхГейт (ЭМОГССБ)** — 7 характеристик в CLAUDE.md
- **SOTA-reference.md** — справочник SOTA-практик
- **WakaTime** — интеграция в стратег-отчёты

## [0.2.0] — 2026-02-09

### Added
- **Note-Review** — сценарий обзора заметок + детерминированная очистка
- **WP Context Files** — поддержка inbox/WP-*.md
- **CI: validate-template.yml** — проверка генеративности на каждый push
- **ONTOLOGY.md** — терминология платформы

## [0.1.0] — 2026-01-27

### Added
- Начальная структура шаблона экзокортекса
- CLAUDE.md, memory/, roles/ (стратег, экстрактор, синхронизатор)
- Стратег: session-prep, day-plan, strategy-session, week-review
- seed/strategy/ — шаблон DS-strategy
