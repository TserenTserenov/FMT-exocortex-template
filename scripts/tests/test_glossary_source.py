"""Tests for scripts/glossary_source.py (WP-617 Ф3): graph snapshot + local queue."""

from __future__ import annotations

import ast
import csv
import re
import sys
from pathlib import Path

import pytest
import yaml

SCRIPTS = Path(__file__).parent.parent
REPO = SCRIPTS.parent
sys.path.insert(0, str(SCRIPTS))

from glossary_source import GlossaryError, load_glossary  # noqa: E402

SNAPSHOT_HEADER = "code,term_ru,term_en,level,domain,name_en_status_raw,rules_version\n"
LOCAL_HEADER = "term_ru,term_en,context,notes,tier\n"
TIERS = {"zp": 1, "fpf": 1, "pack": 2}


def _load(tmp_path: Path, snapshot_rows: list[str], local_rows: list[str], tiers=TIERS):
    (tmp_path / "snap.csv").write_text(SNAPSHOT_HEADER + "".join(snapshot_rows), encoding="utf-8")
    (tmp_path / "local.csv").write_text(LOCAL_HEADER + "".join(local_rows), encoding="utf-8")
    manifest = {"glossary": {"snapshot": "snap.csv", "local": "local.csv", "tier_by_level": tiers}}
    return load_glossary(manifest, tmp_path)


def _by_ru(glossary):
    return {t.term_ru: t for t in glossary.terms}


def test_graph_and_local_terms_are_merged_with_tiers(tmp_path):
    g = _load(
        tmp_path,
        ["ZP.1,Аксиоматичность,Axiomaticity,zp,ZP,ok,r/1\n", "DP.X.1,Практика,Practice,pack,DP,ok,r/1\n"],
        ["Пак,Pack,,,1\n", "Скилл,Skill,,,\n"],
    )
    terms = _by_ru(g)
    assert (terms["Аксиоматичность"].term_en, terms["Аксиоматичность"].tier) == ("Axiomaticity", 1)
    assert (terms["Практика"].term_en, terms["Практика"].tier) == ("Practice", 2)
    assert (terms["Пак"].term_en, terms["Пак"].tier) == ("Pack", 1)
    assert terms["Скилл"].tier == 3  # blank local tier keeps the old delivery_checks default
    assert g.as_mapping()["Практика"] == "Practice"


def test_snapshot_rows_without_cyrillic_are_skipped_and_counted(tmp_path):
    g = _load(tmp_path, ["DP.A.1,AIST Bot,AIST Bot,pack,DP,ok,r/1\n", "DP.A.2,Бот,Bot,pack,DP,ok,r/1\n"], [])
    assert list(_by_ru(g)) == ["Бот"]
    assert g.notes == ["snapshot: 1 rows skipped, term_ru has no Cyrillic (graph data defect)"]


def test_duplicate_names_collapse_when_english_agrees(tmp_path):
    g = _load(
        tmp_path,
        ["DP.M.1,Карта,Map,pack,DP,ok,r/1\n", "ZP.M.1,карта ,Map,zp,ZP,ok,r/1\n"],
        [],
    )
    assert len(g.terms) == 1
    assert g.terms[0].tier == 1  # the strictest level among the duplicates wins


def test_duplicate_names_with_conflicting_english_are_dropped(tmp_path):
    g = _load(tmp_path, ["DP.M.1,Карта,Map,pack,DP,ok,r/1\n", "ECO.M.1,Карта,Chart,pack,ECO,ok,r/1\n"], [])
    assert g.terms == []
    assert "conflicting English names" in g.notes[0]


def test_local_row_cannot_revive_a_term_the_graph_dropped_as_conflicting(tmp_path):
    with pytest.raises(GlossaryError, match="conflicting English names"):
        _load(
            tmp_path,
            ["DP.M.1,Карта,Map,pack,DP,ok,r/1\n", "ECO.M.1,Карта,Chart,pack,ECO,ok,r/1\n"],
            ["Карта,Map,,,1\n"],
        )


def test_unknown_level_fails_closed(tmp_path):
    with pytest.raises(GlossaryError, match="level 'guide'"):
        _load(tmp_path, ["GUIDE.1,Шаг,Step,guide,GUIDE,ok,r/1\n"], [])


def test_local_row_duplicating_graph_term_is_an_error(tmp_path):
    with pytest.raises(GlossaryError, match="remove it from the local glossary"):
        _load(tmp_path, ["DP.X.1,Практика,Practice,pack,DP,ok,r/1\n"], ["Практика,Practice,,,2\n"])


