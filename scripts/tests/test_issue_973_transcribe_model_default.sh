#!/usr/bin/env bash
# test_issue_973_transcribe_model_default.sh — regression for issue #973.
#
# scripts/iwe-transcribe.sh (the executor of /transcribe) hard-coded the model as
# $HOME/.local/share/mlx-whisper/mlx_models/large-v3. Nothing in setup.sh,
# update.sh or step 1 of the skill creates that directory, and mlx_whisper takes
# a path that does not exist for a Hugging Face repo id and dies with
# HFValidationError.
#
# Contract after the fix (the model argument handed to mlx_whisper):
#   1. $IWE_WHISPER_MODEL when it is set and non-empty (path or repo id);
#   2. else the local directory ~/.local/share/mlx-whisper/mlx_models/large-v3
#      when it exists;
#   3. else the Hugging Face repo id mlx-community/whisper-large-v3-mlx.
#
# The venv interpreter is a stub that logs the model argument: no network, no
# Metal, no real model. HOME and TMPDIR are temporary.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$ROOT/scripts/iwe-transcribe.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAKE_HOME="$TMP/home"
mkdir -p "$FAKE_HOME" "$TMP/tmp"
BASE="$FAKE_HOME/.local/share/mlx-whisper"
VENV_BIN="$BASE/.venv-whisper/bin"
LOCAL_MODEL="$BASE/mlx_models/large-v3"
HF_MODEL="mlx-community/whisper-large-v3-mlx"
AUDIO="$TMP/a.mp3"
LOG="$TMP/stub.log"
printf 'x' > "$AUDIO"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

[ -f "$SCRIPT" ] || { echo "FAIL: script not found: $SCRIPT"; exit 1; }

# Stub interpreter: the import check succeeds; the transcribe call (python -
# <file> <model>, code on stdin) logs its model argument and the code it was fed.
mkdir -p "$VENV_BIN"
cat > "$VENV_BIN/python" <<'STUB'
#!/bin/bash
if [ "$1" = "-c" ]; then exit 0; fi
if [ "$1" = "-" ]; then
  printf 'MODEL_ARG=%s\n' "$3" >> "$STUB_LOG"
  cat > "$STUB_LOG.code"
  echo "stub transcript"
  exit 0
fi
echo "unexpected stub call: $*" >> "$STUB_LOG.err"
exit 9
STUB
chmod +x "$VENV_BIN/python"

# run_script [VAR=value ...] : runs the script under test; sets OUT, RC and MODEL_SEEN
# (the model argument the stub received, empty when the stub was not reached).
run_script() {
    : > "$LOG"
    OUT=$(env -u IWE_WHISPER_MODEL HOME="$FAKE_HOME" TMPDIR="$TMP/tmp" STUB_LOG="$LOG" "$@" \
        /bin/bash "$SCRIPT" "$AUDIO" 2>"$TMP/stderr")
    RC=$?
    MODEL_SEEN=$(sed -n 's/^MODEL_ARG=//p' "$LOG" | tail -1)
}

expect_model() { # <desc> <expected model argument>
    if [ "$RC" -eq 0 ] && [ "$MODEL_SEEN" = "$2" ] && [ "$OUT" = "stub transcript" ]; then
        ok "$1"
    else
        bad "$1 (rc=$RC) — expected model [$2], got [$MODEL_SEEN], stdout [$OUT], stderr [$(tr '\n' ' ' < "$TMP/stderr")]"
    fi
}

# 1. Nothing local, nothing set: the Hugging Face repo id (the reported failure).
run_script
expect_model "no local directory, no override: Hugging Face repo id" "$HF_MODEL"

# 2. The local directory exists: it is used as before.
mkdir -p "$LOCAL_MODEL"
run_script
expect_model "local directory exists: the local directory" "$LOCAL_MODEL"

# 3. The override beats both.
run_script IWE_WHISPER_MODEL=/custom/model/dir
expect_model "IWE_WHISPER_MODEL overrides an existing local directory" "/custom/model/dir"
run_script IWE_WHISPER_MODEL=someorg/other-whisper-mlx
expect_model "IWE_WHISPER_MODEL accepts a Hugging Face repo id" "someorg/other-whisper-mlx"
rmdir "$LOCAL_MODEL"
run_script IWE_WHISPER_MODEL=/custom/model/dir
expect_model "IWE_WHISPER_MODEL overrides the repo-id default too" "/custom/model/dir"

# 4. An empty override is "not set", not a model named "".
run_script IWE_WHISPER_MODEL=
expect_model "empty IWE_WHISPER_MODEL falls through to the default" "$HF_MODEL"
mkdir -p "$LOCAL_MODEL"
run_script IWE_WHISPER_MODEL=
expect_model "empty IWE_WHISPER_MODEL falls through to the local directory" "$LOCAL_MODEL"
rmdir "$LOCAL_MODEL"

# 5. "Exists" means a directory: a plain file or a dangling link at that path is not a model.
printf 'not a model' > "$LOCAL_MODEL"
run_script
expect_model "a regular file at the local path is ignored" "$HF_MODEL"
rm -f "$LOCAL_MODEL"
ln -s "$TMP/does-not-exist" "$LOCAL_MODEL"
run_script
expect_model "a dangling link at the local path is ignored" "$HF_MODEL"
rm -f "$LOCAL_MODEL"
mkdir -p "$TMP/real-model-dir"
ln -s "$TMP/real-model-dir" "$LOCAL_MODEL"
run_script
expect_model "a link to a directory counts as the local directory" "$LOCAL_MODEL"
rm -f "$LOCAL_MODEL"

# 6. The chosen value is what the transcribe call actually uses (not dropped on the way).
run_script
if grep -q 'path_or_hf_repo=model_path' "$LOG.code" 2>/dev/null; then
    ok "the model argument is passed to mlx_whisper as path_or_hf_repo"
else
    bad "the python code does not hand the model argument to path_or_hf_repo"
fi

# 7. Unchanged behaviour: a missing audio file is still reported before any model work.
: > "$LOG"
ERR=$(env -u IWE_WHISPER_MODEL HOME="$FAKE_HOME" TMPDIR="$TMP/tmp" STUB_LOG="$LOG" \
    /bin/bash "$SCRIPT" "$TMP/missing.mp3" 2>&1 >/dev/null)
RC=$?
if [ "$RC" -eq 1 ] && [[ $ERR == *"file not found"* ]] && ! grep -q '^MODEL_ARG=' "$LOG"; then
    ok "missing audio file: error, no transcribe call"
else
    bad "missing audio file handling changed (rc=$RC, stderr: $ERR)"
fi

echo "---"
echo "issue #973: passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
