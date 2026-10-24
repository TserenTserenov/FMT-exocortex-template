#!/usr/bin/env bash
# Execute the wp-new skill's routing block against real create-wp.sh.
# Observe all four local records and prove the canonical copy stays untouched.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
python3 - "$ROOT" <<'PY'
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

repo = Path(sys.argv[1])
skill = (repo / '.claude/skills/wp-new/SKILL.md').read_text()
match = re.search(r'```bash\n(WP_GOVERNANCE_REPO=.*?)\n```', skill, re.S)
assert match, 'Missing executable governance routing block in wp-new'
command = match.group(1) + '\nIWE_GOVERNANCE_REPO="$WP_GOVERNANCE_REPO" bash "$CREATE_WP" "$@"\n'


def snapshot(directory):
    return {p.relative_to(directory): p.read_bytes()
            for p in directory.rglob('*') if p.is_file()}


def check_creation(root, governance, environment):
    state = root / '.claude/state'
    state.mkdir(parents=True)
    (state / 'wp-consent-1').touch()
    artifact = root / 'artifact.json'
    artifact.write_text(json.dumps({'artifact': 'Registration fixture',
                                    'resolution_path': 'fixture'}))
    result = subprocess.run(
        ['bash', '-c', command, 'wp-new', '--artifactor-result', str(artifact),
         '--budget', '1h', '--verification-class', 'closed-loop',
         '--hypothesis-relation', 'operational', '--repo', 'DS-result'],
        env=environment, text=True, capture_output=True,
    )
    assert result.returncode == 0, result.stdout + result.stderr
    cards = list((governance / 'inbox').glob('WP-*/WP-*.md'))
    assert len(cards) == 1, cards
    assert cards[0].relative_to(governance).as_posix() == 'inbox/WP-001/WP-001.md'
    assert 'wp: 1\n' in cards[0].read_text()
    for relative in ['docs/WP-REGISTRY.md', 'current/active-wp.md']:
        assert 'Registration fixture' in (governance / relative).read_text(), relative
    registry_row = next(line for line in (governance / 'docs/WP-REGISTRY.md').read_text().splitlines()
                        if 'Registration fixture' in line)
    assert 'DS-result' in [cell.strip() for cell in registry_row.split('|')]
    assert str(governance) not in registry_row, 'Temporary worktree leaked into registry'
    plans = list((governance / 'current').glob('WeekPlan*.md'))
    assert len(plans) == 1, plans
    assert plans[0].read_text().count('Registration fixture') == 1
    assert (state / 'wp-numbers/1').is_dir(), 'Reservation escaped shared workspace'
    checked = subprocess.run(
        ['bash', str(repo / 'scripts/check-wp-registered.sh'), '1', str(governance), str(plans[0])],
        text=True, capture_output=True)
    assert checked.returncode == 0, checked.stdout + checked.stderr


with tempfile.TemporaryDirectory(prefix='issue-1257-') as temporary:
    base = Path(temporary)
    for scenario in ['canonical', 'isolated']:
        root = base / scenario
        canon = root / 'DS-strategy'
        shutil.copytree(repo / 'seed/strategy', canon)
        (root / 'FMT-exocortex-template').symlink_to(repo, target_is_directory=True)
        env = dict(os.environ, IWE_ROOT=str(root), WORKSPACE_DIR=str(root),
                   IWE_GOVERNANCE_REPO='DS-strategy', CREATE_WP=str(repo / 'scripts/create-wp.sh'))
        env.pop('GOV_WT', None)
        governance = canon
        before = snapshot(canon)
        if scenario == 'isolated':
            governance = base / 'copy with spaces'
            shutil.copytree(canon, governance)
            env['GOV_WT'] = str(governance)
        check_creation(root, governance, env)
        if scenario == 'isolated':
            assert snapshot(canon) == before, 'Canonical files changed'
            assert not (governance / '.claude/state').exists(), 'Private number counter created'
        print(f'PASS: {scenario}: card, registry, WeekPlan, active-wp, shared counter')

    before = snapshot(base)
    env['GOV_WT'] = str(base / 'missing copy')
    refused = subprocess.run(['bash', '-c', command, 'wp-new'], env=env,
                             text=True, capture_output=True)
    assert refused.returncode != 0
    assert 'governance-копия недоступна' in refused.stderr
    assert snapshot(base) == before, 'Missing-copy refusal wrote files'
    print('PASS: missing governance copy refused before any write')
PY

# This family is the delivered CI entrypoint for the registration verifier.
bash "$ROOT/scripts/tests/check-wp-registered-smoke.sh"
