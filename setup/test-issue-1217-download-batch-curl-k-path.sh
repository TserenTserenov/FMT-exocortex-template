#!/usr/bin/env bash
# issue #1217 (continuation of #980): download_batch()'s parallel path wrote the
# destination path straight into a curl -K config file. MSYS only rewrites a
# POSIX path inside a command-line ARGUMENT, not inside a file curl itself
# reads, so a native curl.exe given "output = /tmp/..." can't find it and fails
# with exit 23. Fixed by converting through cygpath -m (forward slashes) before
# writing the config line, same pattern already used for day-open-scaffold.sh's
# CONFIG_PY (#1149). This extracts just the config-line-building loop (not the
# whole function, which also shells out to curl) and exercises it against a
# fake cygpath on PATH, plus the no-cygpath fallback used on Linux/macOS.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
UPDATE_SH="$ROOT/update.sh"

fail=0
pass() { echo "  ✅ PASS: $*"; }
fail_test() { echo "  ❌ FAIL: $*" >&2; fail=1; }

grep -q 'if command -v cygpath >/dev/null 2>&1; then' "$UPDATE_SH" \
  && grep -q 'dst_cfg=\$(cygpath -m "\$dst" 2>/dev/null) || dst_cfg="\$dst"' "$UPDATE_SH" \
  || { fail_test "download_batch() no longer converts the -K config path via cygpath -m"; exit 1; }

build_cfg_line() {  # <dst>  -- mirrors the per-file body of download_batch()'s parallel loop
    local dst="$1" dst_cfg="$1"
    if command -v cygpath >/dev/null 2>&1; then
        dst_cfg=$(cygpath -m "$dst" 2>/dev/null) || dst_cfg="$dst"
    fi
    printf 'output = "%s"\n' "$dst_cfg"
}

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/iwe-1217-test.XXXXXX")"
trap 'rm -rf "$TEST_ROOT"' EXIT

# No cygpath on PATH (the real Linux/macOS case): path passes through unchanged.
PATH_NO_CYGPATH="$TEST_ROOT/bin-empty"
mkdir -p "$PATH_NO_CYGPATH"
got=$(PATH="$PATH_NO_CYGPATH" build_cfg_line "/tmp/iwe-update/files/a/b.sh")
[ "$got" = 'output = "/tmp/iwe-update/files/a/b.sh"' ] \
  && pass "no cygpath on PATH: destination path unchanged" \
  || fail_test "no cygpath on PATH: got '$got'"

# A fake cygpath on PATH (simulating Git Bash / MSYS): the POSIX path is
# converted to the drive-letter form curl -K actually accepts.
PATH_WITH_CYGPATH="$TEST_ROOT/bin-cygpath"
mkdir -p "$PATH_WITH_CYGPATH"
cat > "$PATH_WITH_CYGPATH/cygpath" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "-m" ] || exit 1
printf 'C:/iwe-fixture/temp/iwe-update/files/a/b.sh\n'
EOF
chmod +x "$PATH_WITH_CYGPATH/cygpath"
got=$(PATH="$PATH_WITH_CYGPATH:$PATH" build_cfg_line "/tmp/iwe-update/files/a/b.sh")
[ "$got" = 'output = "C:/iwe-fixture/temp/iwe-update/files/a/b.sh"' ] \
  && pass "cygpath on PATH: destination path converted to drive-letter form" \
  || fail_test "cygpath on PATH: got '$got'"

exit "$fail"
