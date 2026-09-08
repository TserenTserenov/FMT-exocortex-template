#!/usr/bin/env bash
# WP-5 Ф38 / #430 and #523: every Hindsight consumer must preserve the same
# optional, explicit-opt-in and no-autostart contract.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
DOC="$ROOT/docs/hindsight-setup.md"
SKILL="$ROOT/.claude/skills/week-close/SKILL.md"

require_text() {
    local file="$1"
    local text="$2"
    grep -Fq "$text" "$file" || {
        echo "FAIL: $file is missing required contract text: $text" >&2
        exit 1
    }
}

reject_text() {
    local file="$1"
    local text="$2"
    if grep -Fq "$text" "$file"; then
        echo "FAIL: $file still promises unsupported automation: $text" >&2
        exit 1
    fi
}

reject_text "$DOC" "No manual action required."
reject_text "$DOC" "Once running, IWE agents automatically:"
require_text "$DOC" "A standard IWE installation does not"
require_text "$DOC" "automatically invoke Recall, Retain, or Reflect."
require_text "$DOC" "\`IWE_HINDSIGHT_RETAIN=1\`"
require_text "$DOC" "Recall and Reflect require a separately"

reject_text "$SKILL" "L2-memory = always-on"
reject_text "$SKILL" "exocortex/hindsight/start.sh"
require_text "$SKILL" "только при явном подключении"
require_text "$SKILL" "не запускает его автоматически"
require_text "$SKILL" "N/A: Hindsight не настроен"
require_text "$SKILL" "автозапуска не было"

HEALTH_BLOCK=$(mktemp)
trap 'rm -f "$HEALTH_BLOCK"' EXIT
awk '
    /^#### 7f\. Hindsight/{section=1}
    section && /^```bash$/{code=1; next}
    code && /^```$/{exit}
    code{print}
' "$SKILL" > "$HEALTH_BLOCK"
[ -s "$HEALTH_BLOCK" ] || {
    echo "FAIL: could not extract the Week Close Hindsight health check" >&2
    exit 1
}

# No configuration must produce an explicit N/A without even invoking Docker.
HINDSIGHT_TEST_HOME=$(mktemp -d)
trap 'rm -f "$HEALTH_BLOCK"; rm -rf "$HINDSIGHT_TEST_HOME"' EXIT
mkdir -p "$HINDSIGHT_TEST_HOME/bin"
cat > "$HINDSIGHT_TEST_HOME/bin/docker" <<'SH'
#!/bin/sh
: > "$HINDSIGHT_DOCKER_CALLED"
exit 99
SH
chmod +x "$HINDSIGHT_TEST_HOME/bin/docker"
HINDSIGHT_DOCKER_CALLED="$HINDSIGHT_TEST_HOME/docker-called"
HINDSIGHT_OUT=$(HOME="$HINDSIGHT_TEST_HOME" IWE_HINDSIGHT_RETAIN= \
    HINDSIGHT_DOCKER_CALLED="$HINDSIGHT_DOCKER_CALLED" \
    PATH="$HINDSIGHT_TEST_HOME/bin:/usr/bin:/bin" bash "$HEALTH_BLOCK")
printf '%s' "$HINDSIGHT_OUT" | grep -Fq "N/A: Hindsight не настроен" || {
    echo "FAIL: unconfigured Week Close did not report Hindsight as N/A" >&2
    exit 1
}
[ ! -e "$HINDSIGHT_DOCKER_CALLED" ] || {
    echo "FAIL: unconfigured Week Close invoked Docker" >&2
    exit 1
}

LAUNCHCTL_START_PATTERN='launch''ctl start'
if grep -Eq "docker (compose )?(up|start)|bash .*start\\.sh|${LAUNCHCTL_START_PATTERN}|systemctl( --user)? start" "$HEALTH_BLOCK"; then
    echo "FAIL: Week Close health check contains an Hindsight autostart command" >&2
    exit 1
fi

# Configured-but-down must report the state without invoking a mutating Docker
# command. Configured-and-up may inspect ps/log/db only.
cat > "$HINDSIGHT_TEST_HOME/bin/docker" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$HINDSIGHT_DOCKER_CALLS"
case "$1" in
  ps)
    if [ "${FAKE_DOCKER_STATE:-down}" = "up" ]; then
      case "$*" in
        *'{{.Names}}'*) echo 'iwe-hindsight' ;;
        *) echo 'iwe-hindsight Up 1 hour' ;;
      esac
    fi
    ;;
  exec)
    [ "${FAKE_DOCKER_STATE:-down}" = "up" ] || exit 1
    echo '-rw------- 1 user user 12M /data/hindsight.db'
    ;;
  *)
    : > "$HINDSIGHT_MUTATION_ATTEMPTED"
    exit 99
    ;;
esac
SH
chmod +x "$HINDSIGHT_TEST_HOME/bin/docker"
mkdir -p "$HINDSIGHT_TEST_HOME/.iwe"
: > "$HINDSIGHT_TEST_HOME/.iwe/hindsight.env"
printf 'healthy-log\n' > "$HINDSIGHT_TEST_HOME/.iwe/hindsight.log"
HINDSIGHT_DOCKER_CALLS="$HINDSIGHT_TEST_HOME/docker-calls"
HINDSIGHT_MUTATION_ATTEMPTED="$HINDSIGHT_TEST_HOME/docker-mutating"

