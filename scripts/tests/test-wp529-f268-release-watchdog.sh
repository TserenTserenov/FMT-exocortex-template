#!/usr/bin/env bash
# WP-529 Ф268: release-watchdog.yml under the "release from the release branch" order.
# Runs the real "Notify about stale release PRs" step (extracted from the YAML) with a stub
# `gh` and fixture JSON; no network. Checks:
#   - release/vX.Y.Z PR with no tag vX.Y.Z (still being checked) -> no issue, however old;
#   - tag older than MERGE_BACK_HOURS, PR still open -> ONE merge-back issue; an open issue
#     with the same key is edited, not duplicated; a fresh tag -> nothing; a lightweight tag
#     works too;
#   - another release/* head keeps the STALE_HOURS rule.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
WF="$ROOT/.github/workflows/release-watchdog.yml"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/iwe-f268-wd.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

FAILS=0
ok()   { echo "  ok: $1"; }
fail() { echo "  FAIL: $1"; FAILS=$((FAILS + 1)); }

command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }
python3 - "$WF" "$TMP/step.sh" <<'PY' || { echo "FAIL: cannot extract the watchdog step"; exit 1; }
import sys, yaml
steps = yaml.safe_load(open(sys.argv[1], encoding='utf-8'))['jobs']['watch']['steps']
run = [s for s in steps if s.get('name') == 'Notify about stale release PRs'][0]['run']
assert '${{' not in run, 'the step must take its inputs from env'
open(sys.argv[2], 'w', encoding='utf-8').write(run)
PY

FX="$TMP/fx"
mkdir -p "$TMP/bin"
cat > "$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "label create") exit 0 ;;
  "pr list") cat "$FX/prs.json" ;;
  "issue list") cat "$FX/issues.json" ;;
  "issue create"|"issue edit") printf '%s\n' "$*" >> "$FX/actions.log" ;;
  api\ *)
    case "$2" in
      */git/ref/tags/*) f="$FX/ref-${2##*/}.json"; [ -f "$f" ] && cat "$f" || { echo "Not Found" >&2; exit 1; } ;;
      */git/tags/*|*/git/commits/*) cat "$FX/obj-${2##*/}.json" ;;
      *) exit 1 ;;
    esac ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH" FX

iso_ago() { python3 -c 'import sys, datetime as d; print((d.datetime.now(d.timezone.utc) - d.timedelta(hours=float(sys.argv[1]))).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$1"; }
reset() { rm -rf "$FX"; mkdir -p "$FX"; echo '[]' > "$FX/issues.json"; : > "$FX/actions.log"; }
pr() {  # pr <number> <head> <created hours ago> -> one-PR list
    printf '[{"number":%s,"headRefName":"%s","baseRefName":"main","headRefOid":"abcdef0123456789","createdAt":"%s","url":"https://example.invalid/pull/%s"}]\n' \
        "$1" "$2" "$(iso_ago "$3")" "$1" > "$FX/prs.json"
}
annotated_tag() {  # annotated_tag <tag> <hours ago>
    printf '{"object":{"type":"tag","sha":"t1"}}\n' > "$FX/ref-$1.json"
    printf '{"tagger":{"date":"%s"}}\n' "$(iso_ago "$2")" > "$FX/obj-t1.json"
}
run_step() {
    : > "$TMP/out"
    (GITHUB_OUTPUT="$TMP/out" GITHUB_REPOSITORY=owner/template STALE_HOURS=12 MERGE_BACK_HOURS=24 \
        bash --noprofile --norc -eo pipefail "$TMP/step.sh") > "$TMP/log" 2>&1
}
actions() { wc -l < "$FX/actions.log" | tr -d ' '; }

echo "== release PR under checking (no tag) =="
reset; pr 12 release/v0.43.0 72
if run_step && [ "$(actions)" = 0 ] && grep -q "ещё проверяется" "$TMP/log"; then
  ok "3-day-old release PR without v0.43.0 -> no issue"
else fail "no tag must mean no issue: $(cat "$TMP/log") / $(cat "$FX/actions.log")"; fi

echo "== tag 30 h ago, PR still open =="
reset; pr 12 release/v0.43.0 72; annotated_tag v0.43.0 30
if run_step && [ "$(actions)" = 1 ] && grep -q "^issue create --label release-pr-waiting --title Обратное слияние просрочено: PR #12 v0.43.0" "$FX/actions.log" \
   && grep -q "следующая нарезка" "$FX/actions.log" && grep -q "found=12 " "$TMP/out"; then
  ok "one merge-back issue created, names the blocked cut"
else fail "overdue merge-back: $(cat "$TMP/log") / $(cat "$FX/actions.log")"; fi

echo "== the same, an open issue already exists (new head commit does not matter) =="
reset; annotated_tag v0.43.0 50
printf '[{"number":12,"headRefName":"release/v0.43.0","baseRefName":"main","headRefOid":"9999999aaaa","createdAt":"%s","url":"u"}]\n' "$(iso_ago 80)" > "$FX/prs.json"
echo '[{"number":77,"state":"OPEN","title":"Обратное слияние просрочено: PR #12 v0.43.0 не влит в main уже 26 ч после выпуска"}]' > "$FX/issues.json"
if run_step && [ "$(actions)" = 1 ] && grep -q "^issue edit 77 --title .*уже 50 ч" "$FX/actions.log"; then
  ok "existing issue #77 edited, no second issue"
else fail "must edit #77: $(cat "$FX/actions.log")"; fi

echo "== tag only 5 h ago =="
reset; pr 12 release/v0.43.0 72; annotated_tag v0.43.0 5
if run_step && [ "$(actions)" = 0 ]; then ok "fresh release -> no issue yet"; else fail "fresh tag: $(cat "$FX/actions.log")"; fi

echo "== lightweight tag =="
reset; pr 12 release/v0.43.0 72
printf '{"object":{"type":"commit","sha":"c1"}}\n' > "$FX/ref-v0.43.0.json"
printf '{"committer":{"date":"%s"}}\n' "$(iso_ago 30)" > "$FX/obj-c1.json"
if run_step && grep -q "^issue create .*PR #12 v0.43.0" "$FX/actions.log"; then ok "commit-type tag dated by its commit"
else fail "lightweight tag: $(cat "$TMP/log")"; fi

echo "== other release/* head keeps the 12 h rule =="
reset; pr 13 release/hotfix-x 13
if run_step && grep -q "^issue create .*Релизный PR #13 @abcdef0 ждёт слияния уже 13 ч" "$FX/actions.log"; then
  ok "non-version release branch -> old notice"
else fail "legacy rule: $(cat "$TMP/log") / $(cat "$FX/actions.log")"; fi

echo
if [ "$FAILS" -gt 0 ]; then
  echo "FAILED: $FAILS check(s)"
  exit 1
fi
echo "PASS"
