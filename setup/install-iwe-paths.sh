#!/bin/bash
# install-iwe-paths.sh — генерация workspace/.iwe-paths + sourcing из ~/.zshenv.
#
# Source-of-truth для IWE_* path-переменных (WP-219, DP.FM.009).
# Вызывается из:
#   - setup.sh (первичная установка)
#   - scripts/migrate-to-runtime-target.sh (миграция 0.28.x → 0.29.x)
#   - update.sh (повторная генерация после апгрейда — на случай если шаблон строки меняется)
#
# OwnerIntegrity: один файл — одно место. Раньше блок был дублирован в setup.sh [4d];
# при миграции ~/.iwe-paths не апгрейдился (Round 5 Евгения, 27 апр).
#
# Usage:
#   bash install-iwe-paths.sh --workspace PATH --governance REPO_NAME
#       [--skip-zshenv] [--dry-run] [--quiet]
#
# Exit codes:
#   0 — успех
#   1 — некорректные аргументы

set -eu

WORKSPACE_DIR=""
GOVERNANCE_REPO=""
DRY_RUN=false
QUIET=false
SKIP_ZSHENV=false

while [ $# -gt 0 ]; do
    case "$1" in
        --workspace)  WORKSPACE_DIR="$2"; shift 2 ;;
        --governance) GOVERNANCE_REPO="$2"; shift 2 ;;
        --dry-run)    DRY_RUN=true; shift ;;
        --skip-zshenv) SKIP_ZSHENV=true; shift ;;
        --quiet|-q)   QUIET=true; shift ;;
        --help|-h)
            grep '^#' "$0" | head -20
            exit 0
            ;;
        *)
            echo "ERROR: Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

if [ -z "$WORKSPACE_DIR" ]; then
    echo "ERROR: --workspace обязателен" >&2
    exit 1
fi

WORKSPACE_DIR="${WORKSPACE_DIR/#\~/$HOME}"
GOVERNANCE_REPO="${GOVERNANCE_REPO:-DS-strategy}"

# WP-7 F161 (peer session 2026-09-21-04-wp537-wp7-fmt-decisions-followup,
# Claude+Codex): a live scripts/ checkout at workspace root is canonical
# and ahead of the template's own copy (which is deliberately trimmed,
# WP-546) -- prefer it when present, fall back to the template only when
# there is no live checkout to defer to. Resolved here, once, at install
# time (not as a runtime if/else in the generated file): .iwe-paths is a
# flat list of literal export lines, same as every other IWE_* var in it,
# and T25 (setup/test-update-edge-cases.sh) asserts exactly one
# `^export IWE_` line per variable.
#
# Issue #957: "a live checkout" is a REGULAR (non-symlink) session-guard.sh in
# $WORKSPACE_DIR/scripts, not just an existing directory. A scripts/ with only
# a README and audit logs, or personal scripts plus symlinks into the template,
# is not a checkout: pointing IWE_SCRIPTS there hides every platform script.
# The marker proves "live checkout", not completeness of its file set.
# Keep in sync with .claude/lib/iwe-env-bootstrap.sh (same rule, same marker).
SCRIPTS_MARKER="$WORKSPACE_DIR/scripts/session-guard.sh"
if [ -f "$SCRIPTS_MARKER" ] && [ ! -L "$SCRIPTS_MARKER" ]; then
    IWE_SCRIPTS_TARGET="\$IWE_WORKSPACE/scripts"
else
    IWE_SCRIPTS_TARGET="\$IWE_TEMPLATE/scripts"
fi

# Issue #966: MC-sessions is created on demand, not by setup.sh (pilot decision
# 18.08, ADR-004). resolve_orz_sessions_dir (scripts/session-guard.sh) reads an
# EXPLICIT IWE_SESSIONS_ROOT as a deliberate choice and refuses without any
# fallback, so naming a directory that was never created made `session-guard.sh
# open` fail on every installation that has not adopted MC-sessions. Name it only
# while it exists; otherwise write an EMPTY value: the resolver tests
# `[ -n "${IWE_SESSIONS_ROOT:-}" ]` (so empty == unset and its legacy fallback with
# a WARN stays reachable) and the file keeps exactly eight `export IWE_` lines
# (T25). A directory that exists but is not a git repository still gets the path:
# the resolver's loud refusal is the intended signal of a broken migration (ADR-004).
if [ -d "$WORKSPACE_DIR/MC-sessions" ]; then
    IWE_SESSIONS_ROOT_TARGET="\$IWE_WORKSPACE/MC-sessions"
