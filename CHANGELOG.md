# Changelog

All notable changes to FMT-exocortex-template will be documented in this file.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning: [Semantic Versioning](https://semver.org/).

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