def test_local_row_may_only_raise_the_tier_of_a_graph_term(tmp_path):
    g = _load(tmp_path, ["DP.X.1,Практика,Practice,pack,DP,ok,r/1\n"], ["практика,Practice,,,1\n"])
    term = _by_ru(g)["Практика"]
    assert (term.term_en, term.tier) == ("Practice", 1)
    assert g.notes == ["tier map gap: «Практика» kept at tier 1 by the local glossary"]


def test_local_row_with_different_english_is_an_error(tmp_path):
    with pytest.raises(GlossaryError, match="differs from graph"):
        _load(tmp_path, ["DP.X.1,Практика,Practice,pack,DP,ok,r/1\n"], ["Практика,Practise,,,1\n"])


def test_duplicate_local_row_is_an_error(tmp_path):
    with pytest.raises(GlossaryError, match="twice"):
        _load(tmp_path, [], ["Пак,Pack,,,1\n", "пак,Pack,,,1\n"])


def test_missing_manifest_block_and_missing_file_fail(tmp_path):
    with pytest.raises(GlossaryError, match="required"):
        load_glossary({}, tmp_path)
    manifest = {"glossary": {"snapshot": "nope.csv", "local": "nope2.csv", "tier_by_level": TIERS}}
    with pytest.raises(GlossaryError, match="not found"):
        load_glossary(manifest, tmp_path)


def test_template_glossary_loads_and_keeps_strict_local_terms():
    manifest = yaml.safe_load((REPO / "translation-manifest.yaml").read_text(encoding="utf-8"))
    glossary = load_glossary(manifest, REPO)
    terms = _by_ru(glossary)
    assert terms
    # Structural, not live data: the daily supplier may rename or drop any graph term, and its own merge
    # request must not fail here. Every local row stays loaded and never gets weaker than it is written.
    with (REPO / manifest["glossary"]["local"]).open(encoding="utf-8", newline="") as handle:
        for row in csv.DictReader(handle):
            term = terms[row["term_ru"].strip()]
            if row["tier"].strip().isdigit():
                assert term.tier <= int(row["tier"])


# Contract for the live graph lookup (decision D', WP-617 Ф4): translation never reaches the graph.
# Only the supplier workflow (glossary-supplier.yml) talks to the graph; translate-sync.yml may run
# an explicit allowlist of scripts, and nothing those scripts import or start may reach the graph.
# The flag live_lookup_enabled is introduced together with the live lookup on the draft branch (pilot, 07.11).

TRANSLATE_WORKFLOW = REPO / ".github/workflows/translate-sync.yml"
SUPPLIER_WORKFLOW = REPO / ".github/workflows/glossary-supplier.yml"
SCRIPT_PATH_RE = re.compile(r"(?:\./)?((?:scripts|setup|\.github/scripts)/[A-Za-z0-9_./-]+\.(?:py|sh))")
TRANSLATE_ALLOWED_SCRIPTS = {
    "scripts/translate.py",
    "scripts/delivery_checks.py",
    "scripts/assemble_distribution.py",
    "scripts/normalize_en_phase_labels.py",
    "scripts/tests/test_assemble_distribution.py",
    "scripts/tests/test_delivery_content.py",
    "scripts/tests/test_delivery_formal.py",
    "scripts/tests/test_glossary_source.py",
    "scripts/tests/test_normalize_en_phase_labels.py",
    "scripts/tests/test_translate_delta.py",
}
# Programs the allowed scripts may start as subprocesses.
ALLOWED_PROGRAMS = {"git"}
GRAPH_MARKERS = (
    "knowledge-mcp",
    "GLOSSARY_LIVE_LOOKUP",
    "GLOSSARY_EXPORTER_SERVICE_SECRET",
    "X-IWE-Service-Auth",
    "fetch-glossary-concepts",
    "glossary_supplier",
)
PROCESS_FUNCS = {
    "subprocess": {"run", "call", "check_call", "check_output", "Popen", "getoutput", "getstatusoutput"},
    "os": {"system", "popen", "posix_spawn", "posix_spawnp"},
    "asyncio": {"create_subprocess_exec", "create_subprocess_shell"},
}
PROCESS_PREFIXES = {"os": ("exec", "spawn")}


def _is_process_func(module: str, name: str) -> bool:
    return name in PROCESS_FUNCS.get(module, ()) or name.startswith(PROCESS_PREFIXES.get(module, ("\0",)))


def _import_closure(entry: Path) -> set[Path]:
    """The entry script and every scripts/ module it imports, transitively."""
    seen: set[Path] = set()
    todo = [entry]
    while todo:
        path = todo.pop()
        if path in seen:
            continue
        seen.add(path)
        for node in ast.walk(ast.parse(path.read_text(encoding="utf-8"))):
            names = [a.name for a in node.names] if isinstance(node, ast.Import) else []
            if isinstance(node, ast.ImportFrom) and node.module:
                names = [node.module]
            for name in names:
                local = SCRIPTS / (name.split(".")[0] + ".py")
                if local.is_file():
                    todo.append(local)
    return seen