else
    IWE_SESSIONS_ROOT_TARGET=""
fi

IWE_ENV_FILE="$WORKSPACE_DIR/.iwe-paths"
ZSHENV_FILE="$HOME/.zshenv"
# issue #808: .zshenv is read only by zsh. On Linux/WSL, where bash is the
# default interactive shell, IWE_* never reached the shell at all — install
# into .bashrc too so both shells pick up the same workspace. --skip-zshenv
# (its name predates this fix) already means "another workspace/tool owns
# this host's shell rc files" at every call site, so it gates both targets.
BASHRC_FILE="$HOME/.bashrc"
IWE_ENV_MARKER="# IWE environment (WP-219, DP.FM.009): lookup-слой для путей к скриптам"

if $DRY_RUN; then
    $QUIET || echo "  [DRY RUN] Would write $IWE_ENV_FILE (workspace=$WORKSPACE_DIR, governance=$GOVERNANCE_REPO)"
    if $SKIP_ZSHENV; then
        $QUIET || echo "  [DRY RUN] Would leave $ZSHENV_FILE and $BASHRC_FILE unchanged (--skip-zshenv)"
    else
        $QUIET || echo "  [DRY RUN] Would ensure $ZSHENV_FILE and $BASHRC_FILE source \$WORKSPACE_DIR/.iwe-paths"
    fi
    exit 0
fi

