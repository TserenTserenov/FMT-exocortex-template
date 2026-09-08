"""End-to-end regression coverage for issue #533.

Every test uses a disposable workspace. The suite must never open or mutate
the pilot's installed fault database.
"""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import re
import shutil
import sqlite3
import stat
import subprocess
import sys
from contextlib import closing
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[2]
SEED = ROOT / "seed" / "strategy"
SKILL = ROOT / ".claude" / "skills" / "agent-fault" / "SKILL.md"
ROUTER = ROOT / "scripts" / "route-task.sh"
HOOK = ROOT / ".claude" / "hooks" / "inject-fault-profile.sh"
UPDATE = ROOT / "update.sh"
OPEN_EXTENSION = ROOT / "extensions" / "protocol-open.after.fault.md"
CLOSE_EXTENSION = ROOT / "extensions" / "protocol-close.checks.fault.md"
AGENT_FAULT_DOC = ROOT / "docs" / "AGENT-FAULT-PROCESS.md"
CLI_REL = Path("scripts/agent-fault/iwe_checklist_memory.py")
CLI = ROOT / CLI_REL
PROFILE_REL = Path("exocortex/agent-fault-profile")
DB_REL = PROFILE_REL / "iwe_memory.db"
EXPORT_REL = PROFILE_REL / "audit" / "faults.md"
SEED_LEGACY_SHIMS = (
    SEED / "scripts" / "iwe_checklist_memory.py",
    SEED / "scripts" / "sync_feedback_to_memory.py",
    SEED / "scripts" / "agent_fault_remind.py",
    SEED / "scripts" / "agent_fault_remind.sh",
)


def _skill_script_path() -> str:
    frontmatter = SKILL.read_text(encoding="utf-8").split("---", 2)[1]
    match = re.search(r'^\s*script_path:\s*["\']?([^"\'\n]+)', frontmatter, re.MULTILINE)
    assert match, "active agent-fault skill must declare routing.script_path"
    return match.group(1).strip()


def _first_bash_block(path: Path) -> str:
    match = re.search(r"```bash\n(.*?)\n```", path.read_text(encoding="utf-8"), re.DOTALL)
    assert match, f"{path.name} must contain an executable bash example"
    return match.group(1)


def _install_seed(tmp_path: Path, governance: str = "DS-private") -> tuple[Path, Path]:
    workspace = tmp_path / "iwe"
    governance_dir = workspace / governance
    workspace.mkdir(parents=True)
    shutil.copytree(SEED, governance_dir)
    return workspace, governance_dir


def _install_workspace_cli(workspace: Path) -> Path:
    installed_cli = workspace / CLI_REL
    installed_cli.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(CLI, installed_cli)
    return installed_cli


def _platform_env(workspace: Path, governance: str, tmp_path: Path) -> dict[str, str]:
    """Use IWE_* while setting conflicting legacy aliases to prove precedence."""

    home = tmp_path / "home"
    home.mkdir(exist_ok=True)
    env = os.environ.copy()
    env.update(
        {
            "HOME": str(home),
            "IWE_DIR": str(workspace),
            "IWE_ROOT": str(workspace),
            "IWE_WORKSPACE": str(workspace),
            "IWE_GOVERNANCE_REPO": governance,
            "IWE_SCRIPTS": str(ROOT / "scripts"),
            "WORKSPACE_DIR": str(tmp_path / "legacy-workspace-must-stay-empty"),
            "GOVERNANCE_REPO": "DS-legacy-must-stay-empty",
            "IWE_SESSION_ID": "test-issue-533",
            "PYTHONDONTWRITEBYTECODE": "1",
        }
    )
    return env


def _run_cli(
    env: dict[str, str],
    *args: str,
    permissive_umask: bool = False,
) -> subprocess.CompletedProcess[str]:
    kwargs: dict[str, object] = {}
    if permissive_umask:
        kwargs["preexec_fn"] = lambda: os.umask(0)
    return subprocess.run(
        [sys.executable, str(CLI), *args],
        env=env,
        capture_output=True,
        text=True,
        check=False,
        timeout=20,
        **kwargs,
    )


def _run_cli_concurrently(
    env: dict[str, str],
    args: tuple[str, ...],
    count: int,
) -> list[subprocess.CompletedProcess[str]]:
    command = (sys.executable, str(CLI), *args)
    return _run_commands_concurrently(env, [command] * count)


def _run_commands_concurrently(
    env: dict[str, str],
    commands: list[tuple[str, ...]],
) -> list[subprocess.CompletedProcess[str]]:
    """Release subprocesses through one pipe barrier for deterministic overlap."""

    read_fd, write_fd = os.pipe()
    wrapper = "import os,sys; os.read(0,1); os.execv(sys.argv[1], sys.argv[1:])"
    processes: list[subprocess.Popen[str]] = []
    try:
        for command in commands:
            processes.append(
                subprocess.Popen(
                    [
                        sys.executable,
                        "-c",
                        wrapper,
                        *command,
                    ],
                    stdin=read_fd,
                    env=env,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                )
            )
    finally:
        os.close(read_fd)
    try:
        os.write(write_fd, b"x" * len(commands))
    finally:
        os.close(write_fd)

    results: list[subprocess.CompletedProcess[str]] = []
    for process in processes:
        stdout, stderr = process.communicate(timeout=60)
        results.append(
            subprocess.CompletedProcess(
                process.args,
                process.returncode,
                stdout,
                stderr,
            )
        )
    return results


def _record(
    env: dict[str, str],
    fault: str,
    *,
    subject_kind: str = "runtime",
    subject_id: str = "runtime-a",
    protocol: str = "open",
    source_citation: str = "AGENTS.md: тестовая цитата",
    permissive_umask: bool = False,
) -> subprocess.CompletedProcess[str]:
    return _run_cli(
        env,
        "record",
        "--severity",
        "major",
        "--protocol",
        protocol,
        "--fault",
        fault,
        "--source-citation",
        source_citation,
        "--subject-kind",
        subject_kind,
        "--subject-id",
        subject_id,
        permissive_umask=permissive_umask,
    )


def _record_args(fault: str) -> tuple[str, ...]:
    return (
        "record",
        "--severity",
        "major",
        "--protocol",
        "open",
        "--fault",
        fault,
        "--source-citation",
        "AGENTS.md: конкурентная проверка",
        "--subject-kind",
        "runtime",
        "--subject-id",
        "runtime-a",
    )


def _write_catalog(path: Path, script_path: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        "\n".join(
            (
                "schema_version: '1.0'",
                "generated_at: '2026-08-24T00:00:00Z'",
                "total_entries: 1",
                "entries:",
                "  - name: agent-fault",
                "    routing:",
                "      executor: script",
                f"      script_path: {json.dumps(script_path)}",
                "      deterministic: true",
                "",
            )
        ),
        encoding="utf-8",
    )


def _init_git_repo(path: Path) -> None:
    subprocess.run(["git", "init", "-q", str(path)], check=True, timeout=10)
    subprocess.run(
        ["git", "-C", str(path), "config", "user.name", "Issue 533 test"],
        check=True,
        timeout=10,
    )
    subprocess.run(
        [
            "git",
            "-C",
            str(path),
            "config",
            "user.email",
            "issue-533@example.invalid",
        ],
        check=True,
        timeout=10,
    )


def _legacy_shim_snapshot(governance_dir: Path) -> tuple[object, ...]:
    states: list[object] = []
    for source in SEED_LEGACY_SHIMS:
        target = governance_dir / source.relative_to(SEED)
        if target.is_symlink():
            states.append(("symlink", os.readlink(target)))
        elif target.is_file():
            states.append(("file", target.read_bytes(), stat.S_IMODE(target.stat().st_mode)))
        elif target.exists():
            states.append(("other", target.stat().st_mode))
        else:
            states.append(("missing",))
    return tuple(states)


def _db_rows(db_path: Path, sql: str, params: tuple[object, ...] = ()) -> list[tuple]:
    with closing(sqlite3.connect(db_path)) as connection, connection:
        return connection.execute(sql, params).fetchall()


def _create_legacy_database(
    governance_dir: Path,
    *,
    content: str = "legacy fault",
    personality_id: str = "legacy-personality",
    context_fields: dict[str, object] | None = None,
) -> tuple[Path, str]:
    """Create the pre-subject schema without importing production code."""

    profile = governance_dir / PROFILE_REL
    profile.mkdir(parents=True, exist_ok=True)
    context = json.dumps(
        {
            "protocols": ["work"],
            "short_content": content,
            **(context_fields or {}),
        },
        ensure_ascii=False,
        sort_keys=True,
    )
    db_path = governance_dir / DB_REL
    with closing(sqlite3.connect(db_path)) as connection, connection:
        connection.execute(
            """
            CREATE TABLE facts (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                fact_type TEXT NOT NULL,
                content TEXT NOT NULL,
                context TEXT,
                trust_score REAL DEFAULT 0.5,
                created_at TEXT DEFAULT CURRENT_TIMESTAMP,
                session_id TEXT,
                personality_id TEXT,
                extra_payload TEXT
            )
            """
        )
        connection.execute(
            """INSERT INTO facts (
                   id, fact_type, content, context, trust_score, session_id,
                   personality_id, extra_payload
               ) VALUES (37, 'agent_fault', ?, ?, 0.8, 'legacy-session', ?, 'keep-me')""",
            (content, context, personality_id),
        )
        connection.commit()
    return db_path, context


def _update_hardening_function() -> str:
    return _update_shell_function("harden_agent_fault_profile_after_update")


def _update_shell_function(name: str) -> str:
    source = UPDATE.read_text(encoding="utf-8")
    match = re.search(
        rf"^{re.escape(name)}\(\) \{{\n.*?^\}}\n",
        source,
        re.MULTILINE | re.DOTALL,
    )
    assert match, f"update.sh must define {name}()"
    return match.group(0)


def _update_shell_array(name: str) -> str:
    source = UPDATE.read_text(encoding="utf-8")
    match = re.search(
        rf"^{re.escape(name)}=\(\n.*?^\)\n",
        source,
        re.MULTILINE | re.DOTALL,
    )
    assert match, f"update.sh must define {name}"
    return match.group(0)


def _update_legacy_shim_functions(
    *,
    fail_after: int | None = None,
    signal_after: int | None = None,
    create_during_scan: bool = False,
) -> str:
    names = (
        "agent_fault_git",
        "agent_fault_target_snapshot",
        "agent_fault_legacy_hash_is_blessed",
        "scan_legacy_agent_fault_import_consumers",
        "print_legacy_agent_fault_manual_remediation",
        "preflight_legacy_agent_fault_shims",
        "agent_fault_revalidate_shim_snapshot",
        "apply_legacy_agent_fault_shims",
        "backfill_legacy_agent_fault_shims",
    )
    source = _update_shell_array("AGENT_FAULT_LEGACY_SHIMS")
    source += _update_shell_function("hash_file")
    source += _update_shell_function("atomic_copy_executable")
    functions = {name: _update_shell_function(name) for name in names}
    if create_during_scan:
        functions["scan_legacy_agent_fault_import_consumers"] = functions[
            "scan_legacy_agent_fault_import_consumers"
        ].replace(
            "scan_legacy_agent_fault_import_consumers()",
            "scan_legacy_agent_fault_import_consumers_original()",
            1,
        )
    source += "".join(functions[name] for name in names)
    if create_during_scan:
        source += r'''
scan_legacy_agent_fault_import_consumers() {
    local scan_output scan_rc=0
    scan_output=$(scan_legacy_agent_fault_import_consumers_original "$@") || scan_rc=$?
    if [ ! -e "$ISSUE533_CONCURRENT_TARGET" ]; then
        printf '#!/usr/bin/env python3\n# concurrent user-owned shim\n' > \
            "$ISSUE533_CONCURRENT_TARGET"
    fi
    [ -z "$scan_output" ] || printf '%s\n' "$scan_output"
    return "$scan_rc"
}
'''
    if fail_after is not None:
        source += f"""
ISSUE533_COPY_COUNT=0
atomic_copy_executable() {{
    ISSUE533_COPY_COUNT=$((ISSUE533_COPY_COUNT + 1))
    if [ "$ISSUE533_COPY_COUNT" -eq {fail_after} ] && [[ "$1" == "$SCRIPT_DIR"/seed/* ]]; then
        return 1
    fi
    mkdir -p "$(dirname "$2")" || return 1
    cp "$1" "$2" || return 1
    chmod +x "$2" || return 1
}}
"""
    if signal_after is not None:
        source += f"""
ISSUE533_COPY_COUNT=0
atomic_copy_executable() {{
    ISSUE533_COPY_COUNT=$((ISSUE533_COPY_COUNT + 1))
    mkdir -p "$(dirname "$2")" || return 1
    cp "$1" "$2" || return 1
    chmod +x "$2" || return 1
    if [ "$ISSUE533_COPY_COUNT" -eq {signal_after} ]; then
        kill -TERM "$$"
    fi
}}
"""
    return source


def _run_update_legacy_shim_backfill(
    workspace: Path,
    governance: str,
    *,
    fail_after: int | None = None,
    create_during_scan: Path | None = None,
) -> subprocess.CompletedProcess[str]:
    script = (
        _update_legacy_shim_functions(
            fail_after=fail_after,
            create_during_scan=create_during_scan is not None,
        )
        + """
SCRIPT_DIR="$1"
WORKSPACE_DIR="$2"
EFFECTIVE_GOVERNANCE_REPO="$3"
PY_BIN="$4"
ISSUE533_CONCURRENT_TARGET="$5"
backfill_legacy_agent_fault_shims
"""
    )
    return subprocess.run(
        [
            "bash",
            "-c",
            script,
            "issue-533-legacy-shim-backfill",
            str(ROOT),
            str(workspace),
            governance,
            sys.executable,
            str(create_during_scan or ""),
        ],
        capture_output=True,
        text=True,
        check=False,
        timeout=30,
    )


def _run_update_hardening(
    workspace: Path,
    governance: str,
) -> subprocess.CompletedProcess[str]:
    script = (
        _update_hardening_function()
        + """
py_available() { return 0; }
SCRIPT_DIR="$1"
WORKSPACE_DIR="$2"
EFFECTIVE_GOVERNANCE_REPO="$3"
PY_BIN="$4"
harden_agent_fault_profile_after_update
"""
    )
    return subprocess.run(
        [
            "bash",
            "-c",
            script,
            "issue-533-update-hardening",
            str(ROOT),
            str(workspace),
            governance,
            sys.executable,
        ],
        capture_output=True,
        text=True,
        check=False,
        timeout=20,
    )