def _process_callees(tree: ast.AST) -> tuple[dict[str, str], dict[str, str]]:
    """Local names bound to process modules (aliases) and to process functions (from-imports)."""
    modules: dict[str, str] = {}
    funcs: dict[str, str] = {}
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                if alias.name in PROCESS_FUNCS:
                    modules[alias.asname or alias.name] = alias.name
        elif isinstance(node, ast.ImportFrom) and node.module in PROCESS_FUNCS:
            for alias in node.names:
                if _is_process_func(node.module, alias.name):
                    funcs[alias.asname or alias.name] = node.module
    return modules, funcs


def _started_programs(path: Path) -> list[str]:
    """First argument of each process start; '<dynamic>' when it is not a literal."""
    tree = ast.parse(path.read_text(encoding="utf-8"))
    modules, funcs = _process_callees(tree)
    programs = []
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        func = node.func
        is_process = (
            isinstance(func, ast.Attribute)
            and isinstance(func.value, ast.Name)
            and func.value.id in modules
            and _is_process_func(modules[func.value.id], func.attr)
        ) or (isinstance(func, ast.Name) and func.id in funcs)
        if not is_process:
            continue
        keyword_args = [k.value for k in node.keywords if k.arg in ("args", "cmd", "program", "path")]
        first = node.args[0] if node.args else (keyword_args[0] if keyword_args else None)
        if isinstance(first, (ast.List, ast.Tuple)) and first.elts and isinstance(first.elts[0], ast.Constant):
            programs.append(str(first.elts[0].value))
        elif isinstance(first, ast.Constant):
            programs.append(str(first.value).split()[0])
        else:
            programs.append("<dynamic>")
    return programs


def test_translation_workflow_runs_only_allowed_scripts():
    referenced = set(SCRIPT_PATH_RE.findall(TRANSLATE_WORKFLOW.read_text(encoding="utf-8")))
    assert referenced == TRANSLATE_ALLOWED_SCRIPTS, (
        "translate-sync.yml runs a script outside the allowlist (or the allowlist is stale): "
        f"new {sorted(referenced - TRANSLATE_ALLOWED_SCRIPTS)}, gone {sorted(TRANSLATE_ALLOWED_SCRIPTS - referenced)}"
    )


def test_translation_workflow_text_never_names_the_graph():
    text = TRANSLATE_WORKFLOW.read_text(encoding="utf-8")
    assert [m for m in GRAPH_MARKERS if m in text] == []


def test_allowed_scripts_and_their_imports_never_reach_the_graph():
    entries = [REPO / p for p in TRANSLATE_ALLOWED_SCRIPTS if p.endswith(".py") and "/tests/" not in p]
    closure = set().union(*(_import_closure(e) for e in entries))
    assert SCRIPTS / "glossary_source.py" in closure  # the scan really follows imports
    for path in closure:
        text = path.read_text(encoding="utf-8")
        assert [m for m in GRAPH_MARKERS if m in text] == [], path.name
        assert set(_started_programs(path)) <= ALLOWED_PROGRAMS, (path.name, _started_programs(path))


def test_process_scan_sees_every_way_to_start_a_program(tmp_path):
    probe = tmp_path / "probe.py"
    probe.write_text(
        "import os, sys, asyncio\n"
        "import subprocess as sp\n"
        "from subprocess import run as go\n"
        "sp.run([sys.executable, 'scripts/fetch-glossary-concepts.py'])\n"
        "sp.check_output(args=['git', 'status'])\n"
        "go(['curl', 'x'])\n"
        "os.system('wget x')\n"
        "os.execvp('nc', ['nc'])\n"
        "asyncio.create_subprocess_exec('ssh')\n"
        "os.path.join('a', 'b')\n",
        encoding="utf-8",
    )
    assert sorted(_started_programs(probe)) == sorted(["<dynamic>", "git", "curl", "wget", "nc", "ssh"])


def test_supplier_workflow_is_not_started_by_a_push():
    triggers = yaml.safe_load(SUPPLIER_WORKFLOW.read_text(encoding="utf-8"))[True]  # YAML 1.1 reads "on" as True
    assert set(triggers) == {"schedule", "workflow_dispatch"}


def test_glossary_loader_has_no_network_imports():
    tree = ast.parse((SCRIPTS / "glossary_source.py").read_text(encoding="utf-8"))
    imported = {
        alias.name.split(".")[0]
        for node in ast.walk(tree)
        if isinstance(node, (ast.Import, ast.ImportFrom))
        for alias in (node.names if isinstance(node, ast.Import) else [ast.alias(node.module or "")])
    }
    assert not imported & {"urllib", "http", "socket", "requests", "httpx"}