# Issue #957: update.sh redoes this file on every apply, always with --quiet, so
# an IWE_SCRIPTS switch used to pass without a word. Remember the previous value
# to announce a change after the write. The file keeps literals ($IWE_WORKSPACE,
# $IWE_TEMPLATE); compare and show them resolved, so an absolute path to the
# same directory is not reported as a change. Only the leading reference is
# replaced, by concatenation: in a ${v//pat/rep} replacement bash 5.2+ treats
# '&' as the matched text (patsub_replacement), which would mangle a workspace
# path that contains one.
resolve_paths_literal() {
    local value="$1"
    # shellcheck disable=SC2016 # literal "$IWE_*" references, exactly as written in .iwe-paths
    case "$value" in
        '$IWE_WORKSPACE' | '$IWE_WORKSPACE'/*)
            value="$WORKSPACE_DIR${value#\$IWE_WORKSPACE}" ;;
        '$IWE_TEMPLATE' | '$IWE_TEMPLATE'/*)
            value="$WORKSPACE_DIR/FMT-exocortex-template${value#\$IWE_TEMPLATE}" ;;
    esac
    printf '%s' "$value"
}
OLD_IWE_SCRIPTS=""
if [ -f "$IWE_ENV_FILE" ]; then
    OLD_IWE_SCRIPTS=$(sed -n 's/^export IWE_SCRIPTS="\(.*\)"$/\1/p' "$IWE_ENV_FILE" | head -1)
fi

cat > "$IWE_ENV_FILE" <<IWEENV_EOF
# IWE environment variables
# Generated by install-iwe-paths.sh. Rerun setup.sh / migrate-to-runtime-target.sh / iwe-update to regenerate.
# Do not edit manually — changes will be lost.

export IWE_WORKSPACE="$WORKSPACE_DIR"
export IWE_ROOT="\$IWE_WORKSPACE"
export IWE_TEMPLATE="\$IWE_WORKSPACE/FMT-exocortex-template"
export IWE_SCRIPTS="$IWE_SCRIPTS_TARGET"
export IWE_ROLES="\$IWE_TEMPLATE/roles"
export IWE_RUNTIME="\$IWE_WORKSPACE/.iwe-runtime"
export IWE_GOVERNANCE_REPO="$GOVERNANCE_REPO"
export IWE_SESSIONS_ROOT="$IWE_SESSIONS_ROOT_TARGET"
IWEENV_EOF

$QUIET || echo "  ✓ $IWE_ENV_FILE written (workspace=$WORKSPACE_DIR)"

if [ -n "$OLD_IWE_SCRIPTS" ]; then
    OLD_SCRIPTS_RESOLVED=$(resolve_paths_literal "$OLD_IWE_SCRIPTS")
    NEW_SCRIPTS_RESOLVED=$(resolve_paths_literal "$IWE_SCRIPTS_TARGET")
    if [ "$OLD_SCRIPTS_RESOLVED" != "$NEW_SCRIPTS_RESOLVED" ]; then
        # Deliberately not gated by --quiet: this is the case --quiet callers must see.
        echo "  ⚠ IWE_SCRIPTS: $OLD_SCRIPTS_RESOLVED → $NEW_SCRIPTS_RESOLVED"
        echo "    Рабочая scripts/ берётся, только если в ней обычный (не симлинк) session-guard.sh; иначе — scripts/ шаблона. Проверьте, что путь ожидаемый."
        echo "    Новое значение подхватят только новые оболочки и Claude Code после перезапуска."
    fi
fi

# WP-529 Ф94 (peer-session 2026-09-08-32): $HOME/.iwe-paths was the ORIGINAL
# canonical file (Round 5, pre-WP-219) before the source-of-truth moved to
# $WORKSPACE_DIR/.iwe-paths above. Installs from that era can still have a
# real (non-symlink) file there that nothing regenerates or reads anymore —
# flag it so custom edits to it don't silently stop mattering unnoticed.
LEGACY_IWE_PATHS="$HOME/.iwe-paths"
if [ -f "$LEGACY_IWE_PATHS" ] && [ ! -L "$LEGACY_IWE_PATHS" ] && [ "$LEGACY_IWE_PATHS" != "$IWE_ENV_FILE" ]; then
    $QUIET || echo "  ⚠ Найден устаревший $LEGACY_IWE_PATHS (до WP-219) — больше не читается ни одним скриптом."
    $QUIET || echo "    Актуальный файл: $IWE_ENV_FILE. Проверьте $LEGACY_IWE_PATHS на предмет ручных правок и удалите его вручную."
fi

# issue #768: a foreign/unowned $ZSHENV_FILE (already pointing at a
# different, already-configured workspace, per the caller's ownership check)
# must not be touched — that real, per-user shell rc file is not scoped to
# $WORKSPACE_DIR the way $IWE_ENV_FILE above is.
# Idempotent: replaces both the legacy $HOME/.iwe-paths one-liner and any
# older managed block in $1 (marker presence alone is not proof that it
# sources this workspace), then appends a fresh block if missing.
install_iwe_env_block() {
    local rc_file="$1"
    if [ -f "$rc_file" ]; then
        local rc_tmp
        rc_tmp=$(mktemp)
        awk '
          /^# IWE environment \(WP-219, DP.FM.009\):/{skip=1; next}
          skip && /^unset _IWE_ROOT$/{skip=0; next}
          /\[ -f "\$HOME\/\.iwe-paths" \] && source "\$HOME\/\.iwe-paths"/{next}
          !skip{print}
        ' "$rc_file" > "$rc_tmp"
        mv "$rc_tmp" "$rc_file"
    fi
    if ! grep -qF "_IWE_ROOT=\"$WORKSPACE_DIR\"" "$rc_file" 2>/dev/null; then
        cat >> "$rc_file" <<RC_EOF

# IWE environment (WP-219, DP.FM.009): lookup-слой для путей к скриптам
_IWE_ROOT="$WORKSPACE_DIR"
[ -f "\$_IWE_ROOT/.iwe-paths" ] && source "\$_IWE_ROOT/.iwe-paths"
unset _IWE_ROOT
RC_EOF
        $QUIET || echo "  ✓ $rc_file → sources \$WORKSPACE_DIR/.iwe-paths"
    else
        $QUIET || echo "  ○ $rc_file already sources $WORKSPACE_DIR/.iwe-paths"
    fi
}

if $SKIP_ZSHENV; then
    $QUIET || echo "  ○ $ZSHENV_FILE and $BASHRC_FILE unchanged (--skip-zshenv)"
else
    install_iwe_env_block "$ZSHENV_FILE"
    # issue #808: bash (login or not) never reads .zshenv. touch -a creates an
    # empty .bashrc if none exists yet, same as a fresh shell would on first
    # write — matches .zshenv's own implicit behavior a few lines above.
    touch "$BASHRC_FILE"
    install_iwe_env_block "$BASHRC_FILE"
fi

# Auto-enable pre-commit hooks for IWE repos that have .githooks/
# (Claude peer-review, 2026-05-26 — BFS3)
for repo_dir in "$WORKSPACE_DIR"/* "$WORKSPACE_DIR"/*/*; do
    [ -d "$repo_dir/.git" ] || continue
    [ -d "$repo_dir/.githooks" ] || continue
    if [ "$(git -C "$repo_dir" config --local core.hooksPath 2>/dev/null)" != ".githooks" ]; then
        git -C "$repo_dir" config --local core.hooksPath .githooks
        $QUIET || echo "  ✓ $repo_dir → core.hooksPath=.githooks"
    fi
done
