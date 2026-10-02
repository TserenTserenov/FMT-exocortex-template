#!/usr/bin/env bash
# wp-sync-bundle-origin-pinned-smoke.sh -- WP-561 Ф24 (peer-session
# 2026-09-27-09, Claude+Kimi+Codex): when the governance working copy is
# STALE/DIVERGED from origin but its remote-tracking ref is provably fresh,
# wp-sync-bundle.sh reads the cards from a snapshot of that one origin commit
# (CARD_SOURCE: origin-pinned, exit 0) instead of blocking (exit 3). Real
# bare-origin sandboxes, real git; the network is the file:// transport.
set -uo pipefail
BUNDLE="$(cd "$(dirname "$0")/../.." && pwd)/.claude/scripts/wp-sync-bundle.sh"
[ -f "$BUNDLE" ] || { echo "FAIL: $BUNDLE not found"; exit 1; }
SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT
GOV=DS-strategy
fails=0
assert() { if [ "$1" = "$2" ]; then echo "  ok   $3"; else echo "  FAIL $3 (got '$1', want '$2')"; fails=$((fails+1)); fi; }

card() {  # <dir> <num> <related-csv> <task>
  mkdir -p "$1/inbox/WP-$2"
  printf -- '---\nwp: %s\ntitle: "Fixture WP-%s"\nstatus: in_progress\nrelated: [%s]\ncreated: 2026-09-01\n---\n# WP-%s\n\n## Осталось\n\n**Что дальше:**\n- [ ] %s\n' \
    "$2" "$2" "$3" "$2" "$4" > "$1/inbox/WP-$2/WP-$2.md"
}
gcommit() { git -C "$1" add -A; git -C "$1" -c user.name=t -c user.email=t@t commit -qm "$2"; }

ORIGIN="$SANDBOX/origin.git"; git init -q --bare -b main "$ORIGIN"
SEED="$SANDBOX/seed"; git init -q "$SEED"; git -C "$SEED" checkout -q -b main
mkdir -p "$SEED/docs" "$SEED/archive/wp-contexts"
printf '| WP | P | Название | Статус |\n|---|---|---|---|\n| 9101 | P1 | **Fixture 9101** | 🔄 |\n| 9102 | P1 | **Fixture 9102** | 🔄 |\n' > "$SEED/docs/WP-REGISTRY.md"
touch "$SEED/archive/wp-contexts/.keep"
card "$SEED" 9101 "WP-9102" "seed task 9101"
card "$SEED" 9102 "" "seed task 9102"
gcommit "$SEED" seed
git -C "$SEED" remote add origin "$ORIGIN"; git -C "$SEED" push -q origin main

WS="$SANDBOX/ws"; mkdir -p "$WS"; git clone -q "$ORIGIN" "$WS/$GOV"          # the shared canonical checkout
PUB="$SANDBOX/pub"; git clone -q "$ORIGIN" "$PUB"                              # some other session's isolated copy

OUT="$SANDBOX/out.md"; ERR="$SANDBOX/err.txt"
run_bundle() {  # <wp> [extra args] -> prints rc; stdout/stderr land in $OUT/$ERR (set above, not here: $(...) is a subshell)
  IWE_WORKSPACE="$WS" IWE_GOVERNANCE_REPO="$GOV" WP_SYNC_GIT_TIMEOUT=5 bash "$BUNDLE" "$1" ${2:-} > "$OUT" 2> "$ERR"
  echo $?
}
line() { sed -n "${1}p" "$OUT"; }

echo "scenario A: working copy in sync -> exit 0, CARD_SOURCE: worktree"
rc=$(run_bundle WP-9101)
assert "$rc" "0" "exit 0"
assert "$(line 1)" "GIT_SYNC_STATUS: OK" "status OK"
assert "$(line 3)" "CARD_SOURCE: worktree" "cards read from the working copy"