# Second line of the isolation contract (Fable review, WP-617 Ф4b): what the import scan cannot see.

ALLOWED_URL_HOSTS = {"github.com", "openrouter.ai", "raw.githubusercontent.com"}
ALLOWED_WORKFLOW_REFERENCES = {
    "secrets.CANON_SYNC_APP_KEY",
    "secrets.OPENROUTER_API_KEY",
    "vars.CANON_SYNC_APP_ID",
    "vars.EN_DISTRIBUTION_ASSEMBLE",
}
# The optional user:password@ part may hold a workflow expression with spaces: ${{ steps.x.outputs.token }}.
URL_HOST_RE = re.compile(r"https?://(?:[^/@'\"\n]*@)?([A-Za-z0-9.-]+)")
REFERENCE_RE = re.compile(r"\b(secrets|vars)\.([A-Za-z0-9_]+)")
NETWORK_TOOL_RE = re.compile(r"\b(curl|wget|ncat|telnet|ssh)\b")
NETWORK_IMPORT_RE = re.compile(r"import (requests|urllib|socket|httpx)|from urllib|http\.client")
DYNAMIC_CODE_NAMES = {"__import__", "exec", "eval", "import_module", "spec_from_file_location", "run_path"}


def _closure_files() -> set[Path]:
    entries = [REPO / p for p in TRANSLATE_ALLOWED_SCRIPTS if p.endswith(".py") and "/tests/" not in p]
    return set().union(*(_import_closure(e) for e in entries))


def test_hosts_named_by_translation_are_allowlisted():
    # A graph endpoint has to come from somewhere: a literal URL in the scripts or the workflow,
    # or a repository variable/secret. All three routes are closed here.
    texts = [p.read_text(encoding="utf-8") for p in _closure_files()] + [TRANSLATE_WORKFLOW.read_text(encoding="utf-8")]
    hosts = {host for text in texts for host in URL_HOST_RE.findall(text)}
    assert hosts <= ALLOWED_URL_HOSTS, sorted(hosts - ALLOWED_URL_HOSTS)


def test_translation_workflow_uses_only_allowlisted_secrets_and_variables():
    text = TRANSLATE_WORKFLOW.read_text(encoding="utf-8")
    used = {f"{kind}.{name}" for kind, name in REFERENCE_RE.findall(text)}
    assert used <= ALLOWED_WORKFLOW_REFERENCES, sorted(used - ALLOWED_WORKFLOW_REFERENCES)


def test_translation_workflow_run_steps_start_no_network_tools():
    workflow = yaml.safe_load(TRANSLATE_WORKFLOW.read_text(encoding="utf-8"))
    for job_name, job in workflow["jobs"].items():
        for step in job["steps"]:
            body = step.get("run") or ""
            where = (job_name, step.get("name"))
            assert not NETWORK_TOOL_RE.search(body), where
            assert not NETWORK_IMPORT_RE.search(body), where


def test_allowed_scripts_load_no_code_dynamically():
    for path in _closure_files():
        for node in ast.walk(ast.parse(path.read_text(encoding="utf-8"))):
            name = node.id if isinstance(node, ast.Name) else node.attr if isinstance(node, ast.Attribute) else None
            assert name not in DYNAMIC_CODE_NAMES, (path.name, name)


def test_contract_scans_catch_realistic_regressions(tmp_path):
    assert URL_HOST_RE.findall("https://x-access-token:${TOKEN}@github.com/o/r") == ["github.com"]
    assert URL_HOST_RE.findall("https://x-access-token:${{ steps.a.outputs.token }}@github.com/o/r") == ["github.com"]
    assert set(URL_HOST_RE.findall("urlopen('https://knowledge-mcp.example.workers.dev/mcp')")) - ALLOWED_URL_HOSTS
    assert REFERENCE_RE.findall("${{ secrets.GRAPH_TOKEN }} ${{ vars.GRAPH_ENDPOINT }}") == [
        ("secrets", "GRAPH_TOKEN"),
        ("vars", "GRAPH_ENDPOINT"),
    ]
    assert NETWORK_TOOL_RE.search('curl "$GRAPH_ENDPOINT"')
    assert NETWORK_IMPORT_RE.search("python3 - <<PYEOF\nimport urllib.request\nPYEOF")
    probe = tmp_path / "probe.py"
    probe.write_text("import importlib\nimportlib.import_module('glossary_' + 'live')\n", encoding="utf-8")
    names = {n.attr for n in ast.walk(ast.parse(probe.read_text(encoding="utf-8"))) if isinstance(n, ast.Attribute)}
    assert names & DYNAMIC_CODE_NAMES
