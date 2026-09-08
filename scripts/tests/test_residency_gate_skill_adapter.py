"""
Тесты residency-gate-skill-adapter.sh (WP-7 ResidencyGate-Event-Adapter, issue #323).

Раньше Point A (проверка согласия при активации функции) была когнитивной:
автор скилла должен был сам вставить `source residency-gate-init.sh` в свой
код — забытая строка означала отсутствие проверки вообще. Этот хук делает то
же самое механически, на событии PreToolUse:Skill, до того как код скилла
вообще запустится.

Прогоняют три shell-адаптера как subprocess и проверяют общий тип исхода:
allowed / policy_denied / manifest_invalid / dependency_error / runtime_error.
Skill-hook получает JSON-payload на stdin (тот же контракт, что и
dry-run-gate.sh: tool_name/tool_input), init source-ится, lazy запускается:
  exit 0 = разрешено (нет data_needs, нет манифеста, или согласие уже дано)
  exit 2 = Skill-hook заблокирован (Claude Code convention для PreToolUse)
  exit 1 = init/lazy fail-closed

Состояние согласия читается из `${IWE_STATE_HOME:-$HOME/.iwe/state}` —
тесты изолируют HOME, IWE_ROOT и IWE_STATE_HOME, чтобы не затронуть реальное
согласие пилота или старый файл миграции.
"""

import importlib.util
import json
import os
import shutil
import stat
import subprocess
from pathlib import Path
from typing import Optional

import pytest

REPO_ROOT = Path(__file__).parent.parent.parent
HOOK = REPO_ROOT / ".claude" / "hooks" / "residency-gate-skill-adapter.sh"
INIT = REPO_ROOT / ".claude" / "hooks" / "residency-gate-init.sh"
LAZY = REPO_ROOT / ".claude" / "hooks" / "residency-gate-lazy.sh"
SKILLS_DIR = REPO_ROOT / ".claude" / "skills"
GATE = SKILLS_DIR / "residency-gate" / "residency-gate.py"
RUNNER = REPO_ROOT / ".claude" / "lib" / "residency-gate-run.sh"
PYTHON_RESOLVER = REPO_ROOT / ".claude" / "lib" / "find-python3.sh"
STATE_MODULE_PATH = SKILLS_DIR / "residency-gate" / "lib" / "state.py"

STATE_SPEC = importlib.util.spec_from_file_location(
    "residency_state_under_test", STATE_MODULE_PATH
)
assert STATE_SPEC is not None and STATE_SPEC.loader is not None
STATE_MODULE = importlib.util.module_from_spec(STATE_SPEC)
STATE_SPEC.loader.exec_module(STATE_MODULE)
ResidencyState = STATE_MODULE.ResidencyState
ResidencyStateError = STATE_MODULE.ResidencyStateError


def _env_with_home(fake_home: Path, resolver: Optional[Path] = None) -> dict:
    """A real hook invocation inherits the caller's full environment (PATH,
    PYTHONPATH, etc.) while state-related paths are isolated explicitly."""
    env = dict(os.environ)
    env.pop("IWE_STATE_HOME", None)
    env["HOME"] = str(fake_home)
    env["IWE_WORKSPACE"] = str(fake_home / "IWE")
    env["IWE_ROOT"] = str(fake_home / "IWE")
    env["CLAUDE_ROOT"] = str(REPO_ROOT)
    if resolver is not None:
        env["IWE_PYTHON_RESOLVER"] = str(resolver)
    return env


def _run_hook(
    skill_name: str,
    fake_home: Path,
    resolver: Optional[Path] = None,
    hook: Path = HOOK,
) -> subprocess.CompletedProcess:
    payload = json.dumps({"tool_name": "Skill", "tool_input": {"skill": skill_name}})
    return subprocess.run(
        ["/bin/bash", str(hook)],
        input=payload,
        capture_output=True,
        text=True,
        timeout=10,
        env=_env_with_home(fake_home, resolver),
    )


def _run_init(
    function_id: str,
    manifest: Path,
    fake_home: Path,
    resolver: Optional[Path] = None,
    project_root: Path = REPO_ROOT,
) -> subprocess.CompletedProcess:
    env = _env_with_home(fake_home, resolver)
    env["CLAUDE_ROOT"] = str(project_root)
    return subprocess.run(
        [
            "bash",
            "-c",
            'source "$1" "$2" "$3"',
            "residency-init-test",
            str(INIT),
            function_id,
            str(manifest),
        ],
        capture_output=True,
        text=True,
        timeout=10,
        env=env,
    )


def _run_lazy(
    function_id: str,
    data_type: str,
    flow: str,
    need_name: str,
    fake_home: Path,
    resolver: Optional[Path] = None,
    project_root: Path = REPO_ROOT,
) -> subprocess.CompletedProcess:
    env = _env_with_home(fake_home, resolver)
    env["CLAUDE_ROOT"] = str(project_root)
    return subprocess.run(
        [str(LAZY), function_id, data_type, flow, need_name],
        capture_output=True,
        text=True,
        timeout=10,
        env=env,
    )