def _run_update_day_open_backfill(
    workspace: Path,
    governance: str,
    *,
    extra_env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    script = (
        _update_shell_function("atomic_copy_executable")
        + _update_shell_function("agent_fault_git")
        + _update_shell_function("backfill_governance_seed_script")
        + _update_shell_function("backfill_day_open_fault_reader")
        + """
SCRIPT_DIR="$1"
WORKSPACE_DIR="$2"
EFFECTIVE_GOVERNANCE_REPO="$3"
backfill_day_open_fault_reader
"""
    )
    return subprocess.run(
        [
            "bash",
            "-c",
            script,
            "issue-533-day-open-backfill",
            str(ROOT),
            str(workspace),
            governance,
        ],
        capture_output=True,
        text=True,
        env={**os.environ, **(extra_env or {})},
        check=False,
        timeout=20,
    )


def _load_cli_module():
    name = "issue_533_agent_fault_cli"
    spec = importlib.util.spec_from_file_location(name, CLI)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def test_delivery_contract_points_to_one_agent_neutral_cli():
    assert CLI.is_file(), "canonical agent-neutral CLI is missing from scripts/agent-fault/"
    assert _skill_script_path() == CLI_REL.as_posix()
    assert (SEED / PROFILE_REL / ".gitignore").is_file()
    assert all(path.is_file() for path in SEED_LEGACY_SHIMS)
    skill_text = SKILL.read_text(encoding="utf-8")
    assert '${IWE_FAULT_SUBJECT_KIND:?' in skill_text
    assert '${IWE_FAULT_SUBJECT_ID:?' in skill_text
    assert "IWE_FAULT_SUBJECT_ID:-claude-code" not in skill_text

    for wrapper in (
        ROOT / "scripts" / "agent_fault_remind.py",
        ROOT / "scripts" / "sync_feedback_to_memory.py",
        *SEED_LEGACY_SHIMS,
    ):
        source = wrapper.read_text(encoding="utf-8")
        assert "sqlite3" not in source, f"{wrapper.name} remains a second DB implementation"
        assert not re.search(
            r"\b(?:CREATE|ALTER|INSERT|UPDATE|DELETE)\s+(?:TABLE|INTO|facts|feedback)",
            source,
            re.IGNORECASE,
        ), f"{wrapper.name} contains schema or DML logic"
    assert "agent-fault" in SEED_LEGACY_SHIMS[0].read_text(encoding="utf-8")


def test_manifest_explicitly_delivers_agent_fault_release_contract():
    expected = {
        CLI_REL.as_posix(),
        "seed/strategy/exocortex/agent-fault-profile/.gitignore",
        *(path.relative_to(ROOT).as_posix() for path in SEED_LEGACY_SHIMS),
        "scripts/tests/test_issue_533_agent_fault_delivery.py",
        "scripts/tests/test_issue_536_day_close_backup.sh",
    }
    generator = (ROOT / "generate-manifest.sh").read_text(encoding="utf-8")
    manifest = json.loads((ROOT / "update-manifest.json").read_text(encoding="utf-8"))
    delivered = {entry["path"] for entry in manifest["files"]}

    assert all(f'"{path}"' in generator for path in expected)
    assert expected <= delivered


def test_week_close_stats_documentation_names_one_exact_subject():
    match = re.search(
        r"\*\*В Week Close:\*\*\n```bash\n(.*?)\n```",
        AGENT_FAULT_DOC.read_text(encoding="utf-8"),
        re.DOTALL,
    )
    assert match, "Week Close agent-fault example must remain executable"
    commands = match.group(1)
    stats_position = commands.index("bash scripts/agent_fault_remind.sh --stats")
    assert commands.index("IWE_FAULT_SUBJECT_KIND=runtime") < stats_position
    assert commands.index("IWE_FAULT_SUBJECT_ID=claude-code") < stats_position


def test_update_backfills_the_governance_reader_that_day_open_executes(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
):
    workspace, governance_dir = _install_seed(tmp_path)
    installed_reader = governance_dir / "scripts" / "day-open-llm-fill.py"
    installed_reader.write_text(
        "#!/usr/bin/env python3\nraise SystemExit('stale reader must be replaced')\n",
        encoding="utf-8",
    )
    installed_reader.chmod(0o755)
    subprocess.run(["git", "init", "-q", str(governance_dir)], check=True, timeout=10)
    subprocess.run(
        ["git", "-C", str(governance_dir), "config", "user.name", "Issue 533 test"],
        check=True,
        timeout=10,
    )
    subprocess.run(
        [
            "git",
            "-C",
            str(governance_dir),
            "config",
            "user.email",
            "issue-533@example.invalid",
        ],
        check=True,
        timeout=10,
    )
    subprocess.run(
        ["git", "-C", str(governance_dir), "add", "--", "scripts/day-open-llm-fill.py"],
        check=True,
        timeout=10,
    )
    subprocess.run(
        ["git", "-C", str(governance_dir), "commit", "-qm", "old day-open reader"],
        check=True,
        timeout=10,
    )

    backfilled = _run_update_day_open_backfill(workspace, governance_dir.name)

    assert backfilled.returncode == 0, backfilled.stdout + backfilled.stderr
    assert installed_reader.read_bytes() == (
        SEED / "scripts" / "day-open-llm-fill.py"
    ).read_bytes()
    assert stat.S_IMODE(installed_reader.stat().st_mode) & 0o111
    update_source = UPDATE.read_text(encoding="utf-8")
    assert "if ! backfill_day_open_fault_reader" in update_source
    assert '"seed/strategy/scripts/day-open-llm-fill.py"' in (
        ROOT / "generate-manifest.sh"
    ).read_text(encoding="utf-8")
    for pipeline in (
        ROOT / "scripts" / "day-open-pipeline.sh",
        SEED / "scripts" / "day-open-pipeline.sh",
    ):
        assert '"$DS_STRATEGY/scripts/day-open-llm-fill.py"' in pipeline.read_text(
            encoding="utf-8"
        )

    env = _platform_env(workspace, governance_dir.name, tmp_path)
    env["IWE_FAULT_SUBJECT_KIND"] = "runtime"
    env["IWE_FAULT_SUBJECT_ID"] = "runtime-updated-day-open"
    fault = "обновлённый governance reader читает доставленный профиль"
    for _ in range(3):
        recorded = _record(env, fault, subject_id="runtime-updated-day-open")
        assert recorded.returncode == 0, recorded.stdout + recorded.stderr
    for key, value in env.items():
        monkeypatch.setenv(key, value)
    module_name = "issue_533_updated_governance_day_open"
    spec = importlib.util.spec_from_file_location(module_name, installed_reader)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    assert module.load_fault_profile() == f"🔴 [MAJOR | n=3] {fault}"

    local_reader = b"#!/usr/bin/env python3\n# local governance customization\n"
    installed_reader.write_bytes(local_reader)
    refused = _run_update_day_open_backfill(workspace, governance_dir.name)
    assert refused.returncode != 0
    assert "локальные изменения" in refused.stderr
    assert installed_reader.read_bytes() == local_reader


def test_day_open_backfill_ignores_alternate_index_and_preserves_tracked_deletion(
    tmp_path: Path,
):
    workspace, governance_dir = _install_seed(tmp_path)
    target = governance_dir / "scripts" / "day-open-llm-fill.py"
    _init_git_repo(governance_dir)
    subprocess.run(
        ["git", "-C", str(governance_dir), "add", "--", target.relative_to(governance_dir)],
        check=True,
        timeout=10,
    )
    subprocess.run(
        ["git", "-C", str(governance_dir), "commit", "-qm", "tracked reader"],
        check=True,
        timeout=10,
    )
    target.unlink()
    real_index = governance_dir / ".git" / "index"
    real_index_before = real_index.read_bytes()
    real_index_mtime = real_index.stat().st_mtime_ns
    alternate_index = tmp_path / "alternate-index"
    redirected_env = {**os.environ, "GIT_INDEX_FILE": str(alternate_index)}
    subprocess.run(
        ["git", "-C", str(governance_dir), "read-tree", "--empty"],
        env=redirected_env,
        check=True,
        timeout=10,
    )
    alternate_before = alternate_index.read_bytes()

    blocked = _run_update_day_open_backfill(
        workspace,
        governance_dir.name,
        extra_env={"GIT_INDEX_FILE": str(alternate_index)},
    )

    assert blocked.returncode != 0
    assert not target.exists()
    assert real_index.read_bytes() == real_index_before
    assert real_index.stat().st_mtime_ns == real_index_mtime
    assert alternate_index.read_bytes() == alternate_before


def test_day_open_backfill_refuses_tracked_deleted_uppercase_alias(
    tmp_path: Path,
):
    workspace, governance_dir = _install_seed(tmp_path)
    lowercase = governance_dir / "scripts" / "day-open-llm-fill.py"
    uppercase = governance_dir / "scripts" / "DAY-OPEN-LLM-FILL.PY"
    lowercase.rename(uppercase)
    _init_git_repo(governance_dir)
    subprocess.run(
        ["git", "-C", str(governance_dir), "config", "core.ignorecase", "true"],
        check=True,
        timeout=10,
    )
    subprocess.run(
        ["git", "-C", str(governance_dir), "add", "--", uppercase.relative_to(governance_dir)],
        check=True,
        timeout=10,
    )
    subprocess.run(
        ["git", "-C", str(governance_dir), "commit", "-qm", "uppercase reader"],
        check=True,
        timeout=10,
    )
    uppercase.unlink()
    index = governance_dir / ".git" / "index"
    index_before = index.read_bytes()
    index_mtime = index.stat().st_mtime_ns

    blocked = _run_update_day_open_backfill(workspace, governance_dir.name)

    assert blocked.returncode != 0
    assert not lowercase.exists()
    assert not uppercase.exists()
    assert "case-insensitive tracked alias" in blocked.stderr
    assert index.read_bytes() == index_before
    assert index.stat().st_mtime_ns == index_mtime


def test_update_atomically_replaces_blessed_historical_legacy_shims(tmp_path: Path):
    workspace, governance_dir = _install_seed(tmp_path)
    for source in SEED_LEGACY_SHIMS:
        (governance_dir / source.relative_to(SEED)).unlink()
    historical_shell = governance_dir / "scripts" / "agent_fault_remind.sh"
    historical_shell.write_text(
        """#!/bin/bash
# routing: helper  skill=day-open  called-by=sonnet
# see DP.SC.159, DP.ROLE.059
# WP-316: Agent Fault Profile reminder wrapper
# Usage: bash scripts/agent_fault_remind.sh [open|close|work]

PROTOCOL="${1:-work}"
cd "$(dirname "$0")/.." || exit 1
python3 scripts/agent_fault_remind.py --protocol "$PROTOCOL"
""",
        encoding="utf-8",
    )
    _init_git_repo(governance_dir)
    subprocess.run(
        ["git", "-C", str(governance_dir), "add", "--", "scripts/agent_fault_remind.sh"],
        check=True,
        timeout=10,
    )
    subprocess.run(
        ["git", "-C", str(governance_dir), "commit", "-qm", "historical FMT shim"],
        check=True,
        timeout=10,
    )
    index = governance_dir / ".git" / "index"
    index_before = index.read_bytes()

    result = _run_update_legacy_shim_backfill(workspace, governance_dir.name)

    assert result.returncode == 0, result.stdout + result.stderr
    for source in SEED_LEGACY_SHIMS:
        target = governance_dir / source.relative_to(SEED)
        assert target.read_bytes() == source.read_bytes()
        assert stat.S_IMODE(target.stat().st_mode) & 0o111
    assert index.read_bytes() == index_before


def test_update_skips_legacy_shims_when_governance_is_truly_absent(tmp_path: Path):
    workspace = tmp_path / "iwe"
    workspace.mkdir()
    governance_dir = workspace / "not-installed-governance"

    result = _run_update_legacy_shim_backfill(workspace, governance_dir.name)

    assert result.returncode == 0, result.stdout + result.stderr
    assert "governance repo не найден" in result.stdout
    assert not governance_dir.exists()


def test_update_creates_legacy_shims_in_clean_git_governance_without_scripts(
    tmp_path: Path,
):
    workspace = tmp_path / "iwe"
    governance_dir = workspace / "clean-governance"
    governance_dir.mkdir(parents=True)
    marker = governance_dir / "README.md"
    marker.write_text("clean governance fixture\n", encoding="utf-8")
    _init_git_repo(governance_dir)
    subprocess.run(
        ["git", "-C", str(governance_dir), "add", "--", marker.name],
        check=True,
        timeout=10,
    )
    subprocess.run(
        ["git", "-C", str(governance_dir), "commit", "-qm", "clean fixture"],
        check=True,
        timeout=10,
    )
    index = governance_dir / ".git" / "index"
    index_before = index.read_bytes()

    result = _run_update_legacy_shim_backfill(workspace, governance_dir.name)

    assert result.returncode == 0, result.stdout + result.stderr
    for source in SEED_LEGACY_SHIMS:
        target = governance_dir / source.relative_to(SEED)
        assert target.read_bytes() == source.read_bytes()
        assert stat.S_IMODE(target.stat().st_mode) & 0o111
    assert index.read_bytes() == index_before


@pytest.mark.parametrize("scripts_state", ("symlink", "file"))
def test_update_refuses_unsafe_existing_governance_scripts_path(
    tmp_path: Path,
    scripts_state: str,
):
    workspace = tmp_path / "iwe"
    governance_dir = workspace / "unsafe-governance"
    governance_dir.mkdir(parents=True)
    marker = governance_dir / "README.md"
    marker.write_text("unsafe scripts fixture\n", encoding="utf-8")
    _init_git_repo(governance_dir)
    subprocess.run(
        ["git", "-C", str(governance_dir), "add", "--", marker.name],
        check=True,
        timeout=10,
    )
    subprocess.run(
        ["git", "-C", str(governance_dir), "commit", "-qm", "unsafe fixture"],
        check=True,
        timeout=10,
    )
    scripts = governance_dir / "scripts"
    outside = tmp_path / "outside-scripts"
    if scripts_state == "symlink":
        outside.mkdir()
        scripts.symlink_to(outside, target_is_directory=True)
    else:
        scripts.write_text("not a directory\n", encoding="utf-8")
    index = governance_dir / ".git" / "index"
    index_before = index.read_bytes()

    blocked = _run_update_legacy_shim_backfill(workspace, governance_dir.name)

    assert blocked.returncode != 0
    assert "governance/scripts must be a real directory" in blocked.stderr
    assert index.read_bytes() == index_before
    if scripts_state == "symlink":
        assert not any(outside.iterdir())
    else:
        assert scripts.read_bytes() == b"not a directory\n"


@pytest.mark.parametrize(
    "consumer_source",
    (
        "from iwe_checklist_memory import init_db, DB_PATH\n",
        "import os, iwe_checklist_memory\n",
        "import os; import pkg.iwe_checklist_memory\n",
    ),
)
def test_update_refuses_ast_import_consumer_before_any_legacy_shim_write(
    tmp_path: Path,
    consumer_source: str,
):
    workspace, governance_dir = _install_seed(tmp_path)
    for source in SEED_LEGACY_SHIMS:
        (governance_dir / source.relative_to(SEED)).unlink()
    consumer = governance_dir / "scripts" / "verify-distinctions-compression.py"
    consumer.write_text(consumer_source, encoding="utf-8")
    _init_git_repo(governance_dir)
    subprocess.run(
        ["git", "-C", str(governance_dir), "add", "--", consumer.relative_to(governance_dir)],
        check=True,
        timeout=10,
    )
    subprocess.run(
        ["git", "-C", str(governance_dir), "commit", "-qm", "legacy import consumer"],
        check=True,
        timeout=10,
    )
    before = _legacy_shim_snapshot(governance_dir)
    index = governance_dir / ".git" / "index"
    index_before = index.read_bytes()

    blocked = _run_update_legacy_shim_backfill(workspace, governance_dir.name)

    assert blocked.returncode != 0
    assert "legacy import consumer" in blocked.stderr
    assert "read_faults" in blocked.stderr
    migrate_notice = blocked.stderr.index(
        "Migrate every listed legacy import consumer"
    )
    review_notice = blocked.stderr.index("Review each source/target diff")
    first_copy_command = blocked.stderr.index("cp ")
    assert migrate_notice < first_copy_command
    assert review_notice < first_copy_command
    assert _legacy_shim_snapshot(governance_dir) == before
    assert consumer.read_text(encoding="utf-8") == consumer_source
    assert index.read_bytes() == index_before


def test_update_refuses_unparseable_python_consumer_without_partial_writes(
    tmp_path: Path,
):
    workspace, governance_dir = _install_seed(tmp_path)
    for source in SEED_LEGACY_SHIMS:
        (governance_dir / source.relative_to(SEED)).unlink()
    consumer = governance_dir / "scripts" / "future-syntax.py"
    consumer_bytes = b"def syntactically_broken(:\n    pass\n"
    consumer.write_bytes(consumer_bytes)
    _init_git_repo(governance_dir)
    subprocess.run(
        ["git", "-C", str(governance_dir), "add", "--", consumer.relative_to(governance_dir)],
        check=True,
        timeout=10,
    )
    subprocess.run(
        [
            "git",
            "-c",
            "core.hooksPath=/dev/null",
            "-C",
            str(governance_dir),
            "commit",
            "-qm",
            "syntax fixture",
        ],
        check=True,
        timeout=10,
    )
    before = _legacy_shim_snapshot(governance_dir)
    index = governance_dir / ".git" / "index"
    index_before = index.read_bytes()

    blocked = _run_update_legacy_shim_backfill(workspace, governance_dir.name)

    assert blocked.returncode != 0
    assert "consumer scan failed to parse" in blocked.stderr
    assert _legacy_shim_snapshot(governance_dir) == before
    assert consumer.read_bytes() == consumer_bytes
    assert index.read_bytes() == index_before


def test_update_refuses_case_insensitive_tracked_alias_without_partial_writes(
    tmp_path: Path,
):
    workspace, governance_dir = _install_seed(tmp_path)
    lowercase = governance_dir / "scripts" / "iwe_checklist_memory.py"
    uppercase = governance_dir / "scripts" / "IWE_CHECKLIST_MEMORY.PY"
    desired_bytes = lowercase.read_bytes()
    lowercase.unlink()
    uppercase.write_bytes(desired_bytes)
    uppercase.chmod(0o755)
    _init_git_repo(governance_dir)
    subprocess.run(
        ["git", "-C", str(governance_dir), "config", "core.ignorecase", "true"],
        check=True,
        timeout=10,
    )
    subprocess.run(
        [
            "git",
            "-C",
            str(governance_dir),
            "add",
            "--",
            uppercase.relative_to(governance_dir),
        ],
        check=True,
        timeout=10,
    )
    subprocess.run(
        ["git", "-C", str(governance_dir), "commit", "-qm", "uppercase alias"],
        check=True,
        timeout=10,
    )
    before = _legacy_shim_snapshot(governance_dir)
    index = governance_dir / ".git" / "index"
    index_before = index.read_bytes()

    blocked = _run_update_legacy_shim_backfill(workspace, governance_dir.name)

    assert blocked.returncode != 0
    assert "case-insensitive tracked alias" in blocked.stderr
    assert uppercase.read_bytes() == desired_bytes
    tracked = subprocess.run(
        ["git", "-C", str(governance_dir), "ls-files", "--", "scripts"],
        capture_output=True,
        text=True,
        check=True,
        timeout=10,
    )
    assert "scripts/IWE_CHECKLIST_MEMORY.PY" in tracked.stdout.splitlines()
    assert _legacy_shim_snapshot(governance_dir) == before
    assert index.read_bytes() == index_before


def test_update_refuses_untracked_case_alias_for_missing_shim_without_writes(
    tmp_path: Path,
):
    workspace, governance_dir = _install_seed(tmp_path)
    lowercase = governance_dir / "scripts" / "iwe_checklist_memory.py"
    uppercase = governance_dir / "scripts" / "IWE_CHECKLIST_MEMORY.PY"
    lowercase.unlink()
    alias_bytes = b"#!/usr/bin/env python3\n# user-owned case alias\n"
    uppercase.write_bytes(alias_bytes)
    if lowercase.exists():
        pytest.skip("untracked case-alias regression requires a case-sensitive filesystem")
    marker = governance_dir / "tracked-marker.txt"
    marker.write_text("tracked fixture\n", encoding="utf-8")
    _init_git_repo(governance_dir)
    subprocess.run(
        ["git", "-C", str(governance_dir), "add", "--", marker.name],
        check=True,
        timeout=10,
    )
    subprocess.run(
        ["git", "-C", str(governance_dir), "commit", "-qm", "case alias fixture"],
        check=True,
        timeout=10,
    )
    before = _legacy_shim_snapshot(governance_dir)
    index = governance_dir / ".git" / "index"
    index_before = index.read_bytes()

    blocked = _run_update_legacy_shim_backfill(workspace, governance_dir.name)

    assert blocked.returncode != 0
    assert "case-insensitive untracked" in blocked.stderr
    assert not lowercase.exists()
    assert uppercase.read_bytes() == alias_bytes
    assert _legacy_shim_snapshot(governance_dir) == before
    assert index.read_bytes() == index_before


def test_update_rechecks_after_consumer_scan_and_preserves_concurrent_target(
    tmp_path: Path,
):
    workspace, governance_dir = _install_seed(tmp_path)
    for source in SEED_LEGACY_SHIMS:
        (governance_dir / source.relative_to(SEED)).unlink()
    marker = governance_dir / "tracked-marker.txt"
    marker.write_text("tracked fixture\n", encoding="utf-8")
    _init_git_repo(governance_dir)
    subprocess.run(
        ["git", "-C", str(governance_dir), "add", "--", marker.name],
        check=True,
        timeout=10,
    )
    subprocess.run(
        ["git", "-C", str(governance_dir), "commit", "-qm", "TOCTOU fixture"],
        check=True,
        timeout=10,
    )
    concurrent_target = governance_dir / "scripts" / "iwe_checklist_memory.py"
    concurrent_bytes = b"#!/usr/bin/env python3\n# concurrent user-owned shim\n"
    index = governance_dir / ".git" / "index"
    index_before = index.read_bytes()

    blocked = _run_update_legacy_shim_backfill(
        workspace,
        governance_dir.name,
        create_during_scan=concurrent_target,
    )

    assert blocked.returncode != 0
    assert concurrent_target.read_bytes() == concurrent_bytes
    for source in SEED_LEGACY_SHIMS[1:]:
        assert not (governance_dir / source.relative_to(SEED)).exists()
    assert index.read_bytes() == index_before


def test_blocked_legacy_preflight_never_refreshes_git_index(tmp_path: Path):
    workspace, governance_dir = _install_seed(tmp_path)
    target = governance_dir / "scripts" / "iwe_checklist_memory.py"
    target_bytes = b"#!/usr/bin/env python3\n# tracked bespoke implementation\n"
    target.write_bytes(target_bytes)
    _init_git_repo(governance_dir)
    subprocess.run(
        ["git", "-C", str(governance_dir), "add", "--", target.relative_to(governance_dir)],
        check=True,
        timeout=10,
    )
    subprocess.run(
        ["git", "-C", str(governance_dir), "commit", "-qm", "tracked bespoke shim"],
        check=True,
        timeout=10,
    )
    index = governance_dir / ".git" / "index"
    index_before = index.read_bytes()
    index_mtime_before = index.stat().st_mtime_ns
    future_mtime = target.stat().st_mtime_ns + 5_000_000_000
    os.utime(target, ns=(future_mtime, future_mtime))

    blocked = _run_update_legacy_shim_backfill(workspace, governance_dir.name)

    assert blocked.returncode != 0
    assert target.read_bytes() == target_bytes
    assert index.read_bytes() == index_before
    assert index.stat().st_mtime_ns == index_mtime_before


def test_update_consumer_scan_refuses_symlinked_python_without_reading_target(
    tmp_path: Path,
):
    workspace, governance_dir = _install_seed(tmp_path)
    secret = "outside-secret-must-not-leak-533"
    outside = tmp_path / "outside-consumer.py"
    outside_bytes = f"from iwe_checklist_memory import init_db  # {secret}\n".encode()
    outside.write_bytes(outside_bytes)
    linked_consumer = governance_dir / "scripts" / "linked-consumer.py"
    linked_consumer.symlink_to(outside)
    _init_git_repo(governance_dir)
    subprocess.run(
        [
            "git",
            "-C",
            str(governance_dir),
            "add",
            "--",
            linked_consumer.relative_to(governance_dir),
        ],
        check=True,
        timeout=10,
    )
    subprocess.run(
        ["git", "-C", str(governance_dir), "commit", "-qm", "linked consumer"],
        check=True,
        timeout=10,
    )
    before = _legacy_shim_snapshot(governance_dir)
    index = governance_dir / ".git" / "index"
    index_before = index.read_bytes()

    blocked = _run_update_legacy_shim_backfill(workspace, governance_dir.name)

    assert blocked.returncode != 0
    assert "consumer scan refused symlinked Python file" in blocked.stderr
    assert secret not in blocked.stdout
    assert secret not in blocked.stderr
    assert outside.read_bytes() == outside_bytes
    assert linked_consumer.is_symlink()
    assert _legacy_shim_snapshot(governance_dir) == before
    assert index.read_bytes() == index_before


def test_update_consumer_scan_refuses_symlinked_directory_without_reading_target(
    tmp_path: Path,
):
    workspace, governance_dir = _install_seed(tmp_path)
    secret = "outside-directory-secret-must-not-leak-533"
    outside = tmp_path / "outside-vendor"
    outside.mkdir()
    outside_consumer = outside / "legacy-consumer.py"
    outside_bytes = f"import iwe_checklist_memory  # {secret}\n".encode()
    outside_consumer.write_bytes(outside_bytes)
    linked_directory = governance_dir / "scripts" / "vendor"
    linked_directory.symlink_to(outside, target_is_directory=True)
    _init_git_repo(governance_dir)
    subprocess.run(
        [
            "git",
            "-C",
            str(governance_dir),
            "add",
            "--",
            linked_directory.relative_to(governance_dir),
        ],
        check=True,
        timeout=10,
    )
    subprocess.run(
        ["git", "-C", str(governance_dir), "commit", "-qm", "linked vendor"],
        check=True,
        timeout=10,
    )
    before = _legacy_shim_snapshot(governance_dir)
    index = governance_dir / ".git" / "index"
    index_before = index.read_bytes()

    blocked = _run_update_legacy_shim_backfill(workspace, governance_dir.name)

    assert blocked.returncode != 0
    assert "consumer scan refused symlinked directory" in blocked.stderr
    assert secret not in blocked.stdout
    assert secret not in blocked.stderr
    assert outside_consumer.read_bytes() == outside_bytes
    assert linked_directory.is_symlink()
    assert _legacy_shim_snapshot(governance_dir) == before
    assert index.read_bytes() == index_before


def test_update_consumer_scan_allows_symlink_resolving_inside_workspace(
    tmp_path: Path,
):
    # issue #661: a .py symlink whose target resolves INSIDE the workspace
    # (e.g. a script shared between two sibling governance repos) must not
    # abort the whole scan — only a symlink escaping the workspace should.
    # The target genuinely imports the legacy module (cold-context review
    # finding on the first version of this test: a content-free target file
    # only proved the scan didn't error, not that it actually READ through
    # the symlink — this would not have caught a regression that silently
    # skipped an in-workspace symlink's content instead of scanning it).
    workspace, governance_dir = _install_seed(tmp_path)
    sibling_repo = workspace / "DS-sibling"
    sibling_scripts = sibling_repo / "scripts"
    sibling_scripts.mkdir(parents=True)
    shared_target = sibling_scripts / "shared.py"
    shared_target.write_text("import iwe_checklist_memory\n", encoding="utf-8")
    linked_consumer = governance_dir / "scripts" / "shared.py"
    linked_consumer.symlink_to(shared_target)
    _init_git_repo(governance_dir)
    subprocess.run(
        [
            "git",
            "-C",
            str(governance_dir),
            "add",
            "--",
            linked_consumer.relative_to(governance_dir),
        ],
        check=True,
        timeout=10,
    )
    subprocess.run(
        ["git", "-C", str(governance_dir), "commit", "-qm", "in-workspace linked consumer"],
        check=True,
        timeout=10,
    )

    result = _run_update_legacy_shim_backfill(workspace, governance_dir.name)

    # The scan must have actually read the symlinked file's content and
    # found the legacy import — proven by the backfill refusing to proceed
    # with that specific finding, not merely by a clean exit.
    assert result.returncode != 0, result.stdout + result.stderr
    assert "consumer scan refused" not in result.stderr
    assert "still require init_db/DB_PATH-style facade removal" in result.stderr
    assert "shared.py" in result.stderr
    assert linked_consumer.is_symlink()


@pytest.mark.parametrize(
    "state",
    ("clean", "dirty", "staged", "untracked", "symlink", "non-git"),
)
def test_update_refuses_unknown_legacy_shim_state_without_partial_writes(
    tmp_path: Path,
    state: str,
):
    workspace, governance_dir = _install_seed(tmp_path)
    target = governance_dir / "scripts" / "iwe_checklist_memory.py"
    target.write_bytes(b"#!/usr/bin/env python3\n# unknown bespoke implementation\n")
    if state != "non-git":
        _init_git_repo(governance_dir)
        if state in {"clean", "dirty", "staged"}:
            subprocess.run(
                ["git", "-C", str(governance_dir), "add", "--", target.relative_to(governance_dir)],
                check=True,
                timeout=10,
            )
            subprocess.run(
                ["git", "-C", str(governance_dir), "commit", "-qm", "unknown legacy shim"],
                check=True,
                timeout=10,
            )
        if state in {"dirty", "staged"}:
            target.write_bytes(b"#!/usr/bin/env python3\n# locally changed bespoke implementation\n")
        if state == "staged":
            subprocess.run(
                ["git", "-C", str(governance_dir), "add", "--", target.relative_to(governance_dir)],
                check=True,
                timeout=10,
            )
        if state == "symlink":
            target.unlink()
            sentinel = tmp_path / "bespoke-symlink-target.py"
            sentinel.write_bytes(b"do not overwrite through link\n")
            target.symlink_to(sentinel)
    before = _legacy_shim_snapshot(governance_dir)
    index = governance_dir / ".git" / "index"
    index_before = index.read_bytes() if index.exists() else None

    blocked = _run_update_legacy_shim_backfill(workspace, governance_dir.name)

    assert blocked.returncode != 0
    assert "manual" in blocked.stderr.lower()
    assert "cp -p" in blocked.stderr
    assert _legacy_shim_snapshot(governance_dir) == before
    assert (index.read_bytes() if index.exists() else None) == index_before


def test_update_rolls_back_every_legacy_shim_after_ordinary_apply_failure(
    tmp_path: Path,
):
    workspace, governance_dir = _install_seed(tmp_path)
    for source in SEED_LEGACY_SHIMS:
        (governance_dir / source.relative_to(SEED)).unlink()
    marker = governance_dir / "tracked-marker.txt"
    marker.write_text("index fixture\n", encoding="utf-8")
    _init_git_repo(governance_dir)
    subprocess.run(
        ["git", "-C", str(governance_dir), "add", "--", marker.name],
        check=True,
        timeout=10,
    )
    subprocess.run(
        ["git", "-C", str(governance_dir), "commit", "-qm", "rollback fixture"],
        check=True,
        timeout=10,
    )
    before = _legacy_shim_snapshot(governance_dir)
    index = governance_dir / ".git" / "index"
    index_before = index.read_bytes()

    failed = _run_update_legacy_shim_backfill(
        workspace,
        governance_dir.name,
        fail_after=2,
    )

    assert failed.returncode != 0
    assert "rolled back" in failed.stderr
    assert _legacy_shim_snapshot(governance_dir) == before
    assert index.read_bytes() == index_before


def test_update_rolls_back_all_legacy_shims_when_term_arrives_mid_apply(
    tmp_path: Path,
):
    workspace, governance_dir = _install_seed(tmp_path)
    old_bytes: dict[Path, bytes] = {}
    for index, source in enumerate(SEED_LEGACY_SHIMS):
        target = governance_dir / source.relative_to(SEED)
        content = f"#!/usr/bin/env python3\n# old shim {index}\n".encode()
        target.write_bytes(content)
        target.chmod(0o755)
        old_bytes[target] = content

    script = (
        _update_legacy_shim_functions(signal_after=2)
        + r'''
SCRIPT_DIR="$1"
governance_dir="$2"
PY_BIN="$3"
AGENT_FAULT_SHIMS_TO_APPLY=("${AGENT_FAULT_LEGACY_SHIMS[@]}")
AGENT_FAULT_SHIM_PREFLIGHT_PATHS=()
AGENT_FAULT_SHIM_TARGET_SNAPSHOTS=()
AGENT_FAULT_SHIM_GIT_READY=()
AGENT_FAULT_SHIM_GIT_PATHSPECS=()
AGENT_FAULT_SHIM_TRACKED_SNAPSHOTS=()
AGENT_FAULT_SHIM_STATUS_SNAPSHOTS=()
for relative_path in "${AGENT_FAULT_LEGACY_SHIMS[@]}"; do
    AGENT_FAULT_SHIM_PREFLIGHT_PATHS+=("$relative_path")
    AGENT_FAULT_SHIM_TARGET_SNAPSHOTS+=(
        "$(agent_fault_target_snapshot "$governance_dir/$relative_path")"
    )
    AGENT_FAULT_SHIM_GIT_READY+=("0")
    AGENT_FAULT_SHIM_GIT_PATHSPECS+=("")
    AGENT_FAULT_SHIM_TRACKED_SNAPSHOTS+=("")
    AGENT_FAULT_SHIM_STATUS_SNAPSHOTS+=("")
done
apply_legacy_agent_fault_shims "$governance_dir"
'''
    )
    terminated = subprocess.run(
        [
            "bash",
            "-c",
            script,
            "issue-533-term-rollback",
            str(ROOT),
            str(governance_dir),
            sys.executable,
        ],
        capture_output=True,
        text=True,
        check=False,
        timeout=30,
    )

    assert terminated.returncode != 0
    assert {path: path.read_bytes() for path in old_bytes} == old_bytes


@pytest.mark.parametrize(
    ("extension", "protocol"),
    ((OPEN_EXTENSION, "work"), (CLOSE_EXTENSION, "close")),
)
def test_protocol_extensions_execute_cli_from_template_runtime(
    tmp_path: Path,
    extension: Path,
    protocol: str,
):
    workspace, governance_dir = _install_seed(tmp_path)
    installed_cli = (
        workspace
        / "FMT-exocortex-template"
        / "scripts"
        / "agent-fault"
        / CLI.name
    )
    installed_cli.parent.mkdir(parents=True)
    shutil.copy2(CLI, installed_cli)
    env = _platform_env(workspace, governance_dir.name, tmp_path)
    env.pop("IWE_SCRIPTS", None)
    env.pop("IWE_TEMPLATE", None)
    env["IWE_FAULT_SUBJECT_KIND"] = "runtime"
    env["IWE_FAULT_SUBJECT_ID"] = "runtime-extension"
    fault = f"расширение {protocol} нашло CLI в шаблонном runtime"
    recorded = _record(
        env,
        fault,
        protocol=protocol,
        subject_id="runtime-extension",
    )
    assert recorded.returncode == 0, recorded.stdout + recorded.stderr

    extension_text = extension.read_text(encoding="utf-8")
    assert "{{WORKSPACE_DIR}}/scripts/agent-fault" not in extension_text
    assert "${IWE_TEMPLATE:-$IWE_ROOT/FMT-exocortex-template}" in extension_text
    result = subprocess.run(
        ["bash", "-eu", "-o", "pipefail", "-c", _first_bash_block(extension)],
        env=env,
        capture_output=True,
        text=True,
        check=False,
        timeout=20,
    )

    assert result.returncode == 0, result.stdout + result.stderr
    assert fault in result.stdout


def test_real_route_records_multi_token_russian_fault_exactly(tmp_path: Path):
    workspace, governance_dir = _install_seed(tmp_path, "DS-custom")
    catalog = governance_dir / "scripts" / "executor-catalog.yaml"
    _write_catalog(catalog, _skill_script_path())
    # route-task.sh resolves a relative script_path against IWE_TEMPLATE
    # (defaults to $IWE_DIR/FMT-exocortex-template, issue #634 fix) - mirror
    # that nested layout, same pattern used by
    # test_protocol_extensions_execute_cli_from_template_runtime above.
    real_skill_script = ROOT / _skill_script_path()
    installed_skill_script = workspace / "FMT-exocortex-template" / _skill_script_path()
    installed_skill_script.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(real_skill_script, installed_skill_script)
    fault = "агент потерял многословное русское описание ошибки"
    env = _platform_env(workspace, governance_dir.name, tmp_path)
    env.update(
        {
            "IWE_EXECUTOR_CATALOG": str(catalog),
            "IWE_ROUTER_AUDIT": str(tmp_path / "route-audit.tsv"),
            "IWE_ROUTER_ERRORS": str(tmp_path / "route-errors.log"),
        }
    )

    result = subprocess.run(
        [
            "bash",
            str(ROUTER),
            "--skill",
            "agent-fault",
            "--args",
            (
                f"record --severity major --protocol open --fault {fault} "
                "--source-citation AGENTS.md:точная-цитата "
                "--subject-kind runtime --subject-id runtime-custom"
            ),
        ],
        env=env,
        capture_output=True,
        text=True,
        check=False,
        timeout=20,
    )

    assert result.returncode == 0, result.stdout + result.stderr
    db_path = governance_dir / DB_REL
    rows = _db_rows(
        db_path,
        "SELECT content, subject_kind, subject_id FROM facts WHERE fact_type='agent_fault'",
    )
    assert rows == [(fault, "runtime", "runtime-custom")]
    assert fault not in (tmp_path / "route-audit.tsv").read_text(encoding="utf-8")
    assert not (tmp_path / "legacy-workspace-must-stay-empty").exists()


def test_subject_is_required_for_record_and_remind(tmp_path: Path):
    workspace, governance_dir = _install_seed(tmp_path)
    env = _platform_env(workspace, governance_dir.name, tmp_path)

    record = _run_cli(env, "record", "--fault", "ошибка без владельца")
    remind = _run_cli(env, "remind", "--protocol", "open")

    assert record.returncode != 0
    assert remind.returncode != 0
    assert "subject" in (record.stderr + remind.stderr).lower()
    assert not (governance_dir / DB_REL).exists()


def test_missing_profile_reminder_is_strictly_read_only(tmp_path: Path):
    workspace = tmp_path / "iwe"
    governance_dir = workspace / "DS-private"
    (governance_dir / "exocortex").mkdir(parents=True)
    env = _platform_env(workspace, governance_dir.name, tmp_path)
    profile = governance_dir / PROFILE_REL
    assert not profile.exists()

    result = _run_cli(
        env,
        "remind",
        "--subject-kind",
        "runtime",
        "--subject-id",
        "runtime-no-profile",
    )

    assert result.returncode == 0, result.stdout + result.stderr
    assert "not found" in result.stdout
    assert not profile.exists()
    assert not (profile / ".gitignore").exists()
    assert not (governance_dir / DB_REL).exists()


def test_missing_profile_escalation_check_is_strictly_read_only(tmp_path: Path):
    workspace = tmp_path / "iwe"
    governance_dir = workspace / "DS-private"
    (governance_dir / "exocortex").mkdir(parents=True)
    env = _platform_env(workspace, governance_dir.name, tmp_path)
    profile = governance_dir / PROFILE_REL
    assert not profile.exists()

    result = _run_cli(env, "escalation-check", "--threshold", "3")

    assert result.returncode == 0, result.stdout + result.stderr
    assert "No active faults" in result.stdout
    assert not profile.exists()
    assert not (profile / ".gitignore").exists()
    assert not (governance_dir / DB_REL).exists()


@pytest.mark.parametrize(
    ("arguments", "message"),
    (
        (("--threshold", "0"), "threshold must be greater than zero"),
        (("--subject-kind", "runtime"), "must be supplied together"),
        (("--subject-id", "runtime-a"), "must be supplied together"),
    ),
)
def test_escalation_check_rejects_invalid_threshold_or_partial_subject(
    tmp_path: Path,
    arguments: tuple[str, ...],
    message: str,
):
    workspace = tmp_path / "iwe"
    governance_dir = workspace / "DS-private"
    (governance_dir / "exocortex").mkdir(parents=True)
    env = _platform_env(workspace, governance_dir.name, tmp_path)

    result = _run_cli(env, "escalation-check", *arguments)

    assert result.returncode != 0
    assert message in result.stderr
    assert not (governance_dir / PROFILE_REL).exists()


def test_escalation_check_filters_active_rows_and_exact_subject(tmp_path: Path):
    workspace, governance_dir = _install_seed(tmp_path)
    env = _platform_env(workspace, governance_dir.name, tmp_path)
    own_fault = "эскалация нужного runtime"
    other_fault = "эскалация другого runtime"
    dormant_fault = "уснувшая эскалация нужного runtime"
    for _index in range(3):
        assert _record(env, own_fault, subject_id="runtime-a").returncode == 0
        assert _record(env, dormant_fault, subject_id="runtime-a").returncode == 0
    for _index in range(4):
        assert _record(env, other_fault, subject_id="runtime-b").returncode == 0
    with closing(sqlite3.connect(governance_dir / DB_REL)) as connection, connection:
        connection.execute(
            "UPDATE facts SET status='dormant' WHERE content=?",
            (dormant_fault,),
        )
        connection.commit()

    exact = _run_cli(
        env,
        "escalation-check",
        "--threshold",
        "3",
        "--subject-kind",
        "runtime",
        "--subject-id",
        "runtime-a",
    )
    all_subjects = _run_cli(env, "escalation-check", "--threshold", "3")

    assert exact.returncode == 0, exact.stdout + exact.stderr
    assert own_fault in exact.stdout
    assert other_fault not in exact.stdout
    assert dormant_fault not in exact.stdout
    assert all_subjects.returncode == 0, all_subjects.stdout + all_subjects.stderr
    assert own_fault in all_subjects.stdout
    assert other_fault in all_subjects.stdout
    assert dormant_fault not in all_subjects.stdout


def test_public_read_faults_is_no_create_and_requires_exact_subject(tmp_path: Path):
    workspace = tmp_path / "iwe"
    governance_dir = workspace / "DS-private"
    (governance_dir / "exocortex").mkdir(parents=True)
    env = _platform_env(workspace, governance_dir.name, tmp_path)
    module = _load_cli_module()

    rows = module.read_faults(
        subject_kind="runtime",
        subject_id="runtime-a",
        env=env,
    )

    assert rows == ()
    assert not (governance_dir / PROFILE_REL).exists()
    with pytest.raises(module.FaultProfileError, match="subject-kind"):
        module.read_faults(subject_kind="runtime", subject_id="", env=env)
    assert not (governance_dir / PROFILE_REL).exists()


def test_public_read_faults_filters_subject_date_and_subtype_immutably(tmp_path: Path):
    workspace, governance_dir = _install_seed(tmp_path)
    env = _platform_env(workspace, governance_dir.name, tmp_path)
    tagged = "точная subtype-запись нужного runtime"
    untagged = "fallback-запись нужного runtime"
    other = "запись другого runtime"
    assert _record(env, tagged, subject_id="runtime-a").returncode == 0
    assert _record(env, untagged, subject_id="runtime-a").returncode == 0
    assert _record(env, other, subject_id="runtime-b").returncode == 0
    with closing(sqlite3.connect(governance_dir / DB_REL)) as connection, connection:
        connection.execute(
            "UPDATE facts SET fault_subtype='distinction-confusion', record_date='2026-08-03' "
            "WHERE content=?",
            (tagged,),
        )
        connection.execute(
            "UPDATE facts SET fault_subtype=NULL, record_date='2026-08-04' WHERE content=?",
            (untagged,),
        )
        connection.execute(
            "UPDATE facts SET fault_subtype='distinction-confusion', record_date='2026-08-05' "
            "WHERE content=?",
            (other,),
        )
        connection.commit()
    module = _load_cli_module()

    primary = module.read_faults(
        subject_kind="runtime",
        subject_id="runtime-a",
        since_date="2026-08-02T23:00:00Z",
        fault_subtype="distinction-confusion",
        env=env,
    )
    fallback = module.read_faults(
        subject_kind="runtime",
        subject_id="runtime-a",
        since_date="2026-08-04",
        exclude_fault_subtype="distinction-confusion",
        env=env,
    )

    assert tuple(row.content for row in primary) == (tagged,)
    assert primary[0].subject_id == "runtime-a"
    assert primary[0].record_date == "2026-08-03"
    assert tuple(row.content for row in fallback) == (untagged,)
    with pytest.raises(AttributeError):
        primary[0].content = "mutable"  # type: ignore[misc]
    with pytest.raises(module.FaultProfileError, match="mutually exclusive"):
        module.read_faults(
            subject_kind="runtime",
            subject_id="runtime-a",
            fault_subtype="distinction-confusion",
            exclude_fault_subtype="other",
            env=env,
        )


def test_public_read_faults_honors_tracked_database_privacy_gate(tmp_path: Path):
    workspace, governance_dir = _install_seed(tmp_path)
    env = _platform_env(workspace, governance_dir.name, tmp_path)
    assert _record(env, "публичный reader не обходит privacy gate").returncode == 0
    subprocess.run(["git", "init", "-q", str(workspace)], check=True, timeout=10)
    pathspec = (Path(governance_dir.name) / DB_REL).as_posix()
    subprocess.run(
        ["git", "-C", str(workspace), "add", "-f", "--", pathspec],
        check=True,
        timeout=10,
    )
    database = governance_dir / DB_REL
    index = workspace / ".git" / "index"
    database_before = database.read_bytes()
    index_before = index.read_bytes()
    module = _load_cli_module()

    with pytest.raises(module.FaultProfileError, match="tracked by Git"):
        module.read_faults(
            subject_kind="runtime",
            subject_id="runtime-a",
            env=env,
        )

    assert database.read_bytes() == database_before
    assert index.read_bytes() == index_before


def test_lazy_record_then_remind_filters_exact_subject_and_dormant(tmp_path: Path):
    workspace, governance_dir = _install_seed(tmp_path)
    env = _platform_env(workspace, governance_dir.name, tmp_path)
    db_path = governance_dir / DB_REL
    assert not db_path.exists(), "fresh install must not ship a user's database"

    records = (
        ("видимая ошибка нужного runtime", "runtime-a"),
        ("ошибка другого runtime", "runtime-b"),
        ("уснувшая ошибка нужного runtime", "runtime-a"),
    )
    for fault, subject_id in records:
        result = _record(env, fault, subject_id=subject_id)
        assert result.returncode == 0, result.stdout + result.stderr

    with closing(sqlite3.connect(db_path)) as connection, connection:
        connection.execute(
            "UPDATE facts SET status='dormant' WHERE content=?",
            ("уснувшая ошибка нужного runtime",),
        )
        connection.commit()

    reminder = _run_cli(
        env,
        "remind",
        "--protocol",
        "open",
        "--limit",
        "10",
        "--subject-kind",
        "runtime",
        "--subject-id",
        "runtime-a",
    )

    assert reminder.returncode == 0, reminder.stdout + reminder.stderr
    assert "видимая ошибка нужного runtime" in reminder.stdout
    assert "ошибка другого runtime" not in reminder.stdout
    assert "уснувшая ошибка нужного runtime" not in reminder.stdout


def test_recorded_all_protocol_matches_every_specific_reminder(tmp_path: Path):
    workspace, governance_dir = _install_seed(tmp_path)
    env = _platform_env(workspace, governance_dir.name, tmp_path)
    fault = "общая ошибка видна во всех протоколах"
    assert _record(env, fault, protocol="all").returncode == 0

    for protocol in ("open", "close", "day_close", "work", "all"):
        reminder = _run_cli(
            env,
            "remind",
            "--protocol",
            protocol,
            "--subject-kind",
            "runtime",
            "--subject-id",
            "runtime-a",
        )
        assert reminder.returncode == 0, reminder.stdout + reminder.stderr
        assert fault in reminder.stdout


def test_decay_uses_real_timestamps_and_valid_created_at_fallback(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
):
    workspace, governance_dir = _install_seed(tmp_path)
    env = _platform_env(workspace, governance_dir.name, tmp_path)
    contents = (
        "29d20h остаётся active в тот же календарный день",
        "старше 30 суток становится dormant",
        "невалидный last_occurrence берёт валидный created_at",
        "две невалидные даты безопасно остаются active",
    )
    for content in contents:
        assert _record(env, content).returncode == 0

    frozen_now = datetime(2026, 8, 24, 12, 0, tzinfo=timezone.utc)
    recent = frozen_now - timedelta(days=29, hours=20)
    old = frozen_now - timedelta(days=30, hours=4)
    with closing(sqlite3.connect(governance_dir / DB_REL)) as connection, connection:
        connection.execute(
            "UPDATE facts SET last_occurrence=?, created_at=? WHERE content=?",
            (recent.strftime("%Y-%m-%d %H:%M:%S"), "2000-01-01 00:00:00", contents[0]),
        )
        connection.execute(
            "UPDATE facts SET last_occurrence=?, created_at=? WHERE content=?",
            (old.isoformat(), "2000-01-01 00:00:00", contents[1]),
        )
        connection.execute(
            "UPDATE facts SET last_occurrence='invalid', created_at=? WHERE content=?",
            (old.strftime("%Y-%m-%d %H:%M:%S"), contents[2]),
        )
        connection.execute(
            """UPDATE facts
                  SET last_occurrence='invalid', created_at='also-invalid'
                WHERE content=?""",
            (contents[3],),
        )
        connection.commit()

    module = _load_cli_module()

    class FrozenDateTime(datetime):
        @classmethod
        def now(cls, tz=None):
            return frozen_now if tz is not None else frozen_now.replace(tzinfo=None)

    monkeypatch.setattr(module, "datetime", FrozenDateTime)
    module.decay(module.resolve_paths(env))

    statuses = dict(
        _db_rows(
            governance_dir / DB_REL,
            "SELECT content, status FROM facts ORDER BY id",
        )
    )
    assert statuses == {
        contents[0]: "active",
        contents[1]: "dormant",
        contents[2]: "dormant",
        contents[3]: "active",
    }


def test_iwe_env_precedence_targets_custom_governance_only(tmp_path: Path):
    workspace, governance_dir = _install_seed(tmp_path, "DS-nondefault")
    env = _platform_env(workspace, governance_dir.name, tmp_path)

    result = _record(env, "проверка каскада переменных", subject_id="runtime-env")

    assert result.returncode == 0, result.stdout + result.stderr
    assert (governance_dir / DB_REL).is_file()
    assert not (tmp_path / "legacy-workspace-must-stay-empty").exists()
    assert not (Path(env["HOME"]) / "IWE").exists()


def test_default_and_legacy_env_cascades(tmp_path: Path):
    home = tmp_path / "home"
    default_workspace = home / "IWE"
    default_governance = default_workspace / "DS-strategy"
    default_workspace.mkdir(parents=True)
    shutil.copytree(SEED, default_governance)
    default_env = {
        **os.environ,
        "HOME": str(home),
        "PYTHONDONTWRITEBYTECODE": "1",
    }
    for name in (
        "IWE_WORKSPACE",
        "WORKSPACE_DIR",
        "IWE_GOVERNANCE_REPO",
        "GOVERNANCE_REPO",
    ):
        default_env.pop(name, None)
    assert _record(default_env, "default cascade").returncode == 0
    assert (default_governance / DB_REL).is_file()

    legacy_workspace = tmp_path / "legacy-iwe"
    legacy_governance = legacy_workspace / "DS.legacy"
    legacy_workspace.mkdir()
    shutil.copytree(SEED, legacy_governance)
    legacy_env = {
        **os.environ,
        "HOME": str(tmp_path / "unused-home"),
        "WORKSPACE_DIR": str(legacy_workspace),
        "GOVERNANCE_REPO": legacy_governance.name,
        "PYTHONDONTWRITEBYTECODE": "1",
    }
    legacy_env.pop("IWE_WORKSPACE", None)
    legacy_env.pop("IWE_GOVERNANCE_REPO", None)
    assert _record(legacy_env, "legacy cascade").returncode == 0
    assert (legacy_governance / DB_REL).is_file()


def test_profile_is_private_gitignored_and_has_no_automatic_raw_audit(tmp_path: Path):
    workspace, governance_dir = _install_seed(tmp_path)
    env = _platform_env(workspace, governance_dir.name, tmp_path)
    fault = "секретоподобное описание не должно попасть в открытый audit"
    exocortex = governance_dir / "exocortex"
    exocortex.chmod(0o700)
    ignore = governance_dir / PROFILE_REL / ".gitignore"
    ignore.write_text("custom-local-pattern\n\n" + ignore.read_text(encoding="utf-8"), encoding="utf-8")

    result = _record(
        env,
        fault,
        subject_id="runtime-private",
        permissive_umask=True,
    )

    assert result.returncode == 0, result.stdout + result.stderr
    profile = governance_dir / PROFILE_REL
    db_path = governance_dir / DB_REL
    assert stat.S_IMODE(profile.stat().st_mode) == 0o700
    assert stat.S_IMODE(db_path.stat().st_mode) == 0o600
    assert stat.S_IMODE(exocortex.stat().st_mode) == 0o700
    assert "custom-local-pattern" in ignore.read_text(encoding="utf-8")
    assert not (profile / "audit").exists(), "record must not emit plaintext Markdown"
    assert not (profile / "faults-queue.md").exists(), "record must not spill raw text"

    subprocess.run(["git", "init", "-q", str(governance_dir)], check=True, timeout=10)
    ignored = subprocess.run(
        ["git", "-C", str(governance_dir), "check-ignore", "--quiet", str(DB_REL)],
        check=False,
        timeout=10,
    )
    assert ignored.returncode == 0, "profile-local .gitignore must ignore iwe_memory.db"
    added = subprocess.run(
        ["git", "-C", str(governance_dir), "add", "--", str(PROFILE_REL)],
        capture_output=True,
        text=True,
        check=False,
        timeout=10,
    )
    assert added.returncode == 0, added.stdout + added.stderr
    staged = subprocess.run(
        ["git", "-C", str(governance_dir), "diff", "--cached", "--name-only"],
        capture_output=True,
        text=True,
        check=True,
        timeout=10,
    ).stdout.splitlines()
    assert DB_REL.as_posix() not in staged


def test_existing_profile_permissions_are_hardened_on_read(tmp_path: Path):
    workspace, governance_dir = _install_seed(tmp_path)
    env = _platform_env(workspace, governance_dir.name, tmp_path)
    assert _record(env, "историческая запись").returncode == 0
    profile = governance_dir / PROFILE_REL
    db_path = governance_dir / DB_REL
    profile.chmod(0o755)
    db_path.chmod(0o644)

    result = _run_cli(
        env,
        "remind",
        "--subject-kind",
        "runtime",
        "--subject-id",
        "runtime-a",
    )

    assert result.returncode == 0, result.stdout + result.stderr
    assert stat.S_IMODE(profile.stat().st_mode) == 0o700
    assert stat.S_IMODE(db_path.stat().st_mode) == 0o600


def test_existing_sqlite_sidecars_are_hardened(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    workspace, governance_dir = _install_seed(tmp_path)
    env = _platform_env(workspace, governance_dir.name, tmp_path)
    assert _record(env, "sidecar hardening").returncode == 0
    db_path = governance_dir / DB_REL
    sidecars = [Path(f"{db_path}{suffix}") for suffix in ("-wal", "-shm", "-journal")]
    for sidecar in sidecars:
        sidecar.write_bytes(b"")
        sidecar.chmod(0o644)
    for key, value in env.items():
        monkeypatch.setenv(key, value)
    module = _load_cli_module()

    module._harden_database_files(module.resolve_paths())

    assert all(stat.S_IMODE(sidecar.stat().st_mode) == 0o600 for sidecar in sidecars)


def test_lazy_migration_preserves_legacy_rows_and_unknown_columns(tmp_path: Path):
    workspace, governance_dir = _install_seed(tmp_path)
    env = _platform_env(workspace, governance_dir.name, tmp_path)
    content = "старая запись сохранилась после миграции"
    db_path, original_context = _create_legacy_database(
        governance_dir,
        content=content,
        personality_id="legacy-personality",
        context_fields={
            "occurrences": 5,
            "severity": "critical",
            "status": "active",
            "source_citation": "Rulebook: exact legacy source",
            "last_update": "2026-08-23T09:10:11+00:00",
            "created": "2026-08-20",
        },
    )
    dormant_context = json.dumps(
        {
            "protocols": ["work"],
            "short_content": "старая dormant-запись",
            "occurrences": 9,
            "severity": "critical",
            "status": "dormant",
        },
        ensure_ascii=False,
        sort_keys=True,
    )
    with closing(sqlite3.connect(db_path)) as connection, connection:
        connection.execute(
            """INSERT INTO facts (
                   id, fact_type, content, context, trust_score, session_id,
                   personality_id, extra_payload
               ) VALUES (38, 'agent_fault', 'старая dormant-запись', ?, 0.95,
                         'legacy-session', 'legacy-personality', 'keep-dormant')""",
            (dormant_context,),
        )
        connection.commit()

    first = _run_cli(
        env,
        "remind",
        "--protocol",
        "work",
        "--subject-kind",
        "personality",
        "--subject-id",
        "legacy-personality",
    )
    columns_after_first = _db_rows(db_path, "PRAGMA table_info(facts)")
    row_after_first = _db_rows(
        db_path,
        """SELECT id, content, context, extra_payload, subject_kind, subject_id,
                      occurrences_count, severity, status, last_occurrence,
                      record_date, source_citation
             FROM facts WHERE id=37""",
    )
    first_export = _run_cli(env, "export")
    first_export_text = (governance_dir / EXPORT_REL).read_text(encoding="utf-8")
    second = _run_cli(
        env,
        "remind",
        "--protocol",
        "work",
        "--subject-kind",
        "personality",
        "--subject-id",
        "legacy-personality",
    )
    columns_after_second = _db_rows(db_path, "PRAGMA table_info(facts)")
    row_after_second = _db_rows(
        db_path,
        """SELECT id, content, context, extra_payload, subject_kind, subject_id,
                      occurrences_count, severity, status, last_occurrence,
                      record_date, source_citation
             FROM facts WHERE id=37""",
    )

    assert first.returncode == 0, first.stdout + first.stderr
    assert second.returncode == 0, second.stdout + second.stderr
    assert first_export.returncode == 0, first_export.stdout + first_export.stderr
    assert content in first.stdout and content in second.stdout
    assert "старая dormant-запись" not in first.stdout + second.stdout
    assert "## 2026-08-20 · CRITICAL" in first_export_text
    assert "- Occurrences: 5" in first_export_text
    assert "- Source citation: Rulebook: exact legacy source" in first_export_text
    expected_row = [
        (
            37,
            content,
            original_context,
            "keep-me",
            "personality",
            "legacy-personality",
            5,
            "critical",
            "active",
            "2026-08-23T09:10:11+00:00",
            "2026-08-20",
            "Rulebook: exact legacy source",
        )
    ]
    assert row_after_first == expected_row
    assert row_after_second == expected_row
    assert columns_after_second == columns_after_first
    assert "extra_payload" in {row[1] for row in columns_after_second}

    repeated = _run_cli(
        env,
        "record",
        "--severity",
        "critical",
        "--protocol",
        "work",
        "--fault",
        content,
        "--subject-kind",
        "personality",
        "--subject-id",
        "legacy-personality",
    )
    reminder_after_repeat = _run_cli(
        env,
        "remind",
        "--protocol",
        "work",
        "--subject-kind",
        "personality",
        "--subject-id",
        "legacy-personality",
    )
    export_after_repeat = _run_cli(env, "export")
    repeated_row = _db_rows(
        db_path,
        """SELECT id, occurrences_count, severity, source_citation, extra_payload
             FROM facts WHERE id=37""",
    )
    repeated_export_text = (governance_dir / EXPORT_REL).read_text(encoding="utf-8")
    assert repeated.returncode == 0, repeated.stdout + repeated.stderr
    assert reminder_after_repeat.returncode == 0
    assert export_after_repeat.returncode == 0
    assert repeated_row == [
        (37, 6, "critical", "Rulebook: exact legacy source", "keep-me")
    ]
    assert f"[CRITICAL | n=6] {content}" in reminder_after_repeat.stdout
    assert "- Occurrences: 6" in repeated_export_text
    assert "- Source citation: Rulebook: exact legacy source" in repeated_export_text


def test_migration_never_rewrites_preexisting_semantic_columns(tmp_path: Path):
    workspace, governance_dir = _install_seed(tmp_path)
    env = _platform_env(workspace, governance_dir.name, tmp_path)
    db_path, _context = _create_legacy_database(
        governance_dir,
        context_fields={
            "occurrences": 99,
            "severity": "critical",
            "status": "active",
            "source_citation": "context must not win",
            "subject_kind": "personality",
            "subject_id": "context-subject",
            "last_update": "2026-08-23T09:10:11+00:00",
            "created": "2026-08-20",
        },
    )
    with closing(sqlite3.connect(db_path)) as connection, connection:
        connection.execute("ALTER TABLE facts ADD COLUMN occurrences_count INTEGER")
        connection.execute("ALTER TABLE facts ADD COLUMN severity TEXT")
        connection.execute("ALTER TABLE facts ADD COLUMN status TEXT")
        connection.execute("ALTER TABLE facts ADD COLUMN subject_kind TEXT")
        connection.execute("ALTER TABLE facts ADD COLUMN subject_id TEXT")
        connection.execute("ALTER TABLE facts ADD COLUMN source_citation TEXT")
        connection.execute("ALTER TABLE facts ADD COLUMN last_occurrence TEXT")
        connection.execute("ALTER TABLE facts ADD COLUMN record_date TEXT")
        connection.execute(
            """UPDATE facts
                  SET occurrences_count=7, severity='minor', status='dormant',
                      subject_kind='runtime', subject_id='existing-subject',
                      source_citation='existing column wins',
                      last_occurrence='2025-01-02T03:04:05+00:00',
                      record_date='2025-01-02'
                WHERE id=37"""
        )
        connection.commit()

    first = _run_cli(env, "stats")
    state_after_first = _db_rows(
        db_path,
        """SELECT id, occurrences_count, severity, status, subject_kind,
                      subject_id, source_citation, last_occurrence, record_date,
                      extra_payload
             FROM facts WHERE id=37""",
    )
    second = _run_cli(env, "stats")
    state_after_second = _db_rows(
        db_path,
        """SELECT id, occurrences_count, severity, status, subject_kind,
                      subject_id, source_citation, last_occurrence, record_date,
                      extra_payload
             FROM facts WHERE id=37""",
    )

    assert first.returncode == 0, first.stdout + first.stderr
    assert second.returncode == 0, second.stdout + second.stderr
    expected = [
        (
            37,
            7,
            "minor",
            "dormant",
            "runtime",
            "existing-subject",
            "existing column wins",
            "2025-01-02T03:04:05+00:00",
            "2025-01-02",
            "keep-me",
        )
    ]
    assert state_after_first == expected
    assert state_after_second == expected


def test_migration_validates_legacy_context_before_backfill(tmp_path: Path):
    workspace, governance_dir = _install_seed(tmp_path)
    env = _platform_env(workspace, governance_dir.name, tmp_path)
    exact_citation = "  Rulebook: preserve exact spacing  "
    db_path, _context = _create_legacy_database(
        governance_dir,
        personality_id="",
        context_fields={
            "occurrences": 4,
            "severity": "high",
            "status": "dormant",
            "source_citation": exact_citation,
            "subject_kind": "runtime",
            "subject_id": "context-runtime",
            "last_sync": "2026-08-22T08:09:10Z",
            "created": "2026-08-21",
        },
    )
    invalid_contexts = (
        {
            "occurrences": True,
            "severity": "urgent",
            "status": "deleted",
            "source_citation": 42,
            "subject_kind": "root",
            "subject_id": "invalid-kind",
            "last_update": "yesterday",
            "created": "2026-02-31",
        },
        {
            "occurrences": -3,
            "severity": ["critical"],
            "status": {"active": True},
            "source_citation": "",
            "subject_kind": "runtime",
            "subject_id": "bad\nsubject",
            "last_sync": ["2026-08-22T08:09:10Z"],
            "date": 20260821,
        },
    )
    with closing(sqlite3.connect(db_path)) as connection, connection:
        for fact_id, context in enumerate(invalid_contexts, start=38):
            connection.execute(
                """INSERT INTO facts (
                       id, fact_type, content, context, trust_score, session_id,
                       personality_id, extra_payload
                   ) VALUES (?, 'agent_fault', ?, ?, 0.95, 'legacy-session', '', ?)""",
                (
                    fact_id,
                    f"invalid legacy context {fact_id}",
                    json.dumps(context, ensure_ascii=False),
                    f"keep-{fact_id}",
                ),
            )
        connection.commit()

    result = _run_cli(env, "stats")
    rows = _db_rows(
        db_path,
        """SELECT id, occurrences_count, severity, status, subject_kind,
                      subject_id, source_citation, last_occurrence, record_date,
                      extra_payload
             FROM facts ORDER BY id""",
    )

    assert result.returncode == 0, result.stdout + result.stderr
    assert rows == [
        (
            37,
            4,
            "major",
            "dormant",
            "runtime",
            "context-runtime",
            exact_citation,
            "2026-08-22T08:09:10+00:00",
            "2026-08-21",
            "keep-me",
        ),
        (38, 1, "major", "active", None, None, None, None, None, "keep-38"),
        (39, 1, "major", "active", None, None, None, None, None, "keep-39"),
    ]


@pytest.mark.parametrize(
    ("raw", "expected"),
    (
        ("2026-08-22T08:09:10", ("2026-08-22T08:09:10+00:00", "2026-08-22")),
        ("2026-08-22T08:09:10Z", ("2026-08-22T08:09:10+00:00", "2026-08-22")),
        ("2026-08-22T11:09:10+03:00", ("2026-08-22T08:09:10+00:00", "2026-08-22")),
        ("2026-02-31T08:09:10", None),
    ),
)
def test_legacy_timestamp_parser_normalizes_historical_utc(
    raw: str,
    expected: tuple[str, str] | None,
):
    module = _load_cli_module()

    assert module._legacy_timestamp(raw) == expected


def test_migrated_recent_occurrence_wins_over_old_created_at_during_decay(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
):
    workspace, governance_dir = _install_seed(tmp_path)
    env = _platform_env(workspace, governance_dir.name, tmp_path)
    db_path, _context = _create_legacy_database(
        governance_dir,
        context_fields={
            "last_update": "2026-08-23T12:00:00+00:00",
            "created": "2026-01-01",
        },
    )
    with closing(sqlite3.connect(db_path)) as connection, connection:
        connection.execute(
            "UPDATE facts SET created_at='2026-01-01 00:00:00' WHERE id=37"
        )
        connection.commit()
    frozen_now = datetime(2026, 8, 24, 12, 0, tzinfo=timezone.utc)
    module = _load_cli_module()

    class FrozenDateTime(datetime):
        @classmethod
        def now(cls, tz=None):
            return frozen_now if tz is not None else frozen_now.replace(tzinfo=None)

    monkeypatch.setattr(module, "datetime", FrozenDateTime)
    module.decay(module.resolve_paths(env))

    assert _db_rows(
        db_path,
        "SELECT status, last_occurrence, record_date FROM facts WHERE id=37",
    ) == [("active", "2026-08-23T12:00:00+00:00", "2026-01-01")]


def test_migration_rolls_back_schema_and_backfill_together_on_failure(tmp_path: Path):
    workspace, governance_dir = _install_seed(tmp_path)
    env = _platform_env(workspace, governance_dir.name, tmp_path)
    db_path, original_context = _create_legacy_database(
        governance_dir,
        context_fields={
            "occurrences": 5,
            "severity": "critical",
            "source_citation": "must roll back",
        },
    )
    original_columns = _db_rows(db_path, "PRAGMA table_info(facts)")
    with closing(sqlite3.connect(db_path)) as connection, connection:
        # SQLite rejects CREATE TABLE when an index already owns that schema
        # name. The failure happens after ALTER/backfill, so rollback must undo
        # the whole migration rather than leave a half-upgraded database.
        connection.execute("CREATE INDEX feedback ON facts(id)")
        connection.commit()

    result = _run_cli(env, "stats")
    columns_after_failure = _db_rows(db_path, "PRAGMA table_info(facts)")
    row_after_failure = _db_rows(
        db_path,
        "SELECT id, context, extra_payload FROM facts WHERE id=37",
    )

    assert result.returncode != 0
    assert "there is already an index named feedback" in result.stderr
    assert columns_after_failure == original_columns
    assert row_after_failure == [(37, original_context, "keep-me")]


def test_valid_json_non_object_context_uses_safe_runtime_fallback(tmp_path: Path):
    workspace, governance_dir = _install_seed(tmp_path)
    env = _platform_env(workspace, governance_dir.name, tmp_path)
    faults = (
        "контекст-массив не ломает запись",
        "контекст-строка не ломает напоминание",
        "контекст-null не ломает импорт",
    )
    for fault in faults:
        assert _record(env, fault).returncode == 0
    with closing(sqlite3.connect(governance_dir / DB_REL)) as connection, connection:
        for fault, context in zip(faults, ("[]", '"string"', "null"), strict=True):
            connection.execute(
                "UPDATE facts SET context=? WHERE content=?",
                (context, fault),
            )
        connection.commit()
    feedback = governance_dir / "exocortex" / "feedback_non_object.md"
    feedback.write_text(
        """---
name: safe-context
description: context parser fallback fixture
---

## Safe import

Use during work sessions.
""",
        encoding="utf-8",
    )

    repeated = _record(env, faults[0])
    reminder = _run_cli(
        env,
        "remind",
        "--protocol",
        "open",
        "--subject-kind",
        "runtime",
        "--subject-id",
        "runtime-a",
    )
    imported = _run_cli(
        env,
        "import-feedback",
        "--subject-kind",
        "runtime",
        "--subject-id",
        "runtime-a",
    )

    for result in (repeated, reminder, imported):
        assert result.returncode == 0, result.stdout + result.stderr
        assert "Traceback" not in result.stdout + result.stderr
    assert all(fault in reminder.stdout for fault in faults)
    assert _db_rows(
        governance_dir / DB_REL,
        "SELECT occurrences_count FROM facts WHERE content=?",
        (faults[0],),
    ) == [(2,)]


def test_repeat_without_citation_preserves_existing_citation(tmp_path: Path):
    workspace, governance_dir = _install_seed(tmp_path)
    env = _platform_env(workspace, governance_dir.name, tmp_path)
    fault = "цитата переживает повтор"
    assert _record(env, fault, source_citation="Rulebook: exact source").returncode == 0
    assert _record(env, fault, source_citation="").returncode == 0

    rows = _db_rows(
        governance_dir / DB_REL,
        "SELECT source_citation FROM facts WHERE content=?",
        (fault,),
    )
    assert rows == [("Rulebook: exact source",)]


def test_repeat_sets_subtype_later_and_omission_preserves_it(tmp_path: Path):
    workspace, governance_dir = _install_seed(tmp_path)
    env = _platform_env(workspace, governance_dir.name, tmp_path)
    fault = "подтип можно уточнить после первой записи"
    assert _record(env, fault).returncode == 0
    set_later = _run_cli(
        env,
        *_record_args(fault),
        "--fault-subtype",
        "distinction-confusion",
    )
    omitted = _record(env, fault)

    assert set_later.returncode == 0, set_later.stdout + set_later.stderr
    assert omitted.returncode == 0, omitted.stdout + omitted.stderr
    assert _db_rows(
        governance_dir / DB_REL,
        "SELECT occurrences_count, fault_subtype, context FROM facts WHERE content=?",
        (fault,),
    )[0][:2] == (3, "distinction-confusion")
    context = json.loads(
        _db_rows(
            governance_dir / DB_REL,
            "SELECT context FROM facts WHERE content=?",
            (fault,),
        )[0][0]
    )
    assert context["fault_subtype"] == "distinction-confusion"


def test_stats_aggregates_legacy_and_canonical_severity_aliases(tmp_path: Path):
    workspace, governance_dir = _install_seed(tmp_path)
    env = _platform_env(workspace, governance_dir.name, tmp_path)
    severities = ("high", "major", "medium", "minor")
    for severity in severities:
        assert _record(env, f"severity alias {severity}").returncode == 0
    with closing(sqlite3.connect(governance_dir / DB_REL)) as connection, connection:
        for severity in severities:
            connection.execute(
                "UPDATE facts SET severity=? WHERE content=?",
                (severity, f"severity alias {severity}"),
            )
        connection.commit()

    result = _run_cli(env, "stats")

    assert result.returncode == 0, result.stdout + result.stderr
    assert result.stdout.splitlines() == ["active/major: 2", "active/minor: 2"]


def test_two_hundred_concurrent_records_have_exact_occurrence_count(tmp_path: Path):
    workspace, governance_dir = _install_seed(tmp_path)
    env = _platform_env(workspace, governance_dir.name, tmp_path)
    fault = "конкурентное обновление не теряет повторы"
    assert _record(env, fault).returncode == 0

    results = _run_cli_concurrently(env, _record_args(fault), 200)
    rows = _db_rows(
        governance_dir / DB_REL,
        """SELECT COUNT(*), occurrences_count FROM facts
             WHERE content=? AND subject_kind='runtime' AND subject_id='runtime-a'""",
        (fault,),
    )

    failures = [result.stderr for result in results if result.returncode != 0]
    assert not failures, "\n".join(failures)
    assert rows == [(1, 201)]


def test_concurrent_first_records_reopen_o_excl_winner_database(tmp_path: Path):
    workspace, governance_dir = _install_seed(tmp_path)
    env = _platform_env(workspace, governance_dir.name, tmp_path)
    fault = "первый конкурентный запуск безопасно переоткрывает базу"

    results = _run_cli_concurrently(env, _record_args(fault), 24)
    rows = _db_rows(
        governance_dir / DB_REL,
        "SELECT COUNT(*), occurrences_count FROM facts WHERE content=?",
        (fault,),
    )

    failures = [result.stderr for result in results if result.returncode != 0]
    assert not failures, "\n".join(failures)
    assert rows == [(1, 24)]


def test_concurrent_feedback_import_is_single_row_and_idempotent(tmp_path: Path):
    workspace, governance_dir = _install_seed(tmp_path)
    env = _platform_env(workspace, governance_dir.name, tmp_path)
    feedback = governance_dir / "exocortex" / "feedback_concurrent.md"
    feedback.write_text(
        """---
name: concurrent-feedback
description: concurrent import fixture
---

## One exact rule

Use this rule during work sessions.
""",
        encoding="utf-8",
    )
    args = (
        "import-feedback",
        "--subject-kind",
        "runtime",
        "--subject-id",
        "runtime-a",
    )

    results = _run_cli_concurrently(env, args, 10)
    rows = _db_rows(
        governance_dir / DB_REL,
        """SELECT id, COUNT(*) FROM facts
             WHERE fact_type='agent_fault' AND subject_kind='runtime'
               AND subject_id='runtime-a' AND content='concurrent-feedback: One exact rule'
             GROUP BY id""",
    )
    repeated = _run_cli(env, *args)
    rows_after_repeat = _db_rows(
        governance_dir / DB_REL,
        """SELECT id, COUNT(*) FROM facts
             WHERE fact_type='agent_fault' AND subject_kind='runtime'
               AND subject_id='runtime-a' AND content='concurrent-feedback: One exact rule'
             GROUP BY id""",
    )

    failures = [result.stderr for result in results if result.returncode != 0]
    assert not failures, "\n".join(failures)
    assert repeated.returncode == 0, repeated.stdout + repeated.stderr
    assert len(rows) == 1 and rows[0][1] == 1
    assert rows_after_repeat == rows


def test_explicit_export_is_full_regeneration_not_append_log(tmp_path: Path):
    workspace, governance_dir = _install_seed(tmp_path)
    env = _platform_env(workspace, governance_dir.name, tmp_path)
    env["IWE_SESSION_ID"] = "test-remove-me"
    assert _record(env, "удаляемая экспортная запись").returncode == 0
    env["IWE_SESSION_ID"] = "test-keep-me"
    assert _record(env, "сохраняемая экспортная запись").returncode == 0
    legacy_export = governance_dir / PROFILE_REL / "audit" / "faults-2026-08.md"
    legacy_export.parent.mkdir()
    legacy_export.write_text("stale raw fault", encoding="utf-8")

    first = _run_cli(env, "export")
    export_path = governance_dir / EXPORT_REL
    assert first.returncode == 0, first.stdout + first.stderr
    first_text = export_path.read_text(encoding="utf-8")
    assert "удаляемая экспортная запись" in first_text
    assert "сохраняемая экспортная запись" in first_text
    assert stat.S_IMODE(export_path.stat().st_mode) == 0o600
    assert not legacy_export.exists()

    removed = _run_cli(
        env,
        "remove-test",
        "--session",
        "test-remove-me",
        "--subject-kind",
        "runtime",
        "--subject-id",
        "runtime-a",
    )
    second = _run_cli(env, "export")
    assert removed.returncode == 0, removed.stdout + removed.stderr
    assert second.returncode == 0, second.stdout + second.stderr
    second_text = export_path.read_text(encoding="utf-8")
    assert "удаляемая экспортная запись" not in second_text
    assert "сохраняемая экспортная запись" in second_text
    assert second_text.count("# Agent Fault Profile export") == 1


def test_tracked_database_blocks_write_without_index_mutation(tmp_path: Path):
    spaced_root = tmp_path / "root with spaces"
    spaced_root.mkdir()
    workspace, governance_dir = _install_seed(spaced_root)
    env = _platform_env(workspace, governance_dir.name, tmp_path)
    subprocess.run(["git", "init", "-q", str(governance_dir)], check=True, timeout=10)
    assert _record(env, "первая локальная запись").returncode == 0
    subprocess.run(
        ["git", "-C", str(governance_dir), "add", "-f", "--", str(DB_REL)],
        check=True,
        timeout=10,
    )
    index_path = governance_dir / ".git" / "index"
    index_before = hashlib.sha256(index_path.read_bytes()).hexdigest()
    rows_before = _db_rows(governance_dir / DB_REL, "SELECT content FROM facts")
    profile = governance_dir / PROFILE_REL
    ignore = profile / ".gitignore"
    profile.chmod(0o755)
    ignore.write_text("sentinel: tracked refusal must not rewrite me\n", encoding="utf-8")
    ignore.chmod(0o644)
    profile_mode_before = stat.S_IMODE(profile.stat().st_mode)
    ignore_mode_before = stat.S_IMODE(ignore.stat().st_mode)
    ignore_before = ignore.read_bytes()

    blocked = _record(env, "эта запись не должна появиться")

    index_after = hashlib.sha256(index_path.read_bytes()).hexdigest()
    rows_after = _db_rows(governance_dir / DB_REL, "SELECT content FROM facts")
    assert blocked.returncode != 0
    assert f"git -C '{governance_dir}' rm --cached -- " in blocked.stderr
    assert index_after == index_before
    assert rows_after == rows_before
    assert stat.S_IMODE(profile.stat().st_mode) == profile_mode_before
    assert stat.S_IMODE(ignore.stat().st_mode) == ignore_mode_before
    assert ignore.read_bytes() == ignore_before


def test_tracked_database_missing_from_worktree_still_blocks_recreation(tmp_path: Path):
    workspace, governance_dir = _install_seed(tmp_path)
    env = _platform_env(workspace, governance_dir.name, tmp_path)
    subprocess.run(["git", "init", "-q", str(governance_dir)], check=True, timeout=10)
    assert _record(env, "индекс помнит удалённую базу").returncode == 0
    db_path = governance_dir / DB_REL
    subprocess.run(
        ["git", "-C", str(governance_dir), "add", "-f", "--", str(DB_REL)],
        check=True,
        timeout=10,
    )
    profile = governance_dir / PROFILE_REL
    shutil.rmtree(profile)
    index_path = governance_dir / ".git" / "index"
    index_before = hashlib.sha256(index_path.read_bytes()).hexdigest()
    staged_before = subprocess.run(
        ["git", "-C", str(governance_dir), "diff", "--cached", "--binary"],
        capture_output=True,
        text=True,
        check=True,
        timeout=10,
    ).stdout

    blocked = _record(env, "база не должна пересоздаться поверх tracked index")

    staged_after = subprocess.run(
        ["git", "-C", str(governance_dir), "diff", "--cached", "--binary"],
        capture_output=True,
        text=True,
        check=True,
        timeout=10,
    ).stdout
    assert blocked.returncode != 0
    assert "is tracked by Git" in blocked.stderr
    assert not profile.exists(), "tracked refusal must happen before recreating the profile"
    assert hashlib.sha256(index_path.read_bytes()).hexdigest() == index_before
    assert staged_after == staged_before


def test_parent_worktree_tracked_database_blocks_before_any_mutation(tmp_path: Path):
    workspace, governance_dir = _install_seed(tmp_path)
    env = _platform_env(workspace, governance_dir.name, tmp_path)
    subprocess.run(["git", "init", "-q", str(workspace)], check=True, timeout=10)
    assert _record(env, "родительский индекс видит базу").returncode == 0
    database_pathspec = (Path(governance_dir.name) / DB_REL).as_posix()
    subprocess.run(
        ["git", "-C", str(workspace), "add", "-f", "--", database_pathspec],
        check=True,
        timeout=10,
    )
    index_path = workspace / ".git" / "index"
    index_before = hashlib.sha256(index_path.read_bytes()).hexdigest()
    rows_before = _db_rows(governance_dir / DB_REL, "SELECT id, content FROM facts")
    profile = governance_dir / PROFILE_REL
    ignore = profile / ".gitignore"
    profile.chmod(0o755)
    ignore.write_text("parent-worktree sentinel\n", encoding="utf-8")
    ignore.chmod(0o644)
    filesystem_before = (
        stat.S_IMODE(profile.stat().st_mode),
        stat.S_IMODE(ignore.stat().st_mode),
        ignore.read_bytes(),
    )

    blocked = _record(env, "tracked parent worktree must refuse")

    assert blocked.returncode != 0
    assert "is tracked by Git" in blocked.stderr
    assert hashlib.sha256(index_path.read_bytes()).hexdigest() == index_before
    assert _db_rows(governance_dir / DB_REL, "SELECT id, content FROM facts") == rows_before
    assert (
        stat.S_IMODE(profile.stat().st_mode),
        stat.S_IMODE(ignore.stat().st_mode),
        ignore.read_bytes(),
    ) == filesystem_before


def test_git_index_redirectors_cannot_bypass_tracked_private_database(tmp_path: Path):
    workspace, governance_dir = _install_seed(tmp_path)
    env = _platform_env(workspace, governance_dir.name, tmp_path)
    subprocess.run(["git", "init", "-q", str(workspace)], check=True, timeout=10)
    assert _record(env, "основной индекс защищает приватную базу").returncode == 0
    pathspec = (Path(governance_dir.name) / DB_REL).as_posix()
    subprocess.run(
        ["git", "-C", str(workspace), "add", "-f", "--", pathspec],
        check=True,
        timeout=10,
    )
    main_index = workspace / ".git" / "index"
    alternate_index = tmp_path / "attacker-empty-index"
    redirected_env = {**os.environ, "GIT_INDEX_FILE": str(alternate_index)}
    subprocess.run(
        ["git", "-C", str(workspace), "read-tree", "--empty"],
        env=redirected_env,
        check=True,
        timeout=10,
    )
    main_before = hashlib.sha256(main_index.read_bytes()).hexdigest()
    alternate_before = hashlib.sha256(alternate_index.read_bytes()).hexdigest()
    rows_before = _db_rows(governance_dir / DB_REL, "SELECT id, content FROM facts")

    blocked = _record(
        {**env, "GIT_INDEX_FILE": str(alternate_index)},
        "redirected index must not hide tracked DB",
    )

    assert blocked.returncode != 0
    assert "is tracked by Git" in blocked.stderr
    assert hashlib.sha256(main_index.read_bytes()).hexdigest() == main_before
    assert hashlib.sha256(alternate_index.read_bytes()).hexdigest() == alternate_before
    assert _db_rows(governance_dir / DB_REL, "SELECT id, content FROM facts") == rows_before


def test_tracked_hardlink_alias_blocks_database_before_any_mutation(tmp_path: Path):
    workspace, governance_dir = _install_seed(tmp_path)
    env = _platform_env(workspace, governance_dir.name, tmp_path)
    subprocess.run(["git", "init", "-q", str(workspace)], check=True, timeout=10)
    assert _record(env, "hardlink privacy baseline").returncode == 0
    database = governance_dir / DB_REL
    alias = governance_dir / "tracked-private-db-alias.sqlite"
    os.link(database, alias)
    subprocess.run(
        [
            "git",
            "-C",
            str(workspace),
            "add",
            "-f",
            "--",
            (Path(governance_dir.name) / alias.name).as_posix(),
        ],
        check=True,
        timeout=10,
    )
    profile = governance_dir / PROFILE_REL
    ignore = profile / ".gitignore"
    profile.chmod(0o755)
    ignore.write_text("hardlink sentinel\n", encoding="utf-8")
    ignore.chmod(0o644)
    index_path = workspace / ".git" / "index"
    index_before = hashlib.sha256(index_path.read_bytes()).hexdigest()
    database_before = database.read_bytes()
    filesystem_before = (
        stat.S_IMODE(profile.stat().st_mode),
        stat.S_IMODE(ignore.stat().st_mode),
        ignore.read_bytes(),
    )

    blocked = _record(env, "hardlink alias must block")

    assert blocked.returncode != 0
    assert "hard links" in blocked.stderr
    assert hashlib.sha256(index_path.read_bytes()).hexdigest() == index_before
    assert database.read_bytes() == alias.read_bytes() == database_before
    assert (
        stat.S_IMODE(profile.stat().st_mode),
        stat.S_IMODE(ignore.stat().st_mode),
        ignore.read_bytes(),
    ) == filesystem_before


def test_case_insensitive_git_probe_blocks_uppercase_database_alias(tmp_path: Path):
    workspace, governance_dir = _install_seed(tmp_path)
    env = _platform_env(workspace, governance_dir.name, tmp_path)
    subprocess.run(["git", "init", "-q", str(workspace)], check=True, timeout=10)
    subprocess.run(
        ["git", "-C", str(workspace), "config", "core.ignorecase", "true"],
        check=True,
        timeout=10,
    )
    assert _record(env, "uppercase database baseline").returncode == 0
    database = governance_dir / DB_REL
    uppercase = database.with_name("IWE_MEMORY.DB")
    database.rename(uppercase)
    uppercase_pathspec = (
        Path(governance_dir.name) / PROFILE_REL / uppercase.name
    ).as_posix()
    subprocess.run(
        ["git", "-C", str(workspace), "add", "-f", "--", uppercase_pathspec],
        check=True,
        timeout=10,
    )
    index_path = workspace / ".git" / "index"
    index_before = hashlib.sha256(index_path.read_bytes()).hexdigest()
    bytes_before = uppercase.read_bytes()

    blocked = _record(env, "uppercase tracked alias must block")

    assert blocked.returncode != 0
    assert uppercase.name in blocked.stderr
    assert hashlib.sha256(index_path.read_bytes()).hexdigest() == index_before
    assert uppercase.read_bytes() == bytes_before


def test_nested_profile_git_index_blocks_tracked_database(tmp_path: Path):
    workspace, governance_dir = _install_seed(tmp_path)
    env = _platform_env(workspace, governance_dir.name, tmp_path)
    profile = governance_dir / PROFILE_REL
    subprocess.run(["git", "init", "-q", str(profile)], check=True, timeout=10)
    assert _record(env, "nested profile baseline").returncode == 0
    subprocess.run(
        ["git", "-C", str(profile), "add", "-f", "--", DB_REL.name],
        check=True,
        timeout=10,
    )
    index_path = profile / ".git" / "index"
    index_before = hashlib.sha256(index_path.read_bytes()).hexdigest()
    database = governance_dir / DB_REL
    database_before = database.read_bytes()
    rows_before = _db_rows(database, "SELECT id, content, occurrences_count FROM facts")

    blocked = _record(env, "nested profile index must block")

    assert blocked.returncode != 0
    assert "is tracked by Git" in blocked.stderr
    assert hashlib.sha256(index_path.read_bytes()).hexdigest() == index_before
    assert database.read_bytes() == database_before
    assert _db_rows(database, "SELECT id, content, occurrences_count FROM facts") == rows_before


def test_parent_worktree_untracked_database_is_allowed_without_index_mutation(
    tmp_path: Path,
):
    workspace, governance_dir = _install_seed(tmp_path)
    env = _platform_env(workspace, governance_dir.name, tmp_path)
    subprocess.run(["git", "init", "-q", str(workspace)], check=True, timeout=10)
    marker = workspace / "tracked-marker.txt"
    marker.write_text("parent index fixture\n", encoding="utf-8")
    subprocess.run(
        ["git", "-C", str(workspace), "add", "--", marker.name],
        check=True,
        timeout=10,
    )
    index_path = workspace / ".git" / "index"
    index_before = hashlib.sha256(index_path.read_bytes()).hexdigest()

    result = _record(env, "untracked parent worktree remains writable")

    assert result.returncode == 0, result.stdout + result.stderr
    assert hashlib.sha256(index_path.read_bytes()).hexdigest() == index_before
    assert _db_rows(
        governance_dir / DB_REL,
        "SELECT content, occurrences_count FROM facts",
    ) == [("untracked parent worktree remains writable", 1)]


@pytest.mark.parametrize("suffix", ["-wal", "-shm", "-journal"])
@pytest.mark.parametrize("present", [True, False], ids=["present", "index-only"])
def test_tracked_sqlite_sidecar_blocks_before_any_mutation(
    tmp_path: Path,
    suffix: str,
    present: bool,
):
    workspace, governance_dir = _install_seed(tmp_path)
    env = _platform_env(workspace, governance_dir.name, tmp_path)
    subprocess.run(["git", "init", "-q", str(workspace)], check=True, timeout=10)
    assert _record(env, "sidecar privacy baseline").returncode == 0
    sidecar = Path(f"{governance_dir / DB_REL}{suffix}")
    sidecar.write_bytes(f"tracked private {suffix} bytes".encode())
    sidecar.chmod(0o644)
    pathspec = (Path(governance_dir.name) / PROFILE_REL / sidecar.name).as_posix()
    subprocess.run(
        ["git", "-C", str(workspace), "add", "-f", "--", pathspec],
        check=True,
        timeout=10,
    )
    if not present:
        sidecar.unlink()
    index_path = workspace / ".git" / "index"
    index_before = hashlib.sha256(index_path.read_bytes()).hexdigest()
    bytes_before = sidecar.read_bytes() if present else None
    mode_before = stat.S_IMODE(sidecar.stat().st_mode) if present else None
    database_before = (governance_dir / DB_REL).read_bytes()

    blocked = _record(env, f"tracked {suffix} must block")

    assert blocked.returncode != 0
    assert sidecar.name in blocked.stderr
    assert hashlib.sha256(index_path.read_bytes()).hexdigest() == index_before
    if present:
        assert sidecar.read_bytes() == bytes_before
        assert stat.S_IMODE(sidecar.stat().st_mode) == mode_before
    else:
        assert not sidecar.exists()
    assert (governance_dir / DB_REL).read_bytes() == database_before


@pytest.mark.parametrize("artifact_name", ["faults.md", "faults-legacy.md"])
def test_export_refuses_tracked_snapshot_or_legacy_before_private_data_access(
    tmp_path: Path,
    artifact_name: str,
):
    workspace, governance_dir = _install_seed(tmp_path)
    env = _platform_env(workspace, governance_dir.name, tmp_path)
    subprocess.run(["git", "init", "-q", str(workspace)], check=True, timeout=10)
    secret = "RAW-FAULT-MUST-NOT-LEAK-533"
    assert _record(env, secret).returncode == 0
    audit = governance_dir / PROFILE_REL / "audit"
    audit.mkdir()
    artifact = audit / artifact_name
    artifact.write_bytes(b"tracked export sentinel\n")
    pathspec = (
        Path(governance_dir.name) / PROFILE_REL / "audit" / artifact_name
    ).as_posix()
    subprocess.run(
        ["git", "-C", str(workspace), "add", "-f", "--", pathspec],
        check=True,
        timeout=10,
    )
    index_path = workspace / ".git" / "index"
    index_before = hashlib.sha256(index_path.read_bytes()).hexdigest()
    artifact_before = artifact.read_bytes()
    database_before = (governance_dir / DB_REL).read_bytes()

    blocked = _run_cli(env, "export")

    assert blocked.returncode != 0
    assert artifact_name in blocked.stderr
    assert secret not in blocked.stdout + blocked.stderr
    assert hashlib.sha256(index_path.read_bytes()).hexdigest() == index_before
    assert artifact.read_bytes() == artifact_before
    assert (governance_dir / DB_REL).read_bytes() == database_before


def test_case_insensitive_git_probe_blocks_uppercase_export_alias(tmp_path: Path):
    workspace, governance_dir = _install_seed(tmp_path)
    env = _platform_env(workspace, governance_dir.name, tmp_path)
    subprocess.run(["git", "init", "-q", str(workspace)], check=True, timeout=10)
    subprocess.run(
        ["git", "-C", str(workspace), "config", "core.ignorecase", "true"],
        check=True,
        timeout=10,
    )
    secret = "UPPERCASE-EXPORT-MUST-NOT-LEAK-533"
    assert _record(env, secret).returncode == 0
    audit = governance_dir / PROFILE_REL / "audit"
    audit.mkdir()
    uppercase = audit / "FAULTS.MD"
    uppercase.write_bytes(b"uppercase tracked export sentinel\n")
    pathspec = (
        Path(governance_dir.name) / PROFILE_REL / "audit" / uppercase.name
    ).as_posix()
    subprocess.run(
        ["git", "-C", str(workspace), "add", "-f", "--", pathspec],
        check=True,
        timeout=10,
    )
    index_path = workspace / ".git" / "index"
    index_before = hashlib.sha256(index_path.read_bytes()).hexdigest()
    bytes_before = uppercase.read_bytes()

    blocked = _run_cli(env, "export")

    assert blocked.returncode != 0
    assert uppercase.name in blocked.stderr
    assert secret not in blocked.stdout + blocked.stderr
    assert hashlib.sha256(index_path.read_bytes()).hexdigest() == index_before
    assert uppercase.read_bytes() == bytes_before


def test_nested_audit_git_index_blocks_tracked_export(tmp_path: Path):
    workspace, governance_dir = _install_seed(tmp_path)
    env = _platform_env(workspace, governance_dir.name, tmp_path)
    first_secret = "NESTED-AUDIT-FIRST-SECRET-533"
    second_secret = "NESTED-AUDIT-SECOND-SECRET-533"
    assert _record(env, first_secret).returncode == 0
    audit = governance_dir / PROFILE_REL / "audit"
    audit.mkdir()
    subprocess.run(["git", "init", "-q", str(audit)], check=True, timeout=10)
    first_export = _run_cli(env, "export")
    assert first_export.returncode == 0, first_export.stdout + first_export.stderr
    export_path = governance_dir / EXPORT_REL
    subprocess.run(
        ["git", "-C", str(audit), "add", "-f", "--", export_path.name],
        check=True,
        timeout=10,
    )
    assert _record(env, second_secret).returncode == 0
    index_path = audit / ".git" / "index"
    index_before = hashlib.sha256(index_path.read_bytes()).hexdigest()
    export_before = export_path.read_bytes()

    blocked = _run_cli(env, "export")

    assert blocked.returncode != 0
    assert export_path.name in blocked.stderr
    assert second_secret not in blocked.stdout + blocked.stderr
    assert hashlib.sha256(index_path.read_bytes()).hexdigest() == index_before
    assert export_path.read_bytes() == export_before


def test_git_tracking_probe_error_fails_closed_before_database_mutation(tmp_path: Path):
    workspace, governance_dir = _install_seed(tmp_path)
    env = _platform_env(workspace, governance_dir.name, tmp_path)
    subprocess.run(["git", "init", "-q", str(governance_dir)], check=True, timeout=10)
    assert _record(env, "исходная запись до сбоя git").returncode == 0
    db_path = governance_dir / DB_REL
    marker = governance_dir / "tracked-marker.txt"
    marker.write_text("index fixture\n", encoding="utf-8")
    subprocess.run(
        ["git", "-C", str(governance_dir), "add", "--", marker.name],
        check=True,
        timeout=10,
    )
    index_path = governance_dir / ".git" / "index"
    index_before = hashlib.sha256(index_path.read_bytes()).hexdigest()
    database_before = hashlib.sha256(db_path.read_bytes()).hexdigest()
    rows_before = _db_rows(db_path, "SELECT id, content, occurrences_count FROM facts")
    staged_before = subprocess.run(
        ["git", "-C", str(governance_dir), "diff", "--cached", "--binary"],
        capture_output=True,
        text=True,
        check=True,
        timeout=10,
    ).stdout
    fake_bin = tmp_path / "fake-git-bin"
    fake_bin.mkdir()
    fake_git = fake_bin / "git"
    fake_git.write_text("#!/bin/sh\nexit 128\n", encoding="utf-8")
    fake_git.chmod(0o755)
    failing_env = {**env, "PATH": f"{fake_bin}:{env['PATH']}"}

    blocked = _record(failing_env, "эта запись запрещена при неизвестном Git state")

    staged_after = subprocess.run(
        ["git", "-C", str(governance_dir), "diff", "--cached", "--binary"],
        capture_output=True,
        text=True,
        check=True,
        timeout=10,
    ).stdout
    assert blocked.returncode != 0
    assert "git rev-parse exit 128" in blocked.stderr
    assert "refusing access" in blocked.stderr
    assert hashlib.sha256(db_path.read_bytes()).hexdigest() == database_before
    assert _db_rows(db_path, "SELECT id, content, occurrences_count FROM facts") == rows_before
    assert hashlib.sha256(index_path.read_bytes()).hexdigest() == index_before
    assert staged_after == staged_before


def test_corrupt_git_metadata_is_error_not_unversioned_workspace(tmp_path: Path):
    workspace, governance_dir = _install_seed(tmp_path)
    env = _platform_env(workspace, governance_dir.name, tmp_path)
    (governance_dir / ".git").mkdir()
    profile = governance_dir / PROFILE_REL
    ignore = profile / ".gitignore"
    profile.chmod(0o755)
    ignore.write_text("corrupt-git sentinel\n", encoding="utf-8")
    ignore.chmod(0o644)
    before = (
        stat.S_IMODE(profile.stat().st_mode),
        stat.S_IMODE(ignore.stat().st_mode),
        ignore.read_bytes(),
    )

    blocked = _record(env, "corrupt Git metadata must fail closed")

    assert blocked.returncode != 0
    assert "git rev-parse exit" in blocked.stderr
    assert not (governance_dir / DB_REL).exists()
    assert (
        stat.S_IMODE(profile.stat().st_mode),
        stat.S_IMODE(ignore.stat().st_mode),
        ignore.read_bytes(),
    ) == before


def test_real_update_hardens_untracked_profile_without_creating_or_staging(tmp_path: Path):
    workspace, governance_dir = _install_seed(tmp_path)
    profile = governance_dir / PROFILE_REL
    legacy_content = "update мигрирует существующую приватную базу"
    db_path, _context = _create_legacy_database(
        governance_dir,
        content=legacy_content,
    )
    subprocess.run(["git", "init", "-q", str(governance_dir)], check=True, timeout=10)
    marker = governance_dir / "tracked-marker.txt"
    marker.write_text("tracked fixture\n", encoding="utf-8")
    subprocess.run(
        ["git", "-C", str(governance_dir), "add", "--", marker.name],
        check=True,
        timeout=10,
    )
    index_path = governance_dir / ".git" / "index"

    keeper = sqlite3.connect(db_path)
    try:
        assert keeper.execute("PRAGMA journal_mode=WAL").fetchone()[0] == "wal"
        keeper.execute("PRAGMA wal_autocheckpoint=0")
        keeper.execute("UPDATE facts SET trust_score=trust_score WHERE id=37")
        keeper.commit()
        sidecars = [Path(f"{db_path}-wal"), Path(f"{db_path}-shm")]
        assert all(sidecar.is_file() for sidecar in sidecars)
        profile.chmod(0o755)
        db_path.chmod(0o644)
        for sidecar in sidecars:
            sidecar.chmod(0o644)
        index_before = hashlib.sha256(index_path.read_bytes()).hexdigest()
        staged_before = subprocess.run(
            ["git", "-C", str(governance_dir), "diff", "--cached", "--binary"],
            capture_output=True,
            text=True,
            check=True,
            timeout=10,
        ).stdout

        hardened = _run_update_hardening(workspace, governance_dir.name)

        assert hardened.returncode == 0, hardened.stdout + hardened.stderr
        assert hardened.stdout == "" and hardened.stderr == ""
        assert stat.S_IMODE(profile.stat().st_mode) == 0o700
        assert stat.S_IMODE(db_path.stat().st_mode) == 0o600
        assert all(stat.S_IMODE(sidecar.stat().st_mode) == 0o600 for sidecar in sidecars)
        assert hashlib.sha256(index_path.read_bytes()).hexdigest() == index_before
        assert subprocess.run(
            ["git", "-C", str(governance_dir), "diff", "--cached", "--binary"],
            capture_output=True,
            text=True,
            check=True,
            timeout=10,
        ).stdout == staged_before
        migrated_columns = {
            row[1] for row in _db_rows(db_path, "PRAGMA table_info(facts)")
        }
        assert {"subject_kind", "subject_id", "status"} <= migrated_columns
    finally:
        keeper.close()

    subprocess.run(
        ["git", "-C", str(governance_dir), "add", "-f", "--", str(DB_REL)],
        check=True,
        timeout=10,
    )
    tracked_index = hashlib.sha256(index_path.read_bytes()).hexdigest()
    tracked_staged = subprocess.run(
        ["git", "-C", str(governance_dir), "diff", "--cached", "--binary"],
        capture_output=True,
        text=True,
        check=True,
        timeout=10,
    ).stdout
    refused = _run_update_hardening(workspace, governance_dir.name)
    assert refused.returncode == 0
    assert "is tracked by Git" in refused.stderr
    assert legacy_content not in refused.stderr
    assert hashlib.sha256(index_path.read_bytes()).hexdigest() == tracked_index
    assert subprocess.run(
        ["git", "-C", str(governance_dir), "diff", "--cached", "--binary"],
        capture_output=True,
        text=True,
        check=True,
        timeout=10,
    ).stdout == tracked_staged

    shutil.rmtree(profile)
    absent_index = hashlib.sha256(index_path.read_bytes()).hexdigest()
    absent_staged = subprocess.run(
        ["git", "-C", str(governance_dir), "diff", "--cached", "--binary"],
        capture_output=True,
        text=True,
        check=True,
        timeout=10,
    ).stdout
    absent = _run_update_hardening(workspace, governance_dir.name)
    assert absent.returncode == 0, absent.stdout + absent.stderr
    assert "is tracked by Git" in absent.stderr
    assert not profile.exists()
    assert not db_path.exists()
    assert hashlib.sha256(index_path.read_bytes()).hexdigest() == absent_index
    assert subprocess.run(
        ["git", "-C", str(governance_dir), "diff", "--cached", "--binary"],
        capture_output=True,
        text=True,
        check=True,
        timeout=10,
    ).stdout == absent_staged
    update_source = UPDATE.read_text(encoding="utf-8")
    assert "harden_agent_fault_profile_after_update" in update_source
    assert "IWE_WORKSPACE=\"$WORKSPACE_DIR\"" in update_source
    post_apply = _update_shell_function("run_post_apply_backfills_or_die")
    assert post_apply.index("harden_agent_fault_profile_after_update") < post_apply.index(
        "backfill_legacy_agent_fault_shims"
    )


@pytest.mark.parametrize(
    "unsafe_name",
    ("../escaped", ".hidden", "bad/name", "bad\\name", "x" * 65),
)
def test_writer_refuses_unsafe_governance_names(tmp_path: Path, unsafe_name: str):
    workspace = tmp_path / "iwe"
    workspace.mkdir()
    env = _platform_env(workspace, unsafe_name, tmp_path)

    result = _record(env, "не выходить из workspace", subject_id="runtime-path")

    assert result.returncode != 0
    assert not (tmp_path / "escaped" / DB_REL).exists()
    if unsafe_name == ".hidden":
        assert "[A-Za-z0-9._-]" in result.stderr
        assert "no leading dot" in result.stderr


@pytest.mark.parametrize("link_at", ("governance", "profile", "gitignore", "database"))
def test_writer_refuses_symlinked_private_path(tmp_path: Path, link_at: str):
    workspace, governance_dir = _install_seed(tmp_path)
    env = _platform_env(workspace, governance_dir.name, tmp_path)
    outside = tmp_path / "outside-private-data"
    outside.mkdir()

    if link_at == "governance":
        shutil.rmtree(governance_dir)
        governance_dir.symlink_to(outside, target_is_directory=True)
    elif link_at == "profile":
        profile = governance_dir / PROFILE_REL
        shutil.rmtree(profile)
        profile.symlink_to(outside, target_is_directory=True)
    elif link_at == "gitignore":
        ignore = governance_dir / PROFILE_REL / ".gitignore"
        ignore.unlink()
        ignore.symlink_to(outside / "captured-ignore")
    else:
        database = governance_dir / DB_REL
        database.symlink_to(outside / "captured-database")

    result = _record(env, "не писать через symlink", subject_id="runtime-link")

    assert result.returncode != 0
    assert list(outside.iterdir()) == []


def test_feedback_import_adopts_one_proven_legacy_row_without_duplicate(tmp_path: Path):
    workspace, governance_dir = _install_seed(tmp_path)
    env = _platform_env(workspace, governance_dir.name, tmp_path)
    feedback = governance_dir / "exocortex" / "feedback_legacy.md"
    feedback.write_text(
        """---
name: Legacy rules
description: adoption fixture
---

## Exact key

Use during work sessions.
""",
        encoding="utf-8",
    )
    db_path, _context = _create_legacy_database(
        governance_dir,
        content="old imported content",
        personality_id="",
        context_fields={
            "source_file": feedback.stem,
            "rule_name": "Exact key",
            "unknown_context_key": "keep-context",
            "occurrences": 3,
            "severity": "major",
        },
    )
    with closing(sqlite3.connect(db_path)) as connection, connection:
        connection.execute(
            "UPDATE facts SET session_id='sync-feedback', personality_id=NULL WHERE id=37"
        )
        connection.commit()
    args = (
        "import-feedback",
        "--subject-kind",
        "system",
        "--subject-id",
        "feedback-import",
    )

    first = _run_cli(env, *args)
    first_rows = _db_rows(
        db_path,
        """SELECT id, content, context, extra_payload, subject_kind, subject_id
             FROM facts WHERE fact_type='agent_fault'""",
    )
    second = _run_cli(env, *args)
    second_rows = _db_rows(
        db_path,
        """SELECT id, content, context, extra_payload, subject_kind, subject_id
             FROM facts WHERE fact_type='agent_fault'""",
    )

    assert first.returncode == 0, first.stdout + first.stderr
    assert second.returncode == 0, second.stdout + second.stderr
    assert len(first_rows) == len(second_rows) == 1
    for rows in (first_rows, second_rows):
        row = rows[0]
        assert row[0] == 37
        assert row[1] == "Legacy rules: Exact key"
        assert row[3:] == ("keep-me", "system", "feedback-import")
        assert json.loads(row[2])["unknown_context_key"] == "keep-context"


def test_feedback_adoption_preserves_five_textual_date_incidents_monotonically(
    tmp_path: Path,
):
    workspace, governance_dir = _install_seed(tmp_path)
    env = _platform_env(workspace, governance_dir.name, tmp_path)
    feedback = governance_dir / "exocortex" / "feedback_textual_dates.md"
    feedback.write_text(
        """---
name: Legacy dated rules
description: actual legacy journal shape
---

## Exact dated rule

Use during work sessions.

**Журнал:**
- 1 августа 2026 — первое нарушение
- 2 августа 2026 — второе нарушение
- 3 августа 2026 — третье нарушение
- 4 августа 2026 — четвёртое нарушение
- 5 августа 2026 — пятое нарушение
""",
        encoding="utf-8",
    )
    db_path, _context = _create_legacy_database(
        governance_dir,
        content="legacy critical content",
        personality_id="",
        context_fields={
            "source_file": feedback.stem,
            "rule_name": "Exact dated rule",
            "occurrences": 5,
            "severity": "critical",
            "last_sync": "2026-08-05T12:00:00",
        },
    )
    with closing(sqlite3.connect(db_path)) as connection, connection:
        connection.execute(
            """UPDATE facts
                  SET session_id='sync-feedback', personality_id=NULL, trust_score=0.95
                WHERE id=37"""
        )
        connection.commit()
    args = (
        "import-feedback",
        "--subject-kind",
        "system",
        "--subject-id",
        "feedback-import",
    )

    first = _run_cli(env, *args)
    second = _run_cli(env, *args)
    rows = _db_rows(
        db_path,
        """SELECT id, occurrences_count, severity, trust_score, context
             FROM facts WHERE fact_type='agent_fault'""",
    )

    assert first.returncode == 0, first.stdout + first.stderr
    assert second.returncode == 0, second.stdout + second.stderr
    assert len(rows) == 1
    row = rows[0]
    assert row[:3] == (37, 5, "critical")
    assert row[3] == pytest.approx(0.95)
    context = json.loads(row[4])
    assert context["occurrences"] == 5
    assert context["severity"] == "critical"


def test_feedback_long_journal_keeps_legacy_occurrence_estimate(tmp_path: Path):
    feedback = tmp_path / "feedback_long_journal.md"
    feedback.write_text(
        """---
name: Long journal
description: length estimate fixture
---

## Long exact rule

**Журнал:**
"""
        + ("x" * 1500),
        encoding="utf-8",
    )
    module = _load_cli_module()

    faults = module._feedback_faults(feedback)

    assert len(faults) == 1
    assert faults[0]["occurrences"] == 5
    assert faults[0]["severity"] == "critical"


@pytest.mark.parametrize(
    ("protocol", "body"),
    (
        ("open", "Apply this during the open protocol."),
        ("close", "Apply this during the close protocol."),
    ),
)
def test_feedback_adoption_keeps_legacy_protocol_conjunction_heuristics(
    tmp_path: Path,
    protocol: str,
    body: str,
):
    workspace, governance_dir = _install_seed(tmp_path)
    env = _platform_env(workspace, governance_dir.name, tmp_path)
    feedback = governance_dir / "exocortex" / f"feedback_{protocol}_protocol.md"
    feedback.write_text(
        f"""---
name: {protocol} rules
description: protocol conjunction fixture
---

## Exact protocol rule

{body}
""",
        encoding="utf-8",
    )
    db_path, _context = _create_legacy_database(
        governance_dir,
        content=f"legacy {protocol} content",
        personality_id="",
        context_fields={
            "source_file": feedback.stem,
            "rule_name": "Exact protocol rule",
            "protocols": [protocol],
        },
    )
    with closing(sqlite3.connect(db_path)) as connection, connection:
        connection.execute(
            "UPDATE facts SET session_id='sync-feedback', personality_id=NULL WHERE id=37"
        )
        connection.commit()

    result = _run_cli(
        env,
        "import-feedback",
        "--subject-kind",
        "system",
        "--subject-id",
        "feedback-import",
    )
    rows = _db_rows(db_path, "SELECT id, context FROM facts")

    assert result.returncode == 0, result.stdout + result.stderr
    assert len(rows) == 1 and rows[0][0] == 37
    assert json.loads(rows[0][1])["protocols"] == [protocol]


def test_noncanonical_subject_cannot_adopt_unassigned_legacy_feedback(tmp_path: Path):
    workspace, governance_dir = _install_seed(tmp_path)
    env = _platform_env(workspace, governance_dir.name, tmp_path)
    feedback = governance_dir / "exocortex" / "feedback_guarded.md"
    feedback.write_text(
        """---
name: Guarded rules
description: subject guard fixture
---

## Exact key

Use during work sessions.
""",
        encoding="utf-8",
    )
    db_path, _context = _create_legacy_database(
        governance_dir,
        personality_id="",
        context_fields={
            "source_file": feedback.stem,
            "rule_name": "Exact key",
        },
    )
    with closing(sqlite3.connect(db_path)) as connection, connection:
        connection.execute(
            "UPDATE facts SET session_id='sync-feedback', personality_id=NULL WHERE id=37"
        )
        connection.commit()

    result = _run_cli(
        env,
        "import-feedback",
        "--subject-kind",
        "runtime",
        "--subject-id",
        "victim",
    )

    assert result.returncode == 0, result.stdout + result.stderr
    assert _db_rows(
        db_path,
        "SELECT id, subject_kind, subject_id FROM facts ORDER BY id",
    ) == [(37, None, None), (38, "runtime", "victim")]


def test_feedback_import_refuses_ambiguous_legacy_adoption(tmp_path: Path):
    workspace, governance_dir = _install_seed(tmp_path)
    env = _platform_env(workspace, governance_dir.name, tmp_path)
    feedback = governance_dir / "exocortex" / "feedback_ambiguous.md"
    feedback.write_text(
        """---
name: Ambiguous rules
description: ambiguity fixture
---

## Same key

Use during work sessions.
""",
        encoding="utf-8",
    )
    db_path, context = _create_legacy_database(
        governance_dir,
        content="first old import",
        personality_id="",
        context_fields={
            "source_file": feedback.stem,
            "rule_name": "Same key",
        },
    )
    with closing(sqlite3.connect(db_path)) as connection, connection:
        connection.execute(
            "UPDATE facts SET session_id='sync-feedback', personality_id=NULL WHERE id=37"
        )
        connection.execute(
            """INSERT INTO facts (
                   id, fact_type, content, context, trust_score, session_id,
                   personality_id, extra_payload
               ) VALUES (38, 'agent_fault', 'second old import', ?, 0.5,
                         'sync-feedback', NULL, 'keep-second')""",
            (context,),
        )
        connection.commit()

    blocked = _run_cli(
        env,
        "import-feedback",
        "--subject-kind",
        "system",
        "--subject-id",
        "feedback-import",
    )

    assert blocked.returncode != 0
    assert "ambiguous feedback rows" in blocked.stderr
    assert _db_rows(
        db_path,
        "SELECT id, subject_kind, subject_id, extra_payload FROM facts ORDER BY id",
    ) == [(37, None, None, "keep-me"), (38, None, None, "keep-second")]


def test_feedback_compatibility_wrapper_uses_canonical_system_subject(tmp_path: Path):
    workspace, governance_dir = _install_seed(tmp_path)
    env = _platform_env(workspace, governance_dir.name, tmp_path)
    feedback = workspace / "memory" / "feedback_issue_533.md"
    feedback.parent.mkdir()
    feedback.write_text(
        """---
name: Router discipline
description: Router must preserve fault text
---

## Правило: Не дробить текст

Передавать всё описание ошибки.

**Журнал:**
- 2026-08-20: WP-7 первое нарушение.
- 2026-08-21: WP-7 второе нарушение.
""",
        encoding="utf-8",
    )

    for _ in range(2):
        result = subprocess.run(
            [sys.executable, str(ROOT / "scripts" / "sync_feedback_to_memory.py")],
            env=env,
            capture_output=True,
            text=True,
            check=False,
            timeout=20,
        )
        assert result.returncode == 0, result.stdout + result.stderr

    rows = _db_rows(
        governance_dir / DB_REL,
        """SELECT subject_kind, subject_id, content, COUNT(*)
           FROM facts WHERE fact_type='agent_fault'
           GROUP BY subject_kind, subject_id, content""",
    )
    assert rows == [
        ("system", "feedback-import", "Router discipline: Правило: Не дробить текст", 1)
    ]
    rejected_override = subprocess.run(
        [
            sys.executable,
            str(ROOT / "scripts" / "sync_feedback_to_memory.py"),
            "--subject-kind",
            "runtime",
            "--subject-id=attacker-controlled",
        ],
        env=env,
        capture_output=True,
        text=True,
        check=False,
        timeout=20,
    )
    assert rejected_override.returncode != 0
    assert "subject overrides are not allowed" in rejected_override.stderr
    abbreviated_override = subprocess.run(
        [
            sys.executable,
            str(ROOT / "scripts" / "sync_feedback_to_memory.py"),
            "--subject-k",
            "runtime",
            "--subject-i",
            "attacker-controlled",
        ],
        env=env,
        capture_output=True,
        text=True,
        check=False,
        timeout=20,
    )
    assert abbreviated_override.returncode == 0, (
        abbreviated_override.stdout + abbreviated_override.stderr
    )
    assert _db_rows(
        governance_dir / DB_REL,
        "SELECT DISTINCT subject_kind, subject_id FROM facts",
    ) == [("system", "feedback-import")]
    assert not (governance_dir / PROFILE_REL / "audit").exists()


def test_legacy_reader_wrappers_keep_stats_and_subject_reminders(tmp_path: Path):
    workspace, governance_dir = _install_seed(tmp_path)
    env = _platform_env(workspace, governance_dir.name, tmp_path)
    env["IWE_FAULT_SUBJECT_KIND"] = "runtime"
    env["IWE_FAULT_SUBJECT_ID"] = "runtime-legacy"
    fault = "старые точки входа используют единый CLI"
    other_fault = "ошибка другого субъекта не должна попасть в обёртку"
    assert _record(env, fault, subject_id="runtime-legacy").returncode == 0
    other = _run_cli(
        env,
        "record",
        "--severity",
        "critical",
        "--protocol",
        "open",
        "--fault",
        other_fault,
        "--source-citation",
        "AGENTS.md: cross-subject fixture",
        "--subject-kind",
        "runtime",
        "--subject-id",
        "runtime-other",
    )
    assert other.returncode == 0, other.stdout + other.stderr

    python_stats = subprocess.run(
        [sys.executable, str(ROOT / "scripts" / "agent_fault_remind.py"), "--stats"],
        env=env,
        capture_output=True,
        text=True,
        check=False,
        timeout=20,
    )
    shell_stats = subprocess.run(
        ["bash", str(ROOT / "scripts" / "agent_fault_remind.sh"), "--stats"],
        env=env,
        capture_output=True,
        text=True,
        check=False,
        timeout=20,
    )
    python_reminder = subprocess.run(
        [
            sys.executable,
            str(ROOT / "scripts" / "agent_fault_remind.py"),
            "--protocol",
            "open",
        ],
        env=env,
        capture_output=True,
        text=True,
        check=False,
        timeout=20,
    )
    shell_reminder = subprocess.run(
        ["bash", str(ROOT / "scripts" / "agent_fault_remind.sh"), "open"],
        env=env,
        capture_output=True,
        text=True,
        check=False,
        timeout=20,
    )

    for result in (python_stats, shell_stats):
        assert result.returncode == 0, result.stdout + result.stderr
        assert "active/major: 1" in result.stdout
        assert "active/critical" not in result.stdout
    for result in (python_reminder, shell_reminder):
        assert result.returncode == 0, result.stdout + result.stderr
        assert fault in result.stdout
        assert other_fault not in result.stdout


def test_top_level_legacy_reminders_refuse_missing_subject_without_creating_db(
    tmp_path: Path,
):
    workspace, governance_dir = _install_seed(tmp_path)
    env = _platform_env(workspace, governance_dir.name, tmp_path)
    env.pop("IWE_FAULT_SUBJECT_KIND", None)
    env.pop("IWE_FAULT_SUBJECT_ID", None)
    commands = (
        [sys.executable, str(ROOT / "scripts" / "agent_fault_remind.py"), "--stats"],
        ["bash", str(ROOT / "scripts" / "agent_fault_remind.sh"), "--stats"],
        [
            sys.executable,
            str(ROOT / "scripts" / "agent_fault_remind.py"),
            "--protocol",
            "open",
        ],
        ["bash", str(ROOT / "scripts" / "agent_fault_remind.sh"), "open"],
    )

    results = [
        subprocess.run(
            command,
            env=env,
            capture_output=True,
            text=True,
            check=False,
            timeout=20,
        )
        for command in commands
    ]

    assert all(result.returncode != 0 for result in results)
    assert all("exact subject" in result.stderr for result in results)
    assert not (governance_dir / DB_REL).exists()


def test_fresh_seed_legacy_names_delegate_with_exact_subjects(tmp_path: Path):
    workspace, governance_dir = _install_seed(tmp_path)
    _install_workspace_cli(workspace)
    env = _platform_env(workspace, governance_dir.name, tmp_path)
    env["IWE_FAULT_SUBJECT_KIND"] = "runtime"
    env["IWE_FAULT_SUBJECT_ID"] = "runtime-seed-shim"
    scripts = governance_dir / "scripts"
    fault = "fresh seed legacy command reached canonical storage"
    record_args = (
        "record",
        "--fault",
        fault,
        "--severity",
        "major",
        "--protocol",
        "open",
        "--subject-kind",
        "runtime",
        "--subject-id",
        "runtime-seed-shim",
    )
    for _index in range(3):
        result = subprocess.run(
            [sys.executable, str(scripts / "iwe_checklist_memory.py"), *record_args],
            env=env,
            capture_output=True,
            text=True,
            check=False,
            timeout=20,
        )
        assert result.returncode == 0, result.stdout + result.stderr

    escalation = subprocess.run(
        [
            sys.executable,
            str(scripts / "iwe_checklist_memory.py"),
            "escalation-check",
            "--threshold",
            "3",
            "--subject-kind",
            "runtime",
            "--subject-id",
            "runtime-seed-shim",
        ],
        env=env,
        capture_output=True,
        text=True,
        check=False,
        timeout=20,
    )
    python_reminder = subprocess.run(
        [sys.executable, str(scripts / "agent_fault_remind.py"), "--protocol", "open"],
        env=env,
        capture_output=True,
        text=True,
        check=False,
        timeout=20,
    )
    shell_reminder = subprocess.run(
        ["bash", str(scripts / "agent_fault_remind.sh"), "open"],
        env=env,
        capture_output=True,
        text=True,
        check=False,
        timeout=20,
    )

    for result in (escalation, python_reminder, shell_reminder):
        assert result.returncode == 0, result.stdout + result.stderr
        assert fault in result.stdout
    assert _db_rows(
        governance_dir / DB_REL,
        "SELECT DISTINCT subject_kind, subject_id FROM facts",
    ) == [("runtime", "runtime-seed-shim")]


def test_seed_shim_pins_installed_workspace_and_ignores_stale_foreign_cli(
    tmp_path: Path,
):
    workspace, governance_dir = _install_seed(tmp_path / "installed")
    _install_workspace_cli(workspace)
    foreign_workspace = tmp_path / "foreign-workspace"
    foreign_cli = foreign_workspace / CLI_REL
    foreign_cli.parent.mkdir(parents=True)
    sentinel = tmp_path / "foreign-cli-executed"
    foreign_cli.write_text(
        "from pathlib import Path\n"
        f"Path({str(sentinel)!r}).write_text('executed', encoding='utf-8')\n",
        encoding="utf-8",
    )
    env = _platform_env(workspace, governance_dir.name, tmp_path)
    env.update(
        {
            "IWE_WORKSPACE": str(foreign_workspace),
            "WORKSPACE_DIR": str(foreign_workspace),
            "IWE_GOVERNANCE_REPO": "foreign-governance",
            "GOVERNANCE_REPO": "foreign-governance",
            "IWE_SCRIPTS": str(foreign_workspace / "scripts"),
        }
    )
    fault = "installed seed shim writes only its physical workspace"

    recorded = subprocess.run(
        [
            sys.executable,
            str(governance_dir / "scripts" / "iwe_checklist_memory.py"),
            *_record_args(fault),
        ],
        env=env,
        capture_output=True,
        text=True,
        check=False,
        timeout=20,
    )

    assert recorded.returncode == 0, recorded.stdout + recorded.stderr
    assert not sentinel.exists()
    assert _db_rows(
        governance_dir / DB_REL,
        "SELECT content, subject_kind, subject_id FROM facts",
    ) == [(fault, "runtime", "runtime-a")]
    assert not (foreign_workspace / "foreign-governance" / DB_REL).exists()


def test_seed_shim_allows_only_workspace_internal_configured_cli(tmp_path: Path):
    workspace, governance_dir = _install_seed(tmp_path / "internal")
    internal_scripts = workspace / "internal-runtime-scripts"
    internal_cli = internal_scripts / "agent-fault" / CLI.name
    internal_cli.parent.mkdir(parents=True)
    shutil.copy2(CLI, internal_cli)
    configured_scripts = workspace / "runtime-scripts"
    configured_scripts.symlink_to(internal_scripts, target_is_directory=True)
    env = _platform_env(workspace, governance_dir.name, tmp_path)
    env["IWE_SCRIPTS"] = str(configured_scripts)

    allowed = subprocess.run(
        [
            sys.executable,
            str(governance_dir / "scripts" / "iwe_checklist_memory.py"),
            *_record_args("internal configured CLI is allowed"),
        ],
        env=env,
        capture_output=True,
        text=True,
        check=False,
        timeout=20,
    )

    assert allowed.returncode == 0, allowed.stdout + allowed.stderr
    assert (governance_dir / DB_REL).exists()

    rejected_workspace, rejected_governance = _install_seed(tmp_path / "rejected")
    external_scripts = tmp_path / "external-runtime-scripts"
    external_cli = external_scripts / "agent-fault" / CLI.name
    external_cli.parent.mkdir(parents=True)
    sentinel = tmp_path / "external-configured-cli-executed"
    external_cli.write_text(
        "from pathlib import Path\n"
        f"Path({str(sentinel)!r}).write_text('executed', encoding='utf-8')\n",
        encoding="utf-8",
    )
    rejected_env = _platform_env(
        rejected_workspace,
        rejected_governance.name,
        tmp_path,
    )
    rejected_env["IWE_SCRIPTS"] = str(external_scripts)
    rejected = subprocess.run(
        [
            sys.executable,
            str(rejected_governance / "scripts" / "iwe_checklist_memory.py"),
            "--help",
        ],
        env=rejected_env,
        capture_output=True,
        text=True,
        check=False,
        timeout=20,
    )

    assert rejected.returncode != 0
    assert "canonical agent-fault CLI is unavailable" in rejected.stderr
    assert not sentinel.exists()
    assert not (rejected_governance / DB_REL).exists()


@pytest.mark.parametrize(
    "partial_flags",
    (("--subject-kind", "personality"), ("--subject-id", "override-only")),
)
def test_legacy_reminders_refuse_half_flag_override_before_env_fallback(
    tmp_path: Path,
    partial_flags: tuple[str, str],
):
    workspace, governance_dir = _install_seed(tmp_path)
    env = _platform_env(workspace, governance_dir.name, tmp_path)
    env["IWE_FAULT_SUBJECT_KIND"] = "runtime"
    env["IWE_FAULT_SUBJECT_ID"] = "runtime-env"
    wrappers = (
        ROOT / "scripts" / "agent_fault_remind.py",
        governance_dir / "scripts" / "agent_fault_remind.py",
    )

    results = [
        subprocess.run(
            [sys.executable, str(wrapper), "--stats", *partial_flags],
            env=env,
            capture_output=True,
            text=True,
            check=False,
            timeout=20,
        )
        for wrapper in wrappers
    ]

    assert all(result.returncode != 0 for result in results)
    assert all("supplied together" in result.stderr for result in results)
    assert not (governance_dir / DB_REL).exists()


def test_fresh_seed_stats_refuses_missing_exact_subject_without_creating_db(
    tmp_path: Path,
):
    workspace, governance_dir = _install_seed(tmp_path)
    env = _platform_env(workspace, governance_dir.name, tmp_path)
    env.pop("IWE_FAULT_SUBJECT_KIND", None)
    env.pop("IWE_FAULT_SUBJECT_ID", None)

    refused = subprocess.run(
        [
            sys.executable,
            str(governance_dir / "scripts" / "agent_fault_remind.py"),
            "--stats",
        ],
        env=env,
        capture_output=True,
        text=True,
        check=False,
        timeout=20,
    )

    assert refused.returncode != 0
    assert "stats require one exact subject" in refused.stderr
    assert not (governance_dir / DB_REL).exists()


def test_fresh_seed_feedback_shim_pins_system_subject(tmp_path: Path):
    workspace, governance_dir = _install_seed(tmp_path)
    _install_workspace_cli(workspace)
    env = _platform_env(workspace, governance_dir.name, tmp_path)
    feedback = governance_dir / "exocortex" / "feedback_seed_shim.md"
    feedback.write_text(
        """---
name: Seed shim
description: fixed subject fixture
---

## One rule

Use during work.
""",
        encoding="utf-8",
    )
    wrapper = governance_dir / "scripts" / "sync_feedback_to_memory.py"

    imported = subprocess.run(
        [sys.executable, str(wrapper)],
        env=env,
        capture_output=True,
        text=True,
        check=False,
        timeout=20,
    )
    override = subprocess.run(
        [sys.executable, str(wrapper), "--subject-kind", "runtime", "--subject-id", "victim"],
        env=env,
        capture_output=True,
        text=True,
        check=False,
        timeout=20,
    )

    assert imported.returncode == 0, imported.stdout + imported.stderr
    assert override.returncode != 0
    assert "subject overrides are not allowed" in override.stderr
    assert _db_rows(
        governance_dir / DB_REL,
        "SELECT DISTINCT subject_kind, subject_id FROM facts",
    ) == [("system", "feedback-import")]


def test_mixed_canonical_and_seed_legacy_records_are_atomic(tmp_path: Path):
    workspace, governance_dir = _install_seed(tmp_path)
    _install_workspace_cli(workspace)
    env = _platform_env(workspace, governance_dir.name, tmp_path)
    fault = "mixed canonical and compatibility writers remain one row"
    arguments = _record_args(fault)
    canonical = (sys.executable, str(CLI), *arguments)
    compatibility = (
        sys.executable,
        str(governance_dir / "scripts" / "iwe_checklist_memory.py"),
        *arguments,
    )
    commands = [canonical if index % 2 == 0 else compatibility for index in range(200)]

    results = _run_commands_concurrently(env, commands)

    failures = [result for result in results if result.returncode != 0]
    assert not failures, "\n".join(result.stdout + result.stderr for result in failures)
    assert _db_rows(
        governance_dir / DB_REL,
        "SELECT content, occurrences_count FROM facts",
    ) == [(fault, 200)]


def test_real_hook_reads_only_explicit_subject(tmp_path: Path):
    if shutil.which("jq") is None:
        pytest.skip("jq is required by the real UserPromptSubmit hook")
    workspace, governance_dir = _install_seed(tmp_path)
    _install_workspace_cli(workspace)
    env = _platform_env(workspace, governance_dir.name, tmp_path)
    env.update(
        {
            "CLAUDE_PROJECT_DIR": str(workspace),
        }
    )
    env.pop("IWE_FAULT_SUBJECT_KIND", None)
    env.pop("IWE_FAULT_SUBJECT_ID", None)
    fault = "хук увидел только свой повторяющийся косяк"
    for _ in range(3):
        result = _record(env, fault, subject_id="claude-code")
        assert result.returncode == 0, result.stdout + result.stderr
    assert _record(env, "чужой runtime", subject_id="runtime-other").returncode == 0

    hook = subprocess.run(
        ["bash", str(HOOK)],
        env=env,
        input=json.dumps({"session_id": "issue533hook"}),
        capture_output=True,
        text=True,
        check=False,
        timeout=20,
    )

    assert hook.returncode == 0, hook.stdout + hook.stderr
    payload = json.loads(hook.stdout)
    context = payload["hookSpecificOutput"]["additionalContext"]
    assert fault in context
    assert "чужой runtime" not in context


def test_hook_pins_custom_project_as_cli_workspace(tmp_path: Path):
    if shutil.which("jq") is None:
        pytest.skip("jq is required by the real UserPromptSubmit hook")
    workspace, governance_dir = _install_seed(tmp_path)
    installed_cli = workspace / "FMT-exocortex-template" / CLI_REL
    installed_cli.parent.mkdir(parents=True)
    shutil.copy2(CLI, installed_cli)
    record_env = _platform_env(workspace, governance_dir.name, tmp_path)
    fault = "hook читает профиль custom workspace, а не HOME/IWE"
    for _ in range(3):
        result = _record(record_env, fault, subject_id="claude-code")
        assert result.returncode == 0, result.stdout + result.stderr

    hook_env = os.environ.copy()
    hook_env.update(
        {
            "HOME": str(tmp_path / "different-home"),
            "CLAUDE_PROJECT_DIR": str(workspace),
            "IWE_GOVERNANCE_REPO": governance_dir.name,
            "PYTHONDONTWRITEBYTECODE": "1",
        }
    )
    for name in ("IWE_WORKSPACE", "WORKSPACE_DIR", "IWE_SCRIPTS"):
        hook_env.pop(name, None)
    hook = subprocess.run(
        ["bash", str(HOOK)],
        env=hook_env,
        input=json.dumps({"session_id": "issue533customworkspace"}),
        capture_output=True,
        text=True,
        check=False,
        timeout=20,
    )

    assert hook.returncode == 0, hook.stdout + hook.stderr
    payload = json.loads(hook.stdout)
    assert fault in payload["hookSpecificOutput"]["additionalContext"]
    assert not (Path(hook_env["HOME"]) / "IWE").exists()


@pytest.mark.parametrize(
    "half_subject",
    (
        {"IWE_FAULT_SUBJECT_KIND": "runtime"},
        {"IWE_FAULT_SUBJECT_ID": "half-only"},
    ),
)
def test_hook_refuses_half_subject_without_state_or_database(
    tmp_path: Path,
    half_subject: dict[str, str],
):
    if shutil.which("jq") is None:
        pytest.skip("jq is required by the real UserPromptSubmit hook")
    workspace, governance_dir = _install_seed(tmp_path)
    env = _platform_env(workspace, governance_dir.name, tmp_path)
    env["CLAUDE_PROJECT_DIR"] = str(workspace)
    env.pop("IWE_FAULT_SUBJECT_KIND", None)
    env.pop("IWE_FAULT_SUBJECT_ID", None)
    env.update(half_subject)

    hook = subprocess.run(
        ["bash", str(HOOK)],
        env=env,
        input=json.dumps({"session_id": "issue533halfsubject"}),
        capture_output=True,
        text=True,
        check=False,
        timeout=20,
    )

    assert hook.returncode == 0, hook.stdout + hook.stderr
    assert json.loads(hook.stdout) == {}
    assert not (workspace / ".claude" / "state").exists()
    assert not (governance_dir / DB_REL).exists()


def test_hook_rejects_foreign_scripts_and_allows_internal_symlink_runtime(
    tmp_path: Path,
):
    if shutil.which("jq") is None:
        pytest.skip("jq is required by the real UserPromptSubmit hook")
    rejected_workspace, rejected_governance = _install_seed(tmp_path / "rejected-hook")
    foreign_scripts = tmp_path / "foreign-hook-scripts"
    foreign_cli = foreign_scripts / "agent-fault" / CLI.name
    foreign_cli.parent.mkdir(parents=True)
    foreign_sentinel = tmp_path / "foreign-hook-cli-executed"
    foreign_cli.write_text(
        "from pathlib import Path\n"
        f"Path({str(foreign_sentinel)!r}).write_text('executed', encoding='utf-8')\n"
        "print('🔴 [CRITICAL | n=9] foreign output')\n",
        encoding="utf-8",
    )
    rejected_env = _platform_env(
        rejected_workspace,
        rejected_governance.name,
        tmp_path,
    )
    rejected_env.update(
        {
            "CLAUDE_PROJECT_DIR": str(rejected_workspace),
            "IWE_SCRIPTS": str(foreign_scripts),
        }
    )
    rejected = subprocess.run(
        ["bash", str(HOOK)],
        env=rejected_env,
        input=json.dumps({"session_id": "issue533foreignhook"}),
        capture_output=True,
        text=True,
        check=False,
        timeout=20,
    )
    assert rejected.returncode == 0, rejected.stdout + rejected.stderr
    assert json.loads(rejected.stdout) == {}
    assert not foreign_sentinel.exists()
    assert not (rejected_workspace / ".claude" / "state").exists()

    workspace, governance_dir = _install_seed(tmp_path / "internal-hook")
    internal_scripts = workspace / "internal-hook-scripts"
    internal_cli = internal_scripts / "agent-fault" / CLI.name
    internal_cli.parent.mkdir(parents=True)
    shutil.copy2(CLI, internal_cli)
    configured_scripts = workspace / "runtime-hook-scripts"
    configured_scripts.symlink_to(internal_scripts, target_is_directory=True)
    record_env = _platform_env(workspace, governance_dir.name, tmp_path)
    fault = "hook accepted its internal symlinked runtime"
    for _ in range(3):
        assert _record(record_env, fault, subject_id="claude-code").returncode == 0
    hook_env = {**record_env, "CLAUDE_PROJECT_DIR": str(workspace)}
    hook_env["IWE_SCRIPTS"] = str(configured_scripts)
    hook_env.pop("IWE_FAULT_SUBJECT_KIND", None)
    hook_env.pop("IWE_FAULT_SUBJECT_ID", None)
    accepted = subprocess.run(
        ["bash", str(HOOK)],
        env=hook_env,
        input=json.dumps({"session_id": "issue533internalhook"}),
        capture_output=True,
        text=True,
        check=False,
        timeout=20,
    )
    assert accepted.returncode == 0, accepted.stdout + accepted.stderr
    assert fault in json.loads(accepted.stdout)["hookSpecificOutput"]["additionalContext"]


def test_day_open_reader_uses_canonical_cli_and_explicit_subject(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
):
    workspace, governance_dir = _install_seed(tmp_path)
    env = _platform_env(workspace, governance_dir.name, tmp_path)
    env["IWE_FAULT_SUBJECT_KIND"] = "runtime"
    env["IWE_FAULT_SUBJECT_ID"] = "runtime-day-open"
    for key, value in env.items():
        monkeypatch.setenv(key, value)
    fault = "day-open загрузил профиль из единого CLI"
    for _ in range(3):
        assert _record(env, fault, subject_id="runtime-day-open").returncode == 0

    module_path = ROOT / "scripts" / "day-open-llm-fill.py"
    spec = importlib.util.spec_from_file_location("day_open_llm_fill_issue_533", module_path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)

    assert module.load_fault_profile() == f"🔴 [MAJOR | n=3] {fault}"


@pytest.mark.parametrize(
    "module_path",
    (
        ROOT / "scripts" / "day-open-llm-fill.py",
        SEED / "scripts" / "day-open-llm-fill.py",
    ),
    ids=("platform-root", "governance-seed"),
)
def test_day_open_reader_adapts_valid_pipeline_root_for_custom_workspace(
    tmp_path: Path,
    module_path: Path,
):
    workspace, governance_dir = _install_seed(tmp_path)
    installed_cli = workspace / "FMT-exocortex-template" / CLI_REL
    installed_cli.parent.mkdir(parents=True)
    shutil.copy2(CLI, installed_cli)
    record_env = _platform_env(workspace, governance_dir.name, tmp_path)
    fault = f"{module_path.parent.name} reader принял физический IWE_ROOT"
    for _ in range(3):
        result = _record(record_env, fault, subject_id="runtime-iwe-root")
        assert result.returncode == 0, result.stdout + result.stderr

    reader_env = os.environ.copy()
    reader_env.update(
        {
            "HOME": str(tmp_path / "different-home"),
            "IWE_ROOT": str(workspace),
            "IWE_GOVERNANCE_REPO": governance_dir.name,
            "IWE_FAULT_SUBJECT_KIND": "runtime",
            "IWE_FAULT_SUBJECT_ID": "runtime-iwe-root",
            "PYTHONDONTWRITEBYTECODE": "1",
        }
    )
    for name in ("IWE_WORKSPACE", "WORKSPACE_DIR", "IWE_SCRIPTS"):
        reader_env.pop(name, None)
    probe = subprocess.run(
        [
            sys.executable,
            "-c",
            (
                "import importlib.util, sys; "
                "p=sys.argv[1]; "
                "s=importlib.util.spec_from_file_location('issue533_iwe_root_reader', p); "
                "m=importlib.util.module_from_spec(s); s.loader.exec_module(m); "
                "print(m.load_fault_profile())"
            ),
            str(module_path),
        ],
        env=reader_env,
        capture_output=True,
        text=True,
        check=False,
        timeout=20,
    )

    assert probe.returncode == 0, probe.stdout + probe.stderr
    assert probe.stdout.strip() == f"🔴 [MAJOR | n=3] {fault}"
    assert not (Path(reader_env["HOME"]) / "IWE").exists()