: > "$HINDSIGHT_DOCKER_CALLS"
HINDSIGHT_DOWN_OUT=$(HOME="$HINDSIGHT_TEST_HOME" IWE_HINDSIGHT_RETAIN= \
    HINDSIGHT_DOCKER_CALLS="$HINDSIGHT_DOCKER_CALLS" \
    HINDSIGHT_MUTATION_ATTEMPTED="$HINDSIGHT_MUTATION_ATTEMPTED" \
    FAKE_DOCKER_STATE=down PATH="$HINDSIGHT_TEST_HOME/bin:/usr/bin:/bin" \
    bash "$HEALTH_BLOCK")
printf '%s' "$HINDSIGHT_DOWN_OUT" | grep -Fq 'Container not running' || {
    echo "FAIL: configured-down Hindsight did not report the stopped container" >&2
    exit 1
}
[ ! -e "$HINDSIGHT_MUTATION_ATTEMPTED" ] || {
    echo "FAIL: configured-down Hindsight attempted a mutating Docker command" >&2
    exit 1
}

: > "$HINDSIGHT_DOCKER_CALLS"
HINDSIGHT_UP_OUT=$(HOME="$HINDSIGHT_TEST_HOME" IWE_HINDSIGHT_RETAIN= \
    HINDSIGHT_DOCKER_CALLS="$HINDSIGHT_DOCKER_CALLS" \
    HINDSIGHT_MUTATION_ATTEMPTED="$HINDSIGHT_MUTATION_ATTEMPTED" \
    FAKE_DOCKER_STATE=up PATH="$HINDSIGHT_TEST_HOME/bin:/usr/bin:/bin" \
    bash "$HEALTH_BLOCK")
printf '%s' "$HINDSIGHT_UP_OUT" | grep -Fq 'healthy-log' || {
    echo "FAIL: configured-up Hindsight did not inspect its log" >&2
    exit 1
}
printf '%s' "$HINDSIGHT_UP_OUT" | grep -Fq '/data/hindsight.db' || {
    echo "FAIL: configured-up Hindsight did not inspect its database size" >&2
    exit 1
}
grep -Fq 'exec iwe-hindsight ls -lh /data/hindsight.db' "$HINDSIGHT_DOCKER_CALLS" || {
    echo "FAIL: configured-up Hindsight did not perform the read-only DB inspection" >&2
    exit 1
}
[ ! -e "$HINDSIGHT_MUTATION_ATTEMPTED" ] || {
    echo "FAIL: configured-up Hindsight attempted a mutating Docker command" >&2
    exit 1
}

expected_retain_gate="[ \"\${IWE_HINDSIGHT_RETAIN:-}\" = \"1\" ]"
for adapter in scripts/kimi-peer-adapter.sh scripts/codex-peer-adapter.sh; do
    grep -Fq "$expected_retain_gate" "$ROOT/$adapter" || {
        echo "FAIL: $adapter no longer gates peer retain with IWE_HINDSIGHT_RETAIN=1" >&2
        exit 1
    }
done

if grep -R --include='*.json' -Fq 'hindsight_trigger.py' "$ROOT/.claude"; then
    echo "FAIL: default Claude configuration registers hindsight_trigger.py" >&2
    exit 1
fi

# #522: Obsidian is an optional editor for the narrow governance vault. Every
# onboarding surface must reject the unsafe workspace-root vault explicitly.
README="$ROOT/README.md"
CLAUDE="$ROOT/CLAUDE.md"
LEARNING_PATH="$ROOT/docs/LEARNING-PATH.md"
SETUP_GUIDE="$ROOT/docs/SETUP-GUIDE.md"

require_text "$README" 'отдельный governance-репозиторий (`DS-strategy`)'
require_text "$README" 'Корень IWE (`~/IWE`) как Obsidian vault не поддерживается'
require_text "$README" '`FPF/FPF-Spec.md`'
reject_text "$CLAUDE" "Без Obsidian"
require_text "$CLAUDE" 'governance-репозиторий `{{GOVERNANCE_REPO}}`'
require_text "$CLAUDE" 'корень `{{WORKSPACE_DIR}}` не открывать как vault'
require_text "$CLAUDE" '`FPF/FPF-Spec.md`'
require_text "$LEARNING_PATH" "Obsidian показывает белый экран при открытии IWE"
require_text "$LEARNING_PATH" 'Корень `~/IWE` как vault не поддерживается'
require_text "$LEARNING_PATH" '`FPF/FPF-Spec.md`'
require_text "$SETUP_GUIDE" 'Корень IWE (`~/IWE`) как Obsidian vault'
require_text "$SETUP_GUIDE" 'governance-репозиторий `DS-strategy`'
require_text "$SETUP_GUIDE" '`FPF/FPF-Spec.md`'
require_text "$SETUP_GUIDE" '**публичный** GitHub-репозиторий `DS-personal-guide`'
require_text "$SETUP_GUIDE" 'не задаёт'
require_text "$SETUP_GUIDE" 'уточняющих вопросов'
require_text "$SETUP_GUIDE" '`create_repository` и `github_status`'
require_text "$SETUP_GUIDE" 'серверный renderer'
reject_text "$SETUP_GUIDE" 'Скилл уточнит цель, доступный контекст'

echo "PASS: optional Hindsight, Obsidian and personal-guide contracts are explicit and safe"
