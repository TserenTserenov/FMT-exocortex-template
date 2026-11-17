#!/usr/bin/env bash
# Issue #1569 (F3 of the v0.42.0 red team): scripts/iwe-notify has no extension and shipped an
# author repo name; the author-content check [1/5] of setup/validate-template.sh only scanned
# *.md/.sh/.py/... files, so it never saw it.
#   1. A delivered (manifest) file without an extension that carries an author name FAILs [1/5],
#      both for an existing delivered file and for a new one listed in the manifest.
#   2. scripts/iwe-notify takes the governance repo name from the workspace settings, not from a
#      hard-coded author name: a gateway in a repo with a custom name is found.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf -- "$TEST_ROOT"' EXIT
TOKEN="DS-my""-strategy"   # split so this file does not trip the scan itself

fail() { echo "FAIL: $1" >&2; [ -z "${2:-}" ] || echo "$2" >&2; exit 1; }

# --- 1. validate-template sees extension-less delivered files ---------------
REPO="$TEST_ROOT/repo"
git clone --quiet --no-hardlinks "$ROOT" "$REPO"
for f in setup/validate-template.sh scripts/iwe-notify .githooks/pre-commit update-manifest.json; do
    cp "$ROOT/$f" "$REPO/$f"
done

validate() { (cd "$REPO" && bash setup/validate-template.sh --mode=pristine . 2>&1); }

output=$(validate) || fail "clean template must pass" "$output"
grep -qF '[1/5] Author-specific content... PASS' <<<"$output" || fail "clean template: [1/5] must pass" "$output"

# An existing delivered file without an extension.
printf '# fallback: %s\n' "$TOKEN" >> "$REPO/.githooks/commit-msg"
rc=0; output=$(validate) || rc=$?
[ "$rc" -ne 0 ] || fail "author name in an extension-less delivered file must fail" "$output"
grep -qF "Found '$TOKEN' (global)" <<<"$output" || fail "[1/5] must name the token" "$output"
grep -qF ".githooks/commit-msg" <<<"$output" || fail "[1/5] must name the extension-less file" "$output"
git -C "$REPO" checkout --quiet -- .githooks/commit-msg

# A new delivered file without an extension, listed in the manifest.
mkdir -p "$REPO/scripts"
printf '#!/usr/bin/env bash\nrepo=%s\n' "$TOKEN" > "$REPO/scripts/issue-1569-probe"
jq '.files += [{"path": "scripts/issue-1569-probe", "sha256": "0"}]' "$REPO/update-manifest.json" \
    > "$TEST_ROOT/manifest.json"
cp "$TEST_ROOT/manifest.json" "$REPO/update-manifest.json"
rc=0; output=$(validate) || rc=$?
[ "$rc" -ne 0 ] || fail "author name in a new extension-less manifest file must fail" "$output"
grep -qF "scripts/issue-1569-probe" <<<"$output" || fail "[1/5] must name the new file" "$output"

# --- 2. iwe-notify reads the governance repo name from the settings ----------
WS="$TEST_ROOT/ws"
mkdir -p "$WS/my-plans/scripts"
printf 'GITHUB_USER=x\nGOVERNANCE_REPO="my-plans"\n' > "$WS/.exocortex.env"
cat > "$WS/my-plans/scripts/iwe-tg" <<'EOF'
#!/usr/bin/env bash
echo called > "$(dirname "$0")/../gateway-called"
exit 0
EOF
chmod +x "$WS/my-plans/scripts/iwe-tg"
out=$(env -u IWE_GOVERNANCE_REPO -u IWE_NOTIFY_GATEWAY -u IWE_WORKSPACE -u TELEGRAM_BOT_TOKEN -u TELEGRAM_CHAT_ID \
        IWE_ROOT="$WS" TMPDIR="$TEST_ROOT" bash "$ROOT/scripts/iwe-notify" --source issue-1569 "hello" 2>/dev/null) || true
[ -f "$WS/my-plans/gateway-called" ] || fail "iwe-notify must find the gateway of the repo named in the settings" "$out"
grep -qx 'iwe-notify: outcome=deferred' <<<"$out" || fail "iwe-notify must report the gateway outcome" "$out"

echo "PASS: issue 1569 extension-less author scan and iwe-notify governance name"
