"""Tests for scripts/glossary_source.py (WP-617 Ф3): graph snapshot + local queue."""

from __future__ import annotations

import ast
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
    terms = _by_ru(load_glossary(manifest, REPO))
    assert terms["Пак"].tier == 1  # tier-1 local terms survive the switch to the snapshot
    assert terms["Практика"].term_en == "Practice"  # removed from local, now served by the graph


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
PROCESS_CALLS = {"run", "call", "check_call", "check_output", "Popen", "system", "popen"}


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


def _started_programs(path: Path) -> list[str]:
    """First argument of each subprocess/os call; '<dynamic>' when it is not a literal."""
    programs = []
    for node in ast.walk(ast.parse(path.read_text(encoding="utf-8"))):
        if not (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)):
            continue
        owner = node.func.value
        is_process = isinstance(owner, ast.Name) and (
            (owner.id == "subprocess" and node.func.attr in PROCESS_CALLS)
            or (owner.id == "os" and (node.func.attr in PROCESS_CALLS or node.func.attr.startswith("exec")))
        )
        if not is_process or not node.args:
            continue
        first = node.args[0]
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


def test_process_scan_sees_dynamic_and_script_calls(tmp_path):
    probe = tmp_path / "probe.py"
    probe.write_text(
        "import os, subprocess, sys\n"
        "subprocess.run([sys.executable, 'scripts/fetch-glossary-concepts.py'])\n"
        "subprocess.run(['git', 'status'])\n"
        "os.system('curl x')\n",
        encoding="utf-8",
    )
    assert _started_programs(probe) == ["<dynamic>", "git", "curl"]


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