echo "scenario B: origin advanced (card edited + new card), ref fetched but not merged -> STALE, origin-pinned, exit 0"
printf -- '- [ ] ORIGIN-ONLY-TASK-9101\n' >> "$PUB/inbox/WP-9101/WP-9101.md"
card "$PUB" 9103 "WP-9101" "origin-only card 9103"
gcommit "$PUB" "origin advances"; git -C "$PUB" push -q origin main
git -C "$WS/$GOV" fetch -q origin            # what refs-sync-broker does every minute: ref moves, tree does not
REMOTE=$(git -C "$WS/$GOV" ls-remote origin refs/heads/main | cut -f1)
rc=$(run_bundle WP-9101)
assert "$rc" "0" "exit 0 (not 3)"
assert "$(line 1)" "GIT_SYNC_STATUS: STALE" "working copy classified STALE"
assert "$(line 3 | cut -d' ' -f1-2)" "CARD_SOURCE: origin-pinned" "CARD_SOURCE is origin-pinned"
assert "$(line 3 | grep -o 'oid=[0-9a-f]*' | cut -d= -f2)" "$REMOTE" "pinned oid == ls-remote oid"
assert "$(grep -c 'ORIGIN-ONLY-TASK-9101' "$OUT")" "1" "origin-side edit of the card is visible in the bundle"
assert "$(grep -c 'ВНИМАНИЕ: карточки прочитаны с origin' "$ERR")" "1" "human-readable warning on stderr"
assert "$(grep -c 'ВСЕ файлы в ней потенциально устарели' "$ERR")" "1" "warning says the WHOLE working copy is stale (Kimi)"
assert "$(grep -c 'Источник карточек: origin-pinned' "$OUT")" "1" "bundle body names the card source"
assert "$(grep -c 'ORIGIN-ONLY-TASK-9101' "$WS/$GOV/inbox/WP-9101/WP-9101.md")" "0" "working copy itself untouched (read-only)"
assert "$(git -C "$WS/$GOV" status --porcelain | wc -l | tr -d ' ')" "0" "no writes into the working copy"
rc=$(run_bundle WP-9103)
assert "$rc" "0" "card that exists only on origin is found (full-universe snapshot)"
assert "$(grep -c 'origin-only card 9103' "$OUT")" "1" "its content comes from origin"
assert "$(ls -d "${TMPDIR:-/tmp}"/wp-sync-origin.* 2>/dev/null | wc -l | tr -d ' ')" "0" "temp snapshot cleaned up"

echo "scenario B2: no PyYAML -> the card path stays repo-relative (stdlib-only resolver), card history is found"
NOYAML="$SANDBOX/noyaml"; mkdir -p "$NOYAML"
printf 'raise ImportError("fixture: PyYAML is not installed")\n' > "$NOYAML/yaml.py"
PYTHONPATH="$NOYAML" IWE_WORKSPACE="$WS" IWE_GOVERNANCE_REPO="$GOV" WP_SYNC_GIT_TIMEOUT=5 bash "$BUNDLE" WP-9101 > "$OUT" 2> "$ERR"; rc=$?
assert "$rc" "0" "exit 0 without PyYAML"
assert "$(line 3 | cut -d' ' -f1-2)" "CARD_SOURCE: origin-pinned" "still origin-pinned without PyYAML"
assert "$(grep -Ec '^  - [0-9a-f]+ seed$' "$OUT")" "1" "history of the related card is listed (repo-relative path), not '_нет коммитов_'"

echo "scenario C: origin advanced again, ref NOT fetched (lagging) -> fail closed, exit 3"
printf -- '- [ ] SECOND-ORIGIN-TASK\n' >> "$PUB/inbox/WP-9101/WP-9101.md"
gcommit "$PUB" "origin advances again"; git -C "$PUB" push -q origin main
rc=$(run_bundle WP-9101)
assert "$rc" "3" "exit 3 when the remote-tracking ref lags behind ls-remote"
assert "$(line 3)" "CARD_SOURCE: worktree" "no origin-pinned claim without a fresh ref"
assert "$(grep -c 'Sync Gate заблокирован' "$ERR")" "1" "blocked message on stderr"