def _run_gate_cli(fake_home: Path, *args: str) -> subprocess.CompletedProcess:
    resolved = subprocess.run(
        [str(PYTHON_RESOLVER)],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    return subprocess.run(
        [resolved, str(GATE), *args],
        env=_env_with_home(fake_home),
        check=True,
        capture_output=True,
        text=True,
    )


def _write_resolver(path: Path, *, python_path: Optional[str] = None) -> Path:
    if python_path is None:
        body = "#!/usr/bin/env bash\necho 'PyYAML intentionally unavailable' >&2\nexit 1\n"
    else:
        body = f"#!/usr/bin/env bash\nprintf '%s\\n' {python_path!r}\n"
    path.write_text(body, encoding="utf-8")
    path.chmod(0o755)
    return path


def _write_manifest(path: Path, *, schema_version: bool = True) -> None:
    schema = ", schema_version: 1" if schema_version else ""
    path.write_text(
        "---\nname: test\n---\n\n"
        "data_needs:\n"
        f"  - type: 2.1, flow: inbound, name: digital-twin{schema}\n",
        encoding="utf-8",
    )


def _write_multiline_manifest(path: Path) -> None:
    path.write_text(
        "---\nname: test\n---\n\n"
        "data_needs:\n"
        "  - type: 2.1\n"
        "    flow: inbound\n"
        "    name: digital-twin\n"
        "    schema_version: 1\n",
        encoding="utf-8",
    )


def _write_bash_manifest(path: Path, *, schema_version: bool = True) -> None:
    schema = "# schema_version: 1\n" if schema_version else ""
    path.write_text(
        "#!/usr/bin/env bash\n"
        "# --- data-needs\n"
        "# type: 2.1, flow: inbound, name: digital-twin\n"
        f"{schema}"
        "# ---\n"
        "exit 0\n",
        encoding="utf-8",
    )


@pytest.fixture
def fake_home(tmp_path):
    home = tmp_path / "home"
    home.mkdir()
    return home


@pytest.fixture
def temp_skill(request):
    """Creates a real (throwaway) skill dir under .claude/skills for the test's
    duration -- the adapter resolves manifests by real path, so a fixture-only
    in-memory manifest cannot exercise it."""
    skill_name = f"pytest-residency-{request.node.name}".replace("[", "-").replace("]", "")
    skill_dir = SKILLS_DIR / skill_name
    yield skill_name, skill_dir
    if skill_dir.exists():
        for f in skill_dir.iterdir():
            f.unlink()
        skill_dir.rmdir()


def test_no_manifest_allows(fake_home, temp_skill):
    """Скилл без SKILL.md вообще (или без файла на диске) — хук не имеет
    мнения, пропускает не вызывая residency-gate.py."""
    skill_name, _ = temp_skill
    result = _run_hook(skill_name, fake_home)
    assert result.returncode == 0, result.stderr


def test_no_data_needs_allows(fake_home, temp_skill):
    """Скилл с SKILL.md, но без блока data_needs — residency-gate.py сам
    возвращает allowed=true, хук пропускает."""
    skill_name, skill_dir = temp_skill
    skill_dir.mkdir(exist_ok=True)
    (skill_dir / "SKILL.md").write_text("---\nname: test\n---\n\nObычный скилл без данных.\n")
    result = _run_hook(skill_name, fake_home)
    assert result.returncode == 0, result.stderr


def test_declared_need_without_consent_blocks(fake_home, temp_skill):
    """Чистая установка (issue #323 acceptance): скилл объявляет data_needs,
    согласия ещё не было — хук блокирует ДО того как код скилла запустится."""
    skill_name, skill_dir = temp_skill
    skill_dir.mkdir(exist_ok=True)
    _write_manifest(skill_dir / "SKILL.md")
    result = _run_hook(skill_name, fake_home)
    assert result.returncode == 2, result.stderr
    assert "BLOCKED" in result.stderr
    assert "[policy_denied]" in result.stderr
    assert "digital-twin" in result.stderr


def test_granted_consent_allows(fake_home, temp_skill):
    """После явного grant тем же CLI, что использует пилот — хук пропускает."""
    skill_name, skill_dir = temp_skill
    skill_dir.mkdir(exist_ok=True)
    manifest = skill_dir / "SKILL.md"
    _write_manifest(manifest)
    _run_gate_cli(fake_home, "grant", skill_name, "2.1", "inbound", "digital-twin")

    results = [
        _run_hook(skill_name, fake_home),
        _run_init(skill_name, manifest, fake_home),
        _run_lazy(skill_name, "2.1", "inbound", "digital-twin", fake_home),
    ]
    assert [result.returncode for result in results] == [0, 0, 0]


def test_denied_consent_blocks(fake_home, temp_skill):
    """Явный отказ пилота — хук продолжает блокировать, не переспрашивает
    молча (Point A не является интерактивным)."""
    skill_name, skill_dir = temp_skill
    skill_dir.mkdir(exist_ok=True)
    (skill_dir / "SKILL.md").write_text(
        "---\nname: test\n---\n\n"
        "data_needs:\n"
        "  - type: 2.2, flow: outbound, name: health-export, schema_version: 1\n"
    )
    _run_gate_cli(
        fake_home,
        "deny",
        skill_name,
        "2.2",
        "outbound",
        "health-export",
        "тестовый отказ",
    )
    result = _run_hook(skill_name, fake_home)
    assert result.returncode == 2, result.stderr
    assert "[policy_denied]" in result.stderr
    assert "health-export" in result.stderr


def test_non_skill_tool_call_ignored(fake_home):
    """Не Skill-вызов (нет .tool_input.skill) — хук выходит немедленно, ничего
    не резолвит и не падает."""
    payload = json.dumps({"tool_name": "Bash", "tool_input": {"command": "ls"}})
    result = subprocess.run(
        ["/bin/bash", str(HOOK)],
        input=payload,
        capture_output=True,
        text=True,
        timeout=10,
        env=_env_with_home(fake_home),
    )
    assert result.returncode == 0, result.stderr


def test_malformed_skill_payload_blocks(fake_home):
    """Повреждённый JSON нельзя превращать в «пустое имя скилла»: проверка
    согласия должна закрыться с типизированной runtime-ошибкой."""
    result = subprocess.run(
        ["/bin/bash", str(HOOK)],
        input='{"tool_name":"Skill","tool_input":',
        capture_output=True,
        text=True,
        timeout=10,
        env=_env_with_home(fake_home),
    )
    assert result.returncode == 2, result.stderr
    assert "[runtime_error]" in result.stderr


def test_missing_tool_name_blocks(fake_home):
    """Matcher=Skill не делает отсутствующий event discriminator безопасным."""
    result = subprocess.run(
        ["/bin/bash", str(HOOK)],
        input=json.dumps({"tool_input": {"skill": "anything"}}),
        capture_output=True,
        text=True,
        timeout=10,
        env=_env_with_home(fake_home),
    )
    assert result.returncode == 2, result.stderr
    assert "[runtime_error]" in result.stderr


def test_missing_jq_blocks_before_skill_parse(fake_home, tmp_path):
    """Отсутствующий JSON-парсер — dependency_error, а не fail-open."""
    minimal_bin = tmp_path / "minimal-bin"
    minimal_bin.mkdir()
    (minimal_bin / "cat").symlink_to(shutil.which("cat"))
    env = _env_with_home(fake_home)
    env["PATH"] = str(minimal_bin)
    result = subprocess.run(
        ["/bin/bash", str(HOOK)],
        input=json.dumps({"tool_name": "Skill", "tool_input": {"skill": "anything"}}),
        capture_output=True,
        text=True,
        timeout=10,
        env=env,
    )
    assert result.returncode == 2, result.stderr
    assert "[dependency_error]" in result.stderr
    assert "jq" in result.stderr


def test_malformed_manifest_fails_closed(fake_home, temp_skill):
    """Битая декларация (нет schema_version) — residency-gate.py сам
    fail-closed (ManifestError); хук отражает это блокировкой, не тихим
    пропуском."""
    skill_name, skill_dir = temp_skill
    skill_dir.mkdir(exist_ok=True)
    manifest = skill_dir / "SKILL.md"
    _write_manifest(manifest, schema_version=False)
    results = [
        _run_hook(skill_name, fake_home),
        _run_init(skill_name, manifest, fake_home),
    ]
    assert [result.returncode for result in results] == [2, 1]
    assert all("manifest_invalid" in result.stderr for result in results)


def test_missing_flow_manifest_fails_closed(fake_home, temp_skill):
    skill_name, skill_dir = temp_skill
    skill_dir.mkdir(exist_ok=True)
    manifest = skill_dir / "SKILL.md"
    manifest.write_text(
        "data_needs:\n"
        "  - type: 2.1, name: digital-twin, schema_version: 1\n",
        encoding="utf-8",
    )
    results = [
        _run_hook(skill_name, fake_home),
        _run_init(skill_name, manifest, fake_home),
    ]
    assert [result.returncode for result in results] == [2, 1]
    assert all("manifest_invalid" in result.stderr for result in results)


def test_empty_declared_comment_block_fails_closed(fake_home, temp_skill):
    skill_name, skill_dir = temp_skill
    skill_dir.mkdir(exist_ok=True)
    manifest = skill_dir / "SKILL.md"
    manifest.write_text(
        "```bash\n"
        "# --- data-needs\n"
        "# schema_version: 1\n"
        "# ---\n"
        "```\n",
        encoding="utf-8",
    )
    results = [
        _run_hook(skill_name, fake_home),
        _run_init(skill_name, manifest, fake_home),
    ]
    assert [result.returncode for result in results] == [2, 1]
    assert all("manifest_invalid" in result.stderr for result in results)


def test_unbalanced_comment_marker_fails_closed(fake_home, temp_skill):
    skill_name, skill_dir = temp_skill
    skill_dir.mkdir(exist_ok=True)
    manifest = skill_dir / "SKILL.md"
    manifest.write_text(
        "```bash\n"
        "# --- data-needs\n"
        "# type: 2.1, flow_direction: inbound, name: profile, schema_version: 1\n",
        encoding="utf-8",
    )
    results = [
        _run_hook(skill_name, fake_home),
        _run_init(skill_name, manifest, fake_home),
    ]
    assert [result.returncode for result in results] == [2, 1]
    assert all("manifest_invalid" in result.stderr for result in results)


def test_multiline_manifest_without_consent_blocks(fake_home, temp_skill):
    skill_name, skill_dir = temp_skill
    skill_dir.mkdir(exist_ok=True)
    manifest = skill_dir / "SKILL.md"
    _write_multiline_manifest(manifest)
    results = [
        _run_hook(skill_name, fake_home),
        _run_init(skill_name, manifest, fake_home),
    ]
    assert [result.returncode for result in results] == [2, 1]
    assert all("policy_denied" in result.stderr for result in results)


def test_raw_bash_manifest_blocks_then_allows_after_grant(fake_home, tmp_path):
    function_id = "raw-bash-function"
    manifest = tmp_path / "raw-manifest.sh"
    _write_bash_manifest(manifest)

    blocked = _run_init(function_id, manifest, fake_home)
    assert blocked.returncode == 1, blocked.stderr
    assert "policy_denied" in blocked.stderr

    _run_gate_cli(
        fake_home,
        "grant",
        function_id,
        "2.1",
        "inbound",
        "digital-twin",
    )
    allowed = _run_init(function_id, manifest, fake_home)
    assert allowed.returncode == 0, allowed.stderr


def test_malformed_raw_bash_manifest_fails_closed(fake_home, tmp_path):
    manifest = tmp_path / "malformed-raw-manifest.sh"
    _write_bash_manifest(manifest, schema_version=False)

    result = _run_init("malformed-raw-bash", manifest, fake_home)
    assert result.returncode == 1, result.stderr
    assert "manifest_invalid" in result.stderr


@pytest.mark.parametrize(
    "state_content",
    [
        "functions: [not-a-mapping\n",
        (
            "functions:\n"
            "  corrupted-status-skill:\n"
            "    2.1_inbound_digital-twin:\n"
            "      status: pending\n"
        ),
    ],
)
def test_corrupt_or_unknown_state_fails_runtime_and_preserves_bytes(
    fake_home, temp_skill, state_content
):
    skill_name, skill_dir = temp_skill
    skill_dir.mkdir(exist_ok=True)
    manifest = skill_dir / "SKILL.md"
    _write_manifest(manifest)
    state_file = fake_home / ".iwe" / "state" / "data-residency.yaml"
    state_file.parent.mkdir(parents=True)
    content = state_content.replace("corrupted-status-skill", skill_name)
    state_file.write_text(content, encoding="utf-8")
    before = state_file.read_bytes()

    results = [
        _run_hook(skill_name, fake_home),
        _run_init(skill_name, manifest, fake_home),
    ]

    assert [result.returncode for result in results] == [2, 1]
    assert all("runtime_error" in result.stderr for result in results)
    assert state_file.read_bytes() == before


def _configure_state_paths(monkeypatch, home: Path) -> tuple[Path, Path]:
    """Point default and legacy storage at one isolated test home."""
    state_home = home / ".iwe" / "state"
    legacy = home / "IWE" / "current" / "data-residency.yaml"
    home.mkdir(parents=True, exist_ok=True)
    monkeypatch.setenv("HOME", str(home))
    monkeypatch.setenv("IWE_WORKSPACE", str(home / "IWE"))
    monkeypatch.setenv("IWE_ROOT", str(home / "IWE"))
    monkeypatch.delenv("IWE_STATE_HOME", raising=False)
    return state_home, legacy


def _consent_document(status: str = "granted") -> bytes:
    return (
        "functions:\n"
        "  migration-test:\n"
        "    2.1_inbound_profile:\n"
        f"      status: {status}\n"
    ).encode("utf-8")


def test_default_state_home_is_local_private_and_outside_iwe(monkeypatch, tmp_path):
    home = tmp_path / "fresh-home"
    state_home, legacy = _configure_state_paths(monkeypatch, home)

    state = ResidencyState()

    target = state_home / "data-residency.yaml"
    assert state.state_file == target
    assert target.is_file()
    assert not legacy.parent.exists()
    assert stat.S_IMODE(state_home.stat().st_mode) == 0o700
    assert stat.S_IMODE(target.stat().st_mode) == 0o600
    assert stat.S_IMODE((state_home / ".data-residency.lock").stat().st_mode) == 0o600


def test_default_state_container_symlink_is_rejected(monkeypatch, tmp_path):
    home = tmp_path / "symlinked-default-container-home"
    state_home, _ = _configure_state_paths(monkeypatch, home)
    outside = tmp_path / "outside-default-container"
    outside.mkdir()
    (home / ".iwe").symlink_to(outside, target_is_directory=True)

    with pytest.raises(
        ResidencyStateError,
        match="default residency state container must not be a symlink",
    ):
        ResidencyState()

    assert not (outside / "state").exists()
    assert not state_home.exists()


@pytest.mark.parametrize("creation_mask", [0o000, 0o777])
def test_default_private_tree_is_umask_independent(
    monkeypatch, tmp_path, creation_mask
):
    home = tmp_path / f"umask-{creation_mask:o}-home"
    state_home, _ = _configure_state_paths(monkeypatch, home)

    previous_mask = os.umask(creation_mask)
    try:
        state = ResidencyState()
        state.grant_consent("umask-test", "2.1_inbound_profile")
    finally:
        os.umask(previous_mask)

    assert stat.S_IMODE((home / ".iwe").stat().st_mode) == 0o700
    assert stat.S_IMODE(state_home.stat().st_mode) == 0o700
    assert stat.S_IMODE(state.state_file.stat().st_mode) == 0o600
    assert stat.S_IMODE(state.lock_file.stat().st_mode) == 0o600


def test_existing_default_private_tree_permissions_are_repaired(
    monkeypatch, tmp_path
):
    home = tmp_path / "repair-private-tree-home"
    state_home, _ = _configure_state_paths(monkeypatch, home)
    state_home.mkdir(parents=True)
    (home / ".iwe").chmod(0o777)
    state_home.chmod(0o777)
    target = state_home / ResidencyState.STATE_FILE_NAME
    target.write_bytes(_consent_document())
    target.chmod(0o666)
    lock = state_home / ResidencyState.LOCK_FILE_NAME
    lock.write_bytes(b"")
    lock.chmod(0o666)

    state = ResidencyState()

    assert stat.S_IMODE((home / ".iwe").stat().st_mode) == 0o700
    assert stat.S_IMODE(state_home.stat().st_mode) == 0o700
    assert stat.S_IMODE(state.state_file.stat().st_mode) == 0o600
    assert stat.S_IMODE(state.lock_file.stat().st_mode) == 0o600


def test_state_home_override_wins_and_legacy_root_is_independent(
    monkeypatch, tmp_path
):
    home = tmp_path / "override-home"
    _configure_state_paths(monkeypatch, home)
    custom_state_home = tmp_path / "private-consent"
    custom_legacy_root = tmp_path / "legacy-workspace"
    monkeypatch.setenv("IWE_STATE_HOME", str(custom_state_home))
    monkeypatch.setenv("IWE_WORKSPACE", str(custom_legacy_root))
    monkeypatch.setenv("IWE_ROOT", str(tmp_path / "decoy-iwe-root"))

    state = ResidencyState()

    assert state.state_file == custom_state_home / "data-residency.yaml"
    assert state.state_file.is_file()
    assert not (home / ".iwe" / "state").exists()


def test_official_iwe_workspace_locates_legacy_outside_default_home(
    monkeypatch, tmp_path
):
    home = tmp_path / "separate-home"
    state_home, _ = _configure_state_paths(monkeypatch, home)
    workspace = tmp_path / "arbitrary-workspace"
    legacy = workspace / "current" / "data-residency.yaml"
    legacy.parent.mkdir(parents=True)
    legacy_content = _consent_document("denied")
    legacy.write_bytes(legacy_content)
    monkeypatch.setenv("IWE_WORKSPACE", str(workspace))
    monkeypatch.setenv("IWE_ROOT", str(tmp_path / "unused-iwe-root"))

    state = ResidencyState()

    assert state.state_file == state_home / "data-residency.yaml"
    assert state.state_file.read_bytes() == legacy_content
    assert not legacy.exists()


def test_legacy_state_migrates_exactly_once_with_recovery_snapshot(
    monkeypatch, tmp_path
):
    home = tmp_path / "migration-home"
    state_home, legacy = _configure_state_paths(monkeypatch, home)
    legacy.parent.mkdir(parents=True)
    legacy_content = _consent_document("denied")
    legacy.write_bytes(legacy_content)

    first = ResidencyState()
    target = state_home / "data-residency.yaml"
    backup = state_home / "migration-backups" / "data-residency.yaml.legacy"

    assert first.get_consent("migration-test", "2.1_inbound_profile")["status"] == "denied"
    assert target.read_bytes() == legacy_content
    assert backup.read_bytes() == legacy_content
    assert not legacy.exists()
    assert stat.S_IMODE(target.stat().st_mode) == 0o600
    assert stat.S_IMODE(backup.stat().st_mode) == 0o600
    target_before = target.read_bytes()
    backup_before = backup.read_bytes()

    second = ResidencyState()

    assert second.list_all_consents() == first.list_all_consents()
    assert target.read_bytes() == target_before
    assert backup.read_bytes() == backup_before


def test_interrupted_quarantine_migration_resumes_idempotently(
    monkeypatch, tmp_path
):
    home = tmp_path / "quarantine-resume-home"
    state_home, legacy = _configure_state_paths(monkeypatch, home)
    state_home.mkdir(parents=True)
    legacy.parent.mkdir(parents=True)
    content = _consent_document("granted")
    target = state_home / "data-residency.yaml"
    target.write_bytes(content)
    quarantine = state_home / ResidencyState.LEGACY_QUARANTINE_NAME
    quarantine.write_bytes(content)

    state = ResidencyState()

    assert state.list_all_consents()["migration-test"]["2.1_inbound_profile"]["status"] == "granted"
    assert not quarantine.exists()
    backup = state_home / "migration-backups" / "data-residency.yaml.legacy"
    assert backup.read_bytes() == content


def test_equal_legacy_and_local_state_retire_legacy_without_rewriting_target(
    monkeypatch, tmp_path
):
    home = tmp_path / "equal-home"
    state_home, legacy = _configure_state_paths(monkeypatch, home)
    state_home.mkdir(parents=True)
    legacy.parent.mkdir(parents=True)
    legacy_content = _consent_document("granted")
    target_content = (
        "# Same YAML, deliberately formatted differently\n"
        "functions: {migration-test: {2.1_inbound_profile: {status: granted}}}\n"
    ).encode("utf-8")
    target = state_home / "data-residency.yaml"
    target.write_bytes(target_content)
    legacy.write_bytes(legacy_content)

    ResidencyState()

    assert target.read_bytes() == target_content
    assert not legacy.exists()
    backup = state_home / "migration-backups" / "data-residency.yaml.legacy"
    assert backup.read_bytes() == legacy_content


def test_long_lived_reader_fails_closed_when_legacy_is_recreated(
    monkeypatch, tmp_path
):
    home = tmp_path / "late-legacy-home"
    state_home, legacy = _configure_state_paths(monkeypatch, home)
    legacy.parent.mkdir(parents=True)
    granted = _consent_document("granted")
    denied = _consent_document("denied")
    legacy.write_bytes(granted)
    state = ResidencyState()
    backup = state_home / "migration-backups" / "data-residency.yaml.legacy"

    legacy.write_bytes(denied)
    with pytest.raises(ResidencyStateError, match="refusing automatic merge"):
        state.get_consent("migration-test", "2.1_inbound_profile")

    assert state.state_file.read_bytes() == granted
    assert legacy.read_bytes() == denied
    assert backup.read_bytes() == granted


def test_long_lived_reader_retires_equal_recreated_legacy(monkeypatch, tmp_path):
    home = tmp_path / "late-equal-legacy-home"
    state_home, legacy = _configure_state_paths(monkeypatch, home)
    legacy.parent.mkdir(parents=True)
    content = _consent_document("granted")
    legacy.write_bytes(content)
    state = ResidencyState()
    target_before = state.state_file.read_bytes()
    backup = state_home / "migration-backups" / "data-residency.yaml.legacy"
    backup_before = backup.read_bytes()

    legacy.write_bytes(content)
    assert state.get_consent("migration-test", "2.1_inbound_profile")["status"] == "granted"

    assert not legacy.exists()
    assert state.state_file.read_bytes() == target_before
    assert backup.read_bytes() == backup_before


def test_conflicting_legacy_and_local_state_stop_without_merge(
    monkeypatch, tmp_path
):
    home = tmp_path / "conflict-home"
    state_home, legacy = _configure_state_paths(monkeypatch, home)
    state_home.mkdir(parents=True)
    legacy.parent.mkdir(parents=True)
    target = state_home / "data-residency.yaml"
    target_content = _consent_document("granted")
    legacy_content = _consent_document("denied")
    target.write_bytes(target_content)
    legacy.write_bytes(legacy_content)

    with pytest.raises(ResidencyStateError, match="refusing automatic merge"):
        ResidencyState()

    assert target.read_bytes() == target_content
    assert legacy.read_bytes() == legacy_content
    assert not (state_home / "migration-backups").exists()


@pytest.mark.parametrize("corrupt", [b"functions: [broken\n", b"functions: []\n"])
def test_corrupt_legacy_stops_before_target_or_backup(
    monkeypatch, tmp_path, corrupt
):
    home = tmp_path / "corrupt-legacy-home"
    state_home, legacy = _configure_state_paths(monkeypatch, home)
    legacy.parent.mkdir(parents=True)
    legacy.write_bytes(corrupt)

    with pytest.raises(ResidencyStateError):
        ResidencyState()

    assert legacy.read_bytes() == corrupt
    assert not (state_home / "data-residency.yaml").exists()
    assert not (state_home / "migration-backups").exists()


def test_backup_conflict_stops_before_target_creation(monkeypatch, tmp_path):
    home = tmp_path / "backup-conflict-home"
    state_home, legacy = _configure_state_paths(monkeypatch, home)
    legacy.parent.mkdir(parents=True)
    legacy_content = _consent_document("granted")
    legacy.write_bytes(legacy_content)
    backup = state_home / "migration-backups" / "data-residency.yaml.legacy"
    backup.parent.mkdir(parents=True)
    backup_content = _consent_document("denied")
    backup.write_bytes(backup_content)

    with pytest.raises(ResidencyStateError, match="backup conflicts"):
        ResidencyState()

    assert legacy.read_bytes() == legacy_content
    assert backup.read_bytes() == backup_content
    assert not (state_home / "data-residency.yaml").exists()


def test_relative_state_home_and_symlink_target_fail_closed(monkeypatch, tmp_path):
    home = tmp_path / "unsafe-home"
    state_home, _ = _configure_state_paths(monkeypatch, home)
    monkeypatch.setenv("IWE_STATE_HOME", "relative-state")
    with pytest.raises(ResidencyStateError, match="absolute path"):
        ResidencyState()

    monkeypatch.setenv("IWE_STATE_HOME", str(state_home))
    state_home.mkdir(parents=True)
    outside = tmp_path / "outside-state.yaml"
    outside.write_bytes(_consent_document())
    (state_home / "data-residency.yaml").symlink_to(outside)
    with pytest.raises(ResidencyStateError, match="must not be a symlink"):
        ResidencyState()
    assert outside.read_bytes() == _consent_document()


def test_state_home_parent_symlink_cannot_alias_legacy_workspace(
    monkeypatch, tmp_path
):
    home = tmp_path / "alias-home"
    _configure_state_paths(monkeypatch, home)
    workspace = tmp_path / "real-workspace"
    legacy = workspace / "current" / "data-residency.yaml"
    legacy.parent.mkdir(parents=True)
    content = _consent_document("granted")
    legacy.write_bytes(content)
    alias = tmp_path / "workspace-alias"
    alias.symlink_to(workspace, target_is_directory=True)
    monkeypatch.setenv("IWE_WORKSPACE", str(workspace))
    monkeypatch.setenv("IWE_STATE_HOME", str(alias / "current"))

    with pytest.raises(ResidencyStateError, match="symlink component|outside"):
        ResidencyState()

    assert legacy.read_bytes() == content


def test_legacy_current_symlink_cannot_escape_workspace(monkeypatch, tmp_path):
    home = tmp_path / "legacy-current-alias-home"
    state_home, _ = _configure_state_paths(monkeypatch, home)
    workspace = home / "IWE"
    outside = tmp_path / "outside-legacy"
    outside.mkdir(parents=True)
    outside_state = outside / "data-residency.yaml"
    content = _consent_document("denied")
    outside_state.write_bytes(content)
    workspace.mkdir(parents=True)
    (workspace / "current").symlink_to(outside, target_is_directory=True)

    with pytest.raises(ResidencyStateError, match="real directory inside"):
        ResidencyState()

    assert outside_state.read_bytes() == content
    assert not (state_home / "data-residency.yaml").exists()
    assert not (state_home / "migration-backups").exists()
    assert not (state_home / ResidencyState.LEGACY_QUARANTINE_NAME).exists()


def test_symlinked_iwe_workspace_root_is_normalized(monkeypatch, tmp_path):
    home = tmp_path / "workspace-root-alias-home"
    state_home, _ = _configure_state_paths(monkeypatch, home)
    real_workspace = tmp_path / "real-legacy-workspace"
    legacy = real_workspace / "current" / "data-residency.yaml"
    legacy.parent.mkdir(parents=True)
    content = _consent_document("denied")
    legacy.write_bytes(content)
    alias = tmp_path / "legacy-workspace-alias"
    alias.symlink_to(real_workspace, target_is_directory=True)
    monkeypatch.setenv("IWE_WORKSPACE", str(alias))

    state = ResidencyState()

    assert state.state_file == state_home / "data-residency.yaml"
    assert state.state_file.read_bytes() == content
    assert not legacy.exists()


def test_long_lived_reader_rejects_replaced_workspace_root(monkeypatch, tmp_path):
    home = tmp_path / "replaced-workspace-root-home"
    state_home, _ = _configure_state_paths(monkeypatch, home)
    state = ResidencyState()
    workspace = home / "IWE"
    outside = tmp_path / "replacement-outside-workspace"
    outside_legacy = outside / "current" / "data-residency.yaml"
    outside_legacy.parent.mkdir(parents=True)
    content = _consent_document("denied")
    outside_legacy.write_bytes(content)
    workspace.symlink_to(outside, target_is_directory=True)

    with pytest.raises(ResidencyStateError, match="cannot open IWE workspace"):
        state.get_consent("migration-test", "2.1_inbound_profile")

    assert outside_legacy.read_bytes() == content
    assert state.state_file == state_home / "data-residency.yaml"
    assert not (state_home / "migration-backups").exists()


def test_long_lived_state_rejects_state_directory_symlink_swap(
    monkeypatch, tmp_path
):
    home = tmp_path / "replaced-state-directory-home"
    state_home, _ = _configure_state_paths(monkeypatch, home)
    state = ResidencyState()
    original_state = state.state_file.read_bytes()
    saved_state_home = state_home.with_name("saved-state")
    state_home.rename(saved_state_home)

    outside = tmp_path / "replacement-outside-state"
    outside.mkdir()
    outside_state = outside / ResidencyState.STATE_FILE_NAME
    outside_state.write_bytes(_consent_document("denied"))
    outside_before = outside_state.read_bytes()
    state_home.symlink_to(outside, target_is_directory=True)

    with pytest.raises(ResidencyStateError, match="directory must not be a symlink"):
        state.grant_consent("migration-test", "2.1_inbound_profile")

    assert outside_state.read_bytes() == outside_before
    saved_state = saved_state_home / ResidencyState.STATE_FILE_NAME
    assert saved_state.read_bytes() == original_state


def test_hardlinked_state_is_rejected_without_touching_peer(monkeypatch, tmp_path):
    home = tmp_path / "hardlinked-state-home"
    state_home, _ = _configure_state_paths(monkeypatch, home)
    state_home.mkdir(parents=True)
    peer = tmp_path / "state-peer.yaml"
    content = _consent_document("granted")
    peer.write_bytes(content)
    target = state_home / "data-residency.yaml"
    os.link(peer, target)
    mode_before = stat.S_IMODE(peer.stat().st_mode)

    with pytest.raises(ResidencyStateError, match="exactly one hard link"):
        ResidencyState()

    assert peer.read_bytes() == content
    assert target.samefile(peer)
    assert peer.stat().st_nlink == 2
    assert stat.S_IMODE(peer.stat().st_mode) == mode_before


def test_hardlinked_lock_is_rejected_before_fchmod(monkeypatch, tmp_path):
    home = tmp_path / "hardlinked-lock-home"
    state_home, _ = _configure_state_paths(monkeypatch, home)
    state_home.mkdir(parents=True)
    peer = tmp_path / "lock-peer"
    peer.write_bytes(b"do-not-touch")
    peer.chmod(0o644)
    os.link(peer, state_home / ".data-residency.lock")

    with pytest.raises(ResidencyStateError, match="lock must have exactly one hard link"):
        ResidencyState()

    assert peer.read_bytes() == b"do-not-touch"
    assert stat.S_IMODE(peer.stat().st_mode) == 0o644
    assert peer.stat().st_nlink == 2


@pytest.mark.parametrize("artifact", ["legacy", "backup"])
def test_hardlinked_migration_artifact_is_rejected_without_retirement(
    monkeypatch, tmp_path, artifact
):
    home = tmp_path / f"hardlinked-{artifact}-home"
    state_home, legacy = _configure_state_paths(monkeypatch, home)
    legacy.parent.mkdir(parents=True)
    content = _consent_document("granted")
    peer = tmp_path / f"{artifact}-peer.yaml"
    peer.write_bytes(content)
    if artifact == "legacy":
        os.link(peer, legacy)
    else:
        legacy.write_bytes(content)
        backup = state_home / "migration-backups" / "data-residency.yaml.legacy"
        backup.parent.mkdir(parents=True)
        os.link(peer, backup)

    with pytest.raises(ResidencyStateError, match="exactly one hard link"):
        ResidencyState()

    assert peer.read_bytes() == content
    assert peer.stat().st_nlink == 2
    assert legacy.exists()
    assert not (state_home / "data-residency.yaml").exists()


def test_failed_post_rename_validation_keeps_quarantine_outside_workspace(
    monkeypatch, tmp_path
):
    home = tmp_path / "external-quarantine-home"
    state_home, legacy = _configure_state_paths(monkeypatch, home)
    legacy.parent.mkdir(parents=True)
    content = _consent_document("granted")
    legacy.write_bytes(content)
    original_reader = ResidencyState._read_migration_candidate

    def fail_on_quarantine(self, path):
        if path.name == self.LEGACY_QUARANTINE_NAME:
            raise ResidencyStateError("injected post-rename failure")
        return original_reader(self, path)

    monkeypatch.setattr(ResidencyState, "_read_migration_candidate", fail_on_quarantine)
    with pytest.raises(ResidencyStateError, match="injected post-rename failure"):
        ResidencyState()

    quarantine = state_home / ResidencyState.LEGACY_QUARANTINE_NAME
    assert quarantine.read_bytes() == content
    assert not legacy.exists()
    assert not (legacy.parent / ResidencyState.LEGACY_QUARANTINE_NAME).exists()
    assert (state_home / "data-residency.yaml").read_bytes() == content
    assert (state_home / "migration-backups" / "data-residency.yaml.legacy").read_bytes() == content


def test_migration_fsyncs_destination_before_source_after_rename(
    monkeypatch, tmp_path
):
    home = tmp_path / "fsync-order-home"
    state_home, legacy = _configure_state_paths(monkeypatch, home)
    legacy.parent.mkdir(parents=True)
    legacy.write_bytes(_consent_document("granted"))
    original_rename = os.rename
    original_fsync = ResidencyState._fsync_descriptor
    renamed = False
    post_rename_labels = []

    def observed_rename(*args, **kwargs):
        nonlocal renamed
        result = original_rename(*args, **kwargs)
        renamed = True
        return result

    def observed_fsync(descriptor, label):
        if renamed:
            post_rename_labels.append(Path(label))
        return original_fsync(descriptor, label)

    monkeypatch.setattr(os, "rename", observed_rename)
    monkeypatch.setattr(ResidencyState, "_fsync_descriptor", staticmethod(observed_fsync))

    ResidencyState()

    assert post_rename_labels[:2] == [state_home, legacy.parent]


def test_destination_fsync_failure_preserves_external_recovery_copy(
    monkeypatch, tmp_path
):
    home = tmp_path / "destination-fsync-failure-home"
    state_home, legacy = _configure_state_paths(monkeypatch, home)
    legacy.parent.mkdir(parents=True)
    content = _consent_document("granted")
    legacy.write_bytes(content)
    original_rename = os.rename
    original_fsync = ResidencyState._fsync_descriptor
    renamed = False

    def observed_rename(*args, **kwargs):
        nonlocal renamed
        result = original_rename(*args, **kwargs)
        renamed = True
        return result

    def fail_destination_after_rename(descriptor, label):
        if renamed and Path(label) == state_home:
            raise ResidencyStateError("injected destination fsync failure")
        return original_fsync(descriptor, label)

    monkeypatch.setattr(os, "rename", observed_rename)
    monkeypatch.setattr(
        ResidencyState,
        "_fsync_descriptor",
        staticmethod(fail_destination_after_rename),
    )

    with pytest.raises(ResidencyStateError, match="destination fsync failure"):
        ResidencyState()

    quarantine = state_home / ResidencyState.LEGACY_QUARANTINE_NAME
    assert not legacy.exists()
    assert quarantine.read_bytes() == content
    assert (state_home / "data-residency.yaml").read_bytes() == content
    assert (state_home / "migration-backups" / "data-residency.yaml.legacy").read_bytes() == content


def test_old_writer_reappearance_preserves_both_versions(
    monkeypatch, tmp_path
):
    home = tmp_path / "old-writer-race-home"
    state_home, legacy = _configure_state_paths(monkeypatch, home)
    legacy.parent.mkdir(parents=True)
    original_content = _consent_document("granted")
    concurrent_content = _consent_document("denied")
    legacy.write_bytes(original_content)
    original_reader = ResidencyState._read_migration_candidate
    injected = False

    def read_and_inject(self, path):
        nonlocal injected
        content = original_reader(self, path)
        if path.name == self.LEGACY_QUARANTINE_NAME and not injected:
            legacy.write_bytes(concurrent_content)
            injected = True
        return content

    monkeypatch.setattr(ResidencyState, "_read_migration_candidate", read_and_inject)
    with pytest.raises(ResidencyStateError, match="old-version writer recreated"):
        ResidencyState()

    target = state_home / "data-residency.yaml"
    quarantine = state_home / ResidencyState.LEGACY_QUARANTINE_NAME
    assert target.read_bytes() == original_content
    assert quarantine.read_bytes() == original_content
    assert legacy.read_bytes() == concurrent_content


def test_parallel_grants_are_serialized_without_lost_updates(fake_home):
    resolved = subprocess.run(
        [str(PYTHON_RESOLVER)],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()
    processes = [
        subprocess.Popen(
            [
                resolved,
                str(GATE),
                "grant",
                f"parallel-{index}",
                "2.1",
                "inbound",
                "profile",
            ],
            env=_env_with_home(fake_home),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        for index in range(12)
    ]
    results = [process.communicate(timeout=15) + (process.returncode,) for process in processes]
    assert all(returncode == 0 for _, _, returncode in results), results

    listed = _run_gate_cli(fake_home, "list")
    records = json.loads(listed.stdout)
    assert sorted(records) == sorted(f"parallel-{index}" for index in range(12))


def test_explicit_state_path_never_reads_or_retires_legacy(monkeypatch, tmp_path):
    home = tmp_path / "explicit-home"
    _, legacy = _configure_state_paths(monkeypatch, home)
    legacy.parent.mkdir(parents=True)
    corrupt = b"functions: [broken\n"
    legacy.write_bytes(corrupt)
    explicit = tmp_path / "embedded-state" / "data-residency.yaml"

    state = ResidencyState(str(explicit))

    assert state.list_all_consents() == {}
    assert explicit.is_file()
    assert legacy.read_bytes() == corrupt


def test_policy_denied_outcome_has_adapter_parity(fake_home, temp_skill):
    """The three adapters expose one policy type while keeping host exit codes."""
    skill_name, skill_dir = temp_skill
    skill_dir.mkdir(exist_ok=True)
    manifest = skill_dir / "SKILL.md"
    _write_manifest(manifest)

    results = [
        _run_hook(skill_name, fake_home),
        _run_init(skill_name, manifest, fake_home),
        _run_lazy(skill_name, "2.1", "inbound", "digital-twin", fake_home),
    ]

    assert [result.returncode for result in results] == [2, 1, 1]
    assert all("policy_denied" in result.stderr for result in results)
    assert all("dependency_error" not in result.stderr for result in results)


def test_missing_pyyaml_is_dependency_error_for_all_adapters(
    tmp_path, fake_home, temp_skill
):
    """A failed shared resolver is never mislabeled as missing consent."""
    resolver = _write_resolver(tmp_path / "resolver-without-pyyaml.sh")
    skill_name, skill_dir = temp_skill
    skill_dir.mkdir(exist_ok=True)
    manifest = skill_dir / "SKILL.md"
    _write_manifest(manifest)

    results = [
        _run_hook(skill_name, fake_home, resolver),
        _run_init(skill_name, manifest, fake_home, resolver),
        _run_lazy(
            skill_name,
            "2.1",
            "inbound",
            "digital-twin",
            fake_home,
            resolver,
        ),
    ]

    assert [result.returncode for result in results] == [2, 1, 1]
    assert all("dependency_error" in result.stderr for result in results)
    assert all("policy_denied" not in result.stderr for result in results)
    assert "requires data consent" not in results[0].stderr
    assert all("PyYAML intentionally unavailable" in result.stderr for result in results)


def test_missing_gate_implementation_blocks_declared_skill(tmp_path, fake_home):
    """A declared need cannot silently bypass a missing protective gate."""
    project_root = tmp_path / "project-without-residency-gate"
    skill_name = "needs-missing-gate"
    skill_dir = project_root / ".claude" / "skills" / skill_name
    skill_dir.mkdir(parents=True)
    _write_manifest(skill_dir / "SKILL.md")
    hook = project_root / ".claude" / "hooks" / HOOK.name
    hook.parent.mkdir(parents=True)
    shutil.copy2(HOOK, hook)
    for source in (RUNNER, PYTHON_RESOLVER):
        target = project_root / ".claude" / "lib" / source.name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)

    results = [
        _run_hook(skill_name, fake_home, hook=hook),
        _run_init(skill_name, skill_dir / "SKILL.md", fake_home, project_root=project_root),
        _run_lazy(
            skill_name,
            "2.1",
            "inbound",
            "digital-twin",
            fake_home,
            project_root=project_root,
        ),
    ]

    assert [result.returncode for result in results] == [2, 1, 1]
    assert all("dependency_error" in result.stderr for result in results)
    assert all("missing" in result.stderr for result in results)
    assert all("policy_denied" not in result.stderr for result in results)


def test_untyped_python_failure_is_runtime_error_for_all_adapters(
    tmp_path, fake_home, temp_skill
):
    """A subprocess crash cannot fall through to the policy-denial message."""
    fake_python = tmp_path / "python-crashes-before-json.sh"
    fake_python.write_text(
        "#!/usr/bin/env bash\necho 'simulated interpreter crash' >&2\nexit 7\n",
        encoding="utf-8",
    )
    fake_python.chmod(0o755)
    resolver = _write_resolver(
        tmp_path / "resolver-to-crashing-python.sh",
        python_path=str(fake_python),
    )
    skill_name, skill_dir = temp_skill
    skill_dir.mkdir(exist_ok=True)
    manifest = skill_dir / "SKILL.md"
    _write_manifest(manifest)

    results = [
        _run_hook(skill_name, fake_home, resolver),
        _run_init(skill_name, manifest, fake_home, resolver),
        _run_lazy(
            skill_name,
            "2.1",
            "inbound",
            "digital-twin",
            fake_home,
            resolver,
        ),
    ]

    assert [result.returncode for result in results] == [2, 1, 1]
    assert all("runtime_error" in result.stderr for result in results)
    assert all("policy_denied" not in result.stderr for result in results)
    assert all("simulated interpreter crash" in result.stderr for result in results)