echo "scenario D: same, with --force-sync -> exit 0, CARD_SOURCE: worktree-forced"
rc=$(run_bundle WP-9101 --force-sync)
assert "$rc" "0" "exit 0 under --force-sync"
assert "$(line 3)" "GIT_SYNC_OVERRIDE: true" "override flag line kept"
assert "$(line 4)" "CARD_SOURCE: worktree-forced" "forced read of the working copy is labelled"

echo "scenario E: DIVERGED (local unpublished commit + origin ahead), ref fresh -> origin-pinned, exit 0"
git -C "$WS/$GOV" fetch -q origin
printf -- '- [ ] LOCAL-UNPUBLISHED-TASK\n' >> "$WS/$GOV/inbox/WP-9102/WP-9102.md"
gcommit "$WS/$GOV" "local canonical writer"
rc=$(run_bundle WP-9101)
assert "$rc" "0" "exit 0"
assert "$(line 1)" "GIT_SYNC_STATUS: DIVERGED" "classified DIVERGED"
assert "$(line 3 | cut -d' ' -f1-2)" "CARD_SOURCE: origin-pinned" "origin-pinned under DIVERGED too"
assert "$(grep -c 'SECOND-ORIGIN-TASK' "$OUT")" "1" "latest origin content read"
assert "$(grep -c 'LOCAL-UNPUBLISHED-TASK' "$OUT")" "0" "local unpublished edit of a related card is NOT shown (origin is the source)"

echo "scenario F: unknown WP under origin-pinned -> exit 1, names the source"
rc=$(run_bundle WP-9999)
assert "$rc" "1" "exit 1 for a missing card"
assert "$(grep -c 'источник: origin-pinned' "$ERR")" "1" "error names the card source"

echo "scenario G: governance repo without archive/ (fresh template install) -> origin-pinned still works"
ORIGIN2="$SANDBOX/origin2.git"; git init -q --bare -b main "$ORIGIN2"
SEED2="$SANDBOX/seed2"; git init -q "$SEED2"; git -C "$SEED2" checkout -q -b main
mkdir -p "$SEED2/docs"
printf '| WP | P | Название | Статус |\n|---|---|---|---|\n| 9201 | P1 | **Fixture 9201** | 🔄 |\n' > "$SEED2/docs/WP-REGISTRY.md"
card "$SEED2" 9201 "" "seed task 9201"
gcommit "$SEED2" seed
git -C "$SEED2" remote add origin "$ORIGIN2"; git -C "$SEED2" push -q origin main
WS2="$SANDBOX/ws2"; mkdir -p "$WS2"; git clone -q "$ORIGIN2" "$WS2/$GOV"
PUB2="$SANDBOX/pub2"; git clone -q "$ORIGIN2" "$PUB2"
printf -- '- [ ] ORIGIN-ONLY-TASK-9201\n' >> "$PUB2/inbox/WP-9201/WP-9201.md"
gcommit "$PUB2" "origin advances 2"; git -C "$PUB2" push -q origin main
git -C "$WS2/$GOV" fetch -q origin
IWE_WORKSPACE="$WS2" IWE_GOVERNANCE_REPO="$GOV" WP_SYNC_GIT_TIMEOUT=5 bash "$BUNDLE" WP-9201 > "$OUT" 2> "$ERR"; rc=$?
assert "$rc" "0" "exit 0 (a missing archive/ does not break the snapshot)"
assert "$(line 3 | cut -d' ' -f1-2)" "CARD_SOURCE: origin-pinned" "CARD_SOURCE is origin-pinned"
assert "$(grep -c 'ORIGIN-ONLY-TASK-9201' "$OUT")" "1" "origin-side edit of the card is visible"

[ "$fails" = 0 ] && echo "PASS: all scenarios" || { echo "FAIL: $fails assertion(s)"; exit 1; }
